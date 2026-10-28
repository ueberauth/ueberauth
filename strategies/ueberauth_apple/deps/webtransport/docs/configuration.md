# Configuration

## Server Options

```erlang
webtransport:start_listener(Name, Opts).
```

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `transport` | yes | -- | `h2` (HTTP/2) or `h3` (HTTP/3) |
| `port` | yes | -- | TCP/UDP port to listen on |
| `certfile` | yes | -- | Path to TLS certificate (PEM) |
| `keyfile` | yes | -- | Path to TLS private key (PEM) |
| `handler` | yes | -- | Module implementing `webtransport_handler` |
| `handler_opts` | no | `#{}` | Map passed to `handler:init/3` |
| `max_data` | no | 1048576 (1 MB) | Session-level flow-control window (bytes) |
| `max_streams_bidi` | no | 100 | Max concurrent bidirectional streams |
| `max_streams_uni` | no | 100 | Max concurrent unidirectional streams |
| `ip` | no | wildcard | Bind address (`inet:ip_address()`; IPv4 4-tuple or IPv6 8-tuple) |
| `family` | no | `inet` | `inet` or `inet6`; forces the family when no `ip` is given (e.g. the IPv6 wildcard) |
| `socket_opts` | no | `[]` | Extra options for the underlying listener socket (h3 only) |
| `sni_callback` | no | -- | Per-SNI certificate selection (see below) |
| `compat_mode` | no | `auto` | HTTP/3 draft selection (see below) |

### Per-SNI certificates

`sni_callback` picks the server certificate per connection from the ClientHello
SNI (RFC 6066 §3), so one listener can present different certs per hostname:

```erlang
SniFun = fun(ServerName) ->
    case lookup_cert(ServerName) of
        {ok, Cert, Key} -> {ok, #{cert => Cert, key => Key}};
        error -> {error, unknown_host}
    end
end,
webtransport:start_listener(srv, Opts#{sni_callback => SniFun}).
```

`ServerName` is a binary hostname (or `undefined` on h3 when the client sends no
SNI). The result `cert` is a DER binary, `key` a decoded private-key term, and
optional `cert_chain` the DER intermediates. For h3 the callback is forwarded to
`quic`; for h2 it is adapted to an `ssl` `sni_fun`. A callback returning
`{error, _}` (or raising) fails the handshake on both transports. When a client
sends no SNI, h2 serves the static `certfile`/`keyfile`. The static cert remains
the default when no callback is set.

### IPv6 binding

```erlang
%% IPv6 wildcard
webtransport:start_listener(srv, Opts#{transport => h3, family => inet6}).

%% A specific IPv6 address
webtransport:start_listener(srv, Opts#{transport => h3,
                                       ip => {0,0,0,0,0,0,0,1}}).
```

Works for both `h3` and `h2`. (h2 IPv6 binding requires the `h2` library
0.7.0 or later, which this release depends on.)

### Bound address

`webtransport:listener_sockname/1` returns the bound `{Ip, Port}`; it is also
included as `sockname` in `listener_info/1`. For h3 the address is resolved
live from the QUIC socket (correct even with `port => 0` or `inet6`). For h2 it
is best-effort: the requested bind address paired with the actual bound port,
because the h2 library exposes only the port.

## Client Options

```erlang
webtransport:connect(Host, Port, Path, Opts).
```

| Option | Default | Description |
|--------|---------|-------------|
| `transport` | `h3` | `h2` or `h3` |
| `verify` | `verify_peer` | `verify_peer` or `verify_none` |
| `cacertfile` | -- | Path to CA certificate bundle |
| `certfile` | -- | Client certificate (mutual TLS) |
| `keyfile` | -- | Client private key (mutual TLS) |
| `headers` | `[]` | Extra headers on the CONNECT request |
| `timeout` | 30000 | Connection timeout (ms) |
| `handler_opts` | `#{}` | Map passed to handler's `init/3` |
| `family` | `any` | `inet`, `inet6`, or `any` (h3 only) |
| `happy_eyeballs` | `true` | RFC 8305 v6/v4 racing for multi-address hosts (h3 only) |
| `connection_attempt_delay` | 250 | Happy Eyeballs stagger between attempts, ms (h3 only) |
| `session_ticket` | -- | Stored 0-RTT resumption ticket (h3 only; see below) |
| `compat_mode` | `latest` | HTTP/3 draft selection (see below) |

`Host` accepts a hostname (string/binary), an IP-literal string, or an
`inet:ip_address()` tuple. IPv6 literals are bracketed in the `:authority`
header automatically.

## 0-RTT / Session Tickets

After a connection completes, the connecting process receives the connection's
resumption ticket as:

```erlang
{webtransport, session_ticket, Ticket}
```

`Ticket` is an opaque term; store it and pass it back as `session_ticket` on a
later `connect/4` to the same server. `webtransport:early_data_accepted/1`
reports whether the connection negotiated 0-RTT (`true` | `false` | `unknown`
for h3, `not_supported` for h2). If early data is rejected, the connecting
process receives `{webtransport, early_data_rejected, StreamIds}`.

This release implements session-ticket capture and connection-level acceptance
reporting. Full 0-RTT resumption (sending the WebTransport CONNECT as early
data) is not supported through the current synchronous connect path.

## Compatibility Mode

The HTTP/3 WebTransport spec has evolved through multiple drafts. As of April
2026, Safari and the IETF are on draft-15 while Chrome and Firefox still use
draft-02. This library keeps the two paths separate:

| Mode | `:protocol` | SETTINGS | Use when |
|------|-------------|----------|----------|
| `latest` | `webtransport-h3` | `wt_enabled=1` + initial flow-control | Draft-15 peers (Safari, spec-conformant servers) |
| `legacy_browser_compat` | `webtransport` | `SETTINGS_ENABLE_WEBTRANSPORT_DRAFT02=1` | Draft-02 peers (Chrome, Firefox, quic-go v0.9) |
| `auto` (server only) | accepts both | advertises both | Accept either draft per request |

### Server detection

In `auto` mode, the server inspects each CONNECT request:

- `:protocol = webtransport-h3` with no draft-02 header -> latest
- `:protocol = webtransport` -> legacy_browser_compat
- Conflicting signals (e.g. `webtransport-h3` plus the draft-02 header) -> 400

The decision is frozen at session init. Pin to `latest` or
`legacy_browser_compat` to refuse the other:

```erlang
%% Accept only draft-15 clients
webtransport:start_listener(strict, #{
    transport => h3,
    port => 4433,
    certfile => "cert.pem",
    keyfile => "key.pem",
    handler => my_handler,
    compat_mode => latest
}).
```

### Client selection

Clients must choose explicitly. Default is `latest`:

```erlang
{ok, Session} = webtransport:connect("example.com", 443, <<"/wt">>, #{
    transport => h3,
    compat_mode => legacy_browser_compat
}).
```

HTTP/2 has no draft-02 variant; `compat_mode` applies only to HTTP/3.

## Flow Control

WebTransport provides session-level and per-stream flow control:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `max_data` | 1048576 (1 MB) | Session-level byte limit |
| `max_streams_bidi` | 100 | Max concurrent bidirectional streams |
| `max_streams_uni` | 100 | Max concurrent unidirectional streams |

Override at listener or connect time:

```erlang
webtransport:start_listener(my_server, #{
    transport => h3,
    port => 4433,
    certfile => "cert.pem",
    keyfile => "key.pem",
    handler => my_handler,
    max_data => 4194304,        %% 4 MB
    max_streams_bidi => 200,
    max_streams_uni => 50
}).
```

### Enforcement

The library enforces these rules from the
[spec](https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http3-15):

- **Monotonicity** -- a peer sending a decreased `WT_MAX_DATA` or
  `WT_MAX_STREAMS` closes the session with `WT_FLOW_CONTROL_ERROR`.
- **Peer stream count** -- streams opened beyond the advertised limit are
  rejected with `WT_BUFFERED_STREAM_REJECTED`.
- **HTTP/3 prohibition** -- `WT_MAX_STREAM_DATA` and `WT_STREAM_DATA_BLOCKED`
  capsules are session errors on HTTP/3 (per-stream flow control uses native
  QUIC).
- **HTTP/2 WebTransport-Init** -- the `WebTransport-Init` structured-field
  header
  ([draft-14 section 4.3.2](https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http2-14#section-4.3.2))
  carries initial flow-control windows. When both SETTINGS and the header are
  present, the greater value is used.
- **Large sends** -- `send/4` accepts a payload of any size and returns `ok`
  once it is queued. On HTTP/3 the bytes go straight to QUIC, which does the
  flow control. On HTTP/2 the bytes that exceed the session or stream window
  (256 KB per stream by default) wait in order on the stream, FIN is held
  until they are out, and the queue drains as the peer raises `WT_MAX_DATA`
  or `WT_MAX_STREAM_DATA`.
- **Credit on receive** -- on HTTP/2 the library sends `WT_MAX_STREAM_DATA`
  and `WT_MAX_DATA` on its own once half of a window has been consumed, so a
  peer that honours our windows is never left waiting.

## Datagram Limits

Datagrams are bounded by the transport:

| Transport | Max payload | Reason |
|-----------|-------------|--------|
| HTTP/3 | 65527 bytes | `max_datagram_frame_size` (65535) minus session-id varint (up to 8 bytes) |
| HTTP/2 | 65471 bytes | HTTP/2 initial stream window (65535) minus capsule framing overhead (64 bytes) |

Sending a datagram larger than the limit returns `{error, datagram_too_large}`.

## Error Codes

The library uses the error codes defined in the
[spec](https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http3-15#section-9.5):

| Constant | Value | Meaning |
|----------|-------|---------|
| `WT_BUFFERED_STREAM_REJECTED` | `0x3994bd84` | Peer exceeded buffered stream limit |
| `WT_SESSION_GONE` | `0x170d7b68` | Session terminated |
| `WT_FLOW_CONTROL_ERROR` | `0x045d4487` | Flow-control violation |
| `WT_REQUIREMENTS_NOT_MET` | `0x212c0d48` | Protocol requirements not satisfied |

Application-level error codes are mapped to/from QUIC error codes per
[draft-15 section 3.3](https://datatracker.ietf.org/doc/html/draft-ietf-webtrans-http3-15#section-3.3).

## Session Termination

When a session closes (locally or by the peer):

1. All live streams are reset with `WT_SESSION_GONE`.
2. A `CLOSE_SESSION` capsule is sent (or received) with an error code and
   reason (max 1024 bytes).
3. The CONNECT stream is half-closed (FIN sent).
4. The handler's `terminate/2` receives `{closed, ErrorCode, Reason}`.

If the peer FINs the CONNECT stream without sending `CLOSE_SESSION`, the
session terminates with `{closed, 0, <<"peer closed CONNECT">>}`.
