%% quic_connection #state{} record, shared with its unit-test support module.
-ifndef(QUIC_CONNECTION_STATE_HRL).
-define(QUIC_CONNECTION_STATE_HRL, true).

%% PTO reset tolerance in milliseconds.
%% set_pto_timer/1 skips the cancel + reschedule cycle when the new PTO
%% deadline is within this many ms of the currently scheduled deadline.
%% Stays well below the RFC 9002 minimum PTO so it does not break
%% retransmission semantics.
-define(PTO_RESET_TOLERANCE_MS, 2).

%% Most handshake bytes per space the congestion window may hold back at
%% once. A large certificate chain runs to tens of kilobytes and a
%% post-quantum key exchange to more, so this sits far above any real
%% flight: reaching it means this endpoint is malfunctioning.
-define(MAX_PENDING_HS_BYTES, 1048576).

%% ACK packet tolerance for 1-RTT (RFC 9002 §6.2).
%% The receiver SHOULD send an ACK frame in response to at least every
%% second ack-eliciting packet. 2 is the RFC floor; higher values trade
%% ACK traffic for RTT-sample granularity.
-define(ACK_PACKET_TOLERANCE, 2).

%% Default per-drain send burst budget in packets (max_burst_packets
%% option). See the burst_budget field.
-define(DEFAULT_MAX_BURST_PACKETS, 64).

%% Indexes into the per-connection counters array (#state.counters).
-define(C_PACKETS_SENT, 1).
-define(C_PACKETS_RECEIVED, 2).
-define(C_ACK_SENT, 3).
-define(C_RETRANSMITS, 4).
-define(C_DATAGRAM_SENT, 5).
-define(C_DATAGRAM_SEND_DROPPED, 6).
-define(C_DATAGRAM_RECV_DELIVERED, 7).
-define(C_DATAGRAM_RECV_DROPPED, 8).
-define(C_SEND_QUEUE_FULL_REFUSALS, 9).
-define(N_COUNTERS, 9).

%% Connection state record
%% Write-once connection configuration, set in init/1 and never
%% updated. Kept apart from #state{} so a state update copies one
%% pointer for all of it.
-record(conn_cfg, {
    %% Connection identity
    scid :: binary(),
    original_dcid :: binary(),
    %% Server-side only. The Retry SCID to echo back as
    %% retry_source_connection_id (RFC 9000 §7.3) when this connection
    %% was spawned from a retried Initial.
    retry_scid_for_tp = undefined :: binary() | undefined,
    role :: client | server,
    %% Acceptable versions in preference order (RFC 9368); the head of
    %% the list is what we advertise as most preferred.
    supported_versions = [?QUIC_VERSION_1] :: [non_neg_integer()],
    %% Dedicated send socket for server connections (SO_REUSEPORT)
    %% Allows each server connection to have its own batching state
    send_socket :: gen_udp:socket() | undefined,
    %% Client socket backend selector (gen_udp | socket). When `socket'
    %% the client uses the OTP socket NIF via open_for_send/2 and a
    %% dedicated receiver process forwards {udp, ...} messages to this
    %% connection. Ignored for server connections (the listener picks).
    client_socket_backend = gen_udp :: gen_udp | socket | adapter,
    local_addr :: {inet:ip_address(), inet:port_number()} | undefined,
    conn_ref :: reference(),
    verify :: boolean(),
    %% Trust anchors (DER): a client validates the server cert against these, a
    %% server validates a presented client cert; undefined = OS store
    cacerts :: [binary()] | undefined,
    %% Server-side mutual TLS: require a valid client certificate. When false, an
    %% empty client Certificate is accepted (optional mTLS, RFC 8446 §4.4.2.4).
    require_client_cert = false :: boolean(),

    %% Key-exchange + signature negotiation (RFC 8446 §4.1.4 / §4.2.3)
    tls_groups = [x25519] :: [atom()],
    tls_sig_algs :: [atom()] | undefined,
    cipher_preference = [aes_128_gcm, aes_256_gcm, chacha20_poly1305] :: [atom()],
    alpn_list :: [binary()],
    %% Per-stream flow control limits (advertised in transport params)
    max_stream_data_bidi_local :: non_neg_integer(),
    max_stream_data_bidi_remote :: non_neg_integer(),
    max_stream_data_uni :: non_neg_integer(),
    fc_max_receive_window :: non_neg_integer(),
    %% Credit for `auto' streams and the connection is withheld while the
    %% owner's mailbox holds more than this, and re-checked on credit_timer
    max_owner_queue = ?DEFAULT_MAX_OWNER_QUEUE :: pos_integer() | infinity,

    %% Largest UDP payload we advertise being willing to receive
    %% (RFC 9000 §18.2). `undefined' means "derive it from the local
    %% address family" rather than the PMTU probing ceiling.
    max_udp_payload_size_local = undefined :: pos_integer() | undefined,

    %% Datagram support (RFC 9221)
    %% Local: our advertised max size (0 = disabled)
    max_datagram_frame_size_local = 0 :: non_neg_integer(),
    %% Bounded receive queue for DATAGRAM frames. `infinity' disables
    %% the cap entirely (default). When finite, we still push each
    %% datagram to the owner process, but we also drop the oldest entry
    %% in this queue when the limit is hit so that `datagram_stats/1'
    %% surfaces dropped counts for backpressure decisions.
    datagram_recv_queue_len = infinity :: non_neg_integer() | infinity,
    spin_bit_enabled = true :: boolean(),

    %% Server-wide secret used to HMAC stateless-reset tokens over a
    %% connection id (RFC 9000 §10.3.2). `undefined' preserves today's
    %% per-CID random-token fallback — acceptable for clients and for
    %% single-instance servers that don't need post-restart recovery.
    stateless_reset_secret = undefined :: binary() | undefined,

    %% RESET_STREAM_AT support (draft-ietf-quic-reliable-stream-reset-07)
    %% Local: whether we advertise support for RESET_STREAM_AT
    reset_stream_at_enabled = false :: boolean(),

    %% Timers
    idle_timeout :: non_neg_integer(),

    %% Keep-alive (RFC 9000 - PING frames for liveness)
    keep_alive_interval :: non_neg_integer() | disabled,

    %% Give up on an unresponsive peer: close the connection when
    %% ack-eliciting data has been in flight with no ACK for this long
    %% (RFC 9000 permits idle-timeout-only, but a stateless-reset-blind
    %% peer then lingers for the whole idle timeout; msquic uses a 16 s
    %% disconnect timeout for the same reason).
    disconnect_timeout = 16000 :: pos_integer() | infinity,
    pacing_enabled = true :: boolean(),

    %% Server-specific fields
    listener :: pid() | undefined,
    %% Per-SNI cert selection (RFC 6066 §3). When set, invoked on the
    %% ClientHello server_name to override the cert fields above.
    sni_callback ::
        fun((binary() | undefined) -> {ok, map()} | {error, term()}) | undefined,
    %% Server preferred address config (RFC 9000 Section 9.6)
    %% Set from listener options: {IPv4, IPv6} where each is {Addr, Port} | undefined
    server_preferred_address :: #preferred_address{} | undefined,

    %% Client certificate (for mutual TLS)
    client_cert :: binary() | undefined,
    client_cert_chain = [] :: [binary()],
    client_private_key :: term() | undefined,
    %% Server-side: the issuing listener's table, the only place a
    %% ticket presented to this connection is looked up
    ticket_table :: ets:table() | undefined,

    %% TLS 1.3 External PSK (RFC 8446 §4.2.11)
    %% Client-side: offered to the peer. Two-tuple form defaults to
    %% modes [psk_dhe_ke]; three-tuple form takes an explicit list.
    external_psk ::
        {binary(), binary()}
        | {binary(), binary(), [psk_dhe_ke | psk_ke]}
        | undefined,
    %% Server-side: configured PSK lookup (callback wins, map as fallback).
    psk_config ::
        #{
            psk_callback => fun((binary()) -> {ok, binary()} | not_found) | undefined,
            psks => #{binary() => binary()} | undefined
        }
        | undefined,

    %% QUIC-LB CID configuration (RFC 9312)
    cid_config :: #cid_config{} | undefined,

    %% Backpressure configuration (for distribution connections)
    %% Connection is congested when queue > cwnd * congestion_threshold
    congestion_threshold = 2 :: pos_integer(),

    %% Statistics, indexed by the ?C_* macros: QUIC packets sent and
    %% received (net_kernel getstat liveness), ACK frames emitted alone or
    %% on a data packet, CC-permitted retransmissions, DATAGRAM frames sent,
    %% dropped on send, delivered and dropped on receive, and writes
    %% refused with send_queue_full. Mutable, so bumping one copies
    %% nothing.
    counters = counters:new(?N_COUNTERS, [atomics]) :: counters:counters_ref(),

    %% Socket active mode - number of packets before socket goes passive
    %% Using {active, N} instead of {active, once} reduces inet:setopts overhead
    active_n = 100 :: pos_integer(),
    pmtu_raise_interval = ?PMTU_DEFAULT_RAISE_INTERVAL :: pos_integer(),

    %% Per-drain send burst budget (max_burst_packets option). Bounds
    %% how many packets one drain emits before the remainder is queued
    %% and a zero-delay pacing continuation is armed, yielding to the
    %% event loop so ACK/loss feedback interleaves with bulk sending.
    %% Without the bound a large cwnd lets a single send event emit
    %% hundreds of packets back-to-back, which overflows slow receivers
    %% (GSO bursts especially) before any loss signal is seen.
    burst_budget = ?DEFAULT_MAX_BURST_PACKETS :: pos_integer(),
    %% Opt-in (delivery_coalescing option): merge consecutive
    %% same-stream stream_data deliveries of one receive pass into a
    %% single owner message. QUIC gives no message-boundary guarantee,
    %% but owners that decode each delivery as one complete
    %% application message (rather than length-framing the byte
    %% stream) break when deliveries merge, so the default keeps the
    %% one-message-per-packet behaviour.
    delivery_coalescing = false :: boolean(),
    %% How many ack-eliciting 1-RTT packets to accumulate before
    %% flushing an ACK. 2 is the RFC 9000 §13.2.1 recommendation;
    %% higher values trade ACK traffic (and receiver CPU) for RTT
    %% sample granularity and slower loss feedback, bounded by the
    %% max_ack_delay timer either way.
    ack_packet_tolerance = ?ACK_PACKET_TOLERANCE :: pos_integer(),

    %% QLOG Tracing (draft-ietf-quic-qlog-quic-events)
    qlog_ctx :: #qlog_ctx{} | undefined
}).

%% Handshake, TLS and peer identity state. Read on the hot path but
%% written only around the handshake, so it is kept out of #state{}:
%% a #state update copies one pointer for all of it.
-record(hs, {
    %% Retry handling (RFC 9000 Section 8.1)

    % Token from Retry packet for Initial resend
    retry_token = <<>> :: binary(),
    % Whether a Retry packet has been received
    retry_received = false :: boolean(),
    %% Server-side only. When the listener already validated the
    %% client's Initial token (and by implication its source address),
    %% the per-connection Initial-token validator skips its recheck.
    address_validated = false :: boolean(),
    %% RFC 9000 §8.1 anti-amplification (server, pre-validation). Cap
    %% bytes sent to <= 3x bytes received until the peer's address is
    %% validated; a datagram over budget is held in pending_hs and tried
    %% again when more is received or the address becomes validated.
    amp_rx = 0 :: non_neg_integer(),
    amp_tx = 0 :: non_neg_integer(),
    % SCID from Retry packet (for transport param validation)
    retry_scid :: binary() | undefined,

    %% Options
    server_name :: binary() | undefined,

    %% Encryption keys per level
    initial_keys :: {#crypto_keys{}, #crypto_keys{}} | undefined,
    %% Pre-switch Initial keys kept through compatible version
    %% negotiation, so first-flight packets in the original version
    %% still decrypt (RFC 9368 §2.2).
    initial_keys_alt :: {non_neg_integer(), {#crypto_keys{}, #crypto_keys{}}} | undefined,
    handshake_keys :: {#crypto_keys{}, #crypto_keys{}} | undefined,

    %% TLS state
    tls_state :: atom(),
    tls_private_key :: quic_crypto:kex_private() | undefined,
    tls_transcript = <<>> :: binary(),
    handshake_secret :: binary() | undefined,
    master_secret :: binary() | undefined,
    server_hs_secret :: binary() | undefined,
    client_hs_secret :: binary() | undefined,
    %% Peer's offered signature_algorithms (wire codes), set on the
    %% server when the ClientHello is parsed.
    peer_sig_algs = [] :: [non_neg_integer()],
    %% CertificateVerify scheme chosen for this handshake (wire code).
    cert_verify_code :: non_neg_integer() | undefined,
    %% Group of the key_share we sent (client) / selected (server)
    tls_group = x25519 :: atom(),
    %% HelloRetryRequest bookkeeping
    hrr_sent = false :: boolean(),
    hrr_group :: atom() | undefined,
    %% Outgoing Initial-level CRYPTO stream offset. Stays 0 for a
    %% one-shot flight; bumps after HRR so CH2 / ServerHello continue
    %% the stream (RFC 9001 §4.1.3).
    initial_tx_off = 0 :: non_neg_integer(),
    %% Client-side: CH1 random + build opts, needed to rebuild CH2
    tls_ch1_random :: binary() | undefined,
    %% Client-side: the Certificate(+CertificateVerify)+Finished payload,
    %% retained until HANDSHAKE_DONE so a lost Finished can be resent -
    %% nothing else retransmits it once the statem has left `handshaking'.
    client_hs_flight = undefined :: undefined | binary(),
    tls_ch1_opts :: map() | undefined,
    %% Negotiated values surfaced in the connected event
    negotiated_group :: atom() | undefined,
    negotiated_scheme :: atom() | undefined,

    %% CRYPTO frame buffer (per level: initial, handshake, app)
    crypto_buffer = #{
        initial => gb_trees:empty(), handshake => gb_trees:empty(), app => gb_trees:empty()
    } :: map(),
    crypto_offset = #{initial => 0, handshake => 0, app => 0} :: map(),
    %% Incomplete TLS message buffer (data that couldn't be parsed yet)
    tls_buffer = #{initial => <<>>, handshake => <<>>, app => <<>>} :: map(),

    %% Packet number spaces
    pn_initial :: #pn_space{},
    pn_handshake :: #pn_space{},
    %% Handshake payloads the congestion window or pacer refused, held as
    %% frames rather than encoded packets so no packet number is spent
    %% until one actually goes out. Drained when an acknowledgement
    %% reopens the window.
    pending_hs = #{initial => queue:new(), handshake => queue:new()} :: #{
        quic_loss:space() => queue:queue({iodata(), [term()]})
    },
    %% Payload bytes held in pending_hs, per space, against
    %% ?MAX_PENDING_HS_BYTES.
    pending_hs_bytes = #{initial => 0, handshake => 0} :: #{
        quic_loss:space() => non_neg_integer()
    },
    %% Set while a probe is being sent, which RFC 9002 Section 7 exempts
    %% from the congestion window.
    hs_probe = false :: boolean(),
    %% Client-side: a Handshake acknowledgement has arrived, so the
    %% server has validated this address (RFC 9002 Appendix A.8
    %% PeerCompletedAddressValidation). Always true for a server, which
    %% reads the predicate directly rather than this field.
    handshake_ack_received = false :: boolean(),

    %% Peer certificate (received during TLS handshake)
    peer_cert :: binary() | undefined,
    peer_cert_chain = [] :: [binary()],
    server_cert :: binary() | undefined,
    server_cert_chain = [] :: [binary()],
    server_private_key :: term() | undefined,
    %% True if server sent CertificateRequest
    cert_request_received = false :: boolean(),

    %% Session resumption (RFC 8446 Section 4.6)
    resumption_secret :: binary() | undefined,
    % Default max 0-RTT data size
    max_early_data = 16384 :: non_neg_integer(),

    %% Client-side ticket storage for session resumption
    ticket_store = #{} :: quic_ticket:ticket_store(),
    %% Per-handshake: identity/secret/mode the server selected, or undefined.
    selected_psk ::
        undefined
        | #{
            identity => binary(),
            identity_idx => non_neg_integer(),
            secret => binary(),
            mode => psk_dhe_ke | psk_ke,
            source => external | ticket
        },

    %% 0-RTT / Early Data (RFC 9001 Section 4.6)

    % {Keys, EarlySecret}
    early_keys :: {#crypto_keys{}, binary()} | undefined,
    % Bytes of early data sent
    early_data_sent = 0 :: non_neg_integer(),
    % Server accepted early data
    early_data_accepted = false :: boolean(),
    %% Streams that have carried 0-RTT-encrypted data. Used at handshake
    %% completion to either retain (acceptance) or reset (rejection per
    %% RFC 9001 §4.6.2) stream state.
    zero_rtt_stream_ids = sets:new([{version, 2}]) :: sets:set(non_neg_integer())
}).

%% Connection migration and path validation (RFC 9000 Section 9).
%% Written only when a path changes, so it is kept out of #state{}.
-record(mig, {
    %% Alternative paths being validated
    alt_paths = [] :: [#path_state{}],
    %% Preferred address being validated (RFC 9000 Section 9.6)
    %% Set when client is validating server's preferred address
    preferred_address :: #preferred_address{} | undefined,

    %% Migration state machine (RFC 9000 Section 9)
    %% idle: no migration in progress
    %% validating_peer: server validating client's new address
    migration_state = idle :: idle | validating_peer,
    %% Path being validated when client sends from new address
    pending_peer_validation :: #path_state{} | undefined,
    %% Old path validation for anti-spoofing defense (RFC 9000 Section 9.3.2)
    %% When detecting apparent migration, probe both old and new paths
    old_path_validation :: #path_state{} | undefined,
    %% Timer reference for path validation timeout
    path_validation_timer :: reference() | undefined,
    %% Token for correlating path validation timeout messages
    %% Used to ignore stale timeouts from canceled validations
    path_validation_token :: reference() | undefined,
    %% Peer's disable_active_migration transport param (RFC 9000 Section 18.2)
    peer_disable_migration = false :: boolean()
}).

-record(state, {
    %% Connection identity (the rest is in #conn_cfg{})
    dcid :: binary(),
    version = ?QUIC_VERSION_1 :: non_neg_integer(),

    %% Socket
    socket :: gen_udp:socket() | socket:socket() | undefined,
    %% Socket state for batching (quic_socket abstraction)
    socket_state :: quic_socket:socket_state() | undefined,
    %% Pid of the client-side receiver process when
    %% client_socket_backend = socket; undefined otherwise.
    client_receiver :: pid() | undefined,
    remote_addr :: {inet:ip_address(), inet:port_number()},

    %% Owner process (receives {quic, Conn, Event} messages where Conn is pid())
    owner :: pid(),
    %% How the connection follows its owner down: a monitor on the owner;
    %% `{linked, Parent}' for a client that follows the caller that started
    %% it through their link, until it is handed to another owner;
    %% `opted_out' when `monitor_owner => false' asked for the connection to
    %% outlive it; `undefined' when there is nothing to follow.
    owner_mon :: reference() | {linked, pid()} | opted_out | undefined,
    % Convenience accessor (= key_state.current_keys)
    app_keys :: {#crypto_keys{}, #crypto_keys{}} | undefined,

    %% Key update state (RFC 9001 Section 6)
    key_state :: #key_update_state{} | undefined,

    %% Negotiated ALPN
    alpn :: binary() | undefined,
    pn_app :: #pn_space{},

    %% Flow control
    max_data_local :: non_neg_integer(),
    max_data_remote :: non_neg_integer(),
    data_sent = 0 :: non_neg_integer(),
    data_received = 0 :: non_neg_integer(),
    %% Flow control auto-tuning state
    fc_last_stream_update :: integer() | undefined,
    fc_last_conn_update :: integer() | undefined,
    credit_timer :: reference() | undefined,
    %% `auto' streams whose MAX_STREAM_DATA is waiting on credit_timer
    credit_withheld = sets:new([{version, 2}]) :: sets:set(non_neg_integer()),
    %% Cached max stream recv window (avoids O(n) scan for connection flow control)
    fc_max_stream_recv_window = ?DEFAULT_INITIAL_MAX_STREAM_DATA :: non_neg_integer(),

    %% Stream management
    streams = #{} :: #{non_neg_integer() => #stream_state{}},
    next_stream_id_bidi :: non_neg_integer(),
    next_stream_id_uni :: non_neg_integer(),
    max_streams_bidi_local :: non_neg_integer(),
    max_streams_bidi_remote :: non_neg_integer(),
    max_streams_uni_local :: non_neg_integer(),
    max_streams_uni_remote :: non_neg_integer(),
    %% Reclaimed-stream tracker (RFC 9000 §2.1: ids are never reused). Per
    %% initiator (local | peer), a sorted list of disjoint {Lo, Hi} intervals
    %% of normalised stream indexes (StreamId bsr 2). Lets us distinguish a
    %% late/retransmitted frame for an already-reclaimed stream from a genuinely
    %% new one without retaining per-stream state. Bounded by concurrent open
    %% streams (the holes), not the total opened.
    reclaimed_ranges_bidi = #{} :: #{local | peer => [{non_neg_integer(), non_neg_integer()}]},
    reclaimed_ranges_uni = #{} :: #{local | peer => [{non_neg_integer(), non_neg_integer()}]},

    %% StreamId => send reliable size, for local RESET_STREAM_AT streams whose
    %% data below the reliable size is not yet fully acked. Drained as acks arrive.
    pending_send_reset_at = #{} :: #{non_neg_integer() => non_neg_integer()},
    %% FIN acked but earlier bytes still queued or in flight
    pending_fin_reclaim = #{} :: #{non_neg_integer() => non_neg_integer()},
    %% Lost control-frame retransmissions deferred by congestion control, replayed
    %% through the CC-checked retransmit path when cwnd reopens.
    deferred_ctrl_retransmits = [] :: [term()],
    %% Remote: peer's advertised max size (0 = not supported)
    max_datagram_frame_size_remote = 0 :: non_neg_integer(),
    datagram_recv_queue = queue:new() :: queue:queue(binary()),

    %% Latency spin bit (RFC 9000 §17.4). `spin_outgoing' is the bit
    %% we set on outbound 1-RTT packets; updated from `spin_recv' on
    %% receipt of a 1-RTT packet whose PN exceeds
    %% `spin_recv_largest_pn' so reordering doesn't flip the bit
    %% back. `spin_bit_enabled = false' opts out (always emit 0).
    spin_outgoing = 0 :: 0 | 1,
    spin_recv = 0 :: 0 | 1,
    spin_recv_largest_pn = -1 :: integer(),

    %% Transport parameters (received from peer)
    transport_params = #{} :: map(),
    last_activity :: non_neg_integer(),
    %% RFC 9000 §10.1: true once an ack-eliciting packet has been sent since the
    %% last received packet. Gates the send-side idle-timer restart so it fires
    %% at most once per received packet (a black-holed sender still times out).
    ack_eliciting_since_recv = false :: boolean(),
    timer_ref :: reference() | undefined,

    %% Congestion control and loss detection
    cc_state :: quic_cc:cc_state() | undefined,
    loss_state :: quic_loss:loss_state() | undefined,
    pto_timer :: reference() | undefined,
    %% Absolute monotonic millisecond deadline for the currently armed
    %% PTO timer. Used by set_pto_timer/1 to skip the cancel + reschedule
    %% cycle when the new deadline is within ?PTO_RESET_TOLERANCE_MS of
    %% the existing one.
    pto_scheduled_at = undefined :: integer() | undefined,
    %% Deadline the armed pto_timer will fire at. The timer is never
    %% cancelled when the deadline moves later; the fire handler re-arms
    %% for the remainder instead (see set_pto_timer/1).
    pto_armed_at = undefined :: integer() | undefined,
    %% The packet number space the armed timer belongs to. A probe has to
    %% go out at that level, and a change of space forces a re-arm: the
    %% lazy "a later deadline never cancels" rule would otherwise leave
    %% the wrong space armed.
    pto_space = app :: quic_loss:space(),
    %% Whether the armed timer is a time-threshold loss deadline or a
    %% probe. They are handled differently when it fires, and a change of
    %% either forces a re-arm.
    pto_kind = pto :: loss | pto,
    idle_timer :: reference() | undefined,
    keep_alive_timer :: reference() | undefined,
    %% Dedicated timer for the above. Checking it only when a PTO happened
    %% to fire made the effective timeout the next PTO after the deadline,
    %% and PTO backoff doubles, so a nominal 16 s took 24 s or more.
    disconnect_timer :: reference() | undefined,

    %% Pacing (RFC 9002 Section 7.7)
    pacing_timer :: reference() | undefined,

    %% Pending data - priority queue with 8 buckets (one per urgency 0-7)
    %% Each bucket is a queue:queue() for FIFO within same priority
    send_queue = {
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new()
    } :: tuple(),
    %% Pre-connection pending sends (simple list, processed when connected)
    pending_data = [] :: [{non_neg_integer(), iodata(), boolean()}],

    %% Send queue byte tracking (prevents memory exhaustion)
    send_queue_bytes = 0 :: non_neg_integer(),
    %% Streams whose receive credit waits for the reader (recv_flow).
    manual_recv_streams = sets:new([{version, 2}]) :: sets:set(non_neg_integer()),
    %% The owner asked to hear `send_ready' once the send queue drains.
    send_ready_wanted = false :: boolean(),
    %% Send queue entry count. Used as an O(1) emptiness check because
    %% send_queue_bytes can legitimately be 0 while an entry is queued
    %% (e.g. an empty FIN-only stream send enqueued under pacing).
    send_queue_count = 0 :: non_neg_integer(),
    %% Send queue version counter (for fast change detection)
    send_queue_version = 0 :: non_neg_integer(),

    %% Receive buffer byte tracking (protects against malicious peers)
    recv_buffer_bytes = 0 :: non_neg_integer(),

    %% Close reason
    close_reason :: term(),

    %% Connection Migration (RFC 9000 Section 9)
    %% Current path (active remote address)
    current_path :: #path_state{} | undefined,
    %% Transient field: source address of the current packet being processed
    %% Set during packet processing, cleared after. Used to route PATH_RESPONSE
    %% to the address that sent the PATH_CHALLENGE (RFC 9000 Section 8.2.2).
    current_packet_source :: {inet:ip_address(), inet:port_number()} | undefined,
    %% Transient field: set to true when a non-probing frame is processed
    %% RFC 9000 Section 9.1: Only non-probing frames trigger migration
    has_non_probing_frame = false :: boolean(),

    %% Both connection ID pools and both active_connection_id_limits
    %% (RFC 9000 Section 5.1), owned by quic_cid.
    cid_pool_state = #cid_pool_state{} :: quic_cid:pool(),

    %% PMTU Discovery (RFC 8899)
    pmtu_state :: #pmtu_state{} | undefined,
    pmtu_probe_timer :: reference() | undefined,
    pmtu_raise_timer :: reference() | undefined,

    %% Deferred PTO timer reset, flushed at batch boundaries via
    %% flush_event/2. (Idle and keep-alive timers are lazy and
    %% re-arm only on fire, so they need no dirty flag.)
    pto_dirty = false :: boolean(),
    burst_sent = 0 :: non_neg_integer(),
    %% True while a connected-state receive pass (first datagram plus
    %% drained mailbox train) is being processed. Count-based ACK
    %% decimation defers its flush to the end of the pass, so one ACK
    %% covers the whole train instead of one per ack_packet_tolerance
    %% packets. The max_ack_delay timer still bounds latency; the
    %% reordering immediate-ACK path bypasses this.
    recv_pass = false :: boolean(),
    %% Pending run for the above: stream id, reversed chunk list, fin.
    %% A delivery for a DIFFERENT stream flushes the pending one
    %% first, so the owner observes stream_data messages in exact
    %% arrival order; only adjacent chunks of one stream merge.
    pend_deliver = none :: none | {non_neg_integer(), [binary()], boolean()},
    %% 1-RTT ACK decimation (RFC 9002 §6.2). Count of ack-eliciting
    %% 1-RTT packets received since the last emitted ACK. When it
    %% reaches ?ACK_PACKET_TOLERANCE (default 2) the ACK is sent
    %% immediately; otherwise a max_ack_delay timer (ack_timer) is
    %% armed so the peer sees an ACK at worst max_ack_delay ms after
    %% the first ack-eliciting packet in the window.
    ack_elicited_count = 0 :: non_neg_integer(),
    ack_timer = undefined :: reference() | undefined,
    %% Transient: classification of the most recently received 1-RTT
    %% packet. Set by `record_received_pn/3' and consumed once by
    %% `maybe_send_ack(app, ...)` to choose between immediate ACK
    %% (RFC 9002 §6.2 reordering recommendation) and count-based
    %% decimation.
    last_recv_trigger = sequential :: sequential | reordered,

    %% Small-send coalescing (issue #201). While `coalesce' is true -
    %% only within one drained batch of send_data/send_data_async
    %% requests - app packets accumulate here and are flushed as one
    %% multi-frame packet per PMTU budget instead of one packet per
    %% frame. Reversed accumulation lists; see send_app_packet_internal
    %% and flush_pending_packet.
    coalesce = false :: boolean(),
    pend_payload = [] :: [iodata()],
    pend_frames = [] :: [tuple()],
    pend_size = 0 :: non_neg_integer(),

    %% Rarely written groups, each copied as one pointer by a state update.
    cfg = #conn_cfg{} :: #conn_cfg{},
    hs = #hs{} :: #hs{},
    mig = #mig{} :: #mig{}
}).

-endif.
