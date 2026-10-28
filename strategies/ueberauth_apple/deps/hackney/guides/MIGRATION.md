# Migration Guide

## Migrating from hackney 2.x to 3.x

### Quick Summary

- **Response format**: Body is now always returned directly in the response
- **`with_body` option**: Deprecated and ignored
- **`hackney:body/1,2` and `hackney:stream_body/1`**: Not needed for regular requests (the body is returned directly), but still available to read the response after `start_response/1` in streaming body mode
- **Async mode**: Now works consistently across HTTP/1.1, HTTP/2, and HTTP/3
- **Metrics removed**: `hackney_metrics` and the prometheus/dummy
  backends are gone. Metrics are now user-supplied middleware. See the
  [Middleware Guide](middleware.md) for the prometheus migration recipe.

### Breaking Changes

#### Response Format

The most significant change is that the response body is now always returned directly in the response tuple, regardless of protocol:

```erlang
%% Before (2.x) - HTTP/1.1
{ok, 200, Headers, ConnPid} = hackney:get(URL),
{ok, Body} = hackney:body(ConnPid).

%% Before (2.x) - HTTP/2
{ok, 200, Headers, Body} = hackney:get(URL).  %% Already returned body

%% After (3.x) - All protocols
{ok, 200, Headers, Body} = hackney:get(URL).  %% Consistent!
```

#### Deprecated Options and Functions

| Deprecated | Replacement |
|------------|-------------|
| `{with_body, true/false}` | Option ignored - body always returned |
| `hackney:body/1` | Body in response tuple |
| `hackney:body/2` | Body in response tuple |
| `hackney:stream_body/1` | Use async mode |

#### Streaming Response Bodies

For incremental body streaming, use async mode instead of `stream_body/1`:

```erlang
%% Before (2.x) - sync streaming
{ok, 200, Headers, Pid} = hackney:get(URL),
{ok, Chunk1} = hackney:stream_body(Pid),
{ok, Chunk2} = hackney:stream_body(Pid),
done = hackney:stream_body(Pid).

%% After (3.x) - async streaming
{ok, Ref} = hackney:get(URL, [], <<>>, [async]),
receive {hackney_response, Ref, {status, 200, _}} -> ok end,
receive {hackney_response, Ref, {headers, Headers}} -> ok end,
stream_loop(Ref).

stream_loop(Ref) ->
    receive
        {hackney_response, Ref, done} -> ok;
        {hackney_response, Ref, Chunk} ->
            process_chunk(Chunk),
            stream_loop(Ref)
    end.
```

For on-demand streaming (pull-based), use `{async, once}`:

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [{async, once}]),
receive {hackney_response, Ref, {status, 200, _}} -> ok end,
hackney:stream_next(Ref),
receive {hackney_response, Ref, {headers, Headers}} -> ok end,
hackney:stream_next(Ref),
receive {hackney_response, Ref, Chunk} -> process(Chunk) end,
hackney:stream_next(Ref),
%% ... continue until done
```

### HTTP/2 Async Mode

HTTP/2 async mode now works correctly. Previously, async requests over HTTP/2 would fail or behave incorrectly. Now the same async API works for all protocols:

```erlang
%% Works for HTTP/1.1, HTTP/2, and HTTP/3
{ok, Ref} = hackney:get(<<"https://nghttp2.org/">>, [], <<>>, [async]),
receive
    {hackney_response, Ref, {status, Status, _}} ->
        io:format("Status: ~p~n", [Status])
end,
receive
    {hackney_response, Ref, {headers, Headers}} ->
        io:format("Headers: ~p~n", [Headers])
end,
receive
    {hackney_response, Ref, done} -> ok;
    {hackney_response, Ref, Chunk} -> io:format("Chunk: ~p~n", [Chunk])
end.
```

---

# Migrating from hackney 1.x to 2.x

## Quick Summary

- **Simple requests**: No changes needed
- **Streaming/async**: Same API, `ClientRef` is now a PID
- **Pool**: Per-host limits replace global pool size, SSL not pooled
- **Proxy**: URL-based config, env vars work automatically

## Architecture: Before and After

### 1.x Design

```
- State stored in ETS tables
- Multiple modules coordinate via hackney_manager
- Socket ownership transferred between processes
- Complex cleanup on errors
- Global pool with max_connections limit
- SSL connections pooled
```

### 2.x Design

```
- One gen_statem process per connection
- Process owns its socket and state
- Clean OTP supervision
- Automatic cleanup on process exit
- Per-host connection limits via load regulation
- TCP-only pooling (SSL connections never pooled)
- Connection prewarm for low-latency reuse
```

See [Design Guide](design.md) for detailed architecture documentation.

### HTTP/2 Support (2.x only)

Hackney 2.x adds transparent HTTP/2 support:

```
- Automatic ALPN negotiation on HTTPS connections
- Connection multiplexing (single connection, multiple streams)
- Header compression (HPACK)
- Server push support
- Same API for both HTTP/1.1 and HTTP/2
```

See [HTTP/2 Guide](http2_guide.md) for details.

### Key Differences

| Aspect | 1.x | 2.x |
|--------|-----|-----|
| State storage | ETS tables | Process state |
| Connection handle | Opaque reference | PID |
| Socket ownership | Transferred between processes | Owned by connection process |
| Error cleanup | Manual via manager | Automatic via process exit |
| Supervision | Custom tracking | OTP supervisor |
| Pool scope | Global max_connections | Per-host limits |
| SSL pooling | Yes | No (security) |
| Prewarm | No | Yes (default 4 per host) |
| HTTP/2 | No | Yes (automatic via ALPN) |

## What Changed

### Connection Handle and Response Format

```erlang
%% 1.x - opaque reference, body read separately
{ok, StatusCode, Headers, Ref} = hackney:get(URL),
{ok, Body} = hackney:body(Ref).

%% 2.x/3.x - body returned directly
{ok, StatusCode, Headers, Body} = hackney:get(URL).
```

In 3.x, body is always returned directly in the response tuple for consistency across all protocols.

### Pool Behavior

The most significant change is how connection pooling works:

**1.x**: Single global pool with `max_connections` limit shared across all hosts.

**2.x**: Per-host connection limits. Each host gets up to `max_per_host` concurrent connections (default 50). TCP connections are pooled; SSL connections are never pooled.

```erlang
%% 1.x - global pool limit
hackney_pool:start_pool(mypool, [{max_connections, 100}]).  %% 100 total

%% 2.x - per-host limit (100 connections per host)
hackney_pool:start_pool(mypool, [{max_connections, 100}]).
%% Plus request option:
hackney:get(URL, [], <<>>, [{pool, mypool}, {max_per_host, 100}]).
```

### SSL Connections

**1.x**: SSL connections were pooled and reused.

**2.x**: SSL connections are never pooled. Each HTTPS request either:
- Gets a TCP connection from pool and upgrades to SSL
- Creates a new connection with SSL

This is a security improvement - SSL session state is never shared.

### Connection Prewarm

**2.x only**: After first use of a host, the pool maintains warm TCP connections:

```erlang
%% Automatic after first request to host
%% Or explicit:
hackney_pool:prewarm(default, "api.example.com", 443, 4).
```

### Load Regulation

**2.x only**: Per-host backpressure when connection limit reached:

```erlang
%% Request waits if api.example.com has 50 active connections
hackney:get("https://api.example.com/data", [], <<>>, [
    {max_per_host, 50},
    {checkout_timeout, 5000}  %% Wait up to 5s for slot
]).

%% Returns {error, checkout_timeout} if slot not available in time
```

### Removed Functions

| 1.x | 2.x |
|-----|-----|
| `hackney:cancel_request/1` | `hackney:close/1` |
| `hackney:controlling_process/2` | Not needed |
| `hackney:send_multipart_body/2` | `hackney:send_body/2` |

### Removed Modules

Merged into `hackney_conn`:
- `hackney_connect`
- `hackney_connection`
- `hackney_request`
- `hackney_response`
- `hackney_stream`

## Migration Patterns

### Simple Request

Body is now returned directly (no need to call `hackney:body/1`):

```erlang
%% 1.x
{ok, 200, Headers, Ref} = hackney:get(URL),
{ok, Body} = hackney:body(Ref).

%% 2.x/3.x - simpler!
{ok, 200, Headers, Body} = hackney:get(URL).
```

### Streaming Request Body

The streaming body API allows you to send the request body in chunks. This is useful for uploading large files or data that is generated incrementally.

**Basic usage:**

```erlang
%% 1. Start request with body = stream
{ok, ConnPid} = hackney:request(post, URL, Headers, stream, []),

%% 2. Send body chunks (can be called multiple times)
ok = hackney:send_body(ConnPid, <<"first chunk">>),
ok = hackney:send_body(ConnPid, <<"second chunk">>),

%% 3. Signal end of body
ok = hackney:finish_send_body(ConnPid),

%% 4. Get response headers
{ok, Status, RespHeaders, ConnPid} = hackney:start_response(ConnPid),

%% 5. Read response body
{ok, RespBody} = hackney:body(ConnPid),

%% 6. Close connection when done
hackney:close(ConnPid).
```

**With chunked transfer encoding:**

When the body size is unknown, use chunked transfer encoding:

```erlang
Headers = [{<<"Transfer-Encoding">>, <<"chunked">>},
           {<<"Content-Type">>, <<"application/octet-stream">>}],
{ok, ConnPid} = hackney:post(URL, Headers, stream),

%% Send chunks as they become available
lists:foreach(fun(Chunk) ->
    ok = hackney:send_body(ConnPid, Chunk)
end, generate_chunks()),

ok = hackney:finish_send_body(ConnPid),
{ok, Status, RespHeaders, ConnPid} = hackney:start_response(ConnPid),
{ok, RespBody} = hackney:body(ConnPid),
hackney:close(ConnPid).
```

**With known Content-Length:**

```erlang
Data = <<"my large data">>,
Headers = [{<<"Content-Length">>, integer_to_binary(byte_size(Data))},
           {<<"Content-Type">>, <<"application/octet-stream">>}],
{ok, ConnPid} = hackney:post(URL, Headers, stream),

%% Send data in smaller chunks
ok = hackney:send_body(ConnPid, binary:part(Data, 0, 5)),
ok = hackney:send_body(ConnPid, binary:part(Data, 5, byte_size(Data) - 5)),

ok = hackney:finish_send_body(ConnPid),
{ok, Status, RespHeaders, ConnPid} = hackney:start_response(ConnPid),
{ok, RespBody} = hackney:body(ConnPid),
hackney:close(ConnPid).
```

**Note:** The `hackney:body/1` function is deprecated for regular requests (where body is returned directly), but is still used after `start_response/1` in streaming body mode to read the response.

### Async Response

No changes:

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [async]),
receive
    {hackney_response, Ref, {status, Status, _}} -> ok
end.
```

### Cancel Request

```erlang
%% 1.x
hackney:cancel_request(Ref).

%% 2.x
hackney:close(Ref).
```

### Pool Configuration

```erlang
%% 1.x - global pool limit
hackney_pool:start_pool(mypool, [{max_connections, 50}]),
hackney:get(URL, [], <<>>, [{pool, mypool}]).

%% 2.x - same API works, but behavior differs:
%% - max_connections is now per pool, not global limit
%% - Add max_per_host for per-host limiting
hackney_pool:start_pool(mypool, [
    {max_connections, 100},    %% Pool capacity
    {prewarm_count, 4},        %% Warm connections per host
    {timeout, 2000}            %% Keepalive timeout (max 2s)
]),
hackney:get(URL, [], <<>>, [
    {pool, mypool},
    {max_per_host, 50},        %% Per-host limit
    {checkout_timeout, 5000}   %% Wait time for slot
]).
```

### High-Concurrency Scenarios

If you were using a large global pool for high concurrency:

```erlang
%% 1.x - 1000 connections shared across all hosts
hackney_pool:start_pool(bigpool, [{max_connections, 1000}]).

%% 2.x - 100 connections per host (better isolation)
hackney_pool:start_pool(bigpool, [{max_connections, 1000}]),
hackney:get(URL, [], <<>>, [
    {pool, bigpool},
    {max_per_host, 100}  %% Each host gets up to 100
]).
```

### Monitoring Pool Stats

```erlang
%% 1.x
hackney_pool:get_stats(mypool).

%% 2.x - same, plus per-host stats
hackney_pool:get_stats(mypool).
hackney_pool:host_stats(mypool, "api.example.com", 443).
%% Returns: [{active, N}, {in_use, N}, {free, N}]
```

## Configuration Changes

### Application Environment

```erlang
%% 1.x
{hackney, [
    {max_connections, 50},
    {timeout, 150000}  %% Could be any value
]}.

%% 2.x
{hackney, [
    {max_connections, 50},
    {timeout, 2000},       %% Capped at 2000ms
    {prewarm_count, 4}     %% New option
]}.
```

### Timeout Capping

Keepalive timeout is now capped at 2000ms (2 seconds). This prevents issues with stale connections and aligns with common server defaults.

```erlang
%% 1.x - any timeout value
hackney_pool:start_pool(p, [{timeout, 300000}]).  %% 5 minutes

%% 2.x - capped at 2000ms
hackney_pool:start_pool(p, [{timeout, 300000}]).  %% Becomes 2000ms
```

## Requirements

Erlang/OTP 27+

## Help

https://github.com/benoitc/hackney/issues
