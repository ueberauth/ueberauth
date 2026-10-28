%%% -*- erlang -*-
%%%
%%% QUIC Listener
%%% RFC 9000 Section 5 - Connections
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC server listener for accepting connections.
%%%
%%% This module handles:
%%% - UDP socket management
%%% - Initial packet routing to connections
%%% - Connection ID management
%%% - Stateless retry (optional)
%%%
%%% == Connection Handler Callback ==
%%%
%%% The `connection_handler' option decides which process owns each new
%%% connection, and so which process receives its `{quic, Conn, _}'
%%% events. Use it when you accept connections yourself rather than
%%% through a higher-level server such as `quic_h3'.
%%%
%%% ```
%%% Opts = #{
%%%     cert => Cert,
%%%     key => Key,
%%%     connection_handler => fun(Conn) ->
%%%         %% Return the process that will consume this connection's
%%%         %% events. It becomes the owner before the connection sees
%%%         %% its first packet.
%%%         {ok, HandlerPid}
%%%     end
%%% }
%%% '''
%%%
%%% Return `{ok, HandlerPid}' to take the connection, or `{error, Reason}'
%%% to decline it, in which case the listener logs a warning and keeps
%%% ownership. An arity-2 fun is called as `Fun(Conn, DCID)'.
%%%
%%% === Return the final owner ===
%%%
%%% The listener calls `quic:set_owner_sync/2' on the pid you return and
%%% only then hands the connection its first packet. That is the one
%%% moment at which ownership moves with nothing in flight.
%%%
%%% Do not return a short-lived broker that later transfers ownership to
%%% a worker. Between the broker's last read and the worker's
%%% `set_owner_sync' the connection is still delivering to the broker, and
%%% those events die with it. Draining the broker's mailbox does not close
%%% that window: the connection can emit into it after the drain returns.
%%%
%%% When the owner is an OTP process, take ownership in `init/1', or in
%%% the handler itself before returning:
%%%
%%% ```
%%% connection_handler => fun(Conn) ->
%%%     {ok, Pid} = my_conn:start_link(Conn),
%%%     ok = quic:set_owner_sync(Conn, Pid),
%%%     {ok, Pid}
%%% end
%%% '''
%%%
%%% `gen_server' and `gen_statem' both answer `start_link' before running
%%% any post-init callback, so a `set_owner_sync' in `handle_continue' or
%%% in a `state_enter' callback runs once the starter is already back in
%%% control, which reopens the same window.
%%%
%%% === Do not assume `connected' arrives first ===
%%%
%%% A datagram is processed before the connection changes state, so stream
%%% events from that datagram reach the owner ahead of
%%% `{quic, Conn, {connected, Info}}'. A client that coalesces its
%%% Finished with a 1-RTT packet does exactly this. An owner that waits
%%% for `connected' before entering its main loop mis-orders or swallows
%%% whatever came first.
%%%
%%% === Owner death ===
%%%
%%% Accepted connections monitor their owner and stop with
%%% `{shutdown, owner_down}' when it exits, sending CONNECTION_CLOSE to
%%% the peer, the way a `gen_tcp' socket follows its controlling process.
%%% Set `monitor_owner => false' in the listener options to keep a
%%% connection up after its handler dies; it then lives until its idle
%%% timeout, so close it explicitly on the way out.

-module(quic_listener).
-behaviour(gen_server).

%% Suppress pattern warnings for defensive callback handling (user-provided callbacks)
-dialyzer({no_match, create_connection/5}).

-export([
    start_link/2,
    start/2,
    stop/1,
    get_port/1,
    get_sockname/1,
    get_connections/1,
    register_cid/3,
    retire_cid/2,
    has_auth_method/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-compile([export_all, nowarn_export_all]).
-endif.

-export([recv_drops/0]).

-include("quic.hrl").
-include_lib("kernel/include/logger.hrl").

%% How long a stopping listener waits for its connections to close.
-define(CLOSE_CONNECTIONS_MS, 1000).

-define(QUIC_LOG_META, #{
    domain => [erlang_quic, listener], report_cb => fun quic_log:format_report/2
}).

%% Packets drained from the listener mailbox into one receive sweep.
-define(RECV_SWEEP_MAX, 256).

%% TLS credentials and ALPN handed to every connection this listener
%% starts.
-record(listener_tls, {
    %% Cert + private_key are optional; PSK-only listeners run with
    %% both `undefined' and rely on `psks' / `psk_callback'.
    cert :: binary() | undefined,
    cert_chain :: [binary()],
    private_key :: term() | undefined,
    %% TLS 1.3 external PSK (RFC 8446 §4.2.11). Either may be set
    %% independently; per-handshake selection happens in quic_connection.
    psks :: #{binary() => binary()} | undefined,
    psk_callback :: fun((binary()) -> {ok, binary()} | not_found) | undefined,
    %% Per-SNI cert selection (RFC 6066 §3). Invoked with the ClientHello
    %% server_name; its returned cert/key override the static ones above.
    sni_callback ::
        fun((binary() | undefined) -> {ok, map()} | {error, term()}) | undefined,
    alpn_list :: [binary()]
}).

-record(listener_state, {
    recv_queue_max = ?MAX_CONN_RECV_QUEUE_MSGS :: pos_integer(),
    socket :: gen_udp:socket() | socket:socket(),
    %% Socket state for quic_socket abstraction (for GRO support on Linux)
    socket_state :: quic_socket:socket_state() | undefined,
    %% Which socket backend: gen_udp or socket (OTP 27+ with GRO)
    socket_backend = gen_udp :: gen_udp | socket,
    %% GRO receiver process (when using socket backend)
    gro_receiver :: pid() | undefined,
    %% Shared sender serializing server-connection sendmsg calls
    %% (socket backend only; see quic_socket:start_shared_sender/1).
    send_sender :: pid() | undefined,
    send_gso_counter :: atomics:atomics_ref() | undefined,
    port :: inet:port_number(),
    tls :: #listener_tls{},
    %% Connection ID -> Pid mapping
    connections :: ets:tid(),
    %% Pid -> Connection ID, for the connections this listener started,
    %% so an exit deletes by key instead of scanning `connections'
    cid_index :: ets:tid(),
    tickets_table :: ets:tid(),
    %% Whether this listener owns the ETS tables (false in pool mode)
    owns_tables = true :: boolean(),
    %% Stateless reset secret (RFC 9000 Section 10.3). Also serves as
    %% the HMAC key for RFC 9000 §8.1 retry / NEW_TOKEN envelopes so
    %% operators only have to manage one rotating secret.
    reset_secret :: binary(),
    %% Address validation policy (RFC 9000 §8.1.2). `never' preserves
    %% the legacy no-retry behaviour; `always' makes the listener emit
    %% a Retry packet whenever a client's Initial arrives without a
    %% valid token. Token freshness bound is `token_max_age_ms'.
    address_validation = never :: never | always,
    token_max_age_ms = 600000 :: non_neg_integer(),
    %% Connection handler callback: fun(Conn) -> {ok, HandlerPid} where Conn is pid()
    connection_handler ::
        fun((pid()) -> {ok, pid()} | {error, term()})
        | fun((pid(), binary()) -> {ok, pid()} | {error, term()})
        | undefined,
    %% QUIC-LB CID configuration (RFC 9312)
    cid_config :: #cid_config{} | undefined,
    %% Expected DCID length for short header packets
    dcid_len = 8 :: pos_integer(),
    %% Options
    opts :: map()
}).
-type state() :: #listener_state{}.

%%====================================================================
%% API
%%====================================================================

%% @doc Start a QUIC listener on the given port.
%% Options:
%%   - cert: Server certificate (DER binary)
%%   - cert_chain: Certificate chain [binary()]
%%   - key: Private key
%%   - alpn: List of supported ALPN protocols
%%   - active_n: Number of packets before socket goes passive (default 100)
%%   - reuseport: Enable SO_REUSEPORT for multiple listeners (default false)
%%   - connections_table: Shared ETS table for connection tracking (pool mode)
%%   - preferred_ipv4: {IP, Port} for preferred IPv4 address (RFC 9000 Section 9.6)
%%   - preferred_ipv6: {IP, Port} for preferred IPv6 address (RFC 9000 Section 9.6)
-spec start_link(inet:port_number(), map()) -> {ok, pid()} | {error, term()}.
start_link(Port, Opts) ->
    gen_server:start_link(?MODULE, {Port, Opts}, []).

%% @doc Start a QUIC listener (without linking to caller).
-spec start(inet:port_number(), map()) -> {ok, pid()} | {error, term()}.
start(Port, Opts) ->
    gen_server:start(?MODULE, {Port, Opts}, []).

%% @doc Stop the listener.
-spec stop(pid()) -> ok.
stop(Listener) ->
    gen_server:stop(Listener).

%% @doc Get the port the listener is bound to.
-spec get_port(pid()) -> inet:port_number().
get_port(Listener) ->
    gen_server:call(Listener, get_port).

%% @doc Get the address the listener is bound to. Resolves the actual bound
%% address from the socket, so it reflects the real value even when the listener
%% was opened with `inet6', `{ip, Addr}' or `{ifaddr, Addr}'.
-spec get_sockname(pid()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
get_sockname(Listener) ->
    gen_server:call(Listener, get_sockname).

%% @doc Get list of active connections.
-spec get_connections(pid()) -> [pid()].
get_connections(Listener) ->
    gen_server:call(Listener, get_connections).

%% @doc Add a connection ID to the routing table. Called by a connection
%% when it issues a new CID (NEW_CONNECTION_ID) so packets the peer sends
%% to the rotated/migrated CID reach the connection (the routing ETS is
%% owned by the listener).
-spec register_cid(pid(), binary(), pid()) -> ok.
register_cid(Listener, CID, ConnPid) ->
    gen_server:cast(Listener, {register_cid, CID, ConnPid}).

%% @doc Remove a connection ID from the routing table (CID retired).
-spec retire_cid(pid(), binary()) -> ok.
retire_cid(Listener, CID) ->
    gen_server:cast(Listener, {retire_cid, CID}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @doc false
-spec init({inet:port_number(), map()}) -> term().
init({Port, Opts}) ->
    process_flag(trap_exit, true),

    %% Check which socket backend to use
    %% socket_backend => socket enables GRO on Linux (OTP 27+)
    %% Default: gen_udp for backwards compatibility
    Backend = maps:get(socket_backend, Opts, gen_udp),

    case Backend of
        socket ->
            init_socket_backend(Port, Opts);
        gen_udp ->
            init_genudp_backend(Port, Opts)
    end.

%% Initialize with OTP socket backend (GRO support on Linux)
init_socket_backend(Port, Opts) ->
    case quic_socket:open(Port, Opts) of
        {ok, SocketState} ->
            Socket = quic_socket:get_socket(SocketState),
            {ok, {Socket, SocketState, socket, Opts}, {continue, discover_manager}};
        {error, Reason} ->
            {stop, Reason}
    end.

%% Initialize with gen_udp backend (default, backwards compatible)
init_genudp_backend(Port, Opts) ->
    ActiveN = maps:get(active_n, Opts, 100),
    ReusePort = maps:get(reuseport, Opts, false),
    ExtraFlags = maps:get(extra_socket_opts, Opts, []),
    Family = extra_socket_family(ExtraFlags),

    %% UDP buffer sizing - larger buffers improve throughput significantly
    %% OS may cap to lower values (check sysctl net.core.rmem_max on Linux)
    RecBuf = maps:get(recbuf, Opts, ?DEFAULT_UDP_RECBUF),
    SndBuf = maps:get(sndbuf, Opts, ?DEFAULT_UDP_SNDBUF),

    SocketOpts =
        [
            binary,
            Family,
            {active, ActiveN},
            {reuseaddr, quic_socket:reuseaddr_for_port(Port)},
            {recbuf, RecBuf},
            {sndbuf, SndBuf}
        ] ++
            case ReusePort of
                true -> [{reuseport, true}, {reuseport_lb, true}];
                false -> []
            end ++ ExtraFlags,
    case gen_udp:open(Port, SocketOpts) of
        {ok, Socket} ->
            {ok, {Socket, undefined, gen_udp, Opts}, {continue, discover_manager}};
        {error, Reason} ->
            {stop, Reason}
    end.

%% Infer the UDP address family from caller socket options: inet6 when an
%% `inet6' atom or an 8-tuple `{ip, _}' is present, inet otherwise.
extra_socket_family(Extra) ->
    case lists:member(inet6, Extra) of
        true ->
            inet6;
        false ->
            case proplists:get_value(ip, Extra) of
                {_, _, _, _, _, _, _, _} -> inet6;
                _ -> inet
            end
    end.

%% @doc false
handle_continue(discover_manager, {Socket, SocketState, Backend, Opts}) ->
    %% Auth-method options: cert+key for X.509 auth, or PSK config
    %% (psks / psk_callback) for TLS 1.3 external PSK (RFC 8446 §4.2.11).
    %% At least one must be provided; both may coexist (per-handshake
    %% selection happens in quic_connection on ClientHello).
    Cert = maps:get(cert, Opts, undefined),
    PrivateKey = maps:get(key, Opts, undefined),
    Psks = maps:get(psks, Opts, undefined),
    PskCallback = maps:get(psk_callback, Opts, undefined),
    SniCallback = maps:get(sni_callback, Opts, undefined),
    case has_auth_method(Opts) of
        ok -> ok;
        {error, no_auth_method} -> exit({listener_init_failed, no_auth_method})
    end,
    CertChain = maps:get(cert_chain, Opts, []),
    ALPNList = maps:get(alpn, Opts, [<<"h3">>]),
    ConnHandler = maps:get(connection_handler, Opts, undefined),

    {ConnTab, TicketTab, OwnsTables} = get_tables(Opts),

    %% Get actual port and bound address
    ActualPort = get_socket_port(Socket, SocketState, Backend),

    %% Generate or use provided stateless reset secret
    ResetSecret = maps:get(reset_secret, Opts, crypto:strong_rand_bytes(32)),

    %% Initialize QUIC-LB CID configuration (RFC 9312)
    {CIDConfig, DCIDLen} = init_cid_config(Opts, ResetSecret),

    %% Start GRO receiver if using socket backend
    GROReceiver = maybe_start_gro_receiver(Backend, SocketState),
    {SendSender, SendGSOCounter} = maybe_start_shared_sender(Backend, SocketState),

    State = #listener_state{
        socket = Socket,
        socket_state = SocketState,
        socket_backend = Backend,
        gro_receiver = GROReceiver,
        send_sender = SendSender,
        send_gso_counter = SendGSOCounter,
        port = ActualPort,
        tls = #listener_tls{
            cert = Cert,
            cert_chain = CertChain,
            private_key = PrivateKey,
            psks = Psks,
            psk_callback = PskCallback,
            sni_callback = SniCallback,
            alpn_list = ALPNList
        },
        connections = ConnTab,
        cid_index = ets:new(quic_cid_index, [bag, private]),
        tickets_table = TicketTab,
        owns_tables = OwnsTables,
        reset_secret = ResetSecret,
        address_validation = maps:get(address_validation, Opts, never),
        token_max_age_ms = maps:get(address_token_max_age_ms, Opts, 600000),
        connection_handler = ConnHandler,
        cid_config = CIDConfig,
        dcid_len = DCIDLen,
        recv_queue_max = quic_socket:recv_queue_max(
            maps:get(max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA)
        ),
        opts = Opts
    },
    {noreply, State}.

%% @private
%% Validate that listener options carry at least one viable auth
%% method. Callers check this before starting a listener so the
%% failure surfaces as an error return rather than a supervisor crash.
-spec has_auth_method(map()) -> ok | {error, no_auth_method}.
has_auth_method(Opts) when is_map(Opts) ->
    has_auth_method(
        maps:get(cert, Opts, undefined),
        maps:get(key, Opts, undefined),
        maps:get(psks, Opts, undefined),
        maps:get(psk_callback, Opts, undefined),
        maps:get(sni_callback, Opts, undefined)
    ).

%% @private
%% Either a cert+key pair for X.509 auth or PSK config for TLS 1.3
%% external PSK (RFC 8446 §4.2.11) must be present. Both may coexist.
%% A `sni_callback' supplies the cert/key per handshake, so it counts as
%% an auth method even when no static cert/key is configured.
has_auth_method(Cert, Key, _Psks, _Cb, _Sni) when Cert =/= undefined, Key =/= undefined -> ok;
has_auth_method(_Cert, _Key, Psks, _Cb, _Sni) when is_map(Psks), map_size(Psks) > 0 -> ok;
has_auth_method(_Cert, _Key, _Psks, Cb, _Sni) when is_function(Cb, 1) -> ok;
has_auth_method(_Cert, _Key, _Psks, _Cb, Sni) when is_function(Sni, 1) -> ok;
has_auth_method(_, _, _, _, _) -> {error, no_auth_method}.

%% Get socket port depending on backend
get_socket_port(_Socket, SocketState, socket) when SocketState =/= undefined ->
    case quic_socket:sockname(SocketState) of
        {ok, {_IP, Port}} -> Port;
        {error, _} -> 0
    end;
get_socket_port(Socket, _SocketState, gen_udp) ->
    case inet:sockname(Socket) of
        {ok, {_IP, Port}} -> Port;
        {error, _} -> 0
    end.

%% Get the bound {IP, Port} depending on backend.
get_socket_sockname(_Socket, SocketState, socket) when SocketState =/= undefined ->
    quic_socket:sockname(SocketState);
get_socket_sockname(Socket, _SocketState, gen_udp) ->
    inet:sockname(Socket).

%% Start GRO receiver process for socket backend
maybe_start_gro_receiver(socket, SocketState) when SocketState =/= undefined ->
    Listener = self(),
    spawn_link(fun() -> gro_receive_loop(SocketState, Listener) end);
maybe_start_gro_receiver(_, _) ->
    undefined.

maybe_start_shared_sender(socket, SocketState) when SocketState =/= undefined ->
    quic_socket:start_shared_sender(SocketState);
maybe_start_shared_sender(_, _) ->
    {undefined, undefined}.

%% GRO receiver loop - runs in separate process
%% Does blocking recvmsg calls and forwards packets to listener
gro_receive_loop(SocketState, Listener) ->
    case quic_socket:recv(SocketState, infinity) of
        {ok, {IP, Port}, Packets} ->
            %% Send packets to listener (may be multiple with GRO)
            Listener ! {gro_packets, IP, Port, Packets},
            gro_receive_loop(SocketState, Listener);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            %% Retry on transient errors
            gro_receive_loop(SocketState, Listener)
    end.

%% @doc false
-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(get_port, _From, #listener_state{port = Port} = State) ->
    {reply, Port, State};
%% @doc false
handle_call(
    get_sockname,
    _From,
    #listener_state{
        socket = Socket, socket_state = SocketState, socket_backend = Backend
    } = State
) ->
    {reply, get_socket_sockname(Socket, SocketState, Backend), State};
%% @doc false
handle_call(get_socket_info, _From, #listener_state{socket = Socket, port = Port} = State) ->
    SockInfo = inet:info(Socket),
    {reply, #{port => Port, socket => Socket, info => SockInfo}, State};
handle_call(get_connections, _From, #listener_state{connections = Conns} = State) ->
    Pids = ets:foldl(fun({_CID, Pid}, Acc) -> [Pid | Acc] end, [], Conns),
    {reply, lists:usort(Pids), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% @doc false
-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({register_cid, CID, ConnPid}, State) ->
    add_cid(CID, ConnPid, State),
    {noreply, State};
handle_cast({retire_cid, CID}, #listener_state{connections = Conns, cid_index = Index} = State) ->
    case ets:take(Conns, CID) of
        [{CID, ConnPid}] -> ets:delete_object(Index, {ConnPid, CID});
        [] -> ok
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc false
%% Handle incoming UDP packets (gen_udp backend)
handle_info(
    {udp, Socket, SrcIP, SrcPort, Packet},
    #listener_state{socket = Socket, socket_backend = gen_udp} = State
) ->
    ?LOG_DEBUG(
        #{what => udp_received, src_ip => SrcIP, src_port => SrcPort, size => byte_size(Packet)},
        ?QUIC_LOG_META
    ),
    Items = drain_recv_sweep(
        Socket, gen_udp, ?RECV_SWEEP_MAX - 1, [{{SrcIP, SrcPort}, [Packet]}]
    ),
    dispatch_recv_sweep(Items, State),
    {noreply, State};
%% Handle GRO packets (socket backend with GRO)
%% May receive multiple packets in single recv call
handle_info(
    {gro_packets, SrcIP, SrcPort, Packets},
    #listener_state{socket_backend = socket} = State
) ->
    ?LOG_DEBUG(
        #{
            what => gro_packets_received,
            src_ip => SrcIP,
            src_port => SrcPort,
            count => length(Packets)
        },
        ?QUIC_LOG_META
    ),
    Items = drain_recv_sweep(
        undefined, socket, ?RECV_SWEEP_MAX - length(Packets), [{{SrcIP, SrcPort}, Packets}]
    ),
    dispatch_recv_sweep(Items, State),
    {noreply, State};
%% Handle socket going passive (backpressure with {active, N}) - gen_udp only
handle_info(
    {udp_passive, Socket},
    #listener_state{socket = Socket, opts = Opts, socket_backend = gen_udp} = State
) ->
    N = maps:get(active_n, Opts, 100),
    inet:setopts(Socket, [{active, N}]),
    {noreply, State};
%% Handle connection process exit
handle_info(
    {'EXIT', Pid, _Reason},
    #listener_state{gro_receiver = GROReceiver, send_sender = SendSender} = State
) ->
    case Pid of
        GROReceiver ->
            %% GRO receiver died - restart it
            NewReceiver = maybe_start_gro_receiver(
                State#listener_state.socket_backend,
                State#listener_state.socket_state
            ),
            {noreply, State#listener_state{gro_receiver = NewReceiver}};
        SendSender when is_pid(SendSender) ->
            %% Shared sender died: new connections get a fresh one,
            %% existing connections fall back to sending directly.
            {NewSender, NewCounter} = maybe_start_shared_sender(
                State#listener_state.socket_backend,
                State#listener_state.socket_state
            ),
            {noreply, State#listener_state{
                send_sender = NewSender, send_gso_counter = NewCounter
            }};
        _ ->
            cleanup_connection(Pid, State),
            {noreply, State}
    end;
%% Handle UDP from different socket (shouldn't happen)
handle_info({udp, _OtherSocket, _SrcIP, _SrcPort, _Packet}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% Drain the datagram messages already queued in the listener mailbox
%% into one receive sweep, so packets for the same connection arriving
%% as separate messages (distinct flows never GRO-coalesce) are
%% dispatched as one batch: the connection wakes once per sweep instead
%% of once per datagram, and its batched receive path engages even for
%% sparse per-connection traffic. Bounded to keep the listener
%% responsive under floods. Returns [{Addr, Packets}] in arrival order.
drain_recv_sweep(_Socket, _Backend, Budget, Acc) when Budget =< 0 ->
    lists:reverse(Acc);
drain_recv_sweep(Socket, Backend, Budget, Acc) ->
    receive
        {udp, Socket, IP, Port, Packet} when Backend =:= gen_udp ->
            drain_recv_sweep(Socket, Backend, Budget - 1, [{{IP, Port}, [Packet]} | Acc]);
        {gro_packets, IP, Port, Packets} when Backend =:= socket ->
            drain_recv_sweep(
                Socket, Backend, Budget - length(Packets), [{{IP, Port}, Packets} | Acc]
            )
    after 0 ->
        lists:reverse(Acc)
    end.

%% Merge the sweep per source address (per-flow packet order preserved,
%% cross-flow order irrelevant) and route each group through the
%% existing batched dispatch, which groups by connection and creates
%% new connections.
dispatch_recv_sweep([{Addr, Packets}], State) ->
    handle_gro_packets(Packets, Addr, State);
dispatch_recv_sweep(Items, State) ->
    maps:foreach(
        fun(Addr, Packets) -> handle_gro_packets(Packets, Addr, State) end,
        group_recv_sweep(Items)
    ).

group_recv_sweep(Items) ->
    Grouped = lists:foldl(
        fun({Addr, Packets}, M) ->
            maps:update_with(Addr, fun(L) -> [Packets | L] end, [Packets], M)
        end,
        #{},
        Items
    ),
    maps:map(fun(_, Trains) -> lists:append(lists:reverse(Trains)) end, Grouped).

%% Handle multiple packets received via GRO
%% Groups packets by connection and sends batched messages
handle_gro_packets([], _RemoteAddr, _State) ->
    ok;
handle_gro_packets([Packet], RemoteAddr, State) ->
    %% Single packet - no need to batch
    handle_packet(Packet, RemoteAddr, State);
handle_gro_packets(Packets, RemoteAddr, State) ->
    %% Multiple packets - group by connection ID and batch
    dispatch_batched_packets(Packets, RemoteAddr, State).

%% Group packets by connection ID and dispatch in batches
dispatch_batched_packets(
    Packets,
    RemoteAddr,
    #listener_state{dcid_len = DCIDLen, connections = Conns, recv_queue_max = QueueMax} = State
) ->
    %% Build map of ConnPid -> [Packets] (preserving order)
    Groups = group_packets_by_conn(Packets, DCIDLen, Conns, #{}),
    %% Dispatch each batch
    maps:foreach(
        fun
            ({conn, ConnPid}, PacketList) ->
                %% Reverse to restore original order (we prepended)
                send_packets_to_connection(
                    ConnPid, lists:reverse(PacketList), RemoteAddr, QueueMax
                );
            ({new, DCID, Version}, PacketList) ->
                %% Initial packets that need new connections. A client
                %% flight larger than one datagram (a hybrid
                %% x25519mlkem768 ClientHello is chunked across
                %% Initials) arrives as several packets for the same
                %% unknown DCID: the first starts the connection, the
                %% rest have to reach it too or the handshake stalls
                %% until the client retransmits them.
                [FirstPacket | Rest] = lists:reverse(PacketList),
                case create_connection(FirstPacket, DCID, Version, RemoteAddr, State) of
                    {ok, ConnPid} when Rest =/= [] ->
                        send_packets_to_connection(ConnPid, Rest, RemoteAddr, QueueMax);
                    _ ->
                        %% Retry sent, limit reached or start failed:
                        %% the client resends the whole flight.
                        ok
                end
        end,
        Groups
    ).

%% Group packets by their destination connection
group_packets_by_conn([], _DCIDLen, _Conns, Acc) ->
    Acc;
group_packets_by_conn([Packet | Rest], DCIDLen, Conns, Acc) ->
    case parse_packet_header(Packet, DCIDLen) of
        {initial, DCID, _SCID, Version, _Rest} ->
            case ets:lookup(Conns, DCID) of
                [{DCID, ConnPid}] ->
                    %% Existing connection
                    Key = {conn, ConnPid},
                    Acc1 = maps:update_with(Key, fun(L) -> [Packet | L] end, [Packet], Acc),
                    group_packets_by_conn(Rest, DCIDLen, Conns, Acc1);
                [] ->
                    %% New connection - group by DCID
                    Key = {new, DCID, Version},
                    Acc1 = maps:update_with(Key, fun(L) -> [Packet | L] end, [Packet], Acc),
                    group_packets_by_conn(Rest, DCIDLen, Conns, Acc1)
            end;
        {short, DCID, _Rest} ->
            case ets:lookup(Conns, DCID) of
                [{DCID, ConnPid}] ->
                    Key = {conn, ConnPid},
                    Acc1 = maps:update_with(Key, fun(L) -> [Packet | L] end, [Packet], Acc),
                    group_packets_by_conn(Rest, DCIDLen, Conns, Acc1);
                [] ->
                    %% Unknown - skip (will be handled as stateless reset if needed)
                    group_packets_by_conn(Rest, DCIDLen, Conns, Acc)
            end;
        {long, DCID, _SCID, _PacketType, _Rest} ->
            case ets:lookup(Conns, DCID) of
                [{DCID, ConnPid}] ->
                    Key = {conn, ConnPid},
                    Acc1 = maps:update_with(Key, fun(L) -> [Packet | L] end, [Packet], Acc),
                    group_packets_by_conn(Rest, DCIDLen, Conns, Acc1);
                [] ->
                    %% Unknown long header - skip
                    group_packets_by_conn(Rest, DCIDLen, Conns, Acc)
            end;
        {error, _Reason} ->
            %% Skip invalid packets
            group_packets_by_conn(Rest, DCIDLen, Conns, Acc)
    end.

%% Send batched packets to a connection. Tail-drops when the
%% connection's mailbox is over QueueMax, see
%% quic_socket:recv_queue_max/1.
send_packets_to_connection(ConnPid, Packets, RemoteAddr, QueueMax) ->
    case erlang:process_info(ConnPid, message_queue_len) of
        {message_queue_len, QLen} when QLen > QueueMax ->
            %% Over the bound: keep one packet of the train so the peer
            %% still gets a timely (dup-)ACK carrying the loss signal,
            %% drop the rest - per-packet-ish drops beat losing whole
            %% GRO trains, which fragments ACK ranges and provokes
            %% retransmit storms.
            count_recv_drop(length(Packets) - 1),
            ConnPid ! {quic_packet, hd(Packets), RemoteAddr},
            ok;
        _ ->
            forward_packet_chunks(ConnPid, Packets, RemoteAddr)
    end.

%% Forward a train in =< ?MAX_PACKETS_PER_CONN_MSG chunks so the
%% mailbox bound above translates to a bounded packet backlog.
forward_packet_chunks(ConnPid, [Packet], RemoteAddr) ->
    ConnPid ! {quic_packet, Packet, RemoteAddr},
    ok;
forward_packet_chunks(ConnPid, Packets, RemoteAddr) ->
    case length(Packets) =< ?MAX_PACKETS_PER_CONN_MSG of
        true ->
            ConnPid ! {quic_packets, Packets, RemoteAddr},
            ok;
        false ->
            {Chunk, Rest} = lists:split(?MAX_PACKETS_PER_CONN_MSG, Packets),
            ConnPid ! {quic_packets, Chunk, RemoteAddr},
            forward_packet_chunks(ConnPid, Rest, RemoteAddr)
    end.

%% Bench diagnostic: global tail-drop counter, readable via
%% quic_listener:recv_drops/0.
count_recv_drop(N) ->
    Ref =
        case persistent_term:get({?MODULE, recv_drops}, undefined) of
            undefined ->
                R = atomics:new(1, []),
                persistent_term:put({?MODULE, recv_drops}, R),
                R;
            R ->
                R
        end,
    atomics:add(Ref, 1, N).

-spec recv_drops() -> non_neg_integer().
recv_drops() ->
    case persistent_term:get({?MODULE, recv_drops}, undefined) of
        undefined -> 0;
        Ref -> atomics:get(Ref, 1)
    end.

%% @doc false
terminate(_Reason, #listener_state{
    connections = ConnTab,
    tickets_table = TicketTab,
    owns_tables = OwnsTables,
    socket_state = SocketState,
    socket_backend = Backend,
    socket = Socket
}) ->
    close_connections(ConnTab),
    %% Close socket based on backend
    case Backend of
        socket when SocketState =/= undefined ->
            quic_socket:close(SocketState);
        _ ->
            safe_close_socket(Socket)
    end,
    %% Only delete ETS tables if we own them (standalone mode, not pool mode)
    case OwnsTables of
        true ->
            safe_delete_table(ConnTab),
            safe_delete_table(TicketTab);
        false ->
            ok
    end,
    ok;
terminate(_Reason, _) ->
    %% Handle case where state is not fully initialized (e.g., init failed early)
    ok.

%% @doc false
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Stop the connections this listener started, and wait for them, while
%% the socket is still open: each sends CONNECTION_CLOSE as it terminates.
%% With the socket closed first, their clients heard nothing until their
%% own idle timeout.
close_connections(ConnTab) ->
    {links, Links} = process_info(self(), links),
    Linked = sets:from_list(Links, [{version, 2}]),
    Conns = lists:usort([P || {_CID, P} <- safe_tab_list(ConnTab), sets:is_element(P, Linked)]),
    Refs = [stop_connection(P) || P <- Conns],
    await_down(Refs, erlang:monotonic_time(millisecond) + ?CLOSE_CONNECTIONS_MS).

stop_connection(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    Ref.

await_down([], _Deadline) ->
    ok;
await_down([Ref | Rest], Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, _, _} -> await_down(Rest, Deadline)
    after Left -> ok
    end.

safe_tab_list(Tab) ->
    try
        ets:tab2list(Tab)
    catch
        error:badarg -> []
    end.

safe_close_socket(Socket) ->
    try
        gen_udp:close(Socket)
    catch
        _:_ -> ok
    end.

safe_delete_table(Tab) ->
    try
        ets:delete(Tab)
    catch
        _:_ -> ok
    end.

%% Initialize QUIC-LB CID configuration from options
%% Returns {CIDConfig | undefined, DCIDLen}
init_cid_config(Opts, ResetSecret) ->
    case maps:get(lb_config, Opts, undefined) of
        undefined ->
            %% No LB config - use default random CIDs
            DCIDLen = maps:get(cid_len, Opts, 8),
            {undefined, DCIDLen};
        LBConfig when is_map(LBConfig) ->
            %% LB config provided as map - create config
            case quic_lb:new_config(LBConfig) of
                {ok, LBCfg} ->
                    CIDLen = quic_lb:expected_cid_len(LBCfg),
                    case
                        quic_lb:new_cid_config(#{
                            lb_config => LBCfg,
                            cid_len => CIDLen,
                            reset_secret => ResetSecret
                        })
                    of
                        {ok, CIDConfig} ->
                            {CIDConfig, CIDLen};
                        {error, Reason} ->
                            ?LOG_WARNING(
                                #{what => invalid_cid_config, reason => Reason},
                                ?QUIC_LOG_META
                            ),
                            {undefined, 8}
                    end;
                {error, Reason} ->
                    ?LOG_WARNING(
                        #{what => invalid_lb_config, reason => Reason},
                        ?QUIC_LOG_META
                    ),
                    {undefined, 8}
            end;
        #lb_config{} = LBCfg ->
            %% LB config provided as record
            CIDLen = quic_lb:expected_cid_len(LBCfg),
            case
                quic_lb:new_cid_config(#{
                    lb_config => LBCfg,
                    cid_len => CIDLen,
                    reset_secret => ResetSecret
                })
            of
                {ok, CIDConfig} ->
                    {CIDConfig, CIDLen};
                {error, Reason} ->
                    ?LOG_WARNING(
                        #{what => invalid_cid_config, reason => Reason},
                        ?QUIC_LOG_META
                    ),
                    {undefined, 8}
            end
    end.

add_cid(CID, ConnPid, #listener_state{connections = Conns, cid_index = Index}) ->
    ets:insert(Conns, {CID, ConnPid}),
    ets:insert(Index, {ConnPid, CID}).

%% Remove all CIDs associated with this connection
cleanup_connection(Pid, #listener_state{connections = Conns, cid_index = Index}) ->
    lists:foreach(fun({_, CID}) -> ets:delete_object(Conns, {CID, Pid}) end, ets:take(Index, Pid)).

%% Use provided ETS table or create new one for connection tracking
%% When using pool mode, the supervisor is in the options, query it for the
%% table manager and get the table from it.
%% Returns {ConnTab, TicketTab, OwnsTable} where OwnsTable indicates if
%% this listener should delete the tables on terminate.
get_tables(#{supervisor := SupPid}) ->
    Children = supervisor:which_children(SupPid),
    {quic_listener_manager, ManagerPid, _, _} = lists:keyfind(quic_listener_manager, 1, Children),
    {ok, {ConnTab, TicketTab}} = quic_listener_manager:get_tables(ManagerPid),
    % Pool mode - don't own tables
    {ConnTab, TicketTab, false};
get_tables(_) ->
    ConnTab = ets:new(quic_connections, [set, protected]),
    %% Public: the connections store the tickets they issue here.
    TicketTab = ets:new(quic_tickets, [set, public]),
    % Standalone mode - own tables
    {ConnTab, TicketTab, true}.

handle_packet(Packet, RemoteAddr, #listener_state{dcid_len = DCIDLen} = State) ->
    case parse_packet_header(Packet, DCIDLen) of
        {initial, DCID, SCID, Version, _Rest} ->
            %% Per-packet routing trace. Logged at debug: every received packet
            %% hits this path (a short-header packet per 1-RTT datagram), so at
            %% info level a busy listener floods the log and burns CPU.
            ?LOG_DEBUG(
                #{
                    what => initial_packet,
                    remote_addr => RemoteAddr,
                    dcid => DCID,
                    version => Version
                },
                ?QUIC_LOG_META
            ),
            case supported_version(Version) of
                true ->
                    handle_initial_packet(Packet, DCID, Version, RemoteAddr, State);
                false ->
                    send_version_negotiation(DCID, SCID, Version, RemoteAddr, State)
            end;
        {short, DCID, _Rest} ->
            ?LOG_DEBUG(#{what => short_header_packet, dcid => DCID}, ?QUIC_LOG_META),
            route_to_connection(DCID, Packet, RemoteAddr, State);
        {long, DCID, _SCID, PacketType, _Rest} ->
            ?LOG_DEBUG(
                #{what => long_header_packet, packet_type => PacketType, dcid => DCID},
                ?QUIC_LOG_META
            ),
            route_to_connection(DCID, Packet, RemoteAddr, State);
        {error, Reason} ->
            ?LOG_WARNING(#{what => packet_parse_failed, reason => Reason}, ?QUIC_LOG_META),
            ok
    end.

%% RFC 9000 Section 6.1: a server that receives a long-header packet with a
%% version it does not support MUST respond with a Version Negotiation packet
%% listing the versions it does support. Without this a peer probing with a
%% reserved version, which is how readiness checks and the QUIC Interop
%% Runner detect a live server, gets silence.
supported_version(?QUIC_VERSION_1) -> true;
supported_version(?QUIC_VERSION_2) -> true;
supported_version(_) -> false.

send_version_negotiation(_DCID, _SCID, 0, _RemoteAddr, _State) ->
    %% Version 0 is itself a Version Negotiation packet; never reply to one
    %% (RFC 9000 Section 6.1), or two servers can trade them forever.
    ok;
send_version_negotiation(DCID, SCID, _Version, {IP, Port}, State) ->
    #listener_state{
        socket = Socket,
        socket_state = SocketState,
        socket_backend = Backend
    } = State,
    %% The connection IDs are swapped: our DCID is what the client used as
    %% its source, so the client can match the reply to its attempt.
    Packet = quic_packet:encode_version_negotiation(
        SCID, DCID, [?QUIC_VERSION_1, ?QUIC_VERSION_2]
    ),
    send_packet(Socket, SocketState, Backend, IP, Port, Packet),
    ok.

%% Parse packet header to extract DCID for routing
%% DCIDLen parameter specifies expected DCID length for short header packets
parse_packet_header(
    <<FirstByte, Version:32, DCIDLenField, DCID:DCIDLenField/binary, SCIDLen, SCID:SCIDLen/binary,
        Rest/binary>>,
    _DCIDLen
) when
    FirstByte band 16#80 =:= 16#80
->
    %% Long header - extract packet type from bits 4-5 of first byte.
    %% The bit patterns are version-specific (RFC 9369 §3.2), so map
    %% through the version before classifying.
    PacketType = (FirstByte bsr 4) band 2#11,
    case quic_packet:bits_to_type(PacketType, Version) of
        initial -> {initial, DCID, SCID, Version, Rest};
        _ -> {long, DCID, SCID, PacketType, Rest}
    end;
parse_packet_header(<<0:1, _:7, Rest/binary>>, DCIDLen) ->
    %% Short header - use configured DCID length
    case Rest of
        <<DCID:DCIDLen/binary, Remaining/binary>> ->
            {short, DCID, Remaining};
        _ ->
            {error, short_header_too_small}
    end;
parse_packet_header(_, _DCIDLen) ->
    {error, invalid_header}.

%% Handle Initial packet - may create new connection
handle_initial_packet(
    Packet,
    DCID,
    Version,
    RemoteAddr,
    #listener_state{connections = Conns} = State
) ->
    case ets:lookup(Conns, DCID) of
        [{DCID, ConnPid}] ->
            %% Existing connection
            send_to_connection(ConnPid, Packet, RemoteAddr);
        [] ->
            %% New connection
            create_connection(Packet, DCID, Version, RemoteAddr, State)
    end.

%% Route packet to existing connection
route_to_connection(
    DCID,
    Packet,
    RemoteAddr,
    #listener_state{connections = Conns} = State
) ->
    case ets:lookup(Conns, DCID) of
        [{DCID, ConnPid}] ->
            send_to_connection(ConnPid, Packet, RemoteAddr);
        [] ->
            %% Unknown connection - potentially send stateless reset
            handle_unknown_packet(DCID, Packet, RemoteAddr, State)
    end.

%% Create a new server-side connection
create_connection(
    Packet,
    DCID,
    Version,
    RemoteAddr,
    #listener_state{
        socket = Socket,
        socket_state = SocketState,
        socket_backend = Backend,
        cid_config = CIDConfig,
        reset_secret = ResetSecret,
        address_validation = Policy,
        token_max_age_ms = MaxAge
    } = State
) ->
    {IP, Port} = RemoteAddr,
    case decide_address_validation(Packet, Version, RemoteAddr, ResetSecret, Policy, MaxAge) of
        {send_retry, ClientSCID, RetryToken} ->
            %% Fresh server-chosen CID the client must use as DCID on
            %% its next Initial.
            RetrySCID =
                case CIDConfig of
                    undefined -> crypto:strong_rand_bytes(8);
                    #cid_config{} -> quic_lb:generate_cid(CIDConfig)
                end,
            RetryPacket = quic_packet:encode_retry(
                DCID, ClientSCID, RetrySCID, RetryToken, Version
            ),
            send_packet(Socket, SocketState, Backend, IP, Port, RetryPacket),
            ok;
        spawn_unvalidated ->
            %% No Retry: the client's DCID is the original; no retry SCID.
            spawn_with_limit(false, DCID, undefined, Packet, DCID, Version, RemoteAddr, State);
        {spawn_validated, OrigDCID, RetrySCID} ->
            spawn_with_limit(true, OrigDCID, RetrySCID, Packet, DCID, Version, RemoteAddr, State)
    end.

spawn_with_limit(Validated, OrigDCID, RetrySCID, Packet, DCID, Version, RemoteAddr, State) ->
    case connection_limit_reached(State) of
        true ->
            %% Silently drop (no reply) to avoid amplification; the client
            %% retries or times out.
            ?LOG_WARNING(#{what => connection_limit_reached}, ?QUIC_LOG_META),
            ok;
        false ->
            create_connection_unconditional(
                Validated, OrigDCID, RetrySCID, Packet, DCID, Version, RemoteAddr, State
            )
    end.

%% Optional cap on concurrent connections (`max_connections' option,
%% default `infinity'). The routing table holds the DCID + server CID
%% pair per connection, so size div 2 approximates the connection count.
connection_limit_reached(#listener_state{connections = Conns, opts = Opts}) ->
    case maps:get(max_connections, Opts, infinity) of
        infinity ->
            false;
        Max when is_integer(Max) ->
            (ets:info(Conns, size) div 2) >= Max
    end.

create_connection_unconditional(
    Validated,
    OrigDCID,
    RetrySCID,
    Packet,
    DCID,
    Version,
    RemoteAddr,
    #listener_state{
        socket = Socket,
        socket_state = SocketState,
        socket_backend = Backend,
        tls = #listener_tls{
            cert = Cert,
            cert_chain = CertChain,
            private_key = PrivateKey,
            psks = Psks,
            psk_callback = PskCallback,
            sni_callback = SniCallback,
            alpn_list = ALPNList
        },
        tickets_table = TicketTab,
        connection_handler = ConnHandler,
        cid_config = CIDConfig,
        reset_secret = ResetSecret,
        send_sender = SendSender,
        send_gso_counter = SendGSOCounter,
        opts = Opts
    } = State
) ->
    %% Generate server connection ID (LB-aware if configured)
    ServerCID =
        case CIDConfig of
            undefined -> crypto:strong_rand_bytes(8);
            #cid_config{} -> quic_lb:generate_cid(CIDConfig)
        end,

    %% Start connection process with client's QUIC version.
    %% `reset_secret' is propagated so this connection's
    %% NEW_CONNECTION_ID tokens match the ones the listener will emit
    %% for orphan packets after the connection goes away (RFC 9000
    %% §10.3.2).
    %% Capabilities of the listener's underlying UDP socket. The server
    %% connection uses these to build a per-connection sender socket_state
    %% that reuses the shared socket but owns its own batch buffer (so
    %% each connection's outgoing packets can be coalesced via GSO on
    %% Linux + socket backend, or just in-memory batched otherwise).
    ListenerGSO =
        case SocketState of
            undefined -> false;
            _ -> quic_socket:gso_supported(SocketState)
        end,
    ConnOpts = #{
        role => server,
        socket => Socket,
        listener_socket_backend => Backend,
        listener_gso_supported => ListenerGSO,
        send_sender => SendSender,
        send_gso_counter => SendGSOCounter,
        remote_addr => RemoteAddr,
        initial_dcid => DCID,
        %% original_destination_connection_id transport param: the client's
        %% DCID before any Retry. Equals DCID when no Retry occurred.
        original_dcid => OrigDCID,
        scid => ServerCID,
        cert => Cert,
        cert_chain => CertChain,
        private_key => PrivateKey,
        psks => Psks,
        psk_callback => PskCallback,
        sni_callback => SniCallback,
        alpn => ALPNList,
        listener => self(),
        ticket_table => TicketTab,
        cid_config => CIDConfig,
        reset_secret => ResetSecret,
        %% The listener already validated the client's token (if any);
        %% skip the per-connection re-validation.
        address_validated => Validated,
        %% retry_source_connection_id (RFC 9000 §7.3): the SCID we put in
        %% the Retry, which is the DCID on this Initial. `undefined' when
        %% no Retry occurred (fresh connection or NEW_TOKEN).
        retry_scid => RetrySCID,
        version => Version
    },

    ?LOG_INFO(#{what => creating_connection, dcid => DCID}, ?QUIC_LOG_META),
    case quic_connection:start_server(maps:merge(Opts, ConnOpts)) of
        {ok, ConnPid} ->
            ?LOG_INFO(#{what => connection_created, conn_pid => ConnPid}, ?QUIC_LOG_META),

            %% Register connection ID
            add_cid(DCID, ConnPid, State),
            add_cid(ServerCID, ConnPid, State),

            %% Invoke connection handler callback BEFORE sending packet
            %% This ensures ownership is transferred before handshake can complete
            case ConnHandler of
                undefined ->
                    ok;
                Fun when is_function(Fun, 2) ->
                    %% Handler takes (ConnPid, DCID)
                    case Fun(ConnPid, DCID) of
                        {ok, HandlerPid} when is_pid(HandlerPid) ->
                            ok = quic:set_owner_sync(ConnPid, HandlerPid);
                        {error, HandlerError} ->
                            ?LOG_WARNING(
                                #{
                                    what => connection_handler_failed,
                                    error => HandlerError
                                },
                                ?QUIC_LOG_META
                            )
                    end;
                Fun when is_function(Fun, 1) ->
                    case Fun(ConnPid) of
                        {ok, HandlerPid} when is_pid(HandlerPid) ->
                            %% Transfer ownership to handler (sync to ensure it completes
                            %% before any packets trigger handshake completion)
                            ok = quic:set_owner_sync(ConnPid, HandlerPid);
                        {error, HandlerError} ->
                            ?LOG_WARNING(
                                #{
                                    what => connection_handler_failed,
                                    error => HandlerError
                                },
                                ?QUIC_LOG_META
                            )
                    end
            end,

            %% Send initial packet to new connection (after ownership transfer)
            send_to_connection(ConnPid, Packet, RemoteAddr),

            {ok, ConnPid};
        {error, Reason} ->
            ?LOG_WARNING(#{what => start_connection_failed, reason => Reason}, ?QUIC_LOG_META),
            {error, Reason}
    end.

send_to_connection(ConnPid, Packet, RemoteAddr) ->
    ConnPid ! {quic_packet, Packet, RemoteAddr}.

%%====================================================================
%% Stateless Reset (RFC 9000 Section 10.3)
%%====================================================================

%% Handle packet to unknown connection - potentially send stateless reset
handle_unknown_packet(
    DCID,
    Packet,
    {IP, Port},
    #listener_state{
        socket = Socket,
        socket_state = SocketState,
        socket_backend = Backend,
        reset_secret = Secret
    }
) ->
    %% RFC 9000 §10.3: reply to a 1-RTT (short-header) packet we cannot route to
    %% any connection with a stateless reset, so a peer whose connection state we
    %% have lost (e.g. after a restart) tears the connection down and reconnects
    %% instead of retransmitting into a black hole until its idle timer fires.
    %%
    %% Constraints (RFC 9000 §10.3.3):
    %%   * Only short-header packets — long-header (handshake) packets are part of
    %%     connection setup and are handled elsewhere.
    %%   * Only packets larger than 21 bytes, so the reset can be made strictly
    %%     smaller than the trigger (build_stateless_reset/2). This both avoids
    %%     amplification and bounds any reset loop: each reply shrinks until it is
    %%     too small to trigger another, so the exchange terminates.
    %%   * Only when a reset secret is configured, so the token is verifiable by a
    %%     peer that received it during the original handshake.
    TriggerSize = byte_size(Packet),
    case is_short_header_packet(Packet) andalso TriggerSize > 21 andalso is_binary(Secret) of
        true ->
            Token = compute_stateless_reset_token(Secret, DCID),
            ResetPacket = build_stateless_reset(Token, TriggerSize),
            send_packet(Socket, SocketState, Backend, IP, Port, ResetPacket);
        false ->
            ok
    end.

%% Decide whether a freshly arrived Initial gets a Retry, spawns a
%% validated connection, or spawns an unvalidated one per the
%% listener's `address_validation' policy.
%%
%% The caller passes the *whole* Initial packet; this helper peels the
%% Long Header off and inspects the Token field.
%%
%% Returns:
%%   spawn_unvalidated — policy is `never' or token was missing on a
%%     `never' server; pass through.
%%   spawn_validated   — token present + signature + addr + freshness
%%     all validated; connection is exempt from re-validation.
%%   {send_retry, ClientSCID, Token} — emit a Retry addressed back to
%%     ClientSCID (which we took from the Initial's SCID) carrying
%%     Token for the client to echo back.
decide_address_validation(_Packet, _Version, _Addr, _Secret, never, _MaxAge) ->
    spawn_unvalidated;
decide_address_validation(Packet, _Version, Addr, Secret, always, MaxAge) ->
    case parse_initial_token(Packet) of
        {ok, <<>>, ClientSCID, ODCID} ->
            %% No token → mint one and require the client to echo it.
            Token = quic_address_token:encode_retry(
                Secret, Addr, ODCID, erlang:system_time(millisecond)
            ),
            {send_retry, ClientSCID, Token};
        {ok, Token, ClientSCID, RetriedDCID} ->
            case validate_initial_token(Secret, Token, Addr, MaxAge) of
                {ok, #{kind := retry, odcid := OrigDCID}} ->
                    %% A Retry happened: the original DCID comes from the
                    %% token (RFC 9000 §7.3), and the Initial's DCID is the
                    %% RetrySCID we issued.
                    {spawn_validated, OrigDCID, RetriedDCID};
                {ok, #{kind := new_token}} ->
                    %% NEW_TOKEN from a prior session, no Retry: the
                    %% Initial's DCID is the original; no retry SCID.
                    {spawn_validated, RetriedDCID, undefined};
                {error, _} ->
                    Fresh = quic_address_token:encode_retry(
                        Secret, Addr, RetriedDCID, erlang:system_time(millisecond)
                    ),
                    {send_retry, ClientSCID, Fresh}
            end;
        {error, _} ->
            %% Malformed Initial — fall back to unvalidated spawn so
            %% the connection's own decoder reports the real error.
            spawn_unvalidated
    end.

%% Extract the Token field from a Long Header Initial packet. Also
%% returns the client's SCID and the DCID (which the client chose as
%% the original destination CID before any retry).
parse_initial_token(
    <<FirstByte, Version:32, DCIDLen:8, DCID:DCIDLen/binary, SCIDLen:8, SCID:SCIDLen/binary,
        Rest/binary>>
) when
    FirstByte band 16#C0 =:= 16#C0
->
    try
        %% Accept only Initial packets; the type bits differ per version.
        initial = quic_packet:bits_to_type((FirstByte bsr 4) band 2#11, Version),
        {TokenLen, Rest1} = quic_varint:decode(Rest),
        <<Token:TokenLen/binary, _/binary>> = Rest1,
        {ok, Token, SCID, DCID}
    catch
        _:_ -> {error, malformed_initial}
    end;
parse_initial_token(_) ->
    {error, not_initial}.

validate_initial_token(Secret, Token, Addr, MaxAge) ->
    case quic_address_token:decode(Secret, Token) of
        {ok, #{addr := TokAddr} = Decoded} when TokAddr =:= Addr ->
            case quic_address_token:validate(Decoded, #{max_age_ms => MaxAge}) of
                ok -> {ok, Decoded};
                {error, _} = Err -> Err
            end;
        {ok, _} ->
            {error, address_mismatch};
        {error, _} = Err ->
            Err
    end.

%% Send a packet using the appropriate backend.
%% Listener self-sends are one-shot control-plane packets (version
%% negotiation, retry, stateless reset) that never benefit from
%% batching. Uses send_immediate/4 on the socket backend to bypass the
%% batch buffer entirely. Both branches return ok | {error, Reason} and
%% log the error at WARNING level so operators see it even when the
%% Retry / Stateless Reset call sites discard the return value.
send_packet(_Socket, SocketState, socket, IP, Port, Packet) when SocketState =/= undefined ->
    case quic_socket:send_immediate(SocketState, IP, Port, Packet) of
        {ok, _} ->
            ok;
        {error, Reason} = Err ->
            ?LOG_WARNING(
                #{
                    what => listener_send_failed,
                    backend => socket,
                    reason => Reason,
                    peer => {IP, Port},
                    size => iolist_size(Packet)
                },
                ?QUIC_LOG_META
            ),
            Err
    end;
send_packet(Socket, _SocketState, gen_udp, IP, Port, Packet) ->
    case gen_udp:send(Socket, IP, Port, Packet) of
        ok ->
            ok;
        {error, Reason} = Err ->
            ?LOG_WARNING(
                #{
                    what => listener_send_failed,
                    backend => gen_udp,
                    reason => Reason,
                    peer => {IP, Port},
                    size => iolist_size(Packet)
                },
                ?QUIC_LOG_META
            ),
            Err
    end.

%% Check if a packet might be a stateless reset
%% RFC 9000 Section 10.3: A reset looks like a short header packet
%% ending with a 16-byte token
%% RFC 9000 §17.3: a short header has the most-significant bit of the first byte
%% clear (long headers set it). 1-RTT packets and stateless resets use short
%% headers; Initial/Handshake/Retry/0-RTT use long headers.
is_short_header_packet(<<0:1, _/bitstring>>) ->
    true;
is_short_header_packet(_) ->
    false.

%% Compute stateless reset token from secret and CID
%% RFC 9000 Section 10.3.2: Token = HMAC(secret, CID)[0:16]
compute_stateless_reset_token(Secret, CID) ->
    <<Token:16/binary, _/binary>> = crypto:mac(hmac, sha256, Secret, CID),
    Token.

%% Build a stateless reset packet
%% RFC 9000 Section 10.3: Looks like a short header packet with random bytes
%% followed by the 16-byte stateless reset token
build_stateless_reset(Token, TriggerSize) ->
    %% Reset should be smaller than trigger (RFC 9000 Section 10.3.3)
    %% but at least 21 bytes. Use a size between 21 and TriggerSize-1.
    ResetSize = min(TriggerSize - 1, max(21, rand:uniform(20) + 21)),
    %% Unpredictable bits with fixed bit = 1 (first bit = 0 for short header)

    % 1 byte header + 16 byte token
    RandomLen = ResetSize - 17,
    RandomBytes = crypto:strong_rand_bytes(RandomLen),
    %% First byte: 0|1|XXXX = short header with fixed bit set
    %% Use random bits for rest to be unpredictable
    <<FirstRandom:6, _:2>> = crypto:strong_rand_bytes(1),
    FirstByte = (0 bsl 7) bor (1 bsl 6) bor FirstRandom,
    <<FirstByte, RandomBytes/binary, Token/binary>>.
