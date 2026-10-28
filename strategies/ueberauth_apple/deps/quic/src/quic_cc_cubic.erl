%%% -*- erlang -*-
%%%
%%% QUIC CUBIC Congestion Control
%%% RFC 9438 - CUBIC for Fast and Long-Distance Networks
%%% RFC 9406 - HyStart++: Modified Slow Start for TCP
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC CUBIC congestion control implementation.
%%%
%%% This module implements the CUBIC congestion control algorithm with:
%%% - RFC 9438 CUBIC window function
%%% - HyStart++ slow start enhancement (RFC 9406)
%%% - Fast convergence for rapid bandwidth discovery
%%% - TCP-friendly mode for fairness
%%% - Application-limited epoch handling
%%% - Pacing support
%%%
%%% == Phases ==
%%%
%%% 1. Slow Start with HyStart++: Exponential growth with RTT-based exit
%%% 2. Congestion Avoidance: CUBIC window function W(t) = C*(t-K)^3 + W_max
%%% 3. Recovery: Multiplicative decrease by beta=0.7 (30% reduction)
%%%

-module(quic_cc_cubic).

-behaviour(quic_cc).

-include_lib("kernel/include/logger.hrl").
-define(QUIC_LOG_META, #{domain => [erlang_quic, congestion_control]}).

-export([
    %% Behavior callbacks
    new/1,
    on_packet_sent/2,
    on_packets_acked/2,
    on_packets_acked/3,
    on_packets_lost/2,
    on_congestion_event/2,
    on_ecn_ce/2,
    on_persistent_congestion/1,
    detect_persistent_congestion/3,
    update_pacing_rate/2,
    update_mtu/2,
    cwnd/1,
    initial_window/1,
    on_packets_discarded/2,
    reset_for_retry/1,
    ssthresh/1,
    bytes_in_flight/1,
    can_send/2,
    can_send_control/2,
    available_cwnd/1,
    in_slow_start/1,
    in_recovery/1,
    pacing_allows/2,
    get_pacing_tokens/2,
    pacing_delay/2,
    send_check/3,
    max_datagram_size/1,
    min_recovery_duration/1,
    ecn_ce_counter/1
]).

%%====================================================================
%% Constants (RFC 9438 + quic-go style)
%%====================================================================

%% CUBIC scaling constant (RFC 9438 Section 5.1)
%% C determines CUBIC's aggressiveness in high BDP networks
-define(CUBIC_C, 0.4).

%% Multiplicative decrease factor (RFC 9438 Section 4.6)
%% CUBIC uses 0.7 (30% reduction) vs NewReno's 0.5
-define(CUBIC_BETA, 0.7).

%% Fast convergence factor (RFC 9438 Section 4.7)
%% W_max = cwnd * (1 + beta) / 2 when cwnd < W_max before loss
%% (1 + 0.7) / 2 = 0.85
-define(FAST_CONVERGENCE_FACTOR, 0.85).

%% TCP-friendly alpha (RFC 9438 Section 4.3)
%% alpha = 3 * (1 - beta) / (1 + beta)
%% With beta = 0.7: alpha = 3 * 0.3 / 1.7 ≈ 0.529
-define(ALPHA_CUBIC, 0.5294117647058824).

%% Default values
-define(MAX_DATAGRAM_SIZE, 1200).
-define(INITIAL_WINDOW, 38400).
-define(PERSISTENT_CONGESTION_THRESHOLD, 3).

%% HyStart++ constants (RFC 9406)
%% Minimum RTT samples before making slow start exit decision
-define(HYSTART_MIN_SAMPLES, 8).
%% CSS growth divisor: grow cwnd by cwnd/divisor per RTT
-define(HYSTART_CSS_GROWTH_DIV, 4).
%% Number of rounds in CSS before entering congestion avoidance
-define(HYSTART_CSS_ROUNDS, 5).
%% Dynamic RTT threshold bounds (RFC 9406)
%% Minimum RTT threshold in milliseconds
-define(HYSTART_MIN_RTT_THRESH, 4).
%% Maximum RTT threshold in milliseconds
-define(HYSTART_MAX_RTT_THRESH, 16).
%% Divisor for baseline RTT to calculate dynamic threshold
-define(HYSTART_MIN_RTT_DIVISOR, 8).

%%====================================================================
%% State Record
%%====================================================================

-record(cubic_state, {
    %% CUBIC core state (RFC 9438)
    %% Window size at last congestion event
    w_max = 0 :: non_neg_integer(),
    %% Previous W_max for fast convergence
    w_last_max = 0 :: non_neg_integer(),
    %% Time to reach W_max (seconds, float)
    k = 0.0 :: float(),
    %% Congestion avoidance epoch start time (milliseconds)
    epoch_start = 0 :: non_neg_integer(),
    %% Origin point (W_max) for current cubic curve
    origin_point = 0 :: non_neg_integer(),
    %% TCP-friendly window comparison
    tcp_cwnd = 0 :: non_neg_integer(),
    %% cwnd when exiting slow start (for HyStart++)
    cwnd_prior = 0 :: non_neg_integer(),

    %% Standard CC state
    cwnd :: non_neg_integer(),
    ssthresh :: non_neg_integer() | infinity,
    bytes_in_flight = 0 :: non_neg_integer(),
    recovery_start_time :: non_neg_integer() | undefined,
    in_recovery = false :: boolean(),
    ecn_ce_counter = 0 :: non_neg_integer(),
    first_sent_time :: non_neg_integer() | undefined,

    %% HyStart++ state (RFC 9406)
    %% Whether HyStart++ is enabled
    hystart_enabled = true :: boolean(),
    %% In Conservative Slow Start phase
    hystart_in_css = false :: boolean(),
    %% Number of CSS rounds completed
    hystart_css_rounds = 0 :: non_neg_integer(),
    %% RTT sample count in current round
    hystart_rtt_sample_count = 0 :: non_neg_integer(),
    %% Last round's minimum RTT
    hystart_last_rtt = 0 :: non_neg_integer(),
    %% Current round's minimum RTT
    hystart_curr_rtt = infinity :: non_neg_integer() | infinity,
    %% Round start packet number (deprecated, kept for compatibility)
    hystart_round_start = 0 :: non_neg_integer(),
    %% Round start time for time-based round detection (RFC 9406)
    hystart_round_start_time = 0 :: non_neg_integer(),
    %% CSS baseline RTT for potential reversion to slow start (RFC 9406)
    hystart_css_baseline_rtt = infinity :: non_neg_integer() | infinity,

    %% Application-limited tracking
    app_limited = false :: boolean(),
    app_limited_start = 0 :: non_neg_integer(),

    %% Configuration
    %% The window this controller started with. cwnd evolves away from
    %% it, so without keeping it a reset cannot restore the configured
    %% value.
    initial_window :: non_neg_integer(),
    minimum_window :: non_neg_integer(),
    max_datagram_size :: pos_integer(),
    min_recovery_duration = 100 :: non_neg_integer(),
    control_allowance = 1200 :: non_neg_integer(),

    %% Pacing state
    pacing_rate = 0 :: non_neg_integer(),
    pacing_tokens = 0 :: non_neg_integer(),
    pacing_max_burst = 14400 :: non_neg_integer(),
    last_pacing_update = 0 :: non_neg_integer(),
    smoothed_rtt = 100 :: non_neg_integer()
}).

-opaque cc_state() :: #cubic_state{}.
-export_type([cc_state/0]).

%%====================================================================
%% Behavior Callbacks
%%====================================================================

%% @doc Create a new CUBIC congestion control state with options.
-spec new(quic_cc:cc_opts()) -> cc_state().
new(Opts) ->
    MaxDatagramSize = maps:get(max_datagram_size, Opts, ?MAX_DATAGRAM_SIZE),
    DefaultWindow = default_initial_window(MaxDatagramSize),
    DefaultMinimumWindow = minimum_window(MaxDatagramSize),
    ConfiguredMinimumWindow =
        case maps:find(minimum_window, Opts) of
            {ok, Value} when is_integer(Value), Value > 0 ->
                max(Value, DefaultMinimumWindow);
            _ ->
                DefaultMinimumWindow
        end,
    InitialWindow0 = maps:get(initial_window, Opts, DefaultWindow),
    InitialWindow = max(InitialWindow0, ConfiguredMinimumWindow),
    MinRecoveryDuration = maps:get(min_recovery_duration, Opts, 100),
    HystartEnabled = maps:get(hystart_enabled, Opts, true),
    PacingMaxBurst = 12 * MaxDatagramSize,
    Now = erlang:monotonic_time(microsecond),
    ?LOG_DEBUG(
        #{
            what => cc_state_initialized,
            algorithm => cubic,
            initial_cwnd => InitialWindow,
            minimum_window => ConfiguredMinimumWindow,
            max_datagram_size => MaxDatagramSize,
            hystart_enabled => HystartEnabled
        },
        ?QUIC_LOG_META
    ),
    #cubic_state{
        cwnd = InitialWindow,
        initial_window = InitialWindow,
        ssthresh = infinity,
        minimum_window = ConfiguredMinimumWindow,
        max_datagram_size = MaxDatagramSize,
        min_recovery_duration = MinRecoveryDuration,
        hystart_enabled = HystartEnabled,
        pacing_max_burst = PacingMaxBurst,
        pacing_tokens = PacingMaxBurst,
        last_pacing_update = Now
    }.

%%====================================================================
%% Congestion Control Events
%%====================================================================

%% @doc Record that a packet was sent.
-spec on_packet_sent(cc_state(), non_neg_integer()) -> cc_state().
on_packet_sent(
    #cubic_state{
        bytes_in_flight = InFlight,
        first_sent_time = undefined
    } = State,
    Size
) ->
    Now = erlang:monotonic_time(millisecond),
    State#cubic_state{
        bytes_in_flight = InFlight + Size,
        first_sent_time = Now
    };
on_packet_sent(#cubic_state{bytes_in_flight = InFlight} = State, Size) ->
    State#cubic_state{bytes_in_flight = InFlight + Size}.

%% @doc Process acknowledged packets.
-spec on_packets_acked(cc_state(), non_neg_integer()) -> cc_state().
on_packets_acked(State, AckedBytes) ->
    Now = erlang:monotonic_time(millisecond),
    on_packets_acked(State, AckedBytes, Now).

%% @doc Process acknowledged packets with largest acked sent time.
-spec on_packets_acked(cc_state(), non_neg_integer(), non_neg_integer()) -> cc_state().
on_packets_acked(
    #cubic_state{
        bytes_in_flight = InFlight,
        in_recovery = true,
        recovery_start_time = RecoveryStart,
        min_recovery_duration = MinDuration
    } = State,
    AckedBytes,
    LargestAckedSentTime
) ->
    NewInFlight = max(0, InFlight - AckedBytes),
    Now = erlang:monotonic_time(millisecond),
    RecoveryDuration = Now - RecoveryStart,

    case
        RecoveryDuration >= MinDuration andalso
            (LargestAckedSentTime > RecoveryStart orelse NewInFlight =:= 0)
    of
        true ->
            %% Exit recovery
            State1 = State#cubic_state{
                bytes_in_flight = NewInFlight,
                in_recovery = false,
                recovery_start_time = Now
            },
            %% Reset epoch and continue cubic growth
            cubic_on_ack(State1, AckedBytes, LargestAckedSentTime);
        false ->
            %% Still in recovery, don't increase cwnd
            State#cubic_state{bytes_in_flight = NewInFlight}
    end;
on_packets_acked(
    #cubic_state{bytes_in_flight = InFlight} = State, AckedBytes, LargestAckedSentTime
) ->
    NewInFlight = max(0, InFlight - AckedBytes),
    State1 = State#cubic_state{bytes_in_flight = NewInFlight},
    cubic_on_ack(State1, AckedBytes, LargestAckedSentTime).

%% @private CUBIC ACK processing with HyStart++ and TCP-friendly mode
cubic_on_ack(
    #cubic_state{cwnd = Cwnd, ssthresh = SSThresh} = State, AckedBytes, LargestAckedSentTime
) when
    Cwnd < SSThresh
->
    %% In slow start
    hystart_on_ack(State, AckedBytes, LargestAckedSentTime);
cubic_on_ack(State, AckedBytes, _LargestAckedSentTime) ->
    %% In congestion avoidance - use CUBIC window function
    cubic_congestion_avoidance(State, AckedBytes).

%% @private HyStart++ slow start processing (RFC 9406)
hystart_on_ack(
    #cubic_state{
        cwnd = Cwnd,
        hystart_enabled = false
    } = State,
    AckedBytes,
    _LargestAckedSentTime
) ->
    %% HyStart++ disabled - standard slow start
    NewCwnd = Cwnd + AckedBytes,
    State#cubic_state{cwnd = NewCwnd};
hystart_on_ack(
    #cubic_state{
        cwnd = Cwnd,
        max_datagram_size = MaxDS,
        hystart_in_css = true,
        hystart_css_rounds = Rounds,
        hystart_css_baseline_rtt = BaselineRTT,
        hystart_curr_rtt = CurrRTT,
        hystart_rtt_sample_count = SampleCount,
        hystart_round_start_time = RoundStartTime
    } = State,
    AckedBytes,
    LargestAckedSentTime
) ->
    Now = erlang:monotonic_time(millisecond),
    NewSampleCount = SampleCount + 1,

    %% Check for CSS reversion after enough samples (RFC 9406)
    %% If RTT dropped below baseline, revert to slow start
    case NewSampleCount >= ?HYSTART_MIN_SAMPLES of
        true when is_integer(CurrRTT), is_integer(BaselineRTT), CurrRTT < BaselineRTT ->
            %% RTT dropped below CSS entry point - revert to slow start
            ?LOG_DEBUG(
                #{
                    what => hystart_css_revert,
                    cwnd => Cwnd,
                    curr_rtt => CurrRTT,
                    baseline_rtt => BaselineRTT
                },
                ?QUIC_LOG_META
            ),
            NewCwnd = Cwnd + AckedBytes,
            State#cubic_state{
                cwnd = NewCwnd,
                hystart_in_css = false,
                hystart_css_rounds = 0,
                hystart_css_baseline_rtt = infinity,
                hystart_rtt_sample_count = 0,
                hystart_round_start_time = Now
            };
        _ ->
            %% Continue CSS with linear growth
            Increment = max(
                MaxDS, (Cwnd * AckedBytes) div (max(Cwnd, 1) * ?HYSTART_CSS_GROWTH_DIV)
            ),
            NewCwnd = Cwnd + Increment,

            %% Time-based round detection (RFC 9406)
            %% A new round begins when we ACK a packet sent after round started
            {NewRounds, NewRoundStartTime} =
                case LargestAckedSentTime > RoundStartTime of
                    true ->
                        %% ACK for packet sent after round started = new round
                        {Rounds + 1, Now};
                    false ->
                        {Rounds, RoundStartTime}
                end,

            case NewRounds >= ?HYSTART_CSS_ROUNDS of
                true ->
                    %% Exit slow start, enter congestion avoidance
                    ?LOG_DEBUG(
                        #{
                            what => hystart_css_complete,
                            cwnd => NewCwnd,
                            rounds => NewRounds
                        },
                        ?QUIC_LOG_META
                    ),
                    State#cubic_state{
                        cwnd = NewCwnd,
                        ssthresh = NewCwnd,
                        cwnd_prior = NewCwnd,
                        hystart_in_css = false,
                        hystart_css_rounds = 0,
                        hystart_css_baseline_rtt = infinity,
                        hystart_round_start_time = 0
                    };
                false ->
                    State#cubic_state{
                        cwnd = NewCwnd,
                        hystart_css_rounds = NewRounds,
                        hystart_rtt_sample_count = NewSampleCount,
                        hystart_round_start_time = NewRoundStartTime
                    }
            end
    end;
hystart_on_ack(
    #cubic_state{
        cwnd = Cwnd,
        hystart_rtt_sample_count = SampleCount,
        hystart_last_rtt = LastRTT,
        hystart_curr_rtt = CurrRTT
    } = State,
    AckedBytes,
    _LargestAckedSentTime
) ->
    %% Standard slow start with HyStart++ RTT monitoring
    Now = erlang:monotonic_time(millisecond),
    NewCwnd = Cwnd + AckedBytes,
    NewSampleCount = SampleCount + 1,

    %% Check for RTT-based exit condition after minimum samples
    State1 = State#cubic_state{
        cwnd = NewCwnd,
        hystart_rtt_sample_count = NewSampleCount
    },

    case NewSampleCount >= ?HYSTART_MIN_SAMPLES of
        true when LastRTT > 0, is_integer(CurrRTT), CurrRTT > 0 ->
            %% Calculate dynamic RTT threshold (RFC 9406)
            %% RttThresh = clamp(MIN, lastRTT/DIVISOR, MAX)
            RTTThresh = calculate_rtt_threshold(LastRTT),
            %% Check if current RTT exceeds threshold
            RTTIncrease = CurrRTT - LastRTT,
            case RTTIncrease > RTTThresh of
                true ->
                    %% Enter Conservative Slow Start
                    %% Save current RTT as baseline for potential reversion
                    %% Initialize round_start_time for time-based round detection
                    ?LOG_DEBUG(
                        #{
                            what => hystart_enter_css,
                            cwnd => NewCwnd,
                            rtt_increase => RTTIncrease,
                            rtt_threshold => RTTThresh,
                            last_rtt => LastRTT,
                            curr_rtt => CurrRTT
                        },
                        ?QUIC_LOG_META
                    ),
                    State1#cubic_state{
                        hystart_in_css = true,
                        hystart_css_rounds = 0,
                        cwnd_prior = NewCwnd,
                        hystart_css_baseline_rtt = CurrRTT,
                        hystart_rtt_sample_count = 0,
                        hystart_round_start_time = Now
                    };
                false ->
                    State1
            end;
        _ ->
            State1
    end.

%% @private Calculate dynamic RTT threshold (RFC 9406)
%% RttThresh = clamp(MIN, lastRTT/DIVISOR, MAX)
calculate_rtt_threshold(LastRTT) when LastRTT > 0 ->
    Threshold = LastRTT div ?HYSTART_MIN_RTT_DIVISOR,
    max(?HYSTART_MIN_RTT_THRESH, min(Threshold, ?HYSTART_MAX_RTT_THRESH));
calculate_rtt_threshold(_) ->
    ?HYSTART_MIN_RTT_THRESH.

%% @private CUBIC congestion avoidance (RFC 9438)
cubic_congestion_avoidance(
    #cubic_state{
        cwnd = Cwnd,
        w_max = WMax,
        epoch_start = EpochStart,
        origin_point = OriginPoint,
        tcp_cwnd = TcpCwnd,
        k = K,
        max_datagram_size = MaxDS
    } = State,
    AckedBytes
) ->
    Now = erlang:monotonic_time(millisecond),

    %% Initialize epoch if needed (RFC 9438 Section 4.8)
    {NewEpochStart, NewOriginPoint, NewK, NewTcpCwnd} =
        case EpochStart of
            0 ->
                %% Start of new epoch
                EP0 = Now,
                %% W_max for CUBIC curve origin (RFC 9438 Section 4.2)
                OP0 = max(Cwnd, WMax),
                %% K = cbrt(W_max * (1 - beta) / C) (RFC 9438 Section 4.2)
                K0 = cubic_k(OP0, MaxDS),
                %% W_est initialized to cwnd at epoch start (RFC 9438 Section 4.3)
                TC0 = Cwnd,
                {EP0, OP0, K0, TC0};
            _ ->
                {EpochStart, OriginPoint, K, TcpCwnd}
        end,

    %% Time since epoch start in seconds
    T = (Now - NewEpochStart) / 1000.0,

    %% CUBIC window: W_cubic(t) = C * (t - K)^3 + W_max (RFC 9438 Section 4.2)
    CubicCwnd = cubic_window(T, NewK, NewOriginPoint, MaxDS),

    %% TCP-friendly mode (RFC 9438 Section 4.3)
    %% W_est = W_est + alpha * acked_segments / cwnd
    %% alpha = 3 * (1 - beta) / (1 + beta) ≈ 0.529
    AckedSegments = AckedBytes / MaxDS,
    CwndSegments = max(1, Cwnd / MaxDS),
    TcpIncSegments = ?ALPHA_CUBIC * AckedSegments / CwndSegments,
    NewTcpCwnd1 = trunc(NewTcpCwnd + TcpIncSegments * MaxDS),

    %% Use the larger of CUBIC and TCP-friendly windows (RFC 9438 Section 4.3)
    TargetCwnd = max(CubicCwnd, NewTcpCwnd1),

    %% Calculate increment based on target (RFC 9438 Section 4.4/4.5)
    %% Increment = (target - cwnd) / cwnd per ACK
    Increment =
        case TargetCwnd > Cwnd of
            true ->
                %% Concave or convex region: grow toward target
                Inc0 = ((TargetCwnd - Cwnd) * AckedBytes) div max(Cwnd, 1),
                max(1, Inc0);
            false ->
                %% At or above target, minimal growth (1 byte per ACK minimum)
                1
        end,

    NewCwnd = Cwnd + Increment,

    ?LOG_DEBUG(
        #{
            what => cubic_ca_update,
            old_cwnd => Cwnd,
            new_cwnd => NewCwnd,
            cubic_cwnd => CubicCwnd,
            tcp_cwnd => NewTcpCwnd1,
            target => TargetCwnd,
            t => T,
            k => NewK,
            w_max => WMax
        },
        ?QUIC_LOG_META
    ),

    State#cubic_state{
        cwnd = NewCwnd,
        epoch_start = NewEpochStart,
        origin_point = NewOriginPoint,
        k = NewK,
        tcp_cwnd = NewTcpCwnd1
    }.

%% @private Calculate K - time to reach W_max (RFC 9438 Section 4.2)
%% K = cubic_root(W_max * (1 - beta) / C)
%% Where W_max is in segments (bytes / max_datagram_size)
cubic_k(WMaxBytes, MaxDS) when WMaxBytes > 0, MaxDS > 0 ->
    %% Convert to segments for the cubic calculation
    WMaxSegments = WMaxBytes / MaxDS,
    %% K = cbrt(W_max * (1 - beta) / C)
    %% With beta = 0.7: (1 - 0.7) = 0.3
    math:pow(WMaxSegments * (1 - ?CUBIC_BETA) / ?CUBIC_C, 1.0 / 3.0);
cubic_k(_WMax, _MaxDS) ->
    0.0.

%% @private CUBIC window function (RFC 9438 Section 4.2)
%% W_cubic(t) = C * (t - K)^3 + W_max
%% Returns target window in bytes
cubic_window(T, K, WMaxBytes, MaxDS) ->
    Diff = T - K,
    %% C * (t - K)^3 gives segments, multiply by MaxDS for bytes
    %% Then add W_max (in bytes)
    CubicSegments = ?CUBIC_C * Diff * Diff * Diff,
    CubicBytes = trunc(CubicSegments * MaxDS) + WMaxBytes,
    max(0, CubicBytes).

%% @doc Process lost packets.
-spec on_packets_lost(cc_state(), non_neg_integer()) -> cc_state().
on_packets_lost(#cubic_state{bytes_in_flight = InFlight} = State, LostBytes) ->
    NewInFlight = max(0, InFlight - LostBytes),
    State#cubic_state{bytes_in_flight = NewInFlight}.

%% @doc Handle a congestion event (packet loss detected).
-spec on_congestion_event(cc_state(), non_neg_integer()) -> cc_state().
on_congestion_event(
    #cubic_state{
        in_recovery = true,
        recovery_start_time = RecoveryStart
    } = State,
    SentTime
) when SentTime =< RecoveryStart ->
    %% Already in recovery for this event
    State;
on_congestion_event(
    #cubic_state{
        in_recovery = true,
        recovery_start_time = RecoveryStart,
        min_recovery_duration = MinDuration
    } = State,
    SentTime
) ->
    Now = erlang:monotonic_time(millisecond),
    RecoveryDuration = Now - RecoveryStart,
    case RecoveryDuration < MinDuration of
        true ->
            %% Protected recovery period
            State;
        false ->
            do_congestion_event(State, SentTime)
    end;
on_congestion_event(
    #cubic_state{
        in_recovery = false,
        recovery_start_time = RecoveryStart
    } = State,
    SentTime
) when is_integer(RecoveryStart), SentTime =< RecoveryStart ->
    %% Packet sent before last recovery ended
    State;
on_congestion_event(State, SentTime) ->
    do_congestion_event(State, SentTime).

%% @private Execute congestion event with CUBIC-specific handling
do_congestion_event(
    #cubic_state{
        cwnd = Cwnd,
        w_last_max = WLastMax,
        minimum_window = MinimumWindow
    } = State,
    SentTime
) ->
    Now = erlang:monotonic_time(millisecond),

    %% Fast convergence (RFC 9438 Section 4.7)
    %% If cwnd < W_last_max, we're still recovering from previous loss
    %% Apply fast convergence to release bandwidth for new flows
    {NewWMax, NewWLastMax} =
        case Cwnd < WLastMax of
            true ->
                %% Fast convergence: W_max = cwnd * (1 + beta) / 2
                %% This is approximately cwnd * 0.85 with beta = 0.7
                FastConvergenceWMax = trunc(Cwnd * ?FAST_CONVERGENCE_FACTOR),
                {FastConvergenceWMax, Cwnd};
            false ->
                %% Normal case: W_max = cwnd, W_last_max = cwnd
                {Cwnd, Cwnd}
        end,

    %% CUBIC uses beta=0.7 (30% reduction) vs NewReno's 0.5 (RFC 9438 Section 4.6)
    %% ssthresh = cwnd * beta
    NewSSThresh = max(trunc(Cwnd * ?CUBIC_BETA), MinimumWindow),
    NewCwnd = max(NewSSThresh, MinimumWindow),

    ?LOG_DEBUG(
        #{
            what => cubic_congestion_event,
            old_cwnd => Cwnd,
            new_cwnd => NewCwnd,
            ssthresh => NewSSThresh,
            w_max => NewWMax,
            w_last_max => NewWLastMax,
            fast_convergence => Cwnd < WLastMax
        },
        ?QUIC_LOG_META
    ),

    State#cubic_state{
        cwnd = NewCwnd,
        ssthresh = NewSSThresh,
        w_max = NewWMax,
        w_last_max = NewWLastMax,
        recovery_start_time = Now,
        in_recovery = true,
        first_sent_time = SentTime,
        %% Reset epoch for next congestion avoidance phase
        epoch_start = 0,
        origin_point = 0,
        k = 0.0,
        tcp_cwnd = 0,
        %% Reset HyStart++ state
        hystart_in_css = false,
        hystart_css_rounds = 0,
        hystart_rtt_sample_count = 0,
        hystart_css_baseline_rtt = infinity,
        hystart_round_start_time = 0
    }.

%%====================================================================
%% ECN Support
%%====================================================================

%% @doc Handle ECN-CE signal.
-spec on_ecn_ce(cc_state(), non_neg_integer()) -> cc_state().
on_ecn_ce(#cubic_state{ecn_ce_counter = OldCount} = State, NewCECount) when
    NewCECount =< OldCount
->
    State;
on_ecn_ce(#cubic_state{in_recovery = true, ecn_ce_counter = OldCount} = State, NewCECount) when
    NewCECount > OldCount
->
    State#cubic_state{ecn_ce_counter = NewCECount};
on_ecn_ce(
    #cubic_state{
        cwnd = Cwnd,
        w_last_max = WLastMax,
        minimum_window = MinimumWindow
    } = State,
    NewCECount
) ->
    Now = erlang:monotonic_time(millisecond),

    %% Fast convergence for ECN (RFC 9438 Section 4.7)
    {NewWMax, NewWLastMax} =
        case Cwnd < WLastMax of
            true ->
                %% Fast convergence: W_max = cwnd * (1 + beta) / 2
                FastConvergenceWMax = trunc(Cwnd * ?FAST_CONVERGENCE_FACTOR),
                {FastConvergenceWMax, Cwnd};
            false ->
                %% Normal case
                {Cwnd, Cwnd}
        end,

    NewSSThresh = max(trunc(Cwnd * ?CUBIC_BETA), MinimumWindow),
    NewCwnd = max(NewSSThresh, MinimumWindow),

    State#cubic_state{
        cwnd = NewCwnd,
        ssthresh = NewSSThresh,
        w_max = NewWMax,
        w_last_max = NewWLastMax,
        recovery_start_time = Now,
        in_recovery = true,
        ecn_ce_counter = NewCECount,
        epoch_start = 0,
        origin_point = 0,
        k = 0.0,
        tcp_cwnd = 0,
        %% Reset HyStart++ state
        hystart_in_css = false,
        hystart_css_rounds = 0,
        hystart_rtt_sample_count = 0,
        hystart_css_baseline_rtt = infinity,
        hystart_round_start_time = 0
    }.

%% @doc Get the current ECN-CE counter.
-spec ecn_ce_counter(cc_state()) -> non_neg_integer().
ecn_ce_counter(#cubic_state{ecn_ce_counter = C}) -> C.

%%====================================================================
%% Persistent Congestion
%%====================================================================

%% @doc Detect persistent congestion from lost packets.
-spec detect_persistent_congestion(
    [{non_neg_integer(), non_neg_integer()}],
    non_neg_integer(),
    cc_state()
) -> boolean().
detect_persistent_congestion([], _PTO, _State) ->
    false;
detect_persistent_congestion([_], _PTO, _State) ->
    false;
detect_persistent_congestion(LostPackets, PTO, _State) ->
    Times = [T || {_PN, T} <- LostPackets],
    MinTime = lists:min(Times),
    MaxTime = lists:max(Times),
    CongestionPeriod = PTO * ?PERSISTENT_CONGESTION_THRESHOLD,
    (MaxTime - MinTime) >= CongestionPeriod.

%% @doc Reset to minimum window on persistent congestion.
-spec on_persistent_congestion(cc_state()) -> cc_state().
on_persistent_congestion(#cubic_state{cwnd = Cwnd, minimum_window = MinimumWindow} = State) ->
    NewSSThresh = max(trunc(Cwnd * ?CUBIC_BETA), MinimumWindow),
    State#cubic_state{
        cwnd = MinimumWindow,
        ssthresh = NewSSThresh,
        in_recovery = false,
        recovery_start_time = undefined,
        first_sent_time = undefined,
        %% Reset CUBIC state
        w_max = 0,
        w_last_max = 0,
        epoch_start = 0,
        origin_point = 0,
        k = 0.0,
        tcp_cwnd = 0,
        %% Reset HyStart++
        hystart_in_css = false,
        hystart_css_rounds = 0,
        hystart_rtt_sample_count = 0,
        hystart_last_rtt = 0,
        hystart_curr_rtt = infinity,
        hystart_css_baseline_rtt = infinity,
        hystart_round_start_time = 0
    }.

%%====================================================================
%% Pacing
%%====================================================================

%% @doc Update pacing rate based on smoothed RTT.
-spec update_pacing_rate(cc_state(), non_neg_integer()) -> cc_state().
update_pacing_rate(#cubic_state{cwnd = Cwnd} = State, SmoothedRTT) when SmoothedRTT > 0 ->
    %% pacing_rate stored as milli-bytes per microsecond for precision with us timestamps
    %% Formula: (cwnd * 1.25 * 1000) / (RTT_ms * 1000) = (cwnd * 1250) / (RTT_ms * 1000)
    PacingRate = max(1, (Cwnd * 1250) div (SmoothedRTT * 1000)),

    %% Update HyStart++ RTT tracking
    State1 = update_hystart_rtt(State, SmoothedRTT),

    State1#cubic_state{
        pacing_rate = PacingRate,
        smoothed_rtt = SmoothedRTT
    };
update_pacing_rate(State, _SmoothedRTT) ->
    State.

%% @private Update HyStart++ RTT samples
update_hystart_rtt(
    #cubic_state{
        hystart_enabled = true,
        hystart_curr_rtt = CurrRTT,
        cwnd = Cwnd,
        ssthresh = SSThresh
    } = State,
    RTT
) when Cwnd < SSThresh ->
    %% In slow start, track RTT samples
    NewCurrRTT =
        case CurrRTT of
            infinity -> RTT;
            _ -> min(CurrRTT, RTT)
        end,
    State#cubic_state{hystart_curr_rtt = NewCurrRTT};
update_hystart_rtt(State, _RTT) ->
    State.

%% @doc Check if pacing allows sending.
-spec pacing_allows(cc_state(), non_neg_integer()) -> boolean().
pacing_allows(#cubic_state{pacing_rate = 0}, _Size) ->
    true;
pacing_allows(
    #cubic_state{
        pacing_tokens = Tokens,
        pacing_max_burst = MaxBurst,
        pacing_rate = Rate,
        last_pacing_update = LastUpdate
    },
    Size
) ->
    Now = erlang:monotonic_time(microsecond),
    RefreshedTokens = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
    RefreshedTokens >= Size.

%% @doc Get tokens for sending.
-spec get_pacing_tokens(cc_state(), non_neg_integer()) -> {non_neg_integer(), cc_state()}.
get_pacing_tokens(#cubic_state{pacing_rate = 0} = State, Size) ->
    {Size, State};
get_pacing_tokens(
    #cubic_state{
        pacing_tokens = Tokens,
        pacing_max_burst = MaxBurst,
        pacing_rate = Rate,
        last_pacing_update = LastUpdate
    } = State,
    Size
) ->
    Now = erlang:monotonic_time(microsecond),
    NewTokens = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
    Allowed = min(Size, NewTokens),
    RemainingTokens = max(0, NewTokens - Allowed),
    NewState = State#cubic_state{
        pacing_tokens = RemainingTokens,
        last_pacing_update = Now
    },
    {Allowed, NewState}.

%% @doc Calculate pacing delay.
-spec pacing_delay(cc_state(), non_neg_integer()) -> non_neg_integer().
pacing_delay(#cubic_state{pacing_rate = 0}, _Size) ->
    0;
pacing_delay(
    #cubic_state{
        pacing_tokens = Tokens,
        pacing_max_burst = MaxBurst,
        pacing_rate = Rate,
        last_pacing_update = LastUpdate
    },
    Size
) ->
    Now = erlang:monotonic_time(microsecond),
    CurrentTokens = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
    case CurrentTokens >= Size of
        true ->
            0;
        false ->
            Deficit = Size - CurrentTokens,
            max(1, (Deficit + Rate - 1) div Rate)
    end.

%% @doc Fused cwnd + pacing check for the hot send path.
-spec send_check(cc_state(), non_neg_integer(), non_neg_integer()) ->
    {ok, cc_state()}
    | {blocked_cwnd, non_neg_integer()}
    | {blocked_pacing, non_neg_integer()}.
send_check(
    #cubic_state{
        cwnd = Cwnd,
        bytes_in_flight = InFlight,
        control_allowance = Allowance,
        pacing_rate = Rate
    } = State,
    Size,
    Urgency
) ->
    CwndLimit =
        case Urgency of
            0 -> Cwnd + Allowance;
            _ -> Cwnd
        end,
    case InFlight + Size =< CwndLimit of
        false ->
            {blocked_cwnd, max(0, Cwnd - InFlight)};
        true when Rate =:= 0 ->
            {ok, State};
        true ->
            #cubic_state{
                pacing_tokens = Tokens,
                pacing_max_burst = MaxBurst,
                last_pacing_update = LastUpdate
            } = State,
            Now = erlang:monotonic_time(microsecond),
            Refreshed = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
            case Refreshed >= Size of
                true ->
                    {ok, State#cubic_state{
                        pacing_tokens = Refreshed - Size,
                        last_pacing_update = Now
                    }};
                false ->
                    Deficit = Size - Refreshed,
                    DelayMs = max(1, (Deficit + Rate - 1) div Rate),
                    {blocked_pacing, DelayMs}
            end
    end.

%%====================================================================
%% MTU Support
%%====================================================================

%% @doc Update congestion control state when MTU changes.
-spec update_mtu(cc_state(), pos_integer()) -> cc_state().
update_mtu(#cubic_state{max_datagram_size = OldMDS} = State, NewMTU) when NewMTU =:= OldMDS ->
    State;
update_mtu(#cubic_state{max_datagram_size = OldMDS, minimum_window = OldMinWin} = State, NewMTU) ->
    NewMinimumWindow = max(2 * NewMTU, (OldMinWin * NewMTU) div OldMDS),
    NewPacingMaxBurst = 12 * NewMTU,

    ?LOG_DEBUG(
        #{
            what => cubic_mtu_updated,
            old_mtu => OldMDS,
            new_mtu => NewMTU,
            new_minimum_window => NewMinimumWindow
        },
        ?QUIC_LOG_META
    ),

    State#cubic_state{
        max_datagram_size = NewMTU,
        minimum_window = NewMinimumWindow,
        pacing_max_burst = NewPacingMaxBurst
    }.

%%====================================================================
%% Queries
%%====================================================================

%% @doc Get the current congestion window.
-spec cwnd(cc_state()) -> non_neg_integer().
cwnd(#cubic_state{cwnd = Cwnd}) -> Cwnd.

%% @doc Drop bytes for a discarded packet number space. Not a
%% congestion event: no window or recovery change.
-spec on_packets_discarded(cc_state(), non_neg_integer()) -> cc_state().
on_packets_discarded(#cubic_state{bytes_in_flight = B} = State, Bytes) ->
    State#cubic_state{bytes_in_flight = max(0, B - Bytes)}.

%% @doc Start over after a Retry, keeping every configured value.
-spec reset_for_retry(cc_state()) -> cc_state().
reset_for_retry(#cubic_state{initial_window = IW} = State) ->
    State#cubic_state{
        cwnd = IW,
        bytes_in_flight = 0,
        ssthresh = infinity,
        in_recovery = false,
        recovery_start_time = undefined,
        first_sent_time = undefined,
        ecn_ce_counter = 0,
        w_max = 0,
        w_last_max = 0,
        k = 0.0,
        epoch_start = 0,
        origin_point = 0,
        tcp_cwnd = 0,
        cwnd_prior = 0,
        pacing_tokens = State#cubic_state.pacing_max_burst,
        pacing_rate = 0
    }.

%% @doc The window this controller was configured with.
-spec initial_window(cc_state()) -> non_neg_integer().
initial_window(#cubic_state{initial_window = IW}) -> IW.

%% @doc Get the slow start threshold.
-spec ssthresh(cc_state()) -> non_neg_integer() | infinity.
ssthresh(#cubic_state{ssthresh = SST}) -> SST.

%% @doc Get bytes currently in flight.
-spec bytes_in_flight(cc_state()) -> non_neg_integer().
bytes_in_flight(#cubic_state{bytes_in_flight = B}) -> B.

%% @doc Check if we can send more bytes.
-spec can_send(cc_state(), non_neg_integer()) -> boolean().
can_send(#cubic_state{cwnd = Cwnd, bytes_in_flight = InFlight}, Size) ->
    InFlight + Size =< Cwnd.

%% @doc Check if a control message can be sent.
-spec can_send_control(cc_state(), non_neg_integer()) -> boolean().
can_send_control(
    #cubic_state{cwnd = Cwnd, bytes_in_flight = InFlight, control_allowance = Allowance}, Size
) ->
    InFlight + Size =< Cwnd + Allowance.

%% @doc Get the available congestion window.
-spec available_cwnd(cc_state()) -> non_neg_integer().
available_cwnd(#cubic_state{cwnd = Cwnd, bytes_in_flight = InFlight}) ->
    max(0, Cwnd - InFlight).

%% @doc Check if in slow start phase.
-spec in_slow_start(cc_state()) -> boolean().
in_slow_start(#cubic_state{cwnd = Cwnd, ssthresh = SSThresh}) ->
    Cwnd < SSThresh.

%% @doc Check if in recovery phase.
-spec in_recovery(cc_state()) -> boolean().
in_recovery(#cubic_state{in_recovery = R}) -> R.

%% @doc Get minimum recovery duration.
-spec min_recovery_duration(cc_state()) -> non_neg_integer().
min_recovery_duration(#cubic_state{min_recovery_duration = D}) -> D.

%% @doc Get the current max datagram size.
-spec max_datagram_size(cc_state()) -> pos_integer().
max_datagram_size(#cubic_state{max_datagram_size = MDS}) -> MDS.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Refill pacing tokens based on elapsed time (microsecond timestamps, rate in milli-bytes/us)
refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now) ->
    ElapsedUs = max(0, Now - LastUpdate),
    %% Rate is in milli-bytes per microsecond, so Added = (elapsed_us * rate) / 1000
    Added = (ElapsedUs * Rate) div 1000,
    min(MaxBurst, Tokens + Added).

%% Calculate initial window (32 packets like quic-go)
default_initial_window(MaxDatagramSize) ->
    32 * MaxDatagramSize.

%% Calculate minimum window (2 * max_datagram_size per RFC 9002)
minimum_window(MaxDatagramSize) ->
    2 * MaxDatagramSize.
