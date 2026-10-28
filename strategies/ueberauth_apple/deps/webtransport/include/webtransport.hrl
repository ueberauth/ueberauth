%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc WebTransport Protocol Definitions
%%
%% draft-ietf-webtrans-overview-12 - Protocol Framework
%% draft-ietf-webtrans-http2-14 - WebTransport over HTTP/2
%% draft-ietf-webtrans-http3-15 - WebTransport over HTTP/3

-ifndef(WEBTRANSPORT_HRL).
-define(WEBTRANSPORT_HRL, 1).

%% ============================================================================
%% HTTP/2 WebTransport Capsule Types (draft-ietf-webtrans-http2-14)
%% ============================================================================

-define(WT_PADDING,              16#190B4D38).
-define(WT_RESET_STREAM,         16#190B4D39).
-define(WT_STOP_SENDING,         16#190B4D3A).
-define(WT_STREAM,               16#190B4D3B).
-define(WT_STREAM_FIN,           16#190B4D3C).
-define(WT_MAX_DATA,             16#190B4D3D).
-define(WT_MAX_STREAM_DATA,      16#190B4D3E).
-define(WT_MAX_STREAMS_BIDI,     16#190B4D3F).
-define(WT_MAX_STREAMS_UNI,      16#190B4D40).
-define(WT_DATA_BLOCKED,         16#190B4D41).
-define(WT_STREAM_DATA_BLOCKED,  16#190B4D42).
-define(WT_STREAMS_BLOCKED_BIDI, 16#190B4D43).
-define(WT_STREAMS_BLOCKED_UNI,  16#190B4D44).
-define(WT_CLOSE_SESSION,        16#190B4D45).
-define(WT_DRAIN_SESSION,        16#190B4D46).

%% HTTP Datagram capsule (RFC 9297)
-define(DATAGRAM,                16#00).

%% ============================================================================
%% HTTP/3 WebTransport (draft-ietf-webtrans-http3-15)
%% ============================================================================

%% HTTP/3 Settings.
%%
%% The WT settings (wt_enabled, wt_initial_max_data, etc.) are now
%% defined as atoms in erlang_quic (quic_h3.hrl) and erlang_h2 (h2.hrl).
%% Use the atom keys directly in settings maps rather than integer macros.
%%
%% Legacy draft-02 compat uses a separate integer codepoint not in either
%% upstream library:
-define(SETTINGS_ENABLE_WEBTRANSPORT_DRAFT02, 16#2b603742).

%% HTTP/3 Unidirectional Stream Type
-define(WT_UNI_STREAM_TYPE, 16#54).

%% HTTP/3 Bidirectional Stream Signal
-define(WT_BIDI_SIGNAL, 16#41).

%% HTTP/3 Capsule Types (session management)
-define(WT_CLOSE_SESSION_H3, 16#2843).
-define(WT_DRAIN_SESSION_H3, 16#78ae).

%% HTTP/3 Error Codes
-define(WT_BUFFERED_STREAM_REJECTED, 16#3994bd84).
-define(WT_SESSION_GONE,             16#170d7b68).
-define(WT_FLOW_CONTROL_ERROR,       16#045d4487).
-define(WT_ALPN_ERROR,               16#0817b3dd).
-define(WT_REQUIREMENTS_NOT_MET,     16#212c0d48).

%% Application error code base
-define(WT_APP_ERROR_FIRST, 16#52e4a40fa8db).

%% ============================================================================
%% Stream State (defined first, referenced by session)
%% ============================================================================

-record(wt_stream, {
    id :: non_neg_integer(),
    type :: bidi | uni,
    state = open :: open | half_closed_local | half_closed_remote | closed,

    %% Flow control
    send_window :: non_neg_integer(),
    recv_window :: non_neg_integer(),

    %% Buffers
    send_buffer = <<>> :: binary(),
    recv_buffer = <<>> :: binary()
}).

%% ============================================================================
%% Session State
%% ============================================================================

-record(wt_session, {
    id :: non_neg_integer(),
    transport :: h2 | h3,
    path :: binary(),
    authority :: binary(),
    state = open :: open | draining | closed,

    %% Flow control (for H2, managed by capsules)
    local_max_data :: non_neg_integer(),
    remote_max_data :: non_neg_integer(),
    local_max_streams_bidi :: non_neg_integer(),
    local_max_streams_uni :: non_neg_integer(),
    remote_max_streams_bidi :: non_neg_integer(),
    remote_max_streams_uni :: non_neg_integer(),

    %% Active streams
    streams :: #{non_neg_integer() => #wt_stream{}},
    stream_count_bidi :: non_neg_integer(),
    stream_count_uni :: non_neg_integer()
}).

%% ============================================================================
%% Default Settings
%% ============================================================================

-define(DEFAULT_MAX_DATA, 1048576).  %% 1 MB
-define(DEFAULT_MAX_STREAM_DATA, 262144).  %% 256 KB
-define(DEFAULT_MAX_STREAMS_BIDI, 100).
-define(DEFAULT_MAX_STREAMS_UNI, 100).
-define(DEFAULT_MAX_SESSIONS, 100).

%% ============================================================================
%% Datagram size ceilings
%% ============================================================================
%%
%% H2 datagrams travel as capsules over the CONNECT stream, bounded by the
%% HTTP/2 default initial stream window (65535 bytes). The capsule header
%% (type varint + length varint) consumes a few bytes; we reserve 64 bytes
%% of headroom to leave room for the RFC 9297 DATAGRAM capsule framing and
%% any intermediate HTTP/2 framing overhead.
-define(WT_H2_DATAGRAM_MAX, 65471).  %% 65535 - 64

%% H3 datagrams are QUIC datagrams prefixed with a quarter-stream-id varint.
%% The peer-advertised `max_datagram_frame_size' (we set 65535) caps the
%% whole encoded datagram — payload + session-id varint — so we reserve
%% 8 bytes for the worst-case varint encoding of the session id.
-define(WT_H3_DATAGRAM_MAX, 65527).  %% 65535 - 8

-endif.
