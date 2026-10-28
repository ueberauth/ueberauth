# HTTP/2 Guide

This guide covers hackney's HTTP/2 support.

## Overview

Hackney supports HTTP/2 with automatic protocol negotiation via ALPN (Application-Layer Protocol Negotiation). When connecting to an HTTPS server that supports HTTP/2, hackney will automatically use it.

### Key Features

- **Automatic negotiation** - HTTP/2 is negotiated during TLS handshake via ALPN
- **Transparent API** - Same `hackney:get/post/request` functions work for both HTTP/1.1 and HTTP/2
- **Multiplexing** - Multiple requests share a single connection
- **Header compression** - HPACK compression reduces overhead
- **Flow control** - Automatic window management
- **Delegated to `erlang_h2`** - the underlying HTTP/2 stack is the `h2`
  hex package; hackney exposes the same request API it always did

## Quick Start

```erlang
%% HTTP/2 is used automatically for HTTPS when server supports it
{ok, 200, Headers, Body} = hackney:get(<<"https://nghttp2.org/">>).

%% Headers are lowercase in HTTP/2
{<<"server">>, Server} = lists:keyfind(<<"server">>, 1, Headers).
```

## Protocol Selection

### Default Behavior

By default, hackney advertises both HTTP/2 and HTTP/1.1 via ALPN, preferring HTTP/2:

```erlang
%% Server chooses protocol (usually HTTP/2 if supported)
hackney:get(<<"https://example.com/">>).
```

### Force HTTP/2 Only

```erlang
hackney:get(URL, [], <<>>, [{protocols, [http2]}]).
```

### Force HTTP/1.1 Only

```erlang
hackney:get(URL, [], <<>>, [{protocols, [http1]}]).
```

### Specify Preference Order

```erlang
%% Prefer HTTP/1.1, fall back to HTTP/2
hackney:get(URL, [], <<>>, [{protocols, [http1, http2]}]).
```

## Detecting the Protocol

HTTP/2 responses have lowercase header names, while HTTP/1.1 preserves the original case:

```erlang
{ok, 200, Headers, Body} = hackney:get(URL),

%% Check first header's key
case hd(Headers) of
    {<<"date">>, _} -> io:format("HTTP/2~n");
    {<<"Date">>, _} -> io:format("HTTP/1.1~n")
end.
```

For low-level access, use `hackney_conn` directly:

```erlang
{ok, Conn} = hackney_conn:start_link(#{
    host => "nghttp2.org",
    port => 443,
    transport => hackney_ssl
}),
ok = hackney_conn:connect(Conn, 10000),
Protocol = hackney_conn:get_protocol(Conn).  %% http2 | http1
```

## HTTP/2 vs HTTP/1.1 Differences

### Header Names

| HTTP/2 | HTTP/1.1 |
|--------|----------|
| `<<"content-type">>` | `<<"Content-Type">>` |
| `<<"cache-control">>` | `<<"Cache-Control">>` |

Always use case-insensitive header lookups:

```erlang
find_header(Name, Headers) ->
    NameLower = hackney_bstr:to_lower(Name),
    case lists:filter(
        fun({K, _}) -> hackney_bstr:to_lower(K) =:= NameLower end,
        Headers
    ) of
        [{_, V} | _] -> V;
        [] -> undefined
    end.
```

### Response Format

Response format is now **consistent** across all protocols (HTTP/1.1, HTTP/2, and HTTP/3):

```erlang
%% All protocols return the same format
{ok, Status, Headers, Body} = hackney:get(URL).
```

For incremental body streaming, use async mode:

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [async]),
receive
    {hackney_response, Ref, {status, Status, _}} -> ok
end,
receive
    {hackney_response, Ref, {headers, Headers}} -> ok
end,
receive
    {hackney_response, Ref, done} -> ok;
    {hackney_response, Ref, Chunk} -> process(Chunk)
end.
```

With `{async, once}` you pull instead: status and headers arrive eagerly,
then each `hackney:stream_next/1` delivers exactly one message (a body chunk
or `done`). On HTTP/2 the stream uses manual flow control, so data you have
not pulled keeps the server's send window closed and in-flight data stays
bounded to one window.

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [{async, once}]),
%% ... receive status and headers as above, then:
ok = hackney:stream_next(Ref),
receive
    {hackney_response, Ref, done} -> ok;
    {hackney_response, Ref, Chunk} ->
        process(Chunk)  %% call stream_next/1 again for the next chunk
end.
```

## Connection Multiplexing

HTTP/2 allows multiple concurrent requests on a single connection. Unlike HTTP/1.1 where each request needs its own connection, HTTP/2 multiplexes requests as independent "streams" on a shared connection.

### Automatic Multiplexing

When using the high-level API, hackney automatically reuses HTTP/2 connections:

```erlang
%% All three requests share ONE TCP connection
{ok, _, _, _} = hackney:get(<<"https://nghttp2.org/">>).
{ok, _, _, _} = hackney:get(<<"https://nghttp2.org/blog/">>).
{ok, _, _, _} = hackney:get(<<"https://nghttp2.org/documentation/">>).
```

You can verify this:

```erlang
{ok, Conn1} = hackney:connect(hackney_ssl, "nghttp2.org", 443, []).
{ok, Conn2} = hackney:connect(hackney_ssl, "nghttp2.org", 443, []).
{ok, Conn3} = hackney:connect(hackney_ssl, "nghttp2.org", 443, []).

Conn1 =:= Conn2.  %% true - same PID
Conn2 =:= Conn3.  %% true - same PID
```

### Explicit Connection Reuse

For more control, get a connection and reuse it directly:

```erlang
%% 1. Get a connection
{ok, Conn} = hackney:connect(hackney_ssl, "nghttp2.org", 443, []).

%% 2. Verify HTTP/2
http2 = hackney_conn:get_protocol(Conn).

%% 3. Make multiple requests on same connection
{ok, 200, _, _} = hackney:send_request(Conn, {get, <<"/">>, [], <<>>}).
{ok, 200, _, _} = hackney:send_request(Conn, {get, <<"/blog/">>, [], <<>>}).
{ok, 200, _, _} = hackney:send_request(Conn, {get, <<"/">>, [], <<>>}).

%% 4. Close when done
hackney:close(Conn).
```

### Concurrent Requests

Fire multiple requests in parallel on the same connection:

```erlang
{ok, Conn} = hackney:connect(hackney_ssl, "nghttp2.org", 443, []).

%% Spawn 3 concurrent requests
Self = self(),
Paths = [<<"/">>, <<"/blog/">>, <<"/documentation/">>],
[spawn(fun() ->
    Result = hackney:send_request(Conn, {get, Path, [], <<>>}),
    Self ! {Path, Result}
end) || Path <- Paths].

%% Collect responses (may arrive out of order due to multiplexing)
[receive {Path, {ok, Status, _, _}} -> {Path, Status} end || _ <- Paths].
```

### How It Works (Architecture)

```
┌─────────────────────────────────────────────────────────────────┐
│                        hackney_pool                              │
│                                                                  │
│  h2_connections = #{ {Host, Port, Transport} => Pid }           │
│                                                                  │
│  checkout_h2(Host, Port, ...) ->                                │
│      case maps:get(Key, h2_connections) of                      │
│          Pid -> {ok, Pid};      %% Reuse existing               │
│          undefined -> none       %% Create new                   │
│      end                                                         │
│                                                                  │
│  register_h2(Host, Port, ..., Pid) ->                           │
│      h2_connections#{Key => Pid}  %% Store for reuse            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              hackney_conn (gen_statem process)                   │
│                                                                  │
│  h2_machine = <HTTP/2 state machine>                            │
│                                                                  │
│  h2_streams = #{                                                │
│      1 => {CallerA, waiting_response},                          │
│      3 => {CallerB, waiting_response},                          │
│      5 => {CallerC, waiting_response}                           │
│  }                                                               │
│                                                                  │
│  Request from CallerA → init_stream() → StreamId=1              │
│  Request from CallerB → init_stream() → StreamId=3              │
│  Request from CallerC → init_stream() → StreamId=5              │
│                                                                  │
│  Response for StreamId=3 arrives:                               │
│      → lookup h2_streams[3] → CallerB                           │
│      → gen_statem:reply(CallerB, {ok, Status, Headers, Body})   │
└─────────────────────────────────────────────────────────────────┘
```

**Key points:**

1. **One connection per host** - The pool stores at most one HTTP/2 connection per `{Host, Port, Transport}` tuple
2. **Connection sharing** - Unlike HTTP/1.1, HTTP/2 connections are not "checked out" exclusively; multiple callers share the same connection
3. **Stream isolation** - Each request gets a unique StreamId; responses are routed back to the correct caller via the `h2_streams` map
4. **Automatic registration** - When a new SSL connection negotiates HTTP/2, it's automatically registered in the pool for future reuse
5. **No single owner** - A shared connection does not belong to the process that opened it. If a caller exits, only its own stream is reset; the other callers' requests continue
6. **Idle close** - A shared connection closes itself once it has had no open stream for the pool `timeout`, and the next request opens a new one

## Server Push

Server push (RFC 7540 §8.2) is deprecated and no longer supported by the
underlying `h2` library. The `enable_push` option is accepted for
backwards-compatibility but is a no-op; pushes from the server are silently
refused.

## Streaming Request and Response Bodies

HTTP/2 supports the same streaming API as HTTP/1.1 and HTTP/3. Pass `stream` as
the body to send the request body in chunks, then read the response either in
full or chunk by chunk.

```erlang
{ok, ConnRef} = hackney:request(post, URL, Headers, stream,
                                [{protocols, [http2]}]),
ok = hackney:send_body(ConnRef, <<"part 1">>),
ok = hackney:send_body(ConnRef, <<"part 2">>),
ok = hackney:finish_send_body(ConnRef),
{ok, Status, RespHeaders, ConnRef} = hackney:start_response(ConnRef),

%% Read the whole body:
{ok, Body} = hackney:body(ConnRef).

%% Or pull it chunk by chunk:
stream_loop(ConnRef) ->
    case hackney:stream_body(ConnRef) of
        {ok, Chunk} -> handle(Chunk), stream_loop(ConnRef);
        done        -> ok;
        {error, R}  -> {error, R}
    end.
```

`send_body/2` also accepts a producer fun (`fun() -> {ok, Data} | eof end` or
`{fun(State) -> {ok, Data, NewState} | eof end, State}`), matching the
HTTP/1.1 behaviour.

Each chunk is sent as a DATA frame and the request stream is closed with
END_STREAM on `finish_send_body/1`. The `h2` connection buffers beyond the
peer's flow-control window and drains as WINDOW_UPDATEs arrive.

A streaming upload uses its pooled connection on its own. From
`hackney:request/5` with `stream` until `start_response/1`, the connection
takes no new requests: requests to the same host in the meantime open another
connection, and streams already open on it are not affected. `send_body/2`
and `finish_send_body/1` find the upload through the connection pid, so two
uploads cannot share one connection.

## Bidirectional Streaming (gRPC-style)

For full-duplex streams, where the client sends and receives on the same
stream interleaved (as gRPC bidi RPCs do), use the `h2_*` API. It mirrors the
`ws_*` / `wt_*` APIs: `h2_open` returns a pid, `h2_send` writes DATA frames,
`h2_recv` reads inbound messages, and `h2_send_trailers` / `h2_send(_, _, fin)`
half-close the send side. The URL must be `https` (HTTP/2 is negotiated over
ALPN), and each `h2_open` uses its own dedicated connection.

```erlang
{ok, S} = hackney:h2_open(<<"https://host/pkg.Service/BidiMethod">>,
                          [{<<"content-type">>, <<"application/grpc">>},
                           {<<"te">>, <<"trailers">>}],
                          [{ssl_options, [...]}]),

{ok, {response, 200, _Headers}} = hackney:h2_recv(S),
ok = hackney:h2_send(S, Frame1),
{ok, {data, Reply1}} = hackney:h2_recv(S),
ok = hackney:h2_send(S, Frame2),          %% keep sending while receiving
{ok, {data, Reply2}} = hackney:h2_recv(S),
ok = hackney:h2_send(S, <<>>, fin),        %% half-close the request
{ok, {trailers, Trailers}} = hackney:h2_recv(S),
{ok, done} = hackney:h2_recv(S),
ok = hackney:h2_close(S).
```

`h2_recv/1,2` returns `{response, Status, Headers}`, `{data, Data}`,
`{trailers, Trailers}`, or `done` (the peer ended the stream); after `done` it
returns `{error, closed}`. With `{active, true | once}` the same messages are
delivered to the owner as `{hackney_h2, Pid, Msg}` instead (errors as
`{hackney_h2_error, Pid, Reason}`).

Open with `{flow_control, manual}` to apply receive backpressure: the window is
only replenished when you call `h2_consume(Pid, NBytes)` for the bytes you have
processed. The API carries raw bytes; gRPC message framing is the caller's
responsibility.

## Flow Control

HTTP/2 has built-in flow control to prevent fast senders from overwhelming slow receivers. Hackney handles this automatically:

- Sends WINDOW_UPDATE frames as data is consumed
- Respects server's flow control windows when sending

No configuration is needed for most use cases.

### Sending Large Bodies

A request body larger than the server's flow control window cannot be sent in one shot: the send waits for the server to open the window with WINDOW_UPDATE frames. Hackney blocks the request until the body is fully handed to the connection, up to `send_timeout` (default 30000 ms). If the server never opens the window, the request fails with `{error, timeout}` instead of hanging.

```erlang
%% Give a slow server more time to drain a large upload
hackney:post(URL, Headers, LargeBody, [{send_timeout, 120000}]).

%% Wait forever
hackney:post(URL, Headers, LargeBody, [{send_timeout, infinity}]).

%% Opt out of blocking: fail fast with {error, send_buffer_full} when the
%% body exceeds the window plus the connection's send buffer
hackney:post(URL, Headers, Body, [{send_timeout, nonblock}]).
```

The option applies to whole-body requests and to streamed bodies sent with `hackney:send_body/2`. HTTP/1.1 and HTTP/3 requests ignore it.

## Error Handling

HTTP/2 specific errors:

```erlang
case hackney:get(URL) of
    {ok, Status, Headers, Body} ->
        ok;
    {error, {goaway, ErrorCode}} ->
        %% Peer sent GOAWAY
        io:format("HTTP/2 GOAWAY: ~p~n", [ErrorCode]);
    {error, {stream_error, ErrorCode}} ->
        %% Peer sent RST_STREAM for this request
        io:format("HTTP/2 stream reset: ~p~n", [ErrorCode]);
    {error, {closed, _Reason}} ->
        %% Connection closed
        ok;
    {error, Reason} ->
        io:format("Error: ~p~n", [Reason])
end.
```

## Performance Tips

### Reuse Connections

HTTP/2's multiplexing works best with connection reuse:

```erlang
%% Good: connections are reused
[hackney:get(URL, [], <<>>, [{pool, default}]) || _ <- lists:seq(1, 100)].

%% Bad: new connection each time
[hackney:get(URL, [], <<>>, [{pool, false}]) || _ <- lists:seq(1, 100)].
```

### Concurrent Requests

Take advantage of multiplexing for parallel requests:

```erlang
Parent = self(),
URLs = [<<"https://api.example.com/1">>, <<"https://api.example.com/2">>],
Pids = [spawn_link(fun() ->
    Result = hackney:get(URL),
    Parent ! {self(), Result}
end) || URL <- URLs],
Results = [receive {Pid, R} -> R end || Pid <- Pids].
```

## Compatibility

### Server Requirements

HTTP/2 requires:
- TLS 1.2 or higher
- ALPN support
- Server HTTP/2 support

Plain HTTP/2 (h2c) is not currently supported.

### Fallback

If the server doesn't support HTTP/2, hackney automatically falls back to HTTP/1.1:

```erlang
%% Works regardless of server HTTP/2 support
{ok, _, _, _} = hackney:get(<<"https://example.com/">>).
```

## Examples

### Elixir

```elixir
# Start hackney
Application.ensure_all_started(:hackney)

# HTTP/2 request - body is returned directly
{:ok, status, headers, body} = :hackney.get("https://nghttp2.org/")

# Check protocol via header case
case headers do
  [{"date", _} | _] -> IO.puts("HTTP/2")
  [{"Date", _} | _] -> IO.puts("HTTP/1.1")
end
```

### Force Protocol

```erlang
%% HTTP/2 only - fails if server doesn't support it
{ok, _, _, _} = hackney:get(URL, [], <<>>, [{protocols, [http2]}]).

%% HTTP/1.1 only - never uses HTTP/2
{ok, _, _, _} = hackney:get(URL, [], <<>>, [{protocols, [http1]}]).
```

## Troubleshooting

### HTTP/2 Not Being Used

1. Check if server supports HTTP/2:
   ```bash
   curl -v --http2 https://example.com/ 2>&1 | grep -i alpn
   ```

2. Verify TLS is being used (HTTP/2 requires HTTPS)

3. Check for explicit `{protocols, [http1]}` in options

### Connection Errors

If you see `{error, closed}` immediately after connect:

1. Server may have sent GOAWAY frame
2. TLS handshake may have failed
3. Check server logs for details

## Next Steps

- [HTTP Guide](http_guide.md) - General HTTP features
- [WebSocket Guide](websocket_guide.md) - WebSocket support
- [Design Guide](design.md) - Architecture details
