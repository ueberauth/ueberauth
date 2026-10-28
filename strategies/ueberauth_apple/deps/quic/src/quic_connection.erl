%%% -*- erlang -*-
%%%
%%% QUIC Connection State Machine
%%% RFC 9000 - QUIC Transport
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC connection state machine implemented as gen_statem.
%%%
%%% This module manages the lifecycle of a QUIC connection, handling:
%%% - TLS 1.3 handshake via CRYPTO frames
%%% - Packet encryption/decryption at each level
%%% - Stream management
%%% - Flow control
%%% - Timer management
%%%
%%% == Connection States ==
%%%
%%% idle -> handshaking -> connected -> draining -> closed
%%%
%%% == Messages to Owner ==
%%%
%%% {quic, Conn, {connected, Info}}         where Conn is the connection pid
%%% {quic, Conn, {stream_data, StreamId, Data, Fin}}
%%% {quic, Conn, {stream_opened, StreamId}}
%%% {quic, Conn, {closed, Reason}}
%%%
%%% == Layout ==
%%%
%%% This module is large. Navigate by section banner, in this order:
%%%
%%% - API, gen_statem callbacks, State Functions, Common Event Handling
%%% - TLS handshake; PSK validation and the session ticket store;
%%%   TLS handshake continued (server flight, tickets)
%%% - Packet send layer: frames and payloads become packets, all levels
%%% - Frame classification; Packet Processing (decrypt, parse, batched
%%%   receive); TLS message driver, which is the handshake's second half
%%%   and is reached from packet processing
%%% - Stream Processing; Socket I/O; ACK emission and decimation;
%%%   Delivery to the owner; Frame classification for ACK policy
%%% - Reclaimed-stream tracking; Send path; Send queue and priority queue
%%% - Retransmission; the timer sections (PTO, idle, keep-alive, pacing)
%%% - Key update; migration and path validation; PMTU discovery
%%%
%%% Two walkthroughs trace the hot paths end to end, naming functions
%%% rather than line numbers: docs/SEND_PATH.md and docs/RECV_PATH.md.
%%%
%%% `#state{}' lives in quic_connection_state.hrl and has 194 fields.
%%% When changing one, grep for the field name: most are touched in
%%% several regions.
%%%

-module(quic_connection).

-behaviour(gen_statem).

-include("quic.hrl").
-include("quic_qlog.hrl").
-include_lib("kernel/include/logger.hrl").
-define(QUIC_LOG_META, #{
    domain => [erlang_quic, connection], report_cb => fun quic_log:format_report/2
}).

%% Suppress warnings for helper functions prepared for future use
-compile([{nowarn_unused_function, [{send_handshake_ack, 1}, {contains_non_probing_frame, 1}]}]).

%% Dialyzer nowarn for functions prepared for future use and unreachable patterns
%% (code structure supports multiple ciphers/paths not yet exercised)
-dialyzer(
    {nowarn_function, [
        send_initial_ack/1,
        %% Reachable from the new TLS_SERVER_HELLO handler via the
        %% selected_psk_identity branch — but no eunit path currently
        %% exercises a PSK handshake end-to-end. The forthcoming
        %% quic_psk_e2e_SUITE drives this code; drop these
        %% suppressions once the suite lands.
        validate_client_psk_selection/2,
        validate_client_psk_selection/4,
        notify_owner/2
    ]}
).
-dialyzer([no_match]).

%% API
-export([
    start_link/4,
    start_link/5,
    connect/4,
    send_data/4,
    send_data_async/4,
    set_stream_flow_control/3,
    stream_consumed/3,
    stream_flow_control/3,
    consume/3,
    notify_send_ready/1,
    send_datagram/2,
    datagram_max_size/1,
    datagram_stats/1,
    open_stream/1,
    open_unidirectional_stream/1,
    close/2,
    close_stream/3,
    reset_stream/3,
    reset_stream_at/4,
    stop_sending/3,
    handle_timeout/1,
    handle_timeout/2,
    process/1,
    get_state/1,
    peername/1,
    sockname/1,
    peercert/1,
    set_owner/2,
    set_owner_sync/2,
    setopts/2,
    get_send_queue_info/1,
    get_path_stats/1,
    %% Connection statistics (for liveness detection)
    get_stats/1,
    %% Whether a certificate's key can sign for it
    check_signing_key/2,
    check_credentials/2,
    %% 0-RTT accessors (RFC 9001 §4.6)
    has_early_keys/1,
    early_data_accepted/1,
    %% Peer transport parameters
    get_peer_transport_params/1,
    %% Transport-level PING (bypasses congestion control)
    send_ping/1,
    %% Key update (RFC 9001 Section 6)
    key_update/1,
    %% Connection migration (RFC 9000 Section 9)
    migrate/1,
    migrate/2,
    %% PMTU Discovery (RFC 8899)
    get_mtu/1,
    %% Server mode
    start_server/1,
    %% Stream prioritization (RFC 9218)
    set_stream_priority/4,
    get_stream_priority/2,
    %% Congestion control
    set_congestion_control/2,
    %% Stream deadlines
    set_stream_deadline/4,
    cancel_stream_deadline/2,
    get_stream_deadline/2,
    %% Connection ID management (RFC 9000 Section 5.1)
    issue_new_connection_ids/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    terminate/3,
    code_change/4
]).

%% State functions
-export([
    idle/3,
    handshaking/3,
    connected/3,
    draining/3,
    closed/3
]).

%% Test exports
-ifdef(TEST).
-compile([export_all, nowarn_export_all]).
-endif.

%% TLS handshake states (client)
-define(TLS_AWAITING_SERVER_HELLO, awaiting_server_hello).
-define(TLS_AWAITING_ENCRYPTED_EXT, awaiting_encrypted_extensions).
-define(TLS_AWAITING_CERT, awaiting_certificate).
-define(TLS_AWAITING_CERT_VERIFY, awaiting_certificate_verify).
-define(TLS_AWAITING_FINISHED, awaiting_finished).
-define(TLS_HANDSHAKE_COMPLETE, handshake_complete).

%% TLS handshake states (server)
-define(TLS_AWAITING_CLIENT_HELLO, awaiting_client_hello).
-define(TLS_AWAITING_CLIENT_CERT, awaiting_client_cert).
-define(TLS_AWAITING_CLIENT_CERT_VERIFY, awaiting_client_cert_verify).
-define(TLS_AWAITING_CLIENT_FINISHED, awaiting_client_finished).

%% TLS alert codes live in include/quic.hrl now (?TLS_ALERT_*).

%% Max pending data entries before connection is established (prevents memory exhaustion)
-define(MAX_PENDING_DATA_ENTRIES, 1000).

%% Client Initial retransmission while the handshake has not completed.
%% Recovers a stalled handshake, including the case where a server defers
%% part of its flight under the anti-amplification limit (RFC 9000 §8.1):
%% re-sending the (padded) Initial lifts the server's received-byte budget
%% so it can flush the deferred flight. Backoff doubles from the base up
%% to the cap. Localhost handshakes complete well under the base, so the
%% timer is cancelled by the state change and never fires.
%% 200 ms base keeps a lossy handshake moving at something closer to
%% PTO cadence on low-RTT paths; 12 attempts bound the total effort to
%% roughly half a minute before the connect timeout owns the outcome.

%% Max send queue size in bytes (16 MB default) - prevents memory exhaustion from queued data
-define(MAX_SEND_QUEUE_BYTES, 16777216).

%% Bounds on the client Finished retransmission interval. The floor keeps
%% a near-zero PTO from spinning; the ceiling keeps a long RTT estimate
%% from parking the flight past the idle timeout.

%% Max additional datagram messages drained from the mailbox in one
%% connected-state receive pass (see drain_recv_msgs/2).
-define(RECV_DRAIN_MAX, 64).

%% Max receive buffer size in bytes (32 MB total across all streams) - protects against malicious peers
-define(MAX_RECV_BUFFER_BYTES, 33554432).

%% Per-level cap on out-of-order CRYPTO reassembly (RFC 9000 §7.5). A
%% legitimate handshake flight is a few KB; bound buffered bytes and the
%% number of out-of-order fragments so a peer cannot grow memory before
%% the handshake completes. Over-limit closes with CRYPTO_BUFFER_EXCEEDED.
-define(MAX_CRYPTO_BUFFER_BYTES, 262144).
-define(MAX_CRYPTO_BUFFER_ENTRIES, 2048).

%% RFC 9001 §6.6 / Appendix B AEAD confidentiality limit for the AES-GCM
%% suites (the only ones negotiated): force a key update before
%% encrypting 2^23 packets under one key.
-define(AEAD_CONFIDENTIALITY_LIMIT, 16#800000).

-include("quic_connection_state.hrl").

%%====================================================================
%% API
%%====================================================================

%% @doc Start a QUIC connection process.
-spec start_link(
    binary() | inet:hostname() | inet:ip_address(),
    inet:port_number(),
    map(),
    pid()
) -> {ok, pid()} | {error, term()}.
start_link(Host, Port, Opts, Owner) ->
    start_link(Host, Port, Opts, Owner, undefined).

%% @doc Start a QUIC connection with optional pre-opened socket.
-spec start_link(
    binary() | inet:hostname() | inet:ip_address(),
    inet:port_number(),
    map(),
    pid(),
    gen_udp:socket() | undefined
) -> {ok, pid()} | {error, term()}.
start_link(Host, Port, Opts, Owner, Socket) ->
    gen_statem:start_link(?MODULE, [Host, Port, Opts, Owner, Socket], statem_opts(Opts)).

%% @doc Initiate a connection to a QUIC server.
%% This is a convenience wrapper that starts the process and initiates handshake.
-spec connect(
    binary() | inet:hostname() | inet:ip_address(),
    inet:port_number(),
    map(),
    pid()
) -> {ok, reference(), pid()} | {error, term()}.
connect(Host, Port, Opts, Owner) ->
    case start_link(Host, Port, Opts, Owner) of
        {ok, Pid} ->
            ConnRef = gen_statem:call(Pid, get_ref),
            {ok, ConnRef, Pid};
        Error ->
            Error
    end.

%% @doc Start a server-side QUIC connection.
%% Called by quic_listener when a new connection is accepted.
-spec start_server(map()) -> {ok, pid()} | {error, term()}.
start_server(Opts) ->
    gen_statem:start_link(?MODULE, {server, Opts}, statem_opts(Opts)).

%% An idle connection process never garbage-collects on its own, so the
%% garbage produced by the handshake (~170 KiB measured) stays pinned to
%% its heap indefinitely; with tens of thousands of mostly-idle
%% connections that dominates the VM footprint. Hibernating after a
%% quiet period runs a fullsweep GC and shrinks the process to a few
%% KiB. Busy connections are unaffected (the timer only fires after
%% `hibernate_after' ms without any event).
statem_opts(Opts) ->
    case maps:get(hibernate_after, Opts, 5000) of
        infinity ->
            [];
        T when is_integer(T), T > 0 ->
            [{hibernate_after, T}]
    end.

%% @doc Send data on a stream.
-spec send_data(pid(), non_neg_integer(), iodata(), boolean()) ->
    ok | {error, term()}.
send_data(Conn, StreamId, Data, Fin) ->
    gen_statem:call(Conn, {send_data, StreamId, Data, Fin}).

%% @doc Send data on a stream asynchronously.
%% This is faster than send_data/4 because it uses cast instead of call,
%% avoiding the round-trip latency. However, errors are silently dropped.
%% Use this for high-throughput scenarios where occasional dropped data is acceptable.
-spec send_data_async(pid(), non_neg_integer(), iodata(), boolean()) -> ok.
send_data_async(Conn, StreamId, Data, Fin) ->
    gen_statem:cast(Conn, {send_data_async, StreamId, Data, Fin}).

%% @private Receive credit for a stream: `auto' grants it as data is
%% delivered, `{manual, Consumed}' only as the reader returns it through
%% stream_consumed/3, Consumed being the offset it has already accounted
%% for. Used by quic_h3; bytes still on their way to the reader count as
%% not consumed.
-spec set_stream_flow_control(pid(), non_neg_integer(), auto | {manual, non_neg_integer()}) ->
    ok.
set_stream_flow_control(Conn, StreamId, Mode) ->
    gen_statem:cast(Conn, {set_stream_flow_control, StreamId, Mode}).

%% @private After a send_queue_full refusal: send the owner
%% `{quic, Conn, send_ready}' once, when the send queue is below half its
%% ceiling (at once if it already is). Used by quic_h3.
-spec notify_send_ready(pid()) -> ok.
notify_send_ready(Conn) ->
    gen_statem:cast(Conn, notify_send_ready).

%% @private The reader of a manual stream has consumed up to Offset
%% (absolute, in stream bytes); credit may advance up to one window past it.
-spec stream_consumed(pid(), non_neg_integer(), non_neg_integer()) -> ok.
stream_consumed(Conn, StreamId, Offset) ->
    gen_statem:cast(Conn, {stream_consumed, StreamId, Offset}).

%% @private Public form of set_stream_flow_control/3, see quic.
-spec stream_flow_control(pid(), non_neg_integer(), auto | manual) ->
    ok | {error, unknown_stream}.
stream_flow_control(Conn, StreamId, Mode) ->
    gen_statem:call(Conn, {stream_flow_control, StreamId, Mode}).

%% @private Return credit for Bytes the reader has processed, see quic.
-spec consume(pid(), non_neg_integer(), non_neg_integer()) -> ok | {error, unknown_stream}.
consume(Conn, StreamId, Bytes) ->
    gen_statem:call(Conn, {consume, StreamId, Bytes}).

%% @doc Open a new bidirectional stream.
-spec open_stream(pid()) -> {ok, non_neg_integer()} | {error, term()}.
open_stream(Conn) ->
    gen_statem:call(Conn, open_stream, 10000).

%% @doc Open a new unidirectional stream.
-spec open_unidirectional_stream(pid()) -> {ok, non_neg_integer()} | {error, term()}.
open_unidirectional_stream(Conn) ->
    gen_statem:call(Conn, open_unidirectional_stream).

%% @doc Close the connection.
-spec close(pid(), term()) -> ok.
close(Conn, Reason) ->
    gen_statem:cast(Conn, {close, Reason}).

%% @doc Close a specific stream.
-spec close_stream(pid(), non_neg_integer(), non_neg_integer()) ->
    ok | {error, term()}.
close_stream(Conn, StreamId, ErrorCode) ->
    gen_statem:call(Conn, {close_stream, StreamId, ErrorCode}).

%% @doc Reset a stream.
-spec reset_stream(pid(), non_neg_integer(), non_neg_integer()) ->
    ok | {error, term()}.
reset_stream(Conn, StreamId, ErrorCode) ->
    gen_statem:call(Conn, {close_stream, StreamId, ErrorCode}).

%% @doc Reset a stream with reliable delivery up to ReliableSize.
%% Data up to ReliableSize will be delivered before the reset takes effect.
%% Requires peer support via the reset_stream_at transport parameter.
-spec reset_stream_at(pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    ok | {error, term()}.
reset_stream_at(Conn, StreamId, ErrorCode, ReliableSize) ->
    gen_statem:call(Conn, {reset_stream_at, StreamId, ErrorCode, ReliableSize}).

%% @doc Request peer to stop sending on a stream.
%% Sends a STOP_SENDING frame (RFC 9000 Section 19.5).
-spec stop_sending(pid(), non_neg_integer(), non_neg_integer()) ->
    ok | {error, term()}.
stop_sending(Conn, StreamId, ErrorCode) ->
    gen_statem:call(Conn, {stop_sending, StreamId, ErrorCode}).

%% @doc Handle a timeout event.
-spec handle_timeout(pid()) -> ok.
handle_timeout(Conn) ->
    gen_statem:cast(Conn, handle_timeout).

%% @doc Handle a timeout event with timestamp.
%% The NowMs parameter is currently unused as the connection
%% manages its own timing internally.
-spec handle_timeout(pid(), non_neg_integer()) -> non_neg_integer() | infinity.
handle_timeout(Conn, _NowMs) ->
    gen_statem:cast(Conn, handle_timeout),
    infinity.

%% @doc Process pending events (called when socket is ready).
-spec process(pid()) -> ok.
process(Conn) ->
    gen_statem:cast(Conn, process).

%% @doc Get current connection state (for debugging).
-spec get_state(pid()) -> {atom(), map()}.
get_state(Conn) ->
    gen_statem:call(Conn, get_state).

%% @doc Get remote address.
-spec peername(pid()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(Conn) ->
    gen_statem:call(Conn, peername).

%% @doc Get local address.
-spec sockname(pid()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(Conn) ->
    gen_statem:call(Conn, sockname).

%% @doc Get peer certificate (DER-encoded).
-spec peercert(pid()) -> {ok, binary()} | {error, term()}.
peercert(Conn) ->
    gen_statem:call(Conn, peercert).

%% @doc Set new owner process (async).
-spec set_owner(pid(), pid()) -> ok.
set_owner(Conn, NewOwner) ->
    gen_statem:cast(Conn, {set_owner, NewOwner}).

%% @doc Set new owner process (synchronous).
%% Use this when you need to ensure ownership is transferred before continuing.
%% A connection that is already draining or closed refuses the swap with
%% `{error, {invalid_state, StateName}}'.
-spec set_owner_sync(pid(), pid()) -> ok | {error, term()}.
set_owner_sync(Conn, NewOwner) ->
    gen_statem:call(Conn, {set_owner, NewOwner}).

%% @doc Send a datagram.
-spec send_datagram(pid(), iodata()) -> ok | {error, term()}.
send_datagram(Conn, Data) ->
    gen_statem:call(Conn, {send_datagram, Data}).

%% @doc Get maximum datagram payload size.
%% Returns 0 if peer doesn't support datagrams.
-spec datagram_max_size(pid()) -> non_neg_integer().
datagram_max_size(Conn) ->
    gen_statem:call(Conn, datagram_max_size).

-spec datagram_stats(pid()) ->
    #{
        delivered := non_neg_integer(),
        dropped_recv := non_neg_integer(),
        sent := non_neg_integer(),
        dropped_send := non_neg_integer()
    }.
datagram_stats(Conn) ->
    gen_statem:call(Conn, datagram_stats).

%% @doc Set connection options.
-spec setopts(pid(), [{atom(), term()}]) -> ok | {error, term()}.
setopts(Conn, Opts) ->
    gen_statem:call(Conn, {setopts, Opts}).

%% @doc Get send queue status for backpressure decisions.
%% Returns information about the current send queue state including
%% whether the connection is congested and should apply backpressure.
-spec get_send_queue_info(pid()) -> {ok, quic:send_queue_info()} | {error, term()}.
get_send_queue_info(Conn) ->
    gen_statem:call(Conn, get_send_queue_info).

%% @doc Path metrics snapshot. See `quic:get_path_stats/1'.
-spec get_path_stats(pid()) -> {ok, quic:path_stats()} | {error, term()}.
get_path_stats(Conn) ->
    gen_statem:call(Conn, get_path_stats).

%% @doc Get connection statistics for liveness detection.
%% Returns packet counts that can be used by net_kernel for tick checking.
%% Any QUIC packet (ACK, PING, data) counts as proof of peer liveness.
-spec get_stats(pid()) -> {ok, map()} | {error, term()}.
get_stats(Conn) ->
    gen_statem:call(Conn, get_stats).

%% @doc Returns whether the connection has derived early keys (RFC 9001
%% §4.6). True when a session ticket was supplied at connect time and
%% send_client_hello/1 derived 0-RTT traffic keys; the H3 layer uses
%% this to choose between the fresh-handshake and 0-RTT bootstraps.
-spec has_early_keys(pid()) -> boolean().
has_early_keys(Conn) ->
    gen_statem:call(Conn, has_early_keys).

%% @doc Returns whether the server accepted early data, or `unknown'
%% if the handshake has not yet completed. Useful only after the
%% connection enters the connected state to confirm that 0-RTT was
%% actually used.
-spec early_data_accepted(pid()) -> boolean() | unknown.
early_data_accepted(Conn) ->
    gen_statem:call(Conn, early_data_accepted).

%% @doc Get peer's transport parameters.
%% Returns the transport parameters received from the peer during handshake.
%% Useful for verifying peer capabilities (e.g., WebTransport support).
-spec get_peer_transport_params(pid()) -> {ok, map()} | {error, term()}.
get_peer_transport_params(Conn) ->
    gen_statem:call(Conn, get_peer_transport_params).

%% @doc Send a PING frame (RFC 9000).
%% PING frames bypass congestion control and are useful for liveness checks.
%% The PING elicits an ACK from the peer, confirming the connection is alive.
-spec send_ping(pid()) -> ok | {error, term()}.
send_ping(Conn) ->
    gen_statem:call(Conn, send_ping).

%% @doc Get the current MTU for the connection.
%% Returns the effective MTU discovered via DPLPMTUD (RFC 8899).
-spec get_mtu(pid()) -> {ok, pos_integer()} | {error, term()}.
get_mtu(Conn) ->
    gen_statem:call(Conn, get_mtu).

%% @doc Initiate a key update (RFC 9001 Section 6).
%% This triggers a key update cycle, deriving new encryption keys.
%% Only valid when connection is in connected state.
-spec key_update(pid()) -> ok | {error, term()}.
key_update(Conn) ->
    gen_statem:call(Conn, key_update).

%% @doc Initiate connection migration.
%% This triggers path validation by sending PATH_CHALLENGE on a new path.
%% Simulates network change by rebinding the socket.
-spec migrate(pid()) -> ok | {error, term()}.
migrate(Conn) ->
    gen_statem:call(Conn, migrate).

%% @doc Trigger connection migration with timeout option.
%% Simulates network change by rebinding the socket.
-spec migrate(pid(), timeout()) -> ok | {error, term()}.
migrate(Conn, Timeout) ->
    gen_statem:call(Conn, {migrate, #{}}, Timeout).

%% @doc Set stream priority (RFC 9218).
%% Urgency: 0-7 (lower = more urgent, default 3)
%% Incremental: boolean (data can be processed incrementally)
-spec set_stream_priority(pid(), non_neg_integer(), 0..7, boolean()) ->
    ok | {error, term()}.
set_stream_priority(Conn, StreamId, Urgency, Incremental) ->
    gen_statem:call(Conn, {set_stream_priority, StreamId, Urgency, Incremental}).

%% @doc Get stream priority (RFC 9218).
%% Returns {ok, {Urgency, Incremental}} or {error, not_found}.
-spec get_stream_priority(pid(), non_neg_integer()) ->
    {ok, {0..7, boolean()}} | {error, term()}.
get_stream_priority(Conn, StreamId) ->
    gen_statem:call(Conn, {get_stream_priority, StreamId}).

%% @doc Set the congestion control algorithm for a connection.
%% Algorithm: newreno | bbr | cubic
-spec set_congestion_control(pid(), quic_cc:cc_algorithm()) -> ok | {error, term()}.
set_congestion_control(Conn, Algorithm) ->
    gen_statem:call(Conn, {set_congestion_control, Algorithm}).

%% @doc Set a deadline for a stream.
%% TimeoutMs is milliseconds from now until expiry.
%% Options: action => reset | notify | both, error_code => non_neg_integer()
-spec set_stream_deadline(pid(), non_neg_integer(), pos_integer(), map()) ->
    ok | {error, term()}.
set_stream_deadline(Conn, StreamId, TimeoutMs, Opts) ->
    gen_statem:call(Conn, {set_stream_deadline, StreamId, TimeoutMs, Opts}).

%% @doc Cancel a stream deadline.
-spec cancel_stream_deadline(pid(), non_neg_integer()) -> ok | {error, term()}.
cancel_stream_deadline(Conn, StreamId) ->
    gen_statem:call(Conn, {cancel_stream_deadline, StreamId}).

%% @doc Get remaining time for a stream deadline.
-spec get_stream_deadline(pid(), non_neg_integer()) ->
    {ok, {non_neg_integer() | infinity, reset | notify | both}} | {error, term()}.
get_stream_deadline(Conn, StreamId) ->
    gen_statem:call(Conn, {get_stream_deadline, StreamId}).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

callback_mode() ->
    [state_functions, state_enter].

init([Host, Port, Opts, Owner, Socket]) ->
    process_flag(trap_exit, true),

    %% Generate connection IDs
    SCID = generate_connection_id(),
    DCID = generate_connection_id(),

    %% Determine remote address (Happy Eyeballs / multi-address resolution is
    %% handled upstream in quic_happy; here Host is a single address or name).
    case resolve_address(Host, Port, maps:get(family, Opts, any)) of
        {error, ResolveErr} ->
            {stop, {resolve_failed, ResolveErr}};
        {ok, RemoteAddr} ->
            %% Create or use provided socket with proper cleanup on failure
            %% Pass RemoteAddr to match address family (IPv4 vs IPv6)
            %% Extra socket opts allow binding to specific address (fix for #28)
            ExtraOpts = maps:get(extra_socket_opts, Opts, []),
            case open_client_socket(Socket, RemoteAddr, Opts, ExtraOpts) of
                {ok, Sock, LocalAddr, OwnsSocket} ->
                    try
                        init_client_state(
                            Host, Opts, Owner, SCID, DCID, RemoteAddr, Sock, LocalAddr
                        )
                    catch
                        Class:Reason:Stack ->
                            %% Clean up socket on initialization failure — pick the
                            %% right close based on the socket_backend option.
                            case OwnsSocket of
                                true -> close_raw_client_socket(Opts, Sock);
                                false -> ok
                            end,
                            %% Drop any stashed socket_state left by
                            %% open_client_socket_backend/2 (process dict)
                            %% so we don't leak it across retries.
                            _ = erase(client_socket_state),
                            erlang:raise(Class, Reason, Stack)
                    end;
                {error, Reason} ->
                    {stop, Reason}
            end
    end;
%% Server-side initialization
init({server, Opts}) ->
    process_flag(trap_exit, true),

    %% Extract required options
    Socket = maps:get(socket, Opts),
    RemoteAddr = maps:get(remote_addr, Opts),
    InitialDCID = maps:get(initial_dcid, Opts),
    SCID = maps:get(scid, Opts),
    %% Cert/key are optional: a `sni_callback' may supply them per
    %% handshake from the ClientHello server_name.
    Cert = maps:get(cert, Opts, undefined),
    CertChain = maps:get(cert_chain, Opts, []),
    PrivateKey = maps:get(private_key, Opts, undefined),
    SniCallback = maps:get(sni_callback, Opts, undefined),
    ALPNList = maps:get(alpn, Opts, [<<"h3">>]),
    Listener = maps:get(listener, Opts),
    %% Use client's QUIC version for key derivation (defaults to v1)
    Version = maps:get(version, Opts, ?QUIC_VERSION_1),
    SupportedVersions =
        case maps:get(versions, Opts, [Version]) of
            [] -> [Version];
            Vs -> Vs
        end,

    %% Generate initial keys using client's DCID and version
    InitialKeys = derive_initial_keys(InitialDCID, Version),

    %% Initialize packet number spaces
    PNSpace = #pn_space{
        next_pn = 0,
        largest_recv = undefined,
        recv_time = undefined,
        ack_ranges = [],
        ack_eliciting_in_flight = 0
    },

    %% Create connection reference (for internal use only)
    ConnRef = make_ref(),

    %% Initialize congestion control and loss detection
    %% Support configurable initial cwnd for distribution workloads
    CCOpts = build_cc_opts(Opts),
    CCState = quic_cc:new(CCOpts),
    LossState = quic_loss:new(),

    %% Get idle timeout for keep-alive calculation
    IdleTimeout = maps:get(idle_timeout, Opts, ?DEFAULT_MAX_IDLE_TIMEOUT),

    %% Query local address from socket (fix for #27).
    %% When the listener runs with socket_backend => socket, the handle
    %% is a `{'$socket', Ref}' from the OTP socket module and
    %% `inet:sockname/1' crashes with function_clause. Branch on the
    %% handle shape to use the right API.
    LocalAddr = query_local_addr(Socket),

    %% Server connections use the listener's shared socket for sending.
    %% This matches standard QUIC implementations (quic-go, quiche) where
    %% all connections share a single UDP socket, demultiplexed by
    %% Connection ID. We previously tried a separate send socket with
    %% reuseport for GSO batching, but on Linux this caused kernel packet
    %% distribution to starve the listener.
    %%
    %% Instead, each server connection now gets its own per-connection
    %% batch buffer via quic_socket:new_sender/2, which reuses (without
    %% owning) the listener's socket. This keeps the single-socket model
    %% intact while letting each connection's ACKs/data be coalesced and,
    %% on Linux with socket backend, use GSO via sendmsg. Gated on
    %% server_send_batching (default true) so operators can fall back to
    %% the direct gen_udp:send/4 path if needed.
    %% Build a per-connection sender even with batching off so sends
    %% dispatch on `#socket_state.backend'. On the socket listener,
    %% `#state.socket' is an OTP socket handle that `gen_udp:send/4'
    %% cannot accept.
    SocketState = build_server_socket_state(Socket, Opts),

    %% Initialize state
    State = #state{
        %% Sequence 0 is the handshake CID. It counts against the peer's
        %% active_connection_id_limit, so the pool has to hold it before
        %% we work out how many more to issue. Its reset token travels in
        %% our transport parameters, not in a NEW_CONNECTION_ID frame.
        cid_pool_state = quic_cid:new(SCID, maps:get(active_connection_id_limit, Opts, 2)),
        % Will be set from ClientHello SCID
        dcid = <<>>,
        % Use client's QUIC version
        version = Version,
        socket = Socket,
        socket_state = SocketState,
        remote_addr = RemoteAddr,
        % Listener is the owner for now
        owner = Listener,
        owner_mon = maybe_monitor_owner(Opts, Listener, true),
        pn_app = PNSpace,
        max_data_local = maps:get(max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA),
        max_data_remote = ?DEFAULT_INITIAL_MAX_DATA,
        fc_last_stream_update = undefined,
        fc_last_conn_update = undefined,
        % Server-initiated bidi: 1, 5, 9, ...
        next_stream_id_bidi = 1,
        % Server-initiated uni: 3, 7, 11, ...
        next_stream_id_uni = 3,
        max_streams_bidi_local = maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        max_streams_bidi_remote = ?DEFAULT_MAX_STREAMS_BIDI,
        max_streams_uni_local = maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI),
        max_streams_uni_remote = ?DEFAULT_MAX_STREAMS_UNI,
        keep_alive_timer = undefined,
        last_activity = erlang:monotonic_time(millisecond),
        cc_state = CCState,
        loss_state = LossState,
        pmtu_state = init_pmtu_state(Opts),
        cfg = #conn_cfg{
            scid = SCID,
            %% Defaults to the Initial's DCID; the listener overrides it with
            %% the pre-Retry DCID (from the token) for a retried connection.
            original_dcid = maps:get(original_dcid, Opts, InitialDCID),
            role = server,
            supported_versions = SupportedVersions,
            %% send_socket is undefined - socket is in socket_state
            send_socket = undefined,
            local_addr = LocalAddr,
            conn_ref = ConnRef,
            verify = maps:get(verify, Opts, false),
            cacerts = maps:get(cacerts, Opts, undefined),
            require_client_cert = maps:get(require_client_cert, Opts, false),
            %% TLS 1.3 external PSK config (RFC 8446 §4.2.11). Either or
            %% both may be `undefined'; if both are undefined the server
            %% only accepts cert-authenticated handshakes.
            psk_config = #{
                psk_callback => maps:get(psk_callback, Opts, undefined),
                psks => maps:get(psks, Opts, undefined)
            },
            %% Accept every group the crypto layer supports: a preference
            %% list holding only x25519 forced a HelloRetryRequest round
            %% trip on any client whose key_share leads with another group
            %% (picoquic shares P-256 first).
            tls_groups = maps:get(groups, Opts, [x25519, secp256r1, secp384r1]),
            tls_sig_algs = maps:get(signature_algs, Opts, undefined),
            alpn_list = normalize_alpn_list(ALPNList),
            max_stream_data_bidi_local = maps:get(
                max_stream_data_bidi_local, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA
            ),
            max_stream_data_bidi_remote = maps:get(
                max_stream_data_bidi_remote, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA
            ),
            max_stream_data_uni = maps:get(
                max_stream_data_uni, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA
            ),
            fc_max_receive_window = maps:get(max_receive_window, Opts, ?DEFAULT_MAX_RECEIVE_WINDOW),
            max_owner_queue = maps:get(max_owner_queue, Opts, ?DEFAULT_MAX_OWNER_QUEUE),
            ack_packet_tolerance = maps:get(ack_packet_tolerance, Opts, ?ACK_PACKET_TOLERANCE),
            burst_budget = maps:get(max_burst_packets, Opts, ?DEFAULT_MAX_BURST_PACKETS),
            delivery_coalescing = bool_opt(delivery_coalescing, Opts),
            cipher_preference = maps:get(ciphers, Opts, default_cipher_preference()),
            max_udp_payload_size_local = maps:get(max_udp_payload_size, Opts, undefined),
            max_datagram_frame_size_local = maps:get(max_datagram_frame_size, Opts, 0),
            datagram_recv_queue_len = maps:get(datagram_recv_queue_len, Opts, infinity),
            spin_bit_enabled = maps:get(spin_bit, Opts, true),
            stateless_reset_secret = maps:get(reset_secret, Opts, undefined),
            retry_scid_for_tp = maps:get(retry_scid, Opts, undefined),
            reset_stream_at_enabled = maps:get(reset_stream_at, Opts, false),
            idle_timeout = IdleTimeout,
            keep_alive_interval = calculate_keep_alive_interval(Opts, IdleTimeout),
            disconnect_timeout = disconnect_timeout_opt(Opts),
            listener = Listener,
            ticket_table = maps:get(ticket_table, Opts, undefined),
            sni_callback = SniCallback,
            server_preferred_address = build_server_preferred_address(Opts),
            cid_config = maps:get(cid_config, Opts, undefined),
            congestion_threshold = maps:get(congestion_threshold, Opts, 2),
            pacing_enabled = maps:get(pacing_enabled, Opts, true),
            pmtu_raise_interval = maps:get(pmtu_raise_interval, Opts, ?PMTU_DEFAULT_RAISE_INTERVAL),
            qlog_ctx = quic_qlog:new(Opts, InitialDCID, server)
        },
        hs = #hs{
            initial_keys = InitialKeys,
            tls_state = ?TLS_AWAITING_CLIENT_HELLO,
            pn_initial = PNSpace,
            pn_handshake = PNSpace,
            address_validated = maps:get(address_validated, Opts, false),
            server_cert = Cert,
            server_cert_chain = CertChain,
            server_private_key = PrivateKey
        }
    },

    %% Emit qlog connection_started event
    quic_qlog:connection_started((State#state.cfg)#conn_cfg.qlog_ctx),

    %% RFC 9000 §10.1: arm the idle timer once; it re-arms itself lazily
    %% from last_activity (the keep-alive timer is armed on entering the
    %% connected state).
    {ok, idle, set_idle_timer(State)}.

%% Build congestion control options from connection options.
%% Supports:
%%   - cc_algorithm: Congestion control algorithm (newreno | bbr | cubic, default: newreno)
%%   - initial_window: Initial congestion window in bytes (default: RFC 9002 formula)
%%                     Higher values improve bulk transfer throughput.
%%                     Recommended for distribution: 65536 (64KB) or higher.
%%   - minimum_window: Lower bound for cwnd after congestion events.
%%                     Defaults to RFC 9002 (2 * max_datagram_size).
%%   - min_recovery_duration: Minimum time in recovery before exit (ms, default: 100)
%%                            Prevents rapid cwnd oscillations on low-latency networks.
build_cc_opts(Opts) ->
    CCOpts = #{},
    CCOpts1 = maybe_add_cc_opt(initial_window, Opts, CCOpts),
    CCOpts2 = maybe_add_cc_opt(minimum_window, Opts, CCOpts1),
    CCOpts3 = maybe_add_cc_opt(min_recovery_duration, Opts, CCOpts2),
    %% Pass max_udp_payload_size as max_datagram_size to CC
    CCOpts4 =
        case maps:find(max_udp_payload_size, Opts) of
            {ok, Size} -> maps:put(max_datagram_size, Size, CCOpts3);
            error -> CCOpts3
        end,
    %% Add algorithm selection (default: newreno)
    case maps:find(cc_algorithm, Opts) of
        {ok, Algo} when Algo =:= newreno; Algo =:= bbr; Algo =:= cubic ->
            CCOpts4#{algorithm => Algo};
        _ ->
            CCOpts4
    end.

maybe_add_cc_opt(Key, Opts, CCOpts) ->
    case maps:find(Key, Opts) of
        {ok, V} when is_integer(V), V > 0 -> CCOpts#{Key => V};
        _ -> CCOpts
    end.

%% Initialize PMTU discovery state from options.
%% Options:
%%   - pmtu_enabled: Enable PMTU discovery (default: true)
%%   - pmtu_max_mtu: Maximum MTU to probe (default: 1500)
init_pmtu_state(Opts) ->
    PMTUOpts = #{
        pmtu_enabled => maps:get(pmtu_enabled, Opts, true),
        pmtu_max_mtu => maps:get(pmtu_max_mtu, Opts, 1500)
    },
    quic_pmtu:new(PMTUOpts).

%% Build preferred_address record from listener options (RFC 9000 Section 9.6)
build_server_preferred_address(Opts) ->
    PreferredIPv4 = maps:get(preferred_ipv4, Opts, undefined),
    PreferredIPv6 = maps:get(preferred_ipv6, Opts, undefined),
    case {PreferredIPv4, PreferredIPv6} of
        {undefined, undefined} ->
            undefined;
        _ ->
            %% Generate new CID (LB-aware if configured) and stateless reset token
            CIDConfig = maps:get(cid_config, Opts, undefined),
            CID = generate_connection_id(CIDConfig),
            Token = crypto:strong_rand_bytes(16),
            {IPv4Addr, IPv4Port} =
                case PreferredIPv4 of
                    {Addr, Port} -> {Addr, Port};
                    undefined -> {undefined, undefined}
                end,
            {IPv6Addr, IPv6Port} =
                case PreferredIPv6 of
                    {Addr6, Port6} -> {Addr6, Port6};
                    undefined -> {undefined, undefined}
                end,
            #preferred_address{
                ipv4_addr = IPv4Addr,
                ipv4_port = IPv4Port,
                ipv6_addr = IPv6Addr,
                ipv6_port = IPv6Port,
                cid = CID,
                stateless_reset_token = Token
            }
    end.

%% Helper to open or use provided socket for client
%% Match address family based on the remote address
%% Opts is the full options map, ExtraOpts allows socket options like {ip, Address}
open_client_socket(undefined, {IP, _Port} = RemoteAddr, Opts, ExtraOpts) ->
    case maps:get(socket_backend, Opts, gen_udp) of
        socket ->
            open_client_socket_backend(RemoteAddr, Opts);
        adapter ->
            open_client_socket_adapter(Opts);
        _ ->
            open_client_socket_genudp(IP, Opts, ExtraOpts)
    end;
open_client_socket(S, _RemoteAddr, _Opts, _ExtraOpts) ->
    %% Pre-opened socket provided, ignore extra opts
    case inet:sockname(S) of
        {ok, LA} -> {ok, S, LA, false};
        {error, Reason} -> {error, Reason}
    end.

build_server_socket_state(Socket, Opts) ->
    BatchOpts =
        case maps:get(server_send_batching, Opts, true) of
            true -> maps:get(batching, Opts, #{});
            false -> #{enabled => false}
        end,
    SenderOpts = #{
        backend => maps:get(listener_socket_backend, Opts, gen_udp),
        gso_supported => maps:get(listener_gso_supported, Opts, false),
        batching => BatchOpts,
        sender_pid => maps:get(send_sender, Opts, undefined),
        gso_counter => maps:get(send_gso_counter, Opts, undefined)
    },
    case quic_socket:new_sender(Socket, SenderOpts) of
        {ok, S} -> S;
        {error, _} -> undefined
    end.

open_client_socket_genudp(IP, Opts, ExtraOpts) ->
    AddrFamily = address_family(IP),
    RecBuf = maps:get(recbuf, Opts, ?DEFAULT_UDP_RECBUF),
    SndBuf = maps:get(sndbuf, Opts, ?DEFAULT_UDP_SNDBUF),
    BaseOpts = [
        binary,
        AddrFamily,
        {active, false},
        {recbuf, RecBuf},
        {sndbuf, SndBuf}
    ],
    case gen_udp:open(0, BaseOpts ++ ExtraOpts) of
        {ok, S} ->
            case inet:sockname(S) of
                {ok, LA} ->
                    {ok, S, LA, true};
                {error, Reason} ->
                    gen_udp:close(S),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Opt-in socket-backend path. Uses `quic_socket:open_for_send/2' so
%% the connection gets an OTP socket with GSO available per-message via
%% cmsg on uniform batches. The wrapping `#socket_state{}' is stashed
%% in the process dictionary for `init_client_state/8' to adopt without
%% widening the tuple shape returned by `open_client_socket/4'.
%% Caller-supplied datagram adapter. The connection delegates outbound
%% sends to `send_fun' inside the adapter map; inbound packets must be
%% delivered to the connection owner as `{udp, Socket, IP, Port, Data}'
%% by the caller's recv loop, where `Socket' is the reference returned
%% in the socket_state. Stash the socket_state via the process dict so
%% `init_client_state/8' adopts it without changing return shapes.
open_client_socket_adapter(Opts) ->
    AdapterOpts = maps:get(socket_adapter, Opts, undefined),
    case AdapterOpts of
        undefined ->
            {error, missing_socket_adapter};
        _ when is_map(AdapterOpts) ->
            case quic_socket:open_adapter(AdapterOpts) of
                {ok, SocketState} ->
                    {ok, LA} = quic_socket:sockname(SocketState),
                    put(client_socket_state, SocketState),
                    {ok, quic_socket:get_socket(SocketState), LA, true};
                {error, _} = Err ->
                    Err
            end;
        _ ->
            {error, badarg_socket_adapter}
    end.

open_client_socket_backend({IP, _Port}, Opts) ->
    OpenOpts = Opts#{backend => socket},
    case quic_socket:open_for_send(IP, OpenOpts) of
        {ok, SocketState} ->
            case quic_socket:sockname(SocketState) of
                {ok, LA} ->
                    put(client_socket_state, SocketState),
                    {ok, quic_socket:get_socket(SocketState), LA, true};
                {error, Reason} ->
                    quic_socket:close(SocketState),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

%% Determine address family from IP tuple
address_family(IP) when tuple_size(IP) =:= 4 -> inet;
address_family(IP) when tuple_size(IP) =:= 8 -> inet6.

%% `monitor_owner' defaults to false for client connections, which are
%% linked to their caller unless supervised, and to true for accepted
%% connections, whose handler is neither linked to nor supervised by us.
%% An explicit false is kept apart from the client default, because only
%% the default stops holding once the connection changes hands.
maybe_monitor_owner(Opts, Owner, Default) ->
    case maps:find(monitor_owner, Opts) of
        {ok, true} -> erlang:monitor(process, Owner);
        {ok, false} -> opted_out;
        error when Default -> erlang:monitor(process, Owner);
        error -> linked_parent()
    end.

%% The caller that started a client connection is linked to it, which is
%% how the connection follows it down. Remember which process that is, so
%% a handoff to another owner knows which link to drop. proc_lib puts the
%% parent at the head of '$ancestors' before init runs.
linked_parent() ->
    case get('$ancestors') of
        [Parent | _] when is_pid(Parent) -> {linked, Parent};
        _ -> undefined
    end.

%% Swap the owner, re-pointing the owner monitor when one exists.
reown(#state{owner_mon = opted_out} = State, NewOwner) ->
    State#state{owner = NewOwner};
reown(#state{owner_mon = {linked, Parent}} = State, Parent) ->
    %% Back with the caller it is linked to, which still covers it.
    State#state{owner = Parent};
reown(#state{owner_mon = {linked, Parent}} = State, NewOwner) ->
    %% The caller handed it on. From here the connection follows the new
    %% owner, which has no link to it, so it is monitored: otherwise its
    %% death leaves the connection up and answering the peer with nobody
    %% behind it. And the caller's link goes, or the connection's exit
    %% when the new owner dies would take the caller down with it.
    true = unlink(Parent),
    State#state{owner = NewOwner, owner_mon = erlang:monitor(process, NewOwner)};
reown(#state{owner_mon = undefined} = State, NewOwner) ->
    State#state{owner = NewOwner};
reown(#state{owner_mon = OldMon} = State, NewOwner) ->
    _ = erlang:demonitor(OldMon, [flush]),
    State#state{owner = NewOwner, owner_mon = erlang:monitor(process, NewOwner)}.

%% Continue client initialization after socket is ready
init_client_state(Host, Opts, Owner, SCID, DCID, RemoteAddr, Sock, LocalAddr) ->
    %% The version decides the Initial salt, so it has to be settled before
    %% any key is derived. This was fixed at v1, which left the `version'
    %% option with nothing to do: both the salt and the version in our own
    %% Initial stayed v1 however the connection was configured.
    Version = maps:get(version, Opts, ?QUIC_VERSION_1),
    %% Versions we would also accept (RFC 9368); the connection itself
    %% starts at `version'.
    SupportedVersions =
        case maps:get(versions, Opts, [Version]) of
            [] -> [Version];
            Vs -> Vs
        end,
    InitialKeys = derive_initial_keys(DCID, Version),

    %% Initialize packet number spaces
    PNSpace = #pn_space{
        next_pn = 0,
        largest_recv = undefined,
        recv_time = undefined,
        ack_ranges = [],
        ack_eliciting_in_flight = 0
    },

    %% Create connection reference (for internal use only)
    ConnRef = make_ref(),

    %% Get server name for SNI
    ServerName =
        case maps:get(server_name, Opts, undefined) of
            undefined when is_binary(Host) -> Host;
            undefined when is_list(Host) -> list_to_binary(Host);
            SN -> SN
        end,

    %% Get ALPN list
    AlpnOpt = maps:get(alpn, Opts, [<<"h3">>]),
    AlpnList = normalize_alpn_list(AlpnOpt),

    %% Initialize congestion control and loss detection
    %% Support configurable initial cwnd for distribution workloads
    CCOpts = build_cc_opts(Opts),
    CCState = quic_cc:new(CCOpts),
    LossState = quic_loss:new(),

    %% Extract session ticket for resumption (if provided)
    SessionTicket = maps:get(session_ticket, Opts, undefined),

    %% Extract external PSK (RFC 8446 §4.2.11). Mutually exclusive
    %% with session_ticket; validated when ClientHello is built.
    ExternalPsk = maps:get(external_psk, Opts, undefined),

    %% Get idle timeout for keep-alive calculation
    IdleTimeoutClient = maps:get(idle_timeout, Opts, ?DEFAULT_MAX_IDLE_TIMEOUT),

    %% Initialize socket_state for batching (client connections only).
    %% On the opt-in `socket_backend => socket' path, `open_client_socket'
    %% already built a `#socket_state{}' with `backend = socket' and
    %% stashed it via the process dictionary — adopt it here so we don't
    %% wrap the raw handle twice. Otherwise (gen_udp default), wrap for
    %% batching unless the caller explicitly disabled it.
    ClientSocketBackend = maps:get(socket_backend, Opts, gen_udp),
    SocketState =
        case erase(client_socket_state) of
            undefined ->
                case maps:get(batching, Opts, #{}) of
                    #{enabled := false} ->
                        undefined;
                    BatchOpts ->
                        {ok, SS} = quic_socket:wrap(Sock, #{batching => BatchOpts}),
                        SS
                end;
            StashedSS ->
                StashedSS
        end,
    %% Socket-backend clients get a dedicated receiver process that
    %% forwards `{udp, Owner, IP, Port, Data}' messages to this
    %% connection — the `socket' NIF has no `{active, N}' mode.
    ClientReceiver =
        case ClientSocketBackend of
            socket when SocketState =/= undefined ->
                {ok, RPid} = quic_socket:start_client_receiver(
                    SocketState,
                    self(),
                    quic_socket:recv_queue_max(
                        maps:get(max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA)
                    )
                ),
                RPid;
            _ ->
                undefined
        end,

    %% If we've previously received a NEW_TOKEN from this endpoint,
    %% reuse it in the Initial so the server can skip retry-based
    %% address validation (RFC 9000 §8.1.3).
    InitialRetryToken =
        case quic_token_cache:take(RemoteAddr) of
            {ok, CachedToken} -> CachedToken;
            empty -> <<>>
        end,

    %% Initialize state
    State = #state{
        %% Sequence 0 is the handshake CID; see the server init path.
        cid_pool_state = quic_cid:new(SCID, maps:get(active_connection_id_limit, Opts, 2)),
        dcid = DCID,
        version = Version,
        socket = Sock,
        socket_state = SocketState,
        client_receiver = ClientReceiver,
        remote_addr = RemoteAddr,
        owner = Owner,
        %% Only supervised connections (started by quic_conn_sup) monitor their
        %% owner; caller-linked connections rely on the link instead, so they do
        %% not stop a different owner's death from propagating through the link.
        owner_mon = maybe_monitor_owner(Opts, Owner, false),
        pn_app = PNSpace,
        max_data_local = maps:get(max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA),
        max_data_remote = ?DEFAULT_INITIAL_MAX_DATA,
        fc_last_stream_update = undefined,
        fc_last_conn_update = undefined,
        % Client-initiated bidi: 0, 4, 8, ...
        next_stream_id_bidi = 0,
        % Client-initiated uni: 2, 6, 10, ...
        next_stream_id_uni = 2,
        max_streams_bidi_local = maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        max_streams_bidi_remote = ?DEFAULT_MAX_STREAMS_BIDI,
        max_streams_uni_local = maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI),
        max_streams_uni_remote = ?DEFAULT_MAX_STREAMS_UNI,
        keep_alive_timer = undefined,
        last_activity = erlang:monotonic_time(millisecond),
        cc_state = CCState,
        loss_state = LossState,
        pmtu_state = init_pmtu_state(Opts),
        cfg = #conn_cfg{
            scid = SCID,
            original_dcid = DCID,
            role = client,
            supported_versions = SupportedVersions,
            client_socket_backend = ClientSocketBackend,
            local_addr = LocalAddr,
            conn_ref = ConnRef,
            verify = normalize_verify(maps:get(verify, Opts, true)),
            cacerts = maps:get(cacerts, Opts, undefined),
            client_cert = maps:get(cert, Opts, undefined),
            client_cert_chain = maps:get(cert_chain, Opts, []),
            client_private_key = maps:get(key, Opts, undefined),
            tls_groups = maps:get(groups, Opts, [x25519]),
            tls_sig_algs = maps:get(signature_algs, Opts, undefined),
            alpn_list = AlpnList,
            max_stream_data_bidi_local = maps:get(
                max_stream_data_bidi_local, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA
            ),
            max_stream_data_bidi_remote = maps:get(
                max_stream_data_bidi_remote, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA
            ),
            max_stream_data_uni = maps:get(
                max_stream_data_uni, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA
            ),
            fc_max_receive_window = maps:get(max_receive_window, Opts, ?DEFAULT_MAX_RECEIVE_WINDOW),
            max_owner_queue = maps:get(max_owner_queue, Opts, ?DEFAULT_MAX_OWNER_QUEUE),
            ack_packet_tolerance = maps:get(ack_packet_tolerance, Opts, ?ACK_PACKET_TOLERANCE),
            burst_budget = maps:get(max_burst_packets, Opts, ?DEFAULT_MAX_BURST_PACKETS),
            delivery_coalescing = bool_opt(delivery_coalescing, Opts),
            cipher_preference = maps:get(ciphers, Opts, default_cipher_preference()),
            max_udp_payload_size_local = maps:get(max_udp_payload_size, Opts, undefined),
            max_datagram_frame_size_local = maps:get(max_datagram_frame_size, Opts, 0),
            datagram_recv_queue_len = maps:get(datagram_recv_queue_len, Opts, infinity),
            spin_bit_enabled = maps:get(spin_bit, Opts, true),
            stateless_reset_secret = maps:get(reset_secret, Opts, undefined),
            reset_stream_at_enabled = maps:get(reset_stream_at, Opts, false),
            idle_timeout = IdleTimeoutClient,
            keep_alive_interval = calculate_keep_alive_interval(Opts, IdleTimeoutClient),
            disconnect_timeout = disconnect_timeout_opt(Opts),
            %% TLS 1.3 external PSK (RFC 8446 §4.2.11) — mutually exclusive
            %% with session_ticket; conflict raised by build_client_hello/1.
            external_psk = ExternalPsk,
            congestion_threshold = maps:get(congestion_threshold, Opts, 2),
            pacing_enabled = maps:get(pacing_enabled, Opts, true),
            active_n = maps:get(active_n, Opts, 100),
            pmtu_raise_interval = maps:get(pmtu_raise_interval, Opts, ?PMTU_DEFAULT_RAISE_INTERVAL),
            qlog_ctx = quic_qlog:new(Opts, DCID, client)
        },
        hs = #hs{
            server_name = ServerName,
            initial_keys = InitialKeys,
            retry_token = InitialRetryToken,
            tls_state = ?TLS_AWAITING_SERVER_HELLO,
            tls_group = hd(maps:get(groups, Opts, [x25519])),
            pn_initial = PNSpace,
            pn_handshake = PNSpace,
            %% Store session ticket for resumption
            ticket_store =
                case SessionTicket of
                    undefined -> quic_ticket:new_store();
                    Ticket -> quic_ticket:store_ticket(ServerName, Ticket, quic_ticket:new_store())
                end
        }
    },

    %% Emit qlog connection_started event
    quic_qlog:connection_started((State#state.cfg)#conn_cfg.qlog_ctx),

    %% RFC 9000 §10.1: arm the idle timer once; it re-arms itself lazily
    %% from last_activity (the keep-alive timer is armed on entering the
    %% connected state).
    {ok, idle, set_idle_timer(State)}.

terminate(
    Reason,
    StateName,
    #state{
        socket_state = SocketState,
        pto_timer = PtoTimer,
        idle_timer = IdleTimer,
        keep_alive_timer = KeepAliveTimer,
        pacing_timer = PacingTimer,
        ack_timer = AckTimer,
        cfg = #conn_cfg{
            send_socket = SendSocket,
            role = Role,
            qlog_ctx = QlogCtx
        }
    } = State
) ->
    %% If we're not already draining/closed, try to send CONNECTION_CLOSE.
    %% No owner notification here - either already notified (draining) or
    %% owner is dead. The send batches the close packet into an updated
    %% socket_state; that updated state must be the one flushed below, or
    %% the close never reaches the wire and the peer holds a phantom
    %% connection until its idle timeout (an owner death then looks like a
    %% host that stays connected for up to a minute).
    FlushSocketState =
        case StateName of
            draining ->
                SocketState;
            closed ->
                SocketState;
            _ ->
                try
                    %% Use close_reason from state if set, otherwise use terminate reason
                    CloseReason =
                        case State#state.close_reason of
                            undefined -> Reason;
                            R -> R
                        end,
                    CloseState = send_connection_close(CloseReason, State),
                    CloseState#state.socket_state
                catch
                    _:_ -> SocketState
                end
        end,
    %% Flush any batched packets before closing and close owned sockets
    case FlushSocketState of
        undefined ->
            ok;
        _ ->
            try
                _ = quic_socket:flush(FlushSocketState),
                %% Close socket_state (respects owns_socket flag)
                _ = quic_socket:close(FlushSocketState)
            catch
                _:_ -> ok
            end
    end,
    %% Cancel any active timers
    cancel_timer(PtoTimer),
    cancel_timer(IdleTimer),
    cancel_timer(KeepAliveTimer),
    cancel_timer(PacingTimer),
    cancel_timer(AckTimer),
    %% Close dedicated send socket for server connections (SO_REUSEPORT socket)
    case SendSocket of
        undefined -> ok;
        _ -> gen_udp:close(SendSocket)
    end,
    %% Only close socket for client connections (clients own their socket).
    %% Server connections share the listener's socket and must not close it.
    %% `close_client_socket/1' handles both the gen_udp and socket
    %% backends (the OTP socket was already closed above via
    %% `quic_socket:close(SocketState)'; the receiver process is stopped
    %% here).
    case Role of
        client -> close_client_socket(State);
        _ -> ok
    end,
    %% Close QLOG trace file
    quic_qlog:close(QlogCtx),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%====================================================================
%% State Functions
%%====================================================================

%% ----- IDLE STATE -----

idle(enter, _OldState, #state{cfg = #conn_cfg{role = client}} = State) ->
    %% Client: Start the handshake by sending Initial packet with ClientHello
    {keep_state, send_client_hello(State)};
idle(enter, _OldState, #state{cfg = #conn_cfg{role = server}} = State) ->
    %% Server: Wait for Initial packet with ClientHello
    {keep_state, State};
idle({call, From}, get_ref, #state{cfg = #conn_cfg{conn_ref = Ref}} = State) ->
    {keep_state, State, [{reply, From, Ref}]};
idle({call, From}, get_state, State) ->
    {keep_state, State, [{reply, From, {idle, state_to_map(State)}}]};
idle({call, From}, peername, #state{remote_addr = Addr} = State) ->
    {keep_state, State, [{reply, From, {ok, Addr}}]};
idle({call, From}, sockname, #state{cfg = #conn_cfg{local_addr = Addr}} = State) ->
    {keep_state, State, [{reply, From, {ok, Addr}}]};
idle({call, From}, {set_owner, NewOwner}, State) ->
    {keep_state, reown(State, NewOwner), [{reply, From, ok}]};
idle(cast, {set_owner, NewOwner}, State) ->
    {keep_state, reown(State, NewOwner)};
%% 0-RTT: Allow opening streams in idle state if early keys are available
idle({call, From}, open_stream, #state{hs = #hs{early_keys = undefined}} = State) ->
    {keep_state, State, [{reply, From, {error, not_connected}}]};
idle({call, From}, open_stream, #state{hs = #hs{early_keys = _EarlyKeys}} = State) ->
    case do_open_stream(State) of
        {ok, StreamId, NewState} ->
            {keep_state, NewState, [{reply, From, {ok, StreamId}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% 0-RTT: HTTP/3 opens its control and QPACK unidirectional streams as early
%% data, so the idle state must allow opening uni streams once early keys are
%% present (mirrors open_stream above).
idle({call, From}, open_unidirectional_stream, #state{hs = #hs{early_keys = undefined}} = State) ->
    {keep_state, State, [{reply, From, {error, not_connected}}]};
idle({call, From}, open_unidirectional_stream, #state{hs = #hs{early_keys = _EarlyKeys}} = State) ->
    case do_open_unidirectional_stream(State) of
        {ok, StreamId, NewState} ->
            {keep_state, NewState, [{reply, From, {ok, StreamId}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% 0-RTT sending is client-only (RFC 9000 §17.2.3), here as in the
%% handshaking state: a server handler answering early data delivered
%% before the handshake completes must queue, or the response goes out
%% as a 0-RTT packet the client can never decrypt.
idle(
    {call, From},
    {send_data, StreamId, Data, Fin},
    #state{cfg = #conn_cfg{role = client}, hs = #hs{early_keys = EarlyKeys}} = State
) when EarlyKeys =/= undefined ->
    case do_send_zero_rtt_data(StreamId, Data, Fin, State) of
        {ok, NewState} ->
            {keep_state, NewState, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
idle(
    {call, From},
    {send_data, StreamId, Data, Fin},
    #state{
        pending_data = Pending
    } = State
) ->
    case length(Pending) >= ?MAX_PENDING_DATA_ENTRIES of
        true ->
            {keep_state, State, [{reply, From, {error, pending_data_limit}}]};
        false ->
            NewPending = Pending ++ [{StreamId, Data, Fin}],
            {keep_state, State#state{pending_data = NewPending}, [{reply, From, ok}]}
    end;
idle(info, {udp, Socket, _IP, _Port, Data}, #state{socket = Socket} = State) ->
    NewState = handle_packet(Data, State),
    %% Flush batched packets and timers after processing incoming data
    FlushedState = flush_event(NewState, event),
    check_state_transition(idle, FlushedState);
idle(info, {udp_batch, Socket, _IP, _Port, Packets}, #state{socket = Socket} = State) ->
    NewState = handle_packets_batch(Packets, State),
    FlushedState = flush_event(NewState, event),
    check_state_transition(idle, FlushedState);
%% Server receives packets from listener
idle(info, {quic_packet, Data, _RemoteAddr}, #state{cfg = #conn_cfg{role = server}} = State) ->
    NewState = handle_packet(Data, State),
    %% Flush batched packets and timers after processing incoming data
    FlushedState = flush_event(NewState, event),
    check_state_transition(idle, FlushedState);
%% Server receives batched packets from listener (GRO optimization)
idle(info, {quic_packets, Packets, _RemoteAddr}, #state{cfg = #conn_cfg{role = server}} = State) ->
    NewState = handle_packets_batch(Packets, State),
    FlushedState = flush_event(NewState, event),
    check_state_transition(idle, FlushedState);
idle(cast, process, #state{cfg = #conn_cfg{role = client, active_n = N}} = State) ->
    %% Re-enable socket for receiving (client only - server uses listener's socket)
    client_rearm_active(State, N),
    {keep_state, State};
idle(cast, process, #state{cfg = #conn_cfg{role = server}} = State) ->
    %% Server connections receive via listener, don't touch socket options
    {keep_state, State};
idle(cast, {close, Reason}, State) ->
    %% Close in idle state - no keys yet, just transition to draining
    emit_qlog_state_change(idle, draining, State),
    State1 = initiate_close(Reason, State),
    NewState = flush_event(State1, event),
    {next_state, draining, NewState};
idle({call, From}, has_early_keys, #state{hs = #hs{early_keys = EK}} = State) ->
    {keep_state, State, [{reply, From, EK =/= undefined}]};
idle({call, From}, early_data_accepted, State) ->
    {keep_state, State, [{reply, From, unknown}]};
idle(EventType, EventContent, State) ->
    handle_common_event(EventType, EventContent, idle, State).

%% ----- HANDSHAKING STATE -----

handshaking(enter, idle, State) ->
    {keep_state, arm_disconnect_timer(State)};
handshaking({call, From}, get_ref, #state{cfg = #conn_cfg{conn_ref = Ref}} = State) ->
    {keep_state, State, [{reply, From, Ref}]};
handshaking({call, From}, get_state, State) ->
    {keep_state, State, [{reply, From, {handshaking, state_to_map(State)}}]};
handshaking({call, From}, peername, #state{remote_addr = Addr} = State) ->
    {keep_state, State, [{reply, From, {ok, Addr}}]};
handshaking({call, From}, sockname, #state{cfg = #conn_cfg{local_addr = Addr}} = State) ->
    {keep_state, State, [{reply, From, {ok, Addr}}]};
handshaking({call, From}, {set_owner, NewOwner}, State) ->
    {keep_state, reown(State, NewOwner), [{reply, From, ok}]};
handshaking(cast, {set_owner, NewOwner}, State) ->
    {keep_state, reown(State, NewOwner)};
%% 0-RTT: Allow opening streams during handshake if early keys are available
handshaking({call, From}, open_stream, #state{hs = #hs{early_keys = undefined}} = State) ->
    %% No early keys, must wait for handshake to complete
    {keep_state, State, [{reply, From, {error, not_connected}}]};
handshaking({call, From}, open_stream, #state{hs = #hs{early_keys = _EarlyKeys}} = State) ->
    %% Early keys available, can open stream for 0-RTT
    case do_open_stream(State) of
        {ok, StreamId, NewState} ->
            {keep_state, NewState, [{reply, From, {ok, StreamId}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% 0-RTT: HTTP/3 opens its control and QPACK streams as early data, and
%% the connection can be past `idle' by the time it does (mirrors idle).
handshaking(
    {call, From}, open_unidirectional_stream, #state{hs = #hs{early_keys = undefined}} = State
) ->
    {keep_state, State, [{reply, From, {error, not_connected}}]};
handshaking({call, From}, open_unidirectional_stream, State) ->
    case do_open_unidirectional_stream(State) of
        {ok, StreamId, NewState} ->
            {keep_state, NewState, [{reply, From, {ok, StreamId}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% 0-RTT: Allow sending data during handshake if early keys are available
handshaking(
    {call, From},
    {send_data, StreamId, Data, Fin},
    #state{cfg = #conn_cfg{role = client}, hs = #hs{early_keys = EarlyKeys}} = State
) when EarlyKeys =/= undefined ->
    %% Send as 0-RTT data. 0-RTT sending is a client-only affair (RFC
    %% 9000 §17.2.3): a server also holds early keys, but only for
    %% receiving. Answering early data before the handshake completes
    %% must not go out in a 0-RTT packet the client can never decrypt,
    %% so the server queues below and the data goes out 1-RTT on
    %% connected.
    case do_send_zero_rtt_data(StreamId, Data, Fin, State) of
        {ok, NewState} ->
            {keep_state, NewState, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
handshaking(
    {call, From},
    {send_data, StreamId, Data, Fin},
    #state{pending_data = Pending} = State
) ->
    %% No usable send keys yet, queue the data for later (with limit to
    %% prevent memory exhaustion)
    case length(Pending) >= ?MAX_PENDING_DATA_ENTRIES of
        true ->
            {keep_state, State, [{reply, From, {error, pending_data_limit}}]};
        false ->
            NewPending = Pending ++ [{StreamId, Data, Fin}],
            {keep_state, State#state{pending_data = NewPending}, [{reply, From, ok}]}
    end;
handshaking(info, {udp, Socket, _IP, _Port, Data}, #state{socket = Socket} = State) ->
    NewState = handle_packet(Data, State),
    %% Flush batched packets and timers after processing incoming data
    FlushedState = flush_event(NewState, event),
    check_state_transition(handshaking, FlushedState);
handshaking(info, {udp_batch, Socket, _IP, _Port, Packets}, #state{socket = Socket} = State) ->
    NewState = handle_packets_batch(Packets, State),
    FlushedState = flush_event(NewState, event),
    check_state_transition(handshaking, FlushedState);
%% Server receives packets from listener
handshaking(info, {quic_packet, Data, _RemoteAddr}, #state{cfg = #conn_cfg{role = server}} = State) ->
    NewState = handle_packet(Data, State),
    %% Flush batched packets and timers after processing incoming data
    FlushedState = flush_event(NewState, event),
    check_state_transition(handshaking, FlushedState);
%% Server receives batched packets from listener (GRO optimization)
handshaking(
    info, {quic_packets, Packets, _RemoteAddr}, #state{cfg = #conn_cfg{role = server}} = State
) ->
    NewState = handle_packets_batch(Packets, State),
    FlushedState = flush_event(NewState, event),
    check_state_transition(handshaking, FlushedState);
handshaking(cast, process, #state{cfg = #conn_cfg{role = client, active_n = N}} = State) ->
    %% Re-enable socket for receiving (client only - server uses listener's socket)
    client_rearm_active(State, N),
    {keep_state, State};
handshaking(cast, process, #state{cfg = #conn_cfg{role = server}} = State) ->
    %% Server connections receive via listener, don't touch socket options
    {keep_state, State};
handshaking(cast, {close, Reason}, State) ->
    %% Close during handshake - may not have app keys yet
    emit_qlog_state_change(handshaking, draining, State),
    State1 = initiate_close(Reason, State),
    NewState = flush_event(State1, event),
    {next_state, draining, NewState};
handshaking({call, From}, has_early_keys, #state{hs = #hs{early_keys = EK}} = State) ->
    {keep_state, State, [{reply, From, EK =/= undefined}]};
handshaking({call, From}, early_data_accepted, State) ->
    {keep_state, State, [{reply, From, unknown}]};
handshaking(EventType, EventContent, State) ->
    handle_common_event(EventType, EventContent, handshaking, State).

%% ----- CONNECTED STATE -----

connected(
    enter,
    OldState,
    #state{
        owner = Owner,
        alpn = Alpn,
        pending_data = Pending,
        transport_params = TransportParams,
        cfg = #conn_cfg{
            role = Role,
            active_n = ActiveN
        },
        hs = #hs{
            negotiated_group = NegGroup,
            negotiated_scheme = NegScheme
        }
    } = State
) when
    OldState =:= handshaking; OldState =:= idle
->
    %% Notify owner that connection is established
    Info = #{
        alpn => Alpn,
        alpn_protocol => Alpn,
        transport_params => TransportParams,
        negotiated_group => NegGroup,
        negotiated_scheme => NegScheme
    },
    Owner ! {quic, self(), {connected, Info}},
    %% For client connections, ensure socket is active for receiving
    %% Server connections receive via listener (quic_packet messages)
    case Role of
        client -> client_rearm_active(State, ActiveN);
        server -> ok
    end,
    %% Send any data that was queued before connection established
    State1 = arm_disconnect_timer(State#state{pending_data = []}),
    State2 = send_pending_data(Pending, State1),
    %% RFC 9000 Section 9.6: Client validates server's preferred address
    State3 =
        case Role of
            client ->
                case maps:get(preferred_address, TransportParams, undefined) of
                    undefined ->
                        State2;
                    PA when is_record(PA, preferred_address) ->
                        initiate_preferred_address_validation(PA, State2);
                    _ ->
                        State2
                end;
            server ->
                State2
        end,
    %% RFC 9000 §8.1.3: server issues a NEW_TOKEN so the client can
    %% skip retry on the next reconnect. Only when a token secret is
    %% available; clients don't issue tokens.
    State3b = maybe_send_new_token(State3),
    %% Refresh activity and arm the keep-alive timer now that we're connected:
    %% its handler runs only in the connected state, so arming it earlier
    %% would risk a handshake-phase fire being dropped without a re-arm. The
    %% idle timer was already armed at init.
    State4 = set_keep_alive_timer(update_last_activity(State3b)),
    %% RFC 9000 §5.1.1: give the peer spare CIDs to migrate onto. This is
    %% the first point where both halves are in place: the peer's
    %% active_connection_id_limit arrived with its transport parameters,
    %% and NEW_CONNECTION_ID travels in a 1-RTT packet, so the app keys
    %% the send path destructures must already exist.
    State4b = issue_new_connection_ids(State4),
    %% RFC 8899: Initialize PMTU discovery after handshake
    State5 = init_pmtu_probing(TransportParams, State4b),
    %% Everything queued above (pending data, NEW_TOKEN, the first PMTU
    %% probe) sits in the send batch; without a flush here it would
    %% only leave with the next event on this connection.
    {keep_state, flush_event(State5, event)};
connected({call, From}, get_ref, #state{cfg = #conn_cfg{conn_ref = Ref}} = State) ->
    {keep_state, State, [{reply, From, Ref}]};
connected({call, From}, get_state, State) ->
    {keep_state, State, [{reply, From, {connected, state_to_map(State)}}]};
connected({call, From}, peername, #state{remote_addr = Addr} = State) ->
    {keep_state, State, [{reply, From, {ok, Addr}}]};
connected({call, From}, sockname, #state{cfg = #conn_cfg{local_addr = Addr}} = State) ->
    {keep_state, State, [{reply, From, {ok, Addr}}]};
connected({call, From}, peercert, #state{hs = #hs{peer_cert = undefined}} = State) ->
    {keep_state, State, [{reply, From, {error, no_peercert}}]};
connected({call, From}, peercert, #state{hs = #hs{peer_cert = Cert}} = State) ->
    {keep_state, State, [{reply, From, {ok, Cert}}]};
connected({call, From}, datagram_max_size, #state{max_datagram_frame_size_remote = Size} = State) ->
    {keep_state, State, [{reply, From, Size}]};
connected({call, From}, datagram_stats, State) ->
    {keep_state, State, [{reply, From, datagram_stats_snapshot(State)}]};
connected({call, From}, {set_owner, NewOwner}, #state{alpn = Alpn, transport_params = TP} = State) ->
    %% Notify new owner that connection is already established
    Info = #{alpn => Alpn, alpn_protocol => Alpn, transport_params => TP},
    NewOwner ! {quic, self(), {connected, Info}},
    {keep_state, reown(State, NewOwner), [{reply, From, ok}]};
connected(cast, {set_owner, NewOwner}, #state{alpn = Alpn, transport_params = TP} = State) ->
    %% Notify new owner that connection is already established
    Info = #{alpn => Alpn, alpn_protocol => Alpn, transport_params => TP},
    NewOwner ! {quic, self(), {connected, Info}},
    {keep_state, reown(State, NewOwner)};
connected({call, From}, {send_datagram, Data}, State) ->
    case do_send_datagram(Data, State) of
        {ok, NewState} ->
            %% Event-driven flush: flush batch and timers after user API call
            FlushedState = flush_event(NewState, event),
            {keep_state, FlushedState, [{reply, From, ok}]};
        {error, Reason, NewState} ->
            {keep_state, NewState, [{reply, From, {error, Reason}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
connected({call, From}, {send_data, StreamId, Data, Fin}, State) ->
    coalesced_sends([{From, StreamId, Data, Fin}], State);
connected({call, From}, open_stream, State) ->
    case do_open_stream(State) of
        {ok, StreamId, NewState} ->
            {keep_state, NewState, [{reply, From, {ok, StreamId}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
connected({call, From}, open_unidirectional_stream, State) ->
    case do_open_unidirectional_stream(State) of
        {ok, StreamId, NewState} ->
            {keep_state, NewState, [{reply, From, {ok, StreamId}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
connected({call, From}, {close_stream, StreamId, ErrorCode}, State) ->
    case do_close_stream(StreamId, ErrorCode, State) of
        {ok, NewState} ->
            {keep_state, flush_event(NewState, event), [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% RESET_STREAM_AT: Reset with reliable delivery up to ReliableSize
%% (draft-ietf-quic-reliable-stream-reset-07)
connected({call, From}, {reset_stream_at, StreamId, ErrorCode, ReliableSize}, State) ->
    case do_reset_stream_at(StreamId, ErrorCode, ReliableSize, State) of
        {ok, NewState} ->
            {keep_state, flush_event(NewState, event), [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% STOP_SENDING: Request peer to stop sending on a stream (RFC 9000 Section 19.5)
connected({call, From}, {stop_sending, StreamId, ErrorCode}, State) ->
    case do_stop_sending(StreamId, ErrorCode, State) of
        {ok, NewState} ->
            {keep_state, flush_event(NewState, event), [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% Stream prioritization (RFC 9218)
connected({call, From}, {set_stream_priority, StreamId, Urgency, Incremental}, State) ->
    case do_set_stream_priority(StreamId, Urgency, Incremental, State) of
        {ok, NewState} ->
            {keep_state, NewState, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
connected({call, From}, {get_stream_priority, StreamId}, State) ->
    case do_get_stream_priority(StreamId, State) of
        {ok, Priority} ->
            {keep_state, State, [{reply, From, {ok, Priority}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% Congestion control
connected({call, From}, {set_congestion_control, Algorithm}, State) ->
    case do_set_congestion_control(Algorithm, State) of
        {ok, NewState} ->
            {keep_state, NewState, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% Stream deadlines
connected({call, From}, {set_stream_deadline, StreamId, TimeoutMs, Opts}, State) ->
    case do_set_stream_deadline(StreamId, TimeoutMs, Opts, State) of
        {ok, NewState} ->
            {keep_state, NewState, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
connected({call, From}, {cancel_stream_deadline, StreamId}, State) ->
    case do_cancel_stream_deadline(StreamId, State) of
        {ok, NewState} ->
            {keep_state, NewState, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
connected({call, From}, {get_stream_deadline, StreamId}, State) ->
    case do_get_stream_deadline(StreamId, State) of
        {ok, Result} ->
            {keep_state, State, [{reply, From, {ok, Result}}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
connected({call, From}, {setopts, _Opts}, State) ->
    {keep_state, State, [{reply, From, ok}]};
connected(
    {call, From},
    get_send_queue_info,
    #state{
        send_queue_bytes = Bytes,
        cc_state = CCState,
        cfg = #conn_cfg{
            congestion_threshold = Threshold
        }
    } = State
) ->
    Cwnd = quic_cc:cwnd(CCState),
    InFlight = quic_cc:bytes_in_flight(CCState),
    InRecovery = quic_cc:in_recovery(CCState),
    %% Congested if queue > cwnd * threshold OR in recovery with queue > cwnd
    Congested = (Bytes > Cwnd * Threshold) orelse (InRecovery andalso Bytes > Cwnd),
    Info = #{
        bytes => Bytes,
        cwnd => Cwnd,
        in_flight => InFlight,
        in_recovery => InRecovery,
        congested => Congested
    },
    {keep_state, State, [{reply, From, {ok, Info}}]};
connected(
    {call, From},
    get_path_stats,
    #state{
        send_queue_bytes = Bytes,
        cc_state = CCState,
        loss_state = LossState,
        cfg = #conn_cfg{
            congestion_threshold = Threshold
        }
    } = State
) ->
    Cwnd = quic_cc:cwnd(CCState),
    InFlight = quic_cc:bytes_in_flight(CCState),
    InRecovery = quic_cc:in_recovery(CCState),
    Congested = (Bytes > Cwnd * Threshold) orelse (InRecovery andalso Bytes > Cwnd),
    %% quic_loss tracks RTT in milliseconds; the public contract is
    %% microseconds. Convert at read time so the underlying state
    %% stays untouched. min_rtt is `infinity' before the first sample
    %% lands; surface it as 0 so callers can rely on non_neg_integer.
    MinRttMs =
        case quic_rtt:min(quic_loss:rtt(LossState)) of
            infinity -> 0;
            M -> M
        end,
    Stats = #{
        srtt => quic_rtt:smoothed(quic_loss:rtt(LossState)) * 1000,
        latest_rtt => quic_rtt:latest(quic_loss:rtt(LossState)) * 1000,
        min_rtt => MinRttMs * 1000,
        rtt_var => quic_rtt:var(quic_loss:rtt(LossState)) * 1000,
        cwnd => Cwnd,
        bytes_in_flight => InFlight,
        in_recovery => InRecovery,
        congested => Congested
    },
    {keep_state, State, [{reply, From, {ok, Stats}}]};
connected(
    {call, From},
    get_stats,
    #state{
        data_received = DataRecv,
        data_sent = DataSent,
        socket_state = SocketState,
        hs = #hs{
            zero_rtt_stream_ids = ZeroRttStreams
        }
    } = State
) ->
    %% Return packet counts for liveness detection (net_kernel uses
    %% recv count to verify peer is alive) plus send-path batching
    %% counters for benchmarks and tests.
    {Flushes, Coalesced, GSOFlushes, Pending} = send_batch_counters(SocketState),
    Stats = #{
        packets_received => count(?C_PACKETS_RECEIVED, State),
        packets_sent => count(?C_PACKETS_SENT, State),
        data_received => DataRecv,
        data_sent => DataSent,
        ack_sent => count(?C_ACK_SENT, State),
        retransmits => count(?C_RETRANSMITS, State),
        %% Streams that carried 0-RTT-encrypted data and kept it. A
        %% rejection clears them (RFC 9001 Section 4.6.2), so a non-zero
        %% value here means early data was sent and the server took it.
        zero_rtt_streams => sets:size(ZeroRttStreams),
        %% Writes refused as backpressure; each is logged at debug only.
        send_queue_full_refusals => count(?C_SEND_QUEUE_FULL_REFUSALS, State),
        batch_flushes => Flushes,
        packets_coalesced => Coalesced,
        gso_flushes => GSOFlushes,
        %% Packets built but not yet handed to the socket. Non-zero
        %% between events means a handler forgot to flush.
        send_batch_pending => Pending
    },
    {keep_state, State, [{reply, From, {ok, Stats}}]};
connected({call, From}, get_peer_transport_params, #state{transport_params = TP} = State) ->
    {keep_state, State, [{reply, From, {ok, TP}}]};
connected({call, From}, send_ping, State) ->
    %% Send PING frame - bypasses congestion control
    NewState = send_keep_alive_ping(State),
    {keep_state, flush_event(NewState, event), [{reply, From, ok}]};
connected({call, From}, get_mtu, State) ->
    MTU = get_current_mtu(State),
    {keep_state, State, [{reply, From, {ok, MTU}}]};
connected({call, From}, key_update, #state{key_state = undefined} = State) ->
    {keep_state, State, [{reply, From, {error, no_keys}}]};
connected({call, From}, key_update, #state{key_state = KeyState} = State) ->
    case KeyState#key_update_state.update_state of
        idle ->
            %% Initiate key update
            NewState = initiate_key_update(State),
            {keep_state, NewState, [{reply, From, ok}]};
        _ ->
            %% Key update already in progress
            {keep_state, State, [{reply, From, {error, key_update_in_progress}}]}
    end;
%% Handle connection migration request (RFC 9000 Section 9)
connected({call, From}, migrate, #state{mig = #mig{peer_disable_migration = true}} = State) ->
    %% Peer disabled migration via transport params
    {keep_state, State, [{reply, From, {error, migration_disabled}}]};
connected({call, From}, migrate, #state{remote_addr = RemoteAddr} = State) ->
    %% RFC 9000 Section 9.5: an endpoint with no unused CID cannot probe a
    %% new path, so the pool is checked before the socket is rebound. The
    %% other order leaves the connection on a new local address still using
    %% the old path's CID, which is the reuse the section forbids.
    case has_unused_cid(State) of
        false ->
            {keep_state, State, [{reply, From, {error, no_available_connection_id}}]};
        true ->
            case rebind_client_socket(State) of
                {ok, State1} ->
                    {keep_state, migrate_to(RemoteAddr, State1), [{reply, From, ok}]};
                {error, Reason} ->
                    {keep_state, State, [{reply, From, {error, Reason}}]}
            end
    end;
%% Handle migration with options
connected(
    {call, From}, {migrate, _Opts}, #state{mig = #mig{peer_disable_migration = true}} = State
) ->
    {keep_state, State, [{reply, From, {error, migration_disabled}}]};
connected({call, From}, {migrate, _Opts}, #state{remote_addr = RemoteAddr} = State) ->
    case has_unused_cid(State) of
        false ->
            {keep_state, State, [{reply, From, {error, no_available_connection_id}}]};
        true ->
            case rebind_client_socket(State) of
                {ok, State1} ->
                    {keep_state, migrate_to(RemoteAddr, State1), [{reply, From, ok}]};
                {error, Reason} ->
                    {keep_state, State, [{reply, From, {error, Reason}}]}
            end
    end;
connected(info, {udp, Socket, IP, Port, Data}, #state{socket = Socket} = State) ->
    %% Track packet source for PATH_RESPONSE routing (RFC 9000 Section 8.2.2)
    State1 = State#state{current_packet_source = {IP, Port}, recv_pass = true},
    NewState = handle_packet(Data, State1),
    %% Drain any further datagrams already in the mailbox into this
    %% pass, then flush ACKs / batches / timers once for the lot.
    FinalState = flush_event(flush_recv_pass(drain_recv_msgs(NewState, ?RECV_DRAIN_MAX)), pass),
    check_state_transition(connected, FinalState);
%% Client receives a whole GRO train from the receiver process as one
%% message; processing it in one pass amortizes the per-event flushes
%% over the train.
connected(info, {udp_batch, Socket, IP, Port, Packets}, #state{socket = Socket} = State) ->
    State1 = State#state{current_packet_source = {IP, Port}, recv_pass = true},
    NewState = handle_packets_batch(Packets, State1),
    FinalState = flush_event(flush_recv_pass(drain_recv_msgs(NewState, ?RECV_DRAIN_MAX)), pass),
    check_state_transition(connected, FinalState);
%% Server receives packets from listener
connected(info, {quic_packet, Data, RemoteAddr}, #state{cfg = #conn_cfg{role = server}} = State) ->
    NewState = server_recv_pass([Data], RemoteAddr, State),
    FinalState = flush_event(flush_recv_pass(drain_recv_msgs(NewState, ?RECV_DRAIN_MAX)), pass),
    check_state_transition(connected, FinalState);
%% Server receives batched packets from listener (GRO optimization)
connected(
    info, {quic_packets, Packets, RemoteAddr}, #state{cfg = #conn_cfg{role = server}} = State
) ->
    NewState = server_recv_pass(Packets, RemoteAddr, State),
    FinalState = flush_event(flush_recv_pass(drain_recv_msgs(NewState, ?RECV_DRAIN_MAX)), pass),
    check_state_transition(connected, FinalState);
%% Path validation timeout - stay on current path if validation fails
%% Match on token (not timer ref) to correlate with specific validation attempt
connected(
    info,
    {path_validation_timeout, Token},
    #state{mig = #mig{path_validation_token = Token}} = State
) when Token =/= undefined ->
    %% Token matches - this is the current validation attempt
    _ = cancel_timer((State#state.mig)#mig.path_validation_timer),
    State1 = State#state{
        mig = (State#state.mig)#mig{
            path_validation_timer = undefined, path_validation_token = undefined
        }
    },
    handle_path_validation_timeout(State1);
connected(info, {path_validation_timeout, _StaleToken}, State) ->
    %% Stale token from canceled validation - ignore
    {keep_state, State};
connected(cast, {close, Reason}, State) ->
    emit_qlog_state_change(connected, draining, State),
    State1 = initiate_close(Reason, State),
    NewState = flush_event(State1, event),
    {next_state, draining, NewState};
%% Async send data - fire-and-forget for high throughput
connected(cast, {send_data_async, StreamId, Data, Fin}, State) ->
    coalesced_sends([{async, StreamId, Data, Fin}], State);
connected(cast, process, #state{cfg = #conn_cfg{role = client, active_n = N}} = State) ->
    %% Re-enable socket for receiving (client only - server uses listener's socket)
    client_rearm_active(State, N),
    {keep_state, State};
connected(cast, process, #state{cfg = #conn_cfg{role = server}} = State) ->
    %% Server connections receive via listener, don't touch socket options
    {keep_state, State};
%% Handle delayed ACK timer (RFC 9000 §13.2.1 / RFC 9221 §5.2).
%% Validates reference to ignore stale timer events.
connected(info, {timeout, Ref, send_delayed_ack}, #state{ack_timer = Ref} = State) ->
    %% send_app_ack/1 clears ack_timer + ack_elicited_count.
    State1 = send_app_ack(State),
    NewState = flush_event(State1, event),
    {keep_state, NewState};
connected(info, {timeout, _StaleRef, send_delayed_ack}, State) ->
    %% Stale timer — ignore.
    {keep_state, State};
%% Handle PMTU probe timeout (RFC 8899)
%% Validates reference to ignore stale timer events
connected(
    info, {pmtu_probe_timeout, Ref}, #state{pmtu_probe_timer = Ref, pmtu_state = PMTUState} = State
) when
    Ref =/= undefined
->
    NewPMTUState = quic_pmtu:on_probe_timeout(PMTUState),
    State1 = State#state{
        pmtu_state = NewPMTUState,
        pmtu_probe_timer = undefined
    },
    %% Retry probing if needed
    State2 = maybe_send_pmtu_probe(State1),
    {keep_state, State2};
connected(info, {pmtu_probe_timeout, _StaleRef}, State) ->
    %% Stale PMTU probe timer - ignore
    {keep_state, State};
%% Handle PMTU raise timer (periodic re-probing)
%% Validates reference to ignore stale timer events
connected(
    info, {pmtu_raise_timeout, Ref}, #state{pmtu_raise_timer = Ref, pmtu_state = PMTUState} = State
) when
    Ref =/= undefined
->
    %% Probe higher from current MTU (don't reset to base)
    NewPMTUState = quic_pmtu:on_raise_timer(PMTUState),
    State1 = State#state{
        pmtu_state = NewPMTUState,
        pmtu_raise_timer = undefined
    },
    State2 = maybe_send_pmtu_probe(State1),
    {keep_state, State2};
connected(info, {pmtu_raise_timeout, _StaleRef}, State) ->
    %% Stale PMTU raise timer - ignore
    {keep_state, State};
%% Handle stream deadline expiry
connected(info, {stream_deadline, StreamId}, State) ->
    case handle_stream_deadline_expired(StreamId, State) of
        {ok, NewState} ->
            {keep_state, NewState};
        {error, _Reason} ->
            %% Stream already closed or doesn't exist
            {keep_state, State}
    end;
connected({call, From}, has_early_keys, #state{hs = #hs{early_keys = EK}} = State) ->
    {keep_state, State, [{reply, From, EK =/= undefined}]};
connected({call, From}, early_data_accepted, #state{hs = #hs{early_data_accepted = EDA}} = State) ->
    {keep_state, State, [{reply, From, EDA}]};
connected(EventType, EventContent, State) ->
    handle_common_event(EventType, EventContent, connected, State).

%% ----- DRAINING STATE -----

draining(
    enter,
    _OldState,
    #state{
        owner = Owner,
        close_reason = Reason,
        loss_state = LossState,
        cfg = #conn_cfg{
            qlog_ctx = QlogCtx
        }
    } = State
) ->
    %% Extract reason phrase for qlog
    ReasonPhrase =
        case Reason of
            {app_error, _, Phrase} -> Phrase;
            {peer_closed, application, _, Phrase} -> Phrase;
            {peer_closed, transport, _, _, Phrase} -> Phrase;
            _ -> undefined
        end,
    %% Emit qlog connection_closed event
    quic_qlog:connection_closed(QlogCtx, close_reason_to_code(Reason), ReasonPhrase),

    Owner ! {quic, self(), {closed, Reason}},
    %% Start drain timer (3 * PTO per RFC 9000 Section 10.2)
    DrainTimeout =
        case LossState of
            % Fallback if loss state not initialized
            undefined -> 3000;
            _ -> 3 * quic_loss:get_pto(LossState, app)
        end,
    TimerRef = erlang:send_after(DrainTimeout, self(), drain_timeout),
    {keep_state, State#state{timer_ref = TimerRef}};
draining({call, From}, get_state, State) ->
    {keep_state, State, [{reply, From, {draining, state_to_map(State)}}]};
draining(info, drain_timeout, State) ->
    {next_state, closed, State};
draining(info, {udp, _Socket, _IP, _Port, _Data}, State) ->
    %% Ignore packets in draining state
    {keep_state, State};
draining(cast, {close, _Reason}, State) ->
    %% Ignore duplicate close requests - already draining
    {keep_state, State};
draining({call, From}, has_early_keys, #state{hs = #hs{early_keys = EK}} = State) ->
    {keep_state, State, [{reply, From, EK =/= undefined}]};
draining({call, From}, early_data_accepted, #state{hs = #hs{early_data_accepted = EDA}} = State) ->
    {keep_state, State, [{reply, From, EDA}]};
draining(EventType, EventContent, State) ->
    handle_common_event(EventType, EventContent, draining, State).

%% ----- CLOSED STATE -----

closed(enter, _OldState, State) ->
    {stop, normal, State};
closed({call, From}, get_state, State) ->
    {keep_state, State, [{reply, From, {closed, state_to_map(State)}}]};
closed({call, From}, has_early_keys, #state{hs = #hs{early_keys = EK}} = State) ->
    {keep_state, State, [{reply, From, EK =/= undefined}]};
closed({call, From}, early_data_accepted, #state{hs = #hs{early_data_accepted = EDA}} = State) ->
    {keep_state, State, [{reply, From, EDA}]};
closed(_EventType, _EventContent, State) ->
    {keep_state, State}.

%%====================================================================
%% Common Event Handling
%%====================================================================

handle_common_event(cast, notify_send_ready, _StateName, State) ->
    {keep_state, maybe_send_ready(State#state{send_ready_wanted = true})};
handle_common_event(cast, {set_stream_flow_control, StreamId, Mode}, StateName, State) ->
    {keep_state, flush_after_grant(StateName, set_recv_flow(StreamId, Mode, StateName, State))};
handle_common_event(cast, {stream_consumed, StreamId, Offset}, StateName, State) ->
    {keep_state, flush_after_grant(StateName, recv_consumed(StreamId, Offset, StateName, State))};
handle_common_event({call, From}, {stream_flow_control, StreamId, Mode}, StateName, State) ->
    case State#state.streams of
        #{StreamId := #stream_state{recv_flow = Mode}} ->
            {keep_state, State, [{reply, From, ok}]};
        #{StreamId := _} ->
            %% Everything delivered so far is still to be consumed.
            Flow =
                case Mode of
                    manual -> {manual, 0};
                    auto -> auto
                end,
            State1 = flush_after_grant(StateName, set_recv_flow(StreamId, Flow, StateName, State)),
            {keep_state, State1, [{reply, From, ok}]};
        _ ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end;
handle_common_event({call, From}, {consume, StreamId, Bytes}, StateName, State) ->
    case State#state.streams of
        #{StreamId := #stream_state{recv_flow = manual, recv_consumed = Consumed}} ->
            State1 = recv_consumed(StreamId, Consumed + Bytes, StateName, State),
            {keep_state, flush_after_grant(StateName, State1), [{reply, From, ok}]};
        #{StreamId := _} ->
            {keep_state, State, [{reply, From, ok}]};
        _ ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end;
handle_common_event(
    {call, From}, get_ref, _StateName, #state{cfg = #conn_cfg{conn_ref = Ref}} = State
) ->
    {keep_state, State, [{reply, From, Ref}]};
handle_common_event({call, From}, get_path_stats, _StateName, State) ->
    {keep_state, State, [{reply, From, {error, not_connected}}]};
handle_common_event(cast, handle_timeout, _StateName, State) ->
    %% Handle loss detection / idle timeout
    NewState = check_timeouts(State),
    {keep_state, NewState};
%% The retained client Finished flight has its own schedule: resend it
%% until the server confirms the handshake. Nothing else is guaranteed
%% to be in flight once the statem has left `handshaking', so without
%% this a Finished lost twice was never resent.
%% `idle' is included because the early handshake runs there: a probe
%% for the Initial or Handshake space fires before the state machine has
%% reached `handshaking', and dropping it wedges the handshake.
handle_common_event(info, {pto_timeout, Ref}, StateName, #state{pto_timer = Ref} = State) when
    Ref =/= undefined andalso
        (StateName =:= connected orelse StateName =:= handshaking orelse StateName =:= idle)
->
    case pto_due(State) of
        idle ->
            {keep_state, State#state{pto_timer = undefined, pto_armed_at = undefined}};
        {later, Remaining} ->
            {keep_state, arm_pto_timer(Remaining, State)};
        due ->
            State1 = State#state{pto_timer = undefined, pto_armed_at = undefined},
            case disconnect_timeout_expired(State1) of
                true ->
                    {next_state, draining, declare_peer_dead(State1)};
                false when State1#state.pto_kind =:= loss ->
                    {keep_state, handle_loss_timeout(State1)};
                false ->
                    %% Handle PTO timeout - send probe packet
                    {keep_state, handle_pto_timeout(State1)}
            end
    end;
handle_common_event(
    info, {disconnect_check, Ref}, StateName, #state{disconnect_timer = Ref} = State
) when
    Ref =/= undefined andalso (StateName =:= connected orelse StateName =:= handshaking)
->
    State1 = State#state{disconnect_timer = undefined},
    case disconnect_timeout_expired(State1) of
        true ->
            {next_state, draining, declare_peer_dead(State1)};
        false ->
            {keep_state, arm_disconnect_timer(State1)}
    end;
handle_common_event(info, {credit_retry, Ref}, StateName, #state{credit_timer = Ref} = State) ->
    State1 = State#state{credit_timer = undefined},
    case StateName of
        connected -> {keep_state, flush_after_grant(connected, release_withheld_credit(State1))};
        _ -> {keep_state, State1}
    end;
handle_common_event(info, {credit_retry, _StaleRef}, _StateName, State) ->
    {keep_state, State};
handle_common_event(info, {disconnect_check, _StaleRef}, _StateName, State) ->
    %% Stale disconnect timer (ref doesn't match or wrong state)
    {keep_state, State};
handle_common_event(info, {pto_timeout, _StaleRef}, _StateName, State) ->
    %% Ignore stale PTO timer (ref doesn't match or wrong state)
    {keep_state, State};
handle_common_event(info, {pacing_timeout, Ref}, StateName, #state{pacing_timer = Ref} = State) when
    Ref =/= undefined andalso
        (StateName =:= connected orelse StateName =:= handshaking orelse StateName =:= idle)
->
    %% Handle pacing timeout - process send queue
    NewState = handle_pacing_timeout(State#state{pacing_timer = undefined}),
    {keep_state, NewState};
handle_common_event(info, {pacing_timeout, _StaleRef}, _StateName, State) ->
    %% Ignore stale pacing timer (ref doesn't match or wrong state)
    {keep_state, State};
handle_common_event(info, {idle_timeout, Ref}, StateName, #state{idle_timer = Ref} = State) when
    Ref =/= undefined andalso StateName =/= draining andalso StateName =/= closed
->
    %% Handle idle timeout - check if we've truly been idle
    Now = erlang:monotonic_time(millisecond),
    TimeSinceActivity = Now - State#state.last_activity,
    case TimeSinceActivity >= (State#state.cfg)#conn_cfg.idle_timeout of
        true ->
            %% Genuine idle timeout - initiate close
            NewState = initiate_close(idle_timeout, State#state{idle_timer = undefined}),
            {next_state, draining, NewState};
        false ->
            %% Spurious timeout (activity occurred) - reset timer
            {keep_state, set_idle_timer(State#state{idle_timer = undefined})}
    end;
handle_common_event(info, {idle_timeout, _StaleRef}, _StateName, State) ->
    %% Ignore stale idle timer (ref doesn't match or wrong state)
    {keep_state, State};
handle_common_event(
    info, {keep_alive_timeout, Ref}, connected, #state{keep_alive_timer = Ref} = State
) when
    Ref =/= undefined
->
    Now = erlang:monotonic_time(millisecond),
    case (Now - State#state.last_activity) < (State#state.cfg)#conn_cfg.keep_alive_interval of
        true ->
            %% Activity since the timer was armed: re-arm for the remainder,
            %% no PING needed.
            {keep_state, set_keep_alive_timer(State#state{keep_alive_timer = undefined})};
        false ->
            %% Idle for a full interval: send a PING, then wait a full
            %% interval before the next one.
            %%
            %% The re-arm must count from now, not from last_activity:
            %% last_activity only moves on the FIRST ack-eliciting packet
            %% sent since the last receive (RFC 9000 §10.1), so on a
            %% connection whose peer stays quiet every later PING leaves it
            %% untouched. Deriving the delay from it then yields
            %% max(0, past + interval - now) = 0, the timer fires straight
            %% back, and the connection spins sending PINGs at timer-wheel
            %% rate (measured: ~930/s per connection, 46k/s across 50 idle
            %% connections) until the peer happens to send something.
            State1 = send_keep_alive_ping(State#state{keep_alive_timer = undefined}),
            State2 = flush_event(State1, event),
            {keep_state,
                arm_keep_alive_timer(State2, (State2#state.cfg)#conn_cfg.keep_alive_interval)}
    end;
handle_common_event(info, {keep_alive_timeout, _StaleRef}, _StateName, State) ->
    %% Ignore stale keep-alive timer (ref doesn't match or wrong state)
    {keep_state, State};
%% Handle socket going passive ({active, N} exhausted)
%% Re-enable socket to continue receiving packets
handle_common_event(
    info,
    {udp_passive, Socket},
    _StateName,
    #state{socket = Socket, cfg = #conn_cfg{role = client, active_n = N}} = State
) ->
    client_rearm_active(State, N),
    {keep_state, State};
handle_common_event(info, {udp_passive, _Socket}, _StateName, State) ->
    %% Server connections or different socket - ignore
    {keep_state, State};
%% Dedicated client receiver died. Without it the socket-backend
%% client is deaf; close instead of sitting idle until max_idle_timeout.
handle_common_event(
    info,
    {'EXIT', Pid, Reason},
    _StateName,
    #state{client_receiver = Pid, owner = Owner, cfg = #conn_cfg{role = client}} = State
) when Reason =/= normal andalso Reason =/= shutdown ->
    Owner ! {quic, self(), {closed, {receiver_exit, Reason}}},
    {stop, {shutdown, {receiver_exit, Reason}}, State};
%% Owner process gone. Tear down so a connection that is not linked to its
%% owner doesn't stay up delivering into a dead mailbox.
handle_common_event(
    info,
    {'DOWN', Mon, process, _Pid, _Reason},
    _StateName,
    #state{owner_mon = Mon} = State
) ->
    {stop, {shutdown, owner_down}, State};
%% The listener's shared sender went away: flush direct from now on.
handle_common_event(
    info,
    {'DOWN', Mon, process, _Pid, _Reason},
    _StateName,
    #state{socket_state = SS} = State
) ->
    case quic_socket:sender_down(SS, Mon) of
        {ok, SS1} -> {keep_state, State#state{socket_state = SS1}};
        false -> {keep_state, State}
    end;
handle_common_event(info, {'EXIT', _Pid, _Reason}, _StateName, State) ->
    %% EXIT signals are handled in terminate/3 callback
    %% Just ignore here - the process will terminate anyway if it's from parent
    {keep_state, State};
%% An async send can arrive before the state machine reaches `connected':
%% the owner is told the connection is up a flight before the handshake
%% concludes, so this is an ordinary race rather than misuse. Queue it the
%% way the synchronous handshaking-state clause does, to be flushed by
%% send_pending_data/2 on entering `connected'. Falling through to the
%% catch-all below would discard it, and send_data_async cannot retry.
handle_common_event(
    cast,
    {send_data_async, StreamId, Data, Fin},
    StateName,
    #state{pending_data = Pending} = State
) ->
    case length(Pending) >= ?MAX_PENDING_DATA_ENTRIES of
        true ->
            ?LOG_WARNING(
                #{
                    what => async_send_dropped_pending_limit,
                    state => StateName,
                    stream_id => StreamId
                },
                ?QUIC_LOG_META
            ),
            {keep_state, State};
        false ->
            {keep_state, State#state{pending_data = Pending ++ [{StreamId, Data, Fin}]}}
    end;
%% Return error for unhandled calls to prevent timeout
handle_common_event({call, From}, _Request, StateName, State) ->
    {keep_state, State, [{reply, From, {error, {invalid_state, StateName}}}]};
handle_common_event(_EventType, _EventContent, _StateName, State) ->
    {keep_state, State}.

%%====================================================================
%% Internal Functions - TLS Handshake
%%====================================================================

%% Send ClientHello in an Initial packet
send_client_hello(State) ->
    #state{
        max_data_local = MaxData,
        max_streams_bidi_local = MaxStreamsBidi,
        max_streams_uni_local = MaxStreamsUni,
        cfg = #conn_cfg{
            scid = SCID,
            alpn_list = AlpnList,
            max_stream_data_bidi_local = MaxStreamDataBidiLocal,
            max_stream_data_bidi_remote = MaxStreamDataBidiRemote,
            max_stream_data_uni = MaxStreamDataUni,
            max_datagram_frame_size_local = MaxDatagramSize
        },
        hs = #hs{
            server_name = ServerName,
            ticket_store = TicketStore
        }
    } = State,

    %% Look up session ticket for resumption — but skip if the caller
    %% supplied an external PSK; build_client_hello/1 will raise
    %% {bad_opts, psk_conflict} if both end up in Opts.
    SessionTicket =
        case (State#state.cfg)#conn_cfg.external_psk of
            undefined ->
                case quic_ticket:lookup_ticket(ServerName, TicketStore) of
                    {ok, Ticket} -> Ticket;
                    error -> undefined
                end;
            _ ->
                undefined
        end,

    %% Build transport parameters
    TransportParams0 = #{
        initial_scid => SCID,
        initial_max_data => MaxData,
        initial_max_stream_data_bidi_local => MaxStreamDataBidiLocal,
        initial_max_stream_data_bidi_remote => MaxStreamDataBidiRemote,
        initial_max_stream_data_uni => MaxStreamDataUni,
        initial_max_streams_bidi => MaxStreamsBidi,
        initial_max_streams_uni => MaxStreamsUni,
        max_idle_timeout => (State#state.cfg)#conn_cfg.idle_timeout,
        active_connection_id_limit => local_active_limit(State),
        max_udp_payload_size => advertised_max_udp_payload_size(State)
    },
    %% Add max_datagram_frame_size if datagrams are enabled (RFC 9221)
    TransportParams1 =
        case MaxDatagramSize of
            0 -> TransportParams0;
            _ -> TransportParams0#{max_datagram_frame_size => MaxDatagramSize}
        end,
    %% Add reset_stream_at if enabled (draft-ietf-quic-reliable-stream-reset-07)
    TransportParams =
        case (State#state.cfg)#conn_cfg.reset_stream_at_enabled of
            false -> TransportParams1;
            true -> TransportParams1#{reset_stream_at => true}
        end,

    %% Build ClientHello (with or without PSK for resumption / external).
    %% session_ticket and external_psk are mutually exclusive; build_client_hello/1
    %% raises {bad_opts, psk_conflict} if both are present.
    ClientHelloOpts0 = #{
        server_name => ServerName,
        alpn => AlpnList,
        transport_params => TransportParams,
        session_ticket => SessionTicket,
        groups => (State#state.cfg)#conn_cfg.tls_groups,
        ciphers => (State#state.cfg)#conn_cfg.cipher_preference
    },
    ClientHelloOpts1 =
        case (State#state.cfg)#conn_cfg.tls_sig_algs of
            undefined -> ClientHelloOpts0;
            SigAlgs -> ClientHelloOpts0#{signature_algs => SigAlgs}
        end,
    ClientHelloOpts =
        case (State#state.cfg)#conn_cfg.external_psk of
            undefined -> ClientHelloOpts1;
            Ext -> ClientHelloOpts1#{external_psk => Ext}
        end,
    {ClientHello, PrivKey, ClientRandom} = quic_tls:build_client_hello(ClientHelloOpts),

    %% Update transcript
    Transcript = ClientHello,

    %% Derive early keys if we have a session ticket that allows 0-RTT
    EarlyKeys =
        case SessionTicket of
            #session_ticket{
                max_early_data = TicketMaxEarly, cipher = Cipher, resumption_secret = ResSecret
            } when TicketMaxEarly > 0 ->
                %% Derive PSK and early secret
                PSK = quic_ticket:derive_psk(ResSecret, SessionTicket),
                EarlySecret = quic_crypto:derive_early_secret(Cipher, PSK),
                %% Derive client early traffic secret from ClientHello hash
                ClientHelloHash = quic_crypto:transcript_hash(Cipher, Transcript),
                EarlyTrafficSecret = quic_crypto:derive_client_early_traffic_secret(
                    Cipher, EarlySecret, ClientHelloHash
                ),
                %% Derive traffic keys
                {Key, IV, HP} = quic_keys:derive_keys(
                    EarlyTrafficSecret, Cipher, State#state.version
                ),
                Keys = #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher},
                {Keys, EarlySecret};
            _ ->
                undefined
        end,

    %% Encrypt and send the ClientHello, chunked across Initial packets
    %% when it exceeds one datagram (hybrid ML-KEM key share).
    State0 = State#state{
        hs = (State#state.hs)#hs{
            tls_private_key = PrivKey,
            tls_transcript = Transcript,
            tls_ch1_random = ClientRandom,
            tls_ch1_opts = ClientHelloOpts,
            initial_tx_off = byte_size(ClientHello),
            early_keys = EarlyKeys,
            max_early_data =
                case SessionTicket of
                    undefined -> 0;
                    #session_ticket{max_early_data = MaxEarly} -> MaxEarly
                end
        }
    },
    NewState = send_initial_crypto(ClientHello, 0, State0),

    %% Event-driven flush: flush batch and timers after sending ClientHello
    %% Critical for handshake - must send immediately
    FlushedState = flush_event(NewState, event),

    %% Enable socket for receiving (use {active, N} for better throughput)
    client_rearm_active(FlushedState, (FlushedState#state.cfg)#conn_cfg.active_n),

    FlushedState.

%% The server's default preference list lives in quic_crypto, which
%% knows whether this CPU has AES instructions.
default_cipher_preference() ->
    quic_crypto:default_cipher_preference().

%%====================================================================
%% PSK validation and the session ticket store (RFC 9001 Section 4.6)
%%
%% The ticket store is the listener's ETS table, so these functions are
%% side-effecting where the negotiation helpers above are pure.
%%====================================================================

%% A ticket resumes only on the listener that issued it, for the server
%% name, ALPN and hash it was issued under (RFC 8446 Sections 4.2.11 and
%% 4.6.1). It is taken once its binder checks out, so of two handshakes
%% presenting it only one resumes (RFC 9001 Section 9.2).
resume_ticket(_Identity, _Binder, _Cipher, _Msg, _Info, #state{
    cfg = #conn_cfg{ticket_table = undefined}
}) ->
    error;
resume_ticket(
    Identity, Binder, Cipher, Msg, Info, #state{cfg = #conn_cfg{ticket_table = Tab}} = State
) ->
    case quic_ticket:lookup_issued(Tab, Identity) of
        {ok, Ticket} ->
            case ticket_matches(Ticket, Cipher, Info, State) of
                true -> check_resumption_binder(Identity, Ticket, Binder, Cipher, Msg, Info, Tab);
                false -> error
            end;
        error ->
            error
    end.

ticket_matches(
    #session_ticket{server_name = SNI, alpn = ALPN, cipher = Issued}, Cipher, Info, State
) ->
    ClientALPN = maps:get(alpn_protocols, Info, []),
    (SNI =:= sni_or_empty(maps:get(server_name, Info, undefined))) andalso
        (ALPN =:=
            quic_tls_negotiation:negotiate_alpn(ClientALPN, (State#state.cfg)#conn_cfg.alpn_list)) andalso
        (quic_crypto:cipher_to_hash(Issued) =:= quic_crypto:cipher_to_hash(Cipher)).

check_resumption_binder(Identity, Ticket, Binder, Cipher, Msg, Info, Tab) ->
    ResumptionSecret = Ticket#session_ticket.resumption_secret,
    PSK = quic_ticket:derive_psk(ResumptionSecret, Ticket),
    Binders = maps:get(psk_binders, Info, undefined),
    case quic_tls:verify_resumption_binder(PSK, Cipher, Msg, Binders, Binder) of
        true ->
            case quic_ticket:take_issued(Tab, Identity) of
                {ok, _} -> {ok, PSK, ResumptionSecret};
                error -> error
            end;
        false ->
            bad_binder
    end.

sni_or_empty(undefined) -> <<>>;
sni_or_empty(Name) -> Name.

%%====================================================================
%% TLS handshake, continued: server flight and session tickets
%%====================================================================

%% Server: Send ServerHello in Initial packet. Uses the tracked
%% Initial CRYPTO offset (non-zero only after a HelloRetryRequest).
send_server_hello(ServerHelloMsg, State) ->
    Off = (State#state.hs)#hs.initial_tx_off,
    State1 = State#state{
        hs = (State#state.hs)#hs{initial_tx_off = Off + byte_size(ServerHelloMsg)}
    },
    %% Chunk across Initial packets: a hybrid ServerHello Initial is
    %% ~1225 bytes and no longer fits one datagram.
    NewState = send_initial_crypto(ServerHelloMsg, Off, State1),
    NewState.

%% Server: Send EncryptedExtensions, Certificate, CertificateVerify, Finished
%% @private
%% Client-side downgrade protection (RFC 8446 §4.1.3).
%% If the client offered an external_psk, the server MUST select it;
%% any other ServerHello outcome (cert path, no PSK extension,
%% identity index out of range) aborts the connection. Without this
%% check a server with `verify => false` could silently fall back to
%% an unauthenticated cert path while the client believed it was on
%% the PSK path.
validate_client_psk_selection(undefined, #state{cfg = #conn_cfg{external_psk = undefined}}) ->
    %% Neither side wants PSK — standard handshake.
    {ok, undefined};
validate_client_psk_selection(undefined, #state{cfg = #conn_cfg{external_psk = _Offered}}) ->
    %% Client offered, server didn't select.
    {error, server_did_not_select_psk};
validate_client_psk_selection(
    Idx,
    #state{
        cfg = #conn_cfg{external_psk = undefined},
        hs = #hs{
            server_name = ServerName,
            ticket_store = TicketStore
        }
    }
) ->
    %% No external PSK was offered, so the server must have selected the
    %% resumption ticket we offered. Re-derive that PSK from the stored
    %% ticket; QUIC always uses psk_dhe_ke (the ECDHE share is present in
    %% the ClientHello).
    case quic_ticket:lookup_ticket(ServerName, TicketStore) of
        {ok, #session_ticket{} = Ticket} when Idx =:= 0 ->
            %% Single-identity resumption offer: index 0 is the only valid
            %% choice. Re-derive the PSK the binder/early secret used.
            PSK = quic_ticket:derive_psk(Ticket#session_ticket.resumption_secret, Ticket),
            {ok, #{identity => Ticket#session_ticket.ticket, secret => PSK, mode => psk_dhe_ke}};
        {ok, #session_ticket{}} ->
            {error, selected_psk_index_out_of_range};
        error ->
            %% Server selected a PSK we never offered (or it expired).
            {error, unexpected_psk_selection}
    end;
validate_client_psk_selection(Idx, #state{cfg = #conn_cfg{external_psk = {Identity, Secret}}}) ->
    validate_client_psk_selection(Idx, Identity, Secret, [psk_dhe_ke]);
validate_client_psk_selection(Idx, #state{cfg = #conn_cfg{external_psk = {Identity, Secret, Modes}}}) ->
    validate_client_psk_selection(Idx, Identity, Secret, Modes).

validate_client_psk_selection(0, Identity, Secret, Modes) ->
    %% Single-identity offer: index 0 is the only valid choice. The
    %% mode actually used is detected later from ServerHello's
    %% key_share presence; record the offered first-preference here
    %% so the rest of the handshake routes through PSK.
    [Mode | _] = Modes,
    {ok, #{identity => Identity, secret => Secret, mode => Mode}};
validate_client_psk_selection(_Idx, _Identity, _Secret, _Modes) ->
    {error, selected_psk_index_out_of_range}.

%% @private
%% Notify the connection owner of a handshake failure so quic:connect/4
%% callers see {error, Reason} rather than a silent stall.
notify_owner(Msg, #state{owner = Owner}) when is_pid(Owner) ->
    try
        Owner ! {quic, self(), Msg},
        ok
    catch
        _:_ -> ok
    end;
notify_owner(_Msg, _State) ->
    ok.

%% Building our own flight is local work, so a failure in it is ours,
%% such as a key from an sni_callback that cannot sign. Left to the packet
%% loop it would be taken for a malformed datagram from the peer and
%% dropped, and the client would wait out its timeout without an answer.
%% Fail the handshake with internal_error (RFC 8446 Section 6.2) instead.
%% exit is left alone, as in the packet loop: it is how the handshake
%% aborts on purpose.
server_handshake_flight(Cipher, TranscriptHash, State) ->
    try
        send_server_handshake_flight(Cipher, TranscriptHash, State)
    catch
        Class:Reason:Stack when Class =:= error; Class =:= throw ->
            ?LOG_ERROR(
                #{
                    what => server_handshake_flight_failed,
                    class => Class,
                    reason => Reason,
                    stacktrace => Stack
                },
                ?QUIC_LOG_META
            ),
            send_tls_alert(?TLS_ALERT_INTERNAL_ERROR, <<"internal error">>, State)
    end.

%% @doc Whether Key can authenticate as Cert: sign a CertificateVerify as a
%% handshake does and check the certificate's public key accepts the
%% signature. This catches a key in a form the signer does not take and a
%% key that belongs to another certificate, both of which would otherwise
%% fail every handshake that presents the certificate.
-spec check_signing_key(binary(), term()) -> ok | {error, term()}.
check_signing_key(Cert, Key) ->
    Hash = crypto:hash(sha256, <<"quic server key check">>),
    Code = hd(compatible_sig_schemes_codes(Key)),
    try quic_tls:build_certificate_verify(Code, Key, Hash) of
        <<_Type, _Len:24, Body/binary>> ->
            case quic_tls:verify_certificate_verify(Body, Cert, Hash, server) of
                true -> ok;
                false -> {error, signature_not_accepted_by_certificate}
            end
    catch
        _:Reason -> {error, {cannot_sign, Reason}}
    end.

%% @doc Whether the `cert' and `key' in Opts can authenticate as Role, the
%% error naming the side whose key is at fault. Opts without both have
%% nothing to check here.
-spec check_credentials(server | client, map()) -> ok | {error, term()}.
check_credentials(Role, #{cert := Cert, key := Key}) when Cert =/= undefined, Key =/= undefined ->
    case check_signing_key(Cert, Key) of
        ok -> ok;
        {error, Reason} when Role =:= server -> {error, {invalid_server_key, Reason}};
        {error, Reason} -> {error, {invalid_client_key, Reason}}
    end;
check_credentials(_Role, _Opts) ->
    ok.

send_server_handshake_flight(Cipher, _TranscriptHashAfterSH, State) ->
    #state{
        alpn = ALPN,
        max_data_local = MaxData,
        max_streams_bidi_local = MaxStreamsBidi,
        max_streams_uni_local = MaxStreamsUni,
        cfg = #conn_cfg{
            scid = SCID,
            verify = Verify,
            max_stream_data_bidi_local = MaxStreamDataBidiLocal,
            max_stream_data_bidi_remote = MaxStreamDataBidiRemote,
            max_stream_data_uni = MaxStreamDataUni,
            max_datagram_frame_size_local = MaxDatagramSize
        },
        hs = #hs{
            server_cert = Cert,
            server_cert_chain = CertChain,
            server_private_key = PrivateKey,
            tls_transcript = Transcript,
            server_hs_secret = ServerHsSecret,
            handshake_secret = HandshakeSecret
        }
    } = State,

    %% Build transport parameters
    TransportParams0 = #{
        %% RFC 9000 §7.3: server MUST send this
        original_dcid => (State#state.cfg)#conn_cfg.original_dcid,
        initial_scid => SCID,
        initial_max_data => MaxData,
        initial_max_stream_data_bidi_local => MaxStreamDataBidiLocal,
        initial_max_stream_data_bidi_remote => MaxStreamDataBidiRemote,
        initial_max_stream_data_uni => MaxStreamDataUni,
        initial_max_streams_bidi => MaxStreamsBidi,
        initial_max_streams_uni => MaxStreamsUni,
        max_idle_timeout => (State#state.cfg)#conn_cfg.idle_timeout,
        active_connection_id_limit => local_active_limit(State),
        max_udp_payload_size => advertised_max_udp_payload_size(State),
        %% RFC 9368: the versions we would also accept; the server may
        %% switch the connection to one of them.
        version_information =>
            {State#state.version, (State#state.cfg)#conn_cfg.supported_versions}
    },
    %% Add max_datagram_frame_size if datagrams are enabled (RFC 9221)
    TransportParams1 =
        case MaxDatagramSize of
            0 -> TransportParams0;
            _ -> TransportParams0#{max_datagram_frame_size => MaxDatagramSize}
        end,
    %% Add reset_stream_at if enabled (draft-ietf-quic-reliable-stream-reset-07)
    TransportParams2 =
        case (State#state.cfg)#conn_cfg.reset_stream_at_enabled of
            false -> TransportParams1;
            true -> TransportParams1#{reset_stream_at => true}
        end,
    %% Add preferred_address if configured (RFC 9000 Section 9.6)
    %% Server MUST NOT send preferred_address if disable_active_migration is set
    TransportParams3 =
        case (State#state.cfg)#conn_cfg.server_preferred_address of
            #preferred_address{} = PA ->
                TransportParams2#{preferred_address => PA};
            _ ->
                TransportParams2
        end,

    %% RFC 9000 §7.3: if this server issued a Retry for this client,
    %% echo the Retry's SCID in retry_source_connection_id so the
    %% client can verify the full handshake against the Retry it saw.
    TransportParams3b =
        case (State#state.cfg)#conn_cfg.retry_scid_for_tp of
            undefined -> TransportParams3;
            RetrySCIDTP -> TransportParams3#{retry_scid => RetrySCIDTP}
        end,
    %% RFC 9368: echo the negotiated version and our acceptable set.
    TransportParams4 = TransportParams3b#{
        version_information =>
            {State#state.version, (State#state.cfg)#conn_cfg.supported_versions}
    },

    %% RFC 9000 §10.3: advertise a stateless_reset_token bound to our initial
    %% SCID, so the peer can recognise a stateless reset for this connection if
    %% we later lose its state (e.g. after a restart) and reply with a reset
    %% derived from the same server-wide secret + CID. Only sent when a secret
    %% is configured.
    TransportParams =
        case (State#state.cfg)#conn_cfg.stateless_reset_secret of
            undefined ->
                TransportParams4;
            _ ->
                TransportParams4#{
                    stateless_reset_token => generate_stateless_reset_token(SCID, State)
                }
        end,

    %% Build EncryptedExtensions
    EncExtMsg = quic_tls:build_encrypted_extensions(#{
        alpn => ALPN,
        transport_params => TransportParams,
        early_data => (State#state.hs)#hs.early_data_accepted
    }),

    %% PSK handshakes (RFC 8446 §4.6) skip CertificateRequest / Certificate /
    %% CertificateVerify entirely. Cert path runs only when no PSK was
    %% selected for this handshake.
    {CertReqMsg, CertMsg, CertVerifyMsg, Transcript2, TranscriptHashForFinished} =
        case (State#state.hs)#hs.selected_psk of
            undefined ->
                %% Cert path
                CertReq =
                    case Verify of
                        true -> build_cert_request(State);
                        false -> <<>>
                    end,
                AllCerts = [Cert | CertChain],
                Cert0 = quic_tls:build_certificate(<<>>, AllCerts),
                T1 = <<Transcript/binary, EncExtMsg/binary, CertReq/binary, Cert0/binary>>,
                HashForCV = quic_crypto:transcript_hash(Cipher, T1),
                %% Scheme negotiated in do_server_client_hello.
                SigAlg = (State#state.hs)#hs.cert_verify_code,
                CV = quic_tls:build_certificate_verify(SigAlg, PrivateKey, HashForCV),
                T2 = <<T1/binary, CV/binary>>,
                HashForFin = quic_crypto:transcript_hash(Cipher, T2),
                {CertReq, Cert0, CV, T2, HashForFin};
            _Selected ->
                %% PSK path: EncryptedExtensions → Finished (no cert
                %% messages contribute to the transcript).
                TP = <<Transcript/binary, EncExtMsg/binary>>,
                HashForFin = quic_crypto:transcript_hash(Cipher, TP),
                {<<>>, <<>>, <<>>, TP, HashForFin}
        end,

    %% Build server Finished
    ServerFinishedKey = quic_crypto:derive_finished_key(Cipher, ServerHsSecret),
    ServerVerifyData = quic_crypto:compute_finished_verify(
        Cipher, ServerFinishedKey, TranscriptHashForFinished
    ),
    FinishedMsg = quic_tls:build_finished(ServerVerifyData),

    %% Update transcript after server Finished
    Transcript3 = <<Transcript2/binary, FinishedMsg/binary>>,
    TranscriptHashFinal = quic_crypto:transcript_hash(Cipher, Transcript3),

    %% Derive master secret and application keys
    MasterSecret = quic_crypto:derive_master_secret(Cipher, HandshakeSecret),

    ClientAppSecret = quic_crypto:derive_client_app_secret(
        Cipher, MasterSecret, TranscriptHashFinal
    ),
    ServerAppSecret = quic_crypto:derive_server_app_secret(
        Cipher, MasterSecret, TranscriptHashFinal
    ),
    keylog_application((State#state.hs)#hs.tls_ch1_random, ClientAppSecret, ServerAppSecret),

    %% Derive app keys
    {ClientKey, ClientIV, ClientHP} = quic_keys:derive_keys(
        ClientAppSecret, Cipher, State#state.version
    ),
    {ServerKey, ServerIV, ServerHP} = quic_keys:derive_keys(
        ServerAppSecret, Cipher, State#state.version
    ),

    ClientAppKeys = #crypto_keys{key = ClientKey, iv = ClientIV, hp = ClientHP, cipher = Cipher},
    ServerAppKeys = #crypto_keys{key = ServerKey, iv = ServerIV, hp = ServerHP, cipher = Cipher},

    %% Initialize key update state
    KeyState = #key_update_state{
        current_phase = 0,
        current_keys = {ClientAppKeys, ServerAppKeys},
        prev_keys = undefined,
        client_app_secret = ClientAppSecret,
        server_app_secret = ServerAppSecret,
        update_state = idle
    },

    %% Combine all messages into the handshake CRYPTO payload.
    %% Include CertificateRequest if verify is enabled.
    HandshakePayload =
        <<EncExtMsg/binary, CertReqMsg/binary, CertMsg/binary, CertVerifyMsg/binary,
            FinishedMsg/binary>>,

    %% Determine next TLS state based on verify option
    %% If verify=true, we expect Certificate from client next
    %% If verify=false, we expect Finished from client next
    NextTlsState =
        case Verify of
            true -> ?TLS_AWAITING_CLIENT_CERT;
            false -> ?TLS_AWAITING_CLIENT_FINISHED
        end,

    %% Update state with transcript and app keys
    State1 = State#state{
        app_keys = {ClientAppKeys, ServerAppKeys},
        key_state = KeyState,
        hs = (State#state.hs)#hs{
            tls_state = NextTlsState,
            tls_transcript = Transcript3,
            master_secret = MasterSecret
        }
    },

    %% Send the flight, segmented so no datagram exceeds the peer's
    %% max_udp_payload_size (issue #134).
    send_handshake_crypto(HandshakePayload, State1).

%% @private Send a handshake CRYPTO payload as one or more packets,
%% each sized to stay within max_udp_payload_size (RFC 9000 §14.1).
%% A single oversized datagram is dropped by strict clients (Chromium),
%% stalling the handshake.
send_handshake_crypto(Payload, State0) ->
    %% RFC 9001 Section 4.9.1: a client discards its Initial keys when it
    %% first sends a Handshake packet. The server's trigger is receiving
    %% one, not sending one, so it must not discard here: it still has a
    %% ServerHello to retransmit at the Initial level.
    State =
        case (State0#state.cfg)#conn_cfg.role of
            client -> discard_initial(State0);
            server -> State0
        end,
    Max = handshake_crypto_budget(State),
    lists:foldl(
        fun({Offset, Chunk}, AccState) ->
            Frame = quic_frame:encode({crypto, Offset, Chunk}),
            send_handshake_packet(Frame, [{crypto, Offset, Chunk}], AccState)
        end,
        State,
        chunk_crypto(Payload, 0, Max)
    ).

%% @private Conservative per-chunk CRYPTO data budget for a Handshake
%% packet. The ceiling is the QUIC baseline (1200): PMTU is unvalidated
%% mid-handshake and every peer's max_udp_payload_size is >= 1200, so
%% 1200 is universally safe. Overhead covers the long header, packet
%% number, AEAD tag and CRYPTO frame header (generous varints).
handshake_crypto_budget(#state{dcid = DCID, cfg = #conn_cfg{scid = SCID}} = State) ->
    PeerMax = maps:get(
        max_udp_payload_size,
        State#state.transport_params,
        ?DEFAULT_MAX_UDP_PAYLOAD_SIZE
    ),
    Ceiling = min(PeerMax, ?DEFAULT_MAX_UDP_PAYLOAD_SIZE),
    Overhead =
        %% long header: first byte + version + DCID len/bytes + SCID len/bytes
        1 + 4 + 1 + byte_size(DCID) + 1 + byte_size(SCID) +
            %% length varint + packet number + AEAD tag
            2 + 4 + 16 +
            %% CRYPTO frame header: type + offset varint + length varint
            1 + 8 + 4,
    max(1, Ceiling - Overhead).

%% @private Split a handshake CRYPTO payload into {Offset, Chunk}
%% pieces, each Chunk =< Max, with contiguous offsets from Offset.
%% The concatenation of the chunks equals the original payload.
chunk_crypto(<<>>, _Offset, _Max) ->
    [];
chunk_crypto(Payload, Offset, Max) ->
    Take = min(byte_size(Payload), Max),
    <<Chunk:Take/binary, Rest/binary>> = Payload,
    [{Offset, Chunk} | chunk_crypto(Rest, Offset + Take, Max)].

%% @private Send an Initial-level CRYPTO payload (ClientHello,
%% ServerHello, or a HelloRetryRequest CH2) as one or more Initial
%% packets, each sized to stay within the 1200-byte pre-PMTU limit
%% (RFC 9000 §14.1). A hybrid ML-KEM ClientHello is ~1360 bytes and no
%% longer fits one datagram; a single oversized Initial is dropped on
%% paths with an MTU below ~1470 (PPPoE, WireGuard, mobile).
send_initial_crypto(Payload, Offset0, State) ->
    Max = initial_crypto_budget(State),
    lists:foldl(
        fun({Offset, Chunk}, AccState) ->
            Decoded = {crypto, Offset, Chunk},
            send_initial_packet(quic_frame:encode(Decoded), [Decoded], AccState)
        end,
        State,
        chunk_crypto(Payload, Offset0, Max)
    ).

%% @private Conservative per-chunk CRYPTO data budget for an Initial
%% packet. Mirrors handshake_crypto_budget/1 but includes the Retry
%% token field, which Initial packets carry (RFC 9000 §17.2.2). Each
%% Initial packet is separately padded to 1200 bytes downstream, so
%% the budget bounds the pre-padding size and keeps every datagram
%% within the universally safe 1200-byte ceiling.
initial_crypto_budget(
    #state{dcid = DCID, cfg = #conn_cfg{scid = SCID}, hs = #hs{retry_token = Token}} = State
) ->
    PeerMax = maps:get(
        max_udp_payload_size,
        State#state.transport_params,
        ?DEFAULT_MAX_UDP_PAYLOAD_SIZE
    ),
    Ceiling = min(PeerMax, ?DEFAULT_MAX_UDP_PAYLOAD_SIZE),
    Overhead =
        %% long header: first byte + version + DCID len/bytes + SCID len/bytes
        1 + 4 + 1 + byte_size(DCID) + 1 + byte_size(SCID) +
            %% token length varint + token bytes
            byte_size(quic_varint:encode(byte_size(Token))) + byte_size(Token) +
            %% length varint + packet number + AEAD tag
            2 + 4 + 16 +
            %% CRYPTO frame header: type + offset varint + length varint
            1 + 8 + 4,
    max(1, Ceiling - Overhead).

%% Server: Send HANDSHAKE_DONE frame after receiving client Finished
confirm_handshake(#state{loss_state = undefined} = State) ->
    State;
confirm_handshake(#state{loss_state = LossState} = State) ->
    %% RFC 9001 Section 4.9.2: neither endpoint sends at the Handshake
    %% level once the handshake is confirmed, so anything still tracked
    %% there can never be acknowledged.
    Confirmed = discard_space(handshake, State#state{
        loss_state = quic_loss:on_handshake_confirmed(LossState)
    }),
    Confirmed#state{hs = (Confirmed#state.hs)#hs{handshake_keys = undefined}}.

%% RFC 9001 Section 4.9.1: the keys go with the packets. Discarding the
%% space alone would leave the connection able to send at a level it must
%% not, and able to decrypt packets it must drop.
discard_initial(State) ->
    State1 = discard_space(initial, State),
    State1#state{hs = (State1#state.hs)#hs{initial_keys = undefined, initial_keys_alt = undefined}}.

%% Drop a packet number space from both byte counters at once. They are
%% tracked separately, so subtracting from one and not the other leaves
%% the congestion window charged for packets that no longer exist.
discard_space(_Space, #state{loss_state = undefined} = State) ->
    State;
discard_space(Space, #state{loss_state = LossState, cc_state = CCState} = State) ->
    %% Unconditional, even when the space tracked nothing: RFC 9002
    %% Appendix A.11 resets the probe backoff and re-arms the timer
    %% whenever a space is dropped, and a space with no packets can still
    %% have earned a backoff.
    {NewLossState, Bytes} = quic_loss:discard_space(Space, LossState),
    purge_unsent(Space, State#state{
        loss_state = NewLossState,
        cc_state = discard_cc_bytes(CCState, Bytes),
        pto_dirty = true
    }).

%% Nothing may be sent at a discarded level (RFC 9001 Section 4.9), which
%% includes packets that never left: one held back by the amplification
%% budget, or by the congestion window.
purge_unsent(Space, #state{hs = #hs{pending_hs = Pending}} = State) ->
    State#state{
        hs = (State#state.hs)#hs{
            pending_hs = Pending#{Space => queue:new()},
            pending_hs_bytes = ((State#state.hs)#hs.pending_hs_bytes)#{Space => 0}
        }
    }.

discard_cc_bytes(undefined, _Bytes) -> undefined;
discard_cc_bytes(CCState, Bytes) -> quic_cc:on_packets_discarded(CCState, Bytes).

send_handshake_done(State) ->
    %% HANDSHAKE_DONE is frame type 0x1e with no payload
    send_frame(handshake_done, State).

%% Server: Send NewSessionTicket after handshake completes
%% RFC 8446 Section 4.6.1: Server sends NewSessionTicket in post-handshake message
%% In QUIC, this is sent as a TLS handshake message in a CRYPTO frame
send_new_session_ticket(#state{hs = #hs{selected_psk = #{source := external}}} = State) ->
    %% Suppress NewSessionTicket on external-PSK handshakes (v1
    %% — see docs/PSK.md "v1 limitations"). External-PSK clients
    %% already have a long-lived credential and don't need a
    %% resumption ticket; mixing the two raises a binding question
    %% we don't want to answer right now. A handshake resumed from a
    %% ticket gets a new one: tickets are single-use.
    State;
send_new_session_ticket(#state{hs = #hs{resumption_secret = undefined}} = State) ->
    %% No resumption secret available - skip sending ticket
    State;
send_new_session_ticket(#state{cfg = #conn_cfg{ticket_table = undefined}} = State) ->
    %% Not started by a listener: nowhere to resume the ticket from.
    State;
send_new_session_ticket(
    #state{
        alpn = ALPN,
        app_keys = {ClientAppKeys, _},
        cfg = #conn_cfg{
            ticket_table = TicketTable
        },
        hs = #hs{
            resumption_secret = ResumptionSecret,
            server_name = ServerName,
            max_early_data = MaxEarlyData
        }
    } = State
) ->
    %% The cipher is the same at every level; the 1-RTT keys are the ones
    %% still held once the handshake is confirmed.
    Cipher = ClientAppKeys#crypto_keys.cipher,

    %% Create a session ticket
    Ticket = quic_ticket:create_ticket(
        case ServerName of
            undefined -> <<"">>;
            Name -> Name
        end,
        ResumptionSecret,
        MaxEarlyData,
        Cipher,
        ALPN
    ),

    quic_ticket:store_issued(TicketTable, Ticket),

    %% Build NewSessionTicket TLS message
    TicketMsg = quic_ticket:build_new_session_ticket(Ticket),

    %% Wrap in TLS handshake message (type 4 = NewSessionTicket)
    TLSMsg = quic_tls:encode_handshake_message(?TLS_NEW_SESSION_TICKET, TicketMsg),

    %% Send in CRYPTO frame (at application level)
    CryptoFrame = {crypto, 0, TLSMsg},
    send_frame(CryptoFrame, State).

%%====================================================================
%% Packet send layer
%%
%% Everything above builds handshake bytes; from here down the module
%% turns frames and payloads into packets on the wire, at all three
%% levels. `send_frame/2' is the entry point most of the module uses.
%%====================================================================

%% RFC 9002 Section 2: a packet is in flight when it is ack-eliciting or
%% carries PADDING. ACK and CONNECTION_CLOSE are neither, so an ACK-only
%% Initial is not in flight and must not arm a probe. Initial datagrams
%% are brought to 1200 bytes after protection, which is datagram padding
%% and not PADDING frames, so only the in-payload padding counts.
-spec packet_flags([term()], boolean()) -> {boolean(), boolean()}.
packet_flags(Frames, Padded) ->
    AckEliciting = quic_ack:contains_ack_eliciting_frames(Frames),
    {AckEliciting, AckEliciting orelse Padded orelse lists:member(padding, Frames)}.

%% RFC 9002 Section 7: a handshake packet counts against the congestion
%% window like any other. A refusal holds the frames rather than the
%% encoded packet, so the packet number is not spent and the packet is
%% rebuilt when the window reopens.
%%
%% Probes are exempt (Section 7, "an endpoint MAY send a probe packet
%% when it is blocked"), which is what keeps a blocked connection from
%% deadlocking on its own window.
-spec admit(
    quic_loss:space(), boolean(), non_neg_integer(), iodata(), [term()], #state{}
) ->
    {ok, #state{}} | {deferred, #state{}}.
%% A packet that is not in flight is not congestion controlled
%% (RFC 9002 Section 2), and holding one back is worse than pointless:
%% an acknowledgement is what frees the window, so deferring it can stall
%% the very handshake that would unblock the sender.
admit(_Space, false, _Size, _Payload, _Frames, State) ->
    {ok, State};
admit(_Space, _InFlight, _Size, _Payload, _Frames, #state{hs = #hs{hs_probe = true}} = State) ->
    {ok, State};
admit(_Space, _InFlight, _Size, _Payload, _Frames, #state{cc_state = undefined} = State) ->
    {ok, State};
admit(Space, true, Size, Payload, Frames, #state{cc_state = CCState} = State) ->
    %% Urgency 0 buys the control allowance: a handshake flight is small
    %% and stalling it behind a full window stalls the connection.
    case quic_cc:send_check(CCState, Size, 0) of
        {ok, NewCC} ->
            {ok, State#state{cc_state = NewCC}};
        {blocked_cwnd, _Avail} ->
            %% The window reopens on acknowledgement, and something is
            %% in flight while it is shut, so the retry is already
            %% coming.
            {deferred, enqueue_hs(Space, Payload, Frames, State)};
        {blocked_pacing, Delay} ->
            %% Pacing can refuse with nothing in flight, so no
            %% acknowledgement is on its way to drain this: it has to
            %% schedule its own retry.
            {deferred, maybe_set_pacing_timer(Delay, enqueue_hs(Space, Payload, Frames, State))}
    end.

%% A queue, so both ends are cheap: a sustained refusal appends and the
%% drain takes from the head.
%%
%% Nothing queued is ever evicted. CRYPTO is a reliable ordered stream,
%% so dropping a fragment leaves the peer a gap it can never fill and
%% deadlocks the handshake. What we queue is our own flight, bounded by
%% the handshake rather than by anything the peer controls, so the
%% ceiling only catches a local fault and closing is the honest answer
%% to reaching it.
enqueue_hs(Space, Payload, Frames, State) ->
    #state{hs = #hs{pending_hs = Pending, pending_hs_bytes = Bytes}} = State,
    Held = maps:get(Space, Bytes, 0) + iolist_size(Payload),
    case Held > ?MAX_PENDING_HS_BYTES of
        true ->
            ?LOG_ERROR(
                #{what => pending_handshake_overflow, space => Space, bytes => Held},
                ?QUIC_LOG_META
            ),
            close_with_error(
                level_for_close(Space),
                transport,
                ?QUIC_INTERNAL_ERROR,
                0,
                <<"pending handshake queue overflow">>,
                State#state{
                    hs = (State#state.hs)#hs{
                        pending_hs = #{initial => queue:new(), handshake => queue:new()},
                        pending_hs_bytes = #{initial => 0, handshake => 0}
                    }
                }
            );
        false ->
            Queued = maps:get(Space, Pending, queue:new()),
            State#state{
                hs = (State#state.hs)#hs{
                    pending_hs = Pending#{Space => queue:in({Payload, Frames}, Queued)},
                    pending_hs_bytes = Bytes#{Space => Held}
                }
            }
    end.

%% Rebuild and resend what a gate refused, in order.
-spec drain_pending_hs(#state{}) -> #state{}.
drain_pending_hs(#state{} = State) ->
    lists:foldl(fun drain_space/2, State, [initial, handshake]).

drain_space(Space, #state{hs = #hs{pending_hs = Pending}} = State) ->
    Queued = maps:get(Space, Pending, queue:new()),
    case queue:is_empty(Queued) of
        true ->
            State;
        false ->
            %% The queue is held outside the state for the walk, so a
            %% refusal re-enqueues into an empty one and is easy to see.
            %% The byte counter stays as it is and is adjusted per
            %% packet.
            drain_one_by_one(Space, Queued, State#state{
                hs = (State#state.hs)#hs{
                    pending_hs = Pending#{Space => queue:new()}
                }
            })
    end.

%% Stop at the first refusal. The gates do not depend on what is being
%% sent, so a refusal settles everything behind it, and every received
%% datagram runs a drain: pushing the whole queue through the send path
%% would rebuild and protect each packet only to have it refused again,
%% which is CPU a peer could spend for us. Putting the untouched tail
%% back costs the same whatever its length.
drain_one_by_one(Space, Queue, State) ->
    case queue:out(Queue) of
        {empty, _} ->
            State;
        {{value, {Payload, Frames}}, Rest} ->
            %% Uncount it before the attempt: a refusal goes back
            %% through enqueue_hs, which counts it again.
            Bytes = (State#state.hs)#hs.pending_hs_bytes,
            Held = max(0, maps:get(Space, Bytes, 0) - iolist_size(Payload)),
            Sent = send_at_level(
                Space, Payload, Frames, State#state{
                    hs = (State#state.hs)#hs{pending_hs_bytes = Bytes#{Space => Held}}
                }
            ),
            Requeued = maps:get(Space, (Sent#state.hs)#hs.pending_hs, queue:new()),
            case queue:is_empty(Requeued) of
                true ->
                    drain_one_by_one(Space, Rest, Sent);
                false ->
                    Sent#state{
                        hs = (Sent#state.hs)#hs{
                            pending_hs = ((Sent#state.hs)#hs.pending_hs)#{
                                Space => queue:join(Requeued, Rest)
                            }
                        }
                    }
            end
    end.

%% Send an Initial packet.
%%
%% Once the keys for a level are discarded nothing may be sent at it
%% (RFC 9001 Section 4.9.1), so a send that races the discard is dropped
%% rather than crashing. The peer has discarded that space too, so there
%% is nothing left for it to acknowledge.
send_initial_packet(_Payload, _Frames, #state{hs = #hs{initial_keys = undefined}} = State) ->
    State;
send_initial_packet(Payload, Frames, State) ->
    #state{
        dcid = DCID,
        version = Version,
        cfg = #conn_cfg{
            scid = SCID,
            role = Role
        },
        hs = #hs{
            initial_keys = {ClientKeys, ServerKeys},
            pn_initial = PNSpace,
            retry_token = RetryToken
        }
    } = State,

    %% Select correct keys based on role:
    %% - Client sends with ClientKeys
    %% - Server sends with ServerKeys
    EncryptKeys =
        case Role of
            client -> ClientKeys;
            server -> ServerKeys
        end,

    PN = PNSpace#pn_space.next_pn,
    PNLen = quic_packet:pn_length(PN),

    %% Encode the retry token (RFC 9000 Section 17.2.2)
    %% Token is a variable-length field preceded by a varint length
    TokenLen = byte_size(RetryToken),
    TokenLenEnc = quic_varint:encode(TokenLen),

    %% Pad payload if needed for header protection sampling
    PaddedPayload = pad_for_header_protection(Payload),

    %% Build header prefix (without packet number)
    HeaderBody = <<
        Version:32,
        (byte_size(DCID)):8,
        DCID/binary,
        (byte_size(SCID)):8,
        SCID/binary,
        % Token length + token
        TokenLenEnc/binary,
        RetryToken/binary,
        % +16 for AEAD tag
        (quic_varint:encode(iolist_size(PaddedPayload) + PNLen + 16))/binary
    >>,

    %% First byte: long header form/fixed bits, version-specific Initial
    %% type bits, PN length
    FirstByte =
        16#C0 bor (quic_packet:type_to_bits(initial, Version) bsl 4) bor (PNLen - 1),
    HeaderPrefix = <<FirstByte, HeaderBody/binary>>,

    %% Protect packet (encrypt + header protection in single call)
    #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = EncryptKeys,
    Packet = quic_aead:protect_long_packet(
        Cipher, Key, IV, HP, PN, HeaderPrefix, PaddedPayload
    ),

    %% Pad Initial packets to at least 1200 bytes
    PaddedPacket = pad_initial_packet(Packet),

    %% Congestion control counts the protected packet; the amplification
    %% budget counts the datagram, which for a short Initial is larger
    %% because it is brought to 1200 bytes outside the packet.
    Padded = iolist_size(PaddedPayload) > iolist_size(Payload),
    {AckEliciting, InFlight} = packet_flags(Frames, Padded),
    Meta = {initial, PN, byte_size(Packet), Frames, AckEliciting, InFlight},
    case gate(initial, InFlight, byte_size(Packet), PaddedPacket, Payload, Frames, State) of
        {deferred, Deferred} ->
            Deferred;
        {ok, Admitted} ->
            State1 = emit(PaddedPacket, Meta, Admitted),

            %% Emit qlog packet_sent event
            quic_qlog:packet_sent((State#state.cfg)#conn_cfg.qlog_ctx, #{
                packet_type => initial,
                packet_number => PN,
                length => byte_size(PaddedPacket)
            }),

            %% Update packet number space and packet counter
            NewPNSpace = PNSpace#pn_space{next_pn = PN + 1},
            bump(?C_PACKETS_SENT, 1, State1),
            State1#state{hs = (State1#state.hs)#hs{pn_initial = NewPNSpace}}
    end.

%% Send an Initial ACK packet
send_initial_ack(State) ->
    #state{hs = #hs{pn_initial = PNSpace}} = State,
    case PNSpace#pn_space.ack_ranges of
        [] ->
            % Nothing to ACK
            State;
        Ranges ->
            %% Build ACK frame
            AckFrame = quic_ack:build_ack_frame(Ranges),
            send_initial_packet(AckFrame, [{ack, Ranges, 0, undefined}], bump_ack_sent(State))
    end.

%% Send a Handshake ACK packet
send_handshake_ack(State) ->
    #state{hs = #hs{pn_handshake = PNSpace}} = State,
    case PNSpace#pn_space.ack_ranges of
        [] ->
            State;
        Ranges ->
            AckFrame = quic_ack:build_ack_frame(Ranges),
            send_handshake_packet(AckFrame, [{ack, Ranges, 0, undefined}], bump_ack_sent(State))
    end.

%% Send an app-level ACK packet (1-RTT)
%% Coalesces ACK with small pending stream data when possible.
%% Always resets the decimation counter + cancels any armed ack_timer
%% so the next ack-eliciting batch starts a fresh window.
send_app_ack(State) ->
    send_app_ack(State, State#state.recv_pass).

%% Cancel the ACK timer, zero the decimation count, count the ACK and
%% set the receive-pass flag in one record update.
send_app_ack(#state{ack_timer = Ref, pn_app = PNSpace} = State, RecvPass) ->
    cancel_timer(Ref),
    case PNSpace#pn_space.ack_ranges of
        [] ->
            State#state{ack_timer = undefined, ack_elicited_count = 0, recv_pass = RecvPass};
        Ranges ->
            AckFrameTuple = quic_ack:build_ack_frame_tuple(Ranges),
            bump(?C_ACK_SENT, 1, State),
            maybe_coalesce_ack_with_data(AckFrameTuple, State#state{
                ack_timer = undefined,
                ack_elicited_count = 0,
                recv_pass = RecvPass
            })
    end.

%% Bump the ack_sent counter. Called once per ACK packet that is about
%% to hit the wire (after the ack_ranges non-empty check).
bump_ack_sent(State) ->
    bump(?C_ACK_SENT, 1, State),
    State.

%% Per-connection counters live in a counters array, so bumping one
%% copies nothing.
bump(Ix, N, #state{cfg = #conn_cfg{counters = C}}) ->
    counters:add(C, Ix, N).

count(Ix, #state{cfg = #conn_cfg{counters = C}}) ->
    counters:get(C, Ix).

%% Try to coalesce ACK frame with small pending stream data
%% Takes frame tuples (not encoded) to avoid re-decode overhead
maybe_coalesce_ack_with_data(AckFrameTuple, State) ->
    case dequeue_small_stream_frame_tuple(State) of
        {ok, StreamFrameTuple, State1} ->
            %% Send coalesced frames - pass tuples directly
            send_frame_tuples([AckFrameTuple, StreamFrameTuple], State1);
        none ->
            %% Flush the pending stream-data batch first: the ACK-only
            %% packet is ~60 bytes and would break GSO uniformity on the
            %% opt-in socket backend (see `quic_socket:gso_batch_uniform/2'),
            %% pushing the whole flush onto `flush_individual'. A
            %% preemptive flush keeps the stream batch uniform and lets
            %% the ACK start a fresh batch that flushes at the next
            %% send-cycle boundary.
            State1 = flush_socket_batch(State),
            send_app_packet_internal(quic_frame:encode(AckFrameTuple), [AckFrameTuple], State1)
    end.

%% Dequeue a small stream frame tuple if available (< 500 bytes)
%% Returns the frame tuple (not encoded) to avoid re-decode overhead
-define(SMALL_FRAME_THRESHOLD, 500).
dequeue_small_stream_frame_tuple(
    #state{
        send_queue = PQ,
        send_queue_bytes = QueueBytes,
        send_queue_count = QueueCount,
        send_queue_version = Version
    } = State
) ->
    case quic_pqueue:peek(PQ) of
        {value, {stream_data, StreamId, Offset, Data, Fin, DataSize}} when
            DataSize < ?SMALL_FRAME_THRESHOLD
        ->
            %% A queued entry is often one the peer's window has no room
            %% for yet: it rides along only once both windows admit it.
            case check_send_queue_flow_control(StreamId, Offset, DataSize, State) of
                ok ->
                    %% Remove from queue and return frame tuple (not encoded).
                    %% send_queue_bytes must be decremented here to match the
                    %% accounting done in process_send_queue_entry/1; otherwise
                    %% the counter leaks until it crosses ?MAX_SEND_QUEUE_BYTES.
                    %% data_sent and the FIN are settled as that path does.
                    {{value, _}, NewPQ} = quic_pqueue:out(PQ),
                    StreamFrameTuple = {stream, StreamId, Offset, Data, Fin},
                    NewState = State#state{
                        send_queue = NewPQ,
                        send_queue_bytes = max(0, QueueBytes - DataSize),
                        send_queue_count = max(0, QueueCount - 1),
                        send_queue_version = Version + 1,
                        data_sent = State#state.data_sent + DataSize
                    },
                    {ok, StreamFrameTuple, fin_sent_if(Fin, StreamId, NewState)};
                {blocked, _} ->
                    none
            end;
        _ ->
            none
    end.

fin_sent_if(true, StreamId, State) -> mark_fin_sent(StreamId, State);
fin_sent_if(false, _StreamId, State) -> State.

%% Send multiple frame tuples in a single packet
%% Takes frame tuples, encodes them, and passes directly to loss tracking
send_frame_tuples(FrameTuples, State) ->
    Payload = iolist_to_binary([quic_frame:encode(F) || F <- FrameTuples]),
    send_app_packet_internal(Payload, FrameTuples, State).

%% Send a Handshake packet
send_handshake_packet(_Payload, _Frames, #state{hs = #hs{handshake_keys = undefined}} = State) ->
    State;
send_handshake_packet(Payload, Frames, State) ->
    #state{
        dcid = DCID,
        version = Version,
        cfg = #conn_cfg{
            scid = SCID,
            role = Role
        },
        hs = #hs{
            handshake_keys = {ClientKeys, ServerKeys},
            pn_handshake = PNSpace
        }
    } = State,

    %% Select correct keys based on role
    EncryptKeys =
        case Role of
            client -> ClientKeys;
            server -> ServerKeys
        end,

    PN = PNSpace#pn_space.next_pn,
    PNLen = quic_packet:pn_length(PN),

    %% First byte for Handshake: 1110 0000 | (PNLen - 1)
    FirstByte =
        16#C0 bor (quic_packet:type_to_bits(handshake, Version) bsl 4) bor (PNLen - 1),

    %% Pad payload if needed for header protection sampling
    PaddedPayload = pad_for_header_protection(Payload),

    %% Build header prefix (length includes PN + encrypted payload + AEAD tag)
    HeaderBody = <<
        Version:32,
        (byte_size(DCID)):8,
        DCID/binary,
        (byte_size(SCID)):8,
        SCID/binary,
        (quic_varint:encode(iolist_size(PaddedPayload) + PNLen + 16))/binary
    >>,
    HeaderPrefix = <<FirstByte, HeaderBody/binary>>,

    %% Protect packet (encrypt + header protection in single call)
    #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = EncryptKeys,
    Packet = quic_aead:protect_long_packet(
        Cipher, Key, IV, HP, PN, HeaderPrefix, PaddedPayload
    ),
    Padded = iolist_size(PaddedPayload) > iolist_size(Payload),
    {AckEliciting, InFlight} = packet_flags(Frames, Padded),
    Meta = {handshake, PN, byte_size(Packet), Frames, AckEliciting, InFlight},
    case gate(handshake, InFlight, byte_size(Packet), Packet, Payload, Frames, State) of
        {deferred, Deferred} ->
            Deferred;
        {ok, Admitted} ->
            State1 = emit(Packet, Meta, Admitted),

            %% Emit qlog packet_sent event
            quic_qlog:packet_sent((State#state.cfg)#conn_cfg.qlog_ctx, #{
                packet_type => handshake,
                packet_number => PN,
                length => byte_size(Packet)
            }),

            %% Update PN space and packet counter
            NewPNSpace = PNSpace#pn_space{next_pn = PN + 1},
            bump(?C_PACKETS_SENT, 1, State1),
            State1#state{hs = (State1#state.hs)#hs{pn_handshake = NewPNSpace}}
    end.

%% Send a 1-RTT (application) packet with a single frame (avoid encode/decode roundtrip)
%% This is the preferred send function - encodes once and passes frame for loss tracking
send_frame(Frame, State) ->
    Payload = quic_frame:encode(Frame),
    send_app_packet_internal(Payload, [Frame], State).

%% Send a 1-RTT (application) packet with pre-encoded binary payload
%% Decodes the payload to extract frame info for loss tracking
%% Note: Prefer send_frame/2 when frame tuple is available
%% Send a 1-RTT packet with explicit frames list for retransmission tracking
%% Coalescing front end: within a drained send batch, small app
%% packets accumulate and are emitted as one multi-frame packet.
%% Everything downstream (packet build, loss tracking, retransmit,
%% counters) already handles a frames list per packet, so only the
%% emission point changes. A payload larger than the remaining budget
%% flushes the pending packet first; coalescing off means the old
%% one-packet-per-call behaviour, byte for byte.
send_app_packet_internal(Payload, Frames, State) ->
    send_app_packet_internal(Payload, Frames, State, State#state.cc_state).

%% CCState is the congestion state the caller already charged for this
%% packet, stored with the rest of the update instead of a copy of its own.
send_app_packet_internal(Payload, Frames, #state{coalesce = true} = State, CCState) ->
    #state{pend_payload = PP, pend_frames = PF, pend_size = PS} = State,
    Size = erlang:iolist_size(Payload),
    Budget = get_max_stream_data_per_packet(State),
    case PS > 0 andalso PS + Size > Budget of
        true ->
            State1 = flush_pending_packet(State#state{cc_state = CCState}),
            State1#state{
                pend_payload = [Payload],
                pend_frames = lists:reverse(Frames),
                pend_size = Size
            };
        false ->
            State#state{
                pend_payload = [Payload | PP],
                pend_frames = lists:reverse(Frames, PF),
                pend_size = PS + Size,
                cc_state = CCState
            }
    end;
send_app_packet_internal(Payload, Frames, State, CCState) ->
    send_app_packet_now(Payload, Frames, State, keep, CCState).

%% Drain consecutive send requests already sitting in the mailbox and
%% process them as one batch with coalescing enabled, so frames from
%% concurrent senders share packets (issue #201). Only send messages
%% are drained; everything else keeps its ordinary ordering. A lone
%% send has nothing to share a packet with and skips coalescing.
coalesced_sends(Acc0, State0) ->
    Sends = drain_send_msgs(Acc0, 63),
    Coalesce = (tl(Sends) =/= []),
    {RevReplies, State1} =
        lists:foldl(
            fun({Tag, Sid, Data, Fin}, {Rs, S}) ->
                case do_send_data(Sid, Data, Fin, S, send_admission(Tag)) of
                    {ok, S2} ->
                        {[{Tag, ok} | Rs], S2};
                    {error, send_queue_full} ->
                        bump(?C_SEND_QUEUE_FULL_REFUSALS, 1, S),
                        {[{Tag, {error, send_queue_full}} | Rs], S};
                    {error, Reason} ->
                        {[{Tag, {error, Reason}} | Rs], S}
                end
            end,
            {[], start_coalescing(Coalesce, State0)},
            Sends
        ),
    State2 = end_coalescing(Coalesce, State1),
    FlushedState = flush_event(State2, event),
    Replies = [{reply, F, R} || {F, R} <- lists:reverse(RevReplies), F =/= async],
    {keep_state, FlushedState, Replies}.

%% An async send has no caller to hand send_queue_full back to.
send_admission(async) -> force;
send_admission(_From) -> check.

drain_send_msgs(Acc, 0) ->
    lists:reverse(Acc);
drain_send_msgs(Acc, N) ->
    receive
        {'$gen_call', From, {send_data, Sid, D, Fin}} ->
            drain_send_msgs([{From, Sid, D, Fin} | Acc], N - 1);
        {'$gen_cast', {send_data_async, Sid, D, Fin}} ->
            drain_send_msgs([{async, Sid, D, Fin} | Acc], N - 1)
    after 0 ->
        lists:reverse(Acc)
    end.

flush_pending_packet(#state{pend_size = 0} = State) ->
    State;
flush_pending_packet(#state{pend_payload = PP, pend_frames = PF} = State) ->
    send_app_packet_now(lists:reverse(PP), lists:reverse(PF), State, clear, State#state.cc_state).

%% Leave a coalescing batch: flush what it accumulated and turn
%% coalescing off in the same update.
start_coalescing(false, State) -> State;
start_coalescing(true, State) -> State#state{coalesce = true}.

end_coalescing(false, State) ->
    State;
end_coalescing(true, #state{pend_size = 0} = State) ->
    State#state{coalesce = false};
end_coalescing(true, #state{pend_payload = PP, pend_frames = PF} = State) ->
    send_app_packet_now(lists:reverse(PP), lists:reverse(PF), State, close, State#state.cc_state).

%% Counts against the per-drain burst budget here rather than in
%% send_app_packet_internal/3: with coalescing on, several sends share
%% one packet, and the budget bounds packets on the wire. `clear' empties
%% the coalescing buffer the payload came from, in the same update;
%% `close' also turns coalescing off.
send_app_packet_now(Payload0, Frames0, State, Pend, CCState) ->
    AckEliciting = quic_ack:contains_ack_eliciting_frames(Frames0),
    {Payload, Frames, AckFields} = piggyback_ack(AckEliciting, Payload0, Frames0, State),
    #state{
        dcid = DCID,
        app_keys = {ClientKeys, ServerKeys},
        pn_app = PNSpace,
        loss_state = LossState,
        cfg = #conn_cfg{
            role = Role
        }
    } = State,

    %% Select correct keys based on role
    EncryptKeys =
        case Role of
            client -> ClientKeys;
            server -> ServerKeys
        end,

    PN = PNSpace#pn_space.next_pn,
    PNLen = quic_packet:pn_length(PN),

    %% Get current key phase for encoding
    KeyPhase = get_current_key_phase(State),

    %% First byte for short header: 01XX XXXX
    %% Bit 5 = spin bit (0), bits 3-4 reserved (0), bit 2 = key phase, bits 0-1 = PN length
    FirstByte = short_header_first_byte(KeyPhase, PNLen, State),

    %% Pad payload if needed for header protection sampling
    PaddedPayload = pad_for_header_protection(Payload),

    %% Protect packet (encrypt + header protection in single call)
    #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = EncryptKeys,
    Packet = quic_aead:protect_short_packet(
        Cipher, Key, IV, HP, PN, FirstByte, DCID, PaddedPayload
    ),
    PacketSize = byte_size(Packet),
    SendResult = do_socket_send(Packet, State),

    %% Handle send result - only track packet and update state if send succeeded
    case SendResult of
        {ok, NewSocketState} ->
            %% Emit qlog packet_sent event (no-op when qlog disabled)
            ?QLOG_EMIT_PACKET_SENT((State#state.cfg)#conn_cfg.qlog_ctx, #{
                packet_type => one_rtt,
                packet_number => PN,
                length => PacketSize,
                frames => Frames
            }),

            %% Single monotonic_time sample shared between loss
            %% tracking and last_activity; saves one BIF call per
            %% packet on the bulk-send hot path.
            Now = erlang:monotonic_time(millisecond),

            %% Track sent packet for loss detection and congestion control.
            NewLossState = quic_loss:on_packet_sent(
                app, LossState, PN, PacketSize, AckEliciting, Frames, Now
            ),
            NewCCState =
                case AckEliciting of
                    true -> quic_cc:on_packet_sent(CCState, PacketSize);
                    false -> CCState
                end,

            %% Update PN space, counters, socket state and dirty bits in
            %% a single record update to avoid copying #state{} multiple
            %% times per packet on the bulk-send hot path.
            NewPNSpace = PNSpace#pn_space{next_pn = PN + 1},
            EffectiveSocketState =
                case NewSocketState of
                    undefined -> State#state.socket_state;
                    _ -> NewSocketState
                end,
            %% RFC 9000 §10.1: restart the idle timer (by bumping last_activity)
            %% only on the first ack-eliciting packet sent since we last received
            %% one. Restarting on every send let a peer sending keep-alive PINGs /
            %% PTO retransmits into a black hole hold its own idle timer open
            %% forever; never restarting would spuriously close a reactivated idle
            %% connection before its first ack returns. The flag is cleared on
            %% every receive (update_last_activity/2).
            RestartIdle = AckEliciting andalso (not State#state.ack_eliciting_since_recv),
            NewLastActivity =
                case RestartIdle of
                    true -> Now;
                    false -> State#state.last_activity
                end,
            {NewKeyState, KeyLimit} = count_sealed(State#state.key_state, 1),
            {AckTimer, AckCount} = sent_ack_fields(AckFields, State),
            bump(?C_PACKETS_SENT, 1, State),
            {PendPayload, PendFrames, PendSize, Coalesce} =
                case Pend of
                    keep ->
                        #state{
                            pend_payload = PP, pend_frames = PF, pend_size = PS, coalesce = C
                        } = State,
                        {PP, PF, PS, C};
                    clear ->
                        {[], [], 0, State#state.coalesce};
                    close ->
                        {[], [], 0, false}
                end,
            State1 = State#state{
                pn_app = NewPNSpace,
                cc_state = NewCCState,
                loss_state = NewLossState,
                socket_state = EffectiveSocketState,
                last_activity = NewLastActivity,
                ack_eliciting_since_recv =
                    AckEliciting orelse State#state.ack_eliciting_since_recv,
                pto_dirty = true,
                burst_sent = State#state.burst_sent + 1,
                key_state = NewKeyState,
                pend_payload = PendPayload,
                pend_frames = PendFrames,
                pend_size = PendSize,
                coalesce = Coalesce,
                ack_timer = AckTimer,
                ack_elicited_count = AckCount
            },
            after_sealed(KeyLimit, State1);
        {error, Reason, ClearedSocketState} ->
            send_app_packet_internal_error(
                Reason,
                PN,
                PacketSize,
                PNSpace,
                clear_pend(Pend, State#state{cc_state = CCState}),
                ClearedSocketState
            );
        {error, Reason} ->
            send_app_packet_internal_error(
                Reason,
                PN,
                PacketSize,
                PNSpace,
                clear_pend(Pend, State#state{cc_state = CCState}),
                undefined
            )
    end.

clear_pend(keep, State) ->
    State;
clear_pend(clear, State) ->
    State#state{pend_payload = [], pend_frames = [], pend_size = 0};
clear_pend(close, State) ->
    State#state{pend_payload = [], pend_frames = [], pend_size = 0, coalesce = false}.

%% An ack-eliciting packet carries the pending ACK when it fits the data
%% budget (RFC 9000 §13.2.1 lets an ACK ride on any 1-RTT packet), so an
%% interactive exchange sends no ACK-only packet and needs no ACK timer.
%% `acked' tells the packet update to clear the decimation state.
piggyback_ack(
    true,
    Payload,
    Frames,
    #state{
        ack_elicited_count = Count,
        ack_timer = Timer,
        pn_app = #pn_space{ack_ranges = [_ | _] = Ranges}
    } = State
) when Count > 0; Timer =/= undefined ->
    AckFrame = quic_ack:build_ack_frame_tuple(Ranges),
    AckBin = quic_frame:encode(AckFrame),
    case
        erlang:iolist_size(Payload) + byte_size(AckBin) =<
            get_max_stream_data_per_packet(State)
    of
        true -> {[AckBin | Payload], [AckFrame | Frames], acked};
        false -> {Payload, Frames, none}
    end;
piggyback_ack(_AckEliciting, Payload, Frames, _State) ->
    {Payload, Frames, none}.

%% ACK timer and decimation count after the packet went out.
sent_ack_fields(none, #state{ack_timer = T, ack_elicited_count = C}) ->
    {T, C};
sent_ack_fields(acked, #state{ack_timer = T} = State) ->
    cancel_timer(T),
    bump(?C_ACK_SENT, 1, State),
    {undefined, 0}.

%% Common error handling for send_app_packet_internal: bump PN without
%% tracking the packet (PTO owns retransmission) and, on the 3-tuple
%% error path, write back the cleared socket_state so the stale batch
%% does not linger.
send_app_packet_internal_error(Reason, PN, PacketSize, PNSpace, State, ClearedSocketState) ->
    ?LOG_WARNING(
        #{what => udp_send_failed, reason => Reason, pn => PN, size => PacketSize},
        ?QUIC_LOG_META
    ),
    NewPNSpace = PNSpace#pn_space{next_pn = PN + 1},
    Burst = State#state.burst_sent + 1,
    case ClearedSocketState of
        undefined ->
            State#state{pn_app = NewPNSpace, burst_sent = Burst};
        _ ->
            State#state{
                pn_app = NewPNSpace, socket_state = ClearedSocketState, burst_sent = Burst
            }
    end.

%% Pad Initial packet to minimum 1200 bytes
pad_initial_packet(Packet) when byte_size(Packet) >= 1200 ->
    Packet;
pad_initial_packet(Packet) ->
    PadLen = 1200 - byte_size(Packet),
    <<Packet/binary, 0:PadLen/unit:8>>.

%% Pad payload if needed for header protection sampling.
%% Header protection requires a 16-byte sample from the encrypted payload.
%% The sample starts at offset max(0, 4 - PNLen) into the ciphertext.
%% With worst-case PNLen=1, we need at least 3 + 16 = 19 bytes of ciphertext.
%% Since AEAD adds a 16-byte tag, plaintext needs to be >= 3 bytes.
%% We pad to 4 bytes to be safe (using PADDING frames which are 0x00).
%% Accepts iodata so the hot stream-send path can avoid flattening the
%% per-chunk payload for frame encoding.
pad_for_header_protection(Payload) ->
    case iolist_size(Payload) of
        N when N >= 4 ->
            Payload;
        N ->
            PadLen = 4 - N,
            [Payload, <<0:PadLen/unit:8>>]
    end.

%% @doc Pad payload for path validation to reach 1200 bytes.
%% RFC 9000 Section 8.2.1: Path validation packets MUST be padded to at least
%% 1200 bytes to verify PMTU and prevent amplification attacks.
%% PADDING frames (0x00 bytes) are added to the payload BEFORE AEAD protection.
-spec pad_for_path_validation(binary(), binary()) -> binary().
pad_for_path_validation(Payload, DCID) ->
    %% Estimate final packet size after protection:
    %% - Short header: 1 (flags) + DCID length + 1-4 (PN) ~= 1 + len(DCID) + 2
    %% - Payload (with padding) + AEAD tag (16 bytes)
    HeaderSize = 1 + byte_size(DCID) + 2,
    AEADTagSize = 16,
    MinPacketSize = 1200,
    CurrentSize = HeaderSize + byte_size(Payload) + AEADTagSize,
    case CurrentSize >= MinPacketSize of
        true ->
            Payload;
        false ->
            PadLen = MinPacketSize - CurrentSize,
            %% PADDING frames are 0x00 bytes - add them to the payload
            PaddingFrames = binary:copy(<<0>>, PadLen),
            <<Payload/binary, PaddingFrames/binary>>
    end.

%%====================================================================
%% Internal Functions - Frame Classification (RFC 9000 Section 9.1)
%%====================================================================

%% @doc Check if a frame is a probing frame.
%% RFC 9000 Section 9.1: Probing frames are PATH_CHALLENGE, PATH_RESPONSE,
%% NEW_CONNECTION_ID, and PADDING. Only non-probing frames trigger migration.
-spec is_probing_frame(term()) -> boolean().
is_probing_frame(padding) -> true;
is_probing_frame({padding, _}) -> true;
is_probing_frame({path_challenge, _}) -> true;
is_probing_frame({path_response, _}) -> true;
is_probing_frame({new_connection_id, _, _, _, _}) -> true;
is_probing_frame(_) -> false.

%% @doc Check if a list of frames contains any non-probing frame.
%% RFC 9000 Section 9.1: Only packets containing non-probing frames trigger migration.
-spec contains_non_probing_frame([term()]) -> boolean().
contains_non_probing_frame([]) ->
    false;
contains_non_probing_frame([Frame | Rest]) ->
    case is_probing_frame(Frame) of
        true -> contains_non_probing_frame(Rest);
        false -> true
    end.

%%====================================================================
%% Internal Functions - Packet Processing
%%====================================================================

%% Handle incoming packet (may be coalesced with multiple QUIC packets)
handle_packet(Data, State) ->
    %% RFC 9000 §8.1: count every received byte toward the
    %% anti-amplification budget, then retry any flight a gate held back,
    %% which the fresh budget (or address validation) may now let out.
    State1 = amp_account_recv(Data, State),
    State2 = handle_packet_loop(Data, State1),
    drain_pending_hs(State2).

%% Server-side anti-amplification accounting/gating (RFC 9000 §8.1).
amp_account_recv(
    Data, #state{cfg = #conn_cfg{role = server}, hs = #hs{address_validated = false}} = State
) ->
    State#state{hs = (State#state.hs)#hs{amp_rx = (State#state.hs)#hs.amp_rx + byte_size(Data)}};
amp_account_recv(_Data, State) ->
    State.

%% Both gates a pre-handshake packet has to clear, in the only order
%% that lets a refusal cost nothing.
%%
%% Amplification first and congestion second, because only the second
%% has state to spend: a packet refused here has not taken a packet
%% number, has not been counted as sent and has not drawn on the pacer,
%% so its later attempt is a first attempt rather than a retry. Both
%% refusals put the frames in the same per-space queue, which is what
%% keeps a flight in order across the two.
%%
%% The two measure different things: the congestion window counts the
%% protected packet, the amplification budget counts the datagram, which
%% for a short Initial is larger because it is brought to 1200 bytes
%% outside the packet.
-spec gate(
    quic_loss:space(), boolean(), non_neg_integer(), iodata(), iodata(), [term()], #state{}
) ->
    {ok, #state{}} | {deferred, #state{}}.
gate(Space, InFlight, Size, Datagram, Payload, Frames, State) ->
    case amp_allows(Datagram, State) of
        false ->
            {deferred, enqueue_hs(Space, Payload, Frames, State)};
        true ->
            admit(Space, InFlight, Size, Payload, Frames, State)
    end.

%% RFC 9000 Section 8.1: until it has validated the peer address a
%% server may send at most three times what it has received. The limit
%% is absolute, so unlike the congestion window it has no probe
%% exemption.
amp_allows(
    Datagram, #state{cfg = #conn_cfg{role = server}, hs = #hs{address_validated = false}} = State
) ->
    ((State#state.hs)#hs.amp_tx + erlang:iolist_size(Datagram)) =< (3 * (State#state.hs)#hs.amp_rx);
amp_allows(_Datagram, _State) ->
    true.

%% Put the datagram on the wire and charge it, in that order: nothing is
%% spent until both gates have passed.
emit(
    Datagram,
    Meta,
    #state{cfg = #conn_cfg{role = server}, hs = #hs{address_validated = false}} = State
) ->
    State1 = State#state{
        socket_state = send_and_take_socket_state(Datagram, State),
        hs = (State#state.hs)#hs{
            amp_tx = (State#state.hs)#hs.amp_tx + erlang:iolist_size(Datagram)
        }
    },
    register_now(Meta, erlang:monotonic_time(millisecond), State1);
emit(Datagram, Meta, State) ->
    State1 = State#state{socket_state = send_and_take_socket_state(Datagram, State)},
    register_now(Meta, erlang:monotonic_time(millisecond), State1).

%% Only a packet in flight is tracked or charged (RFC 9002 Section 2).
register_now({_Space, _PN, _Size, _Frames, _AckEliciting, false}, _Now, State) ->
    State;
register_now({Space, PN, Size, Frames, AckEliciting, true}, Now, State) ->
    LossState = quic_loss:on_packet_sent(
        Space, State#state.loss_state, PN, Size, AckEliciting, Frames, Now
    ),
    State#state{
        loss_state = LossState,
        cc_state = quic_cc:on_packet_sent(State#state.cc_state, Size),
        pto_dirty = true
    }.

%% Mark the peer address validated once a server decrypts a Handshake
%% packet from it (RFC 9000 §8.1) — lifts the amplification limit.
amp_mark_validated(
    handshake, #state{cfg = #conn_cfg{role = server}, hs = #hs{address_validated = false}} = State
) ->
    State#state{hs = (State#state.hs)#hs{address_validated = true}};
amp_mark_validated(_Type, State) ->
    State.

%% RFC 9001 Section 4.9.1: a server discards its Initial keys once it
%% first successfully processes a Handshake packet. The trigger is
%% receiving one, not lifting the amplification limit, which may already
%% have been lifted by a validated token.
server_discard_initial(handshake, #state{cfg = #conn_cfg{role = server}} = State) ->
    discard_initial(State);
server_discard_initial(_Type, State) ->
    State.

%% Batched variant of handle_packet/2: same anti-amplification
%% accounting per datagram, one drain per batch. The batched delivery
%% path previously skipped accounting entirely, so a server's amp budget
%% froze at the first datagram under load and held flights never went
%% out.
handle_packets_batch(Packets, State) ->
    State1 = lists:foldl(fun amp_account_recv/2, State, Packets),
    State2 = do_handle_packets_batch(Packets, State1),
    drain_pending_hs(State2).

%% Handle batch of packets from GRO - process all without re-entering gen_statem
%% This is more efficient than receiving multiple messages
do_handle_packets_batch([], State) ->
    State;
do_handle_packets_batch([<<0:1, 1:1, _:6, _/binary>> | _] = Packets, State) ->
    %% Leading run of short-header (1-RTT) datagrams: open the whole
    %% run in one NIF call when the fused fast path applies.
    case fused_run_keys(State) of
        {ok, Keys} ->
            handle_short_run(Packets, Keys, State);
        no ->
            [Packet | Rest] = Packets,
            do_handle_packets_batch(Rest, handle_packet_loop(Packet, State))
    end;
do_handle_packets_batch([Packet | Rest], State) ->
    NewState = handle_packet_loop(Packet, State),
    do_handle_packets_batch(Rest, NewState).

%% Peer-direction keys for the batched fused open, under the same
%% no-key-update-in-flight condition as fused_decrypt_keys/2.
fused_run_keys(#state{app_keys = undefined}) ->
    no;
fused_run_keys(#state{app_keys = {ClientKeys, ServerKeys}, cfg = #conn_cfg{role = Role}} = State) ->
    Current =
        case Role of
            client -> ServerKeys;
            server -> ClientKeys
        end,
    fused_decrypt_keys(Current, State).

handle_short_run(Packets, Keys, State) ->
    {Run, Tail} = take_short_run(Packets, []),
    #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = Keys,
    case
        quic_aead_ctx:open_run(
            Cipher,
            Key,
            IV,
            HP,
            get_largest_recv(app, State),
            get_current_key_phase(State),
            byte_size((State#state.cfg)#conn_cfg.scid),
            Run
        )
    of
        {ok, Results} ->
            State1 = fold_opened(Results, State),
            case lists:nthtail(length(Results), Run) of
                [] ->
                    do_handle_packets_batch(Tail, State1);
                [Unopened | RunRest] ->
                    %% First datagram the NIF could not open takes the
                    %% generic path (slow decrypt, key-phase transition,
                    %% stateless-reset check), then keep batching.
                    State2 = handle_packet_loop(Unopened, State1),
                    do_handle_packets_batch(RunRest ++ Tail, State2)
            end;
        fallback ->
            [Packet | Rest] = Packets,
            do_handle_packets_batch(Rest, handle_packet_loop(Packet, State))
    end.

take_short_run([<<0:1, 1:1, _:6, _/binary>> = P | Rest], Acc) ->
    take_short_run(Rest, [P | Acc]);
take_short_run(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

%% Post-decrypt processing for a batch-opened run: the same per-packet
%% effects as the fused branch of decrypt_app_packet/4 followed by the
%% `processed' branch of handle_packet_loop/2, with the per-packet
%% bookkeeping collapsed where the run's shape allows it.
%%
%% One monotonic_time sample serves the whole run (runs are opened
%% well under a millisecond, and nothing reads the counter mid-fold).
fold_opened(Results, State) ->
    Now = erlang:monotonic_time(millisecond),
    %% Contiguous-run fast path: when the whole opened run continues the
    %% receive sequence exactly (PNs consecutive from largest_recv + 1,
    %% which also means the head ACK range extends in place), the
    %% per-packet receive bookkeeping collapses into one state update:
    %% largest/ranges/spin from the last packet, every packet classified
    %% sequential. Any other shape takes the per-packet path unchanged.
    case State#state.pn_app of
        #pn_space{largest_recv = L, ack_ranges = [{RangeStart, L} | RestRanges]} = PNSpace when
            is_integer(L)
        ->
            case seq_run_last(Results, L + 1) of
                {LastPN, LastFB} ->
                    SpinRecv = (LastFB bsr 5) band 1,
                    SpinOut =
                        case (State#state.cfg)#conn_cfg.spin_bit_enabled of
                            false -> State#state.spin_outgoing;
                            true when (State#state.cfg)#conn_cfg.role =:= client -> SpinRecv;
                            true -> 1 - SpinRecv
                        end,
                    NewPNSpace = PNSpace#pn_space{
                        largest_recv = LastPN,
                        recv_time = Now,
                        ack_ranges = [{RangeStart, LastPN} | RestRanges]
                    },
                    Recv = {NewPNSpace, SpinRecv, LastPN, SpinOut, Now},
                    case stream_train(Results, State) of
                        {ok, StreamId, FirstOff, RevChunks, Total, N} ->
                            apply_stream_train(
                                StreamId, FirstOff, RevChunks, Total, N, Recv, State
                            );
                        no ->
                            fold_opened_seq(Results, with_recv(Recv, State), 0, 0)
                    end;
                no ->
                    fold_opened(Results, State, Now, 0, 0)
            end;
        _ ->
            fold_opened(Results, State, Now, 0, 0)
    end.

%% Receive bookkeeping of a contiguous run, every packet sequential.
with_recv({PNSpace, SpinRecv, LastPN, SpinOut, Now}, State) ->
    State#state{
        pn_app = PNSpace,
        last_recv_trigger = sequential,
        spin_recv = SpinRecv,
        spin_recv_largest_pn = LastPN,
        spin_outgoing = SpinOut,
        last_activity = Now,
        ack_eliciting_since_recv = false
    }.

%% Last {PN, FirstByte} of a run iff PNs are consecutive from Expected.
seq_run_last([{PN, FB, _}], PN) ->
    {PN, FB};
seq_run_last([{PN, _, _} | [{PN2, _, _} | _] = Rest], PN) when PN2 =:= PN + 1 ->
    seq_run_last(Rest, PN2);
seq_run_last(_, _) ->
    no.

%% Per-packet loop for a contiguous run: receive bookkeeping already
%% applied for the whole train, every packet known sequential.
fold_opened_seq([], State, N, Elicited) ->
    fold_opened_finish(State, N, Elicited);
fold_opened_seq([{_PN, _FB, Opened} | Rest], State, N, Elicited) ->
    {ok, NewState, Frames} = opened_frames(Opened, State),
    ?QLOG_EMIT_PACKET_RECEIVED((NewState#state.cfg)#conn_cfg.qlog_ctx, #{
        packet_type => app,
        frames => Frames
    }),
    ?QLOG_EMIT_FRAMES_PROCESSED((NewState#state.cfg)#conn_cfg.qlog_ctx, Frames),
    {State2, Elicited2} =
        case quic_ack:contains_ack_eliciting_frames(Frames) of
            false ->
                {NewState, Elicited};
            true ->
                case should_delay_ack(Frames) of
                    true -> {schedule_delayed_ack(app, NewState), Elicited};
                    false -> {NewState, Elicited + 1}
                end
        end,
    fold_opened_seq(Rest, State2, N + 1, Elicited2).

%% Per-packet loop for a run that is not one contiguous sequence.
fold_opened([], State, _Now, N, Elicited) ->
    fold_opened_finish(State, N, Elicited);
fold_opened([{PN, FirstByte, Opened} | Rest], State, Now, N, Elicited) ->
    StateF = record_app_recv(FirstByte, PN, State, Now),
    {ok, NewState, Frames} = opened_frames(Opened, StateF),
    ?QLOG_EMIT_PACKET_RECEIVED((NewState#state.cfg)#conn_cfg.qlog_ctx, #{
        packet_type => app,
        frames => Frames
    }),
    ?QLOG_EMIT_FRAMES_PROCESSED((NewState#state.cfg)#conn_cfg.qlog_ctx, Frames),
    %% Per-packet ACK policy identical to maybe_send_ack(app, ...),
    %% except the count-based decimation increment is accumulated
    %% across the run and applied once at the end.
    {State2, Elicited2} =
        case quic_ack:contains_ack_eliciting_frames(Frames) of
            false ->
                {NewState, Elicited};
            true ->
                case should_delay_ack(Frames) of
                    true ->
                        {schedule_delayed_ack(app, NewState), Elicited};
                    false ->
                        case NewState#state.last_recv_trigger of
                            reordered ->
                                %% send_app_ack acks everything seen so
                                %% far and clears the count, so pending
                                %% increments are dropped with it.
                                {send_app_ack(NewState), 0};
                            sequential ->
                                {NewState, Elicited + 1}
                        end
                end
        end,
    fold_opened(Rest, State2, Now, N + 1, Elicited2).

%% Apply the run's packet count and its accumulated ack-eliciting
%% count. Inside a receive pass decimation only counts (the pass end
%% flushes), so one increment and one arm_ack_timer serve the run;
%% outside a pass each increment gets the threshold check it would
%% have had per packet.
fold_opened_finish(State1, N, Elicited) ->
    bump(?C_PACKETS_RECEIVED, N, State1),
    case {Elicited, State1#state.recv_pass} of
        {0, _} ->
            State1;
        {_, true} ->
            State1#state{ack_elicited_count = State1#state.ack_elicited_count + Elicited};
        {_, false} ->
            lists:foldl(
                fun(_, S) -> maybe_decimate_app_ack(S) end, State1, lists:seq(1, Elicited)
            )
    end.

%% Consume an open_run result: the NIF returns either a pre-parsed
%% frame list (term-identical to quic_frame:decode/1 output) or
%% {raw, Plain} for packets with frame types outside the fast path,
%% which keep the generic decoder and its error semantics. Parsed
%% frames go through the same per-frame processing as the decoder
%% loop.
opened_frames({raw, Plain}, State) ->
    decode_and_process_streaming(app, Plain, State);
opened_frames(Frames, State) when is_list(Frames) ->
    {ok,
        lists:foldl(
            fun(F, S) -> process_frame_track_probing(app, F, S) end, State, Frames
        ),
        Frames}.

%% Textbook bulk train: every packet in the run carries exactly one
%% stream frame, all for the same stream, offsets contiguous, no FIN,
%% and qlog is off (its per-packet events would be skipped). Returns
%% the chunks in reverse order.
stream_train(Results, State) ->
    case ?QLOG_ENABLED((State#state.cfg)#conn_cfg.qlog_ctx) of
        true -> no;
        false -> stream_train(Results, undefined, undefined, [], 0, 0)
    end.

stream_train([], Sid, _NextOff, RevChunks, Total, N) when Sid =/= undefined ->
    {Off, _} = lists:last(RevChunks),
    {ok, Sid, Off, RevChunks, Total, N};
stream_train(
    [{_PN, _FB, [{stream, Sid, Off, Data, false}]} | Rest], undefined, undefined, [], 0, 0
) ->
    stream_train(Rest, Sid, Off + byte_size(Data), [{Off, Data}], byte_size(Data), 1);
stream_train(
    [{_PN, _FB, [{stream, Sid, Off, Data, false}]} | Rest], Sid, Off, RevChunks, Total, N
) ->
    stream_train(
        Rest,
        Sid,
        Off + byte_size(Data),
        [{Off, Data} | RevChunks],
        Total + byte_size(Data),
        N + 1
    );
stream_train(_, _, _, _, _, _) ->
    no.

%% One bookkeeping pass for a whole contiguous stream train: the same
%% conditions as the lean clause of do_process_stream_data_buffered/5,
%% checked once with the train's totals; any deviation replays the
%% train through the per-packet path.
%% Inside a receive pass the run's bookkeeping (Recv), the stream update
%% and fold_opened_finish/3 are written in one record update.
apply_stream_train(StreamId, FirstOff, RevChunks, Total, N, Recv, State) ->
    case State#state.streams of
        #{
            StreamId := #stream_state{
                recv_offset = FirstOff,
                recv_max_data = RecvMaxData,
                final_size = undefined,
                recv_reset_at = undefined,
                recv_buffer = RB
            } = Stream
        } ->
            EndOffset = FirstOff + Total,
            NewDataReceived = State#state.data_received + Total,
            HalfWindow = (State#state.cfg)#conn_cfg.fc_max_receive_window div 2,
            case
                Total > 0 andalso
                    gb_trees:is_empty(RB) andalso
                    RecvMaxData - EndOffset >= HalfWindow andalso
                    State#state.max_data_local - NewDataReceived >= HalfWindow andalso
                    State#state.recv_buffer_bytes + Total =< ?MAX_RECV_BUFFER_BYTES
            of
                true ->
                    PendDeliver = deliver_stream_train(StreamId, RevChunks, State),
                    Streams = maps:put(
                        StreamId,
                        Stream#stream_state{recv_offset = EndOffset},
                        State#state.streams
                    ),
                    case State#state.recv_pass of
                        true ->
                            bump(?C_PACKETS_RECEIVED, N, State),
                            {PNSpace, SpinRecv, LastPN, SpinOut, Now} = Recv,
                            State#state{
                                pn_app = PNSpace,
                                last_recv_trigger = sequential,
                                spin_recv = SpinRecv,
                                spin_recv_largest_pn = LastPN,
                                spin_outgoing = SpinOut,
                                last_activity = Now,
                                ack_eliciting_since_recv = false,
                                streams = Streams,
                                data_received = NewDataReceived,
                                pend_deliver = PendDeliver,
                                has_non_probing_frame = true,
                                ack_elicited_count = State#state.ack_elicited_count + N
                            };
                        false ->
                            State1 = with_recv(Recv, State),
                            fold_opened_finish(
                                State1#state{
                                    streams = Streams,
                                    data_received = NewDataReceived,
                                    pend_deliver = PendDeliver,
                                    has_non_probing_frame = true
                                },
                                N,
                                N
                            )
                    end;
                false ->
                    stream_train_fallback(StreamId, RevChunks, with_recv(Recv, State))
            end;
        _ ->
            stream_train_fallback(StreamId, RevChunks, with_recv(Recv, State))
    end.

%% Deviating train: replay it through the ordinary per-packet path.
stream_train_fallback(StreamId, RevChunks, State) ->
    {StateN, N} = lists:foldr(
        fun({Off, Data}, {Acc, Cnt}) ->
            {process_stream_data(StreamId, Off, Data, false, Acc), Cnt + 1}
        end,
        {State, 0},
        RevChunks
    ),
    fold_opened_finish(StateN#state{has_non_probing_frame = true}, N, N).

%% Deliver a whole train with the delivery contract of
%% deliver_stream_data/4: merged into the pending run under coalescing
%% (the chunks are adjacent and in order by construction), one message
%% per chunk in stream order otherwise. Returns the new pend_deliver.
deliver_stream_train(
    StreamId,
    RevChunks,
    #state{recv_pass = true, cfg = #conn_cfg{delivery_coalescing = true}} = State
) ->
    RevData = [Data || {_Off, Data} <- RevChunks],
    case State#state.pend_deliver of
        {StreamId, Acc, F} ->
            {StreamId, RevData ++ Acc, F};
        none ->
            {StreamId, RevData, false};
        {OtherId, Acc, F} ->
            State#state.owner ! {quic, self(), {stream_data, OtherId, run_binary(Acc), F}},
            {StreamId, RevData, false}
    end;
deliver_stream_train(StreamId, RevChunks, State) ->
    Owner = State#state.owner,
    lists:foreach(
        fun({_Off, Data}) -> Owner ! {quic, self(), {stream_data, StreamId, Data, false}} end,
        lists:reverse(RevChunks)
    ),
    State#state.pend_deliver.

%% One server receive pass: process the packets of a listener message
%% (source tracking, frame classification, RFC 9000 §9.1 migration
%% check) without the per-message flushes - the caller flushes once
%% per drain. Opens the receive pass when it is the first message.
server_recv_pass(Packets, RemoteAddr, State) ->
    State1 = State#state{
        current_packet_source = RemoteAddr, has_non_probing_frame = false, recv_pass = true
    },
    NewState = handle_packets_batch(Packets, State1),
    case NewState#state.has_non_probing_frame of
        true ->
            TotalSize = lists:sum([byte_size(P) || P <- Packets]),
            maybe_handle_address_change(RemoteAddr, TotalSize, NewState);
        false ->
            NewState
    end.

%% Drain datagram messages already queued in the mailbox into the
%% current receive pass, so ACK emission, socket-batch flushing and
%% timer resets amortize over the whole train instead of running per
%% datagram. Stops as soon as a close is initiated (the remaining
%% messages are handled as ordinary events by the next state) or the
%% cap is hit (bounds time away from the event loop).
drain_recv_msgs(#state{close_reason = CR} = State, _N) when CR =/= undefined ->
    State;
drain_recv_msgs(State, 0) ->
    State;
drain_recv_msgs(#state{socket = Socket, cfg = #conn_cfg{role = client}} = State, N) ->
    receive
        {udp, Socket, IP, Port, Data} ->
            %% Collect the rest of the queued same-source datagrams so a
            %% train is opened as one batch instead of per message.
            State1 = State#state{current_packet_source = {IP, Port}},
            {Datagrams, Left} = collect_client_udp(Socket, IP, Port, N - 1, [Data]),
            drain_recv_msgs(handle_packets_batch(Datagrams, State1), Left);
        {udp_batch, Socket, IP, Port, Packets} ->
            State1 = State#state{current_packet_source = {IP, Port}},
            drain_recv_msgs(handle_packets_batch(Packets, State1), N - 1)
    after 0 ->
        State
    end;
drain_recv_msgs(#state{cfg = #conn_cfg{role = server}} = State, N) ->
    receive
        {quic_packet, Data, RemoteAddr} ->
            drain_recv_msgs(server_recv_pass([Data], RemoteAddr, State), N - 1);
        {quic_packets, Packets, RemoteAddr} ->
            drain_recv_msgs(server_recv_pass(Packets, RemoteAddr, State), N - 1)
    after 0 ->
        State
    end.

collect_client_udp(_Socket, _IP, _Port, 0, Acc) ->
    {lists:reverse(Acc), 0};
collect_client_udp(Socket, IP, Port, N, Acc) ->
    %% Both message shapes in one receive: taking only the single-datagram
    %% shape would pull those past earlier queued trains and reorder
    %% the connection's view of the wire.
    receive
        {udp, Socket, IP, Port, Data} ->
            collect_client_udp(Socket, IP, Port, N - 1, [Data | Acc]);
        {udp_batch, Socket, IP, Port, Packets} ->
            collect_client_udp(Socket, IP, Port, N - 1, lists:reverse(Packets, Acc))
    after 0 ->
        {lists:reverse(Acc), N}
    end.

handle_packet_loop(<<>>, #state{cfg = #conn_cfg{role = client, active_n = N}} = State) ->
    %% No more data to process - re-enable socket for client connections
    %% Note: With {active, N}, calling setopts resets the counter, so this is optional
    %% but provides safety in case socket went passive during processing
    client_rearm_active(State, N),
    State;
handle_packet_loop(<<>>, #state{cfg = #conn_cfg{role = server}} = State) ->
    %% No more data to process - server socket managed by listener
    State;
handle_packet_loop(Data, State) ->
    %% Header/frame parsing runs on attacker-controlled bytes before (and
    %% during) AEAD checks and can raise on truncated/oversized input
    %% (badmatch, varint throws). Convert any such crash into a dropped
    %% datagram so a malformed packet can never take down the connection.
    Decoded =
        try
            decode_and_decrypt_packet(Data, State)
        catch
            %% Catch every parser failure class (badmatch/badarg are
            %% `error', the varint truncation guard is `throw') so no
            %% datagram can crash the process. `exit' is deliberately not
            %% caught: it is how the handshake signals an intentional
            %% abort (e.g. a failed PSK binder), which must terminate the
            %% connection rather than be swallowed as a dropped datagram.
            ErrClass:ErrReason when ErrClass =:= error; ErrClass =:= throw ->
                {error, {malformed, ErrClass, ErrReason}}
        end,
    case Decoded of
        {ok, Type, Frames, RemainingData, NewState, processed} ->
            %% Frames already processed by streaming decode
            ?QLOG_EMIT_PACKET_RECEIVED((NewState#state.cfg)#conn_cfg.qlog_ctx, #{
                packet_type => Type,
                frames => Frames
            }),

            %% Increment packet counter for liveness detection
            bump(?C_PACKETS_RECEIVED, 1, NewState),

            ?QLOG_EMIT_FRAMES_PROCESSED((NewState#state.cfg)#conn_cfg.qlog_ctx, Frames),

            %% Send ACK if packet contained ack-eliciting frames
            State2 = server_discard_initial(
                Type, amp_mark_validated(Type, maybe_send_ack(Type, Frames, NewState))
            ),
            %% Continue with remaining coalesced packets
            handle_packet_loop(RemainingData, State2);
        {ok, Type, Frames, RemainingData, NewState} ->
            %% Legacy path - frames need to be processed
            ?QLOG_EMIT_PACKET_RECEIVED((NewState#state.cfg)#conn_cfg.qlog_ctx, #{
                packet_type => Type,
                frames => Frames
            }),

            bump(?C_PACKETS_RECEIVED, 1, NewState),
            State1 = process_frames_noreenbl(Type, Frames, NewState),
            ?QLOG_EMIT_FRAMES_PROCESSED((State1#state.cfg)#conn_cfg.qlog_ctx, Frames),
            State2 = server_discard_initial(
                Type, amp_mark_validated(Type, maybe_send_ack(Type, Frames, State1))
            ),
            handle_packet_loop(RemainingData, State2);
        {error, stateless_reset} ->
            %% RFC 9000 Section 10.3: Stateless reset received
            %% Immediately close the connection
            maybe_reenable_socket(State),
            State#state{close_reason = stateless_reset};
        {error, {version_negotiation, _} = Reason} ->
            %% RFC 9000 Section 6.2: the server speaks no version we do.
            %% Nothing may be sent in response, so just abandon the attempt.
            maybe_reenable_socket(State),
            State#state{close_reason = Reason};
        {error, Reason} when
            Reason =:= padding_only;
            Reason =:= empty_packet;
            Reason =:= invalid_fixed_bit
        ->
            %% End of coalesced packets (padding or invalid trailing data)
            %% This is normal, just re-enable socket and return
            maybe_reenable_socket(State),
            State;
        {error, Reason} ->
            %% Log decryption failure for debugging. Include the packet
            %% source, our CID expectation and the datagram head/tail so
            %% a misrouted datagram, a foreign connection's packet or a
            %% stateless reset can be told apart from a key/nonce bug.
            ?LOG_WARNING(
                #{
                    what => packet_decode_decrypt_failed,
                    role => (State#state.cfg)#conn_cfg.role,
                    reason => Reason,
                    size => byte_size(Data),
                    source => State#state.current_packet_source,
                    scid => binhex((State#state.cfg)#conn_cfg.scid),
                    dcid => binhex(State#state.dcid),
                    known_reset_tokens => [
                        {
                            E#cid_entry.seq_num,
                            binhex(E#cid_entry.cid),
                            binhex(E#cid_entry.stateless_reset_token)
                        }
                     || E <- quic_cid:peer_entries(State#state.cid_pool_state)
                    ],
                    head => binhex(binary:part(Data, 0, min(16, byte_size(Data)))),
                    tail => binhex(
                        binary:part(
                            Data,
                            byte_size(Data) - min(16, byte_size(Data)),
                            min(16, byte_size(Data))
                        )
                    )
                },
                ?QUIC_LOG_META
            ),
            %% Re-enable socket
            maybe_reenable_socket(State),
            State
    end.

binhex(Bin) when is_binary(Bin) -> binary:encode_hex(Bin);
binhex(Other) -> Other.

%% Re-enable socket for receiving - only for client connections.
%% Server connections use listener's socket which is managed by the listener.
%% With {active, N}, this resets the counter (provides safety margin).
maybe_reenable_socket(#state{cfg = #conn_cfg{role = client, active_n = N}} = State) ->
    client_rearm_active(State, N);
maybe_reenable_socket(#state{cfg = #conn_cfg{role = server}}) ->
    ok.

%% Decode and decrypt a packet
decode_and_decrypt_packet(Data, State) ->
    %% Check header form (first bit) and fixed bit (second bit)
    %% RFC 9000 Section 17.2/17.3: Fixed bit MUST be 1
    case Data of
        <<>> ->
            %% Empty remaining data, nothing to decode
            {error, empty_packet};
        <<0:8, _/binary>> ->
            %% First byte is 0x00 - this is padding (all zeros)
            %% Skip padding by treating as end of coalesced packets
            {error, padding_only};
        <<1:1, _:7, _/binary>> ->
            %% Long header (bit 7 = 1)
            decode_long_header_packet(Data, State);
        <<0:1, 1:1, _:6, _/binary>> ->
            %% Short header (bit 7 = 0, fixed bit 6 = 1) - valid
            decode_short_header_packet(Data, State);
        <<0:1, 0:1, _:6, _/binary>> ->
            %% Short header form but fixed bit = 0 - invalid, skip as padding
            ?LOG_WARNING(
                #{
                    what => invalid_short_header_fixed_bit,
                    first_byte => binary:first(Data)
                },
                ?QUIC_LOG_META
            ),
            {error, invalid_fixed_bit};
        _ ->
            {error, invalid_packet}
    end.

%% Decode long header packet (Initial, Handshake, etc.)
decode_long_header_packet(Data, State) ->
    %% Parse unprotected header to get DCID length
    <<FirstByte, Version:32, DCIDLen, Rest/binary>> = Data,
    <<DCID:DCIDLen/binary, SCIDLen, Rest2/binary>> = Rest,
    <<SCID:SCIDLen/binary, Rest3/binary>> = Rest2,

    TypeBits = (FirstByte bsr 4) band 2#11,

    case Version of
        0 ->
            handle_version_negotiation(DCID, Rest3, State);
        _ ->
            %% RFC 9368: a client that offered other acceptable versions
            %% adopts the one the server switched to.
            State1 = maybe_adopt_peer_version(Version, State),
            %% The type bits are version-specific (RFC 9369 §3.2)
            Type = quic_packet:bits_to_type(TypeBits, Version),
            decode_long_header_type(Type, Data, FirstByte, Version, DCID, SCID, Rest3, State1)
    end.

%% Client side of compatible version negotiation: the first long-header
%% packet from the server carrying a version we offered (but did not
%% start with) moves the connection there. Only before the ServerHello
%% is processed; later mismatches are left to the normal decode path.
maybe_adopt_peer_version(
    Version,
    #state{
        version = Current,
        cfg = #conn_cfg{
            role = client
        },
        hs = #hs{
            tls_state = ?TLS_AWAITING_SERVER_HELLO
        }
    } = State
) when Version =/= Current ->
    case lists:member(Version, (State#state.cfg)#conn_cfg.supported_versions) of
        true -> switch_version(Version, State);
        false -> State
    end;
maybe_adopt_peer_version(_Version, State) ->
    State.

decode_long_header_type(Type, Data, FirstByte, Version, DCID, SCID, Rest3, State) ->
    case Type of
        initial ->
            decode_initial_packet(Data, FirstByte, DCID, SCID, Rest3, State);
        zero_rtt ->
            decode_zero_rtt_packet(Data, FirstByte, DCID, SCID, Rest3, State);
        handshake ->
            decode_handshake_packet(Data, FirstByte, DCID, SCID, Rest3, State);
        %% Retry (RFC 9000 Section 17.2.5)
        retry ->
            handle_retry_packet(Data, Version, SCID, Rest3, State);
        _ ->
            {error, unsupported_packet_type}
    end.

%% Version Negotiation (RFC 9000 §6.2). Version 0 in a long header: the
%% server does not speak the version we sent and lists what it does speak.
%% A server never receives one, and a client only acts on it before it has
%% processed any packet from this server; later ones are attacks or stale.
handle_version_negotiation(_DCID, _Versions, #state{cfg = #conn_cfg{role = server}}) ->
    {error, unexpected_version_negotiation};
handle_version_negotiation(DCID, VersionsBin, State) ->
    case count(?C_PACKETS_RECEIVED, State) of
        0 -> handle_first_version_negotiation(DCID, VersionsBin, State);
        _ -> {error, late_version_negotiation}
    end.

handle_first_version_negotiation(DCID, _Versions, #state{cfg = #conn_cfg{scid = SCID}}) when
    DCID =/= SCID
->
    {error, version_negotiation_cid_mismatch};
handle_first_version_negotiation(_DCID, VersionsBin, #state{version = Ours}) ->
    Versions = decode_versions(VersionsBin),
    case lists:member(Ours, Versions) of
        true ->
            %% RFC 9000 §6.2: a Version Negotiation offering the version we
            %% already sent is bogus; the server would have answered it.
            {error, version_negotiation_echoes_our_version};
        false ->
            %% Nothing to negotiate down to: this build speaks version 1
            %% only. Abandon the connection with the offered list rather
            %% than retransmitting the Initial until the timeout.
            ?LOG_WARNING(
                #{what => version_negotiation, ours => Ours, offered => Versions},
                ?QUIC_LOG_META
            ),
            {error, {version_negotiation, Versions}}
    end.

%% Adopt the SCID of a peer Initial as our DCID, and record it as the peer's
%% sequence-0 CID: it counts against the active_connection_id_limit we
%% advertised (RFC 9000 §18.2). Only an Initial reaches here; a Retry SCID
%% carries no sequence number and is handled in handle_valid_retry/3.
adopt_peer_scid(PeerSCID, #state{dcid = <<>>} = State) ->
    %% Server, first client Initial.
    install_initial_peer_cid(PeerSCID, State);
adopt_peer_scid(PeerSCID, #state{dcid = DCID} = State) when
    DCID =:= (State#state.cfg)#conn_cfg.original_dcid; DCID =:= (State#state.hs)#hs.retry_scid
->
    %% Client, first server Initial, after a Retry or not.
    install_initial_peer_cid(PeerSCID, State);
adopt_peer_scid(_PeerSCID, State) ->
    State.

install_initial_peer_cid(PeerSCID, #state{cid_pool_state = Pool} = State) ->
    State#state{
        dcid = PeerSCID,
        cid_pool_state = quic_cid:set_initial_peer_cid(Pool, PeerSCID, undefined)
    }.

%% Version list of a Version Negotiation packet. A trailing partial entry
%% (a truncated or padded packet) is ignored.
decode_versions(<<Version:32, Rest/binary>>) -> [Version | decode_versions(Rest)];
decode_versions(_) -> [].

decode_initial_packet(FullPacket, FirstByte, _DCID, PeerSCID, Rest, State) ->
    <<_:8, PacketVersion:32, _/binary>> = FullPacket,
    case initial_keys_for_version(PacketVersion, State) of
        undefined ->
            {error, no_initial_keys};
        Keys ->
            decode_initial_with_keys(FullPacket, FirstByte, PeerSCID, Rest, Keys, State)
    end.

decode_initial_with_keys(FullPacket, FirstByte, PeerSCID, Rest, {ClientKeys, ServerKeys}, State) ->
    #state{cfg = #conn_cfg{role = Role}} = State,

    %% Select correct keys based on role:
    %% - Client receives from server -> use ServerKeys
    %% - Server receives from client -> use ClientKeys
    DecryptKeys =
        case Role of
            client -> ServerKeys;
            server -> ClientKeys
        end,

    %% Parse token and length. The server validates the token against
    %% its listener-wide secret (RFC 9000 §8.1) so it can mark the
    %% address as validated and skip a future retry. Validation
    %% outcomes are logged but do not yet gate connection creation —
    %% the listener-side retry emission is still a follow-up.
    {TokenLen, Rest2} = quic_varint:decode(Rest),
    <<Token:TokenLen/binary, Rest3/binary>> = Rest2,
    {PayloadLen, Rest4} = quic_varint:decode(Rest3),
    _ = maybe_validate_initial_token(Token, State),

    %% Header ends here, payload starts
    HeaderLen = byte_size(FullPacket) - byte_size(Rest4),
    <<Header:HeaderLen/binary, Payload/binary>> = FullPacket,

    State1 = adopt_peer_scid(PeerSCID, State),

    %% Ensure we have enough data
    case byte_size(Payload) >= PayloadLen of
        true ->
            <<EncryptedPayload:PayloadLen/binary, RemainingData/binary>> = Payload,
            decrypt_packet(
                initial, Header, FirstByte, EncryptedPayload, RemainingData, DecryptKeys, State1
            );
        false ->
            {error, incomplete_packet}
    end.

decode_handshake_packet(FullPacket, FirstByte, _DCID, _SCID, Rest, State) ->
    case (State#state.hs)#hs.handshake_keys of
        undefined ->
            {error, no_handshake_keys};
        {ClientKeys, ServerKeys} ->
            %% Select correct keys based on role
            DecryptKeys =
                case (State#state.cfg)#conn_cfg.role of
                    client -> ServerKeys;
                    server -> ClientKeys
                end,
            %% Parse length
            {PayloadLen, Rest2} = quic_varint:decode(Rest),
            HeaderLen = byte_size(FullPacket) - byte_size(Rest2),
            <<Header:HeaderLen/binary, Payload/binary>> = FullPacket,

            case byte_size(Payload) >= PayloadLen of
                true ->
                    <<EncryptedPayload:PayloadLen/binary, RemainingData/binary>> = Payload,
                    decrypt_packet(
                        handshake,
                        Header,
                        FirstByte,
                        EncryptedPayload,
                        RemainingData,
                        DecryptKeys,
                        State
                    );
                false ->
                    {error, incomplete_packet}
            end
    end.

%% Decode 0-RTT packet (RFC 9001 Section 5.3)
%% Server uses early keys derived from client's PSK
decode_zero_rtt_packet(_FullPacket, _FirstByte, _DCID, _SCID, _Rest, #state{
    cfg = #conn_cfg{role = client}
}) ->
    %% Clients don't receive 0-RTT packets
    {error, unexpected_zero_rtt};
decode_zero_rtt_packet(_FullPacket, _FirstByte, _DCID, _SCID, _Rest, #state{
    hs = #hs{early_keys = undefined}
}) ->
    %% No early keys - can't decrypt 0-RTT
    {error, no_early_keys};
decode_zero_rtt_packet(
    FullPacket, FirstByte, _DCID, _SCID, Rest, #state{hs = #hs{early_keys = {EarlyKeys, _}}} = State
) ->
    %% Parse length
    {PayloadLen, Rest2} = quic_varint:decode(Rest),
    HeaderLen = byte_size(FullPacket) - byte_size(Rest2),
    <<Header:HeaderLen/binary, Payload/binary>> = FullPacket,

    case byte_size(Payload) >= PayloadLen of
        true ->
            <<EncryptedPayload:PayloadLen/binary, RemainingData/binary>> = Payload,
            decrypt_packet(
                zero_rtt, Header, FirstByte, EncryptedPayload, RemainingData, EarlyKeys, State
            );
        false ->
            {error, incomplete_packet}
    end.

%% Handle Retry packet (RFC 9000 Section 8.1, RFC 9001 Section 5.8)
%% A client receives a Retry when the server requests address validation.
handle_retry_packet(
    _FullPacket,
    _Version,
    _ServerSCID,
    _Rest,
    #state{cfg = #conn_cfg{role = server}}
) ->
    %% Servers don't receive Retry packets
    {error, unexpected_retry};
handle_retry_packet(
    _FullPacket,
    _Version,
    _ServerSCID,
    _Rest,
    #state{hs = #hs{retry_received = true}}
) ->
    %% RFC 9000 Section 17.2.5.2: MUST discard subsequent Retry packets
    {error, duplicate_retry};
handle_retry_packet(
    FullPacket,
    Version,
    ServerSCID,
    Rest,
    #state{cfg = #conn_cfg{role = client, original_dcid = OriginalDCID}} = State
) ->
    %% Rest contains: Retry Token + Retry Integrity Tag (16 bytes at end)
    %% There's no length field, the entire remaining data is the token + tag
    RetryTokenAndTag = Rest,

    %% Verify the integrity tag (RFC 9001 Section 5.8)
    case quic_crypto:verify_retry_integrity_tag(OriginalDCID, FullPacket, Version) of
        true ->
            %% Extract the retry token (everything except last 16 bytes)
            TagLen = 16,
            case byte_size(RetryTokenAndTag) > TagLen of
                true ->
                    TokenLen = byte_size(RetryTokenAndTag) - TagLen,
                    <<RetryToken:TokenLen/binary, _IntegrityTag:TagLen/binary>> = RetryTokenAndTag,
                    handle_valid_retry(RetryToken, ServerSCID, State);
                false ->
                    {error, invalid_retry_token}
            end;
        false ->
            {error, retry_integrity_check_failed}
    end.

%% Process a valid Retry packet
handle_valid_retry(RetryToken, ServerSCID, State) ->
    %% RFC 9000 Section 8.1.2: Client MUST use the new SCID from the Retry
    %% as the DCID for subsequent packets
    %% Store retry_scid for later validation of transport params (RFC 9000 Section 7.3)
    State1 = State#state{
        dcid = ServerSCID,
        hs = (State#state.hs)#hs{
            retry_token = RetryToken,
            retry_received = true,
            retry_scid = ServerSCID
        }
    },

    %% Regenerate initial keys with the NEW DCID (ServerSCID) and current version
    {ClientKeys, ServerKeys} = derive_initial_keys(ServerSCID, State1#state.version),
    State2 = State1#state{hs = (State1#state.hs)#hs{initial_keys = {ClientKeys, ServerKeys}}},

    %% Reset crypto state for a fresh Initial
    State3 = State2#state{
        hs = (State2#state.hs)#hs{
            crypto_offset = #{initial => 0, handshake => 0, app => 0},
            tls_transcript = <<>>
        }
    },

    %% Reset packet number space for Initial
    State4 = reset_initial_pn_space(State3),

    %% Resend the ClientHello using send_client_hello
    %% (the retry_token field is now set, so send_initial_packet will use it)
    State5 = send_client_hello(State4),

    %% Return state with retry info, no frames to process
    {ok, retry_handled, [], <<>>, State5}.

%% Clear the Initial packet number space after a Retry. RFC 9000 §17.2.5.3:
%% the packet number keeps counting up, so the retried Initial is a new
%% packet to the server rather than a replay of the one it answered with the
%% Retry. Everything else in the space describes packets protected by the
%% keys we just replaced.
reset_initial_pn_space(#state{hs = #hs{pn_initial = #pn_space{next_pn = NextPN}}} = State) ->
    PNSpace = #pn_space{
        next_pn = NextPN,
        largest_recv = undefined,
        recv_time = undefined,
        ack_ranges = [],
        ack_eliciting_in_flight = 0
    },
    %% RFC 9002 Section 6.3: a Retry resets recovery and congestion state,
    %% including the timers. RFC 9000 Section 17.2.5.3: the data that
    %% carried is resent, under packet numbers that keep climbing. The
    %% Initial flight is rebuilt from the retained TLS state with the
    %% Retry token in it, so only 0-RTT is replayed from here.
    cancel_timer(State#state.pto_timer),
    {NewLossState, Discarded} = quic_loss:reset_for_retry(
        State#state.loss_state, erlang:monotonic_time(millisecond)
    ),
    State1 = State#state{
        loss_state = NewLossState,
        cc_state = quic_cc:reset_for_retry(State#state.cc_state),
        pto_timer = undefined,
        pto_scheduled_at = undefined,
        pto_armed_at = undefined,
        hs = (State#state.hs)#hs{
            pn_initial = PNSpace
        }
    },
    requeue_early_data(maps:get(app, Discarded, []), State1).

%% Replay 0-RTT a Retry discarded. It goes back through the
%% retransmission path, not the fresh-send path: this data already
%% consumed its flow-control credit when it first went out.
requeue_early_data([], State) ->
    State;
requeue_early_data(Packets, State) ->
    lists:foldl(
        fun(#sent_packet{frames = Frames}, Acc) ->
            send_retransmit_frames_cc(quic_loss:retransmittable_frames(Frames), Acc)
        end,
        State,
        Packets
    ).

%% Check if a packet is a stateless reset (RFC 9000 Section 10.3)
check_stateless_reset(Data, _State) when byte_size(Data) < 21 ->
    %% Packet too small to be a stateless reset
    {error, decryption_failed};
check_stateless_reset(Data, #state{cid_pool_state = Pool} = _State) ->
    %% Extract the last 16 bytes as potential reset token
    DataSize = byte_size(Data),
    TokenOffset = DataSize - 16,
    <<_:TokenOffset/binary, PotentialToken:16/binary>> = Data,

    %% Check against known reset tokens from peer's CIDs
    case quic_cid:find_reset_token_match(Pool, PotentialToken) of
        {ok, _CID} ->
            %% This is a stateless reset - signal connection termination
            {error, stateless_reset};
        not_found ->
            %% Not a stateless reset, just decryption failure
            {error, decryption_failed}
    end.

decode_short_header_packet(Data, State) ->
    case State#state.app_keys of
        undefined ->
            ?LOG_WARNING(#{what => no_app_keys_short_header}, ?QUIC_LOG_META),
            %% No app keys yet - check if this might be a stateless reset
            check_stateless_reset(Data, State);
        {ClientKeys, ServerKeys} ->
            %% Select correct keys based on role
            DecryptKeys =
                case (State#state.cfg)#conn_cfg.role of
                    client -> ServerKeys;
                    server -> ClientKeys
                end,
            %% Short header: first byte + DCID (our SCID that peer uses as their DCID)
            %% Short header packets don't have length field, so they consume all remaining data
            DCIDLen = byte_size((State#state.cfg)#conn_cfg.scid),
            <<FirstByte, DCID:DCIDLen/binary, EncryptedPayload/binary>> = Data,
            Header = <<FirstByte, DCID/binary>>,
            %% No remaining data after short header packet
            case decrypt_app_packet(Header, EncryptedPayload, DecryptKeys, State) of
                {error, decryption_failed} ->
                    ?LOG_WARNING(#{what => short_header_decryption_failed}, ?QUIC_LOG_META),
                    %% Decryption failed - check if this is a stateless reset
                    check_stateless_reset(Data, State);
                {ok, _Type, _Frames, _Remaining, _NewState} = Result ->
                    Result;
                Other ->
                    Other
            end
    end.

%% Decrypt an application (1-RTT) packet with key phase handling
%% Uses 2-stage API: unprotect header to get key_phase, then decrypt with selected keys
decrypt_app_packet(Header, EncryptedPayload, CurrentKeys, State) ->
    %% Fast path: fused unprotect + PN reconstruction + AEAD open in
    %% one NIF call, valid only when no key update is in flight (the
    %% NIF bails to the generic path when the packet's phase bit
    %% differs from the current phase, and the generic path owns the
    %% RFC 9001 §6 phase-transition bookkeeping).
    Fused =
        case fused_decrypt_keys(CurrentKeys, State) of
            {ok, #crypto_keys{key = FKey, iv = FIV, hp = FHP, cipher = FCipher}} ->
                quic_aead_ctx:open_packet(
                    FCipher,
                    FKey,
                    FIV,
                    FHP,
                    get_largest_recv(app, State),
                    get_current_key_phase(State),
                    Header,
                    EncryptedPayload
                );
            no ->
                fallback
        end,
    case Fused of
        {ok, PN0, FirstByte0, Plaintext0} ->
            Now0 = erlang:monotonic_time(millisecond),
            StateF = record_app_recv(FirstByte0, PN0, State, Now0),
            case decode_and_process_streaming(app, Plaintext0, StateF) of
                {ok, NewState0, Frames0} ->
                    {ok, app, Frames0, <<>>, NewState0, processed};
                {error, Reason0} ->
                    {error, Reason0}
            end;
        error ->
            {error, decryption_failed};
        fallback ->
            decrypt_app_packet_slow(Header, EncryptedPayload, CurrentKeys, State)
    end.

%% The peer-direction keys for the fused path: only when no key update
%% is in flight, so a same-phase packet cannot carry phase-transition
%% side effects (select_decrypt_keys/2 handles those on the slow path).
fused_decrypt_keys(CurrentKeys, #state{key_state = undefined}) ->
    {ok, CurrentKeys};
fused_decrypt_keys(_CurrentKeys, #state{
    key_state = #key_update_state{update_state = idle, current_keys = {CK, SK}},
    cfg = #conn_cfg{
        role = Role
    }
}) ->
    case Role of
        server -> {ok, CK};
        client -> {ok, SK}
    end;
fused_decrypt_keys(_CurrentKeys, _State) ->
    no.

%% The two-stage path: unprotect the header to learn the key phase,
%% select keys, then decrypt.
decrypt_app_packet_slow(Header, EncryptedPayload, CurrentKeys, State) ->
    %% The cipher must come from the negotiated keys: inferring it from
    %% the HP key length mistakes ChaCha20-Poly1305 for AES-256-GCM and
    %% drops every received 1-RTT packet on such connections.
    #crypto_keys{hp = HP, cipher = HpCipher} = CurrentKeys,
    PNOffset = byte_size(Header),

    %% Stage 1: Unprotect header to get key_phase and PN info
    case quic_aead:unprotect_short_header(HpCipher, HP, Header, EncryptedPayload, PNOffset) of
        {error, Reason} ->
            {error, Reason};
        {ok, KeyPhase, PNLen, TruncatedPN, UnprotectedHeader} ->
            %% Select keys based on key_phase
            {DecryptKeys, State1} = select_decrypt_keys(KeyPhase, State),
            PeerDecryptKeys =
                case (State1#state.cfg)#conn_cfg.role of
                    % ClientKeys
                    server -> element(1, DecryptKeys);
                    % ServerKeys
                    client -> element(2, DecryptKeys)
                end,

            %% Stage 2: Decrypt with selected keys
            #crypto_keys{key = Key, iv = IV, cipher = Cipher} = PeerDecryptKeys,
            LargestRecv = get_largest_recv(app, State1),
            case
                quic_aead:decrypt_short_payload(
                    Cipher,
                    Key,
                    IV,
                    UnprotectedHeader,
                    PNLen,
                    TruncatedPN,
                    EncryptedPayload,
                    LargestRecv
                )
            of
                {ok, PN, Plaintext} ->
                    <<UnprotectedFirstByte, _/binary>> = UnprotectedHeader,
                    %% Single monotonic_time sample shared by
                    %% recv_time and last_activity to save one BIF
                    %% call per received packet on the hot path.
                    Now = erlang:monotonic_time(millisecond),
                    State3 = record_app_recv(UnprotectedFirstByte, PN, State1, Now),
                    %% Use streaming decode for efficiency
                    case decode_and_process_streaming(app, Plaintext, State3) of
                        {ok, NewState, Frames} ->
                            {ok, app, Frames, <<>>, NewState, processed};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, decryption_failed} ->
                    {error, decryption_failed}
            end
    end.

%% Decrypt a long header packet (Initial/Handshake)
%% RemainingData is the data after this packet (for coalesced packets)
decrypt_packet(Level, Header, _FirstByte, EncryptedPayload, RemainingData, Keys, State) ->
    #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = Keys,
    LargestRecv = get_largest_recv(Level, State),

    %% Unprotect and decrypt in single call
    case
        quic_aead:unprotect_long_packet(Cipher, Key, IV, HP, Header, EncryptedPayload, LargestRecv)
    of
        {error, Reason} ->
            {error, Reason};
        {ok, PN, _UnprotectedHeader, Plaintext} ->
            %% Track received packet number for ACK generation.
            %% Single monotonic_time sample shared by recv_time and
            %% last_activity.
            Now = erlang:monotonic_time(millisecond),
            State1 = record_received_pn(Level, PN, State, Now),
            State2 = update_last_activity(State1, Now),
            %% Use streaming decode for efficiency
            case decode_and_process_streaming(Level, Plaintext, State2) of
                {ok, NewState, Frames} ->
                    {ok, Level, Frames, RemainingData, NewState, processed};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% Process decoded frames without re-enabling socket (for coalesced packets)
process_frames_noreenbl(_Level, [], State) ->
    State;
process_frames_noreenbl(Level, [Frame | Rest], State) ->
    NewState = process_frame_track_probing(Level, Frame, State),
    process_frames_noreenbl(Level, Rest, NewState).

%% Streaming decode and process - decodes and processes frames without building intermediate list
%% Returns {ok, State, FrameList} where FrameList is accumulated for qlog/ACK tracking
%% This is more efficient than decode_all + process_frames for typical packets
decode_and_process_streaming(Level, Plaintext, State) ->
    decode_and_process_streaming(Level, Plaintext, State, []).

decode_and_process_streaming(Level, <<>>, State, []) ->
    %% RFC 9000 Section 12.4: a packet with zero frames is a PROTOCOL_VIOLATION.
    ?LOG_WARNING(
        #{what => packet_with_no_frames, level => Level}, ?QUIC_LOG_META
    ),
    NewState = close_with_error(
        level_for_close(Level),
        transport,
        ?QUIC_PROTOCOL_VIOLATION,
        0,
        <<"packet contained no frames">>,
        State
    ),
    {ok, NewState, []};
decode_and_process_streaming(_Level, <<>>, State, Acc) ->
    {ok, State, lists:reverse(Acc)};
decode_and_process_streaming(Level, Data, State, Acc) ->
    case quic_frame:decode(Data) of
        {error, {unknown_frame_type, Type}} ->
            %% RFC 9000 Section 12.4: unknown frame type is FRAME_ENCODING_ERROR.
            ?LOG_WARNING(
                #{what => unknown_frame_type, type => Type, level => Level}, ?QUIC_LOG_META
            ),
            ReasonBin = list_to_binary(io_lib:format("unknown frame type 0x~.16b", [Type])),
            NewState = close_with_error(
                level_for_close(Level),
                transport,
                ?QUIC_FRAME_ENCODING_ERROR,
                Type,
                ReasonBin,
                State
            ),
            {ok, NewState, lists:reverse(Acc)};
        {error, Reason} ->
            %% RFC 9000 §12.4: a malformed/truncated frame from an
            %% (authenticated) peer is a FRAME_ENCODING_ERROR, not a drop.
            ?LOG_WARNING(
                #{what => frame_decode_error, reason => Reason, level => Level}, ?QUIC_LOG_META
            ),
            NewState = close_with_error(
                level_for_close(Level),
                transport,
                ?QUIC_FRAME_ENCODING_ERROR,
                0,
                <<"frame encoding error">>,
                State
            ),
            {ok, NewState, lists:reverse(Acc)};
        {Frame, Rest} ->
            NewState = process_frame_track_probing(Level, Frame, State),
            decode_and_process_streaming(Level, Rest, NewState, [Frame | Acc])
    end.

%% Map a packet-processing level atom to the level atom expected by
%% close_with_error/6. Initial and Handshake packets emit CLOSE at their own
%% level; 1-RTT (app) packets emit at app level.
level_for_close(initial) -> initial;
level_for_close(handshake) -> handshake;
level_for_close(app) -> app;
level_for_close(_) -> app.

%% @doc Process a frame and track if it's a non-probing frame.
%% RFC 9000 Section 9.1: Only packets containing non-probing frames trigger migration.
-spec process_frame_track_probing(atom(), term(), #state{}) -> #state{}.
process_frame_track_probing(Level, Frame, State) ->
    %% Update has_non_probing_frame flag if this is a non-probing frame
    State1 =
        case State#state.has_non_probing_frame of
            true ->
                %% Already set, skip check
                State;
            false ->
                case is_probing_frame(Frame) of
                    true -> State;
                    false -> State#state{has_non_probing_frame = true}
                end
        end,
    %% 0-RTT shares the application packet number space and frame
    %% semantics with 1-RTT (RFC 9001 §5.7). Dispatch its frames at the
    %% app level so STREAM and flow-control frames are handled rather than
    %% dropped by the catch-all clause.
    process_frame(frame_dispatch_level(Level), Frame, State1).

frame_dispatch_level(zero_rtt) -> app;
frame_dispatch_level(Level) -> Level.

%% Process individual frames
process_frame(_Level, padding, State) ->
    State;
process_frame(_Level, ping, State) ->
    %% Should trigger ACK
    State;
process_frame(Level, {crypto, Offset, Data}, State) ->
    buffer_crypto_data(Level, Offset, Data, State);
process_frame(Level, {ack, Ranges, AckDelay, ECN}, State) ->
    %% Process ACK - update loss detection and congestion control
    #state{loss_state = LossState, cc_state = CCState} = State,

    %% Convert Ranges list to the format expected by quic_loss
    %% Ranges is a list of {Start, End} tuples from largest to smallest
    case Ranges of
        [] ->
            State;
        [{LargestAcked, _} | _] ->
            %% Convert ranges to ACK frame format for quic_loss
            %% quic_loss expects {ack, LargestAcked, AckDelay, FirstRange, AckRanges}
            {FirstRange, RestRanges} = quic_ack:ranges_to_ack_format(Ranges),
            AckFrame = {ack, LargestAcked, AckDelay, FirstRange, RestRanges},

            Now = erlang:monotonic_time(millisecond),
            case quic_loss:on_ack_received(Level, LossState, AckFrame, Now) of
                {error, ack_range_too_large} ->
                    %% RFC 9000: Invalid ACK range is a protocol violation
                    ?LOG_ERROR(#{what => invalid_ack_range}, ?QUIC_LOG_META),
                    State;
                {NewLossState, AckedPackets, LostPackets, AckMeta} ->
                    %% Use pre-computed metadata from quic_loss (avoids redundant scanning)
                    AckedBytes = maps:get(acked_bytes, AckMeta, 0),
                    LargestAckedSentTime = maps:get(largest_ae_time, AckMeta, Now),
                    HasAckEliciting = maps:get(has_ack_eliciting, AckMeta, false),
                    LostBytes = maps:get(lost_bytes, AckMeta, 0),
                    LargestLostSentTime = maps:get(largest_lost_sent_time, AckMeta, undefined),

                    %% Only update CC ACK processing if there are ack-eliciting packets
                    %% When only non-ack-eliciting packets are ACKed, skip on_packets_acked
                    %% to prevent false recovery exit (LargestAckedSentTime=Now would always
                    %% satisfy > RecoveryStart after min_duration). Loss handling is done
                    %% separately by on_packets_lost and on_congestion_event.
                    CCState1 =
                        case HasAckEliciting of
                            false ->
                                %% No ack-eliciting acks - skip CC ACK update entirely
                                CCState;
                            true ->
                                quic_cc:on_packets_acked(CCState, AckedBytes, LargestAckedSentTime)
                        end,
                    CCState5 = cc_after_loss(
                        CCState1, LostBytes, LargestLostSentTime, ECN, LostPackets, NewLossState
                    ),

                    %% Update pacing rate based on new RTT estimate (RFC 9002 Section 7.7)
                    %% Only update pacing when we have a real RTT sample to avoid
                    %% using the default 100ms RTT which causes excessive pacing delays
                    CCState6 =
                        case quic_rtt:has_sample(quic_loss:rtt(NewLossState)) of
                            true ->
                                SmoothedRTT = quic_rtt:smoothed(quic_loss:rtt(NewLossState)),
                                quic_cc:update_pacing_rate(CCState5, SmoothedRTT);
                            false ->
                                CCState5
                        end,

                    State1 = State#state{
                        loss_state = NewLossState,
                        cc_state = CCState6,
                        pto_dirty = true
                    },

                    %% Emit qlog packets_acked event
                    AckedPNs = [P#sent_packet.pn || P <- AckedPackets],
                    RTTSample =
                        case AckedPackets of
                            [] -> undefined;
                            _ -> Now - LargestAckedSentTime
                        end,
                    ?QLOG_EMIT_PACKETS_ACKED((State1#state.cfg)#conn_cfg.qlog_ctx, AckedPNs, #{
                        rtt_sample => RTTSample
                    }),

                    %% Emit qlog packet_lost events
                    lists:foreach(
                        fun(#sent_packet{pn = LostPN}) ->
                            ?QLOG_EMIT_PACKET_LOST((State1#state.cfg)#conn_cfg.qlog_ctx, #{
                                packet_number => LostPN,
                                reason => timeout
                            })
                        end,
                        LostPackets
                    ),

                    case Level of
                        app ->
                            app_ack_tail(AckedPackets, LostPackets, State1);
                        _ ->
                            handshake_ack_tail(Level, LostPackets, State1)
                    end
                %% close inner case (on_ack_received)
            end
        %% close outer case (Ranges)
    end;
%% HANDSHAKE_DONE: Server confirms handshake complete
%% RFC 9000 Section 19.20: Only server can send, only in 1-RTT (app level)
process_frame(app, handshake_done, #state{cfg = #conn_cfg{role = client}} = State0) ->
    %% Handshake confirmed (RFC 9001 §4.1.2): the retained Finished flight
    %% is done.
    confirm_handshake(clear_hs_flight(State0));
process_frame(app, handshake_done, #state{cfg = #conn_cfg{role = server}} = State) ->
    %% RFC 9000 §19.20: clients MUST NOT send HANDSHAKE_DONE.
    ?LOG_WARNING(
        #{what => invalid_handshake_done_frame, reason => server_received}, ?QUIC_LOG_META
    ),
    close_with_error(
        app,
        transport,
        ?QUIC_PROTOCOL_VIOLATION,
        0,
        <<"HANDSHAKE_DONE received by server">>,
        State
    );
process_frame(Level, handshake_done, State) when Level =/= app ->
    %% RFC 9000 §19.20: HANDSHAKE_DONE MUST be sent in a 1-RTT packet.
    ?LOG_WARNING(#{what => invalid_handshake_done_level, level => Level}, ?QUIC_LOG_META),
    close_with_error(
        level_for_close(Level),
        transport,
        ?QUIC_PROTOCOL_VIOLATION,
        0,
        <<"HANDSHAKE_DONE at wrong encryption level">>,
        State
    );
process_frame(app, {stream, StreamId, Offset, Data, Fin}, State) ->
    process_stream_data(StreamId, Offset, Data, Fin, State);
%% MAX_DATA: Peer is increasing connection-level flow control limit
%% RFC 9000 Section 19.9: MAX_DATA is only allowed in 1-RTT packets
process_frame(app, {max_data, MaxData}, #state{max_data_remote = Current} = State) ->
    case MaxData > Current of
        true ->
            %% Limit increased - try to drain queued data
            State1 = State#state{max_data_remote = MaxData},
            State2 = process_send_queue(State1),
            %% Event-driven flush: flush batch and timers after flow control opens
            flush_event(State2, event);
        false ->
            %% Monotonic: ignore if not increasing (per RFC 9000)
            State
    end;
process_frame(Level, {max_data, _}, State) when Level =/= app ->
    %% Protocol violation: MAX_DATA only allowed in 1-RTT packets
    ?LOG_WARNING(#{what => invalid_max_data_level, level => Level}, ?QUIC_LOG_META),
    State#state{close_reason = {protocol_violation, max_data_wrong_level}};
%% MAX_STREAM_DATA: Peer is increasing stream-level flow control limit
%% RFC 9000 Section 19.10: MAX_STREAM_DATA is only allowed in 1-RTT packets
process_frame(app, {max_stream_data, StreamId, MaxData}, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream_state{send_max_data = Current} = Stream} ->
            ?LOG_DEBUG(
                #{
                    what => received_max_stream_data,
                    stream_id => StreamId,
                    new_limit => MaxData,
                    current_limit => Current,
                    will_update => MaxData > Current
                },
                ?QUIC_LOG_META
            ),
            case MaxData > Current of
                true ->
                    NewStream = Stream#stream_state{send_max_data = MaxData},
                    State1 = State#state{streams = maps:put(StreamId, NewStream, Streams)},
                    %% Limit increased - try to drain queued data
                    State2 = process_send_queue(State1),
                    %% Event-driven flush: flush batch and timers after stream flow control opens
                    flush_event(State2, event);
                false ->
                    %% Monotonic: ignore if not increasing
                    State
            end;
        error ->
            ?LOG_DEBUG(
                #{
                    what => received_max_stream_data_unknown_stream,
                    stream_id => StreamId,
                    new_limit => MaxData
                },
                ?QUIC_LOG_META
            ),
            State
    end;
process_frame(Level, {max_stream_data, _, _}, State) when Level =/= app ->
    %% Protocol violation: MAX_STREAM_DATA only allowed in 1-RTT packets
    ?LOG_WARNING(#{what => invalid_max_stream_data_level, level => Level}, ?QUIC_LOG_META),
    State#state{close_reason = {protocol_violation, max_stream_data_wrong_level}};
%% MAX_STREAMS: Peer is increasing the number of streams we can open
%% RFC 9000 Section 19.11: MAX_STREAMS is only allowed in 1-RTT packets
process_frame(app, {max_streams, bidi, Max}, #state{max_streams_bidi_remote = Current} = State) ->
    case Max > Current of
        true ->
            State#state{max_streams_bidi_remote = Max};
        false ->
            State
    end;
process_frame(app, {max_streams, uni, Max}, #state{max_streams_uni_remote = Current} = State) ->
    case Max > Current of
        true ->
            State#state{max_streams_uni_remote = Max};
        false ->
            State
    end;
process_frame(Level, {max_streams, _, _}, State) when Level =/= app ->
    %% Protocol violation: MAX_STREAMS only allowed in 1-RTT packets
    ?LOG_WARNING(#{what => invalid_max_streams_level, level => Level}, ?QUIC_LOG_META),
    State#state{close_reason = {protocol_violation, max_streams_wrong_level}};
%% PATH_CHALLENGE: Peer is probing the path, respond with PATH_RESPONSE
%% RFC 9000 Section 8.2.2: PATH_RESPONSE MUST be sent on the path where the
%% PATH_CHALLENGE was received (to the source address of that packet).
process_frame(app, {path_challenge, ChallengeData}, State) ->
    %% Send PATH_RESPONSE to the address that sent the PATH_CHALLENGE
    SourceAddr = State#state.current_packet_source,
    case SourceAddr of
        {_IP, _Port} ->
            %% Send padded PATH_RESPONSE to the source address
            send_path_response_to_addr(SourceAddr, ChallengeData, State);
        undefined ->
            %% Fallback: no source tracked (shouldn't happen in normal flow)
            %% Send via normal send_frame to current remote_addr
            send_frame({path_response, ChallengeData}, State)
    end;
%% PATH_RESPONSE: Response to our PATH_CHALLENGE
process_frame(app, {path_response, ResponseData}, State) ->
    handle_path_response(ResponseData, State);
%% NEW_CONNECTION_ID: Peer is providing a new CID for us to use
process_frame(app, {new_connection_id, SeqNum, RetirePrior, CID, ResetToken}, State) ->
    handle_new_connection_id(SeqNum, RetirePrior, CID, ResetToken, State);
%% RETIRE_CONNECTION_ID: Peer is retiring one of our CIDs
process_frame(app, {retire_connection_id, SeqNum}, State) ->
    handle_retire_connection_id(SeqNum, State);
process_frame(_Level, {connection_close, Type, Code, FrameType, ReasonPhrase}, State) ->
    %% Preserve peer error details for owner notification
    CloseReason =
        case Type of
            application ->
                {peer_closed, application, Code, ReasonPhrase};
            transport ->
                {peer_closed, transport, Code, FrameType, ReasonPhrase}
        end,
    State#state{close_reason = CloseReason};
%% RESET_STREAM: Peer is aborting a stream they initiated or we initiated for sending
%% RFC 9000 Section 19.4
process_frame(
    app,
    {reset_stream, StreamId, ErrorCode, FinalSize},
    #state{owner = Owner, streams = Streams} = State
) ->
    %% RFC 9000 Section 4.5: Validate final size against any previously known value
    case maps:find(StreamId, Streams) of
        {ok, #stream_state{final_size = ExistingFinalSize}} when
            ExistingFinalSize =/= undefined andalso ExistingFinalSize =/= FinalSize
        ->
            %% FINAL_SIZE_ERROR: RESET_STREAM has different final size than previously known
            ?LOG_WARNING(
                #{
                    what => final_size_error,
                    stream_id => StreamId,
                    existing => ExistingFinalSize,
                    reset_stream => FinalSize
                },
                ?QUIC_LOG_META
            ),
            CloseFrame =
                {connection_close, transport, ?QUIC_FINAL_SIZE_ERROR, 0,
                    <<"RESET_STREAM final size mismatch">>},
            send_frame(CloseFrame, State#state{close_reason = final_size_error});
        {ok, Stream} ->
            %% Mark stream as reset, store final size for flow control accounting.
            %% Incoming RESET_STREAM closes our receive side.
            NewStreams = maps:put(
                StreamId,
                Stream#stream_state{
                    state = reset,
                    final_size = FinalSize,
                    recv_done = true
                },
                Streams
            ),
            %% Data delivered earlier in this receive pass reaches the
            %% owner before the reset notification.
            StateFl = flush_pending_delivery(State),
            Owner ! {quic, self(), {stream_reset, StreamId, ErrorCode}},
            maybe_reclaim_stream(StreamId, StateFl#state{streams = NewStreams});
        error ->
            case is_reclaimed_frame(StreamId, State) of
                true ->
                    %% Late RESET_STREAM for an already-reclaimed stream; ignore.
                    State;
                false ->
                    case exceeds_stream_limit(StreamId, State) of
                        true ->
                            stream_limit_close(State);
                        false ->
                            %% Unknown stream - notify owner and create minimal state to track reset
                            Owner ! {quic, self(), {stream_opened, StreamId}},
                            NewStreams = maps:put(
                                StreamId,
                                #stream_state{
                                    id = StreamId,
                                    state = reset,
                                    final_size = FinalSize
                                },
                                Streams
                            ),
                            StateFl = flush_pending_delivery(State),
                            Owner ! {quic, self(), {stream_reset, StreamId, ErrorCode}},
                            StateFl#state{streams = NewStreams}
                    end
            end
    end;
%% RESET_STREAM_AT: Peer is aborting a stream with reliable delivery guarantee
%% draft-ietf-quic-reliable-stream-reset-07
process_frame(
    app,
    {reset_stream_at, StreamId, ErrorCode, FinalSize, ReliableSize},
    #state{owner = Owner, streams = Streams} = State
) ->
    %% Validate: ReliableSize <= FinalSize (FRAME_ENCODING_ERROR per spec)
    case ReliableSize > FinalSize of
        true ->
            CloseFrame =
                {connection_close, transport, ?QUIC_FRAME_ENCODING_ERROR, 0,
                    <<"RESET_STREAM_AT reliable_size > final_size">>},
            send_frame(CloseFrame, State#state{close_reason = frame_encoding_error});
        false ->
            case maps:find(StreamId, Streams) of
                {ok, #stream_state{final_size = ExistingFinalSize}} when
                    ExistingFinalSize =/= undefined andalso ExistingFinalSize =/= FinalSize
                ->
                    %% STREAM_STATE_ERROR: FinalSize changed
                    CloseFrame =
                        {connection_close, transport, ?QUIC_STREAM_STATE_ERROR, 0,
                            <<"RESET_STREAM_AT final_size changed">>},
                    send_frame(CloseFrame, State#state{close_reason = stream_state_error});
                {ok, #stream_state{recv_reset_error = ExistingError}} when
                    ExistingError =/= undefined andalso ExistingError =/= ErrorCode
                ->
                    %% STREAM_STATE_ERROR: ErrorCode changed
                    CloseFrame =
                        {connection_close, transport, ?QUIC_STREAM_STATE_ERROR, 0,
                            <<"RESET_STREAM_AT error_code changed">>},
                    send_frame(CloseFrame, State#state{close_reason = stream_state_error});
                {ok, #stream_state{recv_reset_at = ExistingReliable}} when
                    ExistingReliable =/= undefined andalso ReliableSize > ExistingReliable
                ->
                    %% Spec: Ignore if ReliableSize increased (not an error, just ignore)
                    State;
                {ok, Stream} ->
                    %% Valid RESET_STREAM_AT - update stream state. The recv side
                    %% is terminal once the reliable bytes are already delivered.
                    Delivered = Stream#stream_state.recv_offset >= ReliableSize,
                    NewStreams = maps:put(
                        StreamId,
                        Stream#stream_state{
                            state = reset,
                            final_size = FinalSize,
                            recv_reset_at = ReliableSize,
                            recv_reset_error = ErrorCode,
                            recv_done = Delivered orelse Stream#stream_state.recv_done
                        },
                        Streams
                    ),
                    %% Notify owner - same message as RESET_STREAM
                    StateFl = flush_pending_delivery(State),
                    Owner ! {quic, self(), {stream_reset, StreamId, ErrorCode}},
                    maybe_reclaim_stream(StreamId, StateFl#state{streams = NewStreams});
                error ->
                    case is_reclaimed_frame(StreamId, State) of
                        true ->
                            %% Late RESET_STREAM_AT for an already-reclaimed stream; ignore.
                            State;
                        false ->
                            case exceeds_stream_limit(StreamId, State) of
                                true ->
                                    stream_limit_close(State);
                                false ->
                                    %% Unknown stream - notify owner and create minimal state.
                                    %% A fresh stream has recv_offset 0, so the recv side is
                                    %% terminal immediately only when ReliableSize is 0.
                                    Owner ! {quic, self(), {stream_opened, StreamId}},
                                    NewStreams = maps:put(
                                        StreamId,
                                        #stream_state{
                                            id = StreamId,
                                            state = reset,
                                            final_size = FinalSize,
                                            recv_reset_at = ReliableSize,
                                            recv_reset_error = ErrorCode,
                                            recv_done = (ReliableSize =:= 0)
                                        },
                                        Streams
                                    ),
                                    StateFl = flush_pending_delivery(State),
                                    Owner ! {quic, self(), {stream_reset, StreamId, ErrorCode}},
                                    maybe_reclaim_stream(
                                        StreamId, StateFl#state{streams = NewStreams}
                                    )
                            end
                    end
            end
    end;
%% STOP_SENDING: Peer wants us to stop sending on a stream
%% RFC 9000 Section 19.5
process_frame(
    app,
    {stop_sending, StreamId, ErrorCode},
    #state{owner = Owner, streams = Streams} = State
) ->
    case is_reclaimed_frame(StreamId, State) of
        true ->
            %% Late STOP_SENDING for an already-reclaimed stream; ignore.
            State;
        false ->
            case
                (not maps:is_key(StreamId, Streams)) andalso exceeds_stream_limit(StreamId, State)
            of
                true ->
                    stream_limit_close(State);
                false ->
                    %% Clear any queued data for this stream and mark as stopped
                    NewStreams =
                        case maps:find(StreamId, Streams) of
                            {ok, Stream} ->
                                maps:put(
                                    StreamId,
                                    Stream#stream_state{
                                        state = stopped,
                                        % Clear queued data
                                        send_buffer = []
                                    },
                                    Streams
                                );
                            error ->
                                %% Unknown stream - notify owner and create minimal state
                                Owner ! {quic, self(), {stream_opened, StreamId}},
                                maps:put(
                                    StreamId,
                                    #stream_state{
                                        id = StreamId,
                                        state = stopped
                                    },
                                    Streams
                                )
                        end,
                    %% Notify owner - they should stop sending and may send RESET_STREAM
                    Owner ! {quic, self(), {stop_sending, StreamId, ErrorCode}},
                    %% Also remove from send queue and adjust byte / entry count
                    {NewSendQueue, RemovedBytes, RemovedCount} =
                        remove_stream_from_queue(StreamId, State#state.send_queue),
                    NewQueueBytes = max(0, State#state.send_queue_bytes - RemovedBytes),
                    NewQueueCount = max(0, State#state.send_queue_count - RemovedCount),
                    answer_stop_sending(StreamId, ErrorCode, Streams, State#state{
                        streams = NewStreams,
                        send_queue = NewSendQueue,
                        send_queue_bytes = NewQueueBytes,
                        send_queue_count = NewQueueCount
                    })
            end
    end;
%% STREAM_DATA_BLOCKED: Peer is blocked by stream-level flow control
%% RFC 9000 Section 19.13: Receipt opens the stream (Section 3.2)
process_frame(
    app,
    {stream_data_blocked, StreamId, _Limit},
    #state{owner = Owner, streams = Streams} = State
) ->
    case maps:is_key(StreamId, Streams) of
        true ->
            %% Stream already exists, nothing to do (informational frame)
            State;
        false ->
            case is_reclaimed_frame(StreamId, State) of
                true ->
                    %% Late STREAM_DATA_BLOCKED for an already-reclaimed stream; ignore.
                    State;
                false ->
                    case exceeds_stream_limit(StreamId, State) of
                        true ->
                            stream_limit_close(State);
                        false ->
                            %% New stream from peer - notify owner
                            Owner ! {quic, self(), {stream_opened, StreamId}},
                            %% Create minimal stream state with limits for the stream type
                            Kind = peer_stream_kind(StreamId),
                            InitSendMaxData = get_peer_stream_limit(Kind, State),
                            InitRecvMaxData = get_local_recv_limit(Kind, State),
                            NewStream = #stream_state{
                                id = StreamId,
                                state = open,
                                send_max_data = InitSendMaxData,
                                recv_max_data = InitRecvMaxData
                            },
                            State#state{streams = maps:put(StreamId, NewStream, Streams)}
                    end
            end
    end;
%% DATA_BLOCKED: Peer is blocked by connection-level flow control (informational)
%% RFC 9000 Section 19.12: DATA_BLOCKED is only allowed in 1-RTT packets
process_frame(app, {data_blocked, _Limit}, State) ->
    %% Informational - no action needed
    State;
process_frame(Level, {data_blocked, _}, State) when Level =/= app ->
    %% Protocol violation: DATA_BLOCKED only allowed in 1-RTT packets
    ?LOG_WARNING(#{what => invalid_data_blocked_level, level => Level}, ?QUIC_LOG_META),
    State#state{close_reason = {protocol_violation, data_blocked_wrong_level}};
%% DATAGRAM frames (RFC 9221)
%% RFC 9221: MUST terminate with PROTOCOL_VIOLATION if receiving DATAGRAM
%% without having advertised support (max_datagram_frame_size = 0)
process_frame(
    app, {datagram, _Data}, #state{cfg = #conn_cfg{max_datagram_frame_size_local = 0}} = State
) ->
    send_protocol_violation(<<"unexpected DATAGRAM frame">>, State);
process_frame(
    app,
    {datagram_with_length, _Data},
    #state{cfg = #conn_cfg{max_datagram_frame_size_local = 0}} = State
) ->
    send_protocol_violation(<<"unexpected DATAGRAM frame">>, State);
%% RFC 9221: MUST terminate with PROTOCOL_VIOLATION if receiving oversized DATAGRAM
process_frame(
    app, {datagram, Data}, #state{cfg = #conn_cfg{max_datagram_frame_size_local = Max}} = State
) when
    byte_size(Data) > Max
->
    send_protocol_violation(<<"DATAGRAM frame too large">>, State);
process_frame(
    app,
    {datagram_with_length, Data},
    #state{cfg = #conn_cfg{max_datagram_frame_size_local = Max}} = State
) when byte_size(Data) > Max ->
    send_protocol_violation(<<"DATAGRAM frame too large">>, State);
process_frame(app, {datagram, Data}, State) ->
    deliver_datagram(Data, State);
process_frame(app, {datagram_with_length, Data}, State) ->
    deliver_datagram(Data, State);
%% NEW_TOKEN (RFC 9000 §8.1.3): servers MUST treat receipt as
%% PROTOCOL_VIOLATION. Clients accept and currently discard; caching
%% the token for reconnect-without-retry reuse depends on server-side
%% token issuance + validation, which aren't implemented yet and are
%% tracked as a follow-up.
process_frame(app, {new_token, _}, #state{cfg = #conn_cfg{role = server}} = State) ->
    close_with_error(
        app,
        transport,
        ?QUIC_PROTOCOL_VIOLATION,
        0,
        <<"NEW_TOKEN received by server">>,
        State
    );
process_frame(
    app, {new_token, Token}, #state{remote_addr = Addr, cfg = #conn_cfg{role = client}} = State
) ->
    ok = quic_token_cache:put(Addr, Token),
    State;
process_frame(_Level, _Frame, State) ->
    %% Ignore unknown frames
    State.

%% What an ACK means beyond loss and congestion accounting. Only the
%% application space has streams, PMTU probes and a send queue, so the
%% handshake spaces take the short path: replay what was lost, at their
%% own encryption level.
app_ack_tail(AckedPackets, LostPackets, State1) ->
    %% Handle PMTU probe ACKs. Only walk the acked list when a
    %% probe is actually outstanding - the common bulk-ACK case
    %% has none and skips the per-packet fold.
    State2 =
        case pmtu_probe_outstanding(State1) of
            true ->
                lists:foldl(
                    fun(#sent_packet{pn = PN}, S) ->
                        handle_pmtu_probe_ack(PN, S)
                    end,
                    State1,
                    AckedPackets
                );
            false ->
                State1
        end,

    %% Black hole detection: one strike per loss event, and
    %% any large packet acked in this ACK clears the strikes.
    State2a = handle_pmtu_ack_event(AckedPackets, State2),
    State2b = handle_pmtu_loss_event(LostPackets, State2a),

    %% Handle PMTU probe losses while searching
    State3 = lists:foldl(
        fun(#sent_packet{pn = PN, size = Size}, S) ->
            handle_pmtu_probe_loss(PN, Size, S)
        end,
        State2b,
        LostPackets
    ),

    %% Retransmit lost packets
    State4 = retransmit_lost_packets(LostPackets, State3),

    %% Close the send side of streams whose FIN the peer just
    %% acked (RFC 9000 §3.1 "Data Recvd"). Reclaiming here, and
    %% not at send time, paces MAX_STREAMS credit to what the
    %% peer has actually consumed; granting at send time let a
    %% peer run far ahead of its own completions.
    State4a =
        case
            lists:usort([
                Sid
             || #sent_packet{frames = Fs} <- AckedPackets,
                {stream, Sid, _O, _D, true} <- Fs
            ])
        of
            [] -> State4;
            FinSids -> lists:foldl(fun settle_fin_ack/2, State4, FinSids)
        end,

    %% Try to send queued data now that cwnd may have freed up.
    %% This also drains retransmit_stream entries deferred by CC.
    State6 = process_send_queue(State4a),
    %% cwnd reopened: replay CC-deferred control retransmits, then
    %% complete any local reset-at reclaim whose reliable bytes are
    %% now acked.
    State7 = flush_deferred_retransmits(drain_pending_hs(State6)),
    State8 = complete_fin_reclaims(complete_send_reset_at(State7)),
    %% The PTO is re-armed once per receive pass, not once per ACK frame:
    %% inside a pass flush_event/2 runs at its end.
    case State8 of
        #state{recv_pass = true, pto_dirty = true} -> State8;
        #state{recv_pass = true} -> State8#state{pto_dirty = true};
        _ -> flush_event(State8, rearm)
    end.

handshake_ack_tail(Level, LostPackets, State1) ->
    State2 = retransmit_lost_handshake(Level, LostPackets, State1),
    State3 = drain_pending_hs(note_handshake_ack(Level, State2)),
    flush_event(State3#state{pto_dirty = true}, event).

%% A Handshake acknowledgement tells a client the server has processed a
%% protected packet from it, so its address is validated.
note_handshake_ack(handshake, #state{cfg = #conn_cfg{role = client}} = State) ->
    State#state{hs = (State#state.hs)#hs{handshake_ack_received = true}};
note_handshake_ack(_Level, State) ->
    State.

%% A lost CRYPTO frame goes back out at the level it was sent from.
%% Routing it through the application send path would encrypt it with
%% keys the peer cannot use yet.
retransmit_lost_handshake(_Level, [], State) ->
    State;
retransmit_lost_handshake(Level, LostPackets, State) ->
    lists:foldl(
        fun(#sent_packet{frames = Frames}, Acc) ->
            lists:foldl(
                fun
                    ({crypto, _Off, _Data} = Frame, Acc1) ->
                        send_at_level(Level, Frame, Acc1);
                    (_Other, Acc1) ->
                        Acc1
                end,
                Acc,
                Frames
            )
        end,
        State,
        LostPackets
    ).

send_at_level(Space, Frame, State) ->
    send_at_level(Space, quic_frame:encode(Frame), [Frame], State).

send_at_level(initial, Payload, Frames, State) ->
    send_initial_packet(Payload, Frames, State);
send_at_level(handshake, Payload, Frames, State) ->
    send_handshake_packet(Payload, Frames, State).

%% Helper to remove a stream from the send queue (tuple of 8 queues)
%% Returns {NewPQ, RemovedBytes, RemovedCount} to allow adjusting the
%% send_queue_bytes (for memory cap) and send_queue_count (for O(1)
%% emptiness check) counters.
remove_stream_from_queue(StreamId, PQ) ->
    %% Filter out entries for this stream from all 8 priority buckets
    %% Queue entries are 6-tuples: {stream_data, StreamId, Offset, Data, Fin, DataSize}
    {NewQueues, RemovedBytes, RemovedCount} =
        lists:foldl(
            fun(I, {Queues, Bytes, Count}) ->
                Q = element(I, PQ),
                %% Calculate bytes + entry count to remove before filtering.
                %% Both stream_data and retransmit_stream entries can be queued.
                {BytesToRemove, CountToRemove} = queue:fold(
                    fun
                        ({Tag, SId, _, _Data, _, DataSize}, {BAcc, CAcc}) when
                            (Tag =:= stream_data orelse Tag =:= retransmit_stream) andalso
                                SId =:= StreamId
                        ->
                            {BAcc + DataSize, CAcc + 1};
                        (_, Acc) ->
                            Acc
                    end,
                    {0, 0},
                    Q
                ),
                %% Filter to keep only other streams
                Kept = queue:filter(
                    fun
                        ({Tag, SId, _, _, _, _}) when
                            Tag =:= stream_data orelse Tag =:= retransmit_stream
                        ->
                            SId =/= StreamId;
                        (_) ->
                            true
                    end,
                    Q
                ),
                {[Kept | Queues], Bytes + BytesToRemove, Count + CountToRemove}
            end,
            {[], 0, 0},
            lists:seq(1, 8)
        ),
    {list_to_tuple(lists:reverse(NewQueues)), RemovedBytes, RemovedCount}.

%% Buffer CRYPTO data and process when complete messages are available
buffer_crypto_data(Level, Offset, Data, State) ->
    LevelAtom =
        case Level of
            initial -> initial;
            handshake -> handshake;
            app -> app;
            _ -> initial
        end,

    %% Get current buffer
    Buffer = maps:get(LevelAtom, (State#state.hs)#hs.crypto_buffer, gb_trees:empty()),

    %% Bound out-of-order CRYPTO reassembly so a peer cannot grow memory
    %% before the handshake completes (RFC 9000 §7.5). Offsets beyond the
    %% cap can never become contiguous, so reject them too.
    BufferedBytes = quic_reassembly:reassembly_buffer_bytes(Buffer),
    Overflow =
        (Offset > ?MAX_CRYPTO_BUFFER_BYTES) orelse
            ((BufferedBytes + byte_size(Data)) > ?MAX_CRYPTO_BUFFER_BYTES) orelse
            (gb_trees:size(Buffer) >= ?MAX_CRYPTO_BUFFER_ENTRIES),
    case Overflow of
        true ->
            ?LOG_WARNING(
                #{
                    what => crypto_buffer_exceeded,
                    level => LevelAtom,
                    buffered_bytes => BufferedBytes,
                    entries => gb_trees:size(Buffer)
                },
                ?QUIC_LOG_META
            ),
            close_with_transport_error(
                ?QUIC_CRYPTO_BUFFER_EXCEEDED, <<"crypto buffer exceeded">>, State
            );
        false ->
            %% A handshake-level CRYPTO duplicate from offset 0 at a
            %% client that has sent its Finished means the server's
            %% retransmission timer fired: the Finished was lost, and
            %% nothing else retransmits it once the statem has left
            %% `handshaking'. Resend it (CRYPTO offsets are idempotent).
            Expected = maps:get(LevelAtom, (State#state.hs)#hs.crypto_offset, 0),
            State0 =
                case
                    LevelAtom =:= handshake andalso
                        (State#state.cfg)#conn_cfg.role =:= client andalso
                        (State#state.hs)#hs.client_hs_flight =/= undefined andalso
                        Offset =:= 0 andalso Expected > 0
                of
                    true ->
                        send_handshake_crypto((State#state.hs)#hs.client_hs_flight, State);
                    false ->
                        State
                end,
            %% Add data to buffer, keeping the longer chunk if the peer
            %% already sent one at this offset.
            {NewBuffer, _} = quic_reassembly:keep_longest_chunk(Offset, Data, Buffer),
            NewCryptoBuffer = maps:put(LevelAtom, NewBuffer, (State0#state.hs)#hs.crypto_buffer),

            State1 = State0#state{hs = (State0#state.hs)#hs{crypto_buffer = NewCryptoBuffer}},

            %% Try to process contiguous data
            process_crypto_buffer(LevelAtom, State1)
    end.

%% Process contiguous CRYPTO data
process_crypto_buffer(Level, State) ->
    Buffer = maps:get(Level, (State#state.hs)#hs.crypto_buffer, gb_trees:empty()),
    ExpectedOffset = maps:get(Level, (State#state.hs)#hs.crypto_offset, 0),

    case gb_trees:lookup(ExpectedOffset, Buffer) of
        {value, Data} ->
            %% Process this data
            State1 = process_tls_data(Level, Data, State),

            %% Update offset and remove from buffer
            NewOffset = ExpectedOffset + byte_size(Data),
            NewBuffer = gb_trees:delete(ExpectedOffset, Buffer),
            NewCryptoBuffer = maps:put(Level, NewBuffer, (State1#state.hs)#hs.crypto_buffer),
            NewCryptoOffset = maps:put(Level, NewOffset, (State1#state.hs)#hs.crypto_offset),

            State2 = State1#state{
                hs = (State1#state.hs)#hs{
                    crypto_buffer = NewCryptoBuffer,
                    crypto_offset = NewCryptoOffset
                }
            },

            %% Try to process more
            process_crypto_buffer(Level, State2);
        none ->
            %% Nothing keyed exactly at ExpectedOffset, which does not mean a
            %% gap: a peer may re-frame CRYPTO data it retransmits (RFC 9000
            %% §13.3), so the bytes we need can sit inside a chunk that starts
            %% earlier. Drop what is already consumed, re-key what straddles
            %% the offset, then retry once. Storing the trimmed buffer also
            %% stops duplicate retransmissions from accumulating against
            %% ?MAX_CRYPTO_BUFFER_BYTES and closing a healthy connection.
            {Trimmed, _} = quic_reassembly:trim_reassembly_buffer(Buffer, ExpectedOffset),
            State1 = State#state{
                hs = (State#state.hs)#hs{
                    crypto_buffer = maps:put(Level, Trimmed, (State#state.hs)#hs.crypto_buffer)
                }
            },
            case gb_trees:is_defined(ExpectedOffset, Trimmed) of
                true -> process_crypto_buffer(Level, State1);
                false -> State1
            end
    end.

%% Key logging is opt-in via SSLKEYLOGFILE and off otherwise; see
%% quic_keylog for why it exists and what it exposes.
keylog_handshake(ClientRandom, ClientSecret, ServerSecret) ->
    quic_keylog:log(client_handshake, ClientRandom, ClientSecret),
    quic_keylog:log(server_handshake, ClientRandom, ServerSecret).

keylog_application(ClientRandom, ClientSecret, ServerSecret) ->
    quic_keylog:log(client_application, ClientRandom, ClientSecret),
    quic_keylog:log(server_application, ClientRandom, ServerSecret).

%%====================================================================
%% TLS message driver
%%
%% The second half of the handshake, reached from packet processing
%% rather than from the TLS section above: CRYPTO frames arrive here,
%% are reassembled, and drive the TLS state machine.
%%====================================================================

%% Process TLS handshake data from CRYPTO frames
process_tls_data(Level, Data, State) ->
    %% Prepend any buffered incomplete TLS data
    BufferedData = maps:get(Level, (State#state.hs)#hs.tls_buffer, <<>>),
    FullData = <<BufferedData/binary, Data/binary>>,
    %% Clear the buffer before processing
    State1 = State#state{
        hs = (State#state.hs)#hs{tls_buffer = maps:put(Level, <<>>, (State#state.hs)#hs.tls_buffer)}
    },
    process_tls_messages(Level, FullData, State1).

%% Process TLS messages
process_tls_messages(_Level, <<>>, State) ->
    State;
process_tls_messages(Level, Data, State) ->
    case quic_tls:decode_handshake_message(Data) of
        {ok, {Type, Body}, Rest} ->
            %% Capture the ORIGINAL bytes from the wire (including TLS header)
            OriginalMsg = binary:part(Data, 0, 4 + byte_size(Body)),
            %% Pass the original bytes to process_tls_message for transcript
            State1 = process_tls_message(Level, Type, Body, OriginalMsg, State),
            process_tls_messages(Level, Rest, State1);
        {error, incomplete} ->
            %% Buffer the incomplete data for next CRYPTO frame
            State#state{
                hs = (State#state.hs)#hs{
                    tls_buffer = maps:put(Level, Data, (State#state.hs)#hs.tls_buffer)
                }
            };
        {error, _Err} ->
            State
    end.

%% Process individual TLS messages
%% OriginalMsg contains the exact bytes from the wire for transcript computation

%% Server receives ClientHello
process_tls_message(
    _Level,
    ?TLS_CLIENT_HELLO,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = server}, hs = #hs{tls_state = ?TLS_AWAITING_CLIENT_HELLO}} =
        StateChIn
) ->
    case quic_tls:parse_client_hello(Body) of
        {ok,
            #{
                random := _ClientRandom,
                key_share := KeyShareEntries,
                cipher_suites := CipherSuites,
                session_id := SessionId
            } = ClientHelloInfo} ->
            %% RFC 9368 compatible version negotiation must be settled on
            %% the FIRST ClientHello, before any response goes out: a
            %% HelloRetryRequest sent in the old version followed by a
            %% ServerHello in the new one leaves the client mid-handshake
            %% with packets it cannot make sense of.
            State = maybe_negotiate_compatible_version(
                maps:get(transport_params, ClientHelloInfo, #{}),
                maps:get(early_data, ClientHelloInfo, false),
                StateChIn
            ),
            %% Select cipher suite (prefer server's order)
            Cipher = quic_tls_negotiation:select_cipher(
                CipherSuites, (State#state.cfg)#conn_cfg.cipher_preference
            ),
            %% RFC 8446 §4.1.4 group negotiation: use the client's
            %% key_share directly when possible, otherwise send a
            %% HelloRetryRequest for a mutually-supported group.
            %% do_server_client_hello/6 carries the full PSK/0-RTT path
            %% (external PSK, resumption binder verification, single-use
            %% ticket consumption) once the group is settled.
            SupportedGroups = maps:get(supported_groups, ClientHelloInfo, []),
            case
                quic_tls_negotiation:select_key_share_group(
                    (State#state.cfg)#conn_cfg.tls_groups, KeyShareEntries, SupportedGroups
                )
            of
                {direct, SelGroup} ->
                    ClientPubKey = quic_tls_negotiation:extract_group_key(
                        SelGroup, KeyShareEntries
                    ),
                    do_server_client_hello(
                        SelGroup, ClientPubKey, Cipher, ClientHelloInfo, OriginalMsg, State
                    );
                {hrr, HrrGroup} when not (State#state.hs)#hs.hrr_sent ->
                    send_hello_retry_request(HrrGroup, Cipher, SessionId, OriginalMsg, State);
                {hrr, _} ->
                    %% Client ignored our HRR group selection.
                    send_tls_alert(
                        ?TLS_ALERT_ILLEGAL_PARAMETER, <<"bad retry key_share">>, State
                    );
                none ->
                    send_tls_alert(?TLS_ALERT_HANDSHAKE_FAILURE, <<"no common group">>, State)
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{what => client_hello_parse_failed, reason => Reason}, ?QUIC_LOG_META),
            StateChIn
    end;
%% Client receives ServerHello
process_tls_message(
    _Level,
    ?TLS_SERVER_HELLO,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = client}, hs = #hs{tls_state = ?TLS_AWAITING_SERVER_HELLO}} = State
) ->
    case quic_tls:parse_server_hello(Body) of
        {hrr, HrrInfo} ->
            handle_hello_retry_request(HrrInfo, OriginalMsg, State);
        {ok, #{cipher := Cipher} = ServerHelloMap} ->
            %% RFC 8446 §4.1.3: the selected suite must be one we offered.
            case lists:member(Cipher, (State#state.cfg)#conn_cfg.cipher_preference) of
                false ->
                    notify_owner({error, {tls_alert, illegal_parameter}}, State),
                    alert_and_exit(?TLS_ALERT_ILLEGAL_PARAMETER, State, illegal_parameter);
                true ->
                    ok
            end,
            %% Determine handshake type: PSK (with or without DHE) vs
            %% standard cert-auth. PSK selection is signalled by the
            %% `selected_psk_identity' extension echoed in ServerHello.
            ServerPubKey = maps:get(public_key, ServerHelloMap),
            ServerGroup = maps:get(selected_group, ServerHelloMap),
            SelectedPskIdx = maps:get(selected_psk_identity, ServerHelloMap, undefined),
            case validate_client_psk_selection(SelectedPskIdx, State) of
                {error, Reason} ->
                    ?LOG_WARNING(
                        #{what => psk_not_selected, reason => Reason},
                        ?QUIC_LOG_META
                    ),
                    notify_owner({error, psk_not_selected}, State),
                    State;
                {ok, ClientSelectedPsk} ->
                    %% psk_ke = ServerHello omits key_share; ECDHE is skipped.
                    SharedSecret =
                        case {ServerPubKey, ServerGroup} of
                            {undefined, undefined} ->
                                <<>>;
                            {_, Group} when Group =:= (State#state.hs)#hs.tls_group ->
                                quic_crypto:compute_shared_secret(
                                    (State#state.hs)#hs.tls_group,
                                    (State#state.hs)#hs.tls_private_key,
                                    ServerPubKey
                                );
                            _ ->
                                {error, illegal_parameter}
                        end,
                    %% A key_share that doesn't fit the negotiated group
                    %% (wrong length, or a group we didn't pick).
                    case SharedSecret of
                        {error, illegal_parameter} ->
                            notify_owner({error, {tls_alert, illegal_parameter}}, State),
                            alert_and_exit(?TLS_ALERT_ILLEGAL_PARAMETER, State, illegal_parameter);
                        {error, internal_error} ->
                            notify_owner({error, {tls_alert, internal_error}}, State),
                            alert_and_exit(?TLS_ALERT_INTERNAL_ERROR, State, internal_error);
                        _ ->
                            ok
                    end,

                    Transcript = <<
                        ((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary
                    >>,
                    TranscriptHash = quic_crypto:transcript_hash(Cipher, Transcript),

                    %% Cipher-aware hash length for the zero-PSK case.
                    HashLen =
                        case Cipher of
                            aes_256_gcm -> 48;
                            _ -> 32
                        end,
                    EarlySecret =
                        case ClientSelectedPsk of
                            #{secret := Secret} ->
                                quic_crypto:derive_early_secret(Cipher, Secret);
                            undefined ->
                                quic_crypto:derive_early_secret(Cipher, <<0:HashLen/unit:8>>)
                        end,

                    %% psk_ke uses zero IKM in place of the DHE shared secret.
                    HandshakeSecret =
                        case ClientSelectedPsk of
                            #{mode := psk_ke} ->
                                quic_crypto:derive_handshake_secret_psk_only(Cipher, EarlySecret);
                            _ ->
                                quic_crypto:derive_handshake_secret(
                                    Cipher, EarlySecret, SharedSecret
                                )
                        end,

                    ClientHsSecret = quic_crypto:derive_client_handshake_secret(
                        Cipher, HandshakeSecret, TranscriptHash
                    ),
                    ServerHsSecret = quic_crypto:derive_server_handshake_secret(
                        Cipher, HandshakeSecret, TranscriptHash
                    ),
                    {ClientKey, ClientIV, ClientHP} =
                        quic_keys:derive_keys(ClientHsSecret, Cipher, State#state.version),
                    {ServerKey, ServerIV, ServerHP} =
                        quic_keys:derive_keys(ServerHsSecret, Cipher, State#state.version),
                    ClientHsKeys = #crypto_keys{
                        key = ClientKey, iv = ClientIV, hp = ClientHP, cipher = Cipher
                    },
                    ServerHsKeys = #crypto_keys{
                        key = ServerKey, iv = ServerIV, hp = ServerHP, cipher = Cipher
                    },

                    State1 = State#state{
                        hs = (State#state.hs)#hs{
                            tls_state = ?TLS_AWAITING_ENCRYPTED_EXT,
                            tls_transcript = Transcript,
                            handshake_secret = HandshakeSecret,
                            client_hs_secret = ClientHsSecret,
                            server_hs_secret = ServerHsSecret,
                            handshake_keys = {ClientHsKeys, ServerHsKeys},
                            negotiated_group = (State#state.hs)#hs.tls_group,
                            selected_psk = ClientSelectedPsk
                        }
                    },
                    send_initial_ack(State1)
            end;
        {error, illegal_parameter} ->
            notify_owner({error, {tls_alert, illegal_parameter}}, State),
            send_tls_alert(?TLS_ALERT_ILLEGAL_PARAMETER, State);
        {error, _} ->
            State
    end;
process_tls_message(
    _Level,
    ?TLS_ENCRYPTED_EXTENSIONS,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = client}, hs = #hs{tls_state = ?TLS_AWAITING_ENCRYPTED_EXT}} =
        State
) ->
    %% Update transcript - USE ORIGINAL BYTES
    Transcript = <<((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary>>,

    %% Next state depends on auth path: PSK-authenticated handshakes
    %% skip Certificate/CertificateVerify (RFC 8446 §4.6.1) and go
    %% straight to Finished.
    NextState =
        case (State#state.hs)#hs.selected_psk of
            undefined -> ?TLS_AWAITING_CERT;
            _ -> ?TLS_AWAITING_FINISHED
        end,

    case quic_tls:parse_encrypted_extensions(Body) of
        {ok, #{alpn := Alpn, transport_params := TP, early_data := EarlyDataInEE}} ->
            %% RFC 9001 §4.6.2: a client that offered 0-RTT (i.e. has
            %% derived early_keys from a session ticket) confirms
            %% acceptance by the presence of the empty `early_data'
            %% extension in EncryptedExtensions. Absence is rejection.
            %% Clients that did not offer 0-RTT keep the default `false'.
            OfferedZeroRtt = (State#state.hs)#hs.early_keys =/= undefined,
            EarlyDataAccepted = OfferedZeroRtt andalso EarlyDataInEE,
            State0 = State#state{
                alpn = Alpn,
                hs = (State#state.hs)#hs{
                    tls_state = NextState,
                    tls_transcript = Transcript,
                    early_data_accepted = EarlyDataAccepted
                }
            },
            %% Apply peer transport params (extracts active_connection_id_limit).
            %% Client already has handshake keys at this point, so the CLOSE
            %% (if any) can be emitted immediately.
            State1 = maybe_emit_pending_close(apply_peer_transport_params(TP, State0)),
            %% Finalise 0-RTT bookkeeping: if the client offered 0-RTT and
            %% the server did NOT accept, reset every stream that carried
            %% 0-RTT data and notify the owner so the application protocol
            %% can re-issue the affected requests.
            finalize_zero_rtt_state(State1);
        _ ->
            State#state{
                hs = (State#state.hs)#hs{
                    tls_state = NextState,
                    tls_transcript = Transcript
                }
            }
    end;
%% Client receives server Certificate
process_tls_message(
    _Level,
    ?TLS_CERTIFICATE,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = client}, hs = #hs{tls_state = ?TLS_AWAITING_CERT}} = State
) ->
    Transcript = <<((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary>>,
    %% Parse and store peer certificate. The chain and identity are
    %% validated at CertificateVerify, where the signature also proves
    %% the server holds the leaf's private key.
    {PeerCert, PeerCertChain} =
        case quic_tls:parse_certificate(Body) of
            {ok, #{certificates := [First | Rest]}} ->
                {First, Rest};
            {ok, #{certificates := []}} ->
                {undefined, []};
            {error, _} ->
                {undefined, []}
        end,
    State1 = State#state{
        hs = (State#state.hs)#hs{
            tls_state = ?TLS_AWAITING_CERT_VERIFY,
            tls_transcript = Transcript,
            peer_cert = PeerCert,
            peer_cert_chain = PeerCertChain
        }
    },
    case (State#state.cfg)#conn_cfg.verify andalso (PeerCert =:= undefined) of
        true ->
            %% verify enabled but server sent no certificate.
            ?LOG_ERROR(#{what => server_sent_no_certificate}, ?QUIC_LOG_META),
            notify_owner({error, {certificate_invalid, no_certificate}}, State1),
            send_tls_alert(?TLS_ALERT_CERTIFICATE_REQUIRED, State1);
        false ->
            State1
    end;
%% Client receives server CertificateVerify
process_tls_message(
    _Level,
    ?TLS_CERTIFICATE_VERIFY,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = client}, hs = #hs{tls_state = ?TLS_AWAITING_CERT_VERIFY}} = State
) ->
    %% The signature is over the transcript up to and including
    %% Certificate, i.e. before this message is appended.
    {ClientHsKeys, _} = (State#state.hs)#hs.handshake_keys,
    Cipher = ClientHsKeys#crypto_keys.cipher,
    TranscriptHash = quic_crypto:transcript_hash(Cipher, (State#state.hs)#hs.tls_transcript),
    Scheme =
        case quic_tls:parse_certificate_verify(Body) of
            {ok, #{algorithm := Alg}} -> code_to_sig_alg(Alg);
            _ -> undefined
        end,
    Transcript = <<((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary>>,
    Advance = State#state{
        hs = (State#state.hs)#hs{
            tls_state = ?TLS_AWAITING_FINISHED,
            tls_transcript = Transcript,
            negotiated_scheme = Scheme
        }
    },
    case (State#state.cfg)#conn_cfg.verify of
        false ->
            Advance;
        true ->
            verify_server_authentication(Body, TranscriptHash, Advance, State)
    end;
%% Client receives server's Finished
process_tls_message(
    _Level,
    ?TLS_FINISHED,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = client}, hs = #hs{tls_state = ?TLS_AWAITING_FINISHED}} = State
) ->
    %% Get cipher from handshake keys for cipher-aware operations
    {ClientHsKeys, _} = (State#state.hs)#hs.handshake_keys,
    Cipher = ClientHsKeys#crypto_keys.cipher,

    %% Verify server Finished
    case quic_tls:parse_finished(Body) of
        {ok, VerifyData} ->
            TranscriptHash = quic_crypto:transcript_hash(
                Cipher, (State#state.hs)#hs.tls_transcript
            ),
            case
                quic_tls:verify_finished(
                    VerifyData, (State#state.hs)#hs.server_hs_secret, TranscriptHash, Cipher
                )
            of
                true ->
                    %% Update transcript with server Finished - USE ORIGINAL BYTES
                    Transcript = <<
                        ((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary
                    >>,
                    TranscriptHashFinal = quic_crypto:transcript_hash(Cipher, Transcript),

                    %% Derive master secret and application keys (cipher-aware)
                    MasterSecret = quic_crypto:derive_master_secret(
                        Cipher, (State#state.hs)#hs.handshake_secret
                    ),
                    ClientAppSecret = quic_crypto:derive_client_app_secret(
                        Cipher, MasterSecret, TranscriptHashFinal
                    ),
                    ServerAppSecret = quic_crypto:derive_server_app_secret(
                        Cipher, MasterSecret, TranscriptHashFinal
                    ),
                    keylog_application(
                        (State#state.hs)#hs.tls_ch1_random, ClientAppSecret, ServerAppSecret
                    ),

                    %% Derive app keys
                    {ClientKey, ClientIV, ClientHP} = quic_keys:derive_keys(
                        ClientAppSecret, Cipher, State#state.version
                    ),
                    {ServerKey, ServerIV, ServerHP} = quic_keys:derive_keys(
                        ServerAppSecret, Cipher, State#state.version
                    ),

                    ClientAppKeys = #crypto_keys{
                        key = ClientKey, iv = ClientIV, hp = ClientHP, cipher = Cipher
                    },
                    ServerAppKeys = #crypto_keys{
                        key = ServerKey, iv = ServerIV, hp = ServerHP, cipher = Cipher
                    },

                    %% Initialize key update state with app secrets for future key updates
                    KeyState = #key_update_state{
                        current_phase = 0,
                        current_keys = {ClientAppKeys, ServerAppKeys},
                        prev_keys = undefined,
                        client_app_secret = ClientAppSecret,
                        server_app_secret = ServerAppSecret,
                        update_state = idle
                    },

                    %% If server requested client certificate (CertificateRequest received),
                    %% send Certificate and optionally CertificateVerify before Finished
                    %% RFC 8446 Section 4.4.2: client MUST send Certificate if server sent CertificateRequest
                    {CertPayload, Transcript2} =
                        case (State#state.hs)#hs.cert_request_received of
                            true ->
                                case (State#state.cfg)#conn_cfg.client_cert of
                                    undefined ->
                                        %% No client cert - send empty Certificate, no CertificateVerify
                                        EmptyCertMsg = quic_tls:build_certificate(<<>>, []),
                                        {EmptyCertMsg, <<Transcript/binary, EmptyCertMsg/binary>>};
                                    ClientCert ->
                                        %% Have client cert - send Certificate + CertificateVerify
                                        AllClientCerts = [
                                            ClientCert
                                            | (State#state.cfg)#conn_cfg.client_cert_chain
                                        ],
                                        ClientCertMsg = quic_tls:build_certificate(
                                            <<>>, AllClientCerts
                                        ),
                                        T1 = <<Transcript/binary, ClientCertMsg/binary>>,
                                        TranscriptHashCV = quic_crypto:transcript_hash(Cipher, T1),
                                        %% Pick a scheme the server offered and our
                                        %% key can produce; fall back to the key's
                                        %% natural scheme if the offer is empty.
                                        SigAlg = client_cert_verify_code(State),
                                        ClientCertVerifyMsg = quic_tls:build_certificate_verify_client(
                                            SigAlg,
                                            (State#state.cfg)#conn_cfg.client_private_key,
                                            TranscriptHashCV
                                        ),
                                        {
                                            <<ClientCertMsg/binary, ClientCertVerifyMsg/binary>>,
                                            <<T1/binary, ClientCertVerifyMsg/binary>>
                                        }
                                end;
                            false ->
                                %% No CertificateRequest - send nothing before Finished
                                {<<>>, Transcript}
                        end,

                    %% Compute client Finished using updated transcript
                    TranscriptHash2 = quic_crypto:transcript_hash(Cipher, Transcript2),
                    ClientFinishedKey = quic_crypto:derive_finished_key(
                        Cipher, (State#state.hs)#hs.client_hs_secret
                    ),
                    ClientVerifyData = quic_crypto:compute_finished_verify(
                        Cipher, ClientFinishedKey, TranscriptHash2
                    ),
                    ClientFinishedMsg = quic_tls:build_finished(ClientVerifyData),

                    %% Combine Certificate(+CertificateVerify) and Finished into one payload
                    HandshakePayload = <<CertPayload/binary, ClientFinishedMsg/binary>>,

                    State1 = State#state{
                        app_keys = {ClientAppKeys, ServerAppKeys},
                        key_state = KeyState,
                        hs = (State#state.hs)#hs{
                            tls_state = ?TLS_HANDSHAKE_COMPLETE,
                            client_hs_flight = HandshakePayload,
                            tls_transcript = <<Transcript2/binary, ClientFinishedMsg/binary>>,
                            master_secret = MasterSecret
                        }
                    },

                    %% Send client Certificate(+CertificateVerify)+Finished,
                    %% segmented so no datagram exceeds max_udp_payload_size.
                    send_handshake_crypto(HandshakePayload, State1);
                false ->
                    %% Verification failed
                    State
            end;
        {error, _} ->
            State
    end;
%% Server receives client's Finished
process_tls_message(
    _Level,
    ?TLS_FINISHED,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = server}, hs = #hs{tls_state = ?TLS_AWAITING_CLIENT_FINISHED}} =
        State
) ->
    {ClientHsKeys, _} = (State#state.hs)#hs.handshake_keys,
    Cipher = ClientHsKeys#crypto_keys.cipher,

    case quic_tls:parse_finished(Body) of
        {ok, VerifyData} ->
            %% Verify client's Finished using client handshake secret
            TranscriptHash = quic_crypto:transcript_hash(
                Cipher, (State#state.hs)#hs.tls_transcript
            ),
            case
                quic_tls:verify_finished(
                    VerifyData, (State#state.hs)#hs.client_hs_secret, TranscriptHash, Cipher
                )
            of
                true ->
                    %% Update transcript with client Finished
                    Transcript = <<
                        ((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary
                    >>,

                    %% Derive resumption_master_secret (RFC 8446 Section 7.1)
                    %% resumption_master_secret = Derive-Secret(master_secret, "res master",
                    %%                                          ClientHello..client Finished)
                    FinalTranscriptHash = quic_crypto:transcript_hash(Cipher, Transcript),
                    ResumptionSecret = quic_ticket:derive_resumption_secret(
                        Cipher, (State#state.hs)#hs.master_secret, FinalTranscriptHash, <<>>
                    ),

                    %% Application keys are already derived when server sent its Finished
                    State1 = State#state{
                        hs = (State#state.hs)#hs{
                            tls_state = ?TLS_HANDSHAKE_COMPLETE,
                            tls_transcript = Transcript,
                            resumption_secret = ResumptionSecret
                        }
                    },

                    %% The server's handshake is confirmed once complete
                    %% (RFC 9001 §4.1.2); tell the client.
                    State2 = send_handshake_done(confirm_handshake(State1)),

                    %% Send NewSessionTicket to enable session resumption
                    send_new_session_ticket(State2);
                false ->
                    State
            end;
        {error, _} ->
            State
    end;
%% Client receives NewSessionTicket from server (post-handshake)
%% RFC 8446 Section 4.6.1
process_tls_message(
    _Level,
    ?TLS_NEW_SESSION_TICKET,
    Body,
    _OriginalMsg,
    #state{
        alpn = ALPN,
        app_keys = {ClientAppKeys, _},
        cfg = #conn_cfg{
            role = client
        },
        hs = #hs{
            tls_state = ?TLS_HANDSHAKE_COMPLETE,
            server_name = ServerName,
            master_secret = MasterSecret,
            tls_transcript = Transcript
        }
    } = State
) ->
    case quic_ticket:parse_new_session_ticket(Body) of
        {ok, #{
            lifetime := Lifetime,
            age_add := AgeAdd,
            nonce := Nonce,
            ticket := TicketData,
            max_early_data := MaxEarlyData
        }} ->
            %% The cipher is the same across levels; read it from the
            %% 1-RTT keys, which a ticket arriving after confirmation is
            %% protected with anyway.
            Cipher = ClientAppKeys#crypto_keys.cipher,

            %% Derive resumption_master_secret from master secret
            %% The transcript should include client Finished
            FinalTranscriptHash = quic_crypto:transcript_hash(Cipher, Transcript),
            ResumptionSecret = quic_ticket:derive_resumption_secret(
                Cipher, MasterSecret, FinalTranscriptHash, <<>>
            ),

            %% Create session ticket record
            Ticket = #session_ticket{
                server_name =
                    case ServerName of
                        undefined -> <<"">>;
                        Name -> Name
                    end,
                ticket = TicketData,
                lifetime = Lifetime,
                age_add = AgeAdd,
                nonce = Nonce,
                resumption_secret = ResumptionSecret,
                max_early_data = MaxEarlyData,
                received_at = erlang:system_time(second),
                cipher = Cipher,
                alpn = ALPN
            },

            %% Store ticket
            TicketKey =
                case ServerName of
                    undefined -> <<"">>;
                    SN -> SN
                end,
            TicketStore = quic_ticket:store_ticket(
                TicketKey, Ticket, (State#state.hs)#hs.ticket_store
            ),

            %% Notify owner about the new ticket
            #state{owner = Owner} = State,
            Owner ! {quic, self(), {session_ticket, Ticket}},

            State#state{
                hs = (State#state.hs)#hs{
                    ticket_store = TicketStore,
                    resumption_secret = ResumptionSecret
                }
            };
        {error, _Reason} ->
            State
    end;
%% Client receives CertificateRequest from server (mutual TLS)
process_tls_message(
    _Level,
    ?TLS_CERTIFICATE_REQUEST,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = client}, hs = #hs{tls_state = ?TLS_AWAITING_CERT}} = State
) ->
    %% Update transcript and mark that server wants client certificate.
    %% Capture the advertised signature_algorithms so the client can
    %% pick a compatible CertificateVerify scheme.
    Transcript = <<((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary>>,
    PeerSigAlgs =
        case quic_tls:parse_certificate_request(Body) of
            {ok, #{signature_algorithms := SA}} -> SA;
            _ -> []
        end,
    State#state{
        hs = (State#state.hs)#hs{
            tls_transcript = Transcript,
            cert_request_received = true,
            peer_sig_algs = PeerSigAlgs
        }
    };
%% Server receives client Certificate (when verify=true)
process_tls_message(
    _Level,
    ?TLS_CERTIFICATE,
    Body,
    OriginalMsg,
    #state{cfg = #conn_cfg{role = server}, hs = #hs{tls_state = ?TLS_AWAITING_CLIENT_CERT}} = State
) ->
    Transcript = <<((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary>>,
    case quic_tls:parse_certificate(Body) of
        {ok, #{certificates := [First | Rest]}} ->
            %% RFC 8446 §4.4.2.4: validate the client's certificate chain against
            %% our trust anchors before accepting it. Possession of the leaf's
            %% private key is checked next, on CertificateVerify; the signature
            %% check alone does not establish that the certificate is trusted.
            case quic_cert:validate_client(First, Rest, (State#state.cfg)#conn_cfg.cacerts) of
                ok ->
                    State#state{
                        hs = (State#state.hs)#hs{
                            tls_state = ?TLS_AWAITING_CLIENT_CERT_VERIFY,
                            tls_transcript = Transcript,
                            peer_cert = First,
                            peer_cert_chain = Rest
                        }
                    };
                {error, Reason} ->
                    reject_client_cert(Reason, State)
            end;
        {ok, #{certificates := []}} ->
            %% RFC 8446 §4.4.2.4: an empty client Certificate means the client has
            %% none. The server MAY continue without client auth or abort with
            %% certificate_required. Default to optional mTLS; only
            %% require_client_cert makes a client certificate mandatory.
            case (State#state.cfg)#conn_cfg.require_client_cert of
                true ->
                    reject_client_cert(no_certificate, State);
                false ->
                    State#state{
                        hs = (State#state.hs)#hs{
                            tls_state = ?TLS_AWAITING_CLIENT_FINISHED,
                            tls_transcript = Transcript,
                            peer_cert = undefined,
                            peer_cert_chain = []
                        }
                    }
            end;
        {error, _} ->
            reject_client_cert({bad_cert, malformed}, State)
    end;
%% Server receives client CertificateVerify (when verify=true and client sent cert)
process_tls_message(
    _Level,
    ?TLS_CERTIFICATE_VERIFY,
    Body,
    OriginalMsg,
    #state{
        cfg = #conn_cfg{
            role = server
        },
        hs = #hs{
            tls_state = ?TLS_AWAITING_CLIENT_CERT_VERIFY,
            peer_cert = PeerCert
        }
    } = State
) when PeerCert =/= undefined ->
    %% Get cipher for transcript hash
    {ClientHsKeys, _} = (State#state.hs)#hs.handshake_keys,
    Cipher = ClientHsKeys#crypto_keys.cipher,

    %% Verify signature (transcript is BEFORE CertificateVerify)
    TranscriptHash = quic_crypto:transcript_hash(Cipher, (State#state.hs)#hs.tls_transcript),
    case quic_tls:verify_certificate_verify(Body, PeerCert, TranscriptHash, client) of
        true ->
            Transcript = <<((State#state.hs)#hs.tls_transcript)/binary, OriginalMsg/binary>>,
            State#state{
                hs = (State#state.hs)#hs{
                    tls_state = ?TLS_AWAITING_CLIENT_FINISHED,
                    tls_transcript = Transcript
                }
            };
        false ->
            %% Signature verification failed - send TLS decrypt_error alert
            %% RFC 8446: decrypt_error (51) for signature verification failure
            ?LOG_ERROR(#{what => client_cert_verify_failed}, ?QUIC_LOG_META),
            send_tls_alert(?TLS_ALERT_DECRYPT_ERROR, State)
    end;
process_tls_message(_Level, _Type, _Body, _OriginalMsg, State) ->
    State.

%% @private Continue a server-side ClientHello once the key-exchange
%% group is settled (direct or post-HRR). SelectedGroup is the agreed
%% named group; ClientPubKey is the client's key_share for it.
do_server_client_hello(SelectedGroup, ClientPubKey, Cipher, ClientHelloInfo, OriginalMsg, State0In) ->
    %% Remember the client's offered signature schemes for the server's
    %% CertificateVerify negotiation, then resolve the server cert (static
    %% or via the per-SNI callback) before any cert-path work runs.
    StateSig = State0In#state{
        hs = (State0In#state.hs)#hs{
            peer_sig_algs = maps:get(signature_algorithms, ClientHelloInfo, []),
            %% The tickets this connection issues are bound to it.
            server_name = maps:get(server_name, ClientHelloInfo, undefined)
        }
    },
    case resolve_server_cert(ClientHelloInfo, StateSig) of
        {error, Phrase} ->
            send_tls_alert(?TLS_ALERT_HANDSHAKE_FAILURE, Phrase, StateSig);
        {ok, State} ->
            do_server_client_hello_cont(
                SelectedGroup, ClientPubKey, Cipher, ClientHelloInfo, OriginalMsg, State
            )
    end.

%% @private Continue the ClientHello once the server cert/key are settled.
do_server_client_hello_cont(
    SelectedGroup, ClientPubKey, Cipher, ClientHelloInfo, OriginalMsg, State
) ->
    ClientALPN = maps:get(alpn_protocols, ClientHelloInfo, []),
    ClientRandom = maps:get(random, ClientHelloInfo, undefined),
    TP = maps:get(transport_params, ClientHelloInfo, #{}),
    SessionId = maps:get(session_id, ClientHelloInfo, <<>>),
    %% Check for PSK (0-RTT/resumption/external)
    PSKInfo = maps:get(pre_shared_key, ClientHelloInfo, undefined),
    WantsEarlyData = maps:get(early_data, ClientHelloInfo, false),

    %% TLS 1.3 external PSK selection (RFC 8446 §4.2.11).
    %% Validate pre_shared_key placement, lookup identity, verify
    %% binder. On match the server skips the cert path and uses
    %% the PSK secret in the early_secret derivation below.
    PskConfig = (State#state.cfg)#conn_cfg.psk_config,
    ServerPskModes = [psk_dhe_ke, psk_ke],
    ExternalPskResult =
        case PskConfig of
            undefined ->
                none;
            _ ->
                quic_tls:select_psk(
                    ClientHelloInfo, OriginalMsg, PskConfig, ServerPskModes
                )
        end,
    ok,

    HashLen0 =
        case Cipher of
            aes_256_gcm -> 48;
            _ -> 32
        end,
    ZeroPSK = <<0:HashLen0/unit:8>>,

    %% Derive early secret. External-PSK selection wins over
    %% resumption-PSK, which wins over the standard zero-PSK path.
    {EarlyKeys, EarlySecret, SelectedPsk} =
        case ExternalPskResult of
            {ok, #{secret := PSKSecret, mode := Mode} = Sel} ->
                Selected = #{
                    identity => maps:get(identity, Sel),
                    identity_idx => maps:get(identity_idx, Sel),
                    secret => PSKSecret,
                    mode => Mode,
                    source => external
                },
                {
                    undefined,
                    quic_crypto:derive_early_secret(Cipher, PSKSecret),
                    Selected
                };
            none ->
                case PSKInfo of
                    #{identities := [{Identity, _Age} | _], binders := [Binder | _]} ->
                        case
                            resume_ticket(
                                Identity, Binder, Cipher, OriginalMsg, ClientHelloInfo, State
                            )
                        of
                            {ok, PSK, ResumptionSecret} ->
                                ES = quic_crypto:derive_early_secret(Cipher, PSK),
                                %% The ticket's PSK carries the whole
                                %% handshake (psk_dhe_ke), so the cert
                                %% flight is skipped; before, it only
                                %% fed the 0-RTT keys and the
                                %% handshake fell back to a full
                                %% cert exchange on a zero PSK.
                                Selected = #{
                                    identity => Identity,
                                    identity_idx => 0,
                                    secret => PSK,
                                    mode => psk_dhe_ke,
                                    source => ticket
                                },
                                EK =
                                    case WantsEarlyData of
                                        true ->
                                            ClientHelloHash =
                                                quic_crypto:transcript_hash(
                                                    Cipher, OriginalMsg
                                                ),
                                            ETS =
                                                quic_crypto:derive_client_early_traffic_secret(
                                                    Cipher, ES, ClientHelloHash
                                                ),
                                            {Key, IV, HP} =
                                                quic_keys:derive_keys(
                                                    ETS, Cipher, State#state.version
                                                ),
                                            EKeys = #crypto_keys{
                                                key = Key,
                                                iv = IV,
                                                hp = HP,
                                                cipher = Cipher
                                            },
                                            {EKeys, ResumptionSecret};
                                        false ->
                                            undefined
                                    end,
                                {EK, ES, Selected};
                            bad_binder ->
                                ?LOG_WARNING(
                                    #{what => resumption_psk_binder_failed},
                                    ?QUIC_LOG_META
                                ),
                                alert_and_exit(?TLS_ALERT_DECRYPT_ERROR, State, decrypt_error);
                            error ->
                                %% Unknown or expired ticket: fall back to a
                                %% full handshake (RFC 8446 §4.2.11).
                                {undefined, quic_crypto:derive_early_secret(Cipher, ZeroPSK),
                                    undefined}
                        end;
                    _ ->
                        {undefined, quic_crypto:derive_early_secret(Cipher, ZeroPSK), undefined}
                end;
            {error, bad_binder} ->
                %% Bail out via exit/1; the handler returning
                %% here is impossible because the case can't
                %% produce a valid tuple. Elvis prefers exit
                %% over throw.
                ?LOG_WARNING(
                    #{what => psk_binder_verification_failed},
                    ?QUIC_LOG_META
                ),
                alert_and_exit(?TLS_ALERT_DECRYPT_ERROR, State, decrypt_error)
        end,

    %% Server side of the key exchange for the negotiated group: an
    %% ECDHE keygen + ECDH for classical groups, an ML-KEM
    %% encapsulation + ECDH for the hybrid group.
    {ServerPubKey, ServerPrivKey, SharedSecret} =
        case quic_crypto:server_key_exchange(SelectedGroup, ClientPubKey) of
            {error, illegal_parameter} ->
                %% Client share doesn't fit the group it named.
                ?LOG_WARNING(
                    #{what => bad_key_share, group => SelectedGroup},
                    ?QUIC_LOG_META
                ),
                alert_and_exit(?TLS_ALERT_ILLEGAL_PARAMETER, State, illegal_parameter);
            Exchange ->
                Exchange
        end,

    %% Negotiate ALPN
    ALPN = quic_tls_negotiation:negotiate_alpn(ClientALPN, (State#state.cfg)#conn_cfg.alpn_list),

    %% Build ServerHello. For PSK handshakes the ServerHello
    %% carries `selected_psk_identity'; for psk_ke it also
    %% omits key_share (RFC 8446 §4.2.9).
    ServerHelloOpts0 = #{
        cipher_suite => quic_tls_negotiation:cipher_atom_to_code(Cipher),
        key_pair => {ServerPubKey, ServerPrivKey},
        key_share_group => SelectedGroup,
        session_id => SessionId
    },
    ServerHelloOpts =
        case SelectedPsk of
            undefined ->
                ServerHelloOpts0;
            #{identity_idx := Idx, mode := SelMode} ->
                ServerHelloOpts0#{
                    selected_psk_identity => Idx,
                    selected_psk_mode => SelMode
                }
        end,
    {ServerHello, _ServerPrivKey2} = quic_tls:build_server_hello(ServerHelloOpts),

    %% Transcript base: empty for a first ClientHello, or the
    %% synthetic-message_hash + HRR prefix on a post-HRR retry
    %% (already stored in tls_transcript when the HRR was sent).
    Transcript0 =
        case (State#state.hs)#hs.hrr_sent of
            true -> (State#state.hs)#hs.tls_transcript;
            false -> <<>>
        end,
    Transcript = <<Transcript0/binary, OriginalMsg/binary, ServerHello/binary>>,
    TranscriptHash = quic_crypto:transcript_hash(Cipher, Transcript),

    %% Derive handshake secrets. psk_ke (PSK-only) uses zero IKM
    %% per RFC 8446 §7.1; psk_dhe_ke and standard handshakes use
    %% the ECDHE shared secret.
    HandshakeSecret =
        case SelectedPsk of
            #{mode := psk_ke} ->
                quic_crypto:derive_handshake_secret_psk_only(Cipher, EarlySecret);
            _ ->
                quic_crypto:derive_handshake_secret(
                    Cipher, EarlySecret, SharedSecret
                )
        end,

    ClientHsSecret = quic_crypto:derive_client_handshake_secret(
        Cipher, HandshakeSecret, TranscriptHash
    ),
    ServerHsSecret = quic_crypto:derive_server_handshake_secret(
        Cipher, HandshakeSecret, TranscriptHash
    ),

    %% Derive handshake keys
    {ClientKey, ClientIV, ClientHP} = quic_keys:derive_keys(
        ClientHsSecret, Cipher, State#state.version
    ),
    {ServerKey, ServerIV, ServerHP} = quic_keys:derive_keys(
        ServerHsSecret, Cipher, State#state.version
    ),

    ClientHsKeys = #crypto_keys{
        key = ClientKey, iv = ClientIV, hp = ClientHP, cipher = Cipher
    },
    ServerHsKeys = #crypto_keys{
        key = ServerKey, iv = ServerIV, hp = ServerHP, cipher = Cipher
    },

    %% Update DCID from ClientHello SCID
    %% quic_tls decodes the initial_source_connection_id param as initial_scid
    ClientSCID = maps:get(initial_scid, TP, <<>>),

    State0 = State#state{
        dcid = ClientSCID,
        alpn = ALPN,
        hs = (State#state.hs)#hs{
            tls_state = ?TLS_AWAITING_CLIENT_FINISHED,
            tls_transcript = Transcript,
            tls_private_key = ServerPrivKey,
            tls_group = SelectedGroup,
            negotiated_group = SelectedGroup,
            handshake_secret = HandshakeSecret,
            client_hs_secret = ClientHsSecret,
            tls_ch1_random = ClientRandom,
            server_hs_secret = ServerHsSecret,
            handshake_keys = {ClientHsKeys, ServerHsKeys},
            early_keys = EarlyKeys,
            early_data_accepted = (EarlyKeys =/= undefined andalso WantsEarlyData),
            selected_psk = SelectedPsk
        }
    },
    keylog_handshake((State#state.hs)#hs.tls_ch1_random, ClientHsSecret, ServerHsSecret),
    keylog_handshake(ClientRandom, ClientHsSecret, ServerHsSecret),
    %% Negotiate the CertificateVerify scheme up front (cert
    %% path only). No common scheme is fatal (RFC 8446 §4.4.3).
    case negotiate_cert_verify(SelectedPsk, State0) of
        {error, no_common_sig_alg} ->
            send_tls_alert(
                ?TLS_ALERT_HANDSHAKE_FAILURE,
                <<"no common signature algorithm">>,
                State0
            );
        {ok, CVCode, CVScheme} ->
            State0b = State0#state{
                hs = (State0#state.hs)#hs{
                    cert_verify_code = CVCode,
                    negotiated_scheme = CVScheme
                }
            },
            State1 = apply_peer_transport_params(TP, State0b),
            State2 = send_server_hello(ServerHello, State1),
            State3 = server_handshake_flight(Cipher, TranscriptHash, State2),
            maybe_emit_pending_close(State3)
    end.

%% @private Select the server cert/key for this handshake. With no
%% `sni_callback' the static cert configured on the listener is kept.
%% Otherwise the callback is invoked with the ClientHello server_name
%% (RFC 6066 §3); its cert/key/chain override the static ones. A
%% rejection, malformed result, or raised exception fails the handshake.
resolve_server_cert(_ClientHelloInfo, #state{cfg = #conn_cfg{sni_callback = undefined}} = State) ->
    {ok, State};
resolve_server_cert(ClientHelloInfo, #state{cfg = #conn_cfg{sni_callback = Fn}} = State) ->
    ServerName = maps:get(server_name, ClientHelloInfo, undefined),
    try Fn(ServerName) of
        {ok, #{cert := Cert, key := Key} = CertMap} when is_binary(Cert) ->
            {ok, State#state{
                hs = (State#state.hs)#hs{
                    server_cert = Cert,
                    server_private_key = Key,
                    server_cert_chain = maps:get(cert_chain, CertMap, [])
                }
            }};
        Other ->
            ?LOG_WARNING(
                #{what => sni_callback_rejected, server_name => ServerName, result => Other},
                ?QUIC_LOG_META
            ),
            {error, <<"sni callback rejected server name">>}
    catch
        Class:Reason:Stack ->
            ?LOG_WARNING(
                #{
                    what => sni_callback_failed,
                    server_name => ServerName,
                    class => Class,
                    reason => Reason,
                    stacktrace => Stack
                },
                ?QUIC_LOG_META
            ),
            {error, <<"sni callback failed">>}
    end.

%% @private Choose the server's CertificateVerify scheme. PSK
%% handshakes need none. Cert handshakes intersect the key's schemes
%% with the client's offer; no overlap is fatal.
negotiate_cert_verify(SelectedPsk, _State) when SelectedPsk =/= undefined ->
    {ok, undefined, undefined};
negotiate_cert_verify(_None, #state{hs = #hs{server_private_key = undefined}}) ->
    {ok, undefined, undefined};
negotiate_cert_verify(_None, State) ->
    case
        select_signature_algorithm(
            (State#state.hs)#hs.server_private_key,
            (State#state.cfg)#conn_cfg.tls_sig_algs,
            (State#state.hs)#hs.peer_sig_algs
        )
    of
        error -> {error, no_common_sig_alg};
        Code -> {ok, Code, code_to_sig_alg(Code)}
    end.

%% @private Send a HelloRetryRequest for SelectedGroup and arm the
%% server to receive the client's second ClientHello. The transcript
%% is reset to the synthetic message_hash(CH1) + HRR per RFC 8446
%% §4.4.1. No handshake keys exist yet, so HRR ships at Initial level.
send_hello_retry_request(SelectedGroup, Cipher, SessionId, OriginalMsg, State) ->
    CH1Hash = quic_crypto:transcript_hash(Cipher, OriginalMsg),
    Prefix = quic_crypto:hrr_transcript_prefix(Cipher, CH1Hash),
    HRR = quic_tls:build_hello_retry_request(
        SessionId, quic_tls_negotiation:cipher_atom_to_code(Cipher), SelectedGroup
    ),
    Transcript = <<Prefix/binary, HRR/binary>>,
    State1 = State#state{
        hs = (State#state.hs)#hs{
            hrr_sent = true,
            hrr_group = SelectedGroup,
            tls_transcript = Transcript,
            initial_tx_off = byte_size(HRR)
        }
    },
    send_initial_packet(quic_frame:encode({crypto, 0, HRR}), [{crypto, 0, HRR}], State1).

%% @private Client-side HelloRetryRequest handling (RFC 8446 §4.1.4).
%% Validates the one-HRR and group rules, rebuilds CH2 reusing CH1's
%% random + session_id, and rewrites the transcript to the synthetic
%% message_hash(CH1) + HRR prefix.
handle_hello_retry_request(
    #{cipher := Cipher, selected_group := SelGroup}, HrrMsg, State
) ->
    Ch1Opts = (State#state.hs)#hs.tls_ch1_opts,
    PskOffered =
        Ch1Opts =/= undefined andalso
            (maps:get(external_psk, Ch1Opts, undefined) =/= undefined orelse
                maps:get(session_ticket, Ch1Opts, undefined) =/= undefined),
    GroupOffered = lists:member(SelGroup, (State#state.cfg)#conn_cfg.tls_groups),
    case {(State#state.hs)#hs.hrr_sent, PskOffered, GroupOffered} of
        {true, _, _} ->
            %% A second HRR is illegal (RFC 8446 §4.1.4).
            notify_owner({error, {tls_alert, unexpected_message}}, State),
            send_tls_alert(?TLS_ALERT_UNEXPECTED_MESSAGE, State);
        {_, true, _} ->
            %% PSK + HRR is out of scope for v1; aborting avoids a
            %% silent binder-recompute gap.
            notify_owner({error, {tls_alert, unexpected_message}}, State),
            send_tls_alert(?TLS_ALERT_UNEXPECTED_MESSAGE, State);
        {_, _, false} ->
            %% Server picked a group we never offered.
            notify_owner({error, {tls_alert, illegal_parameter}}, State),
            send_tls_alert(?TLS_ALERT_ILLEGAL_PARAMETER, State);
        {false, false, true} ->
            %% Synthetic transcript: message_hash(CH1) || HRR. The
            %% current transcript holds exactly CH1.
            CH1Hash = quic_crypto:transcript_hash(Cipher, (State#state.hs)#hs.tls_transcript),
            Prefix = quic_crypto:hrr_transcript_prefix(Cipher, CH1Hash),
            BaseTranscript = <<Prefix/binary, HrrMsg/binary>>,

            %% Rebuild CH2: same random + session_id, key_share moved
            %% to the server-selected group. supported_groups stays.
            Ch2Opts = Ch1Opts#{
                key_share_group => SelGroup,
                retry_random => (State#state.hs)#hs.tls_ch1_random,
                retry_session_id => <<>>
            },
            {CH2, PrivKey, _Random} = quic_tls:build_client_hello(Ch2Opts),
            Transcript = <<BaseTranscript/binary, CH2/binary>>,

            Off = (State#state.hs)#hs.initial_tx_off,
            State1 = State#state{
                hs = (State#state.hs)#hs{
                    hrr_sent = true,
                    hrr_group = SelGroup,
                    tls_group = SelGroup,
                    tls_private_key = PrivKey,
                    tls_transcript = Transcript,
                    initial_tx_off = Off + byte_size(CH2)
                }
            },
            send_initial_crypto(CH2, Off, State1)
    end.

%%====================================================================
%% Handshake flight retransmission
%%
%% The client retains its Certificate(+CertificateVerify)+Finished flight
%% and resends it until the handshake is confirmed. Nothing here is PMTU,
%% where these two used to sit.
%%====================================================================

%% The flight is acknowledged (HANDSHAKE_DONE, or a 1-RTT ack that only a
%% server holding our Finished could have sent): stop holding it for the
%% handshake-space probe to pick up.
clear_hs_flight(State) ->
    State#state{hs = (State#state.hs)#hs{client_hs_flight = undefined}}.

%%====================================================================
%% Internal Functions - Stream Processing
%%====================================================================

process_stream_data(StreamId, Offset, Data, Fin, State) ->
    #state{cfg = #conn_cfg{role = Role}} = State,

    %% RFC 9000 Section 2.1: Validate stream direction
    %% Cannot receive on locally-initiated unidirectional streams
    case validate_receive_stream(StreamId, Role) of
        {error, Reason} ->
            ?LOG_WARNING(
                #{what => invalid_receive_stream, stream_id => StreamId, reason => Reason},
                ?QUIC_LOG_META
            ),
            % Silently ignore (could send STREAM_STATE_ERROR)
            State;
        ok ->
            case exceeds_stream_limit(StreamId, State) of
                true -> stream_limit_close(State);
                false -> process_stream_data_validated(StreamId, Offset, Data, Fin, State)
            end
    end.

%% Validate that we can receive on this stream
validate_receive_stream(StreamId, Role) ->
    IsUni = (StreamId band 2) =/= 0,
    IsLocallyInitiated =
        case Role of
            client -> (StreamId band 1) =:= 0;
            server -> (StreamId band 1) =:= 1
        end,
    case {IsUni, IsLocallyInitiated} of
        {true, true} ->
            %% Cannot receive on our own unidirectional stream
            {error, stream_state_error};
        _ ->
            ok
    end.

process_stream_data_validated(StreamId, Offset, Data, Fin, State) ->
    NotInMap = not is_map_key(StreamId, State#state.streams),
    case NotInMap andalso stream_reclaimed(StreamId, (State#state.cfg)#conn_cfg.role, State) of
        true ->
            %% Late/retransmitted frame for an already-reclaimed stream. Stream
            %% ids are never reused (RFC 9000 §2.1), so this is never a new
            %% stream; ignore it rather than resurrecting the record.
            State;
        false ->
            case
                NotInMap andalso stream_locally_initiated(StreamId, (State#state.cfg)#conn_cfg.role)
            of
                true ->
                    %% The peer sent STREAM data for one of our locally-initiated
                    %% stream ids that we never opened (RFC 9000 §3.2). The peer
                    %% cannot open our streams: STREAM_STATE_ERROR.
                    stream_state_error_close(
                        StreamId, <<"data for unopened local stream">>, State
                    );
                false ->
                    do_process_stream_data_validated(StreamId, Offset, Data, Fin, State)
            end
    end.

%% Close the connection with STREAM_STATE_ERROR for a frame that references a
%% stream in a way the peer is not allowed to.
stream_state_error_close(StreamId, Reason, State) ->
    ?LOG_WARNING(
        #{what => stream_state_error, stream_id => StreamId, reason => Reason}, ?QUIC_LOG_META
    ),
    close_with_transport_error(?QUIC_STREAM_STATE_ERROR, Reason, State).

do_process_stream_data_validated(StreamId, Offset, Data, Fin, State) ->
    %% If the peer sent RESET_STREAM_AT, it aborted beyond ReliableSize: data at
    %% or after the boundary must not be delivered (clamp), and a frame fully
    %% beyond it is dropped outright.
    case clamp_recv_reset_at(StreamId, Offset, Data, Fin, State) of
        drop ->
            State;
        {ClampedData, ClampedFin} ->
            do_process_stream_data_buffered(StreamId, Offset, ClampedData, ClampedFin, State)
    end.

%% Drop data at/after recv_reset_at, truncate a straddling chunk to the boundary
%% (clearing Fin). Returns drop | {Data, Fin}.
clamp_recv_reset_at(StreamId, Offset, Data, Fin, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream_state{recv_reset_at = R}} when R =/= undefined ->
            if
                Offset >= R -> drop;
                Offset + byte_size(Data) =< R -> {Data, Fin};
                true -> {binary:part(Data, 0, R - Offset), false}
            end;
        _ ->
            {Data, Fin}
    end.

recv_reset_at_met(#stream_state{recv_reset_at = R}, Off) ->
    R =/= undefined andalso Off >= R.

%% Lean path for the dominant bulk shape: existing stream, exactly
%% in-order, empty reassembly buffer, no FIN in sight, no pending reset,
%% both flow-control windows comfortably open (so neither
%% MAX_STREAM_DATA nor MAX_DATA fires). One stream-record update and one
%% map put. Every other shape takes the general path below with
%% identical semantics; on bulk flows 97+ percent of frames land here.
do_process_stream_data_buffered(StreamId, Offset, Data, false = Fin, State) ->
    case State#state.streams of
        #{
            StreamId := #stream_state{
                recv_offset = Offset,
                recv_max_data = RecvMaxData,
                final_size = undefined,
                recv_reset_at = undefined,
                recv_buffer = RB
            } = Stream
        } ->
            DataSize = byte_size(Data),
            EndOffset = Offset + DataSize,
            NewDataReceived = State#state.data_received + DataSize,
            HalfWindow = (State#state.cfg)#conn_cfg.fc_max_receive_window div 2,
            case
                DataSize > 0 andalso
                    gb_trees:is_empty(RB) andalso
                    RecvMaxData - EndOffset >= HalfWindow andalso
                    State#state.max_data_local - NewDataReceived >= HalfWindow andalso
                    State#state.recv_buffer_bytes + DataSize =< ?MAX_RECV_BUFFER_BYTES
            of
                true ->
                    PendDeliver = deliver_stream_data(StreamId, Data, false, State),
                    State#state{
                        streams = maps:put(
                            StreamId,
                            Stream#stream_state{recv_offset = EndOffset},
                            State#state.streams
                        ),
                        data_received = NewDataReceived,
                        pend_deliver = PendDeliver
                    };
                false ->
                    do_process_stream_data_slow(StreamId, Offset, Data, Fin, State)
            end;
        _ ->
            do_process_stream_data_slow(StreamId, Offset, Data, Fin, State)
    end;
do_process_stream_data_buffered(StreamId, Offset, Data, Fin, State) ->
    do_process_stream_data_slow(StreamId, Offset, Data, Fin, State).

do_process_stream_data_slow(StreamId, Offset, Data, Fin, State) ->
    #state{
        owner = Owner,
        streams = Streams,
        max_data_local = MaxDataLocal,
        data_received = DataReceived,
        recv_buffer_bytes = RecvBufferBytes
    } = State,

    DataSize = byte_size(Data),

    %% Get or create stream state
    Stream =
        case maps:find(StreamId, Streams) of
            {ok, S} ->
                S;
            error ->
                %% New stream from peer - notify owner
                Owner ! {quic, self(), {stream_opened, StreamId}},
                %% Use peer's limits for streams they initiate
                InitSendMaxData = get_peer_stream_limit(bidi_peer_initiated, State),
                InitRecvMaxData = get_local_recv_limit(bidi_peer_initiated, State),
                ?LOG_DEBUG(
                    #{
                        what => stream_created_peer_initiated,
                        stream_id => StreamId,
                        init_send_max_data => InitSendMaxData,
                        init_recv_max_data => InitRecvMaxData
                    },
                    ?QUIC_LOG_META
                ),
                #stream_state{
                    id = StreamId,
                    state = open,
                    send_offset = 0,
                    send_max_data = InitSendMaxData,
                    send_fin = false,
                    send_buffer = [],
                    recv_offset = 0,
                    recv_max_data = InitRecvMaxData,
                    recv_fin = false,
                    recv_buffer = gb_trees:empty(),
                    final_size = undefined
                }
        end,

    %% RFC 9000 Section 4.1: Check receive flow control limits BEFORE buffering
    EndOffset = Offset + DataSize,
    RecvMaxData = Stream#stream_state.recv_max_data,

    %% Check if this would exceed our receive buffer limit (malicious peer protection)
    RecvBuffer =
        case Stream#stream_state.recv_buffer of
            undefined -> gb_trees:empty();
            B -> B
        end,
    CurrentOffset = Stream#stream_state.recv_offset,
    IsDuplicate = Offset < CurrentOffset orelse gb_trees:is_defined(Offset, RecvBuffer),

    %% Only check buffer limit for new (non-duplicate) data
    BufferOverflow =
        case IsDuplicate of
            true -> false;
            false -> RecvBufferBytes + DataSize > ?MAX_RECV_BUFFER_BYTES
        end,

    case {EndOffset > RecvMaxData, DataReceived + DataSize > MaxDataLocal, BufferOverflow} of
        {true, _, _} ->
            %% Stream-level flow control violation - RFC 9000 Section 4.1
            ?LOG_WARNING(
                #{
                    what => stream_flow_control_violation,
                    stream_id => StreamId,
                    end_offset => EndOffset,
                    recv_max_data => RecvMaxData
                },
                ?QUIC_LOG_META
            ),
            %% Send FLOW_CONTROL_ERROR and close connection
            CloseFrame =
                {connection_close, transport, ?QUIC_FLOW_CONTROL_ERROR, 0,
                    <<"stream flow control violation">>},
            send_frame(CloseFrame, State#state{close_reason = stream_flow_control_error});
        {_, true, _} ->
            %% Connection-level flow control violation - RFC 9000 Section 4.1
            ?LOG_WARNING(
                #{
                    what => connection_flow_control_violation,
                    recv => DataReceived + DataSize,
                    max => MaxDataLocal
                },
                ?QUIC_LOG_META
            ),
            %% Send FLOW_CONTROL_ERROR and close connection
            CloseFrame =
                {connection_close, transport, ?QUIC_FLOW_CONTROL_ERROR, 0,
                    <<"connection flow control violation">>},
            send_frame(CloseFrame, State#state{close_reason = connection_flow_control_error});
        {_, _, true} ->
            %% Receive buffer overflow - malicious peer sending too much out-of-order data
            ?LOG_WARNING(
                #{
                    what => recv_buffer_overflow,
                    stream_id => StreamId,
                    recv_buffer_bytes => RecvBufferBytes,
                    data_size => DataSize,
                    max_bytes => ?MAX_RECV_BUFFER_BYTES
                },
                ?QUIC_LOG_META
            ),
            %% Send FLOW_CONTROL_ERROR and close connection
            CloseFrame =
                {connection_close, transport, ?QUIC_FLOW_CONTROL_ERROR, 0,
                    <<"recv buffer overflow">>},
            send_frame(CloseFrame, State#state{close_reason = recv_buffer_overflow});
        _ ->
            %% Flow control OK - check final size consistency before buffering

            %% RFC 9000 Section 4.5: once a FIN has fixed the final size it
            %% cannot move, and nothing may lie beyond it.
            ExistingFinalSize = Stream#stream_state.final_size,
            FinalSizeError =
                ExistingFinalSize =/= undefined andalso
                    ((Fin andalso ExistingFinalSize =/= EndOffset) orelse
                        EndOffset > ExistingFinalSize),

            case FinalSizeError of
                true ->
                    ?LOG_WARNING(
                        #{
                            what => final_size_error,
                            stream_id => StreamId,
                            existing => ExistingFinalSize,
                            end_offset => EndOffset,
                            fin => Fin
                        },
                        ?QUIC_LOG_META
                    ),
                    CloseFrame =
                        {connection_close, transport, ?QUIC_FINAL_SIZE_ERROR, 0,
                            <<"stream data past its final size">>},
                    send_frame(CloseFrame, State#state{close_reason = final_size_error});
                false ->
                    %% Track FIN position if received
                    FinalSize =
                        case Fin of
                            true -> EndOffset;
                            false -> ExistingFinalSize
                        end,

                    %% Fast path: in-order delivery with empty buffer
                    %% Avoids the buffer insert and extract_contiguous_data for common case
                    {DeliverData, NewRecvOffset, NewBuffer, DeliverFin, BufferedDelta} =
                        case Offset =:= CurrentOffset andalso gb_trees:is_empty(RecvBuffer) of
                            true ->
                                %% In-order with empty buffer: deliver directly
                                {Data, EndOffset, RecvBuffer, Fin, 0};
                            false ->
                                %% Out-of-order or buffer has data: use buffer path
                                {UpdatedBuffer, Added} =
                                    quic_reassembly:keep_longest_chunk(Offset, Data, RecvBuffer),
                                {ExtractedData, ExtractedOffset, ExtractedBuffer, Removed} =
                                    quic_reassembly:extract_contiguous_data(
                                        UpdatedBuffer, CurrentOffset
                                    ),
                                ExtractedFin =
                                    FinalSize =/= undefined andalso ExtractedOffset >= FinalSize,
                                {ExtractedData, ExtractedOffset, ExtractedBuffer, ExtractedFin,
                                    Added - Removed}
                        end,

                    %% Deliver contiguous data to owner
                    %% RFC 9000: Also deliver FIN-only notification when no data but FIN received
                    PendDeliver1 =
                        case {DeliverData, DeliverFin} of
                            {<<>>, false} ->
                                %% No contiguous data to deliver yet
                                State#state.pend_deliver;
                            _ ->
                                deliver_stream_data(StreamId, DeliverData, DeliverFin, State)
                        end,

                    NewStream = Stream#stream_state{
                        recv_offset = NewRecvOffset,
                        recv_fin = DeliverFin,
                        recv_buffer = NewBuffer,
                        recv_buffered = Stream#stream_state.recv_buffered + BufferedDelta,
                        final_size = FinalSize,
                        recv_done =
                            (DeliverFin andalso gb_trees:is_empty(NewBuffer)) orelse
                                recv_reset_at_met(Stream, NewRecvOffset) orelse
                                Stream#stream_state.recv_done
                    },

                    %% Track connection-level data received - only count NEW bytes, not duplicates
                    NewBytesReceived =
                        case IsDuplicate of
                            true -> 0;
                            false -> DataSize
                        end,
                    NewDataReceivedVal = DataReceived + NewBytesReceived,

                    %% Update receive buffer bytes tracking from the buffer
                    %% itself. The new-minus-delivered estimate drifts upward
                    %% once retransmissions overlap, because the overlapping
                    %% bytes count as new but are never delivered twice, and
                    %% that drift would eventually trip the cap on a stream
                    %% holding nothing.
                    NewRecvBufferBytes = max(0, RecvBufferBytes + BufferedDelta),

                    State1 = State#state{
                        streams = maps:put(StreamId, NewStream, Streams),
                        data_received = NewDataReceivedVal,
                        recv_buffer_bytes = NewRecvBufferBytes,
                        pend_deliver = PendDeliver1
                    },
                    %% The stream is reclaimed at the end of this clause (after the
                    %% MAX_STREAM_DATA / MAX_DATA updates, which re-put the stream),
                    %% so a terminal stream is not re-inserted after removal.

                    State2 =
                        case NewStream#stream_state.recv_flow of
                            auto -> auto_stream_grant(StreamId, State1);
                            manual -> manual_stream_grant(StreamId, State1)
                        end,

                    %% Check if we need to send MAX_DATA for connection-level flow
                    %% control. Trigger on remaining headroom (limit - received),
                    %% like the per-stream update above: comparing cumulative
                    %% received bytes against the absolute limit becomes
                    %% permanently true once total received exceeds one window,
                    %% spraying an ack-eliciting MAX_DATA on every packet.
                    State3 = conn_grant(State2),

                    %% ACK is sent at packet level by maybe_send_ack.
                    %% Reclaim last: if both directions are now terminal, drop the
                    %% stream from the map (RFC 9000 §4.6 / memory reclamation).
                    maybe_reclaim_stream(StreamId, State3)
                % end of FinalSizeError case
            end
    end.

%% MAX_STREAM_DATA for an `auto' stream once the sender's headroom (limit
%% - delivered) drops below half the window. Comparing the absolute limit
%% instead deadlocks once it reaches the window. A stream whose final size
%% is known can never use more credit (RFC 9000 Section 19.10), so it gets
%% none.
auto_stream_grant(StreamId, #state{streams = Streams} = State) ->
    case Streams of
        #{
            StreamId := #stream_state{
                recv_flow = auto,
                final_size = undefined,
                recv_offset = Offset,
                recv_max_data = RecvMaxData
            } = Stream
        } when RecvMaxData - Offset < (State#state.cfg)#conn_cfg.fc_max_receive_window div 2 ->
            case credit_allowed(State) of
                {true, State1} ->
                    send_auto_stream_credit(StreamId, Stream, State1);
                {false, #state{credit_withheld = Withheld} = State1} ->
                    State1#state{credit_withheld = sets:add_element(StreamId, Withheld)}
            end;
        _ ->
            State
    end.

send_auto_stream_credit(
    StreamId,
    #stream_state{recv_offset = Offset, recv_max_data = RecvMaxData} = Stream,
    #state{streams = Streams} = State
) ->
    Now = erlang:monotonic_time(millisecond),
    SmoothedRTT = quic_rtt:smoothed(quic_loss:rtt(State#state.loss_state)),
    MaxWindow = (State#state.cfg)#conn_cfg.fc_max_receive_window,
    %% Check if consumption is fast (< 4*RTT since last update)
    FastConsumption =
        case State#state.fc_last_stream_update of
            undefined -> true;
            Last -> (Now - Last) < (SmoothedRTT * ?AUTO_TUNE_RTT_FACTOR)
        end,
    %% Slide the window forward relative to the delivered offset, capped
    %% at MaxWindow, so the sender never stalls at a fixed limit.
    NewMaxStreamData =
        case FastConsumption of
            true -> Offset + min(RecvMaxData * 2, MaxWindow);
            false -> Offset + min(RecvMaxData + ?DEFAULT_INITIAL_MAX_STREAM_DATA, MaxWindow)
        end,
    %% Cache the granted window size (not the absolute limit) for the
    %% connection-window multiplier in conn_grant/1.
    NewCachedMax = max(NewMaxStreamData - Offset, State#state.fc_max_stream_recv_window),
    State1 = State#state{
        streams = Streams#{StreamId => Stream#stream_state{recv_max_data = NewMaxStreamData}},
        fc_last_stream_update = Now,
        fc_max_stream_recv_window = NewCachedMax
    },
    send_frame({max_stream_data, StreamId, NewMaxStreamData}, State1).

%% Credit waits while the owner is behind on its mailbox: what the peer
%% sends next would only pile up there. A timer re-checks.
credit_allowed(#state{credit_timer = Ref} = State) when Ref =/= undefined ->
    {false, State};
credit_allowed(State) ->
    case owner_behind(State) of
        true ->
            Ref = make_ref(),
            erlang:send_after(?CREDIT_RETRY_MS, self(), {credit_retry, Ref}),
            {false, State#state{credit_timer = Ref}};
        false ->
            {true, State}
    end.

%% The owner is behind when its mailbox holds more than max_owner_queue
%% messages.
owner_behind(#state{cfg = #conn_cfg{max_owner_queue = infinity}}) ->
    false;
owner_behind(#state{owner = Owner, cfg = #conn_cfg{max_owner_queue = Max}}) when
    node(Owner) =:= node()
->
    case erlang:process_info(Owner, message_queue_len) of
        {message_queue_len, Len} -> Len > Max;
        undefined -> false
    end;
owner_behind(_State) ->
    false.

%% Grant what was withheld, or wait another round if the owner is still
%% behind.
release_withheld_credit(#state{credit_withheld = Withheld} = State) ->
    State1 = sets:fold(
        fun auto_stream_grant/2,
        State#state{credit_withheld = sets:new([{version, 2}])},
        Withheld
    ),
    conn_grant(State1).

%% MAX_DATA when the connection's headroom (limit - received) falls under
%% half the window. The new limit is anchored on what readers have taken:
%% bytes a manual stream has delivered but not had consumed do not earn
%% connection credit. Never sent unless it raises the limit.
conn_grant(#state{max_data_local = MaxDataLocal, data_received = Received} = State) ->
    MaxWindow = (State#state.cfg)#conn_cfg.fc_max_receive_window,
    case max(0, MaxDataLocal - Received) < MaxWindow div 2 of
        true ->
            case credit_allowed(State) of
                {true, State0} -> send_conn_credit(State0);
                {false, State0} -> State0
            end;
        false ->
            State
    end.

send_conn_credit(#state{max_data_local = MaxDataLocal, data_received = Received} = State) ->
    MaxWindow = (State#state.cfg)#conn_cfg.fc_max_receive_window,
    {Unconsumed, State1} = manual_unconsumed(State),
    Anchor = Received - Unconsumed,
    Now = erlang:monotonic_time(millisecond),
    SmoothedRTT = quic_rtt:smoothed(quic_loss:rtt(State1#state.loss_state)),
    %% Check if consumption is fast (< 4*RTT since last update)
    FastConsumption =
        case State1#state.fc_last_conn_update of
            undefined -> true;
            Last -> (Now - Last) < (SmoothedRTT * ?AUTO_TUNE_RTT_FACTOR)
        end,
    %% Calculate new window based on RTT-aware growth.
    BaseNewMaxData = next_conn_max_data(
        Anchor, MaxDataLocal, MaxWindow, ?DEFAULT_INITIAL_MAX_DATA, FastConsumption
    ),
    %% Ensure connection window >= 1.5x largest stream window.
    %% MaxStreamWindow is a window size; anchor it to compare limits.
    MaxStreamWindow = get_max_stream_recv_window(State1),
    MinConnWindow =
        Anchor + trunc(MaxStreamWindow * ?CONNECTION_FLOW_CONTROL_MULTIPLIER),
    case max(BaseNewMaxData, MinConnWindow) of
        NewMaxData when NewMaxData > MaxDataLocal ->
            State2 = send_frame({max_data, NewMaxData}, State1),
            State2#state{max_data_local = NewMaxData, fc_last_conn_update = Now};
        _ ->
            State1
    end.

%% Bytes manual streams have delivered but not had consumed, dropping ids
%% whose stream is gone.
manual_unconsumed(#state{manual_recv_streams = Manual, streams = Streams} = State) ->
    case sets:is_empty(Manual) of
        true ->
            {0, State};
        false ->
            {Sum, Live} = sets:fold(
                fun(Id, {Acc, Keep}) ->
                    case Streams of
                        #{Id := #stream_state{recv_flow = manual} = S} ->
                            Owed = S#stream_state.recv_offset - S#stream_state.recv_consumed,
                            {Acc + max(0, Owed), sets:add_element(Id, Keep)};
                        _ ->
                            {Acc, Keep}
                    end
                end,
                {0, sets:new([{version, 2}])},
                Manual
            ),
            {Sum, State#state{manual_recv_streams = Live}}
    end.

%% A manual stream's window: its configured initial limit, capped at the
%% largest window this connection grants. Not auto-tuned.
manual_window(StreamId, #state{cfg = #conn_cfg{role = Role}} = State) ->
    Kind =
        case stream_locally_initiated(StreamId, Role) of
            true -> bidi_local_initiated;
            false -> peer_stream_kind(StreamId)
        end,
    min(get_local_recv_limit(Kind, State), (State#state.cfg)#conn_cfg.fc_max_receive_window).

%% MAX_STREAM_DATA for a manual stream: one window past what the reader
%% consumed, sent once that is at least half a window beyond the current
%% limit, or at once when the peer has used up the current one.
manual_stream_grant(StreamId, #state{streams = Streams} = State) ->
    case Streams of
        #{
            StreamId := #stream_state{
                recv_flow = manual,
                recv_consumed = Consumed,
                recv_max_data = Max,
                final_size = undefined
            } = Stream
        } ->
            Window = manual_window(StreamId, State),
            NewMax = Consumed + Window,
            case NewMax - Max >= max(1, Window div 2) of
                true ->
                    State1 = State#state{
                        streams = Streams#{StreamId => Stream#stream_state{recv_max_data = NewMax}}
                    },
                    send_frame({max_stream_data, StreamId, NewMax}, State1);
                false ->
                    State
            end;
        _ ->
            State
    end.

%% Switch a stream between delivery-driven and reader-driven credit. Frames
%% only go out once the connection is up; before that the mode is recorded
%% and the first grant happens on the receive path.
set_recv_flow(StreamId, Mode, StateName, #state{streams = Streams} = State) ->
    case {Streams, Mode} of
        {#{StreamId := Stream}, {manual, Consumed}} ->
            Stream1 = Stream#stream_state{
                recv_flow = manual,
                recv_consumed = min(Consumed, Stream#stream_state.recv_offset)
            },
            State1 = State#state{
                streams = Streams#{StreamId => Stream1},
                manual_recv_streams = sets:add_element(
                    StreamId, State#state.manual_recv_streams
                )
            },
            grant_when_connected(StreamId, StateName, State1);
        {#{StreamId := Stream}, auto} ->
            Stream1 = Stream#stream_state{recv_flow = auto},
            State1 = State#state{
                streams = Streams#{StreamId => Stream1},
                manual_recv_streams = sets:del_element(
                    StreamId, State#state.manual_recv_streams
                )
            },
            %% A peer blocked on the manual window sends nothing more, so
            %% nothing on the receive path would release it.
            case StateName of
                connected -> conn_grant(auto_stream_release(StreamId, State1));
                _ -> State1
            end;
        _ ->
            State
    end.

recv_consumed(StreamId, Offset, StateName, #state{streams = Streams} = State) ->
    case Streams of
        #{StreamId := #stream_state{recv_flow = manual, recv_consumed = Old} = Stream} ->
            Consumed = max(Old, min(Offset, Stream#stream_state.recv_offset)),
            State1 = State#state{
                streams = Streams#{StreamId => Stream#stream_state{recv_consumed = Consumed}}
            },
            grant_when_connected(StreamId, StateName, State1);
        _ ->
            State
    end.

grant_when_connected(StreamId, connected, State) ->
    conn_grant(manual_stream_grant(StreamId, State));
grant_when_connected(_StreamId, _StateName, State) ->
    State.

%% One window past what was delivered, for a stream leaving manual mode.
auto_stream_release(StreamId, #state{streams = Streams} = State) ->
    case Streams of
        #{
            StreamId := #stream_state{
                recv_offset = Offset, recv_max_data = Max, final_size = undefined
            } = Stream
        } ->
            case Offset + manual_window(StreamId, State) of
                NewMax when NewMax > Max ->
                    State1 = State#state{
                        streams = Streams#{StreamId => Stream#stream_state{recv_max_data = NewMax}}
                    },
                    send_frame({max_stream_data, StreamId, NewMax}, State1);
                _ ->
                    State
            end;
        _ ->
            State
    end.

flush_after_grant(connected, State) ->
    flush_event(State, event);
flush_after_grant(_StateName, State) ->
    State.

%% Get the maximum stream receive window across all streams.
%% Used to ensure connection window >= 1.5x largest stream window.
%% Uses cached value to avoid O(n) scan on every call.
get_max_stream_recv_window(#state{fc_max_stream_recv_window = CachedMax}) ->
    CachedMax.

%%====================================================================
%% Socket I/O
%%
%% What follows this banner was one undifferentiated "Helpers" region;
%% it is four subjects, each with its own banner below.
%%====================================================================

%% Send a packet via quic_socket (with batching) or gen_udp fallback.
%% For client connections with socket_state, uses quic_socket batching.
%% For server connections (shared socket), sends directly via gen_udp.
%%
%% Returns `{ok, SocketState}' where `SocketState' is the updated
%% `#socket_state{}' to replace `State#state.socket_state' (or
%% `undefined' to leave the state unchanged). Callers thread the
%% returned state into their subsequent `#state{}' record update.
-spec do_socket_send(iodata(), #state{}) ->
    {ok, undefined | quic_socket:socket_state()}
    | {error, term()}
    | {error, term(), undefined | quic_socket:socket_state()}.
do_socket_send(Packet, #state{socket_state = undefined, socket = Socket, remote_addr = {IP, Port}}) ->
    case gen_udp:send(Socket, IP, Port, Packet) of
        ok -> {ok, undefined};
        {error, _} = Err -> Err
    end;
do_socket_send(Packet, #state{socket_state = SocketState, remote_addr = {IP, Port}}) ->
    quic_socket:send(SocketState, IP, Port, Packet).

%% Wrapper used by the fire-and-forget senders (Initial / Handshake /
%% 0-RTT). Returns the socket_state to carry forward: the new one on
%% successful batching, or the existing one unchanged when the send
%% went through the raw gen_udp path or failed.
send_and_take_socket_state(Packet, State) ->
    case do_socket_send(Packet, State) of
        {ok, undefined} -> State#state.socket_state;
        {ok, NewSocketState} -> NewSocketState;
        {error, _, NewSocketState} -> NewSocketState;
        {error, _} -> State#state.socket_state
    end.

%% Send a packet to an explicit address (not `remote_addr'). Used by
%% path-validation frames (PATH_CHALLENGE / PATH_RESPONSE). Dispatches
%% on the socket backend so it works whether the client is on the
%% gen_udp path (raw `gen_udp:send/4') or the opt-in socket path
%% (`socket:sendmsg/2' via `quic_socket:send_immediate/4').
send_packet_to_addr(IP, Port, Packet, #state{socket_state = SocketState}) when
    SocketState =/= undefined
->
    case quic_socket:send_immediate(SocketState, IP, Port, Packet) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end;
send_packet_to_addr(IP, Port, Packet, #state{socket = Socket}) ->
    gen_udp:send(Socket, IP, Port, Packet).

%% Re-arm active-N on the client socket. No-op on the `socket' backend
%% which delivers messages via the dedicated receiver process — see
%% `quic_socket:start_client_receiver/2'.
client_rearm_active(#state{cfg = #conn_cfg{client_socket_backend = socket}}, _N) ->
    ok;
client_rearm_active(#state{cfg = #conn_cfg{client_socket_backend = adapter}}, _N) ->
    %% Adapter callers manage their own delivery; there is no UDP
    %% socket whose active counter we could rearm.
    ok;
client_rearm_active(#state{socket = Socket}, N) ->
    inet:setopts(Socket, [{active, N}]).

%% Close the client's raw socket + receiver process on `terminate/3'.
%% `quic_socket:close(SocketState)' in the caller already closed the
%% OTP socket on the socket-backend path; here we only stop the
%% dedicated receiver. For gen_udp we still need to close the raw
%% `gen_udp:socket()' — nothing else owns it.
close_client_socket(#state{
    client_receiver = Receiver, cfg = #conn_cfg{client_socket_backend = socket}
}) ->
    quic_socket:stop_client_receiver(Receiver);
close_client_socket(#state{
    socket_state = SocketState, cfg = #conn_cfg{client_socket_backend = adapter}
}) ->
    case SocketState of
        undefined -> ok;
        _ -> quic_socket:close(SocketState)
    end;
close_client_socket(#state{socket = undefined}) ->
    ok;
close_client_socket(#state{socket = Socket}) ->
    try gen_udp:close(Socket) of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% Close a raw client socket handle (no `#state{}' available yet) based
%% on the `socket_backend' option. Used on init-failure rollback.
close_raw_client_socket(Opts, Socket) ->
    case maps:get(socket_backend, Opts, gen_udp) of
        socket ->
            try socket:close(Socket) of
                _ -> ok
            catch
                _:_ -> ok
            end;
        adapter ->
            %% Adapter holds its own callbacks; nothing native to close.
            ok;
        _ ->
            try gen_udp:close(Socket) of
                _ -> ok
            catch
                _:_ -> ok
            end
    end.

%% Flush any batched packets (call before timers or idle periods)
flush_socket_batch(#state{socket_state = SocketState} = State) ->
    case flushed_socket_state(SocketState) of
        %% Empty batch: the socket state is returned as is.
        SocketState -> State;
        NewSocketState -> State#state{socket_state = NewSocketState}
    end.

%% A receive pass only counts ack-eliciting packets; an ACK still owed at
%% its end gets the max_ack_delay timer here.
pass_ack_timer(#state{ack_elicited_count = 0, ack_timer = Timer}) -> Timer;
pass_ack_timer(#state{ack_timer = Timer}) -> ensure_ack_timer(Timer).

flushed_socket_state(undefined) ->
    undefined;
flushed_socket_state(SocketState) ->
    case quic_socket:flush(SocketState) of
        {ok, NewSocketState} -> NewSocketState;
        {error, _, ClearedSocketState} -> ClearedSocketState
    end.

%% End of an event, in one record update: flush the socket batch and the
%% deferred PTO reset (the idle and keep-alive timers are lazy, so the PTO
%% is the only deferred timer); `rearm' forces the PTO reset. After a
%% receive pass (`pass') the per-pass fields are cleared and an ACK still
%% owed gets its timer. Every event that may have drained the send
%% queue ends here, so it is also where a wanted send_ready goes out.
flush_event(#state{socket_state = SocketState0, pto_dirty = Dirty0} = State, Scope) ->
    SocketState = flushed_socket_state(SocketState0),
    Dirty = Dirty0 orelse Scope =:= rearm,
    State1 =
        case Dirty orelse Scope =:= pass orelse SocketState =/= SocketState0 of
            false ->
                State;
            true ->
                {Timer, ArmedAt, ScheduledAt, Space, Kind} =
                    case Dirty of
                        true ->
                            pto_plan(State);
                        false ->
                            #state{
                                pto_timer = T,
                                pto_armed_at = A,
                                pto_scheduled_at = D,
                                pto_space = Sp,
                                pto_kind = K
                            } = State,
                            {T, A, D, Sp, K}
                    end,
                {Source, RecvPass, AckTimer} =
                    case Scope of
                        pass ->
                            {undefined, false, pass_ack_timer(State)};
                        _ ->
                            {
                                State#state.current_packet_source,
                                State#state.recv_pass,
                                State#state.ack_timer
                            }
                    end,
                State#state{
                    socket_state = SocketState,
                    pto_timer = Timer,
                    pto_armed_at = ArmedAt,
                    pto_scheduled_at = ScheduledAt,
                    pto_space = Space,
                    pto_kind = Kind,
                    pto_dirty = false,
                    current_packet_source = Source,
                    recv_pass = RecvPass,
                    ack_timer = AckTimer
                }
        end,
    maybe_send_ready(State1).

%%====================================================================
%% ACK emission and decimation (RFC 9002 Section 6.2)
%%====================================================================

%% Send ACK if packet contained any ack-eliciting frames.
%%
%% For 1-RTT (`app') traffic the receiver delays ACKs per RFC 9002 §6.2
%% and RFC 9000 §13.2.1: send an ACK after every `?ACK_PACKET_TOLERANCE'
%% ack-eliciting packets, or after `max_ack_delay' ms (whichever comes
%% first). This roughly halves ACK traffic on bulk flows compared to
%% the previous "ACK every packet" policy. Handshake / Initial spaces
%% still ACK immediately (latency-sensitive, short exchange).
%%
%% Datagram-only packets (RFC 9221 §5.2) continue to take the existing
%% delayed-ACK path, which also sits on max_ack_delay.
maybe_send_ack(app, Frames, State) ->
    case quic_ack:contains_ack_eliciting_frames(Frames) of
        true ->
            case should_delay_ack(Frames) of
                true ->
                    %% Datagram-only packets: delay up to max_ack_delay.
                    schedule_delayed_ack(app, State);
                false ->
                    %% Normal stream / control traffic: ACK immediately when
                    %% the last received packet was reordered (RFC 9002 §6.2);
                    %% otherwise count-based decimation + max_ack_delay timer.
                    case State#state.last_recv_trigger of
                        reordered -> send_app_ack(State);
                        sequential -> maybe_decimate_app_ack(State)
                    end
            end;
        false ->
            State
    end;
maybe_send_ack(handshake, Frames, State) ->
    case quic_ack:contains_ack_eliciting_frames(Frames) of
        true -> send_handshake_ack(State);
        false -> State
    end;
maybe_send_ack(initial, Frames, State) ->
    case quic_ack:contains_ack_eliciting_frames(Frames) of
        true -> send_initial_ack(State);
        false -> State
    end;
maybe_send_ack(_, _, State) ->
    State.

%% Count-based 1-RTT ACK decimation.
%% When `?ACK_PACKET_TOLERANCE' ack-eliciting packets have been seen
%% since the last emitted ACK, flush immediately. Otherwise increment
%% the counter and arm a max_ack_delay timer (if not already armed).
maybe_decimate_app_ack(#state{recv_pass = true} = State) ->
    %% Inside a receive pass: only count; flush_recv_pass/1 flushes
    %% one ACK for the whole train and flush_event/2 arms the timer for a
    %% remainder.
    State#state{ack_elicited_count = State#state.ack_elicited_count + 1};
maybe_decimate_app_ack(State) ->
    NewCount = State#state.ack_elicited_count + 1,
    case NewCount >= (State#state.cfg)#conn_cfg.ack_packet_tolerance of
        true ->
            send_app_ack(State);
        false ->
            arm_ack_timer(State#state{ack_elicited_count = NewCount})
    end.

%% End of a connected-state receive pass: flush the accumulated stream
%% delivery, emit the deferred ACK (one per train) if enough
%% ack-eliciting packets accumulated. flush_event/2 then clears the pass
%% flag. Below-tolerance remainders keep their ack_timer. The delivery
%% flushes even when the pass initiated a close: the data arrived
%% before it.
flush_recv_pass(State0) ->
    State = flush_pending_delivery(State0),
    case State of
        #state{
            ack_elicited_count = Count,
            close_reason = undefined,
            cfg = #conn_cfg{ack_packet_tolerance = Tol}
        } when
            Count >= Tol
        ->
            send_app_ack(State, false);
        _ ->
            State
    end.

%% A boolean option: true only when set to exactly `true'.
bool_opt(Key, Opts) ->
    case maps:get(Key, Opts, false) of
        true -> true;
        _ -> false
    end.

%%====================================================================
%% Delivery to the owner process
%%====================================================================

%% Hand stream data to the owner. With delivery coalescing on and a
%% receive pass active, consecutive deliveries for the same stream
%% merge into one pending message, flushed at the end of the pass or
%% as soon as another stream delivers (exact arrival order is kept:
%% only adjacent chunks of one stream merge). Otherwise one message
%% per delivery, as before. Returns the new pend_deliver.
deliver_stream_data(
    StreamId,
    Data,
    Fin,
    #state{recv_pass = true, cfg = #conn_cfg{delivery_coalescing = true}} = State
) ->
    case State#state.pend_deliver of
        {StreamId, Acc, F} ->
            {StreamId, [Data | Acc], F orelse Fin};
        none ->
            {StreamId, [Data], Fin};
        {OtherId, Acc, F} ->
            State#state.owner ! {quic, self(), {stream_data, OtherId, run_binary(Acc), F}},
            {StreamId, [Data], Fin}
    end;
deliver_stream_data(StreamId, Data, Fin, State) ->
    State#state.owner ! {quic, self(), {stream_data, StreamId, Data, Fin}},
    State#state.pend_deliver.

run_binary([Single]) -> Single;
run_binary(RevChunks) -> iolist_to_binary(lists:reverse(RevChunks)).

flush_pending_delivery(#state{pend_deliver = none} = State) ->
    State;
flush_pending_delivery(#state{pend_deliver = {StreamId, Acc, Fin}, owner = Owner} = State) ->
    Owner ! {quic, self(), {stream_data, StreamId, run_binary(Acc), Fin}},
    State#state{pend_deliver = none}.

%% Arm the max_ack_delay timer if not already armed.
%% The delay is our own advertised maximum, not the peer's: `transport_params'
%% holds what the peer sent (RFC 9000 Section 18.2).
arm_ack_timer(#state{ack_timer = Ref} = State) when Ref =/= undefined ->
    State;
arm_ack_timer(#state{ack_timer = undefined} = State) ->
    State#state{ack_timer = ensure_ack_timer(undefined)}.

%% The armed ACK timer, arming one if there is none. A start_timer
%% reference is also the timer handle, so cancel_timer/1 stops it and a
%% piggybacked ACK leaves no stale timeout behind.
ensure_ack_timer(undefined) ->
    erlang:start_timer(?DEFAULT_MAX_ACK_DELAY, self(), send_delayed_ack);
ensure_ack_timer(Ref) ->
    Ref.

%%====================================================================
%% Frame classification for ACK policy
%%====================================================================

%% Per RFC 9221 Section 5.2: Delay ACKs for packets containing only
%% non-retransmittable ack-eliciting frames (like DATAGRAM).
should_delay_ack([{stream, _, _, _, _} | _]) ->
    %% Hot path: a stream frame is ack-eliciting and retransmittable,
    %% so the packet never qualifies for the datagram-only delay.
    false;
should_delay_ack(Frames) ->
    AckEliciting = [F || F <- Frames, quic_ack:is_ack_eliciting_frame(F)],
    Retransmittable = quic_loss:retransmittable_frames(AckEliciting),
    %% If all ack-eliciting frames are non-retransmittable, delay ACK
    Retransmittable =:= [].

%% Schedule a delayed ACK (datagram-only path; RFC 9221 §5.2).
%% Shares the same ack_timer field with the count-based decimation
%% path so both end at the next max_ack_delay fire.
schedule_delayed_ack(app, State) ->
    arm_ack_timer(State).

%% Process ECN counts from ACK frame (RFC 9002 Section 7.1)
%% ECN-CE indicates network congestion experienced
process_ecn_counts(undefined, CCState) ->
    %% No ECN information in this ACK
    CCState;
process_ecn_counts({_ECT0, _ECT1, ECNCE}, CCState) ->
    %% RFC 9002: An increase in ECN-CE count triggers congestion response
    quic_cc:on_ecn_ce(CCState, ECNCE).

%% @doc The congestion-control consequences of declaring packets lost,
%% in the order both the ACK path and the loss-detection timer apply
%% them. ECN counts ride along because on an ACK they land between the
%% congestion event and the persistent-congestion check, and
%% `on_congestion_event/2' is guarded on the recovery period, so the
%% order of the two is observable. A timer-driven loss has no ACK and
%% passes `undefined', which process_ecn_counts/2 treats as a no-op.
-spec cc_after_loss(
    quic_cc:cc_state(),
    non_neg_integer(),
    non_neg_integer() | undefined,
    term(),
    [#sent_packet{}],
    quic_loss:loss_state()
) -> quic_cc:cc_state().
cc_after_loss(CCState, LostBytes, LargestLostSentTime, ECN, LostPackets, LossState) ->
    CC1 = quic_cc:on_packets_lost(CCState, LostBytes),
    CC2 =
        case LargestLostSentTime of
            undefined -> CC1;
            _ -> quic_cc:on_congestion_event(CC1, LargestLostSentTime)
        end,
    CC3 = process_ecn_counts(ECN, CC2),
    check_persistent_congestion(LostPackets, LossState, CC3).

%% Check for persistent congestion (RFC 9002 Section 7.6)
%% If lost packets span more than PTO * 3, reset to minimum window
check_persistent_congestion([], _LossState, CCState) ->
    CCState;
check_persistent_congestion(LostPackets, LossState, CCState) ->
    %% Extract packet number and time sent from lost packets
    LostInfo = [{P#sent_packet.pn, P#sent_packet.time_sent} || P <- LostPackets],
    PTO = quic_loss:persistent_congestion_pto(LossState),
    case quic_cc:detect_persistent_congestion(LostInfo, PTO, CCState) of
        true ->
            quic_cc:on_persistent_congestion(CCState);
        false ->
            CCState
    end.

%% Generate a connection ID
%% Uses LB config if available, otherwise random 8 bytes
generate_connection_id() ->
    crypto:strong_rand_bytes(8).

generate_connection_id(undefined) ->
    crypto:strong_rand_bytes(8);
generate_connection_id(#cid_config{} = Config) ->
    quic_lb:generate_cid(Config).

%% Resolve a host to a single {IP, Port}. `Family' (inet | inet6 | any) sets the
%% lookup order; `any' is IPv4-first then IPv6 for backward compatibility.
%% Multi-address Happy Eyeballs lives in quic_happy; this resolves one address.
-spec resolve_address(
    inet:ip_address() | binary() | string(), inet:port_number(), inet | inet6 | any
) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
resolve_address(Host, Port, _Family) when is_tuple(Host) ->
    {ok, {Host, Port}};
resolve_address(Host, Port, Family) when is_binary(Host) ->
    resolve_address(binary_to_list(Host), Port, Family);
resolve_address(Host, Port, Family) when is_list(Host) ->
    Stripped = strip_brackets(Host),
    case inet:parse_address(Stripped) of
        {ok, IP} ->
            {ok, {IP, Port}};
        {error, _} ->
            case getaddr_family(Stripped, Family) of
                {ok, IP} -> {ok, {IP, Port}};
                {error, _} = Error -> Error
            end
    end.

%% Family-ordered name resolution. `any' tries IPv4 then IPv6.
getaddr_family(Host, inet) ->
    inet:getaddr(Host, inet);
getaddr_family(Host, inet6) ->
    inet:getaddr(Host, inet6);
getaddr_family(Host, any) ->
    case inet:getaddr(Host, inet) of
        {ok, _} = Ok -> Ok;
        {error, _} -> inet:getaddr(Host, inet6)
    end.

%% Drop a single pair of surrounding brackets from an IPv6 literal ("[::1]").
strip_brackets([$[ | Rest]) ->
    case lists:reverse(Rest) of
        [$] | RevInner] -> lists:reverse(RevInner);
        _ -> [$[ | Rest]
    end;
strip_brackets(Host) ->
    Host.

%% Derive initial encryption keys with specific QUIC version
%% Version determines which salt to use (v1 vs v2)
%% RFC 9368: adopt the best mutually acceptable version offered by the
%% client. v1 and v2 are compatible with each other (RFC 9369 §6).
maybe_negotiate_compatible_version(_TP, true, State) ->
    State;
maybe_negotiate_compatible_version(TP, false, State) ->
    case maps:get(version_information, TP, undefined) of
        {_Chosen, Available} when is_list(Available) ->
            Mutual = [
                V
             || V <- (State#state.cfg)#conn_cfg.supported_versions,
                lists:member(V, Available)
            ],
            case Mutual of
                [Best | _] when Best =/= State#state.version ->
                    switch_version(Best, State);
                _ ->
                    State
            end;
        _ ->
            State
    end.

%% Move the connection to another compatible version mid-handshake. The
%% Initial keys are version-specific, so re-derive them from the
%% original DCID for our own sends, keeping the old set so in-flight
%% packets in the previous version still decrypt.
switch_version(NewVersion, State) ->
    ?LOG_INFO(
        #{
            what => compatible_version_negotiation,
            from => State#state.version,
            to => NewVersion
        },
        ?QUIC_LOG_META
    ),
    OldVersion = State#state.version,
    NewKeys = derive_initial_keys((State#state.cfg)#conn_cfg.original_dcid, NewVersion),
    State#state{
        version = NewVersion,
        hs = (State#state.hs)#hs{
            initial_keys = NewKeys,
            initial_keys_alt = {OldVersion, (State#state.hs)#hs.initial_keys}
        }
    }.

%% Initial keys matching a received packet's version: through a
%% compatible version switch the peer's first flight is still protected
%% with the pre-switch version's keys.
initial_keys_for_version(V, #state{version = V, hs = #hs{initial_keys = Keys}}) ->
    Keys;
initial_keys_for_version(V, #state{hs = #hs{initial_keys_alt = {V, Keys}}}) ->
    Keys;
initial_keys_for_version(_, #state{hs = #hs{initial_keys = Keys}}) ->
    Keys.

derive_initial_keys(DCID, Version) ->
    {ClientKey, ClientIV, ClientHP} = quic_keys:derive_initial_client(DCID, Version),
    {ServerKey, ServerIV, ServerHP} = quic_keys:derive_initial_server(DCID, Version),
    ClientKeys = #crypto_keys{
        key = ClientKey,
        iv = ClientIV,
        hp = ClientHP,
        cipher = aes_128_gcm
    },
    ServerKeys = #crypto_keys{
        key = ServerKey,
        iv = ServerIV,
        hp = ServerHP,
        cipher = aes_128_gcm
    },
    {ClientKeys, ServerKeys}.

%% Pick the client's CertificateVerify scheme for mTLS: intersect the
%% server's advertised schemes with the client key's schemes, falling
%% back to the key's natural scheme when the server offered none.
client_cert_verify_code(#state{
    cfg = #conn_cfg{client_private_key = Key}, hs = #hs{peer_sig_algs = Offered}
}) ->
    case Offered of
        [] ->
            select_signature_algorithm(Key);
        _ ->
            case select_signature_algorithm(Key, undefined, Offered) of
                error -> select_signature_algorithm(Key);
                Code -> Code
            end
    end.

%% Build a CertificateRequest advertising the server's configured
%% signature schemes (defaults when none set).
build_cert_request(#state{cfg = #conn_cfg{tls_sig_algs = undefined}}) ->
    quic_tls:build_certificate_request(<<>>);
build_cert_request(#state{cfg = #conn_cfg{tls_sig_algs = SigAlgs}}) ->
    quic_tls:build_certificate_request(<<>>, SigAlgs).

%% Select signature algorithm based on private key type (mTLS client
%% path, no negotiation; picks the key's natural scheme).
select_signature_algorithm(PrivateKey) ->
    hd(compatible_sig_schemes_codes(PrivateKey) ++ [?SIG_RSA_PSS_RSAE_SHA256]).

%% CertificateVerify scheme negotiation (RFC 8446 §4.4.3). Intersects
%% the schemes the private key can produce (server preference order,
%% optionally narrowed by `signature_algs') with the peer's offered
%% list. `rsa_pkcs1_*` is never selected for CertificateVerify.
%% Returns the wire code, or `error' when there is no common scheme.
select_signature_algorithm(PrivateKey, ServerSigAlgs, ClientOfferedCodes) ->
    KeyCodes = compatible_sig_schemes_codes(PrivateKey),
    Allowed =
        case ServerSigAlgs of
            undefined -> KeyCodes;
            Atoms -> [C || C <- KeyCodes, lists:member(code_to_sig_alg(C), Atoms)]
        end,
    case [C || C <- Allowed, lists:member(C, ClientOfferedCodes)] of
        [Code | _] -> Code;
        [] -> error
    end.

%% Wire codes the given private key can sign CertificateVerify with,
%% in preference order. Excludes rsa_pkcs1_* (RFC 8446 §4.4.3).
%% Ed25519 decodes to an ECPrivateKey tuple carrying OID 1.3.101.112;
%% match it before the generic EC clauses.
compatible_sig_schemes_codes({'ECPrivateKey', _, _, {namedCurve, {1, 3, 101, 112}}, _, _}) ->
    [?SIG_ED25519];
compatible_sig_schemes_codes(
    {'ECPrivateKey', _, _, {namedCurve, {1, 2, 840, 10045, 3, 1, 7}}, _, _}
) ->
    [?SIG_ECDSA_SECP256R1_SHA256];
compatible_sig_schemes_codes({'ECPrivateKey', _, _, {namedCurve, {1, 3, 132, 0, 34}}, _, _}) ->
    [?SIG_ECDSA_SECP384R1_SHA384];
compatible_sig_schemes_codes({'ECPrivateKey', _, _, _, _, _}) ->
    [?SIG_ECDSA_SECP256R1_SHA256];
compatible_sig_schemes_codes({'RSAPrivateKey', _, _, _, _, _, _, _, _, _, _}) ->
    [?SIG_RSA_PSS_RSAE_SHA256, ?SIG_RSA_PSS_RSAE_SHA384, ?SIG_RSA_PSS_RSAE_SHA512];
compatible_sig_schemes_codes(Key) ->
    case is_ed25519_key(Key) of
        true -> [?SIG_ED25519];
        false -> [?SIG_RSA_PSS_RSAE_SHA256]
    end.

%% Recognise an Ed25519 private key across the OTP representations
%% (tagged tuple, or an ECPrivateKey tuple carrying the Ed25519 OID
%% 1.3.101.112). Tuple form avoids depending on the public_key hrl.
is_ed25519_key({ed_pri, ed25519, _Pub, _Priv}) -> true;
is_ed25519_key({'ECPrivateKey', _, _, {namedCurve, {1, 3, 101, 112}}, _, _}) -> true;
is_ed25519_key(_) -> false.

%% Map a signature-scheme wire code to its atom.
code_to_sig_alg(?SIG_ECDSA_SECP256R1_SHA256) -> ecdsa_secp256r1_sha256;
code_to_sig_alg(?SIG_ECDSA_SECP384R1_SHA384) -> ecdsa_secp384r1_sha384;
code_to_sig_alg(?SIG_RSA_PSS_RSAE_SHA256) -> rsa_pss_rsae_sha256;
code_to_sig_alg(?SIG_RSA_PSS_RSAE_SHA384) -> rsa_pss_rsae_sha384;
code_to_sig_alg(?SIG_RSA_PSS_RSAE_SHA512) -> rsa_pss_rsae_sha512;
code_to_sig_alg(?SIG_ED25519) -> ed25519;
code_to_sig_alg(?SIG_RSA_PKCS1_SHA256) -> rsa_pkcs1_sha256;
code_to_sig_alg(_) -> unknown.

%% Check if we should transition to a new state
check_state_transition(CurrentState, State) ->
    %% First check if connection should be closing (CONNECTION_CLOSE received)
    case State#state.close_reason of
        {peer_closed, _, _, _} ->
            %% Peer sent APPLICATION CONNECTION_CLOSE, transition to draining
            emit_qlog_state_change(CurrentState, draining, State),
            {next_state, draining, State};
        {peer_closed, _, _, _, _} ->
            %% Peer sent TRANSPORT CONNECTION_CLOSE, transition to draining
            emit_qlog_state_change(CurrentState, draining, State),
            {next_state, draining, State};
        connection_closed ->
            %% Legacy: Peer sent CONNECTION_CLOSE, transition to draining
            emit_qlog_state_change(CurrentState, draining, State),
            {next_state, draining, State};
        stateless_reset ->
            %% Received stateless reset, transition to draining
            emit_qlog_state_change(CurrentState, draining, State),
            {next_state, draining, State};
        {version_negotiation, _} ->
            %% No mutually supported version (RFC 9000 §6.2); give up.
            emit_qlog_state_change(CurrentState, draining, State),
            {next_state, draining, State};
        {transport, _Code, _Reason} ->
            %% We sent a transport-level CONNECTION_CLOSE; enter draining.
            emit_qlog_state_change(CurrentState, draining, State),
            {next_state, draining, State};
        {application, _Code, _Reason} ->
            %% We sent an application-level CONNECTION_CLOSE; enter draining.
            emit_qlog_state_change(CurrentState, draining, State),
            {next_state, draining, State};
        _ ->
            %% Check for TLS handshake state transitions
            case {CurrentState, (State#state.hs)#hs.tls_state, has_app_keys(State)} of
                {idle, ?TLS_AWAITING_ENCRYPTED_EXT, _} ->
                    %% Got ServerHello, have handshake keys
                    emit_qlog_state_change(idle, handshaking, State),
                    {next_state, handshaking, State};
                {idle, ?TLS_AWAITING_CERT, _} ->
                    emit_qlog_state_change(idle, handshaking, State),
                    {next_state, handshaking, State};
                {idle, ?TLS_AWAITING_CERT_VERIFY, _} ->
                    emit_qlog_state_change(idle, handshaking, State),
                    {next_state, handshaking, State};
                {idle, ?TLS_AWAITING_FINISHED, _} ->
                    emit_qlog_state_change(idle, handshaking, State),
                    {next_state, handshaking, State};
                {idle, ?TLS_HANDSHAKE_COMPLETE, true} ->
                    emit_qlog_state_change(idle, connected, State),
                    {next_state, connected, State};
                {handshaking, ?TLS_HANDSHAKE_COMPLETE, true} ->
                    emit_qlog_state_change(handshaking, connected, State),
                    {next_state, connected, State};
                _ ->
                    {keep_state, State}
            end
    end.

%% Helper to emit qlog connection_state_updated event
emit_qlog_state_change(OldState, NewState, #state{cfg = #conn_cfg{qlog_ctx = Ctx}}) ->
    quic_qlog:connection_state_updated(Ctx, OldState, NewState).

%% Convert close reason to error code for qlog
close_reason_to_code(connection_closed) -> 0;
close_reason_to_code(stateless_reset) -> stateless_reset;
close_reason_to_code(idle_timeout) -> idle_timeout;
close_reason_to_code(normal) -> 0;
close_reason_to_code({app_error, Code, _}) when is_integer(Code) -> Code;
close_reason_to_code({peer_closed, application, Code, _}) when is_integer(Code) -> Code;
close_reason_to_code({peer_closed, transport, Code, _, _}) when is_integer(Code) -> Code;
close_reason_to_code({error, Code}) when is_integer(Code) -> Code;
close_reason_to_code({error, application_error}) -> ?QUIC_APPLICATION_ERROR;
close_reason_to_code({application_error, Code, _}) when is_integer(Code) -> Code;
close_reason_to_code({transport, Code, _}) when is_integer(Code) -> Code;
close_reason_to_code({application, Code, _}) when is_integer(Code) -> Code;
close_reason_to_code(Reason) when is_atom(Reason) -> Reason;
close_reason_to_code(_) -> unknown.

has_app_keys(#state{app_keys = undefined}) -> false;
has_app_keys(_) -> true.

%% Record a received packet number for ACK generation.
%% For the 1-RTT (`app') space we also classify whether the PN is
%% sequential (= largest_recv + 1 or the very first packet) or
%% reordered, and stash that on `last_recv_trigger' so the subsequent
%% `maybe_send_ack(app, ...)' can honour RFC 9002 §6.2's recommendation
%% to ACK reordered packets immediately instead of delaying.
%% Single `monotonic_time/1' sample supplied by the caller covers
%% both `recv_time' (below) and the immediately-following
%% `last_activity' write, saving one BIF call per received packet.
record_received_pn(initial, PN, State, Now) ->
    PNSpace = (State#state.hs)#hs.pn_initial,
    NewPNSpace = quic_ack:update_pn_space_recv(PN, PNSpace, Now),
    State#state{hs = (State#state.hs)#hs{pn_initial = NewPNSpace}};
record_received_pn(handshake, PN, State, Now) ->
    PNSpace = (State#state.hs)#hs.pn_handshake,
    NewPNSpace = quic_ack:update_pn_space_recv(PN, PNSpace, Now),
    State#state{hs = (State#state.hs)#hs{pn_handshake = NewPNSpace}};
record_received_pn(app, PN, State, Now) ->
    PNSpace = State#state.pn_app,
    Trigger = classify_recv_trigger(PN, PNSpace),
    NewPNSpace = quic_ack:update_pn_space_recv(PN, PNSpace, Now),
    State#state{pn_app = NewPNSpace, last_recv_trigger = Trigger};
record_received_pn(zero_rtt, PN, State, Now) ->
    %% 0-RTT uses the same PN space as 1-RTT (app)
    PNSpace = State#state.pn_app,
    Trigger = classify_recv_trigger(PN, PNSpace),
    NewPNSpace = quic_ack:update_pn_space_recv(PN, PNSpace, Now),
    State#state{pn_app = NewPNSpace, last_recv_trigger = Trigger};
record_received_pn(_, _PN, State, _Now) ->
    State.

%% Classify a received PN as sequential (monotonic continuation of the
%% largest received) or reordered (gap above, or filling a gap below).
%% Duplicates (PN =:= largest_recv) are treated as reordered so a
%% duplicate in the middle of a flow still forces an immediate ACK;
%% the duplicate itself is filtered elsewhere.
classify_recv_trigger(_PN, #pn_space{largest_recv = undefined}) ->
    sequential;
classify_recv_trigger(PN, #pn_space{largest_recv = L}) when PN =:= L + 1 ->
    sequential;
classify_recv_trigger(_PN, _PNSpace) ->
    reordered.

%% Get largest received PN for a given encryption level
get_largest_recv(initial, State) ->
    ((State#state.hs)#hs.pn_initial)#pn_space.largest_recv;
get_largest_recv(handshake, State) ->
    ((State#state.hs)#hs.pn_handshake)#pn_space.largest_recv;
get_largest_recv(app, State) ->
    (State#state.pn_app)#pn_space.largest_recv;
get_largest_recv(zero_rtt, State) ->
    %% 0-RTT uses the same PN space as 1-RTT (app)
    (State#state.pn_app)#pn_space.largest_recv.

%% Record activity. The idle and keep-alive timers read last_activity at
%% fire time (lazy model), so no timer op is needed per packet.
update_last_activity(State) ->
    update_last_activity(State, erlang:monotonic_time(millisecond)).

%% Now-accepting variant used by the receive hot path. Clears
%% ack_eliciting_since_recv so the next ack-eliciting send restarts the idle
%% timer (RFC 9000 §10.1).
update_last_activity(State, Now) ->
    State#state{last_activity = Now, ack_eliciting_since_recv = false}.

maybe_send_ready(#state{send_ready_wanted = true, send_queue_bytes = Bytes} = State) when
    Bytes < ?MAX_SEND_QUEUE_BYTES div 2
->
    State#state.owner ! {quic, self(), send_ready},
    State#state{send_ready_wanted = false};
maybe_send_ready(State) ->
    State.

%% Reclaim a stream once every direction that applies to it is terminal.
%% Removes the #stream_state{} from the connection map, records the id in the
%% reclaimed-range tracker (so a late/retransmitted frame is not mistaken for a
%% new stream, RFC 9000 §2.1), and for a peer-initiated stream extends the
%% MAX_STREAMS credit by one (RFC 9000 §4.6). Runs at most once per stream:
%% later calls miss the map and no-op, so crediting is exactly-once.
maybe_reclaim_stream(StreamId, #state{streams = Streams, cfg = #conn_cfg{role = Role}} = State) ->
    case maps:find(StreamId, Streams) of
        error ->
            State;
        {ok, Stream} ->
            case stream_reclaimable(StreamId, Role, Stream) of
                false ->
                    State;
                true ->
                    cancel_stream_deadline_timer(Stream),
                    State1 = State#state{streams = maps:remove(StreamId, Streams)},
                    State2 = record_reclaimed(StreamId, Role, State1),
                    credit_peer_on_reclaim(StreamId, Role, State2)
            end
    end.

%% A stream may be reclaimed once the direction(s) that apply to it are terminal.
%% A RESET_STREAM_AT obligation folds into send_done/recv_done (set once the
%% reliable bytes are acked / delivered), so it needs no special case here.
stream_reclaimable(StreamId, Role, Stream) ->
    case stream_class(StreamId, Role) of
        {bidi, _} -> Stream#stream_state.send_done andalso Stream#stream_state.recv_done;
        {uni, local} -> Stream#stream_state.send_done;
        {uni, peer} -> Stream#stream_state.recv_done
    end.

%% {Direction, Initiator} from the two low stream-id bits (RFC 9000 §2.1):
%%   bit 0 = initiator (0 client, 1 server), bit 1 = direction (0 bidi, 1 uni).
stream_class(StreamId, Role) ->
    Dir =
        case (StreamId band 2) =/= 0 of
            true -> uni;
            false -> bidi
        end,
    Init =
        case stream_locally_initiated(StreamId, Role) of
            true -> local;
            false -> peer
        end,
    {Dir, Init}.

stream_locally_initiated(StreamId, Role) ->
    Initiator = StreamId band 1,
    case Role of
        client -> Initiator =:= 0;
        server -> Initiator =:= 1
    end.

%% Flow-control limit key for a peer-created stream, by direction.
peer_stream_kind(StreamId) ->
    case (StreamId band 2) =/= 0 of
        true -> uni_peer_initiated;
        false -> bidi_peer_initiated
    end.

credit_peer_on_reclaim(StreamId, Role, State) ->
    case stream_class(StreamId, Role) of
        {bidi, peer} ->
            N = State#state.max_streams_bidi_local + 1,
            send_frame({max_streams, bidi, N}, State#state{max_streams_bidi_local = N});
        {uni, peer} ->
            N = State#state.max_streams_uni_local + 1,
            send_frame({max_streams, uni, N}, State#state{max_streams_uni_local = N});
        _ ->
            State
    end.

cancel_stream_deadline_timer(#stream_state{deadline_timer = undefined}) ->
    ok;
cancel_stream_deadline_timer(#stream_state{deadline_timer = Timer}) ->
    _ = erlang:cancel_timer(Timer),
    ok.

%% Drop any queued STREAM frames for a stream and adjust the queue counters, so
%% nothing buffered is emitted after a local RESET_STREAM.
purge_stream_send_queue(StreamId, State) ->
    {NewQueue, RemovedBytes, RemovedCount} =
        remove_stream_from_queue(StreamId, State#state.send_queue),
    State#state{
        send_queue = NewQueue,
        send_queue_bytes = max(0, State#state.send_queue_bytes - RemovedBytes),
        send_queue_count = max(0, State#state.send_queue_count - RemovedCount)
    }.

%%====================================================================
%% Reclaimed-stream tracking (RFC 9000 §2.1: stream ids never reused)
%%====================================================================

%% Record a reclaimed stream as a normalised index (StreamId bsr 2) in the
%% per-class disjoint interval list, so a frame for an already-reclaimed stream
%% can be told apart from a genuinely new one without per-stream state.
record_reclaimed(StreamId, Role, State) ->
    {Dir, Init} = stream_class(StreamId, Role),
    Map0 = reclaimed_map(Dir, State),
    Ranges0 = maps:get(Init, Map0, []),
    Ranges1 = quic_interval:add(StreamId bsr 2, Ranges0),
    set_reclaimed_map(Dir, maps:put(Init, Ranges1, Map0), State).

stream_reclaimed(StreamId, Role, State) ->
    {Dir, Init} = stream_class(StreamId, Role),
    quic_interval:member(StreamId bsr 2, maps:get(Init, reclaimed_map(Dir, State), [])).

%% True when a frame's stream is not in the map but was already reclaimed: a
%% late/retransmitted frame that must be ignored rather than recreate the stream
%% (RFC 9000 §2.1: ids are never reused). Used by every open-on-miss handler.
is_reclaimed_frame(StreamId, #state{streams = Streams, cfg = #conn_cfg{role = Role}} = State) ->
    (not is_map_key(StreamId, Streams)) andalso stream_reclaimed(StreamId, Role, State).

reclaimed_map(bidi, State) -> State#state.reclaimed_ranges_bidi;
reclaimed_map(uni, State) -> State#state.reclaimed_ranges_uni.

set_reclaimed_map(bidi, M, State) -> State#state{reclaimed_ranges_bidi = M};
set_reclaimed_map(uni, M, State) -> State#state{reclaimed_ranges_uni = M}.

%% Open a new stream
%% Stream ID patterns: Bit 0=initiator (0=client, 1=server), Bit 1=type (0=bidi, 1=uni)
%% Client bidi=0x00, Server bidi=0x01, Client uni=0x02, Server uni=0x03
do_open_stream(
    #state{
        next_stream_id_bidi = NextId,
        max_streams_bidi_remote = Max,
        streams = Streams,
        cfg = #conn_cfg{
            role = Role
        }
    } = State
) ->
    %% RFC 9000 §4.6: Check cumulative stream count against peer's limit.
    LocalPattern =
        case Role of
            % Client-initiated bidi = 0x00
            client -> 0;
            % Server-initiated bidi = 0x01
            server -> 1
        end,
    StreamIndex = (NextId - LocalPattern) div 4,
    if
        StreamIndex >= Max ->
            {error, stream_limit};
        true ->
            %% Get peer's limit for streams WE initiate (bidi_remote from their perspective)
            SendMaxData = get_peer_stream_limit(bidi_local_initiated, State),
            RecvMaxData = get_local_recv_limit(bidi_local_initiated, State),
            ?LOG_DEBUG(
                #{
                    what => stream_created_local_initiated,
                    stream_id => NextId,
                    send_max_data => SendMaxData,
                    recv_max_data => RecvMaxData
                },
                ?QUIC_LOG_META
            ),
            StreamState = #stream_state{
                id = NextId,
                state = open,
                send_offset = 0,
                send_max_data = SendMaxData,
                send_fin = false,
                send_buffer = [],
                recv_offset = 0,
                recv_max_data = RecvMaxData,
                recv_fin = false,
                recv_buffer = gb_trees:empty(),
                final_size = undefined
            },
            NewState = State#state{
                next_stream_id_bidi = NextId + 4,
                streams = maps:put(NextId, StreamState, Streams)
            },
            {ok, NextId, NewState}
    end.

%% Open a new unidirectional stream
do_open_unidirectional_stream(
    #state{
        next_stream_id_uni = NextId,
        max_streams_uni_remote = Max,
        streams = Streams,
        cfg = #conn_cfg{
            role = Role
        }
    } = State
) ->
    %% RFC 9000 §4.6: MAX_STREAMS value of N permits opening streams with IDs
    %% less than 4*N + stream_type_offset. Check against NextId (cumulative count
    %% of streams opened) rather than current map size, since completed streams
    %% remain in the map but should not block opening new ones once the peer
    %% has increased the limit via MAX_STREAMS frames.
    LocalPattern =
        case Role of
            % Client-initiated uni = 0x02
            client -> 2;
            % Server-initiated uni = 0x03
            server -> 3
        end,
    StreamIndex = (NextId - LocalPattern) div 4,
    if
        StreamIndex >= Max ->
            {error, stream_limit};
        true ->
            %% Unidirectional streams are send-only for the initiator
            %% Get peer's limit for uni streams we initiate
            SendMaxData = get_peer_stream_limit(uni_local_initiated, State),
            StreamState = #stream_state{
                id = NextId,
                state = open,
                send_offset = 0,
                send_max_data = SendMaxData,
                send_fin = false,
                send_buffer = [],
                recv_offset = 0,
                % We don't receive on our uni streams
                recv_max_data = 0,
                % No incoming data expected
                recv_fin = true,
                recv_buffer = gb_trees:empty(),
                final_size = undefined
            },
            NewState = State#state{
                next_stream_id_uni = NextId + 4,
                streams = maps:put(NextId, StreamState, Streams)
            },
            {ok, NextId, NewState}
    end.

%% Default max stream data per packet (leave room for headers, frame overhead, AEAD tag)
%% Used when PMTU discovery is disabled or not yet complete
%% 1200 (min MTU for QUIC) - ~100 bytes overhead = 1100 bytes
-define(DEFAULT_MAX_STREAM_DATA_PER_PACKET, 1100).

%% Packet overhead: short header (1 + DCID ~8) + PN (1-4) + frame header (~10) + AEAD tag (16)
-define(STREAM_PACKET_OVERHEAD, 100).

%% @doc Calculate max stream data per packet based on current PMTU.
-spec get_max_stream_data_per_packet(#state{}) -> pos_integer().
get_max_stream_data_per_packet(#state{pmtu_state = undefined}) ->
    ?DEFAULT_MAX_STREAM_DATA_PER_PACKET;
get_max_stream_data_per_packet(#state{pmtu_state = PMTUState}) ->
    MTU = quic_pmtu:current_mtu(PMTUState),
    max(MTU - ?STREAM_PACKET_OVERHEAD, ?DEFAULT_MAX_STREAM_DATA_PER_PACKET).

%% @doc Get the peer's stream data limit for a given stream type.
%% RFC 9000 Section 4.1: Each endpoint independently sets flow control limits.
%% - bidi_local_initiated: Bidi stream we opened, use peer's initial_max_stream_data_bidi_remote
%% - bidi_peer_initiated: Bidi stream peer opened, use peer's initial_max_stream_data_bidi_local
%% - uni_local_initiated: Uni stream we opened, use peer's initial_max_stream_data_uni
get_peer_stream_limit(StreamType, #state{transport_params = TP}) ->
    Result =
        case StreamType of
            bidi_local_initiated ->
                maps:get(
                    peer_max_stream_data_bidi_remote,
                    TP,
                    maps:get(
                        initial_max_stream_data_bidi_remote, TP, ?DEFAULT_INITIAL_MAX_STREAM_DATA
                    )
                );
            bidi_peer_initiated ->
                maps:get(
                    peer_max_stream_data_bidi_local,
                    TP,
                    maps:get(
                        initial_max_stream_data_bidi_local, TP, ?DEFAULT_INITIAL_MAX_STREAM_DATA
                    )
                );
            uni_local_initiated ->
                maps:get(
                    peer_max_stream_data_uni,
                    TP,
                    maps:get(initial_max_stream_data_uni, TP, ?DEFAULT_INITIAL_MAX_STREAM_DATA)
                )
        end,
    ?LOG_DEBUG(
        #{
            what => get_peer_stream_limit,
            stream_type => StreamType,
            result => Result,
            tp_keys => maps:keys(TP)
        },
        ?QUIC_LOG_META
    ),
    Result.

%% Get our local receive limit for a stream (what we advertised to peer).
%% RFC 9000 Section 18.2: initial_max_stream_data_bidi_local covers the
%% streams opened by the endpoint that sends it, bidi_remote those its
%% peer opens.
%% - bidi_local_initiated: Bidi stream we opened, use our max_stream_data_bidi_local
%% - bidi_peer_initiated: Bidi stream peer opened, use our max_stream_data_bidi_remote
%% - uni_peer_initiated: Uni stream peer opened, use our max_stream_data_uni
get_local_recv_limit(StreamType, #state{
    cfg = #conn_cfg{
        max_stream_data_bidi_local = BidiLocal,
        max_stream_data_bidi_remote = BidiRemote,
        max_stream_data_uni = Uni
    }
}) ->
    case StreamType of
        bidi_local_initiated -> BidiLocal;
        bidi_peer_initiated -> BidiRemote;
        uni_peer_initiated -> Uni
    end.

%% @doc Check if stream is locally or peer initiated.
%% RFC 9000 Section 2.1: Stream ID format determines initiator and type.
%% Bit 0: 0=client-initiated, 1=server-initiated
%% Bit 1: 0=bidirectional, 1=unidirectional
is_locally_initiated(StreamId, #state{cfg = #conn_cfg{role = Role}}) ->
    ClientInitiated = (StreamId band 1) =:= 0,
    case Role of
        client -> ClientInitiated;
        server -> not ClientInitiated
    end.

%% @doc Check if stream is unidirectional.
is_unidirectional(StreamId) ->
    (StreamId band 2) =/= 0.

%% @doc RFC 9000 §4.6: a peer-initiated stream whose number is at or
%% beyond the limit we advertised is a STREAM_LIMIT_ERROR. Our own
%% streams are governed by the peer's MAX_STREAMS (checked on send), so
%% they are never flagged here.
exceeds_stream_limit(StreamId, State) ->
    case is_locally_initiated(StreamId, State) of
        true ->
            false;
        false ->
            Limit =
                case is_unidirectional(StreamId) of
                    true -> State#state.max_streams_uni_local;
                    false -> State#state.max_streams_bidi_local
                end,
            (StreamId bsr 2) >= Limit
    end.

stream_limit_close(State) ->
    ?LOG_WARNING(#{what => stream_limit_exceeded}, ?QUIC_LOG_META),
    close_with_transport_error(
        ?QUIC_STREAM_LIMIT_ERROR, <<"stream limit exceeded">>, State
    ).

%% @doc Validate stream direction for sending.
%% RFC 9000 Section 2.1: Cannot send on peer's unidirectional streams.
can_send_on_stream(StreamId, State) ->
    case is_unidirectional(StreamId) of
        false ->
            %% Bidirectional - can always send
            true;
        true ->
            %% Unidirectional - can only send if we initiated it
            is_locally_initiated(StreamId, State)
    end.

%%====================================================================
%% Send path
%%
%% An application write starts here and ends at the socket. This region
%% previously sat under the reclaimed-stream banner above, which covers
%% only the interval bookkeeping before it.
%%====================================================================

%% Send data on a stream (with fragmentation for large data)
%% Now includes flow control checks at connection and stream level
%%
%% `check' refuses a write that would take the send queue past its ceiling,
%% before any of it is sent, so the caller can retry the same piece.
%% `force' admits it: async writes have no caller to retry.
do_send_data(StreamId, Data, Fin, #state{streams = Streams} = State, Admission) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream_state{send_fin = true}} ->
            %% Our FIN fixed the final size (RFC 9000 Section 4.5), so
            %% anything written now would lie past it.
            {error, stream_closed};
        {ok, StreamState} ->
            %% Check stream direction (can't send on peer's uni streams)
            case can_send_on_stream(StreamId, State) of
                false ->
                    ?LOG_WARNING(
                        #{what => send_on_peer_uni_stream, stream_id => StreamId}, ?QUIC_LOG_META
                    ),
                    {error, stream_state_error};
                true ->
                    %% Use iolist_size to avoid premature flattening
                    %% Data is only flattened when needed for chunking or frame encoding
                    DataSize = iolist_size(Data),
                    case admit_send(Admission, DataSize, State) of
                        true ->
                            send_admitted_data(StreamId, StreamState, Data, DataSize, Fin, State);
                        false ->
                            {error, send_queue_full}
                    end
            end;
        error ->
            {error, unknown_stream}
    end.

admit_send(force, _DataSize, _State) ->
    true;
admit_send(check, DataSize, #state{send_queue_bytes = QueueBytes}) when
    QueueBytes + DataSize =< ?MAX_SEND_QUEUE_BYTES
->
    true;
admit_send(check, DataSize, #state{send_queue_bytes = QueueBytes}) ->
    ?LOG_DEBUG(
        #{
            what => send_queue_full,
            queue_bytes => QueueBytes,
            data_size => DataSize,
            max_bytes => ?MAX_SEND_QUEUE_BYTES
        },
        ?QUIC_LOG_META
    ),
    false.

send_admitted_data(
    StreamId,
    StreamState,
    Data,
    DataSize,
    Fin,
    #state{max_data_remote = MaxDataRemote, data_sent = DataSent} = State
) ->
    Offset = StreamState#stream_state.send_offset,
    SendMaxData = StreamState#stream_state.send_max_data,

    %% Check connection-level flow control
    ConnectionAllowed = MaxDataRemote - DataSent,
    %% Check stream-level flow control
    StreamAllowed = SendMaxData - Offset,

    %% Log flow control status for debugging
    ?LOG_DEBUG(
        #{
            what => send_data_flow_check,
            stream_id => StreamId,
            data_size => DataSize,
            offset => Offset,
            send_max_data => SendMaxData,
            stream_allowed => StreamAllowed,
            max_data_remote => MaxDataRemote,
            data_sent => DataSent,
            connection_allowed => ConnectionAllowed
        },
        ?QUIC_LOG_META
    ),

    Allowed = min(ConnectionAllowed, StreamAllowed),
    case {DataSize =< ConnectionAllowed, DataSize =< StreamAllowed} of
        Fits when Fits =/= {true, true}, Allowed > 0 ->
            %% Part of this write fits in the peer's window.
            %% Send that part and queue the rest: queuing the
            %% whole write instead deadlocks the transfer,
            %% because the peer only extends the window as it
            %% consumes data, so sending nothing means nothing
            %% ever arrives to open it.
            Bin = iolist_to_binary(Data),
            <<Head:Allowed/binary, Tail/binary>> = Bin,
            case do_send_data(StreamId, Head, false, State, force) of
                {ok, SentState} ->
                    queue_blocked_send(
                        StreamId,
                        Offset + Allowed,
                        Tail,
                        Fin,
                        byte_size(Tail),
                        SentState
                    );
                Other ->
                    Other
            end;
        {false, _} ->
            %% Connection-level flow control blocked
            %% RFC 9000: Don't queue data beyond flow control limits.
            %% Send DATA_BLOCKED and return error to caller.
            %% Caller should retry after receiving MAX_DATA from peer.
            ?LOG_DEBUG(
                #{
                    what => connection_flow_control_blocked,
                    need => DataSize,
                    allowed => ConnectionAllowed
                },
                ?QUIC_LOG_META
            ),
            %% RFC 9000 Section 19.12: DATA_BLOCKED reports the connection data limit
            BlockedFrame = {data_blocked, MaxDataRemote},
            State1 = send_frame(BlockedFrame, State),
            queue_blocked_send(StreamId, Offset, Data, Fin, DataSize, State1);
        {_, false} ->
            %% Stream-level flow control blocked. Send
            %% STREAM_DATA_BLOCKED and queue; the send queue is
            %% drained when MAX_STREAM_DATA arrives.
            ?LOG_DEBUG(
                #{
                    what => stream_flow_control_blocked,
                    stream_id => StreamId,
                    need => DataSize,
                    allowed => StreamAllowed
                },
                ?QUIC_LOG_META
            ),
            %% RFC 9000 Section 19.13: STREAM_DATA_BLOCKED reports the stream data limit
            BlockedFrame = {stream_data_blocked, StreamId, SendMaxData},
            State1 = send_frame(BlockedFrame, State),
            queue_blocked_send(StreamId, Offset, Data, Fin, DataSize, State1);
        {true, true} ->
            %% Flow control allows sending
            %% Fragment and send data - congestion control may partially
            %% send and queue the remainder
            {NewState, BytesSent} = send_stream_data_fragmented_tracked(
                StreamId, Offset, Data, Fin, State
            ),
            %% Advance send_offset by full DataSize (not just BytesSent),
            %% because any unsent remainder was queued with correct offsets
            %% and subsequent sends must not overlap.
            case maps:find(StreamId, NewState#state.streams) of
                {ok, UpdatedStream} ->
                    SendFin = (Fin andalso BytesSent =:= DataSize),
                    %% send_done is NOT set here: RFC 9000 §3.1
                    %% ends the send side at "Data Recvd", which
                    %% requires the peer's acks. Reclaim (and the
                    %% MAX_STREAMS credit it returns) happens in
                    %% the ack path via settle_fin_ack/2.
                    FinalStream = UpdatedStream#stream_state{
                        send_offset = Offset + DataSize,
                        send_fin = SendFin
                    },
                    FinalState0 = NewState#state{
                        streams = maps:put(
                            StreamId, FinalStream, NewState#state.streams
                        ),
                        data_sent = NewState#state.data_sent + BytesSent
                    },
                    %% RFC 9000 §4.6: extend MAX_STREAMS when this
                    %% peer-initiated stream is now fully closed.
                    FinalState = maybe_reclaim_stream(
                        StreamId, FinalState0
                    ),
                    {ok, FinalState};
                error ->
                    {ok, NewState}
            end
    end.

%% Send 0-RTT (early) data on a stream
%% RFC 9001 Section 4.6: 0-RTT data uses the early traffic secret
do_send_zero_rtt_data(
    StreamId, Data, Fin, #state{streams = Streams, hs = #hs{early_keys = {EarlyKeys, _}}} = State
) ->
    case maps:find(StreamId, Streams) of
        {ok, StreamState} ->
            DataBin = iolist_to_binary(Data),
            Offset = StreamState#stream_state.send_offset,

            %% A write larger than one packet must be split like any
            %% 1-RTT send; a single oversized 0-RTT packet leaves as one
            %% IP-fragmented datagram, which QUIC forbids (RFC 9000 §14).
            MaxChunk = get_max_stream_data_per_packet(State),
            NewState = send_zero_rtt_chunks(
                StreamId, Offset, DataBin, Fin, MaxChunk, EarlyKeys, State
            ),

            %% Update stream state and track early data sent
            NewStreamState = StreamState#stream_state{
                send_offset = Offset + byte_size(DataBin),
                send_fin = Fin,
                send_done = Fin orelse StreamState#stream_state.send_done
            },
            EarlyDataSent = (State#state.hs)#hs.early_data_sent + byte_size(DataBin),
            NewZeroRttIds = sets:add_element(
                StreamId, (State#state.hs)#hs.zero_rtt_stream_ids
            ),

            FinalState0 = NewState#state{
                streams = maps:put(StreamId, NewStreamState, Streams),
                hs = (NewState#state.hs)#hs{
                    early_data_sent = EarlyDataSent,
                    zero_rtt_stream_ids = NewZeroRttIds
                }
            },
            %% RFC 9000 §4.6: extend MAX_STREAMS once this stream is fully
            %% closed (covers the rare 0-RTT FIN-from-server case).
            {ok, maybe_reclaim_stream(StreamId, FinalState0)};
        error ->
            {error, unknown_stream}
    end.

%% Split a 0-RTT write into per-packet STREAM frames, FIN on the last.
send_zero_rtt_chunks(StreamId, Offset, Data, Fin, MaxChunk, EarlyKeys, State) when
    byte_size(Data) =< MaxChunk
->
    Frame = {stream, StreamId, Offset, Data, Fin},
    send_zero_rtt_packet(quic_frame:encode(Frame), [Frame], EarlyKeys, State);
send_zero_rtt_chunks(StreamId, Offset, Data, Fin, MaxChunk, EarlyKeys, State) ->
    <<Chunk:MaxChunk/binary, Rest/binary>> = Data,
    Frame = {stream, StreamId, Offset, Chunk, false},
    State1 = send_zero_rtt_packet(quic_frame:encode(Frame), [Frame], EarlyKeys, State),
    send_zero_rtt_chunks(StreamId, Offset + MaxChunk, Rest, Fin, MaxChunk, EarlyKeys, State1).

%% Send a 0-RTT packet (long header, type 1)
%% RFC 9001 Section 5.3: 0-RTT packets use early traffic keys
send_zero_rtt_packet(Payload, Frames, EarlyKeys, State) ->
    #state{
        dcid = DCID,
        version = Version,
        % 0-RTT uses app PN space
        pn_app = PNSpace,
        cfg = #conn_cfg{
            scid = SCID
        }
    } = State,

    PN = PNSpace#pn_space.next_pn,
    PNLen = quic_packet:pn_length(PN),

    %% Pad payload if needed for header protection sampling
    PaddedPayload = pad_for_header_protection(Payload),

    %% Long header for 0-RTT; the type bits are version-specific
    FirstByte =
        16#C0 bor (quic_packet:type_to_bits(zero_rtt, Version) bsl 4) bor (PNLen - 1),

    %% Build header prefix (includes Length field, but not PN)
    DCIDLen = byte_size(DCID),
    SCIDLen = byte_size(SCID),
    % +16 for AEAD tag
    PayloadLen = iolist_size(PaddedPayload) + 16,
    LengthEncoded = quic_varint:encode(PNLen + PayloadLen),
    HeaderPrefix =
        <<FirstByte, Version:32, DCIDLen, DCID/binary, SCIDLen, SCID/binary, LengthEncoded/binary>>,

    %% Protect packet (encrypt + header protection in single call)
    #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = EarlyKeys,
    Packet = quic_aead:protect_long_packet(
        Cipher, Key, IV, HP, PN, HeaderPrefix, PaddedPayload
    ),
    NewSocketState = send_and_take_socket_state(Packet, State),

    %% 0-RTT shares the application PN space, so it must be tracked for
    %% loss detection like any 1-RTT packet: a dropped 0-RTT request was
    %% otherwise never retransmitted and the stream hung forever (RFC
    %% 9001 §4.1.1 expects lost 0-RTT data to be resent).
    Now = erlang:monotonic_time(millisecond),
    NewLossState = quic_loss:on_packet_sent(
        app, State#state.loss_state, PN, byte_size(Packet), true, Frames, Now
    ),
    NewCCState = quic_cc:on_packet_sent(State#state.cc_state, byte_size(Packet)),

    %% Update PN space and packet counter
    NewPNSpace = PNSpace#pn_space{next_pn = PN + 1},
    bump(?C_PACKETS_SENT, 1, State),
    State#state{
        pn_app = NewPNSpace,
        socket_state = NewSocketState,
        loss_state = NewLossState,
        cc_state = NewCCState,
        pto_dirty = true
    }.

%% Reset local state for all streams that carried 0-RTT data when the
%% server rejected 0-RTT. Drops the affected entries from the per-conn
%% `streams' map and emits a single batched event to the owner so the
%% application protocol (e.g. HTTP/3) can re-issue the affected requests.
%% RFC 9001 §4.6.2. No RESET_STREAM frame is sent on the wire because
%% the server never accepted these streams; both sides discard locally.
%% `data_sent' is left untouched: the 0-RTT send path never added these
%% bytes to it (they are tracked in `early_data_sent'), and the new 1-RTT
%% keys bring a fresh `initial_max_data' from the server's transport
%% parameters. `early_data_sent' is cleared because the abandoned bytes
%% are re-issued on new 1-RTT streams that count against `data_sent'
%% afresh.
-spec reset_zero_rtt_streams([non_neg_integer()], #state{}) -> #state{}.
reset_zero_rtt_streams([], State) ->
    State;
reset_zero_rtt_streams(RejectedIds, #state{streams = Streams, owner = Owner} = State) ->
    NewStreams = lists:foldl(fun maps:remove/2, Streams, RejectedIds),
    ?LOG_INFO(
        #{
            what => zero_rtt_rejected,
            rejected_stream_ids => RejectedIds,
            count => length(RejectedIds)
        },
        ?QUIC_LOG_META
    ),
    Owner ! {quic, self(), {early_data_rejected, RejectedIds}},
    State#state{
        streams = NewStreams,
        hs = (State#state.hs)#hs{
            zero_rtt_stream_ids = sets:new([{version, 2}]),
            early_data_sent = 0
        }
    }.

%% Branch on early_data_accepted at handshake completion. When 0-RTT was
%% rejected, reset stream state for every stream that carried 0-RTT data
%% (RFC 9001 §4.6.2). When accepted, the server received the 0-RTT data,
%% so it counts toward connection-level flow control: fold the
%% separately-tracked `early_data_sent' into `data_sent' (RFC 9000 §4.1).
%% The 0-RTT send path only accumulates `early_data_sent' and never
%% touches `data_sent', so without this fold the connection counter would
%% under-count accepted early data and could later overshoot max_data.
-spec finalize_zero_rtt_state(#state{}) -> #state{}.
finalize_zero_rtt_state(#state{hs = #hs{early_data_accepted = true}} = State) ->
    #state{data_sent = DataSent, hs = #hs{early_data_sent = EarlyDataSent}} = State,
    State#state{
        data_sent = DataSent + EarlyDataSent, hs = (State#state.hs)#hs{early_data_sent = 0}
    };
finalize_zero_rtt_state(#state{hs = #hs{early_data_accepted = false}} = State) ->
    case sets:to_list((State#state.hs)#hs.zero_rtt_stream_ids) of
        [] -> State;
        RejectedIds -> reset_zero_rtt_streams(RejectedIds, State)
    end.

%% Estimate packet overhead (header + AEAD tag + frame header).
%% Kept as a macro for the stream-chunking paths that sized themselves
%% against it historically.
-define(PACKET_OVERHEAD, 50).

%% Build the short-header first byte, folding in the outgoing spin
%% bit (RFC 9000 §17.4) when enabled. Bit layout:
%%   bit 7 = 0        (fixed header form)
%%   bit 6 = 1        (fixed 1-RTT marker)
%%   bit 5 = spin     (RFC 9000 §17.4)
%%   bits 4-3 = reserved (0)
%%   bit 2   = key phase
%%   bits 1-0 = PN length - 1
short_header_first_byte(KeyPhase, PNLen, #state{
    spin_outgoing = Spin, cfg = #conn_cfg{spin_bit_enabled = true}
}) ->
    16#40 bor (Spin bsl 5) bor (KeyPhase bsl 2) bor (PNLen - 1);
short_header_first_byte(KeyPhase, PNLen, #state{cfg = #conn_cfg{spin_bit_enabled = false}}) ->
    16#40 bor (KeyPhase bsl 2) bor (PNLen - 1).

%% Per-packet receive bookkeeping for the 1-RTT hot path: PN-space
%% update, spin-bit tracking and the activity stamp in one #state{}
%% rebuild. As three separate helpers (record_received_pn +
%% update_spin_from_recv + update_last_activity) each rebuilt the full
%% state record, together ~10% of receive CPU on bulk flows. Same
%% logic as those helpers; the spin part mirrors update_spin_from_recv.
record_app_recv(FirstByte, PN, #state{pn_app = PNSpace} = State, Now) ->
    Trigger = classify_recv_trigger(PN, PNSpace),
    NewPNSpace = quic_ack:update_pn_space_recv(PN, PNSpace, Now),
    {SpinRecv, SpinLargest, SpinOut} =
        case PN > State#state.spin_recv_largest_pn of
            true ->
                R = (FirstByte bsr 5) band 1,
                Out =
                    case (State#state.cfg)#conn_cfg.spin_bit_enabled of
                        false -> State#state.spin_outgoing;
                        true when (State#state.cfg)#conn_cfg.role =:= client -> R;
                        true -> 1 - R
                    end,
                {R, PN, Out};
            false ->
                {State#state.spin_recv, State#state.spin_recv_largest_pn, State#state.spin_outgoing}
        end,
    State#state{
        pn_app = NewPNSpace,
        last_recv_trigger = Trigger,
        spin_recv = SpinRecv,
        spin_recv_largest_pn = SpinLargest,
        spin_outgoing = SpinOut,
        last_activity = Now,
        ack_eliciting_since_recv = false
    }.

%% Short-header packet overhead for a DATAGRAM frame on the 1-RTT level:
%%   1 byte flags
%%   + DCID length (no length byte on short header)
%%   + up to 4 bytes packet number
%%   + 16 bytes AEAD tag
%%   + 1 byte frame type (0x31 DATAGRAM_WITH_LEN)
%%   + up to 2 bytes length varint (covers lengths up to 16383).
%% That leaves `pmtu - datagram_overhead(State)` as the upper bound on
%% the payload we can fit in a single UDP datagram without fragmenting.
datagram_overhead(#state{dcid = Dcid}) ->
    1 + byte_size(Dcid) + 4 + 16 + 1 + 2.

%% Deliver an inbound DATAGRAM to the owner, or drop it while the owner's
%% mailbox holds more than max_owner_queue messages: DATAGRAMs are
%% unreliable (RFC 9221 Section 5), and nothing else stops a peer from
%% filling that mailbox. Drops show in datagram_stats/1.
deliver_datagram(Data, State) ->
    case owner_behind(State) of
        true ->
            bump(?C_DATAGRAM_RECV_DROPPED, 1, State),
            State;
        false ->
            push_datagram(Data, State)
    end.

%% Also account for it in the recv queue. With no cap (`infinity') this
%% is a plain push; with a finite cap the queue drops its oldest entry.
push_datagram(
    Data,
    #state{
        owner = Owner,
        datagram_recv_queue = Queue,
        cfg = #conn_cfg{
            datagram_recv_queue_len = Cap
        }
    } = State
) ->
    Owner ! {quic, self(), {datagram, Data}},
    bump(?C_DATAGRAM_RECV_DELIVERED, 1, State),
    case Cap of
        infinity ->
            State;
        Max when is_integer(Max), Max >= 0 ->
            Queue1 =
                case queue:len(Queue) >= Max of
                    true ->
                        bump(?C_DATAGRAM_RECV_DROPPED, 1, State),
                        queue:in(Data, queue_drop_oldest(Queue));
                    false ->
                        queue:in(Data, Queue)
                end,
            State#state{datagram_recv_queue = Queue1}
    end.

queue_drop_oldest(Q) ->
    case queue:out(Q) of
        {{value, _}, Rest} -> Rest;
        {empty, _} -> Q
    end.

%% Stats snapshot used by quic:datagram_stats/1.
datagram_stats_snapshot(State) ->
    #{
        delivered => count(?C_DATAGRAM_RECV_DELIVERED, State),
        dropped_recv => count(?C_DATAGRAM_RECV_DROPPED, State),
        sent => count(?C_DATAGRAM_SENT, State),
        dropped_send => count(?C_DATAGRAM_SEND_DROPPED, State)
    }.

%% Send a datagram (RFC 9221)
%% RFC 9221: MUST NOT send DATAGRAM frames until receiving peer's max_datagram_frame_size
%% and MUST NOT send frames larger than peer's advertised value.
%% Additionally clamp to the current PMTU budget so we don't emit a UDP
%% payload the network will black-hole.
do_send_datagram(_Data, #state{max_datagram_frame_size_remote = 0}) ->
    %% Peer didn't advertise datagram support
    {error, datagrams_not_supported};
do_send_datagram(
    Data, #state{max_datagram_frame_size_remote = PeerMax, cc_state = CCState} = State
) ->
    DataBin = iolist_to_binary(Data),
    DataSize = byte_size(DataBin),
    PmtuBudget = max(0, get_local_max_udp_payload_size(State) - datagram_overhead(State)),
    if
        DataSize > PeerMax ->
            {error, datagram_too_large};
        DataSize > PmtuBudget ->
            {error, datagram_too_large_for_path};
        true ->
            case quic_cc:can_send(CCState, DataSize + datagram_overhead(State)) of
                true ->
                    %% Use datagram_with_length for better framing
                    Frame = {datagram_with_length, DataBin},
                    Payload = quic_frame:encode(Frame),
                    bump(?C_DATAGRAM_SENT, 1, State),
                    {ok, send_app_packet_internal(Payload, [Frame], State)};
                false ->
                    %% Datagrams are unreliable - just drop if cwnd is full
                    bump(?C_DATAGRAM_SEND_DROPPED, 1, State),
                    {error, congestion_limited, State}
            end
    end.

%% Send stream data in fragments, tracking how many bytes were actually sent
%% Returns {NewState, BytesSent} where BytesSent is the count of bytes actually transmitted
%% (not queued due to congestion)
%%
%% Normalises the payload to binary once at the entry. For binary inputs
%% (the common bulk-send case) this is O(1): iolist_to_binary/1 returns
%% the same refc binary unchanged. For iolist inputs this is one flatten;
%% subsequent chunking reuses the same binary via sub-binary slices and
%% downstream helpers can rely on the binary invariant without re-flattening.
send_stream_data_fragmented_tracked(StreamId, Offset, Data, Fin, State) ->
    send_stream_data_fragmented_tracked(StreamId, Offset, Data, Fin, State, back).

%% Where selects the queue position when a congestion/pacing block forces
%% the unsent remainder back onto the send queue: `back' for fresh sends
%% (their offset is highest, so appending keeps per-stream offset order),
%% `front' when draining the queue (the popped entry's remainder must go
%% back in front of higher-offset entries, or a later flow-control block
%% at the head strands it behind them, leaving a permanent data hole).
send_stream_data_fragmented_tracked(StreamId, Offset, Data, Fin, State, Where) ->
    DataBin =
        case is_binary(Data) of
            true -> Data;
            false -> iolist_to_binary(Data)
        end,
    send_stream_fragments(StreamId, Offset, DataBin, Fin, State, 0, Where).

send_stream_fragments(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Where) when
    is_binary(Data)
->
    %% Calculate max chunk size based on current PMTU
    MaxChunkSize = get_max_stream_data_per_packet(State),
    DataSize = byte_size(Data),

    case DataSize =< MaxChunkSize of
        true ->
            send_stream_single_packet(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Where);
        false ->
            %% Data is already a flat binary; chunk via sub-binary slices.
            send_stream_chunked(
                StreamId, Offset, Data, Fin, State, BytesSentSoFar, MaxChunkSize, Where
            )
    end.

%% @doc Send stream data that fits in a single packet.
%% Data is a binary (normalised by send_stream_data_fragmented_tracked/5).
send_stream_single_packet(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Where) when
    is_binary(Data)
->
    #state{cc_state = CCState, streams = Streams, cfg = #conn_cfg{pacing_enabled = PacingEnabled}} =
        State,
    DataSize = byte_size(Data),
    PacketSize = DataSize + ?PACKET_OVERHEAD,
    %% Control streams (urgency 0) can exceed cwnd to prevent tick blocking
    Urgency = get_stream_urgency(StreamId, Streams),
    %% Fused cwnd + pacing check (Phase 1). With pacing disabled the
    %% check degenerates to cwnd-only in one record match.
    Check =
        case PacingEnabled of
            true -> quic_cc:send_check(CCState, PacketSize, Urgency);
            false -> cwnd_only_check(CCState, PacketSize, Urgency)
        end,
    case Check of
        {ok, NewCCState} ->
            Frame = {stream, StreamId, Offset, Data, Fin},
            Payload = quic_frame:encode_iodata(Frame),
            NewState = send_app_packet_internal(Payload, [Frame], State, NewCCState),
            {NewState, BytesSentSoFar + DataSize};
        {blocked_pacing, Delay} ->
            ?LOG_DEBUG(
                #{
                    what => stream_data_paced,
                    stream_id => StreamId,
                    data_size => DataSize,
                    pacing_delay_ms => Delay
                },
                ?QUIC_LOG_META
            ),
            QueuedState = queue_stream_data(StreamId, Offset, Data, Fin, State, Where),
            {maybe_set_pacing_timer(Delay, QueuedState), BytesSentSoFar};
        {blocked_cwnd, _Available} ->
            ?LOG_DEBUG(
                #{
                    what => stream_data_queued_cwnd,
                    stream_id => StreamId,
                    data_size => DataSize,
                    offset => Offset,
                    cwnd => quic_cc:cwnd(CCState),
                    bytes_in_flight => quic_cc:bytes_in_flight(CCState),
                    available_cwnd => _Available
                },
                ?QUIC_LOG_META
            ),
            {queue_stream_data(StreamId, Offset, Data, Fin, State, Where), BytesSentSoFar}
    end.

%% Approve up to KMax-1 additional same-size sends against CC/pacing,
%% consuming pacing tokens exactly as the one-at-a-time path would.
approve_more_chunks(CC, _Size, _Urgency, _Pacing, KMax, K) when K >= KMax ->
    {K, CC};
approve_more_chunks(CC, Size, Urgency, true, KMax, K) ->
    %% One batched CC/pacing check for the rest of the run instead of
    %% a send_check per chunk.
    {KExtra, CC1} = quic_cc:send_check_run(CC, Size, KMax - K, Urgency),
    {K + KExtra, CC1};
approve_more_chunks(CC, Size, Urgency, false, KMax, K) ->
    %% Pacing off: count how many more chunks fit in the window,
    %% accounting each on a scratch copy so the checks see the chunks
    %% already approved. The real CC state is updated once for the run.
    {cwnd_room_chunks(CC, Size, Urgency, KMax, K), CC}.

cwnd_room_chunks(_CC, _Size, _Urgency, KMax, K) when K >= KMax ->
    K;
cwnd_room_chunks(CC, Size, Urgency, KMax, K) ->
    case cwnd_only_check(CC, Size, Urgency) of
        {ok, _} -> cwnd_room_chunks(quic_cc:on_packet_sent(CC, Size), Size, Urgency, KMax, K + 1);
        _ -> K
    end.

%% Send K CC-approved full-size chunks as one run: seal and hand each
%% wire packet to the socket, then update loss/CC/PN/counters and
%% rebuild #state{} ONCE for the whole run instead of once per packet.
send_stream_chunk_run(StreamId, Offset, Data, Fin, State0, BytesSentSoFar, Ctx, K) ->
    {chunked_ctx, MaxChunkSize, _Urgency, _PacketSize, HeaderPrefix, LengthVarint, _Where} = Ctx,
    %% A packet still pending from send coalescing goes out first so
    %% the wire order matches the send order.
    State = flush_pending_packet(State0),
    #state{
        dcid = DCID,
        app_keys = {ClientKeys, ServerKeys},
        pn_app = PNSpace,
        loss_state = LossState,
        cc_state = CCState,
        socket_state = SocketState,
        cfg = #conn_cfg{
            role = Role
        }
    } = State,
    EncryptKeys =
        case Role of
            client -> ClientKeys;
            server -> ServerKeys
        end,
    #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = EncryptKeys,
    Now = erlang:monotonic_time(millisecond),
    PN0 = PNSpace#pn_space.next_pn,
    KeyPhase = get_current_key_phase(State),
    %% Build the run's frames and QUIC-frame payloads, then seal all K
    %% packets: one fused NIF call when available (header, nonce, AEAD
    %% and header protection in C), per-packet Erlang sealing otherwise.
    {Frames, Payloads, Offset1, Rest} =
        build_run_payloads(K, StreamId, Offset, Data, HeaderPrefix, LengthVarint, MaxChunkSize),
    FirstByteBase = short_header_first_byte(KeyPhase, 1, State),
    Packets =
        case quic_aead_ctx:protect_run(Cipher, Key, IV, HP, PN0, FirstByteBase, DCID, Payloads) of
            {ok, Ps} ->
                Ps;
            fallback ->
                {Ps, _} = lists:mapfoldl(
                    fun(Payload, PN) ->
                        FirstByte = short_header_first_byte(
                            KeyPhase, quic_packet:pn_length(PN), State
                        ),
                        {
                            quic_aead:protect_short_packet(
                                Cipher, Key, IV, HP, PN, FirstByte, DCID, Payload
                            ),
                            PN + 1
                        }
                    end,
                    PN0,
                    Payloads
                ),
                Ps
        end,
    {SS1, TrackedRev} = send_run_packets(Packets, Frames, PN0, State, SocketState, []),
    %% One loss-tracker and one CC update for the run's successful sends.
    {Loss1, CC1} =
        case TrackedRev of
            [] ->
                {LossState, CCState};
            _ ->
                Tracked = lists:reverse(TrackedRev),
                {
                    quic_loss:on_packets_sent_run(app, LossState, Tracked, Now),
                    quic_cc:on_packets_sent(CCState, [Sz || {_, Sz, _} <- Tracked])
                }
        end,
    %% RFC 9000 §10.1: the idle timer restarts on the first ack-eliciting
    %% send since the last receive (see send_app_packet_now/3).
    RestartIdle = not State#state.ack_eliciting_since_recv,
    bump(?C_PACKETS_SENT, K, State),
    State1 = State#state{
        pn_app = PNSpace#pn_space{next_pn = PN0 + K},
        loss_state = Loss1,
        cc_state = CC1,
        socket_state = SS1,
        burst_sent = State#state.burst_sent + K,
        last_activity =
            case RestartIdle of
                true -> Now;
                false -> State#state.last_activity
            end,
        ack_eliciting_since_recv = true,
        pto_dirty = true
    },
    State2 = maybe_force_key_update(State1, K),
    send_stream_chunked_loop(
        StreamId, Offset1, Rest, Fin, State2, BytesSentSoFar + K * MaxChunkSize, Ctx
    ).

%% Split the run's data into K full chunks, building the stream frame
%% and QUIC-frame payload for each. Returns the leftover data and its
%% starting offset for the caller to continue with.
build_run_payloads(K, StreamId, Offset, Data, HeaderPrefix, LengthVarint, MaxChunkSize) ->
    build_run_payloads(
        K, StreamId, Offset, Data, HeaderPrefix, LengthVarint, MaxChunkSize, [], []
    ).

build_run_payloads(0, _Sid, Offset, Data, _HP, _LV, _MCS, FrAcc, PlAcc) ->
    {lists:reverse(FrAcc), lists:reverse(PlAcc), Offset, Data};
build_run_payloads(K, Sid, Offset, Data, HeaderPrefix, LengthVarint, MCS, FrAcc, PlAcc) ->
    <<Chunk:MCS/binary, Rest/binary>> = Data,
    Frame = {stream, Sid, Offset, Chunk, false},
    Payload = build_chunk_iodata(HeaderPrefix, Offset, LengthVarint, Chunk, Frame),
    build_run_payloads(
        K - 1,
        Sid,
        Offset + MCS,
        Rest,
        HeaderPrefix,
        LengthVarint,
        MCS,
        [Frame | FrAcc],
        [Payload | PlAcc]
    ).

%% Hand the run's sealed packets to the socket; the socket state is
%% threaded explicitly so no #state{} copy happens per packet, and the
%% successful sends are collected as [{PN, Size, Frame}] (reversed) for
%% one batched loss/CC update afterwards. Packet I carries PN0 + I. A
%% failed send skips that packet's tracking exactly as
%% send_app_packet_now/3 does (PTO owns retransmission).
send_run_packets([], [], _PN, _State, SS, Tracked) ->
    {SS, Tracked};
send_run_packets([Packet | Pkts], [Frame | Frs], PN, State, SS, Tracked) ->
    PacketSize = byte_size(Packet),
    #state{remote_addr = {IP, Port}} = State,
    SendResult =
        case SS of
            undefined ->
                case gen_udp:send(State#state.socket, IP, Port, Packet) of
                    ok -> {ok, undefined};
                    {error, _} = E -> E
                end;
            _ ->
                quic_socket:send(SS, IP, Port, Packet)
        end,
    case SendResult of
        {ok, SS1} ->
            ?QLOG_EMIT_PACKET_SENT((State#state.cfg)#conn_cfg.qlog_ctx, #{
                packet_type => one_rtt,
                packet_number => PN,
                length => PacketSize,
                frames => [Frame]
            }),
            SS2 =
                case SS1 of
                    undefined -> SS;
                    _ -> SS1
                end,
            send_run_packets(Pkts, Frs, PN + 1, State, SS2, [{PN, PacketSize, Frame} | Tracked]);
        {error, Reason, SSCleared} ->
            ?LOG_WARNING(
                #{what => udp_send_failed, reason => Reason, pn => PN, size => PacketSize},
                ?QUIC_LOG_META
            ),
            send_run_packets(Pkts, Frs, PN + 1, State, SSCleared, Tracked);
        {error, Reason} ->
            ?LOG_WARNING(
                #{what => udp_send_failed, reason => Reason, pn => PN, size => PacketSize},
                ?QUIC_LOG_META
            ),
            send_run_packets(Pkts, Frs, PN + 1, State, SS, Tracked)
    end.

%% Build the iodata payload `[Header, Chunk]' for a chunked stream
%% send, reusing the pre-computed header pieces when `Offset > 0'.
%% On the `Offset =:= 0' first-chunk path the wire format needs a
%% different type byte (no OFF flag, no offset varint), so fall back
%% to the generic `quic_frame:encode_iodata/1' which handles that.
build_chunk_iodata(HeaderPrefix, Offset, LengthVarint, Chunk, _Frame) when Offset > 0 ->
    OffsetVarint = quic_varint:encode(Offset),
    [<<HeaderPrefix/binary, OffsetVarint/binary, LengthVarint/binary>>, Chunk];
build_chunk_iodata(_HeaderPrefix, 0, _LengthVarint, _Chunk, Frame) ->
    quic_frame:encode_iodata(Frame).

%% Cwnd-only check used when pacing is disabled. Keeps the call sites
%% uniform with {ok,_} / {blocked_cwnd,_} while avoiding any pacing work.
cwnd_only_check(CCState, Size, Urgency) ->
    CanSend =
        case Urgency of
            0 -> quic_cc:can_send_control(CCState, Size);
            _ -> quic_cc:can_send(CCState, Size)
        end,
    case CanSend of
        true -> {ok, CCState};
        false -> {blocked_cwnd, quic_cc:available_cwnd(CCState)}
    end.

%% @doc Send stream data that requires chunking.
%%
%% Per-drain constants (Urgency, MaxChunkSize, PacketSize) are cached
%% here once and threaded through send_stream_chunked_loop/9 instead of
%% being re-looked-up for every chunk via a tail-call back into
%% send_stream_data_fragmented_tracked/6. For a 10 MB upload this cuts
%% thousands of get_stream_urgency/2 / get_max_stream_data_per_packet/1
%% calls and record-pattern matches out of the hot send loop.
send_stream_chunked(StreamId, Offset, Data, Fin, State, BytesSentSoFar, MaxChunkSize, Where) ->
    Urgency = get_stream_urgency(StreamId, State#state.streams),
    PacketSize = MaxChunkSize + ?PACKET_OVERHEAD,
    %% Pre-compute the stream-frame header parts that stay constant
    %% across every mid-chunk packet in this drain. The type byte
    %% always carries OFF|LEN (mid-chunks have offset > 0 and
    %% fin = false). Only the offset varint is rebuilt per chunk.
    StreamIdVarint = quic_varint:encode(StreamId),
    LengthVarint = quic_varint:encode(MaxChunkSize),
    HeaderPrefix =
        <<(?FRAME_STREAM bor ?STREAM_FLAG_OFF bor ?STREAM_FLAG_LEN):8, StreamIdVarint/binary>>,
    Ctx = {chunked_ctx, MaxChunkSize, Urgency, PacketSize, HeaderPrefix, LengthVarint, Where},
    send_stream_chunked_loop(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Ctx).

%% Inner chunked-send loop. Cached values in `Ctx' never change within a
%% single drain. The final sub-MaxChunkSize remainder falls through to
%% `send_stream_single_packet/6' so a partial last chunk gets a correctly
%% sized packet (Length != MaxChunkSize) and can also carry a FIN.
send_stream_chunked_loop(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Ctx) ->
    {chunked_ctx, MaxChunkSize, _Urgency, _PacketSize, _HeaderPrefix, _LengthVarint, Where} = Ctx,
    DataSize = byte_size(Data),
    case DataSize =< MaxChunkSize of
        true ->
            send_stream_single_packet(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Where);
        false ->
            send_stream_chunked_step(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Ctx)
    end.

send_stream_chunked_step(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Ctx) ->
    %% Requeue where the caller says, not always at the back: a remainder
    %% popped off the queue has to go back in front of the higher-offset
    %% entries it was ahead of, or the stream goes out on the wire
    %% interleaved for the rest of the transfer.
    {chunked_ctx, _, _, _, _, _, Where} = Ctx,
    case burst_exhausted(State) of
        true ->
            QueuedState = queue_stream_data(StreamId, Offset, Data, Fin, State, Where),
            {arm_burst_continuation(QueuedState), BytesSentSoFar};
        false ->
            send_stream_chunked_step_unbudgeted(
                StreamId, Offset, Data, Fin, State, BytesSentSoFar, Ctx
            )
    end.

send_stream_chunked_step_unbudgeted(StreamId, Offset, Data, Fin, State, BytesSentSoFar, Ctx) ->
    {chunked_ctx, MaxChunkSize, Urgency, PacketSize, _HeaderPrefix, _LengthVarint, Where} = Ctx,
    #state{cc_state = CCState, cfg = #conn_cfg{pacing_enabled = PacingEnabled}} = State,
    Check =
        case PacingEnabled of
            true -> quic_cc:send_check(CCState, PacketSize, Urgency);
            false -> cwnd_only_check(CCState, PacketSize, Urgency)
        end,
    case Check of
        {ok, NewCCState} ->
            %% First chunk approved. Approve as many further full
            %% chunks as CC/pacing and the burst budget allow, then
            %% send the whole run with one bookkeeping pass: the
            %% per-packet #state{} rebuild in send_app_packet_now is
            %% the largest own-time item on the bulk-send profile.
            FullChunks = byte_size(Data) div MaxChunkSize,
            BudgetLeft = max(1, (State#state.cfg)#conn_cfg.burst_budget - State#state.burst_sent),
            KMax = min(FullChunks, BudgetLeft),
            {K, CCStateK} = approve_more_chunks(
                NewCCState, PacketSize, Urgency, PacingEnabled, KMax, 1
            ),
            State0 = State#state{cc_state = CCStateK},
            send_stream_chunk_run(StreamId, Offset, Data, Fin, State0, BytesSentSoFar, Ctx, K);
        {blocked_pacing, Delay} ->
            ?LOG_DEBUG(
                #{
                    what => stream_data_paced_large,
                    stream_id => StreamId,
                    data_size => byte_size(Data),
                    pacing_delay_ms => Delay
                },
                ?QUIC_LOG_META
            ),
            QueuedState = queue_stream_data(StreamId, Offset, Data, Fin, State, Where),
            {maybe_set_pacing_timer(Delay, QueuedState), BytesSentSoFar};
        {blocked_cwnd, Available} ->
            %% Queue remaining data for later
            ?LOG_DEBUG(
                #{
                    what => stream_data_queued_cwnd_large,
                    stream_id => StreamId,
                    total_data_size => byte_size(Data),
                    offset => Offset,
                    bytes_sent_so_far => BytesSentSoFar,
                    cwnd => quic_cc:cwnd(CCState),
                    bytes_in_flight => quic_cc:bytes_in_flight(CCState),
                    available_cwnd => Available
                },
                ?QUIC_LOG_META
            ),
            {queue_stream_data(StreamId, Offset, Data, Fin, State, Where), BytesSentSoFar}
    end.

%% Queue a send the peer's flow-control window has no room for, rather
%% than returning an error. process_send_queue/1 drains it when MAX_DATA
%% or MAX_STREAM_DATA arrives. An error here is silently lost for
%% send_data_async callers, which are fire-and-forget and have no way to
%% retry, and the loss is invisible to both ends: the bytes never reach
%% the wire, so the peer cannot detect a gap, and the next send on the
%% stream simply continues from a later offset.
%%
%% The send offset is advanced at queue time so later sends on the stream
%% order behind this entry. QUIC reassembly is offset-based, so the order
%% the queued entries actually go out in does not matter.
queue_blocked_send(StreamId, Offset, Data, Fin, DataSize, State) ->
    QState = queue_stream_data(StreamId, Offset, Data, Fin, State),
    case maps:find(StreamId, QState#state.streams) of
        {ok, Stream} ->
            NewStream = Stream#stream_state{send_offset = Offset + DataSize},
            {ok, QState#state{
                streams = maps:put(StreamId, NewStream, QState#state.streams)
            }};
        error ->
            {ok, QState}
    end.

%%====================================================================
%% Send queue and the urgency priority queue (RFC 9218)
%%====================================================================

%% Queue stream data when congestion window is full
%% Uses bucket-based priority queue for O(1) insert (RFC 9218)
%% Never refuses: the ceiling is checked once, when do_send_data/5 admits
%% the write, because part of it may already be on the wire by now.
%% Entry format: {stream_data, StreamId, Offset, Data, Fin, DataSize}
%% DataSize is cached to avoid repeated iolist_size calls
queue_stream_data(StreamId, Offset, Data, Fin, State) ->
    queue_stream_data(StreamId, Offset, Data, Fin, State, back).

queue_stream_data(
    StreamId,
    Offset,
    Data,
    Fin,
    #state{
        send_queue = PQ,
        streams = Streams,
        send_queue_bytes = QueueBytes,
        send_queue_count = QueueCount,
        send_queue_version = Version
    } = State,
    Where
) ->
    %% Normalise to a binary: consumers like
    %% dequeue_small_stream_frame_tuple/1 hand the entry's data straight
    %% to quic_frame:encode/1, which requires a binary.
    DataBin =
        case is_binary(Data) of
            true -> Data;
            false -> iolist_to_binary(Data)
        end,
    DataSize = byte_size(DataBin),
    Urgency = get_stream_urgency(StreamId, Streams),
    %% Cache DataSize in entry to avoid repeated iolist_size calls
    Entry = {stream_data, StreamId, Offset, DataBin, Fin, DataSize},
    NewPQ =
        case Where of
            back -> quic_pqueue:in(Entry, Urgency, PQ);
            front -> quic_pqueue:in_front(Entry, Urgency, PQ)
        end,
    State#state{
        send_queue = NewPQ,
        send_queue_bytes = QueueBytes + DataSize,
        send_queue_count = QueueCount + 1,
        send_queue_version = Version + 1
    }.

%% Get stream urgency (default 3 if stream not found)
get_stream_urgency(StreamId, Streams) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream_state{urgency = Urgency}} -> Urgency;
        % Default urgency
        error -> 3
    end.

%% Process send queue when congestion window frees up
%% Processes streams in priority order (lower urgency = higher priority)
%% IMPORTANT: Must check BOTH congestion control AND flow control before sending
%% Fast path: if send_queue_count is 0 the queue is empty, so skip the
%% O(8) bucket walk in quic_pqueue:peek/1. We cannot use send_queue_bytes for
%% this check because a zero-byte FIN-only stream send (iodata of <<>>
%% with Fin=true) can be enqueued under pacing or congestion, leaving
%% bytes at 0 while a real entry is pending.
process_send_queue(#state{send_queue_count = 0} = State) ->
    State;
process_send_queue(State) ->
    case burst_exhausted(State) of
        true -> arm_burst_continuation(State);
        false -> process_send_queue_unbudgeted(State)
    end.

process_send_queue_unbudgeted(#state{send_queue = PQ} = State) ->
    case quic_pqueue:peek(PQ) of
        empty ->
            State;
        {value, {stream_data, StreamId, Offset, _Data, _Fin, DataSize}} ->
            %% Check flow control BEFORE dequeuing
            %% Use the Offset stored in the queue entry, not stream.send_offset,
            %% because send_offset may have advanced past this queued data's position.
            %% DataSize is cached in entry to avoid repeated iolist_size calls.
            case check_send_queue_flow_control(StreamId, Offset, DataSize, State) of
                ok ->
                    %% Flow control allows - dequeue and try to send
                    process_send_queue_entry(State);
                {blocked, _Reason} ->
                    %% An entry larger than the current window still has a
                    %% sendable prefix. Waiting for one grant big enough for
                    %% the whole entry stalls against a peer that extends its
                    %% window in small steps as it reads, because it sizes the
                    %% grant to what it consumed, never to what we have queued.
                    case split_blocked_head(State) of
                        {ok, SplitState} -> process_send_queue_entry(SplitState);
                        false -> State
                    end
            end;
        {value, {retransmit_stream, _StreamId, _Offset, _Data, _Fin, DataSize}} ->
            %% Retransmits are exempt from flow control (bytes already counted),
            %% but still gated by congestion control via the retransmit allowance.
            case quic_cc:can_send_control(State#state.cc_state, DataSize + ?PACKET_OVERHEAD) of
                true ->
                    process_send_queue_entry(State);
                false ->
                    %% cwnd still blocking - leave queued, retried on next ACK
                    State
            end
    end.

%% Check flow control limits for queued data
%% Returns ok | {blocked, connection | {stream, StreamId}}
%% Takes the Offset from the queue entry since stream.send_offset may have
%% advanced past queued data positions (per PR #16 fix).
check_send_queue_flow_control(StreamId, Offset, DataSize, #state{
    max_data_remote = MaxDataRemote,
    data_sent = DataSent,
    streams = Streams
}) ->
    %% Check connection-level flow control
    ConnectionAllowed = MaxDataRemote - DataSent,
    case DataSize =< ConnectionAllowed of
        false ->
            {blocked, connection};
        true ->
            %% Check stream-level flow control using the queue entry's Offset
            case maps:find(StreamId, Streams) of
                {ok, #stream_state{send_max_data = SendMaxData}} ->
                    %% Data at Offset with DataSize must fit within SendMaxData
                    case Offset + DataSize =< SendMaxData of
                        false ->
                            {blocked, {stream, StreamId}};
                        true ->
                            ok
                    end;
                error ->
                    %% Stream not found - allow (will fail later)
                    ok
            end
    end.

%% Replace a flow-control-blocked head entry with the prefix that fits plus
%% the remainder, both at the front so stream order is preserved. Returns
%% false when nothing fits, when the whole entry fits (the caller should not
%% have been blocked), or for a zero-length FIN-only entry.
split_blocked_head(#state{send_queue = PQ, send_queue_count = QueueCount} = State) ->
    case quic_pqueue:peek(PQ) of
        {value, {stream_data, StreamId, Offset, Data, Fin, DataSize}} ->
            case blocked_head_allowance(StreamId, Offset, State) of
                Allowed when Allowed > 0, Allowed < DataSize ->
                    {{value, _}, PQ1} = quic_pqueue:out(PQ),
                    <<Head:Allowed/binary, Tail/binary>> = Data,
                    Urgency = get_stream_urgency(StreamId, State#state.streams),
                    TailEntry =
                        {stream_data, StreamId, Offset + Allowed, Tail, Fin, DataSize - Allowed},
                    HeadEntry = {stream_data, StreamId, Offset, Head, false, Allowed},
                    PQ2 = quic_pqueue:in_front(TailEntry, Urgency, PQ1),
                    PQ3 = quic_pqueue:in_front(HeadEntry, Urgency, PQ2),
                    {ok, State#state{send_queue = PQ3, send_queue_count = QueueCount + 1}};
                _ ->
                    false
            end;
        _ ->
            false
    end.

%% Bytes of the entry at Offset that both connection and stream windows admit.
blocked_head_allowance(StreamId, Offset, #state{
    max_data_remote = MaxDataRemote,
    data_sent = DataSent,
    streams = Streams
}) ->
    ConnectionAllowed = MaxDataRemote - DataSent,
    StreamAllowed =
        case maps:find(StreamId, Streams) of
            {ok, #stream_state{send_max_data = SendMaxData}} -> SendMaxData - Offset;
            error -> ConnectionAllowed
        end,
    min(ConnectionAllowed, StreamAllowed).

%% Actually process the queue entry (called after flow control check passes)
process_send_queue_entry(
    #state{
        send_queue = PQ,
        send_queue_bytes = QueueBytes,
        send_queue_count = QueueCount
    } = State
) ->
    case quic_pqueue:out(PQ) of
        {empty, _} ->
            State;
        {{value, {retransmit_stream, StreamId, Offset, Data, Fin, DataSize}}, NewPQ} ->
            %% Lost data being retransmitted: send via the CC-checked retransmit
            %% path. No data_sent bump and no flow-control consumption (those were
            %% accounted on the original send). If CC blocks again,
            %% send_retransmit_frames_cc/2 re-enqueues it (version bump stops the
            %% drain loop below).
            State1 = State#state{
                send_queue = NewPQ,
                send_queue_bytes = max(0, QueueBytes - DataSize),
                send_queue_count = max(0, QueueCount - 1)
            },
            Frame = {stream, StreamId, Offset, Data, Fin},
            State2 = send_retransmit_frames_cc([Frame], State1),
            case quic_pqueue:is_empty(State2#state.send_queue) of
                true ->
                    State2;
                false ->
                    case State2#state.send_queue_version =:= State1#state.send_queue_version of
                        true -> process_send_queue(State2);
                        false -> State2
                    end
            end;
        {{value, {stream_data, StreamId, Offset, Data, Fin, DataSize}}, NewPQ} ->
            %% Decrement queue bytes and entry count for dequeued data.
            %% DataSize is cached in entry; if data is re-queued,
            %% queue_stream_data will increment appropriately.
            DecrementedQueueBytes = max(0, QueueBytes - DataSize),
            DecrementedQueueCount = max(0, QueueCount - 1),
            State1 = State#state{
                send_queue = NewPQ,
                send_queue_bytes = DecrementedQueueBytes,
                send_queue_count = DecrementedQueueCount
            },
            {State2, BytesSent} = send_stream_data_fragmented_tracked(
                StreamId, Offset, Data, Fin, State1, front
            ),
            %% Only update data_sent for connection-level flow control accounting.
            %% send_offset was already advanced when the data was first queued
            %% (in do_send_data) to prevent offset overlap bugs.
            State3a =
                case BytesSent > 0 of
                    true ->
                        State2#state{
                            data_sent = State2#state.data_sent + BytesSent
                        };
                    false ->
                        State2
                end,
            %% A queued write that carried FIN closes the send side only
            %% here: do_send_data could not mark it (the write was still
            %% queued). The queue-count check rules out a zero-length FIN
            %% entry that was re-queued rather than sent (0 =:= 0 lies).
            EntrySent =
                BytesSent =:= DataSize andalso
                    State3a#state.send_queue_count =:= DecrementedQueueCount,
            State3 =
                case Fin andalso EntrySent of
                    true -> mark_fin_sent(StreamId, State3a);
                    false -> State3a
                end,
            %% If data was queued again (cwnd still full), stop processing
            case quic_pqueue:is_empty(State3#state.send_queue) of
                true ->
                    State3;
                false ->
                    %% Check if we just queued more data (cwnd full)
                    %% Use version counter for fast comparison (avoids structural equality on 8-tuple)
                    case State3#state.send_queue_version =:= State1#state.send_queue_version of
                        % Keep processing (check flow control again)
                        true -> process_send_queue(State3);
                        % New data queued, cwnd full
                        false -> State3
                    end
            end
    end.

%% Send data that was queued before connection was established
send_pending_data([], State) ->
    State;
send_pending_data([{StreamId, Data, Fin} | Rest], State) ->
    %% Accepted before the handshake finished; refusing it now would drop it.
    case do_send_data(StreamId, Data, Fin, State, force) of
        {ok, NewState} ->
            send_pending_data(Rest, NewState);
        {error, _Reason} ->
            %% Skip failed sends
            send_pending_data(Rest, State)
    end.

%% RFC 9000 Section 3.5: STOP_SENDING MUST be answered with RESET_STREAM
%% while our send side is open, and carries the peer's code over. The
%% reset is what closes the peer's side of the stream; without it the peer
%% waits on a stream we have stopped writing to. Only a stream that already
%% existed, and one we can send on, has a send side to reset.
answer_stop_sending(StreamId, ErrorCode, StreamsBefore, State) ->
    case maps:find(StreamId, StreamsBefore) of
        {ok, #stream_state{send_done = false}} ->
            case can_send_on_stream(StreamId, State) of
                true ->
                    {ok, Reset} = do_close_stream(StreamId, ErrorCode, State),
                    Reset;
                false ->
                    State
            end;
        _ ->
            State
    end.

%% Send RESET_STREAM (RFC 9000 §3.2): closes the SEND direction only.
%% The recv side stays alive so the caller can still issue
%% stop_sending and receive frames from the peer until the peer
%% closes its own send side. Drop the stream from the map only when
%% both directions are terminated.
do_close_stream(StreamId, ErrorCode, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, StreamState} ->
            case StreamState#stream_state.deadline_timer of
                undefined -> ok;
                Timer -> erlang:cancel_timer(Timer)
            end,
            FinalSize = StreamState#stream_state.send_offset,
            ResetFrame = {reset_stream, StreamId, ErrorCode, FinalSize},
            NewState = send_frame(ResetFrame, State),
            UpdatedStream = StreamState#stream_state{
                state = reset,
                deadline_timer = undefined,
                send_done = true
            },
            %% Purge any queued STREAM frames so nothing is sent after the reset.
            State1 = purge_stream_send_queue(StreamId, NewState),
            State2 = State1#state{
                streams = maps:put(StreamId, UpdatedStream, State1#state.streams)
            },
            {ok, maybe_reclaim_stream(StreamId, State2)};
        error ->
            {error, unknown_stream}
    end.

%% Request peer to stop sending on a stream (RFC 9000 Section 19.5)
do_stop_sending(StreamId, ErrorCode, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, _StreamState} ->
            %% Send STOP_SENDING frame
            StopFrame = {stop_sending, StreamId, ErrorCode},
            NewState = send_frame(StopFrame, State),
            {ok, NewState};
        error ->
            {error, unknown_stream}
    end.

%% RESET_STREAM_AT: Reset stream with reliable delivery up to ReliableSize
%% (draft-ietf-quic-reliable-stream-reset-07)
do_reset_stream_at(
    StreamId,
    ErrorCode,
    ReliableSize,
    #state{streams = Streams, transport_params = TP} = State
) ->
    case maps:get(reset_stream_at, TP, false) of
        false ->
            {error, not_supported};
        true ->
            case maps:find(StreamId, Streams) of
                {ok, StreamState} ->
                    do_reset_stream_at_with_stream(
                        StreamId, ErrorCode, ReliableSize, StreamState, State
                    );
                error ->
                    {error, unknown_stream}
            end
    end.

do_reset_stream_at_with_stream(StreamId, ErrorCode, ReliableSize, StreamState, State) ->
    FinalSize = StreamState#stream_state.send_offset,
    case validate_reset_stream_at(ReliableSize, FinalSize, ErrorCode, StreamState) of
        ok ->
            execute_reset_stream_at(
                StreamId,
                ErrorCode,
                ReliableSize,
                FinalSize,
                StreamState,
                State
            );
        {error, _} = Error ->
            Error
    end.

validate_reset_stream_at(ReliableSize, FinalSize, ErrorCode, StreamState) ->
    ExistingReliable = StreamState#stream_state.send_reset_at,
    ExistingError = StreamState#stream_state.send_reset_error,
    case ReliableSize > FinalSize of
        true ->
            {error, {invalid_reliable_size, ReliableSize, FinalSize}};
        false ->
            validate_reset_stream_at_constraints(
                ReliableSize,
                ErrorCode,
                ExistingReliable,
                ExistingError
            )
    end.

validate_reset_stream_at_constraints(ReliableSize, ErrorCode, ExistingReliable, ExistingError) ->
    case ExistingReliable =/= undefined andalso ReliableSize > ExistingReliable of
        true ->
            {error, cannot_increase_reliable_size};
        false ->
            case ExistingError =/= undefined andalso ErrorCode =/= ExistingError of
                true ->
                    {error, cannot_change_error_code};
                false ->
                    ok
            end
    end.

execute_reset_stream_at(
    StreamId,
    ErrorCode,
    ReliableSize,
    FinalSize,
    StreamState,
    State
) ->
    %% Cancel deadline timer if any
    case StreamState#stream_state.deadline_timer of
        undefined -> ok;
        Timer -> erlang:cancel_timer(Timer)
    end,
    %% Send RESET_STREAM_AT frame
    Frame = {reset_stream_at, StreamId, ErrorCode, FinalSize, ReliableSize},
    NewState = send_frame(Frame, State),
    %% Truncate send buffer beyond ReliableSize
    TruncatedBuffer = truncate_send_buffer(StreamState#stream_state.send_buffer, ReliableSize),
    UpdatedStream = StreamState#stream_state{
        state = reset,
        send_reset_at = ReliableSize,
        send_reset_error = ErrorCode,
        send_buffer = TruncatedBuffer,
        deadline_timer = undefined
    },
    %% Drop queued STREAM data at/after ReliableSize; keep < ReliableSize for
    %% delivery (the reliable-reset guarantee).
    State1 = trim_stream_send_queue(StreamId, ReliableSize, NewState),
    State2 = State1#state{streams = maps:put(StreamId, UpdatedStream, State1#state.streams)},
    {ok, settle_send_reset_at(StreamId, State2)}.

%% Send side of a local RESET_STREAM_AT is done once no data below ReliableSize
%% remains queued or in flight. Until then, track it so the ack path can finish
%% the reclaim when the last reliable bytes are acked.
settle_send_reset_at(StreamId, State) ->
    RS = (maps:get(StreamId, State#state.streams))#stream_state.send_reset_at,
    Pending =
        stream_has_queued_below(StreamId, RS, State#state.send_queue) orelse
            quic_loss:stream_has_unacked_below(State#state.loss_state, StreamId, RS),
    case Pending of
        false ->
            mark_send_done_and_reclaim(StreamId, State);
        true ->
            State#state{
                pending_send_reset_at =
                    maps:put(StreamId, RS, State#state.pending_send_reset_at)
            }
    end.

%% Mark the send side terminal and try to reclaim. recv_done (for bidi) still
%% gates the actual removal inside maybe_reclaim_stream/2.
mark_send_done_and_reclaim(StreamId, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, S} ->
            State1 = State#state{
                streams = maps:put(
                    StreamId, S#stream_state{send_done = true}, State#state.streams
                )
            },
            maybe_reclaim_stream(StreamId, State1);
        error ->
            State
    end.

%% Drop queued STREAM/retransmit entries for StreamId at/after ReliableSize;
%% truncate a straddling entry to ReliableSize - Offset (clearing Fin); keep
%% entries fully below. Mirrors remove_stream_from_queue/2 bookkeeping and bumps
%% send_queue_version since entry payloads change.
trim_stream_send_queue(StreamId, ReliableSize, #state{send_queue = PQ} = State) ->
    {NewQueues, RemovedBytes, RemovedCount} =
        lists:foldl(
            fun(I, {Queues, Bytes, Count}) ->
                {Kept, DBytes, DCount} = trim_bucket(element(I, PQ), StreamId, ReliableSize),
                {[Kept | Queues], Bytes + DBytes, Count + DCount}
            end,
            {[], 0, 0},
            lists:seq(1, 8)
        ),
    State#state{
        send_queue = list_to_tuple(lists:reverse(NewQueues)),
        send_queue_bytes = max(0, State#state.send_queue_bytes - RemovedBytes),
        send_queue_count = max(0, State#state.send_queue_count - RemovedCount),
        send_queue_version = State#state.send_queue_version + 1
    }.

%% Trim one priority bucket. DCount counts fully-dropped entries only (a
%% truncated entry stays in the queue).
trim_bucket(Q, StreamId, ReliableSize) ->
    lists:foldl(
        fun(Entry, {QAcc, DBytes, DCount}) ->
            case trim_entry(Entry, StreamId, ReliableSize) of
                keep ->
                    {queue:in(Entry, QAcc), DBytes, DCount};
                {truncate, NewEntry, Removed} ->
                    {queue:in(NewEntry, QAcc), DBytes + Removed, DCount};
                {drop, Removed} ->
                    {QAcc, DBytes + Removed, DCount + 1}
            end
        end,
        {queue:new(), 0, 0},
        queue:to_list(Q)
    ).

trim_entry({Tag, SId, Offset, Data, _Fin, DataSize}, StreamId, ReliableSize) when
    (Tag =:= stream_data orelse Tag =:= retransmit_stream) andalso SId =:= StreamId
->
    if
        Offset >= ReliableSize ->
            {drop, DataSize};
        Offset + DataSize =< ReliableSize ->
            keep;
        true ->
            KeepLen = ReliableSize - Offset,
            Truncated = binary:part(iolist_to_binary(Data), 0, KeepLen),
            {truncate, {Tag, SId, Offset, Truncated, false, KeepLen}, DataSize - KeepLen}
    end;
trim_entry(_Entry, _StreamId, _ReliableSize) ->
    keep.

%% True if the send queue holds STREAM/retransmit data for StreamId starting
%% before ReliableSize (reliable bytes still owed).
stream_has_queued_below(StreamId, ReliableSize, PQ) ->
    lists:any(
        fun(I) ->
            lists:any(
                fun
                    ({Tag, SId, Offset, _Data, _Fin, _DataSize}) when
                        Tag =:= stream_data orelse Tag =:= retransmit_stream
                    ->
                        SId =:= StreamId andalso Offset < ReliableSize;
                    (_) ->
                        false
                end,
                queue:to_list(element(I, PQ))
            )
        end,
        lists:seq(1, 8)
    ).

%% Truncate send buffer to only keep data up to ReliableSize
truncate_send_buffer(Buffer, ReliableSize) when is_list(Buffer) ->
    lists:filter(
        fun({Offset, _Data}) ->
            %% Keep chunk if it starts before ReliableSize
            Offset < ReliableSize
        end,
        Buffer
    );
truncate_send_buffer(Buffer, _ReliableSize) ->
    %% Empty or other buffer type - return as-is
    Buffer.

%% Set stream priority (RFC 9218)
do_set_stream_priority(StreamId, Urgency, Incremental, #state{streams = Streams} = State) when
    Urgency >= 0, Urgency =< 7, is_boolean(Incremental)
->
    case maps:find(StreamId, Streams) of
        {ok, StreamState} ->
            NewStreamState = StreamState#stream_state{
                urgency = Urgency,
                incremental = Incremental
            },
            {ok, State#state{
                streams = maps:put(StreamId, NewStreamState, Streams)
            }};
        error ->
            {error, unknown_stream}
    end;
do_set_stream_priority(_StreamId, _Urgency, _Incremental, _State) ->
    {error, invalid_priority}.

%% Get stream priority (RFC 9218)
do_get_stream_priority(StreamId, #state{streams = Streams}) ->
    case maps:find(StreamId, Streams) of
        {ok, StreamState} ->
            {ok, {StreamState#stream_state.urgency, StreamState#stream_state.incremental}};
        error ->
            {error, unknown_stream}
    end.

%% Set congestion control algorithm
do_set_congestion_control(Algorithm, #state{cc_state = OldCC} = State) when
    Algorithm =:= newreno; Algorithm =:= bbr; Algorithm =:= cubic
->
    NewCC = quic_cc:new(Algorithm, #{
        max_datagram_size => quic_cc:max_datagram_size(OldCC)
    }),
    {ok, State#state{cc_state = NewCC}};
do_set_congestion_control(_Algorithm, _State) ->
    {error, invalid_algorithm}.

%% Set stream deadline
do_set_stream_deadline(StreamId, TimeoutMs, Opts, #state{streams = Streams} = State) when
    is_integer(TimeoutMs), TimeoutMs > 0
->
    case maps:find(StreamId, Streams) of
        {ok, StreamState} ->
            %% Cancel existing deadline timer if any
            case StreamState#stream_state.deadline_timer of
                undefined -> ok;
                OldTimer -> erlang:cancel_timer(OldTimer)
            end,
            %% Calculate absolute deadline
            Now = erlang:system_time(millisecond),
            Deadline = Now + TimeoutMs,
            %% Parse options
            Action = maps:get(action, Opts, both),
            ErrorCode = maps:get(error_code, Opts, ?QUIC_STREAM_DEADLINE_EXCEEDED),
            %% Start new timer
            TimerRef = erlang:send_after(TimeoutMs, self(), {stream_deadline, StreamId}),
            NewStreamState = StreamState#stream_state{
                deadline = Deadline,
                deadline_timer = TimerRef,
                deadline_action = Action,
                deadline_error_code = ErrorCode
            },
            {ok, State#state{
                streams = maps:put(StreamId, NewStreamState, Streams)
            }};
        error ->
            {error, unknown_stream}
    end;
do_set_stream_deadline(_StreamId, _TimeoutMs, _Opts, _State) ->
    {error, invalid_timeout}.

%% Cancel stream deadline
do_cancel_stream_deadline(StreamId, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, StreamState} ->
            %% Cancel timer if exists
            case StreamState#stream_state.deadline_timer of
                undefined -> ok;
                Timer -> erlang:cancel_timer(Timer)
            end,
            NewStreamState = StreamState#stream_state{
                deadline = undefined,
                deadline_timer = undefined
            },
            {ok, State#state{
                streams = maps:put(StreamId, NewStreamState, Streams)
            }};
        error ->
            {error, unknown_stream}
    end.

%% Get stream deadline info
do_get_stream_deadline(StreamId, #state{streams = Streams}) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream_state{deadline = undefined}} ->
            {error, no_deadline};
        {ok, #stream_state{deadline = infinity, deadline_action = Action}} ->
            {ok, {infinity, Action}};
        {ok, #stream_state{deadline = Deadline, deadline_action = Action}} ->
            Now = erlang:system_time(millisecond),
            Remaining = max(0, Deadline - Now),
            {ok, {Remaining, Action}};
        error ->
            {error, unknown_stream}
    end.

%% Handle stream deadline expiration
handle_stream_deadline_expired(
    StreamId,
    #state{
        streams = Streams,
        owner = Owner
    } = State
) ->
    case maps:find(StreamId, Streams) of
        {ok,
            #stream_state{
                deadline_action = Action,
                deadline_error_code = ErrorCode,
                state = StreamState
            } = Stream} when StreamState =/= closed, StreamState =/= reset ->
            %% Clear the deadline timer from stream state
            Stream1 = Stream#stream_state{
                deadline = undefined,
                deadline_timer = undefined
            },
            Streams1 = maps:put(StreamId, Stream1, Streams),
            State1 = State#state{streams = Streams1},
            %% Notify owner if requested
            case Action of
                notify ->
                    Owner ! {quic, self(), {stream_deadline, StreamId}},
                    {ok, State1};
                reset ->
                    do_close_stream_deadline(StreamId, ErrorCode, State1);
                both ->
                    Owner ! {quic, self(), {stream_deadline, StreamId}},
                    do_close_stream_deadline(StreamId, ErrorCode, State1)
            end;
        {ok, _ClosedStream} ->
            %% Stream already closed
            {error, stream_closed};
        error ->
            %% Stream doesn't exist
            {error, unknown_stream}
    end.

%% Close stream due to deadline expiry (sends RESET_STREAM)
do_close_stream_deadline(StreamId, ErrorCode, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, StreamState} ->
            %% Send RESET_STREAM frame
            FinalSize = StreamState#stream_state.send_offset,
            ResetFrame = {reset_stream, StreamId, ErrorCode, FinalSize},
            NewState = send_frame(ResetFrame, State),
            %% Local RESET_STREAM closes our send side; purge any queued frames
            %% so nothing is emitted after the reset, then reclaim if terminal.
            NewStreamState = StreamState#stream_state{
                state = reset,
                send_buffer = [],
                send_done = true,
                deadline = undefined,
                deadline_timer = undefined
            },
            State1 = purge_stream_send_queue(StreamId, NewState),
            State2 = State1#state{
                streams = maps:put(StreamId, NewStreamState, State1#state.streams)
            },
            {ok, maybe_reclaim_stream(StreamId, State2)};
        error ->
            {error, unknown_stream}
    end.

%% Initiate connection close
initiate_close(Reason, #state{mig = #mig{path_validation_timer = PathTimer}} = State) ->
    %% Cancel path validation timer if active
    cancel_timer(PathTimer),
    State1 = State#state{
        mig = (State#state.mig)#mig{
            path_validation_timer = undefined, path_validation_token = undefined
        }
    },
    %% Send CONNECTION_CLOSE frame
    {ErrorCode, ReasonPhrase} =
        case Reason of
            normal ->
                {?QUIC_NO_ERROR, <<>>};
            {app_error, Code, Phrase} when is_integer(Code), is_binary(Phrase) ->
                {Code, Phrase};
            _ ->
                {?QUIC_APPLICATION_ERROR, <<>>}
        end,
    CloseFrame = {connection_close, application, ErrorCode, undefined, ReasonPhrase},
    case State1#state.app_keys of
        undefined ->
            %% No keys yet - cannot send frame, just set close_reason
            State1#state{close_reason = Reason};
        _ ->
            send_frame(CloseFrame, State1#state{close_reason = Reason})
    end.

%% Send PROTOCOL_VIOLATION transport error (RFC 9000)
%% Used when a peer violates the protocol (e.g., RFC 9221 datagram violations)
send_protocol_violation(Reason, State) ->
    CloseFrame = {connection_close, transport, ?QUIC_PROTOCOL_VIOLATION, 0, Reason},
    case State#state.app_keys of
        undefined ->
            State#state{close_reason = {protocol_violation, Reason}};
        _ ->
            send_frame(CloseFrame, State#state{close_reason = {protocol_violation, Reason}})
    end.

%% Emit CONNECTION_CLOSE at the requested encryption level.
%% Picks the right keys (initial/handshake/app) and encodes the frame in a
%% packet of that level. Falls back to the next-lower available level when
%% the preferred one has no keys yet (app -> handshake -> initial).
%% This fixes the case where a handshake-time violation used to silently drop
%% the CLOSE frame because only the 1-RTT send path was wired.
close_with_error(Level, Class, Code, FrameType, Reason, State) ->
    CloseFrame = {connection_close, Class, Code, FrameType, Reason},
    CloseState = State#state{close_reason = {Class, Code, Reason}},
    emit_close_at_level(select_close_level(Level, State), CloseFrame, CloseState).

select_close_level(app, #state{app_keys = AppKeys}) when AppKeys =/= undefined ->
    app;
select_close_level(app, State) ->
    select_close_level(handshake, State);
select_close_level(handshake, #state{hs = #hs{handshake_keys = HSKeys}}) when
    HSKeys =/= undefined
->
    handshake;
select_close_level(handshake, State) ->
    select_close_level(initial, State);
select_close_level(initial, #state{hs = #hs{initial_keys = InitKeys}}) when
    InitKeys =/= undefined
->
    initial;
select_close_level(_, _) ->
    none.

emit_close_at_level(app, CloseFrame, State) ->
    send_frame(CloseFrame, State);
emit_close_at_level(handshake, CloseFrame, State) ->
    send_handshake_packet(quic_frame:encode(CloseFrame), [CloseFrame], State);
emit_close_at_level(initial, CloseFrame, State) ->
    send_initial_packet(quic_frame:encode(CloseFrame), [CloseFrame], State);
emit_close_at_level(none, _CloseFrame, State) ->
    State.

%% Send CONNECTION_CLOSE frame during terminate (best effort)
%% This is called when the process is terminating unexpectedly
send_connection_close(_Reason, #state{app_keys = undefined} = State) ->
    %% No app keys yet, can't send encrypted close frame
    State;
send_connection_close(Reason, State) ->
    {ErrorCode, ReasonPhrase} =
        case Reason of
            normal ->
                {?QUIC_NO_ERROR, <<>>};
            shutdown ->
                {?QUIC_NO_ERROR, <<>>};
            {shutdown, _} ->
                {?QUIC_NO_ERROR, <<>>};
            {app_error, Code, Phrase} when is_integer(Code), is_binary(Phrase) ->
                {Code, Phrase};
            _ ->
                {?QUIC_APPLICATION_ERROR, <<>>}
        end,
    CloseFrame = {connection_close, application, ErrorCode, undefined, ReasonPhrase},
    %% Best effort send - ignore errors since we're terminating anyway.
    %% Return the updated state: it carries the batched close packet, and
    %% the caller must flush that socket_state for the frame to reach the
    %% wire.
    try
        send_frame(CloseFrame, State)
    catch
        _:_ -> State
    end.

%% Send TLS alert as QUIC crypto error and close connection.
%% QUIC crypto errors are 0x100 + TLS alert code (RFC 9001 §4.8).
%% The /2 form defaults the close reason phrase per alert code.
%% Emit a TLS alert and stop. The alert is batched into the state
%% send_tls_alert/2 returns, so that state has to be flushed here:
%% terminate/3 runs with the pre-alert state, and its fallback close is
%% skipped outright while app_keys are undefined, which is exactly when
%% alerts happen. Discarding the returned state left the peer with
%% silence until its idle timeout (issue #227).
%%
%% terminate/3 then flushes its own copy of the socket_state, which is
%% the pre-alert one. Anything batched before the alert therefore goes
%% out twice: once here and once there. Those are duplicate packets with
%% packet numbers the peer has already seen, which it discards, so the
%% cost is a few redundant bytes on a connection that is closing.
-spec alert_and_exit(non_neg_integer(), #state{}, atom()) -> no_return().
alert_and_exit(AlertCode, State, Reason) ->
    Sent = send_tls_alert(AlertCode, State),
    _ = flush_socket_batch(Sent),
    exit({tls_alert, Reason}).

send_tls_alert(AlertCode, State) ->
    send_tls_alert(AlertCode, default_alert_phrase(AlertCode), State).

%% Emit the alert at the highest available encryption level
%% (app -> handshake -> initial). Pre-handshake negotiation errors
%% (HRR-phase) ship at the Initial level, where only initial_keys
%% exist, instead of being silently dropped.
send_tls_alert(AlertCode, Phrase, State) ->
    ErrorCode = ?QUIC_CRYPTO_ERROR_BASE + AlertCode,
    CloseState = State#state{close_reason = {tls_alert, AlertCode}},
    CloseFrame = {connection_close, transport, ErrorCode, 0, Phrase},
    emit_close_at_level(select_close_level(app, CloseState), CloseFrame, CloseState).

%% Close with a transport-level error code (RFC 9000 §20.1) at the
%% highest available encryption level. Works before app keys exist
%% (handshake-time errors) unlike the raw stream-path close.
close_with_transport_error(Code, Phrase, State) ->
    CloseState = State#state{close_reason = {transport, Code, Phrase}},
    CloseFrame = {connection_close, transport, Code, 0, Phrase},
    emit_close_at_level(select_close_level(app, CloseState), CloseFrame, CloseState).

default_alert_phrase(?TLS_ALERT_HANDSHAKE_FAILURE) -> <<"handshake failure">>;
default_alert_phrase(?TLS_ALERT_ILLEGAL_PARAMETER) -> <<"illegal parameter">>;
default_alert_phrase(?TLS_ALERT_UNEXPECTED_MESSAGE) -> <<"unexpected message">>;
default_alert_phrase(?TLS_ALERT_DECRYPT_ERROR) -> <<"decrypt error">>;
default_alert_phrase(?TLS_ALERT_INTERNAL_ERROR) -> <<"internal error">>;
default_alert_phrase(?TLS_ALERT_UNKNOWN_PSK_IDENTITY) -> <<"unknown psk identity">>;
default_alert_phrase(?TLS_ALERT_BAD_CERTIFICATE) -> <<"bad certificate">>;
default_alert_phrase(?TLS_ALERT_UNKNOWN_CA) -> <<"unknown ca">>;
default_alert_phrase(?TLS_ALERT_CERTIFICATE_REQUIRED) -> <<"certificate required">>;
default_alert_phrase(_) -> <<"tls alert">>.

%% Normalise the `verify' option to a strict boolean. Accepts the
%% historical booleans as well as ssl-style `verify_peer'/`verify_none'
%% atoms passed through by quic_h3. Unknown values default to verifying.
normalize_verify(true) -> true;
normalize_verify(false) -> false;
normalize_verify(verify_peer) -> true;
normalize_verify(verify_none) -> false;
normalize_verify(none) -> false;
normalize_verify(_) -> true.

%% Verify the server's authentication: the CertificateVerify signature
%% (proof of leaf private-key possession), then the certificate chain
%% and the hostname. `Advance' is the post-message state to return when
%% authentication succeeds; on failure we close from `State' so the
%% catch-all ignores the trailing Finished.
verify_server_authentication(Body, TranscriptHash, Advance, State) ->
    PeerCert = (State#state.hs)#hs.peer_cert,
    case quic_tls:verify_certificate_verify(Body, PeerCert, TranscriptHash, server) of
        true ->
            case
                quic_cert:validate_server(
                    PeerCert,
                    (State#state.hs)#hs.peer_cert_chain,
                    (State#state.cfg)#conn_cfg.cacerts,
                    (State#state.hs)#hs.server_name
                )
            of
                ok ->
                    Advance;
                {error, Reason} ->
                    ?LOG_ERROR(
                        #{what => server_cert_invalid, reason => Reason}, ?QUIC_LOG_META
                    ),
                    notify_owner({error, {certificate_invalid, Reason}}, State),
                    %% Synchronous close event so callers waiting on
                    %% `{closed, _}' fail fast, not after the alert
                    %% round-trips through the state machine.
                    notify_owner({closed, {certificate_invalid, Reason}}, State),
                    send_tls_alert(cert_alert_code(Reason), State)
            end;
        false ->
            ?LOG_ERROR(#{what => server_cert_verify_failed}, ?QUIC_LOG_META),
            notify_owner({error, {certificate_invalid, bad_signature}}, State),
            notify_owner({closed, {certificate_invalid, bad_signature}}, State),
            send_tls_alert(?TLS_ALERT_DECRYPT_ERROR, State)
    end.

%% Reject a client certificate (mutual TLS) the way verify_server_authentication
%% rejects a server one: tell the owner synchronously so a caller waiting on
%% `{closed, _}' fails fast, then send the matching TLS alert.
reject_client_cert(Reason, State) ->
    ?LOG_ERROR(#{what => client_cert_invalid, reason => Reason}, ?QUIC_LOG_META),
    notify_owner({error, {certificate_invalid, Reason}}, State),
    notify_owner({closed, {certificate_invalid, Reason}}, State),
    send_tls_alert(cert_alert_code(Reason), State).

cert_alert_code(unknown_ca) -> ?TLS_ALERT_UNKNOWN_CA;
cert_alert_code(no_trust_anchors) -> ?TLS_ALERT_UNKNOWN_CA;
cert_alert_code(no_certificate) -> ?TLS_ALERT_CERTIFICATE_REQUIRED;
cert_alert_code({hostname_mismatch, _}) -> ?TLS_ALERT_BAD_CERTIFICATE;
cert_alert_code(_) -> ?TLS_ALERT_BAD_CERTIFICATE.

%% Check timeouts
check_timeouts(State) ->
    Now = erlang:monotonic_time(millisecond),
    TimeSinceActivity = Now - State#state.last_activity,
    if
        TimeSinceActivity > (State#state.cfg)#conn_cfg.idle_timeout ->
            initiate_close(idle_timeout, State);
        true ->
            State
    end.

%%====================================================================
%% Retransmission
%%====================================================================

%% Retransmit frames from lost packets
%% IMPORTANT: Retransmissions must respect congestion control to prevent
%% bytes_in_flight from exceeding cwnd. Packets that can't be sent immediately
%% will be retried on the next PTO timeout or when cwnd allows.
retransmit_lost_packets([], State) ->
    State;
retransmit_lost_packets([#sent_packet{frames = Frames} | Rest], State) ->
    RetransmitFrames = quic_loss:retransmittable_frames(Frames),
    %% Filter out stream data beyond ReliableSize (RESET_STREAM_AT spec requirement)
    FilteredFrames = filter_reset_stream_at_data(RetransmitFrames, State),
    State1 = send_retransmit_frames_cc(FilteredFrames, State),
    retransmit_lost_packets(Rest, State1).

%% Filter stream data beyond ReliableSize for streams with RESET_STREAM_AT
%% Per draft-ietf-quic-reliable-stream-reset-07: Data beyond ReliableSize
%% SHOULD NOT be retransmitted
filter_reset_stream_at_data(Frames, #state{streams = Streams}) ->
    lists:filtermap(
        fun(Frame) ->
            case Frame of
                {stream, StreamId, Offset, Data, _Fin} ->
                    case maps:find(StreamId, Streams) of
                        {ok, #stream_state{send_reset_at = RS}} when RS =/= undefined ->
                            if
                                %% Entirely beyond the boundary - drop
                                Offset >= RS ->
                                    false;
                                %% Entirely below - retransmit unchanged
                                Offset + byte_size(Data) =< RS ->
                                    {true, Frame};
                                %% Straddles - truncate to the boundary, clear Fin
                                true ->
                                    {true,
                                        {stream, StreamId, Offset,
                                            binary:part(Data, 0, RS - Offset), false}}
                            end;
                        _ ->
                            %% No RESET_STREAM_AT - always retransmit
                            {true, Frame}
                    end;
                _ ->
                    %% Non-stream frames - always retransmit
                    {true, Frame}
            end
        end,
        Frames
    ).

%% Send frames for retransmission with congestion control check
send_retransmit_frames_cc([], State) ->
    State;
send_retransmit_frames_cc(Frames, State) ->
    send_retransmit_frames_cc(Frames, State, normal).

%% Mode `probe' (PTO) is exempt from congestion control per RFC 9002
%% §7.5. Gating probes on the control allowance deadlocks a full
%% window: bytes_in_flight sits at or just above cwnd, every PTO probe
%% is denied, no probe means no ACK, no ACK means loss detection never
%% runs, and the connection stalls until idle timeout with a full
%% sent_q. Mode `normal' (loss retransmission) stays subject to cwnd.
send_retransmit_frames_cc(Frames, #state{cc_state = CCState} = State, Mode) ->
    %% Encode all frames and check size
    Payload = iolist_to_binary([quic_frame:encode(F) || F <- Frames]),
    PacketSize = byte_size(Payload) + 50,

    case retransmit_cc_allowed(Mode, CCState, PacketSize) of
        true ->
            bump(?C_RETRANSMITS, 1, State),
            send_app_packet_internal(Payload, Frames, State);
        false ->
            %% CC doesn't allow yet. detect_lost_packets/2 already pulled these
            %% frames out of sent_q, so PTO would not retry them. Track them so
            %% they are resent (and so a RESET_STREAM_AT reclaim does not complete
            %% before its reliable bytes are actually re-delivered): stream data
            %% into FC-exempt retransmit_stream queue entries, control frames into
            %% deferred_ctrl_retransmits, both replayed when cwnd reopens.
            ?LOG_DEBUG(
                #{
                    what => retransmit_deferred_by_cc,
                    packet_size => PacketSize,
                    cwnd => quic_cc:cwnd(CCState),
                    bytes_in_flight => quic_cc:bytes_in_flight(CCState)
                },
                ?QUIC_LOG_META
            ),
            defer_retransmit_frames(Frames, State)
    end.

%% RFC 9002 §7: an endpoint MUST NOT exceed cwnd "unless the packet is
%% sent on a PTO timer expiration or when entering a recovery period".
%% A PTO probe is exempt outright; an ordinary loss retransmission
%% stays bound by the congestion window proper, not by the more
%% lenient control allowance.
retransmit_cc_allowed(probe, _CCState, _PacketSize) ->
    true;
retransmit_cc_allowed(normal, CCState, PacketSize) ->
    quic_cc:can_send(CCState, PacketSize).

%% Split CC-deferred lost frames: stream data into FC-exempt retransmit_stream
%% queue entries (retried by process_send_queue/1), control frames into
%% deferred_ctrl_retransmits (replayed by flush_deferred_retransmits/1).
defer_retransmit_frames(Frames, State) ->
    lists:foldl(
        fun
            ({stream, SId, Off, D, F}, S) ->
                enqueue_retransmit_stream(SId, Off, D, F, S);
            (Ctrl, S) ->
                S#state{
                    deferred_ctrl_retransmits = S#state.deferred_ctrl_retransmits ++ [Ctrl]
                }
        end,
        State,
        Frames
    ).

%% Queue a lost STREAM frame for retransmission. Exempt from flow control and
%% data_sent (those were counted on the original send); bytes/count/version are
%% updated like queue_stream_data/5 so the drain and reclaim-gate scans see it.
%% Front-inserted: retransmits fill receiver-side holes, so they must not sit
%% behind a flow-control-blocked head whose window can only grow once the hole
%% is filled.
enqueue_retransmit_stream(StreamId, Offset, Data, Fin, State) ->
    #state{
        send_queue = PQ,
        streams = Streams,
        send_queue_bytes = QueueBytes,
        send_queue_count = QueueCount,
        send_queue_version = Version
    } = State,
    DataSize = iolist_size(Data),
    Urgency = get_stream_urgency(StreamId, Streams),
    Entry = {retransmit_stream, StreamId, Offset, Data, Fin, DataSize},
    State#state{
        send_queue = quic_pqueue:in_front(Entry, Urgency, PQ),
        send_queue_bytes = QueueBytes + DataSize,
        send_queue_count = QueueCount + 1,
        send_queue_version = Version + 1
    }.

%% Replay CC-deferred control retransmits through the same CC-checked path. NOT
%% send_frame/2, which would bypass the congestion check. If cwnd is still
%% blocking, send_retransmit_frames_cc/2 re-defers them back into the list.
flush_deferred_retransmits(#state{deferred_ctrl_retransmits = []} = State) ->
    State;
flush_deferred_retransmits(#state{deferred_ctrl_retransmits = Deferred} = State) ->
    send_retransmit_frames_cc(Deferred, State#state{deferred_ctrl_retransmits = []}).

%% Drain pending local reset-at streams whose data below ReliableSize is now
%% fully acked (no longer queued or in flight), completing the reclaim.
complete_send_reset_at(#state{pending_send_reset_at = P} = State) when map_size(P) =:= 0 ->
    State;
complete_send_reset_at(#state{pending_send_reset_at = P} = State) ->
    maps:fold(
        fun(StreamId, RS, Acc) ->
            Pending =
                stream_has_queued_below(StreamId, RS, Acc#state.send_queue) orelse
                    quic_loss:stream_has_unacked_below(Acc#state.loss_state, StreamId, RS),
            case Pending of
                true ->
                    Acc;
                false ->
                    mark_send_done_and_reclaim(
                        StreamId,
                        Acc#state{
                            pending_send_reset_at =
                                maps:remove(StreamId, Acc#state.pending_send_reset_at)
                        }
                    )
            end
        end,
        State,
        P
    ).

%% Handle PTO timeout - send probe packet
%% The drain-path counterpart of do_send_data's inline FIN bookkeeping.
%% send_done is deliberately not set: that happens when the FIN is acked.
mark_fin_sent(StreamId, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, S} ->
            State#state{
                streams = maps:put(
                    StreamId,
                    S#stream_state{send_fin = true},
                    State#state.streams
                )
            };
        error ->
            State
    end.

%% The peer acked a FIN-bearing STREAM frame. The send side is done once
%% nothing below the final offset remains queued or in flight; otherwise
%% park it for complete_fin_reclaims/1 to finish on a later ack.
settle_fin_ack(StreamId, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream_state{send_done = true}} ->
            State;
        {ok, #stream_state{send_offset = Final}} ->
            Pending =
                stream_has_queued_below(StreamId, Final, State#state.send_queue) orelse
                    quic_loss:stream_has_unacked_below(
                        State#state.loss_state, StreamId, Final
                    ),
            case Pending of
                false ->
                    mark_send_done_and_reclaim(StreamId, State);
                true ->
                    State#state{
                        pending_fin_reclaim =
                            maps:put(StreamId, Final, State#state.pending_fin_reclaim)
                    }
            end;
        error ->
            State
    end.

%% Finish parked FIN reclaims whose remaining bytes are now acked.
complete_fin_reclaims(#state{pending_fin_reclaim = P} = State) when map_size(P) =:= 0 ->
    State;
complete_fin_reclaims(#state{pending_fin_reclaim = P} = State) ->
    maps:fold(
        fun(StreamId, Final, Acc) ->
            Pending =
                stream_has_queued_below(StreamId, Final, Acc#state.send_queue) orelse
                    quic_loss:stream_has_unacked_below(
                        Acc#state.loss_state, StreamId, Final
                    ),
            case Pending of
                true ->
                    Acc;
                false ->
                    mark_send_done_and_reclaim(
                        StreamId,
                        Acc#state{
                            pending_fin_reclaim =
                                maps:remove(StreamId, Acc#state.pending_fin_reclaim)
                        }
                    )
            end
        end,
        State,
        P
    ).

%% The deadline was a time threshold, not a probe: those packets are
%% presumed lost, so declare them and let the same consequences follow as
%% when an acknowledgement declares one. The probe backoff is untouched,
%% because nothing was probed.
handle_loss_timeout(#state{loss_state = LossState, pto_space = Space} = State) ->
    LargestAcked = quic_loss:largest_acked(LossState, Space),
    {NewLossState, Lost} = quic_loss:detect_lost_packets(Space, LossState, LargestAcked),
    State1 = State#state{loss_state = NewLossState},
    State2 = apply_lost_packets(Space, Lost, State1),
    flush_event(State2#state{pto_dirty = true}, event).

%% The congestion response, the retransmission and the qlog record that
%% follow a loss, wherever it was declared.
apply_lost_packets(_Space, [], State) ->
    State;
apply_lost_packets(Space, Lost, #state{cc_state = CCState, loss_state = LossState} = State) ->
    LostBytes = lists:sum([Sz || #sent_packet{size = Sz} <- Lost]),
    LargestLostSentTime = lists:max([TS || #sent_packet{time_sent = TS} <- Lost]),
    NewCC = cc_after_loss(CCState, LostBytes, LargestLostSentTime, undefined, Lost, LossState),
    lists:foreach(
        fun(#sent_packet{pn = LostPN}) ->
            ?QLOG_EMIT_PACKET_LOST((State#state.cfg)#conn_cfg.qlog_ctx, #{
                packet_number => LostPN, reason => timeout
            })
        end,
        Lost
    ),
    retransmit_for_space(Space, Lost, State#state{cc_state = NewCC}).

retransmit_for_space(app, Lost, State) -> retransmit_lost_packets(Lost, State);
retransmit_for_space(Space, Lost, State) -> retransmit_lost_handshake(Space, Lost, State).

handle_pto_timeout(#state{loss_state = LossState, pto_space = Space} = State) ->
    %% Increment PTO count
    NewLossState = quic_loss:on_pto_expired(LossState),
    State1 = State#state{loss_state = NewLossState},

    %% The probe goes out in the space the timer was armed for: at any
    %% other encryption level the peer cannot act on it, and before
    %% confirmation it could not even decrypt it. RFC 9002 Section 7
    %% exempts it from the congestion window, which is what stops a
    %% blocked connection deadlocking on its own.
    Probing = send_probe_packet(Space, State1#state{hs = (State1#state.hs)#hs{hs_probe = true}}),
    State2 = Probing#state{hs = (Probing#state.hs)#hs{hs_probe = false}},

    %% Probes use the control allowance, so retry any CC-deferred control
    %% retransmits here too (they are not in sent_q for the probe to pick up).
    State2a = flush_deferred_retransmits(State2),
    State2b = complete_send_reset_at(State2a),

    %% Flush immediately - probe packets and timers must not be batched
    State3 = flush_event(State2b, event),

    %% Set new PTO timer
    set_pto_timer(State3).

%% Send a probe packet for PTO
%% PTO probes are allowed to use control_allowance per RFC 9002
%% App-space PTO can fire before 1-RTT keys exist when tracked 0-RTT
%% packets are outstanding. Handshake-space recovery drives progress
%% until the keys arrive; sending nothing here avoids building an app
%% packet without keys.
send_probe_packet(app, #state{app_keys = undefined} = State) ->
    State;
send_probe_packet(app, State) ->
    case get_oldest_unacked_frames(app, State) of
        {ok, Frames} ->
            %% Retransmit oldest data as the probe, cwnd-exempt
            send_retransmit_frames_cc(Frames, State, probe);
        none ->
            %% No data to retransmit, send PING (always allowed as control)
            Payload = quic_frame:encode(ping),
            send_app_packet_internal(Payload, [ping], State)
    end;
send_probe_packet(Space, State) ->
    %% A handshake probe replays that space's oldest CRYPTO, or a PING at
    %% the same level when there is nothing outstanding, which is what
    %% the anti-deadlock timer arms for.
    case get_oldest_unacked_frames(Space, State) of
        {ok, Frames} ->
            lists:foldl(fun(F, Acc) -> send_at_level(Space, F, Acc) end, State, Frames);
        none ->
            send_at_level(Space, ping, State)
    end.

%% Get frames from the oldest unacked packet for probe retransmission
%% Uses cached oldest_unacked from loss_state for O(1) lookup
get_oldest_unacked_frames(Space, #state{loss_state = LossState}) ->
    case quic_loss:oldest_unacked(Space, LossState) of
        none ->
            none;
        {ok, #sent_packet{frames = Frames}} ->
            RetransmitFrames = quic_loss:retransmittable_frames(Frames),
            case RetransmitFrames of
                [] -> none;
                _ -> {ok, RetransmitFrames}
            end
    end.

%% Send keep-alive PING frame (RFC 9000 - transport-level liveness)
%% PING frames bypass flow control and ensure connection stays alive
send_keep_alive_ping(#state{app_keys = undefined} = State) ->
    %% No app keys yet, skip PING
    State;
send_keep_alive_ping(State) ->
    Payload = quic_frame:encode(ping),
    send_app_packet_internal(Payload, [ping], State).

%%====================================================================
%% PTO Timer Management
%%====================================================================

%% Set PTO timer based on current loss state
%% Uses unique reference in message to detect stale timer events.
%% Skips the cancel + reschedule cycle when the timer is already armed
%% and the new deadline is within ?PTO_RESET_TOLERANCE_MS of the existing
%% one; this eliminates most per-ACK timer churn in steady-state bulk
%% transfers where bytes_in_flight and smoothed RTT are stable.
%% Lazy re-arm: a send or ACK moves the deadline later, and the armed
%% timer is left alone; when it fires early the handler re-arms for the
%% remainder. Only a deadline that moved earlier by more than the
%% tolerance costs a cancel. Bulk transfers touched the PTO on every
%% packet, and cancel_timer + send_after per packet was a measurable
%% share of the server receive path on small hosts.
set_pto_timer(State) ->
    {Timer, ArmedAt, ScheduledAt, Space, Kind} = pto_plan(State),
    State#state{
        pto_timer = Timer,
        pto_armed_at = ArmedAt,
        pto_scheduled_at = ScheduledAt,
        pto_space = Space,
        pto_kind = Kind,
        pto_dirty = false
    }.

%% The PTO fields set_pto_timer/1 stores, cancelling or arming the timer
%% as needed: {Timer, ArmedAt, ScheduledAt, Space, Kind}.
pto_plan(
    #state{
        loss_state = LossState,
        pto_timer = OldTimer,
        pto_armed_at = ArmedAt,
        pto_space = OldSpace,
        pto_kind = OldKind
    } = State
) ->
    Now = erlang:monotonic_time(millisecond),
    %% RFC 9002 Appendix A.8. A server over its anti-amplification budget
    %% cannot send anything, so it arms nothing; the client is the one
    %% that has to keep probing to unblock it.
    %% RFC 9002 Appendix A.8 in order: a time-threshold loss deadline
    %% takes precedence over a probe, because those packets are already
    %% presumed lost and there is nothing to probe for.
    Selected =
        case {quic_loss:get_loss_time_and_space(LossState), amplification_blocked(State)} of
            {{LossAt, LossSpace}, _} -> {loss, LossAt, LossSpace};
            {none, true} -> none;
            {none, false} -> pto_selection(LossState, Now, State)
        end,
    case Selected of
        {Kind, Deadline, Space} ->
            PTO = max(0, Deadline - Now),
            Same = (Space =:= OldSpace) andalso (Kind =:= OldKind),
            case
                OldTimer =/= undefined andalso Same andalso
                    Deadline + ?PTO_RESET_TOLERANCE_MS >= ArmedAt
            of
                true ->
                    {OldTimer, ArmedAt, Deadline, OldSpace, OldKind};
                false ->
                    cancel_timer(OldTimer),
                    {Ref, NewArmedAt} = start_pto_timer(PTO),
                    {Ref, NewArmedAt, Deadline, Space, Kind}
            end;
        none ->
            cancel_timer(OldTimer),
            {undefined, ArmedAt, undefined, OldSpace, OldKind};
        _ ->
            {OldTimer, ArmedAt, undefined, OldSpace, OldKind}
    end.

pto_selection(LossState, Now, State) ->
    case quic_loss:get_pto_time_and_space(LossState, Now, handshake_status(State)) of
        {Deadline, Space} -> {pto, Deadline, Space};
        none -> none
    end.

%% A server has to stop at three times what it has received from an
%% unvalidated address (RFC 9000 Section 8.1).
amplification_blocked(
    #state{cfg = #conn_cfg{role = server}, hs = #hs{address_validated = false}} = State
) ->
    (State#state.hs)#hs.amp_tx >= 3 * (State#state.hs)#hs.amp_rx;
amplification_blocked(_State) ->
    false.

%% What Appendix A.8 needs that the loss state cannot hold. A server's
%% peer validates its address implicitly, so the predicate is constant
%% there; a client learns it from a Handshake acknowledgement or from
%% confirmation.
handshake_status(#state{cfg = #conn_cfg{role = server}}) ->
    #handshake_status{has_handshake_keys = true, peer_completed_address_validation = true};
handshake_status(#state{loss_state = LossState, hs = #hs{handshake_keys = HSKeys}} = State) ->
    #handshake_status{
        has_handshake_keys = HSKeys =/= undefined,
        peer_completed_address_validation =
            (State#state.hs)#hs.handshake_ack_received orelse
                quic_loss:handshake_confirmed(LossState)
    }.

arm_pto_timer(Delay, State) ->
    {Ref, ArmedAt} = start_pto_timer(Delay),
    State#state{pto_timer = Ref, pto_armed_at = ArmedAt}.

start_pto_timer(Delay) ->
    Ref = make_ref(),
    erlang:send_after(Delay, self(), {pto_timeout, Ref}),
    {Ref, erlang:monotonic_time(millisecond) + Delay}.

%% What a firing PTO timer should do: nothing (flight drained since it
%% was armed), wait the remainder (deadline moved later), or probe.
pto_due(#state{pto_scheduled_at = undefined}) ->
    idle;
pto_due(#state{pto_scheduled_at = Deadline}) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline - Now > ?PTO_RESET_TOLERANCE_MS of
        true -> {later, Deadline - Now};
        false -> due
    end.

%% Helper to cancel a timer reference
cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).

%% Handle pacing timeout - drain queued data
%% Note: pacing_timer is already set to undefined by the handler before calling this
%% Fast path: send_queue_count == 0 implies queue is empty, avoiding the
%% O(8) bucket walk in quic_pqueue:is_empty/1. Byte count is NOT safe here
%% because zero-byte FIN-only entries can sit in the queue with bytes=0.
handle_pacing_timeout(State0) ->
    %% Handshake packets the pacer refused are not in the application
    %% send queue, so they are drained before the fast path that looks
    %% only at that queue.
    State = drain_pending_hs(State0#state{burst_sent = 0}),
    ?LOG_DEBUG(
        #{what => pacing_timeout_fired, queue_empty => (State#state.send_queue_count =:= 0)},
        ?QUIC_LOG_META
    ),
    Processed =
        case State#state.send_queue_count of
            0 -> State;
            _ -> maybe_reschedule_pacing(process_send_queue(State))
        end,
    flush_event(Processed, event).

%% Check if we need to reschedule pacing timer after processing queue
maybe_reschedule_pacing(
    #state{send_queue = PQ, cc_state = CCState, cfg = #conn_cfg{pacing_enabled = true}} = State
) ->
    case quic_pqueue:is_empty(PQ) of
        true ->
            State;
        false ->
            %% Check if pacing would block the next send
            MaxChunkSize = get_max_stream_data_per_packet(State),
            PacketSize = MaxChunkSize + ?PACKET_OVERHEAD,
            case quic_cc:can_send(CCState, PacketSize) of
                true ->
                    %% Cwnd allows, check pacing
                    case quic_cc:pacing_allows(CCState, PacketSize) of
                        true ->
                            %% Can send now - no timer needed
                            State;
                        false ->
                            %% Pacing blocked - set timer
                            Delay = quic_cc:pacing_delay(CCState, PacketSize),
                            maybe_set_pacing_timer(Delay, State)
                    end;
                false ->
                    %% Cwnd blocked - no pacing timer needed
                    State
            end
    end;
maybe_reschedule_pacing(State) ->
    State.

%%====================================================================
%% Idle Timer Management (RFC 9000 §10.1)
%%====================================================================

%% Set idle timer based on idle_timeout configuration
%% Uses unique reference in message to detect stale timer events
set_idle_timer(#state{cfg = #conn_cfg{idle_timeout = 0}} = State) ->
    State#state{idle_timer = undefined};
set_idle_timer(
    #state{
        idle_timer = OldTimer, last_activity = LastActivity, cfg = #conn_cfg{idle_timeout = Timeout}
    } = State
) ->
    cancel_timer(OldTimer),
    %% Lazy re-arm: fire when the connection would actually be idle for
    %% Timeout, measured from last_activity. At the initial arm
    %% last_activity = Now, so this is the full timeout; a spurious-fire
    %% re-arm is the remaining time, not a fresh full timeout.
    Now = erlang:monotonic_time(millisecond),
    Delay = max(0, (LastActivity + Timeout) - Now),
    Ref = make_ref(),
    erlang:send_after(Delay, self(), {idle_timeout, Ref}),
    State#state{idle_timer = Ref}.

%%====================================================================
%% Keep-Alive Timer Management (RFC 9000 - PING frames), and local
%% address lookup, which shares this region without belonging to it
%%====================================================================

%% Calculate keep-alive interval from options and idle timeout
%% Default: disabled (opt-in to preserve idle_timeout semantics)
%% Set to 'auto' for half of idle timeout, or specify explicit interval
%% Query the local address for either a gen_udp port or an OTP
%% socket handle ({'$socket', Ref}). inet:sockname/1 only accepts
%% the gen_udp port shape, socket:sockname/1 the other. Returns
%% undefined if neither succeeds.
query_local_addr(Ref) when is_reference(Ref) ->
    %% Adapter backend: no real socket, no kernel-known sockname.
    undefined;
query_local_addr({'$socket', _} = Socket) ->
    case socket:sockname(Socket) of
        {ok, #{addr := IP, port := Port}} -> {IP, Port};
        {error, _} -> undefined
    end;
query_local_addr(Socket) ->
    case inet:sockname(Socket) of
        {ok, Sockname} -> Sockname;
        {error, _} -> undefined
    end.

disconnect_timeout_expired(#state{cfg = #conn_cfg{disconnect_timeout = infinity}}) ->
    false;
disconnect_timeout_expired(#state{loss_state = LossState, cfg = #conn_cfg{disconnect_timeout = DT}}) ->
    quic_loss:bytes_in_flight(LossState) > 0 andalso
        case quic_loss:last_progress(LossState) of
            undefined ->
                false;
            T ->
                erlang:monotonic_time(millisecond) - T >= DT
        end.

%% The disconnect timeout elapsed with ack-eliciting data in flight and
%% no ACK: declare the peer dead instead of probing until the idle
%% timeout. This is how a client escapes a restarted peer whose stateless
%% resets it cannot recognise.
declare_peer_dead(State) ->
    ?LOG_NOTICE(
        #{
            what => disconnect_timeout,
            in_flight => quic_loss:bytes_in_flight(State#state.loss_state),
            pto_count => quic_loss:pto_count(State#state.loss_state)
        },
        ?QUIC_LOG_META
    ),
    initiate_close(disconnect_timeout, cancel_disconnect_timer(State)).

cancel_disconnect_timer(#state{disconnect_timer = undefined} = State) ->
    State;
cancel_disconnect_timer(#state{disconnect_timer = Ref} = State) ->
    cancel_timer(Ref),
    State#state{disconnect_timer = undefined}.

%% Arm the disconnect check at the deadline itself. Lazy, like the idle
%% timer: a fire that finds the deadline moved re-arms the remainder.
%% The delay is never zero, so this cannot spin the way a re-arm derived
%% from a stale timestamp would.
arm_disconnect_timer(#state{cfg = #conn_cfg{disconnect_timeout = infinity}} = State) ->
    cancel_disconnect_timer(State);
arm_disconnect_timer(
    #state{loss_state = LossState, cfg = #conn_cfg{disconnect_timeout = DT}} = State
) ->
    Delay =
        case quic_loss:last_progress(LossState) of
            undefined ->
                DT;
            T ->
                case quic_loss:bytes_in_flight(LossState) > 0 of
                    true -> max(1, (T + DT) - erlang:monotonic_time(millisecond));
                    false -> DT
                end
        end,
    State1 = cancel_disconnect_timer(State),
    Ref = make_ref(),
    erlang:send_after(Delay, self(), {disconnect_check, Ref}),
    State1#state{disconnect_timer = Ref}.

%% Disconnect-timeout option: how long ack-eliciting data may stay in
%% flight without any ACK before the peer is declared dead.
disconnect_timeout_opt(Opts) ->
    case maps:get(disconnect_timeout, Opts, 16000) of
        infinity -> infinity;
        T when is_integer(T), T >= 1000 -> T;
        _ -> 16000
    end.

calculate_keep_alive_interval(Opts, IdleTimeout) ->
    case maps:get(keep_alive_interval, Opts, disabled) of
        disabled -> disabled;
        0 -> disabled;
        auto when IdleTimeout =:= 0 -> disabled;
        auto -> max(5000, IdleTimeout div 2);
        Interval when is_integer(Interval), Interval >= 5000 -> Interval;
        Interval when is_integer(Interval) -> 5000
    end.

%% Set keep-alive timer
%% Uses unique reference in message to detect stale timer events
set_keep_alive_timer(#state{cfg = #conn_cfg{keep_alive_interval = disabled}} = State) ->
    State#state{keep_alive_timer = undefined};
set_keep_alive_timer(
    #state{
        last_activity = LastActivity,
        cfg = #conn_cfg{
            keep_alive_interval = Interval
        }
    } = State
) ->
    %% Lazy re-arm against last_activity (same model as the idle timer):
    %% full interval on the initial arm, the remainder on a spurious fire.
    Now = erlang:monotonic_time(millisecond),
    arm_keep_alive_timer(State, max(0, (LastActivity + Interval) - Now)).

%% Arm the keep-alive timer with an explicit delay.
arm_keep_alive_timer(#state{cfg = #conn_cfg{keep_alive_interval = disabled}} = State, _Delay) ->
    State#state{keep_alive_timer = undefined};
arm_keep_alive_timer(#state{keep_alive_timer = OldTimer} = State, Delay) ->
    cancel_timer(OldTimer),
    Ref = make_ref(),
    erlang:send_after(Delay, self(), {keep_alive_timeout, Ref}),
    State#state{keep_alive_timer = Ref}.

%%====================================================================
%% Pacing Timer Management (RFC 9002 §7.7)
%%====================================================================

%% Set pacing timer if not already set
%% Only sets a timer if there's data queued and no existing timer
%% Uses unique reference in message to detect stale timer events
maybe_set_pacing_timer(0, State) ->
    %% No delay - don't set timer
    State;
maybe_set_pacing_timer(_Delay, #state{pacing_timer = Ref} = State) when Ref =/= undefined ->
    %% Timer already set - leave it
    State;
maybe_set_pacing_timer(Delay, #state{pacing_timer = undefined} = State) ->
    %% Set new pacing timer
    ?LOG_DEBUG(#{what => pacing_timer_set, delay_ms => Delay}, ?QUIC_LOG_META),
    Ref = make_ref(),
    erlang:send_after(Delay, self(), {pacing_timeout, Ref}),
    State#state{pacing_timer = Ref}.

%% Burst budget: bounds packets emitted per drain (see burst_budget).
burst_exhausted(#state{burst_sent = Sent, cfg = #conn_cfg{burst_budget = Budget}}) ->
    Sent >= Budget.

%% Arm a zero-delay pacing continuation so the queued remainder is
%% drained in the next event-loop pass, after any pending ACK / loss
%% feedback in the mailbox. Reuses the pacing message so the drain and
%% stale-reference handling are shared with real pacing, but sends it
%% directly: send_after(0) goes through the timer wheel, whose ~1 ms
%% service tick would clock every burst continuation (64 packets/ms
%% caps bulk streams at ~85 MB/s regardless of rate).
arm_burst_continuation(#state{pacing_timer = Ref} = State) when Ref =/= undefined ->
    State;
arm_burst_continuation(State) ->
    Ref = make_ref(),
    self() ! {pacing_timeout, Ref},
    State#state{pacing_timer = Ref}.

%% Convert state to map for debugging
state_to_map(#state{} = S) ->
    #{
        scid => (S#state.cfg)#conn_cfg.scid,
        dcid => S#state.dcid,
        role => (S#state.cfg)#conn_cfg.role,
        version => S#state.version,
        tls_state => (S#state.hs)#hs.tls_state,
        alpn => S#state.alpn,
        streams => maps:size(S#state.streams),
        data_sent => S#state.data_sent,
        data_received => S#state.data_received,
        send_queue_bytes => S#state.send_queue_bytes,
        send_queue_count => S#state.send_queue_count,
        %% Per-connection send-path observability. send_backend is
        %% `direct' when the connection bypasses quic_socket (typical
        %% server connections before the batching opt-in landed).
        send_backend => send_backend(S#state.socket_state),
        send_batching_enabled => send_batching_enabled(S#state.socket_state),
        send_gso_supported => send_gso_supported(S#state.socket_state),
        recv_buffer_bytes => S#state.recv_buffer_bytes,
        max_data_local => S#state.max_data_local,
        fc_last_stream_update => S#state.fc_last_stream_update,
        fc_last_conn_update => S#state.fc_last_conn_update,
        fc_max_receive_window => (S#state.cfg)#conn_cfg.fc_max_receive_window,
        idle_timer_armed => S#state.idle_timer =/= undefined,
        keep_alive_timer_armed => S#state.keep_alive_timer =/= undefined,
        %% CID rotation observability: local_cid_count includes sequence 0,
        %% peer_cid_count is what the peer has issued to us.
        local_cid_count => quic_cid:local_active_count(S#state.cid_pool_state),
        peer_cid_count => quic_cid:peer_active_count(S#state.cid_pool_state)
    }.

%% Send-path observability helpers. Each reads one field from the
%% current #socket_state{} via quic_socket:info/1 (single map lookup),
%% or returns the "no batching wrapper" value when socket_state is
%% undefined.
send_backend(undefined) ->
    direct;
send_backend(SocketState) ->
    maps:get(backend, quic_socket:info(SocketState)).

send_batching_enabled(undefined) ->
    false;
send_batching_enabled(SocketState) ->
    maps:get(batching_enabled, quic_socket:info(SocketState)).

send_gso_supported(undefined) ->
    false;
send_gso_supported(SocketState) ->
    maps:get(gso_supported, quic_socket:info(SocketState)).

send_batch_counters(undefined) ->
    {0, 0, 0, 0};
send_batch_counters(SocketState) ->
    Info = quic_socket:info(SocketState),
    {
        maps:get(batch_flushes, Info),
        maps:get(packets_coalesced, Info),
        maps:get(gso_flushes, Info),
        maps:get(batch_pending, Info)
    }.

%% Normalize ALPN list - handles binary, list of binaries, list of strings
normalize_alpn_list(undefined) ->
    [];
normalize_alpn_list(V) when is_binary(V) ->
    [V];
normalize_alpn_list([]) ->
    [];
normalize_alpn_list([H | _] = L) when is_binary(H) ->
    L;
normalize_alpn_list([H | _] = L) when is_list(H) ->
    [list_to_binary(S) || S <- L];
normalize_alpn_list([H | _] = L) when is_atom(H) ->
    [atom_to_binary(A, utf8) || A <- L];
normalize_alpn_list(_) ->
    [].

%%====================================================================
%% Key Update (RFC 9001 Section 6)
%%====================================================================

%% @doc Initiate a key update.
%% Derives new application secrets and keys, switches to the new key phase.
%% RFC 9001 Section 6.6: HP keys are NOT rotated during key updates.
%% Count an outgoing 1-RTT packet toward the AEAD confidentiality limit
%% and force a key update before it is reached (RFC 9001 §6.6). Only the
%% first over-limit packet in an idle phase triggers the update; the
%% counter resets when the new phase begins.
%% N packets at once, for the chunk-run sender.
maybe_force_key_update(#state{key_state = undefined} = State, _N) ->
    State;
maybe_force_key_update(#state{key_state = KeyState} = State, N) ->
    {NewKeyState, KeyLimit} = count_sealed(KeyState, N),
    after_sealed(KeyLimit, State#state{key_state = NewKeyState}).

%% The key state with N more packets sealed, and whether that reached the
%% confidentiality limit with no update in progress.
count_sealed(undefined, _N) ->
    {undefined, false};
count_sealed(KeyState, N) ->
    NewCount = KeyState#key_update_state.send_count + N,
    {
        KeyState#key_update_state{send_count = NewCount},
        NewCount >= ?AEAD_CONFIDENTIALITY_LIMIT andalso
            KeyState#key_update_state.update_state =:= idle
    }.

after_sealed(true, State) -> initiate_key_update(State);
after_sealed(false, State) -> State.

initiate_key_update(#state{key_state = KeyState} = State) ->
    #key_update_state{
        current_phase = CurrentPhase,
        current_keys = CurrentKeys,
        client_app_secret = ClientSecret,
        server_app_secret = ServerSecret
    } = KeyState,

    %% Get cipher and HP keys from current keys (HP keys don't change)
    {OldClientKeys, OldServerKeys} = CurrentKeys,
    Cipher = OldClientKeys#crypto_keys.cipher,

    %% Derive new secrets using "quic ku" label
    {NewClientSecret, {NewClientKey, NewClientIV, _}} =
        quic_keys:derive_updated_keys(ClientSecret, Cipher, State#state.version),
    {NewServerSecret, {NewServerKey, NewServerIV, _}} =
        quic_keys:derive_updated_keys(ServerSecret, Cipher, State#state.version),

    %% Create new crypto_keys records (preserve HP keys per RFC 9001 Section 6.6)
    NewClientKeys = #crypto_keys{
        key = NewClientKey,
        iv = NewClientIV,
        % HP key unchanged
        hp = OldClientKeys#crypto_keys.hp,
        cipher = Cipher
    },
    NewServerKeys = #crypto_keys{
        key = NewServerKey,
        iv = NewServerIV,
        % HP key unchanged
        hp = OldServerKeys#crypto_keys.hp,
        cipher = Cipher
    },

    %% Toggle key phase
    NewPhase = 1 - CurrentPhase,

    %% Update key state
    NewKeyState = KeyState#key_update_state{
        current_phase = NewPhase,
        current_keys = {NewClientKeys, NewServerKeys},
        % Keep old keys for decryption during transition
        prev_keys = CurrentKeys,
        client_app_secret = NewClientSecret,
        server_app_secret = NewServerSecret,
        update_state = initiated,
        % New phase: reset the AEAD send counter.
        send_count = 0
    },

    State#state{
        app_keys = {NewClientKeys, NewServerKeys},
        key_state = NewKeyState
    }.

%% @doc Handle receiving a packet with a different key phase.
%% This is called when we receive a packet with a key phase that differs
%% from our current phase, indicating the peer has initiated a key update.
handle_peer_key_update(#state{key_state = KeyState} = State) ->
    #key_update_state{
        current_phase = CurrentPhase,
        current_keys = CurrentKeys,
        client_app_secret = ClientSecret,
        server_app_secret = ServerSecret,
        update_state = UpdateState
    } = KeyState,

    case UpdateState of
        initiated ->
            %% We initiated, peer responded - complete the update
            NewKeyState = KeyState#key_update_state{
                prev_keys = undefined,
                update_state = idle
            },
            State#state{key_state = NewKeyState};
        idle ->
            %% Peer initiated - we need to respond by deriving new keys
            %% RFC 9001 Section 6.6: HP keys are NOT rotated during key updates
            {OldClientKeys, OldServerKeys} = CurrentKeys,
            Cipher = OldClientKeys#crypto_keys.cipher,

            %% Derive new secrets
            {NewClientSecret, {NewClientKey, NewClientIV, _}} =
                quic_keys:derive_updated_keys(ClientSecret, Cipher, State#state.version),
            {NewServerSecret, {NewServerKey, NewServerIV, _}} =
                quic_keys:derive_updated_keys(ServerSecret, Cipher, State#state.version),

            NewClientKeys = #crypto_keys{
                key = NewClientKey,
                iv = NewClientIV,
                % HP key unchanged
                hp = OldClientKeys#crypto_keys.hp,
                cipher = Cipher
            },
            NewServerKeys = #crypto_keys{
                key = NewServerKey,
                iv = NewServerIV,
                % HP key unchanged
                hp = OldServerKeys#crypto_keys.hp,
                cipher = Cipher
            },

            NewPhase = 1 - CurrentPhase,
            NewKeyState = KeyState#key_update_state{
                current_phase = NewPhase,
                current_keys = {NewClientKeys, NewServerKeys},
                prev_keys = CurrentKeys,
                client_app_secret = NewClientSecret,
                server_app_secret = NewServerSecret,
                update_state = responding,
                send_count = 0
            },
            State#state{
                app_keys = {NewClientKeys, NewServerKeys},
                key_state = NewKeyState
            };
        responding ->
            %% Already responding, just continue
            State
    end.

%% @doc Select the appropriate keys for decryption based on the received key phase.
%% Returns {Keys, State} where State may be updated if a key update is detected.
select_decrypt_keys(_ReceivedKeyPhase, #state{key_state = undefined} = State) ->
    %% No key state yet, use app_keys directly (should not happen in practice)
    {State#state.app_keys, State};
select_decrypt_keys(ReceivedKeyPhase, #state{key_state = KeyState} = State) ->
    #key_update_state{
        current_phase = CurrentPhase,
        current_keys = CurrentKeys,
        prev_keys = PrevKeys,
        update_state = UpdateState
    } = KeyState,

    case ReceivedKeyPhase of
        CurrentPhase when UpdateState =:= idle ->
            %% Same phase, no update in progress.
            {CurrentKeys, State};
        CurrentPhase ->
            %% A packet in the current phase confirms the in-progress key
            %% update: return to idle so the next update (ours or, after a
            %% peer update, the peer's) can proceed (RFC 9001 §6.1). We keep
            %% prev_keys for the transition so a delayed old-phase packet
            %% still decrypts, while never re-deriving keys for an old phase
            %% (that path requires prev_keys = undefined), which avoids a
            %% replayed old-phase packet flipping keys backward.
            {CurrentKeys, State#state{
                key_state = KeyState#key_update_state{update_state = idle}
            }};
        _ ->
            %% Different phase - could be peer initiating update or using prev keys
            case PrevKeys of
                undefined ->
                    %% No previous keys, peer is initiating update
                    %% Handle the key update and decrypt with new keys
                    State1 = handle_peer_key_update(State),
                    {State1#state.key_state#key_update_state.current_keys, State1};
                _ ->
                    %% Try previous keys (during transition period)
                    {PrevKeys, State}
            end
    end.

%% @doc Get the current key phase for sending.
get_current_key_phase(#state{key_state = undefined}) -> 0;
get_current_key_phase(#state{key_state = KeyState}) -> KeyState#key_update_state.current_phase.

%%====================================================================
%% Connection Migration (RFC 9000 Section 9)
%%====================================================================

%% @doc Initiate path validation by sending PATH_CHALLENGE to the new path.
%% RFC 9000 Section 8.2: PATH_CHALLENGE must be sent to the path being validated.
%% Returns updated state with the path in validating status.
-spec initiate_path_validation({inet:ip_address(), inet:port_number()}, #state{}) -> #state{}.
initiate_path_validation(RemoteAddr, State) ->
    case start_path_probe(RemoteAddr, State) of
        {ok, State1, _DCID, _Seq} -> State1;
        none -> State
    end.

%% Bind a CID to the path, record it, and send the first PATH_CHALLENGE
%% under it. The CID is bound before the path's first packet, so the probe
%% itself is already unlinkable from the old path (RFC 9000 Section 9.5),
%% and `none' means the path cannot be probed at all.
-spec start_path_probe({inet:ip_address(), inet:port_number()}, #state{}) ->
    {ok, #state{}, binary(), non_neg_integer()} | none.
start_path_probe(RemoteAddr, State) ->
    case bind_path_cid(RemoteAddr, State) of
        {ok, State0, DCID, Seq} ->
            ChallengeData = crypto:strong_rand_bytes(8),
            PathState = #path_state{
                remote_addr = RemoteAddr,
                status = validating,
                challenge_data = ChallengeData,
                challenge_count = 1,
                bytes_sent = 0,
                bytes_received = 0,
                dcid = DCID,
                dcid_seq = Seq
            },
            State1 = State0#state{
                mig = (State0#state.mig)#mig{
                    alt_paths = [PathState | (State0#state.mig)#mig.alt_paths]
                }
            },
            {ok, send_path_challenge(RemoteAddr, ChallengeData, DCID, State1), DCID, Seq};
        none ->
            none
    end.

%% Take a peer CID for a path, keyed by its address so the same path never
%% binds twice.
bind_path_cid(PathRef, #state{cid_pool_state = Pool, dcid = CurrentDCID} = State) ->
    case quic_cid:bind_peer_cid(Pool, PathRef, CurrentDCID) of
        {ok, Pool1, DCID, Seq} -> {ok, State#state{cid_pool_state = Pool1}, DCID, Seq};
        none -> none
    end.

%% The CID a path probes under, falling back to the connection's when the
%% path never bound one (a NAT rebinding).
path_dcid(#path_state{dcid = DCID}, _State) when DCID =/= undefined -> DCID;
path_dcid(_PathState, #state{dcid = DCID}) -> DCID.

%% Retire the CID an abandoned path bound, if it bound one. A path that
%% kept the connection's CID (a NAT rebinding) leaves it alone.
retire_abandoned_path_cid(#path_state{dcid = DCID, dcid_seq = Seq}, State) when
    Seq =/= undefined
->
    retire_path_cid(DCID, State);
retire_abandoned_path_cid(_PathState, State) ->
    State.

%% Retire the CID we moved away from, unless the path kept using it (a NAT
%% rebinding, where no switch happened).
retire_replaced_dcid(Same, Same, State) -> State;
retire_replaced_dcid(OldDCID, _NewDCID, State) -> retire_path_cid(OldDCID, State).

%% Retire a CID a path has stopped using, announce it and drop the entry.
%% RFC 9000 Section 5.1.2: a CID we will not use again is retired rather
%% than left outstanding against the peer's limit.
retire_path_cid(undefined, State) ->
    State;
retire_path_cid(CID, #state{cid_pool_state = Pool} = State) ->
    case quic_cid:retire_peer(Pool, CID) of
        {ok, Pool1, SeqNum} ->
            State1 = send_retire_connection_ids([SeqNum], State#state{cid_pool_state = Pool1}),
            prune_retired_peer_cids(State1);
        not_found ->
            State
    end.

%% @doc Send PATH_CHALLENGE frame to a specific address.
%% This is used for path validation where the probe must go to the new path.
%% Uses the same packet encoding as send_frame but sends to a different address.
-spec send_path_challenge({inet:ip_address(), inet:port_number()}, binary(), #state{}) -> #state{}.
send_path_challenge(Addr, ChallengeData, #state{dcid = DCID} = State) ->
    send_path_challenge(Addr, ChallengeData, DCID, State).

%% A probe carries the CID bound to the path it probes: RFC 9000 Section 9.5
%% forbids reusing a CID across paths, and the challenge is the path's first
%% packet.
send_path_challenge(
    {IP, Port},
    ChallengeData,
    DCID,
    #state{
        app_keys = AppKeys,
        pn_app = PNSpace,
        cfg = #conn_cfg{
            role = Role
        }
    } = State
) ->
    %% Check we have app keys for encryption
    case AppKeys of
        {ClientKeys, ServerKeys} when ClientKeys =/= undefined, ServerKeys =/= undefined ->
            %% Select correct keys based on role
            EncryptKeys =
                case Role of
                    client -> ClientKeys;
                    server -> ServerKeys
                end,

            %% Build PATH_CHALLENGE frame
            ChallengeFrame = {path_challenge, ChallengeData},
            Payload = quic_frame:encode(ChallengeFrame),
            %% RFC 9000 Section 8.2.1: Pad to 1200 bytes for path validation
            PaddedPayload = pad_for_path_validation(Payload, DCID),

            %% Get packet number and key phase
            PN = PNSpace#pn_space.next_pn,
            PNLen = quic_packet:pn_length(PN),
            KeyPhase = get_current_key_phase(State),

            %% Build first byte for short header
            FirstByte = short_header_first_byte(KeyPhase, PNLen, State),

            %% Encrypt packet
            #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = EncryptKeys,
            Packet = quic_aead:protect_short_packet(
                Cipher, Key, IV, HP, PN, FirstByte, DCID, PaddedPayload
            ),

            %% Send to the specific path address (not current remote_addr)
            case send_packet_to_addr(IP, Port, Packet, State) of
                ok ->
                    %% Update path bytes_sent for anti-amplification tracking
                    PacketSize = byte_size(Packet),
                    State1 = update_path_bytes_sent(IP, Port, PacketSize, State),
                    %% Increment packet number
                    NewPnApp = PNSpace#pn_space{next_pn = PN + 1},
                    State1#state{pn_app = NewPnApp};
                {error, _Reason} ->
                    State
            end;
        _ ->
            %% No app keys yet, can't send path validation
            ?LOG_DEBUG(#{what => path_challenge_no_keys}, ?QUIC_LOG_META),
            State
    end.

%% @doc Send PATH_RESPONSE to a specific address with proper 1200-byte padding.
%% RFC 9000 Section 8.2.1: PATH_RESPONSE MUST be padded to at least 1200 bytes.
%% RFC 9000 Section 8.2.2: PATH_RESPONSE MUST be sent to the source address of
%% the packet containing the PATH_CHALLENGE.
-spec send_path_response_to_addr(
    {inet:ip_address(), inet:port_number()},
    binary(),
    #state{}
) -> #state{}.
send_path_response_to_addr(
    {IP, Port},
    ResponseData,
    #state{
        dcid = DCID,
        app_keys = AppKeys,
        pn_app = PNSpace,
        cfg = #conn_cfg{
            role = Role
        }
    } = State
) ->
    case AppKeys of
        {ClientKeys, ServerKeys} when ClientKeys =/= undefined, ServerKeys =/= undefined ->
            EncryptKeys =
                case Role of
                    client -> ClientKeys;
                    server -> ServerKeys
                end,

            %% Build PATH_RESPONSE frame
            ResponseFrame = {path_response, ResponseData},
            Payload = quic_frame:encode(ResponseFrame),
            %% RFC 9000 Section 8.2.1: Pad to 1200 bytes for path validation
            PaddedPayload = pad_for_path_validation(Payload, DCID),

            %% Get packet number and key phase
            PN = PNSpace#pn_space.next_pn,
            PNLen = quic_packet:pn_length(PN),
            KeyPhase = get_current_key_phase(State),

            %% Build first byte for short header
            FirstByte = short_header_first_byte(KeyPhase, PNLen, State),

            %% Encrypt packet
            #crypto_keys{key = Key, iv = IV, hp = HP, cipher = Cipher} = EncryptKeys,
            Packet = quic_aead:protect_short_packet(
                Cipher, Key, IV, HP, PN, FirstByte, DCID, PaddedPayload
            ),

            %% Send to the address that sent the PATH_CHALLENGE (not current remote_addr)
            case send_packet_to_addr(IP, Port, Packet, State) of
                ok ->
                    %% Increment packet number
                    NewPnApp = PNSpace#pn_space{next_pn = PN + 1},
                    State#state{pn_app = NewPnApp};
                {error, _Reason} ->
                    State
            end;
        _ ->
            %% No app keys yet
            ?LOG_DEBUG(#{what => path_response_no_keys}, ?QUIC_LOG_META),
            State
    end.

%% @doc Update bytes_sent for anti-amplification tracking on a path.
-spec update_path_bytes_sent(inet:ip_address(), inet:port_number(), non_neg_integer(), #state{}) ->
    #state{}.
update_path_bytes_sent(IP, Port, Bytes, #state{mig = #mig{alt_paths = AltPaths}} = State) ->
    NewAltPaths = lists:map(
        fun
            (#path_state{remote_addr = {PathIP, PathPort}} = PS) when
                PathIP =:= IP, PathPort =:= Port
            ->
                PS#path_state{bytes_sent = PS#path_state.bytes_sent + Bytes};
            (PS) ->
                PS
        end,
        AltPaths
    ),
    State#state{mig = (State#state.mig)#mig{alt_paths = NewAltPaths}}.

%% @doc Initiate path validation for server's preferred address (RFC 9000 Section 9.6).
%% Client validates the preferred address before migrating to it.
%% Prefers IPv6 over IPv4 when both are available.
-spec initiate_preferred_address_validation(#preferred_address{}, #state{}) -> #state{}.
initiate_preferred_address_validation(
    #preferred_address{cid = CID, stateless_reset_token = Token} = PA, State
) ->
    %% RFC 9000 Section 9.6: the client must use the CID the preferred
    %% address carries, which has an implicit sequence number of 1.
    State1 =
        case quic_cid:add_preferred_address_cid(State#state.cid_pool_state, CID, Token) of
            {ok, NewPool} ->
                State#state{
                    cid_pool_state = NewPool, mig = (State#state.mig)#mig{preferred_address = PA}
                };
            {error, Reason} ->
                ?LOG_DEBUG(
                    #{what => preferred_address_cid_rejected, reason => Reason},
                    ?QUIC_LOG_META
                ),
                State#state{mig = (State#state.mig)#mig{preferred_address = PA}}
        end,
    %% Choose address - prefer IPv6 over IPv4
    case select_preferred_addr(PA) of
        undefined ->
            %% No valid address to validate
            State1;
        RemoteAddr ->
            initiate_path_validation(RemoteAddr, State1)
    end.

%% Select the preferred address (IPv6 over IPv4)
select_preferred_addr(#preferred_address{ipv6_addr = IPv6, ipv6_port = IPv6Port}) when
    IPv6 =/= undefined, IPv6Port =/= undefined
->
    {IPv6, IPv6Port};
select_preferred_addr(#preferred_address{ipv4_addr = IPv4, ipv4_port = IPv4Port}) when
    IPv4 =/= undefined, IPv4Port =/= undefined
->
    {IPv4, IPv4Port};
select_preferred_addr(_) ->
    undefined.

%% @doc Rebind socket to a new local port (simulates network change).
%% Open new before closing old so an allocation failure leaves the
%% caller's handle usable.
-spec rebind_socket(gen_udp:socket(), inet | inet6) -> {ok, gen_udp:socket()} | {error, term()}.
rebind_socket(OldSocket, Family) ->
    {ok, [{active, Active}]} = inet:getopts(OldSocket, [active]),
    case gen_udp:open(0, [binary, Family, {active, Active}]) of
        {ok, NewSocket} ->
            gen_udp:close(OldSocket),
            {ok, NewSocket};
        {error, _} = Error ->
            Error
    end.

%% @doc Rebind the client's UDP socket for migration. Dispatches on
%% `#state.client_socket_backend' so both the gen_udp and opt-in
%% socket paths pick up a fresh local port without the other path's
%% primitives crashing on the wrong handle.
-spec rebind_client_socket(#state{}) -> {ok, #state{}} | {error, term()}.
rebind_client_socket(#state{cfg = #conn_cfg{client_socket_backend = socket}} = State) ->
    rebind_client_socket_otp(State);
rebind_client_socket(#state{cfg = #conn_cfg{client_socket_backend = adapter}}) ->
    %% Connection migration via fresh local UDP port has no analogue
    %% when the transport is a caller-supplied adapter.
    {error, not_supported_on_adapter};
rebind_client_socket(
    #state{socket = OldSocket, socket_state = OldSocketState, remote_addr = {RemoteIP, _}} = State
) ->
    %% Flush any pending batch to the old socket before rebinding so
    %% already-sequenced packets reach the server under the pre-migrate
    %% path. Without this flush, encrypted packets sitting in
    %% `#socket_state.batch_buffer' would either be silently dropped
    %% (old closed socket) or replayed from the new addr with stale
    %% CIDs (mis-routed on the server side).
    State0 = flush_socket_batch(State),
    case rebind_socket(OldSocket, address_family(RemoteIP)) of
        {ok, NewSocket} ->
            %% `#socket_state{}' kept its reference to the now-closed
            %% old socket. Swap the handle while preserving batching
            %% configuration; the clean batch buffer (from the flush
            %% above) starts fresh for post-migrate traffic.
            NewSocketState =
                case OldSocketState of
                    undefined ->
                        undefined;
                    _ ->
                        quic_socket:set_socket(State0#state.socket_state, NewSocket)
                end,
            {ok, State0#state{socket = NewSocket, socket_state = NewSocketState}};
        {error, _} = Error ->
            Error
    end.

%% Socket-NIF rebind. Open new first; tear down old only after new is up.
rebind_client_socket_otp(
    #state{
        remote_addr = {RemoteIP, _},
        socket_state = OldSocketState,
        client_receiver = OldReceiver,
        max_data_local = MaxData
    } = State
) ->
    OpenOpts = #{backend => socket},
    case quic_socket:open_for_send(RemoteIP, OpenOpts) of
        {ok, NewSocketState} ->
            case
                quic_socket:start_client_receiver(
                    NewSocketState, self(), quic_socket:recv_queue_max(MaxData)
                )
            of
                {ok, NewReceiver} ->
                    ok = quic_socket:stop_client_receiver(OldReceiver),
                    close_socket_state_quietly(OldSocketState),
                    NewSocket = quic_socket:get_socket(NewSocketState),
                    {ok, State#state{
                        socket = NewSocket,
                        socket_state = NewSocketState,
                        client_receiver = NewReceiver
                    }};
                {error, _} = Error ->
                    close_socket_state_quietly(NewSocketState),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

close_socket_state_quietly(undefined) ->
    ok;
close_socket_state_quietly(SocketState) ->
    try quic_socket:close(SocketState) of
        _ -> ok
    catch
        _:_ -> ok
    end.

%%====================================================================
%% Server-Side Address Change Detection (RFC 9000 Section 9)
%%====================================================================

%% @doc Detect type of peer address change.
%% Returns same_path, nat_rebinding (port change only), or new_path (IP change).
-spec detect_peer_address_change(
    {inet:ip_address(), inet:port_number()},
    #state{}
) -> same_path | nat_rebinding | new_path.
detect_peer_address_change(PacketAddr, #state{remote_addr = CurrentAddr}) ->
    case PacketAddr of
        CurrentAddr ->
            same_path;
        {IP, _Port} when IP =:= element(1, CurrentAddr) ->
            %% Same IP, different port - NAT rebinding
            nat_rebinding;
        _ ->
            %% Different IP - active migration
            new_path
    end.

%% @doc Handle potential address change from peer.
%% RFC 9000 Section 9: Server must validate new paths before accepting migration.
-spec maybe_handle_address_change(
    {inet:ip_address(), inet:port_number()},
    non_neg_integer(),
    #state{}
) -> #state{}.
maybe_handle_address_change(RemoteAddr, _Data, #state{remote_addr = RemoteAddr} = State) ->
    %% Same address, no change
    State;
%% NOTE: peer_disable_migration does NOT affect handling peer address changes.
%% RFC 9000 Section 18.2: disable_active_migration only means the RECEIVER should
%% not migrate to a new local address. It does NOT mean ignore peer address changes.
%% The check for peer_disable_migration is correctly placed in migrate/1 API only.
maybe_handle_address_change(
    NewAddr, DataSize, #state{mig = #mig{migration_state = validating_peer}} = State
) ->
    %% Already validating a path - update bytes received for anti-amplification
    update_pending_path_bytes_received(NewAddr, DataSize, State);
maybe_handle_address_change(NewAddr, DataSize, State) ->
    %% New address detected - initiate path validation
    case detect_peer_address_change(NewAddr, State) of
        same_path ->
            State;
        nat_rebinding ->
            %% RFC 9000 Section 9.5 exempts an unintentional change like a
            %% NAT rebinding from the no-reuse rule, so this path keeps the
            %% CID it is already using.
            initiate_peer_path_validation(NewAddr, true, DataSize, State);
        new_path ->
            %% A genuine migration needs a CID that has not been used on
            %% another path. Without one we cannot probe, so nothing is
            %% emitted and no validation state is created.
            case has_unused_cid(State) of
                true -> initiate_peer_path_validation(NewAddr, false, DataSize, State);
                false -> State
            end
    end.

%% @doc Update bytes_received for pending path validation (anti-amplification).
-spec update_pending_path_bytes_received(
    {inet:ip_address(), inet:port_number()},
    non_neg_integer(),
    #state{}
) -> #state{}.
update_pending_path_bytes_received(
    NewAddr,
    Size,
    #state{mig = #mig{pending_peer_validation = #path_state{remote_addr = NewAddr} = PathState}} =
        State
) ->
    NewPath = PathState#path_state{
        bytes_received = PathState#path_state.bytes_received + Size
    },
    State#state{mig = (State#state.mig)#mig{pending_peer_validation = NewPath}};
update_pending_path_bytes_received(_NewAddr, _Size, State) ->
    %% Address doesn't match pending validation
    State.

%% @doc Initiate path validation for peer's new address.
%% RFC 9000 Section 8.2: Send PATH_CHALLENGE to validate the new path.
%% RFC 9000 Section 9.3.2: Also probe the old path to defend against spoofing.
-spec initiate_peer_path_validation(
    {inet:ip_address(), inet:port_number()},
    boolean(),
    non_neg_integer(),
    #state{}
) -> #state{}.
initiate_peer_path_validation(NewAddr, IsNATRebinding, DataSize, State0) ->
    %% A genuine migration takes a CID of its own; a NAT rebinding keeps the
    %% one in use, which Section 9.5 permits for an unintentional change.
    {State, NewDCID, NewSeq} = path_cid_for(NewAddr, IsNATRebinding, State0),

    %% Create path state for the new address
    NewChallengeData = crypto:strong_rand_bytes(8),
    NewPathState = #path_state{
        remote_addr = NewAddr,
        status = validating,
        challenge_data = NewChallengeData,
        challenge_count = 1,
        bytes_sent = 0,
        bytes_received = DataSize,
        dcid = NewDCID,
        dcid_seq = NewSeq,
        is_nat_rebinding = IsNATRebinding
    },

    %% RFC 9000 Section 9.3.2: Also probe the old path to defend against spoofing
    %% An attacker on-path could copy a packet with spoofed source address
    OldAddr = State#state.remote_addr,
    OldChallengeData = crypto:strong_rand_bytes(8),
    OldPathState = #path_state{
        remote_addr = OldAddr,
        status = validating,
        challenge_data = OldChallengeData,
        challenge_count = 1,
        bytes_sent = 0,
        bytes_received = 0,
        dcid = State#state.dcid,
        is_nat_rebinding = false
    },

    %% RFC 9000 §9.3: follow the highest-numbered non-probing packet
    %% immediately (the caller gates on non-probing) and validate in the
    %% background. Waiting for PATH_RESPONSE before moving the data path
    %% stalls the connection for a full validation round trip per
    %% rebinding; under frequent NAT rebinds the old binding is already
    %% dead and everything sent there is lost, so the transfer dies on
    %% idle timeout. The §9.3 unvalidated-address send cap is not
    %% enforced on the 1-RTT path here; noted as a deliberate trade
    %% (spoofing needs the connection ID, the old path is probed per
    %% §9.3.2, and a failed validation resets so the true peer's next
    %% packet re-triggers).
    State1 = State#state{
        remote_addr = NewAddr,
        mig = (State#state.mig)#mig{
            pending_peer_validation = NewPathState,
            old_path_validation = OldPathState,
            migration_state = validating_peer
        }
    },

    %% Send PATH_CHALLENGE to both addresses, each under its own path's CID
    State2 = send_path_challenge_to_addr(NewAddr, NewChallengeData, NewDCID, State1),
    State3 = send_path_challenge_to_old_addr(OldAddr, OldChallengeData, State2),
    start_path_validation_timer(State3).

%% The CID a path probes under. A NAT rebinding is the Section 9.5
%% exception and stays on the current one; anything else binds its own.
path_cid_for(_Addr, true, #state{dcid = DCID} = State) ->
    {State, DCID, undefined};
path_cid_for(Addr, false, State) ->
    case bind_path_cid(Addr, State) of
        {ok, State1, DCID, Seq} -> {State1, DCID, Seq};
        none -> {State, State#state.dcid, undefined}
    end.

%% @doc Send PATH_CHALLENGE to old path address for anti-spoofing validation.
-spec send_path_challenge_to_old_addr(
    {inet:ip_address(), inet:port_number()},
    binary(),
    #state{}
) -> #state{}.
send_path_challenge_to_old_addr(Addr, ChallengeData, State) ->
    %% Reuse existing send_path_challenge logic
    State1 = send_path_challenge(Addr, ChallengeData, State),
    %% Update old path bytes_sent for tracking
    case (State1#state.mig)#mig.old_path_validation of
        #path_state{} = PathState ->
            % Padded probe packet
            PacketSize = 1200,
            NewPath = PathState#path_state{
                bytes_sent = PathState#path_state.bytes_sent + PacketSize
            },
            State1#state{mig = (State1#state.mig)#mig{old_path_validation = NewPath}};
        undefined ->
            State1
    end.

%% @doc Send PATH_CHALLENGE to a specific address for peer validation.
%% Similar to send_path_challenge but used for validating peer's new address.
-spec send_path_challenge_to_addr(
    {inet:ip_address(), inet:port_number()},
    binary(),
    binary(),
    #state{}
) -> #state{}.
send_path_challenge_to_addr(Addr, ChallengeData, DCID, State) ->
    %% Reuse existing send_path_challenge logic
    State1 = send_path_challenge(Addr, ChallengeData, DCID, State),
    %% Update pending path bytes_sent for anti-amplification
    case (State1#state.mig)#mig.pending_peer_validation of
        #path_state{} = PathState ->
            %% Estimate packet size (short header + PATH_CHALLENGE frame)
            PacketSize = 50,
            NewPath = PathState#path_state{
                bytes_sent = PathState#path_state.bytes_sent + PacketSize
            },
            State1#state{mig = (State1#state.mig)#mig{pending_peer_validation = NewPath}};
        undefined ->
            State1
    end.

%% @doc Start path validation timer (3 * PTO).
%% RFC 9000 Section 8.2.4: Use PTO-based timeout for path validation.
%% Uses a token to correlate timeout messages with specific validation attempts,
%% allowing stale timeouts from canceled validations to be ignored.
-spec start_path_validation_timer(#state{}) -> #state{}.
start_path_validation_timer(
    #state{loss_state = LossState, mig = #mig{path_validation_timer = OldTimer}} = State
) ->
    %% Cancel any existing timer
    cancel_timer(OldTimer),
    %% Calculate timeout as 3 * PTO
    Timeout =
        case LossState of
            undefined -> 3000;
            _ -> 3 * quic_loss:get_pto(LossState, app)
        end,
    %% Use same token for both message and state - enables stale timeout detection
    ValidationToken = make_ref(),
    TimerRef = erlang:send_after(Timeout, self(), {path_validation_timeout, ValidationToken}),
    State#state{
        mig = (State#state.mig)#mig{
            path_validation_timer = TimerRef,
            path_validation_token = ValidationToken
        }
    }.

%% @doc Handle path validation timeout.
%% RFC 9000 Section 8.2.4: Validation fails after timeout, stay on current path.
-spec handle_path_validation_timeout(#state{}) -> {keep_state, #state{}}.
handle_path_validation_timeout(#state{mig = #mig{pending_peer_validation = PathState}} = State) ->
    %% Mark path as failed, stay on current path
    case PathState of
        #path_state{challenge_count = Count} when Count < 3 ->
            %% Retry PATH_CHALLENGE
            ChallengeData = crypto:strong_rand_bytes(8),
            NewPathState = PathState#path_state{
                challenge_data = ChallengeData,
                challenge_count = Count + 1
            },
            State1 = State#state{
                mig = (State#state.mig)#mig{pending_peer_validation = NewPathState}
            },
            State2 = send_path_challenge_to_addr(
                PathState#path_state.remote_addr,
                ChallengeData,
                path_dcid(PathState, State1),
                State1
            ),
            State3 = start_path_validation_timer(State2),
            {keep_state, State3};
        _ ->
            %% Max retries reached, give up on this path. A CID that has
            %% appeared on a path is spent: it is retired rather than
            %% returned to the pool (RFC 9000 Section 9.5).
            State1 = State#state{
                mig = (State#state.mig)#mig{
                    pending_peer_validation = undefined,
                    old_path_validation = undefined,
                    migration_state = idle,
                    path_validation_timer = undefined,
                    path_validation_token = undefined
                }
            },
            {keep_state, retire_abandoned_path_cid(PathState, State1)}
    end.

%% @doc Handle PATH_RESPONSE frame.
%% Validates the response against pending challenges.
%% RFC 9000 Section 9.6: Auto-migrate to preferred address on validation success.
%% RFC 9000 Section 9.3.2: Check both new and old path for anti-spoofing defense.
handle_path_response(ResponseData, State) ->
    %% Validation matches on the 64-bit challenge data carried in an
    %% AEAD-protected packet, so off-path forgery is infeasible. RFC 9000
    %% §8.2.3 also expects the response on the path the challenge was sent;
    %% we do not additionally bind it to the source address (an on-path
    %% observer could otherwise answer from a different path). Noted as a
    %% known limitation; a source-address check would interact with NAT
    %% rebinding and is deferred.
    %% First check if this is a response to peer address validation (server validating client)
    case check_peer_validation_response(ResponseData, State) of
        {new_path_validated, PendingPath, State1} ->
            %% New path validated - check migration decision
            decide_migration_after_new_path_validated(PendingPath, State1);
        {old_path_validated, State1} ->
            %% Old path validated - confirms peer is real (anti-spoofing)
            %% Wait for new path validation or timeout
            State1;
        no_match ->
            %% Check alt_paths (client validating paths)
            case find_path_by_challenge(ResponseData, (State#state.mig)#mig.alt_paths) of
                {ok, PathState, OtherPaths} ->
                    %% Mark path as validated
                    ValidatedPath = PathState#path_state{
                        status = validated,
                        challenge_data = undefined
                    },
                    State1 = State#state{
                        mig = (State#state.mig)#mig{alt_paths = [ValidatedPath | OtherPaths]}
                    },
                    %% Check if this is a preferred address validation - auto-migrate
                    maybe_migrate_to_preferred_address(ValidatedPath, State1);
                not_found ->
                    %% Check current path (if we sent challenge on current path)
                    case State#state.current_path of
                        #path_state{challenge_data = ResponseData} = CurrentPath ->
                            ValidatedPath = CurrentPath#path_state{
                                status = validated,
                                challenge_data = undefined
                            },
                            State#state{current_path = ValidatedPath};
                        _ ->
                            %% Unknown response, ignore
                            State
                    end
            end
    end.

%% @doc Check if PATH_RESPONSE matches new or old path validation challenge.
%% RFC 9000 Section 9.3.2: Both old and new paths are probed during migration.
-spec check_peer_validation_response(binary(), #state{}) ->
    {new_path_validated, #path_state{}, #state{}}
    | {old_path_validated, #state{}}
    | no_match.
check_peer_validation_response(ResponseData, State) ->
    %% Check new path (pending_peer_validation)
    case (State#state.mig)#mig.pending_peer_validation of
        #path_state{challenge_data = ResponseData} = PendingPath ->
            %% New path validated
            ValidatedPath = PendingPath#path_state{status = validated, challenge_data = undefined},
            State1 = State#state{
                mig = (State#state.mig)#mig{pending_peer_validation = ValidatedPath}
            },
            {new_path_validated, ValidatedPath, State1};
        _ ->
            %% Check old path
            case (State#state.mig)#mig.old_path_validation of
                #path_state{challenge_data = ResponseData} = OldPath ->
                    %% Old path validated - confirms peer is real (anti-spoofing signal)
                    ValidatedOldPath = OldPath#path_state{
                        status = validated, challenge_data = undefined
                    },
                    State1 = State#state{
                        mig = (State#state.mig)#mig{old_path_validation = ValidatedOldPath}
                    },
                    {old_path_validated, State1};
                _ ->
                    no_match
            end
    end.

%% @doc Decide migration after new path is validated.
%% RFC 9000 Section 9.3.2: Old path validation is an anti-spoofing signal.
%% If both paths validate, accept migration (peer is legitimate).
%% If new path validates but old fails/pending, accept migration (old path might have issues).
-spec decide_migration_after_new_path_validated(#path_state{}, #state{}) -> #state{}.
decide_migration_after_new_path_validated(ValidatedNewPath, State) ->
    %% New path is validated - proceed with migration
    %% Old path validation is informational (anti-spoofing defense)
    handle_peer_path_validated(ValidatedNewPath, State).

%% @doc Handle successful peer path validation (server accepting client's new address).
%% RFC 9000 Section 9: Complete migration to the validated peer address.
-spec handle_peer_path_validated(#path_state{}, #state{}) -> #state{}.
handle_peer_path_validated(PendingPath, #state{mig = #mig{path_validation_timer = Timer}} = State) ->
    %% Cancel validation timer
    cancel_timer(Timer),
    %% RFC 9000 Section 9.5: the path already probed under its own CID, so
    %% that one is promoted here rather than a new one being chosen; the CID
    %% the old path used is then retired.
    OldDCID = State#state.dcid,
    NewDCID = path_dcid(PendingPath, State),
    ValidatedPath = PendingPath#path_state{
        status = validated,
        challenge_data = undefined,
        dcid = NewDCID
    },
    State1 = State#state{dcid = NewDCID},
    %% Complete migration to the new peer address
    State2 = retire_replaced_dcid(OldDCID, NewDCID, complete_migration(ValidatedPath, State1)),
    %% Clear pending validation state including old path validation
    State2#state{
        mig = (State2#state.mig)#mig{
            pending_peer_validation = undefined,
            old_path_validation = undefined,
            migration_state = idle,
            path_validation_timer = undefined,
            path_validation_token = undefined
        }
    }.

%% @doc Auto-migrate to preferred address if the validated path matches.
%% RFC 9000 Section 9.6: Client SHOULD migrate to validated preferred address.
-spec maybe_migrate_to_preferred_address(#path_state{}, #state{}) -> #state{}.
maybe_migrate_to_preferred_address(
    ValidatedPath, #state{mig = #mig{preferred_address = undefined}} = State
) ->
    %% No preferred address, just return
    State#state{
        mig = (State#state.mig)#mig{alt_paths = [ValidatedPath | (State#state.mig)#mig.alt_paths]}
    };
maybe_migrate_to_preferred_address(
    #path_state{remote_addr = RemoteAddr} = ValidatedPath,
    #state{mig = #mig{preferred_address = PA}} = State
) ->
    %% Check if validated path matches the preferred address
    case is_preferred_address_path(RemoteAddr, PA) of
        true ->
            %% Migrate to preferred address
            State1 = complete_migration(ValidatedPath, State),
            %% RFC 9000 Section 9.6: MUST use the new CID on the preferred address
            %% Switch CID BEFORE sending any packets (including PMTU probes)
            State2 = switch_to_preferred_cid(PA, State1),
            %% Clear the preferred_address field since migration is complete
            State3 = State2#state{mig = (State2#state.mig)#mig{preferred_address = undefined}},
            %% Now start PMTU probing on the new path with correct CID
            maybe_send_pmtu_probe(State3);
        false ->
            State
    end.

%% Check if remote address matches the preferred address
is_preferred_address_path({IPv4, Port}, #preferred_address{ipv4_addr = IPv4, ipv4_port = Port}) when
    IPv4 =/= undefined
->
    true;
is_preferred_address_path({IPv6, Port}, #preferred_address{ipv6_addr = IPv6, ipv6_port = Port}) when
    IPv6 =/= undefined
->
    true;
is_preferred_address_path(_, _) ->
    false.

%% Switch to using the CID from preferred_address
switch_to_preferred_cid(#preferred_address{cid = CID}, #state{dcid = OldDCID} = State) ->
    %% RFC 9000 Section 9.6: MUST use the new CID on the preferred address.
    %% The one it replaces is retired, as on any other path change.
    retire_replaced_dcid(OldDCID, CID, State#state{dcid = CID}).

%% @doc Whether a peer CID is free for a path we have not probed yet.
-spec has_unused_cid(#state{}) -> boolean().
has_unused_cid(#state{cid_pool_state = Pool, dcid = CurrentDCID}) ->
    quic_cid:fresh_dcid(Pool, CurrentDCID) =/= not_found.

%% @doc Move to a new path: take a fresh CID for it, retire the one the old
%% path used, and validate (RFC 9000 Section 9.5).
-spec migrate_to({inet:ip_address(), inet:port_number()}, #state{}) -> #state{}.
migrate_to(RemoteAddr, #state{dcid = OldDCID} = State) ->
    case start_path_probe(RemoteAddr, State) of
        {ok, State1, NewCID, _Seq} ->
            retire_path_cid(OldDCID, State1#state{dcid = NewCID});
        none ->
            State
    end.

%% Find a path by challenge data
find_path_by_challenge(_Data, []) ->
    not_found;
find_path_by_challenge(Data, [#path_state{challenge_data = Data} = Path | Rest]) ->
    {ok, Path, Rest};
find_path_by_challenge(Data, [Path | Rest]) ->
    case find_path_by_challenge(Data, Rest) of
        {ok, Found, Others} ->
            {ok, Found, [Path | Others]};
        not_found ->
            not_found
    end.

%% @doc Complete migration to a validated path.
%% Updates the current path and conditionally resets state based on migration type.
%% Note: Does NOT start PMTU probing - caller must call maybe_send_pmtu_probe/1
%% after any required CID switches (e.g., for preferred address migration).
-spec complete_migration(#path_state{}, #state{}) -> #state{}.
%% NAT rebinding: preserve CC, loss, and PMTU state (same network path)
%% RFC 9002 Section 9.4: NAT rebinding does not indicate a new path
complete_migration(
    #path_state{status = validated, is_nat_rebinding = true} = NewPath,
    State
) ->
    %% Same network path (only port changed) - keep existing state
    State#state{
        remote_addr = NewPath#path_state.remote_addr,
        current_path = NewPath,
        mig = (State#state.mig)#mig{
            alt_paths = lists:delete(NewPath, (State#state.mig)#mig.alt_paths),
            migration_state = idle,
            pending_peer_validation = undefined
        }
    };
%% Active migration: reset CC, loss, and PMTU (different network path)
%% RFC 9002 Section 9.4: Reset congestion state on path change
complete_migration(
    #path_state{status = validated, is_nat_rebinding = false} = NewPath,
    #state{
        owner = Owner,
        current_path = OldPath,
        pmtu_state = PMTUState,
        pmtu_probe_timer = ProbeTimer,
        pmtu_raise_timer = RaiseTimer
    } = State
) ->
    %% Notify owner of path change (for logging/monitoring)
    OldAddr =
        case OldPath of
            #path_state{remote_addr = A} -> A;
            undefined -> undefined
        end,
    Owner ! {quic, self(), {path_changed, OldAddr, NewPath#path_state.remote_addr}},

    %% RFC 8899: Reset PMTU on path change
    %% Cancel PMTU timers before resetting state
    cancel_timer(ProbeTimer),
    cancel_timer(RaiseTimer),
    NewPMTUState = quic_pmtu:on_path_change(PMTUState),

    %% RFC 9002 Section 9.4: Reset congestion controller on path change
    %% The new path may have different RTT and bandwidth characteristics.
    %% The loss tracker's sent_q must SURVIVE the switch: replacing it
    %% orphans every in-flight packet (no ACK match, no loss detection,
    %% no PTO since bytes_in_flight reads 0) and their data is never
    %% retransmitted - the peer then stalls on a permanent stream hole.
    NewLossState = quic_loss:reset_for_new_path(State#state.loss_state),
    NewCCState0 = quic_cc:new(#{}),
    NewCCState =
        case quic_loss:bytes_in_flight(NewLossState) of
            0 -> NewCCState0;
            Outstanding -> quic_cc:on_packet_sent(NewCCState0, Outstanding)
        end,

    State#state{
        remote_addr = NewPath#path_state.remote_addr,
        current_path = NewPath,
        pmtu_state = NewPMTUState,
        pmtu_probe_timer = undefined,
        pmtu_raise_timer = undefined,
        %% Reset CC and loss detection for new path
        cc_state = NewCCState,
        loss_state = NewLossState,
        pto_dirty = true,
        mig = (State#state.mig)#mig{
            alt_paths = lists:delete(NewPath, (State#state.mig)#mig.alt_paths)
        }
    };
complete_migration(_, State) ->
    %% Can only migrate to validated paths
    State.

%% @doc Handle NEW_CONNECTION_ID frame from peer.
%% Adds the new CID to our pool of peer CIDs.
%% RFC 9000 Section 5.1.1: Peer must not exceed our active_connection_id_limit.
handle_new_connection_id(SeqNum, RetirePrior, CID, ResetToken, State) ->
    case RetirePrior > SeqNum of
        true ->
            %% RFC 9000 §19.15: retire_prior_to MUST NOT exceed sequence_number.
            close_with_transport_error(
                ?QUIC_FRAME_ENCODING_ERROR,
                <<"NEW_CONNECTION_ID retire_prior_to > sequence_number">>,
                State
            );
        false ->
            add_peer_connection_id(SeqNum, RetirePrior, CID, ResetToken, State)
    end.

add_peer_connection_id(SeqNum, RetirePrior, CID, ResetToken, #state{cid_pool_state = Pool} = State) ->
    case quic_cid:add_peer_cid(Pool, SeqNum, RetirePrior, CID, ResetToken) of
        {duplicate, _Pool} ->
            State;
        {error, {reuse, _Seq}} ->
            %% RFC 9000 §19.15: same sequence number, different CID or
            %% reset token.
            close_with_transport_error(
                ?QUIC_PROTOCOL_VIOLATION,
                <<"NEW_CONNECTION_ID sequence reuse with different CID">>,
                State
            );
        {error, limit_exceeded} ->
            close_with_transport_error(
                ?QUIC_CONNECTION_ID_LIMIT_ERROR,
                <<"active_connection_id_limit exceeded">>,
                State
            );
        {ok, NewPool, ToRetire} ->
            %% RFC 9000 §5.1.2: if the CID we are sending with is among
            %% the retired ones, switch to an active CID BEFORE retiring.
            %% Keeping a retired DCID makes the peer eventually treat our
            %% packets as unroutable and answer with stateless resets
            %% whose token we discarded with the pruned pool entry - the
            %% connection goes irrecoverably deaf.
            State0 = replace_retired_dcid(State#state{cid_pool_state = NewPool}),
            %% Announce the retirements, then drop the entries so the pool
            %% cannot grow without bound.
            State1 = send_retire_connection_ids(ToRetire, State0),
            prune_retired_peer_cids(State1)
    end.

replace_retired_dcid(#state{cid_pool_state = Pool, dcid = DCID} = State) ->
    case quic_cid:replacement_for_retired_dcid(Pool, DCID) of
        {ok, NewCID} ->
            ?LOG_DEBUG(#{what => dcid_retired_switching, new_cid => NewCID}, ?QUIC_LOG_META),
            State#state{dcid = NewCID};
        keep ->
            State
    end.

prune_retired_peer_cids(#state{cid_pool_state = Pool} = State) ->
    State#state{cid_pool_state = quic_cid:prune_retired_peer(Pool)}.

%% RFC 9000 Section 19.16: one RETIRE_CONNECTION_ID per retired sequence.
send_retire_connection_ids(SeqNums, State) ->
    lists:foldl(
        fun(SeqNum, Acc) -> send_frame({retire_connection_id, SeqNum}, Acc) end,
        State,
        lists:sort(SeqNums)
    ).

%% @doc Issue new connection IDs to the peer.
%% RFC 9000 Section 5.1.1: Generates new CIDs with stateless reset tokens.
-spec issue_new_connection_ids(#state{}) -> #state{}.
issue_new_connection_ids(#state{cid_pool_state = Pool} = State) ->
    issue_cids(quic_cid:replenish_needed(Pool), State).

%% Issue N CIDs, then register each with the listener before advertising it,
%% so the peer can use one as a Destination CID the moment the frame lands.
%% Reversed, routing would not recognise it yet.
issue_cids(0, State) ->
    State;
issue_cids(N, #state{cid_pool_state = Pool} = State) when N > 0 ->
    {NewPool, Issued} = quic_cid:issue(Pool, N, (State#state.cfg)#conn_cfg.stateless_reset_secret),
    State1 = State#state{cid_pool_state = NewPool},
    lists:foldl(
        fun({SeqNum, CID, Token}, Acc) ->
            maybe_register_cid(CID, Acc),
            send_frame({new_connection_id, SeqNum, 0, CID, Token}, Acc)
        end,
        State1,
        Issued
    ).

%% How many of the peer's CIDs we will hold, advertised as our
%% active_connection_id_limit.
local_active_limit(#state{cid_pool_state = Pool}) ->
    quic_cid:local_active_limit(Pool).

%% Server connections route through the listener's shared socket, so a
%% newly issued CID must be added to the listener's routing table. Client
%% connections own their socket and route locally, so this is a no-op.
maybe_register_cid(CID, #state{cfg = #conn_cfg{role = server, listener = Listener}}) when
    is_pid(Listener)
->
    quic_listener:register_cid(Listener, CID, self());
maybe_register_cid(_CID, _State) ->
    ok.

maybe_retire_cid(CID, #state{cfg = #conn_cfg{role = server, listener = Listener}}) when
    is_pid(Listener)
->
    quic_listener:retire_cid(Listener, CID);
maybe_retire_cid(_CID, _State) ->
    ok.

%% @doc Compute the next connection-level MAX_DATA limit during receive-window
%% auto-tuning. The limit is anchored at the bytes already received and a window
%% is added on top, with only the *window size* capped at MaxWindow (the largest
%% buffer we are willing to hold). This makes MAX_DATA slide forward as data is
%% consumed — exactly as the per-stream MAX_STREAM_DATA update does.
%%
%% Capping the *absolute* limit at MaxWindow instead (the previous behaviour)
%% froze MAX_DATA once the connection had received MaxWindow bytes in total: the
%% sender then exhausted the connection window and stalled permanently on any
%% transfer larger than MaxWindow, regardless of how fast the receiver consumed.
%% Fast consumption doubles the window; otherwise it grows by one initial window.
-spec next_conn_max_data(
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    boolean()
) -> non_neg_integer().
next_conn_max_data(DataReceived, MaxDataLocal, MaxWindow, _InitialWindow, true) ->
    DataReceived + min(MaxDataLocal * 2, MaxWindow);
next_conn_max_data(DataReceived, MaxDataLocal, MaxWindow, InitialWindow, false) ->
    DataReceived + min(MaxDataLocal + InitialWindow, MaxWindow).

%% @doc Generate a stateless reset token for a connection ID.
%% RFC 9000 §10.3.2 requires the token to be hard for an external
%% observer to guess. When a server-wide secret is configured, derive
%% the token deterministically via HMAC-SHA256 so the same CID always
%% maps to the same token — letting a listener reply with a matching
%% stateless reset for a CID whose per-connection state it no longer
%% holds. Without a secret we fall back to per-CID random bytes.
-spec generate_stateless_reset_token(binary(), #state{}) -> binary().
generate_stateless_reset_token(CID, #state{cfg = #conn_cfg{stateless_reset_secret = Secret}}) ->
    quic_cid:generate_reset_token(CID, Secret).

%% RFC 9000 §8.1.3 server-side issuance. A NEW_TOKEN frame binds the
%% client's current source address to an HMAC-signed envelope so the
%% client can skip the retry round-trip on a future connection.
%% Requires a token secret; reuses the same listener-wide secret as
%% stateless reset to avoid spawning a second knob. Only emitted on
%% server-role connections that reached the connected state.
maybe_send_new_token(#state{cfg = #conn_cfg{role = client}} = State) ->
    State;
maybe_send_new_token(#state{cfg = #conn_cfg{stateless_reset_secret = undefined}} = State) ->
    State;
maybe_send_new_token(
    #state{
        remote_addr = Addr,
        cfg = #conn_cfg{
            role = server,
            stateless_reset_secret = Secret
        }
    } = State
) ->
    Token = quic_address_token:encode_new_token(
        Secret, Addr, erlang:system_time(millisecond)
    ),
    send_frame({new_token, Token}, State).

%% RFC 9000 §8.1: validate the Token field a client placed in its
%% Initial. Returns a `validated | {error, Reason} | no_token'
%% judgement. Clients and tokenless Initials skip; for servers with
%% a token secret the HMAC + address + freshness (+ ODCID on retry
%% tokens) are all checked. This is currently advisory — the listener
%% doesn't yet retry, so validation outcomes only surface in logs.
maybe_validate_initial_token(<<>>, _State) ->
    no_token;
maybe_validate_initial_token(_Token, #state{cfg = #conn_cfg{role = client}}) ->
    no_token;
maybe_validate_initial_token(_Token, #state{hs = #hs{address_validated = true}}) ->
    %% Listener already ran the full token check. Skipping here avoids
    %% duplicating the HMAC verify on the hot path.
    validated;
maybe_validate_initial_token(_Token, #state{cfg = #conn_cfg{stateless_reset_secret = undefined}}) ->
    no_token;
maybe_validate_initial_token(Token, #state{
    remote_addr = Addr,
    cfg = #conn_cfg{
        stateless_reset_secret = Secret
    }
}) ->
    case quic_address_token:decode(Secret, Token) of
        {ok, #{addr := TokAddr} = Decoded} when TokAddr =/= Addr ->
            {error, address_mismatch, Decoded};
        {ok, Decoded} ->
            case quic_address_token:validate(Decoded, #{}) of
                ok -> validated;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Validate connection ID parameters from peer transport params.
%% RFC 9000 Section 7.3: Endpoints MUST validate connection ID parameters.
%% - initial_source_connection_id must match SCID in Initial packet
%% - original_destination_connection_id (server only) must match original DCID
%% - retry_source_connection_id (if Retry used) must match Retry packet SCID
-spec validate_connection_id_params(map(), #state{}) -> ok | {error, term()}.
validate_connection_id_params(TransportParams, #state{cfg = #conn_cfg{role = client}} = State) ->
    %% Client validates server's transport params
    #state{
        dcid = CurrentDCID,
        cfg = #conn_cfg{
            original_dcid = OriginalDCID
        },
        hs = #hs{
            retry_received = RetryReceived,
            retry_scid = RetrySCID
        }
    } = State,

    %% Server must include original_destination_connection_id matching our original DCID
    case maps:get(original_dcid, TransportParams, undefined) of
        undefined ->
            {error, missing_original_dcid};
        OriginalDCID ->
            %% Matches - continue validation
            validate_initial_scid(TransportParams, CurrentDCID, RetryReceived, RetrySCID);
        Other ->
            {error, {original_dcid_mismatch, expected, OriginalDCID, got, Other}}
    end;
validate_connection_id_params(TransportParams, #state{cfg = #conn_cfg{role = server}} = State) ->
    %% Server validates client's transport params
    #state{dcid = ClientSCID} = State,

    %% Client must include initial_source_connection_id matching their SCID
    case maps:get(initial_scid, TransportParams, undefined) of
        undefined ->
            {error, missing_initial_scid};
        ClientSCID ->
            ok;
        Other ->
            {error, {initial_scid_mismatch, expected, ClientSCID, got, Other}}
    end.

%% Helper to validate initial_scid and retry_scid for client
validate_initial_scid(TransportParams, CurrentDCID, RetryReceived, RetrySCID) ->
    %% Server's initial_source_connection_id must match current DCID
    case maps:get(initial_scid, TransportParams, undefined) of
        undefined ->
            {error, missing_initial_scid};
        CurrentDCID ->
            %% Matches - check retry_scid if Retry was used
            validate_retry_scid(TransportParams, RetryReceived, RetrySCID);
        Other ->
            {error, {initial_scid_mismatch, expected, CurrentDCID, got, Other}}
    end.

validate_retry_scid(_TransportParams, false, _RetrySCID) ->
    %% No Retry received - server MUST NOT include retry_source_connection_id
    ok;
validate_retry_scid(TransportParams, true, RetrySCID) ->
    %% Retry was received - server MUST include matching retry_source_connection_id
    case maps:get(retry_scid, TransportParams, undefined) of
        undefined ->
            {error, missing_retry_scid_after_retry};
        RetrySCID ->
            ok;
        Other ->
            {error, {retry_scid_mismatch, expected, RetrySCID, got, Other}}
    end.

%% @doc Apply peer transport parameters to connection state.
%% Extracts flow control limits, stream limits, and CID limit from peer's transport params.
%% RFC 9000 Section 7.4: Transport parameters are applied after the handshake completes.
%% RFC 9000 Section 7.3: Validates connection ID parameters before applying.
apply_peer_transport_params(TransportParams, State) ->
    case validate_peer_transport_params(TransportParams, State) of
        ok ->
            apply_peer_transport_params_internal(TransportParams, State);
        {error, Reason} ->
            ?LOG_ERROR(
                #{what => transport_parameter_validation_failed, reason => Reason},
                ?QUIC_LOG_META
            ),
            ReasonBin = tp_reason_to_binary(Reason),
            %% Mark the violation. `maybe_emit_pending_close/1' picks this up
            %% after the server flight so the peer has handshake keys to
            %% decrypt the CLOSE. The `{pending_close, ...}' tag is distinct
            %% from `{transport, ...}' so check_state_transition does not
            %% move us to draining before the flight is sent.
            State#state{
                close_reason =
                    {pending_close, transport, ?QUIC_TRANSPORT_PARAMETER_ERROR, ReasonBin}
            }
    end.

%% Run all peer-transport-parameter validation checks: connection-id params,
%% role-specific disallowed-parameter rejection, and range checks on
%% numeric parameters per RFC 9000 Section 18.2.
validate_peer_transport_params(TransportParams, State) ->
    case validate_connection_id_params(TransportParams, State) of
        ok ->
            case validate_role_specific_params(TransportParams, State) of
                ok -> quic_tls:validate_transport_param_constraints(TransportParams);
                Error -> Error
            end;
        Error ->
            Error
    end.

validate_role_specific_params(TransportParams, #state{cfg = #conn_cfg{role = server}}) ->
    %% Per RFC 9000 Section 18.2, these parameters MUST NOT be sent by a client.
    ServerOnly = [
        original_dcid,
        preferred_address,
        retry_scid,
        stateless_reset_token
    ],
    case [K || K <- ServerOnly, maps:is_key(K, TransportParams)] of
        [] -> ok;
        [Forbidden | _] -> {error, {forbidden_client_param, Forbidden}}
    end;
validate_role_specific_params(_TransportParams, #state{cfg = #conn_cfg{role = client}}) ->
    ok.

tp_reason_to_binary(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).

%% After the server flight is sent, emit a pending CONNECTION_CLOSE at
%% handshake level so the peer can decrypt it (peer has just derived
%% handshake keys from ServerHello). Flips the close_reason to the final
%% {Class, Code, Reason} tuple so check_state_transition moves to draining.
maybe_emit_pending_close(#state{close_reason = {pending_close, Class, Code, Reason}} = State) ->
    close_with_error(handshake, Class, Code, 0, Reason, State);
maybe_emit_pending_close(State) ->
    State.

%% Internal function to apply transport params after CID validation passes
apply_peer_transport_params_internal(TransportParams, State) ->
    %% Extract connection-level flow control: how much WE can send to THEM
    %% Peer's initial_max_data tells us the max bytes we can send on this connection
    MaxDataRemote = maps:get(initial_max_data, TransportParams, ?DEFAULT_INITIAL_MAX_DATA),

    %% Extract stream-level flow control limits for streams we send on
    %% initial_max_stream_data_bidi_remote: limit for streams WE initiate (from peer's perspective, we're "remote")
    %% initial_max_stream_data_bidi_local: limit for streams THEY initiate (from peer's perspective, they're "local")
    %% initial_max_stream_data_uni: limit for unidirectional streams we initiate
    MaxStreamDataBidiRemote = maps:get(
        initial_max_stream_data_bidi_remote,
        TransportParams,
        ?DEFAULT_INITIAL_MAX_STREAM_DATA
    ),
    MaxStreamDataBidiLocal = maps:get(
        initial_max_stream_data_bidi_local,
        TransportParams,
        ?DEFAULT_INITIAL_MAX_STREAM_DATA
    ),
    MaxStreamDataUni = maps:get(
        initial_max_stream_data_uni,
        TransportParams,
        ?DEFAULT_INITIAL_MAX_STREAM_DATA
    ),

    ?LOG_DEBUG(
        #{
            what => apply_peer_transport_params,
            max_data_remote => MaxDataRemote,
            max_stream_data_bidi_remote => MaxStreamDataBidiRemote,
            max_stream_data_bidi_local => MaxStreamDataBidiLocal,
            max_stream_data_uni => MaxStreamDataUni,
            raw_params => TransportParams
        },
        ?QUIC_LOG_META
    ),

    %% Extract stream limits: how many streams WE can open
    MaxStreamsBidi = maps:get(initial_max_streams_bidi, TransportParams, ?DEFAULT_MAX_STREAMS_BIDI),
    MaxStreamsUni = maps:get(initial_max_streams_uni, TransportParams, ?DEFAULT_MAX_STREAMS_UNI),

    %% Extract max_datagram_frame_size (RFC 9221): peer's max datagram size
    %% Default is 0 (datagrams not supported)
    MaxDatagramFrameSize = maps:get(max_datagram_frame_size, TransportParams, 0),

    %% Extract disable_active_migration (RFC 9000 Section 18.2)
    %% If true, peer has indicated they don't want to receive traffic from different addresses
    PeerDisableMigration = maps:get(disable_active_migration, TransportParams, false),

    %% RFC 9000 §10.3: the peer's stateless_reset_token applies to its
    %% sequence-0 CID. Record it so a later stateless reset is recognised by
    %% check_stateless_reset/2 (only servers send this, so only clients store it).
    NewCIDPool = apply_peer_cid_params(TransportParams, State),

    %% Store stream data limits in state for use when opening streams
    %% These tell us how much we can send on different stream types
    State#state{
        transport_params = maps:merge(TransportParams, #{
            %% Store parsed limits for easy access
            peer_max_stream_data_bidi_remote => MaxStreamDataBidiRemote,
            peer_max_stream_data_bidi_local => MaxStreamDataBidiLocal,
            peer_max_stream_data_uni => MaxStreamDataUni
        }),
        cid_pool_state = NewCIDPool,
        loss_state = peer_ack_params(TransportParams, State#state.loss_state),
        %% Connection-level send limit
        max_data_remote = MaxDataRemote,
        %% Stream limits (how many streams we can open)
        max_streams_bidi_remote = MaxStreamsBidi,
        max_streams_uni_remote = MaxStreamsUni,
        %% Datagram size limit (RFC 9221)
        max_datagram_frame_size_remote = MaxDatagramFrameSize,
        mig = (State#state.mig)#mig{
            %% Migration disabled by peer (RFC 9000 Section 18.2)
            peer_disable_migration = PeerDisableMigration
        }
    }.

%% The peer's ACK timing, which loss detection needs to read its ACK Delay
%% field and to size the PTO (RFC 9002 Sections 5.3 and 6.2.1).
peer_ack_params(_TransportParams, undefined) ->
    undefined;
peer_ack_params(TransportParams, LossState) ->
    quic_loss:set_peer_ack_params(
        LossState,
        maps:get(ack_delay_exponent, TransportParams, ?DEFAULT_ACK_DELAY_EXPONENT),
        maps:get(max_ack_delay, TransportParams, ?DEFAULT_MAX_ACK_DELAY)
    ).

%% Record the peer's transport-parameter stateless_reset_token (RFC 9000 §10.3)
%% against our current DCID (the peer's initial source CID), as a sequence-0
%% entry in the peer CID pool. This is what lets check_stateless_reset/2 match a
%% reset for the initial connection ID — a steady connection never receives a
%% NEW_CONNECTION_ID frame, so without this the token is never stored.
apply_peer_cid_params(TransportParams, #state{cid_pool_state = Pool}) ->
    %% Sequence 0 already exists, installed when the peer's Initial was
    %% adopted; the token only fills it in.
    Token = maps:get(stateless_reset_token, TransportParams, undefined),
    Limit = maps:get(active_connection_id_limit, TransportParams, 2),
    quic_cid:set_peer_active_limit(
        quic_cid:record_initial_reset_token(Pool, Token), Limit
    ).

%% @doc Handle RETIRE_CONNECTION_ID frame from peer.
%% Marks the specified CID in our local pool as retired.
handle_retire_connection_id(SeqNum, #state{cid_pool_state = Pool} = State) ->
    case quic_cid:retire_local(Pool, SeqNum) of
        {error, unissued} ->
            %% RFC 9000 §19.16: retiring a sequence number we never issued.
            close_with_transport_error(
                ?QUIC_PROTOCOL_VIOLATION,
                <<"RETIRE_CONNECTION_ID for unissued sequence number">>,
                State
            );
        {ok, NewPool, RetiredCID} ->
            %% Drop the retired CID from the listener routing table so it
            %% no longer maps to this connection.
            _ =
                case RetiredCID of
                    undefined -> ok;
                    _ -> maybe_retire_cid(RetiredCID, State)
                end,
            %% Replenish the peer's usable CID supply after a retirement.
            issue_new_connection_ids(State#state{cid_pool_state = NewPool})
    end.

%%====================================================================
%% PMTU Discovery (RFC 8899)
%%====================================================================

%% @doc Initialize PMTU probing after handshake completes.
%% Uses peer's max_udp_payload_size from transport parameters.
-spec init_pmtu_probing(map(), #state{}) -> #state{}.
init_pmtu_probing(TransportParams, #state{pmtu_state = PMTUState} = State) ->
    PeerMaxUdp = maps:get(max_udp_payload_size, TransportParams, undefined),
    NewPMTUState = quic_pmtu:on_connection_established(PeerMaxUdp, PMTUState),
    State1 = State#state{pmtu_state = NewPMTUState},
    %% Start probing if enabled and should probe
    maybe_send_pmtu_probe(State1).

%% @doc Send a PMTU probe packet if conditions are met.
-spec maybe_send_pmtu_probe(#state{}) -> #state{}.
maybe_send_pmtu_probe(#state{pmtu_state = undefined} = State) ->
    State;
maybe_send_pmtu_probe(#state{pmtu_state = PMTUState} = State) ->
    case quic_pmtu:should_probe(PMTUState) of
        true ->
            send_pmtu_probe(State);
        false ->
            %% Check if search is complete and set raise timer
            case quic_pmtu:get_state(PMTUState) of
                search_complete ->
                    maybe_set_pmtu_raise_timer(State);
                _ ->
                    State
            end
    end.

%% @doc Send a PMTU probe packet.
-spec send_pmtu_probe(#state{}) -> #state{}.
send_pmtu_probe(#state{pmtu_state = PMTUState, pn_app = PNSpace} = State) ->
    %% Calculate header size (approximate)
    HeaderSize = 50,
    {ProbeSize, Frames} = quic_pmtu:create_probe_packet(PMTUState, HeaderSize),

    case Frames of
        [] ->
            %% No frames to send
            State;
        _ ->
            %% Get packet number for this probe
            PacketNumber = PNSpace#pn_space.next_pn,

            %% Record probe sent (returns generation for stale detection)
            {_Gen, NewPMTUState} = quic_pmtu:on_probe_sent(PacketNumber, PMTUState),

            %% Send the probe packet
            State1 = State#state{pmtu_state = NewPMTUState},
            State2 = send_pmtu_probe_packet(ProbeSize, Frames, State1),

            %% Set probe timeout
            set_pmtu_probe_timer(State2)
    end.

%% @doc Send the actual PMTU probe packet.
%% Uses the existing send_app_packet infrastructure with PING + PADDING.
-spec send_pmtu_probe_packet(pos_integer(), list(), #state{}) -> #state{}.
send_pmtu_probe_packet(_ProbeSize, _Frames, #state{app_keys = undefined} = State) ->
    %% No keys available yet
    State;
send_pmtu_probe_packet(ProbeSize, Frames, #state{dcid = DCID, pn_app = PNSpace} = State) ->
    %% Encode PING + explicit PADDING frames
    EncodedFrames = encode_pmtu_frames(Frames),

    %% Calculate extra padding needed to reach target probe size
    %% Account for: header (1 + DCID), PN (1-4), auth tag (16)
    PN = PNSpace#pn_space.next_pn,
    PNLen = quic_packet:pn_length(PN),
    HeaderLen = 1 + byte_size(DCID),
    AuthTagLen = 16,
    PayloadLen = byte_size(EncodedFrames),
    CurrentSize = HeaderLen + PNLen + PayloadLen + AuthTagLen,
    ExtraPadding = max(0, ProbeSize - CurrentSize),

    %% Add extra padding to frame payload
    PaddedFrames = <<EncodedFrames/binary, (binary:copy(<<0>>, ExtraPadding))/binary>>,

    %% Send with an empty frames list so the probe is tracked as
    %% non-ack-eliciting locally: it stays in sent_q, which is what the
    %% PMTU ack/lost hooks fold over, but adds nothing to
    %% bytes_in_flight, arms no PTO, and is never retransmitted. Losing
    %% a probe is the expected outcome of probing past the path MTU
    %% (RFC 8899 §3, RFC 9000 §14.4): it must be decided by quic_pmtu's
    %% own probe timer, never surface as connection loss. Tracking it
    %% as in-flight data let a single lost raise-probe hold
    %% bytes_in_flight above zero with no possible progress, and the
    %% disconnect timeout then declared the peer dead: every long-lived
    %% connection on an MTU-limited path died on the first periodic
    %% re-probe, both ends at once.
    send_app_packet_internal(PaddedFrames, [], State).

%% @doc Encode PMTU probe frames (PING + PADDING).
-spec encode_pmtu_frames([term()]) -> binary().
encode_pmtu_frames(Frames) ->
    lists:foldl(
        fun
            (ping, Acc) ->
                <<Acc/binary, ?FRAME_PING>>;
            ({padding, N}, Acc) ->
                Padding = binary:copy(<<0>>, N),
                <<Acc/binary, Padding/binary>>
        end,
        <<>>,
        Frames
    ).

%% @doc Set the PMTU probe timeout timer.
%% Uses 5x smoothed RTT as probe timeout (quic-go pattern).
%% This is more responsive than 5x PTO and follows quic-go's approach.
%% Uses unique reference in message to detect stale timer events
-spec set_pmtu_probe_timer(#state{}) -> #state{}.
set_pmtu_probe_timer(#state{pmtu_probe_timer = OldTimer, loss_state = LossState} = State) ->
    cancel_timer(OldTimer),
    %% Use 5x smoothed RTT as probe timeout (quic-go pattern)
    %% With reasonable minimum for very low RTT networks
    Timeout =
        case LossState of
            undefined ->
                ?PMTU_DEFAULT_PROBE_TIMEOUT;
            _ ->
                SRTT = quic_rtt:smoothed(quic_loss:rtt(LossState)),
                max(1000, 5 * SRTT)
        end,
    Ref = make_ref(),
    erlang:send_after(Timeout, self(), {pmtu_probe_timeout, Ref}),
    State#state{pmtu_probe_timer = Ref}.

%% @doc Set the PMTU raise timer for periodic re-probing.
%% Uses unique reference in message to detect stale timer events
-spec maybe_set_pmtu_raise_timer(#state{}) -> #state{}.
maybe_set_pmtu_raise_timer(#state{pmtu_raise_timer = undefined} = State) ->
    Ref = make_ref(),
    erlang:send_after(
        (State#state.cfg)#conn_cfg.pmtu_raise_interval, self(), {pmtu_raise_timeout, Ref}
    ),
    State#state{pmtu_raise_timer = Ref};
maybe_set_pmtu_raise_timer(State) ->
    State.

%% Whether a PMTU probe packet is in flight awaiting ACK/loss.
-spec pmtu_probe_outstanding(#state{}) -> boolean().
pmtu_probe_outstanding(#state{pmtu_state = undefined}) ->
    false;
pmtu_probe_outstanding(#state{pmtu_state = #pmtu_state{probe_pn = ProbePN}}) ->
    ProbePN =/= undefined.

%% @doc Handle ACK of a potential PMTU probe packet.
-spec handle_pmtu_probe_ack(non_neg_integer(), #state{}) -> #state{}.
handle_pmtu_probe_ack(_PacketNumber, #state{pmtu_state = undefined} = State) ->
    State;
handle_pmtu_probe_ack(PacketNumber, #state{pmtu_state = PMTUState, cc_state = CCState} = State) ->
    case quic_pmtu:get_state(PMTUState) of
        searching ->
            %% Check if this ACK is for our probe packet
            case PMTUState#pmtu_state.probe_pn of
                PacketNumber ->
                    %% This is our probe - process it with generation check
                    Gen = quic_pmtu:get_generation(PMTUState),
                    OldMTU = quic_pmtu:current_mtu(PMTUState),
                    NewPMTUState = quic_pmtu:on_probe_acked(PacketNumber, Gen, PMTUState),
                    NewMTU = quic_pmtu:current_mtu(NewPMTUState),

                    %% Update congestion control if MTU changed
                    NewCCState =
                        case NewMTU > OldMTU of
                            true -> quic_cc:update_mtu(CCState, NewMTU);
                            false -> CCState
                        end,

                    %% Cancel probe timer and continue probing
                    cancel_timer(State#state.pmtu_probe_timer),
                    State1 = State#state{
                        pmtu_state = NewPMTUState,
                        cc_state = NewCCState,
                        pmtu_probe_timer = undefined
                    },
                    maybe_send_pmtu_probe(State1);
                _ ->
                    %% ACK for non-probe packet - ignore for PMTU
                    State
            end;
        _ ->
            %% Not searching, just reset black hole counter on any ACK
            NewPMTUState = quic_pmtu:on_packet_acked(PMTUState),
            State#state{pmtu_state = NewPMTUState}
    end.

%% @doc Handle loss of a potential PMTU probe packet.
%% PacketSize is passed directly since lost packets are removed from sent_packets
%% before this function is called.
-spec handle_pmtu_probe_loss(non_neg_integer(), non_neg_integer(), #state{}) -> #state{}.
handle_pmtu_probe_loss(_PacketNumber, _PacketSize, #state{pmtu_state = undefined} = State) ->
    State;
handle_pmtu_probe_loss(PacketNumber, _PacketSize, #state{pmtu_state = PMTUState} = State) ->
    case quic_pmtu:get_state(PMTUState) of
        searching ->
            %% Check if this loss is for our probe packet
            case PMTUState#pmtu_state.probe_pn of
                PacketNumber ->
                    Gen = quic_pmtu:get_generation(PMTUState),
                    NewPMTUState = quic_pmtu:on_probe_lost(PacketNumber, Gen, PMTUState),
                    State1 = State#state{pmtu_state = NewPMTUState},
                    maybe_send_pmtu_probe(State1);
                _ ->
                    %% Loss of non-probe packet - ignore for PMTU
                    State
            end;
        _ ->
            %% Black hole detection is handled per event, see
            %% handle_pmtu_loss_event/2.
            State
    end.

%% @doc Black hole detection, ack side: a large packet acknowledged in
%% this ACK proves the path still passes them.
-spec handle_pmtu_ack_event([#sent_packet{}], #state{}) -> #state{}.
handle_pmtu_ack_event(_Acked, #state{pmtu_state = undefined} = State) ->
    State;
handle_pmtu_ack_event([], State) ->
    State;
handle_pmtu_ack_event(Acked, #state{pmtu_state = PMTUState} = State) ->
    Sizes = [Size || #sent_packet{size = Size} <- Acked],
    State#state{pmtu_state = quic_pmtu:on_ack_event(Sizes, PMTUState)}.

%% @doc Black hole detection, loss side: the newly declared losses of one
%% ACK are one strike if any of them was a large packet. Drops the MTU
%% to base when the strikes reach the threshold.
-spec handle_pmtu_loss_event([#sent_packet{}], #state{}) -> #state{}.
handle_pmtu_loss_event(_Lost, #state{pmtu_state = undefined} = State) ->
    State;
handle_pmtu_loss_event([], State) ->
    State;
handle_pmtu_loss_event(Lost, #state{pmtu_state = PMTUState, cc_state = CCState} = State) ->
    case quic_pmtu:get_state(PMTUState) of
        search_complete ->
            OldMTU = quic_pmtu:current_mtu(PMTUState),
            Sizes = [Size || #sent_packet{size = Size} <- Lost],
            NewPMTUState = quic_pmtu:on_loss_event(Sizes, PMTUState),
            NewMTU = quic_pmtu:current_mtu(NewPMTUState),
            NewCCState =
                case NewMTU < OldMTU of
                    true -> quic_cc:update_mtu(CCState, NewMTU);
                    false -> CCState
                end,
            State#state{
                pmtu_state = NewPMTUState,
                cc_state = NewCCState
            };
        _ ->
            State
    end.

%% @doc Get the current MTU for sending.
-spec get_current_mtu(#state{}) -> pos_integer().
get_current_mtu(#state{pmtu_state = undefined}) ->
    ?DEFAULT_MAX_UDP_PAYLOAD_SIZE;
get_current_mtu(#state{pmtu_state = PMTUState}) ->
    quic_pmtu:current_mtu(PMTUState).

%% @doc Get the local max UDP payload size for transport parameters.
%% Returns the configured max MTU from PMTU state, or the default if not configured.
-spec get_local_max_udp_payload_size(#state{}) -> pos_integer().
get_local_max_udp_payload_size(#state{pmtu_state = undefined}) ->
    ?DEFAULT_MAX_UDP_PAYLOAD_SIZE;
get_local_max_udp_payload_size(#state{pmtu_state = PMTUState}) ->
    PMTUState#pmtu_state.max_mtu.

%% The `max_udp_payload_size' transport parameter (RFC 9000 §18.2): the
%% largest UDP payload we are willing to receive. Distinct from the PMTU
%% ceiling, which bounds what we send. Defaults to what a 1500-byte path
%% delivers for the local address family, since a peer that takes the
%% parameter at face value and sends more would have it dropped.
-spec advertised_max_udp_payload_size(#state{}) -> pos_integer().
advertised_max_udp_payload_size(#state{cfg = #conn_cfg{max_udp_payload_size_local = Size}}) when
    is_integer(Size)
->
    Size;
advertised_max_udp_payload_size(#state{remote_addr = {IP, _Port}}) when is_tuple(IP) ->
    default_max_udp_payload_size(address_family(IP));
advertised_max_udp_payload_size(_State) ->
    default_max_udp_payload_size(inet6).

%% 1500-byte IP MTU less the IP and UDP headers.
default_max_udp_payload_size(inet) -> 1500 - 20 - 8;
default_max_udp_payload_size(inet6) -> 1500 - 40 - 8.
