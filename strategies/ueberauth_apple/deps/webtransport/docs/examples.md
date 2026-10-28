# Examples

The `examples/` directory contains a working echo server and client that
exercise streams, datagrams, and session lifecycle.

## Setup

```sh
# 1. Build the project
rebar3 compile

# 2. Generate a self-signed certificate for local testing
openssl req -x509 -newkey rsa:2048 \
  -keyout key.pem -out cert.pem \
  -days 365 -nodes -subj '/CN=localhost'

# 3. Compile the examples
erlc -o examples \
  -pa _build/default/lib/webtransport/ebin \
  -pa _build/default/lib/quic/ebin \
  -pa _build/default/lib/erlang_h2/ebin \
  -I include \
  examples/echo_server.erl examples/echo_client.erl

# 4. Start a shell with everything loaded
ERL_FLAGS="-pa examples" rebar3 shell --apps webtransport
```

## Echo Server

`examples/echo_server.erl` implements a `webtransport_handler` that:

- Echoes bidi stream data back with an `echo: ` prefix
- Echoes datagrams back with an `echo: ` prefix
- Logs session and stream events to the console

### Source

```erlang
-module(echo_server).
-behaviour(webtransport_handler).

-export([start/0, start/1, stop/0]).
-export([init/3, handle_stream/4, handle_stream_fin/4,
         handle_datagram/2, handle_stream_closed/3, terminate/2]).

-record(state, {
    session :: webtransport:session(),
    streams = #{} :: #{webtransport:stream() => #{type := bidi | uni, buffer := binary()}}
}).

start() -> start(4433).

start(Port) ->
    webtransport:start_listener(echo_server, #{
        transport => h3,
        port => Port,
        certfile => "cert.pem",
        keyfile => "key.pem",
        handler => ?MODULE
    }).

stop() ->
    webtransport:stop_listener(echo_server).

init(Session, Req, _Opts) ->
    Path = maps:get(path, Req),
    Authority = maps:get(authority, Req),
    io:format("[~p] Session started: ~s~s~n", [Session, Authority, Path]),
    {ok, #state{session = Session}}.

handle_stream(Stream, Type, Data, #state{session = Session, streams = Streams} = State) ->
    io:format("[~p] Stream ~p (~p) data: ~p~n", [Session, Stream, Type, Data]),
    Actions = case Type of
        bidi -> [{send, Stream, <<"echo: ", Data/binary>>}];
        uni  -> []
    end,
    StreamInfo = maps:get(Stream, Streams, #{type => Type, buffer => <<>>}),
    NewBuffer = <<(maps:get(buffer, StreamInfo))/binary, Data/binary>>,
    {ok, State#state{streams = Streams#{Stream => StreamInfo#{buffer => NewBuffer}}}, Actions}.

handle_stream_fin(Stream, Type, Data, #state{session = Session, streams = Streams} = State) ->
    io:format("[~p] Stream ~p (~p) FIN: ~p~n", [Session, Stream, Type, Data]),
    Actions = case Type of
        bidi when Data =/= <<>> -> [{send, Stream, <<"echo: ", Data/binary>>, fin}];
        bidi -> [{close_stream, Stream}];
        uni  -> []
    end,
    {ok, State#state{streams = maps:remove(Stream, Streams)}, Actions}.

handle_datagram(Data, #state{session = Session} = State) ->
    io:format("[~p] Datagram: ~p~n", [Session, Data]),
    {ok, State, [{send_datagram, <<"echo: ", Data/binary>>}]}.

handle_stream_closed(Stream, Reason, #state{session = Session, streams = Streams} = State) ->
    io:format("[~p] Stream ~p closed: ~p~n", [Session, Stream, Reason]),
    {ok, State#state{streams = maps:remove(Stream, Streams)}}.

terminate(Reason, #state{session = Session}) ->
    io:format("[~p] Session terminated: ~p~n", [Session, Reason]),
    ok.
```

### Running

```erlang
1> echo_server:start(4433).
{ok, <0.150.0>}
```

## Echo Client

`examples/echo_client.erl` connects to the echo server and runs three
tests: bidirectional stream echo, unidirectional stream send, and
datagram echo. It uses the default `webtransport_client_handler` which
forwards events as Erlang messages.

### Running

```erlang
2> echo_client:test("localhost", 4433).
Connecting to localhost:4433...
Connected!

=== Test 1: Bidirectional Stream ===
Opening bidirectional stream...
Sending: Hello, WebTransport!
Received: echo: Hello, WebTransport!
PASSED

=== Test 2: Unidirectional Stream ===
Opening unidirectional stream...
Sending: One-way message
Sent (no response expected for uni stream)
PASSED

=== Test 3: Datagram ===
Sending datagram: ping
Received: echo: ping
PASSED

All tests completed.
ok
```

### Source highlights

```erlang
%% Connect with verify_none for self-signed certs
connect(Host, Port) ->
    webtransport:connect(Host, Port, <<"/echo">>, #{
        transport => h3,
        verify => verify_none
    }).

%% Send and wait for echo
send_echo(Session, Stream, Data) ->
    ok = webtransport:send(Session, Stream, Data),
    receive
        {webtransport, Session, {stream, Stream, _, Response}} ->
            {ok, Response};
        {webtransport, Session, {stream_fin, Stream, _, Response}} ->
            {ok, Response}
    after 5000 ->
        {error, timeout}
    end.

%% Datagram round-trip
send_datagram(Session, Data) ->
    ok = webtransport:send_datagram(Session, Data),
    receive
        {webtransport, Session, {datagram, Response}} ->
            {ok, Response}
    after 5000 ->
        {error, timeout}
    end.
```

## Interactive Shell Usage

You don't need the example modules to try things interactively:

```erlang
%% Start a server with the echo handler
{ok, _} = webtransport:start_listener(demo, #{
    transport => h3,
    port => 4433,
    certfile => "cert.pem",
    keyfile => "key.pem",
    handler => echo_server
}).

%% Connect a client
{ok, Session} = webtransport:connect("localhost", 4433, <<"/echo">>, #{
    transport => h3,
    verify => verify_none
}).

%% Open a stream and send
{ok, Stream} = webtransport:open_stream(Session, bidi).
ok = webtransport:send(Session, Stream, <<"hello">>).

%% Check the mailbox
flush().
%% Shell got {webtransport,<0.170.0>,{stream,0,bidi,<<"echo: hello">>}}

%% Send a datagram
ok = webtransport:send_datagram(Session, <<"ping">>).
flush().
%% Shell got {webtransport,<0.170.0>,{datagram,<<"echo: ping">>}}

%% Inspect session state
{ok, Info} = webtransport:session_info(Session).
io:format("~p~n", [Info]).
%% #{transport => h3, stream_count => 1, bytes_sent => 5, ...}

%% Close
webtransport:close_session(Session).
webtransport:stop_listener(demo).
```

## HTTP/2 Example

The same handler works over HTTP/2 -- just change the transport:

```erlang
%% Server
{ok, _} = webtransport:start_listener(demo_h2, #{
    transport => h2,
    port => 4443,
    certfile => "cert.pem",
    keyfile => "key.pem",
    handler => echo_server
}).

%% Client
{ok, Session} = webtransport:connect("localhost", 4443, <<"/echo">>, #{
    transport => h2,
    verify => verify_none
}).

{ok, Stream} = webtransport:open_stream(Session, bidi).
webtransport:send(Session, Stream, <<"hello over h2">>).
flush().
```
