# WebSocket Guide

hackney provides a WebSocket client with process-per-connection architecture.

## Quick Start

```erlang
{ok, Conn} = hackney:ws_connect(<<"wss://echo.websocket.org">>),
ok = hackney:ws_send(Conn, {text, <<"Hello!">>}),
{ok, {text, <<"Hello!">>}} = hackney:ws_recv(Conn),
hackney:ws_close(Conn).
```

## Connecting

### Simple Connection

```erlang
{ok, Conn} = hackney:ws_connect(<<"wss://example.com/socket">>).
```

### Connection with Options

```erlang
{ok, Conn} = hackney:ws_connect(<<"wss://example.com/socket">>, [
    {connect_timeout, 5000},
    {recv_timeout, 30000},
    {headers, [{<<"authorization">>, <<"Bearer token">>}]},
    {protocols, [<<"graphql-ws">>]}
]).
```

### Available Options

| Option | Default | Description |
|--------|---------|-------------|
| `connect_timeout` | 8000 | TCP connection timeout (ms) |
| `recv_timeout` | infinity | Receive timeout (ms) |
| `headers` | `[]` | Extra headers for upgrade |
| `protocols` | `[]` | Sec-WebSocket-Protocol values |
| `active` | `false` | Active mode: false, true, once |
| `ssl_options` | `[]` | SSL options for wss:// |

## Sending Messages

### Text Messages

```erlang
ok = hackney:ws_send(Conn, {text, <<"Hello">>}).
```

### Binary Messages

```erlang
ok = hackney:ws_send(Conn, {binary, <<1, 2, 3>>}).
```

### Ping/Pong

```erlang
ok = hackney:ws_send(Conn, ping).
ok = hackney:ws_send(Conn, {ping, <<"heartbeat">>}).
```

## Receiving Messages

### Passive Mode (Default)

```erlang
{ok, Frame} = hackney:ws_recv(Conn).
{ok, Frame} = hackney:ws_recv(Conn, 5000).  %% With timeout
```

### Frame Types

```erlang
case hackney:ws_recv(Conn) of
    {ok, {text, Text}} -> handle_text(Text);
    {ok, {binary, Data}} -> handle_binary(Data);
    {ok, ping} -> ok;  %% Auto-responded
    {ok, pong} -> ok;
    {error, {closed, Code, Reason}} -> handle_close(Code)
end.
```

## Active Mode

### Enable Active Mode

```erlang
{ok, Conn} = hackney:ws_connect(URL, [{active, true}]).
%% Or later:
hackney:ws_setopts(Conn, [{active, true}]).
```

### Receive Messages

```erlang
receive
    {hackney_ws, Conn, {text, Text}} -> handle(Text);
    {hackney_ws, Conn, closed} -> done;
    {hackney_ws_error, Conn, Reason} -> error
end.
```

### Active Once

```erlang
{ok, Conn} = hackney:ws_connect(URL, [{active, once}]),
receive {hackney_ws, Conn, Frame} -> ok end,
hackney:ws_setopts(Conn, [{active, once}]).  %% Get next
```

## Closing Connections

```erlang
hackney:ws_close(Conn).
hackney:ws_close(Conn, {1000, <<"Goodbye">>}).
```

### Close Codes

| Code | Meaning |
|------|---------|
| 1000 | Normal closure |
| 1001 | Going away |
| 1002 | Protocol error |

## Example: Chat Client

```erlang
-module(chat).
-export([start/1, send/2]).

start(URL) ->
    {ok, Conn} = hackney:ws_connect(URL, [{active, true}]),
    spawn(fun() -> loop(Conn) end),
    Conn.

send(Conn, Msg) ->
    hackney:ws_send(Conn, {text, Msg}).

loop(Conn) ->
    receive
        {hackney_ws, Conn, {text, Text}} ->
            io:format("~s~n", [Text]),
            loop(Conn);
        {hackney_ws, Conn, closed} ->
            ok
    end.
```

## Error Handling

```erlang
case hackney:ws_connect(URL) of
    {ok, Conn} -> use(Conn);
    {error, {http_error, 401}} -> unauthorized;
    {error, timeout} -> timeout;
    {error, Reason} -> {error, Reason}
end.
```

## Next Steps

- [HTTP Guide](http_guide.md)
- [Getting Started](../GETTING_STARTED.md)
