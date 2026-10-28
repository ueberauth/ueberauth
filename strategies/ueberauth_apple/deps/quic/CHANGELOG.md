# Changelog

All notable changes to this project will be documented in this file.

## [2.1.3] - 2026-10-26

### Changed
- Connections produce much less garbage and use less CPU per packet. A
  small request/response exchange creates about 70% less garbage per
  round trip, decoding the common frames is about twice as fast, and
  bulk transfers run faster as well.
- A pending acknowledgement now travels on the next data packet instead
  of in a packet of its own, so a request/response exchange sends two
  packets per round trip instead of three. `ack_sent` in `get_stats/1`
  counts these acknowledgements too.
- Sending an acknowledgement now cancels its delay timer, so the
  connection no longer wakes up later for a timer with nothing left to
  do.

## [2.1.2] - 2026-10-25

### Security
- A session ticket now resumes only on the listener that issued it, for
  the server name and ALPN it was issued under. Tickets were kept in one
  table for the whole VM and accepted by any listener, so a client given
  a ticket by one listener could log in to any other listener in the
  same VM, including one that only admits clients holding its pre-shared
  key. (GHSA-cv3h-phw9-vfjm, CWE-287). Found by GPT Cyber.
- A listener no longer stalls when many connections close at once.
  Each closing connection made the listener scan its whole routing
  table, so a burst of short-lived connections, which anyone can open,
  kept it from accepting or routing other clients for tens of seconds.
  (GHSA-fqq7-rg4w-x69m, CWE-407). Reported by wallace0409.
- A peer can no longer fill a slow connection owner's mailbox until the
  VM runs out of memory. Stream data earned the peer new credit as soon
  as it reached the owner's mailbox, read or not. Credit now waits while
  the owner's mailbox holds more than `max_owner_queue` messages (1000
  by default). (GHSA-6fr7-vvrm-wf2w, CWE-770). Reported by wallace0409.
- A peer can no longer fill a slow owner's mailbox with DATAGRAMs.
  Every DATAGRAM received was sent to the owner whatever its backlog;
  the `datagram_recv_queue_len` cap did not limit the mailbox. DATAGRAMs
  that arrive while the owner's mailbox holds more than
  `max_owner_queue` messages are now dropped and counted in
  `datagram_stats/1`. (GHSA-gq4m-5qh3-q47h, CWE-770). Reported by
  wallace0409.

### Added
- `quic:set_stream_flow_control/3` and `quic:consume/3`: a stream in
  `manual` mode earns the peer credit only for the bytes the owner
  reports as processed, so the peer sends at most one stream window
  ahead of the reader.

### Fixed
- An HTTP/3 server handler reading a request body now always learns
  where the body ends. A request without a body (curl sends every GET
  this way) or one ending with trailers never signalled its end to the
  handler, so a handler waiting for the body hung.
- A server that answers a request before it is fully received, then
  stops reading it (RFC 9114 Section 4.1.1), no longer resets its own
  response when the client resets the request. On a lossy link the
  reset could throw away the end of the response.

## [2.1.1] - 2026-10-04

### Fixed
- HTTP/3 streams already open keep working after a GOAWAY, sent or
  received (RFC 9114 Section 5.2). `quic_h3:cancel/2,3` sent nothing, the
  peer's RESET_STREAM and STOP_SENDING were never reported, and calls such
  as `send_trailers/3`, `send_response/4` or `get_quic_conn/1` waited out
  their timeout. Only new requests are refused. A call the connection
  does not know is answered with `{error, unknown_call}` in every live
  state instead of being dropped.
- GOAWAY from both endpoints. A server that had sent GOAWAY closed with
  H3_ID_ERROR when the client answered with its own, or rejected every
  new stream. The identifier the peer sent is now kept apart from the one
  we sent, either side can answer the other's GOAWAY with
  `quic_h3:goaway/1`, and a server refuses new pushes once the client's
  GOAWAY arrives.

## [2.1.0] - 2026-09-28

### Added
- Receive backpressure for HTTP/3. `quic_h3:set_stream_handler/4` and
  `quic_h3:request/3` take `flow_control => manual`, and
  `quic_h3:consume/3` returns credit for body the reader has processed.
  The peer can then send at most one stream window past what was consumed,
  so a handler that stops reading stops the peer instead of filling its
  mailbox. HTTP/3 framing is credited as it is parsed. `auto`, the
  default, is unchanged.
- A write refused with `send_queue_full` is followed by
  `{quic_h3, Conn, {send_ready, StreamId}}` to the refused caller once the
  send queue drains below half its ceiling, so writers need not poll.

### Fixed
- A small queued stream frame could ride along with an ACK past the peer's
  flow-control limit, closing the connection with FLOW_CONTROL_ERROR. It now
  waits for both windows, and its bytes count against the connection limit.
- `quic_h3:set_stream_handler/3,4` and `unset_stream_handler/2` no longer
  leave the caller waiting forever while the connection is still connecting
  or after a GOAWAY: every state answers them.

## [2.0.3] - 2026-09-27

### Fixed
- A transfer through a small receive window no longer stops after the
  first window. Each bidirectional stream tracked the other limit than the
  one it advertised (RFC 9000 Section 18.2), so with a small
  `max_receive_window` the receiver never sent MAX_STREAM_DATA and the
  sender's writes sat queued. A receiver now keeps granting credit as it
  receives, whatever the window.
- The hex package ships the README image and leaves out a local
  `c_src/build` directory.

### Changed
- `max_receive_window` below 16384 bytes is refused by `quic:connect/4` and
  `quic:start_server/3` with `{error, {invalid_max_receive_window, W}}`;
  such a window cannot keep the peer moving.
- A write refused with `send_queue_full` is logged at debug rather than as a
  warning, since callers retry it until the queue drains.
  `quic:get_stats/1` reports the count as `send_queue_full_refusals`.

## [2.0.2] - 2026-09-27

### Fixed
- `{error, send_queue_full}` from `quic:send_data/4,5` and
  `quic_h3:send_data/3,4` now means nothing was written. A write larger
  than one packet could already have sent part of itself before being
  refused, and the connection then forgot those packets, so the retry
  reused their packet numbers and loss recovery never covered them. The
  ceiling is now checked once, before anything is sent, and it is per
  connection. `quic:send_data_async/4` is never refused, and a queued
  remainder is no longer dropped when the queue is over the ceiling.
- A refused HTTP/3 HEADERS, trailers or PUSH_PROMISE write keeps the QPACK
  encoder state once its encoder instructions were sent, so the peer's
  decoder stays in step.

## [2.0.1] - 2026-09-25

### Fixed
- `quic` compiles on Windows again. The NIF build and clean hooks ran
  through `sh`, which Windows lacks, so every compile failed there,
  including projects that only reach `quic` through hackney. The hooks now
  run `c_src/build_nif.sh` only on Unix platforms, and Windows runs on OTP
  crypto (#358).

## [2.0.0] - 2026-09-24

Upgrading from 1.x: the HTTP/3 connection close is now always
`{quic_h3, Conn, {closed, Reason}}`. Two of the three close paths used to send
the bare atom `closed`, so code matching that atom stops matching and, where the
match sits in a `handle_info/2` with a catch-all or in a selective receive, the
close is dropped silently and the caller waits out its own timeout instead.
Match the reason-carrying shape. Code that already matches a peer
`{stream_reset, StreamId, ErrorCode}` needs no change and will simply start
seeing the streams this library resets as well.

### Changed
- An HTTP/3 connection reports every close as `{quic_h3, Conn, {closed, Reason}}`.
  Two of the three close paths sent a bare `closed`, which
  `quic_h3:wait_connected/2` does not match, so a connection that died while
  connecting reported a timeout it never waited out. The reason is `normal` for a
  local close or a drained GOAWAY, `owner_down` when the owning process exits,
  `{h3_error, Code, Phrase}` for a protocol error, and otherwise whatever the
  QUIC connection reported.
- An HTTP/3 stream that this library resets is reported to its stream handler,
  or to the connection owner if none is registered, as
  `{stream_reset, StreamId, ErrorCode}`, the same event a peer reset produces.
  A body refused past `max_buffered_body`, a frame error on a stream, and
  `quic_h3:cancel/2,3` told the peer and left the local caller waiting out its
  own timeout. The stream's handler registration is dropped with it, so a
  cancelled stream no longer leaves a monitor behind.
- An HTTP/3 request that finished in both directions is dropped from the
  connection's stream map. One consequence to be aware of:
  `quic_h3:send_datagram/3` for such a stream now returns
  `{error, unknown_stream}`, where the leaked entry used to let it through. A
  datagram session holds its request stream open (`end_stream => false`), as
  extended CONNECT and MASQUE do, so it is unaffected. Nothing removed it on a clean FIN, so a connection
  grew by the retained header list of every request it had served, and, because
  the GOAWAY drain waits for that map to empty, a connection that had served
  anything never closed gracefully. The half-close state is now combined rather
  than overwritten, so a stream that finished both directions reaches `closed`.

### Added
- `quic:connect/4`, `quic:start_server/3` and `quic:server_spec/3` accept
  `cacertfile`, a PEM file holding the trust anchors, read once where the
  connection or server starts. The key was accepted nowhere and silently
  ignored, so verification fell back to the OS trust store without saying so.
  A file that cannot be read, or that holds no certificate, fails the call.
  `cacerts` still wins when both are given.

### Fixed
- A response that announces a Content-Length and carries no body is read as the
  protocol defines it rather than as a short body. A HEAD response states the
  size a GET would have returned (RFC 9110 Section 8.6), and 204 and 304 never
  carry content (Section 6.4.1); all three were reset with H3_MESSAGE_ERROR. A
  body that really is shorter than its Content-Length is still refused.
- `quic_h3:send_response/4` and the push equivalent take the status as an
  argument, so a `:status` in the header list as well is dropped rather than
  sent beside it. Two of one pseudo-header is a malformed response
  (RFC 9114 Section 4.3.1).
- An HTTP/3 peer resetting a request stream, or sending STOP_SENDING
  on it, is reported as `{stream_reset, StreamId, ErrorCode}` or
  `{stop_sending, StreamId, ErrorCode}`, to the stream handler if one
  is set and to the connection owner otherwise. Both were dropped, so a
  client waiting on a response the server had reset waited out its own
  timeout.
- A STOP_SENDING is answered with a RESET_STREAM carrying the peer's
  code (RFC 9000 Section 3.5).
- `quic:reset_stream/3`, `quic:reset_stream_at/4`, `quic:stop_sending/3`
  and `quic:send_ping/1` send their frame before returning, instead of
  leaving it for the next packet the connection happened to send.
- qlog events reach the file while the connection is open, within the
  writer's 100 ms flush interval. The file driver's write buffer held
  them back until 64 KB had built up or the connection closed.
- qlog logs a run of padding as one `padding` frame with its `length`,
  instead of one entry per byte.
- HTTP/3 DATA frames of any size are accepted, and their payload reaches
  the owner or stream handler as it arrives. A DATA frame over 1 MiB,
  which `quic_h3:send_data/4` and the Go http3 server produce for a large
  body written in one call, closed the connection with H3_FRAME_ERROR.
- An HTTP/3 client receives a response without Content-Length past
  16 MiB; the cap now applies only to the request body a server buffers.
- A request or push stream ending inside a frame closes the connection
  with H3_FRAME_ERROR instead of crashing the HTTP/3 connection process.
- A server issues a new session ticket on a handshake resumed from a
  ticket. Tickets are single-use, so a client could resume only once and
  then fell back to a full handshake without 0-RTT.
- A client offers 0-RTT only on a ticket that allows early data
  (RFC 8446 Section 4.2.10), and derives early keys only then.
- A resuming client whose HTTP/3 layer opens its control and QPACK
  streams after the first server packets arrived no longer fails the
  connect. The QUIC connection refused to open unidirectional streams in
  the handshaking state, which one scheduler made common.
- A stopping server closes its connections before its socket, so each
  sends CONNECTION_CLOSE and its clients are told at once. They heard
  nothing until their own idle timeout.
- A QPACK encoder-stream instruction that announces more than any
  insertable entry could need is refused before its bytes are buffered,
  and an entry larger than the capacity in force is an encoder stream
  error rather than being dropped while our insert count drifts from the
  peer's (RFC 9204 Section 3.2.2). A peer could pin memory for the life of
  the connection by announcing a huge name and stopping.
- The QPACK dynamic table starts at zero capacity and opens only on the
  peer's Set Dynamic Table Capacity, within what we advertised, while the
  Required Insert Count of a field section is decoded against the
  advertised capacity as RFC 9204 Section 4.5.1.1 requires.
- A malformed Huffman literal or an over-long integer on the encoder
  stream closes the connection with QPACK_ENCODER_STREAM_ERROR instead of
  crashing the HTTP/3 connection process.
- An HTTP/3 server bounds what it holds for request bodies whose handler
  has not registered yet: `max_buffered_body`, 16 MiB by default, counted
  across the whole connection. A body with a Content-Length was not bounded
  at all, and the guard that did fire counted bytes received rather than
  held, so it also reset large uploads a handler was reading. Buffered bytes
  are now released when a stream is reset or cancelled, and empty or
  fin-only pieces are charged so they cannot accumulate for free.
- `{error, send_queue_full}` is named in the `quic:send_data/4,5` and
  `quic_h3:send_data/3,4` specs and documented as the backpressure signal it is:
  nothing was written, and the same piece should be sent again once the
  connection drains. It appeared in no spec and no page.
- A QUIC distribution connection is closed when the `dist_util` process
  handshaking over it dies, which is what stock distribution gets from
  socket ownership. net_kernel resolves a simultaneous connect by killing
  the losing handshake process, and the peer, seeing no drop, blocked in
  `recv_status` until its setup timer fired seconds later while
  net_kernel held a pending entry for that node, so the next
  `connect_node/1` on either side returned false.
- A distribution handshake read waiting on a connection that closes gets
  `{error, closed}`, which `dist_util` reports as a failed handshake,
  instead of the caller dying out of the gen_statem call.
- `SO_REUSEADDR` is set only on a listener bound to a fixed port. On a
  client socket, or a listener on port 0, it let the kernel autobind two
  sockets to one port and deliver every datagram for it to one of them,
  leaving the other connection unable to hear the server. A gen_udp
  caller that wants it can still pass it in `extra_socket_opts`.

## [1.10.0] - 2026-09-21

### Added
- `active_connection_id_limit` sets how many connection IDs the peer may
  hold at once. (#317)
- `quic:get_stats/1` reports `zero_rtt_streams`, the number of streams
  whose 0-RTT data the server kept. (#334)

### Changed
- Loss detection and recovery keep per-space state behind one timer, the
  shape RFC 9002 Appendix A describes. Initial and Handshake packets are
  tracked and acknowledged in their own spaces instead of being dropped
  by a guard, the application-data probe is armed only once the handshake
  is confirmed, and the three ad-hoc handshake retransmission timers are
  replaced by the probe for whichever space lost something. Handshake
  packets are admitted against the congestion window and the
  anti-amplification budget before a packet number, the send counter or
  the pacing allowance is spent; either refusal holds the frames in one
  per-space queue and a later attempt is a first attempt. Keys are
  discarded with the spaces they protect, on the role-specific triggers
  RFC 9001 §4.9.1 gives, and a Retry resets recovery and congestion state
  while keeping the data to resend. (#333, #334)
- `quic_connection` sheds the pieces that stand on their own. New
  internal modules: `quic_pqueue` for the send queue's priority buckets,
  `quic_reassembly` and `quic_interval` for stream reassembly,
  `quic_tls_negotiation` for TLS negotiation and the node-wide ticket
  store, `quic_cid` for the connection ID pools, and `quic_rtt` for the
  RTT estimate, which belongs to the path rather than to any packet
  number space. The connection's ACK frame path, its receive-side packet
  number bookkeeping and its range accumulation move into `quic_ack`,
  which now separates its two topics, and both halves of a range encode
  through one guarded gap encoder. Peer transport parameters are
  validated in one place, and the module is laid out by section with the
  handshake-flight timers out of the PMTU code. No public API changes.
  (#319, #320, #321, #322, #323, #327, #329, #330, #332, #334)
- Elvis rules live in `elvis.config` alone, the build fails if a second
  lint configuration appears, and `rebar3_lint` is pinned to the version
  CI resolves. (#328)

### Fixed
- A connection ID is bound to the path that first used it and retired
  when a new path replaces it (RFC 9000 §9.5), and `RETIRE_CONNECTION_ID`
  is sent for the IDs a `retire_prior_to` covers. The peer's handshake
  connection ID counts against `active_connection_id_limit`. (#317, #324,
  #333)
- The delayed-ACK timer runs on our own `max_ack_delay` rather than the
  peer's, and the persistent-congestion window is built from the PTO
  without its exponential backoff (RFC 9002 §7.6.1). (#333)
- The peer's ACK timing parameters reach loss detection. (#324)

## [1.9.1] - 2026-09-15

### Changed
- Interop and compliance tests exercise the external peers for real.
  Peers are probed with a Version Negotiation request instead of a UDP
  send, network tests fail on connect, handshake, echo and close errors,
  the quic-go container runs its HTTP/3 server instead of an echo demo
  that exits, and CI runs the compliance, reassembly and 0-RTT suites
  against the peers. A Docs job builds `rebar3 ex_doc`. (#310)
- `quic_connection`, `quic_listener` and `quic_socket` compile with
  `export_all` under TEST instead of carrying test-only export lists.
  The `#state{}` record moves to `src/quic_connection_state.hrl` and the
  state builders to `test/quic_connection_test_support.erl`. The default
  build is unchanged. (#307, #311)

### Fixed
- The owner-exit close tests no longer race the connection's exit on
  slow runners. (#312)

## [1.9.0] - 2026-09-14

### Added
- `delivery_coalescing` (default `false`) merges consecutive
  same-stream `stream_data` deliveries of one receive pass into a
  single owner message, flushed at the end of the pass or as soon as
  another stream delivers, so arrival order across streams is kept and
  a `stream_reset` never overtakes data delivered before it. Owners
  otherwise wake once per packet on bulk flows. QUIC gives no
  message-boundary guarantee, but owners that decode each delivery as
  one complete application message break when deliveries merge, so it
  is opt-in.
- Bulk stream sends go out as runs: once the first full-size chunk is
  approved, as many further chunks as congestion control, pacing and
  the burst budget allow are approved up front (consuming pacing
  tokens exactly as one-at-a-time sends would), sealed and handed to
  the socket in one loop, and loss, congestion, packet-number and
  counter bookkeeping is updated once for the run:
  `quic_cc:send_check_run/4` approves the run against cwnd and pacing
  in one step (never more permissive than the sequential checks),
  `quic_cc:on_packets_sent/2` and `quic_loss:on_packets_sent_run/4`
  fold it into one record update each (native for NewReno, a fold for
  other algorithms). The per-packet connection-state rebuild was the
  largest own-time item on the bulk-send profile; a 64-packet run
  replaces 64 copies with one. The socket-backend receive queue bound
  is the connection's flow-control window in full-size packets (never
  below 512 messages): a run sender inside the window it was given is
  never tail-dropped, and the bound only catches a peer outside it. A
  fixed 512-message bound sat below a 16 MB window and turned
  flow-control-permitted data into loss on loopback.
- The listener drains the datagram messages already queued in its
  mailbox into one receive sweep (up to 256 packets), groups them per
  source address and dispatches each group as one batch. Distinct
  flows never GRO-coalesce, so at a server with many sparse
  connections every datagram used to be its own listener message and
  its own connection wakeup; connections now wake once per sweep and
  their batched receive path engages even for sparse traffic. ACK
  processing re-arms the PTO once at the end of the receive pass
  instead of once per ACK frame.
  processing re-arms the PTO once at the end of the receive pass
  instead of once per ACK frame.
- Server connections on the socket backend hand their finished send
  batches to one shared sender process per listener, which performs
  the `sendmsg` calls serially. Concurrent `sendmsg` on one socket
  handle from many connection processes burns about 20x the CPU in
  NIF-level contention (98.6 vs 4.7 us per send with 50 concurrent
  senders); in a 50-connection fan-out model server CPU went from 24.3
  to 11.0 s for the same window. Connections keep their own batch
  buffers, GSO grouping and counters; a connection whose sender has
  died sends directly from then on, and the listener starts a new one
  for new connections.

### Fixed
- PMTU black-hole detection counts loss events, not lost packets, and a
  large packet acknowledged in between clears the count. It counted every
  large packet declared lost and, once the search had completed, nothing
  ever reset it, so a single burst loss of six or more full-size packets
  on a healthy path (a qdisc dropping one GSO super-packet, a small
  receiver socket buffer) dropped the path MTU to 1200 for the rest of
  the connection: about 15 % more packets for every byte after it. On a
  1 GbE rig two such drops per 50 MB were enough. Now one ACK's worth of
  losses is one strike if any of them was large, and an ACK carrying a
  large packet proves the path still passes them.
- A stream receiver with a hole at the head of its reassembly buffer no
  longer slows down with every packet buffered behind it. The
  connection-level receive-buffer byte count was recomputed from the
  buffer on every out-of-order stream frame, twice, by walking every
  chunk in the tree, so with one lost packet and a congestion window's
  worth of data queued behind it each further packet cost a walk of
  thousands of chunks, the receiver's mailbox grew into the thousands,
  ACKs went out seconds late and the sender sat on its window: a 50 MB
  download over 1 GbE with a single early loss ran at 13 MB/s where
  10 MB, or a peer that never lost a packet, ran at 90 to 108. The
  stream now keeps a running byte count and every tree change reports
  its delta.
- The NIF's AEAD context cache is bounded and no longer raises. Each
  key update derives fresh keys, and the per-process cache kept a live
  EVP context for every one of them, so a long-lived bulk connection
  accumulated them until it exited; only the current and previous key
  phase are ever live (RFC 9001 section 6), so the oldest are now
  evicted. A context the NIF cannot build also falls back to the OTP
  crypto path instead of failing a `{ok, Ctx}` match, which is what the
  optional NIF is supposed to guarantee.
- A client Initial flight spanning more than one datagram reaches the
  connection in full. The listener's receive sweep groups the packets
  of one flight together, and the group that starts a new connection
  handed only its first packet over, dropping the rest; the handshake
  then stalled until the client retransmitted. A chunked
  `x25519mlkem768` ClientHello makes a multi-datagram flight the normal
  case, and the sweep put this on the default `gen_udp` path.
- Pacing no longer freezes on sub-millisecond links. RTT samples are
  whole milliseconds, so such a link reports a smoothed RTT of 0 and
  `update_pacing_rate` treated that as "no RTT yet" and skipped the
  update: the rate stayed at its handshake-time value while cwnd kept
  growing, clocking the connection at that stale rate forever. The RTT
  is floored at 1 ms for the rate computation instead.
- Burst continuations are sent to the connection directly rather than
  through `erlang:send_after(0, ...)`. The timer wheel's ~1 ms service
  tick turned every 64-packet burst continuation into a 64 packets per
  millisecond clock, capping bulk streams at roughly 85 MB/s regardless
  of the paced rate. Together with the previous fix, a verified
  single-stream loopback bulk transfer went from 83 to 194 MiB/s.
- The frames a connection sends on entering `connected` (data queued
  before the handshake finished, the server's NEW_TOKEN, the first PMTU
  probe) leave with that transition. They went through the send batch
  and the state-enter handler returned without flushing it, so they
  waited for the next event on the connection: on a quiet connection the
  peer's delayed ACK or a PTO. `get_stats` now reports
  `send_batch_pending`, the packets built but not yet handed to the
  socket, which is what caught this.

### Changed
- The optional crypto NIF is no longer built by default. Set
  `QUIC_BUILD_NIF=1` while compiling `quic` to build it; a requested
  build that fails now fails the compile instead of being skipped.
  Without the variable nothing is compiled and the library runs on OTP
  crypto.
- ChaCha20-Poly1305 connections use the fused crypto NIF paths
  (`protect_run`, `open_packet`, `open_run`) like the AES suites. The
  header-protection mask is five ChaCha20 keystream bytes with the
  16-byte sample as the cipher IV (RFC 9001 5.4.4), so the NIF keeps a
  keyed ChaCha20 context per HP key and reloads only the IV per packet,
  the same shape as the AES-ECB context. Where the CPU has no AES
  instructions ChaCha is the faster cipher by a wide margin and was the
  one suite left on the per-packet path.
- The interop runner declares the passive robustness cases (longrtt,
  blackhole, amplificationlimit, handshakeloss, transferloss,
  handshakecorruption, transfercorruption, rebind-port, rebind-addr),
  runs the multiconnect case as one connection per file so the runner's
  handshake count matches, disables `disconnect_timeout` in both
  endpoints so the blackhole case can outlast its outage, waits 60 s per
  download, and the server loads the full certificate chain from
  cert.pem.
- Count-based ACK decimation defers its flush while a receive pass is
  active, so one ACK covers the whole drained train instead of one per
  `ack_packet_tolerance` packets. A 64-packet pass previously emitted
  about 32 ACKs, each costing a packet build, an AEAD seal and a send
  on the receiver and a decrypt plus ACK-frame pass on the sender; it
  also released the sender's window in 2-3 packet quanta, which kept
  GSO batches near size 1. The max_ack_delay timer still bounds ACK
  latency for below-tolerance remainders and the reordering
  immediate-ACK path is unchanged.
- The out-of-order reassembly buffers (stream data and CRYPTO) are
  ordered trees instead of maps. A miss at the delivery point, which
  happens once per received packet while a hole is outstanding, is now
  answered with one smallest-key lookup, and the trim walk for
  repacketized overlaps visits only chunks below the delivery point.
  The map version rebuilt the whole buffer on every miss; with a
  multi-megabyte hole under loss recovery that walk dominated receiver
  CPU.
- The per-packet receive bookkeeping on the 1-RTT path (PN space, spin
  bit, activity stamp) is one state update instead of three; the three
  separate helpers each rebuilt the full connection state and together
  cost about a tenth of receive CPU on bulk flows.
- Receive-side fast paths for the dominant bulk shape: an in-order
  stream frame on an existing stream with an empty reassembly buffer
  and both flow-control windows comfortably open is one stream-record
  update and one map put, falling back to the general path for every
  other shape; a sequential packet number extends the head ACK range
  without the range-cap scan; a packet led by a stream frame skips the
  datagram-only delayed-ACK check. The per-frame `max_stream_data_check`
  debug log is gone, it cost a logger allow-check per frame.
- The connected-state receive pass drains the datagram messages already
  queued in the connection's mailbox (up to 64) before flushing ACKs,
  socket batches and timers, so those flushes amortize over a train
  instead of running once per datagram. On the socket backend the
  listener and the client receiver now emulate a bounded kernel receive
  buffer: trains are forwarded in chunks of at most 8 packets and
  tail-dropped once the connection's mailbox exceeds its bound (see
  the send-side entry), keeping the head packet so the peer still
  gets a timely ACK. An unbounded mailbox turned receiver overload into queueing
  delay instead of loss, which inflated the peer's RTT samples and
  destabilized its loss detector.
- With the crypto NIF loaded, a bulk chunk run is sealed in one call:
  `protect_run` builds each short header, derives the nonce, AEAD-seals
  the payload and applies header protection for the whole run in C,
  instead of two crypto NIF calls plus header, nonce and mask glue per
  packet. AES only (the header-protection context is ECB); ChaCha and
  NIF-less builds seal per packet as before. Send-side crypto drops
  from about 9% of connection CPU to about 2% on bulk flows. The output
  is checked byte for byte against the per-packet path.
- With the crypto NIF loaded, a received 1-RTT packet is opened in one
  call: `open_packet` does header unprotection, packet-number
  reconstruction (RFC 9000 Appendix A) and AEAD open together, replacing
  two crypto NIF calls plus mask, packet-number and AAD glue per
  packet. It runs only while no key update is in flight and checks the
  key-phase bit before decrypting, handing a phase change to the
  two-stage path so RFC 9001 §6 bookkeeping stays where it was. ChaCha
  and NIF-less builds are unchanged.
- A train of short-header datagrams (a GRO train at the server, the
  drained mailbox at the client) is opened in one NIF call: `open_run`
  carries the largest received packet number forward across the run in
  C, matching sequential `open_packet` calls exactly, and stops at the
  first packet that needs the generic path (key-phase transition,
  authentication failure, undersized datagram), which the caller then
  handles per packet. The client drain now collects queued same-source
  datagrams into one batch before processing.
- After the batched decrypt, `open_run` also parses each packet's
  frames in C and returns a frame list term-identical to what
  `quic_frame:decode/1` produces (PING, ACK with ECN, CRYPTO, STREAM,
  MAX_DATA, MAX_STREAM_DATA, MAX_STREAMS, HANDSHAKE_DONE, with stream
  and crypto payloads as zero-copy sub-binaries). A packet with any
  other frame type comes back raw and goes through the Erlang decoder,
  which keeps every error semantic (unknown type, truncation, empty
  packet). The parser is differential-tested against the decoder and
  fuzzed with random and mutated frame sequences. In a 50-connection
  server model this cut steady-state reductions by 8%; on a verified
  bulk transfer, 190 to 222 MiB/s.
- A batch-opened run whose packets continue the receive sequence is
  folded with one receive-bookkeeping update (largest, ACK range, spin
  bit, activity) and one ACK-decimation increment instead of one of
  each per packet; and when such a run carries one stream frame per
  packet, all for the same stream, offsets contiguous, no FIN, the
  stream bookkeeping runs once for the train: one flow-control check
  with the train's totals, one stream-record update, one delivery.
  Every deviation (mixed frames, gaps, duplicates, FIN, tight windows,
  qlog enabled) takes the per-packet path unchanged and the delivery
  contract holds in both modes. Verified bulk with delivery coalescing
  on: 339 to 405 MiB/s (+19%).
- AEAD sealing and opening reuse a cipher context instead of re-running
  the key schedule on every packet. `crypto:crypto_one_time_aead/7` sets
  the key up on each call and QUIC seals each packet as its own AEAD
  unit, so that cost landed on every packet in both directions. Where
  the running OTP has `crypto_one_time_aead_init/4` (OTP 28+) the handle
  is cached per key and direction, bounded the way the header-protection
  contexts already are; older releases keep the one-shot path. Measured
  on a 1200-byte packet: AES-128-GCM seal 0.540 to 0.331 us and open
  0.468 to 0.331, ChaCha20-Poly1305 seal 1.132 to 0.934 and open 1.067
  to 0.934. A payload too short to hold an authentication tag is now
  rejected as an authentication failure rather than raising.
- Accepted connections now monitor their owner and stop with
  `{shutdown, owner_down}` (CONNECTION_CLOSE to the peer) when it exits,
  as supervised client connections already did. Before, a dead handler
  left the connection up until its idle timeout, delivering into a dead
  mailbox. `monitor_owner => false` in the listener options restores the
  old behaviour.

## [1.8.2] - 2026-09-05

### Added
- `versions` lists the QUIC versions a connection will also accept, for
  RFC 9368 compatible version negotiation. Contributed by jbevemyr (#243).
- `hibernate_after` (default 5000 ms) hibernates an idle connection
  process, running a fullsweep so the handshake's garbage stops being
  pinned to a heap that never collects on its own. `infinity` opts out.
  Contributed by jbevemyr (#207).
- TLS secrets are written to the file named by `SSLKEYLOGFILE` when it is
  set, in the format Wireshark reads. Contributed by jbevemyr (#231).
- `max_burst_packets` bounds how many packets leave per send drain, so a
  large queued write cannot monopolise the scheduler. Contributed by
  jbevemyr (#214).
- `ack_packet_tolerance` makes the 1-RTT ACK decimation threshold
  configurable; it defaults to the RFC 9000 section 13.2.1 value of 2.
  Contributed by jbevemyr (#213).

### Fixed
- A stream written in more than one `send_data/4` call no longer goes out
  interleaved. When the per-drain burst budget was spent, the unsent
  remainder was requeued at the back of its priority bucket instead of the
  front, so the drain round-robined between the queued entries and the
  stream stayed out of order for the rest of the transfer, leaving the
  receiver holding most of it for reassembly (1.2 MB buffered on a 2 MB
  transfer in 16 writes, against 0 once ordered). Throughput on loopback
  is unchanged; the cost is the reassembly buffer, and any real path where
  reordering matters.
- An authenticated distribution connection no longer drops the peer's
  first handshake message about half the time. The `auth_callback` path
  put a short-lived gatekeeper process in front of the dist controller
  and replayed its mailbox after the handoff, but the controller took
  ownership from a `gen_statem` state-enter callback, which runs after
  `start_link` has already returned; everything the connection emitted in
  between arrived at a process that had stopped reading. The controller
  now owns the connection from the first packet on the server and from
  before `start_link` returns on the client, so there is no handoff to
  race. Auth callbacks must not open streams, which never worked.
- A TLS alert raised during the handshake now reaches the peer. The
  CONNECTION_CLOSE was batched into the state `send_tls_alert/2` returns,
  which the six immediate-exit sites discarded before calling `exit/1`;
  `terminate/3` could not recover it, since it runs with the pre-alert
  state and its fallback close is skipped entirely while app keys do not
  exist. The peer saw silence and waited out its idle timeout instead of
  learning why the handshake failed. Reported by obi458 (#227).
- Two nodes dialling each other at the same time no longer deadlock over
  QUIC distribution. `net_kernel` resolves a simultaneous connect by
  killing the losing setup process and then blocking, with no timeout,
  until that process dies; the setup process trapped exits, so the signal
  became an unread message, nothing died, and the node's distribution
  machinery stayed wedged until both dials timed out. It now acts on that
  exit while it still owns the connection, and stops trapping once the
  controller has taken ownership, which is what OTP's own setup processes
  do.
- An HTTP/3 message body ends at stream end rather than at a frame
  boundary, so a response whose last DATA frame is followed by the FIN
  in a separate packet is not truncated. Contributed by jbevemyr (#244).
- A server answers a long-header packet carrying a version it does not
  support with a Version Negotiation packet (RFC 9000 section 6.1)
  instead of silence. Probing with a reserved version is how readiness
  checks and the interop runner detect a live server. A packet that is
  itself a Version Negotiation is never answered. Contributed by
  jbevemyr (#229).
- QUIC v2 (RFC 9369) uses the correct wire format: version-specific
  packet-type bits, salts and key labels, and compatible version
  negotiation settles on the first ClientHello. Contributed by
  jbevemyr (#243).
- A client switches away from a connection ID the peer has retired
  (RFC 9000 section 5.1.2) instead of continuing to use it.
  Contributed by jbevemyr (#218).
- The keep-alive PING no longer spins on a connection whose peer has
  gone quiet. Contributed by jbevemyr (#221).
- An unresponsive peer is given up on after a disconnect timeout, checked
  on its own timer rather than on the PTO. Contributed by jbevemyr (#224).
- A peer address change is followed immediately and validated in the
  background, so a NAT rebind does not stall the connection while
  validation runs. Contributed by jbevemyr (#255).
- The server sends a Retry when configured to, and its cipher preference
  order is configurable rather than fixed. Contributed by jbevemyr (#232).
- The client offers the cipher suites it was configured with instead of
  always the built-in list, and honours the `version` option.
  Contributed by jbevemyr (#232, #235).
- Short headers are unprotected with the negotiated cipher, so a
  connection that negotiated ChaCha20-Poly1305 no longer fails to
  decrypt. Contributed by jbevemyr (#234).
- A session ticket selects the PSK it belongs to rather than only
  feeding 0-RTT, so resumption works on its own. Contributed by
  jbevemyr (#238).
- The session-ticket table is owned by the server registry rather than
  whichever connection created it: it used to vanish with that
  connection, and a client resuming afterwards fell back to a full
  handshake. Contributed by jbevemyr (#239).
- Only the client sends 0-RTT, and 0-RTT data lost in flight is resent.
  Oversized 0-RTT writes are split, and the idle-state send path is
  gated too. Contributed by jbevemyr (#240).
- The connection-level MAX_DATA update triggers on remaining headroom
  rather than cumulative bytes received. The old comparison became
  permanently true once total received passed one window, putting an
  ack-eliciting MAX_DATA on every packet. Contributed by jbevemyr (#209).
- Retained ACK ranges are capped at 64 per packet-number space
  (RFC 9000 section 13.2.4). Under burst loss the list fragmented into
  hundreds of ranges, and every outgoing ACK encoded all of them.
  Contributed by jbevemyr (#211).
- Overlapping and duplicate chunks are handled when reassembling stream
  and CRYPTO data, keeping the longer chunk at a given offset instead of
  trusting whichever arrived first. Contributed by jbevemyr (#223).
- A flow-control-blocked write no longer strands data behind a blocked
  queue head: the sendable prefix goes out, the remainder requeues in
  order, and queued data is normalised to a binary. Contributed by
  jbevemyr (#233).
- Streams are reclaimed when their FIN is acknowledged rather than when
  it is sent, so a lost FIN cannot retire the stream early. Contributed
  by jbevemyr (#236).
- MAX_STREAM_DATA is no longer sent for a stream whose final size the
  peer has already declared. Contributed by jbevemyr (#241).
- The client's retained Finished flight carries its own retransmission
  timer. Once the state machine leaves the handshake nothing is
  guaranteed to be in flight to arm a PTO, so a Finished lost more than
  once was never resent and the handshake stalled until the idle timeout.
- The GSO segment size is derived from the batch instead of a
  configured constant. 1-RTT packets follow the current max datagram
  size, so the uniformity check against the fixed 1200 never matched and
  the GSO path never ran; a batch is now split into runs of equal-sized
  packets and each run segmented on its own size. Each write is capped
  at 64 segments and 64 KB, and GSO is requested per message rather than
  as a socket-level `UDP_SEGMENT`, which segmented every datagram
  including handshake packets. Reported by jbevemyr (#196).
- The socket-backend client binds the source address from
  `extra_socket_opts` instead of leaving it to the kernel's route
  lookup, which picks the wrong address on a multi-address host.
  Contributed by jbevemyr (#261).
- A GRO train reaches the client connection as one message rather than
  one per packet, so the whole train is processed in a single receive
  pass. Contributed by jbevemyr (#248).
- PTO probe packets are exempt from the congestion window and loss
  retransmissions are bound to it, per RFC 9002 section 7. A probe is
  the only thing that can restart a stalled connection, so blocking it
  on a window the peer's silence keeps closed deadlocks the transfer;
  ordinary loss retransmissions, which were previously sent regardless,
  now respect the window like any other send. Contributed by jbevemyr
  (#249).
- ACKs arriving at the Initial or Handshake encryption level no longer
  reach the 1-RTT loss tracker. Packet numbers restart per space
  (RFC 9000 §12.3), so a Handshake-space ACK of packet numbers 0..N was
  retiring the first N 1-RTT packets from the sent queue without the peer
  having received them: nothing retransmitted them and the peer kept a
  permanent hole in the stream. A path that drops a full window and then
  returns (WiFi-to-cellular handover, VPN reconnect, NAT rebind) left the
  transfer stalled for good. Contributed by jbevemyr (#250).
- The sent-packet tracker now survives an active path migration. It was
  replaced wholesale, which orphaned every packet already in flight: no
  ACK matched them, loss detection never ran, and `bytes_in_flight` read
  zero so no PTO fired either. Their data was never retransmitted and
  the peer kept a permanent hole in the stream. The path-derived
  estimates (RTT, PTO count) still reset, since those belong to the old
  path. Contributed by jbevemyr (#251).
- The PTO backoff is capped at 5 seconds. RFC 9002 section 6.2.1 doubles
  the PTO on each consecutive expiration and the doubling had no
  ceiling, so on a 50 ms path it reached roughly 90 seconds after nine
  expirations and about twelve minutes after twelve. A probe scheduled
  that far out never happens: the idle timer and any request deadline
  above it have long since fired. Contributed by jbevemyr (#254).
- The loss time threshold is `max(smoothed_rtt, latest_rtt)`
  (RFC 9002 section 6.1.2) rather than the smoothed estimate alone. When
  an RTT spike outruns the EWMA the two diverge, and the smaller
  threshold declares in-flight packets lost while their ACKs are merely
  late. Each spurious loss both retransmits data the peer already has
  and collapses the congestion window, so a single latency excursion
  (receiver queueing, bufferbloat) turned into a throughput collapse.
  Contributed by jbevemyr (#210).
- PMTU probes are tracked as non-ack-eliciting, so a probe lost past the path MTU no longer inflates `bytes_in_flight`, arms the PTO machinery, or feeds a congestion event (RFC 8899 §3, RFC 9000 §14.4). Combined with an in-flight-keyed liveness check, the periodic raise probe previously killed every long-lived connection on an MTU-limited path once per 600-second raise interval, both ends at once. The raise interval is configurable as `pmtu_raise_interval`. (#264)
- The UDP_GRO control message is read as the int the kernel sends.
  Matching exactly two bytes meant the lookup never succeeded, so a
  GRO-coalesced buffer was passed up unsplit as one oversized datagram
  and dropped by the QUIC layer, which cannot re-split short-header
  packets. GRO was therefore silently losing every coalesced train.
  Contributed by jbevemyr (#204).
- The GRO receive path sizes its read buffer for a maximally coalesced
  train (64 KiB). Passing 0 used the OTP default 8 KiB buffer and
  `recvmsg' silently truncated anything larger, discarding every segment
  past the first few. The client receiver also went through a plain
  `recvfrom', which never split trains at all. Contributed by jbevemyr
  (#215).
- A client whose Finished is lost now recovers. The
  Certificate(+CertificateVerify)+Finished flight goes out at the
  Handshake level, and once the client state machine left `handshaking'
  nothing retransmitted it: handshake-space packets are not in the 1-RTT
  loss tracker and the handshake retransmit timer only runs in that
  state. The client considered itself connected and sent 1-RTT data the
  server could not act on before handshake completion, while the server
  replayed its own flight against ACK-only answers, until the connection
  died on the idle timer. The flight is now retained until
  HANDSHAKE_DONE and resent from the PTO and on a duplicate
  handshake-level CRYPTO at offset 0. A write that exceeds the peer's
  flow-control limit also sends the part that fits rather than nothing,
  which is what lets the recovered connection drain its queue.
  Contributed by jbevemyr (#252, #230, #225).
- Anti-amplification accounting (RFC 9000 §8.1) now also runs on the batched listener delivery path. A server whose ClientHello arrived in a GRO batch kept its amp budget at zero, deferred the handshake flight, and the handshake wedged until the connect timeout. (#263)
- A server handshake flight lost on the wire is retransmitted on the client-Initial backoff schedule until the client's Finished arrives. Initial/Handshake packets are not loss-tracked, so a lost flight previously wedged the handshake permanently: the client's Initial retransmits only elicited ACKs once the server TLS state had advanced. (#263)

### Changed
- Header protection reuses a cipher context instead of re-running the key
  schedule on every packet. Measured on an 8 MB transfer, the `crypto:*`
  share of connection-process time drops from 10.95% to 8.30%; header
  protection itself goes from 0.77us to 0.28us per mask. Both directions'
  keys are cached, since they alternate packet by packet.
- The interop runner speaks real HTTP/3 in the http3 case, serves more
  than one request per connection, issues requests concurrently within
  the peer's stream credit, and its resumption and 0-RTT cases test what
  they claim. Contributed by jbevemyr (#245).
- A mixed-size send batch on a GSO socket is split into runs of
  equal-sized packets and each run sent with one UDP_SEGMENT call,
  instead of falling back to one `sendmsg' per packet. A single
  odd-sized packet between data packets (an ACK, a flow-control update)
  previously degraded the whole batch. Contributed by jbevemyr (#217).
- Small sends are coalesced into shared packets. Contributed by jbevemyr
  (#203).
- The pacing burst allowance scales with the pacing rate rather than
  sitting at a fixed 12 packets. Pacing wakeups have roughly
  millisecond resolution, so the fixed bucket capped throughput at 12
  packets per wakeup whenever the sender outran the ACK clock,
  regardless of the configured rate. Contributed by jbevemyr (#219).
- A server with no explicit `groups` option now offers every classical
  group the crypto layer supports (x25519, secp256r1, secp384r1) instead
  of x25519 alone. A preference list holding only x25519 sent a
  HelloRetryRequest to any client whose key_share led with another
  curve, costing a full extra round trip on every such connection and
  exercising the HRR path in flows that did not need it. picoquic shares
  P-256 first, so this was every connection from it. An explicit
  `groups` option still restricts the set exactly as before.
  Contributed by jbevemyr (#246).
- The CONNECTION_CLOSE sent from terminate/3 (owner death, exit signals) reaches the wire: it was batched into an updated socket state that terminate discarded, flushing the stale one instead, so the peer never learned of the close and held a phantom connection until its idle timeout. Peers now see an owner-death close within milliseconds. (#265)

## [1.8.1] - 2026-08-15

### Added
- Post-quantum hybrid key exchange `x25519mlkem768` (draft-ietf-tls-ecdhe-mlkem, ML-KEM-768 + X25519), opt-in via `groups`. Negotiable only when the crypto library provides the ML-KEM APIs (OTP 28.1+); a `groups` option naming an unsupported group is rejected up front from `connect/4` and `start_server/3` as `{error, {unsupported_group, _}}` instead of crashing during the handshake. (#195, #198)
- `docs/INTERNAL_NETWORKS.md` covers running without a CA on a trusted subnet: why TLS cannot be disabled, and the `verify_none` and PSK-only setups for both QUIC and Erlang distribution. (#197)

### Fixed
- Initial-level CRYPTO is now chunked across Initial packets, each within the 1200-byte pre-PMTU limit, and the whole flight is replayed on retransmit. A hybrid `x25519mlkem768` ClientHello (~1360 bytes) or ServerHello Initial (~1225 bytes) no longer leaves as a single oversized datagram that is dropped on paths with an MTU below ~1470 (IPv6-over-PPPoE, WireGuard, mobile). (#195, #198)
- A peer key share that does not fit the negotiated group is answered with an `illegal_parameter` alert instead of raising inside `crypto` and taking the connection process down. The ServerHello key_share group is kept and checked against the negotiated one, each group accepts exactly one share length, and an all-zero ECDH shared secret is rejected (RFC 8446 §7.4.2). (#198)
- `start_server/3` returns `{error, no_auth_method}` when a listener has neither `cert`/`key` nor PSK configuration, as documented. The check ran after the listener had started, so the call returned `{ok, Pid}` and the pool then collapsed. (#197)
- `connect/4` and `start_server/3` reject a `groups` option that is not a non-empty list rather than failing later inside the connection. (#198)

### Changed
- The `verify` default is documented correctly as `verify_peer`: clients validate the server certificate unless told otherwise. `docs/CLIENT_GUIDE.md` and `docs/DEVELOPER_GUIDE.md` both listed the default as no verification. (#197)

## [1.8.0] - 2026-08-05

### Fixed
- The client hostname check applies the RFC 6125 HTTPS rules, so a wildcard SAN such as `*.example.com` matches `host.example.com`. Servers behind a wildcard-only certificate, `www.google.com` among them, were rejected as `{hostname_mismatch, _}`. (#188)
- A Happy Eyeballs winner hands its owner the events it delivered before reporting `connected`. A server that sends its HTTP/3 SETTINGS in the same flight as the handshake had them dropped, so `quic_h3:connect/3` timed out for a multi-address host. (#188)
- A client that receives a Retry keeps counting Initial packet numbers up (RFC 9000 §17.2.5.3) instead of restarting at 0, so the retried Initial is not a replay of the packet the Retry answered. The pre-Retry Initials leave loss detection instead of staying charged as bytes in flight.
- A client acts on a Version Negotiation packet (RFC 9000 §6.2) instead of misparsing and dropping it: no shared version closes the connection as `{version_negotiation, Versions}`, and a packet that arrives late, carries a foreign connection ID, or offers back our own version is discarded.
- The advertised `max_udp_payload_size` is what we are willing to receive rather than the PMTU probing ceiling: the `max_udp_payload_size` option when set, otherwise 1472 over IPv4 and 1452 over IPv6. Both roles used to advertise 1500, which does not fit a 1500-byte path. (#184)

### Changed
- A handshake failure reaches the owner as `{quic, Conn, {error, Reason}}`, tagged with the connection handle like every other owner event; the connection reference used to be the tag and nothing matched it. `quic_h3:connect/3` passes the reason through, so a rejected certificate returns `{error, {certificate_invalid, _}}` rather than `{error, connect_timeout}`, and an exhausted Happy Eyeballs race returns the last attempt's reason rather than `all_attempts_failed`. Owners matching `{quic, ConnRef, {error, _}}` must match the handle instead.

## [1.7.1] - 2026-07-17

### Fixed
- An HTTP/3 connection process now stops with `normal` when the underlying QUIC connection closes cleanly (graceful drain, idle timeout, shutdown), instead of the abnormal reason `quic_closed`. Clean closes no longer emit ERROR and CRASH reports or kill non-trapping linked owners; an abnormal QUIC exit still stops the H3 process, now as `{quic_closed, Reason}`. The owner also receives the `{quic_h3, Conn, closed}` notification on this path, which was previously skipped. (#186)

## [1.7.0] - 2026-07-06

### Added
- Stateless reset on restart (RFC 9000 §10.3). A server advertises a `stateless_reset_token` transport parameter bound to its initial connection ID and, after losing connection state (for example a restart), replies to an unroutable 1-RTT packet with a stateless reset derived from the same secret. A client stores the advertised token and recognises the reset, tearing the dead connection down promptly instead of waiting for its idle timer. Contributed by sstrollo (#177).
- `require_client_cert` server option for mutual TLS. With `verify => true` the server requests a client certificate and validates any presented chain against `cacerts`; `require_client_cert => true` additionally rejects a client that sends no certificate (`certificate_required`), making mutual TLS mandatory. Contributed by sstrollo (#178).

### Security
- The server now validates the client certificate chain in mutual TLS. With `verify => true` a presented client certificate is checked against the configured trust anchors (`cacerts`, OS store by default) in addition to the CertificateVerify signature, so a self-signed or otherwise untrusted certificate is rejected instead of accepted. An empty client certificate is still accepted by default (optional mTLS, RFC 8446 §4.4.2.4); set `require_client_cert => true` to require one. Contributed by sstrollo (#178).

### Fixed
- HTTP/3 client connections close cleanly on an invalid peer SETTINGS frame instead of crashing the connection process. A SETTINGS violation (for example `SETTINGS_H3_DATAGRAM` advertised without the QUIC `max_datagram_frame_size` transport parameter) is reported to the owner as `{error, 265, _}` (H3_SETTINGS_ERROR) and the connection closes, rather than the state machine terminating with `bad_return_from_state_function` and taking the owner's request down. (#172)
- The connection idle timer is driven by received activity (RFC 9000 §10.1): it restarts on every received packet and on the first ack-eliciting packet sent since the last receive, but not on subsequent sends. A connection sending keep-alive PINGs or PTO retransmits into a black hole now idle-closes instead of holding its own timer open forever, while a reactivated idle connection is not closed before its first ack returns. Contributed by sstrollo (#174).
- Connection-level MAX_DATA slides forward with received bytes instead of capping the absolute limit at the receive window, so a sustained transfer no longer stalls permanently once the connection has received `fc_max_receive_window` (8 MiB) bytes in total. Contributed by sstrollo (#176), reported independently by maslowalex (#173).

### Changed
- Per-packet routing traces in the listener are logged at debug instead of info, so a busy or post-restart listener no longer floods the log. Contributed by sstrollo (#175).

## [1.6.5] - 2026-06-12

### Added
- `quic_h3:respond/5` sends an HTTP/3 response status, headers and full body with end-stream in a single connection call, coalescing what previously took `send_response/4` plus `send_data/4`. HEAD, 204 and 304 responses send no body.
- `quic:start_server/3` accepts a `sni_callback` that selects the server certificate and key per connection from the ClientHello SNI (RFC 6066 §3), so an HTTP/3 listener can present different certificates per hostname. The callback is invoked with the parsed `server_name` and returns `{ok, #{cert => Cert, key => Key, cert_chain => Chain}}` or `{error, _}`; an error, malformed result or raised exception fails the handshake with a `handshake_failure` alert. The static `cert`/`key` remain the default when no callback is set.

## [1.6.4] - 2026-06-05

### Changed
- HTTP/3 no longer accumulates received DATA payloads in the stream record. Data still reaches owners and handlers through the existing delivery path, while Content-Length and unbounded-body limits are enforced from a byte counter. The `#h3_stream.body` field is retained for compatibility but is no longer populated.

## [1.6.3] - 2026-06-03

### Added
- `quic:safe_close/1,2,3` closes a connection and ignores any error if it is already gone, for teardown paths that must not crash.

### Fixed
- HTTP/3 connection errors now send a CONNECTION_CLOSE. `handle_connection_error` passed the error reason straight to `quic:close/3`, but several call sites supply a non-binary reason, which failed the function's binary guard and was swallowed by a surrounding `catch`, so the connection was left open. The reason is now coerced to a binary phrase.

### Changed
- Replaced the deprecated bare `catch` expressions in the library and test suites with `try ... catch`, clearing the OTP 27+ compiler warnings. CI now runs the unit tests on OTP 26, 27, 28 and 29 (the matrix previously collapsed to one OTP version per OS).

## [1.6.2] - 2026-06-03

### Fixed
- Happy Eyeballs + HTTP/3: a client connecting to a hostname that resolves to more than one address (so the race path runs) could hang in `quic_h3:connect/3` until `connect_timeout`. The QUIC connection completes its handshake while owned by the race coordinator, so the server's HTTP/3 control stream and SETTINGS were delivered to the transient owner and dropped before the H3 connection process existed. `set_owner` re-delivers `{connected}` but not that already-arrived stream data; the race coordinator and `quic_h3:connect/3` now forward the buffered `{quic, Conn, _}` backlog to the new owner at each ownership handoff. Diagnosed and originally fixed by ycastorium (#160, #161).
- Server certificate validation recovers from an expired cross-signed root. When the served chain anchors at an expired cross-signed root (Let's Encrypt ISRG Root X2 cross-signed by the now-expired ISRG Root X1) and the trust store holds a still-valid root with the same public key, the client retries the alternative trust anchors instead of failing with `cert_expired`. A genuinely expired leaf or intermediate still fails.

## [1.6.1] - 2026-06-02

### Fixed
- Server-side 0-RTT acceptance now works end to end. The server echoes the empty `early_data` extension in EncryptedExtensions when it accepts 0-RTT, so a resuming client reports `early_data_accepted/1 =:= true` instead of always seeing the data rejected. Inbound 0-RTT frames are dispatched at the application level, so the early request and its control/QPACK streams are processed rather than dropped, and the resumed request completes normally.

## [1.6.0] - 2026-06-02

### Added
- 0-RTT (early data) support. On resumption a client can send application data in its first flight, and HTTP/3 can issue an early request, before the handshake completes. `quic:has_early_keys/1` reports whether 0-RTT keys are available, and `quic:early_data_accepted/1` / `quic_h3:early_data_accepted/1` report whether the server accepted the early data. (#148)
- `quic_listener:get_sockname/1` and `quic:get_server_sockname/1` return the listener's bound `{IP, Port}`, resolved live from the socket so it is correct when the listener was opened with `inet6`, `{ip, _}` or `{ifaddr, _}`. (#153)

### Fixed
- Streams aborted with RESET_STREAM_AT are reclaimed from the connection's stream map once their reliable obligation is met (local reset: reliable bytes acked; incoming reset: reliable bytes delivered), instead of being retained for the life of the connection. Data beyond the reliable size is trimmed from the send queue and retransmit path, and dropped on receive. (#152)
- A lost-packet retransmission deferred by congestion control is re-queued and resent when the window reopens, instead of being dropped (it had already been removed from the sent queue, so it was never retried).
- STREAM data referencing a locally-initiated stream that was never opened is rejected with STREAM_STATE_ERROR instead of creating the stream. (#152)
- Erlang distribution over QUIC: the keep-alive PING is paced off `net_ticktime` instead of the QUIC idle timeout, so a healthy connection is no longer declared down by `net_kernel` under load. (#157)

## [1.5.0] - 2026-05-30

### Added
- IPv6 client connections: `quic:connect/4` accepts a hostname, an IP-literal string (IPv4 or IPv6, optionally bracketed), or an `inet:ip_address()` tuple. Dual-stack hostnames use RFC 8305 Happy Eyeballs (IPv6-first racing) with `happy_eyeballs`, `family`, `connection_attempt_delay` and `connect_timeout` options. A hostname that fails to resolve returns `{error, Reason}` instead of dialing a default address. (#150)
- Listeners can bind to IPv6: pass `inet6` or an IPv6 `{ip, Addr}` in `extra_socket_opts`; the address family is inferred from those options. (#149)

## [1.4.5] - 2026-05-28

### Fixed
- Server certificate chain validation accepts chains where the server sends an extra or cross-signed cert above the cert that actually anchors. The previous topmost-only anchor lookup rejected valid chains (notably `cloudflare.com` over Google Trust Services on Mozilla NSS, `certifi` and FreeBSD `ca_root_nss`) with `unknown_ca`. The client now walks the served chain for the highest cert whose issuer is in the trust store and validates the sub-path from there.
- Server certificate verification failures reach the QUIC owner as a synchronous `{closed, {certificate_invalid, _}}` event alongside the existing `{error, {certificate_invalid, _}}` notification, so HTTP/3 clients waiting on the close fail fast instead of stalling until their connect timeout fires.

## [1.4.4] - 2026-05-28

### Security
- The QUIC client now authenticates the server. It verifies the CertificateVerify signature, validates the certificate chain against the trust store (`cacerts` option, OS store by default), and checks the hostname. Previously `verify` was a no-op on the client, so any certificate was accepted and a man-in-the-middle on the network path could impersonate any server. `verify` now defaults to on for clients; set `verify => false` to accept any certificate (for example self-signed test servers). HTTP/3 uses the same client and is fixed too. (GHSA-2r8v-p65x-3663, CVE-2026-49457, CWE-295). Reported by benmmurphy.
- Hardening from a full security review: 3x anti-amplification limit with Initial retransmission, CRYPTO-buffer and listener connection caps, MAX_STREAMS and connection-ID limit enforcement, resumption PSK binder verification with single-use 0-RTT, TLS 1.3 handshake state guards, AEAD usage-limit key update, working address-validation Retry with constant-time token compares, and stricter HTTP/3 and QPACK decoding.

## [1.4.3] - 2026-05-25

### Fixed
- QPACK Encoded Field Section Prefix and dynamic table now follow RFC 9204, so the encoder interoperates with strict decoders such as nghttp3. The Base is signalled as S=0 (Base = Required Insert Count), the Required Insert Count is written as an 8-bit prefix integer, and the Insert With Literal Name opcode and dynamic-table field-section encoding are corrected. (#142)

## [1.4.2] - 2026-05-23

### Fixed
- HTTP/3 extended CONNECT (RFC 9220) regressed in 1.4.1: the response-HEADERS coalescing introduced in 1.4.1 buffered a CONNECT tunnel's `200` until the first DATA frame, but a tunnel server sends no DATA until the client does and the client waits for the `200`, so the tunnel deadlocked (WebTransport and WebSocket-over-H3). CONNECT responses now flush the `200` immediately; plain H3 responses still coalesce headers with the first body chunk.

## [1.4.1] - 2026-05-23

### Changed
- Idle and keep-alive timers are now lazy: armed once at connection setup and re-armed only when they fire, from the `last_activity` timestamp, instead of being cancelled and rescheduled on every packet. (#140)
- HTTP/3 responses coalesce the HEADERS frame with the first DATA frame, so a response's headers and first body bytes go out in one 1-RTT packet instead of two. A large body still fragments as before. (#141)

## [1.4.0] - 2026-05-22

### Added
- TLS 1.3 external PSK (RFC 8446 §4.2.11). Client `external_psk` and server `psks` / `psk_callback` options, both `psk_dhe_ke` and `psk_ke` modes, constant-time server-side binder verification, cert and PSK coexistence on one listener, and client downgrade protection. `quic_dist` can authenticate node-to-node with a shared PSK and no certificates. See `docs/PSK.md`. (#133)
- TLS 1.3 HelloRetryRequest with multi-group key exchange. The `groups` option advertises `x25519`, `secp256r1` and `secp384r1`; a server that prefers a group the client did not key-share triggers a HelloRetryRequest and the client retries transparently. (#135)
- Per-handshake signature negotiation via the `signature_algs` option, adding ECDSA secp384r1-SHA384, RSA-PSS-RSAE SHA384/512 and Ed25519 sign/verify. The `connected` event now reports `negotiated_group` and `negotiated_scheme`. (#135)
- Per-pair multi-stream routing for Erlang distribution over QUIC. Dist messages are hashed by `{From, To}` across 16 streams to send concurrently while preserving order within each sender/receiver pair. (#132)
- `SECURITY.md` with a private vulnerability reporting policy.

### Changed
- HTTP/3 header field-character validation inlines the character class into the scanner clause guards, removing a per-byte predicate call from a request hot path. (#136)

### Fixed
- The server now segments its TLS handshake flight so no datagram exceeds `max_udp_payload_size`. The 3-5 KB flight previously went out as one UDP datagram that clients enforcing their advertised limit (Chromium) dropped, stalling the handshake until idle timeout. (#134, #137)
- ex_doc generation no longer breaks on a `@doc` tag preceding a `-callback`. (#129)

## [1.3.3] - 2026-05-03

### Added
- `quic:get_path_stats/1` returns a snapshot of the connection's path metrics (srtt / latest_rtt / min_rtt / rtt_var in microseconds, plus cwnd, bytes_in_flight, in_recovery, congested) for downstream routing layers. Backward-compatible; off the packet-processing path. (#127)
- `quic_dist` `auth_callback` option runs a custom `{Mod,Fun}` (or `fun/3`) on both sides between the QUIC handshake and the dist_util handshake. `{error, _}` closes the connection without ever starting the dist controller. New `quic_dist_auth` behaviour. (#126)
- `quic_dist` `register_with_epmd` option (default `false`) registers the listening port via the configured `epmd_module` so external tooling (e.g. `epmd -names`) can resolve the node. (#126)

## [1.3.2] - 2026-05-03

### Added
- `priv/bin/quic_call.sh`, an `erl_call`-style one-shot RPC helper for `quic_dist` clusters. Boots a hidden probe node with `-proto_dist quic`, runs `rpc:call/5` against the target, asks the target to disconnect so the hidden-node entry is reaped immediately, and halts. Reuses the cluster's `sys.config` (`-C`) for credentials and discovery; cert/key can also be passed via `--cert`/`--key`. (#123, #124)

## [1.3.1] - 2026-04-30

### Added
- `socket_backend => adapter` lets callers plug their own datagram transport (for example a MASQUE CONNECT-UDP session) under a QUIC client. The adapter map carries `send_fun` (and optional `close_fun`, `socket_ref`); batching, GSO and GRO are forced off, and connection migration is rejected on this path. (#121)

## [1.3.0] - 2026-04-25

QUIC and HTTP/3 protocol-conformance hardening: closes the silent-drop
of CONNECTION_CLOSE at handshake-time violations, replaces the
unmaintained h3spec runner with an in-tree RFC 9114 / 9204 compliance
suite, and fixes two externally-reported stream-API bugs.

### Added
- `close_with_error/6` emits CONNECTION_CLOSE at the right encryption level (initial / handshake / app), with fallback to the lower available level. (#111)
- Server-side validation of peer transport parameters per RFC 9000 §18.2: server-only ids (`original_dcid`, `preferred_address`, `retry_scid`, `stateless_reset_token`) and numeric ranges (`max_udp_payload_size` ≥ 1200, `ack_delay_exponent` ≤ 20, `max_ack_delay` < 2^14). (#111)
- Frame-pipeline guards: zero-frame packet → `PROTOCOL_VIOLATION`; unknown frame type → `FRAME_ENCODING_ERROR`. (#111)
- HTTP/3 RFC 9114 + 9204 conformance: 30 in-tree unit tests covering control-stream rules, pseudo-headers, stream-type uniqueness, push-id bounds, CONNECT validation, QPACK static-index and capacity limits, RFC 9218 priority signal, RFC 9297 SETTINGS_H3_DATAGRAM. (#112)
- `docs/h3_compliance.md`: RFC 9114 / 9204 / 9218 / 9297 matrix mapping every MUST and SHOULD to its test. (#112)

### Fixed
- Reject request streams carrying `:status` pseudo-header (RFC 9114 §4.3.1). (#112)
- `quic_qpack:set_dynamic_capacity/2` clamps to `max_allowed_capacity` per RFC 9204 §4.3. (#112)
- `quic:reset_stream/3` keeps the stream entry alive so subsequent `quic:stop_sending/3` emits STOP_SENDING instead of returning `{error, unknown_stream}`. (#113, #115)
- `quic:close/2` with an integer reason propagates that integer as the application error code; previously every input fell through to `?QUIC_APPLICATION_ERROR` (0x0c). (#114, #116)
- NEW_TOKEN received by a server and HANDSHAKE_DONE at the wrong level now route through `close_with_error/6` so the CLOSE frame reaches the peer when app keys are absent. (#111)

### Removed
- `quic_h3_h3spec_SUITE` and `docker/h3spec/`. The corpus is ported into `quic_h3_compliance_tests` as deterministic state-machine tests. (#112)

## [1.2.0] - 2026-04-21

Post-1.1.0 work split across three tracks: a client-side socket-backend
opt-in, a round of hot-path micro-optimisations on the send and
receive paths, and a migration fix for the default gen_udp client.

### Added
- Opt-in `socket_backend => socket` for client connections. Routes
  the client through `quic_socket:open_for_send/2` so it picks up the
  OTP socket NIF on Linux with GSO available per-message via cmsg,
  instead of the `gen_udp` port driver. +18% download throughput on
  arm64 Linux docker (10 MB bench); upload is neutral. (#88, #91)
- Client migration (`quic:migrate/1`) now works on the opt-in socket
  backend. Rebind closes the old OTP socket, stops its dedicated
  receiver process, opens a fresh one, and threads the new handle
  through the connection state. (#90)
- `quic_socket` `start_client_receiver` / `stop_client_receiver`:
  dedicated receiver process for the socket-backend client path
  (the OTP socket NIF has no `{active, N}` mode). (#88)
- `quic_socket:set_socket/2` swaps the underlying socket handle
  inside a `#socket_state{}` while preserving batching configuration.
  Used by the migration rebind path. (#93)
- Instrumentation counters `ack_sent` and `retransmits` on
  `quic_connection:get_stats/1` and the throughput bench output
  (Phase 0a). (#77, #78)

### Fixed
- `quic:migrate/1` on the default gen_udp client no longer drops
  post-migrate traffic. Rebinding previously left
  `#state.socket_state` pointing at the just-closed old socket; every
  send went through the dead handle and was silently dropped. Also
  flushes any pending batch to the old socket before rebind so
  pre-migrate packets reach the server under their original CID.
  (#93)
- `quic_dist`: simultaneous-connect deadlock in the accept path.
  Two nodes dialling each other within a tight window wedged both
  `net_kernel:connect_node/1` calls indefinitely. The old accept
  path ran the dist worker through a nine-hop handoff
  (register_pending / controller rendezvous in acceptor_loop) before
  reaching `dist_util:mark_pending`, so net_kernel's tie-breaker
  arbitration never ran in time. Collapsed to the TCP-dist shape:
  `accept_connection/5` runs `set_supervisor` + `start_timer` +
  `handshake_other_started` inline. Docker 5-node regression now
  passes 5/5. (#106)
- `quic_dist`: batch-yield path in `input_handler_loop` could lose
  or reorder buffered dist bytes when the mailbox had backlog.
  Yield now threads the buffer remnant through the normal return
  channel instead of piggybacking on the self-message. (#104)
- `quic_dist_user_stream_SUITE` / `accept_user_streams/2` doc:
  refreshed to match the auto-assign / direct
  `{quic_dist_stream, _, {data, _, _}}` delivery shape. (#105)
- `docker/dist`: 3+ node cluster mesh formation. Each node now dials
  only higher-named peers and boots with `-connect_all false`, so
  `global` does not re-introduce cross-dials behind the explicit
  test topology. (#95, #106)
- h3: preserve WebTransport and unknown SETTINGS identifiers in the
  peer settings map so extension-stream hooks can read them. (#96)
- `quic_socket`: client migrate path opens the new socket before
  closing the old one, avoiding a window where the client has no
  valid send handle. (#97)
- `quic_socket`: `client_recv_loop` exits cleanly on unexpected
  socket errors instead of spinning. (#98)
- `quic_socket`: clear the pending batch buffer on flush error so
  stale frames do not get retried on the next flush. (#99)
- `quic:connect/4`: reject the `socket` + `{socket_backend, socket}`
  option combination with a clear error instead of silently
  overriding one. (#100)
- Client connection: treat receiver-process exit as a fatal error
  and close the connection, matching server behaviour. (#101)
- Server: build a per-connection sender even when
  `server_send_batching` is `false` so the direct-send path uses the
  same `quic_socket` shape as the batched path. (#102, #103)

### Performance
- Fuse per-packet cwnd + pacing check into `quic_cc:send_check/3`
  (one BIF call and one record match instead of the previous four).
  (#79)
- Hoist per-chunk lookups (`stream_urgency`, `max_stream_data_per_packet`,
  pre-computed stream-frame header prefix) out of the chunked send
  loop. (#80, #85)
- ACK 1-RTT packets immediately on reorder (RFC 9002 §6.2) while
  keeping the decimation window for in-order traffic. (#81)
- Fast-path single-stream-frame in `contains_ack_eliciting_frames/1`
  on the bulk-upload hot path. (#82)
- Thread the updated `socket_state` back from `do_socket_send` via
  the return value, dropping the process-dictionary roundtrip. (#83)
- Replace the `crypto:exor/2` NIF call with inline Erlang XOR for
  the 1-4 byte header-protection mask. (#84)
- Inline the `?QLOG_ENABLED` check at packet/frame event call
  sites so the event-map is never built when qlog is off. (#86)
- Coalesce the `monotonic_time` samples on the receive hot path
  (one BIF call per received datagram instead of three). (#87)
- Flush the pending stream-data batch before emitting an ACK-only
  packet so it does not break GSO uniformity on the opt-in socket
  backend. +6.4% upload throughput on arm64 Linux docker. (#92)
- Re-enable GSO on the opt-in socket-backend client: drop the
  socket-level `UDP_SEGMENT` setsockopt and rely on per-message cmsg
  via `flush_gso/1`. (#91)

## [1.1.0] - 2026-04-18

Server-side throughput work. Per-connection send batching over the
shared listener socket on Linux + socket backend coalesces outgoing
packets into sendmsg super-datagrams via UDP_SEGMENT (GSO); on macOS /
gen_udp it is functionally neutral. Several GSO correctness fixes
after CI surfaced a handshake stall. Extra observability so tests and
operators can see the batching win directly.

### Added
- Per-connection send batching on the server. Each server connection
  owns a `quic_socket` batch buffer that reuses the listener's UDP
  socket. Gated by the new `server_send_batching` option on
  `start_server/3` (default `true`); set to `false` to fall back to
  the previous direct `gen_udp:send/4` path. (#66)
- `quic_socket:info/1` — map with `backend`, `gso_supported`,
  `gso_size`, `gro_enabled`, `batching_enabled`, `max_batch_packets`,
  and the new `batch_flushes` / `packets_coalesced` counters.
- `quic_socket:send_immediate/4` — public wrapper that bypasses the
  per-connection batch for one-shot control-plane sends.
- `quic_socket:new_sender/2` — build a per-connection sender that
  inherits backend + GSO capability from the listener without owning
  the socket.
- `quic_connection:get_stats/1` now returns `batch_flushes` and
  `packets_coalesced` so tests and benchmarks can assert batching
  behaviour rather than just wiring.
- `quic_server_batching_SUITE` — behaviour-level regression: real
  256 KB server-to-client downloads assert `packets_coalesced > 1`
  when batching is on, and both counters stay at 0 when disabled.
- `docker/gso-debug/` — Erlang 28 + tcpdump + strace container that
  reproduces the GSO handshake stall against a bind-mounted tree.
  (#74)
- `bench/run_download_bench.erl` and
  `quic_throughput_bench:run_download_sink/0,1` drive server-to-client
  bulk transfers and report MB/s alongside `batch_flushes` /
  `packets_coalesced` so the batching effect is visible next to
  throughput.

### Changed
- Stream send path is iovec-native. `quic_frame:encode_iodata/1`
  returns `[Header, Data]` and threads iodata through header
  protection and `quic_aead` without copying `Data` into a fresh
  binary. AEAD specs relaxed to accept iodata.
- 1-RTT ACKs delayed to every 2nd packet or `max_ack_delay` per
  RFC 9002 §6.2. Halves receiver ACK traffic on the server and
  sender event-processing on the client. Measured on macOS gen_udp:
  10 MB upload 45 → 56 MB/s. (#69)
- `quic_loss` switched to a single `queue:queue(#sent_packet{})` for
  outstanding packets. Per-ACK work scales with the ACK window, not
  the full outstanding queue. Measured on macOS gen_udp: 10 MB
  upload 55 → 59 MB/s, 5 MB download 34 → 50 MB/s. (#72)
- `flush_gso/1` passes the batch as an iov list directly to
  `socket:sendmsg/2` with the UDP_SEGMENT cmsg, saving up to
  ~76 KB of user-space copy per flush on a 64-packet batch. (#70)
- `send_app_packet_internal/3` samples `monotonic_time` once per
  packet and reuses it for loss tracking and `last_activity`. (#71)
- Per-packet overhead on the bulk-send path reduced: single
  `#state{}` update, PTO timer reschedule skipped when within
  tolerance, `process_send_queue` and pacing timeout short-circuit
  on empty queue, stream data normalised to binary once at the
  fragmentation boundary.
- `state_to_map/1` replaces the coarse `send_batching` boolean with
  three explicit fields: `send_backend` (`direct` | `gen_udp` |
  `socket`), `send_batching_enabled`, `send_gso_supported`.

### Fixed
- Server connection crashed with `function_clause` when the listener
  was on `socket_backend => socket` because `inet:sockname/1` rejects
  `{'$socket', Ref}` handles. Branch on socket shape:
  `socket:sockname/1` for OTP socket handles, `inet:sockname/1` for
  `gen_udp` ports.
- UDP_SEGMENT `setsockopt` now uses `sizeof(int)` (32-bit native)
  instead of u16, which Linux rejected with `EINVAL`; GSO capability
  detection silently returned false and the GSO CT job was skipping.
  The cmsg path already used u16 correctly. (#67)
- GSO skipped for single-packet batches: UDP_SEGMENT with a
  sub-`gso_size` single-packet payload drops silently on
  ubuntu-24.04. `batch_count == 1` has no segmentation work; fall
  through to `flush_individual`. (#73)
- Listener no longer sets UDP_SEGMENT at socket level. A socket-wide
  UDP_SEGMENT forces segmentation on every outbound datagram,
  including short handshake packets that can't be segmented. GSO is
  now applied only via the per-message cmsg in `flush_gso`. (#73)
- GSO bypassed when a batch mixes packet sizes (padded 1200-byte
  Initial + ~400-byte Handshake). UDP_SEGMENT requires every segment
  except the last to be exactly `gso_size`, otherwise the client
  sees undecodable datagrams and stalls at
  `awaiting_encrypted_extensions`. `flush/1` checks uniformity and
  falls through to `flush_individual` when it fails. (#75)
- Listener self-send: `send_packet/6` was calling `quic_socket:send/4`
  and dropping the returned state, so version-negotiation / retry /
  stateless-reset packets were buffered then lost on the socket
  backend with `batching_enabled=true`. Switched to
  `send_immediate/4`.
- `send_queue_bytes` accounting leaked on ACK-coalesce dequeues and
  could eventually trip `?MAX_SEND_QUEUE_BYTES` on long-lived
  connections. Added `send_queue_count` as an explicit O(1)
  emptiness predicate so zero-byte FIN-only sends enqueued under
  pacing are no longer stranded.
- `examples/echo_server.erl`: `handle_connection/2` expects a DCID
  binary, not an info map; returns `{ok, HandlerPid}` so the listener
  transfers ownership; peer address fetched via `quic:peername/1`.
  (#65)
- `examples/qlog_example.erl`: added a `connection_handler` so the
  server echoes client data; waits for the client connection to
  terminate before returning so the qlog writer flushes. (#68)

## [1.0.2] - 2026-04-16

### Fixed
- h3: thread FIN through the peer uni stream-type dispatch so a
  STREAM frame carrying type-varint + payload + FIN surfaces as one
  `{stream_type_data, uni, _, _, true}` event to claimed-stream
  owners (#64)

## [1.0.1] - 2026-04-15

### Fixed
- h3: consult `stream_type_handler` on fresh peer-initiated bidi
  streams so extensions can claim them before default request
  handling (#62)
- docs: `rebar3 ex_doc` now runs clean (#63)

## [1.0.0] - 2026-04-15

First release with HTTP/3. Brings full client + server HTTP/3
(RFC 9114) with QPACK (RFC 9204), HTTP Datagrams (RFC 9297),
Server Push, Extensible Priorities, Extended CONNECT, and the
extension-stream hooks WebTransport needs. Also a critical
flow-control deadlock fix in the QUIC core, a BBR loopback
throughput fix, and the H3 server owner default change.

### HTTP/3 (`quic_h3`, new module)

#### Added
- HTTP/3 client and server (RFC 9114) with QPACK header compression
  (RFC 9204): request/response, body data, trailers, GOAWAY,
  cancellation, CLI tools (`bin/quic_h3c`, `bin/quic_h3d`)
- Server Push (RFC 9114 §4.6): `push/3`, `send_push_response/4`,
  `send_push_data/4`, `set_max_push_id/2`, `cancel_push/2`
- Extensible Priorities (RFC 9218): `priority` request option,
  PRIORITY_UPDATE frames, urgency / incremental hints
- Extended CONNECT (RFC 9220) for WebTransport-style upgrades
- HTTP Datagrams (RFC 9297): `send_datagram/3`,
  `h3_datagrams_enabled/1`, `max_datagram_size/2`, capsule framing
- Extension-stream hook: `stream_type_handler` option on
  `start_server/3` claims peer-initiated uni and bidi streams whose
  first varint matches a caller-supplied filter; claimed bytes are
  delivered as `{stream_type_data, ...}` owner messages instead of
  being parsed as HTTP/3 requests. Owner also receives
  `stream_type_open`, `stream_type_closed`, `stream_type_reset`,
  `stream_type_stop_sending` events
- Client-initiated extension streams: `quic_h3:open_bidi_stream/1,2`
  pre-claims a bidi stream with a signal-type varint (e.g.
  WebTransport's `0x41`) so inbound bytes route through the
  claimed-bidi path
- Per-connection owner override via `connection_handler` callback on
  `start_server/3` for hosting many sessions per listener
- Per-stream handler registration: `set_stream_handler/3,4`,
  `unset_stream_handler/2` to redirect body data to a worker pid
- Query API: `get_settings/1`, `get_peer_settings/1`,
  `get_quic_conn/1`
- Documentation: `docs/HTTP3.md` reference + benchmarks section
- E2E test infrastructure: `quic_h3_e2e_SUITE`, `quic_h3_h3spec_SUITE`,
  `quic_h3_owner_SUITE`; dedicated CI job
- Performance benchmark: `quic_h3_bench`

#### Changed
- Server connection owner now defaults to the listener gen_server
  (long-lived, trap_exit'ed) instead of the `start_server` caller
  pid; durable owners for datagram / stream-type events should be
  supplied via the per-connection `connection_handler` callback
- SETTINGS directionality validation tightened to RFC 9114

#### Fixed
- Server connections wedged with `connect_timeout` when the process
  that called `start_server/3` exited before a client arrived and
  either `h3_datagram_enabled` or `stream_type_handler` was set
- Discard unknown unidirectional stream payload (RFC 9114 §6.2
  unknown-stream-type rule) instead of erroring the connection
- Emit trailing empty DATA event when response carries FIN so owners
  always see `Fin = true` exactly once
- Strict PRIORITY_UPDATE frame parsing per RFC 9218
- DoS hardening on header / capsule / frame parsing
- Header / trailer / `:path` / `:status` symmetry between client and
  server validation
- GOAWAY drain enforcement: reject new requests after a GOAWAY is
  sent or received
- Server push lifecycle correctness (PUSH_PROMISE pairing, duplicate
  detection, MAX_PUSH_ID enforcement)
- Tighten RFC 9114 / 9204 compliance across multiple parsers
- `sync` option on `connect/3` resolves an E2E race where the client
  tried to send before SETTINGS exchange completed
- Improved frame error handling and header validation
- aioquic SETTINGS compatibility
- QPACK: encoder eviction guard prevents references to
  unacknowledged dynamic-table entries; rejects `Increment = 0`

### QUIC transport

#### Added
- Spin bit (RFC 9000 §17.4)
- Stateless reset support (RFC 9000 §10.3)
- Full NEW_TOKEN issuance and validation loop
- `RESET_STREAM_AT` transport parameter and frame plumbing
- `quic:set_congestion_control/2` runtime CC switch API
- `quic:get_peer_transport_params/1` introspection API

#### Changed
- BBR internal clock switched to microseconds; loopback transfers no
  longer pin to the InitialRtt fallback

#### Fixed
- Stream-level `MAX_STREAM_DATA` window stopped sliding once
  `recv_max_data` reached `fc_max_receive_window` (8 MB default).
  Past the cap, the auto-tune re-sent the same value forever and the
  sender stalled at 8 MB lifetime per stream. The window now slides
  past `recv_offset` like the connection-level window already does
- BBR loopback throughput regression: ms-precision clock collapsed
  delivery-rate intervals to 0/1 ms and clamped BDP to the 4-packet
  minimum, holding throughput at ~0.03 Mbps. Microsecond-precision
  internal clock restores expected behavior
- Send `MAX_STREAMS` as peer-initiated streams complete
  (RFC 9000 §4.6); previously peers could exhaust the stream-id space

### Distribution (`quic_dist`)

#### Added
- User-accessible streams API: `quic_dist:open_stream/1,2`, `send/3`,
  `close_stream/1`, `reset_stream/1,2`, `controlling_process/2`,
  `list_streams/0,1`, with acceptor pool and stream priorities
- Connection migration logging
- Distributed Erlang benchmarks + multi-node test scripts
- Per-iteration latency stats in throughput benchmark (min/p50/p99/max
  + timeout counts)

#### Changed
- Test runner logs each test's results as it returns rather than at
  the end, so a stalled middle test no longer hides the others

### Tests and infrastructure
- `quic_e2e_*_SUITE` and `quic_h3_e2e_SUITE` run against in-process
  servers; Docker no longer required for these jobs

## [0.11.0] - 2026-04-09

### Added
- Full QUIC connection migration support (RFC 9000 Section 9)
  - Server-side address change detection (NAT rebinding vs active migration)
  - Path validation with PATH_CHALLENGE/PATH_RESPONSE
  - CID rotation for path unlinkability
  - `disable_active_migration` transport parameter
- Application error code support for CONNECTION_CLOSE frames
- Client certificate support (`verify` server option)
- CUBIC congestion control (RFC 9438)
- BBR congestion control
- HyStart++ slow start (RFC 9406) for all CC algorithms
- UDP packet batching with GSO/GRO support
- Configurable UDP buffer sizing (recbuf/sndbuf options)
- QLOG tracing for debug visibility
- Pluggable congestion control behavior
- Stream deadlines for per-stream timeout control
- STOP_SENDING API (`quic:stop_sending/3`)
- `max_udp_payload_size` transport parameter
- Async send API and socket receive optimizations
- Throughput benchmarks (`quic_throughput_bench`, `quic_batch_bench`)
- QUIC-based Erlang distribution (`quic_dist`) for node communication over QUIC
- Distribution modules: `quic_dist`, `quic_dist_controller`, `quic_dist_sup`
- EPMD replacement module (`quic_epmd`) for QUIC-based node discovery
- Discovery backends: `quic_discovery_static` (static config), `quic_discovery_dns` (DNS SRV)
- Session ticket storage (`quic_dist_tickets`) for 0-RTT reconnection
- Stream prioritization for distribution: control stream (urgency 0), data streams (urgency 4-6)
- Backpressure mechanism for distribution congestion control
- Keep-alive PING frames for transport-level liveness (configurable via `keep_alive_interval`)
- `quic:get_stats/1` API for connection packet counts (used for liveness detection)
- `quic:send_ping/1` API for transport-level PING frames
- RTT-based flow control auto-tuning for improved throughput
- Packet pacing (RFC 9002 Section 7.7) to prevent bursts

### Changed
- ConnRef is now connection PID (simpler API)
- Improved ACK processing performance (O(n^2) to O(n) with gb_sets)
- Timer batching for reduced overhead
- Zero-copy packet processing optimizations
- Distribution liveness detection now uses QUIC packet counts instead of application ticks
- Improved congestion control with quic-go-inspired settings (larger initial cwnd)
- Flow control windows auto-tune based on RTT measurements

### Fixed
- Throughput regression in connection migration (wasteful binary allocation)
- CUBIC cwnd collapse issue
- BBR delivery rate interval causing cwnd collapse
- BBR initial pacing rate causing transfer hangs
- Pacing precision loss causing transfer stalls
- Various RFC compliance fixes for QUIC connection migration
- `net_tick_timeout` errors under heavy load by using QUIC-level activity as liveness proof
- Stream flow control `recv_max_data` using wrong limits
- Distribution controller backpressure data loss
- Congestion control protocol compliance issues
- Recovery exit when only non-ack-eliciting packets are ACKed
- Tick timeout issues in distribution controller
- Flow control blocking that caused deadlocks
- Message framing for large message transfers

### Removed
- NAT traversal support from `quic_dist` (use standard QUIC connection migration instead)

## [0.10.2] - 2026-02-21

### Fixed
- Deprecated `catch` expressions replaced with `try...catch...end`
- Undefined `dynamic()` type replaced with `term()` in type specs
- CI workflow consolidated with separate unit-tests, e2e, and interop jobs

## [0.10.1] - 2026-02-21

### Fixed
- ACK range encoding crash for out-of-order packets: when packets arrived out
  of order (e.g., 10, 5, 6), ACK ranges were not properly maintained in
  descending order or merged, causing negative Gap values that crashed
  `quic_varint:encode/1` with `badarg`

## [0.10.0] - 2026-02-21

### Added
- RFC 9312 QUIC-LB Connection ID encoding support for load balancer routing
- New `quic_lb` module with three encoding algorithms:
  - Plaintext: server_id visible in CID (no encryption)
  - Stream Cipher: AES-128-CTR encryption of server_id
  - Block Cipher: 4-round Feistel network for <16 bytes, AES-CTR for 16 bytes,
    truncated cipher for >16 bytes
- `#lb_config{}` record for LB configuration (algorithm, server_id, key, nonce_len)
- `#cid_config{}` record for CID generation configuration
- `lb_config` option in `quic_listener` to enable LB-aware CID generation
- Variable DCID length support in short header packet parsing
- LB-aware CID generation in `quic_connection` for NEW_CONNECTION_ID frames
- E2E test suite `quic_lb_e2e_SUITE` with 21 integration tests
- `quic:server_spec/3` to get a child spec for embedding QUIC servers in custom
  supervision trees
- Stream reassembly test suite `quic_stream_reassembly_SUITE` for ordered delivery
  verification

### Changed
- `quic:set_owner/2` is now asynchronous (cast instead of call)

### Fixed
- `quic:get_server_port/1` now returns the actual OS-assigned port when server
  was started with port 0 (ephemeral port), instead of returning 0
- `quic:get_server_connections/1` now correctly returns connection PIDs; was
  returning empty list due to `get_listeners/1` returning supervisor pids
  instead of actual listener processes
- Removed redundant `link/1` call in listener (connection already linked via
  `gen_statem:start_link`)
- Unhandled calls in connection state machine now return `{error, {invalid_state, State}}`
  instead of silently timing out
- Server-side connection termination no longer closes shared listener socket:
  previously when a server connection terminated, it would close the UDP socket
  shared with the listener, breaking all subsequent connections
- Cancel delayed ACK timer in connection terminate to prevent timer messages
  to dead processes
- Session ticket table now has TTL (7 days) and size limit (10,000 entries) to
  prevent unbounded memory growth
- Listener now properly cleans up ETS tables on terminate (standalone mode only,
  pool mode tables are managed by the pool manager)
- Draining state now uses calculated `3 * PTO` timeout per RFC 9000 Section 10.2
  instead of hardcoded 3 seconds
- Pre-connection pending data queue now has size limit (1000 entries) to prevent
  memory exhaustion from slow handshakes
- Buffer contiguity calculation now has iteration limit to prevent stack overflow
  with highly fragmented receive buffers
- Stream data is now properly reassembled before delivery: previously data was
  delivered immediately as received, causing corruption when packets arrived out
  of order during large file transfers. Data is still streamed incrementally as
  contiguous chunks become available
- Server connections no longer modify listener's socket active state: server-side
  connections were calling `inet:setopts(Socket, [{active, once}])` on the shared
  listener socket, overriding the listener's `{active, N}` configuration and
  causing the socket to go passive after receiving packets

## [0.9.0] - 2026-02-20

### Added
- Multi-pool server support with ranch-style named server pools
- `quic:start_server/3` to start named server with connection pooling
- `quic:stop_server/1` to stop named server
- `quic:get_server_info/1` to get server information (pid, port, opts, started_at)
- `quic:get_server_port/1` to get server listening port
- `quic:get_server_connections/1` to get server connection PIDs
- `quic:which_servers/0` to list all running servers
- Application supervision structure (`quic_app`, `quic_sup`, `quic_server_sup`)
- ETS-based server registry (`quic_server_registry`) with process monitoring
- `pool_size` option for listener process pooling with SO_REUSEPORT
- FreeBSD CI testing workflow
- Expanded Linux CI matrix (Ubuntu 22.04/24.04, OTP 26-28)

### Changed
- `quic.app.src` now includes `{mod, {quic_app, []}}` for OTP application behaviour
- Listener supervisor registers with server registry on init for restart recovery

## [0.8.0] - 2026-02-20

### Added
- Stream prioritization (RFC 9218): urgency-based scheduling with 8 priority
  levels (0-7) and incremental delivery flag
- `quic:set_stream_priority/4` and `quic:get_stream_priority/2` API
- Bucket-based priority queue for O(1) stream scheduling
- Preferred address handling (RFC 9000 Section 9.6): server can advertise a
  preferred address during handshake, client validates via PATH_CHALLENGE and
  automatically migrates to validated preferred address
- `preferred_ipv4` and `preferred_ipv6` listener options for server configuration
- `#preferred_address{}` record for IPv4/IPv6 addresses, CID, and reset token
- `quic_tls:encode_preferred_address/1` and `quic_tls:decode_preferred_address/1`
- Idle timeout enforcement (RFC 9000 Section 10.1): when `idle_timeout` option
  is set, internal timer automatically closes connection after timeout with no
  activity (set to 0 to disable)
- Persistent congestion detection (RFC 9002 Section 7.6): detects prolonged packet
  loss spanning > PTO * 3 and resets cwnd to minimum window
- Frame coalescing: ACK frames are coalesced with small pending stream data
  (< 500 bytes) for more efficient packet utilization

## [0.7.1] - 2026-02-20

### Fixed
- Packet number reconstruction per RFC 9000 Appendix A: truncated packet numbers
  are now properly reconstructed using the largest received PN, fixing decryption
  failures for large responses (>255 packets with 1-byte PN encoding)

## [0.7.0] - 2026-02-20

### Added
- Docker interop runner integration (client and server images)
- Session resumption interop test (`resumption`)
- 0-RTT early data interop test (`zerortt`)
- Connection migration interop test (`connectionmigration`)
- `quic:migrate/1` API for triggering active path migration
- All 10 QUIC Interop Runner test cases now pass:
  - handshake, transfer, retry, keyupdate, chacha20, multiconnect, v2,
    resumption, zerortt, connectionmigration

### Fixed
- Connection-level flow control: now properly tracks `data_received` and sends
  MAX_DATA frames when 50% of connection window is consumed (RFC 9000 Section 4.1)
- Large downloads: interop client now writes to disk incrementally (streaming)
  instead of accumulating in memory
- Server DCID initialization: server now correctly sets DCID from client's
  Initial packet SCID field, fixing short header packet alignment
- Key update HP key preservation: header protection keys are no longer rotated
  during key updates per RFC 9001 Section 6.6
- Fixed bit validation: skip padding bytes (0x00) and invalid short headers
  (fixed bit not set) in coalesced packets
- Role-based key selection in 1-RTT packet decryption

## [0.6.5] - 2026-02-19

### Added
- `quic_listener:start/2` for unlinked listener processes
- `set_owner` call handling in idle and handshaking states

### Fixed
- IPv4/IPv6 address family matching when opening client sockets
- Race condition: transfer socket ownership before sending packet
- Handle header unprotection errors gracefully in packet decryption
- Removed verbose debug logging from listener

## [0.6.4] - 2026-02-17

### Fixed
- Server now selects correct signature algorithm based on key type (EC vs RSA)

## [0.6.3] - 2026-02-17

### Fixed
- Fixed transport params parsing in ClientHello - properly unwrap {ok, Map} result

## [0.6.2] - 2026-02-17

### Fixed
- Fixed key selection for all packet types based on role (server vs client)
- Server now uses correct keys for both sending and receiving packets
- Fixed Initial, Handshake, and 1-RTT packet encryption/decryption

## [0.6.1] - 2026-02-17

### Fixed
- Server-side packet decryption now uses correct keys (client keys for Initial/Handshake packets received from clients)

## [0.6.0] - 2026-02-17

### Added
- DATAGRAM frame support (RFC 9221) for unreliable data transmission
- `quic:set_owner/2` to transfer connection ownership (like gen_tcp:controlling_process/2)
- `quic:peercert/1` to retrieve peer certificate (DER-encoded)
- `quic:send_datagram/2` to send QUIC datagrams
- Connection handler callback in `quic_listener` for custom connection handling
- ACK delay for datagram-only packets per RFC 9221 Section 5.2
- Proper ACK generation at packet level for all ack-eliciting frames

### Fixed
- Datagrams are not retransmitted on loss (RFC 9221 compliance)
- ACKs now sent for all ack-eliciting frames, not just stream data

## [0.5.1] - 2026-02-17

### Fixed
- Pad payload for header protection sampling to prevent crashes during PTO timeout

## [0.5.0] - 2026-02-17

### Added
- Retry packet handling (RFC 9000 Section 8.1)
- Stateless reset support (RFC 9000 Section 10.3)
- Connection ID limit enforcement (RFC 9000 Section 5.1.1)
- ECN support for congestion control (RFC 9002 Section 7.1)
- RFC 9000/9001 test vectors
- Interoperability test suite with quic-go server
- E2E tests in CI pipeline

### Fixed
- CI compatibility with OTP 28 (use rebar3 nightly)
- quic-go Docker build (pin to v0.48.2)

## [0.4.0] - 2025-02-17

### Changed
- Moved `doc/` to `docs/` to prevent ex_doc from overwriting documentation
- Consolidated `hash_len/1` and `cipher_to_hash/1` functions in `quic_crypto` module
- Refactored key derivation in `quic_keys` using `cipher_params/1` helper
- Improved socket cleanup on initialization failure in `quic_connection`

### Removed
- Removed `send_headers/4` API (HTTP/3 functionality, not core QUIC transport)

### Fixed
- Added bounds checking for header protection sample extraction in `quic_aead`
- Added CID length validation (max 20 bytes per RFC 9000) in `quic_packet`
- Added token length validation in `quic_packet`
- Added frame data length limits in `quic_frame` to prevent memory exhaustion
- Added ACK range limits in `quic_ack` to prevent DoS attacks
- Fixed weak random: use `crypto:strong_rand_bytes/1` for ticket age_add
- Fixed dialyzer warning in `quic_tls` by adding error handling to `decode_transport_params/1`

## [0.3.0] - 2025-02-16

### Added
- Server mode with `quic_listener` module
- 0-RTT early data support (RFC 9001 Section 4.6)
- Connection migration support (RFC 9000 Section 9)
- Key update support (RFC 9001 Section 6)

## [0.2.0] - 2025-02-15

### Added
- Stream multiplexing (bidirectional and unidirectional)
- Flow control (connection and stream level)
- Congestion control (NewReno)
- Loss detection and packet retransmission (RFC 9002)

## [0.1.0] - 2025-02-14

### Added
- Initial release
- TLS 1.3 handshake (RFC 8446)
- Basic QUIC transport (RFC 9000)
- AEAD packet protection (RFC 9001)
