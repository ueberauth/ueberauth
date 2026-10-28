# WebTransport Guide

hackney provides a WebTransport client that mirrors the WebSocket API, so
existing code can move from WebSocket to WebTransport by swapping the `ws_`
prefix for `wt_`. It runs over HTTP/3 (QUIC) by default, with HTTP/2 as an
option, and uses the same process-per-connection model.

WebTransport is the analog of an HTTP/2 connection: one connection carries
many multiplexed streams plus unreliable datagrams.

## Quick Start

```erlang
{ok, Conn} = hackney:wt_connect(<<"https://example.com/wt">>),
ok = hackney:wt_send(Conn, {binary, <<"Hello!">>}),
{ok, {binary, <<"Hello!">>}} = hackney:wt_recv(Conn),
hackney:wt_close(Conn).
```

Compare with WebSocket; the shape is identical:

```erlang
{ok, Conn} = hackney:ws_connect(<<"wss://example.com/socket">>),
ok = hackney:ws_send(Conn, {binary, <<"Hello!">>}),
{ok, {binary, <<"Hello!">>}} = hackney:ws_recv(Conn),
hackney:ws_close(Conn).
```

## Connecting

WebTransport always runs over TLS. Use the `https://` scheme; `wss://` is
accepted as an alias so a URL can carry over unchanged.

```erlang
{ok, Conn} = hackney:wt_connect(<<"https://example.com/wt">>).
```

### Connection with Options

```erlang
{ok, Conn} = hackney:wt_connect(<<"https://example.com/wt">>, [
    {transport, h3},
    {connect_timeout, 5000},
    {recv_timeout, 30000},
    {headers, [{<<"authorization">>, <<"Bearer token">>}]}
]).
```

### Available Options

| Option | Default | Description |
|--------|---------|-------------|
| `transport` | `h3` | `h3` (QUIC) or `h2` |
| `connect_timeout` | 8000 | Session handshake timeout (ms) |
| `recv_timeout` | infinity | Default receive timeout (ms) |
| `active` | `false` | Active mode: false, true, once |
| `headers` | `[]` | Extra headers for the CONNECT request |
| `ssl_options` | `[]` | TLS options: `verify`, `cacerts`/`cacertfile`, `cert`/`certfile`, `key`/`keyfile` |
| `verify` | `verify_peer` | `verify_peer` or `verify_none` |
| `compat_mode` | `latest` | `latest` or `legacy_browser_compat` |
| `max_recv_buffer` | 67108864 | Cap (bytes) on buffered, unread data |

When verifying with no CA configured, hackney uses the bundled `certifi`
trust store, the same as for HTTPS requests.

## The Default Message Channel

`wt_send`/`wt_recv` operate on a single persistent bidirectional stream
opened at connect time. This is the drop-in replacement for the WebSocket
message channel.

```erlang
ok = hackney:wt_send(Conn, {binary, <<1, 2, 3>>}).
ok = hackney:wt_send(Conn, {text, <<"text is sent as bytes">>}).
{ok, {binary, Data}} = hackney:wt_recv(Conn).
{ok, {binary, Data}} = hackney:wt_recv(Conn, 5000).  %% With timeout
```

WebTransport has no message framing of its own. To stay interoperable with
any server, hackney does not add a wire format: bytes are written to the
stream as-is, and a received chunk is returned as `{binary, Data}`. Chunks
are reliable and ordered, but are **not** guaranteed to line up with your
send boundaries. If you need message boundaries, delimit them yourself, or
use one stream per message (see below).

## Datagrams

Datagrams are unreliable, unordered, and size-limited, like UDP.

```erlang
ok = hackney:wt_send_datagram(Conn, <<"ping">>).
%% Inbound datagrams arrive on the default channel:
{ok, {datagram, Data}} = hackney:wt_recv(Conn).
```

## Multiplexed Streams

Open as many streams as you want over one session, just like HTTP/2
multiplexes requests over one connection. Each stream has its own send and
receive channel keyed by id.

```erlang
{ok, StreamId} = hackney:wt_open_stream(Conn, bidi),   %% or uni
ok = hackney:wt_stream_send(Conn, StreamId, <<"request">>),
ok = hackney:wt_stream_send(Conn, StreamId, <<"!">>, fin),  %% close write side
{ok, Data} = hackney:wt_stream_recv(Conn, StreamId),
{ok, {fin, Last}} = hackney:wt_stream_recv(Conn, StreamId).  %% peer ended stream
```

Stream lifecycle:

```erlang
hackney:wt_close_stream(Conn, StreamId).             %% graceful FIN
hackney:wt_reset_stream(Conn, StreamId, ErrorCode).  %% abort
hackney:wt_stop_sending(Conn, StreamId, ErrorCode).  %% ask peer to stop
```

Data on streams the server opens (rather than ones you opened) is surfaced
on the default channel as `{stream, Id, Data}` / `{stream_fin, Id, Data}`.

## Active Mode

In active mode every event is forwarded to the owner process, uniformly
tagged with its stream id.

```erlang
{ok, Conn} = hackney:wt_connect(URL, [{active, true}]),
receive
    {hackney_wt, Conn, {binary, Data}}         -> handle(Data);
    {hackney_wt, Conn, {datagram, Data}}       -> handle_dgram(Data);
    {hackney_wt, Conn, {stream, Id, Data}}     -> handle_stream(Id, Data);
    {hackney_wt, Conn, {stream_fin, Id, Data}} -> handle_fin(Id, Data);
    {hackney_wt, Conn, closed}                 -> done;
    {hackney_wt_error, Conn, Reason}           -> error
end.
```

`active, once` delivers a single message and reverts to passive:

```erlang
{ok, Conn} = hackney:wt_connect(URL, [{active, once}]),
receive {hackney_wt, Conn, Msg} -> ok end,
hackney:wt_setopts(Conn, [{active, once}]).  %% arm for the next one
```

## Closing Connections

```erlang
hackney:wt_close(Conn).
hackney:wt_close(Conn, {0, <<"bye">>}).  %% {ErrorCode, Reason}
```

## Server Side

hackney is the WebTransport **client**. The peer is any WebTransport
server. To run one in Erlang, use the `webtransport` library (a hackney
dependency, from the [erlang-webtransport](https://github.com/benoitc/erlang-webtransport)
project): start a listener and implement the `webtransport_handler`
behaviour. The handler callbacks are where you receive what the hackney
client sends, and the actions you return are what the client receives back.

### Handler

```erlang
-module(my_wt_handler).
-behaviour(webtransport_handler).

-export([init/3, handle_stream/4, handle_stream_fin/4,
         handle_datagram/2, handle_stream_closed/3, terminate/2]).

init(_Session, _Req, _Opts) ->
    {ok, #{}}.

%% A chunk arrived on a stream (no FIN yet). Reply by returning a `send'
%% action on the SAME stream id; that is what the client reads back.
handle_stream(StreamId, bidi, Data, State) ->
    {ok, State, [{send, StreamId, Data}]};      %% echo
handle_stream(_StreamId, uni, _Data, State) ->
    {ok, State}.

%% The peer closed its write side (FIN). For a bidi stream you can answer
%% with a final chunk and FIN to close yours.
handle_stream_fin(StreamId, bidi, Data, State) ->
    {ok, State, [{send, StreamId, Data, fin}]};
handle_stream_fin(_StreamId, uni, _Data, State) ->
    {ok, State}.

handle_datagram(Data, State) ->
    {ok, State, [{send_datagram, Data}]}.        %% echo a datagram

handle_stream_closed(_StreamId, _Reason, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
```

Available actions a callback may return in its `{ok, State, Actions}`
result: `{send, StreamId, Data}`, `{send, StreamId, Data, fin}`,
`{send_datagram, Data}`, `{open_stream, bidi | uni}`,
`{close_stream, StreamId}`, `{reset_stream, StreamId, Code}`,
`{stop_sending, StreamId, Code}`, `drain_session`,
`{close_session, Code, Reason}`.

### Listener

```erlang
{ok, _} = application:ensure_all_started(webtransport),
{ok, _Pid} = webtransport:start_listener(my_listener, #{
    transport => h3,            %% or h2
    port      => 4433,
    certfile  => "cert.pem",
    keyfile   => "key.pem",
    handler   => my_wt_handler
}).
%% ... later
ok = webtransport:stop_listener(my_listener).
```

### How client calls map to server callbacks

| hackney client | server callback | reply to client |
|----------------|-----------------|-----------------|
| `wt_send(C, {binary, D})` (default stream) | `handle_stream(Id, bidi, D, S)` | `{send, Id, D2}` → client `wt_recv` returns `{binary, D2}` |
| `wt_send_datagram(C, D)` | `handle_datagram(D, S)` | `{send_datagram, D2}` → client `wt_recv` returns `{datagram, D2}` |
| `wt_open_stream(C, bidi)` + `wt_stream_send(C, Id, D)` | `handle_stream(Id, bidi, D, S)` | `{send, Id, D2}` → client `wt_stream_recv(C, Id)` returns `{ok, D2}` |
| `wt_stream_send(C, Id, D, fin)` | `handle_stream_fin(Id, bidi, D, S)` | `{send, Id, D2, fin}` → client gets `{ok, {fin, D2}}` |

Reply on the **same stream id** you were called with to answer on that
stream. To push data the client did not ask for, return `{open_stream, ...}`
and send on the new id; the client surfaces it on the default channel as
`{stream, Id, Data}` (or `{hackney_wt, C, {stream, Id, Data}}` in active
mode).

Browsers and other WebTransport clients work against the same listener;
nothing about the server is hackney-specific.

## Differences from WebSocket

| WebSocket | WebTransport |
|-----------|--------------|
| Single ordered message channel | Many multiplexed streams + datagrams |
| Reliable, framed messages | Reliable streams (no framing) + unreliable datagrams |
| `ping`/`pong` frames | Not used (QUIC keepalive); `wt_send` returns `{error, {unsupported_frame, ping}}` |
| `ws://` / `wss://` | `https://` (TLS only) |
| HTTP/1.1 Upgrade, proxies | HTTP/3 (QUIC) or HTTP/2, no proxy |

`wt_recv`/`wt_stream_recv` return `{error, {active_mode, Mode}}` in active
mode, `{error, timeout}` on timeout, and `{error, closed}` once the session
ends and buffered data is drained.

## Example: Echo Client

```erlang
-module(wt_echo).
-export([run/1]).

run(URL) ->
    {ok, Conn} = hackney:wt_connect(URL),
    ok = hackney:wt_send(Conn, {binary, <<"hello">>}),
    {ok, {binary, Reply}} = hackney:wt_recv(Conn, 5000),
    io:format("echo: ~s~n", [Reply]),
    hackney:wt_close(Conn).
```

## Next Steps

- [WebSocket Guide](websocket_guide.md)
- [HTTP/3 Guide](http3_guide.md)
- [Getting Started](../GETTING_STARTED.md)
