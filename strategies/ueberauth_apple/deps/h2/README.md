# h2

HTTP/2 client and server for Erlang/OTP.

- Full **RFC 7540 / RFC 9113** protocol (frames, streams, flow control, SETTINGS negotiation, GOAWAY, CONTINUATION, malformed-message enforcement).
- **RFC 7541** HPACK with static + dynamic tables and Huffman coding.
- **RFC 7540 §8.3** CONNECT tunnel mode for bidirectional byte streams.
- **RFC 8441** Extended CONNECT (`:protocol` pseudo-header) for bootstrapping WebSockets and similar protocols over HTTP/2.
- **gRPC-style bidirectional streaming**: interleaved DATA both ways on one stream, per-stream event handlers owned by per-call processes, receive/send backpressure, and trailers.
- ALPN `h2` over TLS 1.2+ by default; cleartext (`h2c` over plain TCP) also supported.
- Owner-process event messages (`{h2, Conn, Event}`) mirroring the [`quic_h3`](https://github.com/benoitc/erlang_quic) HTTP/3 API so cross-protocol code stays symmetric.

## Install

Add to `rebar.config`:

```erlang
{deps, [
    {h2, "0.12.5", {git, "https://github.com/benoitc/erlang_h2.git", {tag, "0.12.5"}}}
]}.
```

Requires Erlang/OTP 24+.

## Client

```erlang
{ok, Conn} = h2:connect("example.com", 443),
{ok, StreamId} = h2:request(Conn, <<"GET">>, <<"/">>, [{<<"host">>, <<"example.com">>}]),
receive
    {h2, Conn, {response, StreamId, Status, _Headers}} ->
        io:format("status: ~p~n", [Status])
end,
receive
    {h2, Conn, {data, StreamId, Body, true}} ->
        io:format("body: ~p~n", [Body])
end,
ok = h2:close(Conn).
```

Messages delivered to the owner process:

| Message | Meaning |
|---|---|
| `{h2, Conn, connected}` | handshake + SETTINGS exchange complete |
| `{h2, Conn, {response, StreamId, Status, Headers}}` | final response headers (2xx–5xx) |
| `{h2, Conn, {informational, StreamId, Status, Headers}}` | 1xx interim response (100/103/…) |
| `{h2, Conn, {data, StreamId, Data, EndStream}}` | response body fragment (an empty final frame marks end-of-stream for body-less responses) |
| `{h2, Conn, {trailers, StreamId, Headers}}` | response trailers |
| `{h2, Conn, {stream_reset, StreamId, ErrorCode}}` | peer sent RST_STREAM |
| `{h2, Conn, {goaway, LastStreamId, ErrorCode}}` | peer is shutting down |
| `{h2, Conn, {closed, Reason}}` | connection closed |

By default these go to the connection owner. Register a per-stream handler (see [Bidirectional streaming](#bidirectional-streaming-grpc)) to route a single stream's events to a dedicated process instead, so many concurrent calls can be driven independently over one connection.

Options to `h2:connect/3`:

```erlang
#{transport    => ssl | tcp,            %% default: ssl
  ssl_opts     => [ssl:tls_client_option()],
  verify       => verify_peer | verify_none,
  cacerts      => [binary()],
  settings     => h2_settings:settings(),
  timeout      => timeout()}
```

Send a request body in chunks:

```erlang
{ok, Sid} = h2:request(Conn, <<"POST">>, <<"/upload">>, Headers, false),
ok = h2:send_data(Conn, Sid, Chunk1, false),
ok = h2:send_data(Conn, Sid, Chunk2, true).   %% last chunk: EndStream = true
```

## Server

`h2:start_server/2` starts the listener under the `h2` application's supervision tree, so make sure the application is started first:

```erlang
ok = application:ensure_started(h2).
```

```erlang
Handler = fun(Conn, StreamId, <<"GET">>, <<"/">>, _Headers) ->
    h2:send_response(Conn, StreamId, 200, [{<<"content-type">>, <<"text/plain">>}]),
    h2:send_data(Conn, StreamId, <<"Hello HTTP/2!">>, true)
end,

{ok, Server} = h2:start_server(8443, #{
    cert    => "server.pem",
    key     => "server.key",
    handler => Handler
}),

Port = h2:server_port(Server),
%% ... later ...
ok = h2:stop_server(Server).
```

For the common headers-plus-body response, `h2:respond/5` sends both in a single
call and a single socket write (HEADERS coalesced with DATA), instead of the two
round-trips of `send_response/4` + `send_data/4`. It falls back to the granular
path automatically when the response cannot be coalesced (oversized headers or
body, CONNECT tunnels):

```erlang
Handler = fun(Conn, StreamId, <<"GET">>, <<"/">>, _Headers) ->
    h2:respond(Conn, StreamId, 200, [{<<"content-type">>, <<"text/plain">>}],
               <<"Hello HTTP/2!">>)
end.
```

Use the granular `send_response/4` + `send_data/4` (or `send_data/4` in chunks)
when the body is streamed or produced incrementally.

Options to `h2:start_server/2,3`:

```erlang
#{cert                    := binary() | string(),
  key                     := binary() | string(),
  cacerts                 => [binary()],
  handler                 := fun((Conn, StreamId, Method, Path, Headers) -> any()),
  settings                => h2_settings:settings(),
  acceptors               => pos_integer(),       %% default: schedulers
  backlog                 => pos_integer(),       %% listen queue, default: 1024
  transport               => ssl | tcp,           %% default: ssl
  enable_connect_protocol => boolean()}           %% RFC 8441, default: false
```

A module handler (`handler => {Mod, Args}`) is also supported; `Mod:handle_request/5` receives the same arguments.

The `Headers` argument is the request header list with pseudo-headers stripped, except `:authority`, `:scheme`, and `:protocol`, which are kept so adapters can reconstruct the request authority/scheme (a compliant client may send `:authority` and no `host` header) and read the Extended CONNECT token. `:method` and `:path` are already passed as the separate `Method`/`Path` arguments. Read what you need and strip these pseudo-headers before exposing the list as ordinary application headers:

```erlang
Handler = fun(Conn, StreamId, Method, Path, Headers) ->
    Authority  = proplists:get_value(<<":authority">>, Headers),
    Scheme     = proplists:get_value(<<":scheme">>, Headers),
    AppHeaders = [{K, V} || {<<C, _/binary>> = K, V} <- Headers, C =/= $:],
    my_app:handle(Conn, StreamId, Method, Path, Scheme, Authority, AppHeaders)
end.
```

### Scaling the acceptor pool

Each accepted socket runs its own `h2_connection` gen_statem, so concurrency on established connections scales with BEAM schedulers. The `acceptors` opt only sizes the pool of processes blocked in `ssl:transport_accept` / `gen_tcp:accept` on the shared listen socket — raise it when the incoming connection rate (not in-flight traffic) is the bottleneck:

```erlang
h2:start_server(8443, #{cert => ..., key => ..., handler => ...,
                        acceptors => 100}).
```

Default is `erlang:system_info(schedulers)` (one per core). 100 is a good ceiling for high connection-rate workloads; going higher rarely helps. Complementary knobs: kernel `somaxconn` / `tcp_max_syn_backlog`, OS-level SSL session cache, and a `handler` that spawns per request (the built-in server loop already does).

## CONNECT tunnels (RFC 7540 §8.3)

Open a bidirectional byte tunnel through an h2 proxy:

```erlang
%% Client
{ok, Conn} = h2:connect(ProxyHost, ProxyPort),
{ok, Sid}  = h2:request(Conn, [
    {<<":method">>, <<"CONNECT">>},
    {<<":authority">>, <<"target.example.com:443">>}
]),
receive {h2, Conn, {response, Sid, 200, _}} -> ok end,
ok = h2:send_data(Conn, Sid, <<"raw bytes">>, false),
receive {h2, Conn, {data, Sid, Reply, _}} -> Reply end.
```

Server handler establishes the tunnel by replying 2xx, then echoes / forwards bytes via `set_stream_handler/3`:

```erlang
fun(Conn, Sid, <<"CONNECT">>, _, _Headers) ->
    h2:send_response(Conn, Sid, 200, []),
    h2:set_stream_handler(Conn, Sid, self()),
    tunnel_loop(Conn, Sid)
end.
```

Tunnel semantics: DATA frames carry raw bytes (no body-length enforcement), `END_STREAM` is a half-close, trailers are rejected, and `Content-Length` / `Transfer-Encoding` on the 2xx response are rejected.

## Extended CONNECT (RFC 8441)

Bootstrap WebSockets (or any protocol) over an HTTP/2 stream. Server opts in:

```erlang
{ok, Server} = h2:start_server(8443, #{
    cert => "server.pem",
    key => "server-key.pem",
    handler => Handler,
    enable_connect_protocol => true   %% advertises SETTINGS_ENABLE_CONNECT_PROTOCOL=1
}).
```

Client uses the `protocol` opt; `:scheme`, `:path`, `:authority` are required:

```erlang
{ok, Conn} = h2:connect("localhost", 8443),
{ok, Sid}  = h2:request(Conn, [
    {<<":method">>, <<"CONNECT">>},
    {<<":scheme">>, <<"https">>},
    {<<":path">>, <<"/chat">>},
    {<<":authority">>, <<"localhost">>}
], #{protocol => <<"websocket">>}),
receive {h2, Conn, {response, Sid, 200, _}} -> ok end,
ok = h2:send_data(Conn, Sid, FrameBytes, false).
```

If the peer never advertised the setting, `h2:request/3` returns `{error, extended_connect_disabled}`. Server handlers read `:protocol` from the request `Headers` argument (alongside `:authority`/`:scheme`; see [Server](#server)). Tunnel semantics (no body length, no trailers) apply once the 2xx is sent.

## Bidirectional streaming (gRPC)

A gRPC call is one HTTP/2 stream where both peers send interleaved DATA, the client half-closes with `END_STREAM` on its last DATA while still receiving, and the server ends with trailers carrying `grpc-status`. Each call runs in its own process that owns *its* stream's events without owning the connection, so many calls multiplex one connection.

Pass `#{handler => Pid}` at request time to route every event for that stream (`response`, `data`, `trailers`, `informational`, `stream_reset`) to `Pid` from creation, race-free:

```erlang
%% Client call process
{ok, Sid} = h2:request(Conn, [
    {<<":method">>, <<"POST">>},
    {<<":scheme">>, <<"https">>},
    {<<":path">>, <<"/pkg.Service/BidiMethod">>},
    {<<":authority">>, <<"localhost">>},
    {<<"content-type">>, <<"application/grpc">>},
    {<<"te">>, <<"trailers">>}
], #{handler => self(), end_stream => false}),
receive {h2, Conn, {response, Sid, 200, _}} -> ok end,
[ok = h2:send_data(Conn, Sid, Msg, false) || Msg <- OutMsgs],
ok = h2:send_data(Conn, Sid, <<>>, true),     %% half-close, keep receiving
{InMsgs, Trailers} = collect(Conn, Sid).       %% data frames, then {trailers, ...}
```

```erlang
%% Server handler: stream out while reading inbound, end with trailers
fun(Conn, Sid, _Method, _Path, _Headers) ->
    ok = h2:set_stream_handler(Conn, Sid, self()),
    ok = h2:send_response(Conn, Sid, 200, [{<<"content-type">>, <<"application/grpc">>}]),
    ok = bidi_loop(Conn, Sid),                  %% send_data / receive {data, ...} interleaved
    ok = h2:send_trailers(Conn, Sid, [{<<"grpc-status">>, <<"0">>}])
end.
```

`h2:set_stream_handler/3,4` works after the stream exists too: any events that arrived before registration are buffered and replayed to the handler in order, never dropped to the owner.

**Receive backpressure.** By default the stream receive window is replenished on dispatch, so a slow handler's mailbox can grow unbounded. Pass `#{flow_control => manual}` (at request time or in `set_stream_handler/4`) and call `h2:consume/3` after processing, so `WINDOW_UPDATE` tracks consumer progress:

```erlang
{ok, Sid} = h2:request(Conn, Headers, #{handler => self(), flow_control => manual}),
%% ... after handling N received bytes:
ok = h2:consume(Conn, Sid, N).
```

**Receive windows for large downloads.** `settings.initial_window_size` only sizes each stream's window; every stream also shares one connection window, which stays at 65,535 bytes unless you set `connection_window_size` (65535..2147483647). With the default, a download moves at most 64 KB per round trip. Raise both for large bodies over high-latency links; the same option is accepted by `h2:start_server/2,3` and `h2:serve_socket/2`:

```erlang
{ok, Conn} = h2:connect(Host, 443, #{settings => #{initial_window_size => 8 * 1024 * 1024},
                                     connection_window_size => 32 * 1024 * 1024}).
```

An invalid value makes `h2_connection:start_link/3,4` return `{error, {invalid_option, {connection_window_size, V}}}`.

**Send backpressure.** `h2:send_data/4` buffers when the peer's window is shut and returns `{error, send_buffer_full}` once the per-stream cap is reached (non-blocking; back off and retry). For a blocking send, `h2:send_data/5` with `#{block => Timeout}` waits until the window accepts the data, returning `ok` or `{error, timeout}`:

```erlang
case h2:send_data(Conn, Sid, Msg, false, #{block => 5000}) of
    ok              -> ok;
    {error, timeout} -> h2:cancel(Conn, Sid)
end.
```

**Cancel and teardown.** `h2:cancel/2,3` sends `RST_STREAM`; the peer's stream handler receives `{stream_reset, Sid, Code}` (deadline/cancel map to `CANCEL`). A stream handler is also told about connection-wide `{goaway, ...}` and `{closed, Reason}`, so a call process learns of disconnect and can clean up without owning the connection.

The message framing (the 5-byte length prefix and protobuf) is the application's concern; h2 carries the HTTP/2 stream, flow control, and trailers. See `test/h2_grpc_tests.erl` for a full loopback example and `test/h2_grpc_interop_SUITE.erl` / `test/h2_grpc_client_interop_SUITE.erl` for interop against real gRPC peers.

## Using with Ranch

The built-in `h2:start_server/2` runs its own acceptor pool. To plug into an existing Ranch listener instead, hand the accepted socket to `h2:serve_socket/2`. A minimal Ranch protocol module:

```erlang
-module(h2_ranch_protocol).
-behaviour(ranch_protocol).
-export([start_link/3]).

start_link(Ref, Transport, Opts) ->
    {ok, spawn_link(fun() -> init(Ref, Transport, Opts) end)}.

init(Ref, _Transport, Opts) ->
    {ok, Socket} = ranch:handshake(Ref),
    {ok, Conn}   = h2:serve_socket(Socket, Opts),
    %% Ranch counts this process as the connection; outlive the h2 one.
    MRef = erlang:monitor(process, Conn),
    receive {'DOWN', MRef, process, Conn, _} -> ok end.
```

`Opts` is the same map `h2:start_server/2` takes — `serve_socket/2` reads `handler`, `settings`, and `enable_connect_protocol` from it.

Wire it up:

```erlang
{ok, _} = ranch:start_listener(my_h2, ranch_ssl,
    #{socket_opts => [{port, 8443},
                      {certfile, "cert.pem"}, {keyfile, "key.pem"},
                      {alpn_preferred_protocols, [<<"h2">>]}]},
    h2_ranch_protocol,
    #{handler => fun my_app:handle/5}).
```

Ranch owns draining, acceptor-pool sizing, and metrics; h2 handles h2 semantics.

## Coexisting with HTTP/1.1

This library is HTTP/2-only. Where you need HTTP/1.1 too, the pattern is always "different library, same socket boundary".

**Client fallback.** `h2:connect/2,3` surfaces ALPN mismatches explicitly — no silent fall-through to assumed-h2 (RFC 9113 §3.3):

```erlang
case h2:connect(Host, 443) of
    {ok, Conn}                               -> h2_flow(Conn);
    {error, {alpn_mismatch, <<"http/1.1">>}} -> http1_flow(Host);
    {error, alpn_not_negotiated}             -> http1_flow(Host);
    Err                                      -> Err
end.
```

**Dual-stack server.** Own the listener yourself, advertise both protocols, and hand the `h2` connections to `h2:serve_socket/2` — same map `start_server/2` takes, over a socket you already accepted and handshook:

```erlang
{ok, Listen} = ssl:listen(8443, [{certfile, "cert.pem"}, {keyfile, "key.pem"},
                                 {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]},
                                 {active, false}, {mode, binary}]),

accept(Listen, Opts) ->
    {ok, Sock} = ssl:transport_accept(Listen),
    spawn(fun() -> dispatch(Sock, Opts) end),
    accept(Listen, Opts).

dispatch(Sock, Opts) ->
    {ok, Socket} = ssl:handshake(Sock, 30000),
    case ssl:negotiated_protocol(Socket) of
        {ok, <<"h2">>}       -> h2:serve_socket(Socket, Opts);
        {ok, <<"http/1.1">>} -> my_http1:serve(Socket);
        _                    -> ssl:close(Socket)
    end.
```

One port, TLS picks per connection. Handshake in the per-connection process, not the accept loop, so a stalled client can't block the queue.

`serve_socket/2` returns `{ok, Pid}` and takes ownership of the socket — don't read, write, or close it afterwards. `Pid` is spawned **linked** to the caller: a clean disconnect exits `normal`, a connection failure propagates unless you trap exits, and your death tears the connection down. Call it from the process whose lifetime the connection should follow. ALPN is not re-checked; you already resolved it. A plain `gen_tcp` socket works too and is served as prior-knowledge h2c.

**Cleartext `Upgrade: h2c` from HTTP/1.1.** Deprecated by RFC 9113 and not supported. Use prior-knowledge h2c instead — both peers agree out of band that the connection is plaintext h2:

```erlang
{ok, Conn}   = h2:connect(Host, Port, #{transport => tcp}).
{ok, Server} = h2:start_server(Port, #{transport => tcp, handler => Handler}).
```

## Modules

| Module | Purpose |
|---|---|
| `h2` | Public API (client + server). |
| `h2_connection` | `gen_statem` per-connection state machine. |
| `h2_server` | TLS listener + acceptor pool. |
| `h2_frame` | Frame encode/decode. |
| `h2_hpack` | HPACK encoder/decoder. |
| `h2_settings` | SETTINGS encode/decode/validate. |
| `h2_error` | Error code mappings. |

## Performance

Each connection is one `h2_connection` gen_statem that owns the socket; each
request is handled in its own process, so in-flight concurrency scales with BEAM
schedulers.

For the common request/response, prefer `h2:respond/5` (status + headers + body
in one call and one coalesced socket write) over `h2:send_response/4` +
`h2:send_data/4` (two `gen_statem` round-trips and two writes). Use the granular
pair when the body is produced or streamed incrementally.

Indicative h2c throughput, `h2load` on a 14-core machine with a "Hello, World!"
handler, against cowboy 2.14 on the same box:

| clients x streams | `send_response` + `send_data` | `respond/5` | cowboy |
|---|---|---|---|
| 16 x 16 | 250k req/s | 388k req/s | 320k req/s |
| 32 x 32 | 268k req/s | 420k req/s | 397k req/s |

Numbers are machine-specific; treat them as relative. Reproduce with the harness
under `bench/` (`start_h2.sh`, raw-client and `fprof`/decode microbenches).

Tuning knobs: a handler that uses `respond/5`, `acceptors` (connection-accept
rate), and `backlog` (listen queue). HPACK decode is cheapest once a
connection's dynamic table is warm (repeated headers decode as indexed
references); the cold path (first request, or high header churn) decodes literal
values through a table-driven Huffman state machine.

## Build and test

```bash
rebar3 compile
rebar3 eunit          # 310 tests + 800 PropEr properties
rebar3 ct             # 81 compliance + 6 h2spec interop cases
rebar3 dialyzer       # clean
rebar3 xref           # clean
rebar3 ex_doc         # HTML docs
```

## Interop

External-peer interop tests live in `test/h2_interop_SUITE.erl` and drive
the server from [h2spec](https://github.com/summerwind/h2spec). Install
h2spec locally, then:

```bash
# macOS
brew install summerwind/h2spec/h2spec
# Linux: download a release tarball from
# https://github.com/summerwind/h2spec/releases

rebar3 ct --suite=test/h2_interop_SUITE
```

Without h2spec on `PATH` the suite skips cleanly. The generic and HPACK
groups are run in observe mode — failures are logged with full output for
triage rather than treated as hard failures. Library-level conformance
(which does not need h2spec) stays in `h2_compliance_SUITE`.

## Status

Production-oriented: spec-correct and deterministic under the in-tree CT suite. Intentionally out of scope:

- Server push (§8.2) — deprecated and rarely useful.
- Stream priorities (§5.3) — deprecated by RFC 9218.
- Alt-Svc and HTTP/2 cleartext upgrade (§3.2) — ALPN-only in this release.

## License

Apache License 2.0
