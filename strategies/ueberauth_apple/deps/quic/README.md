# erlang_quic

Pure Erlang QUIC implementation (RFC 9000/9001).

## Features

### QUIC transport (RFC 9000 / 9001)
- TLS 1.3 handshake (RFC 8446)
- Stream multiplexing (bidirectional and unidirectional)
- Key update support (RFC 9001 Section 6)
- Connection migration with active path migration API (RFC 9000 Section 9)
- 0-RTT early data support with session resumption (RFC 9001 Section 4.6)
- DATAGRAM frame support for unreliable data (RFC 9221)
- QUIC v2 support (RFC 9369)
- Server mode with listener and pooled listeners (SO_REUSEPORT)
- QUIC-LB load balancer support with routable CIDs (RFC 9312)
- Retry packet handling for address validation (RFC 9000 Section 8.1)
- Stateless reset support (RFC 9000 Section 10.3)
- Spin bit (RFC 9000 §17.4) and full NEW_TOKEN issuance/validation
- `RESET_STREAM_AT` extension
- Flow control (connection and stream level) with RTT-based auto-tune
- Congestion control (NewReno, CUBIC, BBR with ECN support)
- HyStart++ slow start (RFC 9406)
- Packet pacing (RFC 9002 Section 7.7)
- Loss detection and packet retransmission (RFC 9002)
- QLOG tracing support for debug visibility
- UDP packet batching (GSO/GRO)
- Client certificate verification
- TLS 1.3 external PSK authentication (RFC 8446 §4.2.11, both `psk_dhe_ke`
  and `psk_ke`). See [docs/PSK.md](docs/PSK.md).
- Path-metrics snapshot (`quic:get_path_stats/1`) for routing layers

### HTTP/3 (`quic_h3`)
- Full HTTP/3 client and server (RFC 9114) with QPACK header compression (RFC 9204)
- HTTP Datagrams (RFC 9297) with capsule framing
- Server Push (RFC 9114 Section 4.6)
- Extensible Priorities (RFC 9218): PRIORITY_UPDATE frames, urgency / incremental
- Extended CONNECT (RFC 9220) for WebTransport-style upgrades
- Extension stream hooks: `stream_type_handler` (peer-claimed uni/bidi)
  and `quic_h3:open_bidi_stream/1,2` (client-initiated, pre-claimed
  with a signal-type varint)
- Per-connection owner override via `connection_handler` callback for
  multi-tenant servers
- Per-stream handler registration to redirect body data to worker pids
- CLI escripts `quic_h3_client` and `quic_h3_server`, built with
  `rebar3 as h3_client escriptize` / `rebar3 as h3_server escriptize` into
  `_build/<profile>/bin/`
- See [docs/HTTP3.md](docs/HTTP3.md) for the full guide

### Distributed Erlang over QUIC (`quic_dist`)
- EPMD-less node discovery (`quic_discovery_static`, `quic_discovery_dns`)
- Session-ticket cache for 0-RTT reconnection
- User-accessible streams API on top of dist connections
- Stream prioritization (control vs data) and connection-level backpressure
- `priv/bin/quic_call.sh`: `erl_call`-style one-shot RPC against a `-proto_dist quic` node
- Optional `auth_callback` for an app-level handshake between TLS and `dist_util`, plus `register_with_epmd` for stock-EPMD discoverability
- See [docs/QUIC_DIST.md](docs/QUIC_DIST.md) for setup

## Requirements

- Erlang/OTP 26.0 or later
- rebar3

## Installation

Add to your `rebar.config` dependencies:

```erlang
{deps, [
    {quic, {git, "https://github.com/benoitc/erlang_quic.git", {branch, "main"}}}
]}.
```

## Quick Start

### Client

```erlang
%% Connect to a QUIC server
{ok, ConnRef} = quic:connect(<<"example.com">>, 443, #{
    alpn => [<<"h3">>],
    verify => false
}, self()),

%% Wait for connection
receive
    {quic, ConnRef, {connected, Info}} ->
        io:format("Connected: ~p~n", [Info])
end,

%% Open a bidirectional stream
{ok, StreamId} = quic:open_stream(ConnRef),

%% Send data on the stream
ok = quic:send_data(ConnRef, StreamId, <<"Hello, QUIC!">>, true),

%% Receive data
receive
    {quic, ConnRef, {stream_data, StreamId, Data, _Fin}} ->
        io:format("Received: ~p~n", [Data])
end,

%% Close connection
quic:close(ConnRef, normal).
```

### Server

```erlang
%% Load certificate and key
{ok, CertDer} = file:read_file("server.crt"),
{ok, KeyDer} = file:read_file("server.key"),

%% Start a named server (recommended)
{ok, _Pid} = quic:start_server(my_server, 4433, #{
    cert => CertDer,
    key => KeyDer,
    alpn => [<<"h3">>]
}),

%% Get the port (useful if 0 was specified for ephemeral port)
{ok, Port} = quic:get_server_port(my_server),
io:format("Listening on port ~p~n", [Port]),

%% Incoming connections are handled automatically
%% The server spawns quic_connection processes for each client

%% Stop the server when done
quic:stop_server(my_server).
```

Alternatively, use the low-level listener API directly:

```erlang
{ok, Listener} = quic_listener:start_link(4433, #{
    cert => CertDer,
    key => KeyDer,
    alpn => [<<"h3">>]
}),
Port = quic_listener:get_port(Listener).
```

### HTTP/3

```erlang
%% Server
{ok, _} = quic_h3:start_server(my_h3, 4433, #{
    cert => CertDer,
    key => KeyDer,
    handler => fun(Conn, StreamId, <<"GET">>, Path, _Headers) ->
        Body = <<"hello from ", Path/binary>>,
        quic_h3:send_response(Conn, StreamId, 200,
                              [{<<"content-type">>, <<"text/plain">>}]),
        quic_h3:send_data(Conn, StreamId, Body, true)
    end
}).

%% Client
{ok, H3} = quic_h3:connect("example.com", 4433, #{verify => false, sync => true}),
{ok, StreamId} = quic_h3:request(H3, [
    {<<":method">>, <<"GET">>},
    {<<":scheme">>, <<"https">>},
    {<<":path">>, <<"/hi">>},
    {<<":authority">>, <<"example.com">>}
]),
receive
    {quic_h3, H3, {response, StreamId, 200, _Headers}} -> ok
end,
receive
    {quic_h3, H3, {data, StreamId, Body, true}} ->
        io:format("got ~p~n", [Body])
end,
quic_h3:close(H3).
```

See [docs/HTTP3.md](docs/HTTP3.md) for datagrams, push, priorities,
extended CONNECT, extension streams, and per-connection owners.

## Messages

The owner process receives messages in the format `{quic, ConnRef, Event}`:

| Event | Description |
|-------|-------------|
| `{connected, Info}` | Connection established |
| `{stream_opened, StreamId}` | New stream opened by peer |
| `{stream_data, StreamId, Data, Fin}` | Data received on stream |
| `{stream_reset, StreamId, ErrorCode}` | Stream reset by peer |
| `{closed, Reason}` | Connection closed |
| `{transport_error, Code, Reason}` | Transport error |
| `{session_ticket, Ticket}` | Session ticket for 0-RTT resumption |
| `{datagram, Data}` | Datagram received (RFC 9221) |
| `{stop_sending, StreamId, ErrorCode}` | Stop sending requested by peer |
| `{send_ready, StreamId}` | Stream ready for writing |

## API Reference

See [docs/features.md](docs/features.md) for the complete API reference and feature list.

### Quick Reference

**Connection:** `quic:connect/4`, `quic:close/2`, `quic:peername/1`, `quic:migrate/1`

**Streams:** `quic:open_stream/1`, `quic:send_data/4`, `quic:reset_stream/3`

**Server:** `quic:start_server/3`, `quic:stop_server/1`, `quic:get_server_port/1`

**Datagrams:** `quic:send_datagram/2` (RFC 9221)

**HTTP/3:** `quic_h3:connect/3`, `quic_h3:request/2,3`, `quic_h3:send_response/4`,
`quic_h3:send_data/3,4`, `quic_h3:start_server/3`, `quic_h3:open_bidi_stream/1,2`,
`quic_h3:send_datagram/3` (RFC 9114 / 9204 / 9297)

**Load Balancer:** `quic_lb:new_config/1`, `quic_lb:generate_cid/1` (RFC 9312)

## Building

```bash
rebar3 compile
```

## Formatting

```bash
rebar3 fmt
```

## Static analysis tools

```bash
rebar3 lint
rebar3 xref
rebar3 dialyzer
```

## Testing

```bash
# Run unit tests
rebar3 eunit

# Run property-based tests
rebar3 proper

# Run all tests
rebar3 eunit && rebar3 proper
```

## Interoperability

This implementation passes all 10 [QUIC Interop Runner](https://github.com/quic-interop/quic-interop-runner) test cases. See [docs/features.md](docs/features.md) for the full test matrix and [interop/README.md](interop/README.md) for details on running interop tests.

## Documentation

Topic guides under `docs/`:

- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md): first-connection walkthrough
- [docs/CLIENT_GUIDE.md](docs/CLIENT_GUIDE.md): client API reference
- [docs/SERVER_GUIDE.md](docs/SERVER_GUIDE.md): server API reference
- [docs/HTTP3.md](docs/HTTP3.md): HTTP/3 and datagrams
- [docs/QUIC_DIST.md](docs/QUIC_DIST.md): Erlang distribution over QUIC
- [docs/PSK.md](docs/PSK.md): TLS 1.3 external PSK
- [docs/INTERNAL_NETWORKS.md](docs/INTERNAL_NETWORKS.md): running without a CA on a trusted subnet
- [docs/QLOG_GUIDE.md](docs/QLOG_GUIDE.md): qlog tracing
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): throughput characteristics, socket-backend rationale, roadmap
- [docs/DESIGN.md](docs/DESIGN.md): architecture, state machine, packet flow
- [docs/MODULE_MAP.md](docs/MODULE_MAP.md): where the code lives and what to read first
- [docs/SEND_PATH.md](docs/SEND_PATH.md): how a write becomes bytes on a socket
- [docs/RECV_PATH.md](docs/RECV_PATH.md): how a datagram becomes an owner message
- [docs/GLOSSARY.md](docs/GLOSSARY.md): abbreviations and local vocabulary
- [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md): application developer recipes
- [docs/features.md](docs/features.md): feature matrix and API reference

Changing the library itself: [CONTRIBUTING.md](CONTRIBUTING.md).

Generate API documentation with:

```bash
rebar3 ex_doc
```

## Sponsors

<a href="https://enki-multimedia.eu"><img src="docs/images/enki-multimedia.svg" alt="Enki Multimedia" height="50" /></a>

## License

Apache License 2.0

## Author

Benoit Chesneau
