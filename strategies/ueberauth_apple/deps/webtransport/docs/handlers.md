# Writing Handlers

Handlers implement the `webtransport_handler` behaviour. The session process
calls your handler's callbacks when events occur (stream data, datagrams,
stream close, etc.).

## Minimal Handler

```erlang
-module(my_handler).
-behaviour(webtransport_handler).

-export([init/3, handle_stream/4, handle_datagram/2,
         handle_stream_closed/3, terminate/2]).

init(_Session, _Req, _Opts) ->
    {ok, #{}}.

handle_stream(Stream, Type, Data, State) ->
    Actions = case Type of
        bidi -> [{send, Stream, <<"echo: ", Data/binary>>}];
        uni  -> []
    end,
    {ok, State, Actions}.

handle_datagram(Data, State) ->
    {ok, State, [{send_datagram, <<"echo: ", Data/binary>>}]}.

handle_stream_closed(_Stream, _Reason, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
```

## Callbacks

All callbacks receive the handler state and return `{ok, NewState}`,
`{ok, NewState, Actions}`, or `{stop, Reason, NewState}`.

### `init/3` (required)

Called when a session is established.

```erlang
init(Session, Request, Opts) ->
    {ok, State} | {ok, State, Actions} | {error, Reason}
```

- `Session` -- the session pid, used for `webtransport:open_stream/2`, etc.
- `Request` -- `#{path := binary(), authority := binary(), headers => [{binary(), binary()}]}`
- `Opts` -- the `handler_opts` map from the listener or connect call

`init/2` is a back-compat shim. It is called only when `init/3` is not
exported and loses the `Opts` argument.

### `handle_stream/4` (required)

Called when data arrives on a stream.

```erlang
handle_stream(Stream, Type, Data, State) ->
    {ok, State} | {ok, State, Actions} | {stop, Reason, State}
```

- `Stream` -- stream ID (non-negative integer)
- `Type` -- `bidi` or `uni`
- `Data` -- binary payload

### `handle_stream_fin/4` (optional)

Called when data arrives with the FIN flag (last data on the stream). If not
exported, `handle_stream/4` is called instead.

```erlang
handle_stream_fin(Stream, Type, Data, State) ->
    {ok, State} | {ok, State, Actions} | {stop, Reason, State}
```

### `handle_datagram/2` (required)

Called when an unreliable datagram arrives.

```erlang
handle_datagram(Data, State) ->
    {ok, State} | {ok, State, Actions} | {stop, Reason, State}
```

### `handle_stream_closed/3` (required)

Called when a stream closes or is reset by the peer.

```erlang
handle_stream_closed(Stream, Reason, State) ->
    {ok, State} | {stop, Reason, State}
```

`Reason` is one of:
- `normal` -- clean close
- `{reset, ErrorCode}` -- peer aborted the stream
- `{stop_sending, ErrorCode}` -- peer requested we stop sending
- `{error, Term}` -- transport-level error

### `handle_info/2` (optional)

Called for any Erlang message not handled by the session state machine. Use
this to receive messages from other processes (timers, database replies, etc.)
and return actions.

```erlang
handle_info(Info, State) ->
    {ok, State} | {ok, State, Actions} | {stop, Reason, State}
```

### `handle_action_failed/3` (optional)

Called when an action returned by a callback fails to dispatch (e.g. sending
to an unknown stream). Default behaviour: log via `logger:warning` and
continue.

```erlang
handle_action_failed(Action, Reason, State) ->
    {ok, State} | {stop, Reason, State}
```

### `origin_check/2` (optional)

Called before `init/3` on server-side CONNECT requests. Return `accept` or
`{reject, Status, Reason}` to refuse a session before it starts.

```erlang
origin_check(Headers, Opts) ->
    accept | {reject, 400..599, binary()}
```

When not exported, the default behaviour is:

- **Requests with an `origin` header** (browser clients): rejected with 403.
  The [spec](https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http3-15#section-3.2)
  requires server-side origin verification.
- **Requests without an `origin` header** (non-browser clients): accepted.

Implement this callback to allow browser origins:

```erlang
origin_check(Headers, _Opts) ->
    case proplists:get_value(<<"origin">>, Headers) of
        <<"https://myapp.example.com">> -> accept;
        _ -> {reject, 403, <<"origin not allowed">>}
    end.
```

### `terminate/2` (required)

Called when the session ends.

```erlang
terminate(Reason, State) -> term()
```

`Reason` is one of:
- `normal` -- clean shutdown
- `{closed, ErrorCode, Message}` -- peer sent `CLOSE_SESSION`
- `{error, Term}` -- error
- `Term` -- other

## Actions

Callbacks can return a list of actions as the third element of the return tuple:

```erlang
handle_stream(Stream, bidi, Data, State) ->
    {ok, State, [
        {send, Stream, <<"echo: ", Data/binary>>},
        {send_datagram, <<"got data">>}
    ]}.
```

| Action | Description |
|--------|-------------|
| `{send, Stream, Data}` | Send data on a stream |
| `{send, Stream, Data, fin}` | Send data and half-close the stream |
| `{send_datagram, Data}` | Send an unreliable datagram |
| `{open_stream, bidi \| uni}` | Open a new stream |
| `{close_stream, Stream}` | Half-close a stream (send FIN) |
| `{reset_stream, Stream, ErrorCode}` | Abort a stream with an error code |
| `{stop_sending, Stream, ErrorCode}` | Ask the peer to stop sending |
| `drain_session` | Signal that no new streams will be opened |
| `{close_session, ErrorCode, Reason}` | Close the session |

## Passing Data to Handlers

Use `handler_opts` to pass configuration, owner pids, or context into your
handler's `init/3`:

```erlang
%% Server side
webtransport:start_listener(my_server, #{
    transport => h3,
    port => 4433,
    certfile => "cert.pem",
    keyfile => "key.pem",
    handler => my_handler,
    handler_opts => #{db_pool => my_pool, max_rooms => 50}
}).
```

```erlang
%% In the handler
init(Session, _Req, #{db_pool := Pool, max_rooms := Max}) ->
    {ok, #{session => Session, pool => Pool, max_rooms => Max}}.
```

## Server-Initiated Streams

To open a stream from the server, spawn a helper process. Do not call
`webtransport:open_stream/2` from inside a callback -- the session process
would deadlock (it is a `gen_statem` and `open_stream` is a `call`).

```erlang
handle_info({push_data, Payload}, #{session := Session} = State) ->
    spawn(fun() ->
        {ok, Stream} = webtransport:open_stream(Session, bidi),
        webtransport:send(Session, Stream, Payload, fin)
    end),
    {ok, State}.
```

Or use the `{open_stream, bidi}` action and handle the new stream's ID in a
subsequent callback. Note: the action variant discards the stream ID, so use
the spawn approach when you need to send on the new stream immediately.
