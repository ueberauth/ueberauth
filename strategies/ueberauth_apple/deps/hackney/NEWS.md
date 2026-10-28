# NEWS

4.9.1 - 2026-10-26
------------------

### Fixed

- The documentation builds again. A misplaced doc comment in 4.9.0 made
  edoc fail, which also blocked publishing that release to Hex.

4.9.0 - 2026-10-25
------------------

### Added

- A `max_body_size` request option caps a response body that hackney
  buffers for you (the default `hackney:request` result, or `body/1`).
  It defaults to 512 MiB and also accepts the 1.x name `max_body`;
  `infinity` turns it off (#980).

### Fixed

- URLs that hide a loopback or private IP inside a percent-encoded
  bracketed IPv6 address, or behind a trailing dot, are now refused like
  other IP literals. The earlier fix for CVE-2026-47076 missed these two
  spellings, so such a URL still reached the address it denotes (#987).
- Pinning your own CA with `cacerts` or `cacertfile` now actually limits
  which servers are trusted. hackney still accepted any certificate chain
  that included a publicly trusted root, so a pinned connection could reach
  a server its CA never vouched for (#978).
- Following a redirect no longer resends `basic_auth` and `cookie` to
  another port on the same host, or over plain HTTP after HTTPS. Only a
  redirect to the same scheme, host and port keeps them, unless you set
  `location_trusted` (#979).
- A server sending an endless or highly compressed body can no longer
  exhaust memory. Buffered bodies had no limit on HTTP/1.1, HTTP/2 and
  HTTP/3, and `auto_decompress` inflated the whole body at once. Both now
  stop at `max_body_size` with `{error, body_too_large}` (#980).
- HTTPS proxies reached through CONNECT now get the same certificate checks
  as the target: hackney's CA bundle and a hostname check against the
  proxy. The connection to the proxy only set the server name, so on
  OTP 27 and later it failed unless `proxy_ssl_options` set `cacerts` or
  `verify_none`. An explicit `{verify, verify_none}` is still honoured (#988).
- A `proxy_auth_fun` that returns a value containing CR, LF or NUL is now
  refused with `{error, {proxy_auth_error, invalid_header}}`. The value was
  written as is into the CONNECT request, so those bytes added header lines
  of their own (#989).
- A slow or unreachable host no longer stalls every request that goes
  through the same pool. The pool opened new connections itself, so while
  one host took its time to answer, checkouts for every other host waited,
  for up to `connect_timeout`. The requester now opens its own connection,
  as in hackney 1.x (#973).
- A failed TLS handshake on a pooled connection no longer frees a
  `max_per_host` slot held by another request. The slot was released twice,
  so the host could get one more concurrent connection than allowed (#984).

### Changed

- Buffered downloads over 512 MiB now fail with `{error, body_too_large}`
  unless you raise `max_body_size` (#980).
- If you pin `cacerts` that include the bundled public roots, hackney no
  longer falls back to trusting a cross-signed root it finds in the
  server's chain. Add the root you need to your list, or pass your own
  `partial_chain` (#978).

4.8.7 - 2026-10-25
------------------

### Changed

- Update `quic` to 2.1.2, a security release for HTTP/3 and WebTransport.
  Session tickets now resume only on the listener that issued them, and a
  hostile peer can no longer stall a listener or grow a slow owner's
  mailbox without bound (#982).

4.8.6 - 2026-10-24
------------------

### Fixed

- Large HTTP/2 downloads over slow links no longer fail with
  `{error, {stream_error, internal_error}}`. hackney let only 64 KB of a
  response travel per round trip, so over a 120 ms link a 40 MB body took
  longer than the server allowed and the server cancelled it. HTTP/2
  downloads now run about as fast as HTTP/1.1 (#976).
- Closing a pooled TLS connection no longer logs a supervisor report with
  reason `killed`. The connection waited for the server to close its side,
  which took longer than the pool allows, and was killed (#976).

### Changed

- Update `h2` to 0.12.5 and `certifi` to 2.18.0. The new `certifi` removes
  the compromised eMudhra certificates from the CA bundle (#975).

4.8.5 - 2026-10-04
------------------

### Fixed

- A GOAWAY fails only the requests the server refused. HTTP/2 failed every
  in-flight request with `{error, {goaway, _}}`, including ones the server
  went on to complete, and HTTP/3 ignored the GOAWAY and kept sending new
  requests on the connection. Accepted streams now finish, streamed uploads
  and responses included, refused ones fail and are reset, and the
  connection leaves the pool and closes once drained (#961, #962, #964,
  #965, #968).
- A failed HTTP/2 request body send fails the other streams on the
  connection instead of leaving them waiting (#964).
- Closing an HTTP/3 connection no longer makes the other live HTTP/3
  connections unreachable. The connection table was owned by the first
  connection and went away with it (#967).

### Changed

- Update `h2` to 0.12.4, `quic` to 2.1.1 and `webtransport` to 0.4.8.

4.8.4 - 2026-09-27
------------------

### Fixed

- `hackney:close/1` on a shared pooled HTTP/2 connection resets only the
  caller's own streams. It stopped the connection, failing every other
  caller's streams on it. The connection still closes itself once idle with
  no stream open.
- A connection opened without a pool honours `connect_timeout` above 8
  seconds, and a dial that outlives it returns `{error, connect_timeout}`.
  The wait was capped at 8 seconds and ended as an exit in the caller. A
  dial stuck in the transport no longer holds the caller past its deadline
  either (#945).

4.8.3 - 2026-09-27
------------------

### Fixed

- `hackney_conn:set_owner/2` works while a streamed request body is being
  sent. It returned `{error, invalid_state}`.
- A response body cut short by the server closing the connection is an
  error. For a chunked or `Content-Length` body, `body/1` returns
  `{error, {closed, Partial}}` with the bytes that arrived, and
  `stream_body/1` and async responses end with `{error, closed}`. They
  reported a short body as complete. A body with neither still ends when the
  connection closes.
- An HTTPS request through a CONNECT proxy reached over TLS
  (`{proxy_transport, ssl}`) works. The target TLS handshake ran over the
  proxy TLS socket as if it were plain TCP and failed.
- A pooled connection from `hackney:connect/*` stays with its caller between
  requests, and `hackney:close/1` checks it back into the pool. It went back
  to the pool after every response while the caller still used it, so the
  pool could stop it in the middle of the next request (`{error, closed}`)
  or lend it to another process.

4.8.2 - 2026-09-26
------------------

### Fixed

- A connection opened without a pool is owned by the process that opened it
  and closes when that process dies. It was started under `hackney_conn_sup`
  and owned by it, so a killed caller left the connection and its socket open
  until the server closed it (`idle_timeout` defaults to `infinity`). Covers
  `request/5` and `connect/*` with `{pool, false}`, streamed request bodies,
  async responses, HTTP proxies, CONNECT and SOCKS5 tunnels, HTTP/2 and
  HTTP/3, and `h2_open/*` streams. With `stream_to`, the `stream_to` process
  owns the connection, as before. `hackney_conn:set_owner/2` still moves
  ownership.
- An HTTP/1.1 connection waiting for a response closes within a second of
  its owner dying. It was blocked in the socket read and noticed only when
  the response came, the server closed, or `recv_timeout` expired.
- A CONNECT or SOCKS5 tunnel socket belongs to its connection. It stayed with
  the process that opened it, so after `hackney_conn:set_owner/2` it still
  closed when that process died.

4.8.1 - 2026-09-25
------------------

### Changed

- Update `quic` to 2.0.1, which compiles on Windows again. Its NIF build and
  clean hooks ran through `sh`, which Windows lacks, so the compile failed
  there for anything that reaches quic, hackney included. Windows runs on OTP
  crypto.

4.8.0 - 2026-09-24
------------------

### Fixed

- `hackney:send_request/2` works on HTTP/2 and HTTP/3. Those protocols answer
  a request with the body included, which the function did not handle, so it
  failed with a `case_clause`. It returns the connection on every protocol
  now, so the response is read with `body/1` or pulled with `stream_body/1`.
- Several callers reading responses on one HTTP/2 or HTTP/3 connection each
  get their own. The read was resolved from the connection's last stream
  rather than the caller's, so on HTTP/2 all but one caller got
  `{error, no_stream}`, and on HTTP/3 two callers could be handed each
  other's body.
- A caller reading an HTTP/3 response with `body/1` or `stream_body/1` is
  answered when the server resets its stream, instead of waiting for its own
  timeout. Needs quic 2.0.0, the first release to report a peer RESET_STREAM.
- A pooled HTTP/2 connection no longer closes when the caller that opened it
  exits. It stayed owned by that caller, so its exit failed every other
  caller's request on the connection with `{error, closed}`. A shared
  connection now has no owner: each stream is tied to its own caller and is
  reset if that caller dies, and the connection closes itself once it has had
  no open stream for the pool `timeout` (#937, thanks @smartinio).
- Unregistering a pooled HTTP/2 connection no longer leaks its per-host slot.
  The pool dropped its monitor on the connection, so the slot was never
  released when the connection stopped.
- A response that crosses a reset of its stream no longer closes the HTTP/2
  connection. `h2` dropped the header block of that response without decoding
  it, so the next response on the connection failed with COMPRESSION_ERROR.
- The response to an HTTP/3 streaming upload can be read. After
  `start_response/1`, `body/1` returned `{error, invalid_state}` and
  `stream_body/1` returned `{error, no_stream}`: the body went to the
  `start_response/1` caller as a second reply and was lost. When the response
  headers arrived before `start_response/1` was called, it could wait forever.
- HTTP/3 response headers carry one `:status`. quic_h3 passes the status
  separately and keeps it in the header list, and hackney prepended its own,
  so every response reached the low-level `{h3, _, {stream_headers, ...}}`
  consumer with the pseudo-header twice, which RFC 9114 4.3.1 makes a
  malformed response. Requests through `hackney:request/5` were not affected:
  pseudo-headers are filtered before the caller sees them.
- An HTTP/3 connection that goes away reports why. `quic_h3` sends the reason
  with its close event, and the handler only matched the older shape without
  one, so the message was dropped: the caller waited out its own timeout and
  the connection process stayed alive. A handshake that fails on a bad
  certificate or a TLS alert now comes back as that error instead of
  `{error, timeout}`.
- `hackney_h3:connect/3,4` and `hackney_h3:request/5` honor a `cacertfile`
  option. It was handed to quic, which only takes DER `cacerts`, so it was
  ignored and verification failed as `{error, timeout}`. `hackney:request/5`
  was not affected.
- Connection-specific headers are dropped from HTTP/2 and HTTP/3 requests.
  A caller's `Connection: keep-alive`, legal in HTTP/1.1 and banned by
  RFC 9113 8.2.2 and RFC 9114 4.2, reached the header block and every request
  failed before anything was written. hackney picks the protocol through ALPN,
  so the caller cannot know which rules apply: `Connection`, `Keep-Alive`,
  `Proxy-Connection`, `Transfer-Encoding` and `Upgrade` are stripped alongside
  `Host`. `TE` is kept, being allowed with the value `trailers`
  (#935, thanks @lennartschoch).
- A pooled HTTP/1.1 connection handed to a requester no longer closes itself
  under the request. Checkout left the keepalive timer running, armed before
  the readiness probe, so a connection could pass the probe and then fire the
  timer, and the request that followed came back as `{error, invalid_state}`.
  The timer is disarmed on checkout and re-armed when the connection returns
  to the pool (#934, thanks @lennartschoch).
- A request that races a peer-initiated close now returns `{error, closed}`
  instead of `{error, invalid_state}`. A connection that sees the peer close
  stays alive briefly so late calls get an answer, and during that window every
  call without a handler answered with the generic `invalid_state`. The same
  race therefore had two answers: `{error, closed}` once the connection process
  was gone, `{error, invalid_state}` while it lingered. Callers can now tell a
  closed connection from a misuse of the API (#932, #933, thanks @kpy3).

### Changed

- Update `h2` to 0.12.3. 0.12.3 sends the DATA already buffered on a stream
  when a SETTINGS frame raises the initial window, so a request body queued
  against a zero window no longer stalls until an unrelated WINDOW_UPDATE
  arrives.
- Update `quic` to 2.0.0 and `webtransport` to 0.4.7. quic 2.0.0 reports a
  peer resetting a request stream, always sends a reason with its HTTP/3
  close event, and fixes a handshake that could stall when resuming from a
  cached session ticket.

4.7.4 - 2026-08-12
------------------

### Fixed

- A connection attempt that outlives its timeout no longer terminates the pool,
  and with it every caller of that pool. The dial is made with the request's
  `connect_timeout`, and a call that times out, like a connection process that
  dies while dialing, comes back as a checkout error (#927, #928, thanks
  @aboroska).
- Handing a pooled connection to a new owner, and the prewarm dial, are guarded
  like the other calls the pool makes into a connection process. A connection
  that is gone or wedged is dropped instead of taking the pool down (#929).
- Stopping a connection from inside the pool is bounded to 100ms, after which
  the connection is killed. A connection wedged in a transport call, which a
  failed dial makes likely, used to hold every caller of the pool for as long
  as the transport took to return (#929).
- The health probes the pool runs on a connection (`is_ready`, `checkin_info`,
  `set_owner`, `get_state`) take an explicit timeout, and the pool passes
  250ms. `h2_conn_usable/1` used the 5s default, so one wedged HTTP/2
  connection stalled the pool for 5 seconds on every checkout for that host
  (#929).

### Added

- Fault injection test harness for the pool: a transport which can be told to
  misbehave, a sentinel which makes a dead pool visible, fault and chaos
  suites, and a structural test which fails if the pool calls a connection
  process outside a `try`. `DEVELOPMENT.md` explains how to use it (#929).

### Changed

- Update dependencies to their latest releases: `h2` 0.12.0 and `webtransport`
  0.4.5 (#930).

4.7.3 - 2026-08-11
------------------

### Fixed

- Reusing a pooled HTTP/2 or HTTP/3 connection no longer crashes the caller of
  `hackney:connect/4` when the pooled connection terminates during the checkout
  liveness probe. The `get_state` probe is guarded so a terminating connection
  falls through to a fresh one (#914).
- `hackney_url:normalize/2` now rejects a host that reaches an IP literal only
  after IDNA folds the Unicode full-stop variants (U+3002/U+FF0E/U+FF61) to
  ASCII dots (for example `127。0。0。1` becoming `127.0.0.1`), closing a bypass
  of the percent-encoded-IP check.
- The CONNECT proxy handshake rejects CR/LF/NUL in the target host instead of
  concatenating it into the request line and `Host` header.
- The pooled HTTPS upgrade bounds the TLS handshake with `connect_timeout`
  (`ssl:connect/3`), so a server that stalls the handshake no longer pins the
  connection process and its pool slot (#916).
- The streaming request path sanitizes header values (CR/LF) like the buffered
  path, and the request method is validated (CR/LF/NUL) at every entry point,
  not just the request target.
- A response body cut short by the peer closing mid-transfer no longer leaks
  the connection process. `read_full_body/2` hands back `socket = undefined`,
  so the connection went straight to `closed` and never reached the reuse
  check added for #902. An unpooled connection arms no grace timer there and,
  when started under `hackney_conn_sup`, has the supervisor as its `owner`, so
  the owner-DOWN clause never fired either: the process parked forever holding
  every refc binary it had read. Callers could not clean up, since a
  synchronous request returns the body directly and the truncated read still
  reports `{ok, Body}` (#918). The same applies to a failed body read and to
  bodyless (204/304) responses.
- `hackney_conn:get_location/1` and `set_location/2` no longer exit with
  `noproc` when the connection has already stopped, which would otherwise
  propagate out of `hackney:request/5` on the redirect path.

### Changed

- Like curl, an empty body on a body-bearing method (POST/PUT/PATCH) now sends
  `Content-Length: 0`; bodyless methods (GET/HEAD/DELETE) are unchanged (#917).
- Update dependencies to their latest releases: `quic` 1.8.0, `webtransport`
  0.4.4, `mimerl` 1.5.0, and `cowboy` 2.18.0 for the test suite.

4.7.2 - 2026-07-17
------------------

### Changed

- Bump `quic` to 1.7.1. A clean QUIC connection close (idle pooled HTTP/3
  connections, orderly shutdown) no longer emits ERROR and CRASH reports from
  `quic_h3_connection` nor propagates an abnormal exit to the connection
  owner. This also removes the intermittent eunit group cancellation in the
  h3/wt test suites.

4.7.1 - 2026-07-17
------------------

### Fixed

- Chunked decoding no longer fails with `{error, invalid_chunk_size}` when
  the CRLF terminating a chunk-size line is split across two socket reads
  (buffer ending on a lone `\r`). The parser now waits for the `\n` (#901).
- A malformed chunk-size line or chunk terminator now fails cleanly with
  `{error, invalid_chunk_size}` or `{error, poorly_formatted_chunked_size}`
  instead of crashing the parser with a `case_clause` error.

4.7.0 - 2026-07-17
------------------

### Fixed

- HTTP/2 request bodies larger than the peer's flow control window no longer
  fail with `{error, send_buffer_full}`. Body sends now block until the
  server opens the window with WINDOW_UPDATE frames, bounded by the new
  `send_timeout` request option (default 30000 ms, `infinity` allowed). If
  the window never opens the request fails with `{error, timeout}` instead
  of hanging, and the abandoned stream is reset (RST_STREAM) so its buffered
  body does not linger on a shared connection. Pass `{send_timeout, nonblock}`
  to restore the previous non-blocking behavior. Applies to whole-body and
  streamed HTTP/2 request bodies; HTTP/1.1 and HTTP/3 are unchanged.
- HTTP/2 async requests now deliver their response messages. The stream
  entry stored the internal call reference where the delivery code expected
  the `stream_to` pid, so every async HTTP/2 response was silently dropped
  and the caller never received `{hackney_response, Ref, ...}` messages.
- HTTP/2 `{async, once}` now honors `stream_next/1` with the same contract
  as HTTP/1.1: status and headers are delivered eagerly, then each
  `stream_next/1` delivers exactly one message (a body chunk or `done`).
  Previously every frame was pushed eagerly, identical to `{async, true}`.
  once-mode streams run h2 manual flow control, so a slow consumer keeps the
  peer's window closed and in-flight data stays bounded to one window.
- Connections created with `hackney:connect/4` and `{pool, false}` honor a
  `{send_timeout, T}` connect option again (`hackney:send_request/2` has no
  per-request options channel). Pooled connections keep the constant default
  and take the per-request option instead.

4.6.1 - 2026-07-15
------------------

### Changed

- Bump `h2` to 0.11.0. It adds `h2:peername/1`, which returns the peer's
  `{IpAddress, Port}` for a live connection. Additive only; no behavior
  change for hackney.

4.6.0 - 2026-07-15
------------------

### Added

- `set_owner/2` now works while a response body is streaming, in both the
  synchronous and the async path. It used to return `{error, invalid_state}`
  once the body had started. This lets a short lived worker run a request and
  hand the still streaming response to a longer lived process before it exits,
  without stopping the connection.
- `connect/4` accepts a binary host, restoring the 1.x behavior. A binary is
  converted to a string, so callers passing a binary host no longer fail.

### Fixed

- A non-reusable connection (flagged `no_reuse` for proxy tunnels, SSL
  upgrades or a disabled pool, or answered with `Connection: close`) is now
  closed and its process stopped when a synchronous request completes, instead
  of parking in `connected` forever. With a long lived owner nothing stopped
  it, so one `hackney_conn` process leaked per request until the node ran out
  of memory (#902). The sync and async reuse decision now share the same
  check, which also stops a `no_reuse` pooled connection on the async path.

4.5.2 - 2026-07-06
------------------

### Changed

- Bump `h2` to 0.10.4. It fixes a regression from 0.10.3 where a blocking
  send whose data had fully drained received `{error, stream_closed}` when
  the stream closed on its END_STREAM chunk. A waiting sender is now settled
  as `ok` once the send buffer has drained, and only gets the close-reason
  error when data is still outstanding.
- Bump `quic` to 1.7.0. Relevant to hackney's HTTP/3 client: the connection
  flow-control window now slides forward with received bytes instead of
  stalling after 8 MiB, so large HTTP/3 downloads keep flowing; the idle
  timer restarts on received activity per RFC 9000 §10.1; an invalid peer
  SETTINGS frame now closes the connection cleanly instead of crashing; and
  a client recognizes a server stateless reset (RFC 9000 §10.3) and closes
  promptly instead of waiting for the idle timeout.
- Bump `webtransport` to 0.4.3, which aligns its transitive `h2` (0.10.4) and
  `quic` (1.7.0) dependencies with hackney's own, so the `wt_*` API runs on
  the same HTTP/2 and HTTP/3 stack versions.

4.5.1 - 2026-07-04
------------------

### Changed

- Bump `h2` to 0.10.3. It fixes an HTTP/2 upload hang: a sender blocked on
  flow control is now released with `{error, stream_reset}` or
  `{error, stream_closed}` when the peer cancels the stream, instead of
  hanging for the connection's lifetime. This affects hackney's streamed
  request bodies over HTTP/2 when the server resets the stream
  mid-backpressure.

4.5.0 - 2026-07-04
------------------

### Added

- HTTP QUERY method (RFC 10008) as a first-class method: `hackney:query/1..4`
  helpers and `hackney:request(query, ...)`. QUERY is safe and idempotent and
  carries a request body like POST. It works over HTTP/1.1, HTTP/2, and
  HTTP/3 with every request body mode (binary, streamed, async, connection
  API).

4.4.5 - 2026-06-18
------------------

### Fixed

- HTTPS: a connection reused over a resumed TLS 1.3 session is no longer
  mislabeled as HTTP/1 when it negotiated HTTP/2. `ssl:negotiated_protocol/1`
  reports nothing on a resumed session, so hackney now remembers the protocol
  learned on the full handshake (per host and advertised ALPN) and offers
  resumption only once that protocol is known, resolving a resumed session
  against that snapshot. Reused h2 connections take the h2 path instead of
  feeding h2 frames to the HTTP/1 parser.
- HTTP/1.1: a response that cannot begin an HTTP/1 status line (for example an
  HTTP/2 frame on a mislabeled connection) now fails fast with
  `{error, {bad_response, not_http}}` instead of spinning the CPU in the
  status-line parser.
- Connection pooling: `Connection: close` responses are no longer returned to
  the pool on the sync body path; checkin only pools connections proven
  keep-alive and socket-ready (unknown defaults to close); and a closed pooled
  entry is discarded at checkout instead of being redialed inside the pool
  process (#888).
- Connection pooling: stopping a pool while requests are in flight no longer
  leaks the per-host concurrency (`load_regulation`) slots of the checked-out
  connections. The pool now traps exits so its shutdown releases those slots and
  stops the in-use connections, instead of orphaning them and starving the host's
  concurrency cap node-wide (#892).

4.4.4 - 2026-06-17
------------------

### Fixed

- HTTP/2: a connection is no longer reused after the peer sends `GOAWAY` while
  keeping the socket open (as AWS ALB does to recycle connections). The
  connection is retired so the pool dials a fresh one, instead of being handed
  out again with new streams the peer ignores until `recv_timeout`.
- HTTP/2: when the per-stream `recv_timeout` watchdog fires, the stalled stream
  is cancelled (`RST_STREAM`) so the peer stops sending and the connection is not
  reused with an orphaned stream.
- HTTP/1.1: bytes that issue #544's idle `{active, once}` delivers to the
  connection mailbox on a reused connection are now buffered and fed to the next
  request instead of dropping the connection (refines the 4.4.3 behavior below),
  so a reused request no longer blocks to `recv_timeout` while the response sits
  stranded as an unread message. The idle buffer is bounded, and a server close
  still refuses reuse (#544).

4.4.3 - 2026-06-17
------------------

### Fixed

- HTTP/2: a response that signals end of stream with a trailing HEADERS frame
  (trailers, or an empty trailing HEADERS as proxies emit for responses without
  a content-length) no longer hangs the body read until `recv_timeout`. The
  trailer event is now treated as end of stream, so reads complete on fresh and
  reused connections.
- HTTP/2: sync reads run under a per-stream `recv_timeout` watchdog, so a lost
  frame fails fast with `{error, timeout}` instead of blocking until the
  connection dies.
- HTTP/1.1: a pooled connection that received unsolicited data while idle is
  dropped at checkout instead of having the bytes discarded, which could strand
  or corrupt the next read. Healthy idle connections still reuse normally,
  preserving keep-alive and the issue #544 stale-connection detection.

4.4.2 - 2026-06-16
------------------

### Fixed

- Apply the pool overflow fix to the opt-in `ssl_pooling` checkout path. With
  `ssl_pooling` enabled and `pool_size` below `max_per_host`, a second
  concurrent HTTPS request could still fail with `checkout_timeout`; it now
  opens an overflow connection like the plain checkout path, closed at checkin
  rather than pooled. HTTP/2 and HTTP/3 are unaffected (they multiplex over
  shared connections).

4.4.1 - 2026-06-16
------------------

### Fixed

- Pool checkout no longer fails with `checkout_timeout` when a connection from
  a just-completed request has not yet been checked back in. `pool_size` /
  `max_connections` now bounds the warm (idle) pool kept for reuse; per-host
  concurrency is capped by `max_per_host`. A request beyond the warm pool size
  opens an overflow connection that is closed at checkin instead of being
  pooled. Set `max_per_host` to cap concurrent connections to a host.

### Dependencies

- webtransport 0.4.0 -> ~> 0.4.1, h2 ~> 0.10.0 -> ~> 0.10.1, quic 1.6.5 ->
  ~> 1.6.5. The exact webtransport 0.4.0 pin required h2 0.9.0, conflicting
  with hackney's own h2 ~> 0.10.0 and breaking installation on strict
  resolvers. webtransport 0.4.1 relaxes that requirement; the ranges now
  accept any 0.4.x / 0.10.x / 1.6.x patch release without a further bump.
  (#879)

4.4.0 - 2026-06-13
------------------

### Added

- HTTP/2 streaming request bodies and streaming response reads. Passing
  `stream` as the body now works over HTTP/2, as it already did for HTTP/1.1
  and HTTP/3: send the request body in chunks with `send_body/2` then
  `finish_send_body/1`, and read the response with `start_response/1` followed
  by `body/1` or `stream_body/1`. (#875)
- Full-duplex HTTP/2 bidirectional streaming (gRPC-style) via a new `h2_*`
  API: `h2_open`, `h2_send`, `h2_recv`, `h2_send_trailers`, `h2_consume`,
  `h2_setopts` and `h2_close`, mirroring the `ws_*` and `wt_*` APIs. A single
  stream sends and receives interleaved, sends trailers, delivers messages in
  passive or active mode, and applies receive backpressure with
  `{flow_control, manual}` plus `h2_consume/2`. Backed by the new
  `hackney_h2_stream` module. (#876)

### Dependencies

- h2 0.9.0 -> ~> 0.10.0. The requirement now accepts every patched 0.10
  release without a further bump.

4.3.0 - 2026-06-12
------------------

### Added

- Opt-in pooling of HTTPS/1.1 connections. With `{ssl_pooling, true}` (request
  option, or the `ssl_pooling` application env; default false) an upgraded SSL
  connection returns to the pool keyed by the hash of its effective TLS
  options and is reused only on an exact match, skipping the TLS handshake on
  follow-up requests. The default is unchanged: SSL connections are closed at
  checkin. (#872)
- TLS 1.3 session resumption for requests using hackney's default TLS config.
  When no `ssl_options` are passed, connections are opened with
  `{session_tickets, auto}` so fresh connections to the same server resume
  the session instead of paying a full handshake. Disable with the
  `tls_session_resumption` application env (default true). Requests with
  custom `ssl_options` deliberately get no resumption: OTP's ticket store is
  node-global and a resumed handshake skips certificate validation, so only
  the shared default trust config may use it (trust isolation). (#872)

### Changed

- Shared HTTP/2 connections are keyed by the effective TLS options, and shared
  HTTP/3 connections plus cached 0-RTT session tickets by the QUIC trust
  options. Requests with different `ssl_options` no longer share a multiplexed
  connection or resume each other's tickets.
- The TLS options hash computed for every pooled HTTPS request is memoized in
  a bounded ETS cache keyed by the pre-merge inputs and the relevant
  application envs, skipping a sha256 over the full CA bundle on cache hits.
- SNI handling. No `server_name_indication` is sent when the host is an IP
  literal (RFC 6066), on HTTP/1.1, HTTP/2 and HTTP/3. A user-supplied
  `server_name_indication` in `ssl_options` is now honored consistently as
  both the wire value and the hostname-verification target, works on the
  HTTP/3 path too, and `disable` suppresses SNI without weakening
  verification.
- Bump `quic` to 1.6.5 and `webtransport` to 0.4.0.

4.2.3 - 2026-06-10
------------------

### Dependencies

- h2 0.8.0 -> 0.9.0.
- webtransport 0.3.2 -> 0.3.3.
- parse_trans 3.4.1 -> 3.4.2.
- cowboy 2.12.0 -> 2.16.0 (test only); ranch test helper updated for the
  ranch 2.x protocol callback.

4.2.2 - 2026-06-07
------------------

### Fixed

- Pool no longer crashes when a pooled connection dies during the liveness
  check. `find_available` could call `hackney_conn:is_ready/1` on a connection
  that died right after the `is_process_alive/1` check, and the resulting
  `noproc` exit took down the pool. The dead connection is now skipped. (#869)

4.2.1 - 2026-06-05
------------------

### Dependencies

- quic 1.6.3 -> 1.6.4.
- webtransport 0.3.1 -> 0.3.2.
- certifi 2.16.0 -> 2.17.0.

4.2.0 - 2026-06-03
------------------

### Added

- IPv6 for HTTP/3. The `family` connect option (`inet` | `inet6`) is forwarded
  to QUIC, which resolves DNS and races addresses with Happy Eyeballs (RFC
  8305). IPv6 literals such as `https://[::1]/` work too. `family` may be set in
  `connect_options` or `ssl_options`.
- 0-RTT and session resumption for HTTP/3. The server's session ticket is cached
  in the pool per `{host, port, transport}` and replayed on the next
  connection; a bodyless one-shot request is then sent as 0-RTT, otherwise the
  ticket gives a resumed handshake. Enabled by default and controlled by the
  `zero_rtt` option, with an explicit `session_ticket` taking precedence over
  the cache. New `hackney_h3` helpers: `early_data_accepted/1`,
  `get_session_ticket/1`, `wait_session_ticket/2`.

### Fixed

- Recover from an expired cross-signed root instead of failing the handshake
  (e.g. Let's Encrypt's ISRG Root X2 cross-signed by the expired ISRG Root X1).
  For HTTP/1.1 and HTTP/2 the verification function rewrites `cert_expired` to
  `root_cert_expired` so OTP's cross-sign recovery runs; for HTTP/3 and
  WebTransport the same recovery is in quic 1.6.2. A genuinely expired leaf or
  intermediate still fails, and partial chains keep working.
- HTTP/3 connections from the pool now apply `ssl_options` (`cacerts`,
  `insecure`) that previously did not reach the QUIC layer.
- A pooled connection that stops between checkout and the request call no
  longer leaks `exit:{normal, _}` (or `exit:noproc`) to the caller. The
  request, body and streaming calls now return `{error, closed}` instead
  (issue #861).
- A proxy host given as an atom (e.g. `localhost`) or a binary is accepted
  again for `{ProxyHost, Port}`, `{connect, ...}` and `{socks5, ...}` proxy
  options, instead of being silently ignored. Regression from a too-strict
  `is_list/1` guard (issue #858).

### Dependencies

- quic 1.4.5 -> 1.6.3.
- h2 0.6.1 -> 0.8.0.
- webtransport 0.2.6 -> 0.3.1.

4.1.0 - 2026-05-29
------------------

### Added

- WebTransport client API (`hackney:wt_connect/1,2`, `wt_send/2`,
  `wt_recv/1,2`, `wt_setopts/2`, `wt_close/1,2`). It mirrors the WebSocket
  API so code can switch by swapping the `ws_` prefix for `wt_`. Runs over
  HTTP/3 (QUIC) by default, HTTP/2 optional. One session multiplexes many
  streams (`wt_open_stream/2`, `wt_stream_send/3,4`, `wt_stream_recv/2,3`,
  `wt_close_stream/2`, `wt_reset_stream/3`, `wt_stop_sending/3`) plus
  unreliable datagrams (`wt_send_datagram/2`) and `wt_session_info/1`.
  Backed by the `webtransport` library. Caller-supplied request headers and
  path are checked for CR/LF/NUL, and a buffer cap bounds unread data.
  See the WebTransport Guide.

### Dependencies

- Add `webtransport` 0.2.6.

4.0.3 - 2026-05-28
------------------

### Security

- HTTP/3 now verifies the server certificate. quic 1.4.4 authenticates the
  server by default; hackney passes the request's `insecure` option and any
  configured CA (`cacerts`/`cacertfile` in `ssl_options`) through to the QUIC
  connection, so verification can be disabled or pointed at a custom trust
  store. Without a configured CA, quic uses its default trust store.

### Changed

- Replace the deprecated `catch Expr` form with `try ... catch` so hackney
  compiles cleanly on OTP 29.

### Dependencies

- Bump quic to 1.4.5.
- Bump h2 to 0.6.1.

4.0.2 - 2026-05-25
------------------

### Bug Fixes

- Fix an intermittent pool crash when a server closes a pooled keep-alive
  connection during checkout (#850). The checkout now tolerates the
  `set_owner` race and falls through to a fresh connection instead of crashing
  on a bad match, and an async ownership handoff to an already-closed pooled
  connection stops it promptly so the pool drops it from rotation.
- Expose `hackney:body/1,2` and `hackney:stream_body/1` again so the response
  body can be read after `start_response/1` in streaming body mode (#849).
  The migration guide and examples referenced these but they were not
  exported.

4.0.1 - 2026-05-25
------------------

Security release. Fixes 10 reported vulnerabilities (5 high, 4 medium,
1 low) plus one hardening change. No API changes; drop-in for 4.0.0. It
also rolls up the dependency and documentation changes landed since 4.0.0.

### Security

- CVE-2026-47066 (GHSA-6cp8): Alt-Svc response parser entered an infinite
  loop on a header starting with a non-token byte, pinning a scheduler at
  100% CPU. The parser now rejects the malformed entry instead of looping.
- CVE-2026-47067 (GHSA-9653): URL scheme parsing called binary_to_atom on
  attacker-controlled prefixes, allowing atom-table exhaustion and a BEAM
  crash. Unknown schemes no longer create atoms.
- CVE-2026-47073 (GHSA-q8jg): WebSocket frame, message and handshake buffers
  were unbounded. Added max_frame_size (16 MiB), max_message_size (64 MiB,
  cumulative across fragments) and a 64 KiB handshake-response cap.
- CVE-2026-47074 (GHSA-jq4m): the per-chunk HTTP/3 read timeout reset on
  every chunk while the full body buffered in memory, enabling a slow-drip
  OOM. Buffered bodies are now capped by max_body_size.
- CVE-2026-47071 (GHSA-gp9c): the post-handshake TLS upgrade over a proxy
  CONNECT tunnel used ssl:connect with no timeout, so a stalled peer hung the
  caller forever. The connect timeout is now forwarded.
- CVE-2026-47076 (GHSA-pj7v): hackney_url:normalize/2 decoded percent-escapes
  in the host after the SSRF allowlist ran, letting an encoded host bypass
  the check and resolve to a blocked IP. Hosts that decode to an IP are now
  refused.
- CVE-2026-47072 (GHSA-f9vr): the WebSocket upgrade request did not validate
  the target, allowing CR/LF/NUL header injection. These bytes are now
  rejected.
- CVE-2026-47075 (GHSA-j9wq): the HTTP request target (path and query) was
  not validated, allowing CR/LF injection and request splitting. CR/LF/NUL
  are now rejected.
- CVE-2026-47070 (GHSA-h73q): cross-origin HTTP/3 redirects forwarded
  Authorization, Cookie and Proxy-Authorization. These are now stripped when
  the redirect target origin differs, unless location_trusted is set. As with
  curl and the HTTP/1.1 path, the request body is still forwarded on 307/308.
- CVE-2026-47069 (GHSA-mp55): cookie domain and path options were not
  validated, allowing CR/LF header injection. These are now rejected.
- Hardening: to_atom/1 no longer falls back to list_to_atom/1, removing an
  atom-leak path (GHSA-6rmf, no CVE assigned).

### Dependencies

- Bump quic to 1.4.3.
- Bump h2 to 0.6.0.

### Docs

- Add SECURITY.md describing private vulnerability reporting.
- Add a sponsor section to the README.
- Fix exdoc generation: drop the unsupported source_ref and skip the
  NEWS/MIGRATION warnings.

### Chore

- Drop stray files (nat2, lifecycle.json, .gitlab-ci.yml).

4.0.0 - 2026-04-16
------------------

Hackney 4 trims the client down. The HTTP/2 and HTTP/3 stacks are now
delegated to `erlang_h2` and `erlang_quic`, so hackney no longer ships
its own framing, HPACK / QPACK codecs, control streams or state
machines. The HTTP/3 path is fully spec-compliant via `quic_h3`, with
ALPN negotiation, Alt-Svc discovery (RFC 7838), and the same
`hackney:request/5` API as HTTP/1.1. The bundled metrics subsystem is
gone too, replaced by a Go-style middleware chain that lets users plug
in prometheus, telemetry or anything else without hackney owning the
policy. See `guides/middleware.md` and `guides/http3_guide.md`.

### Breaking

- Removed the built-in metrics subsystem (`hackney_metrics`,
  `hackney_metrics_backend`, `hackney_metrics_prometheus`,
  `hackney_metrics_dummy`). Hackney no longer emits request or pool
  metrics on its own and the `metrics_backend` app-env is no longer
  read. In its place, `hackney:request/1..5` runs a chain of
  user-supplied middleware (Go-style `RoundTripper`) configured via the
  `{middleware, [Fun, ...]}` option or `application:set_env(hackney,
  middleware, [...])`. See `guides/middleware.md` for the API, chain
  semantics, and worked prometheus / telemetry recipes. Pool state is
  still observable via `hackney_pool:get_stats/1`.

### Bug Fixes

- Wire `hackney_altsvc:parse_and_cache/3` into the response path so
  server-advertised HTTP/3 endpoints are actually recorded. Previously
  the cache was only populated by manual `cache/4` calls; the HTTP/3
  guide claimed automatic discovery but it never fired. Same hook
  honors RFC 7838 `clear` (invalidates the cached entry) and merges
  multiple `Alt-Svc` headers per RFC 7230 §3.2.2. Fires on every
  protocol so the cache TTL stays fresh while h3 is in use.
- Fix HTTP/2 pooled connections wedging under sustained concurrent load
  (#836). The pool checks out a TCP connection first then upgrades to
  SSL+ALPN; `connected(enter)` armed the 2s pool idle timer while the
  protocol was still classified as HTTP/1.1, and the timer then fired
  on a busy multiplexed HTTP/2 connection, terminating it mid-request.
  `init_h2_connection` / `init_h2_after_upgrade` now explicitly cancel
  the idle timer. hackney_conn also traps `EXIT` from the linked
  `h2_connection` and stays alive briefly in `closed` state so late
  calls that raced the pool checkout get a proper error reply instead
  of `exit:{normal, _}`. Pool's `checkout_h2` validates the state of
  the connection process (not just `is_process_alive`).
- Bump `h2` dependency to 0.4.0.

### Refactor

- HTTP/2 is now delegated to the `erlang_h2` library (hex `h2` 0.4.0).
  Hackney no longer ships its own HTTP/2 framing, HPACK codec, or
  connection/stream state machine:
  - `hackney_http2.erl`, `hackney_http2_machine.erl`, `hackney_hpack.erl`
    and the `hackney_hpack_huffman*` headers have been removed.
  - `hackney_conn.erl` now starts an `h2_connection` gen_statem on the
    post-ALPN socket, transfers socket ownership, and translates
    `{h2, Conn, Event}` owner-messages into hackney's sync replies or
    `{hackney_response, Ref, _}` async events.
  - Server push handling (RFC 7540 §8.2, deprecated) is no longer exposed.
    The `enable_push` option is a no-op.
  - Public user-facing API is unchanged: `hackney:request/5`, streaming
    async responses, pooled HTTP/2 connections, and `request_async` all
    behave as before.
- HTTP/3 is now delegated to the `erlang_quic` library's `quic_h3` module
  (hex `quic` 1.0.0). Hackney no longer ships its own HTTP/3 framing,
  QPACK codec, control-stream or unidirectional-stream handling:
  - `hackney_quic.erl` has been merged into `hackney_h3.erl`: the single
    module now holds both the high-level request API and the gen_server
    adapter that translates `{quic_h3, Conn, _}` events.
  - The public low-level message tag is now `{h3, ConnRef, _}` (previously
    `{quic, ConnRef, _}`). External subscribers to these events must retag
    their receives.
  - The public low-level API moves from `hackney_quic:` to `hackney_h3:`
    (`connect/4`, `send_request/3`, `send_data/4`, `reset_stream/3`,
    `close/2`, `process/1`).
  - `hackney_qpack.erl` removed (~622 LOC); the QPACK codec lives in
    `quic_qpack` in the `quic` dependency.
  - H3 `peername`/`sockname`/`peercert` are wired through the underlying
    `quic` connection and work the same as for HTTP/1.1 and HTTP/2.
    `setopts` still returns `{error, not_supported}` since QUIC has no
    `{active, once}`-style socket model.
- `rebar.config`: `quic` dependency pinned to hex `1.0.0`.

3.2.1 - 2026-03-01
------------------

### Bug Fixes

- Fix `recv_timeout` option being ignored for pooled connections (#832)
- Fix off-by-one error in HPACK decoding (#831)
- Fix invalid match in `handle_h2_frame/2` for HTTP/2 window updates (#829)
- Fix binary syntax in EDoc comment to fix XML parsing error

3.2.0 - 2026-02-21
------------------

### Refactor

- Replace all cowlib modules with hackney-native implementations
  - `hackney_cow_http2_machine` → `hackney_http2_machine` (with optimizations)
  - `hackney_cow_http2` → `hackney_http2`
  - `hackney_cow_deflate` → `hackney_deflate`
  - `hackney_cow_ws` → `hackney_ws_proto`
  - `hackney_cow_hpack_dec_huffman_lookup.hrl` → `hackney_hpack_huffman_dec.hrl`
  - Remove `hackney_cow_hpack` (already replaced by `hackney_hpack`)
- Remove `src/libs/` directory (all modules moved to `src/`)

### Performance

- HTTP/2 state machine optimizations:
  - Stream caching for recently accessed streams
  - gb_sets for lingering streams (O(log N) vs O(N) lookups)
  - IOList accumulation for header fragments
- HPACK and QPACK header compression with O(1) static table lookups
- WebSocket: use `rand:bytes/1` instead of `crypto:strong_rand_bytes/1` for mask keys

### Added

- h2spec HTTP/2 compliance testing (95% pass rate - 139/146 tests)
  - `h2spec_server.erl`: Minimal HTTP/2 server for compliance testing
  - `h2spec_SUITE.erl`: CT suite for running h2spec tests
  - Makefile target: `make h2spec-test`
- HTTP/3 E2E tests against real servers
  - `hackney_http3_e2e_SUITE.erl`: Tests against Cloudflare, Google, quic.tech
  - Makefile targets: `make http3-e2e-test`, `make all-e2e-test`
- HTTP/2 machine benchmarks (`hackney_http2_machine_bench.erl`)

### Bug Fixes

- Fix HTTP/2 flow control for body sending (use `send_or_queue_data/4`)
- Fix async 204/304/HEAD responses not sending `done` message
- Fix unknown HTTP/2 frame types not being ignored (RFC 7540 4.1)
- Fix HTTP/2 frame size validation

3.1.2 - 2026-02-21
------------------

### Dependencies

- Bump `quic` dependency to 0.10.2

3.1.1 - 2026-02-20
------------------

### Bug Fixes

- Fix HTTP/3 Fin flag handling for HEAD requests and responses without body
- Bump `quic` dependency to 0.7.1 (fixes packet number reconstruction)

### Added

- Add TLS options support in `hackney_quic` (verify, cacerts, cacertfile, SNI)
- Add redirect following in `hackney_h3` (follow_redirect, max_redirect options)
- Add HTTP/3 integration and redirect test suites (36 new tests)

3.1.0 - 2026-02-17
------------------

### Refactor

- Replace QUIC NIF with pure Erlang implementation. HTTP/3 now works with zero external dependencies - no CMake, Go, or C compiler needed. Just `rebar3 compile`.

### Removed

- Remove c_src/ directory containing lsquic, BoringSSL, and NIF code (~1.3M lines of C)
- Remove do_cmake.sh and do_quic.sh build scripts

### Added

- Add `hackney_qpack.erl` for QPACK header compression (RFC 9204)

### Changed

- `hackney_quic:is_available/0` now always returns `true` (pure Erlang is always available)
- Update documentation to reflect no C dependencies

3.0.3 - 2026-02-15
------------------

### Bug Fixes

- Restore function-based streaming body support (#821). Functions passed to `send_body/2` now work correctly for iterative body streaming, supporting both stateless `fun() -> {ok, Data} | eof` and stateful `fun(State) -> {ok, Data, NewState} | eof` forms.

### CI

- Fix FreeBSD CI job by adding pcre2 package to resolve git linker error

3.0.2 - 2026-02-02
------------------

### Bug Fixes

- Add default `Content-Type: application/octet-stream` header when sending a body without explicit Content-Type (#823). This restores 1.x behavior and follows RFC 7231 recommendations.

### Dependencies

- Bump `certifi` to 2.16.0 (#824)

3.0.1 - 2026-01-28
------------------

### Bug Fixes

- Fix dialyzer warning in `follow_redirect` by removing dead code branch that checked `is_pid()` on a value that was always binary
- Store final redirect location in connection process state so it can be retrieved via `hackney:location/1`
- Clean up `request_ret()` type spec to accurately reflect return values

3.0.0 - 2026-01-27
------------------

### BREAKING CHANGES

This is a major release with breaking changes to the high-level API. See [Migration Guide](guides/MIGRATION.md) for detailed upgrade instructions.

#### Response Format Change

The high-level API now returns the response body directly in the tuple, consistent across all protocols (HTTP/1.1, HTTP/2, HTTP/3):

```erlang
%% Before (2.x) - HTTP/1.1
{ok, 200, Headers, ConnPid} = hackney:get(URL),
{ok, Body} = hackney:body(ConnPid).

%% After (3.x) - All protocols
{ok, 200, Headers, Body} = hackney:get(URL).
```

#### Removed Functions

The following deprecated functions have been removed:

| Function | Replacement |
|----------|-------------|
| `hackney:body/1` | Body returned directly in response tuple |
| `hackney:body/2` | Body returned directly in response tuple |
| `hackney:stream_body/1` | Use async mode with `[async]` or `[{async, once}]` |
| `hackney:skip_body/1` | Not needed - body always consumed |

#### Security: Cross-Host Redirect Behavior (CVE-2018-1000007)

Authorization headers and credentials are no longer forwarded when following redirects to a different host. This prevents credential leakage when a server redirects to an untrusted host.

To restore the previous behavior (not recommended), use the `location_trusted` option:

```erlang
hackney:get(URL, [], <<>>, [{location_trusted, true}]).
```

### New Features

- **HTTP/3 enhancements**: Added `peername/1`, `sockname/1`, `peercert/1`, and `setopts/2` support for HTTP/3 connections
- **HTTP 1xx informational responses**: Support for handling 103 Early Hints and other informational responses
- **Native metrics with Prometheus**: Pluggable metrics backend with built-in Prometheus support

### Migration

For streaming responses, migrate to async mode:

```erlang
%% Async streaming (push-based)
{ok, Ref} = hackney:get(URL, [], <<>>, [async]),
receive {hackney_response, Ref, {status, 200, _}} -> ok end,
receive {hackney_response, Ref, {headers, Headers}} -> ok end,
%% Receive body chunks until done

%% On-demand streaming (pull-based)
{ok, Ref} = hackney:get(URL, [], <<>>, [{async, once}]),
%% Call hackney:stream_next(Ref) to receive each chunk
```

See [Migration Guide](guides/MIGRATION.md) for complete migration instructions.

---

2.0.1 - 2026-01-21
------------------

### Dependencies

- Remove `unicode_util_compat` dependency (stdlib has `unicode_util` since OTP 20)
- Bump `idna` to 7.1.0
- Replace `string_compat` calls with stdlib `string` module functions

2.0.0 - 2026-01-20
------------------

This release finalizes the 2.0 architecture with many bug fixes and new features since beta.1.

See [Migration Guide](guides/MIGRATION.md) and [Design Guide](guides/design.md) for details.

### New Features

- **HTTP 1xx informational responses** (#631) - Support for handling 103 Early Hints and other informational responses
- **HTTPS proxy support** (#795) - Full support for proxying through HTTPS proxies
- **Proxy authentication callback** (#799) - New `proxy_auth_fun` option for custom proxy authentication logic
- **CONNECT response callback** (#798) - New `on_connect_response` callback to inspect CONNECT proxy response headers
- **SSL peer certificate** (#599) - New `hackney:peercert/1` function to get the peer's SSL certificate

### New Options

- `auto_decompress` - When `true`, automatically decompresses gzip/deflate responses (#155):
  ```erlang
  {ok, Status, Headers, Body} = hackney:request(get, URL, [], [],
      [{with_body, true}, {auto_decompress, true}]).
  ```
- `stream_to` - For async requests, the `stream_to` process is now set as the connection owner (#646). If `stream_to` dies, the connection terminates; if the original caller dies, the connection continues as long as `stream_to` is alive.
- `proxy_auth_fun` - Callback function for custom proxy authentication
- `on_connect_response` - Callback to receive CONNECT proxy response headers

### New Functions

- `hackney:peercert/1` - Get the peer's SSL certificate from a connection

### Bug Fixes

- fix: handle non-HTTP URL schemes properly (#468)
- fix: force connection close for 204/304 responses (#434)
- fix: sanitize header values to prevent HTTP header injection (#506)
- fix: filter Host header for HTTP/2 requests (send as `:authority` pseudo-header)
- fix: handle non-standard decimal status codes (#697)
- fix: remove parse_trans from runtime dependencies (#714)
- fix: handle race condition in get_protocol calls
- fix: strip auth credentials on cross-host redirects (#701)
- fix: tolerate trailing semicolons in parameter parsing (#618)
- fix: handle @ symbols in URL credentials per RFC 3986 (#657)
- fix: properly resolve relative redirect URLs per RFC 3986 (#711)
- fix: detect server-initiated closes on idle pooled connections (#544)
- fix: respect recv_timeout during proxy CONNECT handshake
- fix: prevent SOCKS5 and HTTP CONNECT tunnels from being pooled (#797)
- fix: auto-release connections to pool when body reading completes (connection leak fix)

### Security

- Header injection prevention (#506) - Header values are now sanitized to prevent CRLF injection attacks
- Auth credential stripping (#701) - Authorization headers and credentials are stripped when redirecting to a different host

---

2.0.0-beta.1 - 2026-01-07
-------------------------

Process-per-connection architecture. Each connection is a `gen_statem` process.

See [Migration Guide](guides/MIGRATION.md) and [Design Guide](guides/design.md) for details.

### HTTP/3 Support

Full HTTP/3 support via QUIC (requires QUIC NIF to be built):

- **QUIC transport** - UDP-based, encrypted by default with TLS 1.3
- **Transparent API** - Same `hackney:get/post/request` functions work for HTTP/3
- **Multiplexing** - Multiple streams without head-of-line blocking
- **Alt-Svc discovery** - Automatic HTTP/3 endpoint detection from Alt-Svc headers
- **Connection pooling** - HTTP/3 connections shared across callers
- **Negative caching** - Failed H3 attempts cached to avoid repeated failures
- **Async streaming** - `{async, true/once}` for push-based streaming
- **Pull-based streaming** - `hackney:stream_body/1` for chunked reads
- **Streaming uploads** - `send_body/2` for chunked uploads
- **Protocol selection** - Use `{protocols, [http3]}` to force HTTP/3

Check availability with `hackney_quic:is_available()`.

See [HTTP/3 Guide](guides/http3_guide.md) for details.

### HTTP/2 Support

Full HTTP/2 support with automatic protocol negotiation:

- **ALPN negotiation** - HTTP/2 is automatically negotiated during TLS handshake
- **Transparent API** - Same `hackney:get/post/request` functions work for both protocols
- **Multiplexing** - Multiple requests share a single HTTP/2 connection
- **Header compression** - HPACK compression for reduced overhead
- **Flow control** - Automatic window management with WINDOW_UPDATE frames
- **Server push** - Optional support for server-initiated streams
- **Protocol selection** - Use `{protocols, [http2]}` or `{protocols, [http1]}` to force protocol

See [HTTP/2 Guide](guides/http2_guide.md) for details.

### Architecture Changes

- Connection handle is now a PID (was opaque reference)
- `hackney_conn` manages connections (replaces hackney_connect, hackney_connection, hackney_request, hackney_response, hackney_stream)
- `hackney_headers` renamed from `hackney_headers_new`
- Clean OTP supervision tree with `hackney_conn_sup`

### Pool Redesign

The connection pool has been completely redesigned:

- **Per-host connection limits** - Each host gets up to `max_per_host` concurrent connections (default 50), replacing the global pool limit
- **TCP-only pooling** - SSL connections are never pooled (security improvement). HTTPS requests upgrade pooled TCP connections to SSL
- **Connection prewarm** - Pool maintains warm TCP connections per host (default 4) after first use
- **Load regulation** - New `hackney_load_regulation` module provides lock-free per-host backpressure using ETS counting semaphore
- **Keepalive timeout capped** - Maximum 2 seconds idle time to prevent stale connections
- **Host stats API** - New `hackney_pool:host_stats/3` for per-host monitoring

### New Options

- `default_protocols` - Default protocol preference order (default: `[http3, http2, http1]`). Set via application env to change globally:
  ```erlang
  application:set_env(hackney, default_protocols, [http2, http1]).
  ```
- `max_per_host` - Maximum concurrent connections per host (default 50)
- `checkout_timeout` - Timeout to acquire connection slot (default 8000ms)
- `prewarm_count` - Warm connections per host (default 4)

### New Functions

- `hackney_util:default_protocols/0` - Get the default protocol preference list
- `hackney:get_version/0` - Get hackney version
- `hackney_pool:host_stats/3` - Get per-host connection stats
- `hackney_pool:prewarm/3,4` - Explicitly prewarm connections to a host
- `hackney_load_regulation:current/2` - Get current connection count for host

### Removed

- `cancel_request/1` - use `close/1`
- `controlling_process/2` - not needed
- `send_multipart_body/2` - use `send_body/2`
- SOCKS5 and HTTP CONNECT proxy (planned 2.1.0)

### Security

- **BREAKING**: Authorization credentials and cookies are no longer sent on cross-host redirects by default (CVE-2018-1000007). This prevents credential leakage when a server redirects to a different host (e.g., API redirecting to S3). To restore the old behavior, use `{location_trusted, true}` option (similar to curl's `--location-trusted`).

### Bug Fixes

- fix: validate connection state on pool checkout for HTTP/2 and HTTP/3. On FreeBSD + OTP 28, pooled connections could be in `closed` state when checked out due to SSL timing differences, causing `{error, invalid_state}` errors. Now connections are verified to be in `connected` state after checkout.

### Metrics

Native metrics system with pluggable backends, replacing the external `metrics` library dependency:

- **Pluggable backends** - `hackney_metrics_backend` behaviour for custom implementations
- **Dummy backend** (default) - Zero-overhead no-op backend when metrics not needed
- **Prometheus backend** (opt-in) - Full Prometheus integration when enabled
- **Correct metric types** - Pool counts now use gauges instead of histograms (#560)

#### Prometheus Metrics

When enabled, the following metrics are exported:

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `hackney_requests_total` | Counter | host | Total requests started |
| `hackney_requests_active` | Gauge | host | Currently active requests |
| `hackney_requests_finished_total` | Counter | host | Completed requests |
| `hackney_request_duration_seconds` | Histogram | host | Request duration in seconds |
| `hackney_pool_free_count` | Gauge | pool | Available connections in pool |
| `hackney_pool_in_use_count` | Gauge | pool | Connections currently in use |
| `hackney_pool_checkouts_total` | Counter | pool | Total connection checkouts |

#### Configuration

```erlang
%% Default: dummy backend (zero overhead)
%% To enable Prometheus metrics:
{hackney, [{metrics_backend, prometheus}]}
```

### Requirements

- Erlang/OTP 27+

1.25.0 - 2025-07-24
-------------------

** IMPORTANT CHANGE **

- change: `insecure_basic_auth` now defaults to `true` instead of `false`
  
  This restores backward compatibility with pre-1.24.0 behavior where basic auth 
  was allowed over HTTP connections. If you need strict HTTPS-only basic auth:
  - Set globally: `application:set_env(hackney, insecure_basic_auth, false)`
  - Or per-request: `{insecure_basic_auth, false}` in options

1.24.1 - 2025-05-26
-------------------

- fix: remove unused variable warning in hackney.erl

1.24.0 - 2025-05-26
-------------------

- security: fix basic auth credential exposure vulnerability
- security: add application variable support for insecure_basic_auth
- fix: NXDOMAIN error in Docker Compose environments (issue #764)
- fix: stream_body timeout after first chunk (issue #762)
- fix: SSL hostname verification with custom ssl_options and SSL message leak in async streaming
- fix: pool connections not freed on 307 redirects and multiple pool/timer race conditions
- fix: socket leaks, process deadlocks, ETS memory leaks, and infinite gen_server calls
- fix: controlling_process error handling in happy eyeballs and connection pool return
- improvement: update GitHub Actions to ubuntu-22.04 and bump certifi/mimerl dependencies

1.23.0 - 2025-02-25
-------------------

- fix: happy eyeball use correct timeout during connection
- fix: don't wrap connection error
- improvement: only spawn ipv6 worker when needed

1.22.0 - 2025-02-20
-------------------

- feature: prefer to connect using IPv6. happy eyeball strategy
- improvement: fully support no_proxy environment variable
- doc: migrated to ex_doc


1.21.0 - 2025-02-20
-------------------

- fix: remove SSL options incompatible with tls 1.3
- fix: url parsing handle "/" path correctly
- fix: simplify integration test suite
- fix: handle chunked response in redirect responses
- fix: handle http & https proxies separately
- fix: skip junk lines in 1.xx response

** security fixes ***

- fix URL parsing to prevent SSRF . (related to CVE-2025-1211)
- use latest SSL certificate bundle


1.20.1 - 2023-10-11
-------------------

- fix multipart: handle case where Length is undefined

1.20.0 - 2023-10-10
-------------------

- handle `*` in path encoding
- Support LF separators: since rfc7230-3.5 allows for LF-only
- fix recv stream fix fetching trailers during streaming
- fix CI
- Improve documentation

1.19.1 - 2023-09-21
-------------------

- feature: add `no_proxy_env` option to bypass proxy environment settings

1.19.0 - 2023-09-20
-------------------

- fix: recv: if expected size < BufSize fallback to old behaviour. Fix issue with negative length
- feature: add support for proxy environment setting

1.18.2 - 2023-08-29
-------------------

- security: update default CA bundles


1.18.1 - 2022-02-03
-------------------

- security: update default CA bundles
- doc: fix typos


1.18.0 - 2021-09-28
-------------------

- security: update default CA bundle
- fix pool: make checkout synchronous (remove unwanted messages)

1.17.4 - 2021-03-18
-------------------

- fix checking when socket is put back in the pool when the requester died.

1.17.3 - 2021-03-17
-------------------

- fix: ensure we release a socket in the pool when the requester died before being monitored.

1.17.2 - 2021-03-16
-------------------

- use parse_trans 3.3.1 only (fix compatibility with Erlang < 21)
- bump certifi version
- Allow merging of SSL opts

1.17.1 - 2021-03-15
-------------------

- fix: Avoid `parse_trans` warning when using hackney as a dependency
- fix: Link checkout process to fix dangling aborted request

1.17.0 - 2020-12-19
-------------------

- fix SSL compatibility with erlang OTP 23
- handle empty trailers
- fix race condition in connection pool
- fix memory leak in connection pool
- IDNA update to unicode 13.0.0
- fix build on macosx with OTP >= 20.1
- fix network Location on redirect
- produce uppercase hexadecimal in URLS
- pool queue count metric is now named `queue_count`
- miscellaneous fixes in documentation


** possible breaking change **

- pool queue count metric is now named `queue_count`. You should update your dashboard to reflect it.

- possible breaking changes when producing uppercase hexadecimal in urls

This change the behaviour of urlencode and pathencode to produce
uppercase hexadecimal to comply to the RFC3986 which may affect
systems using URL as signature or in an hash.

1.16.0 - 2020-05-25
-------------------


- pool: cache connection IDs
- pool: make sure to reuse a connection if the options match the one given in the request. fix usage with proxy and ssl
  connections
- url: handle fragment correctly, a fragment is parsed first to not be mistaken with an URL
- ssl: fix validation with Erlang 19 & Erlang 20
- ssl: handle tlsv1.3 on Erlang OTP 23
- ssl: increase validation depth to match openssl default
- ssl: optimiaz partial chain handling
- ssl: fix hostname checking and correctly handle SNI
- ssl: fix ciphers
- request: fix regression with fully fqdn
- ssl: fix usage with OTP 23
- url: decode username/password for basic auth parameters
- request: do not normalize when converting relative redirect to absolute
- ssl: update to certifi 2.5.2
- request: handle Connection: close response header for stteam
- http: handle leading new lines in HTTP messages
- http: handle trailers in persistent connection
- pool: update pool timeout documentation
- url: fix urlencode

1.15.2 - 2019-09-25
-------------------

- doc: fix test run example in readme
- fix: hackney stream, send `hackney_response` before calling `handle_error`
- fix: error remove ssl `honor_cipher_order` option
- doc: document self-signed certificate usage
- bump `ssl_verify_fun` to 1.1.5
- fix: don't use default pool if set to false
- fix: `hackney_headers:store/3`  fix value appending to a list
- fix: miscellaneous specs
- doc: miscellaneous improvements


1.15.1 - 2019-02-26
-------------------

- fix: don't try to encode to IDN with full ASCII names.

> this behaviour is similar to curl and fix errors some people had with docker
> creating domain names containing a `_`

- doc: clarify `recv_timeout` usage
- fix: don't try to encode hostname IPs to IDN
- fix: path encoding to support `(` `)` characters
- bump mimerl to 1.2
- bump certifi to 2.5.1


1.15.0 - 2019-01-04
-------------------

- improve multipart: send form with a field names for files
- fix pool `checkout_cancel`: reduce the number of pending requests

1.14.3 - 2018-09-29
-------------------

- idna: don't try to encode a unix socket path

1.14.2 - 2018-09-28
-------------------

- fix: don't IDNA encode the host with unix scheme
- doc: document `basic_auth` setting

1.14.0 - 2018-09-12
-------------------

- bump to certifi 2.4.2
- bump to idna 0.6.0
- fix support of rebar2
- fix specs
- add `hackney:sockname/1` and `hackney:peername/1` functions
- add new `checkout_timeout` option for clarity
- improve `hackney_url:parse_qs/1` to trim leading and trailing empty values


1.13.0 - 2018-06-22
-------------------

- fix compatibility with Erlang/OTP 21
- fix parsing query parameters on url without path (#512)
- bump idna to 1.5.2: fix compatibility with rebar2 (#509)
- fix accessing HTTPS sites with an IP address (#494)

1.12.1 - 2018-04-03
-------------------

- fix terminate_async_response (#498)

1.12.0 - 2018-04-03
-------------------

- fix socks5 badarg error when an IP is given
- upgrade IDNA to 5.1.1
- upgrade certifi to 2.3.1
- fix handling of requests with content-length or transfer-encoding given (#475)
- improvements: send SNI in socks5 SSL
- fix:  Allow trailing spaces at the end of chunk sizes (#489)
- fix: set once the metrics engine
- fix leak in the socket pool (#462)
- fix doc

1.11.0 - 2018-01-23
-------------------

- add: send SNI for Erlang >= 17
- fix: better handling of stream exits in `hackney_manager`
- improvement: remove high priority flag from the pool process
- fix: change when hackney loads the hackney metric module (speed improvement)
- fix: return value from the function `del_from_queue` in connection pool
- fix: handle empty or invalid content-length
- fix: documentation on removed method


1.10.1 - 2017-10-20
-------------------

- improvement: ignore port empty values on redirect (#444)
- fix: fix reference leak introduced in latest version (#445)
- fix: stream termination, don't raise an error on normal exit

1.10.0 - 2017-10-18
-------------------

- fix owner tracking (#443)
- fix: fix deadlock in `hackney_pool` during request timeout (#420)
- fix: set PoolHandler on connect (#427)
- fix: fix unicode in include file (#426)

1.9.0 - 2017-07-30
------------------

- security: certifi 2.0.0
- dependency: update idna 5.1.0 (fix windows build and usage with elixir)
- doc: fix typo `hackney_multipart` doc (#422)

1.8.6 - 2017-06-09
--------------------

- fix: cleanup socket in async request (#411)

1.8.5 - 2017-05-30
------------------

- fix: dialyzer

1.8.4 - 2017-05-28
------------------

- fix: tests
- dependency: update idna  5.0.2 (fix compatibility with erlang R20)

1.8.3 - 2017-05-22
------------------

- security: certifi 1.2.1
- dependency: update idna  5.0.1

1.8.2 - 2017-05-20
------------------

- fix: race condition in controlling process (#407)
- fix: spec of #hackney_url{} (#404)
- fix: make sure to not lost a message during hibernation in async request
- security: certifi 1.2.0
- dependency: update idna  5.0.0

1.8.0 - 2017-04-20
-----------------

- fix: undefined function (#393)
- fix: close connection if proxy handshake failed (#392)
- fix: handle all headers with the new datastructure introduced in 1.7.0 (#395)
- fix: host header when redirect (#400)
- fix: use connect timeout when retrieving from the pool (#402)
- security: new certifi version

1.7.1 - 2017-03-02
------------------

- fix: regression in headers handling (handle different key types)

1.7.0 - 2017-03-01
------------------

- fix: new datastructure to handle headers (#390)
- security: new certifi version

1.6.6 - 2017-02-26
------------------

- fix: fix header appending
- fix: Url encode host header for unix domain sockets (#382)
- security: new certifi version
- doc: fix few typos

1.6.4 - 2016-12-22
------------------

- add: optional urlencode options to qs (#368)
- fix: handle continuation lines in HTTP headers correctly (#366)
- doc: Fix a few documentation typos

1.6.3 - 2016-10-27
------------------

- fix: handle trailing whitespace in header values

1.6.2 - 2016-10-22
------------------

- add: unix sockets support on Erlang > 19
- fix: `hackney_multiprart` for Erlang < 17
- add: new `socks5_resolver` function
- fix: `hackney_util:merge_opts/2`
- improvements: inet6 support in socks5 sockets
- doc: miscellaneous docs fixes
- security: being more strict in ssl support
- security: bump to certifi 0.7

1.6.1 - 2016-07-10
------------------
- fix: close socket on error (#308)
- improvement: handle errors in `hackney_response:wait_status` (#313)
- improvement: make pathencode faster (#317)
- fix: typo (#321)
- fix: elixir 1.4 warnings (#325)

1.6.0 - 2016-03-25
------------------

- add `path_encode_fun` option to request.
- add: allow force non-POST 303 redirects
- use `ssl_verif_fun` dependency to replace `ssl_verify_hostname`
- fix: 	move included_applications to applications
- fix: mix packaging

1.5.4 - 2016-03-18
------------------

- fix support of rebar 3 stable
- add mix package

1.5.0 - 2016-03-02
------------------

- refactor: one flat source
- replace hackney_metrics_* by [metrics](https://github.com/benoitc/erlang-metrics) library
- fix: hackney_pool (#286)
- security: bump to [erlang-certifi](https://github.com/certifi/erlang-certifi) 0.4.0

1.4.10 - 2016/02/27
------------------

- bump to idna 1.1.0
- fix: don't encode @ in urls
- fix: header stream multipart

1.4.7 - 2015/12/07
------------------

- bump to mimerl 1.0.2

1.4.6 - 2015/11/24
------------------

- fix build with mix

1.4.5 - 2015/11/23
------------------

- fix multipart/form parsing (#258)
- TRAVIS-CI build with rebar3

1.4.4 - 2015/11/04
------------------

- fix rebar3 detection

1.4.3 - 2015/11/04
------------------

- fix header value parsing (#256)

1.4.2 - 2015/11/03
------------------

- fix build with rebar2 and Erlang < 17

1.4.1 - 2015/11/03
------------------

- fix build with mix (#255)

1.4.0 - 2015/10/27
------------------

- build using hex.pm & small refactoring
- fix multipart (#245)
- fix redirection (#237)
- fix url parsing (#236)
- close connection when max body length is reached (#248)

1.3.2 - 2015/08/27
------------------

- fix `connect_time metric` (#227)
- fix redirection when `with_body`  is enabled (#228)
- close half-closed socket to avoid leak (#231)
- fix unexpected message in `hackney_stream` (#223)
- fix receive/error in hackney_manager (#232)

1.3.1 - 2015/07/28
------------------

- fix: set default `recv_timeout` to 5s. (#219)
- fix: socks5 fix auth: handle not required case (#218)

1.3.0 - 2015/07/23
------------------

- new add `max_body` setting
- fix: handle partial chains during handshake in HTTPS (#196)

1.2.0 - 2015/06/25
------------------

- new: add `with_body` option to return the body directly (#184)
- fix: rely on ssl version to validate certificates securely using hostname
  verification
- fix: fix redirection when transport change (#177)
- new: build is now using rebar3
- new: updated root certificates
- fix: ignore comma in set-cookie attributes (#193)
- fix: status line parsing when reason phrase is missing entirely (#190)
- fix: make sure the response is done during async streaming (#186)
- fix metrics (#186)
- new: bump latest version of `ssl_verify_hostname` (#175)
- fix: parse server headers
- fix: really honor max redirection (#170)
- fix: handle path parameters in URL (#176)
-

1.1.1 - 2015/03/20
------------------

- fix: fix max redirection (#170)
- fix: don't encode path parameters and unreserved chars. (#176)


1.1.0 - 2015/03/04
------------------

- fix: honor max_redirect.
- fix: socket checkout in the pool: close the socket if something happen while
  passing the control to the client
- fix: put back the waiter in the queue of the pool if no socket can be
  delivered
- fix: make sure we don't release a closed typo
- add: shutdown method to transports
- add: hackney_trace module to trace a request
- add: reuse/new connection metrics
- fix: guard binary in `hackney_multipart:len_mp_stream/2`
- improvement: pass the socket to `hackney:request_info/1`
- dependency: update ssl_verify_hostname
- fix: make sure to pass the Host header to the request
- fix: HTTP basic authentication
- fix content-type case
- improvement: tests

1.0.6 - 2015/01/21
------------------

- improvement: handle {error, closed} for HTTP 1.1 when no content-length is given.
- improvement: handle 204 and 304 status
- fix keep-alive handling
- remove expm package
- build under R18

1.0.5 - 2014/12/12
------------------

- improvement: Do not wait to cancel a request
- improvement: do not control the request preemptively

1.0.4 - 2014/12/8
-----------------

- fix client leaks on error
- fix monitor counters

1.0.3 - 2014/12/5
-----------------

- fix SSL validation under R15 and R14 Erlang versions.
- Apply SSL certificate validation to SOCKS5 and HTTP proxies.

1.0.2 - 2014/12/02
------------------

- fix redirection: rewrite Host header

1.0.1 - 2014/12/01
------------------

- update default certification authority file. Make sure we can validate all SSL
  connections even on the AWS platform.
- fix typo

1.0.0 - 2014/11/30
------------------

hackney 1.0.0 has been released. This is the first stable and long term
supported release of hackney.

- add [metrics](https://github.com/benoitc/hackney#metrics)
- add SSL certificate verification by default.
- fix: Pool handling


0.15.2 - 2014/11/27
-------------------

- fix: handle strings in headers
- fix; convert User/Password as string if needed
- fix: handle body given as an empty list

0.15.1 - 2014/11/26
-------------------

- export `find_pool/1` and allows any poolname.

0.15.0 - 2014/11/11
-------------------

- improve hackney performance and concurrency
- fix pool handling: make sure to reuse the connections

0.14.3 - 2014/10/28
-------------------

- fix `hackney:stop_async/1`

0.14.2 - 2014/10/27
-------------------

- fix memory leak (#77): some requests were not cleaned correctly in
  hackney_manager.
- fix ssl race condition (#130)
- fix: check if relative url contains a forward slash
- refactor integration tests and add more tests
- fix socket pool: make sure to close all sockets when the pool is terminated,
  and do not store closed sockets if we know it.

0.14.1 - 2014/09/24
-------------------

- fix redirect location: make sure we use absolute urls
- fix redirection: make sure to follow redirections
- fix hackney_response:read_body/3 spec
- trim response headers when needed
- add redirection basic tests

0.14.0 - 2014/09/18
-------------------

- fix: validate if the redirection url is absolute.
- fix: return location from headers when possible in
  `hackney:location/1`.
- fix HEAD request. Remove the need to call the body method
- fix: remove undefined function references
- tests: start to handle tests with httpbin

### Breaking change:

When doing an HEAD request, the signature of the response when it
succeeded is now `{ok, Status, ResponseHeaders}` and do not contain a
client reference anymore.


0.13.0 - 2014/07/08
-------------------

- put hackney_lib back in the source code and refactor the source repository
- fix: handle bad socks5 proxy response
  [#113](http://github.com/benoitc/hackney/issues/113)
- fix: handle timeout in hackney_socks4:connect/5
  [#112](http://github.com/benoitc/hackney/issues/112)
- fix: Accept inet6 tcp option for ssl
- fix redirection
- fix: add versions option for ssl

0.12.1 - 2014/04/18
-------------------

- fix: return the full body on closed connections.
- fix: make sure to always pass the Host header.

0.12.0 - 2014/04/18
-------------------

- improvement: URI encoding is now fully normalized.
- improvement: TCP_NODELAY is now available by default for all transports
- improvements: IDNA parsing is only done during the normalization which
  makes all the connections faster.
- fix: connections options are now correctly passed to the transports.
- fix: HTTP proxying. make sure we reuse the connection
- fix: HTTP proxying, only resolve the proxy domain.
- bump [hackney_lib](https://github.com/benoitc/hackney_lib) to 0.3.0

### Breaking change:

the [mimetypes](https://github.com/spawngrid/mimetypes) has been
replaced by the
[hackney_mimetypes](https://github.com/benoitc/hackney_lib/blob/master/doc/hackney_mimetypes.md)
module. It makes content-type detection a little more efficient. In the
process the functions hackney_util:content_type/1 and
hackney_bstr:content_type/1 have been removed. You should now use the
function `hackney_mimetypes:filename/1` .



0.11.2 - 2014/04/15
-------------------

- new improved and more performant IDNA support
- make sure the socket is closed when we skip the body if needed
- fix multipart EOF parsing
- make sure we finish a multipart stream
- bump hackney_lib to 0.2.5
- enable TCP_NODELAY by default. (To disable, pass the option
  `{nodelay, false}` to `connect_options`).

0.11.1 - 2014/03/03
-------------------

- improvement: speed IDNA domains handing
- fix http proxy via CONNECT
- fix: encode the path
- bump to [hackney_lib 0.2.4](https://github.com/benoitc/hackney_lib/releases/tag/0.2.4)

0.11.0 - 2014/03/02
-------------------

- add `hackney:location/1` to get the final location
- make `hackney_request:send/2` more efficient
- fix socket removing in the pool
- fix [HTTP proxying](https://github.com/benoitc/hackney/commit/a21e8802e1dc91c25d863ac6fc5b23a79196efcd)
- support IDNA hostnames

0.10.1 - 2013/12/30
-------------------

- fix multipart file header
- improve the performance when sending a `{multipart, Parts}` body. Send
  it as a stream.
- bump hackney_lib version to 0.2.2

0.10.0 - 2013/12/29
-------------------

- improve multipart handling: With this change, we can now calculate the
  full multipart stream content-length using `hackney_multipart:len_mp_stream/2` .
- add `hackney:setopts/2` to set options to a request when reusing it.
- add `hackney:send_reques/3` to pass new options to a request.
- add the `{stream_to, Pid}` setting to a request to send the messages
  from an asynchronous response to another PID.
- fix `Host` header: some server do not comply well with the spec and
  fail to parse the port when they are listening on 80 or 443. This
change fix it.
- fix: make sure we are re-using connections with asynchronous
  responses.

### Breaking changes:

- All messages from an async response are now under the
  format `{hackney_response, Ref, ... }` to distinct hackney messages
from others in a process easily.
- You can only make an async response at a time. Ie if you are doing
  a persistent request (reusing the same reference) you will need to
pass the async option again to the request. For that purpose the
functions hackney:send_request/3 and hackney:setopts/2 have been
added.
- multipart messages have changed. See the documentation for more
  information.

0.9.1 - 2013/12/20
------------------

- fix response multipart processing

0.9.0 - 2013/12/19
------------------

- add support for multipart responses
- add support for cookies: There is now a `cookie`
option that can be passed to the request. It can be a single cookie or a
list of cookies. To parse cookies from the response a function `hackney:cookies/1` has
been added. It returns all the cookies as a list of [{Key, Value}].
- breaking change: use [hackney_lib](http://github.com/benoitc/hackney_lib)  a web toolkit to handle the HTTP protocol and other manipulations.
- optimization: send body and headers together when it is possible
- fix release handling

0.8.3 - 2013/12/07
------------------

- add: support redirection in async responses
- improve
  [hackney_url:make_url/3](https://github.com/benoitc/hackney/commit/a545d266106c0557374a8b9b13caa63ce89e86f2)
- fix: handle case where the response is already done in async responses

0.8.2 - 2013/12/05
------------------

- fix: trap exits in hackney_manager

0.8.1 - 2013/12/04
------------------

service release with a new feature and some minor improvements

- added the support for [socks5
  proxies](https://github.com/benoitc/hackney#socks5-proxy)
- improvement: integer and atom can now be passed in url params or forms
  values.
- breaking change: differentiate connect/recv timeout, now connect
  timeout return `{error, connect_timeout}`

0.8.0 - 2013/12/02
------------------

major release. With this release the API will not evolve much until the
1.0 release sometimes in january.

- breaking change: hackney now return a reference instead of an opaque record. The
  information is maintained in an ETS table. The same reference is now
used for async response requests.
- breaking change: `stream_body_request/2` and `stream_multipart_request/2` functions has
  been renamed to `send_body/2` and `send_multipart_body/2` .
- breaking change: remove `hackney:close_stream/1` function. You only need to
  use `hackney:close/1` now.
- breaking change: rename `hackney:raw/1` function to
  `hackney:cancel_request/1`.
- breaking change: the hackney pool handler based on dispcount is now
  available in its [own repository](https://github.com/benoitc/hackney_disp) so hackney doe  not depends on dispcount.
- fix: canceling and closing a request now make sure the async response
  process is killed.
- fix: make sure we pass a `Transfer-Encoding: chunked` header when we
  send a body without content-length.
- fix: make sure the client is correctly reconnected when we reuse a
  reference.

0.7.0 - 2013/11/22
------------------

- add new Loadbalance pool handler based on dispcount
- allows to set the pool handler
- breaking change: remove `hackney:start_pool/2` and
  `hackney:stop_pool/1`, use instead `hackney_pool:start_pool/2` and
  `hackney_pool:stop_pool/1`
- breaking change: A pool is now used by default
- breaking change: The `hackney_form` module has been removed. You can
  now encode/parse a form using the functions in the `hackney_url` module.
- deprecate `pool_size` and replace it by `max_connections`
- fix: apply applications defaults to the pool


0.6.1 - 2013/11/21
------------------

- doc: Fix the asynchronous response example in the readme
- add hackney_url:make_url/3, hackney_url:qs/1, hackney_url:parse_qs/1 functions

0.6.0 - 2013/11/21
------------------

- add the possibility to get an asynchronous response
- add support for the "Expect: 100-continue" header
- add hackney:controlling_process/2 to pass the control of an hackney context to another process

0.5.0 - 2013/11/06
------------------

- fix: proxied connections
- fix: correct the path passed to a request
- fix: multipart forms
- fix: Make sure that the controller process of the socket is the pool process when the socket is in the pool
- fix: auth header when the user is not given

0.4.4 - 2013/08/25
------------------

- fix: doc typos
- fix: dialyzer errors
- fix: add mimetypes to the list of loaded applications
- fix: test.ebin example

0.4.3 - 2013/08/04
------------------

- removed parse_transform, the REST API is now available at the compilation.
fix: fix file upload content type
- doc: fix typos

0.4.2 - 2013/06/10
------------------

- handle `identity` transfer encoding. When the connection close return
  latest buffer.

0.4.1 - 2013/06/10
------------------

- Body can be passed as a
  [function](https://github.com/benoitc/hackney/commit/efd877f52733ccecf0ba1b5ed10783fe29d49b74)
- Add recv_timeout option
- Fix HEAD request (don't stream the body)
- Don't pass the Port to the Host header if it's default (http, https)
- Set the connection timeout
- Make sure sendfile correctly handle chunked encoding
- Add support for partial file uploads
- Return received buffer when no content length is given (http 1.0)
- Instead of returning `{error, closed}`, return `{error, {closed,
  Buffer}}`  when you receive the body, so you can figure what happened
and maybe use the partial body.

0.4.0 - 2012/10/26
------------------

- Allows to stream a multipart request
- Add `insecure` option to connect via ssl without verifying an SSL
  certificate
- Handle empty headers values
- Add `force_redirect` option
- Add expm support
- Fix body streaming
- Fix SSL handling
- Fix hackney:request/3 (no more loop)


0.3.0 - 2012/09/26
------------------

- Add Multipart support
- Add HTTP Proxy tunneling support
- Fix Chunked Response decoding

0.2.0 - 2012/07/18
------------------

- Allows the user to use a custom function to stream the body
- Add the possibility to send chunked requests
- Add an option to automatically follow a redirection
- Allows the user to force hackney to use the default pool

0.1.0 - 2012/07/16
------------------

- initial release
