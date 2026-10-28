%%% -*- erlang -*-
%%%
%%% QUIC protocol constants and records
%%% RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport
%%%

-ifndef(QUIC_HRL).
-define(QUIC_HRL, true).

%%====================================================================
%% QUIC Version
%%====================================================================

-define(QUIC_VERSION_1, 16#00000001).
-define(QUIC_VERSION_2, 16#6b3343cf).

%%====================================================================
%% Packet Types (Long Header)
%%====================================================================

-define(PACKET_TYPE_INITIAL, 16#00).
-define(PACKET_TYPE_0RTT, 16#01).
-define(PACKET_TYPE_HANDSHAKE, 16#02).
-define(PACKET_TYPE_RETRY, 16#03).

%%====================================================================
%% Frame Types (RFC 9000 Section 12.4)
%%====================================================================

-define(FRAME_PADDING, 16#00).
-define(FRAME_PING, 16#01).
-define(FRAME_ACK, 16#02).
-define(FRAME_ACK_ECN, 16#03).
-define(FRAME_RESET_STREAM, 16#04).
-define(FRAME_STOP_SENDING, 16#05).
-define(FRAME_CRYPTO, 16#06).
-define(FRAME_NEW_TOKEN, 16#07).
% 0x08-0x0f depending on flags
-define(FRAME_STREAM, 16#08).
-define(FRAME_MAX_DATA, 16#10).
-define(FRAME_MAX_STREAM_DATA, 16#11).
-define(FRAME_MAX_STREAMS_BIDI, 16#12).
-define(FRAME_MAX_STREAMS_UNI, 16#13).
-define(FRAME_DATA_BLOCKED, 16#14).
-define(FRAME_STREAM_DATA_BLOCKED, 16#15).
-define(FRAME_STREAMS_BLOCKED_BIDI, 16#16).
-define(FRAME_STREAMS_BLOCKED_UNI, 16#17).
-define(FRAME_NEW_CONNECTION_ID, 16#18).
-define(FRAME_RETIRE_CONNECTION_ID, 16#19).
-define(FRAME_PATH_CHALLENGE, 16#1a).
-define(FRAME_PATH_RESPONSE, 16#1b).
-define(FRAME_CONNECTION_CLOSE, 16#1c).
-define(FRAME_CONNECTION_CLOSE_APP, 16#1d).
-define(FRAME_HANDSHAKE_DONE, 16#1e).

%% DATAGRAM Frames (RFC 9221)
-define(FRAME_DATAGRAM, 16#30).
-define(FRAME_DATAGRAM_WITH_LEN, 16#31).

%% RESET_STREAM_AT Frame (draft-ietf-quic-reliable-stream-reset-07)
-define(FRAME_RESET_STREAM_AT, 16#24).

%%====================================================================
%% Stream Frame Flags (bits 0-2 of frame type 0x08-0x0f)
%%====================================================================

% Offset field present
-define(STREAM_FLAG_OFF, 16#04).
% Length field present
-define(STREAM_FLAG_LEN, 16#02).
% Final frame for stream
-define(STREAM_FLAG_FIN, 16#01).

%%====================================================================
%% Transport Error Codes (RFC 9000 Section 20.1)
%%====================================================================

-define(QUIC_NO_ERROR, 16#00).
-define(QUIC_INTERNAL_ERROR, 16#01).
-define(QUIC_CONNECTION_REFUSED, 16#02).
-define(QUIC_FLOW_CONTROL_ERROR, 16#03).
-define(QUIC_STREAM_LIMIT_ERROR, 16#04).
-define(QUIC_STREAM_STATE_ERROR, 16#05).
-define(QUIC_FINAL_SIZE_ERROR, 16#06).
-define(QUIC_FRAME_ENCODING_ERROR, 16#07).
-define(QUIC_TRANSPORT_PARAMETER_ERROR, 16#08).
-define(QUIC_CONNECTION_ID_LIMIT_ERROR, 16#09).
-define(QUIC_PROTOCOL_VIOLATION, 16#0a).
-define(QUIC_INVALID_TOKEN, 16#0b).
-define(QUIC_APPLICATION_ERROR, 16#0c).
-define(QUIC_CRYPTO_BUFFER_EXCEEDED, 16#0d).
-define(QUIC_KEY_UPDATE_ERROR, 16#0e).
-define(QUIC_AEAD_LIMIT_REACHED, 16#0f).
-define(QUIC_NO_VIABLE_PATH, 16#10).
% 0x100-0x1ff for TLS alerts
-define(QUIC_CRYPTO_ERROR_BASE, 16#100).

%% Application-level error codes (for stream deadlines)
%% Default error code when stream deadline expires
-define(QUIC_STREAM_DEADLINE_EXCEEDED, 16#FF).

%%====================================================================
%% HTTP/3 Error Codes (RFC 9114 Section 8.1)
%%====================================================================

-define(H3_NO_ERROR, 16#100).
-define(H3_GENERAL_PROTOCOL_ERROR, 16#101).
-define(H3_INTERNAL_ERROR, 16#102).
-define(H3_STREAM_CREATION_ERROR, 16#103).
-define(H3_CLOSED_CRITICAL_STREAM, 16#104).
-define(H3_FRAME_UNEXPECTED, 16#105).
-define(H3_FRAME_ERROR, 16#106).
-define(H3_EXCESSIVE_LOAD, 16#107).
-define(H3_ID_ERROR, 16#108).
-define(H3_SETTINGS_ERROR, 16#109).
-define(H3_MISSING_SETTINGS, 16#10a).
-define(H3_REQUEST_REJECTED, 16#10b).
-define(H3_REQUEST_CANCELLED, 16#10c).
-define(H3_REQUEST_INCOMPLETE, 16#10d).
-define(H3_MESSAGE_ERROR, 16#10e).
-define(H3_CONNECT_ERROR, 16#10f).
-define(H3_VERSION_FALLBACK, 16#110).

%%====================================================================
%% Transport Parameters (RFC 9000 Section 18.2)
%%====================================================================

-define(TP_ORIGINAL_DCID, 16#00).
-define(TP_MAX_IDLE_TIMEOUT, 16#01).
-define(TP_STATELESS_RESET_TOKEN, 16#02).
-define(TP_MAX_UDP_PAYLOAD_SIZE, 16#03).
-define(TP_INITIAL_MAX_DATA, 16#04).
-define(TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, 16#05).
-define(TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, 16#06).
-define(TP_INITIAL_MAX_STREAM_DATA_UNI, 16#07).
-define(TP_INITIAL_MAX_STREAMS_BIDI, 16#08).
-define(TP_INITIAL_MAX_STREAMS_UNI, 16#09).
-define(TP_ACK_DELAY_EXPONENT, 16#0a).
-define(TP_MAX_ACK_DELAY, 16#0b).
-define(TP_DISABLE_ACTIVE_MIGRATION, 16#0c).
-define(TP_PREFERRED_ADDRESS, 16#0d).
-define(TP_ACTIVE_CONNECTION_ID_LIMIT, 16#0e).
-define(TP_INITIAL_SCID, 16#0f).
-define(TP_RETRY_SCID, 16#10).
%% RFC 9368 version_information
-define(TP_VERSION_INFORMATION, 16#11).

%% RFC 9221 - QUIC Datagrams
-define(TP_MAX_DATAGRAM_FRAME_SIZE, 16#20).

%% draft-ietf-quic-reliable-stream-reset-07 - Reliable RESET_STREAM
-define(TP_RESET_STREAM_AT, 16#17f7586d2cb571).

%%====================================================================
%% Crypto Constants
%%====================================================================

%% Initial salt for QUIC v1 (RFC 9001 Section 5.2)
%% 0x38762cf7f55934b34d179ae6a4c80cadccbb7f0a
-define(QUIC_V1_INITIAL_SALT,
    <<16#38, 16#76, 16#2c, 16#f7, 16#f5, 16#59, 16#34, 16#b3, 16#4d, 16#17, 16#9a, 16#e6, 16#a4,
        16#c8, 16#0c, 16#ad, 16#cc, 16#bb, 16#7f, 16#0a>>
).

%% Initial salt for QUIC v2 (RFC 9369 Section 5.2)
%% RFC 9369 §3.3.2: first 20 bytes of sha256("QUICv2 salt"). The old
%% value here was from a pre-RFC draft, so v2 worked against ourselves
%% and no one else.
-define(QUIC_V2_INITIAL_SALT,
    <<16#0d, 16#ed, 16#e3, 16#de, 16#f7, 16#00, 16#a6, 16#db, 16#81, 16#93, 16#81, 16#be, 16#6e,
        16#26, 16#9d, 16#cb, 16#f9, 16#bd, 16#2e, 16#d9>>
).

%% HKDF labels
-define(QUIC_LABEL_CLIENT_IN, <<"client in">>).
-define(QUIC_LABEL_SERVER_IN, <<"server in">>).
-define(QUIC_LABEL_QUIC_KEY, <<"quic key">>).
-define(QUIC_LABEL_QUIC_IV, <<"quic iv">>).
-define(QUIC_LABEL_QUIC_HP, <<"quic hp">>).
-define(QUIC_LABEL_QUIC_KU, <<"quic ku">>).

%%====================================================================
%% TLS 1.3 Message Types (RFC 8446 Section 4)
%%====================================================================

-define(TLS_CLIENT_HELLO, 1).
-define(TLS_SERVER_HELLO, 2).
-define(TLS_NEW_SESSION_TICKET, 4).
-define(TLS_END_OF_EARLY_DATA, 5).
-define(TLS_ENCRYPTED_EXTENSIONS, 8).
-define(TLS_CERTIFICATE, 11).
-define(TLS_CERTIFICATE_REQUEST, 13).
-define(TLS_CERTIFICATE_VERIFY, 15).
-define(TLS_FINISHED, 20).
-define(TLS_KEY_UPDATE, 24).
-define(TLS_MESSAGE_HASH, 254).

%%====================================================================
%% TLS 1.3 Extension Types (RFC 8446 Section 4.2)
%%====================================================================

-define(EXT_SERVER_NAME, 0).
-define(EXT_SUPPORTED_GROUPS, 10).
-define(EXT_SIGNATURE_ALGORITHMS, 13).
-define(EXT_ALPN, 16).
% RFC 8446 Section 4.2.11
-define(EXT_PRE_SHARED_KEY, 41).
% RFC 8446 Section 4.2.10
-define(EXT_EARLY_DATA, 42).
-define(EXT_SUPPORTED_VERSIONS, 43).
-define(EXT_PSK_KEY_EXCHANGE_MODES, 45).
-define(EXT_KEY_SHARE, 51).
-define(EXT_QUIC_TRANSPORT_PARAMS, 57).

%%====================================================================
%% TLS 1.3 PSK Key Exchange Modes (RFC 8446 Section 4.2.9)
%%====================================================================

%% PSK-only key establishment (no (EC)DHE; no forward secrecy)
-define(PSK_KE_MODE_KE, 0).
%% PSK with (EC)DHE key establishment (forward-secret)
-define(PSK_KE_MODE_DHE_KE, 1).

%%====================================================================
%% TLS 1.3 Alerts (RFC 8446 Section 6)
%%====================================================================

-define(TLS_ALERT_UNEXPECTED_MESSAGE, 10).
-define(TLS_ALERT_HANDSHAKE_FAILURE, 40).
-define(TLS_ALERT_BAD_CERTIFICATE, 42).
-define(TLS_ALERT_CERTIFICATE_REQUIRED, 116).
-define(TLS_ALERT_ILLEGAL_PARAMETER, 47).
-define(TLS_ALERT_UNKNOWN_CA, 48).
-define(TLS_ALERT_DECRYPT_ERROR, 51).
-define(TLS_ALERT_INTERNAL_ERROR, 80).
-define(TLS_ALERT_UNKNOWN_PSK_IDENTITY, 115).

%%====================================================================
%% PSK offer record (client-side, fed into ClientHello PSK builder)
%%====================================================================

-record(psk_offer, {
    %% resumption | external
    type :: resumption | external,
    %% binary identity sent on the wire
    identity :: binary(),
    %% obfuscated_ticket_age:32 — 0 for external PSKs (RFC 8446 §4.2.11)
    age = 0 :: non_neg_integer(),
    %% raw PSK secret (passed to HKDF unchanged)
    secret :: binary(),
    %% cipher whose hash determines binder length & key schedule
    cipher :: atom(),
    %% offered modes in client preference order
    modes = [psk_dhe_ke] :: [psk_dhe_ke | psk_ke],
    %% whether to offer 0-RTT: only on a ticket that allows early data
    early_data = false :: boolean()
}).

%% HelloRetryRequest sentinel random (RFC 8446 §4.1.3): SHA-256 of
%% "HelloRetryRequest". A ServerHello carrying this random IS an HRR.
-define(TLS_HRR_RANDOM, <<
    16#CF,
    16#21,
    16#AD,
    16#74,
    16#E5,
    16#9A,
    16#61,
    16#11,
    16#BE,
    16#1D,
    16#8C,
    16#02,
    16#1E,
    16#65,
    16#B8,
    16#91,
    16#C2,
    16#A2,
    16#11,
    16#16,
    16#7A,
    16#BB,
    16#8C,
    16#5E,
    16#07,
    16#9E,
    16#09,
    16#E2,
    16#C8,
    16#A8,
    16#33,
    16#9C
>>).

%%====================================================================
%% TLS 1.3 Named Groups (RFC 8446 Section 4.2.7)
%%====================================================================

-define(GROUP_SECP256R1, 16#0017).
-define(GROUP_SECP384R1, 16#0018).
-define(GROUP_SECP521R1, 16#0019).
-define(GROUP_X25519, 16#001d).
-define(GROUP_X448, 16#001e).
%% Post-quantum hybrid X25519MLKEM768 (draft-ietf-tls-ecdhe-mlkem)
-define(GROUP_X25519MLKEM768, 16#11ec).

%%====================================================================
%% TLS 1.3 Signature Algorithms (RFC 8446 Section 4.2.3)
%%====================================================================

-define(SIG_RSA_PKCS1_SHA256, 16#0401).
-define(SIG_RSA_PKCS1_SHA384, 16#0501).
-define(SIG_RSA_PKCS1_SHA512, 16#0601).
-define(SIG_ECDSA_SECP256R1_SHA256, 16#0403).
-define(SIG_ECDSA_SECP384R1_SHA384, 16#0503).
-define(SIG_ECDSA_SECP521R1_SHA512, 16#0603).
-define(SIG_RSA_PSS_RSAE_SHA256, 16#0804).
-define(SIG_RSA_PSS_RSAE_SHA384, 16#0805).
-define(SIG_RSA_PSS_RSAE_SHA512, 16#0806).
-define(SIG_ED25519, 16#0807).
-define(SIG_ED448, 16#0808).

%%====================================================================
%% TLS 1.3 Cipher Suites (RFC 8446 Section B.4)
%%====================================================================

-define(TLS_AES_128_GCM_SHA256, 16#1301).
-define(TLS_AES_256_GCM_SHA384, 16#1302).
-define(TLS_CHACHA20_POLY1305_SHA256, 16#1303).

%%====================================================================
%% TLS Versions
%%====================================================================

-define(TLS_VERSION_1_2, 16#0303).
-define(TLS_VERSION_1_3, 16#0304).

%%====================================================================
%% Default Values
%%====================================================================

-define(DEFAULT_MAX_UDP_PAYLOAD_SIZE, 1200).
% 30 seconds
-define(DEFAULT_MAX_IDLE_TIMEOUT, 30000).
-define(DEFAULT_MAX_STREAMS_BIDI, 100).
-define(DEFAULT_MAX_STREAMS_UNI, 100).
% 512KB - stream-level flow control (quic-go default for stream)
-define(DEFAULT_INITIAL_MAX_STREAM_DATA, 524288).
% 768KB - connection = 1.5x stream window (512KB * 1.5)
-define(DEFAULT_INITIAL_MAX_DATA, 786432).
-define(DEFAULT_ACK_DELAY_EXPONENT, 3).
% 25ms
-define(DEFAULT_MAX_ACK_DELAY, 25).

%% Auto-tuning constants
% Connection window should be >= 1.5x largest stream window
-define(CONNECTION_FLOW_CONTROL_MULTIPLIER, 1.5).
% 8MB cap on receive window
-define(DEFAULT_MAX_RECEIVE_WINDOW, 8388608).
%% Below a few full-size packets per window the transfer crawls or stops.
-define(MIN_RECEIVE_WINDOW, 16384).
% Double window if consumed in < 4*RTT (aggressive), else linear growth
-define(AUTO_TUNE_RTT_FACTOR, 4).
%% Owner mailbox length past which receive credit and DATAGRAMs wait
-define(DEFAULT_MAX_OWNER_QUEUE, 1000).
%% How often withheld credit is re-checked against the owner's mailbox
-define(CREDIT_RETRY_MS, 10).

%% Congestion Control - Initial Window
%% RFC 9002 default: min(10 * max_datagram_size, max(14720, 2 * max_datagram_size))
%% = ~14720 bytes for 1200 byte datagrams (~12 packets)
%% For distribution/bulk transfer workloads, a higher initial window reduces
%% slow start duration and improves throughput for large messages.
% 64KB - recommended for distribution/LAN
-define(INITIAL_WINDOW_DISTRIBUTION, 65536).
% 16KB - conservative floor to avoid starvation in bursty virtual networks
-define(MINIMUM_WINDOW_DISTRIBUTION, 16384).
% 128KB - aggressive for high-bandwidth LAN

%% Recovery Duration - Distribution-specific
%% Longer minimum recovery duration for distribution to handle packet reordering
%% in virtual networks (Docker bridge) without rapid recovery re-entry.
-define(MIN_RECOVERY_DURATION_DISTRIBUTION, 200).

%% Flow Control - Distribution-specific limits
%% Higher limits for distribution to avoid flow control blocking during
%% large message transfers (e.g., code loading, large term passing).
%% Connection-level limit must comfortably exceed
%% ?QUIC_DIST_DATA_STREAMS * ?DIST_INITIAL_MAX_STREAM_DATA so per-pair
%% multi-stream routing doesn't hit connection backpressure before
%% per-stream windows do. With N=16 data streams + 1 control, the
%% per-stream budget alone is 16 * 4 MB = 64 MB; the connection
%% budget is 4× that so a single-RTT burst can't deplete the window
%% before MAX_DATA frames replenish it.
% 256MB connection-level limit
-define(DIST_INITIAL_MAX_DATA, 268435456).
% 4MB per-stream limit
-define(DIST_INITIAL_MAX_STREAM_DATA, 4194304).

%% MTU - Distribution-specific
%% Use known-safe MTU for LAN instead of PMTU probing.
%% 1452 = 1500 (Ethernet) - 40 (IPv6 header) - 8 (UDP header)
%% This is safe for both IPv4 and IPv6 over standard Ethernet.
-define(DIST_MAX_UDP_PAYLOAD_SIZE, 1452).
-define(INITIAL_WINDOW_AGGRESSIVE, 131072).

%% UDP Socket Buffer Sizes
%% 7MB buffers improve throughput by 40%+ (matches quic-go, quiche, lsquic)
%% OS may cap to lower value (Linux: check net.core.rmem_max, macOS: typically 2-4MB)
%% Note: Erlang uses "recbuf" (not "recvbuf") and "sndbuf"
-define(DEFAULT_UDP_RECBUF, 7340032).
-define(DEFAULT_UDP_SNDBUF, 7340032).

%% UDP Packet Batching (GSO/GRO on Linux)
%% Maximum packets to batch before auto-flush
-define(DEFAULT_MAX_BATCH_PACKETS, 64).
%% Default GSO segment size (QUIC packet size for batching)
-define(DEFAULT_GSO_SEGMENT_SIZE, 1200).

%% Floor on the messages a connection process mailbox may hold before
%% the socket-backend receive path tail-drops incoming datagrams. The
%% working bound is quic_socket:recv_queue_max/1: the connection's
%% flow-control window in full-size packets, so a peer inside the
%% window it was given is never dropped and the bound only catches one
%% outside it. A bound below the window turned flow-control-permitted
%% data into loss.
-define(MAX_CONN_RECV_QUEUE_MSGS, 512).
%% Nominal packet size used to turn a byte window into that bound.
-define(RECV_QUEUE_PACKET_BYTES, 1200).

%% Max packets per {quic_packets, ...} message forwarded to a
%% connection. GRO can aggregate trains of ~44 packets; forwarded
%% whole, the mailbox bound above cannot cap queueing DELAY (a message
%% may be 1 or 44 packets). Splitting trains keeps the worst-case
%% queued backlog, and thus the RTT inflation seen by the peer's loss
%% detector, small and predictable.
-define(MAX_PACKETS_PER_CONN_MSG, 8).
%% Kernel limits on a single UDP_SEGMENT write: UDP_MAX_SEGMENTS segments,
%% and a payload that still fits a 16-bit UDP length. A run larger than
%% either is split across writes.
-define(MAX_GSO_SEGMENTS, 64).
-define(MAX_GSO_PAYLOAD, 65535).

%%====================================================================
%% Records
%%====================================================================

%% Crypto keys for an encryption level
-record(crypto_keys, {
    key :: binary(),
    iv :: binary(),
    hp :: binary(),
    cipher :: aes_128_gcm | aes_256_gcm | chacha20_poly1305
}).

%% Key Update State (RFC 9001 Section 6)
%% Tracks the key phase and keys for 1-RTT packet encryption.
%% Maintains both current and previous keys for decryption during key update.
-record(key_update_state, {
    %% Current key phase (0 or 1), toggles on each key update
    current_phase = 0 :: 0 | 1,

    %% Current keys for sending and receiving
    current_keys :: {#crypto_keys{}, #crypto_keys{}} | undefined,

    %% Previous keys for decryption (kept during key update transition)
    %% Set to undefined when no key update is in progress
    prev_keys :: {#crypto_keys{}, #crypto_keys{}} | undefined,

    %% Application traffic secrets (needed for deriving next keys)
    client_app_secret :: binary() | undefined,
    server_app_secret :: binary() | undefined,

    %% Key update state machine
    %% idle: normal operation, no key update in progress
    %% initiated: we sent a packet with new key phase, awaiting response
    %% responding: we received a packet with new key phase, transitioning
    update_state = idle :: idle | initiated | responding,

    %% Packets encrypted under the current key phase; forces a key update
    %% at the AEAD confidentiality limit (RFC 9001 §6.6).
    send_count = 0 :: non_neg_integer()
}).

%% Path State for Connection Migration (RFC 9000 Section 9)
%% Tracks the validation state and metrics for a network path.
-record(path_state, {
    %% Remote address for this path
    remote_addr :: {inet:ip_address(), inet:port_number()},

    %% Path validation status
    %% unknown: path not yet validated
    %% validating: PATH_CHALLENGE sent, waiting for PATH_RESPONSE
    %% validated: PATH_RESPONSE received successfully
    %% failed: validation failed (timeout or mismatch)
    status = unknown :: unknown | validating | validated | failed,

    %% PATH_CHALLENGE data (8 bytes) for validation
    challenge_data :: binary() | undefined,

    %% Number of PATH_CHALLENGE attempts
    challenge_count = 0 :: non_neg_integer(),

    %% Anti-amplification: bytes sent/received on this path
    bytes_sent = 0 :: non_neg_integer(),
    bytes_received = 0 :: non_neg_integer(),

    %% RTT estimation for this path
    rtt :: non_neg_integer() | undefined,

    %% CID used on this path, and its sequence number so it can be retired
    %% when the path is abandoned (RFC 9000 Section 9.5)
    dcid :: binary() | undefined,
    dcid_seq :: non_neg_integer() | undefined,

    %% NAT rebinding vs active migration (RFC 9000 Section 9.3)
    %% NAT rebinding: only port changed, same IP
    %% Active migration: different IP address
    is_nat_rebinding = false :: boolean()
}).

%% Preferred Address for Server Migration (RFC 9000 Section 9.6)
%% Server advertises this to clients for connection migration.
-record(preferred_address, {
    %% IPv4 address (optional)
    ipv4_addr :: inet:ip4_address() | undefined,
    ipv4_port :: inet:port_number() | undefined,
    %% IPv6 address (optional)
    ipv6_addr :: inet:ip6_address() | undefined,
    ipv6_port :: inet:port_number() | undefined,
    %% Connection ID for the preferred address
    cid :: binary(),
    %% Stateless reset token (16 bytes)
    stateless_reset_token :: binary()
}).

%% Session Ticket for 0-RTT (RFC 9001 Section 4.6)
%% Stores session ticket information for resumption.
-record(session_ticket, {
    %% Server name (SNI) this ticket is valid for
    server_name :: binary(),

    %% Ticket data (opaque to client)
    ticket :: binary(),

    %% Ticket lifetime in seconds
    lifetime :: non_neg_integer(),

    %% Ticket age add (for obfuscation)
    age_add :: non_neg_integer(),

    %% Ticket nonce (for PSK derivation)
    nonce :: binary(),

    %% Resumption master secret (for deriving PSK)
    resumption_secret :: binary(),

    %% Max early data size (0 = no early data)
    max_early_data :: non_neg_integer(),

    %% When this ticket was received
    received_at :: non_neg_integer(),

    %% Cipher suite used for the original connection
    cipher :: atom(),

    %% ALPN used for the original connection
    alpn :: binary() | undefined
}).

%% Connection ID Entry for CID Pool (RFC 9000 Section 5.1)
%% Manages multiple connection IDs for connection migration.
-record(cid_entry, {
    %% Sequence number assigned by the peer
    seq_num :: non_neg_integer(),

    %% The connection ID
    cid :: binary(),

    %% Stateless reset token (16 bytes, optional for seq 0)
    stateless_reset_token :: binary() | undefined,

    %% Status: active (can be used), retired (no longer valid)
    status = active :: active | retired,

    %% The path this CID has been bound to, if any. A CID that has appeared
    %% on one path must not appear on another (RFC 9000 Section 9.5), so a
    %% bound entry is never handed out again.
    bound_to :: term() | undefined
}).

%% Both connection ID pools, held in one #state{} field and owned by
%% quic_cid. The limits cross over: the limit we advertise bounds how many
%% of the peer's CIDs we retain, and the peer's bounds how many of ours we
%% issue (RFC 9000 Section 5.1.1).
-record(cid_pool_state, {
    %% CIDs we issued to the peer, newest first, including our sequence 0
    local = [] :: [#cid_entry{}],

    %% CIDs the peer issued to us, newest first, including its sequence 0
    peer = [] :: [#cid_entry{}],

    %% Ours, advertised as active_connection_id_limit; bounds `peer'
    local_active_limit = 2 :: non_neg_integer(),

    %% The peer's, from its transport parameters; bounds `local'
    peer_active_limit = 2 :: non_neg_integer()
}).

%% Stream state
-record(stream_state, {
    id :: non_neg_integer(),
    state :: idle | open | half_closed_local | half_closed_remote | closed | reset | stopped,

    %% Send state
    send_offset :: non_neg_integer(),
    send_max_data :: non_neg_integer(),
    send_fin :: boolean(),
    send_buffer :: iolist(),
    %% Our send side is terminal: FIN emitted or we sent RESET_STREAM. Used
    %% (with recv_done) to reclaim the stream from the connection map.
    send_done = false :: boolean(),

    %% Receive state
    recv_offset :: non_neg_integer(),
    recv_max_data :: non_neg_integer(),
    recv_fin :: boolean(),
    %% Offset => Data, ordered, for out-of-order reassembly. Ordering
    %% keeps the per-packet gap check O(log n) and lets the trim walk
    %% stop at the delivered point instead of visiting every buffered
    %% chunk, which matters once loss recovery has megabytes buffered.
    recv_buffer :: gb_trees:tree(non_neg_integer(), binary()),
    %% Bytes held in recv_buffer, a running count so per-packet
    %% accounting never walks the tree.
    recv_buffered = 0 :: non_neg_integer(),
    %% `manual': credit follows recv_consumed, the offset the reader has
    %% returned, instead of what has been delivered.
    recv_flow = auto :: auto | manual,
    recv_consumed = 0 :: non_neg_integer(),
    %% Our recv side is terminal: FIN read (buffer empty) or peer RESET_STREAM.
    recv_done = false :: boolean(),

    %% Final size (set when FIN received)
    final_size :: non_neg_integer() | undefined,

    %% Stream Priority (RFC 9218)
    %% Urgency: 0-7 (lower = more urgent, default 3)
    %% Incremental: boolean (data can be processed incrementally)
    urgency = 3 :: 0..7,
    incremental = false :: boolean(),

    %% Stream Deadlines
    %% deadline: absolute timestamp in ms (erlang:system_time(millisecond))
    deadline :: non_neg_integer() | infinity | undefined,
    %% deadline_timer: erlang timer reference for deadline expiry
    deadline_timer :: reference() | undefined,
    %% deadline_action: what to do when deadline expires
    %% - notify: send {quic, ConnRef, {stream_deadline, StreamId}} to owner
    %% - reset: send RESET_STREAM and clean up
    %% - both: notify AND reset (default)
    deadline_action = both :: reset | notify | both,
    %% deadline_error_code: error code for RESET_STREAM on deadline expiry
    deadline_error_code = 16#FF :: non_neg_integer(),

    %% RESET_STREAM_AT reliable size (draft-ietf-quic-reliable-stream-reset-07)
    %% Direction-split: send_* is our local reset reliable size, recv_* is the
    %% peer's. A bidi stream can carry both without clashing.
    send_reset_at = undefined :: non_neg_integer() | undefined,
    recv_reset_at = undefined :: non_neg_integer() | undefined,
    %% Error codes from RESET_STREAM_AT (must not change once set)
    send_reset_error = undefined :: non_neg_integer() | undefined,
    recv_reset_error = undefined :: non_neg_integer() | undefined
}).

%% Sent packet info for loss detection
-record(sent_packet, {
    pn :: non_neg_integer(),
    time_sent :: non_neg_integer(),
    ack_eliciting :: boolean(),
    in_flight :: boolean(),
    size :: non_neg_integer(),
    frames :: [term()]
}).

%% What the loss-detection timer needs that the loss state cannot hold:
%% both facts depend on the role and on key availability (RFC 9002
%% Appendix A.8). PeerCompletedAddressValidation is always true for a
%% server; a client learns it from a Handshake ACK or from confirmation.
-record(handshake_status, {
    has_handshake_keys = false :: boolean(),
    peer_completed_address_validation = false :: boolean()
}).

%% Packet number space.
%%
%% Send and receive bookkeeping only. Loss detection state lives in
%% quic_loss, keyed by space there, so it has one owner.
-record(pn_space, {
    %% Send state
    next_pn :: non_neg_integer(),

    %% Receive state
    largest_recv :: non_neg_integer() | undefined,
    recv_time :: non_neg_integer() | undefined,
    ack_ranges :: [{non_neg_integer(), non_neg_integer()}],
    ack_eliciting_in_flight :: non_neg_integer()
}).

%% QUIC packet
-record(quic_packet, {
    type :: initial | handshake | zero_rtt | one_rtt | retry,
    version :: non_neg_integer() | undefined,
    dcid :: binary(),
    scid :: binary() | undefined,
    token :: binary() | undefined,
    pn :: non_neg_integer() | undefined,
    % frames list or encrypted payload
    payload :: binary() | [term()]
}).

%% Connection state
-record(conn_state, {
    %% Connection IDs

    % Source Connection ID
    scid :: binary(),
    % Destination Connection ID
    dcid :: binary(),
    % Original DCID (for Initial packets)
    original_dcid :: binary(),

    %% Connection state
    state :: idle | handshaking | connected | draining | closed,
    role :: client | server,
    version :: non_neg_integer(),

    %% Socket
    socket :: gen_udp:socket() | undefined,
    remote_addr :: {inet:ip_address(), inet:port_number()},
    local_addr :: {inet:ip_address(), inet:port_number()},

    %% Owner process
    owner :: pid(),

    %% Crypto state (per encryption level)
    initial_keys :: #crypto_keys{} | undefined,
    handshake_keys :: #crypto_keys{} | undefined,
    app_keys :: #crypto_keys{} | undefined,

    %% TLS state
    tls_state :: term(),
    alpn :: binary() | undefined,

    %% Flow control
    max_data_local :: non_neg_integer(),
    max_data_remote :: non_neg_integer(),
    data_sent :: non_neg_integer(),
    data_received :: non_neg_integer(),

    %% Stream management
    streams :: #{non_neg_integer() => #stream_state{}},
    next_stream_id_bidi :: non_neg_integer(),
    next_stream_id_uni :: non_neg_integer(),
    max_streams_bidi_local :: non_neg_integer(),
    max_streams_bidi_remote :: non_neg_integer(),
    max_streams_uni_local :: non_neg_integer(),
    max_streams_uni_remote :: non_neg_integer(),

    %% Packet numbers
    pn_space_initial :: #pn_space{},
    pn_space_handshake :: #pn_space{},
    pn_space_app :: #pn_space{},

    %% Timers
    idle_timeout :: non_neg_integer(),
    last_activity :: non_neg_integer(),

    %% Transport parameters
    transport_params :: map()
}).

%%====================================================================
%% QUIC-LB (RFC 9312) - QUIC Load Balancer Configuration
%%====================================================================

%% Config Rotation for unroutable packets (CR bits = 0b111)
-define(LB_CR_UNROUTABLE, 7).
%% Maximum server ID length (1-15 bytes)
-define(LB_MAX_SERVER_ID_LEN, 15).
%% Maximum nonce length (4-18 bytes)
-define(LB_MAX_NONCE_LEN, 18).
%% Minimum nonce length
-define(LB_MIN_NONCE_LEN, 4).

%% QUIC-LB Configuration record
%% Defines how the load balancer encodes server identity in CIDs
-record(lb_config, {
    %% Config rotation bits (0-6, 7 = unroutable)
    config_rotation = 0 :: 0..6,
    %% Encoding algorithm
    algorithm = plaintext :: plaintext | stream_cipher | block_cipher,
    %% Server ID (1-15 bytes identifying this server)
    server_id :: binary(),
    %% Length of server ID in bytes
    server_id_len :: 1..15,
    %% Length of nonce in bytes (4-18)
    nonce_len = 4 :: 4..18,
    %% Encryption key (16 bytes for AES-128, required for cipher algorithms)
    key :: binary() | undefined
}).

%% CID generation configuration record
%% Combines LB config with additional parameters for CID generation
-record(cid_config, {
    %% Optional LB config (undefined = use random CIDs)
    lb_config :: #lb_config{} | undefined,
    %% Target CID length (1-20 bytes)
    cid_len = 8 :: 1..20,
    %% Reset secret for stateless reset token generation
    reset_secret :: binary() | undefined
}).

%%====================================================================
%% PMTU Discovery (RFC 8899 - DPLPMTUD)
%%====================================================================

%% PMTU Discovery state machine
%% Implements Datagram Packetization Layer Path MTU Discovery
%% Uses quic-go's loss array algorithm for better random loss tolerance
-record(pmtu_state, {
    %% State machine state (RFC 8899 Section 5.2)
    %% disabled: PMTU discovery not active
    %% base: Using base MTU (1200), ready to probe
    %% searching: Binary search for optimal MTU in progress
    %% search_complete: Found optimal MTU
    %% error: Black hole detected, fell back to base MTU
    state = disabled :: disabled | base | searching | search_complete | error,

    %% Base MTU - minimum guaranteed to work (QUIC minimum)
    base_mtu = 1200 :: pos_integer(),

    %% Current effective MTU for sending
    current_mtu = 1200 :: pos_integer(),

    %% Maximum MTU to probe (from peer's max_udp_payload_size or config)
    max_mtu = 1500 :: pos_integer(),

    %% Binary search minimum (confirmed working size)
    search_min = 1200 :: pos_integer(),

    %% Loss array: up to 3 sizes that failed probing (quic-go algorithm)
    %% Sorted ascending, 'undefined' for unused slots
    %% Initialized with [max_mtu, undefined, undefined]
    %% When full (3 losses), the largest becomes the new search max
    lost = [1500, undefined, undefined] :: [pos_integer() | undefined],

    %% Track if last probe was lost (affects next probe size calculation)
    %% When true: probe (search_min + lost[0]) / 2
    %% When false: probe (search_min + get_max()) / 2
    last_probe_lost = false :: boolean(),

    %% Current probe size being tested
    probe_size = 0 :: non_neg_integer(),

    %% Packet number of the last sent probe (for ACK matching)
    probe_pn :: non_neg_integer() | undefined,

    %% Generation counter for path migration (quic-go pattern)
    %% Incremented on path change to ignore stale ACKs/losses
    generation = 0 :: non_neg_integer(),

    %% Timer reference for probe timeout
    probe_timer :: reference() | undefined,

    %% Timer reference for periodic re-probing (raise timer)
    raise_timer :: reference() | undefined,

    %% Black hole detection: consecutive losses at current MTU
    black_hole_count = 0 :: non_neg_integer(),

    %% Threshold for black hole detection (consecutive losses)
    black_hole_threshold = 6 :: pos_integer()
}).

%% PMTU Discovery configuration options
-define(PMTU_DEFAULT_PROBE_TIMEOUT, 5000).
-define(PMTU_DEFAULT_RAISE_INTERVAL, 600000).
-define(PMTU_SEARCH_THRESHOLD, 10).

% QUIC_HRL
-endif.
