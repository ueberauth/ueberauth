# hackney

An HTTP client for Erlang. Simple, reliable, fast.

[![Build Status](https://github.com/benoitc/hackney/workflows/build/badge.svg)](https://github.com/benoitc/hackney/actions?query=workflow%3Abuild)
[![Hex pm](http://img.shields.io/hexpm/v/hackney.svg?style=flat)](https://hex.pm/packages/hackney)

## Why hackney?

- **HTTP/3 support** - Experimental QUIC/HTTP3 via pure Erlang. Opt-in with `{protocols, [http3, http2, http1]}`.
- **HTTP/2 support** - Automatic protocol negotiation via ALPN. Multiplexing, header compression, flow control.
- **Process per connection** - Each connection runs in its own `gen_statem` process. Clean isolation, automatic cleanup on crashes.
- **Connection pooling** - Reuse connections automatically. Configure pools per host or globally.
- **Streaming** - Stream request bodies, response bodies, or both. Handle large files without loading them in memory.
- **Async responses** - Get response chunks as messages. Process other work while waiting.
- **WebSocket support** - Full WebSocket client with the same process-per-connection model.
- **WebTransport support** - WebTransport client over HTTP/3 (or HTTP/2) with a WebSocket-shaped API; switch by swapping the `ws_` prefix for `wt_`.
- **HTTP/2 bidirectional streams** - Full-duplex gRPC-style streaming with the `h2_*` API; send and receive interleaved on one stream, with trailers and flow control.
- **IPv6 first** - Happy Eyeballs algorithm tries IPv6 before IPv4 for faster connections on modern networks.
- **SSL by default** - Secure connections with certificate verification using Mozilla's CA bundle.
- **Automatic decompression** - Transparently decompress gzip/deflate responses with `{auto_decompress, true}`.

## Quick Start

```erlang
%% Start hackney
application:ensure_all_started(hackney).

%% Simple GET - the body is returned directly
{ok, 200, _Headers, Body} = hackney:get(<<"https://httpbin.org/get">>).

%% POST JSON
Headers = [{<<"content-type">>, <<"application/json">>}],
Payload = <<"{\"key\": \"value\"}">>,
{ok, 200, _, _} = hackney:post(<<"https://httpbin.org/post">>, Headers, Payload).
```

## Installation

### Rebar3

```erlang
{deps, [hackney]}.
```

### Mix

```elixir
{:hackney, "~> 4.0"}
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](GETTING_STARTED.md) | Installation, first requests, basic patterns |
| [HTTP Guide](guides/http_guide.md) | Requests, responses, streaming, async, pools |
| [HTTP/2 Guide](guides/http2_guide.md) | HTTP/2 protocol, ALPN, multiplexing, flow control |
| [HTTP/3 Guide](guides/http3_guide.md) | HTTP/3 over QUIC, opt-in configuration, Alt-Svc |
| [WebSocket Guide](guides/websocket_guide.md) | Connect, send, receive, active mode |
| [WebTransport Guide](guides/webtransport_guide.md) | Streams, datagrams, multiplexing, server handlers |
| [Design Guide](guides/design.md) | Architecture, pooling, load regulation internals |
| [Migration Guide](guides/MIGRATION.md) | Upgrading from hackney 1.x |
| [API Reference](https://hexdocs.pm/hackney) | Full module documentation |
| [Changelog](NEWS.md) | Version history |

## Features

### HTTP Methods

All standard HTTP methods as convenient functions:

```erlang
hackney:get(URL).
hackney:post(URL, Headers, Body).
hackney:put(URL, Headers, Body).
hackney:delete(URL).
hackney:head(URL).
hackney:options(URL).
hackney:patch(URL, Headers, Body).
hackney:query(URL, Headers, Body).
```

`QUERY` (RFC 10008) is a safe, idempotent method for read-only operations
that need a request body:

```erlang
hackney:query(
    URL,
    [{<<"content-type">>, <<"application/json">>}],
    Json,
    Options
).
```

### Connection Pooling

Connections are pooled by default. Configure pools for different use cases:

```erlang
%% Use default pool
hackney:get(URL).

%% Named pool with custom settings
hackney_pool:start_pool(api_pool, [{max_connections, 100}]),
hackney:get(URL, [], <<>>, [{pool, api_pool}]).

%% No pooling for one-off requests
hackney:get(URL, [], <<>>, [{pool, false}]).
```

By default only plain TCP connections stay in the pool: an HTTPS request
upgrades a pooled TCP connection and the SSL connection is closed after use.
Set `{ssl_pooling, true}` per request (or the `ssl_pooling` application env)
to also pool HTTPS/1.1 connections. Pooled SSL connections are keyed by their
TLS options, so only requests with identical `ssl_options` reuse them:

```erlang
%% Reuse HTTPS/1.1 connections, skipping the TLS handshake
hackney:get(URL, [], <<>>, [{ssl_pooling, true}]).
```

Requests using hackney's default TLS config (no `ssl_options` passed) also
enable TLS 1.3 session resumption (`{session_tickets, auto}`), so fresh
connections to a recently contacted server skip the full handshake. Set the
`tls_session_resumption` application env to `false` to turn this off.
Requests with custom `ssl_options` never use resumption: the OTP ticket
store is shared node-wide and a resumed session skips certificate
validation, so it is reserved for the identical default trust config.

### Streaming

Stream request bodies for uploads:

```erlang
{ok, Ref} = hackney:post(URL, Headers, stream),
hackney:send_body(Ref, <<"chunk 1">>),
hackney:send_body(Ref, <<"chunk 2">>),
hackney:finish_send_body(Ref),
{ok, Status, _, Ref} = hackney:start_response(Ref),
{ok, Body} = hackney:body(Ref).
```

Sync responses return the full body directly. To receive a large response
piece-by-piece, use the async API (see the [Async Responses](#async-responses)
section below).

### Async Responses

Receive response data as messages:

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [async]),
receive
    {hackney_response, Ref, {status, 200, _}} -> ok
end,
receive
    {hackney_response, Ref, {headers, Headers}} -> ok
end,
receive_body(Ref).

receive_body(Ref) ->
    receive
        {hackney_response, Ref, done} -> ok;
        {hackney_response, Ref, Bin} -> receive_body(Ref)
    end.
```

### WebSocket

```erlang
{ok, Conn} = hackney:ws_connect(<<"wss://echo.websocket.org">>),
ok = hackney:ws_send(Conn, {text, <<"hello">>}),
{ok, {text, <<"hello">>}} = hackney:ws_recv(Conn),
hackney:ws_close(Conn).
```

### WebTransport

Same shape as WebSocket, over HTTP/3 (QUIC). Swap `ws_` for `wt_`:

```erlang
{ok, Conn} = hackney:wt_connect(<<"https://example.com/wt">>),
ok = hackney:wt_send(Conn, {binary, <<"hello">>}),
{ok, {binary, <<"hello">>}} = hackney:wt_recv(Conn),
hackney:wt_close(Conn).
```

### HTTP/2

HTTP/2 is used automatically when the server supports it:

```erlang
%% Automatic HTTP/2 via ALPN negotiation
{ok, 200, Headers, Body} = hackney:get(<<"https://nghttp2.org/">>).

%% Force HTTP/1.1 only
hackney:get(URL, [], <<>>, [{protocols, [http1]}]).

%% Force HTTP/2 only
hackney:get(URL, [], <<>>, [{protocols, [http2]}]).
```

### HTTP/3 (Experimental)

HTTP/3 support is **opt-in**. Enable it per-request or globally:

```erlang
%% Enable HTTP/3 for a single request
hackney:get(URL, [], <<>>, [{protocols, [http3, http2, http1]}]).

%% Enable HTTP/3 globally (application-wide)
application:set_env(hackney, default_protocols, [http3, http2, http1]).
```

IPv6 works out of the box (Happy Eyeballs); force a family with
`{connect_options, [{family, inet6}]}`. Session resumption and 0-RTT are on by
default and cached per host; disable with `{zero_rtt, false}`. See the
[HTTP/3 Guide](guides/http3_guide.md) for details.

**Note:** HTTP/3 uses QUIC (UDP transport). Some networks may block UDP traffic.

### Multipart

Upload files and form data:

```erlang
Multipart = {multipart, [
    {<<"field">>, <<"value">>},
    {file, <<"/path/to/file.txt">>},
    {file, <<"/path/to/image.png">>, <<"image.png">>, [{<<"content-type">>, <<"image/png">>}]}
]},
hackney:post(URL, [], Multipart).
```

### Proxy Support

```erlang
%% HTTP proxy
hackney:get(URL, [], <<>>, [{proxy, <<"http://proxy:8080">>}]).

%% With authentication
hackney:get(URL, [], <<>>, [{proxy, <<"http://user:pass@proxy:8080">>}]).

%% Environment variables work automatically
%% HTTP_PROXY, HTTPS_PROXY, NO_PROXY
```

### Redirects

```erlang
%% Follow redirects automatically
hackney:get(URL, [], <<>>, [{follow_redirect, true}, {max_redirect, 5}]).
```

### Timeouts

```erlang
hackney:get(URL, [], <<>>, [
    {connect_timeout, 5000},  %% Connection timeout
    {recv_timeout, 30000},    %% Response timeout
    {send_timeout, 30000}     %% HTTP/2 body send timeout (flow control)
]).
```

### Automatic Decompression

```erlang
%% Automatically decompress gzip/deflate responses
hackney:get(URL, [], <<>>, [{auto_decompress, true}]).
```

### SSL Options

```erlang
%% Custom CA certificate
hackney:get(URL, [], <<>>, [
    {ssl_options, [{cacertfile, "/path/to/ca.pem"}]}
]).

%% Skip verification (development only)
hackney:get(URL, [], <<>>, [
    {ssl_options, [{verify, verify_none}]}
]).
```

#### SNI

By default the TLS `server_name_indication` is the request host, and it is
omitted when the host is an IP literal (RFC 6066 forbids SNI for IP
addresses). Set it explicitly to present a different name; the value is used
both on the wire and as the certificate hostname-verification target, which
is useful when connecting to an IP or a proxy while validating a hostname:

```erlang
hackney:get("https://93.184.216.34", [], <<>>, [
    {ssl_options, [{server_name_indication, "example.com"}]}
]).

%% Suppress SNI without weakening verification
hackney:get(URL, [], <<>>, [
    {ssl_options, [{server_name_indication, disable}]}
]).
```

This applies to HTTP/1.1, HTTP/2 and HTTP/3.

## Modules

| Module | Purpose |
|--------|---------|
| `hackney` | Main API - requests, connections, WebSocket |
| `hackney_pool` | Connection pool management |
| `hackney_url` | URL parsing and encoding |
| `hackney_headers` | Header manipulation |
| `hackney_multipart` | Multipart encoding |
| `hackney_cookie` | Cookie parsing |
| `hackney_http` | HTTP protocol parser |

## Requirements

Erlang/OTP 27+

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on pull requests and development setup.

Issues and pull requests welcome at https://github.com/benoitc/hackney

## Support

hackney is critical infrastructure for many Erlang and Elixir applications. If your company relies on it, consider sponsoring its maintenance:

[![Sponsor](https://img.shields.io/badge/sponsor-❤-ff69b4)](https://github.com/sponsors/benoitc)

Sponsorship ensures continued development, timely security patches, and compatibility with OTP releases.

**Corporate sponsors:** If hackney is part of your infrastructure, [reach out](mailto:benoitc@enki-multimedia.eu) for sponsored support options.

## Sponsors

<a href="https://enki-multimedia.eu"><img src="guides/images/enki-multimedia.svg" alt="Enki Multimedia" height="50" /></a>

## License

Apache 2.0 - See [LICENSE](LICENSE) and [NOTICE](NOTICE)

Copyright (c) 2012-2026 Benoit Chesneau
