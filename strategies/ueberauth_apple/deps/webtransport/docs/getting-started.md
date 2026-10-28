# Getting Started

## Requirements

- Erlang/OTP 26.0 or later
- [rebar3](https://rebar3.org/)
- OpenSSL (for certificate generation)

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {webtransport, {git, "https://github.com/benoitc/erlang-webtransport.git",
                    {branch, "main"}}}
]}.
```

Fetch and compile:

```sh
rebar3 get-deps
rebar3 compile
```

## TLS Certificates

WebTransport requires TLS. For local development, generate a self-signed certificate:

```sh
openssl req -x509 -newkey rsa:2048 \
  -keyout key.pem -out cert.pem \
  -days 365 -nodes -subj '/CN=localhost'
```

This produces two files:

- `cert.pem` -- the X.509 certificate
- `key.pem` -- the unencrypted private key

For production, use certificates from a trusted CA (e.g. [Let's Encrypt](https://letsencrypt.org/)). The `certfile` and `keyfile` options accept absolute or relative file paths.

## Quick Start

Start a shell with all dependencies loaded:

```sh
rebar3 shell
```

### Start the server

```erlang
{ok, _} = webtransport:start_listener(my_server, #{
    transport => h3,
    port => 4433,
    certfile => "cert.pem",
    keyfile => "key.pem",
    handler => echo_server
}).
```

### Connect a client

```erlang
{ok, Session} = webtransport:connect("localhost", 4433, <<"/echo">>, #{
    transport => h3,
    verify => verify_none
}).
```

### Send and receive

```erlang
%% Open a bidirectional stream
{ok, Stream} = webtransport:open_stream(Session, bidi).

%% Send data
ok = webtransport:send(Session, Stream, <<"hello">>).

%% Receive the echo (default client handler forwards to calling process)
receive
    {webtransport, Session, {stream, Stream, bidi, Data}} ->
        io:format("Got: ~s~n", [Data])  %% prints "Got: echo: hello"
after 3000 ->
    io:format("timeout~n")
end.

%% Send an unreliable datagram
ok = webtransport:send_datagram(Session, <<"ping">>).

receive
    {webtransport, Session, {datagram, DgData}} ->
        io:format("Got: ~s~n", [DgData])  %% prints "Got: echo: ping"
after 3000 ->
    io:format("timeout~n")
end.

%% Clean up
webtransport:close_session(Session).
webtransport:stop_listener(my_server).
```

## Default Client Handler

When connecting without a custom handler, `webtransport_client_handler` is used. It forwards all events to the calling process as Erlang messages:

| Message | Description |
|---------|-------------|
| `{webtransport, Session, {stream, Stream, Type, Data}}` | Stream data received |
| `{webtransport, Session, {stream_fin, Stream, Type, Data}}` | Stream data with FIN |
| `{webtransport, Session, {datagram, Data}}` | Datagram received |
| `{webtransport, Session, {stream_closed, Stream, Reason}}` | Stream closed |
| `{webtransport, Session, closed}` | Session terminated |

## Next Steps

- [Writing Handlers](handlers.html) -- implement the `webtransport_handler` behaviour
- [Configuration](configuration.html) -- flow control, compat mode, limits
