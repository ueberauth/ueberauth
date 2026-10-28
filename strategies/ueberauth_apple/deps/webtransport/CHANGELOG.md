# Changelog

## 0.4.8 - 2026-10-03

- Payloads larger than one HTTP/2 DATA frame are no longer truncated on h2.
  A WT_STREAM capsule carries a whole `send/4` payload and h2 splits it into
  16 KiB frames, but the CONNECT-stream reader decoded each frame on its own
  and dropped the partial tail. The reader now carries the tail over to the
  next frame. A single capsule over 64 MiB closes the session.
- Sends larger than the per-stream window no longer lose data. The stream
  cut the payload at its window (256 KiB by default), kept the rest in a
  buffer nothing drained, and still sent FIN. On h3 the WebTransport window
  is now unbounded, since QUIC does the flow control there. On h2 the bytes
  that do not fit are queued in order, FIN waits until the queue drains, and
  the queue is flushed when the peer raises `WT_MAX_DATA` or
  `WT_MAX_STREAM_DATA`.
- The h2 receiver now returns flow-control credit: once half of a stream or
  session window is consumed it sends `WT_MAX_STREAM_DATA` or `WT_MAX_DATA`.
  Before, a peer that honoured our windows stalled for good after 256 KiB
  on a stream or 1 MiB on a session.
- New tests: a 1 MiB bidi echo on both transports, and unit tests for the
  frame reassembly.
- The per-connection router reaper no longer crashes with `badarg` when the
  `webtransport_routers` table is already gone, which happens when an
  embedder stops its listener while connections are still closing.
- Closing a session whose transport is already gone no longer crashes the
  session with `noproc`. The stream resets and the CLOSE_SESSION send are
  skipped when the connection process has exited, so `close_session/1`
  always completes.

## 0.4.7 - 2026-09-24

- Bump `quic` dep to 2.0.0, constraint `~> 2.0`.
- Lock `h2` to 0.12.3 (constraint unchanged, `~> 0.12`).
- A connection that closes while a client waits for its CONNECT response is
  reported again. quic 2.0.0 always sends the close reason with the event,
  and the receive only matched the older shape without one, so the close was
  not seen and the caller waited out its timeout. Both shapes are matched.

## 0.4.6 - 2026-09-21

- Bump `quic` dep to 1.10.0. The constraint is now `~> 1.10` (1.10 and up
  within 1.x) instead of a patch-pinned `~> 1.8.0`, so a project can take
  newer quic releases without a webtransport release. Picks up the RFC 9002
  loss detection and recovery rework, connection ID binding to paths, and the
  1.9 fixes for multi-datagram Initial flights and frames that waited for the
  next event after the handshake. No source changes needed.

## 0.4.5 - 2026-08-12

- Bump `h2` dep to 0.12.0. The constraint is now `~> 0.12` (0.12 and up within
  0.x) instead of a patch-pinned `~> 0.12.0`. Picks up `h2:serve_socket/2` for
  embedders owning their own TLS listener, and moves the TLS handshake into the
  per-connection process so a stalled client no longer blocks the acceptor
  queue. `start_server/2` behaviour is unchanged; no source changes needed.

## 0.4.4 - 2026-08-06

- Bump `quic` dep to 1.8.0 (`~> 1.8.0`, locked at 1.8.0). Picks up RFC 6125
  wildcard SAN matching for client hostname checks, Happy Eyeballs backlog
  delivery on the winning attempt, Retry packet-number continuity, Version
  Negotiation handling, and a `max_udp_payload_size` that reflects what we
  accept rather than the probing ceiling.
- Bump `h2` dep to 0.11.0 (`~> 0.11.0`, locked at 0.11.0). Adds
  `h2:peername/1`.

## 0.4.3 - 2026-07-06

- Bump `quic` dep to 1.7.0 (`~> 1.7.0`, locked at 1.7.0).

## 0.4.2 - 2026-07-05

- Bump `h2` dep to 0.10.4 (`~> 0.10.4`, locked at 0.10.4).

## 0.4.1 - 2026-06-14

- Bump `h2` dep to 0.10.1.
- Accept patch releases of deps via `~>` constraints: `h2 ~> 0.10.1`,
  `quic ~> 1.6.5` (locked at 0.10.1 / 1.6.5).

## 0.4.0 - 2026-06-12

- Bump `quic` dep to 1.6.5.
- Per-SNI certificate selection. Listeners accept an `sni_callback` option
  (`fun((ServerName) -> {ok, #{cert, key, cert_chain}} | {error, _})`) that
  picks the server certificate per ClientHello SNI (RFC 6066 §3), so one
  listener can present different certs per hostname. For h3 the callback is
  forwarded to `quic`; for h2 it is adapted to an `ssl` `sni_fun`. A callback
  error fails the handshake on both transports. When a client sends no SNI, h2
  serves the static `certfile`/`keyfile` (ssl never calls the callback) while
  h3 invokes the callback with `undefined`.
- Test: SNI round-trip on both h3 and h2 groups.

## 0.3.3 - 2026-06-10

- Bump `h2` dep to 0.9.0.

## 0.3.2 - 2026-06-05

- Bump `quic` dep to 1.6.4.

## 0.3.1

- Bump `quic` dep to 1.6.3.

## 0.3.0

- Bump `quic` dep to 1.6.2, `h2` dep to 0.8.0.
- IPv6: listeners bind via `ip` / `family` (h3 and h2); clients accept IP-literal hosts and `inet:ip_address()` tuples, with `family` / `happy_eyeballs` / `connection_attempt_delay` controls (h3). IPv6 literals are bracketed in the `:authority` header.
- `webtransport:listener_sockname/1` returns the bound `{Ip, Port}` (also surfaced as `sockname` in `listener_info/1`). Resolved from the socket for h3; best-effort (requested addr + bound port) for h2, which exposes only the port.
- 0-RTT: session-ticket capture (`{webtransport, session_ticket, _}` to the connecting process) and connection-level acceptance reporting via `webtransport:early_data_accepted/1`. The `session_ticket` connect option plumbs a stored ticket through to QUIC. Full 0-RTT resumption is not yet supported through the synchronous connect path.
- Tests: IPv6 round-trip (h3 + h2), sockname, and session-ticket capture.

## 0.2.6

- Fix: failed h3 `connect/4` no longer leaks its per-connection router. The router is `start_link`'d to the caller but traps exits, so the caller link never reaped it; `connect_h3` now stops it on the connect-failure path, and closes the H3 connection (which reaps the router via its monitor) when the session fails to start.
- Fix: the h2 CONNECT-stream data loop now monitors both the h2 connection and the session and exits on either `'DOWN'`, instead of blocking forever if the connection dies without a `closed` message or the session goes away. Server and client now spawn it the same way.
- Bound the router `open_bidi_stream` call (was `infinity`) so an unresponsive H3 connection cannot stall the session process.
- Tests: regressions for the router leak and the data-loop termination.

## 0.2.5

- Bump `quic` dep to 1.4.5, `h2` dep to 0.6.1.
- OTP 29 support: replace deprecated `catch Expr` expressions with `try ... catch ... end` (`webtransport_h2`, `webtransport_session`, `webtransport`).
- CI: add OTP 28 and 29 to the test matrix; bump rebar3 to 3.25.0.

## 0.2.4

- Bump `quic` dep to 1.4.2.

## 0.2.3

- Embedding (h3): `accept/4` now works when called from a process other than the QUIC connection process. The per-connection stream router is keyed by the QUIC connection pid, shared by the `h3_settings/1` connection_handler and by `accept/4` (via `quic_h3:get_quic_conn/1`), instead of the caller's process dictionary. Incoming bidi/uni streams and datagrams now reach the session even when the embedder dispatches each request to its own worker (e.g. Livery). The router's registry row and process are reaped when its QUIC connection ends.
- CT: `embedded_accept_round_trip_test` (h3) drives a raw `quic_h3` server with `h3_settings/0` merged in, accepts from a worker process, and asserts that a bidi stream (with FIN) and a datagram both round-trip through the echo handler.

## 0.2.2

- Docs: README gains a Sponsors section (Enki Multimedia logo vendored under `docs/images/`).
- Docs: fix invalid `webtransport:open_stream(Session, bidi | uni)` snippet — type-union pipe was in expression position; now `bidi  %% or uni`.
- CT: cover `listeners/0`, `listener_info/1`, and `start_listener/2` cert/key error paths (`webtransport.erl` line coverage 51% → 54%).

## 0.2.1

- `start_listener/2` (h3): switch the listener loop from `spawn_link/3` to `spawn/3` so `stop_listener/1` no longer propagates a `shutdown` exit to the caller. The interactive shell (and any non-trapping caller) now stays clean across a full lifecycle.
- `webtransport_session:init/1`: distinguish a handler module that fails to load (`{handler_not_loaded, M, Reason}`) from a loaded module missing `init/2` or `init/3`.
- README: quick-start now launches the shell with `ERL_FLAGS="-pa examples" rebar3 shell --apps webtransport` so handler modules outside `src/` are reachable.
- Regression test: `stop_listener_does_not_kill_caller_test` (h3 + h2 groups).

Known issue (tracked upstream in `quic`): a graceful `close_session/1` still emits a `quic_h3_connection` `quic_closed` CRASH REPORT because the dep treats any QUIC-conn `'DOWN'` as abnormal. Will resolve when `quic` is bumped.

## 0.2.0

- Switch `h2` and `quic` deps to hex packages: `h2 0.5.0`, `quic 1.3.0`.
- Add `public_key` to the application list.
- Clean dialyzer run: dropped dead `{error, _}` clauses around `h2_capsule:decode/1` and `h2_varint:decode/1`, removed unreachable `Router =:= undefined` branch, dropped unsupported `h3_datagram_enabled` from `quic_h3:start_server/3` opts, switched listener loop to `spawn_link/3` for static reachability.
- Configure `xref_checks` (skip `exports_not_used` for the public API) and `dialyzer` (`plt_extra_apps: [public_key, ssl, crypto, inets]`).
- Add GitHub Actions CI: OTP 26/27 matrix runs compile, xref, eunit, dialyzer; separate job builds ex_doc.

## 0.1.0

- Initial release.
