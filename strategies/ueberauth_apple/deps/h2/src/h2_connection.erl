%% @doc HTTP/2 Connection State Machine (RFC 7540)
%%
%% This module implements the HTTP/2 connection protocol using gen_statem.
%% It handles both client and server modes, managing the connection preface,
%% settings exchange, stream lifecycle, flow control, and frame dispatch.
%%
%% States:
%% - preface: Exchanging connection preface
%% - settings: Exchanging SETTINGS frames
%% - connected: Ready for requests/responses
%% - goaway_sent: Graceful shutdown initiated by us
%% - goaway_received: Peer initiated shutdown
%% - closing: Connection closing
%%
-module(h2_connection).
-behaviour(gen_statem).

%% API
-export([start_link/3, start_link/4]).
-export([activate/1]).
-export([wait_connected/1, wait_connected/2]).
-export([send_request/4, send_request/5, send_request_headers/3, send_request_headers/4,
         send_response/4, respond/5, send_data/3, send_data/4, send_data/5]).
-export([set_stream_handler/3, set_stream_handler/4, unset_stream_handler/2]).
-export([consume/3]).
-export([send_trailers/3]).
-export([cancel_stream/2, cancel_stream/3]).
-export([send_goaway/1, send_goaway/2, close/1]).
-export([get_settings/1, get_peer_settings/1, peername/1]).
-export([controlling_process/2]).
-export([verify_stream_counts/1]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).
-export([preface/3, settings/3, connected/3, goaway_sent/3, goaway_received/3, closing/3]).

-include("h2.hrl").

-define(SETTINGS_TIMEOUT_MS, 5000).
-define(CLOSE_TIMEOUT_MS, 5000).
-define(GOAWAY_DRAIN_MS, 100).
%% RFC 9113 §5.1: post-close error classification needs to know whether the
%% stream was closed via END_STREAM (connection-scoped error) or RST_STREAM
%% (stream-scoped). We keep two layered caches so the lookup is exact for
%% both recent and less-recent streams:
%%   * full #stream record for the last ?CLOSED_STREAMS_LIMIT ids
%%     (needed for body/trailers follow-up logic that depends on the record),
%%   * a compact id → reason side map for the last ?CLOSED_REASONS_LIMIT ids.
%% Beyond both bounds we fall back to a stream-id-range heuristic.
-define(CLOSED_STREAMS_LIMIT, 100).
-define(CLOSED_REASONS_LIMIT, 10000).
%% RFC 9113 §10.5: mitigate PING and RST_STREAM floods. Counters reset every
%% second; exceeding the limit triggers GOAWAY(ENHANCE_YOUR_CALM).
-define(PING_FLOOD_LIMIT_PER_SEC, 20).
-define(RST_FLOOD_LIMIT_PER_SEC, 100).
%% RFC 9113 §10.5 / §6.5.2: cap the raw bytes of a HEADERS+CONTINUATION
%% block before HPACK decode, so a CONTINUATION flood cannot OOM the node
%% before max_header_list_size (which acts on decoded headers) can fire.
-define(MAX_HEADER_BLOCK_BYTES, 256 * 1024).
%% RFC 7541 §4.2: the peer can advertise an arbitrarily large
%% SETTINGS_HEADER_TABLE_SIZE; honoring it verbatim turns our encoder
%% dynamic table into a memory- and CPU-exhaustion vector (lookup is O(n)).
%% Cap the value we actually apply.
-define(MAX_PEER_HEADER_TABLE_SIZE, 65536).
%% Per-stream outbound send buffer cap. If the peer stops opening its
%% receive window, the only thing limiting our memory is this. Callers
%% that exceed the cap get {error, send_buffer_full} so they back off
%% instead of growing the connection process indefinitely.
-define(MAX_SEND_BUFFER_BYTES, 1024 * 1024).

%% Upper bound on the body bytes staged into a single coalesced socket write.
%% flush_stream_one_chunk/2 batches every flow-control-ready DATA frame into one
%% Transport:send instead of one send per frame; this caps the per-write iolist
%% so a large window cannot build an unbounded binary. Bodies past this still
%% drain via the existing {flush_stream,_} self-cast, one write per cap-sized
%% batch, so multi-MB responses keep yielding to inbound frames.
-define(MAX_COALESCED_BODY_BYTES, 1024 * 1024).

%% Stream states per RFC 7540 Section 5.1
-record(stream, {
    id :: non_neg_integer(),
    state = idle :: idle | open | half_closed_local | half_closed_remote | closed | reserved_local | reserved_remote,
    window_size :: integer(),
    recv_window_size :: integer(),
    send_buffer = <<>> :: binary(),
    pending_end_stream = false :: boolean(),
    header_buffer = [] :: iodata(),
    header_buffer_size = 0 :: non_neg_integer(),
    request_headers = [] :: [{binary(), binary()}],
    response_headers = [] :: [{binary(), binary()}],
    %% Optional pid to receive events for this stream (set_stream_handler).
    handler :: pid() | undefined,
    %% Where stream-scoped events go when no handler is registered yet.
    %%   owner  -> deliver to the connection owner (default; legacy client behaviour)
    %%   buffer -> hold in recv_buffer until a handler registers, then replay
    %% Server streams buffer implicitly (see dispatch_stream_event_inflight/4)
    %% to preserve the pre-existing "buffer DATA until set_stream_handler" model.
    dispatch_mode = owner :: owner | buffer,
    %% Events buffered before a handler is registered. Holds full event tuples
    %% in arrival order, most-recent first (reversed on replay). Generalises the
    %% old DATA-only buffer so response/trailers/stream_reset that race ahead of
    %% set_stream_handler are replayed too (gRPC bidi), never dropped to the owner.
    recv_buffer = [] :: [term()],
    %% Receive-side flow control mode (RFC 9113 §6.9):
    %%   auto   -> connection replenishes the stream window on dispatch (default)
    %%   manual -> window is only replenished by an explicit consume/3 call, so a
    %%             slow consumer applies backpressure instead of growing unbounded.
    flow_control = auto :: auto | manual,
    %% Bytes received but not yet acknowledged via consume/3 (manual mode only).
    unacked = 0 :: non_neg_integer(),
    %% Blocking send_data/5 callers parked until the send buffer drains, each with
    %% an optional timeout timer ref. Replied `ok` on drain, `{error, timeout}` on
    %% timer fire. Empty for the default non-blocking send path.
    send_waiters = [] :: [{term(), reference() | undefined}],
    %% Trailers queued behind still-buffered DATA: send_trailers carries
    %% END_STREAM, so it must not overtake DATA waiting on the flow-control
    %% window. Held here and emitted once the send_buffer drains (RFC 9113 §5.1
    %% ordering). undefined when no trailers are pending.
    pending_trailers :: undefined | [{binary(), binary()}],
    %% RFC 7540 §8.3: stream is a CONNECT tunnel — DATA frames carry raw
    %% bytes, END_STREAM is half-close, no trailers, no CL/TE on response.
    tunnel = false :: boolean(),
    %% RFC 9113 §8.1.1 body-length tracking:
    %% expected = parsed Content-Length (undefined if header absent).
    %% received = cumulative DATA payload size (flow-controlled).
    %% body_forbidden = HEAD request / 1xx / 204 / 304 response → no DATA allowed.
    %% Set once on initial HEADERS, used in handle_data_frame/5.
    expected_body_length :: undefined | non_neg_integer(),
    received_body_length = 0 :: non_neg_integer(),
    body_forbidden = false :: boolean(),
    %% Set once the client's initial (2xx+) response HEADERS has been dispatched.
    %% Interim 1xx responses do NOT set this; subsequent HEADERS after it are trailers.
    response_seen_final = false :: boolean(),
    %% Request method, captured server-side to decide body-forbidden and tunnel rules.
    request_method :: undefined | binary(),
    %% RFC 8441: Extended CONNECT protocol token (e.g. <<"websocket">>).
    %% Set when the request carries a `:protocol` pseudo-header.
    protocol :: undefined | binary(),
    %% RFC 9113 §5.1: how this stream reached `closed`. Determines whether
    %% later frames on it are a connection error (end_stream) or a stream
    %% error (rst). undefined while not closed.
    closed_reason :: undefined | end_stream | rst
}).

%% Connection state
-record(state, {
    mode :: client | server,
    socket :: gen_tcp:socket() | ssl:sslsocket(),
    transport :: gen_tcp | ssl,
    owner :: pid(),
    %% Monitor on the current owner, installed by controlling_process/2.
    %% The initial owner is reached via the start_link bidirectional link;
    %% subsequent owners are tracked via monitor so a dead owner is
    %% detected even when no link exists.
    owner_monitor = undefined :: undefined | reference(),
    buffer = <<>> :: binary(),

    %% Settings
    local_settings :: h2_settings:settings(),
    peer_settings :: h2_settings:settings(),
    pending_settings = [] :: [h2_settings:settings()],

    %% Cached peer settings values accessed on every frame / new stream.
    %% Refreshed whenever peer_settings changes (apply_peer_settings/2).
    peer_max_frame_size = ?DEFAULT_MAX_FRAME_SIZE :: non_neg_integer(),
    peer_initial_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
    peer_max_concurrent_streams = ?DEFAULT_MAX_CONCURRENT_STREAMS :: non_neg_integer() | unlimited,

    %% HPACK contexts
    encode_context :: h2_hpack:context(),
    decode_context :: h2_hpack:context(),

    %% Streams
    streams = #{} :: #{non_neg_integer() => #stream{}},
    %% Incrementally maintained stream counters, kept in sync by put_stream/3.
    %% Avoid folding the whole `streams` map (which also holds retained closed
    %% streams) on every new stream. See put_stream/3 and stream_count_delta/4.
    %% active: streams whose state =/= closed (any initiator).
    %% peer_active: peer-initiated streams in open / half_closed_*.
    active_stream_count = 0 :: non_neg_integer(),
    peer_active_stream_count = 0 :: non_neg_integer(),
    %% FIFO of closed stream ids in close order, bounded by ?CLOSED_STREAMS_LIMIT.
    %% When the limit is exceeded the oldest id is evicted from `streams`.
    closed_streams = queue:new() :: queue:queue(non_neg_integer()),
    closed_streams_count = 0 :: non_neg_integer(),
    %% Longer-lived compact id → reason map. Survives eviction from `streams`.
    closed_reasons = #{} :: #{non_neg_integer() => end_stream | rst},
    closed_reasons_q = queue:new() :: queue:queue(non_neg_integer()),
    closed_reasons_count = 0 :: non_neg_integer(),
    next_stream_id :: non_neg_integer(),  % 1 for client, 2 for server
    last_peer_stream_id = 0 :: non_neg_integer(),

    %% Flow control
    conn_window_size :: integer(),       % Our send window
    recv_conn_window_size :: integer(),  % Our receive window
    %% Size the receive window is refilled to (connection_window_size option).
    recv_conn_window_target = ?DEFAULT_INITIAL_WINDOW_SIZE :: pos_integer(),

    %% State tracking
    preface_received = false :: boolean(),
    settings_acked = false :: boolean(),
    goaway_sent = false :: boolean(),
    goaway_received = false :: boolean(),
    last_stream_id = 0 :: non_neg_integer(),
    goaway_error = no_error :: atom(),

    %% Timers
    settings_timer :: reference() | undefined,
    close_timer :: reference() | undefined,

    %% Callers waiting for connected state
    waiters = [] :: [gen_statem:from()],
    connected_notified = false :: boolean(),

    %% RFC 7540 §6.10: once HEADERS/PUSH_PROMISE/CONTINUATION without
    %% END_HEADERS arrives, the only frame we may accept until
    %% END_HEADERS is a matching CONTINUATION on the same stream.
    %% {StreamId, EndStream} while awaiting; undefined otherwise.
    expecting_continuation :: {non_neg_integer(), boolean()} | undefined,
    %% Field block of a HEADERS frame we rejected with a stream error,
    %% buffered until END_HEADERS so it can still be decoded (RFC 9113 §4.3):
    %% {StreamId, Buffer, Size}.
    discarded_block :: {non_neg_integer(), iodata(), non_neg_integer()} | undefined,

    %% Scheme to advertise on outbound :scheme pseudo-header.
    %% Derived from transport at init: ssl -> https, gen_tcp -> http.
    scheme = <<"https">> :: binary(),

    %% RFC 8441: when true, server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL=1
    %% and accepts requests with the `:protocol` pseudo-header. Server-side opt-in.
    enable_connect_protocol = false :: boolean(),

    %% RFC 9113 §10.5 flood counters. `{BucketSec, Count}`; BucketSec is
    %% `erlang:monotonic_time(second)` for the current second.
    ping_flood = {0, 0} :: {integer(), non_neg_integer()},
    rst_flood  = {0, 0} :: {integer(), non_neg_integer()}
}).

%% ============================================================================
%% API Functions
%% ============================================================================

%% @doc Start a connection as a client.
-spec start_link(client, gen_tcp:socket() | ssl:sslsocket(), map()) -> {ok, pid()} | {error, term()}.
start_link(client, Socket, Opts) ->
    start_link(client, Socket, self(), Opts).

%% @doc Start a connection with explicit owner.
-spec start_link(client | server, gen_tcp:socket() | ssl:sslsocket(), pid(), map()) -> {ok, pid()} | {error, term()}.
start_link(Mode, Socket, Owner, Opts) ->
    %% Validated here rather than in init/1: a {stop, _} from init/1 would
    %% log a crash report for what is a caller error.
    case maps:get(connection_window_size, Opts, ?DEFAULT_INITIAL_WINDOW_SIZE) of
        V when is_integer(V), V >= ?DEFAULT_INITIAL_WINDOW_SIZE, V =< ?MAX_WINDOW_SIZE ->
            gen_statem:start_link(?MODULE, {Mode, Socket, Owner, Opts}, []);
        V ->
            {error, {invalid_option, {connection_window_size, V}}}
    end.

%% @doc Wait for the connection to reach connected state.
-spec wait_connected(pid()) -> ok | {error, term()}.
wait_connected(Conn) ->
    wait_connected(Conn, ?DEFAULT_TIMEOUT_MS).

%% @doc Wait for the connection to reach connected state with timeout.
-spec wait_connected(pid(), timeout()) -> ok | {error, term()}.
wait_connected(Conn, Timeout) ->
    try
        gen_statem:call(Conn, wait_connected, Timeout)
    catch
        exit:{Reason, _} -> {error, Reason};
        exit:Reason -> {error, Reason}
    end.

%% @doc Activate the socket after ownership transfer.
%% Must be called after transferring socket ownership to this process.
%% Synchronous so the caller knows the preface + SETTINGS have been sent and
%% the socket has been set to active mode before it proceeds.
-spec activate(pid()) -> ok | {error, term()}.
activate(Conn) ->
    gen_statem:call(Conn, activate).

%% @doc Send a request (client mode).
-spec send_request(pid(), binary(), binary(), [{binary(), binary()}]) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(Conn, Method, Path, Headers) ->
    send_request(Conn, Method, Path, Headers, true).

%% @doc Send a request with EndStream flag (client mode).
-spec send_request(pid(), binary(), binary(), [{binary(), binary()}], boolean()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(Conn, Method, Path, Headers, EndStream) ->
    gen_statem:call(Conn, {send_request, Method, Path, Headers, EndStream}).

%% @doc Send a request with a pre-built header list (including pseudo-headers).
-spec send_request_headers(pid(), [{binary(), binary()}], boolean()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request_headers(Conn, Headers, EndStream) ->
    send_request_headers(Conn, Headers, EndStream, #{}).

%% @doc Send a request with a pre-built header list and per-stream options. For
%% gRPC bidi a dedicated call process passes `#{handler => self()}' so the
%% stream's events route to it from creation (race-free, no owner detour), and
%% optionally `#{flow_control => manual}' to apply receive-side backpressure.
%% `#{defer => true}' buffers events until a later set_stream_handler/3 replays
%% them when the handler pid is not known at creation time.
-spec send_request_headers(pid(), [{binary(), binary()}], boolean(), map()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request_headers(Conn, Headers, EndStream, Opts) when is_map(Opts) ->
    gen_statem:call(Conn, {send_request_headers, Headers, EndStream, Opts}).

%% @doc Register a pid to receive body data for StreamId.
%% By default any DATA frames that arrived before the handler was registered
%% are replayed to the handler pid as `{h2, Conn, {data, StreamId, Data, Fin}}'
%% messages, and the call returns `ok'. Pass `#{drain_buffer => true}' to
%% receive the raw buffer in the reply (`{ok, [{Data, Fin}, ...]}') and
%% forward it manually. Matches quic_h3:set_stream_handler/3,4.
-spec set_stream_handler(pid(), non_neg_integer(), pid()) ->
    ok | {ok, [{binary(), boolean()}]} | {error, term()}.
set_stream_handler(Conn, StreamId, Pid) ->
    set_stream_handler(Conn, StreamId, Pid, #{}).

-spec set_stream_handler(pid(), non_neg_integer(), pid(), map()) ->
    ok | {ok, [{binary(), boolean()}]} | {error, term()}.
set_stream_handler(Conn, StreamId, Pid, Opts) ->
    gen_statem:call(Conn, {set_stream_handler, StreamId, Pid, Opts}).

-spec unset_stream_handler(pid(), non_neg_integer()) -> ok.
unset_stream_handler(Conn, StreamId) ->
    gen_statem:call(Conn, {unset_stream_handler, StreamId}).

%% @doc Send a response (server mode).
-spec send_response(pid(), non_neg_integer(), non_neg_integer(), [{binary(), binary()}]) ->
    ok | {error, term()}.
send_response(Conn, StreamId, Status, Headers) ->
    gen_statem:call(Conn, {send_response, StreamId, Status, Headers}).

%% @doc Send a complete response (headers + full body) in one call. Returns
%% `need_fallback' when the fast path does not apply; callers (h2:respond/5)
%% then use send_response/4 + send_data/4.
-spec respond(pid(), non_neg_integer(), non_neg_integer(),
              [{binary(), binary()}], binary()) ->
    ok | need_fallback | {error, term()}.
respond(Conn, StreamId, Status, Headers, Body) ->
    gen_statem:call(Conn, {respond, StreamId, Status, Headers, Body}).

%% @doc Send data on a stream.
-spec send_data(pid(), non_neg_integer(), binary()) -> ok | {error, term()}.
send_data(Conn, StreamId, Data) ->
    send_data(Conn, StreamId, Data, false).

%% @doc Send data on a stream with end_stream flag.
%%
%% Default (non-blocking) backpressure: when the peer's flow-control window is
%% exhausted the data is buffered, and once the buffer would exceed the per-stream
%% cap the call returns `{error, send_buffer_full}' so the caller backs off rather
%% than growing the connection unboundedly.
-spec send_data(pid(), non_neg_integer(), binary(), boolean()) -> ok | {error, term()}.
send_data(Conn, StreamId, Data, EndStream) ->
    gen_statem:call(Conn, {send_data, StreamId, Data, EndStream}).

%% @doc Send data with per-call options. `#{block => Timeout}' turns send_data
%% into a blocking call: when the peer's window cannot accept the data yet the
%% caller is parked (bypassing the send_buffer_full cap) until the buffer drains,
%% returning `ok', or `{error, timeout}' if `Timeout' ms elapse first. Without
%% `block' this behaves exactly like send_data/4.
-spec send_data(pid(), non_neg_integer(), binary(), boolean(), map()) ->
    ok | {error, term()}.
send_data(Conn, StreamId, Data, EndStream, Opts) when is_map(Opts) ->
    case maps:get(block, Opts, undefined) of
        undefined ->
            gen_statem:call(Conn, {send_data, StreamId, Data, EndStream});
        Timeout ->
            %% Give the gen_statem call a longer deadline than the flow-control
            %% block so the {error, timeout} comes from us, not gen_statem.
            CallTimeout = call_timeout_for(Timeout),
            gen_statem:call(Conn, {send_data_blocking, StreamId, Data, EndStream, Timeout},
                            CallTimeout)
    end.

call_timeout_for(infinity) -> infinity;
call_timeout_for(Timeout) when is_integer(Timeout) -> Timeout + 1000.

%% @doc Acknowledge consumption of ByteCount received bytes on a manual-flow
%% stream, replenishing its receive window via WINDOW_UPDATE. No-op for streams
%% in the default `auto' flow-control mode. This is the receive-side backpressure
%% knob: a handler calls it only after it has processed data, so the peer's send
%% window tracks consumer progress instead of growing the mailbox unboundedly.
-spec consume(pid(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
consume(Conn, StreamId, ByteCount) when is_integer(ByteCount), ByteCount >= 0 ->
    gen_statem:call(Conn, {consume, StreamId, ByteCount}).

%% @doc Send trailers on a stream.
-spec send_trailers(pid(), non_neg_integer(), [{binary(), binary()}]) -> ok | {error, term()}.
send_trailers(Conn, StreamId, Trailers) ->
    gen_statem:call(Conn, {send_trailers, StreamId, Trailers}).

%% @doc Cancel a stream.
-spec cancel_stream(pid(), non_neg_integer()) -> ok | {error, term()}.
cancel_stream(Conn, StreamId) ->
    cancel_stream(Conn, StreamId, cancel).

%% @doc Cancel a stream with a specific error code.
-spec cancel_stream(pid(), non_neg_integer(), atom()) -> ok | {error, term()}.
cancel_stream(Conn, StreamId, ErrorCode) ->
    gen_statem:call(Conn, {cancel_stream, StreamId, ErrorCode}).

%% @doc Send GOAWAY frame.
-spec send_goaway(pid()) -> ok | {error, term()}.
send_goaway(Conn) ->
    send_goaway(Conn, no_error).

%% @doc Send GOAWAY frame with error code.
-spec send_goaway(pid(), atom()) -> ok | {error, term()}.
send_goaway(Conn, ErrorCode) ->
    gen_statem:call(Conn, {send_goaway, ErrorCode}).

%% @doc Close the connection.
-spec close(pid()) -> ok.
close(Conn) ->
    gen_statem:stop(Conn).

%% @doc Get local settings.
-spec get_settings(pid()) -> h2_settings:settings().
get_settings(Conn) ->
    gen_statem:call(Conn, get_settings).

%% @doc Get peer settings.
-spec get_peer_settings(pid()) -> h2_settings:settings().
get_peer_settings(Conn) ->
    gen_statem:call(Conn, get_peer_settings).

%% @doc Return the address of the connection's peer.
-spec peername(pid()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(Conn) ->
    gen_statem:call(Conn, peername).

%% @doc Transfer ownership of the connection.
-spec controlling_process(pid(), pid()) -> ok | {error, term()}.
controlling_process(Conn, NewOwner) ->
    gen_statem:call(Conn, {controlling_process, NewOwner}).

%% ============================================================================
%% gen_statem Callbacks
%% ============================================================================

callback_mode() -> [state_functions, state_enter].

init({Mode, Socket, Owner, Opts}) ->
    process_flag(trap_exit, true),

    %% Determine transport
    Transport = case is_ssl_socket(Socket) of
        true -> ssl;
        false -> gen_tcp
    end,

    %% Initialize settings.
    %% RFC 9113 §6.5.2: a server MUST NOT advertise SETTINGS_ENABLE_PUSH=1.
    %% We don't implement push as either client or server, so always 0.
    UserSettings = maps:get(settings, Opts, #{}),
    EnableConnectProtocol = Mode =:= server
                            andalso maps:get(enable_connect_protocol, Opts, false) =:= true,
    %% RFC 8441 §3: server opts in by sending SETTINGS_ENABLE_CONNECT_PROTOCOL=1.
    ConnectProtoSettings = case EnableConnectProtocol of
        true  -> #{enable_connect_protocol => 1};
        false -> #{}
    end,
    LocalSettings = maps:merge(
        maps:merge(h2_settings:default(), UserSettings),
        ConnectProtoSettings#{enable_push => 0}),
    PeerSettings = h2_settings:default(),

    %% Scheme depends on transport: TCP → http, TLS → https.
    Scheme = case Transport of
        ssl     -> <<"https">>;
        gen_tcp -> <<"http">>
    end,

    %% Initialize HPACK contexts
    EncodeCtx = h2_hpack:new_context(h2_settings:get(header_table_size, PeerSettings)),
    DecodeCtx = h2_hpack:new_context(h2_settings:get(header_table_size, LocalSettings)),

    %% RFC 9113 §6.9.2: SETTINGS_INITIAL_WINDOW_SIZE only affects stream
    %% flow-control windows; the connection window starts at 65535 octets
    %% and only changes via WINDOW_UPDATE frames. A larger
    %% connection_window_size is granted once the preface is out, see
    %% grow_conn_window/1.

    State = #state{
        mode = Mode,
        socket = Socket,
        transport = Transport,
        owner = Owner,
        local_settings = LocalSettings,
        peer_settings = PeerSettings,
        peer_max_frame_size = h2_settings:get(max_frame_size, PeerSettings),
        peer_initial_window_size = h2_settings:get(initial_window_size, PeerSettings),
        peer_max_concurrent_streams = h2_settings:get(max_concurrent_streams, PeerSettings),
        encode_context = EncodeCtx,
        decode_context = DecodeCtx,
        next_stream_id = case Mode of client -> 1; server -> 2 end,
        conn_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE,
        recv_conn_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE,
        recv_conn_window_target = maps:get(connection_window_size, Opts,
                                           ?DEFAULT_INITIAL_WINDOW_SIZE),
        scheme = Scheme,
        enable_connect_protocol = EnableConnectProtocol
    },

    %% Note: Socket is NOT set to active here - it will be activated
    %% in the preface state after socket ownership is properly transferred.
    %% The caller must transfer socket ownership before the connection can receive data.

    {ok, preface, State}.

terminate(Reason, _StateName, #state{socket = Socket, transport = Transport, goaway_sent = GoawaySent} = State) ->
    %% Send GOAWAY if not already sent
    case GoawaySent of
        false ->
            Frame = h2_frame:goaway(0, no_error, <<>>),
            _ = sock_send(State, h2_frame:encode_iodata(Frame));
        true ->
            ok
    end,
    Transport:close(Socket),
    %% Notify owner exactly once that the connection is gone.
    PeeledReason = peel_reason(Reason),
    notify_owner({h2, self(), {closed, PeeledReason}}, State),
    %% Also tell each per-stream handler so a bidi call process can clean up.
    notify_all_handlers({closed, PeeledReason}, State),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% ============================================================================
%% State: preface
%% ============================================================================

preface(enter, _OldState, State) ->
    %% Don't send preface/settings yet - wait for socket activation
    %% The caller will transfer socket ownership and call activate
    {keep_state, State};

preface(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(preface, Data, State);
preface(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(preface, Data, State);

preface(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    stop_and_notify_waiters({shutdown, tcp_closed}, State);
preface(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    stop_and_notify_waiters({shutdown, ssl_closed}, State);

preface(info, {tcp_error, Socket, Reason}, #state{socket = Socket} = State) ->
    stop_and_notify_waiters({shutdown, {tcp_error, Reason}}, State);
preface(info, {ssl_error, Socket, Reason}, #state{socket = Socket} = State) ->
    stop_and_notify_waiters({shutdown, {ssl_error, Reason}}, State);

preface(info, {timeout, Timer, settings_timeout}, #state{settings_timer = Timer} = State) ->
    %% Peer didn't respond in time
    State1 = send_goaway_frame(0, settings_timeout, State),
    {next_state, closing, State1};

preface({call, From}, activate, #state{mode = Mode, transport = Transport, socket = Socket} = State) ->
    %% Socket ownership has been transferred, now we can send and receive.
    case set_active(Transport, Socket) of
        ok ->
            State0 = case Mode of
                client -> send_preface(State);
                server -> send_settings_frame(State)
            end,
            State1 = grow_conn_window(State0),
            Timer = erlang:start_timer(?SETTINGS_TIMEOUT_MS, self(), settings_timeout),
            {keep_state, State1#state{settings_timer = Timer},
             [{reply, From, ok}]};
        {error, Reason} ->
            {stop_and_reply, {shutdown, {socket_error, Reason}},
             [{reply, From, {error, Reason}}], State}
    end;

preface({call, From}, Request, State) ->
    %% Queue or reject requests until connected
    handle_call_early(From, Request, preface, State);

preface(EventType, Event, State) ->
    handle_common(EventType, Event, preface, State).

%% ============================================================================
%% State: settings
%% ============================================================================

settings(enter, _OldState, State) ->
    {keep_state, State};

settings(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(settings, Data, State);
settings(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(settings, Data, State);

settings(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    stop_and_notify_waiters({shutdown, tcp_closed}, State);
settings(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    stop_and_notify_waiters({shutdown, ssl_closed}, State);

settings(info, {timeout, Timer, settings_timeout}, #state{settings_timer = Timer} = State) ->
    State1 = send_goaway_frame(0, settings_timeout, State),
    {next_state, closing, State1};

settings({call, From}, activate, State) ->
    %% Already activated on transition out of preface; idempotent.
    {keep_state, State, [{reply, From, ok}]};

%% A server may send response frames before the peer ACKs the server's SETTINGS:
%% it has already sent its own SETTINGS and received the client preface, so it is
%% allowed to respond. Clients pipeline requests right after the preface
%% (RFC 9113 §3.4); the per-request handler must not have its response dropped
%% just because the SETTINGS-ACK has not arrived yet. Handle the response-side
%% calls here exactly as `connected` does (the connection stays in `settings`
%% until the ACK arrives, then transitions normally).
settings({call, From}, Request, State) ->
    case handle_stream_call(From, Request, State) of
        false  -> handle_call_early(From, Request, settings, State);
        Result -> Result
    end;

settings(EventType, Event, State) ->
    handle_common(EventType, Event, settings, State).

%% ============================================================================
%% State: connected
%% ============================================================================

connected(enter, _OldState, #state{settings_timer = Timer, waiters = Waiters,
                                    connected_notified = Notified} = State) ->
    %% Cancel settings timer (and flush its message if it already fired).
    ok = cancel_timer(Timer),
    case Notified of
        true ->
            %% notify_connected/1 already fired inline from handle_frame
            {keep_state, State#state{settings_timer = undefined}};
        false ->
            notify_owner({h2, self(), connected}, State),
            Replies = [{reply, From, ok} || From <- Waiters],
            {keep_state, State#state{settings_timer = undefined, waiters = [],
                                      connected_notified = true}, Replies}
    end;

connected(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(connected, Data, State);
connected(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(connected, Data, State);

connected(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, tcp_closed}, State};
connected(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, ssl_closed}, State};

connected({call, From}, {send_request, Method, Path, Headers, EndStream}, State) ->
    handle_send_request(From, Method, Path, Headers, EndStream, State);

connected({call, From}, {send_request_headers, Headers, EndStream, Opts}, State) ->
    handle_send_request_headers(From, Headers, EndStream, Opts, State);

connected({call, From}, {send_goaway, ErrorCode}, State) ->
    handle_send_goaway(From, ErrorCode, connected, State);

connected({call, From}, wait_connected, State) ->
    %% Already connected, reply immediately
    {keep_state, State, [{reply, From, ok}]};

connected({call, From}, Request, State) ->
    case handle_stream_call(From, Request, State) of
        false  -> handle_call_common(From, Request, connected, State);
        Result -> Result
    end;

connected(EventType, Event, State) ->
    %% Routes cast {flush_stream, _} (send_data continuation) through
    %% handle_common so it's handled uniformly across all live states.
    handle_common(EventType, Event, connected, State).

%% ============================================================================
%% State: goaway_sent
%% ============================================================================

goaway_sent(enter, _OldState, #state{close_timer = Timer} = State) when Timer =/= undefined ->
    %% Drain timer already armed by handle_send_goaway.
    {keep_state, State};
goaway_sent(enter, _OldState, State) ->
    %% No drain timer (e.g. internally-triggered error GOAWAY) — close soon.
    Timer = erlang:start_timer(?CLOSE_TIMEOUT_MS, self(), close_timeout),
    {keep_state, State#state{close_timer = Timer}};

goaway_sent(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(goaway_sent, Data, State);
goaway_sent(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(goaway_sent, Data, State);

goaway_sent(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, tcp_closed}, State};
goaway_sent(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, ssl_closed}, State};

goaway_sent(info, {timeout, Timer, goaway_drain},
            #state{close_timer = Timer, last_peer_stream_id = LastId,
                   goaway_error = ErrorCode} = State) ->
    %% Drain window elapsed — send the real GOAWAY with the actual last
    %% peer-initiated stream id and close.
    State1 = send_goaway_frame(LastId, ErrorCode, State#state{close_timer = undefined}),
    {stop, {shutdown, goaway_drained}, State1};

goaway_sent(info, {timeout, Timer, close_timeout}, #state{close_timer = Timer} = State) ->
    {stop, {shutdown, close_timeout}, State};

goaway_sent({call, From}, {send_request, _, _, _, _}, State) ->
    {keep_state, State, [{reply, From, {error, goaway_sent}}]};
goaway_sent({call, From}, {send_request_headers, _, _, _}, State) ->
    {keep_state, State, [{reply, From, {error, goaway_sent}}]};

goaway_sent({call, From}, wait_connected, State) ->
    {keep_state, State, [{reply, From, ok}]};

goaway_sent({call, From}, Request, State) ->
    %% Existing streams stay valid after a GOAWAY (RFC 9113 6.8): every
    %% per-stream operation keeps working, only new streams are refused.
    case handle_stream_call(From, Request, State) of
        false  -> handle_call_common(From, Request, goaway_sent, State);
        Result -> Result
    end;

goaway_sent(EventType, Event, State) ->
    handle_common(EventType, Event, goaway_sent, State).

%% ============================================================================
%% State: goaway_received
%% ============================================================================

goaway_received(enter, _OldState, State) ->
    {keep_state, State};

goaway_received(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(goaway_received, Data, State);
goaway_received(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(goaway_received, Data, State);

goaway_received(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, tcp_closed}, State};
goaway_received(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, ssl_closed}, State};

goaway_received({call, From}, {send_request, _, _, _, _}, State) ->
    {keep_state, State, [{reply, From, {error, goaway_received}}]};
goaway_received({call, From}, {send_request_headers, _, _, _}, State) ->
    {keep_state, State, [{reply, From, {error, goaway_received}}]};

goaway_received({call, From}, {send_goaway, ErrorCode}, State) ->
    handle_send_goaway(From, ErrorCode, goaway_received, State);

goaway_received({call, From}, wait_connected, State) ->
    {keep_state, State, [{reply, From, ok}]};

goaway_received({call, From}, Request, State) ->
    %% Existing streams stay valid after a GOAWAY (RFC 9113 6.8): every
    %% per-stream operation keeps working, and a stream the peer refused
    %% (id above last_stream_id) needs cancel_stream to be dropped.
    case handle_stream_call(From, Request, State) of
        false  -> handle_call_common(From, Request, goaway_received, State);
        Result -> Result
    end;

goaway_received(EventType, Event, State) ->
    handle_common(EventType, Event, goaway_received, State).

%% ============================================================================
%% State: closing
%% ============================================================================

closing(enter, _OldState, #state{socket = Socket, transport = Transport, waiters = Waiters, goaway_error = ErrorCode} = State) ->
    %% We entered `closing` after sending GOAWAY for a connection error.
    %% Half-close the write side so the queued GOAWAY is flushed and the
    %% peer observes a clean FIN; then keep reading to drain any in-flight
    %% payload still sitting in the kernel recv buffer. A full close() with
    %% unread data is what makes Linux send RST instead of FIN, and that is
    %% what was masking our GOAWAY on the h2spec oversized-frame case
    %% (RFC 9113 §4.2, §5.4). terminate/3 does the final close once the
    %% peer closes its end or the safety timer fires.
    _ = shutdown_write(Transport, Socket),
    _ = set_active(Transport, Socket),
    Timer = erlang:start_timer(?CLOSE_TIMEOUT_MS, self(), close_timeout),
    Replies = [{reply, From, {error, ErrorCode}} || From <- Waiters],
    {keep_state, State#state{close_timer = Timer, waiters = []}, Replies};

closing(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, tcp_closed}, State};
closing(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, {shutdown, ssl_closed}, State};

closing(info, {timeout, Timer, close_timeout}, #state{close_timer = Timer} = State) ->
    {stop, {shutdown, close_timeout}, State};

closing(info, {tcp, _Socket, _Data}, State) ->
    %% Ignore incoming data
    {keep_state, State};
closing(info, {ssl, _Socket, _Data}, State) ->
    {keep_state, State};

closing({call, From}, _, State) ->
    {keep_state, State, [{reply, From, {error, closing}}]};

closing(EventType, Event, State) ->
    handle_common(EventType, Event, closing, State).

%% ============================================================================
%% Internal: Data Handling
%% ============================================================================

handle_data(StateName, Data, #state{buffer = Buffer, mode = Mode, preface_received = PrefaceReceived} = State) ->
    DataBin = iolist_to_binary(Data),
    NewBuffer = <<Buffer/binary, DataBin/binary>>,
    State1 = State#state{buffer = NewBuffer},

    %% Check for preface if server and not yet received
    case Mode of
        server when not PrefaceReceived ->
            case check_preface(NewBuffer) of
                {ok, Rest} ->
                    State2 = State1#state{buffer = Rest, preface_received = true},
                    process_frames(StateName, State2);
                need_more ->
                    case set_active(State1#state.transport, State1#state.socket) of
                        ok ->
                            {keep_state, State1};
                        {error, Reason} ->
                            {stop, {shutdown, {socket_error, Reason}}, State1}
                    end;
                {error, Reason} ->
                    State2 = send_goaway_frame(0, protocol_error, State1),
                    {stop, {shutdown, {preface_error, Reason}}, State2}
            end;
        _ ->
            process_frames(StateName, State1)
    end.

check_preface(Buffer) when byte_size(Buffer) < ?H2_PREFACE_SIZE ->
    need_more;
check_preface(Buffer) ->
    case Buffer of
        <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", Rest/binary>> ->
            {ok, Rest};
        _ ->
            {error, invalid_preface}
    end.

process_frames(StateName, #state{buffer = Buffer, local_settings = Local} = State) ->
    MaxFrameSize = h2_settings:get(max_frame_size, Local),
    case h2_frame:decode(Buffer, MaxFrameSize) of
        {ok, Frame, Rest} ->
            case handle_frame(StateName, Frame, State#state{buffer = Rest}) of
                {ok, NewStateName, NewState} ->
                    process_frames(next_frame_state(StateName, NewStateName), NewState);
                {stop, Reason, NewState} ->
                    {stop, Reason, NewState};
                {error, ErrorCode, NewState} ->
                    NewState1 = send_goaway_frame(NewState#state.last_peer_stream_id, ErrorCode, NewState),
                    {next_state, closing, NewState1}
            end;
        {more, _Needed} ->
            case set_active(State#state.transport, State#state.socket) of
                ok ->
                    %% Determine the correct state based on connection conditions
                    determine_state_transition(StateName, State);
                {error, Reason} ->
                    {stop, {shutdown, {socket_error, Reason}}, State}
            end;
        {error, {stream_error, StreamId, ErrorCode}, Rest} ->
            %% Frame-level decode error scoped to a single stream
            %% (e.g. WINDOW_UPDATE 0 on a non-zero stream id).
            send_rst_stream(StreamId, ErrorCode, State),
            State1 = close_stream(StreamId, rst, State),
            process_frames(StateName, State1#state{buffer = Rest});
        {error, Reason} ->
            State1 = send_goaway_frame(State#state.last_peer_stream_id, Reason, State),
            {next_state, closing, State1}
    end.

%% Most frame handlers report `connected' whatever state they ran in. Once a
%% GOAWAY has been sent or received the connection must stay in that state,
%% so a frame handled there cannot move it back to `connected'.
next_frame_state(goaway_sent, _NewStateName) -> goaway_sent;
next_frame_state(goaway_received, _NewStateName) -> goaway_received;
next_frame_state(_StateName, NewStateName) -> NewStateName.

%% Determine the correct state based on connection conditions
determine_state_transition(goaway_sent, State) ->
    {next_state, goaway_sent, State};
determine_state_transition(goaway_received, State) ->
    {next_state, goaway_received, State};
determine_state_transition(_StateName, #state{mode = Mode, preface_received = PrefaceReceived,
                                               settings_acked = SettingsAcked} = State) ->
    %% For client: connected when we've received and acked peer's settings,
    %% and received ack for our settings
    %% For server: connected when preface received, settings exchanged
    case Mode of
        client ->
            case SettingsAcked of
                true -> {next_state, connected, State};
                false -> {next_state, settings, State}
            end;
        server ->
            case {PrefaceReceived, SettingsAcked} of
                {true, true} -> {next_state, connected, State};
                {true, false} -> {next_state, settings, State};
                {false, _} -> {keep_state, State}
            end
    end.

%% ============================================================================
%% Internal: Frame Handling
%% ============================================================================

%% RFC 7540 §6.10: while awaiting CONTINUATION, only a CONTINUATION on the
%% same stream is allowed. Anything else is a connection PROTOCOL_ERROR.
handle_frame(_StateName, Frame, #state{expecting_continuation = {_StreamId, _}} = State)
  when element(1, Frame) =/= continuation ->
    {error, protocol_error, State};
handle_frame(_StateName, {continuation, StreamId, _, _}, #state{expecting_continuation = {Expected, _}} = State)
  when StreamId =/= Expected ->
    {error, protocol_error, State};

handle_frame(_StateName, {settings, Settings}, State) ->
    handle_settings(Settings, State);

handle_frame(_StateName, {settings_ack}, #state{pending_settings = [Pending|Rest]} = State) ->
    %% Apply our pending settings
    State1 = apply_local_settings(Pending, State),
    State2 = State1#state{pending_settings = Rest, settings_acked = true},
    NewStateName = case State2#state.preface_received orelse State2#state.mode =:= client of
        true -> connected;
        false -> settings
    end,
    State3 = case NewStateName of
        connected -> notify_connected(State2);
        _ -> State2
    end,
    {ok, NewStateName, State3};
handle_frame(StateName, {settings_ack}, State) ->
    %% Unsolicited SETTINGS ACK with no pending settings. RFC 9113 §6.5.3
    %% technically calls this a PROTOCOL_ERROR; we stay lenient and ignore
    %% it, but preserve the current state instead of forcing `connected'
    %% (which would short-circuit the preface state machine server-side).
    {ok, StateName, State};

handle_frame(_StateName, {ping, Data}, State) ->
    case bump_flood_counter(ping, State) of
        {ok, State1} ->
            Frame = h2_frame:ping_ack(Data),
            case send_frame(Frame, State1) of
                ok -> {ok, connected, State1};
                {error, Reason} ->
                    {stop, {shutdown, {send_failed, Reason}}, State1}
            end;
        flood ->
            {error, enhance_your_calm, State}
    end;

handle_frame(_StateName, {ping_ack, _Data}, State) ->
    %% PING response received
    {ok, connected, State};

handle_frame(StateName, {goaway, LastStreamId, ErrorCodeInt, _DebugData}, State) ->
    ErrorCode = h2_error:name(ErrorCodeInt),
    notify_owner({h2, self(), {goaway, LastStreamId, ErrorCode}}, State),
    %% Also tell each per-stream handler so a bidi call process (which owns its
    %% stream's events but not the connection) learns the connection is going away.
    notify_all_handlers({goaway, LastStreamId, ErrorCode}, State),
    State1 = State#state{goaway_received = true, last_stream_id = LastStreamId},
    case StateName of
        goaway_sent -> {stop, {shutdown, goaway_exchange}, State1};
        _ -> {ok, goaway_received, State1}
    end;

handle_frame(_StateName, {window_update, 0, Increment}, #state{conn_window_size = Window} = State) ->
    NewWindow = Window + Increment,
    if
        NewWindow > ?MAX_WINDOW_SIZE ->
            {error, flow_control_error, State};
        true ->
            %% Try to send buffered data
            State1 = State#state{conn_window_size = NewWindow},
            State2 = flush_send_buffers(State1),
            {ok, connected, State2}
    end;

handle_frame(_StateName, {window_update, StreamId, Increment}, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{window_size = Window} = Stream} ->
            NewWindow = Window + Increment,
            if
                NewWindow > ?MAX_WINDOW_SIZE ->
                    send_rst_stream(StreamId, flow_control_error, State),
                    State1 = close_stream(StreamId, rst, State),
                    {ok, connected, State1};
                true ->
                    Stream1 = Stream#stream{window_size = NewWindow},
                    State1 = State#state{streams = maps:put(StreamId, Stream1, Streams)},
                    State2 = flush_stream_buffer(StreamId, State1),
                    {ok, connected, State2}
            end;
        error ->
            %% RFC 9113 §5.1: a frame other than HEADERS/PRIORITY on an idle
            %% stream is a connection PROTOCOL_ERROR. An "evicted closed"
            %% stream just gets ignored (loose end-of-lifecycle).
            case in_closed_stream_range(StreamId, State) of
                true  -> {ok, connected, State};
                false -> {error, protocol_error, State}
            end
    end;

handle_frame(_StateName, {headers, StreamId, HeaderBlock, EndStream, EndHeaders}, State) ->
    handle_headers(StreamId, HeaderBlock, EndStream, EndHeaders, undefined, State);

%% RFC 9113 §5.3.1: HEADERS with inline priority cannot depend on itself.
handle_frame(_StateName, {headers, StreamId, HeaderBlock, _EndStream, EndHeaders,
                           {_Exclusive, StreamId, _Weight}}, State) ->
    reject_header_block(StreamId, protocol_error, HeaderBlock, EndHeaders, State);
handle_frame(_StateName, {headers, StreamId, HeaderBlock, EndStream, EndHeaders, Priority}, State) ->
    handle_headers(StreamId, HeaderBlock, EndStream, EndHeaders, Priority, State);

handle_frame(_StateName, {continuation, StreamId, HeaderBlock, EndHeaders}, State) ->
    handle_continuation(StreamId, HeaderBlock, EndHeaders, State);

handle_frame(_StateName, {data, StreamId, Data, EndStream, FlowControlled}, State) ->
    handle_data_frame(StreamId, Data, EndStream, FlowControlled, State);

handle_frame(_StateName, {rst_stream, StreamId, ErrorCode},
             #state{streams = Streams} = State) ->
    case bump_flood_counter(rst, State) of
        flood ->
            {error, enhance_your_calm, State};
        {ok, State0} ->
            %% RFC 7540 §6.4 / §5.1: RST_STREAM on an "idle" stream (one that was
            %% never opened by either side) is a connection PROTOCOL_ERROR.
            WasSeen = maps:is_key(StreamId, Streams)
                 orelse recently_closed_reason(StreamId, State0) =/= unknown
                 orelse in_closed_stream_range(StreamId, State0),
            case WasSeen of
                true ->
                    State0a = dispatch_stream_event(StreamId, {stream_reset, StreamId,
                                             h2_error:name(ErrorCode)}, State0),
                    State1 = close_stream(StreamId, rst, State0a),
                    {ok, connected, State1};
                false ->
                    {error, protocol_error, State0}
            end
    end;

%% RFC 9113 §5.3.1: a stream cannot depend on itself — stream PROTOCOL_ERROR.
handle_frame(_StateName, {priority, StreamId, _Exclusive, StreamId, _Weight}, State) ->
    send_rst_stream(StreamId, protocol_error, State),
    {ok, connected, State};
handle_frame(_StateName, {priority, _StreamId, _Exclusive, _DependsOn, _Weight}, State) ->
    %% Priority is advisory, ignore
    {ok, connected, State};

%% RFC 9113 §8.4: PUSH_PROMISE MUST only be sent by a server — a server
%% receiving it is a connection PROTOCOL_ERROR. On the client side we
%% advertise SETTINGS_ENABLE_PUSH=0, so the peer MUST NOT send
%% PUSH_PROMISE at all; if it does, §6.5.2 requires a connection
%% PROTOCOL_ERROR.
handle_frame(_StateName, {push_promise, _, _, _, _}, State) ->
    {error, protocol_error, State};

%% RFC 9113 §4.1: frames of unknown type MUST be ignored and discarded.
handle_frame(_StateName, {unknown_frame, _Type, _Flags, _StreamId, _Payload}, State) ->
    {ok, connected, State}.

%% ============================================================================
%% Internal: Settings Handling
%% ============================================================================

handle_settings(Settings, #state{mode = Mode, peer_settings = OldSettings} = State) ->
    %% Decode and validate settings. Validation is mode-aware so a client
    %% receiving SETTINGS_ENABLE_PUSH=1 can reject per RFC 9113 §6.5.2.
    case h2_settings:decode(encode_settings_list(Settings)) of
        {ok, NewSettings} ->
            case h2_settings:validate(NewSettings, Mode) of
                ok ->
                    %% Merge and apply
                    MergedSettings = h2_settings:merge(OldSettings, NewSettings),
                    case apply_peer_settings(MergedSettings, State) of
                        {ok, State1} ->
                            case send_frame(h2_frame:settings_ack(), State1) of
                                ok ->
                                    NewStateName = case State1#state.settings_acked of
                                        true -> connected;
                                        false -> settings
                                    end,
                                    %% RFC 9113 §6.9.2: a larger initial window
                                    %% can unblock data already buffered on
                                    %% open streams, and no WINDOW_UPDATE will
                                    %% come to drain it.
                                    State2 = case window_grew(OldSettings, MergedSettings) of
                                        true -> flush_send_buffers(State1);
                                        false -> State1
                                    end,
                                    {ok, NewStateName, State2};
                                {error, Reason} ->
                                    {stop, {shutdown, {send_failed, Reason}}, State1}
                            end;
                        {error, ErrCode} ->
                            {error, ErrCode, State}
                    end;
                %% RFC 9113 §6.9.2: IWS above 2^31-1 is FLOW_CONTROL_ERROR,
                %% not PROTOCOL_ERROR.
                {error, {initial_window_size, _}} ->
                    {error, flow_control_error, State};
                {error, _Reason} ->
                    {error, protocol_error, State}
            end;
        {error, _Reason} ->
            {error, protocol_error, State}
    end.

window_grew(OldSettings, NewSettings) ->
    h2_settings:get(initial_window_size, NewSettings) >
        h2_settings:get(initial_window_size, OldSettings).

encode_settings_list(Settings) ->
    lists:foldl(fun({Id, Value}, Acc) ->
        <<Acc/binary, Id:16, Value:32>>
    end, <<>>, Settings).

apply_peer_settings(Settings, #state{encode_context = EncCtx, streams = Streams,
                                      peer_settings = OldSettings} = State) ->
    PeerTableSize = h2_settings:get(header_table_size, Settings),
    AppliedTableSize = min(PeerTableSize, ?MAX_PEER_HEADER_TABLE_SIZE),
    EncCtx1 = h2_hpack:set_max_table_size(AppliedTableSize, EncCtx),

    OldWindow = h2_settings:get(initial_window_size, OldSettings),
    NewWindow = h2_settings:get(initial_window_size, Settings),
    Delta = NewWindow - OldWindow,
    %% RFC 7540 §6.9.2: if the change makes any stream's flow-control window
    %% exceed 2^31-1, treat as connection FLOW_CONTROL_ERROR.
    Overflow = maps:fold(fun(_Id, #stream{window_size = W}, Acc) ->
        Acc orelse (W + Delta) > ?MAX_WINDOW_SIZE
    end, false, Streams),
    case Overflow of
        true ->
            {error, flow_control_error};
        false ->
            Streams1 = maps:map(fun(_Id, #stream{window_size = W} = S) ->
                S#stream{window_size = W + Delta}
            end, Streams),
            {ok, State#state{
                peer_settings = Settings,
                peer_max_frame_size = h2_settings:get(max_frame_size, Settings),
                peer_initial_window_size = NewWindow,
                peer_max_concurrent_streams = h2_settings:get(max_concurrent_streams, Settings),
                encode_context = EncCtx1,
                streams = Streams1
            }}
    end.

apply_local_settings(Settings, #state{decode_context = DecCtx, local_settings = Prev} = State) ->
    %% Update HPACK decoder table size
    NewTableSize = h2_settings:get(header_table_size, Settings),
    OldTableSize = h2_settings:get(header_table_size, Prev),
    DecCtx1 = h2_hpack:set_max_table_size(NewTableSize, DecCtx),
    %% RFC 7541 §6.3: peer-advertised limit (= our SETTINGS_HEADER_TABLE_SIZE)
    %% caps any size update the peer's encoder may send.
    DecCtx1a = h2_hpack:set_peer_max_table_size(NewTableSize, DecCtx1),
    %% RFC 7541 §4.2: when we reduce HEADER_TABLE_SIZE, the peer's next
    %% header block MUST start with a size update at or below the new max.
    DecCtx2 = case NewTableSize < OldTableSize of
        true -> h2_hpack:mark_pending_size_update(DecCtx1a);
        false -> DecCtx1a
    end,
    State#state{
        local_settings = Settings,
        decode_context = DecCtx2
    }.

%% ============================================================================
%% Internal: Headers Handling
%% ============================================================================

handle_headers(StreamId, HeaderBlock, EndStream, EndHeaders, _Priority, #state{mode = Mode, streams = Streams} = State) ->
    %% Check if this is a response on an existing stream or a new stream
    case maps:find(StreamId, Streams) of
        {ok, #stream{state = StreamState} = Stream}
          when StreamState =:= open; StreamState =:= half_closed_local ->
            %% Existing stream — response (client) or trailers
            case EndHeaders of
                true ->
                    decode_and_process_headers(StreamId, HeaderBlock, EndStream, State);
                false ->
                    Stream1 = Stream#stream{header_buffer = HeaderBlock,
                                            header_buffer_size = byte_size(HeaderBlock)},
                    State1 = put_stream(StreamId, Stream1, State),
                    State2 = State1#state{expecting_continuation = {StreamId, EndStream}},
                    {ok, connected, State2}
            end;
        {ok, #stream{state = closed, closed_reason = end_stream}} ->
            %% RFC 9113 §5.1: a stream closed via END_STREAM accepts only
            %% PRIORITY; HEADERS arriving on it is a CONNECTION error
            %% STREAM_CLOSED.
            {error, stream_closed, State};
        {ok, #stream{state = closed, closed_reason = rst}} ->
            %% RFC 9113 §5.1: after RST_STREAM, further frames on the stream
            %% are a stream error STREAM_CLOSED (peer/self may have in-flight
            %% frames; don't tear down the connection).
            reject_header_block(StreamId, stream_closed, HeaderBlock, EndHeaders, State);
        {ok, _Stream} ->
            %% RFC 9113 §5.1 (half_closed_remote): HEADERS in this state is a
            %% stream error STREAM_CLOSED.
            reject_header_block(StreamId, stream_closed, HeaderBlock, EndHeaders, State);
        error ->
            %% No active record. If the id was closed recently (record
            %% evicted but reason retained), apply the spec-correct
            %% classification before treating it as a new stream.
            case recently_closed_reason(StreamId, State) of
                end_stream ->
                    {error, stream_closed, State};
                rst ->
                    reject_header_block(StreamId, stream_closed, HeaderBlock,
                                        EndHeaders, State);
                unknown ->
                    handle_headers_new(StreamId, HeaderBlock, EndStream, EndHeaders, Mode, State)
            end
    end.

handle_headers_new(StreamId, HeaderBlock, EndStream, EndHeaders, Mode, State) ->
            case validate_stream_id(StreamId, Mode, State) of
                ok ->
                    %% RFC 9113 §5.1.2: reject peer-initiated streams that
                    %% would exceed our advertised SETTINGS_MAX_CONCURRENT_STREAMS.
                    case peer_stream_limit_exceeded(Mode, State) of
                        true ->
                            reject_header_block(StreamId, refused_stream,
                                                HeaderBlock, EndHeaders, State);
                        false ->
                            case EndHeaders of
                                true ->
                                    decode_and_process_headers(StreamId, HeaderBlock, EndStream, State);
                                false ->
                                    Stream = get_or_create_stream(StreamId, State),
                                    Stream1 = Stream#stream{header_buffer = HeaderBlock,
                                                            header_buffer_size = byte_size(HeaderBlock)},
                                    State1 = put_stream(StreamId, Stream1, State),
                                    State2 = State1#state{expecting_continuation = {StreamId, EndStream}},
                                    {ok, connected, State2}
                            end
                    end;
                {error, ErrorCode} ->
                    {error, ErrorCode, State}
            end.

%% RFC 9113 §5.1.2: counts streams this endpoint accepted from the peer that
%% are still in open / half_closed_* (the three states that count toward the
%% limit). Idle, reserved, and closed do not count. We only check the local
%% setting because exceeding it is what the spec scopes to REFUSED_STREAM.
peer_stream_limit_exceeded(Mode, #state{local_settings = Settings} = State) ->
    case h2_settings:get(max_concurrent_streams, Settings) of
        unlimited -> false;
        N when is_integer(N) ->
            count_peer_active_streams(Mode, State) >= N
    end.

%% O(1): peer_active_stream_count is kept in sync by put_stream/3. Mode is
%% already baked into the counter (the connection's mode is fixed).
count_peer_active_streams(_Mode, #state{peer_active_stream_count = N}) ->
    N.

%% RFC 9113 §6.10: CONTINUATION is only valid immediately after a
%% HEADERS/PUSH_PROMISE/CONTINUATION without END_HEADERS on the same stream.
%% Anything else is a connection PROTOCOL_ERROR, including CONTINUATION on a
%% closed stream.
handle_continuation(_StreamId, _HeaderBlock, _EndHeaders,
                    #state{expecting_continuation = undefined} = State) ->
    {error, protocol_error, State};
handle_continuation(StreamId, HeaderBlock, EndHeaders,
                    #state{discarded_block = {StreamId, Buffer, Size}} = State) ->
    NewSize = Size + byte_size(HeaderBlock),
    case NewSize > ?MAX_HEADER_BLOCK_BYTES of
        true ->
            {error, enhance_your_calm, State};
        false ->
            NewBuffer = [Buffer, HeaderBlock],
            case EndHeaders of
                true ->
                    decode_discarded_block(
                      iolist_to_binary(NewBuffer),
                      State#state{expecting_continuation = undefined,
                                  discarded_block = undefined});
                false ->
                    {ok, connected,
                     State#state{discarded_block = {StreamId, NewBuffer, NewSize}}}
            end
    end;
handle_continuation(StreamId, HeaderBlock, EndHeaders,
                    #state{streams = Streams,
                           expecting_continuation = Expecting} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{state = closed}} ->
            {error, protocol_error, State};
        {ok, #stream{header_buffer = Buffer,
                     header_buffer_size = OldSize} = Stream} ->
            NewSize = OldSize + byte_size(HeaderBlock),
            case NewSize > ?MAX_HEADER_BLOCK_BYTES of
                true ->
                    {error, enhance_your_calm, State};
                false ->
                    NewBuffer = [Buffer, HeaderBlock],
                    case EndHeaders of
                        true ->
                            Stream1 = Stream#stream{header_buffer = [],
                                                    header_buffer_size = 0},
                            State1 = put_stream(StreamId, Stream1, State),
                            %% Restore the original END_STREAM flag captured when
                            %% HEADERS arrived; clear expecting_continuation.
                            {_, EndStream} = Expecting,
                            State2 = State1#state{expecting_continuation = undefined},
                            decode_and_process_headers(StreamId, iolist_to_binary(NewBuffer), EndStream, State2);
                        false ->
                            Stream1 = Stream#stream{header_buffer = NewBuffer,
                                                    header_buffer_size = NewSize},
                            State1 = put_stream(StreamId, Stream1, State),
                            {ok, connected, State1}
                    end
            end;
        error ->
            {error, protocol_error, State}
    end.

%% RFC 9113 §4.3: every field block updates the HPACK decoding context, so a
%% block must be decoded even when its stream is refused or already reset.
%% Skipping it leaves our dynamic table behind the peer's, and the next block
%% that references the missing entries fails with COMPRESSION_ERROR, taking
%% the connection down. Answer the stream error, then decode the block
%% (buffering any CONTINUATION frames) and drop the headers.
reject_header_block(StreamId, ErrorCode, HeaderBlock, EndHeaders, State) ->
    send_rst_stream(StreamId, ErrorCode, State),
    case EndHeaders of
        true ->
            decode_discarded_block(HeaderBlock, State);
        false ->
            {ok, connected,
             State#state{expecting_continuation = {StreamId, false},
                         discarded_block = {StreamId, HeaderBlock,
                                            byte_size(HeaderBlock)}}}
    end.

decode_discarded_block(HeaderBlock, #state{decode_context = DecCtx} = State) ->
    case h2_hpack:decode(HeaderBlock, DecCtx) of
        {ok, _Headers, DecCtx1} ->
            {ok, connected, State#state{decode_context = DecCtx1}};
        {error, _Reason} ->
            logger:error("h2: HPACK decode error", #{}),
            {error, compression_error, State}
    end.

decode_and_process_headers(StreamId, HeaderBlock, EndStream, #state{decode_context = DecCtx, mode = Mode} = State) ->
    case h2_hpack:decode(HeaderBlock, DecCtx) of
        {ok, Headers, DecCtx1} ->
            State1 = State#state{decode_context = DecCtx1},
            %% RFC 9113 §6.5.2: enforce our advertised MAX_HEADER_LIST_SIZE.
            case check_local_max_header_list_size(Headers, State1) of
                {error, _} ->
                    send_rst_stream(StreamId, protocol_error, State1),
                    State2 = case maps:is_key(StreamId, State1#state.streams) of
                        true -> close_stream(StreamId, rst, State1);
                        false -> State1
                    end,
                    {ok, connected, State2};
                ok ->
                    decode_and_process_headers_validated(Mode, StreamId, Headers, EndStream, State1)
            end;
        {error, _Reason} ->
            %% Reason can echo attacker-supplied header bytes; keep the log
            %% line bounded and tagged. Use modern OTP logger; error_logger
            %% is deprecated.
            logger:error("h2: HPACK decode error", #{}),
            {error, compression_error, State}
    end.

decode_and_process_headers_validated(Mode, StreamId, Headers, EndStream, State1) ->
            %% Determine role of this HEADERS block:
            %%   initial  — first HEADERS on the stream (request or response).
            %%   interim  — 1xx response (client only), more HEADERS to follow.
            %%   trailers — after initial request body or after final response.
            Kind = classify_headers(Mode, StreamId, Headers, State1),
            IsTunnel = case maps:find(StreamId, State1#state.streams) of
                {ok, #stream{tunnel = T}} -> T;
                _ -> false
            end,
            Validation = case {Kind, IsTunnel} of
                {trailers, true} -> {error, protocol_error};  %% §8.3
                {trailers, false} -> validate_trailers(Headers, EndStream);
                {_, _} -> validate_initial_headers(Mode, Headers)
            end,
            case Validation of
                ok ->
                    decode_and_process_headers_cont(Kind, StreamId, Headers, EndStream, State1);
                {error, ValidErr} ->
                    send_rst_stream(StreamId, ValidErr, State1),
                    State2 = case maps:is_key(StreamId, State1#state.streams) of
                        true -> close_stream(StreamId, rst, State1);
                        false -> State1
                    end,
                    {ok, connected, State2}
            end.

classify_headers(server, StreamId, _Headers, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{request_method = undefined}} -> initial;
        error -> initial;
        {ok, _} -> trailers
    end;
classify_headers(client, StreamId, Headers, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{response_seen_final = true}} -> trailers;
        {ok, _} ->
            case parse_status(Headers) of
                {ok, S} when S >= 100, S =< 199 -> interim;
                _ -> initial
            end;
        error -> initial
    end.

decode_and_process_headers_cont(Kind, StreamId, Headers, EndStream, #state{mode = Mode} = State) ->
    Stream = get_or_create_stream(StreamId, State),
    dispatch_headers(Mode, Kind, StreamId, Stream, Headers, EndStream, State).

%% Server receives the initial request HEADERS on a new stream.
dispatch_headers(server, initial, StreamId, Stream, Headers, EndStream, State) ->
    Protocol = proplists:get_value(<<":protocol">>, Headers),
    case extended_connect_allowed(Protocol, State) of
        false -> stream_reject(StreamId, protocol_error, State);
        true  -> handle_server_initial(StreamId, Stream, Headers, Protocol, EndStream, State)
    end;

%% Server receives trailing HEADERS closing a request body.
dispatch_headers(server, trailers, StreamId, _Stream, _Headers, false, State) ->
    %% RFC 9113 §8.1: trailers MUST carry END_STREAM.
    stream_reject(StreamId, protocol_error, State);
dispatch_headers(server, trailers, StreamId, Stream, Headers, true, State) ->
    deliver_trailers(StreamId, Stream, Headers, State);

%% Client receives a 1xx informational response. Stream stays open.
%% RFC 9113 §8.1 / RFC 9110 §15.2: interim responses MUST NOT carry END_STREAM
%% and MUST NOT carry content (Content-Length is meaningless).
dispatch_headers(client, interim, StreamId, _Stream, _Headers, true, State) ->
    stream_reject_and_close(StreamId, protocol_error, State);
dispatch_headers(client, interim, StreamId, _Stream, Headers, false, State) ->
    case proplists:is_defined(<<"content-length">>, Headers) of
        true ->
            stream_reject_and_close(StreamId, protocol_error, State);
        false ->
            {ok, Status} = parse_status(Headers),
            State1 = dispatch_stream_event(StreamId,
                        {informational, StreamId, Status, strip_pseudo(Headers)}, State),
            {ok, connected, State1}
    end;

%% Client receives the final response HEADERS.
dispatch_headers(client, initial, StreamId, Stream, Headers, EndStream, State) ->
    case parse_status(Headers) of
        malformed    -> stream_reject_and_close(StreamId, protocol_error, State);
        {ok, Status} -> handle_client_initial(StreamId, Stream, Headers, Status, EndStream, State)
    end;

%% Client receives trailing HEADERS closing a response body.
dispatch_headers(client, trailers, StreamId, Stream, Headers, _EndStream, State) ->
    deliver_trailers(StreamId, Stream, Headers, State).

%% ---- Initial-HEADERS handlers ------------------------------------------------

handle_server_initial(StreamId, Stream, Headers, Protocol, EndStream, State) ->
    case parse_content_length(Headers) of
        {error, Err} ->
            stream_reject(StreamId, Err, State);
        {ok, ExpectedCL} ->
            case end_stream_body_mismatch(ExpectedCL, EndStream) of
                true ->
                    %% RFC 9113 §8.1: END_STREAM + CL>0 is malformed.
                    stream_reject(StreamId, protocol_error, State);
                false ->
                    commit_server_initial(StreamId, Stream, Headers, Protocol,
                                          ExpectedCL, EndStream, State)
            end
    end.

commit_server_initial(StreamId, Stream, Headers, Protocol, ExpectedCL, EndStream, State) ->
    {Method, Path, OtherHeaders} = extract_request_headers(Headers),
    %% RFC 7540 §8.3: a CONNECT stream becomes a tunnel only once the 2xx
    %% response is sent. Keep tunnel=false here; handle_send_response flips it.
    Stream1 = Stream#stream{
        state = stream_state_after_end(EndStream),
        request_headers = Headers,
        request_method = Method,
        tunnel = false,
        protocol = Protocol,
        expected_body_length = ExpectedCL,
        body_forbidden = Method =:= <<"HEAD">>
    },
    State1 = put_stream(StreamId, Stream1, State),
    State2 = State1#state{last_peer_stream_id =
                            max(StreamId, State1#state.last_peer_stream_id)},
    notify_owner({h2, self(), {request, StreamId, Method, Path, OtherHeaders}}, State2),
    %% END_STREAM on the request HEADERS means the request has no body. Emit
    %% the trailing empty DATA event (buffered until a stream handler
    %% registers) so handlers waiting on end-of-stream don't hang. Mirrors
    %% finalize_client_initial and quic_h3.
    case EndStream of
        true ->
            State3 = dispatch_stream_event(StreamId, {data, StreamId, <<>>, true}, State2),
            {ok, connected, State3};
        false ->
            {ok, connected, State2}
    end.

handle_client_initial(StreamId, Stream, Headers, Status, EndStream, State) ->
    case parse_content_length(Headers) of
        {error, Err} ->
            stream_reject(StreamId, Err, State);
        {ok, ExpectedCL} ->
            BodyForbidden = Stream#stream.request_method =:= <<"HEAD">>
                            orelse Status =:= 204 orelse Status =:= 304,
            %% RFC 7540 §8.3: stream becomes a tunnel only on a 2xx response
            %% to a CONNECT request.
            IsTunnel = Stream#stream.request_method =:= <<"CONNECT">>
                       andalso Status >= 200 andalso Status < 300,
            Stream1 = Stream#stream{
                %% Apply the remote END_STREAM (or its absence) to the stream's
                %% *current* state. A client stream is already half_closed_local
                %% after sending its request; response HEADERS without END_STREAM
                %% must not reset it to `open` (that would leave the stream stuck
                %% in half_closed_remote after the final DATA, never reaching
                %% closed). Mirrors handle_data_frame's transition.
                state = apply_remote_end(Stream#stream.state, EndStream),
                response_headers = Headers,
                response_seen_final = true,
                tunnel = IsTunnel,
                expected_body_length = ExpectedCL,
                body_forbidden = BodyForbidden
            },
            State1 = put_stream(StreamId, Stream1, State),
            State2 = dispatch_stream_event(StreamId,
                        {response, StreamId, Status, strip_pseudo(Headers)}, State1),
            finalize_client_initial(StreamId, EndStream, ExpectedCL, BodyForbidden, State2)
    end.

%% RFC 9110 §9.3.2 / §15.4: HEAD, 204, 304 responses have no body — any
%% DATA frames after the header block are a protocol violation. If
%% END_STREAM is absent on the header block, the response is malformed
%% and the stream must not be left open for later frames.
finalize_client_initial(StreamId, false, _ExpectedCL, true, State) ->
    State1 = dispatch_stream_event(StreamId, {stream_reset, StreamId, protocol_error}, State),
    stream_reject_and_close(StreamId, protocol_error, State1);
%% Body-less response with END_STREAM — the response is complete. A
%% non-zero content-length on HEAD is allowed (RFC 9110 §9.3.2, it
%% indicates what the GET response size would be) — do not reject it.
finalize_client_initial(StreamId, true, _ExpectedCL, true, State) ->
    State1 = dispatch_stream_event(StreamId, {data, StreamId, <<>>, true}, State),
    {ok, connected, close_stream(StreamId, end_stream, State1)};
%% Body-allowed response: body continues arriving as DATA frames.
finalize_client_initial(_StreamId, false, _ExpectedCL, false, State) ->
    {ok, connected, State};
%% Body-allowed response with END_STREAM and a declared content-length > 0
%% is malformed: the body can't be both empty and non-empty.
finalize_client_initial(StreamId, true, ExpectedCL, false, State)
  when ExpectedCL =/= undefined, ExpectedCL > 0 ->
    stream_reject_and_close(StreamId, protocol_error, State);
%% Body-allowed response with END_STREAM and either no content-length or
%% content-length=0: emit the trailing empty DATA event so owners waiting
%% on end-of-stream don't hang. Matches quic_h3.
finalize_client_initial(StreamId, true, _ExpectedCL, false, State) ->
    State1 = dispatch_stream_event(StreamId, {data, StreamId, <<>>, true}, State),
    {ok, connected, close_stream(StreamId, end_stream, State1)}.

%% ---- Shared helpers ---------------------------------------------------------

%% RFC 9113 §5.1: trailers carry END_STREAM from the peer. That half-closes
%% the peer's side — the new state depends on whether we've already sent
%% END_STREAM ourselves:
%%   open              → half_closed_remote
%%   half_closed_local → closed
%% Closing prematurely (as we used to) makes the owner's reply on a still-
%% open server stream fail with invalid_stream_state.
deliver_trailers(StreamId, #stream{state = StreamState} = Stream, Headers, State) ->
    NewState = case StreamState of
        open              -> half_closed_remote;
        half_closed_local -> closed;
        _                 -> closed
    end,
    Stream1 = Stream#stream{state = NewState},
    State1  = put_stream(StreamId, Stream1, State),
    State2  = dispatch_stream_event(StreamId, {trailers, StreamId, Headers}, State1),
    case NewState of
        closed -> {ok, connected, close_stream(StreamId, end_stream, State2)};
        _      -> {ok, connected, State2}
    end.

%% RFC 8441 §4: a server that has not advertised SETTINGS_ENABLE_CONNECT_PROTOCOL=1
%% MUST treat a request carrying `:protocol` as malformed.
extended_connect_allowed(undefined, _State) -> true;
extended_connect_allowed(_Proto, #state{enable_connect_protocol = Flag}) -> Flag.

end_stream_body_mismatch(undefined, _EndStream) -> false;
end_stream_body_mismatch(CL, true) when CL > 0  -> true;
end_stream_body_mismatch(_, _)                  -> false.

stream_state_after_end(true)  -> half_closed_remote;
stream_state_after_end(false) -> open.

%% Transition a stream on a received END_STREAM (or its absence), preserving any
%% prior local half-close. Same rule as handle_data_frame's end-of-stream block.
apply_remote_end(StreamState, false) -> StreamState;
apply_remote_end(open, true)              -> half_closed_remote;
apply_remote_end(half_closed_local, true) -> closed;
apply_remote_end(Other, true)             -> Other.

strip_pseudo(Headers) ->
    lists:filter(fun({N, _}) -> not is_pseudo_header(N) end, Headers).

stream_reject(StreamId, ErrorCode, State) ->
    send_rst_stream(StreamId, ErrorCode, State),
    {ok, connected, State}.

stream_reject_and_close(StreamId, ErrorCode, State) ->
    send_rst_stream(StreamId, ErrorCode, State),
    {ok, connected, close_stream(StreamId, rst, State)}.

%% RFC 9113 §8.1.1: Content-Length parser. Multiple headers with the same
%% value collapse into one; mismatched values are malformed. Non-numeric or
%% negative values are malformed.
parse_content_length(Headers) ->
    Values = [V || {<<"content-length">>, V} <- Headers],
    case lists:usort(Values) of
        [] ->
            {ok, undefined};
        [Single] ->
            case parse_nonneg_integer(Single) of
                {ok, N} -> {ok, N};
                error -> {error, protocol_error}
            end;
        _ ->
            {error, protocol_error}
    end.

parse_nonneg_integer(Bin) ->
    try binary_to_integer(Bin) of
        N when N >= 0 -> {ok, N};
        _ -> error
    catch
        _:_ -> error
    end.

%% Validate an initial request/response HEADERS block per RFC 7540 §8.1.2.
%% Checks: pseudo-header order/set/duplicates, lowercase header names,
%% connection-specific headers, TE header restriction, :path syntax
%% (requests), :authority vs Host consistency (requests).
validate_initial_headers(Mode, Headers) ->
    Checks = [
        fun() -> check_pseudo_order(Headers) end,
        fun() -> check_pseudo_set(Mode, Headers) end,
        fun() -> check_lowercase_names(Headers) end,
        fun() -> check_connection_headers(Headers) end,
        fun() -> check_request_specific(Mode, Headers) end
    ],
    run_checks(Checks).

%% Validate a trailing HEADERS block per RFC 7540 §8.1:
%% MUST have END_STREAM and MUST NOT contain any pseudo-header.
validate_trailers(Headers, true) ->
    Checks = [
        fun() -> check_no_pseudo_in_trailers(Headers) end,
        fun() -> check_lowercase_names(Headers) end,
        fun() -> check_connection_headers(Headers) end
    ],
    run_checks(Checks);
validate_trailers(_Headers, false) ->
    {error, protocol_error}.

run_checks([]) -> ok;
run_checks([F | Rest]) ->
    case F() of
        ok -> run_checks(Rest);
        Err -> Err
    end.

check_no_pseudo_in_trailers(Headers) ->
    case [N || {<<$:, _/binary>> = N, _} <- Headers] of
        [] -> ok;
        _ -> {error, protocol_error}
    end.

%% RFC 9113 §8.2: field names are lowercase RFC 7230 tchar (pseudo-headers
%% start with ':'); values must not contain NUL/CR/LF nor have leading or
%% trailing SP/HTAB.
check_lowercase_names(Headers) ->
    Bad = lists:any(fun bad_field/1, Headers),
    case Bad of
        true -> {error, protocol_error};
        false -> ok
    end.

bad_field({<<>>, _}) -> true;
bad_field({<<$:, Rest/binary>>, Value}) ->
    %% Pseudo-header: rest must be lowercase tchar too.
    not valid_name_bytes(Rest) orelse bad_value(Value);
bad_field({Name, Value}) ->
    not valid_name_bytes(Name) orelse bad_value(Value).

%% Allowed bytes in a header field name: lowercase ALPHA, DIGIT, and
%%   !#$%&'*+-.^_`|~
valid_name_bytes(<<>>) -> true;
valid_name_bytes(<<C, Rest/binary>>) ->
    Ok = (C >= $a andalso C =< $z)
         orelse (C >= $0 andalso C =< $9)
         orelse lists:member(C, "!#$%&'*+-.^_`|~"),
    Ok andalso valid_name_bytes(Rest).

%% RFC 7230 §3.2.6 `token` — same alphabet as a header field name but
%% case-insensitive (uppercase also allowed). Used for RFC 8441 `:protocol`.
valid_token(<<>>)       -> false;
valid_token(Bin) when is_binary(Bin) -> valid_token_bytes(Bin);
valid_token(_)          -> false.

valid_token_bytes(<<>>) -> true;
valid_token_bytes(<<C, Rest/binary>>) ->
    Ok = (C >= $a andalso C =< $z)
         orelse (C >= $A andalso C =< $Z)
         orelse (C >= $0 andalso C =< $9)
         orelse lists:member(C, "!#$%&'*+-.^_`|~"),
    Ok andalso valid_token_bytes(Rest).

%% A value is bad if empty-after-trimming is fine, but leading/trailing SP/HTAB
%% or any NUL/CR/LF byte is forbidden.
bad_value(<<>>) -> false;
bad_value(<<C, _/binary>>) when C =:= $\s; C =:= $\t -> true;
bad_value(Bin) ->
    Last = binary:last(Bin),
    case Last of
        $\s -> true;
        $\t -> true;
        _ -> has_bad_value_byte(Bin)
    end.

has_bad_value_byte(<<>>) -> false;
has_bad_value_byte(<<0, _/binary>>) -> true;
has_bad_value_byte(<<$\n, _/binary>>) -> true;
has_bad_value_byte(<<$\r, _/binary>>) -> true;
has_bad_value_byte(<<_, Rest/binary>>) -> has_bad_value_byte(Rest).

%% RFC 7540 §8.1.2.2: reject connection-specific headers; TE only allowed with
%% the exact value "trailers".
check_connection_headers(Headers) ->
    Banned = [<<"connection">>, <<"proxy-connection">>, <<"keep-alive">>,
              <<"transfer-encoding">>, <<"upgrade">>, <<"host">>],
    %% We only ban Host as duplicate-check target, not here — Host handled in check_authority_host.
    BannedStrict = Banned -- [<<"host">>],
    Bad = lists:any(
        fun({Name, _}) -> lists:member(Name, BannedStrict) end, Headers),
    case Bad of
        true -> {error, protocol_error};
        false -> check_te_header(Headers)
    end.

check_te_header(Headers) ->
    case [V || {<<"te">>, V} <- Headers] of
        [] -> ok;
        [<<"trailers">>] -> ok;
        _ -> {error, protocol_error}
    end.

check_request_specific(server, Headers) ->
    Method = proplists:get_value(<<":method">>, Headers),
    case Method of
        undefined -> ok;  %% already caught in check_pseudo_set
        <<"CONNECT">> ->
            %% CONNECT has no :path/:scheme but :authority (no userinfo) still applies.
            check_authority_host(Headers);
        _ ->
            case check_path(Headers) of
                ok -> check_authority_host(Headers);
                Err -> Err
            end
    end;
check_request_specific(client, _Headers) ->
    ok.

check_path(Headers) ->
    case proplists:get_value(<<":path">>, Headers) of
        undefined -> ok;  %% already caught
        <<>> -> {error, protocol_error};
        Path ->
            case proplists:get_value(<<":scheme">>, Headers) of
                undefined -> ok;
                Scheme when Scheme =:= <<"http">>; Scheme =:= <<"https">> ->
                    Method = proplists:get_value(<<":method">>, Headers),
                    case {binary_part(Path, 0, 1), Method, Path} of
                        {<<"/">>, _, _} -> ok;
                        {<<"*">>, <<"OPTIONS">>, <<"*">>} -> ok;
                        _ -> {error, protocol_error}
                    end;
                _ -> ok
            end
    end.

check_authority_host(Headers) ->
    case proplists:get_value(<<":authority">>, Headers) of
        undefined -> ok;
        Authority ->
            %% RFC 9113 §8.3.1: `:authority` MUST NOT include the deprecated
            %% userinfo subcomponent for http/https schemes.
            case binary:match(Authority, <<"@">>) of
                nomatch -> check_host_consistency(Authority, Headers);
                _       -> {error, protocol_error}
            end
    end.

check_host_consistency(Authority, Headers) ->
    case proplists:get_value(<<"host">>, Headers) of
        undefined -> ok;
        Host ->
            case string:equal(Authority, Host, true) of
                true  -> ok;
                false -> {error, protocol_error}
            end
    end.

check_pseudo_order(Headers) ->
    check_pseudo_order(Headers, pseudo).

check_pseudo_order([], _) -> ok;
check_pseudo_order([{<<$:, _/binary>>, _} | Rest], pseudo) ->
    check_pseudo_order(Rest, pseudo);
check_pseudo_order([{<<$:, _/binary>>, _} | _], regular) ->
    {error, protocol_error};
check_pseudo_order([{_, _} | Rest], _) ->
    check_pseudo_order(Rest, regular).

check_pseudo_set(server, Headers) ->
    Pseudos = [N || {<<$:, _/binary>> = N, _} <- Headers],
    Uniq = lists:usort(Pseudos),
    case length(Pseudos) =:= length(Uniq) of
        false -> {error, protocol_error};
        true ->
            %% RFC 8441 §4: `:protocol` is allowed only with method CONNECT.
            Allowed = [<<":method">>, <<":scheme">>, <<":path">>, <<":authority">>,
                       <<":protocol">>],
            case [N || N <- Pseudos, not lists:member(N, Allowed)] of
                [] ->
                    Method = proplists:get_value(<<":method">>, Headers),
                    Protocol = proplists:get_value(<<":protocol">>, Headers),
                    case {Method, Protocol} of
                        {undefined, _} -> {error, protocol_error};
                        {_, undefined} when Method =:= <<"CONNECT">> ->
                            %% Vanilla CONNECT (RFC 7540 §8.3): `:authority`
                            %% required, `:scheme`/`:path` MUST be omitted.
                            HasScheme = proplists:is_defined(<<":scheme">>, Headers),
                            HasPath   = proplists:is_defined(<<":path">>, Headers),
                            case {proplists:get_value(<<":authority">>, Headers),
                                  HasScheme, HasPath} of
                                {undefined, _, _} -> {error, protocol_error};
                                {_, true, _} -> {error, protocol_error};
                                {_, _, true} -> {error, protocol_error};
                                _ -> ok
                            end;
                        {<<"CONNECT">>, _} ->
                            %% Extended CONNECT (RFC 8441 §4): `:method=CONNECT`
                            %% plus `:protocol` (RFC 7230 token), `:scheme`,
                            %% `:path`, `:authority` all REQUIRED.
                            case valid_token(Protocol) of
                                false -> {error, protocol_error};
                                true ->
                            case {proplists:get_value(<<":scheme">>, Headers),
                                  proplists:get_value(<<":path">>, Headers),
                                  proplists:get_value(<<":authority">>, Headers)} of
                                {undefined, _, _} -> {error, protocol_error};
                                {_, undefined, _} -> {error, protocol_error};
                                {_, <<>>, _} -> {error, protocol_error};
                                {_, _, undefined} -> {error, protocol_error};
                                _ -> ok
                            end
                            end;
                        {_, P} when P =/= undefined ->
                            %% `:protocol` without method CONNECT is malformed.
                            {error, protocol_error};
                        _ ->
                            case {proplists:get_value(<<":scheme">>, Headers),
                                  proplists:get_value(<<":path">>, Headers)} of
                                {undefined, _} -> {error, protocol_error};
                                {_, undefined} -> {error, protocol_error};
                                {_, <<>>} -> {error, protocol_error};
                                _ -> ok
                            end
                    end;
                _Unknown ->
                    {error, protocol_error}
            end
    end;
check_pseudo_set(client, Headers) ->
    Pseudos = [N || {<<$:, _/binary>> = N, _} <- Headers],
    Uniq = lists:usort(Pseudos),
    case length(Pseudos) =:= length(Uniq) of
        false -> {error, protocol_error};
        true ->
            case [N || N <- Pseudos, N =/= <<":status">>] of
                [] ->
                    case proplists:get_value(<<":status">>, Headers) of
                        undefined -> {error, protocol_error};
                        _ -> ok
                    end;
                _Unknown ->
                    {error, protocol_error}
            end
    end.

extract_request_headers(Headers) ->
    Method = proplists:get_value(<<":method">>, Headers, <<"GET">>),
    Path = proplists:get_value(<<":path">>, Headers, <<"/">>),
    %% Strip pseudo-headers from the user-visible list, except `:protocol`
    %% (RFC 8441), `:authority` and `:scheme`. Adapters need these to
    %% reconstruct the request authority/scheme for virtual hosting and
    %% reverse-proxy use; a compliant client may send `:authority` without a
    %% `host` header, so it is not always recoverable otherwise. Consumers
    %% that forward or reflect the header list MUST strip these pseudo-headers
    %% first. `:method` and `:path` are already exposed as separate fields.
    OtherHeaders = lists:filter(
        fun({<<":protocol">>, _}) -> true;
           ({<<":authority">>, _}) -> true;
           ({<<":scheme">>, _})    -> true;
           ({Name, _})             -> not is_pseudo_header(Name)
        end, Headers),
    {Method, Path, OtherHeaders}.

%% RFC 9113 §8.3.2: :status MUST be present on a response HEADERS, exactly
%% three ASCII digits in the range 100..599. Anything else is a malformed
%% response and must trigger a stream PROTOCOL_ERROR.
parse_status(Headers) ->
    case proplists:get_value(<<":status">>, Headers) of
        %% RFC 9113 §8.6: HTTP/2 MUST NOT accept 101 Switching Protocols.
        <<"101">> -> malformed;
        <<D1, D2, D3>> when D1 >= $1, D1 =< $5, D2 >= $0, D2 =< $9, D3 >= $0, D3 =< $9 ->
            {ok, (D1 - $0) * 100 + (D2 - $0) * 10 + (D3 - $0)};
        _ ->
            malformed
    end.

%% RFC 9113 §6.5.2 / RFC 7541 §4.1: per-header overhead is 32 bytes plus the
%% name and value octets. Returns the advisory "header list size" sum.
header_list_size(Headers) ->
    lists:foldl(fun({N, V}, Acc) ->
        Acc + 32 + byte_size(N) + byte_size(V)
    end, 0, Headers).

%% Enforce peer-advertised SETTINGS_MAX_HEADER_LIST_SIZE before encoding.
check_peer_max_header_list_size(Headers, #state{peer_settings = PS}) ->
    case h2_settings:get(max_header_list_size, PS) of
        unlimited -> ok;
        Max when is_integer(Max) ->
            case header_list_size(Headers) > Max of
                true  -> {error, header_list_too_large};
                false -> ok
            end
    end.

%% Enforce our SETTINGS_MAX_HEADER_LIST_SIZE on received decoded headers.
check_local_max_header_list_size(Headers, #state{local_settings = LS}) ->
    case h2_settings:get(max_header_list_size, LS) of
        unlimited -> ok;
        Max when is_integer(Max) ->
            case header_list_size(Headers) > Max of
                true  -> {error, protocol_error};
                false -> ok
            end
    end.

%% RFC 9113 §8.1.1, §8.2: validate every outbound header block.
%% The existing Mode parameter of validate_initial_headers refers to the
%% *receiver*'s role (server validates requests, client validates responses),
%% so for outbound validation we flip: sending a request → server rules,
%% sending a response → client rules.
validate_outbound_request(Headers) ->
    validate_initial_headers(server, Headers).

validate_outbound_response(Headers) ->
    %% Status 101 already rejected before calling.
    validate_initial_headers(client, Headers).

is_pseudo_header(<<$:, _/binary>>) -> true;
is_pseudo_header(_) -> false.

%% ============================================================================
%% Internal: Data Frame Handling
%% ============================================================================

%% RFC 9113 §6.1: the receiver MUST count the full DATA payload (including
%% the pad length byte and any padding) against the connection-level flow
%% control window — *regardless* of stream state. Failing to consume post-
%% reset DATA desynchronizes the peer's accounting and lets it overshoot the
%% advertised receive window.
handle_data_frame(StreamId, Data, EndStream, FlowControlled,
                  #state{streams = Streams, recv_conn_window_size = ConnWindow} = State) ->
    if
        FlowControlled > ConnWindow ->
            %% Peer violated our advertised connection window.
            {error, flow_control_error, State};
        true ->
            State0 = State#state{recv_conn_window_size = ConnWindow - FlowControlled},
            State0a = maybe_send_conn_window_update(FlowControlled, State0),
            case maps:find(StreamId, Streams) of
                {ok, #stream{state = StreamState, recv_window_size = StreamWindow,
                             body_forbidden = BodyForbidden,
                             expected_body_length = ExpectedCL,
                             received_body_length = ReceivedSoFar,
                             tunnel = IsTunnel} = Stream} when StreamState == open; StreamState == half_closed_local ->
                    DataSize = byte_size(Data),
                    %% §8.1.1 body enforcement (not applicable to tunnels).
                    BodyViolation =
                        (not IsTunnel) andalso
                        ((BodyForbidden andalso DataSize > 0)
                         orelse (ExpectedCL =/= undefined andalso ReceivedSoFar + DataSize > ExpectedCL)
                         orelse (EndStream andalso ExpectedCL =/= undefined
                                 andalso ReceivedSoFar + DataSize =/= ExpectedCL)),
                    if
                        FlowControlled > StreamWindow ->
                            send_rst_stream(StreamId, flow_control_error, State0a),
                            State1 = close_stream(StreamId, rst, State0a),
                            {ok, connected, State1};
                        BodyViolation ->
                            send_rst_stream(StreamId, protocol_error, State0a),
                            State1 = close_stream(StreamId, rst, State0a),
                            {ok, connected, State1};
                        true ->
                            NewStreamWindow = StreamWindow - FlowControlled,
                            Stream1 = Stream#stream{
                                recv_window_size = NewStreamWindow,
                                received_body_length = ReceivedSoFar + DataSize
                            },

                            Stream2 = case EndStream of
                                true ->
                                    case StreamState of
                                        open -> Stream1#stream{state = half_closed_remote};
                                        half_closed_local -> Stream1#stream{state = closed}
                                    end;
                                false ->
                                    Stream1
                            end,

                            {Stream3, State1} = dispatch_data(StreamId, Stream2, Data, EndStream, State0a),
                            State2 = put_stream(StreamId, Stream3, State1),

                            State3 = maybe_send_window_update(StreamId, FlowControlled, State2),

                            case EndStream andalso Stream2#stream.state == closed of
                                true ->
                                    State4 = close_stream(StreamId, end_stream, State3),
                                    {ok, connected, State4};
                                false ->
                                    {ok, connected, State3}
                            end
                    end;
                {ok, #stream{state = closed, closed_reason = end_stream}} ->
                    %% RFC 9113 §5.1: DATA on a stream closed via END_STREAM
                    %% is a CONNECTION error STREAM_CLOSED.
                    {error, stream_closed, State0a};
                {ok, #stream{state = closed, closed_reason = rst}} ->
                    %% RFC 9113 §5.1: after RST_STREAM, further DATA is a
                    %% stream error STREAM_CLOSED.
                    send_rst_stream(StreamId, stream_closed, State0a),
                    {ok, connected, State0a};
                {ok, _} ->
                    %% half_closed_remote etc.: stream-scoped STREAM_CLOSED.
                    send_rst_stream(StreamId, stream_closed, State0a),
                    {ok, connected, State0a};
                error ->
                    case recently_closed_reason(StreamId, State0a) of
                        end_stream ->
                            %% Exact: peer END_STREAM then more DATA → conn error.
                            {error, stream_closed, State0a};
                        rst ->
                            send_rst_stream(StreamId, stream_closed, State0a),
                            {ok, connected, State0a};
                        unknown ->
                            case in_closed_stream_range(StreamId, State0a) of
                                true ->
                                    send_rst_stream(StreamId, stream_closed, State0a),
                                    {ok, connected, State0a};
                                false ->
                                    {error, protocol_error, State0a}
                            end
                    end
            end
    end.

%% Exact lookup for recently-closed streams. Returns `unknown` for ids
%% beyond the closed_reasons retention window; callers fall back to
%% `in_closed_stream_range/2`.
recently_closed_reason(StreamId, #state{closed_reasons = Reasons}) ->
    maps:get(StreamId, Reasons, unknown).

%% Fallback heuristic for stream ids evicted from the closed-streams FIFO.
%% Treats both peer-initiated ids (up to last_peer_stream_id) and our own
%% ids (strictly below next_stream_id) as "was opened at some point" —
%% symmetric for client and server modes.
%% RFC 9113 §10.5: per-connection flood counters. Bucket-per-second; when
%% the count within the current second exceeds the limit, the caller emits
%% GOAWAY(ENHANCE_YOUR_CALM).
bump_flood_counter(Kind, State) ->
    Now = erlang:monotonic_time(second),
    {Bucket, Count} = case Kind of
        ping -> State#state.ping_flood;
        rst  -> State#state.rst_flood
    end,
    {NewBucket, NewCount} = case Bucket =:= Now of
        true  -> {Bucket, Count + 1};
        false -> {Now, 1}
    end,
    Limit = case Kind of
        ping -> ?PING_FLOOD_LIMIT_PER_SEC;
        rst  -> ?RST_FLOOD_LIMIT_PER_SEC
    end,
    case NewCount > Limit of
        true  -> flood;
        false ->
            State1 = case Kind of
                ping -> State#state{ping_flood = {NewBucket, NewCount}};
                rst  -> State#state{rst_flood  = {NewBucket, NewCount}}
            end,
            {ok, State1}
    end.

in_closed_stream_range(StreamId, #state{mode = Mode, last_peer_stream_id = LastPeer,
                                         next_stream_id = NextLocal}) ->
    {PeerParity, LocalParity} = case Mode of
        client -> {0, 1};  %% peer (server) = even; we = odd
        server -> {1, 0}   %% peer (client) = odd;  we = even
    end,
    (StreamId rem 2 =:= PeerParity andalso StreamId =< LastPeer)
    orelse (StreamId rem 2 =:= LocalParity andalso StreamId < NextLocal).

%% Connection-level WINDOW_UPDATE refill. Called for every DATA frame,
%% including those on closed/unknown streams — per RFC 9113 §5.1 the
%% connection window is consumed regardless of stream state. The refill
%% target is the connection_window_size option (65535 by default), not
%% SETTINGS_INITIAL_WINDOW_SIZE, which only adjusts stream windows
%% (RFC 9113 §6.9.2).
maybe_send_conn_window_update(_DataSize, #state{recv_conn_window_size = ConnWindow,
                                                recv_conn_window_target = Target} = State) ->
    Threshold = Target div 2,
    case ConnWindow < Threshold of
        true ->
            ConnIncrement = Target - ConnWindow,
            %% Best-effort: a dead socket will surface via {tcp_closed,_} /
            %% {ssl_closed,_} momentarily and terminate the connection.
            _ = send_frame(h2_frame:window_update(0, ConnIncrement), State),
            State#state{recv_conn_window_size = ConnWindow + ConnIncrement};
        false ->
            State
    end.

maybe_send_window_update(StreamId, DataSize, #state{local_settings = Settings,
                                                     streams = Streams} = State) ->
    InitialWindow = h2_settings:get(initial_window_size, Settings),
    Threshold = InitialWindow div 2,
    case maps:find(StreamId, Streams) of
        %% Manual flow control (RFC 9113 §6.9): do NOT auto-replenish. Track the
        %% bytes as unacked so consume/3 can replenish them on consumer progress.
        %% This is what bounds a slow consumer's in-flight data to one window.
        {ok, #stream{flow_control = manual, unacked = Unacked} = Stream} ->
            Stream1 = Stream#stream{unacked = Unacked + DataSize},
            State#state{streams = maps:put(StreamId, Stream1, Streams)};
        {ok, #stream{recv_window_size = StreamWindow} = Stream} when StreamWindow < Threshold ->
            StreamIncrement = InitialWindow - StreamWindow,
            %% Best-effort: dead socket surfaces via {tcp_closed,_} / {ssl_closed,_}.
            _ = send_frame(h2_frame:window_update(StreamId, StreamIncrement), State),
            Stream1 = Stream#stream{recv_window_size = StreamWindow + StreamIncrement},
            State#state{streams = maps:put(StreamId, Stream1, Streams)};
        _ ->
            State
    end.

%% Handle an explicit consume/3 call: replenish the stream receive window by up
%% to the unacked byte count via WINDOW_UPDATE. No-op (but still `ok') for auto
%% streams — auto windows are managed by maybe_send_window_update/3.
handle_consume(From, StreamId, ByteCount, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{flow_control = manual, recv_window_size = StreamWindow,
                     unacked = Unacked} = Stream} ->
            Ack = min(ByteCount, Unacked),
            case Ack > 0 of
                true ->
                    _ = send_frame(h2_frame:window_update(StreamId, Ack), State),
                    Stream1 = Stream#stream{recv_window_size = StreamWindow + Ack,
                                            unacked = Unacked - Ack},
                    State1 = State#state{streams = maps:put(StreamId, Stream1, Streams)},
                    {keep_state, State1, [{reply, From, ok}]};
                false ->
                    {keep_state, State, [{reply, From, ok}]}
            end;
        {ok, _} ->
            %% auto-mode stream: window already managed automatically.
            {keep_state, State, [{reply, From, ok}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

%% ============================================================================
%% Internal: Send Operations
%% ============================================================================

handle_send_request(From, Method, Path, Headers, EndStream, #state{mode = client, next_stream_id = StreamId,
                                                        peer_max_concurrent_streams = MaxStreams,
                                                        peer_initial_window_size = InitialWindow,
                                                        scheme = Scheme,
                                                        encode_context = EncCtx} = State) ->
    ActiveStreams = count_active_streams(State),

    case MaxStreams of
        N when is_integer(N), ActiveStreams >= N ->
            {keep_state, State, [{reply, From, {error, max_streams_exceeded}}]};
        _ ->
            IsConnect = Method =:= <<"CONNECT">>,
            Host = proplists:get_value(<<"host">>, Headers),
            %% RFC 7540 §8.3: CONNECT MUST omit :scheme/:path; :authority required.
            %% For non-CONNECT, RFC 9113 §8.3.1 makes :authority optional — omit
            %% it rather than injecting an empty string when host is missing.
            case {IsConnect, Host} of
                {true, undefined} ->
                    {keep_state, State, [{reply, From, {error, missing_authority}}]};
                _ ->
                    PseudoBase = [{<<":method">>, Method}],
                    Pseudo1 = case IsConnect of
                        true  -> PseudoBase;
                        false -> PseudoBase
                                 ++ [{<<":path">>, Path},
                                     {<<":scheme">>, Scheme}]
                    end,
                    Pseudo = case Host of
                        undefined -> Pseudo1;
                        _         -> Pseudo1 ++ [{<<":authority">>, Host}]
                    end,
                    AllHeaders = Pseudo
                                 ++ lists:filter(fun({N1, _}) -> N1 =/= <<"host">> end, Headers),

            case validate_outbound_request(AllHeaders) of
                {error, _} = Err ->
                    {keep_state, State, [{reply, From, Err}]};
                ok ->
                    case check_peer_max_header_list_size(AllHeaders, State) of
                        {error, _} = SErr ->
                            {keep_state, State, [{reply, From, SErr}]};
                        ok ->
                    {HeaderBlock, EncCtx1} = h2_hpack:encode(AllHeaders, EncCtx),

                    RecvWindow = h2_settings:get(initial_window_size, State#state.local_settings),
                    StreamState = case EndStream of
                        true -> half_closed_local;
                        false -> open
                    end,
                    %% RFC 7540 §8.3: tunnel is only established on the 2xx
                    %% response; do NOT pre-set tunnel=true here. The client-side
                    %% flip happens in handle_client_initial.
                    Stream = #stream{
                        id = StreamId,
                        state = StreamState,
                        window_size = InitialWindow,
                        recv_window_size = RecvWindow,
                        tunnel = false,
                        request_method = Method
                    },

                    case send_header_block(StreamId, HeaderBlock, EndStream, State) of
                        ok ->
                            State0 = put_stream(StreamId, Stream, State),
                            State1 = State0#state{
                                encode_context = EncCtx1,
                                next_stream_id = StreamId + 2
                            },
                            {keep_state, State1, [{reply, From, {ok, StreamId}}]};
                        {error, SendReason} ->
                            {stop_and_reply,
                             {shutdown, {send_failed, SendReason}},
                             [{reply, From, {error, SendReason}}],
                             State}
                    end
                    end
            end
            end
    end;

handle_send_request(From, _Method, _Path, _Headers, _EndStream, State) ->
    {keep_state, State, [{reply, From, {error, not_client}}]}.

handle_send_request_headers(From, Headers, EndStream, Opts,
                            #state{mode = client, next_stream_id = StreamId,
                                   peer_max_concurrent_streams = MaxStreams,
                                   peer_initial_window_size = InitialWindow,
                                   peer_settings = PeerSettings,
                                   encode_context = EncCtx} = State) ->
    ActiveStreams = count_active_streams(State),
    case MaxStreams of
        N when is_integer(N), ActiveStreams >= N ->
            {keep_state, State, [{reply, From, {error, max_streams_exceeded}}]};
        _ ->
            Method = proplists:get_value(<<":method">>, Headers),
            Protocol = proplists:get_value(<<":protocol">>, Headers),
            %% RFC 8441: client MUST NOT send Extended CONNECT until peer has
            %% advertised SETTINGS_ENABLE_CONNECT_PROTOCOL=1; method MUST be
            %% CONNECT when `:protocol` is present.
            ExtendedConnectGuard = case Protocol of
                undefined -> ok;
                _ when Method =/= <<"CONNECT">> ->
                    {error, extended_connect_method};
                _ ->
                    case h2_settings:get(enable_connect_protocol, PeerSettings) of
                        1 -> ok;
                        _ -> {error, extended_connect_disabled}
                    end
            end,
            case ExtendedConnectGuard of
                {error, _} = ECErr ->
                    {keep_state, State, [{reply, From, ECErr}]};
                ok ->
            case validate_outbound_request(Headers) of
                {error, _} = Err ->
                    {keep_state, State, [{reply, From, Err}]};
                ok ->
            case check_peer_max_header_list_size(Headers, State) of
                {error, _} = SErr ->
                    {keep_state, State, [{reply, From, SErr}]};
                ok ->
            {HeaderBlock, EncCtx1} = h2_hpack:encode(Headers, EncCtx),
            RecvWindow = h2_settings:get(initial_window_size, State#state.local_settings),
            StreamState = case EndStream of true -> half_closed_local; false -> open end,
            {Handler, DispatchMode, FlowControl} = stream_opts(Opts),
            %% RFC 7540 §8.3 / RFC 8441: tunnel only opens on the 2xx response.
            Stream = #stream{
                id = StreamId,
                state = StreamState,
                window_size = InitialWindow,
                recv_window_size = RecvWindow,
                tunnel = false,
                protocol = Protocol,
                request_method = Method,
                handler = Handler,
                dispatch_mode = DispatchMode,
                flow_control = FlowControl
            },
            case send_header_block(StreamId, HeaderBlock, EndStream, State) of
                ok ->
                    State0 = put_stream(StreamId, Stream, State),
                    State1 = State0#state{
                        encode_context = EncCtx1,
                        next_stream_id = StreamId + 2
                    },
                    {keep_state, State1, [{reply, From, {ok, StreamId}}]};
                {error, SendReason} ->
                    {stop_and_reply,
                     {shutdown, {send_failed, SendReason}},
                     [{reply, From, {error, SendReason}}],
                     State}
            end
            end
            end
            end
    end;
handle_send_request_headers(From, _Headers, _EndStream, _Opts, State) ->
    {keep_state, State, [{reply, From, {error, not_client}}]}.

%% Resolve per-stream creation options into {Handler, DispatchMode, FlowControl}.
%% `handler' takes priority (events route to the pid from creation, race-free);
%% `defer => true' buffers events for a later set_stream_handler; otherwise the
%% legacy owner-dispatch default applies.
stream_opts(Opts) ->
    Handler = case maps:get(handler, Opts, undefined) of
        P when is_pid(P) -> P;
        _                -> undefined
    end,
    DispatchMode = case {Handler, maps:get(defer, Opts, false)} of
        {H, _} when is_pid(H) -> owner;   %% handler set: mode is irrelevant
        {_, true}             -> buffer;
        _                     -> owner
    end,
    FlowControl = case maps:get(flow_control, Opts, auto) of
        manual -> manual;
        _      -> auto
    end,
    {Handler, DispatchMode, FlowControl}.

handle_send_response(From, StreamId, Status, Headers, #state{mode = server, streams = Streams,
                                                              encode_context = EncCtx} = State) ->
    case maps:find(StreamId, Streams) of
        _ when Status =:= 101 ->
            %% RFC 9113 §8.6: HTTP/2 MUST NOT generate 101 Switching Protocols.
            {keep_state, State, [{reply, From, {error, status_101_forbidden}}]};
        {ok, #stream{state = StreamState, request_method = ReqMethod} = Stream}
          when StreamState == open; StreamState == half_closed_remote ->
            %% RFC 7540 §8.3: a CONNECT 2xx response MUST NOT carry
            %% Content-Length or Transfer-Encoding; the stream becomes a
            %% tunnel only when the 2xx goes out, never before.
            IsConnectRequest = ReqMethod =:= <<"CONNECT">>,
            IsSuccess        = Status >= 200 andalso Status < 300,
            case IsConnectRequest andalso IsSuccess andalso
                 has_banned_tunnel_header(Headers) of
                true ->
                    {keep_state, State,
                     [{reply, From, {error, banned_header_in_tunnel_response}}]};
                false ->
                    StatusBin = integer_to_binary(Status),
                    AllHeaders = [{<<":status">>, StatusBin} | Headers],
                    case validate_outbound_response(AllHeaders) of
                        {error, _} = Err ->
                            {keep_state, State, [{reply, From, Err}]};
                        ok ->
                    case check_peer_max_header_list_size(AllHeaders, State) of
                        {error, _} = SErr ->
                            {keep_state, State, [{reply, From, SErr}]};
                        ok ->
                    {HeaderBlock, EncCtx1} = h2_hpack:encode(AllHeaders, EncCtx),
                    %% RFC 9110 §9.3.2 / §15.4: body-forbidden responses
                    %% (HEAD / 204 / 304) terminate at the header block —
                    %% end the stream here so later send_data is a no-op
                    %% on the wire and the peer's stream state matches ours.
                    BodyForbidden = ReqMethod =:= <<"HEAD">>
                                    orelse Status =:= 204 orelse Status =:= 304,
                    case send_header_block(StreamId, HeaderBlock, BodyForbidden, State) of
                        ok ->
                            NewTunnel = IsConnectRequest andalso IsSuccess,
                            NewState = case BodyForbidden of
                                true ->
                                    case StreamState of
                                        open -> half_closed_local;
                                        half_closed_remote -> closed
                                    end;
                                false ->
                                    StreamState
                            end,
                            Stream1 = Stream#stream{response_headers = AllHeaders,
                                                    tunnel = NewTunnel,
                                                    body_forbidden = BodyForbidden,
                                                    state = NewState},
                            State0 = put_stream(StreamId, Stream1, State),
                            State1 = State0#state{encode_context = EncCtx1},
                            State2 = case NewState of
                                closed -> close_stream(StreamId, end_stream, State1);
                                _      -> State1
                            end,
                            {keep_state, State2, [{reply, From, ok}]};
                        {error, SendReason} ->
                            {stop_and_reply,
                             {shutdown, {send_failed, SendReason}},
                             [{reply, From, {error, SendReason}}],
                             State}
                    end
                    end
                    end
            end;
        {ok, _} ->
            {keep_state, State, [{reply, From, {error, invalid_stream_state}}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end;

handle_send_response(From, _StreamId, _Status, _Headers, State) ->
    {keep_state, State, [{reply, From, {error, not_server}}]}.

%% Combined response: status + headers + full body in one gen_statem call and a
%% single socket write (HEADERS coalesced with the DATA frame). This halves the
%% per-request round-trips and syscalls versus send_response + send_data. The
%% fast path covers the common case; anything it does not cover replies
%% `need_fallback' and h2:respond/5 retries via the granular API. Validation
%% mirrors handle_send_response exactly.
handle_respond(From, StreamId, Status, Headers, Body,
               #state{mode = server, streams = Streams, encode_context = EncCtx,
                      conn_window_size = ConnWindow,
                      peer_max_frame_size = MaxFrameSize} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{state = St, request_method = ReqMethod,
                     window_size = StreamWindow} = Stream}
          when (St == open orelse St == half_closed_remote)
               andalso Status =/= 101
               andalso ReqMethod =/= <<"CONNECT">> ->
            AllHeaders = [{<<":status">>, integer_to_binary(Status)} | Headers],
            case validate_outbound_response(AllHeaders) of
                {error, _} = Err ->
                    {keep_state, State, [{reply, From, Err}]};
                ok ->
            case check_peer_max_header_list_size(AllHeaders, State) of
                {error, _} = SErr ->
                    {keep_state, State, [{reply, From, SErr}]};
                ok ->
            {HeaderBlock, EncCtx1} = h2_hpack:encode(AllHeaders, EncCtx),
            BodyForbidden = ReqMethod =:= <<"HEAD">>
                            orelse Status =:= 204 orelse Status =:= 304,
            HeadersFit = byte_size(HeaderBlock) =< MaxFrameSize,
            BodySize = byte_size(Body),
            if
                %% Headers-only end-of-stream (body forbidden, or empty body).
                %% send_header_block also handles CONTINUATION for big blocks.
                BodyForbidden orelse BodySize =:= 0 ->
                    case send_header_block(StreamId, HeaderBlock, true, State) of
                        ok ->
                            finish_respond(From, StreamId, Stream, AllHeaders,
                                           EncCtx1, St, 0, State);
                        {error, R} ->
                            {stop_and_reply, {shutdown, {send_failed, R}},
                             [{reply, From, {error, R}}], State}
                    end;
                %% Coalesce HEADERS + every DATA frame into one write when the
                %% whole body is within the peer's flow-control windows and the
                %% coalesce cap. HeadersFit keeps the HEADERS within one frame;
                %% data_frames/4 chunks the body to MaxFrameSize. BodySize > 0
                %% here (the empty/forbidden case is handled by the branch above).
                HeadersFit
                andalso BodySize =< ConnWindow
                andalso BodySize =< StreamWindow
                andalso BodySize =< ?MAX_COALESCED_BODY_BYTES ->
                    IoData = [h2_frame:encode(
                                h2_frame:headers(StreamId, HeaderBlock, false))
                              | data_frames(StreamId, Body, MaxFrameSize, true)],
                    case sock_send(State, IoData) of
                        ok ->
                            finish_respond(From, StreamId, Stream, AllHeaders,
                                           EncCtx1, St, BodySize, State);
                        {error, R} ->
                            {stop_and_reply, {shutdown, {send_failed, R}},
                             [{reply, From, {error, R}}], State}
                    end;
                %% Oversized headers/body: let the granular path split frames and
                %% apply flow control. Drop EncCtx1 so the dynamic table is only
                %% updated once, by the fallback encode.
                true ->
                    {keep_state, State, [{reply, From, need_fallback}]}
            end
            end
            end;
        {ok, _} ->
            %% Wrong stream state: let the granular path produce the right error.
            {keep_state, State, [{reply, From, need_fallback}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end;
handle_respond(From, _StreamId, _Status, _Headers, _Body, State) ->
    {keep_state, State, [{reply, From, {error, not_server}}]}.

%% Commit the post-send stream/window state for handle_respond. BodySize is 0
%% for headers-only responses. Matches the open->half_closed_local /
%% half_closed_remote->closed transition used by the granular send path.
finish_respond(From, StreamId, #stream{window_size = StreamWindow} = Stream,
               AllHeaders, EncCtx1, OldState, BodySize,
               #state{conn_window_size = ConnWindow} = State) ->
    NewSt = case OldState of
        open -> half_closed_local;
        half_closed_remote -> closed
    end,
    Stream1 = Stream#stream{response_headers = AllHeaders, state = NewSt,
                            window_size = StreamWindow - BodySize},
    State0 = put_stream(StreamId, Stream1, State),
    State1 = State0#state{encode_context = EncCtx1,
                          conn_window_size = ConnWindow - BodySize},
    State2 = case NewSt of
        closed -> close_stream(StreamId, end_stream, State1);
        _      -> State1
    end,
    {keep_state, State2, [{reply, From, ok}]}.

%% RFC 9113 §4.2: a HEADERS frame's payload must not exceed
%% SETTINGS_MAX_FRAME_SIZE advertised by the peer. If our encoded block is
%% larger, split it across one HEADERS frame + one or more CONTINUATION
%% frames. No other frames on this stream may interleave.
%% Returns ok | {error, Reason}.
send_header_block(StreamId, HeaderBlock, EndStream, #state{peer_max_frame_size = MaxFrameSize} = State) ->
    case byte_size(HeaderBlock) =< MaxFrameSize of
        true ->
            send_frame(h2_frame:headers(StreamId, HeaderBlock, EndStream), State);
        false ->
            <<First:MaxFrameSize/binary, Rest/binary>> = HeaderBlock,
            case send_frame(h2_frame:headers(StreamId, First, EndStream, false), State) of
                ok -> send_continuations(StreamId, Rest, MaxFrameSize, State);
                {error, _} = Err -> Err
            end
    end.

send_continuations(StreamId, Rest, MaxFrameSize, State) when byte_size(Rest) =< MaxFrameSize ->
    send_frame(h2_frame:continuation(StreamId, Rest, true), State);
send_continuations(StreamId, Rest, MaxFrameSize, State) ->
    <<Chunk:MaxFrameSize/binary, More/binary>> = Rest,
    case send_frame(h2_frame:continuation(StreamId, Chunk, false), State) of
        ok -> send_continuations(StreamId, More, MaxFrameSize, State);
        {error, _} = Err -> Err
    end.

%% Build an iolist of DATA frames covering Body, each at most MaxFrameSize, so
%% the whole batch goes out in one socket write. END_STREAM is set only on the
%% final frame, and only when End is true. An empty Body yields no frame unless
%% End is set (then a single empty END_STREAM frame). Pure: no socket, no state.
data_frames(_StreamId, <<>>, _MaxFrameSize, false) ->
    [];
data_frames(StreamId, <<>>, _MaxFrameSize, true) ->
    [h2_frame:encode_iodata({data, StreamId, <<>>, true})];
data_frames(StreamId, Bin, MaxFrameSize, End) when byte_size(Bin) =< MaxFrameSize ->
    [h2_frame:encode_iodata({data, StreamId, Bin, End})];
data_frames(StreamId, Bin, MaxFrameSize, End) ->
    <<Chunk:MaxFrameSize/binary, Rest/binary>> = Bin,
    [h2_frame:encode_iodata({data, StreamId, Chunk, false})
     | data_frames(StreamId, Rest, MaxFrameSize, End)].

%% RFC 7540 §8.3: forbidden on a 2xx CONNECT response.
has_banned_tunnel_header(Headers) ->
    lists:any(fun({Name, _}) ->
        Name =:= <<"content-length">> orelse Name =:= <<"transfer-encoding">>
    end, Headers).

%% Buffer the payload onto the stream's send_buffer (with cap check), then
%% drain at most one DATA frame synchronously. If more remains and the
%% windows still allow it, flush_stream_one_chunk/2 self-casts so the
%% gen_statem yields between frames — that way inbound frames (PING,
%% WINDOW_UPDATE, RST_STREAM) get processed instead of queuing up for the
%% duration of a multi-megabyte body.
handle_send_data(From, StreamId, Data, EndStream, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{state = StreamState, send_buffer = Buffer} = Stream}
          when StreamState == open; StreamState == half_closed_remote ->
            case byte_size(Buffer) + byte_size(Data) > ?MAX_SEND_BUFFER_BYTES of
                true ->
                    {keep_state, State,
                     [{reply, From, {error, send_buffer_full}}]};
                false ->
                    NewBuffer = <<Buffer/binary, Data/binary>>,
                    Stream1 = Stream#stream{send_buffer = NewBuffer,
                                            pending_end_stream = EndStream},
                    State1 = put_stream(StreamId, Stream1, State),
                    case flush_stream(StreamId, State1) of
                        {ok, State2} ->
                            {keep_state, State2, [{reply, From, ok}]};
                        {error, Reason, State2} ->
                            {stop_and_reply,
                             {shutdown, {send_failed, Reason}},
                             [{reply, From, {error, Reason}}],
                             State2}
                    end
            end;
        {ok, _} ->
            {keep_state, State, [{reply, From, {error, invalid_stream_state}}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

%% Blocking send: append the data and drain a chunk. If the window already
%% accepted everything, reply `ok'. Otherwise park the caller on the stream's
%% send_waiters until the buffer drains (flush_stream/2 releases it) or the
%% per-call timer fires with {error, timeout}. Parking the caller is what bounds
%% buffering: it cannot enqueue more until this call returns.
handle_send_data_blocking(From, StreamId, Data, EndStream, Timeout,
                          #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{state = StreamState, send_buffer = Buffer} = Stream}
          when StreamState == open; StreamState == half_closed_remote ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            Stream1 = Stream#stream{send_buffer = NewBuffer,
                                    pending_end_stream = EndStream},
            State1 = put_stream(StreamId, Stream1, State),
            case flush_stream(StreamId, State1) of
                {ok, State2} ->
                    case stream_send_buffer_empty(StreamId, State2) of
                        true ->
                            {keep_state, State2, [{reply, From, ok}]};
                        false ->
                            TimerRef = start_send_timer(Timeout),
                            State3 = add_send_waiter(StreamId, {From, TimerRef}, State2),
                            {keep_state, State3}
                    end;
                {error, Reason, State2} ->
                    {stop_and_reply,
                     {shutdown, {send_failed, Reason}},
                     [{reply, From, {error, Reason}}],
                     State2}
            end;
        {ok, _} ->
            {keep_state, State, [{reply, From, {error, invalid_stream_state}}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

start_send_timer(infinity) -> undefined;
start_send_timer(Timeout) when is_integer(Timeout) ->
    erlang:start_timer(Timeout, self(), send_timeout).

stream_send_buffer_empty(StreamId, #state{streams = Streams}) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{send_buffer = <<>>, pending_end_stream = false}} -> true;
        _ -> false
    end.

add_send_waiter(StreamId, Waiter, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{send_waiters = Waiters} = Stream} ->
            put_stream(StreamId, Stream#stream{send_waiters = Waiters ++ [Waiter]}, State);
        error ->
            State
    end.

%% Reply `ok' to every parked blocking-send caller once a stream's buffer has
%% fully drained, cancelling their timers.
release_send_waiters_if_drained(StreamId, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{send_buffer = <<>>, pending_end_stream = false,
                     send_waiters = [_ | _] = Waiters} = Stream} ->
            lists:foreach(fun({From, TimerRef}) ->
                ok = cancel_timer(TimerRef),
                gen_statem:reply(From, ok)
            end, Waiters),
            put_stream(StreamId, Stream#stream{send_waiters = []}, State);
        _ ->
            State
    end.

%% Settle every parked blocking-send caller of a stream that is closing.
%% When the send buffer fully drained, their data was sent (e.g. the closing
%% END_STREAM chunk on a half_closed_remote stream reaches close_stream before
%% flush_stream gets to release them), so reply `ok'. Otherwise the data is
%% stuck in the buffer forever, reply an error mapping the close cause:
%% `rst' → {error, stream_reset}, `end_stream' → {error, stream_closed}.
settle_send_waiters(#stream{send_waiters = []}, _Reason) ->
    ok;
settle_send_waiters(#stream{send_buffer = Buffer, pending_end_stream = PendingEnd,
                            send_waiters = Waiters}, Reason) ->
    Reply = if
        Buffer =:= <<>>, PendingEnd =:= false -> ok;
        Reason =:= rst -> {error, stream_reset};
        true -> {error, stream_closed}
    end,
    lists:foreach(fun({From, TimerRef}) ->
        ok = cancel_timer(TimerRef),
        gen_statem:reply(From, Reply)
    end, Waiters).

%% Fire {error, timeout} to the parked caller whose timer expired and drop it.
release_send_waiter_timeout(TimerRef, #state{streams = Streams} = State) ->
    maps:fold(fun(StreamId, #stream{send_waiters = Waiters} = Stream, AccState) ->
        case lists:keytake(TimerRef, 2, Waiters) of
            {value, {From, TimerRef}, Rest} ->
                gen_statem:reply(From, {error, timeout}),
                put_stream(StreamId, Stream#stream{send_waiters = Rest}, AccState);
            false ->
                AccState
        end
    end, State, Streams).

%% Drain one chunk, release any satisfied blocking-send waiters, then emit any
%% trailers that were queued behind the buffered DATA. The single choke point
%% used by every flush trigger.
flush_stream(StreamId, State) ->
    case flush_stream_one_chunk(StreamId, State) of
        {ok, State1} ->
            State2 = release_send_waiters_if_drained(StreamId, State1),
            maybe_flush_pending_trailers(StreamId, State2);
        {error, _Reason, _State1} = Err ->
            Err
    end.

%% Once a stream's send_buffer has fully drained, emit any trailers that were
%% deferred by handle_send_trailers so END_STREAM never overtakes the DATA.
maybe_flush_pending_trailers(StreamId, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{send_buffer = <<>>, pending_end_stream = false,
                     pending_trailers = Trailers} = Stream}
          when Trailers =/= undefined ->
            emit_trailers_frame(StreamId, Trailers, Stream, State);
        _ ->
            {ok, State}
    end.

handle_send_trailers(From, StreamId, Trailers, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{tunnel = true}} ->
            %% RFC 7540 §8.3: trailers are forbidden on a CONNECT tunnel.
            {keep_state, State, [{reply, From, {error, tunnel_no_trailers}}]};
        {ok, #stream{state = StreamState, send_buffer = Buffer} = Stream}
          when StreamState == open; StreamState == half_closed_remote ->
            case validate_trailers(Trailers, true) of
                {error, _} = Err ->
                    {keep_state, State, [{reply, From, Err}]};
                ok ->
            case check_peer_max_header_list_size(Trailers, State) of
                {error, _} = SErr ->
                    {keep_state, State, [{reply, From, SErr}]};
                ok ->
            case Buffer of
                <<>> ->
                    %% Nothing buffered: emit the trailers (END_STREAM) now.
                    case emit_trailers_frame(StreamId, Trailers, Stream, State) of
                        {ok, State1} ->
                            {keep_state, State1, [{reply, From, ok}]};
                        {error, SendReason, State1} ->
                            {stop_and_reply,
                             {shutdown, {send_failed, SendReason}},
                             [{reply, From, {error, SendReason}}],
                             State1}
                    end;
                _ ->
                    %% DATA still draining under the flow-control window: queue the
                    %% trailers so END_STREAM goes out strictly after that DATA.
                    %% flush_stream/2 emits them once the buffer empties.
                    Stream1 = Stream#stream{pending_trailers = Trailers},
                    {keep_state, put_stream(StreamId, Stream1, State),
                     [{reply, From, ok}]}
            end
            end
            end;
        {ok, _} ->
            {keep_state, State, [{reply, From, {error, invalid_stream_state}}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

%% Encode and write a trailers HEADERS frame with END_STREAM, transitioning the
%% stream and closing it when both sides are done. Shared by the immediate path
%% and the deferred (post-drain) path in maybe_flush_pending_trailers/2.
emit_trailers_frame(StreamId, Trailers,
                    #stream{state = StreamState} = Stream,
                    #state{encode_context = EncCtx} = State) ->
    {HeaderBlock, EncCtx1} = h2_hpack:encode(Trailers, EncCtx),
    case send_header_block(StreamId, HeaderBlock, true, State) of
        {error, Reason} ->
            {error, Reason, State};
        ok ->
            NewStreamState = case StreamState of
                open               -> half_closed_local;
                half_closed_remote -> closed;
                _                  -> StreamState
            end,
            Stream1 = Stream#stream{state = NewStreamState,
                                    pending_trailers = undefined},
            State1 = put_stream(StreamId, Stream1,
                                State#state{encode_context = EncCtx1}),
            State2 = case NewStreamState of
                closed -> close_stream(StreamId, end_stream, State1);
                _      -> State1
            end,
            {ok, State2}
    end.

handle_cancel_stream(From, StreamId, ErrorCode, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{state = StreamState}} when StreamState =/= closed ->
            send_rst_stream(StreamId, ErrorCode, State),
            State1 = close_stream(StreamId, rst, State),
            {keep_state, State1, [{reply, From, ok}]};
        {ok, _} ->
            {keep_state, State, [{reply, From, {error, stream_closed}}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

handle_set_stream_handler(From, StreamId, Pid, Opts, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{recv_buffer = Buf} = Stream} ->
            %% Default: the connection replays every previously-buffered event
            %% (response/data/trailers/informational/stream_reset) to the handler
            %% pid, in arrival order, so anything that raced ahead of registration
            %% is never dropped to the owner. Opt in to `drain_buffer => true' to
            %% get the raw DATA buffer back as [{Data,Fin}] and forward it by hand
            %% (kept for the existing WebSocket/MASQUE callers).
            HandToCaller = maps:get(drain_buffer, Opts, false),
            FlowControl = case maps:get(flow_control, Opts, Stream#stream.flow_control) of
                manual -> manual;
                _      -> auto
            end,
            Stream1 = Stream#stream{handler = Pid, recv_buffer = [],
                                    flow_control = FlowControl},
            State1 = put_stream(StreamId, Stream1, State),
            Ordered = lists:reverse(Buf),
            Reply = case HandToCaller of
                true ->
                    case [{D, Fin} || {data, _Sid, D, Fin} <- Ordered] of
                        []   -> ok;
                        Data -> {ok, Data}
                    end;
                false ->
                    lists:foreach(fun(Event) ->
                        Pid ! {h2, self(), Event},
                        ok
                    end, Ordered),
                    ok
            end,
            {keep_state, State1, [{reply, From, Reply}]};
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

handle_unset_stream_handler(From, StreamId, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Stream1 = Stream#stream{handler = undefined},
            State1 = put_stream(StreamId, Stream1, State),
            {keep_state, State1, [{reply, From, ok}]};
        error ->
            {keep_state, State, [{reply, From, ok}]}
    end.

%% Deliver a DATA event using the unified stream-event routing below.
dispatch_data(StreamId, Stream, Data, Fin, State) ->
    dispatch_stream_event_inflight(StreamId, Stream, {data, StreamId, Data, Fin}, State).

%% Route a stream-scoped event for an *in-flight* (not-yet-committed) #stream
%% record, returning the possibly-updated record plus state. One choke point for
%% every per-stream event (data/response/trailers/informational/stream_reset):
%%   1. handler registered      -> deliver to the handler pid
%%   2. dispatch_mode = buffer  -> hold in recv_buffer for later replay
%%   3. client, no handler      -> deliver to the owner (legacy client behaviour)
%%   4. server, no handler      -> buffer (legacy "buffer until set_stream_handler")
dispatch_stream_event_inflight(_StreamId, #stream{handler = Pid} = Stream, Event, State)
  when is_pid(Pid) ->
    _ = Pid ! {h2, self(), Event},
    {Stream, State};
dispatch_stream_event_inflight(_StreamId, #stream{dispatch_mode = buffer,
                                                  recv_buffer = Buf} = Stream, Event, State) ->
    {Stream#stream{recv_buffer = [Event | Buf]}, State};
dispatch_stream_event_inflight(_StreamId, #stream{} = Stream, Event,
                               #state{mode = client} = State) ->
    notify_owner({h2, self(), Event}, State),
    {Stream, State};
dispatch_stream_event_inflight(_StreamId, #stream{recv_buffer = Buf} = Stream, Event, State) ->
    {Stream#stream{recv_buffer = [Event | Buf]}, State}.

%% Route a stream-scoped event when the #stream record is already committed to
%% the streams map (response/informational/trailers/stream_reset paths). Reads
%% the record, dispatches via the in-flight router, and re-commits it so the
%% buffer case persists. Falls back to the owner for unknown streams.
dispatch_stream_event(StreamId, Event, #state{streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            {Stream1, State1} = dispatch_stream_event_inflight(StreamId, Stream, Event, State),
            put_stream(StreamId, Stream1, State1);
        error ->
            notify_owner({h2, self(), Event}, State)
    end.

handle_send_goaway(From, ErrorCode, _CurrentState, State) ->
    %% RFC 7540 §6.8: two-phase GOAWAY. Send a "shutdown warning" first with
    %% LastStreamID = 2^31-1 and NO_ERROR so the peer can finish in-flight
    %% streams; after a brief drain, send the real GOAWAY with the actual
    %% last_peer_stream_id and close.
    State1 = send_goaway_frame(?MAX_STREAM_ID, no_error, State),
    notify_owner({h2, self(), goaway_sent}, State1),
    DrainTimer = erlang:start_timer(?GOAWAY_DRAIN_MS, self(), goaway_drain),
    State2 = State1#state{
        goaway_error = ErrorCode,
        close_timer = DrainTimer
    },
    {next_state, goaway_sent, State2, [{reply, From, ok}]}.

%% ============================================================================
%% Internal: Common Call Handling
%% ============================================================================

handle_call_early(From, Request, StateName, #state{waiters = Waiters} = State) ->
    case Request of
        wait_connected ->
            %% Queue this caller to be notified when connected
            {keep_state, State#state{waiters = [From | Waiters]}};
        get_settings ->
            {keep_state, State, [{reply, From, State#state.local_settings}]};
        get_peer_settings ->
            {keep_state, State, [{reply, From, State#state.peer_settings}]};
        peername ->
            {keep_state, State, [{reply, From, do_peername(State)}]};
        {controlling_process, NewOwner} ->
            {keep_state, swap_owner_monitor(NewOwner, State),
             [{reply, From, ok}]};
        _ ->
            {keep_state, State, [{reply, From, {error, {not_ready, StateName}}}]}
    end.

%% Per-stream calls that are valid in every state where streams exist:
%% `settings' (a server may answer before the SETTINGS ack), `connected',
%% and both goaway states (RFC 9113 6.8 keeps existing streams alive after
%% a GOAWAY). Returns `false' for anything else.
handle_stream_call(From, {send_data, StreamId, Data, EndStream}, State) ->
    handle_send_data(From, StreamId, Data, EndStream, State);
handle_stream_call(From, {send_data_blocking, StreamId, Data, EndStream, Timeout}, State) ->
    handle_send_data_blocking(From, StreamId, Data, EndStream, Timeout, State);
handle_stream_call(From, {consume, StreamId, ByteCount}, State) ->
    handle_consume(From, StreamId, ByteCount, State);
handle_stream_call(From, {send_response, StreamId, Status, Headers}, State) ->
    handle_send_response(From, StreamId, Status, Headers, State);
handle_stream_call(From, {respond, StreamId, Status, Headers, Body}, State) ->
    handle_respond(From, StreamId, Status, Headers, Body, State);
handle_stream_call(From, {send_trailers, StreamId, Trailers}, State) ->
    handle_send_trailers(From, StreamId, Trailers, State);
handle_stream_call(From, {cancel_stream, StreamId, ErrorCode}, State) ->
    handle_cancel_stream(From, StreamId, ErrorCode, State);
handle_stream_call(From, {set_stream_handler, StreamId, Pid, Opts}, State) ->
    handle_set_stream_handler(From, StreamId, Pid, Opts, State);
handle_stream_call(From, {unset_stream_handler, StreamId}, State) ->
    handle_unset_stream_handler(From, StreamId, State);
handle_stream_call(_From, _Request, _State) ->
    false.

handle_call_common(From, Request, _StateName, State) ->
    case Request of
        get_settings ->
            {keep_state, State, [{reply, From, State#state.local_settings}]};
        get_peer_settings ->
            {keep_state, State, [{reply, From, State#state.peer_settings}]};
        peername ->
            {keep_state, State, [{reply, From, do_peername(State)}]};
        {controlling_process, NewOwner} ->
            {keep_state, swap_owner_monitor(NewOwner, State),
             [{reply, From, ok}]};
        _ ->
            {keep_state, State, [{reply, From, {error, unknown_request}}]}
    end.

do_peername(#state{socket = undefined}) ->
    {error, not_connected};
do_peername(#state{socket = Socket, transport = gen_tcp}) ->
    inet:peername(Socket);
do_peername(#state{socket = Socket, transport = ssl}) ->
    ssl:peername(Socket).

handle_common(info, {'EXIT', Owner, Reason}, _StateName, #state{owner = Owner} = State) ->
    {stop, {shutdown, {owner_exit, Reason}}, State};
handle_common(info, {'DOWN', Ref, process, _Pid, Reason}, _StateName,
              #state{owner_monitor = Ref} = State) when Ref =/= undefined ->
    {stop, {shutdown, {owner_exit, Reason}}, State};
handle_common(info, {tcp_error, Socket, Reason}, _StateName, #state{socket = Socket} = State) ->
    {stop, {shutdown, {tcp_error, Reason}}, State};
handle_common(info, {ssl_error, Socket, Reason}, _StateName, #state{socket = Socket} = State) ->
    {stop, {shutdown, {ssl_error, Reason}}, State};
%% Yielded send_data continuation. We accept this in any state — the
%% connection may have transitioned to goaway_sent/_received between the
%% cast being scheduled and processed; draining the buffered data is still
%% safe and lets in-flight streams complete.
handle_common(cast, {flush_stream, StreamId}, _StateName, State) ->
    case flush_stream(StreamId, State) of
        {ok, State1} -> {keep_state, State1};
        {error, Reason, State1} ->
            {stop, {shutdown, {send_failed, Reason}}, State1}
    end;
%% A blocking send_data/5 waiter's deadline elapsed before its buffer drained.
handle_common(info, {timeout, TimerRef, send_timeout}, _StateName, State) ->
    {keep_state, release_send_waiter_timeout(TimerRef, State)};
handle_common(_EventType, _Event, _StateName, State) ->
    {keep_state, State}.

%% ============================================================================
%% Internal: Stream Management
%% ============================================================================

validate_stream_id(StreamId, client, #state{last_peer_stream_id = LastPeer}) ->
    %% Server-initiated streams must be even
    if
        StreamId rem 2 =:= 1 -> {error, protocol_error};  % Must be even
        StreamId =< LastPeer -> {error, protocol_error};  % Must be new
        true -> ok
    end;
validate_stream_id(StreamId, server, #state{last_peer_stream_id = LastPeer}) ->
    %% Client-initiated streams must be odd
    if
        StreamId rem 2 =:= 0 -> {error, protocol_error};  % Must be odd
        StreamId =< LastPeer -> {error, protocol_error};  % Must be new
        true -> ok
    end.

get_or_create_stream(StreamId, #state{streams = Streams,
                                       peer_initial_window_size = InitialWindow,
                                       local_settings = LocalSettings} = _State) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Stream;
        error ->
            RecvWindow = h2_settings:get(initial_window_size, LocalSettings),
            #stream{
                id = StreamId,
                state = idle,
                window_size = InitialWindow,
                recv_window_size = RecvWindow
            }
    end.

%% Single choke point for stream-map writes. Adjusts the maintained counters by
%% comparing the stream's old state (from the map) to its new state, so the two
%% count_* functions stay O(1). The only deletion from `streams` is closed-stream
%% eviction (count 0), so removals never need adjustment.
put_stream(StreamId, Stream, #state{streams = Streams, mode = Mode,
                                    active_stream_count = AC,
                                    peer_active_stream_count = PC} = State) ->
    OldState = case maps:find(StreamId, Streams) of
                   {ok, #stream{state = OS}} -> OS;
                   error -> undefined
               end,
    {DA, DP} = stream_count_delta(StreamId, Mode, OldState, Stream#stream.state),
    State#state{streams = maps:put(StreamId, Stream, Streams),
                active_stream_count = AC + DA,
                peer_active_stream_count = PC + DP}.

%% Count-membership delta for a stream transitioning OldState -> NewState.
%% `undefined` OldState means the stream was absent (insert).
stream_count_delta(Id, Mode, OldState, NewState) ->
    {b2i(is_active_state(NewState)) - b2i(is_active_state(OldState)),
     b2i(is_peer_active(Id, Mode, NewState))
         - b2i(is_peer_active(Id, Mode, OldState))}.

is_active_state(closed)    -> false;
is_active_state(undefined) -> false;
is_active_state(_)         -> true.

is_peer_active(Id, Mode, S) ->
    is_peer_initiated(Id, Mode)
        andalso (S =:= open orelse S =:= half_closed_local
                 orelse S =:= half_closed_remote).

%% Stream-id parity fixes the initiator for the stream's whole life.
is_peer_initiated(Id, server) -> Id rem 2 =:= 1;   %% peer = client (odd ids)
is_peer_initiated(Id, client) -> Id rem 2 =:= 0.   %% peer = server (even ids, push)

b2i(true)  -> 1;
b2i(false) -> 0.

%% Mark a stream closed with an explicit reason and retain its record so
%% later frames can be classified correctly per RFC 9113 §5.1.
%% Reason: `end_stream` (natural close) → post-close frames are a connection
%% error; `rst` (peer or local RST_STREAM) → post-close frames are a stream
%% error. The FIFO is capped so memory stays bounded.
close_stream(StreamId, Reason, #state{streams = Streams} = State0) ->
    %% Flip state via put_stream/3 so the counters are decremented once
    %% (idempotent: a stream already closed has Old = closed, delta 0).
    State = case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            %% A blocking send_data/5 caller parked on this stream can never
            %% be satisfied once the stream closes: flush_stream/2 (the only
            %% release path besides its timeout timer) no longer runs for a
            %% closed stream, so an infinity-blocked sender would hang for
            %% the connection's lifetime. Settle the waiters instead.
            settle_send_waiters(Stream, Reason),
            put_stream(StreamId,
                       Stream#stream{state = closed, closed_reason = Reason,
                                     send_waiters = []},
                       State0);
        error ->
            State0
    end,
    #state{streams = Streams1,
           closed_streams = Q,
           closed_streams_count = N,
           closed_reasons = Reasons,
           closed_reasons_q = RQ,
           closed_reasons_count = RN} = State,
    Q1 = queue:in(StreamId, Q),
    N1 = N + 1,
    {Streams2, Q2, N2} = evict_old_closed(Streams1, Q1, N1),
    Reasons1 = maps:put(StreamId, Reason, Reasons),
    RQ1 = queue:in(StreamId, RQ),
    RN1 = RN + 1,
    {Reasons2, RQ2, RN2} = evict_old_reasons(Reasons1, RQ1, RN1),
    State#state{streams = Streams2,
                closed_streams = Q2, closed_streams_count = N2,
                closed_reasons = Reasons2,
                closed_reasons_q = RQ2, closed_reasons_count = RN2}.

evict_old_closed(Streams, Q, N) when N =< ?CLOSED_STREAMS_LIMIT ->
    {Streams, Q, N};
evict_old_closed(Streams, Q, N) ->
    {{value, OldId}, Q1} = queue:out(Q),
    evict_old_closed(maps:remove(OldId, Streams), Q1, N - 1).

evict_old_reasons(Reasons, Q, N) when N =< ?CLOSED_REASONS_LIMIT ->
    {Reasons, Q, N};
evict_old_reasons(Reasons, Q, N) ->
    {{value, OldId}, Q1} = queue:out(Q),
    evict_old_reasons(maps:remove(OldId, Reasons), Q1, N - 1).

%% O(1): active_stream_count is kept in sync by put_stream/3.
count_active_streams(#state{active_stream_count = N}) ->
    N.

%% @doc Test/debug invariant: recompute the stream counters by folding the live
%% `streams` map and compare against the incrementally maintained fields.
%% Returns `ok' when they agree, `{mismatch, ...}' otherwise.
-spec verify_stream_counts(pid()) -> ok | {mismatch, map()}.
verify_stream_counts(Pid) ->
    {_StateName, #state{mode = Mode, streams = Streams,
                        active_stream_count = AC,
                        peer_active_stream_count = PC}} = sys:get_state(Pid),
    {RA, RP} = maps:fold(fun(Id, #stream{state = S}, {A, P}) ->
        {A + b2i(is_active_state(S)),
         P + b2i(is_peer_active(Id, Mode, S))}
    end, {0, 0}, Streams),
    case {AC, PC} of
        {RA, RP} -> ok;
        _ -> {mismatch, #{active => AC, recomputed_active => RA,
                          peer_active => PC, recomputed_peer_active => RP}}
    end.

flush_send_buffers(#state{streams = Streams} = State) ->
    maps:fold(fun(StreamId, _Stream, AccState) ->
        flush_stream_buffer(StreamId, AccState)
    end, State, Streams).

%% Backwards-compatible wrapper used by callers that don't care about
%% transport errors at the call site (peer-driven WINDOW_UPDATE handler,
%% flush_send_buffers fold). The actual draining is one chunk at a time;
%% remaining bytes drain via self-casts handled in connected/3.
flush_stream_buffer(StreamId, State) ->
    case flush_stream(StreamId, State) of
        {ok, State1} -> State1;
        %% Best-effort: a dead socket surfaces via {tcp_closed,_} /
        %% {ssl_closed,_} and terminates the connection shortly after.
        {error, _Reason, State1} -> State1
    end.

%% Send AT MOST one DATA frame from the stream's send_buffer. If more
%% remains and the windows have room, self-cast `{flush_stream, StreamId}'
%% so the gen_statem yields between chunks instead of monopolising the
%% scheduler on multi-megabyte bodies. Returns:
%%   {ok, NewState}             - sent (or nothing to send right now)
%%   {error, Reason, NewState}  - transport error, caller decides shutdown
flush_stream_one_chunk(StreamId, #state{streams = Streams,
                                         conn_window_size = ConnWindow,
                                         peer_max_frame_size = MaxFrameSize} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{send_buffer = <<>>, pending_end_stream = true,
                     state = SState} = Stream}
          when SState =:= open; SState =:= half_closed_remote ->
            %% Empty body with END_STREAM still needs an empty DATA frame
            %% on the wire to half-close the stream peer-side.
            emit_end_stream_data(StreamId, Stream, State);
        {ok, #stream{send_buffer = <<>>}} ->
            {ok, State};
        {ok, #stream{send_buffer = Buffer, window_size = StreamWindow,
                     pending_end_stream = PendingEnd, state = StreamState} = Stream} ->
            Available = min(ConnWindow, StreamWindow),
            %% Stage the whole flow-control-ready batch (bounded by the coalesce
            %% cap) and write it in one go, chunked to MaxFrameSize frames.
            ToSend = min(min(Available, ?MAX_COALESCED_BODY_BYTES), byte_size(Buffer)),
            case ToSend =< 0 of
                true ->
                    {ok, State};
                false ->
                    <<SendData:ToSend/binary, Remaining/binary>> = Buffer,
                    IsEnd = PendingEnd andalso Remaining == <<>>,
                    IoData = data_frames(StreamId, SendData, MaxFrameSize, IsEnd),
                    case sock_send(State, IoData) of
                        {error, Reason} ->
                            {error, Reason, State};
                        ok ->
                            NewStreamState = case IsEnd of
                                true ->
                                    case StreamState of
                                        open -> half_closed_local;
                                        half_closed_remote -> closed;
                                        _ -> StreamState
                                    end;
                                false ->
                                    StreamState
                            end,
                            NewConnWindow = ConnWindow - ToSend,
                            NewStreamWindow = StreamWindow - ToSend,
                            Stream1 = Stream#stream{
                                send_buffer = Remaining,
                                window_size = NewStreamWindow,
                                pending_end_stream = PendingEnd andalso Remaining =/= <<>>,
                                state = NewStreamState
                            },
                            State0 = put_stream(StreamId, Stream1, State),
                            State1 = State0#state{conn_window_size = NewConnWindow},
                            State2 = case NewStreamState =:= closed
                                         andalso StreamState =:= half_closed_remote of
                                true  -> close_stream(StreamId, end_stream, State1);
                                false -> State1
                            end,
                            case Remaining =/= <<>>
                                 andalso NewConnWindow > 0
                                 andalso NewStreamWindow > 0
                                 andalso NewStreamState =/= closed of
                                true ->
                                    gen_statem:cast(self(),
                                                    {flush_stream, StreamId}),
                                    {ok, State2};
                                false ->
                                    {ok, State2}
                            end
                    end
            end;
        error ->
            {ok, State}
    end.

%% Emit an empty DATA frame with END_STREAM=1 to half-close the stream on
%% the wire. Used when send_data was called with empty payload + EndStream.
emit_end_stream_data(StreamId, #stream{state = StreamState} = Stream, State) ->
    Frame = h2_frame:data(StreamId, <<>>, true),
    case send_frame(Frame, State) of
        {error, Reason} ->
            {error, Reason, State};
        ok ->
            NewStreamState = case StreamState of
                open -> half_closed_local;
                half_closed_remote -> closed;
                _ -> StreamState
            end,
            Stream1 = Stream#stream{pending_end_stream = false,
                                    state = NewStreamState},
            State1 = put_stream(StreamId, Stream1, State),
            State2 = case NewStreamState =:= closed
                         andalso StreamState =:= half_closed_remote of
                true  -> close_stream(StreamId, end_stream, State1);
                false -> State1
            end,
            {ok, State2}
    end.

%% ============================================================================
%% Internal: Frame Sending
%% ============================================================================

send_preface(State) ->
    %% Send connection preface (tolerate peer-close mid-send)
    _ = sock_send(State, ?H2_PREFACE),
    send_settings_frame(State).

%% The connection window can only grow through a stream-0 WINDOW_UPDATE
%% (RFC 9113 §6.9.2), so a connection_window_size above the 65535 default is
%% granted in one frame right after our SETTINGS.
grow_conn_window(#state{recv_conn_window_size = Window,
                        recv_conn_window_target = Target} = State) when Target > Window ->
    %% Best-effort like send_settings_frame/1.
    _ = send_frame(h2_frame:window_update(0, Target - Window), State),
    State#state{recv_conn_window_size = Target};
grow_conn_window(State) ->
    State.

send_settings_frame(#state{local_settings = Settings, pending_settings = Pending} = State) ->
    Frame = h2_frame:settings(settings_to_list(Settings)),
    %% Best-effort like the preface above: if the peer has already closed,
    %% the imminent {tcp_closed,_} / {ssl_closed,_} will tear us down and
    %% reply {error, _} to any wait_connected callers.
    _ = send_frame(Frame, State),
    State#state{pending_settings = Pending ++ [Settings]}.

settings_to_list(Settings) ->
    maps:fold(fun(Key, Value, Acc) ->
        case h2_settings:setting_id(Key) of
            undefined -> Acc;
            Id -> [{Id, h2_settings:encode_value(Value)} | Acc]
        end
    end, [], Settings).

%% Returns ok | {error, Reason}. Callers must handle errors so that
%% an in-flight gen_statem:call cannot reply ok to the user after the
%% socket has died.
send_frame(Frame, State) ->
    %% iodata: DATA payloads are sent without an extra body copy.
    sock_send(State, h2_frame:encode_iodata(Frame)).

%% Single socket-write choke point. Every frame and coalesced batch goes through
%% here, so one Transport:send maps to one socket write (and the test traces this
%% to count writes). Returns ok | {error, Reason} from the transport.
sock_send(#state{socket = Socket, transport = Transport}, IoData) ->
    Transport:send(Socket, IoData).

send_goaway_frame(LastStreamId, ErrorCode, State) ->
    Frame = h2_frame:goaway(LastStreamId, ErrorCode, <<>>),
    _ = sock_send(State, h2_frame:encode_iodata(Frame)),
    State#state{goaway_sent = true, goaway_error = ErrorCode}.

send_rst_stream(StreamId, ErrorCode, State) ->
    Frame = h2_frame:rst_stream(StreamId, ErrorCode),
    _ = sock_send(State, h2_frame:encode_iodata(Frame)),
    ok.

%% ============================================================================
%% Internal: Utilities
%% ============================================================================

set_active(gen_tcp, Socket) ->
    inet:setopts(Socket, [{active, once}]);
set_active(ssl, Socket) ->
    ssl:setopts(Socket, [{active, once}]).

shutdown_write(gen_tcp, Socket) ->
    gen_tcp:shutdown(Socket, write);
shutdown_write(ssl, Socket) ->
    ssl:shutdown(Socket, write).

%% Stop the gen_statem with Reason, replying {error, Reason} to any waiters
%% that called wait_connected before we reached the connected state.
stop_and_notify_waiters(Reason, #state{waiters = Waiters} = State) ->
    Replies = [{reply, From, {error, peel_reason(Reason)}} || From <- Waiters],
    {stop_and_reply, Reason, Replies, State#state{waiters = []}}.

%% Reply `ok` to any queued wait_connected callers and fire the owner
%% notification. Called inline when a frame causes the transition to
%% `connected` so the reply isn't lost if the very next frame in the same
%% buffer triggers a connection error before gen_statem enters the state.
notify_connected(#state{connected_notified = true} = State) ->
    State;
notify_connected(#state{waiters = Waiters, settings_timer = Timer} = State) ->
    ok = cancel_timer(Timer),
    notify_owner({h2, self(), connected}, State),
    [gen_statem:reply(From, ok) || From <- Waiters],
    State#state{waiters = [], settings_timer = undefined, connected_notified = true}.

%% Strip nested `{shutdown, _}' wrappers so callers see the underlying
%% cause; `{shutdown, {shutdown, X}}' shouldn't escape to the API layer.
peel_reason({shutdown, R}) -> peel_reason(R);
peel_reason(R) -> R.

%% Cancel a timer and ensure any already-delivered {timeout, Ref, _}
%% message is flushed from the mailbox so it cannot match a future
%% timer that happens to reuse the same field name.
cancel_timer(undefined) -> ok;
cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref, [{async, false}, {info, false}]) of
        _ -> ok
    end,
    receive
        {timeout, Ref, _} -> ok
    after 0 -> ok
    end.

%% Switch owner liveness tracking to NewOwner: demonitor the previous
%% monitor (if any), install a fresh one. The initial owner is reached via
%% start_link's bidirectional link, so owner_monitor is undefined until the
%% first controlling_process call.
swap_owner_monitor(NewOwner, #state{owner_monitor = OldRef} = State) ->
    case OldRef of
        undefined -> ok;
        _ -> _ = erlang:demonitor(OldRef, [flush]), ok
    end,
    NewRef = erlang:monitor(process, NewOwner),
    State#state{owner = NewOwner, owner_monitor = NewRef}.

%% Mirror of h2:is_ssl_socket/1. Two copies for now because both modules
%% need it during their own init paths and neither exposes it publicly;
%% keep them in sync if you change one.
is_ssl_socket(Socket) when is_tuple(Socket) ->
    element(1, Socket) =:= sslsocket;
is_ssl_socket(_) ->
    false.

notify_owner(Msg, #state{owner = Owner}) ->
    Owner ! Msg,
    ok.

%% Deliver Event to every distinct registered stream handler. Used on
%% connection-wide teardown (GOAWAY / closed) so a per-stream bidi process is
%% told its connection is going away even though it does not own the connection.
%% The owner is excluded — it is notified separately, exactly once.
notify_all_handlers(Event, #state{streams = Streams, owner = Owner}) ->
    Pids = maps:fold(fun(_Id, #stream{handler = Pid}, Acc)
                           when is_pid(Pid), Pid =/= Owner ->
                             Acc#{Pid => true};
                        (_Id, _Stream, Acc) ->
                             Acc
                     end, #{}, Streams),
    _ = [Pid ! {h2, self(), Event} || Pid <- maps:keys(Pids)],
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Parse a flattened iolist of DATA frames back into [{Payload, EndStream}].
parse_data_frames(<<>>) ->
    [];
parse_data_frames(<<Len:24, 0:8, Flags:8, _R:1, _Sid:31,
                    Payload:Len/binary, Rest/binary>>) ->
    [{Payload, (Flags band 1) =:= 1} | parse_data_frames(Rest)].

data_frames_test_() ->
    Max = 16384,
    Body = binary:copy(<<"x">>, 100 * 1024),
    Frames = parse_data_frames(iolist_to_binary(data_frames(1, Body, Max, true))),
    Sizes = [byte_size(P) || {P, _} <- Frames],
    Ends  = [E || {_, E} <- Frames],
    %% Exact multiple of Max: N full frames, END_STREAM on the last only.
    Body2 = binary:copy(<<"y">>, 2 * Max),
    Frames2 = parse_data_frames(iolist_to_binary(data_frames(3, Body2, Max, true))),
    [%% 100 KiB / 16 KiB -> 7 DATA frames.
     ?_assertEqual(7, length(Frames)),
     %% Only the final frame carries END_STREAM.
     ?_assertEqual([false, false, false, false, false, false, true], Ends),
     %% Chunked to Max, last frame is the 4 KiB remainder.
     ?_assertEqual([Max, Max, Max, Max, Max, Max, 100 * 1024 - 6 * Max], Sizes),
     %% Reassembles to the original body.
     ?_assertEqual(Body, iolist_to_binary([P || {P, _} <- Frames])),
     %% Empty body without END_STREAM -> no frames.
     ?_assertEqual([], data_frames(1, <<>>, Max, false)),
     %% Empty body with END_STREAM -> a single empty END_STREAM frame.
     ?_assertEqual([{<<>>, true}],
                   parse_data_frames(iolist_to_binary(
                       data_frames(1, <<>>, Max, true)))),
     %% Exact multiple: two full frames, END_STREAM on the second.
     ?_assertEqual([Max, Max], [byte_size(P) || {P, _} <- Frames2]),
     ?_assertEqual([false, true], [E || {_, E} <- Frames2])].

parse_status_test_() ->
    [?_assertEqual({ok, 200}, parse_status([{<<":status">>, <<"200">>}])),
     ?_assertEqual({ok, 100}, parse_status([{<<":status">>, <<"100">>}])),
     ?_assertEqual({ok, 599}, parse_status([{<<":status">>, <<"599">>}])),
     ?_assertEqual(malformed, parse_status([{<<":status">>, <<"abc">>}])),
     ?_assertEqual(malformed, parse_status([{<<":status">>, <<"2000">>}])),
     ?_assertEqual(malformed, parse_status([{<<":status">>, <<"99">>}])),
     ?_assertEqual(malformed, parse_status([{<<":status">>, <<"600">>}])),
     ?_assertEqual(malformed, parse_status([{<<":status">>, <<>>}])),
     ?_assertEqual(malformed, parse_status([]))].

parse_content_length_test_() ->
    [?_assertEqual({ok, undefined}, parse_content_length([])),
     ?_assertEqual({ok, 0},  parse_content_length([{<<"content-length">>, <<"0">>}])),
     ?_assertEqual({ok, 42}, parse_content_length([{<<"content-length">>, <<"42">>}])),
     %% Duplicate with same value collapses.
     ?_assertEqual({ok, 42}, parse_content_length([{<<"content-length">>, <<"42">>},
                                                    {<<"content-length">>, <<"42">>}])),
     %% Mismatched duplicates → malformed.
     ?_assertEqual({error, protocol_error},
                   parse_content_length([{<<"content-length">>, <<"1">>},
                                         {<<"content-length">>, <<"2">>}])),
     %% Non-numeric.
     ?_assertEqual({error, protocol_error},
                   parse_content_length([{<<"content-length">>, <<"abc">>}])),
     %% Negative.
     ?_assertEqual({error, protocol_error},
                   parse_content_length([{<<"content-length">>, <<"-1">>}]))].

header_value_validation_test_() ->
    [?_assertEqual({error, protocol_error},
                   check_lowercase_names([{<<"x">>, <<"a", 0, "b">>}])),
     ?_assertEqual({error, protocol_error},
                   check_lowercase_names([{<<"x">>, <<"a\nb">>}])),
     ?_assertEqual({error, protocol_error},
                   check_lowercase_names([{<<"x">>, <<"a\rb">>}])),
     ?_assertEqual({error, protocol_error},
                   check_lowercase_names([{<<>>, <<"v">>}])),
     ?_assertEqual(ok,
                   check_lowercase_names([{<<"x">>, <<"ok">>}]))].

extract_request_headers_test_() ->
    Req = [{<<":method">>, <<"GET">>},
           {<<":scheme">>, <<"https">>},
           {<<":authority">>, <<"example.com:443">>},
           {<<":path">>, <<"/index">>},
           {<<":protocol">>, <<"websocket">>},
           {<<"accept">>, <<"text/html">>}],
    {Method, Path, Other} = extract_request_headers(Req),
    [%% :method and :path become separate fields.
     ?_assertEqual(<<"GET">>, Method),
     ?_assertEqual(<<"/index">>, Path),
     %% :authority/:scheme/:protocol survive for adapters.
     ?_assertEqual(<<"example.com:443">>, proplists:get_value(<<":authority">>, Other)),
     ?_assertEqual(<<"https">>, proplists:get_value(<<":scheme">>, Other)),
     ?_assertEqual(<<"websocket">>, proplists:get_value(<<":protocol">>, Other)),
     %% :method/:path are stripped from the header list.
     ?_assertEqual(undefined, proplists:get_value(<<":method">>, Other)),
     ?_assertEqual(undefined, proplists:get_value(<<":path">>, Other)),
     %% Regular headers pass through.
     ?_assertEqual(<<"text/html">>, proplists:get_value(<<"accept">>, Other)),
     %% Defaults when :method/:path absent.
     ?_assertEqual({<<"GET">>, <<"/">>, []}, extract_request_headers([]))].
-endif.
