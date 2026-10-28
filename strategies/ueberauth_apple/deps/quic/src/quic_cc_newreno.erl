%%% -*- erlang -*-
%%%
%%% QUIC NewReno Congestion Control
%%% RFC 9002 Section 7 - Congestion Control
%%% RFC 9406 - HyStart++: Modified Slow Start for TCP
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC NewReno congestion control implementation.
%%%
%%% This module implements the NewReno congestion control algorithm:
%%% - Slow Start: Exponential growth until threshold or loss
%%% - HyStart++ (RFC 9406): Safer slow start exit via RTT monitoring
%%% - Congestion Avoidance: Linear growth after threshold
%%% - Recovery: Multiplicative decrease on loss
%%% - Persistent Congestion: Reset on prolonged loss
%%%
%%% == Phases ==
%%%
%%% 1. Slow Start with HyStart++: cwnd += bytes_acked with RTT-based exit
%%% 2. Conservative Slow Start (CSS): cwnd += cwnd/4 per RTT for 5 rounds
%%% 3. Congestion Avoidance: cwnd += max_datagram_size * bytes_acked / cwnd
%%% 4. Recovery: ssthresh = cwnd * 0.5, cwnd = max(ssthresh, min_window)
%%%

-module(quic_cc_newreno).

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
    send_check_run/4,
    on_packets_sent/2,
    max_datagram_size/1,
    min_recovery_duration/1,
    ecn_ce_counter/1
]).

%% Constants from RFC 9002

% Minimum QUIC packet size
-define(MAX_DATAGRAM_SIZE, 1200).
% Initial cwnd: 32 packets like quic-go for better initial throughput
% RFC 9002 suggests min(10*mds, max(14720, 2*mds)) but larger is common
-define(INITIAL_WINDOW, 38400).
% Loss reduction factor: 0.7 like quic-go for less aggressive backoff
% Standard NewReno uses 0.5, but 0.7 gives better throughput recovery
-define(LOSS_REDUCTION_FACTOR, 0.7).
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

%% Congestion control state
-record(cc_state, {
    %% Congestion window
    cwnd :: non_neg_integer(),
    ssthresh :: non_neg_integer() | infinity,

    %% Bytes tracking
    bytes_in_flight = 0 :: non_neg_integer(),

    %% Recovery state
    recovery_start_time :: non_neg_integer() | undefined,
    in_recovery = false :: boolean(),

    %% Persistent congestion detection
    first_sent_time :: non_neg_integer() | undefined,

    %% ECN state (RFC 9002 Section 7.1)
    %% Tracks the highest ECN-CE count acknowledged
    ecn_ce_counter = 0 :: non_neg_integer(),

    %% Configuration
    %% The window this controller started with. cwnd evolves away from it,
    %% so without keeping it a reset cannot restore the configured value.
    initial_window :: non_neg_integer(),
    minimum_window :: non_neg_integer(),
    max_datagram_size :: non_neg_integer(),

    %% Minimum time to stay in recovery (ms)
    %% Prevents rapid re-entry on low-latency networks
    min_recovery_duration = 100 :: non_neg_integer(),

    %% Control message allowance (bytes) - allows critical small messages
    %% to exceed cwnd by this amount to prevent blocking ticks
    control_allowance = 1200 :: non_neg_integer(),

    %% Pacing state (RFC 9002 Section 7.7)
    %% Pacing prevents bursts by spacing out packet sends

    % bytes/ms
    pacing_rate = 0 :: non_neg_integer(),
    % available tokens (bytes)
    pacing_tokens = 0 :: non_neg_integer(),
    % 12 packets burst allowance
    pacing_max_burst = 14400 :: non_neg_integer(),
    % timestamp (ms)
    last_pacing_update = 0 :: non_neg_integer(),

    %% HyStart++ state (RFC 9406)
    %% Whether HyStart++ is enabled
    hystart_enabled = true :: boolean(),
    %% In Conservative Slow Start phase
    hystart_in_css = false :: boolean(),
    %% Number of CSS rounds completed
    hystart_css_rounds = 0 :: non_neg_integer(),
    %% RTT sample count in current round
    hystart_rtt_sample_count = 0 :: non_neg_integer(),
    %% Last round's minimum RTT (milliseconds)
    hystart_last_rtt = 0 :: non_neg_integer(),
    %% Current round's minimum RTT (milliseconds)
    hystart_curr_rtt = infinity :: non_neg_integer() | infinity,
    %% CSS baseline RTT for potential reversion to slow start (RFC 9406)
    hystart_css_baseline_rtt = infinity :: non_neg_integer() | infinity,
    %% Round start time for time-based round detection (RFC 9406)
    hystart_round_start_time = 0 :: non_neg_integer()
}).

-opaque cc_state() :: #cc_state{}.
-export_type([cc_state/0]).

%%====================================================================
%% Behavior Callbacks
%%====================================================================

%% @doc Create a new congestion control state with options.
%% Options:
%%   - max_datagram_size: Maximum datagram size (default: 1200)
%%   - initial_window: Override initial congestion window (default: RFC 9002 formula)
%%                     Higher values can improve throughput for bulk transfers.
%%                     Recommended: 32768 (32KB) or 65536 (64KB) for LAN/distribution.
%%   - minimum_window: Lower bound for cwnd after congestion events
%%                     (default: 2 * max_datagram_size per RFC 9002).
%%   - min_recovery_duration: Minimum time in recovery before exit (ms, default: 100)
%%                            Prevents rapid cwnd oscillations on low-latency networks.
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
    %% Pacing: 10 packets burst allowance (12 with 1200 byte packets = 14400)
    PacingMaxBurst = 12 * MaxDatagramSize,
    Now = erlang:monotonic_time(microsecond),
    ?LOG_DEBUG(
        #{
            what => cc_state_initialized,
            algorithm => newreno,
            initial_cwnd => InitialWindow,
            default_cwnd => DefaultWindow,
            minimum_window => ConfiguredMinimumWindow,
            default_minimum_window => DefaultMinimumWindow,
            max_datagram_size => MaxDatagramSize,
            min_recovery_duration => MinRecoveryDuration,
            pacing_max_burst => PacingMaxBurst,
            hystart_enabled => HystartEnabled
        },
        ?QUIC_LOG_META
    ),
    #cc_state{
        cwnd = InitialWindow,
        initial_window = InitialWindow,
        ssthresh = infinity,
        minimum_window = ConfiguredMinimumWindow,
        max_datagram_size = MaxDatagramSize,
        min_recovery_duration = MinRecoveryDuration,
        %% Initialize pacing with full burst allowance
        pacing_max_burst = PacingMaxBurst,
        pacing_tokens = PacingMaxBurst,
        last_pacing_update = Now,
        %% HyStart++ initialization
        hystart_enabled = HystartEnabled
    }.

%%====================================================================
%% Congestion Control Events
%%====================================================================

%% @doc Record that a packet was sent.
-spec on_packet_sent(cc_state(), non_neg_integer()) -> cc_state().
on_packet_sent(
    #cc_state{
        bytes_in_flight = InFlight,
        first_sent_time = undefined
    } = State,
    Size
) ->
    Now = erlang:monotonic_time(millisecond),
    State#cc_state{
        bytes_in_flight = InFlight + Size,
        first_sent_time = Now
    };
on_packet_sent(#cc_state{bytes_in_flight = InFlight} = State, Size) ->
    State#cc_state{bytes_in_flight = InFlight + Size}.

%% @doc Batched on_packet_sent for a run of packets: one state update
%% for the whole list of sizes.
-spec on_packets_sent(cc_state(), [non_neg_integer()]) -> cc_state().
on_packets_sent(State, []) ->
    State;
on_packets_sent(#cc_state{bytes_in_flight = InFlight} = State, Sizes) ->
    Total = lists:sum(Sizes),
    case State#cc_state.first_sent_time of
        undefined ->
            Now = erlang:monotonic_time(millisecond),
            State#cc_state{bytes_in_flight = InFlight + Total, first_sent_time = Now};
        _ ->
            State#cc_state{bytes_in_flight = InFlight + Total}
    end.

%% @doc Process acknowledged packets.
%% AckedBytes is the total size of acknowledged packets.
%% LargestAckedSentTime is the time when the largest acknowledged packet was sent.
%% RFC 9002: Exit recovery when the largest acked packet was sent after recovery started.
-spec on_packets_acked(cc_state(), non_neg_integer()) -> cc_state().
on_packets_acked(State, AckedBytes) ->
    %% Use current time as a proxy - ideally caller would pass largest_acked_sent_time
    Now = erlang:monotonic_time(millisecond),
    on_packets_acked(State, AckedBytes, Now).

%% @doc Process acknowledged packets.
%% RFC 9002: Exit recovery when the largest acked packet was sent after recovery started.
%% Extended: Also requires minimum recovery duration to pass before exiting.
-spec on_packets_acked(cc_state(), non_neg_integer(), non_neg_integer()) -> cc_state().
on_packets_acked(
    #cc_state{
        bytes_in_flight = InFlight,
        cwnd = OldCwnd,
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

    %% RFC 9002 Section 7.3.2: A recovery period ends and the sender
    %% enters congestion avoidance when a packet sent during the recovery period
    %% is acknowledged. Check if the largest acked packet was sent AFTER recovery started.
    %% Extended: Also requires minimum recovery duration to pass before exiting.
    %% This prevents rapid cwnd oscillations on low-latency networks.
    case
        RecoveryDuration >= MinDuration andalso
            (LargestAckedSentTime > RecoveryStart orelse NewInFlight =:= 0)
    of
        true ->
            %% Exit recovery - packet sent after recovery started was acked
            %% and minimum recovery duration has passed
            %% Now in congestion avoidance, can increase cwnd
            #cc_state{cwnd = Cwnd, ssthresh = SSThresh, max_datagram_size = MaxDS} = State,
            State1 = State#cc_state{
                bytes_in_flight = NewInFlight,
                in_recovery = false,
                recovery_start_time = Now
            },
            State2 =
                case Cwnd < SSThresh of
                    true ->
                        %% Slow start with HyStart++ (RFC 9406)
                        hystart_on_ack(State1, AckedBytes, LargestAckedSentTime);
                    false ->
                        %% Congestion avoidance
                        Increment = (MaxDS * AckedBytes) div max(Cwnd, 1),
                        NewCwnd = Cwnd + max(Increment, 1),
                        State1#cc_state{cwnd = NewCwnd}
                end,
            NewCwnd2 = State2#cc_state.cwnd,
            ?LOG_DEBUG(
                #{
                    what => cc_ack_exit_recovery,
                    acked_bytes => AckedBytes,
                    old_cwnd => OldCwnd,
                    new_cwnd => NewCwnd2,
                    old_in_flight => InFlight,
                    new_in_flight => NewInFlight,
                    ssthresh => SSThresh,
                    recovery_duration => RecoveryDuration
                },
                ?QUIC_LOG_META
            ),
            State2;
        false ->
            %% Still in recovery, don't increase cwnd
            ?LOG_DEBUG(
                #{
                    what => cc_ack_in_recovery,
                    acked_bytes => AckedBytes,
                    cwnd => OldCwnd,
                    old_in_flight => InFlight,
                    new_in_flight => NewInFlight,
                    recovery_duration => RecoveryDuration,
                    min_duration => MinDuration
                },
                ?QUIC_LOG_META
            ),
            State#cc_state{bytes_in_flight = NewInFlight}
    end;
on_packets_acked(
    #cc_state{
        cwnd = Cwnd,
        ssthresh = SSThresh,
        bytes_in_flight = InFlight,
        max_datagram_size = MaxDS
    } = State,
    AckedBytes,
    LargestAckedSentTime
) ->
    NewInFlight = max(0, InFlight - AckedBytes),
    State1 = State#cc_state{bytes_in_flight = NewInFlight},

    %% Increase cwnd based on phase
    InSlowStart = Cwnd < SSThresh,
    State2 =
        case InSlowStart of
            true ->
                %% Slow start with HyStart++ (RFC 9406)
                hystart_on_ack(State1, AckedBytes, LargestAckedSentTime);
            false ->
                %% Congestion avoidance: increase by ~1 MSS per RTT
                %% cwnd += max_datagram_size * acked_bytes / cwnd
                Increment = (MaxDS * AckedBytes) div max(Cwnd, 1),
                NewCwnd = Cwnd + max(Increment, 1),
                State1#cc_state{cwnd = NewCwnd}
        end,

    NewCwnd2 = State2#cc_state.cwnd,
    ?LOG_DEBUG(
        #{
            what => cc_ack_processed,
            acked_bytes => AckedBytes,
            old_cwnd => Cwnd,
            new_cwnd => NewCwnd2,
            old_in_flight => InFlight,
            new_in_flight => NewInFlight,
            ssthresh => SSThresh,
            slow_start => InSlowStart
        },
        ?QUIC_LOG_META
    ),

    State2.

%% @doc Process lost packets.
%% LostBytes is the total size of lost packets.
-spec on_packets_lost(cc_state(), non_neg_integer()) -> cc_state().
on_packets_lost(#cc_state{bytes_in_flight = InFlight} = State, LostBytes) ->
    NewInFlight = max(0, InFlight - LostBytes),
    State#cc_state{bytes_in_flight = NewInFlight}.

%%====================================================================
%% HyStart++ Implementation (RFC 9406)
%%====================================================================

%% @private HyStart++ slow start processing (RFC 9406)
%% Clause 1: HyStart++ disabled - standard slow start
hystart_on_ack(
    #cc_state{
        cwnd = Cwnd,
        hystart_enabled = false
    } = State,
    AckedBytes,
    _LargestAckedSentTime
) ->
    NewCwnd = Cwnd + AckedBytes,
    State#cc_state{cwnd = NewCwnd};
%% Clause 2: In Conservative Slow Start - grow by cwnd/CSS_GROWTH_DIV per RTT
%% RFC 9406: Can revert to slow start if RTT drops below baseline
hystart_on_ack(
    #cc_state{
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
            State#cc_state{
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
                    State#cc_state{
                        cwnd = NewCwnd,
                        ssthresh = NewCwnd,
                        hystart_in_css = false,
                        hystart_css_rounds = 0,
                        hystart_css_baseline_rtt = infinity,
                        hystart_round_start_time = 0
                    };
                false ->
                    State#cc_state{
                        cwnd = NewCwnd,
                        hystart_css_rounds = NewRounds,
                        hystart_rtt_sample_count = NewSampleCount,
                        hystart_round_start_time = NewRoundStartTime
                    }
            end
    end;
%% Clause 3: Normal slow start with HyStart++ RTT monitoring
hystart_on_ack(
    #cc_state{
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

    %% Update state with new cwnd and sample count
    State1 = State#cc_state{
        cwnd = NewCwnd,
        hystart_rtt_sample_count = NewSampleCount
    },

    %% Check for RTT-based exit condition after minimum samples
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
                    State1#cc_state{
                        hystart_in_css = true,
                        hystart_css_rounds = 0,
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

%% @private Update HyStart++ RTT samples
%% Called from update_pacing_rate when in slow start
update_hystart_rtt(
    #cc_state{
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
    State#cc_state{hystart_curr_rtt = NewCurrRTT};
update_hystart_rtt(State, _RTT) ->
    State.

%% @doc Handle a congestion event (packet loss detected).
%% SentTime is the time when the lost packet was sent.
-spec on_congestion_event(cc_state(), non_neg_integer()) -> cc_state().
on_congestion_event(
    #cc_state{
        in_recovery = true,
        recovery_start_time = RecoveryStart
    } = State,
    SentTime
) when SentTime =< RecoveryStart ->
    %% Already in recovery for this event - skip
    ?LOG_DEBUG(
        #{
            what => cc_congestion_skipped_in_recovery,
            sent_time => SentTime,
            recovery_start_time => RecoveryStart
        },
        ?QUIC_LOG_META
    ),
    State;
on_congestion_event(
    #cc_state{
        in_recovery = true,
        recovery_start_time = RecoveryStart,
        min_recovery_duration = MinDuration
    } = State,
    SentTime
) ->
    %% Already in recovery - check if min_recovery_duration has passed
    Now = erlang:monotonic_time(millisecond),
    RecoveryDuration = Now - RecoveryStart,
    case RecoveryDuration < MinDuration of
        true ->
            %% Still within protected recovery period - don't reset recovery
            ?LOG_DEBUG(
                #{
                    what => cc_congestion_skipped_protected_recovery,
                    sent_time => SentTime,
                    recovery_start_time => RecoveryStart,
                    recovery_duration => RecoveryDuration,
                    min_duration => MinDuration
                },
                ?QUIC_LOG_META
            ),
            State;
        false ->
            %% min_recovery_duration passed but packet sent after recovery started was lost
            %% Allow this to reset recovery (fall through to general clause)
            do_congestion_event(State, SentTime)
    end;
on_congestion_event(
    #cc_state{
        in_recovery = false,
        recovery_start_time = RecoveryStart
    } = State,
    SentTime
) when is_integer(RecoveryStart), SentTime =< RecoveryStart ->
    %% Packet was sent before the last recovery period ended.
    %% Don't re-enter recovery for old packets.
    ?LOG_DEBUG(
        #{
            what => cc_congestion_skipped_post_recovery,
            sent_time => SentTime,
            recovery_start_time => RecoveryStart
        },
        ?QUIC_LOG_META
    ),
    State;
on_congestion_event(State, SentTime) ->
    do_congestion_event(State, SentTime).

%% @private Helper to execute the congestion event logic.
do_congestion_event(
    #cc_state{
        cwnd = Cwnd,
        bytes_in_flight = InFlight,
        minimum_window = MinimumWindow,
        in_recovery = InRecovery,
        recovery_start_time = OldRecoveryStart
    } = State,
    SentTime
) ->
    Now = erlang:monotonic_time(millisecond),

    %% Enter recovery
    %% ssthresh = cwnd * kLossReductionFactor
    %% cwnd = max(ssthresh, kMinimumWindow)
    NewSSThresh = max(trunc(Cwnd * ?LOSS_REDUCTION_FACTOR), MinimumWindow),
    NewCwnd = max(NewSSThresh, MinimumWindow),

    ?LOG_DEBUG(
        #{
            what => cc_congestion_event,
            old_cwnd => Cwnd,
            new_cwnd => NewCwnd,
            ssthresh => NewSSThresh,
            bytes_in_flight => InFlight,
            sent_time => SentTime,
            old_in_recovery => InRecovery,
            old_recovery_start => OldRecoveryStart,
            new_recovery_start => Now
        },
        ?QUIC_LOG_META
    ),

    State#cc_state{
        cwnd = NewCwnd,
        ssthresh = NewSSThresh,
        recovery_start_time = Now,
        in_recovery = true,
        % Track for persistent congestion
        first_sent_time = SentTime,
        %% Reset HyStart++ state
        hystart_in_css = false,
        hystart_css_rounds = 0,
        hystart_rtt_sample_count = 0,
        hystart_css_baseline_rtt = infinity,
        hystart_round_start_time = 0
    }.

%%====================================================================
%% ECN Support (RFC 9002 Section 7.1)
%%====================================================================

%% @doc Handle ECN-CE (Congestion Experienced) signal from ACK.
%% RFC 9002: An increase in ECN-CE count is treated as a congestion signal.
%% NewCECount is the ECN-CE count from the received ACK frame.
%% SentTime is the time when the largest acknowledged packet was sent.
-spec on_ecn_ce(cc_state(), non_neg_integer()) -> cc_state().
on_ecn_ce(#cc_state{ecn_ce_counter = OldCount} = State, NewCECount) when
    NewCECount =< OldCount
->
    %% No new CE marks, no action needed
    State;
on_ecn_ce(#cc_state{in_recovery = true, ecn_ce_counter = OldCount} = State, NewCECount) when
    NewCECount > OldCount
->
    %% Already in recovery, just update counter
    State#cc_state{ecn_ce_counter = NewCECount};
on_ecn_ce(#cc_state{cwnd = Cwnd, minimum_window = MinimumWindow} = State, NewCECount) ->
    %% RFC 9002: ECN-CE triggers the same response as packet loss
    %% Enter recovery: ssthresh = cwnd * kLossReductionFactor
    Now = erlang:monotonic_time(millisecond),
    NewSSThresh = max(trunc(Cwnd * ?LOSS_REDUCTION_FACTOR), MinimumWindow),
    NewCwnd = max(NewSSThresh, MinimumWindow),

    State#cc_state{
        cwnd = NewCwnd,
        ssthresh = NewSSThresh,
        recovery_start_time = Now,
        in_recovery = true,
        ecn_ce_counter = NewCECount,
        %% Reset HyStart++ state
        hystart_in_css = false,
        hystart_css_rounds = 0,
        hystart_rtt_sample_count = 0,
        hystart_css_baseline_rtt = infinity,
        hystart_round_start_time = 0
    }.

%% @doc Get the current ECN-CE counter.
-spec ecn_ce_counter(cc_state()) -> non_neg_integer().
ecn_ce_counter(#cc_state{ecn_ce_counter = C}) -> C.

%%====================================================================
%% Queries
%%====================================================================

%% @doc Get the current congestion window.
-spec cwnd(cc_state()) -> non_neg_integer().
cwnd(#cc_state{cwnd = Cwnd}) -> Cwnd.

%% @doc Drop bytes for a discarded packet number space. Not a
%% congestion event: no window or recovery change.
-spec on_packets_discarded(cc_state(), non_neg_integer()) -> cc_state().
on_packets_discarded(#cc_state{bytes_in_flight = B} = State, Bytes) ->
    State#cc_state{bytes_in_flight = max(0, B - Bytes)}.

%% @doc Start over after a Retry, keeping every configured value.
-spec reset_for_retry(cc_state()) -> cc_state().
reset_for_retry(#cc_state{initial_window = IW} = State) ->
    State#cc_state{
        cwnd = IW,
        bytes_in_flight = 0,
        ssthresh = infinity,
        in_recovery = false,
        recovery_start_time = undefined,
        first_sent_time = undefined,
        ecn_ce_counter = 0,
        pacing_tokens = State#cc_state.pacing_max_burst,
        pacing_rate = 0
    }.

%% @doc The window this controller was configured with.
-spec initial_window(cc_state()) -> non_neg_integer().
initial_window(#cc_state{initial_window = IW}) -> IW.

%% @doc Get the slow start threshold.
-spec ssthresh(cc_state()) -> non_neg_integer() | infinity.
ssthresh(#cc_state{ssthresh = SST}) -> SST.

%% @doc Get bytes currently in flight.
-spec bytes_in_flight(cc_state()) -> non_neg_integer().
bytes_in_flight(#cc_state{bytes_in_flight = B}) -> B.

%% @doc Check if we can send more bytes.
-spec can_send(cc_state(), non_neg_integer()) -> boolean().
can_send(#cc_state{cwnd = Cwnd, bytes_in_flight = InFlight}, Size) ->
    InFlight + Size =< Cwnd.

%% @doc Check if a control message can be sent.
%% Control messages (ticks, ACKs) can exceed cwnd by control_allowance
%% to prevent net_tick_timeout in distribution.
%% RFC 9002 recommends allowing at least one packet for progress.
-spec can_send_control(cc_state(), non_neg_integer()) -> boolean().
can_send_control(
    #cc_state{cwnd = Cwnd, bytes_in_flight = InFlight, control_allowance = Allowance}, Size
) ->
    InFlight + Size =< Cwnd + Allowance.

%% @doc Get the available congestion window (cwnd - bytes_in_flight).
-spec available_cwnd(cc_state()) -> non_neg_integer().
available_cwnd(#cc_state{cwnd = Cwnd, bytes_in_flight = InFlight}) ->
    max(0, Cwnd - InFlight).

%% @doc Check if in slow start phase.
-spec in_slow_start(cc_state()) -> boolean().
in_slow_start(#cc_state{cwnd = Cwnd, ssthresh = SSThresh}) ->
    Cwnd < SSThresh.

%% @doc Check if in recovery phase.
-spec in_recovery(cc_state()) -> boolean().
in_recovery(#cc_state{in_recovery = R}) -> R.

%% @doc Get minimum recovery duration setting.
%% External CC implementations can use this to tune recovery behavior.
-spec min_recovery_duration(cc_state()) -> non_neg_integer().
min_recovery_duration(#cc_state{min_recovery_duration = D}) -> D.

%% @doc Get the current max datagram size.
-spec max_datagram_size(cc_state()) -> pos_integer().
max_datagram_size(#cc_state{max_datagram_size = MDS}) -> MDS.

%%====================================================================
%% PMTU Discovery Support
%%====================================================================

%% @doc Update congestion control state when MTU changes.
%%
%% Called by PMTU discovery when a new MTU is discovered.
%% Updates max_datagram_size, minimum_window, and pacing_max_burst.
%%
%% RFC 9002: When max_datagram_size changes, dependent parameters
%% should be updated proportionally.
-spec update_mtu(cc_state(), pos_integer()) -> cc_state().
update_mtu(#cc_state{max_datagram_size = OldMDS} = State, NewMTU) when NewMTU =:= OldMDS ->
    %% No change
    State;
update_mtu(#cc_state{max_datagram_size = OldMDS, minimum_window = OldMinWin} = State, NewMTU) ->
    %% Scale minimum_window proportionally
    %% minimum_window = 2 * max_datagram_size (RFC 9002)
    NewMinimumWindow = max(2 * NewMTU, (OldMinWin * NewMTU) div OldMDS),

    %% Update pacing_max_burst (12 * max_datagram_size)
    NewPacingMaxBurst = max(12 * NewMTU, 2 * State#cc_state.pacing_rate),

    ?LOG_DEBUG(
        #{
            what => cc_mtu_updated,
            old_mtu => OldMDS,
            new_mtu => NewMTU,
            old_minimum_window => OldMinWin,
            new_minimum_window => NewMinimumWindow,
            new_pacing_max_burst => NewPacingMaxBurst
        },
        ?QUIC_LOG_META
    ),

    State#cc_state{
        max_datagram_size = NewMTU,
        minimum_window = NewMinimumWindow,
        pacing_max_burst = NewPacingMaxBurst
    }.

%%====================================================================
%% Persistent Congestion (RFC 9002 Section 7.6)
%%====================================================================

%% @doc Detect persistent congestion from lost packets.
%% Returns true if lost packets span more than PTO * kPersistentCongestionThreshold.
%% LostPackets is a list of {PacketNumber, TimeSent} tuples.
-spec detect_persistent_congestion(
    [{non_neg_integer(), non_neg_integer()}],
    non_neg_integer(),
    cc_state()
) -> boolean().
detect_persistent_congestion([], _PTO, _State) ->
    false;
detect_persistent_congestion([_], _PTO, _State) ->
    %% Need at least 2 packets to establish a time span
    false;
detect_persistent_congestion(LostPackets, PTO, _State) ->
    Times = [T || {_PN, T} <- LostPackets],
    MinTime = lists:min(Times),
    MaxTime = lists:max(Times),
    CongestionPeriod = PTO * ?PERSISTENT_CONGESTION_THRESHOLD,
    (MaxTime - MinTime) >= CongestionPeriod.

%% @doc Reset to minimum window on persistent congestion (RFC 9002 SS7.6.2).
%% This is a severe response to prolonged packet loss.
-spec on_persistent_congestion(cc_state()) -> cc_state().
on_persistent_congestion(#cc_state{cwnd = Cwnd, minimum_window = MinimumWindow} = State) ->
    NewSSThresh = max(trunc(Cwnd * ?LOSS_REDUCTION_FACTOR), MinimumWindow),
    State#cc_state{
        cwnd = MinimumWindow,
        ssthresh = NewSSThresh,
        in_recovery = false,
        recovery_start_time = undefined,
        first_sent_time = undefined,
        %% Reset HyStart++ state
        hystart_in_css = false,
        hystart_css_rounds = 0,
        hystart_rtt_sample_count = 0,
        hystart_last_rtt = 0,
        hystart_curr_rtt = infinity,
        hystart_css_baseline_rtt = infinity,
        hystart_round_start_time = 0
    }.

%%====================================================================
%% Pacing (RFC 9002 Section 7.7)
%%====================================================================

%% @doc Update pacing rate based on smoothed RTT and cwnd.
%% RFC 9002: pacing_rate = cwnd / smoothed_rtt
%% Called when RTT estimate is updated.
-spec update_pacing_rate(cc_state(), non_neg_integer()) -> cc_state().
update_pacing_rate(#cc_state{cwnd = Cwnd} = State, SmoothedRTT0) ->
    %% RTT samples are whole milliseconds, so a sub-millisecond link
    %% reports 0. Skipping the update then freezes the rate at its
    %% handshake-time value while cwnd keeps growing, clocking the
    %% connection at that stale rate forever. Floor at 1 ms so the
    %% rate keeps tracking cwnd and the congestion controller governs.
    SmoothedRTT = max(1, SmoothedRTT0),
    %% pacing_rate stored as milli-bytes per microsecond for precision with us timestamps
    %% Formula: (cwnd * 1.25 * 1000) / (RTT_ms * 1000) = (cwnd * 1250) / (RTT_ms * 1000)
    %% Simplified: (cwnd * 5 * 250) / (RTT_ms * 1000) = (cwnd * 1250) / (RTT_ms * 1000)
    PacingRate = max(1, (Cwnd * 1250) div (SmoothedRTT * 1000)),

    ?LOG_DEBUG(
        #{
            what => pacing_rate_updated,
            cwnd => Cwnd,
            smoothed_rtt_ms => SmoothedRTT,
            new_pacing_rate => PacingRate
        },
        ?QUIC_LOG_META
    ),

    %% Update HyStart++ RTT tracking
    State1 = update_hystart_rtt(State, SmoothedRTT),

    %% The burst allowance must cover at least a couple of timer
    %% granularities' worth of tokens at the paced rate: pacing wakeups
    %% (send_after) have ~1 ms resolution, so a fixed 12-packet bucket
    %% caps throughput at 12 packets per wakeup whenever the sender
    %% outruns the incoming ACK clock, regardless of the configured
    %% rate. 2 ms of rate keeps micro-bursts bounded (same idea as
    %% Linux fq's pacing quantum) while letting a 1 ms clock sustain
    %% the rate.
    MaxBurst = max(12 * State1#cc_state.max_datagram_size, 2 * PacingRate),

    State1#cc_state{pacing_rate = PacingRate, pacing_max_burst = MaxBurst}.

%% @doc Check if pacing allows sending Size bytes.
%% Returns true if enough tokens are available (including burst allowance).
-spec pacing_allows(cc_state(), non_neg_integer()) -> boolean().
pacing_allows(#cc_state{pacing_rate = 0}, _Size) ->
    %% Pacing not initialized yet - allow sending
    true;
pacing_allows(
    #cc_state{
        pacing_tokens = Tokens,
        pacing_max_burst = MaxBurst,
        pacing_rate = Rate,
        last_pacing_update = LastUpdate
    },
    Size
) ->
    %% Refill tokens first, then check
    Now = erlang:monotonic_time(microsecond),
    RefreshedTokens = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
    RefreshedTokens >= Size.

%% @doc Get tokens for sending, consuming them and returning updated state.
%% Returns `{AllowedBytes, UpdatedState}' where AllowedBytes is at most Size.
-spec get_pacing_tokens(cc_state(), non_neg_integer()) -> {non_neg_integer(), cc_state()}.
get_pacing_tokens(#cc_state{pacing_rate = 0} = State, Size) ->
    %% Pacing not initialized - allow full send
    {Size, State};
get_pacing_tokens(
    #cc_state{
        pacing_tokens = Tokens,
        pacing_max_burst = MaxBurst,
        pacing_rate = Rate,
        last_pacing_update = LastUpdate
    } = State,
    Size
) ->
    Now = erlang:monotonic_time(microsecond),
    %% Refill tokens based on elapsed time
    NewTokens = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
    %% Consume up to available tokens
    Allowed = min(Size, NewTokens),
    RemainingTokens = max(0, NewTokens - Allowed),
    NewState = State#cc_state{
        pacing_tokens = RemainingTokens,
        last_pacing_update = Now
    },
    {Allowed, NewState}.

%% @doc Calculate delay (in ms) until Size bytes can be sent.
%% Returns 0 if sending is allowed immediately.
-spec pacing_delay(cc_state(), non_neg_integer()) -> non_neg_integer().
pacing_delay(#cc_state{pacing_rate = 0}, _Size) ->
    %% Pacing not initialized - no delay
    0;
pacing_delay(
    #cc_state{
        pacing_tokens = Tokens,
        pacing_max_burst = MaxBurst,
        pacing_rate = Rate,
        last_pacing_update = LastUpdate
    },
    Size
) ->
    Now = erlang:monotonic_time(microsecond),
    %% Calculate current tokens
    CurrentTokens = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
    case CurrentTokens >= Size of
        true ->
            0;
        false ->
            %% Calculate time needed to accumulate enough tokens
            Deficit = Size - CurrentTokens,
            %% Time = bytes / (bytes/ms) = ms
            max(1, (Deficit + Rate - 1) div Rate)
    end.

%% @doc Fused cwnd + pacing check for the hot send path.
%% One monotonic_time call, one record match. Replaces
%% can_send/can_send_control + pacing_allows + pacing_delay +
%% get_pacing_tokens on every packet.
-spec send_check(cc_state(), non_neg_integer(), non_neg_integer()) ->
    {ok, cc_state()}
    | {blocked_cwnd, non_neg_integer()}
    | {blocked_pacing, non_neg_integer()}.
send_check(
    #cc_state{
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
            %% Pacing not initialized — no state change needed.
            {ok, State};
        true ->
            #cc_state{
                pacing_tokens = Tokens,
                pacing_max_burst = MaxBurst,
                last_pacing_update = LastUpdate
            } = State,
            Now = erlang:monotonic_time(microsecond),
            Refreshed = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
            case Refreshed >= Size of
                true ->
                    {ok, State#cc_state{
                        pacing_tokens = Refreshed - Size,
                        last_pacing_update = Now
                    }};
                false ->
                    Deficit = Size - Refreshed,
                    DelayMs = max(1, (Deficit + Rate - 1) div Rate),
                    {blocked_pacing, DelayMs}
            end
    end.

%% @doc Batched send_check: approve up to MaxK packets of Size in one
%% pass, consuming pacing tokens exactly as MaxK sequential send_check
%% calls would, minus the sub-millisecond token refill between
%% iterations, so the batch is never more permissive. Returns how many
%% packets were approved and the updated state.
-spec send_check_run(cc_state(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), cc_state()}.
send_check_run(
    #cc_state{
        cwnd = Cwnd,
        bytes_in_flight = InFlight,
        control_allowance = Allowance,
        pacing_rate = Rate
    } = State,
    Size,
    MaxK,
    Urgency
) ->
    CwndLimit =
        case Urgency of
            0 -> Cwnd + Allowance;
            _ -> Cwnd
        end,
    Room = CwndLimit - InFlight,
    KC =
        case Room >= Size of
            true -> min(MaxK, Room div Size);
            false -> 0
        end,
    case {KC, Rate} of
        {0, _} ->
            {0, State};
        {_, 0} ->
            {KC, State};
        _ ->
            #cc_state{
                pacing_tokens = Tokens,
                pacing_max_burst = MaxBurst,
                last_pacing_update = LastUpdate
            } = State,
            Now = erlang:monotonic_time(microsecond),
            Refreshed = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
            case min(KC, Refreshed div Size) of
                KP when KP =< 0 ->
                    {0, State};
                KP ->
                    {KP, State#cc_state{
                        pacing_tokens = Refreshed - KP * Size,
                        last_pacing_update = Now
                    }}
            end
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Refill pacing tokens based on elapsed time (microsecond timestamps, rate in milli-bytes/us)
refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now) ->
    ElapsedUs = max(0, Now - LastUpdate),
    %% Rate is in milli-bytes per microsecond, so Added = (elapsed_us * rate) / 1000
    Added = (ElapsedUs * Rate) div 1000,
    min(MaxBurst, Tokens + Added).

%% Calculate initial window
%% Use 32 packets like quic-go for better initial throughput
%% RFC 9002 suggests min(10*mds, max(14720, 2*mds)) but larger is common in practice
default_initial_window(MaxDatagramSize) ->
    32 * MaxDatagramSize.

%% Calculate minimum window
%% kMinimumWindow = 2 * max_datagram_size
minimum_window(MaxDatagramSize) ->
    2 * MaxDatagramSize.
