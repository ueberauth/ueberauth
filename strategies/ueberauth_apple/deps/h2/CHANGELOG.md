# Changelog

All notable changes to `h2` are documented here. This project follows [Semantic Versioning](https://semver.org/).

## [0.12.5] - 2026-10-23

### Added

- New `connection_window_size` option for clients and servers. h2 kept the
  connection-wide flow-control window at 64 KB, so large downloads over slow
  links were capped at 64 KB per round trip, whatever `initial_window_size`
  was. Set `connection_window_size` together with a larger
  `initial_window_size` to raise it. Default stays 64 KB, so nothing changes
  unless you set it.

## [0.12.4] - 2026-10-03

### Fixed

- Existing streams keep working after a GOAWAY has been sent or received
  (RFC 9113 §6.8). The `goaway_sent` and `goaway_received` states only
  accepted `send_data`, `send_data_blocking` and `consume`, so
  `h2:cancel/2,3`, `h2:send_trailers/3`, `h2:send_response/4`, `h2:respond/5`
  and the stream handler calls got `{error, unknown_request}`. A client needs
  the reset to drop the streams a peer GOAWAY refused, and a gRPC stream
  needs trailers to finish. The per-stream calls now share one dispatcher
  across `settings`, `connected` and both goaway states.
- A received GOAWAY now keeps the client in `goaway_received`. The frame loop
  recomputed the state after every read and put a client whose settings were
  acked back in `connected`, so the GOAWAY state never stuck and new requests
  were still sent on a connection the peer was closing. `h2:request` now
  returns `{error, goaway_received}` there, and `h2:goaway/1,2` is accepted
  to answer the peer. The same recomputation could move a connection out of
  `goaway_sent` when a frame arrived during the drain window.

## [0.12.3] - 2026-09-24

### Fixed

- A SETTINGS frame that raises `SETTINGS_INITIAL_WINDOW_SIZE` now sends the
  DATA already buffered on open streams (RFC 9113 §6.9.2). The larger window
  was applied, but nothing drained the buffers, so a response body queued
  against a zero window stalled until an unrelated WINDOW_UPDATE arrived. Since
  0.12.0 this showed up as an intermittent h2spec 6.9.2/1 failure.

## [0.12.2] - 2026-09-24

### Fixed

- The `h2_client` CLI now reports a connection that closes while it waits for
  a response, along with the close reason. It matched a bare `closed` atom
  that `h2_connection` never sends, so it waited out its timeout and printed
  "Timeout waiting for response". The owner-message list in `h2` now documents
  `{h2, Conn, {closed, Reason}}`.

## [0.12.1] - 2026-09-21

### Fixed

- A HEADERS frame rejected with a stream error now has its field block
  decoded before it is dropped (RFC 9113 §4.3). This covers HEADERS on a reset
  or half-closed stream, a stream refused by `max_concurrent_streams`, and
  HEADERS whose priority depends on its own stream, including blocks
  continued in CONTINUATION frames. Skipping the block left the HPACK decoder
  behind the peer's encoder, so the next block that referenced the missing
  dynamic table entries failed with COMPRESSION_ERROR and the whole connection
  closed. A client hit this when a response crossed its own RST_STREAM.

## [0.12.0] - 2026-08-11

### Added

- `h2:serve_socket/2` runs the server connection loop over a socket the caller
  already accepted and handshook, so an embedder can own a single TLS listener,
  resolve ALPN itself, and dispatch `h2` here while sending `http/1.1`
  elsewhere. Takes the same `server_opts()` map as `start_server/2` and derives
  its connection options through the same code, so the two cannot drift. ALPN is
  not re-validated. Accepts a plain `gen_tcp` socket too, served as
  prior-knowledge h2c. Socket ownership transfers to the returned pid, which is
  linked to the caller.

### Changed

- The TLS handshake now runs in the per-connection process instead of the
  acceptor. A slow or stalled client no longer holds up that acceptor's accept
  queue. `start_server/2` behaviour is otherwise unchanged.

## [0.11.0] - 2026-07-15

### Added

- `h2:peername/1` returns the peer's `{IpAddress, Port}` for a live
  connection (server or client side), reading the underlying socket via
  `inet:peername`/`ssl:peername`. Enables SIP Via received/rport for
  embedders built on h2.

## [0.10.4] - 2026-07-05

### Fixed

- A blocking `send_data/5` whose data fully drained no longer gets
  `{error, stream_closed}` when the drain of its closing END_STREAM chunk is
  what closes the stream (peer already half-closed). `close_stream` now
  settles parked waiters by buffer state: `ok` when the send buffer drained,
  the close-reason error otherwise. Regression introduced in 0.10.3.

## [0.10.3] - 2026-07-04

### Fixed

- A blocking `send_data/5` caller parked on flow control is now released with
  `{error, stream_reset}` (peer or local RST_STREAM) or `{error, stream_closed}`
  when the stream closes. Previously the waiter list was dropped on close, so a
  sender blocked with `#{block => infinity}` hung for the connection's lifetime
  when the peer cancelled the stream mid-backpressure.
- A server request whose HEADERS frame carries END_STREAM now delivers the
  trailing `{data, StreamId, <<>>, true}` event to the stream handler, so
  handlers waiting on end-of-stream don't hang on body-less requests. This
  mirrors the client-side behaviour and quic_h3.

## [0.10.2] - 2026-06-16

### Changed

- Server request delivery now keeps `:authority` and `:scheme` in the handler
  `Headers` list (previously only `:protocol` survived). Adapters can reconstruct
  the request authority/scheme for virtual hosting and reverse-proxy use without
  relying on a `host` header, which a compliant client may omit. `:method` and
  `:path` are still passed as separate fields. Consumers that forward or reflect
  the header list should strip these pseudo-headers first.

## [0.10.1] - 2026-06-13

### Documentation

- Documented gRPC bidirectional streaming in the README and the `h2` module docs:
  per-stream handlers, half-close, receive backpressure (`consume/3`), blocking
  send (`send_data/5`), and cancel / goaway / closed delivery to the handler.
- Fixed ex_doc autolink warnings for private functions referenced in the
  changelog so the docs build clean.
- Synced the README install snippet to the current version.

## [0.10.0] - 2026-06-13

### Added

- gRPC bidirectional streaming support. A dedicated per-call process can own a
  single stream's events without owning the connection, while many calls
  multiplex one connection.
  - Per-stream event routing now covers every event type. `set_stream_handler/3`
    routes `{response,...}`, `{data,...}`, `{trailers,...}`, `{informational,...}`
    and `{stream_reset,...}` to the handler, and replays in arrival order any
    events buffered before registration (previously only DATA was buffered, and
    response/trailers went only to the owner). `h2:request(Conn, Headers,
    #{handler => Pid})' sets the handler at stream creation to avoid the
    registration race.
  - Receive-side backpressure: `#{flow_control => manual}' stops auto-replenishing
    the stream receive window on dispatch; `h2:consume(Conn, StreamId, N)' sends
    the WINDOW_UPDATE after the consumer has processed N bytes, bounding a slow
    consumer to one window instead of an unbounded mailbox.
  - Send-side backpressure: `h2:send_data/5' with `#{block => Timeout}' blocks
    until the peer's window accepts the data (`ok') or the deadline passes
    (`{error, timeout}'). The default non-blocking path still returns
    `{error, send_buffer_full}' once the per-stream buffer cap is reached.
  - Teardown is delivered per stream: a stream handler now also receives
    `{goaway, Last, Code}' and `{closed, Reason}', so a bidi call process learns
    its connection is going away. `cancel/2,3' RST_STREAM continues to reach the
    peer handler as `{stream_reset, StreamId, Code}'.
  - All additions are opt-in; default streams and the existing client/server and
    WebSocket-over-h2 (extended CONNECT) APIs are unchanged.
  - Interop coverage in both directions: a real gRPC client (grpcurl) against an
    h2-hosted echo service, and our h2 client against a real grpc-python echo
    server.

### Fixed

- `send_trailers/3` no longer lets the trailers (END_STREAM) overtake DATA still
  buffered behind a closed flow-control window. The trailers are now queued and
  emitted once the send buffer drains, so a `send_data` then `send_trailers`
  sequence under backpressure (e.g. a gRPC server response) cannot drop the tail
  of the body. Surfaced by the small-window bidi stress test.

## [0.9.0] - 2026-06-06

### Changed

- A response's frames are written to the socket in one `Transport:send` instead
  of one send per frame. `flush_stream_one_chunk/2` now stages every
  flow-control-ready DATA frame (chunked to `peer_max_frame_size`, bounded by a
  1 MiB coalescing cap) into a single write, and the `respond/5` fast path writes
  `[HEADERS | DATA...]` in one go. A 100 KiB TLS response drops from 8 socket
  writes to 1, cutting the per-frame gen_statem round-trips and TLS-record AEAD
  encryptions; large-body throughput roughly doubles (~37k -> ~65k req/s on
  h2load `-c64 -m32` over TLS). Flow control, framing and the public API are
  unchanged; multi-megabyte bodies still yield between cap-sized batches.
- Active stream counts are maintained incrementally instead of folding the whole
  stream map on every new stream. `count_peer_active_streams/2` (checked per
  inbound HEADERS) and `count_active_streams/1` (checked per outbound request)
  are now O(1) reads of counters kept in sync by `put_stream/3`, removing an
  O(n^2) cost under stream churn. About 13% h2load throughput gain at c=100
  m=100 over h2c. No behaviour change.

## [0.8.0] - 2026-06-03

### Added

- `h2:respond/5` sends a complete response (status, headers and body) in one call
  and one coalesced socket write (HEADERS plus DATA), instead of the two
  round-trips of `send_response/4` followed by `send_data/4`. It falls back to
  the granular path when the response cannot be coalesced (oversized headers or
  body, CONNECT tunnels). The existing send functions are unchanged.
- `backlog` server option (default 1024) sizes the listen queue.

### Fixed

- Connection collapse under concurrent load. The server dropped responses for
  requests pipelined before the client's SETTINGS-ACK (legal per RFC 9113): a
  handler's `send_response`/`send_data` was rejected while the connection was
  still in the `settings` state, so fast clients (h2load, browsers) lost whole
  connections under load. The server now serves while in the `settings` state.
- Client stream leak. Response HEADERS without END_STREAM reset a
  `half_closed_local` stream back to `open`, so the final DATA reached only
  `half_closed_remote` and completed streams never closed, eventually exhausting
  `SETTINGS_MAX_CONCURRENT_STREAMS`.

### Changed

- HPACK encoder static-table lookup is an O(1) precomputed map, and the dynamic
  table is a map keyed by insertion sequence for O(1) indexed lookup, insert and
  eviction (was `lists:nth/2`).
- HPACK Huffman decoding is a table-driven 8-bit state machine (one tuple lookup
  per input byte); cold header decode is about 9x faster.
- DATA frames are sent as iodata without copying the body.

## [0.7.0] - 2026-06-02

### Added

- Listeners can bind a specific address or family. `start_server/2,3`
  accept `ip => inet:ip_address()` (an 8-tuple selects IPv6) and
  `inet6 => boolean()` (bind the IPv6 wildcard `::`) for both the `ssl`
  and `tcp` transports.

## [0.6.1] - 2026-05-28

### Changed

- OTP 29 compatibility: replaced every deprecated old-style `catch Expr` in `src/` with `try ... catch ... end`. Fire-and-forget cleanup calls now go through a private `ignore_errors/1` helper; the `--port`/`--timeout`/URL-port argument parsers use `try`. No behaviour change. The build is clean under `warnings_as_errors` on OTP 29.
- CI now runs on OTP 29.0.

## [0.6.0] - 2026-05-20

Security and concurrency hardening pass driven by a multi-agent audit. Several behaviour changes are flagged below; the new error returns require callers to widen their pattern matches.

### Security

- **CONTINUATION flood (Critical).** `handle_continuation` caps the raw bytes of an in-flight HEADERS+CONTINUATION block at `?MAX_HEADER_BLOCK_BYTES` (256 KB). Past the cap the connection emits `GOAWAY(ENHANCE_YOUR_CALM)`. Pre-fix a peer could OOM the node before `max_header_list_size` (which acts on decoded headers) could fire, same class as CVE-2024-27316.
- **Owner liveness (Critical).** `controlling_process/2` now monitors the new owner and demonitors the previous one. Before the fix the new owner's death produced no signal and the connection orphaned the socket.
- **`send_frame/2` error propagation (High).** `send_request` / `send_request_headers` / `send_response` / `send_data` / `send_trailers` used to reply `ok` to the caller even after `Transport:send` returned `{error, closed}`. They now stop with `{shutdown, {send_failed, Reason}}` and propagate `{error, Reason}` to the in-flight caller.
- **Peer `SETTINGS_HEADER_TABLE_SIZE` capped (High)** at 64 KB before applying. RFC 7541 lets the peer advertise any 32-bit value; honoring it fed the encoder dynamic table (O(n) lookup) and turned a chatty peer into a CPU/memory exhaustion vector.
- **Per-stream send-buffer cap (High).** `Stream#stream.send_buffer` is capped at `?MAX_SEND_BUFFER_BYTES` (1 MB). A peer that stalls its receive window now gets `{error, send_buffer_full}` instead of growing the connection process unbounded.
- **Acceptor mailbox drain (High).** ssl and tcp acceptor loops drain queued `{'EXIT', _, _}` after every accept. Pre-fix every closed connection left an EXIT message in the trapping acceptor; on a busy server the mailbox grew without bound.
- **TLS server hardening (High).** `start_server` honors top-level `verify` (default `verify_none`), rejects `verify_peer` without `cacerts` (`{error, verify_peer_requires_cacerts}`), accepts an `ssl_opts` override list, and defaults `honor_cipher_order` to `true`.
- **Demo escript path traversal.** The `h2_server` escript's `safe_path` helper uses `filelib:safe_relative_path/2`; URL-encoded `%2e%2e` and normalised escapes (`/a/../../etc/passwd`) are now rejected.

### Breaking

- `h2:set_stream_handler/3,4` default flipped from `drain_buffer => true` to `drain_buffer => false`. The connection now replays previously-buffered DATA frames to the handler pid itself; the call returns `ok`. Callers that explicitly matched `{ok, Buf}` on the default and forwarded by hand can drop that code. Pass `#{drain_buffer => true}` to keep the old shape.
- `h2:send_data/3,4` may return `{error, send_buffer_full}` when the peer has stopped consuming. Widen any `ok = h2:send_data(...)` match.
- `h2:cancel_stream/2,3` is marked `-deprecated` in favour of `h2:cancel/2,3`. Same behaviour; compiler emits the deprecation warning.
- Default `SETTINGS_MAX_CONCURRENT_STREAMS` is now `100` (was `unlimited`, per RFC 9113 §5.1.2 floor). Peers attempting more than 100 concurrent streams now get `RST_STREAM(REFUSED_STREAM)`.
- TLS server `start_server`: `verify_peer` without `cacerts` now fails fast with `{error, verify_peer_requires_cacerts}` instead of silently accepting unauthenticated peers.

### Added

- `?MAX_HEADER_BLOCK_BYTES` (256 KB), `?MAX_PEER_HEADER_TABLE_SIZE` (64 KB), `?MAX_SEND_BUFFER_BYTES` (1 MB), `?DEFAULT_TIMEOUT_MS` (30 s) macros in `h2.hrl`.
- `h2_settings:setting_id/1` and `h2_settings:encode_value/1` exported; `h2_connection` reuses them so the literal-hex setting-id table cannot drift again.
- CT regressions in `h2_compliance_SUITE`:
  - `continuation_flood_triggers_enhance_your_calm_test`: > 256 KB of CONTINUATION traffic yields GOAWAY.
  - `controlling_process_monitors_new_owner_test`: killing the new owner terminates the connection.
  - `send_returns_error_on_closed_socket_test`: closed socket + `send_data` returns `{error, _}`.
  - `send_buffer_full_when_peer_stalls_window_test`: 2 MB push past stalled window yields `send_buffer_full`.
  - `set_stream_handler_default_replays_buffer_test`: the new auto-replay default is exercised.
  - `large_body_yields_to_inbound_frames_test`: PING ACK round-trips during a 512 KB upload.

### Changed

- `handle_send_data` no longer recurses inside the gen_statem callback for multi-frame bodies. It buffers the payload (subject to the cap) and `flush_stream_one_chunk/2` emits one DATA frame per gen_statem step via self-cast. Inbound frames (PING, WINDOW_UPDATE, RST_STREAM) are now interleaved with outbound chunks instead of queueing for the duration.
- HPACK decode failures and handler crashes log via `logger:error/2` (was the deprecated `error_logger:error_msg/2`). The HPACK reason term is dropped from the log line; it echoed attacker-supplied header bytes.
- An unsolicited `SETTINGS_ACK` preserves the current state name instead of forcing `connected` (still lenient-ignore, not the RFC 9113 §6.5.3 PROTOCOL_ERROR; just no longer short-circuits the preface state machine).
- `peel_reason/1` is recursive; doubly-wrapped `{shutdown, {shutdown, _}}` reasons collapse to the inner value.
- Default ssl/tcp transport tag, ALPN, and timeouts all flow from `?DEFAULT_TIMEOUT_MS` (30 s).

### Fixed

- `set_active/2` on a closed socket no longer crashes the gen_statem with `badmatch`; the connection stops cleanly with `{shutdown, {socket_error, _}}`.
- `cancel_timer` uses synchronous cancel + flushes any already-delivered `{timeout, Ref, _}` so stale messages cannot match a future reused timer.
- The `h2_listener` accept loop and the `h2` server connection loop `logger:debug` unknown messages instead of silently dropping.

## [0.5.0] - 2026-04-19

### Added
- `h2_settings`: WebTransport over HTTP/2 settings (draft-ietf-webtrans-http2-14 §11.2). IDs `0x2b61`-`0x2b66` encode/decode as `wt_initial_max_data`, `wt_initial_max_stream_data_uni`, `wt_initial_max_stream_data_bidi_local`, `wt_initial_max_stream_data_bidi_remote`, `wt_initial_max_streams_uni`, `wt_initial_max_streams_bidi`. No defaults: absence means "not advertised".

### Changed
- `h2_settings:decode/1`: unknown setting IDs are preserved under their raw 16-bit integer key in the returned map instead of being dropped. RFC 7540 §6.5.2 "MUST ignore" means "do not act on", not "discard"; keeping them lets higher layers (e.g. WebTransport) inspect extension settings without a patch here. `h2_settings:encode/1` also accepts integer keys for symmetric round-trip.

## [0.4.0] - 2026-04-15

Listener robustness + TLS regression guard. The server listener no longer dies when the process that called `h2:start_server/2` exits, which broke test helpers and init callbacks spinning up short-lived listeners.

### Added
- `h2_app` / `h2_sup` / `h2_listener`: `h2` is now a proper OTP application with a top-level `simple_one_for_one` supervisor for per-server listeners. Server listeners live under the application supervision tree instead of being linked to the caller of `h2:start_server/2`.
- CT regression `tls_transport_tag_detected_test` in `h2_compliance_SUITE`: asserts `h2_connection` classifies the TLS socket as `ssl` (not `gen_tcp`) after connect, so any future drift in OTP's `sslsocket` tuple shape is caught early.

### Changed
- **Breaking:** `h2:start_server/2` now requires the `h2` application to be started (`application:ensure_started(h2)`). Previously it worked from any process; now it registers a child under `h2_sup`.
- `h2:stop_server/1` sends a stop message to the listener process and lets it shut down the acceptor pool and close the listen socket under OTP supervision.

### Fixed
- `wait_connected/1,2` callers and the `{h2, Conn, connected}` owner event are now fired inline from `handle_frame` when the first SETTINGS ack transitions the connection to `connected`. Previously, if the same socket read buffer also contained a frame that caused a connection error, `gen_statem` would enter `closing` before the `connected` state-enter callback ran and waiters would only see the teardown reply.
- `closing` state-enter now replies to any still-queued `wait_connected/1,2` callers with `{error, ErrorCode}` instead of leaving them to time out.
- `closing` state-enter now half-closes the write side (`shutdown(write)`) and keeps reading to drain the recv buffer before the final close. A full `close()` with unread peer data was causing Linux to emit RST instead of FIN, which masked our GOAWAY on the h2spec oversized-frame case (`4.2 / 2: Sends a large size DATA frame that exceeds SETTINGS_MAX_FRAME_SIZE`).

## [0.3.0] - 2026-04-15

Third review pass + h2spec interop; behaviour-visible spec fixes across the whole state machine. No breaking API change, but callers that matched on specific error atoms may see different values on edge cases (ALPN, ENABLE_PUSH, IWS).

### Added
- External interop suite `test/h2_interop_SUITE.erl` drives the server from [h2spec](https://github.com/summerwind/h2spec). Six groups: TLS generic/HPACK, h2c plaintext generic/HPACK, small-window (forced flow-control fragmentation), `--strict` mode. 146/146 generic+HPACK cases pass. Skips cleanly when `h2spec` is not on `$PATH`.
- `.github/workflows/interop.yml`: CI runs h2spec v2.6.0 on every push/PR; logs uploaded on failure.
- `.github/workflows/ci.yml`: now runs `h2_compliance_SUITE` in addition to eunit; CT logs uploaded on failure.
- PING/RST_STREAM flood mitigation (RFC 9113 §10.5): per-second counters per connection, GOAWAY(ENHANCE_YOUR_CALM) on overflow.
- Extended CONNECT (RFC 8441): server opt-in via `h2:start_server(Port, #{enable_connect_protocol => true, ...})` advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL=1`. Client uses `h2:request(Conn, Headers, #{protocol => <<"websocket">>})`. New errors: `{error, extended_connect_disabled}`, `{error, extended_connect_method}`. Inbound: server rejects `:protocol` with stream `PROTOCOL_ERROR` if it has not opted in.
- `h2:start_server` honors `transport => tcp` (cleartext h2c prior-knowledge listener with gen_tcp acceptor pool).
- `h2:connect/3` top-level `verify` and `cacerts` options merged into SSL options.
- Owner event `{h2, Conn, {informational, StreamId, Status, Headers}}` for 1xx interim responses (excluding 101).
- Send-side header validation runs before HPACK encode on `send_request`, `send_request_headers`, `send_response`, and `send_trailers`.
- README: "Using with Ranch" and "Coexisting with HTTP/1.1" sections with code sketches.

### Changed
- `SETTINGS_ENABLE_PUSH` default is now **0** (was 1). Server advertises 0; inbound PUSH_PROMISE on either side is a connection PROTOCOL_ERROR (RFC 9113 §6.5.2 / §8.4).
- TLS `connect/2,3` requires ALPN `h2`. Previously fell through silently on `protocol_not_negotiated`; now returns `{error, alpn_not_negotiated}` (§3.3).
- Connection-level receive window fixed at 65535 regardless of `SETTINGS_INITIAL_WINDOW_SIZE` (§6.9.2). IWS now only adjusts stream windows.
- Request builder no longer injects `:authority = ""` when the caller omits `host`. Non-CONNECT requests without host now send no `:authority`; CONNECT without host returns `{error, missing_authority}` (§8.3.1).
- Trailers from the peer transition the stream to `half_closed_remote` (was `closed`), so a handler mid-response isn't surprised by `invalid_stream_state` when the peer pipelines body+trailers (§5.1).
- `closing` state proactively closes the TCP/TLS socket on entry (§5.4) instead of waiting up to 5 s for the peer.
- Closed-stream error classification: closed-reason retained in a compact id → reason side map bounded at 10 000 entries. Late DATA/HEADERS on a recently-closed stream is scoped exactly (connection vs stream) regardless of whether the full record has been evicted from the 100-entry window.
- Owner event `{h2, Conn, {goaway, LastStreamId}}` is now `{goaway, LastStreamId, ErrorCode}`.
- Per-stream events (`data`, `trailers`, `stream_reset`) routed to the registered stream handler when set; connection owner receives them only as fallback.
- HEADERS whose encoded block exceeds peer `SETTINGS_MAX_FRAME_SIZE` are split into HEADERS + CONTINUATION chain (§4.2).
- Body-less responses (HEAD / 204 / 304) emit a trailing `{data, Sid, <<>>, true}` event so callers waiting for end-of-stream don't hang.
- HPACK: Huffman encode/decode tables precomputed once via `persistent_term` + `-on_load`; dynamic table caches length and uses a single `lists:reverse` on eviction.

### Fixed
- HEADERS/DATA on a stream closed via END_STREAM: connection STREAM_CLOSED (was stream-scoped RST) (§5.1).
- HEADERS/DATA on a stream closed via RST_STREAM: stream-scoped STREAM_CLOSED (was connection-scoped).
- CONTINUATION without an outstanding pending HEADERS: connection PROTOCOL_ERROR (§6.10).
- PRIORITY self-dependency on both the PRIORITY frame and inline HEADERS priority: stream PROTOCOL_ERROR (§5.3.1).
- PRIORITY frame with length != 5: stream FRAME_SIZE_ERROR (was connection) (§6.3).
- WINDOW_UPDATE on an idle stream: connection PROTOCOL_ERROR (was silently ignored) (§5.1).
- Unknown frame types: ignored per §4.1 (previously function_clause-crashed the connection).
- Inbound `MAX_CONCURRENT_STREAMS` enforced: peer HEADERS over our advertised limit now get `RST_STREAM(REFUSED_STREAM)` (§5.1.2).
- `SETTINGS_ENABLE_PUSH=1` received as client: connection PROTOCOL_ERROR (§6.5.2).
- `SETTINGS_INITIAL_WINDOW_SIZE` above 2³¹−1: connection FLOW_CONTROL_ERROR (was PROTOCOL_ERROR) (§6.9.2).
- Body-less responses (HEAD/204/304): accept `content-length > 0` with `END_STREAM` (RFC 9110 §9.3.2); reject when `END_STREAM` is absent on the header block.
- `in_closed_stream_range` was asymmetric in client mode (only matched peer-initiated ids); now mirrors server mode.
- HPACK decoder: truncated literal returns `{error, incomplete_string}` instead of `function_clause`.
- 1xx interim responses with `END_STREAM` or `Content-Length` → stream `PROTOCOL_ERROR` (§8.1, RFC 9110 §15.2).
- CONNECT tunnel flag no longer pre-set on the request; the stream becomes a tunnel only when the 2xx response is sent/received. Non-2xx CONNECT responses permit trailers and enforce body rules (RFC 7540 §8.3).
- `:authority` containing userinfo (`user@host`) rejected with `PROTOCOL_ERROR` on both inbound and outbound paths (§8.3.1); `check_authority_host` runs for CONNECT requests too.
- Extended CONNECT `:protocol` value validated as an RFC 7230 token (RFC 8441 §4).
- `:scheme` pseudo-header follows the actual transport (`http` on TCP, `https` on TLS).
- `:method = CONNECT` outbound: trailers rejected with `{error, tunnel_no_trailers}`.
- `WINDOW_UPDATE` with increment 0 on a non-zero stream → stream RST_STREAM(`PROTOCOL_ERROR`) (§6.9.1).
- `:status` parsing: malformed values trigger stream `PROTOCOL_ERROR` instead of crashing the gen_statem.
- `:status = 101` rejected on both send and receive (§8.6).
- Padding counted against receive flow control (§6.1). Connection-level receive window consumed on DATA for closed or unknown streams (§5.1).
- `Content-Length` enforcement (§8.1.1): duplicate/mismatched/non-numeric/negative values → `PROTOCOL_ERROR`; DATA overshoot or END_STREAM mismatch → stream RST.
- Server-side request trailers: trailing HEADERS without END_STREAM → `PROTOCOL_ERROR`.
- Field name validation tightened to RFC 7230 `tchar` (rejects SP, HTAB, colon in regular headers, other controls, DEL, non-ASCII). Field values: leading/trailing SP/HTAB rejected in addition to NUL/CR/LF.
- `SETTINGS_MAX_HEADER_LIST_SIZE` enforced in both directions: outbound exceed → `{error, header_list_too_large}`; inbound exceed → stream `PROTOCOL_ERROR`.

### Docs
- `docs/features.md`: PRIORITY metadata is parsed and self-dep rejected, but no scheduler is implemented (RFC 9218 supersedes RFC 7540 priorities).

## [0.2.0] - 2026-04-13

First usable release with a full connection-layer client and server. Previous 0.1.0 shipped only frame/HPACK primitives.

### Added
- Public API module `h2` with client and server entry points aligned with `quic_h3`:
  - `h2:connect/2,3`, `h2:wait_connected/1,2`
  - `h2:request/2,3,4,5`, `h2:send_data/3,4`, `h2:send_trailers/3`
  - `h2:start_server/2,3`, `h2:stop_server/1`, `h2:server_port/1`
  - `h2:send_response/4`, `h2:cancel/2,3`, `h2:cancel_stream/2,3`
  - `h2:set_stream_handler/3,4`, `h2:unset_stream_handler/2`
  - `h2:goaway/1,2`, `h2:close/1`, `h2:controlling_process/2`
  - `h2:get_settings/1`, `h2:get_peer_settings/1`
- `h2_connection` gen_statem implementing the full stream state machine (RFC 7540 §5.1) with flow control, SETTINGS negotiation, two-phase GOAWAY, and CONTINUATION handling.
- CONNECT tunnel mode (RFC 7540 §8.3): bidirectional byte tunnels over a stream, half-close semantics, trailers rejection, `Content-Length`/`Transfer-Encoding` rejection on 2xx.
- `h2_server` with TLS acceptor pool and ALPN `h2` negotiation.
- Owner-process event messages: `{h2, Conn, {response, ...}}`, `{data, ...}`, `{trailers, ...}`, `{stream_reset, ...}`, `{goaway, ...}`, `closed`, `connected`.
- Compliance test suite (Common Test) with 32 cases covering protocol conformance, API parity, and tunnel mode.

### Changed
- `h2_hpack`: persistent_term-backed precomputed Huffman encode tuple and sorted decode table; static table lookups via `element/2` (O(1)); dynamic table caches length and evicts with a single `lists:reverse`.
- `h2_connection`: cached `peer_max_frame_size`, `peer_initial_window_size`, `peer_max_concurrent_streams` on the state record; CONTINUATION header buffer uses `iodata()` (flattened once on END_HEADERS) instead of per-frame binary concatenation.
- Frame decoder (`h2_frame:decode/2`) takes `MaxFrameSize` and enforces per-type stream-id 0 rules (DATA/HEADERS/PRIORITY/RST_STREAM/PUSH_PROMISE/CONTINUATION reject 0; SETTINGS/PING/GOAWAY require 0).

### Fixed
- RFC 7540/7541 compliance gaps:
  - Padding bound in DATA/HEADERS frames now accepts `PadLength == byte_size(Rest)`.
  - `WINDOW_UPDATE` increment 0: stream-level RST_STREAM / connection-level GOAWAY with `PROTOCOL_ERROR`.
  - `SETTINGS_INITIAL_WINDOW_SIZE` change that overflows any open stream → connection `FLOW_CONTROL_ERROR`.
  - Pseudo-header validation: order, lowercase header names, connection-specific headers rejected, `:path`/`:authority` checks.
  - CONTINUATION interleaving on a different stream → `PROTOCOL_ERROR`.
  - RST_STREAM on an idle stream → `PROTOCOL_ERROR`.
  - HEADERS on a half-closed-remote or closed stream → `STREAM_CLOSED`.
  - HPACK: dynamic-table size update larger than peer-advertised max → `COMPRESSION_ERROR`; size update after a non-size-update representation → `COMPRESSION_ERROR`.
  - Huffman decoder: EOS symbol in the middle of a string rejected; padding must be < 8 bits of all-ones.
- Body duplication when `send_data` split buffers across frames.
- Connection owner notified with `closed` on termination.
- CT suite flakiness: acceptor socket defaulted to active mode, losing data between `ssl:handshake` return and `setopts({active, false})`.

## [0.1.0]

Initial release. Low-level HTTP/2 primitives (frames, HPACK, settings, capsule, varint).
