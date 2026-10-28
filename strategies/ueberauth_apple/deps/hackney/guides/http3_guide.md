# HTTP/3 Guide

This guide covers hackney's HTTP/3 support via QUIC.

## Overview

Hackney supports HTTP/3, the latest version of HTTP built on QUIC (UDP-based transport). HTTP/3 offers improved performance, especially on lossy networks, with features like connection migration and zero round-trip connection establishment.

### Key Features

- **QUIC transport** - UDP-based, encrypted by default with TLS 1.3
- **Transparent API** - Same `hackney:get/post/request` functions work for HTTP/3
- **Multiplexing** - Multiple streams without head-of-line blocking
- **Alt-Svc discovery** - Automatic HTTP/3 endpoint detection from Alt-Svc headers
- **Connection pooling** - HTTP/3 connections shared across callers
- **Negative caching** - Failed H3 attempts cached to avoid repeated failures

## Requirements

HTTP/3 support is provided by the [`erlang_quic`](https://github.com/benoitc/erlang_quic) dependency (module `quic_h3`), which handles the QUIC transport, QPACK header compression, HTTP/3 framing, and control streams. Hackney hosts only a thin adapter (`hackney_h3`) that translates `quic_h3` events into the internal connection protocol. No C dependencies, no external binaries required.

## Quick Start

```erlang
%% HTTP/3 request with explicit protocol selection
{ok, 200, Headers, Body} = hackney:get(
    <<"https://cloudflare.com/cdn-cgi/trace">>,
    [],
    <<>>,
    [{protocols, [http3]}, with_body]
).

%% Body contains: http=http/3
```

## Protocol Selection

### Default Behavior

By default, hackney uses HTTP/2 and HTTP/1.1 (not HTTP/3):

```erlang
%% Default: [http2, http1]
hackney:get(<<"https://example.com/">>).
```

### Enable HTTP/3

Add `http3` to the protocols list:

```erlang
%% Try HTTP/3 first, fall back to HTTP/2, then HTTP/1.1
hackney:get(URL, [], <<>>, [{protocols, [http3, http2, http1]}]).
```

### Force HTTP/3 Only

```erlang
%% HTTP/3 only - fails if H3 unavailable
hackney:get(URL, [], <<>>, [{protocols, [http3]}]).
```

### Force HTTP/2 Only

```erlang
hackney:get(URL, [], <<>>, [{protocols, [http2]}]).
```

### Force HTTP/1.1 Only

```erlang
hackney:get(URL, [], <<>>, [{protocols, [http1]}]).
```

## Detecting the Protocol

Check the negotiated protocol on a connection:

```erlang
{ok, Conn} = hackney:connect(hackney_ssl, "cloudflare.com", 443,
                              [{protocols, [http3]}]),
Protocol = hackney_conn:get_protocol(Conn).  %% http3 | http2 | http1
hackney:close(Conn).
```

Or verify via Cloudflare's trace endpoint:

```erlang
{ok, 200, _, Body} = hackney:get(
    <<"https://cloudflare.com/cdn-cgi/trace">>,
    [], <<>>,
    [{protocols, [http3]}, with_body]
),
%% Body contains "http=http/3" if using HTTP/3
```

## Alt-Svc Discovery

Servers advertise HTTP/3 support via the `Alt-Svc` response header:

```
Alt-Svc: h3=":443"; ma=86400
```

Hackney automatically caches these and uses HTTP/3 on subsequent requests:

```erlang
%% First request uses HTTP/2 or HTTP/1.1
%% Server returns Alt-Svc: h3=":443"; ma=86400
{ok, _, Headers1, _} = hackney:get(URL, [], <<>>, [{protocols, [http3, http2, http1]}]).

%% Alt-Svc is now cached, second request uses HTTP/3
{ok, _, Headers2, _} = hackney:get(URL, [], <<>>, [{protocols, [http3, http2, http1]}]).
```

### Manual Alt-Svc Cache Management

```erlang
%% Check if HTTP/3 is cached for a host
hackney_altsvc:lookup(<<"example.com">>, 443).
%% {ok, h3, 443} | none

%% Manually cache HTTP/3 endpoint
hackney_altsvc:cache(<<"example.com">>, 443, 443, 86400).

%% Clear cached entry
hackney_altsvc:clear(<<"example.com">>, 443).

%% Clear all cached entries
hackney_altsvc:clear_all().
```

## Connection Multiplexing

Like HTTP/2, HTTP/3 multiplexes requests as streams on a single QUIC connection:

```erlang
%% All requests share ONE QUIC connection
{ok, _, _, _} = hackney:get(<<"https://cloudflare.com/">>,
                            [], <<>>, [{protocols, [http3]}]).
{ok, _, _, _} = hackney:get(<<"https://cloudflare.com/cdn-cgi/trace">>,
                            [], <<>>, [{protocols, [http3]}]).
```

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        hackney_pool                              │
│                                                                  │
│  h3_connections = #{ {Host, Port, Transport} => Pid }           │
│                                                                  │
│  checkout_h3(Host, Port, ...) ->                                │
│      case maps:get(Key, h3_connections) of                      │
│          Pid -> {ok, Pid};      %% Reuse existing               │
│          undefined -> none       %% Create new                   │
│      end                                                         │
│                                                                  │
│  register_h3(Host, Port, ..., Pid) ->                           │
│      h3_connections#{Key => Pid}  %% Store for reuse            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              hackney_conn (gen_statem process)                   │
│                                                                  │
│  h3_conn = <QUIC connection reference>                          │
│                                                                  │
│  h3_streams = #{                                                │
│      0 => {CallerA, waiting_headers, <<>>},                     │
│      4 => {CallerB, waiting_headers, <<>>},                     │
│      8 => {CallerC, waiting_headers, <<>>}                      │
│  }                                                               │
│                                                                  │
│  Request from CallerA → open_stream() → StreamId=0              │
│  Request from CallerB → open_stream() → StreamId=4              │
│  Request from CallerC → open_stream() → StreamId=8              │
│                                                                  │
│  Response for StreamId=4 arrives:                               │
│      → lookup h3_streams[4] → CallerB                           │
│      → gen_statem:reply(CallerB, {ok, Status, Headers, Body})   │
└─────────────────────────────────────────────────────────────────┘
```

## IPv6

DNS resolution and address-family selection are handled by the `quic` library,
which races IPv6 and IPv4 with RFC 8305 Happy Eyeballs. Hostnames with AAAA
records, IPv6 tuples, and bracketed literals all work without extra options.

```erlang
%% Bracketed IPv6 literal
hackney:get(<<"https://[2606:4700::1111]/">>, [], <<>>, [{protocols, [http3]}]).

%% Force a family with the `family' connect option (inet | inet6)
hackney:get(<<"https://example.com/">>, [], <<>>,
            [{protocols, [http3]}, {connect_options, [{family, inet6}]}]).
```

`family` (and an optional `happy_eyeballs` boolean) may be set in
`connect_options` or `ssl_options`; both are forwarded to the QUIC layer.

## 0-RTT and Session Resumption

After the first HTTP/3 connection to a host, hackney caches the server's TLS
session ticket in the pool, keyed by `{host, port, transport}`, and replays it on
the next connection to resume the handshake. For a **bodyless** request this can
also send the request as QUIC 0-RTT (in the first flight), saving a round trip.

This is enabled by default and controlled by the `zero_rtt` request option:

```erlang
%% Default: resumption/0-RTT used automatically when a ticket is cached.
hackney:get(Url, [], <<>>, [{protocols, [http3]}]).

%% Disable it for a request:
hackney:get(Url, [], <<>>, [{protocols, [http3]}, {zero_rtt, false}]).

%% Supply a ticket explicitly (overrides the cache):
hackney:get(Url, [], <<>>,
            [{protocols, [http3]}, {connect_options, [{session_ticket, Ticket}]}]).
```

Scope:

  - **Request-in-0-RTT** (request bytes in the first flight) applies only to
    **bodyless** requests via the one-shot `hackney_h3` API. quic carries only
    the HEADERS as early data, so a request with a body resumes at 1-RTT.
  - The **pooled/multiplexed path** uses the ticket for a resumed (abbreviated)
    handshake; requests are sent at 1-RTT since they arrive after connect.
  - On 0-RTT rejection, the one-shot path retries once at 1-RTT and the cached
    ticket is dropped.

For callers managing tickets directly, `hackney_h3` exposes
`wait_session_ticket/2`, `get_session_ticket/1` and `early_data_accepted/1`.

## Low-Level Stream API

The high-level `hackney:get/post/...` functions cover the common case. For
servers that send streamed responses, or when you want to drive several
requests concurrently on the same QUIC connection, use the `hackney_h3`
adapter directly.

### Connect

```erlang
{ok, ConnRef} = hackney_h3:connect(<<"cloudflare.com">>, 443, #{}, self()).

receive
    {h3, ConnRef, {connected, _Info}} -> ok
after 5000 ->
    error(connect_timeout)
end.
```

`hackney_h3:connect/4` registers the calling process as the owner of the
connection. All events for the connection arrive as messages of the form
`{h3, ConnRef, Event}`.

### Send a request

`send_request/3` opens a request stream and sends the HEADERS frame in one
shot. Pass `Fin = true` when the request has no body, `false` if you will
follow up with `send_data/4`:

```erlang
Headers = [
    {<<":method">>, <<"GET">>},
    {<<":scheme">>, <<"https">>},
    {<<":authority">>, <<"cloudflare.com">>},
    {<<":path">>, <<"/cdn-cgi/trace">>}
],
{ok, StreamId} = hackney_h3:send_request(ConnRef, Headers, true).
```

For requests with a body:

```erlang
{ok, StreamId} = hackney_h3:send_request(ConnRef, Headers, false),
ok = hackney_h3:send_data(ConnRef, StreamId, <<"chunk-1">>, false),
ok = hackney_h3:send_data(ConnRef, StreamId, <<"chunk-2">>, true).  %% Fin
```

### Receive the response

The owner process receives a response as a sequence of events tagged with
the `StreamId`:

```erlang
recv(ConnRef, StreamId, Status, Headers, Body) ->
    receive
        {h3, ConnRef, {stream_headers, StreamId, RespHeaders, _Fin}} ->
            {<<":status">>, S} = lists:keyfind(<<":status">>, 1, RespHeaders),
            recv(ConnRef, StreamId, binary_to_integer(S),
                 [H || {K, _} = H <- RespHeaders, K =/= <<":status">>],
                 Body);
        {h3, ConnRef, {stream_data, StreamId, Chunk, true}} ->
            {ok, Status, Headers, <<Body/binary, Chunk/binary>>};
        {h3, ConnRef, {stream_data, StreamId, Chunk, false}} ->
            recv(ConnRef, StreamId, Status, Headers, <<Body/binary, Chunk/binary>>);
        {h3, ConnRef, {stream_reset, StreamId, ErrorCode}} ->
            {error, {stream_reset, ErrorCode}};
        {h3, ConnRef, {closed, Reason}} ->
            {error, {closed, Reason}}
    after 30000 ->
        {error, timeout}
    end.
```

The `Fin = true` flag on a `stream_data` event marks end-of-stream. For
header-only responses (HEAD, 204, 304) the adapter still emits a final
`{stream_data, StreamId, <<>>, true}` so this loop terminates the same way.

### Concurrent streams on one connection

Since each request gets its own `StreamId`, you can have several in flight
on the same QUIC connection and demultiplex on the StreamId in your receive:

```erlang
{ok, S1} = hackney_h3:send_request(ConnRef, headers(<<"/">>), true),
{ok, S2} = hackney_h3:send_request(ConnRef, headers(<<"/cdn-cgi/trace">>), true),
{ok, S3} = hackney_h3:send_request(ConnRef, headers(<<"/robots.txt">>), true),

%% Collect responses as they complete; order is not guaranteed.
collect(ConnRef, sets:from_list([S1, S2, S3]), #{}).

collect(_ConnRef, Pending, Acc) when map_size(Acc) =:= sets:size(Pending) ->
    Acc;
collect(ConnRef, Pending, Acc) ->
    receive
        {h3, ConnRef, {stream_headers, SId, Hs, _}} ->
            collect(ConnRef, Pending, Acc#{SId => {Hs, <<>>}});
        {h3, ConnRef, {stream_data, SId, Chunk, true}} ->
            #{SId := {Hs, Body}} = Acc,
            collect(ConnRef, Pending, Acc#{SId => {Hs, <<Body/binary, Chunk/binary>>}});
        {h3, ConnRef, {stream_data, SId, Chunk, false}} ->
            #{SId := {Hs, Body}} = Acc,
            collect(ConnRef, Pending, Acc#{SId => {Hs, <<Body/binary, Chunk/binary>>}})
    end.
```

### Cancel a stream

Use `reset_stream/3` to abort a single in-flight request without tearing
down the connection:

```erlang
ok = hackney_h3:reset_stream(ConnRef, StreamId, 16#0102).  %% H3_REQUEST_CANCELLED
```

### Close

```erlang
hackney_h3:close(ConnRef, normal).
```

### Event reference

| Event                                              | Meaning                                                 |
|----------------------------------------------------|---------------------------------------------------------|
| `{connected, Info}`                                | QUIC + H3 handshake complete                            |
| `{stream_headers, StreamId, Headers, Fin}`         | Response headers (or trailers when `Fin = true`)        |
| `{stream_data, StreamId, Bin, Fin}`                | Response body chunk; `Fin = true` ends the stream       |
| `{stream_reset, StreamId, ErrorCode}`              | Peer reset the stream                                   |
| `{goaway, LastStreamId}`                           | Peer is shutting down; finish in-flight streams         |
| `{closed, Reason}`                                 | Connection closed                                       |
| `{transport_error, Code, Reason}`                  | QUIC transport error                                    |

## UDP Blocking and Fallback

Some networks block UDP traffic, which prevents HTTP/3 from working. Hackney handles this with negative caching:

```erlang
%% If HTTP/3 fails, host is marked as blocked for 5 minutes
%% Subsequent requests skip HTTP/3 and use HTTP/2 or HTTP/1.1

%% Check if host is marked as H3-blocked
hackney_altsvc:is_h3_blocked(<<"example.com">>, 443).  %% true | false

%% Manually mark as blocked (e.g., for testing)
hackney_altsvc:mark_h3_blocked(<<"example.com">>, 443).
```

## HTTP/3 vs HTTP/2 Differences

| Feature | HTTP/3 | HTTP/2 |
|---------|--------|--------|
| Transport | QUIC (UDP) | TCP |
| TLS | Built-in (TLS 1.3) | Separate layer |
| Head-of-line blocking | Per-stream only | Connection-wide |
| Connection migration | Supported | Not supported |
| 0-RTT resumption | Supported | Not supported |

### Header Format

Both HTTP/2 and HTTP/3 use lowercase header names:

```erlang
%% HTTP/3 headers (same as HTTP/2)
[{<<":status">>, <<"200">>},
 {<<"content-type">>, <<"text/html">>},
 {<<"server">>, <<"cloudflare">>}]
```

## Error Handling

```erlang
case hackney:get(URL, [], <<>>, [{protocols, [http3]}]) of
    {ok, Status, Headers, Body} ->
        ok;
    {error, {quic_error, Code, Reason}} ->
        %% QUIC-level error
        io:format("QUIC error ~p: ~s~n", [Code, Reason]);
    {error, timeout} ->
        %% Connection timeout (possibly UDP blocked)
        io:format("Timeout - UDP may be blocked~n");
    {error, Reason} ->
        io:format("Error: ~p~n", [Reason])
end.
```

## Performance Tips

### Use HTTP/3 for Unreliable Networks

HTTP/3's per-stream flow control and connection migration work well on mobile or lossy networks:

```erlang
%% Good for mobile apps
Opts = [{protocols, [http3, http2, http1]}, {connect_timeout, 10000}].
```

### Connection Reuse

HTTP/3 connections are expensive to establish. Use pooling:

```erlang
%% Good: connections are reused via pool
[hackney:get(URL, [], <<>>, [{pool, default}, {protocols, [http3]}])
 || _ <- lists:seq(1, 100)].

%% Bad: new QUIC handshake each time
[hackney:get(URL, [], <<>>, [{pool, false}, {protocols, [http3]}])
 || _ <- lists:seq(1, 100)].
```

## Compatibility

### Server Requirements

HTTP/3 requires servers that support:
- QUIC (RFC 9000)
- HTTP/3 (RFC 9114)

Major CDNs with HTTP/3 support:
- Cloudflare
- Google
- Fastly
- Akamai

### Checking Server Support

```bash
# Using curl
curl -v --http3 https://cloudflare.com/ 2>&1 | grep -i http/3

# Check Alt-Svc header
curl -v https://cloudflare.com/ 2>&1 | grep -i alt-svc
```

### Fallback

If HTTP/3 is unavailable, hackney falls back to HTTP/2 or HTTP/1.1:

```erlang
%% Works regardless of H3 support (if http2/http1 in protocols)
{ok, _, _, _} = hackney:get(URL, [], <<>>,
                            [{protocols, [http3, http2, http1]}]).
```

## Examples

### Elixir

```elixir
# Start hackney
Application.ensure_all_started(:hackney)

# HTTP/3 request
{:ok, status, headers, body} = :hackney.get(
  "https://cloudflare.com/cdn-cgi/trace",
  [],
  "",
  [{:protocols, [:http3]}, :with_body]
)

# Verify HTTP/3
String.contains?(body, "http=http/3")  # true
```

### Force Protocol

```erlang
%% HTTP/3 only - fails if server doesn't support it or UDP blocked
{ok, _, _, _} = hackney:get(URL, [], <<>>, [
    with_body,
    {protocols, [http3]}
]).

%% HTTP/2 only - never uses HTTP/3
{ok, _, _, _} = hackney:get(URL, [], <<>>, [
    with_body,
    {protocols, [http2]}
]).
```

## Troubleshooting

### HTTP/3 Not Being Used

1. Check if `http3` is in protocols list

2. Check if host is marked as blocked:
   ```erlang
   hackney_altsvc:is_h3_blocked(Host, Port).
   ```

3. Verify server supports HTTP/3:
   ```bash
   curl -v --http3 https://example.com/
   ```

### Connection Timeouts

UDP may be blocked by firewalls. Try:

1. Use fallback protocols: `{protocols, [http3, http2, http1]}`
2. Check if other HTTP/3 sites work (e.g., cloudflare.com)
3. Check firewall/network settings for UDP port 443

## Next Steps

- [HTTP/2 Guide](http2_guide.md) - HTTP/2 features
- [HTTP Guide](http_guide.md) - General HTTP features
- [Design Guide](design.md) - Architecture details
