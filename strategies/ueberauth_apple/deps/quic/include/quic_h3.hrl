%%% -*- erlang -*-
%%%
%%% HTTP/3 protocol constants and records (RFC 9114)
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-ifndef(QUIC_H3_HRL).
-define(QUIC_H3_HRL, true).

%%====================================================================
%% HTTP/3 Frame Types (RFC 9114 Section 7.2)
%%====================================================================

-define(H3_FRAME_DATA, 16#00).
-define(H3_FRAME_HEADERS, 16#01).
-define(H3_FRAME_CANCEL_PUSH, 16#03).
-define(H3_FRAME_SETTINGS, 16#04).
-define(H3_FRAME_PUSH_PROMISE, 16#05).
-define(H3_FRAME_GOAWAY, 16#07).
-define(H3_FRAME_MAX_PUSH_ID, 16#0D).

%% Reserved frame types (RFC 9114 Section 7.2.8)
%% 0x1f * N + 0x21 for any non-negative integer N

%% PRIORITY_UPDATE frame (RFC 9218 Section 7)

%% For request streams
-define(H3_FRAME_PRIORITY_UPDATE_REQUEST, 16#0F0700).
%% For push streams
-define(H3_FRAME_PRIORITY_UPDATE_PUSH, 16#0F0701).

%%====================================================================
%% HTTP/3 Unidirectional Stream Types (RFC 9114 Section 6.2)
%%====================================================================

-define(H3_STREAM_CONTROL, 16#00).
-define(H3_STREAM_PUSH, 16#01).
-define(H3_STREAM_QPACK_ENCODER, 16#02).
-define(H3_STREAM_QPACK_DECODER, 16#03).

%%====================================================================
%% HTTP/3 Settings (RFC 9114 Section 7.2.4.1)
%%====================================================================

-define(H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY, 16#01).
-define(H3_SETTINGS_MAX_FIELD_SECTION_SIZE, 16#06).
-define(H3_SETTINGS_QPACK_BLOCKED_STREAMS, 16#07).
-define(H3_SETTINGS_ENABLE_CONNECT_PROTOCOL, 16#08).
%% RFC 9297 §2.1
-define(H3_SETTINGS_H3_DATAGRAM, 16#33).

%% WebTransport over HTTP/3 (draft-ietf-webtrans-http3-15 §9.2)
-define(H3_SETTINGS_WT_ENABLED, 16#2c7cf000).
-define(H3_SETTINGS_WT_INITIAL_MAX_DATA, 16#2b61).
-define(H3_SETTINGS_WT_INITIAL_MAX_STREAMS_UNI, 16#2b64).
-define(H3_SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI, 16#2b65).

%% RFC 9297 §3.2 registered capsule types
-define(H3_CAPSULE_DATAGRAM, 16#00).
-define(H3_CAPSULE_LEGACY_DATAGRAM, 16#ff37a0).

%% Reserved settings (RFC 9114 Section 7.2.4.1)
%% 0x1f * N + 0x21 for any non-negative integer N

%%====================================================================
%% HTTP/3 Default Settings Values
%%====================================================================

-define(H3_DEFAULT_QPACK_MAX_TABLE_CAPACITY, 0).
-define(H3_DEFAULT_MAX_FIELD_SECTION_SIZE, 65536).
-define(H3_DEFAULT_QPACK_BLOCKED_STREAMS, 0).

%%====================================================================
%% DoS-bounded ceilings (RFC 9114 §7.1 + §7.2.4 reasonable limits)
%%====================================================================

%% Maximum accepted frame payload size. Anything larger is rejected with
%% H3_EXCESSIVE_LOAD before allocation, to prevent unbounded memory use
%% when peers craft pathological Length varints (up to 2^62 - 1).
-define(H3_MAX_FRAME_SIZE, 16#100000).

%% Cap on a request body buffered at the H3 layer when no Content-Length
%% bounds it. Flow control limits in-flight bytes, but a long stream whose
%% data is consumed could otherwise grow this buffer without bound.
-define(H3_MAX_BUFFERED_BODY, 16#1000000).

%% What one retained chunk costs against `max_buffered_body' on top of its
%% payload. Without it an empty chunk, or a fin-only entry left by a request
%% no handler claimed, would be free and a peer could accumulate entries
%% without spending the budget.
-define(H3_BUFFER_CHUNK_OVERHEAD, 64).

%%====================================================================
%% QPACK Error Codes (RFC 9204 Section 8.2)
%%====================================================================

-define(H3_QPACK_DECOMPRESSION_FAILED, 16#200).
-define(H3_QPACK_ENCODER_STREAM_ERROR, 16#201).
-define(H3_QPACK_DECODER_STREAM_ERROR, 16#202).

%%====================================================================
%% HTTP/3 Stream State
%%====================================================================

-record(h3_stream, {
    %% Stream ID
    id :: non_neg_integer(),

    %% Stream type
    type :: request | push,

    %% Stream state
    state :: idle | open | half_closed_local | half_closed_remote | closed,

    %% For request streams: method, path, and headers
    method :: binary() | undefined,
    path :: binary() | undefined,
    scheme :: binary() | undefined,
    authority :: binary() | undefined,

    %% Headers (request or response)
    headers = [] :: [{binary(), binary()}],
    trailers = [] :: [{binary(), binary()}],

    %% Response status (for client)
    status :: non_neg_integer() | undefined,

    %% Retained for compatibility; DATA payloads are delivered through
    %% events/handlers and are not accumulated in the stream record.
    body = <<>> :: binary(),

    %% Content-Length tracking
    content_length :: non_neg_integer() | undefined,
    body_received = 0 :: non_neg_integer(),

    %% Frame parsing state
    %% expecting_headers: waiting for HEADERS frame
    %% expecting_data: received HEADERS, waiting for DATA/trailers
    %% expecting_trailers: received DATA with fin, expecting trailers
    %% complete: stream finished
    frame_state = expecting_headers ::
        expecting_headers | expecting_data | expecting_trailers | complete,

    %% Bytes of the current DATA frame still to arrive; 0 between frames.
    data_remaining = 0 :: non_neg_integer(),

    %% Priority (RFC 9218 Extensible Priorities)
    %% urgency: 0-7 (lower = more urgent, default 3)
    %% incremental: whether data can be processed incrementally
    urgency = 3 :: 0..7,
    incremental = false :: boolean(),

    %% RFC 9114 §4.4 CONNECT: once the request/response succeeds, the stream
    %% becomes a raw tunnel carrying only DATA frames.
    is_connect = false :: boolean(),

    %% RFC 9220 extended CONNECT: :protocol pseudo-header (e.g. websocket).
    %% Set when SETTINGS_ENABLE_CONNECT_PROTOCOL is negotiated and the
    %% client sends method=CONNECT with :protocol.
    protocol :: binary() | undefined,

    %% This stream was reset rather than finished. Both end up `closed',
    %% but a reset one stays in the map so whatever else arrives on it is
    %% swallowed, while a finished one is dropped.
    reset = false :: boolean(),

    %% Receive credit. `manual': QUIC grants it only for what the reader
    %% returns with quic_h3:consume/3. `received' counts QUIC stream bytes
    %% handed to the parser, `unconsumed' payload delivered but not yet
    %% consumed, `consumed_sent' the offset last reported to QUIC.
    flow = auto :: auto | manual,
    received = 0 :: non_neg_integer(),
    unconsumed = 0 :: non_neg_integer(),
    consumed_sent = 0 :: non_neg_integer()
}).

%%====================================================================
%% HTTP/3 Connection State
%%====================================================================

-record(h3_conn, {
    %% Underlying QUIC connection reference
    quic_conn :: reference(),

    %% Role: client or server
    role :: client | server,

    %% Connection state
    state = connecting :: connecting | connected | goaway_sent | goaway_received | closing,

    %% Critical unidirectional streams (RFC 9114 Section 6.2)
    %% Local streams (we opened)
    local_control_stream :: non_neg_integer() | undefined,
    local_encoder_stream :: non_neg_integer() | undefined,
    local_decoder_stream :: non_neg_integer() | undefined,

    %% Remote streams (peer opened)
    peer_control_stream :: non_neg_integer() | undefined,
    peer_encoder_stream :: non_neg_integer() | undefined,
    peer_decoder_stream :: non_neg_integer() | undefined,

    %% QPACK state
    qpack_encoder :: quic_qpack:state(),
    qpack_decoder :: quic_qpack:state(),

    %% Settings (local and peer)
    local_settings :: map(),
    peer_settings :: map() | undefined,
    settings_sent = false :: boolean(),
    settings_received = false :: boolean(),

    %% Push state (server push)
    max_push_id :: non_neg_integer() | undefined,
    next_push_id = 0 :: non_neg_integer(),

    %% GOAWAY state
    goaway_id :: non_neg_integer() | undefined,

    %% Request streams (bidirectional)
    %% Maps StreamId -> stream state
    streams = #{} :: #{non_neg_integer() => #h3_stream{}},

    %% Next local stream ID for requests (client: 0, 4, 8, ...; server: 1, 5, 9, ...)
    next_request_stream_id :: non_neg_integer(),

    %% Owner process
    owner :: pid(),

    %% Pending data buffers for partial frame decoding per stream
    stream_buffers = #{} :: #{non_neg_integer() => binary()}
}).

%%====================================================================
%% HTTP/3 Frame Records
%%====================================================================

-record(h3_frame_data, {
    payload :: binary()
}).

-record(h3_frame_headers, {
    header_block :: binary()
}).

-record(h3_frame_cancel_push, {
    push_id :: non_neg_integer()
}).

-record(h3_frame_settings, {
    settings :: map()
}).

-record(h3_frame_push_promise, {
    push_id :: non_neg_integer(),
    header_block :: binary()
}).

-record(h3_frame_goaway, {
    stream_id :: non_neg_integer()
}).

-record(h3_frame_max_push_id, {
    push_id :: non_neg_integer()
}).

-record(h3_frame_unknown, {
    type :: non_neg_integer(),
    payload :: binary()
}).

-endif.
