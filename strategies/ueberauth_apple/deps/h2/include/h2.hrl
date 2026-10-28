%% @doc HTTP/2 protocol definitions
%% RFC 7540 - Hypertext Transfer Protocol Version 2 (HTTP/2)
%% RFC 7541 - HPACK: Header Compression for HTTP/2

-ifndef(H2_HRL).
-define(H2_HRL, 1).

%% HTTP/2 Connection Preface
-define(H2_PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(H2_PREFACE_SIZE, 24).

%% Frame Types (RFC 7540 Section 6)
-define(DATA,          16#0).
-define(HEADERS,       16#1).
-define(PRIORITY,      16#2).
-define(RST_STREAM,    16#3).
-define(SETTINGS,      16#4).
-define(PUSH_PROMISE,  16#5).
-define(PING,          16#6).
-define(GOAWAY,        16#7).
-define(WINDOW_UPDATE, 16#8).
-define(CONTINUATION,  16#9).

%% Frame Flags
-define(FLAG_END_STREAM,  16#1).
-define(FLAG_ACK,         16#1).
-define(FLAG_END_HEADERS, 16#4).
-define(FLAG_PADDED,      16#8).
-define(FLAG_PRIORITY,    16#20).

%% Settings Parameters (RFC 7540 Section 6.5.2)
-define(SETTINGS_HEADER_TABLE_SIZE,      16#1).
-define(SETTINGS_ENABLE_PUSH,            16#2).
-define(SETTINGS_MAX_CONCURRENT_STREAMS, 16#3).
-define(SETTINGS_INITIAL_WINDOW_SIZE,    16#4).
-define(SETTINGS_MAX_FRAME_SIZE,         16#5).
-define(SETTINGS_MAX_HEADER_LIST_SIZE,   16#6).

%% RFC 8441 - Extended CONNECT for WebSockets and WebTransport
-define(SETTINGS_ENABLE_CONNECT_PROTOCOL, 16#8).

%% draft-ietf-webtrans-http2-14 Section 11.2 - WebTransport over HTTP/2
-define(SETTINGS_WT_INITIAL_MAX_DATA,                    16#2b61).
-define(SETTINGS_WT_INITIAL_MAX_STREAM_DATA_UNI,         16#2b62).
-define(SETTINGS_WT_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL,  16#2b63).
-define(SETTINGS_WT_INITIAL_MAX_STREAMS_UNI,             16#2b64).
-define(SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI,            16#2b65).
-define(SETTINGS_WT_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, 16#2b66).

%% Default timeout for connect / wait_connected / TLS handshake (ms).
-define(DEFAULT_TIMEOUT_MS,             30000).

%% Default Settings Values
-define(DEFAULT_HEADER_TABLE_SIZE,      4096).
%% RFC 9113 §6.5.2: endpoints that do not produce server push SHOULD
%% advertise 0. We reject inbound PUSH_PROMISE; advertise 0.
-define(DEFAULT_ENABLE_PUSH,            0).
%% RFC 9113 §5.1.2 RECOMMENDS at least 100. Defaulting to `unlimited`
%% lets a peer keep opening idle streams forever; cap at 100 so the
%% `streams` map (and HPACK dynamic-table state for each) stays bounded.
-define(DEFAULT_MAX_CONCURRENT_STREAMS, 100).
-define(DEFAULT_INITIAL_WINDOW_SIZE,    65535).
-define(DEFAULT_MAX_FRAME_SIZE,         16384).
-define(DEFAULT_MAX_HEADER_LIST_SIZE,   unlimited).

%% Protocol Limits
-define(MIN_FRAME_SIZE,                 16384).
-define(MAX_FRAME_SIZE,                 16777215).
-define(MAX_WINDOW_SIZE,                2147483647).
-define(MAX_STREAM_ID,                  2147483647).

%% Error Codes (RFC 7540 Section 7)
-define(NO_ERROR,            16#0).
-define(PROTOCOL_ERROR,      16#1).
-define(INTERNAL_ERROR,      16#2).
-define(FLOW_CONTROL_ERROR,  16#3).
-define(SETTINGS_TIMEOUT,    16#4).
-define(STREAM_CLOSED,       16#5).
-define(FRAME_SIZE_ERROR,    16#6).
-define(REFUSED_STREAM,      16#7).
-define(CANCEL,              16#8).
-define(COMPRESSION_ERROR,   16#9).
-define(CONNECT_ERROR,       16#a).
-define(ENHANCE_YOUR_CALM,   16#b).
-define(INADEQUATE_SECURITY, 16#c).
-define(HTTP_1_1_REQUIRED,   16#d).

%% HPACK Static Table Size
-define(HPACK_STATIC_TABLE_SIZE, 61).

%% Frame record
-record(h2_frame, {
    length   = 0            :: non_neg_integer(),
    type     = ?DATA        :: 0..255,
    flags    = 0            :: 0..255,
    stream_id = 0           :: non_neg_integer(),
    payload  = <<>>         :: binary()
}).

-endif.
