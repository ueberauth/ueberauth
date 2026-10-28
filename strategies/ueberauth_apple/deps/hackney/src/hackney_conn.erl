%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024 Benoit Chesneau
%%%
%%% @doc gen_statem process for managing a single HTTP connection.
%%%
%%% This module implements a state machine for HTTP connections,
%%% handling connection establishment, request/response cycles,
%%% and connection reuse.
%%%
%%% States:
%%% - idle: Process started, not connected
%%% - connecting: TCP/SSL handshake in progress
%%% - connected: Ready for requests
%%% - sending: Sending request data
%%% - receiving: Awaiting/streaming response
%%% - closed: Connection terminated

-module(hackney_conn).
-behaviour(gen_statem).

%% API
-export([
    start_link/1,
    stop/1,
    stop/2,
    connect/1,
    connect/2,
    get_state/1,
    get_state/2,
    %% Request/Response (sync)
    request/5,
    request/6,
    request/7,
    request_streaming/5,
    body/1,
    body/2,
    stream_body/1,
    %% Streaming body (request body)
    send_request_headers/4,
    send_request_headers/5,
    send_body_chunk/2,
    finish_send_body/1,
    start_response/1,
    %% HTTP/2 bidirectional stream (handler-routed, for hackney_h2_stream)
    open_h2_stream/6,
    %% Async streaming
    request_async/6,
    request_async/7,
    request_async/8,
    request_async/9,
    stream_next/1,
    stop_async/1,
    pause_stream/1,
    resume_stream/1,
    %% Socket operations
    setopts/2,
    peername/1,
    peercert/1,
    sockname/1,
    %% Low-level socket operations (for hackney_request/hackney_response)
    send/2,
    recv/2,
    recv/3,
    close/1,
    %% Response info
    response_headers/1,
    get_location/1,
    set_location/2,
    %% Pool management
    release_to_pool/1,
    hold/1,
    release_held/1,
    verify_socket/1,
    is_ready/1,
    is_ready/2,
    %% SSL upgrade
    upgrade_to_ssl/2,
    upgrade_to_ssl/3,
    is_upgraded_ssl/1,
    %% Reuse control
    is_no_reuse/1,
    checkin_info/1,
    checkin_info/2,
    %% Owner management
    set_owner/2,
    set_owner/3,
    set_owner_async/2,
    share_h2/1,
    %% Protocol info
    get_protocol/1
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
    connecting/3,
    connected/3,
    sending/3,
    streaming_body/3,
    receiving/3,
    streaming/3,
    streaming_once/3,
    closed/3
]).

-ifdef(TEST).
-export([h3_tls_opts/2]).
-endif.

-include("hackney.hrl").
-include("hackney_lib.hrl").

-define(CONNECT_TIMEOUT, 8000).
-define(IDLE_TIMEOUT, infinity).
%% How long an HTTP/2 request-body send may wait on flow control
%% (WINDOW_UPDATE) before failing with {error, timeout}. The atom nonblock
%% opts out of blocking: sends then fail fast with {error, send_buffer_full}
%% once the h2 per-stream buffer cap is hit.
-define(SEND_TIMEOUT, 30000).
%% HTTP/2 receive windows. The protocol default (65,535 bytes for each stream
%% and for the connection) allows one 64 KB window in flight per round trip,
%% so over a 120 ms link a large download outlasts the server's stream timeout.
%% 8 MB per stream and 32 MB for the connection bring a download over a 250 ms
%% link to HTTP/1.1 speed.
-define(H2_STREAM_WINDOW, 8 * 1024 * 1024).
-define(H2_CONN_WINDOW, 32 * 1024 * 1024).
%% Grace window for pooled hackney_conn in `closed` state, during which
%% late-arriving calls race the pool DOWN cleanup and still get a proper
%% error reply instead of exit:{normal, _}. See issue #836.
-define(CLOSED_GRACE_MS, 50).

%% HTTP/3 H3_REQUEST_CANCELLED (RFC 9114 8.1), used to reset refused streams.
-define(H3_REQUEST_CANCELLED, 16#10c).

%% A blocking HTTP/1.1 read is cut into slices this long; between slices the
%% conn checks whether its owner died, so a dead owner does not keep the
%% socket open until the response comes or recv_timeout expires.
-define(OWNER_CHECK_INTERVAL, 1000).
%% Cap on bytes buffered from an idle HTTP/1.1 connection via #544 {active,
%% once}. A well-behaved peer sends nothing while idle; the next response's
%% stranded prefix is small. Past this, treat the peer as misbehaving (flooding
%% an idle connection) and drop it rather than buffer unboundedly.
-define(MAX_IDLE_BUFFER, 65536).

%% State data record
-record(conn_data, {
    %% Connection owner
    owner :: pid() | undefined,
    owner_mon :: reference() | undefined,

    %% Connection identity
    host :: string(),
    port :: inet:port_number(),
    netloc :: binary() | undefined,
    transport :: module(),

    %% Socket state
    socket :: inet:socket() | ssl:sslsocket() | undefined,
    buffer = <<>> :: binary(),

    %% Options
    connect_timeout = ?CONNECT_TIMEOUT :: timeout(),
    recv_timeout = ?RECV_TIMEOUT :: timeout(),
    send_timeout = ?SEND_TIMEOUT :: timeout() | nonblock,
    %% Effective send_timeout for the streaming-body request in flight, set at
    %% every stream start (send_headers) so a per-request override never leaks
    %% into later requests. The connection-level default above is never
    %% mutated per-request.
    req_send_timeout :: timeout() | nonblock | undefined,
    idle_timeout = ?IDLE_TIMEOUT :: timeout(),
    connect_options = [] :: list(),
    ssl_options = [] :: list(),
    inform_fun :: fun((integer(), binary(), list()) -> any()) | undefined,
    auto_decompress = false :: boolean(),
    max_body_size = ?DEFAULT_MAX_BODY_SIZE :: non_neg_integer() | infinity,

    %% Pool integration
    pool_pid :: pid() | undefined,  %% If set, connection is from a pool

    %% Request tracking
    request_from :: {pid(), reference()} | undefined,
    method :: binary() | undefined,
    path :: binary() | undefined,
    %% Whether the current request carried Connection: close (the caller asked
    %% the server to close). Folded into the keepalive decision at checkin so a
    %% requested close is never reused. Reset on every request send.
    request_close = false :: boolean(),

    %% Response state
    version :: {integer(), integer()} | undefined,
    status :: integer() | undefined,
    reason :: binary() | undefined,
    response_headers :: term() | undefined,
    location :: binary() | undefined,  %% Stores the final URL after redirects

    %% Parser state
    parser :: #hparser{} | undefined,

    %% Async mode
    async = false :: false | true | once | paused,
    stream_to :: pid() | undefined,
    async_ref :: pid() | undefined,  %% Connection PID used as message correlation ref
    follow_redirect = false :: boolean(),

    %% SSL upgrade tracking - set when TCP connection is upgraded to SSL
    %% Upgraded connections are not returned to the pool unless pool_ssl is set
    upgraded_ssl = false :: boolean(),

    %% Set with upgraded_ssl when the caller opted into ssl_pooling, allowing
    %% the pool to keep the upgraded HTTPS/1.1 connection instead of closing it
    pool_ssl = false :: boolean(),

    %% No-reuse flag - set for connections that should never be pooled
    %% (e.g., SOCKS5 proxy connections which establish per-request tunnels)
    no_reuse = false :: boolean(),

    %% HTTP/2 support
    %% Protocol negotiated via ALPN (http1, http2, or http3)
    protocol = http1 :: http1 | http2 | http3,
    %% HTTP/2 connection pid (from h2 library)
    h2_conn :: pid() | undefined,
    %% Monitor ref for the h2_connection process so hackney_conn fails fast
    %% if the h2 lib crashes.
    h2_mon :: reference() | undefined,
    %% Map of active HTTP/2 streams: StreamId => {From, StreamState}
    %% StreamState (one-shot request/response):
    %%   {sync, waiting_headers}
    %%   {sync, body, Status, Headers, AccBody}
    %%   {async, AsyncMode, StreamTo, Ref, waiting_headers}
    %%   {async, AsyncMode, StreamTo, Ref, streaming, Status, Headers}
    %% StreamState (streaming body, body = stream):
    %%   {stream, sending}
    %%   {stream, waiting_headers, From}
    %%   {stream, headers, Status, Headers, Buffer, Pending}
    %%   {stream, body_full, Status, Headers, Acc, From}
    %%   {stream, done, Status, Headers, Buffer}
    %%   {stream, refused, ErrorCode}  (refused by a GOAWAY, caller not yet told)
    h2_streams = #{} :: #{pos_integer() => {term(), tuple()}},
    %% Shared through the pool (share_h2/1): no owner, each stream monitors
    %% its caller, and the connection closes itself once idle.
    h2_shared = false :: boolean(),
    %% Error code of a GOAWAY that left accepted streams to finish. While set,
    %% new requests are refused and the connection closes when the last
    %% stream ends.
    h2_goaway :: atom() | undefined,
    %% Per-stream caller monitors of a shared connection: StreamId => ref
    h2_stream_monitors = #{} :: #{pos_integer() => reference()},
    %% Current HTTP/2 stream ID for streaming body mode (body = stream)
    h2_stream_id :: pos_integer() | undefined,
    %% Per-stream recv_timeout watchdog timers (sync one-shot reads):
    %% StreamId => timer ref. Fires {timeout, TRef, {h2_recv_timeout, StreamId}}
    %% if no progress within recv_timeout, so a lost frame fails fast instead of
    %% blocking until the connection dies. Re-armed on each DATA frame.
    h2_timers = #{} :: #{pos_integer() => reference()},

    %% HTTP/3 support (QUIC)
    %% HTTP/3 connection reference from hackney_h3
    h3_conn :: reference() | undefined,
    %% Map of active HTTP/3 streams: StreamId => {From, StreamState}
    h3_streams = #{} :: #{non_neg_integer() => {gen_statem:from() | pid(), atom() | tuple()}},
    %% Current HTTP/3 stream ID for streaming body mode
    h3_stream_id :: non_neg_integer() | undefined,
    %% Stream ID of a GOAWAY that left accepted streams to finish. While set,
    %% new requests are refused and the connection closes when the last
    %% stream ends.
    h3_goaway :: non_neg_integer() | undefined,
    %% Whether to try HTTP/3 (requires UDP)
    try_http3 = false :: boolean(),
    %% Pool name + handler module, so the connection can cache the H3
    %% 0-RTT/resumption session ticket it receives.
    pool_name = default :: term(),
    pool_handler :: module() | undefined,
    %% Last H3 session ticket delivered by hackney_h3 (opaque term).
    h3_session_ticket :: term() | undefined,
    %% A pooled HTTP/1.1 conn goes back to the pool once its response is
    %% read. false while a hackney:connect/* caller holds it (hold/1).
    auto_release = true :: boolean()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a connection process.
%% Options:
%%   - host: Target host (string)
%%   - port: Target port (integer)
%%   - transport: hackney_tcp or hackney_ssl
%%   - connect_timeout: Connection timeout (default 8000ms)
%%   - recv_timeout: Receive timeout (default 5000ms)
%%   - idle_timeout: Idle timeout before closing (default infinity)
%%   - connect_options: Options passed to transport connect
%%   - ssl_options: Additional SSL options
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, [self(), Opts], []).

%% @doc Stop the connection process.
%% Returns ok even if the process has already terminated.
-spec stop(pid()) -> ok.
stop(Pid) ->
    stop(Pid, infinity).

%% @doc Stop the connection process, waiting at most `Timeout' for it.
%% A connection wedged inside a transport call (a dial that outlived its
%% timeout, a socket that never answers) cannot handle a stop request; it is
%% killed rather than left holding the caller, which for pool checkouts is the
%% pool gen_server itself.
%% Returns ok even if the process has already terminated.
-spec stop(pid(), timeout()) -> ok.
stop(Pid, Timeout) ->
    try
        gen_statem:stop(Pid, normal, Timeout)
    catch
        exit:noproc -> ok;
        exit:{noproc, _} -> ok;
        exit:normal -> ok;
        exit:{normal, _} -> ok;
        exit:timeout -> kill(Pid);
        exit:{timeout, _} -> kill(Pid)
    end.

kill(Pid) ->
    exit(Pid, kill),
    ok.

%% @doc Connect to the target host. Blocks until connected or timeout.
-spec connect(pid()) -> ok | {error, term()}.
connect(Pid) ->
    connect(Pid, ?CONNECT_TIMEOUT).

%% A dial that outlives `Timeout', or a connection that dies while dialing,
%% is an error for the caller, not an exit: the caller stops the conn on any
%% error return.
-spec connect(pid(), timeout()) -> ok | {error, term()}.
connect(Pid, Timeout) ->
    try gen_statem:call(Pid, connect, Timeout)
    catch
        exit:{timeout, _} -> {error, connect_timeout};
        exit:{Reason, {gen_statem, call, _}} -> {error, Reason};
        exit:Reason -> {error, Reason}
    end.

%% @doc Get current state name for debugging.
-spec get_state(pid()) -> {ok, atom()} | {error, term()}.
get_state(Pid) ->
    get_state(Pid, 5000).

%% @doc Get current state name, waiting at most `Timeout'. Callers that probe
%% a connection they do not own (the pool, deciding whether to hand it out)
%% pass a short timeout: a connection that cannot answer promptly is unusable
%% to them, and waiting on it blocks everything behind them.
-spec get_state(pid(), timeout()) -> {ok, atom()} | {error, term()}.
get_state(Pid, Timeout) ->
    gen_statem:call(Pid, get_state, Timeout).

%% @doc Send an HTTP request and wait for the response status and headers.
%% Returns {ok, Status, Headers} for HTTP/1.1 or {ok, Status, Headers, Body} for HTTP/2.
%% For HTTP/1.1, use body/1 or stream_body/1 to get the response body.
-spec request(pid(), binary(), binary(), list(), binary() | iolist()) ->
    {ok, integer(), list()} | {ok, integer(), list(), binary()} | {error, term()}.
request(Pid, Method, Path, Headers, Body) ->
    request(Pid, Method, Path, Headers, Body, infinity, []).

-spec request(pid(), binary(), binary(), list(), binary() | iolist(), timeout()) ->
    {ok, integer(), list()} | {ok, integer(), list(), binary()} | {error, term()}.
request(Pid, Method, Path, Headers, Body, Timeout) ->
    request(Pid, Method, Path, Headers, Body, Timeout, []).

%% @doc Make an HTTP request with additional request options.
%% Options:
%%   - inform_fun: fun(Status, Reason, Headers) - callback for 1xx responses
-spec request(pid(), binary(), binary(), list(), binary() | iolist(), timeout(), list()) ->
    {ok, integer(), list()} | {ok, integer(), list(), binary()} | {error, term()}.
request(Pid, Method, Path, Headers, Body, Timeout, ReqOpts) ->
    case valid_request_line(Method, Path) of
        ok -> safe_call(Pid, {request, Method, Path, Headers, Body, ReqOpts}, Timeout);
        Err -> Err
    end.

%% @private gen_statem:call that converts a callee which has already stopped,
%% or stops while the call is in flight, into `{error, closed}' instead of
%% letting `exit:{normal, _}' / `exit:noproc' reach the caller. A pooled
%% connection can stop between checkout and the call (issue #861); the brief
%% linger in the `closed' state narrows the window but cannot close it. Other
%% exits (e.g. timeout) propagate unchanged.
safe_call(Pid, Msg) ->
    safe_call(Pid, Msg, infinity).

safe_call(Pid, Msg, Timeout) ->
    try
        gen_statem:call(Pid, Msg, Timeout)
    catch
        exit:noproc -> {error, closed};
        exit:{noproc, _} -> {error, closed};
        exit:normal -> {error, closed};
        exit:{normal, _} -> {error, closed};
        exit:shutdown -> {error, closed};
        exit:{shutdown, _} -> {error, closed}
    end.

%% @private GHSA-j9wq: the request target (path + query) is written verbatim
%% into the HTTP/1.1 request line and the HTTP/2 / HTTP/3 :path pseudo-header.
%% Raw CR, LF or NUL bytes let a caller-controlled URL inject extra header
%% lines or split the request. RFC 3986 requires those bytes to be
%% percent-encoded; reject them rather than emit a malformed request.
valid_request_target(Path) when is_binary(Path) ->
    case binary:match(Path, [<<"\r">>, <<"\n">>, <<0>>]) of
        nomatch -> ok;
        _ -> {error, {invalid_request_target, Path}}
    end;
valid_request_target(Path) when is_list(Path) ->
    valid_request_target(iolist_to_binary(Path));
valid_request_target(_) ->
    ok.

%% @private Validate both the method and the request target before they are
%% serialized into the request line. The method sits on the same line as the
%% path, so a caller-influenced method carrying CR/LF/NUL could inject headers
%% or split the request just as a bad path could.
valid_request_line(Method, Path) ->
    case valid_method(Method) of
        ok -> valid_request_target(Path);
        Error -> Error
    end.

valid_method(Method) ->
    case binary:match(hackney_bstr:to_binary(Method), [<<"\r">>, <<"\n">>, <<0>>]) of
        nomatch -> ok;
        _ -> {error, {invalid_method, Method}}
    end.

%% @doc Send an HTTP/3 request and return headers immediately.
%% Returns {ok, Status, Headers} and allows subsequent stream_body/1 calls.
%% This is for pull-based body streaming over HTTP/3.
%% The HTTP/2 path answers `{ok, Status, Headers, pid()}', like
%% start_response/1; the others answer `{ok, Status, Headers}'.
-spec request_streaming(pid(), binary(), binary(), list(), binary() | iolist()) ->
    {ok, integer(), list()} | {ok, integer(), list(), pid()} | {error, term()}.
request_streaming(Pid, Method, Path, Headers, Body) ->
    case valid_request_line(Method, Path) of
        ok -> safe_call(Pid, {request_streaming, Method, Path, Headers, Body}, infinity);
        Err -> Err
    end.

%% @doc Send only the request headers (for streaming body mode).
%% After this, use send_body_chunk/2 and finish_send_body/1 to send the body,
%% then start_response/1 to receive the response.
-spec send_request_headers(pid(), binary(), binary(), list()) -> ok | {error, term()}.
send_request_headers(Pid, Method, Path, Headers) ->
    send_request_headers(Pid, Method, Path, Headers, []).

%% @doc Like send_request_headers/4 with per-request options. Currently only
%% send_timeout is used (HTTP/2 flow-control deadline for the body chunks).
-spec send_request_headers(pid(), binary(), binary(), list(), list()) -> ok | {error, term()}.
send_request_headers(Pid, Method, Path, Headers, ReqOpts) ->
    case valid_request_line(Method, Path) of
        ok -> safe_call(Pid, {send_headers, Method, Path, Headers, ReqOpts}, infinity);
        Err -> Err
    end.

%% @doc Send a chunk of the request body.
-spec send_body_chunk(pid(), iodata()) -> ok | {error, term()}.
send_body_chunk(Pid, Data) ->
    safe_call(Pid, {send_body_chunk, Data}, infinity).

%% @doc Finish sending the request body.
-spec finish_send_body(pid()) -> ok | {error, term()}.
finish_send_body(Pid) ->
    safe_call(Pid, finish_send_body, infinity).

%% @doc Start receiving the response after sending the full body.
-spec start_response(pid()) -> {ok, integer(), list(), pid()} | {error, term()}.
start_response(Pid) ->
    safe_call(Pid, start_response, infinity).

%% @doc Open an HTTP/2 stream whose events are routed to HandlerPid (the gRPC
%% bidi model), returning the underlying h2_connection pid and stream id so the
%% handler can drive send_data/send_trailers/consume directly. Used by
%% hackney_h2_stream; the stream is not tracked in this gen_statem.
-spec open_h2_stream(pid(), binary(), binary(), list(), pid(), map()) ->
    {ok, pid(), pos_integer()} | {error, term()}.
open_h2_stream(Pid, Method, Path, Headers, HandlerPid, Opts) ->
    case valid_request_line(Method, Path) of
        ok -> safe_call(Pid, {open_h2_stream, Method, Path, Headers, HandlerPid, Opts}, infinity);
        Err -> Err
    end.

%% @doc Get the full response body.
-spec body(pid()) -> {ok, binary()} | {error, term()}.
body(Pid) ->
    body(Pid, infinity).

-spec body(pid(), timeout()) -> {ok, binary()} | {error, term()}.
body(Pid, Timeout) ->
    safe_call(Pid, body, Timeout).

%% @doc Stream the response body in chunks.
%% Returns {ok, Data} for each chunk, {done, Pid} when complete.
-spec stream_body(pid()) -> {ok, binary()} | done | {error, term()}.
stream_body(Pid) ->
    safe_call(Pid, stream_body).

%% @doc Send an HTTP request asynchronously.
%% Returns {ok, Ref} immediately. Response is sent as messages:
%%   - {hackney_response, Ref, {status, Status, Reason}}
%%   - {hackney_response, Ref, {headers, Headers}}
%%   - {hackney_response, Ref, Data} (body chunks)
%%   - {hackney_response, Ref, done}
%%   - {hackney_response, Ref, {error, Reason}}
%% When follow_redirect is true and response is a redirect:
%%   - {hackney_response, Ref, {redirect, Location, Headers}} for 301,302,307,308
%%   - {hackney_response, Ref, {see_other, Location, Headers}} for 303 with POST
%% AsyncMode: true (continuous) or once (one message at a time, use stream_next/1)
-spec request_async(pid(), binary(), binary(), list(), binary() | iolist(), true | once) ->
    {ok, pid()} | {error, term()}.
request_async(Pid, Method, Path, Headers, Body, AsyncMode) ->
    request_async(Pid, Method, Path, Headers, Body, AsyncMode, self(), false).

-spec request_async(pid(), binary(), binary(), list(), binary() | iolist(), true | once, pid()) ->
    {ok, pid()} | {error, term()}.
request_async(Pid, Method, Path, Headers, Body, AsyncMode, StreamTo) ->
    request_async(Pid, Method, Path, Headers, Body, AsyncMode, StreamTo, false).

-spec request_async(pid(), binary(), binary(), list(), binary() | iolist(), true | once, pid(), boolean()) ->
    {ok, pid()} | {error, term()}.
request_async(Pid, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect) ->
    case valid_request_line(Method, Path) of
        ok -> safe_call(Pid, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect});
        Err -> Err
    end.

-spec request_async(pid(), binary(), binary(), list(), binary() | iolist(), true | once, pid(), boolean(), list()) ->
    {ok, pid()} | {error, term()}.
request_async(Pid, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, ReqOpts) ->
    case valid_request_line(Method, Path) of
        ok -> safe_call(Pid, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, ReqOpts});
        Err -> Err
    end.

%% @doc Request the next message in {async, once} mode. The caller pid rides
%% along so a shared HTTP/2 connection can route the pull to the right stream.
-spec stream_next(pid()) -> ok | {error, term()}.
stream_next(Pid) ->
    gen_statem:cast(Pid, {stream_next, self()}).

%% @doc Stop async mode and return to sync mode.
-spec stop_async(pid()) -> ok | {error, term()}.
stop_async(Pid) ->
    gen_statem:call(Pid, stop_async).

%% @doc Pause async streaming (hibernate the stream).
-spec pause_stream(pid()) -> ok | {error, term()}.
pause_stream(Pid) ->
    gen_statem:cast(Pid, pause_stream).

%% @doc Resume paused async streaming.
-spec resume_stream(pid()) -> ok | {error, term()}.
resume_stream(Pid) ->
    gen_statem:cast(Pid, resume_stream).

%% @doc Set socket options on the underlying socket.
-spec setopts(pid(), list()) -> ok | {error, term()}.
setopts(Pid, Opts) ->
    gen_statem:call(Pid, {setopts, Opts}).

%% @doc Get the remote address and port.
-spec peername(pid()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(Pid) ->
    gen_statem:call(Pid, peername).

%% @doc Get the peer SSL certificate.
%% Returns {ok, Cert} where Cert is the DER-encoded certificate binary,
%% or {error, Reason} if the connection is not SSL or the certificate is unavailable.
-spec peercert(pid()) -> {ok, binary()} | {error, term()}.
peercert(Pid) ->
    gen_statem:call(Pid, peercert).

%% @doc Get the local address and port.
-spec sockname(pid()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(Pid) ->
    gen_statem:call(Pid, sockname).

%% @doc Get the last response headers.
-spec response_headers(pid()) -> list() | undefined.
response_headers(Pid) ->
    gen_statem:call(Pid, response_headers).

%% @doc Get the stored location (final URL after redirects).
-spec get_location(pid()) -> binary() | undefined.
get_location(Pid) ->
    case safe_call(Pid, get_location) of
        {error, closed} -> undefined;
        Location -> Location
    end.

%% @doc Set the location (used after following redirects).
-spec set_location(pid(), binary()) -> ok | {error, closed}.
set_location(Pid, Location) ->
    safe_call(Pid, {set_location, Location}).

%% @doc Send data through the connection process.
%% This is a low-level function used by hackney_request.
-spec send(pid(), iodata()) -> ok | {error, term()}.
send(Pid, Data) ->
    gen_statem:call(Pid, {send, Data}).

%% @doc Receive data from the connection process.
%% This is a low-level function used by hackney_response.
-spec recv(pid(), timeout()) -> {ok, binary()} | {error, term()}.
recv(Pid, Timeout) ->
    recv(Pid, 0, Timeout).

-spec recv(pid(), non_neg_integer(), timeout()) -> {ok, binary()} | {error, term()}.
recv(Pid, Length, Timeout) ->
    gen_statem:call(Pid, {recv, Length, Timeout}, Timeout + 5000).

%% @doc Close the connection.
%% This is a low-level function that closes the socket but keeps the process.
-spec close(pid()) -> ok.
close(Pid) ->
    gen_statem:call(Pid, close_socket).

%% @doc Release the connection back to the pool.
%% This notifies the pool that the connection is available for reuse.
%% Uses a synchronous call to ensure the pool has processed the checkin.
-spec release_to_pool(pid()) -> ok.
release_to_pool(Pid) ->
    gen_statem:call(Pid, release_to_pool, 5000).

%% @doc Keep a pooled HTTP/1.1 connection with its owner between requests.
%% It is not handed back to the pool after each response; release_held/1
%% does that. Used by hackney:connect/*, whose caller reuses the connection.
%% No effect on an unpooled or multiplexed connection.
-spec hold(pid()) -> ok | {error, term()}.
hold(Pid) ->
    try gen_statem:call(Pid, hold, 5000)
    catch exit:_ -> {error, closed}
    end.

%% @doc Give up the caller's hold on a pooled connection. A held HTTP/1.1
%% connection goes back to its pool. On a shared HTTP/2 connection only the
%% caller's own streams are reset: the connection stays up for the other
%% callers and closes itself once idle with no stream open. Returns an error
%% for any other connection, which the caller then stops.
-spec release_held(pid()) -> ok | {error, term()}.
release_held(Pid) ->
    try gen_statem:call(Pid, release_held, 5000)
    catch exit:_ -> {error, closed}
    end.

%% @doc Set a new owner for this connection (sync).
%% This updates the process being monitored - if the new owner crashes,
%% the connection will terminate. Used by the pool when checking out
%% a connection to a new requester.
-spec set_owner(pid(), pid()) -> ok | {error, closed | invalid_state}.
set_owner(Pid, NewOwner) ->
    set_owner(Pid, NewOwner, 5000).

%% @doc Set a new owner, waiting at most `Timeout'. @see get_state/2
-spec set_owner(pid(), pid(), timeout()) -> ok | {error, closed | invalid_state}.
set_owner(Pid, NewOwner, Timeout) ->
    gen_statem:call(Pid, {set_owner, NewOwner}, Timeout).

%% @doc Set a new owner for this connection (async).
%% Same as set_owner/2 but non-blocking. Used when the caller cannot
%% block (e.g., during pool checkin to avoid deadlock).
-spec set_owner_async(pid(), pid()) -> ok.
set_owner_async(Pid, NewOwner) ->
    gen_statem:cast(Pid, {set_owner, NewOwner}).

%% @doc Share a pooled HTTP/2 connection between callers.
%% The connection stops monitoring its owner, so the caller that dialed it
%% can exit without tearing down other callers' streams. Each stream is tied
%% to its own caller instead, and the connection closes itself after
%% `idle_timeout' with no stream open. Only pooled connections can be shared.
-spec share_h2(pid()) -> ok | {error, term()}.
share_h2(Pid) ->
    safe_call(Pid, share_h2, 5000).

%% @doc Check if the connection's socket is still healthy.
%% Returns ok if socket is open, {error, closed} otherwise.
-spec verify_socket(pid()) -> ok | {error, closed | term()}.
verify_socket(Pid) ->
    gen_statem:call(Pid, verify_socket).

%% @doc Check if the connection is ready for a new request.
%% Returns {ok, connected} if ready, or error/closed status.
%% This combines state check and socket verification in one call.
-spec is_ready(pid()) -> {ok, connected} | {ok, closed} | {error, term()}.
is_ready(Pid) ->
    is_ready(Pid, 5000).

%% @doc Check socket health, waiting at most `Timeout'. @see get_state/2
-spec is_ready(pid(), timeout()) -> {ok, connected} | {ok, closed} | {error, term()}.
is_ready(Pid, Timeout) ->
    gen_statem:call(Pid, is_ready, Timeout).

%% @doc Upgrade a TCP connection to SSL.
%% This performs an SSL handshake on the existing TCP socket.
%% After upgrade, the connection is marked as upgraded_ssl and should
%% NOT be returned to the pool (SSL connections are not pooled for security).
-spec upgrade_to_ssl(pid(), list()) -> ok | {error, term()}.
upgrade_to_ssl(Pid, SslOpts) ->
    upgrade_to_ssl(Pid, SslOpts, #{final => false}).

%% @doc Upgrade a TCP connection to SSL with explicit upgrade options.
%% With `#{final => true}' SslOpts is handed to `ssl:connect/2' as-is
%% (the caller computed it via hackney_ssl:effective_opts/3); the default
%% `#{final => false}' keeps the legacy behavior of merging defaults and
%% ALPN options inside the connection process. `#{pool_ssl => true}' marks
%% the upgraded connection as poolable again (ssl_pooling opt-in).
-spec upgrade_to_ssl(pid(), list(), map()) -> ok | {error, term()}.
upgrade_to_ssl(Pid, SslOpts, UpgradeOpts) when is_map(UpgradeOpts) ->
    gen_statem:call(Pid, {upgrade_to_ssl, SslOpts, UpgradeOpts}, infinity).

%% @doc Check if this connection was upgraded from TCP to SSL.
%% Upgraded connections should be closed after use, not returned to pool.
-spec is_upgraded_ssl(pid()) -> boolean().
is_upgraded_ssl(Pid) ->
    gen_statem:call(Pid, is_upgraded_ssl).

%% @doc Check if this connection should not be reused/pooled.
%% SOCKS5 proxy connections set this flag since each establishes a unique tunnel.
-spec is_no_reuse(pid()) -> boolean().
is_no_reuse(Pid) ->
    gen_statem:call(Pid, is_no_reuse).

%% @doc Get the flags the pool needs for its checkin decision in one call:
%% whether the connection was SSL upgraded, opted into SSL pooling, must not
%% be reused (proxy tunnels), the negotiated protocol, whether the response
%% requires the connection to close (keepalive), and whether the socket is
%% proven ready to pool.
-spec checkin_info(pid()) -> #{upgraded_ssl := boolean(), no_reuse := boolean(),
                               pool_ssl := boolean(), protocol := atom(),
                               should_close := boolean(), ready := boolean()}.
checkin_info(Pid) ->
    checkin_info(Pid, 5000).

%% @doc Checkin flags, waiting at most `Timeout'. @see get_state/2
-spec checkin_info(pid(), timeout()) -> map().
checkin_info(Pid, Timeout) ->
    gen_statem:call(Pid, checkin_info, Timeout).

%% @doc Get the negotiated protocol for this connection.
%% Returns http1, http2, or http3 based on ALPN negotiation (SSL connections),
%% QUIC (HTTP/3), or http1 for plain TCP connections.
-spec get_protocol(pid()) -> http1 | http2 | http3.
get_protocol(Pid) ->
    gen_statem:call(Pid, get_protocol).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

callback_mode() -> [state_functions, state_enter].

init([DefaultOwner, Opts]) ->
    process_flag(trap_exit, true),
    %% Use owner from opts if provided (e.g., from pool), otherwise use default
    Owner = maps:get(owner, Opts, DefaultOwner),
    OwnerMon = monitor(process, Owner),

    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts, 80),
    Transport = maps:get(transport, Opts, hackney_tcp),

    %% Compute netloc for Host header
    Netloc = compute_netloc(Host, Port, Transport),

    %% Check if a pre-established socket is provided (e.g., from proxy)
    Socket = maps:get(socket, Opts, undefined),

    Data = #conn_data{
        owner = Owner,
        owner_mon = OwnerMon,
        host = Host,
        port = Port,
        netloc = Netloc,
        transport = Transport,
        socket = Socket,
        connect_timeout = maps:get(connect_timeout, Opts, ?CONNECT_TIMEOUT),
        recv_timeout = maps:get(recv_timeout, Opts, ?RECV_TIMEOUT),
        send_timeout = maps:get(send_timeout, Opts, ?SEND_TIMEOUT),
        idle_timeout = maps:get(idle_timeout, Opts, ?IDLE_TIMEOUT),
        connect_options = maps:get(connect_options, Opts, []),
        ssl_options = maps:get(ssl_options, Opts, []),
        pool_pid = maps:get(pool_pid, Opts, undefined),
        pool_name = maps:get(pool_name, Opts, default),
        pool_handler = maps:get(pool_handler, Opts, undefined),
        no_reuse = maps:get(no_reuse, Opts, false),
        inform_fun = maps:get(inform_fun, Opts, undefined),
        auto_decompress = maps:get(auto_decompress, Opts, false)
    },

    %% If socket is provided, start in connected state; otherwise start in idle
    case Socket of
        undefined ->
            {ok, idle, Data};
        _ ->
            {ok, connected, Data}
    end.

terminate(_Reason, _State, #conn_data{socket = Socket, transport = Transport,
                                      h2_conn = H2Conn, h2_mon = H2Mon,
                                      h3_conn = H3Conn}) ->
    %% Close HTTP/2 connection (owns its socket)
    case H2Conn of
        undefined -> ok;
        _ ->
            case H2Mon of
                undefined -> ok;
                _ -> erlang:demonitor(H2Mon, [flush])
            end,
            close_h2(H2Conn)
    end,
    %% Close HTTP/3 connection if present
    case H3Conn of
        undefined -> ok;
        _ -> hackney_h3:close(H3Conn)
    end,
    %% Close socket (only still owned by us for HTTP/1.1; h2 lib closes its own)
    case {Socket, H2Conn} of
        {undefined, _} -> ok;
        {_, undefined} -> close_on_terminate(Transport, Socket);
        _ -> ok
    end,
    ok.

%% ssl:close/1 sends close_notify, then waits up to 5 s for the server to close
%% the TCP connection (ssl:close/2 ignores its timeout on an established
%% connection): at least one round trip. The pool stops a conn with a 100 ms
%% budget and kills it past that, which logged a supervisor report for every
%% pooled TLS conn closed over a slow link. The conn reads nothing more, so
%% shutdown/2 sends close_notify and closes both directions, and close/1 then
%% returns without waiting.
close_on_terminate(hackney_ssl, Socket) ->
    _ = hackney_ssl:shutdown(Socket, read_write),
    _ = hackney_ssl:close(Socket),
    ok;
close_on_terminate(Transport, Socket) ->
    Transport:close(Socket).

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%====================================================================
%% State: idle - Not connected yet
%%====================================================================

idle(enter, _OldState, _Data) ->
    keep_state_and_data;

idle({call, From}, connect, Data) ->
    %% Perform connection synchronously
    #conn_data{
        host = Host,
        port = Port,
        transport = Transport,
        connect_timeout = Timeout,
        connect_options = ConnectOpts,
        ssl_options = SslOpts,
        try_http3 = TryHttp3
    } = Data,

    %% Check if we should try HTTP/3 first (SSL transport + http3 in protocols)
    Protocols = proplists:get_value(protocols, ConnectOpts, hackney_util:default_protocols()),
    ShouldTryHttp3 = TryHttp3 orelse (Transport =:= hackney_ssl andalso lists:member(http3, Protocols)),

    case ShouldTryHttp3 of
        true ->
            %% Try HTTP/3 first
            case try_h3_connect(Host, Port, Timeout, ConnectOpts, SslOpts) of
                {ok, H3Conn} ->
                    NewData = Data#conn_data{
                        h3_conn = H3Conn,
                        protocol = http3
                    },
                    {next_state, connected, NewData, [{reply, From, ok}]};
                {error, _H3Reason} ->
                    %% HTTP/3 failed, fall back to TCP/TLS
                    do_tcp_connect(From, Data)
            end;
        false ->
            %% Standard TCP/TLS connection
            do_tcp_connect(From, Data)
    end;

idle({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, idle}}]};

idle(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    %% Owner died
    {stop, normal, Data};

idle(EventType, Event, Data) ->
    handle_common(EventType, Event, idle, Data).

%%====================================================================
%% State: connecting - TCP/SSL handshake in progress
%%====================================================================

connecting(enter, _OldState, _Data) ->
    keep_state_and_data;

connecting(state_timeout, connect_timeout, Data) ->
    reply_and_stop(Data#conn_data.request_from, {error, connect_timeout}, Data);

connecting({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, connecting}}]};

connecting(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

connecting(EventType, Event, Data) ->
    handle_common(EventType, Event, connecting, Data).

%%====================================================================
%% State: connected - Ready for requests
%%====================================================================

connected(enter, OldState, #conn_data{transport = Transport, socket = Socket,
                                       idle_timeout = Timeout, pool_pid = PoolPid} = Data) ->
    %% Set socket to active mode to receive server close notifications (tcp_closed/ssl_closed)
    %% This fixes issue #544: stale connections not being detected when server closes idle connections
    %% Only enable active mode when returning from a completed request cycle (receiving, streaming states)
    %% NOT on initial connection from 'connecting' state - server might send data before we send request
    _ = case {Socket, should_enable_active_mode(OldState)} of
        {undefined, _} -> ok;
        {_, false} -> ok;
        {_, true} -> Transport:setopts(Socket, [{active, once}])
    end,
    %% Auto-release to pool when body reading is complete
    %% This happens when transitioning from receiving state (body fully read)
    Data2 = case {PoolPid, should_auto_release(OldState)} of
        {undefined, _} ->
            Data;
        {_, false} ->
            Data;
        {_, true} when not Data#conn_data.auto_release ->
            %% Held by a hackney:connect/* caller until release_held/1.
            Data;
        {_, true} ->
            %% Transfer ownership back to pool and notify it
            auto_release_to_pool(Data)
    end,
    case {Timeout, Data2#conn_data.protocol} of
        {infinity, _} -> {keep_state, Data2};
        %% HTTP/2 multiplexes: the connection idles when its last stream ends,
        %% not when it enters `connected' (#836).
        {_, http2} -> {keep_state, Data2, h2_idle_actions(Data2)};
        _ -> {keep_state, Data2, [{state_timeout, Timeout, idle_timeout}]}
    end;

connected({call, From}, share_h2, #conn_data{h2_shared = true}) ->
    {keep_state_and_data, [{reply, From, ok}]};

connected({call, From}, share_h2, #conn_data{protocol = http2, pool_pid = PoolPid,
                                             owner_mon = OwnerMon} = Data)
  when is_pid(PoolPid) ->
    %% The dialing caller no longer owns the connection: its exit must not
    %% close streams other callers opened. Streams opened from now on monitor
    %% their own caller, and the pool releases the per-host slot when the
    %% connection stops.
    demonitor(OwnerMon, [flush]),
    Data2 = Data#conn_data{owner = undefined, owner_mon = undefined,
                           h2_shared = true},
    {keep_state, Data2, [{reply, From, ok} | h2_idle_actions(Data2)]};

connected({call, From}, hold, #conn_data{pool_pid = PoolPid, protocol = http1} = Data)
  when is_pid(PoolPid) ->
    {keep_state, Data#conn_data{auto_release = false}, [{reply, From, ok}]};

connected({call, From}, hold, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

connected({call, {Caller, _} = From}, release_held,
          #conn_data{h2_shared = true, h2_streams = Streams} = Data) ->
    Mine = [StreamId || {StreamId, {Owner, _}} <- maps:to_list(Streams),
                        h2_stream_owner_pid(Owner) =:= Caller],
    Data1 = lists:foldl(
              fun(StreamId, D) ->
                      _ = cancel_h2_stream(D#conn_data.h2_conn, StreamId),
                      drop_h2_stream(StreamId, D)
              end, Data, Mine),
    h2_stream_result(Data1, [{reply, From, ok}]);

connected({call, From}, release_held, #conn_data{pool_pid = PoolPid, auto_release = false} = Data)
  when is_pid(PoolPid) ->
    connected({call, From}, release_to_pool, Data#conn_data{auto_release = true});

connected({call, From}, release_to_pool, #conn_data{pool_pid = PoolPid, owner_mon = OldMon,
                                                    transport = Transport, socket = Socket} = Data) ->
    %% Reset owner to pool before notifying, to avoid deadlock
    %% (pool might call set_owner back, but connection is blocked here)
    Data2 = case PoolPid of
        undefined ->
            Data;
        _ ->
            demonitor(OldMon, [flush]),
            NewMon = monitor(process, PoolPid),
            Data#conn_data{owner = PoolPid, owner_mon = NewMon}
    end,
    %% Enable active mode for close detection now that connection is idle in pool
    %% This fixes issue #544: detect server-initiated closes while idle
    _ = case Socket of
        undefined -> ok;
        _ -> Transport:setopts(Socket, [{active, once}])
    end,
    %% Notify pool that connection is available for reuse (sync)
    notify_pool_available_sync(Data2),
    {keep_state, Data2, [{reply, From, ok}]};

connected({call, From}, {set_owner, _NewOwner}, #conn_data{h2_shared = true}) ->
    %% A shared connection has no owner to hand over.
    {keep_state_and_data, [{reply, From, ok}]};

connected(cast, {set_owner, _NewOwner}, #conn_data{h2_shared = true}) ->
    keep_state_and_data;

connected({call, From}, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon} = Data) ->
    %% Update owner - demonitor old, monitor new
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon},
     [{reply, From, ok}]};

connected(cast, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon, pool_pid = PoolPid,
                                                  transport = Transport, socket = Socket} = Data) ->
    %% Async owner update - used by pool during checkin to avoid deadlock
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    %% If new owner is the pool, connection is becoming idle - enable active mode for close detection
    %% This fixes issue #544: detect server-initiated closes while idle in pool
    _ = case {NewOwner, PoolPid, Socket} of
        {PoolPid, PoolPid, Socket} when PoolPid =/= undefined, Socket =/= undefined ->
            Transport:setopts(Socket, [{active, once}]);
        _ ->
            ok
    end,
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon}};

connected(state_timeout, idle_timeout, Data) ->
    %% Idle timeout - close connection
    {next_state, closed, Data};

connected({call, From}, get_state, #conn_data{h3_goaway = GoawayId})
  when GoawayId =/= undefined ->
    {keep_state_and_data, [{reply, From, {ok, draining}}]};
connected({call, From}, get_state, #conn_data{h2_goaway = ErrorCode})
  when ErrorCode =/= undefined ->
    %% Draining after a GOAWAY: still serving its accepted streams, but the
    %% pool and request/5 must not pick it, as they would a closed one.
    {keep_state_and_data, [{reply, From, {ok, draining}}]};
connected({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, connected}}]};

connected({call, From}, verify_socket, #conn_data{socket = undefined} = Data) ->
    %% Socket not connected
    {next_state, closed, Data, [{reply, From, {error, closed}}]};
connected({call, From}, verify_socket, #conn_data{transport = Transport, socket = Socket} = Data) ->
    %% Check if socket has any pending data or close messages
    case check_socket_health(Transport, Socket) of
        ok -> {keep_state_and_data, [{reply, From, ok}]};
        {error, Reason} ->
            {next_state, closed, Data#conn_data{socket = undefined}, [{reply, From, {error, Reason}}]}
    end;

connected({call, From}, is_ready, #conn_data{socket = undefined} = Data) ->
    %% Socket not connected
    {next_state, closed, Data, [{reply, From, {ok, closed}}]};
connected({call, From}, is_ready, #conn_data{transport = Transport, socket = Socket,
                                             buffer = Buffer} = Data) ->
    %% Stop active-mode delivery before reconciling the socket for checkout, so
    %% no further {tcp,_}/{ssl,_} messages can land after we inspect it.
    _ = Transport:setopts(Socket, [{active, false}]),
    case has_pending_close(Socket) of
        true ->
            %% #544: the server closed the idle connection - never reuse it.
            {next_state, closed, Data#conn_data{socket = undefined},
             [{reply, From, {ok, closed}}]};
        false ->
            case check_socket_health(Transport, Socket) of
                ok ->
                    %% Bytes delivered to the mailbox while idle in {active, once}
                    %% are the start of the response; keep them in the read buffer
                    %% so the next request consumes them instead of stranding them.
                    Drained = drain_socket_data(Socket),
                    %% This conn is on its way to a requester, so it is not idle
                    %% any more: disarm the keepalive timer armed by
                    %% connected(enter). It has been running since before this
                    %% probe and would otherwise still fire, closing the conn under
                    %% the request about to arrive. Re-armed on release.
                    {keep_state,
                     Data#conn_data{buffer = <<Buffer/binary, Drained/binary>>},
                     [{state_timeout, infinity, idle_timeout},
                      {reply, From, {ok, connected}}]};
                {error, _} ->
                    {keep_state_and_data, [{reply, From, {ok, closed}}]}
            end
    end;

connected({call, From}, {upgrade_to_ssl, _SslOpts, _UpgradeOpts}, #conn_data{transport = hackney_ssl} = _Data) ->
    %% Already SSL - no upgrade needed
    {keep_state_and_data, [{reply, From, ok}]};
connected({call, From}, {upgrade_to_ssl, SslOpts, UpgradeOpts}, #conn_data{socket = Socket, host = Host, connect_options = ConnectOpts, connect_timeout = HandshakeTimeout} = Data) ->
    %% Upgrade TCP socket to SSL (e.g., after CONNECT proxy tunnel)
    FinalSslOpts = case maps:get(final, UpgradeOpts, false) of
        true ->
            %% Caller computed the exact handshake options with
            %% hackney_ssl:effective_opts/3; use them as-is so the pool
            %% tls_key hash matches what the handshake actually used.
            SslOpts;
        false ->
            %% Use ssl_opts/2 to properly merge defaults with user options
            %% (handles cacertfile vs cacerts correctly)
            MergedSslOpts = hackney_ssl:ssl_opts(Host, [{ssl_options, SslOpts}]),
            %% Add ALPN options for HTTP/2 negotiation
            %% Check both SslOpts (from upgrade call) and ConnectOpts (from initial config)
            AlpnOpts = case hackney_ssl:alpn_opts(SslOpts) of
                [] -> hackney_ssl:alpn_opts(ConnectOpts);
                Opts -> Opts
            end,
            hackney_util:merge_opts(MergedSslOpts, AlpnOpts)
    end,
    %% Gate TLS resumption on the ALPN memo and snapshot the cached protocol, so a
    %% resumed session (where ssl reports no ALPN) resolves against this snapshot.
    %% Resumable: only the resumption-eligible config (session_tickets enabled)
    %% updates the memo, so a custom-ssl_options handshake cannot poison it.
    AlpnProtos = alpn_advertised(FinalSslOpts),
    Resumable = hackney_ssl:auto_tickets(FinalSslOpts),
    Cached = hackney_ssl:recall_alpn(Host, AlpnProtos),
    GatedSslOpts = gate_resumption(FinalSslOpts, Cached),
    %% Bound the pooled TLS upgrade handshake with the connection's
    %% connect_timeout. ssl:connect/2 has no handshake deadline, so a server
    %% that stalls after TCP accept would pin this process and its pool slot
    %% indefinitely, past connect_timeout/recv_timeout.
    case ssl:connect(Socket, GatedSslOpts, HandshakeTimeout) of
        {ok, SslSocket} ->
            %% Detect negotiated protocol, carrying ALPN across resumption
            Protocol = hackney_ssl:negotiated_protocol(SslSocket, Host, AlpnProtos, Cached, Resumable),
            %% Update connection to use SSL
            NewData = Data#conn_data{
                transport = hackney_ssl,
                socket = SslSocket,
                upgraded_ssl = true,  % Mark as upgraded - pooled again only with pool_ssl
                pool_ssl = maps:get(pool_ssl, UpgradeOpts, false),
                protocol = Protocol
            },
            %% Initialize HTTP/2 if negotiated
            case Protocol of
                http2 ->
                    init_h2_after_upgrade(SslSocket, NewData, From);
                http1 ->
                    {keep_state, NewData, [{reply, From, ok}]}
            end;
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;

connected({call, From}, is_upgraded_ssl, #conn_data{upgraded_ssl = Upgraded}) ->
    {keep_state_and_data, [{reply, From, Upgraded}]};

connected({call, From}, is_no_reuse, #conn_data{no_reuse = NoReuse}) ->
    {keep_state_and_data, [{reply, From, NoReuse}]};

connected({call, From}, checkin_info, Data) ->
    %% In connected state: prove the socket is ready before the pool may keep it.
    Map = (checkin_info_map(Data))#{ready => socket_ready(Data)},
    {keep_state_and_data, [{reply, From, Map}]};

connected({call, From}, {request, Method, Path, Headers, Body, ReqOpts}, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 request - use h2_machine (1xx not applicable for HTTP/2)
    %% Allow recv_timeout to be overridden per-request (fix for issue #832)
    RecvTimeout = proplists:get_value(recv_timeout, ReqOpts, Data#conn_data.recv_timeout),
    %% send_timeout is passed along, never stored: a per-request override must
    %% not leak into later requests on a pooled connection.
    SendTimeout = proplists:get_value(send_timeout, ReqOpts, Data#conn_data.send_timeout),
    NewData = Data#conn_data{recv_timeout = RecvTimeout,
                             max_body_size = max_body_size(ReqOpts)},
    do_h2_request(From, Method, Path, Headers, Body, SendTimeout, NewData);

connected({call, From}, {request, Method, Path, Headers, Body, ReqOpts}, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 request - use hackney_h3 (1xx not applicable for HTTP/3)
    %% Allow recv_timeout to be overridden per-request (fix for issue #832)
    RecvTimeout = proplists:get_value(recv_timeout, ReqOpts, Data#conn_data.recv_timeout),
    NewData = Data#conn_data{recv_timeout = RecvTimeout,
                             max_body_size = max_body_size(ReqOpts)},
    do_h3_request(From, Method, Path, Headers, Body, NewData);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo}, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 async request
    do_h2_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, false,
                        Data#conn_data.send_timeout, Data);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect}, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 async request with redirect option
    do_h2_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect,
                        Data#conn_data.send_timeout, Data);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo}, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 async request
    do_h3_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, Data);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, _FollowRedirect}, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 async request (redirect not yet implemented for H3)
    do_h3_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, Data);

connected({call, From}, {request_streaming, Method, Path, Headers, Body}, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 request with streaming body reads (returns headers, then stream_body for chunks)
    do_h3_request_streaming(From, Method, Path, Headers, Body,
                            Data#conn_data{max_body_size = ?DEFAULT_MAX_BODY_SIZE});

connected({call, From}, {request_streaming, Method, Path, Headers, Body}, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2: reply with status and headers, leave the body for
    %% stream_body/1 or body/1, like the HTTP/3 clause above.
    do_h2_send(From, Method, Path, Headers, Body, {stream, waiting_headers, From},
               sync, Data#conn_data.send_timeout,
               Data#conn_data{max_body_size = ?DEFAULT_MAX_BODY_SIZE});

connected({call, From}, {request_streaming, Method, Path, Headers, Body}, _Data) ->
    %% HTTP/1.1 leaves the body on the connection anyway, so this is the
    %% plain request path.
    {keep_state_and_data,
     [{next_event, {call, From}, {request, Method, Path, Headers, Body, []}}]};

connected({call, From}, {request, Method, Path, Headers, Body, ReqOpts}, Data) ->
    %% HTTP/1.1 request
    InformFun = proplists:get_value(inform_fun, ReqOpts, undefined),
    AutoDecompress = proplists:get_value(auto_decompress, ReqOpts, false),
    %% Allow recv_timeout to be overridden per-request (fix for issue #832)
    RecvTimeout = proplists:get_value(recv_timeout, ReqOpts, Data#conn_data.recv_timeout),
    NewData = Data#conn_data{
        request_from = From,
        method = Method,
        path = Path,
        parser = undefined,
        version = undefined,
        status = undefined,
        reason = undefined,
        response_headers = undefined,
        %% NOTE: buffer is intentionally preserved (not reset to <<>>). It is
        %% empty after any complete response, but may hold response bytes that
        %% #544 {active, once} stranded into the mailbox and connected(info,...)
        %% buffered; the next request must consume them.
        async = false,
        async_ref = undefined,
        stream_to = undefined,
        inform_fun = InformFun,
        auto_decompress = AutoDecompress,
        max_body_size = max_body_size(ReqOpts),
        recv_timeout = RecvTimeout
    },
    {next_state, sending, NewData, [{next_event, internal, {send_request, Method, Path, Headers, Body}}]};

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo}, Data) ->
    %% Start a new async request (no redirect following)
    do_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, false, Data);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect}, Data) ->
    %% Start a new async request with redirect option (HTTP/1.1)
    do_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, Data);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, ReqOpts}, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 async request with ReqOpts (fix for issue #832)
    RecvTimeout = proplists:get_value(recv_timeout, ReqOpts, Data#conn_data.recv_timeout),
    %% send_timeout passed along, never stored (no leak across pooled requests)
    SendTimeout = proplists:get_value(send_timeout, ReqOpts, Data#conn_data.send_timeout),
    NewData = Data#conn_data{recv_timeout = RecvTimeout},
    do_h2_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, SendTimeout, NewData);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, _FollowRedirect, ReqOpts}, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 async request with ReqOpts (fix for issue #832, redirect not yet implemented for H3)
    RecvTimeout = proplists:get_value(recv_timeout, ReqOpts, Data#conn_data.recv_timeout),
    NewData = Data#conn_data{recv_timeout = RecvTimeout},
    do_h3_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, NewData);

connected({call, From}, {request_async, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, ReqOpts}, Data) ->
    %% HTTP/1.1 async request with ReqOpts (fix for issue #832)
    RecvTimeout = proplists:get_value(recv_timeout, ReqOpts, Data#conn_data.recv_timeout),
    NewData = Data#conn_data{recv_timeout = RecvTimeout},
    do_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, NewData);

connected({call, From}, {send_headers, Method, Path, Headers, ReqOpts}, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 streaming body - send headers only via QUIC
    do_h3_send_headers(From, Method, Path, Headers,
                       Data#conn_data{max_body_size = max_body_size(ReqOpts)});

connected({call, From}, {send_headers, Method, Path, Headers, ReqOpts}, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 streaming body - send headers without END_STREAM, then accept body
    %% chunks via send_body_chunk/finish_send_body. Mirrors do_h3_send_headers/5.
    do_h2_send_headers(From, Method, Path, Headers, ReqOpts,
                       Data#conn_data{max_body_size = max_body_size(ReqOpts)});

connected({call, From}, {open_h2_stream, Method, Path, Headers, HandlerPid, Opts},
          #conn_data{protocol = http2, h2_conn = H2Conn} = Data) ->
    %% Open a stream routed to HandlerPid (gRPC bidi). The handler owns the
    %% stream end to end; we do not track it in h2_streams. Returns the
    %% h2_connection pid + stream id so the handler drives it directly.
    {_, _, H2Headers} = build_h2_request_headers(Method, Path, Headers, Data),
    FlowControl = maps:get(flow_control, Opts, auto),
    StreamOpts = #{handler => HandlerPid, flow_control => FlowControl},
    Reply = try
        case h2_connection:send_request_headers(H2Conn, H2Headers, false, StreamOpts) of
            {ok, StreamId} -> {ok, H2Conn, StreamId};
            {error, _} = E -> E
        end
    catch
        exit:{ExitReason, _} -> {error, {closed, ExitReason}};
        exit:ExitReason      -> {error, {closed, ExitReason}}
    end,
    {keep_state_and_data, [{reply, From, Reply}]};

connected({call, From}, {send_headers, Method, Path, Headers, ReqOpts}, Data) ->
    %% Send only headers for streaming body mode (HTTP/1.1)
    NewData = Data#conn_data{
        request_from = From,
        method = Method,
        path = Path,
        parser = undefined,
        version = undefined,
        status = undefined,
        reason = undefined,
        response_headers = undefined,
        %% buffer preserved (see the {request,...} handler): may hold stranded
        %% response bytes buffered from #544 {active, once}.
        async = false,
        async_ref = undefined,
        stream_to = undefined,
        max_body_size = max_body_size(ReqOpts)
    },
    %% Transition to streaming_body state
    {next_state, streaming_body, NewData, [{next_event, internal, {send_headers_only, Method, Path, Headers}}]};

%% {async, once} pull for an HTTP/2 stream. The h1 pulls are handled in the
%% streaming_once state; on a connected h2 conn the pull routes to the
%% caller's once-mode stream. The bare atom is the pre-upgrade message form.
connected(cast, {stream_next, Caller}, Data) ->
    handle_h2_stream_next(Caller, Data);
connected(cast, stream_next, Data) ->
    handle_h2_stream_next(undefined, Data);

%% HTTP/2 owner messages from h2 library
connected(info, {h2, H2Conn, Event}, #conn_data{h2_conn = H2Conn} = Data) ->
    handle_h2_event(Event, Data);
%% HTTP/2 per-stream recv_timeout watchdog (see arm_h2_timer/2).
connected(info, {timeout, TRef, {h2_recv_timeout, StreamId}}, Data) ->
    handle_h2_recv_timeout(StreamId, TRef, Data);
%% h2_connection is linked via start_link; trap_exit surfaces its termination
%% as an 'EXIT' signal. Convert to the same cleanup path as the monitor DOWN.
connected(info, {'EXIT', H2Conn, Reason}, #conn_data{h2_conn = H2Conn} = Data) ->
    h2_on_closed(Reason, Data#conn_data{h2_conn = undefined, h2_mon = undefined});
connected(info, {'DOWN', Mon, process, _Pid, Reason},
          #conn_data{h2_mon = Mon} = Data) ->
    h2_on_closed(Reason, Data#conn_data{h2_conn = undefined, h2_mon = undefined});

connected(info, {tcp_closed, Socket}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

connected(info, {ssl_closed, Socket}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

connected(info, {tcp_error, Socket, _Reason}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

connected(info, {ssl_error, Socket, _Reason}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

%% Unexpected data received while idle - HTTP/1.1 only (H/2 socket is owned
%% by h2_connection; H/3 uses QUIC messages).
%% Bytes delivered by #544 {active, once} while idle are the start of the next
%% response on a reused connection. Buffer them (do NOT treat as a broken
%% connection) and re-arm close detection, so the next request consumes them.
connected(info, {tcp, Socket, Data}, #conn_data{socket = Socket} = D) ->
    buffer_idle_data(Data, D);
connected(info, {ssl, Socket, Data}, #conn_data{socket = Socket} = D) ->
    buffer_idle_data(Data, D);

%% HTTP/3 message handling
connected(info, {h3, ConnRef, {stream_headers, StreamId, Headers, Fin}},
          #conn_data{h3_conn = ConnRef, h3_streams = Streams} = Data) ->
    h3_drain_result(handle_h3_headers(StreamId, Headers, Fin, Streams, Data));

connected(info, {h3, ConnRef, {stream_data, StreamId, RecvData, Fin}},
          #conn_data{h3_conn = ConnRef, h3_streams = Streams} = Data) ->
    h3_drain_result(handle_h3_data(StreamId, RecvData, Fin, Streams, Data));

connected(info, {h3, ConnRef, {stream_reset, StreamId, ErrorCode}},
          #conn_data{h3_conn = ConnRef, h3_streams = Streams} = Data) ->
    h3_drain_result(handle_h3_stream_reset(StreamId, ErrorCode, Streams, Data));

connected(info, {h3, ConnRef, {goaway, GoawayId}}, #conn_data{h3_conn = ConnRef} = Data) ->
    h3_on_goaway(GoawayId, connected, Data);

connected(info, {h3, ConnRef, {closed, Reason}},
          #conn_data{h3_conn = ConnRef} = Data) ->
    %% HTTP/3 connection closed
    handle_h3_conn_closed(Reason, Data);

connected(info, {h3, ConnRef, {transport_error, Code, Msg}},
          #conn_data{h3_conn = ConnRef} = Data) ->
    %% QUIC transport error
    handle_h3_error({transport_error, Code, Msg}, Data);

%% QUIC socket ready - drive event loop
connected(info, {select, _Resource, _Ref, ready_input},
          #conn_data{h3_conn = ConnRef}) when ConnRef =/= undefined ->
    _ = hackney_h3:process(ConnRef),
    keep_state_and_data;

connected(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

%% HTTP/3 stream_body call - returns buffered chunk or waits for data
connected({call, From}, stream_body, #conn_data{protocol = http3, h3_streams = Streams} = Data) ->
    h3_drain_result(handle_h3_stream_body(From, Streams, Data));

%% HTTP/2 streaming-body response reads (after start_response/1).
connected({call, From}, stream_body, #conn_data{protocol = http2} = Data) ->
    handle_h2_stream_body(From, Data);

connected({call, From}, body, #conn_data{protocol = http2} = Data) ->
    handle_h2_read_body(From, Data);

connected({call, From}, body, #conn_data{protocol = http3, h3_streams = Streams} = Data) ->
    h3_drain_result(handle_h3_read_body(From, Streams, Data));

connected(EventType, Event, Data) ->
    handle_common(EventType, Event, connected, Data).

%%====================================================================
%% State: sending - Sending request data
%%====================================================================

sending(enter, connected, #conn_data{transport = Transport, socket = Socket,
                                     buffer = Buffer} = Data) ->
    %% Deterministically leave {active, once} before sending the request, and
    %% drain any bytes already delivered to the mailbox into the read buffer so
    %% the request/response cycle never runs with stranded data (the reuse hang).
    %% Note: socket may be undefined for HTTP/3 (QUIC) connections.
    case Socket of
        undefined ->
            keep_state_and_data;
        _ ->
            _ = Transport:setopts(Socket, [{active, false}]),
            Drained = drain_socket_data(Socket),
            {keep_state, Data#conn_data{buffer = <<Buffer/binary, Drained/binary>>}}
    end;

sending(internal, {send_request, Method, Path, Headers, Body}, Data) ->
    case do_send_request(Method, Path, Headers, Body, Data) of
        {ok, NewData} ->
            {next_state, receiving, NewData, [{next_event, internal, do_recv_response}]};
        {error, Reason} ->
            {next_state, closed, Data, [{reply, Data#conn_data.request_from, {error, Reason}}]}
    end;

sending(internal, {send_request_async, Method, Path, Headers, Body}, Data) ->
    case do_send_request(Method, Path, Headers, Body, Data) of
        {ok, NewData} ->
            %% Reply with ref immediately, then start async receiving
            From = NewData#conn_data.request_from,
            Ref = NewData#conn_data.async_ref,
            {next_state, receiving, NewData#conn_data{request_from = undefined},
             [{reply, From, {ok, Ref}}, {next_event, internal, do_recv_response_async}]};
        {error, Reason} ->
            From = Data#conn_data.request_from,
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

sending({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, sending}}]};

sending(info, {tcp_closed, Socket}, #conn_data{socket = Socket, request_from = From} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}, [{reply, From, {error, closed}}]};

sending(info, {ssl_closed, Socket}, #conn_data{socket = Socket, request_from = From} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}, [{reply, From, {error, closed}}]};

sending(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

sending(EventType, Event, Data) ->
    handle_common(EventType, Event, sending, Data).

%%====================================================================
%% State: streaming_body - Streaming request body
%%====================================================================

streaming_body(enter, connected, #conn_data{protocol = http2}) ->
    %% HTTP/2: the h2_connection process owns the socket and reads it in active
    %% mode. hackney_conn must NOT flip it to passive or the h2 lib stops
    %% receiving frames (the response would never arrive).
    keep_state_and_data;
streaming_body(enter, connected, #conn_data{transport = Transport, socket = Socket,
                                            buffer = Buffer} = Data) ->
    %% Same as sending(enter): go passive and un-strand any mailbox bytes before
    %% the request/response cycle (socket may be undefined for HTTP/3 QUIC).
    case Socket of
        undefined ->
            keep_state_and_data;
        _ ->
            _ = Transport:setopts(Socket, [{active, false}]),
            Drained = drain_socket_data(Socket),
            {keep_state, Data#conn_data{buffer = <<Buffer/binary, Drained/binary>>}}
    end;

streaming_body(internal, {send_headers_only, Method, Path, Headers}, Data) ->
    %% Send only headers, then return ok and wait for body chunks
    #conn_data{host = _Host, port = _Port, transport = Transport, socket = Socket} = Data,
    %% Build request line and headers (with Transfer-Encoding: chunked for streaming)
    HeadersObj = hackney_headers:from_list(Headers),
    %% Add Transfer-Encoding: chunked if not present
    HeadersWithTE = case hackney_headers:get_value(<<"transfer-encoding">>, HeadersObj) of
        undefined -> hackney_headers:store(<<"Transfer-Encoding">>, <<"chunked">>, HeadersObj);
        _ -> HeadersObj
    end,
    RequestLine = build_request_line(Method, Path),
    %% Serialize through to_iolist/1 so header values are CR/LF sanitized like
    %% the buffered path; the raw to_list/1 concatenation used before let a
    %% header value carry its own CRLF and inject extra lines. to_iolist/1
    %% already appends the terminating blank line.
    HeaderBlock = hackney_headers:to_iolist(HeadersWithTE),
    HeadersData = [RequestLine, HeaderBlock],
    %% Record whether the caller asked the server to close (the request line is
    %% built here, not via do_send_request/5), for the keepalive decision.
    RequestClose = hackney_keepalive:request_closes(HeadersWithTE),
    case Transport:send(Socket, HeadersData) of
        ok ->
            From = Data#conn_data.request_from,
            {keep_state, Data#conn_data{request_from = undefined,
                                        request_close = RequestClose},
             [{reply, From, ok}]};
        {error, Reason} ->
            From = Data#conn_data.request_from,
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

%% A GOAWAY refused this upload between two of its caller's calls (see
%% h3_on_goaway/3): its next call is the first chance to tell it.
streaming_body({call, From}, Req, #conn_data{protocol = http3, h3_stream_id = StreamId,
                                             h3_streams = Streams} = Data)
  when (Req =:= finish_send_body orelse Req =:= start_response orelse
        element(1, Req) =:= send_body_chunk),
       is_map_key(StreamId, Streams),
       element(2, map_get(StreamId, Streams)) =:= refused ->
    Data1 = Data#conn_data{h3_streams = maps:remove(StreamId, Streams),
                           h3_stream_id = undefined, request_from = undefined},
    Reply = {reply, From, {error, {goaway, no_error}}},
    case h3_drain_result({keep_state, Data1, [Reply]}) of
        {keep_state, Data2, Actions} -> {next_state, connected, Data2, Actions};
        Closed -> Closed
    end;

streaming_body({call, From}, {send_body_chunk, BodyData}, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 - send body chunk via QUIC
    #conn_data{h3_conn = ConnRef, h3_stream_id = StreamId} = Data,
    Result = case BodyData of
        Fun when is_function(Fun, 0) ->
            stream_body_fun_h3(ConnRef, StreamId, Fun);
        {Fun, State} when is_function(Fun, 1) ->
            stream_body_fun_h3(ConnRef, StreamId, {Fun, State});
        _ ->
            hackney_h3:send_body_chunk(ConnRef, StreamId, iolist_to_binary(BodyData), false)
    end,
    case Result of
        ok ->
            {keep_state_and_data, [{reply, From, ok}]};
        {error, Reason} ->
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

%% A GOAWAY refused this upload between two of its caller's calls (see
%% h2_on_goaway/3): its next call is the first chance to tell it.
streaming_body({call, From}, Req, #conn_data{protocol = http2, h2_stream_id = StreamId,
                                             h2_streams = Streams} = Data)
  when (Req =:= finish_send_body orelse Req =:= start_response orelse
        element(1, Req) =:= send_body_chunk),
       is_map_key(StreamId, Streams),
       element(1, element(2, map_get(StreamId, Streams))) =:= stream,
       element(2, element(2, map_get(StreamId, Streams))) =:= refused ->
    {_, {stream, refused, ErrorCode}} = maps:get(StreamId, Streams),
    h2_upload_done(drop_h2_stream(StreamId, Data),
                   [{reply, From, {error, {goaway, ErrorCode}}}]);

streaming_body({call, From}, {send_body_chunk, BodyData}, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 - send a DATA frame without END_STREAM.
    #conn_data{h2_conn = H2Conn, h2_stream_id = StreamId,
               req_send_timeout = SendTimeout} = Data,
    Result = case BodyData of
        Fun when is_function(Fun, 0) ->
            stream_body_fun_h2(H2Conn, StreamId, Fun, SendTimeout);
        {Fun, State} when is_function(Fun, 1) ->
            stream_body_fun_h2(H2Conn, StreamId, {Fun, State}, SendTimeout);
        _ ->
            h2_send_data(H2Conn, StreamId, iolist_to_binary(BodyData), false,
                         SendTimeout)
    end,
    case Result of
        ok ->
            {keep_state_and_data, [{reply, From, ok}]};
        {error, Reason} ->
            h2_upload_failed(From, Reason, Data)
    end;

streaming_body({call, From}, {send_body_chunk, BodyData}, Data) ->
    #conn_data{transport = Transport, socket = Socket} = Data,
    %% Send as chunked encoding (HTTP/1.1)
    Result = case BodyData of
        Fun when is_function(Fun, 0) ->
            stream_body_fun(Transport, Socket, Fun);
        {Fun, State} when is_function(Fun, 1) ->
            stream_body_fun(Transport, Socket, {Fun, State});
        _ ->
            Transport:send(Socket, encode_chunk(BodyData))
    end,
    case Result of
        ok ->
            {keep_state_and_data, [{reply, From, ok}]};
        {error, Reason} ->
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

streaming_body({call, From}, finish_send_body, #conn_data{protocol = http3} = Data) ->
    %% HTTP/3 - finish sending body (send empty data with Fin=true)
    #conn_data{h3_conn = ConnRef, h3_stream_id = StreamId, h3_streams = Streams} = Data,
    case hackney_h3:finish_send_body(ConnRef, StreamId, Streams) of
        {ok, _} ->
            {keep_state_and_data, [{reply, From, ok}]};
        {error, Reason} ->
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

streaming_body({call, From}, finish_send_body, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 - close the request stream with an empty END_STREAM DATA frame.
    #conn_data{h2_conn = H2Conn, h2_stream_id = StreamId,
               req_send_timeout = SendTimeout} = Data,
    case h2_send_data(H2Conn, StreamId, <<>>, true, SendTimeout) of
        ok ->
            {keep_state, Data, [{reply, From, ok}]};
        {error, Reason} ->
            h2_upload_failed(From, Reason, Data)
    end;

streaming_body({call, From}, finish_send_body, Data) ->
    #conn_data{transport = Transport, socket = Socket} = Data,
    %% Send final chunk marker (HTTP/1.1)
    case Transport:send(Socket, <<"0\r\n\r\n">>) of
        ok ->
            {keep_state, Data#conn_data{request_from = From}, [{reply, From, ok}]};
        {error, Reason} ->
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

streaming_body({call, From}, start_response, #conn_data{protocol = http2} = Data) ->
    %% HTTP/2 - move to connected and surface the response. If the response
    %% raced ahead of this call (headers already buffered) reply now; otherwise
    %% park the caller and let h2_on_response/4 reply when :status arrives.
    %% CancelIdle keeps the #836 invariant: h2 conns stay in connected and must
    %% not have the pool keepalive timer re-armed by connected(enter) here, or it
    %% would tear down a slow streaming response mid-flight.
    CancelIdle = {state_timeout, infinity, idle_timeout},
    #conn_data{h2_stream_id = StreamId, h2_streams = Streams} = Data,
    case maps:get(StreamId, Streams, undefined) of
        {_, {stream, headers, Status, Hdrs, _Buf, _}} ->
            {next_state, connected, Data, [CancelIdle, {reply, From, {ok, Status, Hdrs, self()}}]};
        {_, {stream, done, Status, Hdrs, _Buf}} ->
            {next_state, connected, Data, [CancelIdle, {reply, From, {ok, Status, Hdrs, self()}}]};
        {_, {stream, sending}} ->
            Streams2 = maps:put(StreamId, {From, {stream, waiting_headers, From}}, Streams),
            {next_state, connected, Data#conn_data{h2_streams = Streams2}, [CancelIdle]};
        _ ->
            {next_state, connected, Data, [CancelIdle, {reply, From, {error, no_stream}}]}
    end;

streaming_body({call, From}, start_response,
               #conn_data{protocol = http3, h3_stream_id = StreamId,
                          h3_streams = Streams} = Data) ->
    %% HTTP/3 - the response headers may already be in; otherwise park the
    %% caller until handle_h3_headers/5 answers it.
    case maps:get(StreamId, Streams, undefined) of
        {_, {sending_body, _}} ->
            {next_state, connected, Data#conn_data{request_from = From}};
        {_, _Response} ->
            #conn_data{status = Status, response_headers = Headers} = Data,
            {next_state, connected, Data,
             [{reply, From, {ok, Status, Headers, self()}}]};
        undefined ->
            {next_state, connected, Data, [{reply, From, {error, no_stream}}]}
    end;

streaming_body({call, From}, start_response, Data) ->
    %% Transition to receiving state and get response (HTTP/1.1)
    %% Use {do_recv_response, include_pid} to include pid in response
    NewData = Data#conn_data{request_from = From},
    {next_state, receiving, NewData, [{next_event, internal, {do_recv_response, include_pid}}]};

streaming_body({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, streaming_body}}]};

streaming_body(info, {tcp_closed, Socket}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming_body(info, {ssl_closed, Socket}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

%% HTTP/2 message handling while still sending the request body. The server can
%% respond early (e.g. an error); buffer it via handle_h2_event so start_response
%% can surface it. Mirrors the connected-state h2 handlers.
streaming_body(info, {h2, H2Conn, Event}, #conn_data{h2_conn = H2Conn} = Data) ->
    handle_h2_event(Event, Data);
streaming_body(info, {timeout, TRef, {h2_recv_timeout, StreamId}}, Data) ->
    handle_h2_recv_timeout(StreamId, TRef, Data);
streaming_body(info, {'EXIT', H2Conn, Reason}, #conn_data{h2_conn = H2Conn} = Data) ->
    h2_on_closed(Reason, Data#conn_data{h2_conn = undefined, h2_mon = undefined});
streaming_body(info, {'DOWN', Mon, process, _Pid, Reason}, #conn_data{h2_mon = Mon} = Data) ->
    h2_on_closed(Reason, Data#conn_data{h2_conn = undefined, h2_mon = undefined});

%% HTTP/3 message handling in streaming_body state
streaming_body(info, {h3, ConnRef, {stream_headers, StreamId, Headers, Fin}},
               #conn_data{h3_conn = ConnRef, h3_streams = Streams} = Data) ->
    %% Early response headers while still sending body
    h3_drain_result(handle_h3_headers(StreamId, Headers, Fin, Streams, Data));

streaming_body(info, {h3, ConnRef, {stream_data, StreamId, RecvData, Fin}},
               #conn_data{h3_conn = ConnRef, h3_streams = Streams} = Data) ->
    h3_drain_result(handle_h3_data(StreamId, RecvData, Fin, Streams, Data));

streaming_body(info, {h3, ConnRef, {stream_reset, StreamId, ErrorCode}},
               #conn_data{h3_conn = ConnRef, h3_streams = Streams} = Data) ->
    h3_drain_result(handle_h3_stream_reset(StreamId, ErrorCode, Streams, Data));

streaming_body(info, {h3, ConnRef, {goaway, GoawayId}}, #conn_data{h3_conn = ConnRef} = Data) ->
    h3_on_goaway(GoawayId, streaming_body, Data);

streaming_body(info, {h3, ConnRef, {closed, Reason}},
               #conn_data{h3_conn = ConnRef} = Data) ->
    handle_h3_conn_closed(Reason, Data);

streaming_body(info, {h3, ConnRef, {transport_error, Code, Msg}},
               #conn_data{h3_conn = ConnRef} = Data) ->
    handle_h3_error({transport_error, Code, Msg}, Data);

%% QUIC socket ready - drive event loop
streaming_body(info, {select, _Resource, _Ref, ready_input},
               #conn_data{h3_conn = ConnRef}) when ConnRef =/= undefined ->
    _ = hackney_h3:process(ConnRef),
    keep_state_and_data;

streaming_body(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

streaming_body({call, From}, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon} = Data) ->
    %% Hand over mid-upload: the new owner sends the rest of the body.
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon},
     [{reply, From, ok}]};
streaming_body(cast, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon} = Data) ->
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon}};

streaming_body(EventType, Event, Data) ->
    handle_common(EventType, Event, streaming_body, Data).

%%====================================================================
%% State: receiving - Awaiting/streaming response
%%====================================================================

receiving(enter, sending, _Data) ->
    %% Just enter state, request handling happens in internal event
    keep_state_and_data;

receiving(enter, streaming_body, _Data) ->
    %% Coming from streaming body state
    keep_state_and_data;

receiving(enter, receiving, _Data) ->
    %% Re-entering after body streaming
    keep_state_and_data;

receiving(internal, do_recv_response, Data) ->
    %% Receive and parse response status and headers (sync mode, no pid in response)
    do_recv_response_impl(Data, false);

receiving(internal, {do_recv_response, include_pid}, Data) ->
    %% Receive and parse response status and headers (sync mode, include pid in response)
    do_recv_response_impl(Data, true);

receiving(internal, do_recv_response_async, Data) ->
    %% Receive and parse response status and headers (async mode)
    Parser = hackney_http:parser([response]),
    DataWithParser = Data#conn_data{parser = Parser},
    #conn_data{async_ref = Ref, stream_to = StreamTo, async = AsyncMode,
               follow_redirect = FollowRedirect, method = Method} = Data,
    case recv_status_and_headers(DataWithParser) of
        {ok, Status, Headers, NewData} ->
            HeadersList = hackney_headers:to_list(Headers),
            maybe_record_altsvc(HeadersList, NewData),
            %% Check if this is a redirect and we should handle it
            case maybe_handle_async_redirect(Status, Method, Headers, FollowRedirect) of
                {redirect, Location} ->
                    %% Skip body and send redirect message
                    _ = skip_response_body(NewData),
                    StreamTo ! {hackney_response, Ref, {redirect, Location, HeadersList}},
                    notify_pool_available(NewData),
                    {next_state, connected, NewData#conn_data{response_headers = Headers}};
                {see_other, Location} ->
                    %% Skip body and send see_other message
                    _ = skip_response_body(NewData),
                    StreamTo ! {hackney_response, Ref, {see_other, Location, HeadersList}},
                    notify_pool_available(NewData),
                    {next_state, connected, NewData#conn_data{response_headers = Headers}};
                no_redirect ->
                    %% Normal response - send status and headers
                    StreamTo ! {hackney_response, Ref, {status, Status, NewData#conn_data.reason}},
                    StreamTo ! {hackney_response, Ref, {headers, HeadersList}},
                    %% Check if response has no body (204, 304, or HEAD request)
                    HasNoBody = (Status =:= 204) orelse (Status =:= 304) orelse (Method =:= <<"HEAD">>),
                    case HasNoBody of
                        true ->
                            %% No body - send done immediately
                            StreamTo ! {hackney_response, Ref, done},
                            notify_pool_available(NewData),
                            {next_state, connected, NewData#conn_data{response_headers = Headers,
                                                                       async = false, async_ref = undefined}};
                        false ->
                            %% Transition to appropriate streaming state based on mode
                            NextState = case AsyncMode of
                                true -> streaming;
                                once -> streaming_once
                            end,
                            {next_state, NextState, NewData#conn_data{response_headers = Headers}}
                    end
            end;
        {error, Reason} ->
            StreamTo ! {hackney_response, Ref, {error, Reason}},
            {next_state, closed, Data}
    end;

receiving({call, From}, body, Data) ->
    %% Read full body
    case read_full_body(Data, <<>>) of
        {ok, Body, #conn_data{socket = undefined} = NewData} ->
            %% Socket was closed during body read (e.g., no Content-Length)
            finish_dead_request(From, {ok, Body}, NewData);
        {ok, Body, NewData} ->
            %% Socket still valid - reuse it, or stop if not reusable.
            finish_sync_request(From, {ok, Body}, NewData);
        {error, Reason} ->
            finish_dead_request(From, {error, Reason}, Data)
    end;

receiving({call, From}, stream_body, Data) ->
    %% Stream body chunk
    case stream_body_chunk(Data) of
        {ok, Chunk, NewData} ->
            {keep_state, NewData, [{reply, From, {ok, Chunk}}]};
        {done, #conn_data{socket = undefined} = NewData} ->
            %% Socket was closed during body read
            finish_dead_request(From, done, NewData);
        {done, NewData} ->
            finish_sync_request(From, done, NewData);
        {error, Reason} ->
            finish_dead_request(From, {error, Reason}, Data)
    end;

receiving({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, receiving}}]};

receiving(info, {tcp_closed, Socket}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

receiving(info, {ssl_closed, Socket}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

receiving(info, {tcp_error, Socket, _Reason}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

receiving(info, {ssl_error, Socket, _Reason}, #conn_data{socket = Socket} = Data) ->
    {next_state, closed, Data#conn_data{socket = undefined}};

receiving(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

receiving({call, From}, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon} = Data) ->
    %% Reparent mid-stream: swap the monitored owner so the process reading the
    %% body can exit without stopping the connection. Socket/async state untouched.
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon},
     [{reply, From, ok}]};
receiving(cast, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon} = Data) ->
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon}};

receiving(EventType, Event, Data) ->
    handle_common(EventType, Event, receiving, Data).

%%====================================================================
%% State: streaming - Continuous async body streaming (async=true)
%%====================================================================

streaming(enter, receiving, Data) ->
    %% Start streaming immediately by sending self a cast
    gen_statem:cast(self(), do_stream),
    {keep_state, Data};

streaming(enter, streaming, _Data) ->
    keep_state_and_data;

streaming(cast, do_stream, Data) ->
    %% Stream body chunks continuously
    #conn_data{async_ref = Ref, stream_to = StreamTo} = Data,
    case stream_body_chunk(Data) of
        {ok, Chunk, NewData} ->
            StreamTo ! {hackney_response, Ref, Chunk},
            %% Continue streaming
            gen_statem:cast(self(), do_stream),
            {keep_state, NewData};
        {done, NewData} ->
            StreamTo ! {hackney_response, Ref, done},
            %% Check Connection: close header and pool status
            finish_async_streaming(NewData);
        {error, Reason} ->
            StreamTo ! {hackney_response, Ref, {error, Reason}},
            {next_state, closed, Data}
    end;

streaming(cast, pause_stream, Data) ->
    %% Pause - transition to streaming_once which waits for explicit next
    {next_state, streaming_once, Data};

streaming({call, From}, stop_async, Data) ->
    {next_state, receiving, reset_async(Data), [{reply, From, ok}]};

streaming({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, streaming}}]};

streaming(info, {tcp_closed, Socket}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, closed}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming(info, {ssl_closed, Socket}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, closed}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming(info, {tcp_error, Socket, Reason}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, Reason}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming(info, {ssl_error, Socket, Reason}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, Reason}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

streaming({call, From}, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon} = Data) ->
    %% Reparent the lifecycle monitor mid-stream. stream_to is left as-is, so the
    %% async message target does not change; only owner death handling moves.
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon},
     [{reply, From, ok}]};
streaming(cast, {set_owner, NewOwner}, #conn_data{owner_mon = OldMon} = Data) ->
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, NewOwner),
    {keep_state, Data#conn_data{owner = NewOwner, owner_mon = NewMon}};

streaming(EventType, Event, Data) ->
    handle_common(EventType, Event, streaming, Data).

%%====================================================================
%% State: streaming_once - On-demand async streaming (async=once)
%%====================================================================

streaming_once(enter, _OldState, _Data) ->
    %% Wait for stream_next
    keep_state_and_data;

streaming_once(cast, {stream_next, _Caller}, Data) ->
    streaming_once(cast, stream_next, Data);
streaming_once(cast, stream_next, Data) ->
    %% Stream one chunk (bare-atom form kept for pre-upgrade callers)
    #conn_data{async_ref = Ref, stream_to = StreamTo} = Data,
    case stream_body_chunk(Data) of
        {ok, Chunk, NewData} ->
            StreamTo ! {hackney_response, Ref, Chunk},
            {keep_state, NewData};
        {done, NewData} ->
            StreamTo ! {hackney_response, Ref, done},
            %% Check Connection: close header and pool status
            finish_async_streaming(NewData);
        {error, Reason} ->
            StreamTo ! {hackney_response, Ref, {error, Reason}},
            {next_state, closed, Data}
    end;

streaming_once(cast, resume_stream, Data) ->
    %% Switch to continuous mode
    {next_state, streaming, Data#conn_data{async = true}};

streaming_once({call, From}, stop_async, Data) ->
    {next_state, receiving, reset_async(Data), [{reply, From, ok}]};

streaming_once({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, streaming_once}}]};

streaming_once(info, {tcp_closed, Socket}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, closed}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming_once(info, {ssl_closed, Socket}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, closed}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming_once(info, {tcp_error, Socket, Reason}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, Reason}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming_once(info, {ssl_error, Socket, Reason}, #conn_data{socket = Socket, async_ref = Ref, stream_to = StreamTo} = Data) ->
    StreamTo ! {hackney_response, Ref, {error, Reason}},
    {next_state, closed, Data#conn_data{socket = undefined}};

streaming_once(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

streaming_once(EventType, Event, Data) ->
    handle_common(EventType, Event, streaming_once, Data).

%%====================================================================
%% State: closed - Connection terminated
%%====================================================================

closed(enter, _OldState, #conn_data{socket = Socket, transport = Transport, pool_pid = PoolPid} = Data) ->
    %% Close socket if still open
    case Socket of
        undefined -> ok;
        _ -> Transport:close(Socket)
    end,
    %% Pooled connections used to stop immediately here, but that made
    %% late-arriving {call, From, {request, _}} messages from workers that
    %% raced the pool checkout race a terminating gen_statem — which
    %% surfaces as `exit:{normal, _}` in the caller (issue #836). Stay
    %% alive briefly so those late calls get a proper `{error, closed}`
    %% reply via handle_common's closed-state fallback, then stop.
    %% A GOAWAY drain ends here, whichever way the connection closed.
    Data2 = Data#conn_data{socket = undefined, h2_goaway = undefined},
    case PoolPid of
        undefined ->
            {keep_state, Data2};
        _ ->
            {keep_state, Data2,
             [{state_timeout, ?CLOSED_GRACE_MS, closed_grace_expired}]}
    end;

closed(state_timeout, closed_grace_expired, Data) ->
    {stop, normal, Data};

closed({call, From}, connect, Data) ->
    %% Allow reconnection from closed state
    #conn_data{
        host = Host,
        port = Port,
        transport = Transport,
        connect_timeout = Timeout,
        connect_options = ConnectOpts,
        ssl_options = SslOpts
    } = Data,

    %% Build connection options
    Opts = case Transport of
        hackney_ssl -> ConnectOpts ++ SslOpts;
        _ -> ConnectOpts
    end,

    %% Attempt connection
    case Transport:connect(Host, Port, Opts, Timeout) of
        {ok, Socket} ->
            %% Connection successful
            NewData = Data#conn_data{socket = Socket},
            {next_state, connected, NewData, [{reply, From, ok}]};
        {error, Reason} ->
            %% Connection failed, stay in closed state
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;

closed({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, closed}}]};

closed(info, {'DOWN', Ref, process, _Pid, _Reason}, #conn_data{owner_mon = Ref} = Data) ->
    {stop, normal, Data};

closed(cast, {set_owner, _NewOwner}, #conn_data{pool_pid = PoolPid} = Data)
  when is_pid(PoolPid) ->
    %% #850: the pool tried to hand ownership to a pooled connection that
    %% already closed (async checkin/prewarm raced a server-side close). Stop
    %% now so the pool's monitor removes us from `available` promptly, instead
    %% of lingering through the grace window and being handed out again.
    {stop, normal, Data};

closed(EventType, Event, Data) ->
    handle_common(EventType, Event, closed, Data).

%%====================================================================
%% Internal functions
%%====================================================================

%% @private Handle common events across all states
%% Handle enter events for state transitions (required when using state_enter callback mode)
handle_common(enter, _OldState, _NewState, _Data) ->
    keep_state_and_data;

handle_common(cast, stop, _State, Data) ->
    %% Async stop - used by pool to avoid deadlock during sync checkin
    {stop, normal, Data};

handle_common(info, {'DOWN', Ref, process, _Pid, _Reason}, State, Data) ->
    handle_h2_stream_owner_down(Ref, State, Data);

handle_common({timeout, h2_idle}, h2_idle, connected,
              #conn_data{h2_shared = true, h2_streams = Streams,
                         h2_conn = H2Conn, h2_mon = H2Mon} = Data)
  when map_size(Streams) =:= 0 ->
    %% Idle with no stream open: close like a GOAWAY. The conn stops after
    %% the closed grace window and the pool drops it on DOWN.
    _ = case H2Mon of
        undefined -> ok;
        _ -> erlang:demonitor(H2Mon, [flush])
    end,
    close_h2(H2Conn),
    {next_state, closed, Data#conn_data{h2_conn = undefined, h2_mon = undefined,
                                        socket = undefined}};

handle_common({timeout, h2_idle}, h2_idle, _State, _Data) ->
    %% A stream opened since the timer was armed; the last one to finish
    %% arms it again.
    keep_state_and_data;

handle_common(cast, _Msg, _State, _Data) ->
    keep_state_and_data;

%% Socket operations - available in any state with a socket
handle_common({call, From}, {setopts, Opts}, _State, #conn_data{transport = Transport, socket = Socket} = _Data)
  when Socket =/= undefined ->
    Result = Transport:setopts(Socket, Opts),
    {keep_state_and_data, [{reply, From, Result}]};

handle_common({call, From}, peername, _State, #conn_data{transport = Transport, socket = Socket} = _Data)
  when Socket =/= undefined ->
    Result = Transport:peername(Socket),
    {keep_state_and_data, [{reply, From, Result}]};

handle_common({call, From}, peercert, _State, #conn_data{transport = Transport, socket = Socket} = _Data)
  when Socket =/= undefined ->
    Result = case erlang:function_exported(Transport, peercert, 1) of
        true -> Transport:peercert(Socket);
        false -> {error, not_ssl}
    end,
    {keep_state_and_data, [{reply, From, Result}]};

handle_common({call, From}, sockname, _State, #conn_data{transport = Transport, socket = Socket} = _Data)
  when Socket =/= undefined ->
    Result = Transport:sockname(Socket),
    {keep_state_and_data, [{reply, From, Result}]};

%% HTTP/3 socket operations — peername/sockname/peercert delegated to the
%% underlying quic connection; setopts has no analog over QUIC.
handle_common({call, From}, peername, _State,
              #conn_data{h3_conn = H3Conn} = _Data) when H3Conn =/= undefined ->
    {keep_state_and_data, [{reply, From, hackney_h3:peername(H3Conn)}]};

handle_common({call, From}, sockname, _State,
              #conn_data{h3_conn = H3Conn} = _Data) when H3Conn =/= undefined ->
    {keep_state_and_data, [{reply, From, hackney_h3:sockname(H3Conn)}]};

handle_common({call, From}, peercert, _State,
              #conn_data{h3_conn = H3Conn} = _Data) when H3Conn =/= undefined ->
    {keep_state_and_data, [{reply, From, hackney_h3:peercert(H3Conn)}]};

handle_common({call, From}, {setopts, _Opts}, _State,
              #conn_data{h3_conn = H3Conn} = _Data) when H3Conn =/= undefined ->
    {keep_state_and_data, [{reply, From, {error, not_supported}}]};

%% Low-level send operation
handle_common({call, From}, {send, Data}, _State, #conn_data{transport = Transport, socket = Socket} = _Data)
  when Socket =/= undefined ->
    Result = Transport:send(Socket, Data),
    {keep_state_and_data, [{reply, From, Result}]};

%% Low-level recv operation
handle_common({call, From}, {recv, Length, Timeout}, _State, #conn_data{transport = Transport, socket = Socket} = _Data)
  when Socket =/= undefined ->
    Result = Transport:recv(Socket, Length, Timeout),
    {keep_state_and_data, [{reply, From, Result}]};

%% Close socket but keep process
handle_common({call, From}, close_socket, _State, #conn_data{transport = Transport, socket = Socket} = Data)
  when Socket =/= undefined ->
    Transport:close(Socket),
    {next_state, closed, Data#conn_data{socket = undefined}, [{reply, From, ok}]};

handle_common({call, From}, close_socket, _State, Data) ->
    {next_state, closed, Data, [{reply, From, ok}]};

handle_common({call, From}, {send, _SendData}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

handle_common({call, From}, {recv, _Length, _Timeout}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

handle_common({call, From}, {setopts, _Opts}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

handle_common({call, From}, peername, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

handle_common({call, From}, peercert, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

handle_common({call, From}, sockname, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

handle_common({call, From}, response_headers, _State, #conn_data{response_headers = Headers}) ->
    {keep_state_and_data, [{reply, From, Headers}]};

handle_common({call, From}, get_location, _State, #conn_data{location = Location}) ->
    {keep_state_and_data, [{reply, From, Location}]};

handle_common({call, From}, {set_location, Location}, _State, Data) ->
    {keep_state, Data#conn_data{location = Location}, [{reply, From, ok}]};

handle_common({call, From}, is_upgraded_ssl, _State, #conn_data{upgraded_ssl = Upgraded}) ->
    {keep_state_and_data, [{reply, From, Upgraded}]};

handle_common({call, From}, is_no_reuse, _State, #conn_data{no_reuse = NoReuse}) ->
    {keep_state_and_data, [{reply, From, NoReuse}]};

handle_common({call, From}, checkin_info, _State, Data) ->
    %% Any non-connected state (e.g. already closed) is not poolable.
    Map = (checkin_info_map(Data))#{ready => false},
    {keep_state_and_data, [{reply, From, Map}]};

handle_common({call, From}, get_protocol, _State, #conn_data{protocol = Protocol}) ->
    {keep_state_and_data, [{reply, From, Protocol}]};

handle_common({call, From}, _, closed, _Data) ->
    %% #932: a call that reaches a connection already in `closed' (a request
    %% that raced a peer-initiated close after checkout) is a closed
    %% connection, not a misuse of the API. Reply with the same
    %% `{error, closed}' safe_call/3 gives when the process is already gone,
    %% so the race has one answer instead of two.
    {keep_state_and_data, [{reply, From, {error, closed}}]};

handle_common({call, From}, _, _State, _Data) ->
    {keep_state_and_data, [{reply, From, {error, invalid_state}}]};

%% QUIC socket ready - drive event loop (common handler for all states)
handle_common(info, {select, _Resource, _Ref, ready_input},
              _State, #conn_data{h3_conn = ConnRef}) when ConnRef =/= undefined ->
    _ = hackney_h3:process(ConnRef),
    keep_state_and_data;

%% HTTP/3 0-RTT/resumption: cache the session ticket in the pool so the next
%% connection to this host can resume. Handled here (common to all H3 states)
%% since the ticket can arrive at any point after the handshake.
handle_common(info, {h3, ConnRef, {session_ticket, Ticket}}, _State,
              #conn_data{h3_conn = ConnRef} = Data) ->
    maybe_store_h3_session(Ticket, Data),
    {keep_state, Data#conn_data{h3_session_ticket = Ticket}};

%% HTTP/3 0-RTT rejection. Requests on this path are sent at 1-RTT, so this is
%% not expected; if it arrives, invalidate the cached ticket and fail any
%% matching in-flight stream so the caller can retry.
handle_common(info, {h3, ConnRef, {early_data_rejected, StreamIds}}, _State,
              #conn_data{h3_conn = ConnRef, h3_streams = Streams} = Data) ->
    maybe_delete_h3_session(Data),
    {NewStreams, Actions} = fail_rejected_h3_streams(StreamIds, Streams),
    h3_drain_result({keep_state, Data#conn_data{h3_streams = NewStreams}, Actions});

%% With trap_exit = true, an EXIT signal from any linked process (other than
%% h2_conn, handled in connected/3) arrives here. Swallow it rather than
%% propagating — avoids tearing down the gen_statem on stray links.
handle_common(info, {'EXIT', _Pid, _Reason}, _State, _Data) ->
    keep_state_and_data;

handle_common(info, _Msg, _State, _Data) ->
    keep_state_and_data.

%% @private Reply to caller and stop
reply_and_stop(undefined, _Reply, Data) ->
    {stop, normal, Data};
reply_and_stop(From, Reply, _Data) ->
    {stop_and_reply, normal, [{reply, From, Reply}]}.

%% @private Reset async state
reset_async(Data) ->
    Data#conn_data{
        async = false,
        async_ref = undefined,
        stream_to = undefined
    }.

%% @private Whether the connection must close (not be reused) for keepalive
%% reasons. Distinguishes "no response observed yet" (a fresh or idle pooled
%% conn, which stays poolable) from a parsed response, whose close decision
%% follows RFC 7230 via hackney_keepalive:should_close/3.
should_close_connection(#conn_data{response_headers = undefined, version = undefined}) ->
    %% No request/response cycle has run on this connection: keep it poolable so
    %% a plain checkout/checkin (no request) still returns the live conn to the
    %% pool.
    false;
should_close_connection(#conn_data{version = Version, response_headers = Headers,
                                   request_close = RequestClose}) ->
    hackney_keepalive:should_close(Version, Headers, RequestClose).

%% @private Whether a connection whose request/response cycle just finished may
%% be reused. Shared by the sync and async completion paths so the reuse test
%% lives in one place: a connection flagged no_reuse (proxy tunnel, SSL upgrade,
%% pool disabled) or whose response asked to close (RFC 7230) is not reusable.
connection_reusable(#conn_data{no_reuse = true}) ->
    false;
connection_reusable(Data) ->
    not should_close_connection(Data).

%% @private Close the socket if we still hold one. Returns ok.
close_socket(_Transport, undefined) -> ok;
close_socket(Transport, Socket) -> Transport:close(Socket), ok.

%% @private Finish a completed synchronous request (blocking body / stream_body).
%% A reusable connection returns to `connected': a pooled one is handed back to
%% the pool from connected(enter, receiving), a direct one stays alive for the
%% owner to reuse. A non-reusable one is closed and the process stopped, so a
%% no_reuse / Connection: close conn no longer parks in `connected' forever
%% (#902). Mirrors finish_async_streaming/1 for the sync path.
finish_sync_request(From, Reply, #conn_data{transport = Transport, socket = Socket} = Data) ->
    case connection_reusable(Data) of
        true ->
            {next_state, connected, Data, [{reply, From, Reply}]};
        false ->
            ok = close_socket(Transport, Socket),
            {stop_and_reply, normal, [{reply, From, Reply}],
             Data#conn_data{socket = undefined}}
    end.

%% @private The request is over and the connection cannot carry another one:
%% the body was cut short (the peer closed mid-transfer, so read_full_body/2
%% hands back `socket = undefined'), the response had no body to read, or the
%% read failed outright. None of these reach finish_sync_request/3 (#902).
%%
%% A pooled conn parks in `closed', keeping the grace window added for #836 so
%% late calls still get a proper reply before it stops. An unpooled conn has no
%% such timer, and when it was started under hackney_conn_sup its `owner' is the
%% supervisor, so the owner-DOWN clause never fires either: parking there leaks
%% the process along with every refc binary it read (#918). Stop instead.
finish_dead_request(From, Reply, #conn_data{transport = Transport, socket = Socket,
                                            pool_pid = PoolPid} = Data) ->
    case PoolPid of
        undefined ->
            ok = close_socket(Transport, Socket),
            {stop_and_reply, normal, [{reply, From, Reply}],
             Data#conn_data{socket = undefined}};
        _ ->
            {next_state, closed, Data, [{reply, From, Reply}]}
    end.

%% @private Finish async streaming. Reuse only a reusable, pooled connection
%% (direct async conns are not re-driven, so they stop rather than park);
%% otherwise close and stop. Now also honours no_reuse via connection_reusable/1,
%% closing the gap where a no_reuse pooled async conn returned to `connected'.
finish_async_streaming(#conn_data{transport = Transport, socket = Socket,
                                  pool_pid = PoolPid} = Data) ->
    case connection_reusable(Data) andalso PoolPid =/= undefined of
        true ->
            {next_state, connected, reset_async(Data)};
        false ->
            ok = close_socket(Transport, Socket),
            {stop, normal, reset_async(Data#conn_data{socket = undefined})}
    end.

%% @private Handle receiving response status and headers
%% IncludePid determines whether to include pid in the response
do_recv_response_impl(Data, IncludePid) ->
    Parser = hackney_http:parser([response]),
    DataWithParser = Data#conn_data{parser = Parser},
    case recv_status_and_headers(DataWithParser) of
        {ok, Status, Headers, NewData} ->
            From = NewData#conn_data.request_from,
            HeadersList = hackney_headers:to_list(Headers),
            maybe_record_altsvc(HeadersList, NewData),
            Reply = case IncludePid of
                true -> {ok, Status, HeadersList, self()};
                false -> {ok, Status, HeadersList}
            end,
            {keep_state, NewData#conn_data{
                request_from = undefined,
                response_headers = Headers
            }, [{reply, From, Reply}]};
        {error, Reason} ->
            From = Data#conn_data.request_from,
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end.

%% @private Send HTTP request (shared by sync and async)
do_send_request(Method, Path, Headers, Body, Data) ->
    #conn_data{
        transport = Transport,
        socket = Socket,
        netloc = Netloc
    } = Data,

    %% Build request headers
    FinalHeaders = build_headers(Method, Headers, Body, Netloc),

    %% Record whether the caller asked the server to close, for the keepalive
    %% decision at checkin. Reset per request.
    Data1 = Data#conn_data{request_close = hackney_keepalive:request_closes(FinalHeaders)},

    %% Build request line and headers
    Path1 = case Path of
        <<>> -> <<"/">>;
        _ -> Path
    end,
    RequestLine = <<Method/binary, " ", Path1/binary, " HTTP/1.1\r\n">>,
    HeadersBin = headers_to_binary(FinalHeaders),
    RequestData = <<RequestLine/binary, HeadersBin/binary>>,

    %% Send request
    case Transport:send(Socket, RequestData) of
        ok ->
            %% Send body if present
            case send_body(Transport, Socket, Body) of
                ok ->
                    {ok, Data1};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Compute netloc for Host header
compute_netloc(Host, Port, Transport) ->
    HostBin = hackney_bstr:to_binary(Host),
    case {Transport, Port} of
        {hackney_tcp, 80} -> HostBin;
        {hackney_ssl, 443} -> HostBin;
        _ ->
            PortBin = integer_to_binary(Port),
            <<HostBin/binary, ":", PortBin/binary>>
    end.

%% @private Build request headers
build_headers(Method, Headers0, Body, Netloc) ->
    %% Start with user headers
    Headers1 = hackney_headers:new(Headers0),

    %% Add Host header if not present
    {_, Headers2} = hackney_headers:store_new(<<"Host">>, Netloc, Headers1),

    %% Add User-Agent if not present
    {_, Headers3} = hackney_headers:store_new(<<"User-Agent">>, default_ua(), Headers2),

    %% Add Content-Length for bodies
    case Body of
        B when B =:= <<>>; B =:= [] ->
            %% Empty body: like curl, send Content-Length: 0 for methods that
            %% carry a body (POST/PUT/PATCH) so a server that requires the
            %% header (e.g. AWS) still gets it; leave bodyless methods
            %% (GET/HEAD/DELETE/...) without one.
            case body_method(Method) andalso
                 not hackney_headers:is_key(<<"content-length">>, Headers3) of
                true -> hackney_headers:store(<<"Content-Length">>, <<"0">>, Headers3);
                false -> Headers3
            end;
        _ when is_binary(Body) ->
            Len = byte_size(Body),
            case hackney_headers:is_key(<<"content-length">>, Headers3) of
                true -> Headers3;
                false ->
                    hackney_headers:store(<<"Content-Length">>, integer_to_binary(Len), Headers3)
            end;
        _ when is_list(Body) ->
            Len = iolist_size(Body),
            case hackney_headers:is_key(<<"content-length">>, Headers3) of
                true -> Headers3;
                false ->
                    hackney_headers:store(<<"Content-Length">>, integer_to_binary(Len), Headers3)
            end;
        _ ->
            %% Streaming body - expect user to have set Content-Length or Transfer-Encoding
            Headers3
    end.

%% @private Methods that carry a request body, so an empty body still gets an
%% explicit Content-Length: 0 (curl does the same for POST/PUT/PATCH).
body_method(Method) ->
    case hackney_bstr:to_upper(hackney_bstr:to_binary(Method)) of
        <<"POST">> -> true;
        <<"PUT">> -> true;
        <<"PATCH">> -> true;
        _ -> false
    end.

%% @private Convert headers to binary
headers_to_binary(Headers) ->
    hackney_headers:to_binary(Headers).

%% @private Build request line
build_request_line(Method, Path) ->
    [Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>].

%% @private Encode a chunk for chunked transfer encoding
encode_chunk(Data) when is_binary(Data) ->
    Size = byte_size(Data),
    SizeHex = integer_to_binary(Size, 16),
    [SizeHex, <<"\r\n">>, Data, <<"\r\n">>];
encode_chunk(Data) when is_list(Data) ->
    Size = iolist_size(Data),
    SizeHex = integer_to_binary(Size, 16),
    [SizeHex, <<"\r\n">>, Data, <<"\r\n">>].

%% @private Stream body from stateless function
%% fun() -> {ok, Data} | eof | {error, Reason}
stream_body_fun(Transport, Socket, Fun) when is_function(Fun, 0) ->
    case Fun() of
        {ok, Data} ->
            case Transport:send(Socket, encode_chunk(Data)) of
                ok -> stream_body_fun(Transport, Socket, Fun);
                Error -> Error
            end;
        eof ->
            ok;
        {error, _} = Error ->
            Error
    end;
%% @private Stream body from stateful function
%% fun(State) -> {ok, Data, NewState} | eof | {error, Reason}
stream_body_fun(Transport, Socket, {Fun, State}) when is_function(Fun, 1) ->
    case Fun(State) of
        {ok, Data, NewState} ->
            case Transport:send(Socket, encode_chunk(Data)) of
                ok -> stream_body_fun(Transport, Socket, {Fun, NewState});
                Error -> Error
            end;
        eof ->
            ok;
        {error, _} = Error ->
            Error
    end.

%% @private Stream body from function for HTTP/3
stream_body_fun_h3(ConnRef, StreamId, Fun) when is_function(Fun, 0) ->
    case Fun() of
        {ok, Data} ->
            case hackney_h3:send_body_chunk(ConnRef, StreamId, iolist_to_binary(Data), false) of
                ok -> stream_body_fun_h3(ConnRef, StreamId, Fun);
                Error -> Error
            end;
        eof ->
            ok;
        {error, _} = Error ->
            Error
    end;
stream_body_fun_h3(ConnRef, StreamId, {Fun, State}) when is_function(Fun, 1) ->
    case Fun(State) of
        {ok, Data, NewState} ->
            case hackney_h3:send_body_chunk(ConnRef, StreamId, iolist_to_binary(Data), false) of
                ok -> stream_body_fun_h3(ConnRef, StreamId, {Fun, NewState});
                Error -> Error
            end;
        eof ->
            ok;
        {error, _} = Error ->
            Error
    end.

%% @private Get default User-Agent
default_ua() ->
    Version = case application:get_key(hackney, vsn) of
        {ok, FullVersion} ->
            list_to_binary(hd(string:tokens(FullVersion, "-")));
        _ ->
            <<"0.0.0">>
    end,
    <<"hackney/", Version/binary>>.

%% @private Send request body
send_body(_Transport, _Socket, <<>>) ->
    ok;
send_body(_Transport, _Socket, []) ->
    ok;
send_body(_Transport, _Socket, stream) ->
    %% Stream body mode - body will be sent separately
    ok;
send_body(Transport, Socket, Body) when is_binary(Body); is_list(Body) ->
    Transport:send(Socket, Body).

%% @private Receive and parse response status and headers
%% Handles 1XX informational responses per RFC 7231
recv_status_and_headers(Data) ->
    recv_status_and_headers_loop(Data).

recv_status_and_headers_loop(Data) ->
    case recv_status(Data) of
        {ok, Status, Headers, NewData} when Status >= 100, Status < 200 ->
            %% 1XX informational response per RFC 7231 Section 6.2
            #conn_data{inform_fun = InformFun, reason = Reason, parser = OldParser,
                       stream_to = StreamTo, async_ref = AsyncRef} = NewData,
            HeadersList = hackney_headers:to_list(Headers),
            %% Handle differently for sync vs async mode
            case StreamTo of
                undefined ->
                    %% Sync mode - call callback if provided
                    case InformFun of
                        undefined -> ok;
                        Fun when is_function(Fun, 3) ->
                            Fun(Status, Reason, HeadersList)
                    end;
                _ ->
                    %% Async mode - send message to stream_to
                    StreamTo ! {hackney_response, AsyncRef, {informational, Status, Reason, HeadersList}}
            end,
            %% Reset parser for next response, preserving any buffered data
            %% The old parser's buffer may contain the start of the next response
            OldBuffer = hackney_http:get(OldParser, buffer),
            NewParser = hackney_http:parser([response]),
            recv_status_and_headers_loop(NewData#conn_data{parser = NewParser, buffer = OldBuffer});
        Other ->
            Other
    end.

recv_status(#conn_data{parser = Parser, buffer = Buffer} = Data) ->
    case hackney_http:execute(Parser, Buffer) of
        {more, NewParser} ->
            %% The parser needs more bytes to complete the status line. It already
            %% consumed what it could, so re-feeding its own buffer makes no
            %% progress (that was an infinite spin); always read from the socket.
            %% But a valid HTTP/1 status line starts with "HTTP/": if what we have
            %% can never be that (e.g. an HTTP/2 frame on a mislabeled connection),
            %% fail fast instead of reading until recv_timeout.
            case maybe_http_status_start(hackney_http:get(NewParser, buffer)) of
                false ->
                    {error, {bad_response, not_http}};
                true ->
                    case recv_data(Data) of
                        {ok, RecvData} ->
                            recv_status(Data#conn_data{parser = NewParser, buffer = RecvData});
                        {error, Reason} ->
                            {error, Reason}
                    end
            end;
        {response, Version, Status, Reason, NewParser} ->
            recv_headers(Data#conn_data{
                parser = NewParser,
                buffer = <<>>,
                version = Version,
                status = Status,
                reason = Reason
            }, hackney_headers:new());
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Whether the buffered bytes can still be the start of an HTTP/1 status
%% line. Leading blank lines are tolerated (RFC 7230 3.5). True while the buffer is
%% empty or shares a common prefix with "HTTP/" up to the shorter length, so both a
%% still-accumulating version ("HTT") and a longer partial line ("HTTP/1.1 2") pass;
%% false once it diverges (e.g. an HTTP/2 frame), so a protocol mismatch fails fast.
maybe_http_status_start(Buffer) ->
    case strip_leading_eol(Buffer) of
        <<>> ->
            true;
        Bin ->
            Prefix = <<"HTTP/">>,
            N = min(byte_size(Bin), byte_size(Prefix)),
            binary:part(Bin, 0, N) =:= binary:part(Prefix, 0, N)
    end.

%% @private Drop leading CR/LF bytes (lenient about blank lines before the status line).
strip_leading_eol(<<"\r", Rest/binary>>) -> strip_leading_eol(Rest);
strip_leading_eol(<<"\n", Rest/binary>>) -> strip_leading_eol(Rest);
strip_leading_eol(Bin) -> Bin.

recv_headers(#conn_data{parser = Parser} = Data, Headers) ->
    case hackney_http:execute(Parser) of
        {more, NewParser} ->
            case recv_data(Data) of
                {ok, RecvData} ->
                    case hackney_http:execute(NewParser, RecvData) of
                        {header, {Key, Value}, NewParser2} ->
                            Headers2 = hackney_headers:append(Key, Value, Headers),
                            recv_headers(Data#conn_data{parser = NewParser2}, Headers2);
                        {headers_complete, NewParser2} ->
                            {ok, Data#conn_data.status, Headers, Data#conn_data{parser = NewParser2}};
                        {more, NewParser2} ->
                            recv_headers(Data#conn_data{parser = NewParser2, buffer = <<>>}, Headers);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {header, {Key, Value}, NewParser} ->
            Headers2 = hackney_headers:append(Key, Value, Headers),
            recv_headers(Data#conn_data{parser = NewParser}, Headers2);
        {headers_complete, NewParser} ->
            {ok, Data#conn_data.status, Headers, Data#conn_data{parser = NewParser}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Read full response body
read_full_body(#conn_data{method = <<"HEAD">>} = Data, Acc) ->
    %% HEAD requests have no body
    {ok, Acc, Data};
read_full_body(#conn_data{status = Status} = Data, Acc) when Status =:= 204; Status =:= 304 ->
    %% 204 No Content and 304 Not Modified have no body per RFC 7230 3.3.3
    %% Force connection close to avoid corrupting subsequent requests if
    %% a misbehaving server sent Content-Length or body data
    {ok, Acc, Data#conn_data{socket = undefined}};
read_full_body(#conn_data{max_body_size = Max} = Data, Acc) ->
    case stream_body_chunk(Data) of
        {ok, Chunk, NewData} ->
            case body_within_limit(byte_size(Acc) + byte_size(Chunk), Max) of
                true ->
                    read_full_body(NewData, <<Acc/binary, Chunk/binary>>);
                false ->
                    %% The rest of the body stays unread on the socket; the
                    %% caller's error path drops the connection.
                    {error, body_too_large}
            end;
        {done, NewData} ->
            %% Body complete - apply decompression if needed
            maybe_decompress_body(Acc, NewData);
        {error, closed} ->
            %% Cut short: hand back what did arrive.
            {error, {closed, Acc}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Per-request body cap: max_body_size, with max_body (the 1.x
%% option name) accepted as an alias.
max_body_size(ReqOpts) ->
    case proplists:get_value(max_body_size, ReqOpts) of
        undefined -> proplists:get_value(max_body, ReqOpts, ?DEFAULT_MAX_BODY_SIZE);
        Max -> Max
    end.

body_within_limit(_Size, infinity) -> true;
body_within_limit(Size, Max) -> Size =< Max.

%% @private Apply decompression if auto_decompress is enabled and Content-Encoding is set
maybe_decompress_body(Body, #conn_data{auto_decompress = false} = Data) ->
    {ok, Body, Data};
maybe_decompress_body(Body, #conn_data{response_headers = undefined} = Data) ->
    {ok, Body, Data};
maybe_decompress_body(Body, #conn_data{response_headers = Headers, auto_decompress = true,
                                       max_body_size = Max} = Data) ->
    %% Get Content-Encoding from response headers
    ContentEncoding = case hackney_headers:get_value(<<"content-encoding">>, Headers) of
        undefined -> <<>>;
        CE -> hackney_bstr:to_lower(CE)
    end,
    case ContentEncoding of
        <<"gzip">> ->
            case decompress_gzip(Body, Max) of
                {ok, Decompressed} -> {ok, Decompressed, Data};
                {error, body_too_large} -> {error, body_too_large};
                {error, Reason} -> {error, {decompress_error, gzip, Reason}}
            end;
        <<"deflate">> ->
            case decompress_deflate(Body, Max) of
                {ok, Decompressed} -> {ok, Decompressed, Data};
                {error, body_too_large} -> {error, body_too_large};
                {error, Reason} -> {error, {decompress_error, deflate, Reason}}
            end;
        <<"x-gzip">> ->
            %% x-gzip is an alias for gzip
            case decompress_gzip(Body, Max) of
                {ok, Decompressed} -> {ok, Decompressed, Data};
                {error, body_too_large} -> {error, body_too_large};
                {error, Reason} -> {error, {decompress_error, gzip, Reason}}
            end;
        _ ->
            %% No compression or unknown encoding - return as-is
            {ok, Body, Data}
    end.

%% @private Decompress gzip-encoded data (RFC 1952), at most Max bytes out.
decompress_gzip(Data, Max) ->
    inflate_bounded(Data, 16 + 15, Max).

%% @private Decompress deflate-encoded data, at most Max bytes out.
%% Note: Some servers send raw deflate, others send zlib-wrapped deflate
decompress_deflate(Data, Max) ->
    %% zlib-wrapped (RFC 1950), as before
    inflate_bounded(Data, 15, Max).

%% @private Inflate in bounded steps so a small compressed body cannot expand
%% past max_body_size in memory (a gzip bomb inflates ~1000x). zlib:gunzip/1
%% and zlib:inflate/2 produce the whole output before returning.
inflate_bounded(Data, WindowBits, Max) ->
    try
        Z = zlib:open(),
        try
            ok = zlib:inflateInit(Z, WindowBits),
            case inflate_loop(Z, zlib:safeInflate(Z, Data), [], 0, Max) of
                {ok, Chunks} ->
                    ok = zlib:inflateEnd(Z),
                    {ok, iolist_to_binary(lists:reverse(Chunks))};
                {error, _} = Error ->
                    Error
            end
        after
            zlib:close(Z)
        end
    catch
        error:Reason -> {error, Reason};
        exit:Reason -> {error, Reason}
    end.

inflate_loop(Z, {Status, Output}, Acc, Size, Max) ->
    Size1 = Size + iolist_size(Output),
    case body_within_limit(Size1, Max) of
        false ->
            {error, body_too_large};
        true when Status =:= continue ->
            inflate_loop(Z, zlib:safeInflate(Z, []), [Output | Acc], Size1, Max);
        true ->
            {ok, [Output | Acc]}
    end.

%% @private Stream a single body chunk
stream_body_chunk(#conn_data{method = <<"HEAD">>} = Data) ->
    {done, Data};
stream_body_chunk(#conn_data{status = Status} = Data) when Status =:= 204; Status =:= 304 ->
    %% 204 No Content and 304 Not Modified have no body per RFC 7230 3.3.3
    %% Force connection close to avoid corrupting subsequent requests if
    %% a misbehaving server sent Content-Length or body data
    {done, Data#conn_data{socket = undefined}};
stream_body_chunk(#conn_data{parser = Parser} = Data) ->
    case hackney_http:execute(Parser) of
        {more, NewParser, _Buffer} ->
            %% Need more data
            case owner_recv(Data) of
                {ok, RecvData} ->
                    stream_body_chunk_result(hackney_http:execute(NewParser, RecvData), Data);
                {error, closed} ->
                    body_closed(Data);
                {error, Reason} ->
                    {error, Reason}
            end;
        {more, NewParser} ->
            %% Need more data
            case owner_recv(Data) of
                {ok, RecvData} ->
                    %% Execute with new data and handle result
                    stream_body_chunk_result(hackney_http:execute(NewParser, RecvData), Data);
                {error, closed} ->
                    body_closed(Data);
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, Chunk, NewParser} ->
            {ok, Chunk, Data#conn_data{parser = NewParser}};
        {done, Rest} ->
            {done, Data#conn_data{buffer = Rest, parser = undefined}};
        done ->
            {done, Data#conn_data{buffer = <<>>, parser = undefined}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private The peer closed the socket mid-body. That ends a body framed by
%% the close itself; a chunked or Content-Length body is cut short.
body_closed(#conn_data{parser = Parser} = Data) ->
    case hackney_http:get(Parser, [transfer_encoding, content_length]) of
        [<<"chunked">>, _] -> {error, closed};
        [_, CLen] when is_integer(CLen) -> {error, closed};
        _ -> {done, Data#conn_data{socket = undefined}}
    end.

%% @private Handle result of parsing received data
stream_body_chunk_result({ok, Chunk, NewParser}, Data) ->
    {ok, Chunk, Data#conn_data{parser = NewParser}};
stream_body_chunk_result({done, Rest}, Data) ->
    {done, Data#conn_data{buffer = Rest, parser = undefined}};
stream_body_chunk_result(done, Data) ->
    {done, Data#conn_data{buffer = <<>>, parser = undefined}};
stream_body_chunk_result({more, NewParser}, Data) ->
    stream_body_chunk(Data#conn_data{parser = NewParser});
stream_body_chunk_result({more, NewParser, _Buffer}, Data) ->
    stream_body_chunk(Data#conn_data{parser = NewParser});
stream_body_chunk_result({error, Reason}, _Data) ->
    {error, Reason}.

%% @private Receive data from socket
recv_data(#conn_data{socket = Socket} = Data) ->
    %% Consume any bytes stranded in the mailbox by #544 {active, once} before
    %% falling back to a passive socket read, so a reused connection never blocks
    %% on an empty socket buffer while the response sits unread as a message.
    case drain_socket_data(Socket) of
        <<>> ->
            case has_pending_close(Socket) of
                true -> {error, closed};
                false -> owner_recv(Data)
            end;
        Bytes ->
            {ok, Bytes}
    end.

%% @private Passive read that still notices the owner dying. The read runs
%% in slices of at most ?OWNER_CHECK_INTERVAL, with a look for the owner's
%% 'DOWN' between them. The 'DOWN' is put back in the mailbox, so once the
%% error unwinds the current callback, the state's owner-'DOWN' clause stops
%% the conn as it always did. The whole read still honours recv_timeout.
owner_recv(#conn_data{transport = Transport, socket = Socket,
                      recv_timeout = Timeout, owner_mon = undefined}) ->
    Transport:recv(Socket, 0, Timeout);
owner_recv(#conn_data{transport = Transport, socket = Socket,
                      recv_timeout = Timeout, owner_mon = OwnerMon}) ->
    owner_recv(Transport, Socket, OwnerMon, recv_deadline(Timeout)).

owner_recv(Transport, Socket, OwnerMon, Deadline) ->
    Remaining = recv_remaining(Deadline),
    case Transport:recv(Socket, 0, min(Remaining, ?OWNER_CHECK_INTERVAL)) of
        {error, timeout} when Remaining > ?OWNER_CHECK_INTERVAL ->
            receive
                {'DOWN', OwnerMon, process, _, _} = Down ->
                    self() ! Down,
                    {error, owner_down}
            after 0 ->
                owner_recv(Transport, Socket, OwnerMon, Deadline)
            end;
        Result ->
            Result
    end.

recv_deadline(infinity) -> infinity;
recv_deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

%% Atoms sort after integers, so min/2 keeps a slice when this is infinity.
recv_remaining(infinity) -> infinity;
recv_remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% @private Determine if we should enable active mode when entering connected state
%% We only want active mode for close detection when the connection is truly idle
%% (returning from a completed request), not on initial connection where the server
%% might send data before we send our request (as in pipelining or some test scenarios).
should_enable_active_mode(receiving) -> true;
should_enable_active_mode(streaming) -> true;
should_enable_active_mode(streaming_once) -> true;
should_enable_active_mode(closed) -> true;  %% Reconnection from closed state
should_enable_active_mode(_) -> false.

%% @private Determine if we should auto-release to pool when entering connected state
%% We release when body reading is complete (coming from receiving state)
%% but NOT from streaming states (user is still actively streaming)
should_auto_release(receiving) -> true;
should_auto_release(_) -> false.

%% @private Auto-release connection back to pool
%% Transfers ownership to pool and notifies it asynchronously
auto_release_to_pool(#conn_data{pool_pid = PoolPid, owner_mon = OldMon} = Data) ->
    %% Transfer ownership to pool
    demonitor(OldMon, [flush]),
    NewMon = monitor(process, PoolPid),
    Data2 = Data#conn_data{owner = PoolPid, owner_mon = NewMon},
    %% Notify pool asynchronously (avoid blocking the state machine)
    notify_pool_available(Data2),
    Data2.

%% @private Check if socket is healthy (not closed by peer)
%% Note: With active mode enabled on connected sockets, we rely on tcp_closed/ssl_closed
%% messages to detect server closes. This function now uses peername to verify the
%% socket is still valid without conflicting with active mode.
check_socket_health(Transport, Socket) ->
    %% Use peername to check if socket is still connected
    %% This works regardless of active/passive mode
    Module = case Transport of
        hackney_ssl -> ssl;
        hackney_tcp -> inet;
        _ -> inet
    end,
    case Module:peername(Socket) of
        {ok, _} ->
            %% Socket is connected
            ok;
        {error, Reason} ->
            %% Socket error (closed, einval, etc.)
            {error, Reason}
    end.

%% @private Check for pending close message in mailbox
%% Returns true if a close message is waiting, false otherwise.
has_pending_close(Socket) ->
    receive
        {tcp_closed, Socket} -> true;
        {ssl_closed, Socket} -> true;
        {tcp_error, Socket, _} -> true;
        {ssl_error, Socket, _} -> true
    after 0 ->
        false
    end.

%% @private Whether the socket is proven ready to pool: present, no queued close,
%% and still connected. Runs in the conn process (peername + receive-after-0,
%% both fast); consuming a queued close here makes a server-closed idle conn
%% report not-ready. Does not disable active-once, so no stranded-byte regression.
socket_ready(#conn_data{socket = undefined}) ->
    false;
socket_ready(#conn_data{transport = Transport, socket = Socket}) ->
    not has_pending_close(Socket) andalso
        check_socket_health(Transport, Socket) =:= ok.

%% @private Drain and return any {tcp/ssl, Socket, Data} bytes queued in the
%% mailbox. #544 puts idle pooled sockets in {active, once}, which delivers the
%% next inbound bytes (the start of the response on a reused connection) as a
%% mailbox message and reverts the socket to passive. Those bytes are real
%% response data and must reach the parser, so we drain-and-return them rather
%% than discard them. Close/error messages are handled via has_pending_close/1.
drain_socket_data(Socket) ->
    drain_socket_data(Socket, <<>>).

drain_socket_data(Socket, Acc) ->
    receive
        {tcp, Socket, Data} -> drain_socket_data(Socket, <<Acc/binary, Data/binary>>);
        {ssl, Socket, Data} -> drain_socket_data(Socket, <<Acc/binary, Data/binary>>)
    after 0 ->
        Acc
    end.

%% @private Buffer bytes that #544 {active, once} delivered on an idle HTTP/1.1
%% connection (the start of the next response on reuse) and re-arm close
%% detection, so the next request consumes them. Bounded by ?MAX_IDLE_BUFFER: a
%% peer flooding an idle connection is dropped rather than buffered unboundedly.
buffer_idle_data(Data, #conn_data{socket = Socket, transport = Transport,
                                  buffer = Buffer} = D) ->
    NewBuffer = <<Buffer/binary, Data/binary>>,
    case byte_size(NewBuffer) > ?MAX_IDLE_BUFFER of
        true ->
            {next_state, closed, D#conn_data{socket = undefined}};
        false ->
            _ = Transport:setopts(Socket, [{active, once}]),
            {keep_state, D#conn_data{buffer = NewBuffer}}
    end.

%% @private Notify pool that connection is available for reuse (async)
notify_pool_available(#conn_data{pool_pid = undefined}) ->
    %% Not from a pool, nothing to do
    ok;
notify_pool_available(#conn_data{pool_pid = PoolPid}) ->
    %% Tell the pool this connection is available
    gen_server:cast(PoolPid, {checkin, nil, self()}).

%% @private Notify pool that connection is available for reuse (sync)
%% This ensures the pool has processed the checkin before returning.
%% We pass a "should close" flag to avoid deadlock (pool can't call back to us).
%% The flag is true for proxy tunnels (no_reuse), for SSL upgrades unless the
%% caller opted into ssl_pooling, and for non HTTP/1.1 conns (multiplexed
%% conns never enter the pool's available set).
notify_pool_available_sync(#conn_data{pool_pid = undefined}) ->
    ok;
notify_pool_available_sync(#conn_data{pool_pid = PoolPid, upgraded_ssl = UpgradedSsl,
                                      no_reuse = NoReuse, pool_ssl = PoolSsl,
                                      protocol = Protocol} = Data) ->
    %% do_checkin_with_close_flag/3 pools whenever this flag is false, with no
    %% further check, so also close on a keepalive-close response and on an
    %% unready socket - matching the async-cast checkin gate.
    ShouldClose = NoReuse orelse (UpgradedSsl andalso not PoolSsl)
        orelse Protocol =/= http1
        orelse should_close_connection(Data)
        orelse not socket_ready(Data),
    gen_server:call(PoolPid, {checkin_sync, self(), ShouldClose}, 5000).

%% @private Flags for the pool's checkin decision, see checkin_info/1. The
%% `ready' flag is added per-state by the checkin_info handlers, since it
%% depends on the conn being in `connected' with a healthy socket.
checkin_info_map(#conn_data{upgraded_ssl = UpgradedSsl, no_reuse = NoReuse,
                            pool_ssl = PoolSsl, protocol = Protocol} = Data) ->
    #{upgraded_ssl => UpgradedSsl, no_reuse => NoReuse,
      pool_ssl => PoolSsl, protocol => Protocol,
      should_close => should_close_connection(Data)}.

%% @private Start an async request
do_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, Data) ->
    %% Use self() (connection PID) as the async ref for message correlation
    Ref = self(),
    %% Issue #646: If StreamTo is different from the caller, set StreamTo as owner.
    %% This way the connection lifecycle is tied to the message recipient.
    %% If StreamTo dies, the connection will be terminated.
    {CallerPid, _} = From,
    Data2 = case StreamTo =:= CallerPid of
        true ->
            Data;
        false ->
            %% Change owner to StreamTo
            demonitor(Data#conn_data.owner_mon, [flush]),
            NewMon = monitor(process, StreamTo),
            Data#conn_data{owner = StreamTo, owner_mon = NewMon}
    end,
    NewData = Data2#conn_data{
        request_from = From,
        method = Method,
        path = Path,
        parser = undefined,
        version = undefined,
        status = undefined,
        reason = undefined,
        response_headers = undefined,
        %% buffer preserved (see the {request,...} handler): may hold stranded
        %% response bytes buffered from #544 {active, once}.
        async = AsyncMode,
        async_ref = Ref,
        stream_to = StreamTo,
        follow_redirect = FollowRedirect
    },
    {next_state, sending, NewData, [{next_event, internal, {send_request_async, Method, Path, Headers, Body}}]}.

%% @private Check if response is a redirect that should be handled
maybe_handle_async_redirect(Status, _Method, Headers, true) when
        Status =:= 301; Status =:= 302; Status =:= 307; Status =:= 308 ->
    %% Redirect status - get location
    case hackney_headers:get_value(<<"location">>, Headers) of
        undefined -> no_redirect;
        Location -> {redirect, Location}
    end;
maybe_handle_async_redirect(303, <<"POST">>, Headers, true) ->
    %% 303 See Other for POST - should redirect as GET
    case hackney_headers:get_value(<<"location">>, Headers) of
        undefined -> no_redirect;
        Location -> {see_other, Location}
    end;
maybe_handle_async_redirect(_, _, _, _) ->
    no_redirect.

%% @private Skip the response body
%% Chunks are dropped as they arrive, so a large body costs no memory and is
%% not subject to max_body_size.
skip_response_body(#conn_data{method = <<"HEAD">>} = Data) ->
    Data;
skip_response_body(#conn_data{status = Status} = Data) when Status =:= 204; Status =:= 304 ->
    Data;
skip_response_body(Data) ->
    case stream_body_chunk(Data) of
        {ok, _Chunk, NewData} -> skip_response_body(NewData);
        {done, NewData} -> NewData;
        {error, _} -> Data
    end.

%%====================================================================
%% HTTP/2 Support Functions
%%====================================================================

%% @private Try HTTP/3 connection via QUIC
%% lsquic handles its own UDP socket creation and DNS resolution.
try_h3_connect(Host, Port, Timeout, ConnectOpts, SslOpts) ->
    HostBin = if is_list(Host) -> list_to_binary(Host); true -> Host end,
    case hackney_h3:connect(HostBin, Port, h3_tls_opts(ConnectOpts, SslOpts), self()) of
        {ok, ConnRef} ->
            %% Drive event loop until connected
            wait_h3_connected(ConnRef, Timeout, erlang:monotonic_time(millisecond));
        {error, _} = Error ->
            Error
    end.

%% @private Map hackney's TLS options to the QUIC client verification.
%% quic >= 1.4.4 verifies the server certificate. An insecure connection opts
%% out; an explicitly configured CA (cacerts/cacertfile) is used as the trust
%% store; otherwise quic verifies against its own default (OS) trust store.
%% `family' (inet|inet6) and a `session_ticket' (for resumption) are forwarded
%% when present in either the connect options or the ssl options.
h3_tls_opts(ConnectOpts, SslOpts) ->
    Insecure = proplists:get_value(insecure, ConnectOpts,
                 proplists:get_value(insecure, SslOpts, false)),
    Base = case Insecure of
        true -> #{verify => verify_none};
        false -> h3_ca_opts(SslOpts)
    end,
    Base1 = case proplists:get_value(family, ConnectOpts,
                   proplists:get_value(family, SslOpts, undefined)) of
        undefined -> Base;
        Family -> Base#{family => Family}
    end,
    Base2 = case proplists:get_value(session_ticket, ConnectOpts,
              proplists:get_value(session_ticket, SslOpts, undefined)) of
        undefined -> Base1;
        Ticket -> Base1#{session_ticket => Ticket}
    end,
    %% Forward a user SNI so build_h3_opts can honor it (hostname or `disable').
    case proplists:get_value(server_name_indication, SslOpts, undefined) of
        undefined -> Base2;
        Sni -> Base2#{server_name_indication => Sni}
    end.

%% @private Use an explicitly configured CA as the H3 trust store. quic only
%% accepts DER cacerts, so a cacertfile is decoded here. With no CA configured
%% the map is empty and quic falls back to its default trust store.
h3_ca_opts(SslOpts) ->
    case proplists:get_value(cacerts, SslOpts) of
        undefined ->
            case proplists:get_value(cacertfile, SslOpts) of
                undefined -> #{};
                File -> #{cacerts => hackney_h3:cacertfile_ders(File)}
            end;
        CACerts ->
            #{cacerts => CACerts}
    end.

%% @private Drive QUIC event loop until connected
wait_h3_connected(ConnRef, Timeout, StartTime) ->
    Elapsed = erlang:monotonic_time(millisecond) - StartTime,
    Remaining = max(0, Timeout - Elapsed),
    receive
        {select, _Resource, _Ref, ready_input} ->
            _ = hackney_h3:process(ConnRef),
            wait_h3_connected(ConnRef, Timeout, StartTime);
        {h3, ConnRef, {connected, _Info}} ->
            {ok, ConnRef};
        {h3, ConnRef, {closed, Reason}} ->
            {error, {quic_closed, Reason}};
        {h3, ConnRef, {transport_error, Code, Msg}} ->
            {error, {quic_error, Code, Msg}}
    after Remaining ->
        hackney_h3:close(ConnRef, timeout),
        {error, timeout}
    end.

%% @private Standard TCP/TLS connection
do_tcp_connect(From, Data) ->
    #conn_data{
        host = Host,
        port = Port,
        transport = Transport,
        connect_timeout = Timeout,
        connect_options = ConnectOpts,
        ssl_options = SslOpts0
    } = Data,
    %% Filter out hackney-specific options that are not valid for transport
    TransportOpts = proplists:delete(protocols, ConnectOpts),
    case Transport of
        hackney_ssl ->
            %% effective_opts is the single builder of ssl:connect options for
            %% both default and custom ssl_options. It resolves SNI and ALPN
            %% and adds TLS 1.3 resumption only for the default config (custom
            %% ssl_options leave it off, see resumption_allowed/1).
            SslOpts1 = case proplists:get_value(protocols, ConnectOpts) of
                undefined -> SslOpts0;
                Protocols -> [{protocols, Protocols} | SslOpts0]
            end,
            FinalSslOpts0 = hackney_ssl:effective_opts(Host, SslOpts1, ConnectOpts),
            %% Gate TLS resumption on the ALPN memo and snapshot the cached
            %% protocol now, so a resumed session (where ssl reports no ALPN) is
            %% resolved against this snapshot rather than re-read from the memo.
            %% Resumable: only the resumption-eligible config updates the memo.
            AlpnProtos = alpn_advertised(FinalSslOpts0),
            Resumable = hackney_ssl:auto_tickets(FinalSslOpts0),
            Cached = hackney_ssl:recall_alpn(Host, AlpnProtos),
            FinalSslOpts = gate_resumption(FinalSslOpts0, Cached),
            Opts = TransportOpts ++ [{ssl_options, FinalSslOpts}],
            case Transport:connect(Host, Port, Opts, Timeout) of
                {ok, Socket} ->
                    case hackney_ssl:negotiated_protocol(Socket, Host, AlpnProtos, Cached, Resumable) of
                        http2 ->
                            init_h2_connection(Socket,
                                Data#conn_data{socket = Socket, protocol = http2}, From);
                        http1 ->
                            {next_state, connected,
                             Data#conn_data{socket = Socket, protocol = http1},
                             [{reply, From, ok}]}
                    end;
                {error, Reason} ->
                    {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
            end;
        _ ->
            case Transport:connect(Host, Port, TransportOpts, Timeout) of
                {ok, Socket} ->
                    {next_state, connected,
                     Data#conn_data{socket = Socket, protocol = http1},
                     [{reply, From, ok}]};
                {error, Reason} ->
                    {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
            end
    end.

%% @private The advertised ALPN protocol list (in offered order) from ssl opts,
%% or [] when none is offered. Used as part of the ALPN memo key.
alpn_advertised(SslOpts) ->
    proplists:get_value(alpn_advertised_protocols, SslOpts, []).

%% @private Gate TLS resumption on the ALPN memo: keep `session_tickets' (offer
%% resumption) only once a full handshake has cached this host+ALPN's protocol.
%% A cold memo (`none') strips it so the handshake is full and reports ALPN, which
%% repopulates the memo. Keeps a resumed session from losing the protocol.
gate_resumption(SslOpts, none) -> proplists:delete(session_tickets, SslOpts);
gate_resumption(SslOpts, _Cached) -> SslOpts.

%% @private Initialize HTTP/2 connection via the h2 library.
%% The h2_connection process takes ownership of the socket and delivers
%% owner messages ({h2, Conn, Event}) to this gen_statem's mailbox.
init_h2_connection(Socket, Data, From) ->
    start_h2_connection(Socket, Data, From, first_connect).

%% @private Initialize HTTP/2 after SSL upgrade (e.g., after CONNECT proxy tunnel)
init_h2_after_upgrade(SslSocket, Data, From) ->
    start_h2_connection(SslSocket, Data, From, after_upgrade).

start_h2_connection(Socket, Data, From, Origin) ->
    #conn_data{transport = Transport} = Data,
    H2Opts = #{settings => #{initial_window_size => ?H2_STREAM_WINDOW},
               connection_window_size => ?H2_CONN_WINDOW},
    case h2_connection:start_link(client, Socket, self(), H2Opts) of
        {ok, H2Conn} ->
            %% Transfer socket ownership then activate handshake.
            _ = Transport:controlling_process(Socket, H2Conn),
            case h2_connection:activate(H2Conn) of
                ok ->
                    case h2_connection:wait_connected(H2Conn,
                                                     Data#conn_data.connect_timeout) of
                        ok ->
                            Mon = erlang:monitor(process, H2Conn),
                            NewData = Data#conn_data{
                                h2_conn = H2Conn,
                                h2_mon = Mon,
                                h2_streams = #{},
                                h2_stream_monitors = #{},
                                h2_goaway = undefined
                            },
                            %% Cancel any pending idle_timeout armed by the
                            %% TCP-first connected(enter): HTTP/2 connections
                            %% multiplex and stay in `connected`, so the 2s
                            %% pool default would kill a busy conn (#836).
                            CancelIdle = {state_timeout, infinity, idle_timeout},
                            case Origin of
                                first_connect ->
                                    {next_state, connected, NewData,
                                     [CancelIdle, {reply, From, ok}]};
                                after_upgrade ->
                                    {keep_state, NewData,
                                     [CancelIdle, {reply, From, ok}]}
                            end;
                        {error, WaitErr} ->
                            close_h2(H2Conn),
                            h2_start_failure(Origin, From, WaitErr)
                    end;
                {error, ActivateErr} ->
                    close_h2(H2Conn),
                    h2_start_failure(Origin, From, ActivateErr)
            end;
        {error, Reason} ->
            h2_start_failure(Origin, From, Reason)
    end.

h2_start_failure(first_connect, From, Reason) ->
    {stop_and_reply, normal, [{reply, From, {error, Reason}}]};
h2_start_failure(after_upgrade, From, Reason) ->
    {keep_state_and_data, [{reply, From, {error, Reason}}]}.

%% @private Close an HTTP/2 connection, tolerating an already-closed one.
close_h2(H2Conn) ->
    try h2_connection:close(H2Conn) catch _:_ -> ok end.

%% An unshared connection lives and dies with its owner, so its streams need
%% no monitor of their own.
track_h2_stream(StreamId, Owner, StreamState,
                #conn_data{h2_shared = false, h2_streams = Streams} = Data) ->
    Data#conn_data{h2_streams = maps:put(StreamId, {Owner, StreamState}, Streams)};
track_h2_stream(StreamId, Owner, StreamState,
                #conn_data{h2_streams = Streams,
                           h2_stream_monitors = Monitors} = Data) ->
    OwnerPid = h2_stream_owner_pid(Owner),
    Monitor = erlang:monitor(process, OwnerPid),
    Data#conn_data{
        h2_streams = maps:put(StreamId, {Owner, StreamState}, Streams),
        h2_stream_monitors = maps:put(StreamId, Monitor, Monitors)
    }.

h2_stream_owner_pid({Pid, _Tag}) when is_pid(Pid) -> Pid;
h2_stream_owner_pid(Pid) when is_pid(Pid) -> Pid.

drop_h2_stream(StreamId,
               #conn_data{h2_streams = Streams,
                          h2_stream_monitors = Monitors} = Data) ->
    Data1 = cancel_h2_timer(StreamId, Data),
    Monitors2 = case maps:take(StreamId, Monitors) of
        {Monitor, Rest} ->
            _ = erlang:demonitor(Monitor, [flush]),
            Rest;
        error ->
            Monitors
    end,
    Data1#conn_data{
        h2_streams = maps:remove(StreamId, Streams),
        h2_stream_monitors = Monitors2
    }.

clear_h2_stream_monitors(#conn_data{h2_stream_monitors = Monitors} = Data) ->
    _ = maps:fold(fun(_StreamId, Monitor, ok) ->
        _ = erlang:demonitor(Monitor, [flush]),
        ok
    end, ok, Monitors),
    Data#conn_data{h2_stream_monitors = #{}}.

handle_h2_stream_owner_down(Ref, State,
                            #conn_data{h2_stream_monitors = Monitors} = Data) ->
    case [StreamId || {StreamId, Monitor} <- maps:to_list(Monitors),
                      Monitor =:= Ref] of
        [StreamId] ->
            _ = cancel_h2_stream(Data#conn_data.h2_conn, StreamId),
            Data1 = drop_h2_stream(StreamId, Data),
            h2_stream_owner_down_result(State, StreamId, Data1);
        [] ->
            keep_state_and_data
    end.

h2_stream_owner_down_result(streaming_body, StreamId,
                            #conn_data{h2_stream_id = StreamId} = Data) ->
    %% The caller streaming a request body died: its stream is gone, so the
    %% connection can take requests again, unless that stream was the last
    %% one of a GOAWAY drain.
    h2_upload_done(Data, []);
h2_stream_owner_down_result(_State, _StreamId, Data) ->
    h2_stream_result(Data, []).

%% @private Arm a per-stream recv_timeout watchdog for a sync HTTP/2 read so a
%% lost frame fails fast with {error, timeout} instead of blocking until the
%% connection dies. No-op when recv_timeout is infinity.
arm_h2_timer(StreamId, #conn_data{recv_timeout = Timeout, h2_timers = Timers} = Data) ->
    case Timeout of
        infinity ->
            Data;
        _ ->
            TRef = erlang:start_timer(Timeout, self(), {h2_recv_timeout, StreamId}),
            Data#conn_data{h2_timers = maps:put(StreamId, TRef, Timers)}
    end.

%% @private Cancel and forget a stream's recv_timeout watchdog, if any.
cancel_h2_timer(StreamId, #conn_data{h2_timers = Timers} = Data) ->
    case maps:take(StreamId, Timers) of
        {TRef, Timers2} ->
            _ = erlang:cancel_timer(TRef),
            Data#conn_data{h2_timers = Timers2};
        error ->
            Data
    end.

%% @private Reset a stream's recv_timeout watchdog after progress (headers or a
%% DATA frame). Keeps the deadline relative to the last byte received, matching
%% HTTP/1.1 per-recv timeout semantics. No-op for streams without a timer.
rearm_h2_timer(StreamId, #conn_data{h2_timers = Timers} = Data) ->
    case maps:is_key(StreamId, Timers) of
        true -> arm_h2_timer(StreamId, cancel_h2_timer(StreamId, Data));
        false -> Data
    end.

%% @private Cancel every outstanding recv_timeout watchdog (connection gone).
cancel_all_h2_timers(#conn_data{h2_timers = Timers} = Data) ->
    _ = maps:fold(fun(_StreamId, TRef, _Acc) -> erlang:cancel_timer(TRef) end,
                  ok, Timers),
    Data#conn_data{h2_timers = #{}}.

%% @private A recv_timeout watchdog fired: if it is still the live timer for the
%% stream and a sync reader is parked, fail that reader and drop the stream.
%% A stale timer (re-armed or already completed) is ignored.
handle_h2_recv_timeout(StreamId, TRef,
                       #conn_data{h2_streams = Streams, h2_timers = Timers,
                                  h2_conn = H2Conn} = Data) ->
    case maps:get(StreamId, Timers, undefined) of
        TRef ->
            case maps:get(StreamId, Streams, undefined) of
                {From, Inner} when is_tuple(Inner), element(1, Inner) =:= sync ->
                    %% RST_STREAM(CANCEL) the stalled stream so the peer stops
                    %% sending for it and the h2 layer drops it; otherwise the
                    %% pooled connection would be reused with an orphaned stream
                    %% still open (h2_conn_usable only checks the conn state).
                    _ = cancel_h2_stream(H2Conn, StreamId),
                    Data2 = drop_h2_stream(
                              StreamId,
                              Data#conn_data{request_from = undefined}),
                    h2_stream_result(
                      Data2,
                      [{reply, From, {error, timeout}}]);
                _ ->
                    {keep_state,
                     Data#conn_data{h2_timers = maps:remove(StreamId, Timers)}}
            end;
        _ ->
            {keep_state, Data}
    end.

%% @private RST_STREAM(CANCEL) a stalled HTTP/2 stream, tolerating a dead conn.
cancel_h2_stream(undefined, _StreamId) -> ok;
cancel_h2_stream(H2Conn, StreamId) ->
    try h2_connection:cancel_stream(H2Conn, StreamId) catch _:_ -> ok end.

%% @private Send an HTTP/2 request via the h2 library.
do_h2_request(From, Method, Path, Headers, Body, SendTimeout, Data) ->
    do_h2_send(From, Method, Path, Headers, Body,
               {sync, waiting_headers}, sync, SendTimeout, Data).

%% @private Send an HTTP/2 async request.
do_h2_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo,
                    _FollowRedirect, SendTimeout, Data) ->
    Ref = self(),
    StreamState = {async, AsyncMode, StreamTo, Ref, waiting_headers},
    do_h2_send(From, Method, Path, Headers, Body, StreamState,
               {async, Ref, StreamTo, AsyncMode}, SendTimeout, Data).

do_h2_send(From, _Method, _Path, _Headers, _Body, _StreamState, _Mode, _SendTimeout,
           #conn_data{h2_goaway = ErrorCode}) when ErrorCode =/= undefined ->
    %% Checked out before the pool dropped this draining connection. The peer
    %% would ignore a new stream, so refuse it here; nothing was sent.
    {keep_state_and_data, [{reply, From, {error, {goaway, ErrorCode}}}]};
do_h2_send(From, Method, Path, Headers, Body, StreamState, Mode, SendTimeout, Data) ->
    #conn_data{h2_conn = H2Conn} = Data,
    {MethodBin, PathBin, H2Headers} =
        build_h2_request_headers(Method, Path, Headers, Data),
    BodyBin = case Body of
        B when is_binary(B) -> B;
        L -> iolist_to_binary(L)
    end,
    %% once-mode async pulls response chunks via stream_next/1: open the
    %% stream with manual flow control so the peer stalls at one window until
    %% the consumer pulls (consume/3 releases bytes as chunks are delivered).
    StreamOpts = case Mode of
        {async, _, _, once} -> #{flow_control => manual};
        _ -> #{}
    end,
    %% h2_connection can die between pool checkout and this call; gen_statem:call
    %% on a dead pid raises exit:noproc. Catch that and normalise to an error
    %% so the caller sees {error, {closed, _}} instead of a gen_statem:call
    %% blowing up (issue #836).
    SendRes = try
        case BodyBin of
            <<>> -> h2_connection:send_request_headers(H2Conn, H2Headers, true, StreamOpts);
            _ ->
                case h2_connection:send_request_headers(H2Conn, H2Headers, false, StreamOpts) of
                    {ok, SId} ->
                        %% Block on flow control so bodies larger than the
                        %% peer's window wait for WINDOW_UPDATE instead of
                        %% failing with send_buffer_full.
                        case h2_send_data(H2Conn, SId, BodyBin, true, SendTimeout) of
                            ok -> {ok, SId};
                            {error, _} = E1 -> E1
                        end;
                    Err -> Err
                end
        end
    catch
        exit:{ExitReason, _} -> {error, {closed, ExitReason}};
        exit:ExitReason     -> {error, {closed, ExitReason}}
    end,
    case SendRes of
        {ok, StreamId} ->
            %% The entry's first element is the stream owner: the parked sync
            %% caller, or the async StreamTo pid. The async delivery clauses
            %% (h2_on_response/h2_on_data) match it against the StreamTo held
            %% in the stream state, so storing the gen_statem From tuple there
            %% would silently drop every async response.
            Owner = case Mode of
                sync -> From;
                {async, _Ref0, StreamTo0, _AsyncMode0} -> StreamTo0
            end,
            NewData0 = track_h2_stream(StreamId, Owner, StreamState, Data),
            NewData1 = NewData0#conn_data{
                method = MethodBin,
                path = PathBin,
                %% A streaming read is served by stream_body/1 and body/1,
                %% which look the stream up by id.
                h2_stream_id = case StreamState of
                    {stream, waiting_headers, _} -> StreamId;
                    _ -> NewData0#conn_data.h2_stream_id
                end
            },
            NewData = case Mode of
                sync ->
                    %% Watchdog the response so a lost frame fails fast rather
                    %% than blocking on the infinity gen_statem:call.
                    arm_h2_timer(StreamId, NewData1#conn_data{request_from = From});
                {async, Ref, StreamTo, AsyncMode} ->
                    NewData1#conn_data{
                        async = AsyncMode,
                        async_ref = Ref,
                        stream_to = StreamTo
                    }
            end,
            case Mode of
                sync -> {keep_state, NewData};
                {async, Ref1, _, _} -> {keep_state, NewData, [{reply, From, {ok, Ref1}}]}
            end;
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end.

%% @private Begin an HTTP/2 streaming-body request: send HEADERS without
%% END_STREAM and transition to streaming_body so the caller can push body
%% chunks via send_body_chunk/finish_send_body. Mirrors do_h3_send_headers/5.
do_h2_send_headers(From, _Method, _Path, _Headers, _ReqOpts,
                   #conn_data{h2_goaway = ErrorCode}) when ErrorCode =/= undefined ->
    {keep_state_and_data, [{reply, From, {error, {goaway, ErrorCode}}}]};
do_h2_send_headers(From, Method, Path, Headers, ReqOpts, Data) ->
    #conn_data{h2_conn = H2Conn} = Data,
    {MethodBin, PathBin, H2Headers} =
        build_h2_request_headers(Method, Path, Headers, Data),
    %% Effective send_timeout for this stream's body chunks. Stored in the
    %% per-request field, set at every stream start, so an override never
    %% leaks into later requests; the connection default stays untouched.
    SendTimeout = proplists:get_value(send_timeout, ReqOpts, Data#conn_data.send_timeout),
    %% h2_connection can die between pool checkout and this call; normalise the
    %% gen_statem:call exit into an error reply (issue #836).
    SendRes = try
        h2_connection:send_request_headers(H2Conn, H2Headers, false)
    catch
        exit:{ExitReason, _} -> {error, {closed, ExitReason}};
        exit:ExitReason      -> {error, {closed, ExitReason}}
    end,
    case SendRes of
        {ok, StreamId} ->
            Owner = element(1, From),
            NewData0 = track_h2_stream(StreamId, Owner, {stream, sending}, Data),
            NewData = NewData0#conn_data{
                h2_stream_id = StreamId,
                req_send_timeout = SendTimeout,
                method = MethodBin,
                path = PathBin,
                request_from = undefined
            },
            {next_state, streaming_body, NewData, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end.

%% @private h2 send_data with flow-control blocking. With a timeout (or
%% infinity) the caller parks in h2_connection until the peer's WINDOW_UPDATEs
%% drain the send buffer, so bodies larger than the flow-control window
%% complete instead of failing; {error, timeout} if the window never opens.
%% With nonblock, keeps the historical non-blocking behavior: h2_connection
%% buffers beyond the window and returns {error, send_buffer_full} past its
%% per-stream cap. Normalises a dead h2_connection exit to an error.
%%
%% Every caller abandons the request on a failed body send, so the half-sent
%% stream is RST_STREAM(CANCEL)ed here: its buffered body must not linger on
%% a shared connection, accumulating memory and stream capacity.
h2_send_data(H2Conn, StreamId, Bin, EndStream, SendTimeout) ->
    Res = try
        do_h2_send_data(H2Conn, StreamId, Bin, EndStream, SendTimeout)
    catch
        exit:{ExitReason, _} -> {error, {closed, ExitReason}};
        exit:ExitReason      -> {error, {closed, ExitReason}}
    end,
    h2_send_result(Res, H2Conn, StreamId).

h2_send_result(ok, _H2Conn, _StreamId) ->
    ok;
h2_send_result({error, _} = Error, H2Conn, StreamId) ->
    _ = cancel_h2_stream(H2Conn, StreamId),
    Error.

do_h2_send_data(H2Conn, StreamId, Bin, EndStream, nonblock) ->
    h2_connection:send_data(H2Conn, StreamId, Bin, EndStream);
do_h2_send_data(H2Conn, StreamId, Bin, EndStream, Timeout) ->
    h2_connection:send_data(H2Conn, StreamId, Bin, EndStream, #{block => Timeout}).

%% @private Drain a body-producer fun, sending each chunk as a non-final h2 DATA
%% frame. Mirrors stream_body_fun/3 (HTTP/1.1) and stream_body_fun_h3/3.
stream_body_fun_h2(H2Conn, StreamId, Fun, SendTimeout) when is_function(Fun, 0) ->
    case Fun() of
        {ok, Data} ->
            case h2_send_data(H2Conn, StreamId, iolist_to_binary(Data), false,
                              SendTimeout) of
                ok -> stream_body_fun_h2(H2Conn, StreamId, Fun, SendTimeout);
                Error -> Error
            end;
        eof ->
            ok;
        {error, _} = Error ->
            Error
    end;
stream_body_fun_h2(H2Conn, StreamId, {Fun, State}, SendTimeout) when is_function(Fun, 1) ->
    case Fun(State) of
        {ok, Data, NewState} ->
            case h2_send_data(H2Conn, StreamId, iolist_to_binary(Data), false,
                              SendTimeout) of
                ok -> stream_body_fun_h2(H2Conn, StreamId, {Fun, NewState}, SendTimeout);
                Error -> Error
            end;
        eof ->
            ok;
        {error, _} = Error ->
            Error
    end.

%% @private stream_body/1 over an HTTP/2 streaming response. Returns the next
%% buffered chunk, parks the caller until data arrives, or signals done.
%% Mirrors handle_h3_stream_body/3.
handle_h2_stream_body(From, #conn_data{h2_streams = Streams} = Data) ->
    StreamId = h2_read_stream(From, Data),
    case maps:get(StreamId, Streams, undefined) of
        {Owner, {stream, headers, Status, Hdrs, Buffer, undefined}} ->
            case Buffer of
                <<>> ->
                    %% No data yet - park the caller; h2_on_data/4 replies.
                    Streams2 = maps:put(StreamId,
                                        {From, {stream, headers, Status, Hdrs, <<>>, From}},
                                        Streams),
                    {keep_state, Data#conn_data{h2_streams = Streams2}};
                _ ->
                    Streams2 = maps:put(StreamId,
                                        {Owner, {stream, headers, Status, Hdrs, <<>>, undefined}},
                                        Streams),
                    {keep_state, Data#conn_data{h2_streams = Streams2},
                     [{reply, From, {ok, Buffer}}]}
            end;
        {_, {stream, done, _Status, _Hdrs, <<>>}} ->
            h2_stream_result(drop_h2_stream(StreamId, Data),
                             [{reply, From, done}]);
        {Owner, {stream, done, Status, Hdrs, Buffer}} ->
            %% Hand back the last buffered chunk; next call returns done.
            Streams2 = maps:put(StreamId, {Owner, {stream, done, Status, Hdrs, <<>>}}, Streams),
            {keep_state, Data#conn_data{h2_streams = Streams2}, [{reply, From, {ok, Buffer}}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, no_stream}}]}
    end.

%% @private body/1 over an HTTP/2 streaming response: accumulate the whole body
%% then reply. Parks the caller until END_STREAM (h2_on_data/4 replies).
handle_h2_read_body(From, #conn_data{h2_streams = Streams} = Data) ->
    StreamId = h2_read_stream(From, Data),
    case maps:get(StreamId, Streams, undefined) of
        {_, {stream, headers, Status, Hdrs, Buffer, undefined}} ->
            Streams2 = maps:put(StreamId,
                                {From, {stream, body_full, Status, Hdrs, Buffer, From}},
                                Streams),
            {keep_state, Data#conn_data{h2_streams = Streams2}};
        {_, {stream, done, _Status, _Hdrs, Buffer}} ->
            h2_stream_result(drop_h2_stream(StreamId, Data),
                             [{reply, From, {ok, Buffer}}]);
        _ ->
            {keep_state_and_data, [{reply, From, {error, no_stream}}]}
    end.

%% @private Build the method/path/header list for an HTTP/2 request.
%% Shared by the one-shot path (do_h2_send/8) and the streaming-body path
%% (the {send_headers,...} http2 clause) so both emit identical pseudo-headers.
build_h2_request_headers(Method, Path, Headers, Data) ->
    #conn_data{transport = Transport, host = Host, port = Port} = Data,
    MethodBin = to_binary(Method),
    PathBin = case Path of
        <<>> -> <<"/">>;
        _ -> to_binary(Path)
    end,
    Scheme = case Transport of
        hackney_ssl -> <<"https">>;
        _ -> <<"http">>
    end,
    Authority = build_authority(Host, Port, Transport),
    PseudoHeaders = [
        {<<":method">>, MethodBin},
        {<<":scheme">>, Scheme},
        {<<":authority">>, Authority},
        {<<":path">>, PathBin}
    ],
    H2Headers = PseudoHeaders ++ normalize_headers(Headers),
    {MethodBin, PathBin, H2Headers}.

%% @private Build authority (host:port) for HTTP/2 :authority pseudo-header
build_authority(Host, Port, Transport) ->
    HostBin = to_binary(Host),
    case {Transport, Port} of
        {hackney_ssl, 443} -> HostBin;
        {hackney_tcp, 80} -> HostBin;
        _ -> <<HostBin/binary, ":", (integer_to_binary(Port))/binary>>
    end.

%% @private Convert value to binary
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).

%% @private Normalize headers to binary key-value pairs for HTTP/2
%% Also filters out Host header since :authority pseudo-header is used instead.
%% Having both Host and :authority causes protocol_error on strict servers (e.g. Google).
%% The connection-specific headers go too: RFC 9113 8.2.2 forbids them, so the h2
%% layer refuses to send a block containing one and the request fails before it
%% reaches the socket. They are perfectly legal in HTTP/1.1, and a caller cannot
%% know which protocol ALPN picked, so hackney drops them here rather than failing
%% requests that are valid for its own API.
normalize_headers(Headers) ->
    lists:filtermap(fun({K, V}) ->
        KeyLower = hackney_bstr:to_lower(to_binary(K)),
        case is_connection_specific(KeyLower) of
            true -> false;
            false -> {true, {KeyLower, to_binary(V)}}
        end
    end, Headers).

%% @private Host is carried by :authority; the rest are the connection-specific
%% header fields of RFC 9113 8.2.2. TE is left alone: it is allowed with the
%% single value "trailers", and the h2 layer validates that itself.
is_connection_specific(<<"host">>) -> true;
is_connection_specific(<<"connection">>) -> true;
is_connection_specific(<<"keep-alive">>) -> true;
is_connection_specific(<<"proxy-connection">>) -> true;
is_connection_specific(<<"transfer-encoding">>) -> true;
is_connection_specific(<<"upgrade">>) -> true;
is_connection_specific(_) -> false.

%% @private Handle a {h2, Conn, Event} owner message from the h2 library.
handle_h2_event({informational, _StreamId, _Status, _Headers}, Data) ->
    %% 1xx interim responses: ignore for now (same as previous HPACK path).
    {keep_state, Data};
handle_h2_event({response, StreamId, Status, Headers}, Data) ->
    h2_on_response(StreamId, Status, Headers, Data);
handle_h2_event({data, StreamId, Body, EndStream}, Data) ->
    h2_on_data(StreamId, Body, EndStream, Data);
handle_h2_event({trailers, StreamId, _Headers}, Data) ->
    %% RFC 9113 §5.1: a trailing HEADERS frame carries END_STREAM. The h2 lib
    %% delivers it as a {trailers,...} event with no terminal DATA frame, so
    %% treat it as end-of-stream to release a reader parked on END_STREAM
    %% (otherwise the body read hangs until the connection dies).
    h2_on_data(StreamId, <<>>, true, Data);
handle_h2_event({stream_reset, StreamId, ErrorCode}, Data) ->
    h2_on_stream_reset(StreamId, ErrorCode, Data);
handle_h2_event({goaway, LastStreamId, ErrorCode}, Data) ->
    h2_on_goaway(LastStreamId, ErrorCode, Data);
handle_h2_event({closed, Reason}, Data) ->
    h2_on_closed(Reason, Data);
handle_h2_event(_Other, Data) ->
    {keep_state, Data}.

h2_on_response(StreamId, Status, Headers, Data) ->
    maybe_record_altsvc(Headers, Data),
    #conn_data{h2_streams = Streams} = Data,
    case maps:get(StreamId, Streams, undefined) of
        {From, {sync, waiting_headers}} ->
            %% Headers alone with END_STREAM arrive here when the server
            %% already finished the response (body sent via empty data).
            Streams2 = maps:put(StreamId,
                                {From, {sync, body, Status, Headers, <<>>}},
                                Streams),
            Data2 = rearm_h2_timer(StreamId,
                                   Data#conn_data{h2_streams = Streams2,
                                                  status = Status,
                                                  response_headers = Headers}),
            {keep_state, Data2};
        {StreamTo, {async, once, StreamTo, Ref, waiting_headers}} ->
            %% once mode, same contract as HTTP/1.1: status and headers are
            %% delivered eagerly, then each stream_next/1 pulls exactly one
            %% message (a body chunk or done). Queue holds undelivered items;
            %% Credit is 1 when a stream_next arrived before any data.
            StreamTo ! {hackney_response, Ref, {status, Status, <<>>}},
            StreamTo ! {hackney_response, Ref, {headers, Headers}},
            Streams2 = maps:put(StreamId,
                                {StreamTo, {async_once, StreamTo, Ref, [], 0}},
                                Streams),
            {keep_state, Data#conn_data{h2_streams = Streams2,
                                        status = Status,
                                        response_headers = Headers}};
        {StreamTo, {async, AsyncMode, StreamTo, Ref, waiting_headers}} ->
            StreamTo ! {hackney_response, Ref, {status, Status, <<>>}},
            StreamTo ! {hackney_response, Ref, {headers, Headers}},
            Streams2 = maps:put(StreamId,
                                {StreamTo, {async, AsyncMode, StreamTo, Ref,
                                            streaming, Status, Headers}},
                                Streams),
            {keep_state, Data#conn_data{h2_streams = Streams2,
                                        status = Status,
                                        response_headers = Headers}};
        {_, {stream, sending}} ->
            %% Streaming body: response arrived before start_response/1; buffer
            %% the headers so start_response can reply immediately.
            Streams2 = maps:put(StreamId,
                                {undefined, {stream, headers, Status, Headers, <<>>, undefined}},
                                Streams),
            {keep_state, Data#conn_data{h2_streams = Streams2,
                                        status = Status,
                                        response_headers = Headers}};
        {Owner, {stream, waiting_headers, From}} ->
            %% start_response/1 or request_streaming/5 is parked - reply with
            %% status/headers now. The owner is kept so the reader of this
            %% stream is found by caller, not by the connection's last id.
            Streams2 = maps:put(StreamId,
                                {Owner, {stream, headers, Status, Headers, <<>>, undefined}},
                                Streams),
            {keep_state, Data#conn_data{h2_streams = Streams2,
                                        status = Status,
                                        response_headers = Headers},
             [{reply, From, {ok, Status, Headers, self()}}]};
        _ ->
            {keep_state, Data}
    end.

%% @private Deliver exactly one queued item of a once-mode h2 async stream:
%% a body chunk (consume/3 reopens exactly those bytes of the peer's window)
%% or done (stream finished, cleanup). An empty queue parks the pull as a
%% credit; the next DATA frame delivers immediately.
deliver_once_item(StreamId, StreamTo, Ref, [{data, Body} | Rest], Data) ->
    StreamTo ! {hackney_response, Ref, Body},
    _ = try h2_connection:consume(Data#conn_data.h2_conn, StreamId, byte_size(Body))
        catch _:_ -> ok end,
    Streams2 = maps:put(StreamId,
                        {StreamTo, {async_once, StreamTo, Ref, Rest, 0}},
                        Data#conn_data.h2_streams),
    {keep_state, Data#conn_data{h2_streams = Streams2}};
deliver_once_item(StreamId, StreamTo, Ref, [done], Data) ->
    StreamTo ! {hackney_response, Ref, done},
    Data1 = drop_h2_stream(StreamId, Data),
    h2_stream_result(Data1#conn_data{async = false,
                                     async_ref = undefined,
                                     stream_to = undefined}, []);
deliver_once_item(StreamId, StreamTo, Ref, [], Data) ->
    Streams2 = maps:put(StreamId,
                        {StreamTo, {async_once, StreamTo, Ref, [], 1}},
                        Data#conn_data.h2_streams),
    {keep_state, Data#conn_data{h2_streams = Streams2}}.

%% @private Route a stream_next pull to the caller's once-mode h2 stream.
%% With several once-mode streams for the same caller on a shared connection,
%% the oldest stream id wins (the pull API cannot address a specific stream).
handle_h2_stream_next(Caller, #conn_data{h2_streams = Streams} = Data) ->
    OnceIds = [SId || {SId, {StreamTo, {async_once, StreamTo, _, _, _}}}
                          <- maps:to_list(Streams),
                      StreamTo =:= Caller orelse Caller =:= undefined],
    case lists:sort(OnceIds) of
        [] ->
            keep_state_and_data;
        [StreamId | _] ->
            {StreamTo, {async_once, StreamTo, Ref, Queue, _Credit}} =
                maps:get(StreamId, Streams),
            deliver_once_item(StreamId, StreamTo, Ref, Queue, Data)
    end.

h2_on_data(StreamId, Body, EndStream, Data) ->
    #conn_data{h2_streams = Streams, max_body_size = Max} = Data,
    case maps:get(StreamId, Streams, undefined) of
        {From, {sync, body, Status, Headers, Acc}} ->
            case body_within_limit(byte_size(Acc) + byte_size(Body), Max) of
                false ->
                    h2_body_too_large(StreamId, From,
                                      Data#conn_data{request_from = undefined});
                true ->
                    h2_on_sync_data(StreamId, From, Status, Headers,
                                    <<Acc/binary, Body/binary>>, EndStream, Data)
            end;
        {StreamTo, {async_once, StreamTo, Ref, Queue, Credit}} ->
            %% Queue the frame; deliver only when the consumer has pulled.
            %% The stream runs manual flow control, so undelivered bytes keep
            %% the peer's window closed (bounded in-flight data).
            Queue1 = Queue ++ [{data, Body} || Body =/= <<>>]
                           ++ [done || EndStream],
            case Credit of
                1 ->
                    deliver_once_item(StreamId, StreamTo, Ref, Queue1, Data);
                0 ->
                    Streams2 = maps:put(StreamId,
                                        {StreamTo, {async_once, StreamTo, Ref, Queue1, 0}},
                                        Streams),
                    {keep_state, Data#conn_data{h2_streams = Streams2}}
            end;
        {StreamTo, {async, AsyncMode, StreamTo, Ref, streaming, Status, Headers}} ->
            _ = case byte_size(Body) of
                0 -> ok;
                _ -> StreamTo ! {hackney_response, Ref, Body}
            end,
            case EndStream of
                true ->
                    StreamTo ! {hackney_response, Ref, done},
                    Data2 = drop_h2_stream(StreamId, Data),
                    h2_stream_result(
                      Data2#conn_data{async = false,
                                      async_ref = undefined,
                                      stream_to = undefined}, []);
                false ->
                    NewState = {async, AsyncMode, StreamTo, Ref, streaming,
                                Status, Headers},
                    Streams2 = maps:put(StreamId, {StreamTo, NewState}, Streams),
                    {keep_state, Data#conn_data{h2_streams = Streams2}}
            end;
        {Owner, {stream, headers, Status, Headers, Buffer, Pending}} ->
            %% Streaming-body response, pull reads via stream_body/1.
            NewBuffer = <<Buffer/binary, Body/binary>>,
            case Pending of
                undefined ->
                    NextState = case EndStream of
                        true -> {stream, done, Status, Headers, NewBuffer};
                        false -> {stream, headers, Status, Headers, NewBuffer, undefined}
                    end,
                    %% Keep the owner: a reader of this stream is found by
                    %% caller, and its body may land before it reads.
                    Streams2 = maps:put(StreamId, {Owner, NextState}, Streams),
                    {keep_state, Data#conn_data{h2_streams = Streams2}};
                From when NewBuffer =/= <<>> ->
                    NextState = case EndStream of
                        true -> {stream, done, Status, Headers, <<>>};
                        false -> {stream, headers, Status, Headers, <<>>, undefined}
                    end,
                    Streams2 = maps:put(StreamId, {undefined, NextState}, Streams),
                    {keep_state, Data#conn_data{h2_streams = Streams2},
                     [{reply, From, {ok, NewBuffer}}]};
                From when EndStream ->
                    %% Parked caller, no buffered bytes, stream ended -> done.
                    h2_stream_result(drop_h2_stream(StreamId, Data),
                                     [{reply, From, done}]);
                _From ->
                    %% Empty DATA frame without END_STREAM: keep the caller parked.
                    {keep_state, Data}
            end;
        {From, {stream, body_full, Status, Headers, Acc, From}} ->
            %% Full-body read via body/1 after start_response/1.
            case body_within_limit(byte_size(Acc) + byte_size(Body), Max) of
                false ->
                    h2_body_too_large(StreamId, From, Data);
                true ->
                    NewAcc = <<Acc/binary, Body/binary>>,
                    case EndStream of
                        true ->
                            h2_stream_result(drop_h2_stream(StreamId, Data),
                                             [{reply, From, {ok, NewAcc}}]);
                        false ->
                            Streams2 = maps:put(StreamId,
                                                {From, {stream, body_full, Status, Headers, NewAcc, From}},
                                                Streams),
                            {keep_state, Data#conn_data{h2_streams = Streams2}}
                    end
            end;
        _ ->
            {keep_state, Data}
    end.

%% @private DATA for a sync request whose body is buffered whole.
h2_on_sync_data(StreamId, From, Status, Headers, NewAcc, true, Data) ->
    Data2 = drop_h2_stream(StreamId, Data#conn_data{request_from = undefined}),
    h2_stream_result(Data2, [{reply, From, {ok, Status, Headers, NewAcc}}]);
h2_on_sync_data(StreamId, From, Status, Headers, NewAcc, false,
                #conn_data{h2_streams = Streams} = Data) ->
    Streams2 = maps:put(StreamId, {From, {sync, body, Status, Headers, NewAcc}}, Streams),
    Data2 = rearm_h2_timer(StreamId, Data#conn_data{h2_streams = Streams2}),
    {keep_state, Data2}.

%% @private A buffered body passed max_body_size: RST_STREAM(CANCEL) it so the
%% peer stops sending (as the recv_timeout watchdog does), drop the stream and
%% fail the parked reader. The connection itself stays usable.
h2_body_too_large(StreamId, From, #conn_data{h2_conn = H2Conn} = Data) ->
    _ = cancel_h2_stream(H2Conn, StreamId),
    h2_stream_result(drop_h2_stream(StreamId, Data),
                     [{reply, From, {error, body_too_large}}]).

h2_on_stream_reset(StreamId, ErrorCode, Data) ->
    #conn_data{h2_streams = Streams} = Data,
    case maps:get(StreamId, Streams, undefined) of
        {From, Inner} when is_tuple(Inner), element(1, Inner) =:= sync ->
            Data2 = drop_h2_stream(
                      StreamId,
                      Data#conn_data{request_from = undefined}),
            h2_stream_result(Data2,
                             [{reply, From, {error, {stream_error, ErrorCode}}}]);
        {StreamTo, {async, _, StreamTo, Ref, _, _, _}} ->
            StreamTo ! {hackney_response, Ref, {error, {stream_error, ErrorCode}}},
            h2_stream_result(drop_h2_stream(StreamId, Data), []);
        {StreamTo, {async, _, StreamTo, Ref, _}} ->
            StreamTo ! {hackney_response, Ref, {error, {stream_error, ErrorCode}}},
            h2_stream_result(drop_h2_stream(StreamId, Data), []);
        {StreamTo, {async_once, StreamTo, Ref, _, _}} ->
            StreamTo ! {hackney_response, Ref, {error, {stream_error, ErrorCode}}},
            h2_stream_result(drop_h2_stream(StreamId, Data), []);
        {_, Inner} when is_tuple(Inner), element(1, Inner) =:= stream ->
            %% Streaming-body stream: reply to any parked caller and drop it so a
            %% later stream_body/start_response sees {error, no_stream}.
            Replies = case h2_stream_parked_from(Inner) of
                undefined -> [];
                From -> [{reply, From, {error, {stream_error, ErrorCode}}}]
            end,
            h2_stream_result(
              drop_h2_stream(
                StreamId,
                Data#conn_data{request_from = undefined}),
              Replies);
        _ ->
            {keep_state, Data}
    end.

%% @private Extract the gen_statem caller parked inside a streaming-body
%% h2 stream state, or undefined when no caller is currently blocked.
h2_stream_parked_from({stream, waiting_headers, From}) -> From;
h2_stream_parked_from({stream, headers, _, _, _, From}) -> From;
h2_stream_parked_from({stream, body_full, _, _, _, From}) -> From;
h2_stream_parked_from(_) -> undefined.

%% @private Result for a handler that just removed an HTTP/2 stream: a shared
%% connection left with no stream arms its idle timer, and one draining after
%% a GOAWAY closes once its last accepted stream has ended.
h2_stream_result(#conn_data{h2_goaway = ErrorCode, h2_streams = Streams} = Data,
                 Replies)
  when ErrorCode =/= undefined, map_size(Streams) =:= 0 ->
    {next_state, closed, Data2, CloseReplies} = h2_close_on_goaway(ErrorCode, Data),
    {next_state, closed, Data2, Replies ++ CloseReplies};
h2_stream_result(Data, Replies) ->
    {keep_state, Data, Replies ++ h2_idle_actions(Data)}.

%% @private Arm the idle timer of a shared HTTP/2 connection with no stream
%% open. Re-arming replaces the previous timer, so it always counts from the
%% moment the last stream finished.
h2_idle_actions(#conn_data{h2_shared = true, h2_streams = Streams,
                           idle_timeout = Timeout})
  when map_size(Streams) =:= 0, Timeout =/= infinity ->
    [{{timeout, h2_idle}, Timeout, h2_idle}];
h2_idle_actions(_Data) ->
    [].

%% RFC 9113 6.8: a GOAWAY refuses the streams above LastStreamId, but the peer
%% may still process the ones up to it and keeps the connection open to finish
%% them. Fail only the refused streams, leave the pool so no new request lands
%% here, and close once the accepted streams end. Aborting those too reported
%% requests the server went on to complete as failed.
%%
%% A streaming-body request the GOAWAY refuses has no caller parked on it, so
%% it is kept as a `refused' entry and the connection stays in streaming_body
%% until the caller's next call learns of it.
h2_on_goaway(LastStreamId, ErrorCode, #conn_data{h2_streams = Streams} = Data) ->
    Refused = [SId || SId <- maps:keys(Streams), SId > LastStreamId],
    {Replies, Data1} = abort_h2_streams(Refused, ErrorCode, Data),
    case map_size(Data1#conn_data.h2_streams) =:= 0 of
        true ->
            {next_state, closed, Data2, CloseReplies} = h2_close_on_goaway(ErrorCode, Data1),
            {next_state, closed, Data2, Replies ++ CloseReplies};
        false ->
            ok = leave_h2_pool(Data1),
            {keep_state, Data1#conn_data{h2_goaway = ErrorCode}, Replies}
    end.

%% @private Leave streaming_body once the upload stream is gone: back to
%% connected, or closed when it was the last stream of a GOAWAY drain.
h2_upload_done(Data, Replies) ->
    case h2_stream_result(Data#conn_data{h2_stream_id = undefined,
                                         request_from = undefined}, Replies) of
        {keep_state, Data1, Actions} ->
            {next_state, connected, Data1,
             [{state_timeout, infinity, idle_timeout} | Actions]};
        Closed ->
            Closed
    end.

%% @private A body send failed and the connection is unusable: fail the other
%% streams on it too instead of leaving their callers waiting.
h2_upload_failed(From, Reason, Data) ->
    {next_state, closed, Data1, Replies} = h2_teardown({closed, Reason}, Data),
    {next_state, closed, Data1, [{reply, From, {error, Reason}} | Replies]}.

leave_h2_pool(#conn_data{pool_pid = PoolPid}) when is_pid(PoolPid) ->
    gen_server:cast(PoolPid, {unregister_h2, self()});
leave_h2_pool(_Data) ->
    ok.

h2_close_on_goaway(ErrorCode, Data) ->
    %% A GOAWAY means the peer will not service new streams on this connection.
    %% AWS ALBs recycle connections this way, sending GOAWAY but keeping the
    %% socket open for a drain window. Leaving the conn `connected` and pooled
    %% made checkout_h2/h2_conn_usable keep handing it out, so every reused
    %% request opened a stream past last_stream_id that the peer ignored and hung
    %% to recv_timeout. Tear the connection down and transition to `closed` (like
    %% h2_on_closed/2): the pool then stops reusing it (h2_conn_usable requires
    %% `connected`) and new requests dial a fresh connection.
    h2_teardown({goaway, ErrorCode}, Data).

h2_teardown(Err, #conn_data{h2_conn = H2Conn, h2_mon = H2Mon} = Data) ->
    {Replies, Data1} = collect_h2_aborts(Err, Data),
    Data2 = cancel_all_h2_timers(Data1),
    _ = case H2Mon of
        undefined -> ok;
        _ -> erlang:demonitor(H2Mon, [flush])
    end,
    close_h2(H2Conn),
    Stripped = Data2#conn_data{h2_conn = undefined, h2_mon = undefined,
                               socket = undefined, no_reuse = true},
    {next_state, closed, Stripped, Replies}.

h2_on_closed(Reason, Data) ->
    {Replies, Data1} = collect_h2_aborts({closed, Reason}, Data),
    Data2 = cancel_all_h2_timers(Data1),
    Stripped = Data2#conn_data{h2_conn = undefined, h2_mon = undefined,
                               socket = undefined},
    %% Transition to closed. For pooled conns, closed(enter,...) keeps the
    %% process alive for ?CLOSED_GRACE_MS so calls from workers that raced
    %% the pool checkout get a proper error reply (issue #836).
    {next_state, closed, Stripped, Replies}.

collect_h2_aborts(Err, #conn_data{h2_streams = Streams} = Data) ->
    Replies = h2_abort_replies(Err, Streams),
    Data1 = clear_h2_stream_monitors(
              Data#conn_data{h2_streams = #{}, request_from = undefined}),
    {Replies, Data1}.

%% @private Fail the refused streams and keep the rest of the connection
%% running. A request body still being sent has no caller parked on it, so
%% its stream is kept as a `refused' entry for the caller's next call to find.
%% Each newly refused stream is reset so the h2 layer drops it too; a marker
%% left by an earlier GOAWAY was reset then.
abort_h2_streams(StreamIds, ErrorCode, #conn_data{h2_streams = Streams,
                                                  h2_conn = H2Conn} = Data) ->
    Refused = maps:with(StreamIds, Streams),
    Replies = h2_abort_replies({goaway, ErrorCode}, Refused),
    Data1 = maps:fold(fun
        (_StreamId, {_Owner, {stream, refused, _}}, D) ->
            D;
        (StreamId, {Owner, {stream, sending}}, D) ->
            _ = cancel_h2_stream(H2Conn, StreamId),
            D#conn_data{h2_streams = maps:put(StreamId, {Owner, {stream, refused, ErrorCode}},
                                              D#conn_data.h2_streams)};
        (StreamId, _Entry, D) ->
            _ = cancel_h2_stream(H2Conn, StreamId),
            drop_h2_stream(StreamId, D)
    end, Data, Refused),
    {Replies, Data1}.

h2_abort_replies(Err, Streams) ->
    maps:fold(fun
        (_SId, {From, {sync, _}}, Acc) ->
            [{reply, From, {error, Err}} | Acc];
        (_SId, {From, {sync, body, _, _, _}}, Acc) ->
            [{reply, From, {error, Err}} | Acc];
        (_SId, {StreamTo, {async, _, StreamTo, Ref, _}}, Acc) ->
            StreamTo ! {hackney_response, Ref, {error, Err}},
            Acc;
        (_SId, {StreamTo, {async, _, StreamTo, Ref, _, _, _}}, Acc) ->
            StreamTo ! {hackney_response, Ref, {error, Err}},
            Acc;
        (_SId, {StreamTo, {async_once, StreamTo, Ref, _, _}}, Acc) ->
            StreamTo ! {hackney_response, Ref, {error, Err}},
            Acc;
        (_SId, {_, Inner}, Acc) when is_tuple(Inner), element(1, Inner) =:= stream ->
            case h2_stream_parked_from(Inner) of
                undefined -> Acc;
                From -> [{reply, From, {error, Err}} | Acc]
            end;
        (_, _, Acc) -> Acc
    end, [], Streams).


%%====================================================================
%% HTTP/3 Support Functions
%%====================================================================

%% @private Send an HTTP/3 request
%% Opens a stream, sends headers and optionally body
do_h3_request(From, _Method, _Path, _Headers, _Body, #conn_data{h3_goaway = GoawayId})
  when GoawayId =/= undefined ->
    %% Draining after a GOAWAY: the peer would refuse a new stream.
    {keep_state_and_data, [{reply, From, {error, {goaway, no_error}}}]};
do_h3_request(From, Method, Path, Headers, Body, Data) ->
    #conn_data{
        host = Host,
        h3_conn = ConnRef,
        h3_streams = Streams
    } = Data,

    MethodBin = to_binary(Method),
    PathBin = case Path of
        <<>> -> <<"/">>;
        _ -> to_binary(Path)
    end,
    HostBin = to_binary(Host),

    %% Use hackney_h3 to send request
    case hackney_h3:send_request(ConnRef, MethodBin, HostBin, PathBin, normalize_headers(Headers), Body) of
        {ok, StreamId, _NewStreams} ->
            %% Track stream for response
            UpdatedStreams = maps:put(StreamId, {From, waiting_headers}, Streams),
            NewData = Data#conn_data{
                h3_streams = UpdatedStreams,
                method = MethodBin,
                path = PathBin,
                request_from = From
            },
            %% Stay in connected state, wait for response via QUIC messages
            {keep_state, NewData};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end.

%% @private Send an HTTP/3 async request
%% Opens a stream, sends headers and body, sets up async streaming
do_h3_request_async(From, _Method, _Path, _Headers, _Body, _AsyncMode, _StreamTo, #conn_data{h3_goaway = GoawayId})
  when GoawayId =/= undefined ->
    %% Draining after a GOAWAY: the peer would refuse a new stream.
    {keep_state_and_data, [{reply, From, {error, {goaway, no_error}}}]};
do_h3_request_async(From, Method, Path, Headers, Body, AsyncMode, StreamTo, Data) ->
    #conn_data{
        host = Host,
        h3_conn = ConnRef,
        h3_streams = Streams
    } = Data,

    MethodBin = to_binary(Method),
    PathBin = case Path of
        <<>> -> <<"/">>;
        _ -> to_binary(Path)
    end,
    HostBin = to_binary(Host),

    %% Use connection PID as async ref
    Ref = self(),

    %% Use hackney_h3 to send request
    case hackney_h3:send_request(ConnRef, MethodBin, HostBin, PathBin, normalize_headers(Headers), Body) of
        {ok, StreamId, _NewStreams} ->
            %% Track stream with async info
            StreamState = {waiting_headers_async, AsyncMode, StreamTo, Ref},
            UpdatedStreams = maps:put(StreamId, {From, StreamState}, Streams),
            NewData = Data#conn_data{
                h3_streams = UpdatedStreams,
                method = MethodBin,
                path = PathBin,
                request_from = From,
                async = AsyncMode,
                async_ref = Ref,
                stream_to = StreamTo
            },
            %% Reply immediately with {ok, Ref} for async
            {keep_state, NewData, [{reply, From, {ok, Ref}}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end.

%% @private Send an HTTP/3 request with streaming body reads
%% Returns {ok, Status, Headers} and allows subsequent stream_body calls
do_h3_request_streaming(From, _Method, _Path, _Headers, _Body, #conn_data{h3_goaway = GoawayId})
  when GoawayId =/= undefined ->
    %% Draining after a GOAWAY: the peer would refuse a new stream.
    {keep_state_and_data, [{reply, From, {error, {goaway, no_error}}}]};
do_h3_request_streaming(From, Method, Path, Headers, Body, Data) ->
    #conn_data{
        host = Host,
        h3_conn = ConnRef,
        h3_streams = Streams
    } = Data,

    MethodBin = to_binary(Method),
    PathBin = case Path of
        <<>> -> <<"/">>;
        _ -> to_binary(Path)
    end,
    HostBin = to_binary(Host),

    %% Use hackney_h3 to send request
    case hackney_h3:send_request(ConnRef, MethodBin, HostBin, PathBin, normalize_headers(Headers), Body) of
        {ok, StreamId, _NewStreams} ->
            %% Track stream for streaming response
            StreamState = {waiting_headers_streaming, From},
            UpdatedStreams = maps:put(StreamId, {From, StreamState}, Streams),
            NewData = Data#conn_data{
                h3_streams = UpdatedStreams,
                method = MethodBin,
                path = PathBin,
                request_from = From
            },
            %% Stay in connected state, wait for headers
            {keep_state, NewData};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end.

%% @private Send HTTP/3 request headers only (for streaming body mode)
%% Returns ok and transitions to streaming_body state
do_h3_send_headers(From, _Method, _Path, _Headers, #conn_data{h3_goaway = GoawayId})
  when GoawayId =/= undefined ->
    %% Draining after a GOAWAY: the peer would refuse a new stream.
    {keep_state_and_data, [{reply, From, {error, {goaway, no_error}}}]};
do_h3_send_headers(From, Method, Path, Headers, Data) ->
    #conn_data{
        host = Host,
        h3_conn = ConnRef,
        h3_streams = Streams
    } = Data,

    MethodBin = to_binary(Method),
    PathBin = case Path of
        <<>> -> <<"/">>;
        _ -> to_binary(Path)
    end,
    HostBin = to_binary(Host),

    %% Use hackney_h3 to send headers only (Fin=false)
    case hackney_h3:send_request_headers(ConnRef, MethodBin, HostBin, PathBin, normalize_headers(Headers)) of
        {ok, StreamId, _NewStreams} ->
            %% Track stream for response (will wait after body is sent)
            StreamState = {sending_body, From},
            UpdatedStreams = maps:put(StreamId, {From, StreamState}, Streams),
            NewData = Data#conn_data{
                h3_streams = UpdatedStreams,
                h3_stream_id = StreamId,
                method = MethodBin,
                path = PathBin,
                request_from = undefined
            },
            %% Transition to streaming_body state
            {next_state, streaming_body, NewData, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end.

%% @private Handle HTTP/3 stream_body call
%% Returns buffered chunk, waits for data, or returns done
handle_h3_stream_body(From, Streams, Data) ->
    %% Find the stream this caller is reading
    case find_streaming_stream(From, Streams) of
        {ok, StreamId, {streaming_body, Status, Headers, Buffer, undefined}} ->
            %% No pending caller, check buffer
            case Buffer of
                <<>> ->
                    %% No data buffered - wait for QUIC data
                    NewStreamState = {streaming_body, Status, Headers, <<>>, From},
                    UpdatedStreams = maps:put(StreamId, {undefined, NewStreamState}, Streams),
                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams}};
                _ ->
                    %% Return buffered data
                    NewStreamState = {streaming_body, Status, Headers, <<>>, undefined},
                    UpdatedStreams = maps:put(StreamId, {undefined, NewStreamState}, Streams),
                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
                     [{reply, From, {ok, Buffer}}]}
            end;
        {ok, StreamId, {streaming_body_done, _Status, _Headers}} ->
            %% Stream complete, no more data
            UpdatedStreams = maps:remove(StreamId, Streams),
            {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
             [{reply, From, done}]};
        {ok, StreamId, {streaming_body_final, _Status, _Headers, FinalBuffer}} ->
            %% Stream complete with final chunk
            case FinalBuffer of
                <<>> ->
                    UpdatedStreams = maps:remove(StreamId, Streams),
                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
                     [{reply, From, done}]};
                _ ->
                    %% Return final chunk, next call gets done
                    NewStreamState = {streaming_body_done, _Status, _Headers},
                    UpdatedStreams = maps:put(StreamId, {undefined, NewStreamState}, Streams),
                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
                     [{reply, From, {ok, FinalBuffer}}]}
            end;
        {ok, _StreamId, _OtherState} ->
            %% Stream in wrong state
            {keep_state_and_data, [{reply, From, {error, not_streaming}}]};
        none ->
            %% No streaming stream found
            {keep_state_and_data, [{reply, From, {error, no_stream}}]}
    end.

%% @private Handle HTTP/3 body call: the rest of the streaming response in
%% one binary, returned at once if it already ended or when its FIN arrives.
handle_h3_read_body(From, Streams, Data) ->
    case find_streaming_stream(From, Streams) of
        {ok, StreamId, {streaming_body, Status, Headers, Buffer, undefined}} ->
            NewStreamState = {streaming_body_full, Status, Headers, Buffer, From},
            {keep_state, Data#conn_data{h3_streams = maps:put(StreamId,
                {undefined, NewStreamState}, Streams)}};
        {ok, StreamId, {streaming_body_final, _Status, _Headers, Buffer}} ->
            {keep_state, Data#conn_data{h3_streams = maps:remove(StreamId, Streams)},
             [{reply, From, {ok, Buffer}}]};
        {ok, StreamId, {streaming_body_done, _Status, _Headers}} ->
            {keep_state, Data#conn_data{h3_streams = maps:remove(StreamId, Streams)},
             [{reply, From, {ok, <<>>}}]};
        {ok, _StreamId, _OtherState} ->
            {keep_state_and_data, [{reply, From, {error, not_streaming}}]};
        none ->
            {keep_state_and_data, [{reply, From, {error, no_stream}}]}
    end.

%% @private The HTTP/2 stream a reader owns. Several callers can have a
%% stream open on one connection, so a read is resolved by the calling
%% process; the streaming-body upload path has no owner recorded per read
%% and falls back to the connection's current stream id.
h2_read_stream(From, #conn_data{h2_stream_id = StreamId, h2_streams = Streams}) ->
    Caller = h2_stream_owner_pid(From),
    Owned = [Id || {Id, {Owner, State}} <- maps:to_list(Streams),
                   Owner =/= undefined,
                   h2_stream_owner_pid(Owner) =:= Caller,
                   is_tuple(State), element(1, State) =:= stream],
    case Owned of
        [Id | _] -> Id;
        [] -> StreamId
    end.

%% @private Find the stream a reader owns, or any streaming one when the
%% caller owns none: several callers can read on one connection, and the
%% streaming-body upload path records no owner for its reads.
find_streaming_stream(From, Streams) ->
    Caller = h3_stream_owner_pid(From),
    Owned = maps:fold(fun
        (StreamId, {Owner, State}, none) when Owner =/= undefined ->
            case h3_stream_owner_pid(Owner) =:= Caller andalso is_streaming_state(State) of
                true -> {ok, StreamId, State};
                false -> none
            end;
        (_, _, Acc) -> Acc
    end, none, Streams),
    case Owned of
        none -> find_streaming_stream(Streams);
        Found -> Found
    end.

h3_stream_owner_pid({Pid, _Tag}) when is_pid(Pid) -> Pid;
h3_stream_owner_pid(Pid) when is_pid(Pid) -> Pid;
h3_stream_owner_pid(_) -> undefined.

is_streaming_state(State) when is_tuple(State) ->
    lists:member(element(1, State),
                 [streaming_body, streaming_body_done, streaming_body_final,
                  streaming_body_full]);
is_streaming_state(_) ->
    false.

%% @private Find a stream in streaming mode
find_streaming_stream(Streams) ->
    Result = maps:fold(fun
        (StreamId, {_, {streaming_body, _, _, _, _} = State}, none) ->
            {ok, StreamId, State};
        (StreamId, {_, {streaming_body_done, _, _} = State}, none) ->
            {ok, StreamId, State};
        (StreamId, {_, {streaming_body_final, _, _, _} = State}, none) ->
            {ok, StreamId, State};
        (_, _, Acc) ->
            Acc
    end, none, Streams),
    Result.

%% @private Handle HTTP/3 response headers
handle_h3_headers(StreamId, Headers, Fin, Streams, Data) ->
    case hackney_h3:parse_response_headers(Headers) of
        {ok, Status, RespHeaders} ->
            %% RespHeaders from hackney_h3:parse_response_headers is already a list
            HeadersList = RespHeaders,
            maybe_record_altsvc(HeadersList, Data),
            case maps:get(StreamId, Streams, undefined) of
                {From, waiting_headers} ->
                    case Fin of
                        true ->
                            %% Headers with Fin=true means no body (redirect, 204, 304, HEAD response)
                            %% Reply immediately with empty body
                            UpdatedStreams = maps:remove(StreamId, Streams),
                            {keep_state, Data#conn_data{
                                h3_streams = UpdatedStreams,
                                status = Status,
                                response_headers = RespHeaders,
                                request_from = undefined
                            }, [{reply, From, {ok, Status, HeadersList, <<>>}}]};
                        false ->
                            %% Sync mode - update stream state to receiving body
                            UpdatedStreams = maps:put(StreamId,
                                {From, {receiving_body, Status, RespHeaders, <<>>}}, Streams),
                            {keep_state, Data#conn_data{
                                h3_streams = UpdatedStreams,
                                status = Status,
                                response_headers = RespHeaders
                            }}
                    end;
                {_From, {waiting_headers_async, AsyncMode, StreamTo, Ref}} ->
                    %% Async mode - send status and headers to StreamTo
                    StreamTo ! {hackney_response, Ref, {status, Status, <<"">>}},
                    StreamTo ! {hackney_response, Ref, {headers, HeadersList}},
                    %% Update stream state for async body streaming
                    NewStreamState = {streaming_body_async, AsyncMode, StreamTo, Ref, Status, RespHeaders},
                    UpdatedStreams = maps:put(StreamId, {undefined, NewStreamState}, Streams),
                    {keep_state, Data#conn_data{
                        h3_streams = UpdatedStreams,
                        status = Status,
                        response_headers = RespHeaders
                    }};
                {Owner, {waiting_headers_streaming, From}} ->
                    %% Streaming mode - reply with headers, then allow
                    %% stream_body calls. The owner is kept so this stream's
                    %% reader is found by caller: a connection can carry
                    %% several.
                    NewStreamState = {streaming_body, Status, RespHeaders, <<>>, undefined},
                    UpdatedStreams = maps:put(StreamId, {Owner, NewStreamState}, Streams),
                    {keep_state, Data#conn_data{
                        h3_streams = UpdatedStreams,
                        status = Status,
                        response_headers = RespHeaders
                    }, [{reply, From, {ok, Status, HeadersList}}]};
                {Owner, {sending_body, _}} ->
                    %% Response to a streamed upload: read it like a
                    %% request_streaming response, with stream_body/1 or
                    %% body/1. start_response/1 may already be waiting.
                    NewStreamState = case Fin of
                        true -> {streaming_body_done, Status, RespHeaders};
                        false -> {streaming_body, Status, RespHeaders, <<>>, undefined}
                    end,
                    UpdatedStreams = maps:put(StreamId, {Owner, NewStreamState}, Streams),
                    NewData = Data#conn_data{h3_streams = UpdatedStreams,
                                             status = Status,
                                             response_headers = RespHeaders},
                    case Data#conn_data.request_from of
                        undefined ->
                            {keep_state, NewData};
                        WaitingFrom ->
                            {keep_state, NewData#conn_data{request_from = undefined},
                             [{reply, WaitingFrom, {ok, Status, HeadersList, self()}}]}
                    end;
                _ ->
                    %% Unknown stream or wrong state
                    {keep_state, Data}
            end;
        {error, Reason} ->
            %% Failed to parse headers
            case maps:get(StreamId, Streams, undefined) of
                {From, _State} when From =/= undefined ->
                    UpdatedStreams = maps:remove(StreamId, Streams),
                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
                     [{reply, From, {error, Reason}}]};
                {_, {waiting_headers_async, _AsyncMode, StreamTo, Ref}} ->
                    %% Async error
                    StreamTo ! {hackney_response, Ref, {error, Reason}},
                    UpdatedStreams = maps:remove(StreamId, Streams),
                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams}};
                _ ->
                    {keep_state, Data}
            end
    end.

%% @private Handle HTTP/3 response body data
handle_h3_data(StreamId, RecvData, Fin, Streams, #conn_data{max_body_size = Max} = Data) ->
    case maps:get(StreamId, Streams, undefined) of
        {From, {receiving_body, Status, Headers, AccBody}} ->
            %% Sync mode - buffer body
            case body_within_limit(byte_size(AccBody) + byte_size(RecvData), Max) of
                false ->
                    h3_body_too_large(StreamId, From, Streams,
                                      Data#conn_data{request_from = undefined});
                true ->
                    h3_on_sync_data(StreamId, From, Status, Headers,
                                    <<AccBody/binary, RecvData/binary>>, Fin, Streams, Data)
            end;
        {_, {streaming_body_async, _AsyncMode, StreamTo, Ref, Status, Headers}} ->
            %% Async mode - send chunk to StreamTo
            _ = case byte_size(RecvData) > 0 of
                true -> StreamTo ! {hackney_response, Ref, RecvData};
                false -> ok
            end,
            case Fin of
                true ->
                    %% Stream complete - send done
                    StreamTo ! {hackney_response, Ref, done},
                    UpdatedStreams = maps:remove(StreamId, Streams),
                    {keep_state, Data#conn_data{
                        h3_streams = UpdatedStreams,
                        request_from = undefined,
                        async = false,
                        async_ref = undefined,
                        stream_to = undefined
                    }};
                false ->
                    %% More data expected - keep streaming
                    NewStreamState = {streaming_body_async, _AsyncMode, StreamTo, Ref, Status, Headers},
                    UpdatedStreams = maps:put(StreamId, {undefined, NewStreamState}, Streams),
                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams}}
            end;
        {Owner, {streaming_body, Status, Headers, Buffer, PendingFrom}} ->
            %% Pull-based streaming mode. The owner is kept through these
            %% transitions: a connection can carry several readers, and a
            %% response may land before its caller reads it.
            case Fin of
                true ->
                    %% Stream complete
                    case PendingFrom of
                        undefined when Buffer =:= <<>>, RecvData =:= <<>> ->
                            %% No pending caller, no data - mark done
                            NewStreamState = {streaming_body_done, Status, Headers},
                            UpdatedStreams = maps:put(StreamId, {Owner, NewStreamState}, Streams),
                            {keep_state, Data#conn_data{h3_streams = UpdatedStreams}};
                        undefined ->
                            %% No pending caller, has data - store final chunk for next stream_body call
                            NewBuffer = <<Buffer/binary, RecvData/binary>>,
                            FinalStreams = maps:put(StreamId, {Owner, {streaming_body_final, Status, Headers, NewBuffer}}, Streams),
                            {keep_state, Data#conn_data{h3_streams = FinalStreams}};
                        _ ->
                            %% Has pending caller - reply with last chunk or done
                            NewBuffer = <<Buffer/binary, RecvData/binary>>,
                            case NewBuffer of
                                <<>> ->
                                    %% No data - reply done
                                    UpdatedStreams = maps:remove(StreamId, Streams),
                                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
                                     [{reply, PendingFrom, done}]};
                                _ ->
                                    %% Has data - reply with it, next call gets done
                                    NewStreamState = {streaming_body_done, Status, Headers},
                                    UpdatedStreams = maps:put(StreamId, {Owner, NewStreamState}, Streams),
                                    {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
                                     [{reply, PendingFrom, {ok, NewBuffer}}]}
                            end
                    end;
                false ->
                    %% More data expected
                    case PendingFrom of
                        undefined ->
                            %% No pending caller - buffer data
                            NewBuffer = <<Buffer/binary, RecvData/binary>>,
                            NewStreamState = {streaming_body, Status, Headers, NewBuffer, undefined},
                            UpdatedStreams = maps:put(StreamId, {Owner, NewStreamState}, Streams),
                            {keep_state, Data#conn_data{h3_streams = UpdatedStreams}};
                        _ ->
                            %% Has pending caller - reply with data
                            NewBuffer = <<Buffer/binary, RecvData/binary>>,
                            NewStreamState = {streaming_body, Status, Headers, <<>>, undefined},
                            UpdatedStreams = maps:put(StreamId, {Owner, NewStreamState}, Streams),
                            {keep_state, Data#conn_data{h3_streams = UpdatedStreams},
                             [{reply, PendingFrom, {ok, NewBuffer}}]}
                    end
            end;
        {_, {streaming_body_full, Status, Headers, Acc, From}} ->
            %% body/1 is waiting for the whole body
            case body_within_limit(byte_size(Acc) + byte_size(RecvData), Max) of
                false ->
                    h3_body_too_large(StreamId, From, Streams, Data);
                true ->
                    NewAcc = <<Acc/binary, RecvData/binary>>,
                    case Fin of
                        true ->
                            {keep_state, Data#conn_data{h3_streams = maps:remove(StreamId, Streams)},
                             [{reply, From, {ok, NewAcc}}]};
                        false ->
                            NewStreamState = {streaming_body_full, Status, Headers, NewAcc, From},
                            {keep_state, Data#conn_data{h3_streams = maps:put(StreamId,
                                {undefined, NewStreamState}, Streams)}}
                    end
            end;
        {_, {streaming_body_final, Status, Headers, FinalBuffer}} ->
            %% Already got final data, just buffer more (shouldn't happen)
            NewBuffer = <<FinalBuffer/binary, RecvData/binary>>,
            UpdatedStreams = maps:put(StreamId, {undefined, {streaming_body_final, Status, Headers, NewBuffer}}, Streams),
            {keep_state, Data#conn_data{h3_streams = UpdatedStreams}};
        {From, waiting_headers} ->
            %% Got data before headers - unusual but handle it
            {keep_state, Data#conn_data{h3_streams = maps:put(StreamId,
                {From, {receiving_body, 0, [], RecvData}}, Streams)}};
        _ ->
            %% Unknown stream
            {keep_state, Data}
    end.

%% @private DATA for a sync HTTP/3 request whose body is buffered whole.
h3_on_sync_data(StreamId, From, Status, Headers, NewBody, true, Streams, Data) ->
    %% Stream complete - reply with full response
    {keep_state, Data#conn_data{h3_streams = maps:remove(StreamId, Streams),
                                request_from = undefined},
     [{reply, From, {ok, Status, Headers, NewBody}}]};
h3_on_sync_data(StreamId, From, Status, Headers, NewBody, false, Streams, Data) ->
    %% More data expected
    UpdatedStreams = maps:put(StreamId, {From, {receiving_body, Status, Headers, NewBody}}, Streams),
    {keep_state, Data#conn_data{h3_streams = UpdatedStreams}}.

%% @private A buffered body passed max_body_size: reset the stream so the peer
%% stops sending, forget it and fail the parked reader.
h3_body_too_large(StreamId, From, Streams, #conn_data{h3_conn = ConnRef} = Data) ->
    _ = hackney_h3:reset_stream(ConnRef, StreamId, ?H3_REQUEST_CANCELLED),
    {keep_state, Data#conn_data{h3_streams = maps:remove(StreamId, Streams)},
     [{reply, From, {error, body_too_large}}]}.

%% @private Handle HTTP/3 stream reset
handle_h3_stream_reset(StreamId, ErrorCode, Streams, Data) ->
    case maps:get(StreamId, Streams, undefined) of
        {From, _State} when is_pid(From) ->
            %% Sync stream - reply with error
            UpdatedStreams = maps:remove(StreamId, Streams),
            {keep_state, Data#conn_data{h3_streams = UpdatedStreams, request_from = undefined},
             [{reply, From, {error, {stream_reset, ErrorCode}}}]};
        {_, {streaming_body_async, _AsyncMode, StreamTo, Ref, _Status, _Headers}} ->
            %% Async stream - send error to StreamTo
            StreamTo ! {hackney_response, Ref, {error, {stream_reset, ErrorCode}}},
            UpdatedStreams = maps:remove(StreamId, Streams),
            {keep_state, Data#conn_data{h3_streams = UpdatedStreams, request_from = undefined}};
        {_, {waiting_headers_async, _AsyncMode, StreamTo, Ref}} ->
            %% Async stream waiting for headers
            StreamTo ! {hackney_response, Ref, {error, {stream_reset, ErrorCode}}},
            UpdatedStreams = maps:remove(StreamId, Streams),
            {keep_state, Data#conn_data{h3_streams = UpdatedStreams, request_from = undefined}};
        {_, StreamState} when element(1, StreamState) =:= streaming_body;
                              element(1, StreamState) =:= streaming_body_full ->
            %% A stream_body/1 or body/1 caller may be parked on this stream.
            Replies = [{reply, Waiting, {error, {stream_reset, ErrorCode}}}
                       || Waiting <- [h3_parked_from(StreamState)], Waiting =/= undefined],
            {keep_state, Data#conn_data{h3_streams = maps:remove(StreamId, Streams)},
             Replies};
        _ ->
            {keep_state, Data}
    end.

%% @private The caller parked on a pull-mode stream, if any.
h3_parked_from({streaming_body, _Status, _Headers, _Buffer, From}) -> From;
h3_parked_from({streaming_body_full, _Status, _Headers, _Acc, From}) -> From;
h3_parked_from(_) -> undefined.

%% @private Cache the H3 session ticket in the pool (best effort, guarded so a
%% custom pool handler without the callback degrades to no caching).
maybe_store_h3_session(_Ticket, #conn_data{pool_handler = undefined}) ->
    ok;
maybe_store_h3_session(Ticket, #conn_data{pool_handler = PoolHandler, host = Host,
                                          port = Port, transport = Transport,
                                          pool_name = PoolName,
                                          connect_options = ConnectOpts,
                                          ssl_options = SslOpts}) ->
    case erlang:function_exported(PoolHandler, store_h3_session, 5) of
        true ->
            %% connect_options may carry the injected per-resumption
            %% session_ticket; h3_options_key ignores it, so this key matches
            %% the one the request side computes without the ticket.
            K3 = hackney_ssl:h3_options_key(ConnectOpts, SslOpts),
            try PoolHandler:store_h3_session(Host, Port, Transport, Ticket,
                                             [{pool, PoolName}, {h3_tls_key, K3}])
            catch _:_ -> ok
            end,
            ok;
        false ->
            ok
    end.

%% @private Drop a cached H3 session ticket (e.g. after 0-RTT rejection).
maybe_delete_h3_session(#conn_data{pool_handler = undefined}) ->
    ok;
maybe_delete_h3_session(#conn_data{pool_handler = PoolHandler, host = Host,
                                   port = Port, transport = Transport,
                                   pool_name = PoolName,
                                   connect_options = ConnectOpts,
                                   ssl_options = SslOpts}) ->
    case erlang:function_exported(PoolHandler, delete_h3_session, 4) of
        true ->
            K3 = hackney_ssl:h3_options_key(ConnectOpts, SslOpts),
            try PoolHandler:delete_h3_session(Host, Port, Transport,
                                              [{pool, PoolName}, {h3_tls_key, K3}])
            catch _:_ -> ok
            end,
            ok;
        false ->
            ok
    end.

%% RFC 9114 5.2: a GOAWAY refuses the requests on stream GoawayId and above,
%% while the ones below it may still be processed. Fail and reset only the
%% refused streams, leave the pool so no new request lands here, and close
%% once the accepted streams end. An upload refused while its caller is
%% between calls is marked `refused' until that caller's next call.
h3_on_goaway(GoawayId, State, #conn_data{h3_streams = Streams, h3_conn = ConnRef,
                                         pool_pid = PoolPid} = Data) ->
    Refused = [S || {S, Entry} <- maps:to_list(Streams), S >= GoawayId,
                    element(2, Entry) =/= refused],
    {Streams1, Actions, RequestFrom} =
        lists:foldl(fun(S, Acc) -> refuse_h3_stream(S, State, Data, Acc) end,
                    {Streams, [], Data#conn_data.request_from}, Refused),
    _ = [hackney_h3:reset_stream(ConnRef, S, ?H3_REQUEST_CANCELLED) || S <- Refused],
    _ = case PoolPid of
        undefined -> ok;
        _ -> gen_server:cast(PoolPid, {unregister_h3, self()})
    end,
    h3_drain_result({keep_state, Data#conn_data{h3_streams = Streams1,
                                                request_from = RequestFrom,
                                                h3_goaway = GoawayId},
                     Actions}).

refuse_h3_stream(S, State, #conn_data{h3_stream_id = UploadId},
                 {Streams, Actions, RequestFrom}) ->
    Err = {error, {goaway, no_error}},
    case maps:get(S, Streams) of
        {Owner, {sending_body, _}} when State =:= streaming_body, S =:= UploadId ->
            {maps:put(S, {Owner, refused}, Streams), Actions, RequestFrom};
        {_, {sending_body, _}} when RequestFrom =/= undefined ->
            %% start_response/1 is parked waiting for this response.
            {maps:remove(S, Streams), [{reply, RequestFrom, Err} | Actions], undefined};
        {_, {waiting_headers_streaming, From}} ->
            {maps:remove(S, Streams), [{reply, From, Err} | Actions],
             h3_clear_from(From, RequestFrom)};
        {_, PullState} when element(1, PullState) =:= streaming_body;
                            element(1, PullState) =:= streaming_body_full ->
            Actions1 = case h3_parked_from(PullState) of
                undefined -> Actions;
                Waiting -> [{reply, Waiting, Err} | Actions]
            end,
            {maps:remove(S, Streams), Actions1, RequestFrom};
        _ ->
            {Streams1, Actions1} = fail_h3_stream(S, Err, Streams, Actions),
            {Streams1, Actions1, h3_clear_from(element(1, maps:get(S, Streams)), RequestFrom)}
    end.

h3_clear_from(From, From) -> undefined;
h3_clear_from(_From, RequestFrom) -> RequestFrom.

%% @private Result for a handler on a connection draining after a GOAWAY:
%% once its last stream has ended it closes.
h3_drain_result({keep_state, #conn_data{h3_goaway = GoawayId, h3_streams = Streams} = Data})
  when GoawayId =/= undefined, map_size(Streams) =:= 0 ->
    h3_close_drained(Data, []);
h3_drain_result({keep_state, #conn_data{h3_goaway = GoawayId, h3_streams = Streams} = Data,
                 Actions})
  when GoawayId =/= undefined, map_size(Streams) =:= 0 ->
    h3_close_drained(Data, Actions);
h3_drain_result(Result) ->
    Result.

h3_close_drained(#conn_data{h3_conn = ConnRef} = Data, Actions) ->
    _ = hackney_h3:close(ConnRef),
    {next_state, closed, Data1, Actions1} =
        handle_h3_termination({goaway, no_error},
                              Data#conn_data{request_from = undefined, no_reuse = true}),
    {next_state, closed, Data1#conn_data{h3_goaway = undefined, h3_stream_id = undefined},
     Actions ++ Actions1}.

%% @private Fail any in-flight stream whose 0-RTT data the server rejected.
%% Returns the updated stream map plus gen_statem reply actions for sync
%% callers; async callers are notified via their StreamTo mailbox directly.
fail_rejected_h3_streams(StreamIds, Streams) ->
    Ids = case is_list(StreamIds) of
              true -> StreamIds;
              false -> sets:to_list(StreamIds)
          end,
    lists:foldl(fun(StreamId, {AccStreams, AccActions}) ->
                        fail_rejected_h3_stream(StreamId, AccStreams, AccActions)
                end, {Streams, []}, Ids).

fail_rejected_h3_stream(StreamId, Streams, Actions) ->
    fail_h3_stream(StreamId, {error, early_data_rejected}, Streams, Actions).

fail_h3_stream(StreamId, Err, Streams, Actions) ->
    case maps:get(StreamId, Streams, undefined) of
        undefined ->
            {Streams, Actions};
        {From, waiting_headers} ->
            %% Sync request awaiting headers - reply via the state machine.
            {maps:remove(StreamId, Streams), [{reply, From, Err} | Actions]};
        {From, {sending_body, _}} ->
            {maps:remove(StreamId, Streams), [{reply, From, Err} | Actions]};
        {From, {waiting_headers_streaming, _}} ->
            {maps:remove(StreamId, Streams), [{reply, From, Err} | Actions]};
        {_, {streaming_body_async, _AsyncMode, StreamTo, Ref, _Status, _Headers}} ->
            StreamTo ! {hackney_response, Ref, Err},
            {maps:remove(StreamId, Streams), Actions};
        {_, {waiting_headers_async, _AsyncMode, StreamTo, Ref}} ->
            StreamTo ! {hackney_response, Ref, Err},
            {maps:remove(StreamId, Streams), Actions};
        {_, {async, _AsyncMode, StreamTo, Ref, _SubState}} ->
            StreamTo ! {hackney_response, Ref, Err},
            {maps:remove(StreamId, Streams), Actions};
        _ ->
            {maps:remove(StreamId, Streams), Actions}
    end.

%% @private Handle HTTP/3 connection closed
%% After a GOAWAY the connection closes once its last stream is answered, which
%% can be before the caller has read that answer. Fully received responses stay
%% readable; the drain ends when they have been read.
handle_h3_conn_closed(Reason, #conn_data{h3_goaway = GoawayId, h3_streams = Streams} = Data)
  when GoawayId =/= undefined ->
    Received = maps:filter(fun(_StreamId, {_, StreamState}) ->
                                   h3_response_received(StreamState)
                           end, Streams),
    case map_size(Received) of
        0 ->
            handle_h3_termination({connection_closed, Reason}, Data);
        _ ->
            Pending = maps:without(maps:keys(Received), Streams),
            {next_state, closed, _, Actions} =
                handle_h3_termination({connection_closed, Reason},
                                      Data#conn_data{h3_streams = Pending}),
            {keep_state, Data#conn_data{h3_conn = undefined, h3_streams = Received,
                                        request_from = undefined}, Actions}
    end;
handle_h3_conn_closed(Reason, Data) ->
    handle_h3_termination({connection_closed, Reason}, Data).

h3_response_received({streaming_body_done, _Status, _Headers}) -> true;
h3_response_received({streaming_body_final, _Status, _Headers, _Buffer}) -> true;
h3_response_received(_StreamState) -> false.

%% @private Handle HTTP/3 transport error
handle_h3_error(Error, Data) ->
    handle_h3_termination(Error, Data).

%% @private Shared helper for HTTP/3 connection termination.
%% Notifies all pending streams and transitions to closed state.
handle_h3_termination(Error, Data) ->
    #conn_data{h3_streams = Streams, request_from = From} = Data,
    %% Notify all pending streams (sync and async)
    Actions = maps:fold(fun(_StreamId, StreamState, Acc) ->
        case StreamState of
            {StreamFrom, _State} when is_pid(StreamFrom) ->
                %% Sync stream
                [{reply, StreamFrom, {error, Error}} | Acc];
            {_, {streaming_body_async, _AsyncMode, StreamTo, Ref, _Status, _Headers}} ->
                %% Async stream - send error to StreamTo (not gen_statem action)
                StreamTo ! {hackney_response, Ref, {error, Error}},
                Acc;
            {_, {waiting_headers_async, _AsyncMode, StreamTo, Ref}} ->
                %% Async stream waiting for headers
                StreamTo ! {hackney_response, Ref, {error, Error}},
                Acc;
            {_, PullState} ->
                %% A stream_body/1 or body/1 caller parked on this stream
                case h3_parked_from(PullState) of
                    undefined -> Acc;
                    Waiting -> [{reply, Waiting, {error, Error}} | Acc]
                end;
            _ ->
                Acc
        end
    end, [], Streams),
    %% Clear connection state
    NewData = Data#conn_data{
        h3_conn = undefined,
        h3_streams = #{},
        request_from = undefined,
        async = false,
        async_ref = undefined,
        stream_to = undefined
    },
    case From of
        undefined ->
            {next_state, closed, NewData, Actions};
        _ ->
            %% Don't duplicate reply if From is already in Actions
            case lists:any(fun({reply, F, _}) -> F =:= From end, Actions) of
                true -> {next_state, closed, NewData, Actions};
                false ->
                    {next_state, closed, NewData, [{reply, From, {error, Error}} | Actions]}
            end
    end.

%% @private Hand response headers to the Alt-Svc cache so server-advertised
%% HTTP/3 endpoints get recorded for future requests. Fires for every
%% protocol so the cache TTL stays fresh while h3 is in use and `clear'
%% directives are honored even on h3 responses.
maybe_record_altsvc(Headers, #conn_data{host = Host, port = Port})
  when is_list(Headers) ->
    _ = (try hackney_altsvc:parse_and_cache(Host, Port, Headers) catch _:_ -> ok end),
    ok;
maybe_record_altsvc(_Headers, _Data) ->
    ok.
