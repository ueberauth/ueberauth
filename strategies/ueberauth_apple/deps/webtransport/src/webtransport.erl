%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc WebTransport Public API
%%
%% This module provides the public API for WebTransport over HTTP/2 and HTTP/3.
%%
%% == Server Usage ==
%%
%% ```
%% %% Start a WebTransport listener
%% {ok, Listener} = webtransport:start_listener(my_listener, #{
%%     transport => h3,
%%     port => 8443,
%%     certfile => "cert.pem",
%%     keyfile => "key.pem",
%%     handler => my_wt_handler
%% }).
%%
%% %% Stop the listener
%% ok = webtransport:stop_listener(my_listener).
%% '''
%%
%% == Client Usage ==
%%
%% ```
%% %% Connect to a WebTransport server
%% {ok, Session} = webtransport:connect("example.com", 443, "/wt", #{
%%     transport => h3
%% }).
%%
%% %% Open a bidirectional stream
%% {ok, Stream} = webtransport:open_stream(Session, bidi).
%%
%% %% Send data
%% ok = webtransport:send(Session, Stream, <<"Hello">>).
%%
%% %% Send with FIN flag
%% ok = webtransport:send(Session, Stream, <<"World">>, fin).
%%
%% %% Send unreliable datagram
%% ok = webtransport:send_datagram(Session, <<"ping">>).
%%
%% %% Close stream
%% ok = webtransport:close_stream(Session, Stream).
%%
%% %% Close session
%% ok = webtransport:close_session(Session).
%% '''
%%
%% == Handler Behaviour ==
%%
%% See {@link webtransport_handler} for the callback behaviour.
%%
-module(webtransport).

%% Integration API (for embedding in a generic HTTP server)
-export([h3_settings/0, h3_settings/1]).
-export([h2_settings/0, h2_settings/1]).
-export([accept/4]).

%% Server API (convenience: standalone listener)
-export([start_listener/2, stop_listener/1]).
-export([listeners/0, listener_info/1, listener_sockname/1]).
-export([listener_loop/1]).

%% Client API
-export([connect/4, connect/5]).

%% Session API
-export([open_stream/2]).
-export([send/3, send/4]).
-export([send_datagram/2]).
-export([close_stream/2]).
-export([reset_stream/3, stop_sending/3]).
-export([drain_session/1]).
-export([close_session/1, close_session/2, close_session/3]).
-export([session_info/1]).
-export([early_data_accepted/1]).

-ifdef(TEST).
%% Exported for eunit: lets tests drive the h2 CONNECT-stream data loop with
%% fake connection/session pids to assert it self-terminates.
-export([h2_data_loop/3]).
-endif.

%% Types
-type session() :: pid().
-type stream() :: non_neg_integer().
-type listener_name() :: atom().
-type request() :: #{
    path := binary(),
    authority := binary(),
    headers => [{binary(), binary()}]
}.

-type listener_opts() :: #{
    transport := h2 | h3,
    port := inet:port_number(),
    certfile := file:filename(),
    keyfile := file:filename(),
    handler := module(),
    handler_opts => term(),
    max_data => non_neg_integer(),
    max_streams_bidi => non_neg_integer(),
    max_streams_uni => non_neg_integer(),
    %% Bind address / family. `ip' binds the listener socket to a specific
    %% address (IPv4 4-tuple or IPv6 8-tuple); `family' forces `inet' or
    %% `inet6' when no `ip' is given (e.g. the IPv6 wildcard). `socket_opts'
    %% are passed verbatim to the underlying UDP (h3) listener socket.
    ip => inet:ip_address(),
    family => inet | inet6,
    socket_opts => list(),
    %% Per-SNI certificate selection. Invoked per connection with the
    %% ClientHello SNI (RFC 6066 §3); the returned cert/key override the
    %% static `certfile'/`keyfile' for that handshake, letting one listener
    %% present different certificates per hostname. `cert' is a DER binary,
    %% `key' a decoded private-key term, `cert_chain' the DER intermediates.
    %% For h3 it is forwarded to `quic' (>= 1.6.5); for h2 it is adapted to
    %% an `ssl' `sni_fun'. When the callback returns `{error, _}' (or raises)
    %% the static cert is used for h2; for h3 the handshake fails.
    sni_callback => sni_callback(),
    %% `compat_mode' selects which WebTransport HTTP/3 draft the listener
    %% accepts. Default `auto' accepts draft-15 and draft-02 and picks the
    %% matching code path per CONNECT. Pin to `latest' to refuse draft-02
    %% clients or to `legacy_browser_compat' to refuse draft-15 clients.
    compat_mode => latest | legacy_browser_compat | auto
}.

-type sni_callback() :: fun(
    (ServerName :: binary() | undefined) ->
        {ok, #{cert := binary(), key := term(), cert_chain => [binary()]}}
        | {error, term()}
).

-type connect_opts() :: #{
    transport => h2 | h3,
    certfile => file:filename(),
    keyfile => file:filename(),
    cacertfile => file:filename(),
    verify => verify_none | verify_peer,
    headers => [{binary(), binary()}],
    timeout => timeout(),
    %% Address-family / dual-stack controls (h3 only), passed through to the
    %% QUIC client. `family' restricts resolution; `happy_eyeballs' toggles
    %% RFC 8305 v6/v4 racing; `connection_attempt_delay' is the stagger in ms.
    family => inet | inet6 | any,
    happy_eyeballs => boolean(),
    connection_attempt_delay => non_neg_integer(),
    %% 0-RTT: a session ticket captured from a prior connection
    %% (`{webtransport, session_ticket, Ticket}'). Opaque term, passed back to
    %% the QUIC layer as-is. h3 only.
    session_ticket => term(),
    %% Clients pick an explicit compat mode. Default `latest' sends
    %% draft-15 SETTINGS and `:protocol = webtransport-h3'. Use
    %% `legacy_browser_compat' only when talking to a known draft-02 peer
    %% (Chrome / Firefox / quic-go v0.9).
    compat_mode => latest | legacy_browser_compat
}.

-export_type([session/0, stream/0, request/0]).
-export_type([listener_name/0, listener_opts/0, connect_opts/0, sni_callback/0]).

-include("webtransport.hrl").

%% Largest partial capsule the h2 CONNECT-stream reader buffers before
%% treating the peer as misbehaving (a WT_STREAM capsule is one send/4
%% payload, so this bounds the biggest single send a peer may make).
-define(H2_CAPSULE_BUFFER_MAX, 64 * 1024 * 1024).

%% ============================================================================
%% Integration API
%% ============================================================================

%% @doc Return HTTP/3 settings to merge into a quic_h3 server configuration.
%%
%% Use this when embedding WebTransport into an existing HTTP/3 server
%% instead of using `start_listener/2'. The returned map contains:
%%
%% - `settings' -- H3 SETTINGS to advertise (wt_enabled, flow control, etc.)
%% - `stream_type_handler' -- claims WT extension streams (0x41 bidi, 0x54 uni)
%% - `h3_datagram_enabled' -- enables QUIC datagrams
%% - `quic_opts' -- QUIC transport params (max_datagram_frame_size, reset_stream_at)
%% - `connection_handler' -- per-connection setup (creates the WT stream router)
%%
%% Merge the result into your quic_h3 server opts:
%% ```
%% Opts = maps:merge(webtransport:h3_settings(), #{
%%     cert => CertDer, key => PrivateKey,
%%     handler => fun my_handler/5
%% }),
%% quic_h3:start_server(my_server, 443, Opts).
%% '''
-spec h3_settings() -> map().
h3_settings() ->
    h3_settings(#{}).

-spec h3_settings(map()) -> map().
h3_settings(Opts) ->
    CompatMode = maps:get(compat_mode, Opts, auto),
    Settings = case CompatMode of
        auto ->
            maps:merge(wt_h3:default_settings(latest),
                       wt_h3:default_settings(legacy_browser_compat));
        Mode ->
            wt_h3:default_settings(Mode)
    end,
    Claim = wt_stream_type_handler(),
    ConnectionHandler = fun(QuicConnPid) ->
        {ok, Router} = webtransport_h3_router:start(undefined),
        ensure_router_table(),
        %% Key the router by the QUIC connection pid. accept/4 derives the
        %% same key from its H3 connection via quic_h3:get_quic_conn/1, so
        %% it resolves this exact router no matter which process calls
        %% accept/4. quic_h3 runs request handlers in a spawned process and
        %% this callback runs in the listener process, so there is no shared
        %% process dictionary to rely on; the embedder may also dispatch
        %% accept/4 to its own per-request worker.
        ets:insert(webtransport_routers, {QuicConnPid, Router}),
        spawn(fun() -> reap_router(QuicConnPid, Router) end),
        #{
            owner => Router,
            stream_type_handler => Claim,
            h3_datagram_enabled => true
        }
    end,
    #{
        settings => Settings,
        stream_type_handler => Claim,
        h3_datagram_enabled => true,
        quic_opts => #{
            max_datagram_frame_size => 65535,
            reset_stream_at => true
        },
        connection_handler => ConnectionHandler
    }.

%% @doc Return HTTP/2 settings to merge into an h2 server configuration.
%%
%% ```
%% Opts = maps:merge(webtransport:h2_settings(), #{
%%     cert => "cert.pem", key => "key.pem",
%%     handler => fun my_handler/5,
%%     enable_connect_protocol => true
%% }),
%% h2:start_server(443, Opts).
%% '''
-spec h2_settings() -> map().
h2_settings() ->
    h2_settings(#{}).

-spec h2_settings(map()) -> map().
h2_settings(Opts) ->
    #{
        enable_connect_protocol => true,
        settings => #{
            enable_connect_protocol => 1,
            wt_initial_max_data =>
                maps:get(max_data, Opts, ?DEFAULT_MAX_DATA),
            wt_initial_max_streams_bidi =>
                maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
            wt_initial_max_streams_uni =>
                maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI)
        }
    }.

%% @doc Accept a WebTransport session on an incoming CONNECT request.
%%
%% Call this from your HTTP request handler when you want a particular
%% CONNECT request to become a WebTransport session. The function validates
%% headers, starts the session gen_statem, registers it as the stream
%% handler (like `quic_h3:set_stream_handler/3'), sends 200, and returns
%% `{ok, Session}'.
%%
%% ```
%% my_handler(Conn, StreamId, <<"CONNECT">>, <<"/wt">>, Headers) ->
%%     webtransport:accept(Conn, StreamId, Headers, #{
%%         transport => h3,
%%         handler => my_wt_handler,
%%         handler_opts => #{owner => self()}
%%     });
%% my_handler(Conn, StreamId, <<"GET">>, _Path, _Headers) ->
%%     quic_h3:send_response(Conn, StreamId, 200, []),
%%     quic_h3:send_data(Conn, StreamId, <<"hello">>, true).
%% '''
-spec accept(pid(), non_neg_integer(), [{binary(), binary()}], map()) ->
    {ok, session()} | {error, term()}.
accept(Conn, StreamId, Headers, Opts) ->
    Transport = maps:get(transport, Opts, h3),
    Handler = maps:get(handler, Opts, undefined),
    HandlerOpts = maps:get(handler_opts, Opts, #{}),
    Method = proplists:get_value(<<":method">>, Headers, <<>>),
    Path = proplists:get_value(<<":path">>, Headers, <<"/">>),
    case {Handler, Method} of
        {undefined, _} ->
            {error, missing_handler};
        {_, <<"CONNECT">>} ->
            case run_origin_check(Handler, Headers, HandlerOpts) of
                accept ->
                    do_accept(Transport, Conn, StreamId, Path,
                              Headers, Handler, HandlerOpts, Opts);
                {reject, Status, Reason} ->
                    send_reject(Transport, Conn, StreamId, Status, Reason),
                    {error, {rejected, Status}}
            end;
        {_, _} ->
            {error, not_connect_method}
    end.

do_accept(h3, H3Conn, StreamId, Path, Headers, Handler, HandlerOpts, Opts) ->
    CompatMode = maps:get(compat_mode, Opts, auto),
    case classify_h3_connect(Headers, CompatMode) of
        {ok, ClientMode} ->
            Router = get_or_create_router(H3Conn),
            Opts1 = Opts#{compat_mode => ClientMode},
            do_accept_h3(H3Conn, StreamId, Path, Headers,
                         Handler, HandlerOpts, Opts1, Router);
        {error, Reason} ->
            send_reject(h3, H3Conn, StreamId, 400,
                        iolist_to_binary(io_lib:format("~p", [Reason]))),
            {error, Reason}
    end;
do_accept(h2, Conn, StreamId, Path, Headers, Handler, HandlerOpts, Opts) ->
    case is_webtransport_request(Headers) of
        true ->
            do_accept_h2(Conn, StreamId, Path, Headers,
                         Handler, HandlerOpts, Opts);
        false ->
            send_reject(h2, Conn, StreamId, 400, <<"Bad Request">>),
            {error, not_webtransport}
    end.

do_accept_h3(H3Conn, StreamId, Path, Headers, Handler, HandlerOpts, Opts, Router) ->
    TransportState = webtransport_h3:new(H3Conn, StreamId, Router),
    Authority = proplists:get_value(<<":authority">>, Headers, <<>>),
    Request = #{path => Path, authority => Authority, headers => Headers},
    SessionOpts = maps:merge(HandlerOpts, #{
        request => Request,
        is_server => true,
        handler_opts => HandlerOpts,
        max_data => maps:get(max_data, Opts, ?DEFAULT_MAX_DATA),
        max_streams_bidi => maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        max_streams_uni => maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI)
    }),
    case webtransport_session:start_link(h3, TransportState, Handler, SessionOpts) of
        {ok, Session} ->
            quic_h3:set_stream_handler(H3Conn, StreamId, Session),
            webtransport_h3_router:register_session(Router, StreamId, Session),
            quic_h3:send_response(H3Conn, StreamId, 200, []),
            {ok, Session};
        {error, Reason} ->
            send_reject(h3, H3Conn, StreamId, 500,
                        iolist_to_binary(io_lib:format("~p", [Reason]))),
            {error, Reason}
    end.

do_accept_h2(Conn, StreamId, Path, Headers, Handler, HandlerOpts, Opts) ->
    h2:send_response(Conn, StreamId, 200, []),
    TransportState = webtransport_h2:new(Conn, StreamId),
    Authority = proplists:get_value(<<":authority">>, Headers, <<>>),
    Request = #{path => Path, authority => Authority, headers => Headers},
    ServerDefaults = #{
        u  => maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI),
        bl => maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        br => maps:get(max_data, Opts, ?DEFAULT_MAX_DATA)
    },
    Negotiated = case proplists:get_value(<<"webtransport-init">>, Headers) of
        undefined -> ServerDefaults;
        InitBin ->
            case wt_h2_init:parse(InitBin) of
                {ok, Init} -> wt_h2_init:apply_greater_of(Init, ServerDefaults);
                {error, _} -> ServerDefaults
            end
    end,
    SessionOpts = maps:merge(HandlerOpts, #{
        request => Request,
        is_server => true,
        handler_opts => HandlerOpts,
        max_data => maps:get(br, Negotiated, ?DEFAULT_MAX_DATA),
        max_streams_bidi => maps:get(bl, Negotiated, ?DEFAULT_MAX_STREAMS_BIDI),
        max_streams_uni => maps:get(u, Negotiated, ?DEFAULT_MAX_STREAMS_UNI)
    }),
    case webtransport_session:start_link(h2, TransportState, Handler, SessionOpts) of
        {ok, Session} ->
            LoopPid = spawn(fun() -> h2_data_loop(Conn, StreamId, Session) end),
            _ = h2:set_stream_handler(Conn, StreamId, LoopPid),
            {ok, Session};
        {error, Reason} ->
            h2:send_data(Conn, StreamId,
                         iolist_to_binary(io_lib:format("~p", [Reason])), true),
            {error, Reason}
    end.

send_reject(h3, H3Conn, StreamId, Status, Body) ->
    quic_h3:send_response(H3Conn, StreamId, Status, []),
    quic_h3:send_data(H3Conn, StreamId, Body, true);
send_reject(h2, Conn, StreamId, Status, Body) ->
    h2:send_response(Conn, StreamId, Status, []),
    h2:send_data(Conn, StreamId, Body, true).

%% Find the WT stream router for an H3 connection.
%%
%% The router demuxes extension streams (uni 0x54, bidi 0x41) to sessions.
%% It is keyed by the QUIC connection pid: the `h3_settings/1'
%% connection_handler registers it under the pid it is handed, and accept/4
%% derives the same pid from its H3 connection via `quic_h3:get_quic_conn/1'.
%% Both agree on one router per connection without a shared process
%% dictionary, so accept/4 works from any process (e.g. an embedder's
%% per-request worker).
get_or_create_router(H3Conn) ->
    ensure_router_table(),
    Key = router_key(H3Conn),
    case ets:lookup(webtransport_routers, Key) of
        [{_, Router}] ->
            case is_process_alive(Router) of
                true -> Router;
                false ->
                    ets:delete(webtransport_routers, Key),
                    create_and_register_router(Key)
            end;
        [] ->
            %% No connection_handler ran for this connection (the server was
            %% wired without h3_settings/1). Create a router so the session
            %% still starts; lacking the connection_handler's `owner' it
            %% won't receive peer-opened streams, but that is a caller-side
            %% misconfiguration.
            create_and_register_router(Key)
    end.

%% The registry key shared by the connection_handler and accept/4: the QUIC
%% connection pid behind the H3 connection. The connection_handler is handed
%% this same pid directly, so both sides resolve one router per connection.
router_key(H3Conn) ->
    quic_h3:get_quic_conn(H3Conn).

create_and_register_router(Key) ->
    {ok, Router} = webtransport_h3_router:start(undefined),
    ets:insert(webtransport_routers, {Key, Router}),
    Router.

%% Drop a per-connection router's registry row and stop the router when its
%% QUIC connection ends, so a long-lived embedder doesn't accumulate stale
%% rows or idle router processes. Runs in a throwaway process: the
%% connection_handler that spawns it runs inside the quic listener, which
%% must not block or monitor on its behalf. The {Key, Router} match means a
%% later connection that reuses the pid (and overwrote the row) is left
%% untouched.
reap_router(QuicConnPid, Router) ->
    Ref = erlang:monitor(process, QuicConnPid),
    receive
        {'DOWN', Ref, process, _, _} ->
            %% The table belongs to whichever process first created it; when
            %% an embedder stops its whole listener that owner may be gone
            %% already, and there is nothing left to clean up.
            try ets:match_delete(webtransport_routers, {QuicConnPid, Router})
            catch error:badarg -> ok
            end,
            try gen_server:stop(Router, normal, 5000) catch _:_ -> ok end,
            ok
    end.

ensure_router_table() ->
    case ets:whereis(webtransport_routers) of
        undefined ->
            try
                ets:new(webtransport_routers, [named_table, public, set])
            catch
                error:badarg -> ok  %% race: another process created it
            end;
        _ ->
            ok
    end.

%% ============================================================================
%% Server API
%% ============================================================================

%% @doc Start a WebTransport listener.
%%
%% Options:
%% - `transport' - Required. Either `h2' (HTTP/2) or `h3' (HTTP/3)
%% - `port' - Required. Port to listen on
%% - `certfile' - Required. Path to TLS certificate
%% - `keyfile' - Required. Path to TLS private key
%% - `handler' - Required. Module implementing webtransport_handler behaviour
%% - `handler_opts' - Optional. Initial options passed to handler:init/2
%% - `max_data' - Optional. Initial max session data (default 1MB)
%% - `max_streams_bidi' - Optional. Initial max bidi streams (default 100)
%% - `max_streams_uni' - Optional. Initial max uni streams (default 100)
%%
-spec start_listener(listener_name(), listener_opts()) ->
    {ok, pid()} | {error, term()}.
start_listener(Name, #{transport := Transport} = Opts) when is_atom(Name) ->
    case validate_listener_opts(Opts) of
        ok ->
            case Transport of
                h2 -> start_h2_listener(Name, Opts);
                h3 -> start_h3_listener(Name, Opts)
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc Stop a WebTransport listener.
-spec stop_listener(listener_name()) -> ok | {error, term()}.
stop_listener(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined ->
            {error, not_found};
        Pid ->
            case persistent_term:get({webtransport_listener, Name}, undefined) of
                undefined ->
                    {error, not_found};
                #{transport := h2, server_ref := ServerRef} ->
                    h2:stop_server(ServerRef),
                    persistent_term:erase({webtransport_listener, Name}),
                    exit(Pid, shutdown),
                    ok;
                #{transport := h3, server_ref := ServerRef} ->
                    quic_h3:stop_server(ServerRef),
                    persistent_term:erase({webtransport_listener, Name}),
                    exit(Pid, shutdown),
                    ok
            end
    end.

%% @doc List all active listeners.
-spec listeners() -> [listener_name()].
listeners() ->
    %% Get all persistent terms that match our pattern
    [Name || {{webtransport_listener, Name}, _} <- persistent_term:get()].

%% @doc Get information about a listener.
%%
%% The `sockname' field is the bound `{Ip, Port}'. For h3 it is resolved live
%% from the QUIC socket (correct even when bound with port 0 or `inet6'). For
%% h2 it is best-effort (requested address + bound port), since the h2 library
%% does not expose the bound IP.
-spec listener_info(listener_name()) -> {ok, map()} | {error, not_found}.
listener_info(Name) ->
    case persistent_term:get({webtransport_listener, Name}, undefined) of
        undefined ->
            {error, not_found};
        Info ->
            Base = maps:without([server_ref], Info),
            WithSockname = case listener_sockname(Name) of
                {ok, Sockname} -> Base#{sockname => Sockname};
                {error, _} -> Base
            end,
            {ok, WithSockname}
    end.

%% @doc Get the bound `{Ip, Port}' of a listener.
%%
%% For h3, resolved live from the QUIC listener socket. For h2 this is
%% best-effort: the requested bind address (defaulting to the family wildcard)
%% paired with the actual bound port, because the h2 library exposes only the
%% port, not the bound IP.
-spec listener_sockname(listener_name()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
listener_sockname(Name) ->
    case persistent_term:get({webtransport_listener, Name}, undefined) of
        undefined ->
            {error, not_found};
        #{transport := h3} ->
            quic:get_server_sockname(Name);
        #{transport := h2, server_ref := ServerRef} = Info ->
            Ip = maps:get(bind_ip, Info, {0, 0, 0, 0}),
            {ok, {Ip, h2:server_port(ServerRef)}}
    end.

%% ============================================================================
%% Client API
%% ============================================================================

%% @doc Connect to a WebTransport server.
%%
%% Options:
%% - `transport' - Optional. Either `h2' or `h3' (default: h3)
%% - `cacertfile' - Optional. CA certificate file for verification
%% - `verify' - Optional. `verify_none' or `verify_peer' (default: verify_peer)
%% - `headers' - Optional. Extra headers to send in CONNECT request
%% - `timeout' - Optional. Connection timeout in ms (default: 30000)
%%
-spec connect(Host, Port, Path, Opts) -> {ok, session()} | {error, term()} when
    Host :: string() | binary() | inet:ip_address(),
    Port :: inet:port_number(),
    Path :: binary(),
    Opts :: connect_opts().
connect(Host, Port, Path, Opts) ->
    connect(Host, Port, Path, Opts, undefined).

%% @doc Connect to a WebTransport server with a custom handler.
-spec connect(Host, Port, Path, Opts, Handler) -> {ok, session()} | {error, term()} when
    Host :: string() | binary() | inet:ip_address(),
    Port :: inet:port_number(),
    Path :: binary(),
    Opts :: connect_opts(),
    Handler :: module() | undefined.
connect(Host, Port, Path, Opts, Handler) ->
    Transport = maps:get(transport, Opts, h3),
    case Transport of
        h2 -> connect_h2(Host, Port, Path, Opts, Handler);
        h3 -> connect_h3(Host, Port, Path, Opts, Handler)
    end.

%% ============================================================================
%% Session API
%% ============================================================================

%% @doc Open a new stream on the session.
-spec open_stream(session(), bidi | uni) -> {ok, stream()} | {error, term()}.
open_stream(Session, Type) when Type =:= bidi; Type =:= uni ->
    webtransport_session:open_stream(Session, Type).

%% @doc Send data on a stream.
-spec send(session(), stream(), iodata()) -> ok | {error, term()}.
send(Session, Stream, Data) ->
    webtransport_session:send(Session, Stream, Data, false).

%% @doc Send data on a stream with optional FIN flag.
-spec send(session(), stream(), iodata(), fin | nofin) -> ok | {error, term()}.
send(Session, Stream, Data, fin) ->
    webtransport_session:send(Session, Stream, Data, true);
send(Session, Stream, Data, nofin) ->
    webtransport_session:send(Session, Stream, Data, false).

%% @doc Send an unreliable datagram.
-spec send_datagram(session(), iodata()) -> ok | {error, term()}.
send_datagram(Session, Data) ->
    webtransport_session:send_datagram(Session, Data).

%% @doc Close a stream gracefully (send FIN).
-spec close_stream(session(), stream()) -> ok | {error, term()}.
close_stream(Session, Stream) ->
    webtransport_session:close_stream(Session, Stream).

%% @doc Abruptly terminate a stream with an error code.
-spec reset_stream(session(), stream(), non_neg_integer()) -> ok | {error, term()}.
reset_stream(Session, Stream, ErrorCode) ->
    webtransport_session:reset_stream(Session, Stream, ErrorCode).

%% @doc Request that the peer stop sending on a stream.
-spec stop_sending(session(), stream(), non_neg_integer()) -> ok | {error, term()}.
stop_sending(Session, Stream, ErrorCode) ->
    webtransport_session:stop_sending(Session, Stream, ErrorCode).

%% @doc Signal that no new streams will be created.
-spec drain_session(session()) -> ok.
drain_session(Session) ->
    webtransport_session:drain(Session).

%% @doc Close the session gracefully.
-spec close_session(session()) -> ok.
close_session(Session) ->
    close_session(Session, 0, <<>>).

%% @doc Close the session with an error code.
-spec close_session(session(), non_neg_integer()) -> ok.
close_session(Session, ErrorCode) ->
    close_session(Session, ErrorCode, <<>>).

%% @doc Close the session with an error code and reason.
%% draft-14 §4.6 / draft-15 §5: Reason must be at most 1024 UTF-8 bytes.
-spec close_session(session(), non_neg_integer(), binary()) -> ok | {error, reason_too_long}.
close_session(_Session, _ErrorCode, Reason) when byte_size(Reason) > 1024 ->
    {error, reason_too_long};
close_session(Session, ErrorCode, Reason) ->
    webtransport_session:close(Session, ErrorCode, Reason).

%% @doc Get session information.
-spec session_info(session()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    webtransport_session:get_info(Session).

%% @doc Report whether the session's connection negotiated 0-RTT early data.
%%
%% Returns `true', `false', or `unknown' for h3 sessions (RFC 9001 §4.6), and
%% `not_supported' for h2. This is connection-level: it reflects whether the
%% QUIC connection used 0-RTT, regardless of whether the WebTransport CONNECT
%% itself rode as early data.
-spec early_data_accepted(session()) -> boolean() | unknown | not_supported.
early_data_accepted(Session) ->
    webtransport_session:early_data_accepted(Session).

%% ============================================================================
%% Internal Functions - Listener Setup
%% ============================================================================

validate_listener_opts(Opts) ->
    Required = [transport, port, certfile, keyfile, handler],
    Missing = [K || K <- Required, not maps:is_key(K, Opts)],
    case Missing of
        [] -> ok;
        _ -> {error, {missing_options, Missing}}
    end.

%% Build the `extra_socket_opts' list passed to quic for the h3 listener.
%% `quic_listener' infers the socket family from this list (the `inet6' atom
%% or an IPv6 `ip' tuple), so we just assemble the right entries:
%%   - `family => inet6' or an 8-tuple `ip' selects IPv6
%%   - `ip' adds `{ip, Addr}'
%%   - user `socket_opts' are appended verbatim
build_extra_socket_opts(Opts) ->
    Ip = maps:get(ip, Opts, undefined),
    Family = maps:get(family, Opts, inet),
    UserOpts = maps:get(socket_opts, Opts, []),
    Inet6 = (Family =:= inet6) orelse is_ipv6_addr(Ip),
    FamilyOpts = case Inet6 of
        true -> [inet6];
        false -> []
    end,
    IpOpts = case Ip of
        undefined -> [];
        _ -> [{ip, Ip}]
    end,
    FamilyOpts ++ IpOpts ++ UserOpts.

is_ipv6_addr({_, _, _, _, _, _, _, _}) -> true;
is_ipv6_addr(_) -> false.

%% Map our `ip' / `family' listener opts onto the `ip' / `inet6' keys that
%% h2:start_server understands.
add_h2_bind_opts(ServerOpts, Opts) ->
    Ip = maps:get(ip, Opts, undefined),
    Inet6 = (maps:get(family, Opts, inet) =:= inet6) orelse is_ipv6_addr(Ip),
    WithIp = case Ip of
        undefined -> ServerOpts;
        _ -> ServerOpts#{ip => Ip}
    end,
    case Inet6 of
        true -> WithIp#{inet6 => true};
        false -> WithIp
    end.

%% Forward a `sni_callback' into the h3 `quic_opts' map so it reaches
%% `quic:start_server' (quic >= 1.6.5 selects the cert per ClientHello SNI).
maybe_put_sni(Opts, QuicOpts) ->
    case maps:find(sni_callback, Opts) of
        {ok, Fun} -> QuicOpts#{sni_callback => Fun};
        error -> QuicOpts
    end.

%% Adapt a quic-style `sni_callback' to an `ssl' `sni_fun' for the h2 path.
%% `ssl' invokes `sni_fun' only when the ClientHello carries an SNI, so a
%% client with no SNI keeps the static certfile/keyfile.
add_h2_sni_opts(ServerOpts, Opts) ->
    case maps:find(sni_callback, Opts) of
        {ok, Fun} ->
            SniFun = sni_fun_from_callback(Fun),
            UserSslOpts = maps:get(ssl_opts, ServerOpts, []),
            ServerOpts#{ssl_opts => [{sni_fun, SniFun} | UserSslOpts]};
        error ->
            ServerOpts
    end.

%% Wrap the quic-style callback as an `ssl' `sni_fun'. `ssl' passes the
%% ServerName as a charlist; we hand the user a binary. On `{ok, _}' we
%% return the leaf+chain and re-encode the decoded key to the `{Tag, DER}'
%% form `ssl' expects via a `certs_keys' entry. Any other result (or a
%% raised error) aborts the handshake, matching h3's `handshake_failure'.
sni_fun_from_callback(Fun) ->
    fun(ServerName) ->
        ServerNameBin = case ServerName of
            undefined -> undefined;
            _ when is_list(ServerName) -> list_to_binary(ServerName);
            _ when is_binary(ServerName) -> ServerName
        end,
        case Fun(ServerNameBin) of
            {ok, #{cert := Cert, key := Key} = CertMap} when is_binary(Cert) ->
                Chain = maps:get(cert_chain, CertMap, []),
                KeyDer = {element(1, Key), public_key:der_encode(element(1, Key), Key)},
                [{certs_keys, [#{cert => [Cert | Chain], key => KeyDer}]}];
            Other ->
                error({sni_callback_rejected, ServerNameBin, Other})
        end
    end.

%% Resolved default bind address for the stored listener record, used by
%% `listener_sockname/1' / `listener_info/1' when no explicit `ip' was given.
default_bind_ip(Opts) ->
    case maps:get(ip, Opts, undefined) of
        undefined ->
            case (maps:get(family, Opts, inet) =:= inet6) of
                true -> {0, 0, 0, 0, 0, 0, 0, 0};
                false -> {0, 0, 0, 0}
            end;
        Ip ->
            Ip
    end.

start_h2_listener(Name, Opts) ->
    #{
        port := Port,
        certfile := CertFile,
        keyfile := KeyFile,
        handler := Handler
    } = Opts,

    HandlerOpts = maps:get(handler_opts, Opts, #{}),

    %% Create wrapper handler for H2
    H2Handler = make_h2_handler(Handler, HandlerOpts, Opts),

    WtSettings = #{
        enable_connect_protocol => 1,
        wt_initial_max_data =>
            maps:get(max_data, Opts, ?DEFAULT_MAX_DATA),
        wt_initial_max_streams_bidi =>
            maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        wt_initial_max_streams_uni =>
            maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI)
    },
    ServerOpts0 = #{
        cert => CertFile,
        key => KeyFile,
        handler => H2Handler,
        enable_connect_protocol => true,
        settings => WtSettings
    },
    %% h2:start_server reads `ip' / `inet6' from its server-opts map. Map our
    %% `ip' / `family' listener opts onto those keys.
    ServerOpts1 = add_h2_bind_opts(ServerOpts0, Opts),
    %% Per-SNI cert selection: adapt the quic-style `sni_callback' to an `ssl'
    %% `sni_fun' and pass it through `ssl_opts' (h2 merges these on top of its
    %% defaults). When no callback is set the static certfile/keyfile is used.
    ServerOpts = add_h2_sni_opts(ServerOpts1, Opts),

    %% h2:start_server spawn_link's acceptor/manager processes to its caller.
    %% Delegating to a persistent owner process keeps those links on a
    %% long-lived pid so the listener survives after the caller returns.
    case start_h2_server_owner(Name, Port, Handler, ServerOpts) of
        {ok, OwnerPid, ServerRef} ->
            persistent_term:put({webtransport_listener, Name}, #{
                transport => h2,
                port => Port,
                bind_ip => default_bind_ip(Opts),
                handler => Handler,
                server_ref => ServerRef
            }),
            {ok, OwnerPid};
        {error, Reason} ->
            {error, Reason}
    end.

start_h2_server_owner(Name, Port, _Handler, ServerOpts) ->
    Parent = self(),
    Ref = make_ref(),
    OwnerPid = spawn(fun() -> h2_owner_init(Parent, Ref, Name, Port, ServerOpts) end),
    receive
        {Ref, {ok, ServerRef}} ->
            {ok, OwnerPid, ServerRef};
        {Ref, {error, Reason}} ->
            {error, Reason}
    after 5000 ->
        exit(OwnerPid, kill),
        {error, h2_listener_start_timeout}
    end.

h2_owner_init(Parent, Ref, Name, Port, ServerOpts) ->
    case h2:start_server(Port, ServerOpts) of
        {ok, ServerRef} ->
            try register(Name, self()) catch _:_ -> ok end,
            Parent ! {Ref, {ok, ServerRef}},
            h2_owner_loop(Name, ServerRef);
        {error, Reason} ->
            Parent ! {Ref, {error, Reason}}
    end.

h2_owner_loop(Name, ServerRef) ->
    receive
        {stop, _From} ->
            h2:stop_server(ServerRef),
            persistent_term:erase({webtransport_listener, Name}),
            ok;
        _ ->
            h2_owner_loop(Name, ServerRef)
    end.

start_h3_listener(Name, Opts) ->
    #{
        port := Port,
        certfile := CertFile,
        keyfile := KeyFile,
        handler := Handler
    } = Opts,

    HandlerOpts = maps:get(handler_opts, Opts, #{}),

    %% Read and decode certificate and key
    case read_cert_and_key(CertFile, KeyFile) of
        {ok, CertDer, PrivateKey} ->
            Claim = wt_stream_type_handler(),

            ConnectionHandler = fun(_QuicConnPid) ->
                {ok, Router} = webtransport_h3_router:start(undefined),
                #{
                    owner => Router,
                    handler => make_h3_handler(Handler, HandlerOpts, Opts, Router),
                    stream_type_handler => Claim,
                    h3_datagram_enabled => true
                }
            end,

            ServerCompatMode = maps:get(compat_mode, Opts, auto),
            %% `auto' advertises both latest (draft-15) AND legacy
            %% (draft-02) setting keys. H3 SETTINGS are connection-
            %% scoped and sent before any CONNECT, so the server cannot
            %% know the client's draft at SETTINGS time. Peers MUST
            %% ignore unknown settings (RFC 9114 §7.2.4.1), so the
            %% merged shape is wire-safe. Pinning to a specific mode
            %% sends only that mode's settings.
            AdvertisedSettings = case ServerCompatMode of
                auto ->
                    maps:merge(wt_h3:default_settings(latest),
                               wt_h3:default_settings(legacy_browser_compat));
                Other ->
                    wt_h3:default_settings(Other)
            end,
            ServerOpts = #{
                cert => CertDer,
                key => PrivateKey,
                handler => make_h3_handler(Handler, HandlerOpts, Opts, undefined),
                settings => AdvertisedSettings,
                %% `sni_callback' rides inside `quic_opts' so it reaches
                %% `quic:start_server'; `quic_h3' only lifts cert/key from
                %% the top level. quic selects the cert per ClientHello SNI.
                quic_opts => maybe_put_sni(Opts, #{
                    max_datagram_frame_size => 65535,
                    reset_stream_at => true,
                    extra_socket_opts => build_extra_socket_opts(Opts)
                }),
                stream_type_handler => Claim,
                connection_handler => ConnectionHandler
            },

            case quic_h3:start_server(Name, Port, ServerOpts) of
                {ok, ServerRef} ->
                    Pid = spawn(?MODULE, listener_loop, [Name]),
                    register(Name, Pid),
                    persistent_term:put({webtransport_listener, Name}, #{
                        transport => h3,
                        port => Port,
                        bind_ip => default_bind_ip(Opts),
                        handler => Handler,
                        server_ref => ServerRef
                    }),
                    {ok, Pid};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

listener_loop(Name) ->
    receive
        {stop, _From} ->
            persistent_term:erase({webtransport_listener, Name}),
            ok;
        _ ->
            listener_loop(Name)
    end.

%% ============================================================================
%% Internal Functions - Request Handling
%% ============================================================================

handle_h2_request(Conn, StreamId, <<"CONNECT">>, Path, Headers, Handler, HandlerOpts, Opts) ->
    case is_webtransport_request(Headers) of
        true ->
            case run_origin_check(Handler, Headers, HandlerOpts) of
                accept ->
                    accept_h2_session(Conn, StreamId, Path, Headers,
                                      Handler, HandlerOpts, Opts);
                {reject, Status, Reason} ->
                    h2:send_response(Conn, StreamId, Status, []),
                    h2:send_data(Conn, StreamId, Reason, true)
            end;
        false ->
            h2:send_response(Conn, StreamId, 400, []),
            h2:send_data(Conn, StreamId, <<"Bad Request">>, true)
    end;

handle_h2_request(Conn, StreamId, _Method, _Path, _Headers, _Handler, _HandlerOpts, _Opts) ->
    h2:send_response(Conn, StreamId, 405, []),
    h2:send_data(Conn, StreamId, <<"Method Not Allowed">>, true).

handle_h3_request(H3Conn, StreamId, <<"CONNECT">>, Path, Headers,
                  Handler, HandlerOpts, Opts, Router) ->
    ListenerMode = maps:get(compat_mode, Opts, auto),
    case classify_h3_connect(Headers, ListenerMode) of
        {ok, ClientMode} ->
            case run_origin_check(Handler, Headers, HandlerOpts) of
                accept ->
                    Opts1 = Opts#{compat_mode => ClientMode},
                    accept_h3_session(H3Conn, StreamId, Path, Headers,
                                      Handler, HandlerOpts, Opts1, Router);
                {reject, Status, Reason} ->
                    quic_h3:send_response(H3Conn, StreamId, Status, []),
                    quic_h3:send_data(H3Conn, StreamId, Reason, true)
            end;
        {error, Reason} ->
            Body = iolist_to_binary(io_lib:format("Bad Request: ~p", [Reason])),
            quic_h3:send_response(H3Conn, StreamId, 400, []),
            quic_h3:send_data(H3Conn, StreamId, Body, true)
    end;

handle_h3_request(H3Conn, StreamId, _Method, _Path, _Headers,
                  _Handler, _HandlerOpts, _Opts, _Router) ->
    quic_h3:send_response(H3Conn, StreamId, 405, []),
    quic_h3:send_data(H3Conn, StreamId, <<"Method Not Allowed">>, true).

accept_h2_session(Conn, StreamId, Path, Headers, Handler, HandlerOpts, Opts) ->
    h2:send_response(Conn, StreamId, 200, []),
    TransportState = webtransport_h2:new(Conn, StreamId),
    Authority = proplists:get_value(<<":authority">>, Headers, <<>>),
    Request = #{
        path => Path,
        authority => Authority,
        headers => Headers
    },
    %% Parse WebTransport-Init from the client's CONNECT request and
    %% apply the greater-of rule (draft-14 §4.3.2) against our defaults.
    ServerDefaults = #{
        u  => maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI),
        bl => maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        br => maps:get(max_data, Opts, ?DEFAULT_MAX_DATA)
    },
    Negotiated = case proplists:get_value(<<"webtransport-init">>, Headers) of
        undefined -> ServerDefaults;
        InitBin ->
            case wt_h2_init:parse(InitBin) of
                {ok, Init} -> wt_h2_init:apply_greater_of(Init, ServerDefaults);
                {error, _} -> ServerDefaults
            end
    end,
    SessionOpts = maps:merge(HandlerOpts, #{
        request => Request,
        is_server => true,
        handler_opts => HandlerOpts,
        max_data => maps:get(br, Negotiated, ?DEFAULT_MAX_DATA),
        max_streams_bidi => maps:get(bl, Negotiated, ?DEFAULT_MAX_STREAMS_BIDI),
        max_streams_uni => maps:get(u, Negotiated, ?DEFAULT_MAX_STREAMS_UNI)
    }),
    case webtransport_session:start_link(h2, TransportState, Handler, SessionOpts) of
        {ok, Session} ->
            LoopPid = spawn(fun() -> h2_data_loop(Conn, StreamId, Session) end),
            _ = h2:set_stream_handler(Conn, StreamId, LoopPid);
        {error, Reason} ->
            h2:send_response(Conn, StreamId, 500, []),
            h2:send_data(Conn, StreamId,
                         iolist_to_binary(io_lib:format("~p", [Reason])), true)
    end.

accept_h3_session(H3Conn, StreamId, Path, Headers, Handler, HandlerOpts, Opts, Router) ->
    TransportState = webtransport_h3:new(H3Conn, StreamId, Router),
    Authority = proplists:get_value(<<":authority">>, Headers, <<>>),
    Request = #{
        path => Path,
        authority => Authority,
        headers => Headers
    },
    SessionOpts = maps:merge(HandlerOpts, #{
        request => Request,
        is_server => true,
        handler_opts => HandlerOpts,
        max_data => maps:get(max_data, Opts, ?DEFAULT_MAX_DATA),
        max_streams_bidi => maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        max_streams_uni => maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI)
    }),
    %% Register the session with the router BEFORE the 200 goes out.
    %% Otherwise the client sees 200, opens extension streams, and the
    %% stream_type_data arrives at the router while sessions is still
    %% empty. The router then silently drops the data.
    case webtransport_session:start_link(h3, TransportState, Handler, SessionOpts) of
        {ok, Session} ->
            quic_h3:set_stream_handler(H3Conn, StreamId, Session),
            case Router of
                undefined -> ok;
                _ -> webtransport_h3_router:register_session(Router, StreamId, Session)
            end,
            quic_h3:send_response(H3Conn, StreamId, 200, []),
            ok;
        {error, Reason} ->
            quic_h3:send_response(H3Conn, StreamId, 500, []),
            quic_h3:send_data(H3Conn, StreamId,
                              iolist_to_binary(io_lib:format("~p", [Reason])), true)
    end.

%% Defaults to accept when the handler does not export origin_check/2.
run_origin_check(Handler, Headers, Opts) ->
    _ = code:ensure_loaded(Handler),
    case erlang:function_exported(Handler, origin_check, 2) of
        true ->
            try Handler:origin_check(Headers, Opts) of
                accept -> accept;
                {reject, Status, Reason}
                  when is_integer(Status), Status >= 400, Status < 600,
                       is_binary(Reason) ->
                    {reject, Status, Reason};
                Other ->
                    logger:warning("invalid origin_check/2 result: ~p", [Other]),
                    accept
            catch
                Kind:Err:Stk ->
                    logger:warning("origin_check/2 crashed ~p:~p ~p", [Kind, Err, Stk]),
                    {reject, 500, <<"origin check failed">>}
            end;
        false ->
            %% No custom origin_check/2 callback. The drafts (h3 §3.2,
            %% h2 §3.2) require: "the server MUST verify the Origin header
            %% to ensure that the specified origin is allowed". If the
            %% request carries an Origin header (browser client), reject
            %% by default so servers cannot accidentally skip verification.
            %% Non-browser requests (no Origin header) are accepted.
            case proplists:get_value(<<"origin">>, Headers) of
                undefined -> accept;
                _ -> {reject, 403, <<"origin not allowed">>}
            end
    end.

is_webtransport_request(Headers) ->
    case proplists:get_value(<<":protocol">>, Headers) of
        <<"webtransport">> -> true;
        _ -> false
    end.

%% Classify an incoming h3 CONNECT request against the listener's
%% compat_mode. Returns `{ok, ClientMode}' when the request is well-formed
%% and allowed, or `{error, Reason}' when it is malformed or disallowed.
classify_h3_connect(Headers, ListenerMode) ->
    case wt_h3:detect_compat_mode(Headers) of
        {ok, ClientMode} ->
            case allowed_by_listener(ClientMode, ListenerMode) of
                true -> {ok, ClientMode};
                false -> {error, {compat_mode_refused, ClientMode}}
            end;
        {error, _} = Err ->
            Err
    end.

allowed_by_listener(_, auto) -> true;
allowed_by_listener(Mode, Mode) -> true;
allowed_by_listener(_, _) -> false.

%% ============================================================================
%% Internal Functions - Data Loops
%% ============================================================================

h2_data_loop(Conn, StreamId, Session) ->
    %% Monitor both ends so the loop can never orphan: if the h2 connection
    %% dies without a `closed' message, or the session goes away, we exit
    %% instead of blocking in `receive' forever.
    ConnRef = erlang:monitor(process, Conn),
    SessionRef = erlang:monitor(process, Session),
    h2_data_loop(Conn, StreamId, Session, ConnRef, SessionRef, <<>>).

%% `Buf' holds the tail of the previous DATA frame that did not end on a
%% capsule boundary. A WT_STREAM capsule carries a whole send/4 payload, and
%% h2 splits it into DATA frames of at most SETTINGS_MAX_FRAME_SIZE (16 KiB
%% by default), so most capsules over that size arrive in pieces. Dropping
%% the tail, as earlier versions did, truncated every such payload.
h2_data_loop(Conn, StreamId, Session, ConnRef, SessionRef, Buf) ->
    receive
        {h2, Conn, {data, StreamId, Data, _IsFin}} ->
            %% Decode every complete capsule, keep the partial tail.
            case webtransport_h2:decode_capsules(<<Buf/binary, Data/binary>>) of
                {ok, Capsules, Rest} when byte_size(Rest) =< ?H2_CAPSULE_BUFFER_MAX ->
                    lists:foreach(fun(Capsule) ->
                        dispatch_h2_capsule(Session, Capsule)
                    end, Capsules),
                    h2_data_loop(Conn, StreamId, Session, ConnRef, SessionRef, Rest);
                {ok, _Capsules, _Rest} ->
                    %% A single capsule larger than we are willing to hold
                    %% in memory. Treat as a protocol violation.
                    logger:warning("h2 capsule exceeds ~p bytes", [?H2_CAPSULE_BUFFER_MAX]),
                    cleanup_data_loop(ConnRef, SessionRef),
                    webtransport_session:close(Session, 0, <<"capsule too large">>);
                {error, Reason} ->
                    %% Malformed capsule framing on the CONNECT stream is
                    %% a protocol violation. Close the session.
                    logger:warning("h2 capsule decode error: ~p", [Reason]),
                    cleanup_data_loop(ConnRef, SessionRef),
                    webtransport_session:close(Session, 0, <<"malformed capsule">>)
            end;
        {h2, Conn, {stream_reset, StreamId, _ErrorCode}} ->
            cleanup_data_loop(ConnRef, SessionRef),
            webtransport_session:close(Session, 0, <<"stream reset">>);
        %% h2 0.12 always reports the reason; older ones sent the bare atom.
        {h2, Conn, {closed, _Reason}} ->
            cleanup_data_loop(ConnRef, SessionRef),
            webtransport_session:close(Session, 0, <<"connection closed">>);
        {h2, Conn, closed} ->
            cleanup_data_loop(ConnRef, SessionRef),
            webtransport_session:close(Session, 0, <<"connection closed">>);
        {'DOWN', ConnRef, process, Conn, _Reason} ->
            erlang:demonitor(SessionRef, [flush]),
            webtransport_session:close(Session, 0, <<"connection closed">>);
        {'DOWN', SessionRef, process, Session, _Reason} ->
            %% Session is gone; nothing left to forward to. Exit so we don't
            %% leak this process for the life of the h2 connection.
            erlang:demonitor(ConnRef, [flush]),
            ok;
        _ ->
            h2_data_loop(Conn, StreamId, Session, ConnRef, SessionRef, Buf)
    end.

cleanup_data_loop(ConnRef, SessionRef) ->
    erlang:demonitor(ConnRef, [flush]),
    erlang:demonitor(SessionRef, [flush]).

dispatch_h2_capsule(Session, {wt_stream, WtStreamId, Data}) ->
    %% h2 multiplexes WT streams over CONNECT; peer-opened streams don't get
    %% a separate open signal, so we seed the session's stream map on first
    %% data (handle_stream_opened is idempotent). Direction follows the QUIC
    %% stream-id rule (bit 1 = 0 bidi, 1 = uni) per draft-14.
    webtransport_session:handle_stream_opened(Session, WtStreamId,
                                              webtransport_stream:stream_type(WtStreamId)),
    webtransport_session:handle_stream_data(Session, WtStreamId, Data, false);
dispatch_h2_capsule(Session, {wt_stream_fin, WtStreamId, Data}) ->
    webtransport_session:handle_stream_opened(Session, WtStreamId,
                                              webtransport_stream:stream_type(WtStreamId)),
    webtransport_session:handle_stream_data(Session, WtStreamId, Data, true);
dispatch_h2_capsule(Session, {datagram, Data}) ->
    webtransport_session:handle_datagram_data(Session, Data);
dispatch_h2_capsule(Session, {reset_stream, WtStreamId, ErrorCode}) ->
    webtransport_session:handle_stream_closed(Session, WtStreamId, {reset, ErrorCode});
dispatch_h2_capsule(Session, {stop_sending, WtStreamId, ErrorCode}) ->
    webtransport_session:handle_stream_closed(Session, WtStreamId, {stop_sending, ErrorCode});
dispatch_h2_capsule(Session, Capsule) ->
    webtransport_session:handle_capsule(Session, Capsule).

%% ============================================================================
%% Internal Functions - Client Connection
%% ============================================================================

connect_h2(Host, Port, Path, Opts, Handler) ->
    Caller = self(),
    UserHandlerOpts = maps:get(handler_opts, Opts, #{}),
    HandlerOpts = maps:merge(#{owner => Caller}, UserHandlerOpts),
    Opts1 = Opts#{ssl_opts => build_h2_ssl_opts(Opts)},
    case webtransport_h2:connect(Host, Port, Path, Opts1) of
        {ok, TransportState} ->
            %% Default handler for client
            ActualHandler = case Handler of
                undefined -> webtransport_client_handler;
                _ -> Handler
            end,
            Request = #{
                path => Path,
                authority => authority(Host, Port),
                headers => maps:get(headers, Opts, [])
            },
            SessionOpts = #{
                request => Request,
                is_server => false,
                handler_opts => HandlerOpts
            },
            case webtransport_session:start_link(h2, TransportState, ActualHandler, SessionOpts) of
                {ok, Session} ->
                    H2Conn = webtransport_h2:h2_conn(TransportState),
                    StreamId = webtransport_h2:connect_stream_id(TransportState),
                    LoopPid = spawn(fun() -> h2_data_loop(H2Conn, StreamId, Session) end),
                    _ = h2:set_stream_handler(H2Conn, StreamId, LoopPid),
                    {ok, Session};
                {error, _} = Err ->
                    Err
            end;
        {error, Reason} ->
            {error, Reason}
    end.

connect_h3(Host, Port, Path, Opts0, Handler) ->
    Caller = self(),
    UserHandlerOpts = maps:get(handler_opts, Opts0, #{}),
    HandlerOpts = maps:merge(#{owner => Caller}, UserHandlerOpts),
    Opts = Opts0#{handler_opts => HandlerOpts},
    Authority = authority(Host, Port),
    {ok, Router} = webtransport_h3_router:start_link(Caller),
    H3ConnOpts = build_h3_connect_opts(Opts),
    case webtransport_h3_router:client_connect(Router, Host, Port, H3ConnOpts) of
        {ok, H3Conn} ->
            h3_validate_and_request(H3Conn, Authority, Path, Opts, Handler, Router);
        {error, Reason} ->
            %% No H3 connection was established, so the router never started
            %% monitoring one and would otherwise linger (it traps exits, so
            %% the caller link won't reap it). Stop it explicitly.
            _ = gen_server:stop(Router, normal, 5000),
            {error, Reason}
    end.

build_h2_ssl_opts(Opts) ->
    Base = maps:get(ssl_opts, Opts, []),
    WithVerify =
        case maps:get(verify, Opts, verify_peer) of
            verify_none -> [{verify, verify_none} | Base];
            verify_peer -> [{verify, verify_peer} | Base]
        end,
    WithCACerts =
        case {maps:find(cacertfile, Opts), maps:find(cacerts, Opts)} of
            {{ok, CAFile}, _} ->
                case read_cacerts_file(CAFile) of
                    {ok, CACerts} -> [{cacerts, CACerts} | WithVerify];
                    _ -> WithVerify
                end;
            {_, {ok, CACerts}} -> [{cacerts, CACerts} | WithVerify];
            _ -> WithVerify
        end,
    WithCert =
        case {maps:find(certfile, Opts), maps:find(cert, Opts)} of
            {{ok, CertFile}, _} -> [{certfile, CertFile} | WithCACerts];
            {_, {ok, CertDer}} -> [{cert, CertDer} | WithCACerts];
            _ -> WithCACerts
        end,
    case {maps:find(keyfile, Opts), maps:find(key, Opts)} of
        {{ok, KeyFile}, _} -> [{keyfile, KeyFile} | WithCert];
        {_, {ok, KeyTerm}} -> [{key, KeyTerm} | WithCert];
        _ -> WithCert
    end.

build_h3_connect_opts(Opts) ->
    %% Client picks a compat_mode explicitly; default `latest' (draft-15).
    %% Clients must not auto-probe the server, so the default is a single
    %% disjoint handshake shape.
    CompatMode = case maps:get(compat_mode, Opts, latest) of
        legacy_browser_compat -> legacy_browser_compat;
        _ -> latest
    end,
    WTSettings = wt_h3:default_settings(CompatMode),
    BaseOpts = #{
        settings => WTSettings,
        sync => true,
        connect_timeout => maps:get(timeout, Opts, 30000),
        verify => maps:get(verify, Opts, verify_peer),
        quic_opts => build_client_quic_opts(Opts),
        h3_datagram_enabled => true,
        stream_type_handler => fun
            (uni,  _, 16#54) -> claim;
            (bidi, _, 16#41) -> claim;
            (_, _, _) -> ignore
        end
    },
    %% Handle client certificate if provided
    WithCert = case {maps:find(certfile, Opts), maps:find(cert, Opts)} of
        {{ok, CertFile}, _} ->
            case read_cert_file(CertFile) of
                {ok, CertDer} -> BaseOpts#{cert => CertDer};
                _ -> BaseOpts
            end;
        {_, {ok, CertDer}} ->
            BaseOpts#{cert => CertDer};
        _ ->
            BaseOpts
    end,
    %% Handle client key if provided
    WithKey = case {maps:find(keyfile, Opts), maps:find(key, Opts)} of
        {{ok, KeyFile}, _} ->
            case read_key_file(KeyFile) of
                {ok, KeyTerm} -> WithCert#{key => KeyTerm};
                _ -> WithCert
            end;
        {_, {ok, KeyTerm}} ->
            WithCert#{key => KeyTerm};
        _ ->
            WithCert
    end,
    %% Handle CA certificates if provided
    case {maps:find(cacertfile, Opts), maps:find(cacerts, Opts)} of
        {{ok, CAFile}, _} ->
            case read_cacerts_file(CAFile) of
                {ok, CACerts} -> WithKey#{cacerts => CACerts};
                _ -> WithKey
            end;
        {_, {ok, CACerts}} ->
            WithKey#{cacerts => CACerts};
        _ ->
            WithKey
    end.

%% Build the `quic_opts' map for a client h3 connect. Threads the optional
%% IPv6 / Happy Eyeballs controls and a stored 0-RTT `session_ticket' through
%% to quic:connect/4 alongside the WebTransport transport defaults.
build_client_quic_opts(Opts) ->
    Base = #{
        max_datagram_frame_size => 65535,
        reset_stream_at => true
    },
    PassThrough = [family, happy_eyeballs, connection_attempt_delay, session_ticket],
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Opts) of
            {ok, Value} -> Acc#{Key => Value};
            error -> Acc
        end
    end, Base, PassThrough).

%% Format an HTTP `:authority' from a host (string/binary/IP tuple) and port.
%% IPv6 literals and 8-tuple addresses are bracketed per RFC 3986.
authority(Host, Port) when is_tuple(Host) ->
    authority(inet:ntoa(Host), Port);
authority(Host, Port) when is_list(Host) ->
    authority(list_to_binary(Host), Port);
authority(Host, Port) when is_binary(Host) ->
    PortBin = integer_to_binary(Port),
    case is_ipv6_literal(Host) of
        true -> <<"[", Host/binary, "]:", PortBin/binary>>;
        false -> <<Host/binary, ":", PortBin/binary>>
    end.

%% An IPv6 literal contains a colon and no brackets (a bare host or IPv4
%% literal never does). Already-bracketed input is left as-is.
is_ipv6_literal(<<"[", _/binary>>) -> false;
is_ipv6_literal(Host) -> binary:match(Host, <<":">>) =/= nomatch.

h3_validate_and_request(H3Conn, Authority, Path, Opts, Handler, Router) ->
    CompatMode = maps:get(compat_mode, Opts, latest),
    QuicConn = quic_h3:get_quic_conn(H3Conn),
    case wt_h3:validate_wt_support(H3Conn, QuicConn, CompatMode) of
        ok ->
            h3_send_connect(H3Conn, Authority, Path, Opts, Handler, Router, CompatMode);
        {error, Reason} ->
            quic_h3:close(H3Conn),
            {error, Reason}
    end.

h3_send_connect(H3Conn, Authority, Path, Opts, Handler, Router, CompatMode) ->
    Headers = maps:get(headers, Opts, []),
    case wt_h3:request_session(H3Conn, Authority, Path, Headers, CompatMode) of
        {ok, SessionId} ->
            h3_await_response(H3Conn, SessionId, Authority, Path, Opts, Handler, Router);
        {error, Reason} ->
            quic_h3:close(H3Conn),
            {error, Reason}
    end.

h3_await_response(H3Conn, SessionId, Authority, Path, Opts, Handler, Router) ->
    Timeout = maps:get(timeout, Opts, 30000),
    receive
        {quic_h3, H3Conn, {response, SessionId, Status, Headers}} when Status >= 200, Status < 300 ->
            h3_start_session(H3Conn, SessionId, Authority, Path, Headers, Opts, Handler, Router);
        {quic_h3, H3Conn, {response, SessionId, Status, _Headers}} ->
            quic_h3:close(H3Conn),
            {error, {http_error, Status}};
        %% quic 2.0.0 always reports the reason; older ones send the bare
        %% atom from two of their three close paths.
        {quic_h3, H3Conn, {closed, _Reason}} ->
            {error, connection_closed};
        {quic_h3, H3Conn, closed} ->
            {error, connection_closed}
    after Timeout ->
        quic_h3:close(H3Conn),
        {error, timeout}
    end.

h3_start_session(H3Conn, SessionId, Authority, Path, Headers, Opts, Handler, Router) ->
    TransportState = webtransport_h3:new(H3Conn, SessionId, Router),
    ActualHandler = case Handler of
        undefined -> webtransport_client_handler;
        _ -> Handler
    end,
    Request = #{
        path => Path,
        authority => Authority,
        headers => Headers
    },
    HandlerOpts = maps:get(handler_opts, Opts, #{}),
    SessionOpts = #{
        request => Request,
        is_server => false,
        handler_opts => HandlerOpts
    },
    case webtransport_session:start_link(h3, TransportState, ActualHandler, SessionOpts) of
        {ok, Session} ->
            webtransport_h3_router:register_session(Router, SessionId, Session),
            {ok, Session};
        {error, _} = Err ->
            %% Session failed to start after a successful CONNECT. Closing the
            %% H3 connection makes the router stop via its h3_conn monitor, so
            %% neither the connection nor the router is left dangling.
            quic_h3:close(H3Conn),
            Err
    end.

%% ============================================================================
%% Handler Factories
%% ============================================================================

make_h2_handler(Handler, HandlerOpts, Opts) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        handle_h2_request(Conn, StreamId, Method, Path, Headers, Handler, HandlerOpts, Opts)
    end.

make_h3_handler(Handler, HandlerOpts, Opts, Router) ->
    fun(H3Conn, StreamId, Method, Path, Headers) ->
        handle_h3_request(H3Conn, StreamId, Method, Path, Headers,
                          Handler, HandlerOpts, Opts, Router)
    end.

wt_stream_type_handler() ->
    fun
        (uni,  _StreamId, 16#54) -> claim;
        (bidi, _StreamId, 16#41) -> claim;
        (_, _, _) -> ignore
    end.

%% ============================================================================
%% Certificate/Key Helpers
%% ============================================================================

%% @private Read and decode certificate and private key files.
read_cert_and_key(CertFile, KeyFile) ->
    case {file:read_file(CertFile), file:read_file(KeyFile)} of
        {{ok, CertPem}, {ok, KeyPem}} ->
            case public_key:pem_decode(CertPem) of
                [{_, CertDer, _} | _] ->
                    case decode_private_key(KeyPem) of
                        {ok, PrivateKey} ->
                            {ok, CertDer, PrivateKey};
                        {error, Reason} ->
                            {error, {key_decode_failed, Reason}}
                    end;
                [] ->
                    {error, invalid_certificate}
            end;
        {{error, CertErr}, _} ->
            {error, {cert_read_failed, CertErr}};
        {_, {error, KeyErr}} ->
            {error, {key_read_failed, KeyErr}}
    end.

%% @private Decode a PEM-encoded private key.
decode_private_key(PemData) ->
    case public_key:pem_decode(PemData) of
        [{Type, Der, not_encrypted}] ->
            decode_key_entry(Type, Der);
        [{Type, Der, _Cipher}] ->
            decode_key_entry(Type, Der);
        _ ->
            {error, invalid_private_key}
    end.

decode_key_entry('RSAPrivateKey', Der) ->
    {ok, public_key:der_decode('RSAPrivateKey', Der)};
decode_key_entry('ECPrivateKey', Der) ->
    {ok, public_key:der_decode('ECPrivateKey', Der)};
decode_key_entry('PrivateKeyInfo', Der) ->
    {ok, public_key:der_decode('PrivateKeyInfo', Der)};
decode_key_entry(Type, _Der) ->
    {error, {unsupported_key_type, Type}}.

%% @private Read a single certificate from a PEM file.
read_cert_file(CertFile) ->
    case file:read_file(CertFile) of
        {ok, PemData} ->
            case public_key:pem_decode(PemData) of
                [{_, CertDer, _} | _] -> {ok, CertDer};
                [] -> {error, invalid_certificate}
            end;
        {error, Reason} ->
            {error, {cert_read_failed, Reason}}
    end.

%% @private Read a private key from a PEM file.
read_key_file(KeyFile) ->
    case file:read_file(KeyFile) of
        {ok, PemData} ->
            decode_private_key(PemData);
        {error, Reason} ->
            {error, {key_read_failed, Reason}}
    end.

%% @private Read CA certificates from a PEM file.
read_cacerts_file(CAFile) ->
    case file:read_file(CAFile) of
        {ok, PemData} ->
            Certs = [Der || {_, Der, _} <- public_key:pem_decode(PemData)],
            case Certs of
                [] -> {error, no_certificates};
                _ -> {ok, Certs}
            end;
        {error, Reason} ->
            {error, {cacerts_read_failed, Reason}}
    end.
