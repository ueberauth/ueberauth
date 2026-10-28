# Hackney Architecture

This document describes the internal architecture of hackney 3.x, including the process-per-connection model, connection pooling, load regulation, and SSL handling.

## Overview

Hackney uses a **process-per-connection** architecture where each HTTP connection runs in its own `gen_statem` process. This design provides:

- **Clean isolation** - Each connection has its own state, no shared mutable state
- **Automatic cleanup** - Process crashes clean up sockets automatically
- **Simple ownership** - Socket always owned by connection process
- **OTP supervision** - Standard supervisor tree for fault tolerance

```
hackney_sup
├── hackney_manager          (connection registry)
├── hackney_conn_sup         (connection supervisor)
│   └── hackney_conn [1..N]  (connection processes for HTTP/1.1, HTTP/2)
├── hackney_pools_sup        (pool supervisor)
│   └── hackney_pool [1..N]  (pool processes)
└── hackney_altsvc           (Alt-Svc cache for HTTP/3 discovery)

QUIC connections (HTTP/3):
└── hackney_h3.erl           (HTTP/3 high-level + adapter over quic_h3)
```

## Connection Process (hackney_conn)

Each connection is a `gen_statem` process that manages:

- TCP/SSL socket
- HTTP protocol state (request/response phases)
- Streaming state (chunked encoding, content-length tracking)
- Owner process monitoring

### State Machine

```
                    ┌─────────────┐
                    │   created   │
                    └──────┬──────┘
                           │ connect
                           ▼
                    ┌─────────────┐
              ┌─────│  connected  │─────┐
              │     └─────────────┘     │
              │            │            │
        send_request       │      upgrade_to_ssl
              │            │            │
              ▼            │            ▼
       ┌────────────┐      │     ┌────────────┐
       │  on_body   │      │     │  connected │ (SSL)
       └─────┬──────┘      │     └────────────┘
             │             │
      finish_send_body     │
             │             │
             ▼             │
    ┌─────────────────┐    │
    │ waiting_response│    │
    └────────┬────────┘    │
             │             │
       start_response      │
             │             │
             ▼             │
      ┌────────────┐       │
      │ on_status  │       │
      └─────┬──────┘       │
            │              │
            ▼              │
      ┌────────────┐       │
      │ on_headers │───────┤
      └─────┬──────┘       │
            │              │
            ▼              │
    ┌──────────────┐       │
    │ on_resp_body │       │
    └───────┬──────┘       │
            │              │
            │ body done    │
            └──────────────┘
                  │
                  ▼
           ┌────────────┐
           │  closing   │
           └─────┬──────┘
                 │
                 ▼
              [exit]
```

### Owner Monitoring

The connection process monitors its owner: the process that checked out the connection, or for a connection opened without a pool, the process that opened it (with `stream_to`, the `stream_to` process once the async request starts). If the owner crashes, the connection terminates automatically, preventing socket leaks. An HTTP/1.1 read waiting on the server checks for this every second. `hackney_conn:set_owner/2` moves ownership to another process.

```erlang
%% When connection is checked out
MonitorRef = monitor(process, Owner),
%% If owner dies
{'DOWN', MonitorRef, process, Owner, _} -> terminate
```

## Connection Pool (hackney_pool)

The pool stores **TCP connections only** for reuse. SSL connections are never pooled for security reasons (they close after use).

### Why TCP-Only Pooling?

1. **Security** - SSL session state should not be shared across requests
2. **Simplicity** - No need to validate SSL session freshness
3. **Flexibility** - TCP connections can be upgraded to SSL when needed

### Pool State

```erlang
-record(state, {
    name,                    %% Pool name
    max_connections,         %% Global max (legacy, per-host preferred)
    keepalive_timeout,       %% Max idle time (default 2000ms, max 2000ms)
    prewarm_count,           %% Connections to maintain per host (default 4)
    available = #{},         %% #{Key => [Pid]} - idle TCP connections
    in_use = #{},            %% #{Pid => Key} - checked out connections
    pid_monitors = #{},      %% #{Pid => MonitorRef}
    activated_hosts          %% Hosts with prewarm enabled
}).
```

### Pool Operations

**Checkout**: Get an available TCP connection or `none`
```erlang
hackney_pool:checkout(Host, Port, Transport, Opts)
%% Returns: {ok, PoolInfo, Pid} | {error, no_pool}
```

**Checkin**: Return a connection to the pool
```erlang
hackney_pool:checkin(PoolInfo, Pid)
%% TCP connections are stored, SSL connections are closed
```

### Keepalive Timeout

Idle connections are closed after `keepalive_timeout` (default and max: 2 seconds). This prevents:

- Stale connections that the server has closed
- Resource accumulation from unused connections
- Issues with server-side connection limits

## Load Regulation (hackney_load_regulation)

Per-host connection limits prevent overwhelming individual servers. This uses an **ETS counting semaphore** pattern for lock-free concurrent access.

### How It Works

```erlang
%% ETS table: hackney_host_limits
%% Key: {Host, Port} -> Value: current_count

%% Acquire a slot (blocks with backoff until available or timeout)
acquire(Host, Port, MaxPerHost, Timeout) ->
    Count = ets:update_counter(Table, Key, {2, 1}, {Key, 0}),
    case Count =< MaxPerHost of
        true -> ok;
        false ->
            ets:update_counter(Table, Key, {2, -1}),
            %% Backoff and retry until timeout
    end.

%% Release a slot
release(Host, Port) ->
    ets:update_counter(Table, Key, {2, -1, 0, 0}).
```

### Why ETS Counting Semaphore?

1. **Lock-free** - `ets:update_counter` is atomic
2. **Per-host isolation** - Different hosts don't block each other
3. **No process bottleneck** - No gen_server call for every request
4. **Backpressure** - Requests wait when limit reached

### Configuration

```erlang
%% Default: 50 concurrent connections per host
hackney:get(URL, [], <<>>, [{max_per_host, 100}]).

%% Per-request timeout for acquiring a slot
hackney:get(URL, [], <<>>, [{checkout_timeout, 5000}]).
```

## SSL Upgrade Strategy

HTTPS requests use **TCP connection upgrade** rather than direct SSL connections:

```
1. Get TCP connection (from pool or new)
2. Upgrade to SSL in-place: ssl:connect(Socket, SslOpts)
3. Use SSL connection for request
4. Close connection (SSL connections not pooled)
5. Trigger TCP prewarm for next HTTPS request
```

### Benefits

- **Connection reuse** - Pooled TCP connections can serve HTTP or HTTPS
- **Prewarm works for HTTPS** - TCP connections ready to upgrade
- **Security** - SSL state never shared between requests

### Code Flow

```erlang
%% In hackney.erl
connect_pool(Host, Port, Transport, Opts) ->
    %% Always checkout as TCP
    case hackney_pool:checkout(Host, Port, hackney_tcp, Opts) of
        {ok, PoolInfo, Pid} ->
            %% Upgrade if HTTPS
            case Transport of
                hackney_ssl ->
                    ok = hackney_conn:upgrade_to_ssl(Pid, SslOpts),
                    {ok, PoolInfo, Pid};
                _ ->
                    {ok, PoolInfo, Pid}
            end;
        ...
    end.
```

## Protocol Selection

Hackney supports three HTTP protocols: HTTP/1.1, HTTP/2, and HTTP/3 (experimental). The protocol selection is controlled via the `protocols` option.

### Default Protocols

By default, hackney uses `[http2, http1]`:

```erlang
%% Default behavior - HTTP/2 preferred, HTTP/1.1 fallback
hackney:get("https://example.com/")
```

The default can be changed via application environment:

```erlang
%% In sys.config or at runtime
application:set_env(hackney, default_protocols, [http2, http1]).
```

### Enabling HTTP/3 (Experimental)

HTTP/3 uses QUIC (UDP transport). To enable HTTP/3:

```erlang
%% Per-request: opt-in to HTTP/3
hackney:get("https://example.com/", [], <<>>, [
    {protocols, [http3, http2, http1]}
]).

%% Application-wide: enable HTTP/3 by default
application:set_env(hackney, default_protocols, [http3, http2, http1]).
```

**Important considerations for HTTP/3:**

- **Experimental** - QUIC support is still maturing
- **UDP may be blocked** - Corporate firewalls often block UDP

### Protocol Priority

Protocols are tried in order. With `[http3, http2, http1]`:

1. If QUIC is available and server supports HTTP/3: use HTTP/3
2. Otherwise, ALPN negotiates HTTP/2 or HTTP/1.1 over TLS
3. Server chooses the highest protocol it supports

### Forcing a Single Protocol

```erlang
%% Force HTTP/1.1 only (no HTTP/2 negotiation)
hackney:get(URL, [], <<>>, [{protocols, [http1]}]).

%% Force HTTP/2 only
hackney:get(URL, [], <<>>, [{protocols, [http2]}]).

%% HTTP/3 only (will fail if QUIC unavailable or server doesn't support it)
hackney:get(URL, [], <<>>, [{protocols, [http3]}]).
```

## HTTP/3 and QUIC Architecture

HTTP/3 connections use QUIC (UDP-based transport) via a pure Erlang implementation from the `quic` dependency.

### Event-Driven Architecture

Like TCP connections, QUIC uses an event-driven architecture where the owner process drives the connection:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Owner Process (Erlang)                       │
│                                                                  │
│  1. connect() → Creates QUIC connection via quic library        │
│                                                                  │
│  2. Receives {select, Resource, Ref, ready_input}               │
│     └── Socket has data ready                                   │
│                                                                  │
│  3. Calls hackney_h3:process(ConnRef)                         │
│     └── Receives UDP packets                                    │
│     └── Processes QUIC frames                                   │
│     └── Triggers events (headers, data, etc.)                   │
│     └── Returns next timeout in ms                              │
│                                                                  │
│  4. Receives {h3, ConnRef, Event}                             │
│     └── {connected, Info}                                       │
│     └── {stream_headers, StreamId, Headers, Fin}                │
│     └── {stream_data, StreamId, Data, Fin}                      │
│     └── {closed, Reason}                                        │
│                                                                  │
│  5. Schedules timer: erlang:send_after(TimeoutMs, self(), ...)  │
│     └── Calls process() again when timer fires                  │
└─────────────────────────────────────────────────────────────────┘
```

### Pure Erlang Components

```
┌─────────────────────────────────────────────────────────────────┐
│                       hackney_h3.erl                             │
│  - connect/4: Start QUIC connection via quic_h3                 │
│  - send_request/3: Open stream + send HEADERS                   │
│  - send_data/4: Send request body                               │
│  - reset_stream/3: Cancel an in-flight stream                   │
│  - close/2: Close connection                                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   quic application (dependency)                  │
│  - QUIC protocol implementation (RFC 9000)                      │
│  - TLS 1.3 handshake                                            │
│  - Packet encoding/decoding                                     │
│  - Congestion control and loss recovery                         │
└─────────────────────────────────────────────────────────────────┘
```

### Connection Lifecycle

```
Owner Process                         quic library
     │                                     │
     │  hackney_h3:connect(...)          │
     ├────────────────────────────────────►│ Create UDP socket
     │                                     │ Generate TLS keys
     │                                     │ Send Initial packet
     │◄────────────────────────────────────┤ {ok, ConnRef}
     │                                     │
     │  {select, _, _, ready_input}        │
     │◄────────────────────────────────────┤ UDP packet received
     │                                     │
     │  hackney_h3:process(ConnRef)      │
     ├────────────────────────────────────►│ Process QUIC packets
     │                                     │ Continue handshake
     │  {h3, ConnRef, {connected, Info}} │
     │◄────────────────────────────────────┤
     │                                     │
     │  ... (request/response cycle) ...   │
     │                                     │
     │  hackney_h3:close(ConnRef, ...)   │
     ├────────────────────────────────────►│ Send CONNECTION_CLOSE
     │  {h3, ConnRef, {closed, normal}}  │
     │◄────────────────────────────────────┤
     │                                     │
```

### Benefits of Pure Erlang Implementation

| Aspect | Pure Erlang | NIF-based |
|--------|-------------|-----------|
| Portability | All platforms | Requires C compiler |
| Build complexity | rebar3 compile | CMake + dependencies |
| Debugging | Erlang tools | GDB/LLDB |
| Crash isolation | Process crash | Possible VM crash |
| Hot code loading | Supported | Limited |

## HTTP/2 Multiplexing

HTTP/2 connections are handled differently from HTTP/1.1. A single HTTP/2 connection can handle multiple concurrent requests via stream multiplexing.

### HTTP/2 Pool Design

The pool maintains a separate map for HTTP/2 connections:

```erlang
-record(state, {
    %% ... existing fields ...

    %% HTTP/2 connections: one per host, shared across callers
    h2_connections = #{}  %% #{Key => Pid}
}).
```

Key differences from HTTP/1.1 pooling:

| Aspect | HTTP/1.1 | HTTP/2 |
|--------|----------|--------|
| Connections per host | Multiple (pool) | One (shared) |
| Checkout behavior | Exclusive access | Shared access |
| Checkin behavior | Return to pool | Keep in pool |
| Request handling | Sequential | Multiplexed streams |

### HTTP/2 Connection Flow

```
hackney:get("https://api.example.com/data")
    │
    ▼
┌─────────────────────────────────────┐
│ 1. Check for existing HTTP/2 conn   │
│    checkout_h2(Host, Port, ...)     │
│    → Returns {ok, Pid} or none      │
└─────────────────┬───────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
   {ok, Pid}              none
   (reuse!)                 │
        │                   ▼
        │         ┌─────────────────────┐
        │         │ 2. Normal TCP flow  │
        │         │    checkout → new   │
        │         │    → upgrade SSL    │
        │         └──────────┬──────────┘
        │                    │
        │                    ▼
        │         ┌─────────────────────┐
        │         │ 3. Check protocol   │
        │         │    get_protocol()   │
        │         │    → http2 | http1  │
        │         └──────────┬──────────┘
        │                    │
        │              ┌─────┴─────┐
        │              │           │
        │           http2       http1
        │              │           │
        │              ▼           │
        │    ┌─────────────────┐   │
        │    │ 4. Register H2  │   │
        │    │    register_h2()│   │
        │    └────────┬────────┘   │
        │             │            │
        └──────┬──────┘            │
               │                   │
               ▼                   │
┌─────────────────────────────────────┐
│ 5. Send request                     │
│    HTTP/2: assign StreamId          │
│    HTTP/1.1: send directly          │
└─────────────────────────────────────┘
```

### Stream Multiplexing in hackney_conn

Each `hackney_conn` process maintains a map of active HTTP/2 streams:

```erlang
-record(conn_data, {
    %% HTTP/2 state machine (from cowlib)
    h2_machine :: tuple(),

    %% Active streams: #{StreamId => {Caller, State}}
    h2_streams = #{} :: #{
        pos_integer() => {gen_statem:from(), atom()}
    }
}).
```

When a request arrives:

```erlang
%% In hackney_conn.erl
do_h2_request(From, Method, Path, Headers, Body, Data) ->
    %% 1. Get next stream ID from h2_machine
    {ok, StreamId, H2Machine1} = hackney_cow_http2_machine:init_stream(...),

    %% 2. Track caller for this stream
    Streams = maps:put(StreamId, {From, waiting_response}, Data#conn_data.h2_streams),

    %% 3. Send HEADERS frame (and DATA if body present)
    HeadersFrame = hackney_cow_http2:headers(StreamId, ...),
    Transport:send(Socket, HeadersFrame),

    %% 4. Return updated state (caller will receive reply when response arrives)
    {keep_state, Data#conn_data{h2_streams = Streams}}.
```

When a response arrives:

```erlang
%% Response for StreamId received
handle_h2_frame({headers, StreamId, ...}, Data) ->
    %% Lookup caller from h2_streams
    {From, _State} = maps:get(StreamId, Data#conn_data.h2_streams),

    %% Reply to the correct caller
    gen_statem:reply(From, {ok, Status, Headers, Body}),

    %% Remove completed stream
    Streams = maps:remove(StreamId, Data#conn_data.h2_streams),
    {ok, Data#conn_data{h2_streams = Streams}}.
```

### Benefits of HTTP/2 Multiplexing

1. **Reduced latency** - No connection setup for subsequent requests
2. **Better resource usage** - One TCP connection instead of many
3. **Head-of-line blocking avoided** - Responses can arrive out of order
4. **Server efficiency** - Servers prefer fewer connections with more streams

### ALPN Protocol Negotiation

HTTP/2 is negotiated during TLS handshake via ALPN:

```erlang
%% In hackney_ssl.erl
alpn_opts(Opts) ->
    Protocols = proplists:get_value(protocols, Opts, [http2, http1]),
    AlpnProtos = [proto_to_alpn(P) || P <- Protocols],
    [{alpn_advertised_protocols, AlpnProtos}].

proto_to_alpn(http2) -> <<"h2">>;
proto_to_alpn(http1) -> <<"http/1.1">>.

%% After connection
get_negotiated_protocol(SslSocket) ->
    case ssl:negotiated_protocol(SslSocket) of
        {ok, <<"h2">>} -> http2;
        _ -> http1
    end.
```

## Connection Prewarm

After first use of a host, the pool maintains warm TCP connections ready for immediate use.

### How It Works

1. First request to `api.example.com:443` completes
2. On checkin, pool marks host as "activated"
3. Pool creates `prewarm_count` (default 4) TCP connections
4. Next request gets connection immediately (no connect latency)

### Configuration

```erlang
%% Global default
application:set_env(hackney, prewarm_count, 4).

%% Per-pool
hackney_pool:start_pool(mypool, [{prewarm_count, 8}]).

%% Explicit prewarm
hackney_pool:prewarm(default, "api.example.com", 443, 10).
```

### Prewarm for HTTPS

When an SSL connection is checked in (and closed), the pool still triggers TCP prewarm. This ensures TCP connections are ready for the next HTTPS request to upgrade.

## Request Flow

Complete flow for an HTTPS request with pooling:

```
hackney:get("https://api.example.com/data")
    │
    ▼
┌─────────────────────────────────────┐
│ 1. Load Regulation                  │
│    acquire("api.example.com", 443,  │
│            MaxPerHost, Timeout)     │
│    → Blocks if at limit             │
└─────────────────┬───────────────────┘
                  │ ok
                  ▼
┌─────────────────────────────────────┐
│ 2. Pool Checkout                    │
│    checkout(Host, 443, hackney_tcp) │
│    → Returns Pid or none            │
└─────────────────┬───────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
   {ok, Pid}              none
        │                   │
        │                   ▼
        │         ┌─────────────────┐
        │         │ Create new conn │
        │         │ hackney_conn_sup│
        │         └────────┬────────┘
        │                  │
        └────────┬─────────┘
                 │
                 ▼
┌─────────────────────────────────────┐
│ 3. SSL Upgrade                      │
│    upgrade_to_ssl(Pid, SslOpts)     │
│    → TCP socket becomes SSL         │
└─────────────────┬───────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│ 4. HTTP Request                     │
│    send_request(Pid, Method, ...)   │
│    recv_response(Pid)               │
└─────────────────┬───────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│ 5. Checkin (async)                  │
│    Connection closed (SSL)          │
│    TCP prewarm triggered            │
└─────────────────┬───────────────────┘
                  │
                  ▼
┌─────────────────────────────────────┐
│ 6. Load Regulation Release          │
│    release("api.example.com", 443)  │
│    → Slot available for next req    │
└─────────────────────────────────────┘
```

## Monitoring and Stats

### Pool Stats

```erlang
hackney_pool:get_stats(PoolName).
%% Returns:
%% [{name, PoolName},
%%  {max, MaxConnections},
%%  {in_use_count, InUse},
%%  {free_count, Free},
%%  {queue_count, 0}]  %% Always 0, load regulation handles queuing
```

### Per-Host Stats

```erlang
hackney_pool:host_stats(PoolName, Host, Port).
%% Returns:
%% [{active, N},    %% Currently in use (from load_regulation)
%%  {in_use, N},    %% Checked out from pool
%%  {free, N}]      %% Available in pool
```

### Load Regulation Stats

```erlang
hackney_load_regulation:current(Host, Port).
%% Returns: integer() - current concurrent connections to host
```

## Advantages of This Architecture

### vs. hackney 1.x

| Aspect | 1.x | 2.x |
|--------|-----|-----|
| State storage | ETS tables | Process state |
| Socket ownership | Transferred between processes | Always connection process |
| Error cleanup | Manual via manager | Automatic via process exit |
| SSL pooling | Yes (security risk) | No (TCP only) |
| Connection limits | Global pool size | Per-host limits |
| Prewarm | No | Yes |

### vs. Other HTTP Clients

**Process isolation**: Each connection is independent. A slow response on one connection doesn't block others. A crash in one connection doesn't affect others.

**Backpressure**: Load regulation naturally applies backpressure when a server is overwhelmed. Requests wait rather than creating unbounded connections.

**Resource control**: Per-host limits prevent a single slow host from consuming all connections. Different hosts are isolated.

**SSL security**: SSL connections are never reused, preventing session confusion attacks and ensuring fresh handshakes.

**Prewarm efficiency**: Frequently-used hosts have warm connections ready, eliminating connection latency for subsequent requests.

## Configuration Reference

### Pool Options

| Option | Default | Description |
|--------|---------|-------------|
| `pool_size` / `max_connections` | 50 | Warm (idle) connections kept for reuse. Concurrency is capped by `max_per_host`; requests above this open overflow connections that close at checkin |
| `timeout` / `keepalive_timeout` | 2000 | Idle timeout (max 2000ms) |
| `prewarm_count` | 4 | Connections to maintain per host |

### Request Options

| Option | Default | Description |
|--------|---------|-------------|
| `pool` | `default` | Pool name, or `false` for no pooling |
| `max_per_host` | 50 | Max concurrent connections to host |
| `checkout_timeout` | 8000 | Timeout to acquire connection slot |
| `connect_timeout` | 8000 | TCP connect timeout |
| `recv_timeout` | 5000 | Response receive timeout |

### Application Environment

```erlang
%% In sys.config or application:set_env
{hackney, [
    {pool_handler, hackney_pool},
    {max_connections, 50},
    {timeout, 2000},
    {prewarm_count, 4}
]}.
```
