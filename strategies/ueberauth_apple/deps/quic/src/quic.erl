%%% -*- erlang -*-
%%%
%%% Pure Erlang QUIC implementation
%%% RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC public API.
%%%
%%% This module provides the public interface for QUIC connections.
%%% The API is compatible with hackney_quic for drop-in replacement.
%%%
%%% == Messages ==
%%%
%%% Messages sent to owner process (Conn is the connection pid):
%%% <ul>
%%%   <li>`{quic, Conn, {connected, Info}}' - Connection established</li>
%%%   <li>`{quic, Conn, {stream_opened, StreamId}}' - Stream opened</li>
%%%   <li>`{quic, Conn, {closed, Reason}}' - Connection closed</li>
%%%   <li>`{quic, Conn, {error, Reason}}' - Handshake failed, e.g.
%%%       `{certificate_invalid, _}'</li>
%%%   <li>`{quic, Conn, {transport_error, Code, Reason}}' - Transport error</li>
%%%   <li>`{quic, Conn, {stream_data, StreamId, Bin, Fin}}' - Data received</li>
%%%   <li>`{quic, Conn, {stream_reset, StreamId, ErrorCode}}' - Stream reset</li>
%%%   <li>`{quic, Conn, {stop_sending, StreamId, ErrorCode}}' - Stop sending</li>
%%%   <li>`{quic, Conn, {goaway, LastStreamId, ErrorCode, Debug}}' - GoAway received</li>
%%%   <li>`{quic, Conn, {session_ticket, Ticket}}' - Session ticket for 0-RTT</li>
%%%   <li>`{quic, Conn, {send_ready, StreamId}}' - Stream ready to write</li>
%%%   <li>`{quic, Conn, {timer, NextTimeoutMs}}' - Timer notification</li>
%%%   <li>`{quic, Conn, {datagram, Data}}' - Datagram received (RFC 9221)</li>
%%%   <li>`{quic, Conn, {stream_deadline, StreamId}}' - Stream deadline expired</li>
%%% </ul>
%%%

-module(quic).

-include("quic.hrl").

%% Send queue information for backpressure decisions.
%% Used by distribution controllers and other high-level protocols
%% to implement backpressure based on congestion state.
%% Exported for pattern matching by consumers.
-type send_queue_info() :: #{
    %% Bytes currently queued
    bytes := non_neg_integer(),
    %% Congestion window size
    cwnd := non_neg_integer(),
    %% Bytes sent but not acked
    in_flight := non_neg_integer(),
    %% Currently in recovery mode
    in_recovery := boolean(),
    %% Whether backpressure should apply
    congested := boolean()
}.

%% Export the send_queue_info type for external use
-export_type([send_queue_info/0]).

%% Path metrics snapshot for routing decisions (e.g. multipath
%% selection). All RTT values are in microseconds. `min_rtt' is `0'
%% before any RTT sample has been taken (i.e. before the handshake
%% provides one); callers should treat `min_rtt =:= 0' as "no sample
%% yet".
-type path_stats() :: #{
    srtt := non_neg_integer(),
    latest_rtt := non_neg_integer(),
    min_rtt := non_neg_integer(),
    rtt_var := non_neg_integer(),
    cwnd := non_neg_integer(),
    bytes_in_flight := non_neg_integer(),
    in_recovery := boolean(),
    congested := boolean()
}.

-export_type([path_stats/0]).

-export([
    connect/4,
    close/1,
    close/2,
    close/3,
    safe_close/1,
    safe_close/2,
    safe_close/3,
    open_stream/1,
    open_unidirectional_stream/1,
    send_data/4,
    send_data/5,
    send_data_async/4,
    %% Receive credit
    set_stream_flow_control/3,
    consume/3,
    reset_stream/3,
    reset_stream_at/4,
    stop_sending/3,
    handle_timeout/2,
    process/1,
    peername/1,
    sockname/1,
    peercert/1,
    set_owner/2,
    set_owner_sync/2,
    send_datagram/2,
    datagram_max_size/1,
    datagram_stats/1,
    setopts/2,
    migrate/1,
    migrate/2,
    %% Stream prioritization (RFC 9218)
    set_stream_priority/4,
    get_stream_priority/2,
    %% Congestion control
    set_congestion_control/2,
    %% Stream deadlines
    set_stream_deadline/3,
    set_stream_deadline/4,
    cancel_stream_deadline/2,
    get_stream_deadline/2,
    %% Congestion/backpressure status
    get_send_queue_info/1,
    %% Path metrics (RTT + congestion control snapshot)
    get_path_stats/1,
    %% Connection statistics for liveness detection
    get_stats/1,
    %% 0-RTT accessors (RFC 9001 §4.6)
    has_early_keys/1,
    early_data_accepted/1,
    %% Transport-level PING (bypasses congestion control)
    send_ping/1,
    %% PMTU Discovery (RFC 8899)
    get_mtu/1,
    %% Peer transport parameters
    get_peer_transport_params/1
]).

%% Server management API
-export([
    start_server/3,
    stop_server/1,
    server_spec/3,
    get_server_info/1,
    get_server_port/1,
    get_server_sockname/1,
    get_server_connections/1,
    which_servers/0
]).

-export([is_available/0, get_fd/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Check if QUIC support is available.
%% Always returns true for pure Erlang implementation.
-spec is_available() -> boolean().
is_available() ->
    %% Check that required crypto algorithms are available
    try
        Algos = crypto:supports(),
        Ciphers = proplists:get_value(ciphers, Algos, []),
        Macs = proplists:get_value(macs, Algos, []),
        HasAES =
            lists:member(aes_128_gcm, Ciphers) orelse
                lists:member(aes_gcm, Ciphers),
        HasSHA256 = lists:member(hmac, Macs),
        HasAES andalso HasSHA256
    catch
        _:_ -> false
    end.

%% @doc Get the file descriptor from a gen_udp socket.
%% This can be used to pass an existing UDP socket to connect/4
%% via the `socket_fd' option.
-spec get_fd(gen_udp:socket()) -> {ok, integer()} | {error, term()}.
get_fd(Socket) ->
    case inet:getfd(Socket) of
        {ok, Fd} -> {ok, Fd};
        Error -> Error
    end.

%% @doc Connect to a QUIC server.
%% Returns {ok, Conn} on success where Conn is a pid(). `Host' may be a
%% hostname, an IP-literal string (IPv4 or IPv6, optionally bracketed),
%% or an `inet:ip_address()' tuple.
%% The owner process will receive {quic, Conn, {connected, Info}}
%% when the connection is established.
%%
%% For a hostname that resolves to both IPv4 and IPv6 addresses, RFC 8305
%% Happy Eyeballs is used: the addresses are raced IPv6-first and the
%% first to complete its handshake is returned. In that case `connect/4'
%% blocks until the first attempt connects (or all fail / time out); a
%% single address, IP literal/tuple, or pre-opened `socket' keeps the
%% immediate, asynchronous return.
%%
%% Options:
%% <ul>
%%   <li>`happy_eyeballs' - Race IPv6/IPv4 for multi-address hostnames
%%       (default: `true'). `false' forces the legacy IPv4-first resolver.</li>
%%   <li>`family' - `inet | inet6 | any' (default `any'); restricts
%%       resolution to one address family.</li>
%%   <li>`connection_attempt_delay' - RFC 8305 stagger between attempts in
%%       milliseconds (default: 250).</li>
%%   <li>`connect_timeout' - Overall Happy Eyeballs deadline in
%%       milliseconds (default: 5000).</li>
%%   <li>`socket' - Use an existing UDP socket (gen_udp:socket())</li>
%%   <li>`extra_socket_opts' - Options for socket creation (e.g., [{ip, Addr}])</li>
%%   <li>`socket_backend' - `gen_udp' (default), `socket' (OTP NIF) or
%%       `adapter' (caller-supplied datagram callbacks)</li>
%%   <li>`socket_adapter' - Required when `socket_backend = adapter'.
%%       Map with `send_fun => fun((IP, Port, Packet) -> ok | {error,_})'
%%       and optional `close_fun', `local'. Inbound packets must be
%%       delivered to the owning connection as `{udp, Socket, IP, Port,
%%       Data}' messages. `send_fun' runs in the connection process, so
%%       `self()' inside it is the connection pid: capture it there to learn
%%       the delivery target from the first outbound packet (the ClientHello).
%%       Waiting for `connect/4' to return the pid races the handshake's first
%%       flight, so the peer's reply can be dropped before the return path is
%%       wired up (most visible with 0-RTT/PSK, where retransmits do not mask
%%       it).</li>
%%   <li>`verify' - Validate the server certificate chain, signature
%%       and hostname (default: `true'). Set to `false' to skip
%%       validation (e.g. self-signed test servers).</li>
%%   <li>`cacerts' - Trust anchors as a list of DER-encoded CA
%%       certificates. Defaults to the OS trust store.</li>
%%   <li>`cacertfile' - Path to a PEM file holding those anchors, read
%%       once here. A file that cannot be read, or that holds no
%%       certificate, fails the call rather than falling back to the OS
%%       store. Ignored when `cacerts' is given.</li>
%%   <li>`cert' - DER-encoded client certificate, for mutual TLS</li>
%%   <li>`key' - Decoded private key for `cert'. One that cannot sign for
%%       the certificate is refused with `{error, {invalid_client_key, _}}'.</li>
%%   <li>`alpn' - ALPN protocols (default: [&lt;&lt;"h3"&gt;&gt;])</li>
%%   <li>`server_name' - Server Name Indication, also the hostname
%%       checked against the certificate (default: Host)</li>
%%   <li>`external_psk' - TLS 1.3 external PSK (RFC 8446 §4.2.11).
%%       `{Identity, Secret}' defaults to modes `[psk_dhe_ke]';
%%       `{Identity, Secret, Modes}' takes an explicit non-empty
%%       list (`psk_dhe_ke | psk_ke'). Mutually exclusive with
%%       `session_ticket'. See docs/PSK.md.</li>
%%   <li>`groups' - key-exchange groups in preference order
%%       (`x25519 | secp256r1 | secp384r1'; default `[x25519]').
%%       The head gets a `key_share'; the rest are HelloRetryRequest
%%       eligible.</li>
%%   <li>`signature_algs' - advertised signature schemes
%%       (`ecdsa_secp256r1_sha256 | ecdsa_secp384r1_sha384 |
%%       rsa_pss_rsae_sha256|384|512 | ed25519 | rsa_pkcs1_sha256').
%%       Defaults to the historical wire list.</li>
%% </ul>
-spec connect(Host, Port, Opts, Owner) -> {ok, pid()} | {error, term()} when
    Host :: binary() | string() | inet:ip_address(),
    Port :: inet:port_number(),
    Opts :: map(),
    Owner :: pid().
connect(Host, Port, Opts, Owner) when is_list(Host) ->
    connect(list_to_binary(Host), Port, Opts, Owner);
connect(Host, Port, Opts, Owner) when
    is_binary(Host), is_integer(Port), Port > 0, Port =< 65535, is_map(Opts), is_pid(Owner);
    is_tuple(Host),
    tuple_size(Host) =:= 4,
    is_integer(Port),
    Port > 0,
    Port =< 65535,
    is_map(Opts),
    is_pid(Owner);
    is_tuple(Host),
    tuple_size(Host) =:= 8,
    is_integer(Port),
    Port > 0,
    Port =< 65535,
    is_map(Opts),
    is_pid(Owner)
->
    %% Extract socket option for pre-opened socket support
    Socket = maps:get(socket, Opts, undefined),
    case validate_client_opts(Socket, Opts) of
        ok -> dial(Host, Port, Opts, Owner, Socket);
        {error, _} = Error -> Error
    end;
connect(_Host, _Port, _Opts, _Owner) ->
    {error, badarg}.

%% Resolution (and RFC 8305 Happy Eyeballs for hostnames) runs in the
%% caller process so a resolution failure returns {error, _} instead of
%% crashing the caller via the start_link.
dial(Host, Port, Opts, Owner, Socket) ->
    case quic_cert:resolve_cacerts(Opts) of
        {ok, Opts1} -> quic_happy:connect(Host, Port, Opts1, Owner, Socket);
        {error, _} = Error -> Error
    end.

%% @private All client-side option checks that must run before the
%% connection process is started, so a bad option returns {error, _}
%% to the caller instead of crashing mid-handshake.
validate_client_opts(Socket, Opts) ->
    case validate_groups(Opts) of
        ok ->
            first_error([
                credentials(client, Opts),
                validate_connect_opts(Socket, Opts),
                validate_receive_window(Opts),
                validate_owner_queue(Opts)
            ]);
        {error, _} = Error ->
            Error
    end.

%% A pre-opened `socket' is always a gen_udp handle; requesting the
%% OTP socket NIF backend or the callback adapter at the same time
%% cannot be honoured.
validate_connect_opts(Socket, Opts) when Socket =/= undefined ->
    case maps:get(socket_backend, Opts, gen_udp) of
        socket -> {error, {incompatible_options, [socket, {socket_backend, socket}]}};
        adapter -> {error, {incompatible_options, [socket, {socket_backend, adapter}]}};
        _ -> ok
    end;
validate_connect_opts(undefined, Opts) ->
    case maps:get(socket_backend, Opts, gen_udp) of
        adapter ->
            validate_adapter_opts(maps:get(socket_adapter, Opts, undefined));
        _ ->
            ok
    end.

validate_adapter_opts(undefined) ->
    {error, missing_socket_adapter};
validate_adapter_opts(A) when is_map(A) ->
    case maps:get(send_fun, A, undefined) of
        F when is_function(F, 3) -> ok;
        _ -> {error, badarg_socket_adapter}
    end;
validate_adapter_opts(_) ->
    {error, badarg_socket_adapter}.

%% @doc Close a QUIC connection with normal reason.
-spec close(Conn) -> ok when
    Conn :: pid().
close(Conn) when is_pid(Conn) ->
    close(Conn, normal).

%% @doc Close a QUIC connection with the given reason. An integer is
%% treated as an application error code (RFC 9000 §19.19) and sent
%% verbatim in the CONNECTION_CLOSE frame; any other term keeps its
%% historical pass-through behaviour.
-spec close(Conn, Reason) -> ok when
    Conn :: pid(),
    Reason :: non_neg_integer() | term().
close(Conn, ErrorCode) when
    is_pid(Conn),
    is_integer(ErrorCode),
    ErrorCode >= 0,
    ErrorCode < (1 bsl 62)
->
    quic_connection:close(Conn, {app_error, ErrorCode, <<>>});
close(Conn, Reason) when is_pid(Conn) ->
    quic_connection:close(Conn, Reason).

%% @doc Close a QUIC connection with application error code and reason phrase.
%% ErrorCode is a 62-bit unsigned integer (RFC 9000).
%% Reason is the reason phrase sent in the CONNECTION_CLOSE frame.
-spec close(Conn, ErrorCode, Reason) -> ok when
    Conn :: pid(),
    ErrorCode :: 0..16#3FFFFFFFFFFFFFFF,
    Reason :: binary().
close(Conn, ErrorCode, Reason) when
    is_pid(Conn),
    is_integer(ErrorCode),
    ErrorCode >= 0,
    ErrorCode < (1 bsl 62),
    is_binary(Reason)
->
    quic_connection:close(Conn, {app_error, ErrorCode, Reason}).

%% @doc Close a connection, ignoring any error if it is already gone.
%% For teardown paths that must not crash when the connection has
%% already closed or the pid is dead.
-spec safe_close(Conn) -> ok when
    Conn :: pid().
safe_close(Conn) ->
    try
        close(Conn)
    catch
        _:_ -> ok
    end.

%% @doc Like {@link safe_close/1} with a close reason.
-spec safe_close(Conn, Reason) -> ok when
    Conn :: pid(),
    Reason :: non_neg_integer() | term().
safe_close(Conn, Reason) ->
    try
        close(Conn, Reason)
    catch
        _:_ -> ok
    end.

%% @doc Like {@link safe_close/1} with an application error code and reason phrase.
-spec safe_close(Conn, ErrorCode, Reason) -> ok when
    Conn :: pid(),
    ErrorCode :: 0..16#3FFFFFFFFFFFFFFF,
    Reason :: binary().
safe_close(Conn, ErrorCode, Reason) ->
    try
        close(Conn, ErrorCode, Reason)
    catch
        _:_ -> ok
    end.

%% @doc Open a new bidirectional stream.
%% Returns {ok, StreamId} on success.
-spec open_stream(Conn) -> {ok, non_neg_integer()} | {error, term()} when
    Conn :: pid().
open_stream(Conn) when is_pid(Conn) ->
    quic_connection:open_stream(Conn).

%% @doc Open a new unidirectional stream.
%% Returns {ok, StreamId} on success.
%% Unidirectional streams are send-only for the initiator.
-spec open_unidirectional_stream(Conn) -> {ok, non_neg_integer()} | {error, term()} when
    Conn :: pid().
open_unidirectional_stream(Conn) when is_pid(Conn) ->
    quic_connection:open_unidirectional_stream(Conn).

%% @doc Send data on a stream.
%% Fin indicates if this is the final frame on the stream.
%%
%% Returns `{error, send_queue_full}' when the connection's send queue is
%% already at its ceiling, which is the backpressure signal: the write
%% did not happen, and the caller should let the connection drain and
%% retry rather than treat it as a failure. The ceiling is shared by
%% every stream of the connection.
-spec send_data(Conn, StreamId, Data, Fin) -> ok | {error, send_queue_full | term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    Data :: iodata(),
    Fin :: boolean().
send_data(Conn, StreamId, Data, Fin) when is_pid(Conn) ->
    quic_connection:send_data(Conn, StreamId, Data, Fin).

%% @doc Send data on a stream with a timeout.
%% Fin indicates if this is the final frame on the stream.
%% Timeout is in milliseconds; if the operation takes longer, returns {error, timeout}.
-spec send_data(Conn, StreamId, Data, Fin, Timeout) ->
    ok | {error, send_queue_full | timeout | term()}
when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    Data :: iodata(),
    Fin :: boolean(),
    Timeout :: timeout().
send_data(Conn, StreamId, Data, Fin, Timeout) when is_pid(Conn) ->
    try
        gen_statem:call(Conn, {send_data, StreamId, Data, Fin}, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout}
    end.

%% @doc Send data on a stream asynchronously (fire-and-forget).
%% This is faster than send_data/4 because it uses cast instead of call,
%% avoiding the round-trip latency. However, errors are silently dropped.
%% The send-queue ceiling does not apply: an async write is always queued,
%% so a caller that writes faster than the peer reads grows the queue.
%% Use this for high-throughput scenarios where occasional dropped data is acceptable.
-spec send_data_async(Conn, StreamId, Data, Fin) -> ok when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    Data :: iodata(),
    Fin :: boolean().
send_data_async(Conn, StreamId, Data, Fin) when is_pid(Conn) ->
    quic_connection:send_data_async(Conn, StreamId, Data, Fin).

%% @doc Choose how a stream earns the peer receive credit.
%%
%% `auto' (default) grants credit as data is delivered to the owner,
%% while the owner's mailbox holds no more than `max_owner_queue'
%% messages. `manual' grants it only for the bytes the owner returns
%% with {@link consume/3}, so an owner that stops reading stops the peer
%% after one stream window. Bytes delivered before the switch count as
%% received and are consumed like any other.
%% Returns `{error, unknown_stream}' once the stream is finished or reset.
%%
%% ```
%% {quic, Conn, {stream_opened, StreamId}} ->
%%     ok = quic:set_stream_flow_control(Conn, StreamId, manual)
%% '''
%% @end
-spec set_stream_flow_control(Conn, StreamId, Mode) -> ok | {error, unknown_stream} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    Mode :: auto | manual.
set_stream_flow_control(Conn, StreamId, Mode) when
    is_pid(Conn), Mode =:= auto; is_pid(Conn), Mode =:= manual
->
    quic_connection:stream_flow_control(Conn, StreamId, Mode).

%% @doc Return receive credit on a `manual' stream.
%%
%% Call it after processing `Bytes' received on `StreamId'; the peer may
%% then send up to one stream window past what was consumed. A no-op
%% returning `ok' on an `auto' stream. Returns `{error, unknown_stream}'
%% once the stream is finished or reset.
%%
%% ```
%% {quic, Conn, {stream_data, StreamId, Data, _Fin}} ->
%%     handle(Data),
%%     ok = quic:consume(Conn, StreamId, byte_size(Data))
%% '''
%% @end
-spec consume(Conn, StreamId, Bytes) -> ok | {error, unknown_stream} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    Bytes :: non_neg_integer().
consume(Conn, StreamId, Bytes) when is_pid(Conn), is_integer(Bytes), Bytes >= 0 ->
    quic_connection:consume(Conn, StreamId, Bytes).

%% @doc Reset a stream with an error code.
-spec reset_stream(Conn, StreamId, ErrorCode) -> ok | {error, term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    ErrorCode :: non_neg_integer().
reset_stream(Conn, StreamId, ErrorCode) when is_pid(Conn) ->
    quic_connection:reset_stream(Conn, StreamId, ErrorCode).

%% @doc Reset a stream with reliable delivery up to specified size.
%% Data up to ReliableSize will be delivered before the reset takes effect.
%% Requires peer support for the reliable stream reset extension
%% (draft-ietf-quic-reliable-stream-reset-07).
%% ReliableSize must be less than or equal to the amount of data already sent.
-spec reset_stream_at(Conn, StreamId, ErrorCode, ReliableSize) ->
    ok | {error, term()}
when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    ErrorCode :: non_neg_integer(),
    ReliableSize :: non_neg_integer().
reset_stream_at(Conn, StreamId, ErrorCode, ReliableSize) when is_pid(Conn) ->
    quic_connection:reset_stream_at(Conn, StreamId, ErrorCode, ReliableSize).

%% @doc Request peer to stop sending on a stream.
%% Sends a STOP_SENDING frame (RFC 9000 Section 19.5).
-spec stop_sending(Conn, StreamId, ErrorCode) -> ok | {error, term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    ErrorCode :: non_neg_integer().
stop_sending(Conn, StreamId, ErrorCode) when is_pid(Conn) ->
    quic_connection:stop_sending(Conn, StreamId, ErrorCode).

%% @doc Handle connection timeout.
%% Should be called when timer expires.
%% Returns next timeout in ms or 'infinity'.
-spec handle_timeout(Conn, NowMs) -> non_neg_integer() | infinity when
    Conn :: pid(),
    NowMs :: non_neg_integer().
handle_timeout(Conn, NowMs) when is_pid(Conn) ->
    quic_connection:handle_timeout(Conn, NowMs).

%% @doc Process pending QUIC events.
%% This is called automatically by the connection process.
-spec process(Conn) -> ok when
    Conn :: pid().
process(Conn) when is_pid(Conn) ->
    quic_connection:process(Conn).

%% @doc Get the remote address of the connection.
-spec peername(Conn) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()} when
    Conn :: pid().
peername(Conn) when is_pid(Conn) ->
    quic_connection:peername(Conn).

%% @doc Get the local address of the connection.
-spec sockname(Conn) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()} when
    Conn :: pid().
sockname(Conn) when is_pid(Conn) ->
    quic_connection:sockname(Conn).

%% @doc Get the peer certificate.
%% Returns the DER-encoded certificate of the peer if available.
-spec peercert(Conn) -> {ok, binary()} | {error, term()} when
    Conn :: pid().
peercert(Conn) when is_pid(Conn) ->
    quic_connection:peercert(Conn).

%% @doc Set the owner process for a connection.
%% Similar to gen_tcp:controlling_process/2.
-spec set_owner(Conn, NewOwner) -> ok | {error, term()} when
    Conn :: pid(),
    NewOwner :: pid().
set_owner(Conn, NewOwner) when is_pid(Conn), is_pid(NewOwner) ->
    quic_connection:set_owner(Conn, NewOwner).

%% @doc Set the owner process for a connection (synchronous).
%% Use this when you need to ensure ownership is transferred before continuing.
-spec set_owner_sync(Conn, NewOwner) -> ok | {error, term()} when
    Conn :: pid(),
    NewOwner :: pid().
set_owner_sync(Conn, NewOwner) when is_pid(Conn), is_pid(NewOwner) ->
    quic_connection:set_owner_sync(Conn, NewOwner).

%% @doc Send a datagram on the connection.
%% Datagrams are unreliable and may be lost.
-spec send_datagram(Conn, Data) -> ok | {error, term()} when
    Conn :: pid(),
    Data :: iodata().
send_datagram(Conn, Data) when is_pid(Conn) ->
    quic_connection:send_datagram(Conn, Data).

%% @doc Get maximum datagram payload size.
%% Returns 0 if peer doesn't support datagrams (RFC 9221).
%% The returned size is the peer's advertised max_datagram_frame_size.
-spec datagram_max_size(Conn) -> non_neg_integer() | {error, term()} when
    Conn :: pid().
datagram_max_size(Conn) when is_pid(Conn) ->
    quic_connection:datagram_max_size(Conn).

%% @doc Get datagram accounting counters.
%% Returns delivered / dropped_recv / sent / dropped_send counters.
%% `dropped_recv' counts DATAGRAMs dropped because the owner's mailbox
%% held more than `max_owner_queue' messages, or because a finite
%% `datagram_recv_queue_len' was full.
-spec datagram_stats(Conn) ->
    #{
        delivered := non_neg_integer(),
        dropped_recv := non_neg_integer(),
        sent := non_neg_integer(),
        dropped_send := non_neg_integer()
    }
when
    Conn :: pid().
datagram_stats(Conn) when is_pid(Conn) ->
    quic_connection:datagram_stats(Conn).

%% @doc Set connection options.
-spec setopts(Conn, Opts) -> ok | {error, term()} when
    Conn :: pid(),
    Opts :: [{atom(), term()}].
setopts(Conn, Opts) when is_pid(Conn), is_list(Opts) ->
    quic_connection:setopts(Conn, Opts).

%% @doc Trigger connection migration to a new local address.
%% This initiates path validation on a new network path.
%% The connection will send PATH_CHALLENGE and wait for PATH_RESPONSE.
%%
%% Returns `{error, no_available_connection_id}' when the peer has not
%% supplied a connection ID that is unused on another path. RFC 9000
%% Section 9.5 forbids reusing one, so migrating is not possible until the
%% peer issues another. The first spare arrives shortly after the
%% connection is established, so a migration attempted immediately can
%% fail and succeed on retry.
-spec migrate(Conn) -> ok | {error, term()} when
    Conn :: pid().
migrate(Conn) when is_pid(Conn) ->
    quic_connection:migrate(Conn).

%% @doc Trigger connection migration with options.
%% This initiates path validation on a new network path.
%% The connection will send PATH_CHALLENGE and wait for PATH_RESPONSE.
%%
%% Options:
%% <ul>
%%   <li>`timeout' - Timeout in milliseconds for the gen_statem call (default: 5000)</li>
%% </ul>
-spec migrate(Conn, Opts) -> ok | {error, term()} when
    Conn :: pid(),
    Opts :: #{timeout => pos_integer()}.
migrate(Conn, Opts) when is_pid(Conn), is_map(Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    quic_connection:migrate(Conn, Timeout).

%% @doc Set the congestion control algorithm for a connection.
%% This changes the algorithm on a live connection.
%% The new algorithm starts fresh (cwnd, ssthresh reset to defaults).
%% Only works in connected state.
%%
%% Algorithm: newreno | bbr | cubic
-spec set_congestion_control(Conn, Algorithm) -> ok | {error, term()} when
    Conn :: pid(),
    Algorithm :: newreno | bbr | cubic.
set_congestion_control(Conn, Algorithm) when is_pid(Conn) ->
    quic_connection:set_congestion_control(Conn, Algorithm).

%% @doc Set the priority for a stream.
%% Urgency: 0-7 (lower = more urgent, default 3)
%% Incremental: boolean (data can be processed incrementally, default false)
%% Per RFC 9218 (Extensible Priorities for HTTP).
-spec set_stream_priority(Conn, StreamId, Urgency, Incremental) -> ok | {error, term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    Urgency :: 0..7,
    Incremental :: boolean().
set_stream_priority(Conn, StreamId, Urgency, Incremental) when is_pid(Conn) ->
    quic_connection:set_stream_priority(Conn, StreamId, Urgency, Incremental).

%% @doc Get the priority for a stream.
%% Returns {ok, {Urgency, Incremental}} or {error, not_found}.
-spec get_stream_priority(Conn, StreamId) -> {ok, {0..7, boolean()}} | {error, term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer().
get_stream_priority(Conn, StreamId) when is_pid(Conn) ->
    quic_connection:get_stream_priority(Conn, StreamId).

%% @doc Set a deadline for a stream.
%% TimeoutMs is the number of milliseconds from now until the deadline expires.
%% When the deadline expires, the stream will be reset and/or the owner will be notified.
%% Default action is 'both' (notify + reset).
-spec set_stream_deadline(Conn, StreamId, TimeoutMs) -> ok | {error, term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    TimeoutMs :: pos_integer().
set_stream_deadline(Conn, StreamId, TimeoutMs) ->
    set_stream_deadline(Conn, StreamId, TimeoutMs, #{}).

%% @doc Set a deadline for a stream with options.
%% TimeoutMs is the number of milliseconds from now until the deadline expires.
%%
%% Options:
%% - `action': What to do when deadline expires:
%%   - `notify': Send `{quic, Conn, {stream_deadline, StreamId}}' to owner
%%   - `reset': Send RESET_STREAM and clean up
%%   - `both' (default): Notify AND reset
%% - `error_code': Error code for RESET_STREAM (default: 16#FF)
-spec set_stream_deadline(Conn, StreamId, TimeoutMs, Opts) -> ok | {error, term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer(),
    TimeoutMs :: pos_integer(),
    Opts :: #{action => reset | notify | both, error_code => non_neg_integer()}.
set_stream_deadline(Conn, StreamId, TimeoutMs, Opts) when is_pid(Conn) ->
    quic_connection:set_stream_deadline(Conn, StreamId, TimeoutMs, Opts).

%% @doc Cancel a stream deadline.
%% Returns ok if the deadline was cancelled, or {error, not_found} if no deadline exists.
-spec cancel_stream_deadline(Conn, StreamId) -> ok | {error, term()} when
    Conn :: pid(),
    StreamId :: non_neg_integer().
cancel_stream_deadline(Conn, StreamId) when is_pid(Conn) ->
    quic_connection:cancel_stream_deadline(Conn, StreamId).

%% @doc Get the remaining time for a stream deadline.
%% Returns {ok, {RemainingMs, Action}} where RemainingMs is milliseconds until expiry.
%% Returns {error, no_deadline} if no deadline is set.
-spec get_stream_deadline(Conn, StreamId) ->
    {ok, {non_neg_integer() | infinity, reset | notify | both}} | {error, term()}
when
    Conn :: pid(),
    StreamId :: non_neg_integer().
get_stream_deadline(Conn, StreamId) when is_pid(Conn) ->
    quic_connection:get_stream_deadline(Conn, StreamId).

%% @doc Get send queue information for a connection.
%% This can be used by distribution controllers or other high-level
%% protocols to implement backpressure based on queue state.
%%
%% Returns a map with:
%% - `bytes': Current bytes in send queue
%% - `cwnd': Congestion window size
%% - `in_flight': Bytes sent but not acknowledged
%% - `in_recovery': Whether in congestion recovery
%% - `congested': Whether backpressure should be applied
%%
%% See `quic_dist_controller' for usage example.
-spec get_send_queue_info(Conn) -> {ok, send_queue_info()} | {error, term()} when
    Conn :: pid().
get_send_queue_info(Conn) when is_pid(Conn) ->
    quic_connection:get_send_queue_info(Conn).

%% @doc Return a snapshot of the connection's path metrics.
%%
%% The map combines RTT estimates from `quic_loss' with congestion
%% control state from `quic_cc'. Intended for routing layers that need
%% per-connection path quality without poking at internal records via
%% `sys:get_state/1'.
%%
%% Returns `{error, not_connected}' if the connection has not yet
%% completed the handshake.
-spec get_path_stats(Conn) -> {ok, path_stats()} | {error, term()} when
    Conn :: pid().
get_path_stats(Conn) when is_pid(Conn) ->
    quic_connection:get_path_stats(Conn).

%% @doc Get connection statistics for liveness detection.
%%
%% Returns packet counts that can be used by net_kernel for tick checking.
%% Any QUIC packet (ACK, PING, data) counts as proof of peer liveness.
%%
%% Returns a map with:
%% - `packets_received': Total QUIC packets successfully received
%% - `packets_sent': Total QUIC packets sent
%% - `data_received': Total bytes of application data received
%% - `data_sent': Total bytes of application data sent
%% - `send_queue_full_refusals': Writes refused with `send_queue_full'
%%
%% See `quic_dist_controller' for usage in distribution tick checking.
-spec get_stats(Conn) -> {ok, map()} | {error, term()} when
    Conn :: pid().
get_stats(Conn) when is_pid(Conn) ->
    quic_connection:get_stats(Conn).

%% @doc Returns whether the connection has derived early keys (i.e. a
%% session ticket was provided and 0-RTT is possible). Used by the H3
%% layer to choose between the fresh-handshake and 0-RTT paths.
-spec has_early_keys(Conn) -> boolean() when
    Conn :: pid().
has_early_keys(Conn) when is_pid(Conn) ->
    quic_connection:has_early_keys(Conn).

%% @doc Returns whether the server accepted early data, or `unknown' if
%% the handshake has not yet completed. Use after the connection enters
%% the connected state to confirm 0-RTT was actually used.
-spec early_data_accepted(Conn) -> boolean() | unknown when
    Conn :: pid().
early_data_accepted(Conn) when is_pid(Conn) ->
    quic_connection:early_data_accepted(Conn).

%% @doc Send a PING frame on the connection.
%%
%% PING frames are transport-level frames that bypass congestion control.
%% They elicit an ACK from the peer and can be used for liveness checking.
%% This is useful for distribution tick messages that must get through
%% even when the connection is congested.
%%
%% Returns `ok' if the PING was sent, or `{error, Reason}' if it failed.
-spec send_ping(Conn) -> ok | {error, term()} when
    Conn :: pid().
send_ping(Conn) when is_pid(Conn) ->
    quic_connection:send_ping(Conn).

%% @doc Get the current MTU for a connection.
%%
%% Returns the effective MTU discovered via DPLPMTUD (RFC 8899).
%% The MTU starts at 1200 bytes (QUIC minimum) and is probed up
%% to the peer's max_udp_payload_size or local configuration.
%%
%% Returns `{ok, MTU}' where MTU is the current maximum packet size,
%% or `{error, not_found}' if the connection doesn't exist.
-spec get_mtu(Conn) -> {ok, pos_integer()} | {error, term()} when
    Conn :: pid().
get_mtu(Conn) when is_pid(Conn) ->
    quic_connection:get_mtu(Conn).

%% @doc Get the peer's transport parameters.
%%
%% Returns the transport parameters received from the peer during handshake.
%% Useful for verifying peer capabilities such as WebTransport support
%% (e.g., checking for `reset_stream_at' transport parameter).
%%
%% Returns `{ok, TransportParams}' where TransportParams is a map of
%% the peer's advertised transport parameters.
-spec get_peer_transport_params(Conn) -> {ok, map()} | {error, term()} when
    Conn :: pid().
get_peer_transport_params(Conn) when is_pid(Conn) ->
    quic_connection:get_peer_transport_params(Conn).

%%====================================================================
%% Server Management API
%%====================================================================

%% @doc Start a named QUIC server on the specified port.
%%
%% Creates a listener pool that accepts incoming QUIC connections.
%% Multiple named servers can run on different ports.
%%
%% At least one authentication method must be configured: either a
%% `cert' + `key' pair for X.509 auth, or `psks' / `psk_callback' for
%% TLS 1.3 external PSK (RFC 8446 §4.2.11). Both may coexist; the
%% per-handshake selection rules are documented in docs/PSK.md.
%% Without either, this returns `{error, no_auth_method}': QUIC has no
%% unauthenticated mode (RFC 9001 §3).
%%
%% Options:
%% <ul>
%%   <li>`cert' - DER-encoded certificate</li>
%%   <li>`key' - Decoded private key for `cert', as
%%       `public_key:pem_entry_decode/1' returns it. One that cannot sign for
%%       the certificate is refused with `{error, {invalid_server_key, _}}'.</li>
%%   <li>`verify' - Request a client certificate (mutual TLS) and validate any
%%       presented chain against `cacerts' (RFC 8446 §4.4.2.4). Optional by
%%       default: a client that sends no certificate still connects.</li>
%%   <li>`cacerts' - Trust anchors (list of DER CA certs) for validating a
%%       client certificate; `undefined' uses the OS trust store.</li>
%%   <li>`cacertfile' - Path to a PEM file holding those anchors, read once
%%       at start. A file that cannot be read, or that holds no certificate,
%%       fails the start. Ignored when `cacerts' is given.</li>
%%   <li>`require_client_cert' - With `verify', reject a client that presents
%%       no certificate (`certificate_required') instead of accepting it,
%%       making mutual TLS mandatory (default `false').</li>
%%   <li>`psks' - `#{Identity :: binary() => Secret :: binary()}'
%%       static PSK table</li>
%%   <li>`psk_callback' - `fun((Identity :: binary()) -> {ok, Secret} | not_found)';
%%       takes precedence over `psks'</li>
%%   <li>`alpn' - List of ALPN protocols (default: [&lt;&lt;"h3"&gt;&gt;])</li>
%%   <li>`groups' - accepted key-exchange groups in preference order
%%       (`x25519 | secp256r1 | secp384r1'; default `[x25519]'). When
%%       the client's `key_share' matches none of these but a
%%       `supported_groups' entry does, the server sends a
%%       HelloRetryRequest.</li>
%%   <li>`signature_algs' - accepted/advertised signature schemes; the
%%       CertificateVerify scheme is the server's first choice the
%%       client also offered. `rsa_pkcs1_*' is never selected for
%%       CertificateVerify (RFC 8446 §4.4.3).</li>
%%   <li>`pool_size' - Number of listener processes (default: 1)</li>
%%   <li>`connection_handler' - `fun((Conn) -> {ok, HandlerPid})'.
%%       `HandlerPid' becomes the connection's owner, and so receives its
%%       `{quic, Conn, _}' events, before the connection sees its first
%%       packet. Return the process that will consume those events, not a
%%       broker that hands off later; see the ownership rules in
%%       `quic_listener'.</li>
%%   <li>`sni_callback' -
%%       `fun((ServerName :: binary() | undefined) -> {ok, CertMap} | {error, term()})'
%%       where `CertMap :: #{cert := binary(), key := term(), cert_chain => [binary()]}'.
%%       Invoked per connection with the ClientHello SNI (RFC 6066 §3);
%%       the returned cert/key override the static `cert'/`key' for that
%%       handshake. `cert'/`key' may be omitted when this is set. An
%%       `{error, _}', a malformed result, or a raised exception fails the
%%       handshake with a `handshake_failure' alert.</li>
%% </ul>
%%
%% Example:
%% ```
%% {ok, _} = quic:start_server(my_server, 4433, #{
%%     cert => CertDer,
%%     key => KeyTerm,
%%     alpn => [<<"h3">>],
%%     pool_size => 4
%% }).
%% '''
-spec start_server(Name, Port, Opts) -> {ok, pid()} | {error, term()} when
    Name :: atom(),
    Port :: inet:port_number(),
    Opts :: map().
start_server(Name, Port, Opts) when
    is_atom(Name),
    is_integer(Port),
    Port >= 0,
    Port =< 65535,
    is_map(Opts)
->
    case validate_server_opts(Opts) of
        ok ->
            case quic_cert:resolve_cacerts(Opts) of
                {ok, Opts1} -> quic_server_sup:start_server(Name, Port, Opts1);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end;
start_server(_Name, _Port, _Opts) ->
    {error, badarg}.

%% @private All listener option checks that must run before the
%% listener pool is started, so a bad option returns {error, _} to the
%% caller instead of taking the pool down after it has been created.
validate_server_opts(Opts) ->
    case validate_groups(Opts) of
        ok ->
            first_error([
                quic_listener:has_auth_method(Opts),
                credentials(server, Opts),
                validate_receive_window(Opts),
                validate_owner_queue(Opts)
            ]);
        {error, _} = Error ->
            Error
    end.

%% @private A key that cannot sign for its certificate fails every
%% handshake, so it is refused up front rather than on each connection.
credentials(Role, Opts) ->
    quic_connection:check_credentials(Role, Opts).

first_error(Results) ->
    case [E || {error, _} = E <- Results] of
        [] -> ok;
        [Error | _] -> Error
    end.

%% @private The receive window grows up to `max_receive_window'; one too
%% small to hold a few packets leaves the peer unable to make progress.
validate_receive_window(Opts) ->
    case maps:find(max_receive_window, Opts) of
        error -> ok;
        {ok, W} when is_integer(W), W >= ?MIN_RECEIVE_WINDOW -> ok;
        {ok, W} -> {error, {invalid_max_receive_window, W}}
    end.

%% @private `max_owner_queue' is a message count or `infinity'.
validate_owner_queue(Opts) ->
    case maps:find(max_owner_queue, Opts) of
        error -> ok;
        {ok, infinity} -> ok;
        {ok, N} when is_integer(N), N > 0 -> ok;
        {ok, N} -> {error, {invalid_max_owner_queue, N}}
    end.

%% @private Reject a `groups' option naming a key-exchange group this
%% runtime cannot perform, up front with a clean error, rather than
%% crashing later inside crypto:generate_key/2 during the handshake.
%% The hybrid x25519mlkem768 group needs ML-KEM-768 support in crypto
%% (OTP 28.1+); on older OTP releases group_supported/1 returns false.
%% An explicit `groups' must be a non-empty list; the head group is the
%% one that gets a key_share, so an empty list has no meaning.
validate_groups(Opts) ->
    case maps:find(groups, Opts) of
        error ->
            ok;
        {ok, Groups} when is_list(Groups), Groups =/= [] ->
            case [G || G <- Groups, not quic_crypto:group_supported(G)] of
                [] -> ok;
                [G | _] -> {error, {unsupported_group, G}}
            end;
        {ok, _} ->
            {error, badarg}
    end.

%% @doc Stop a named QUIC server.
%%
%% Stops the server and all its connections.
%% The port will be freed for reuse.
-spec stop_server(Name) -> ok | {error, term()} when
    Name :: atom().
stop_server(Name) when is_atom(Name) ->
    quic_server_sup:stop_server(Name);
stop_server(_Name) ->
    {error, badarg}.

%% @doc Return a child spec for embedding a QUIC server in your own supervisor.
%%
%% This allows you to supervise QUIC servers within your application's
%% supervision tree instead of using the built-in server management.
%%
%% Example:
%% ```
%% init([]) ->
%%     Spec = quic:server_spec(my_quic, 4433, #{
%%         cert => CertDer,
%%         key => KeyTerm,
%%         alpn => [<<"h3">>]
%%     }),
%%     {ok, {#{strategy => one_for_one}, [Spec]}}.
%% '''
-spec server_spec(Name, Port, Opts) -> supervisor:child_spec() when
    Name :: atom(),
    Port :: inet:port_number(),
    Opts :: map().
server_spec(Name, Port, Opts) when
    is_atom(Name),
    is_integer(Port),
    Port >= 0,
    Port =< 65535,
    is_map(Opts)
->
    case quic_cert:resolve_cacerts(Opts) of
        {ok, Opts1} -> quic_server_sup:server_spec(Name, Port, Opts1);
        {error, Reason} -> error(Reason)
    end;
server_spec(_Name, _Port, _Opts) ->
    error(badarg).

%% @doc Get information about a named server.
%%
%% Returns a map containing:
%% <ul>
%%   <li>`pid' - Server supervisor PID</li>
%%   <li>`port' - Listening port</li>
%%   <li>`opts' - Server options</li>
%%   <li>`started_at' - Start timestamp in milliseconds</li>
%% </ul>
-spec get_server_info(Name) -> {ok, map()} | {error, not_found} when
    Name :: atom().
get_server_info(Name) when is_atom(Name) ->
    quic_server_registry:lookup(Name);
get_server_info(_Name) ->
    {error, badarg}.

%% @doc Get the listening port of a named server.
%%
%% Useful when the server was started with port 0 (ephemeral port).
-spec get_server_port(Name) -> {ok, inet:port_number()} | {error, not_found} when
    Name :: atom().
get_server_port(Name) when is_atom(Name) ->
    quic_server_registry:get_port(Name);
get_server_port(_Name) ->
    {error, badarg}.

%% @doc Get the bound address of a named server.
%%
%% Returns the listener's actual `{IP, Port}', resolved from the socket, so it is
%% correct even when the server was started with port 0, `inet6', `{ip, _}' or
%% `{ifaddr, _}'.
-spec get_server_sockname(Name) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}
when
    Name :: atom().
get_server_sockname(Name) when is_atom(Name) ->
    quic_server_registry:get_sockname(Name);
get_server_sockname(_Name) ->
    {error, badarg}.

%% @doc Get the list of connection PIDs for a named server.
-spec get_server_connections(Name) -> {ok, [pid()]} | {error, not_found} when
    Name :: atom().
get_server_connections(Name) when is_atom(Name) ->
    quic_server_registry:get_connections(Name);
get_server_connections(_Name) ->
    {error, badarg}.

%% @doc List all running server names.
-spec which_servers() -> [atom()].
which_servers() ->
    quic_server_registry:list().
