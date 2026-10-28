%%% -*- erlang -*-
%%%
%%% QLOG Tracing for QUIC (draft-ietf-quic-qlog-quic-events)
%%% JSON-SEQ format for Wireshark/qvis compatibility
%%%

-ifndef(QUIC_QLOG_HRL).
-define(QUIC_QLOG_HRL, true).

%%====================================================================
%% QLOG Context Record
%%====================================================================

%% Per-connection QLOG context
-record(qlog_ctx, {
    %% Whether qlog is enabled for this connection
    enabled = false :: boolean(),
    %% Writer process pid (handles async file writes)
    writer :: pid() | undefined,
    %% Original Destination Connection ID (used for filename)
    odcid :: binary() | undefined,
    %% Reference time in milliseconds (erlang:system_time(millisecond))
    reference_time :: integer() | undefined,
    %% Vantage point: client or server
    vantage_point :: client | server | undefined,
    %% Which events to log: all or a list of event atoms
    events = all :: all | [atom()],
    %% Directory for qlog files
    dir = "/tmp/qlog" :: file:filename()
}).

%%====================================================================
%% Event Types
%%====================================================================

%% Transport events
-define(QLOG_PACKET_SENT, packet_sent).
-define(QLOG_PACKET_RECEIVED, packet_received).
-define(QLOG_FRAMES_PROCESSED, frames_processed).

%% Connectivity events
-define(QLOG_CONNECTION_STARTED, connection_started).
-define(QLOG_CONNECTION_STATE_UPDATED, connection_state_updated).
-define(QLOG_CONNECTION_CLOSED, connection_closed).

%% Recovery events
-define(QLOG_PACKETS_ACKED, packets_acked).
-define(QLOG_PACKET_LOST, packet_lost).
-define(QLOG_METRICS_UPDATED, metrics_updated).

%%====================================================================
%% Macros for Efficient Guard Checks
%%====================================================================

%% Check if qlog is enabled (use in guards or before emitting events)
-define(QLOG_ENABLED(Ctx),
    (Ctx =/= undefined andalso Ctx#qlog_ctx.enabled =:= true)
).

%% Check if a specific event should be logged
-define(QLOG_EVENT_ENABLED(Ctx, Event),
    (?QLOG_ENABLED(Ctx) andalso
        (Ctx#qlog_ctx.events =:= all orelse
            lists:member(Event, Ctx#qlog_ctx.events)))
).

%% Hot-path emit wrappers. The `Info' / `Frames' / `PNs' argument is
%% only evaluated when qlog is enabled, so the common disabled-by-
%% default path does not pay for map / list construction at every
%% sent / received packet. Use these at any send/recv/ack site that
%% fires on the per-packet hot path.
-define(QLOG_EMIT_PACKET_SENT(Ctx, Info),
    case ?QLOG_ENABLED(Ctx) of
        true -> quic_qlog:packet_sent(Ctx, Info);
        false -> ok
    end
).

-define(QLOG_EMIT_PACKET_RECEIVED(Ctx, Info),
    case ?QLOG_ENABLED(Ctx) of
        true -> quic_qlog:packet_received(Ctx, Info);
        false -> ok
    end
).

-define(QLOG_EMIT_FRAMES_PROCESSED(Ctx, Frames),
    case ?QLOG_ENABLED(Ctx) of
        true -> quic_qlog:frames_processed(Ctx, Frames);
        false -> ok
    end
).

-define(QLOG_EMIT_PACKETS_ACKED(Ctx, PNs, Info),
    case ?QLOG_ENABLED(Ctx) of
        true -> quic_qlog:packets_acked(Ctx, PNs, Info);
        false -> ok
    end
).

-define(QLOG_EMIT_PACKET_LOST(Ctx, Info),
    case ?QLOG_ENABLED(Ctx) of
        true -> quic_qlog:packet_lost(Ctx, Info);
        false -> ok
    end
).

%%====================================================================
%% Writer Configuration
%%====================================================================

%% Flush every 100ms
-define(QLOG_FLUSH_INTERVAL_MS, 100).
%% Or after 1000 events (whichever comes first)
-define(QLOG_FLUSH_THRESHOLD, 1000).
%% Maximum buffer size in bytes before force flush
-define(QLOG_MAX_BUFFER_SIZE, 65536).

%%====================================================================
%% QLOG Version
%%====================================================================

-define(QLOG_VERSION, <<"0.4">>).
-define(QLOG_FORMAT, <<"JSON-SEQ">>).

-endif.
