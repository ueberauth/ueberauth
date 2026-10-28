%%% -*- erlang -*-
%%%
%%% QUIC BBRv3 Congestion Control
%%% IETF Draft: draft-ietf-ccwg-bbr
%%% RFC 9406 - HyStart++: Modified Slow Start for TCP
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC BBRv3 congestion control implementation.
%%%
%%% BBRv3 (Bottleneck Bandwidth and Round-trip propagation time) is a
%%% model-based congestion control algorithm that aims to maximize throughput
%%% while minimizing latency and packet loss.
%%%
%%% HyStart++ (RFC 9406) provides additional RTT-based startup exit detection
%%% alongside BBR's bandwidth plateau detection for earlier, safer exits.
%%%
%%% == States ==
%%%
%%% 1. Startup: Exponential bandwidth probing (2.77x pacing gain) with HyStart++ RTT monitoring
%%% 2. Drain: Reduce queue built during startup (0.35x pacing gain)
%%% 3. ProbeBW: Steady-state with cycling phases (DOWN/CRUISE/REFILL/UP)
%%% 4. ProbeRTT: Periodic RTT measurement with reduced cwnd
%%%
%%% == Key Concepts ==
%%%
%%% - BDP (Bandwidth-Delay Product): max_bw * min_rtt
%%% - Pacing Rate: pacing_gain * max_bw * 0.99
%%% - CWND: cwnd_gain * BDP (minimum 4 packets)
%%% - Delivery Rate: Measured bandwidth from ACK feedback

-module(quic_cc_bbr).

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
%% BBRv3 Constants
%%====================================================================

%% Pacing gains (matched to Google quiche BBR2)
-define(STARTUP_PACING_GAIN, 2.885).
-define(DRAIN_PACING_GAIN, 0.347).
-define(PROBE_BW_DOWN_PACING_GAIN, 0.91).

%% Initial RTT estimate when no samples exist (milliseconds)
-define(INITIAL_RTT, 100).
-define(PROBE_BW_CRUISE_PACING_GAIN, 1.0).
-define(PROBE_BW_REFILL_PACING_GAIN, 1.0).
-define(PROBE_BW_UP_PACING_GAIN, 1.25).

%% CWND gains
-define(DEFAULT_CWND_GAIN, 2.0).
-define(PROBE_RTT_CWND_GAIN, 0.5).

%% Loss handling
-define(LOSS_THRESH, 0.02).
-define(BETA, 0.7).

%% Minimum cwnd in packets
-define(MIN_PIPE_CWND, 4).

%% Timing constants (microseconds internally; loopback RTTs lose
%% signal at ms granularity so every timestamp field below is µs).
-define(PROBE_RTT_DURATION, 200 * 1000).
-define(PROBE_RTT_INTERVAL, 5000 * 1000).
-define(MIN_RTT_FILTER_LEN, 10000 * 1000).
-define(MAX_BW_FILTER_LEN, 2).

%% Minimum ACK interval before falling back to initial_rtt (µs).
%% Below this, delivery-rate samples are unreliable (e.g. coalesced
%% ACKs on loopback) and would artificially depress max_bw.
-define(MIN_ACK_INTERVAL_US, 200).

%% Pacing margin (1% headroom)
-define(PACING_MARGIN, 0.99).

%% Startup exit threshold (25% growth)
-define(STARTUP_GROWTH_TARGET, 1.25).
-define(STARTUP_FULL_BW_ROUNDS, 3).

%% Default values
-define(MAX_DATAGRAM_SIZE, 1200).
-define(PERSISTENT_CONGESTION_THRESHOLD, 3).

%% HyStart++ constants (RFC 9406)
%% Minimum RTT samples before making slow start exit decision
-define(HYSTART_MIN_SAMPLES, 8).
%% Dynamic RTT threshold bounds (RFC 9406)
%% Minimum RTT threshold in milliseconds
-define(HYSTART_MIN_RTT_THRESH, 4).
%% Maximum RTT threshold in milliseconds
-define(HYSTART_MAX_RTT_THRESH, 16).
%% Divisor for baseline RTT to calculate dynamic threshold
-define(HYSTART_MIN_RTT_DIVISOR, 8).

%%====================================================================
%% BBRv3 State Record
%%====================================================================

-record(bbr_state, {
    %% State Machine
    state = startup :: startup | drain | probe_bw | probe_rtt,
    probe_bw_phase = down :: down | cruise | refill | up,
    cycle_count = 0 :: non_neg_integer(),

    %% Bandwidth Model (windowed max filter)
    max_bw = 0 :: non_neg_integer(),
    max_bw_filter = [] :: list(),

    %% RTT Model (windowed min filter)
    initial_rtt = ?INITIAL_RTT :: pos_integer(),
    min_rtt = infinity :: non_neg_integer() | infinity,
    min_rtt_stamp = 0 :: non_neg_integer(),

    %% Delivery Rate Sampling
    delivered = 0 :: non_neg_integer(),
    delivered_time = 0 :: non_neg_integer(),
    first_sent_time = 0 :: non_neg_integer(),

    %% Gains
    pacing_gain = ?STARTUP_PACING_GAIN :: float(),
    cwnd_gain = ?DEFAULT_CWND_GAIN :: float(),

    %% CWND and Pacing
    cwnd = 0 :: non_neg_integer(),
    prior_cwnd = 0 :: non_neg_integer(),
    pacing_rate = 0 :: non_neg_integer(),

    %% Bytes Tracking
    bytes_in_flight = 0 :: non_neg_integer(),

    %% Round Tracking
    round_count = 0 :: non_neg_integer(),
    round_start = 0 :: non_neg_integer(),
    next_round_delivered = 0 :: non_neg_integer(),

    %% Startup Exit Detection
    startup_full_bw = 0 :: non_neg_integer(),
    startup_full_bw_count = 0 :: non_neg_integer(),

    %% Loss Handling (BBRv3)
    loss_in_round = 0 :: non_neg_integer(),
    bytes_in_round = 0 :: non_neg_integer(),
    inflight_hi = infinity :: non_neg_integer() | infinity,

    %% ProbeRTT
    probe_rtt_done_stamp = 0 :: non_neg_integer(),
    probe_rtt_min_stamp = 0 :: non_neg_integer(),

    %% Recovery (for interface compatibility)
    in_recovery = false :: boolean(),
    recovery_start_time = 0 :: non_neg_integer(),

    %% ECN
    ecn_ce_counter = 0 :: non_neg_integer(),

    %% Configuration
    %% The window this controller started with. cwnd evolves away from
    %% it, so without keeping it a reset cannot restore the configured
    %% value.
    initial_window = 0 :: non_neg_integer(),
    max_datagram_size = ?MAX_DATAGRAM_SIZE :: pos_integer(),
    minimum_window = 2400 :: non_neg_integer(),
    min_recovery_duration = 100 :: non_neg_integer(),

    %% Control message allowance
    control_allowance = 1200 :: non_neg_integer(),

    %% Pacing Tokens
    pacing_tokens = 0 :: non_neg_integer(),
    pacing_max_burst = 14400 :: non_neg_integer(),
    last_pacing_update = 0 :: non_neg_integer(),

    %% HyStart++ state (RFC 9406)
    %% Whether HyStart++ is enabled
    hystart_enabled = true :: boolean(),
    %% RTT sample count in current round
    hystart_rtt_sample_count = 0 :: non_neg_integer(),
    %% Last round's minimum RTT (milliseconds)
    hystart_last_rtt = 0 :: non_neg_integer(),
    %% Current round's minimum RTT (milliseconds)
    hystart_curr_rtt = infinity :: non_neg_integer() | infinity
}).

-opaque cc_state() :: #bbr_state{}.
-export_type([cc_state/0]).

%%====================================================================
%% Behavior Callbacks - State Management
%%====================================================================

%% @doc Create a new BBRv3 congestion control state.
-spec new(quic_cc:cc_opts()) -> cc_state().
new(Opts) ->
    MaxDatagramSize = maps:get(max_datagram_size, Opts, ?MAX_DATAGRAM_SIZE),
    MinimumWindow = maps:get(minimum_window, Opts, 2 * MaxDatagramSize),
    %% Public option is milliseconds; store as µs internally.
    MinRecoveryDurationMs = maps:get(min_recovery_duration, Opts, 100),
    MinRecoveryDuration = MinRecoveryDurationMs * 1000,
    InitialRtt = maps:get(initial_rtt, Opts, ?INITIAL_RTT),
    HystartEnabled = maps:get(hystart_enabled, Opts, true),
    PacingMaxBurst = 12 * MaxDatagramSize,
    Now = erlang:monotonic_time(microsecond),

    %% Initial cwnd: 10 packets or BDP estimate
    InitialCwnd = max(
        maps:get(initial_window, Opts, 10 * MaxDatagramSize),
        ?MIN_PIPE_CWND * MaxDatagramSize
    ),

    %% Initial bandwidth estimate: cwnd / rtt in bytes/sec.
    %% InitialRtt is ms, so multiply by 1000 to get bytes/sec.
    InitialMaxBw = (InitialCwnd * 1000) div InitialRtt,

    %% Initial pacing rate (bytes/sec): startup_gain * max_bw.
    InitialPacingRate = trunc(?STARTUP_PACING_GAIN * InitialMaxBw),

    ?LOG_DEBUG(
        #{
            what => cc_state_initialized,
            algorithm => bbr,
            initial_cwnd => InitialCwnd,
            minimum_window => MinimumWindow,
            max_datagram_size => MaxDatagramSize,
            initial_rtt => InitialRtt,
            initial_pacing_rate => InitialPacingRate,
            initial_max_bw => InitialMaxBw,
            hystart_enabled => HystartEnabled
        },
        ?QUIC_LOG_META
    ),

    #bbr_state{
        state = startup,
        pacing_gain = ?STARTUP_PACING_GAIN,
        cwnd_gain = ?DEFAULT_CWND_GAIN,
        cwnd = InitialCwnd,
        initial_window = InitialCwnd,
        initial_rtt = InitialRtt,
        max_bw = InitialMaxBw,
        pacing_rate = InitialPacingRate,
        minimum_window = max(MinimumWindow, 2 * MaxDatagramSize),
        max_datagram_size = MaxDatagramSize,
        min_recovery_duration = MinRecoveryDuration,
        pacing_max_burst = PacingMaxBurst,
        pacing_tokens = PacingMaxBurst,
        last_pacing_update = Now,
        min_rtt_stamp = Now,
        probe_rtt_min_stamp = Now,
        delivered_time = Now,
        round_start = Now,
        %% HyStart++ initialization
        hystart_enabled = HystartEnabled
    }.

%%====================================================================
%% Behavior Callbacks - Congestion Control Events
%%====================================================================

%% @doc Record that a packet was sent.
-spec on_packet_sent(cc_state(), non_neg_integer()) -> cc_state().
on_packet_sent(
    #bbr_state{
        bytes_in_flight = InFlight,
        first_sent_time = 0
    } = State,
    Size
) ->
    Now = erlang:monotonic_time(microsecond),
    State#bbr_state{
        bytes_in_flight = InFlight + Size,
        first_sent_time = Now
    };
on_packet_sent(
    #bbr_state{
        bytes_in_flight = InFlight,
        bytes_in_round = BytesInRound
    } = State,
    Size
) ->
    State#bbr_state{
        bytes_in_flight = InFlight + Size,
        bytes_in_round = BytesInRound + Size
    }.

%% @doc Process acknowledged packets (2-arg version).
-spec on_packets_acked(cc_state(), non_neg_integer()) -> cc_state().
on_packets_acked(State, AckedBytes) ->
    %% 2-arg path has no sent-time info; use current time so the RTT
    %% sample on this ACK would be 0 and gets ignored downstream.
    Now = erlang:monotonic_time(microsecond),
    do_on_packets_acked(State, AckedBytes, Now, Now).

%% @doc Process acknowledged packets with timing info.
%% AckTime is the sent-time of the largest acked packet, in ms
%% (supplied by quic_connection). We convert to µs on entry and work
%% in microsecond precision throughout — loopback RTTs round to 0 ms
%% otherwise, which collapses BDP.
-spec on_packets_acked(cc_state(), non_neg_integer(), non_neg_integer()) -> cc_state().
on_packets_acked(State, AckedBytes, AckTimeMs) ->
    Now = erlang:monotonic_time(microsecond),
    AckTimeUs = AckTimeMs * 1000,
    do_on_packets_acked(State, AckedBytes, AckTimeUs, Now).

do_on_packets_acked(
    #bbr_state{
        bytes_in_flight = InFlight,
        delivered = Delivered,
        delivered_time = DeliveredTime
    } = State,
    AckedBytes,
    AckTime,
    Now
) ->
    NewInFlight = max(0, InFlight - AckedBytes),
    NewDelivered = Delivered + AckedBytes,

    %% Calculate delivery rate
    State1 = State#bbr_state{
        bytes_in_flight = NewInFlight,
        delivered = NewDelivered
    },

    %% Update delivery rate and bandwidth
    State2 = update_delivery_rate(State1, AckedBytes, DeliveredTime, Now),

    %% Update RTT if we have timing info. RttSample = Now - AckTime, µs.
    RttSample = Now - AckTime,
    State3 =
        case RttSample > 0 of
            true -> update_min_rtt(State2, RttSample, Now);
            false -> State2
        end,

    %% Check round completion
    State4 = check_round_completion(State3),

    %% Run the state machine
    State5 = run_state_machine(State4, Now),

    %% Update cwnd and pacing based on new state
    State6 = update_cwnd(State5),
    update_bbr_pacing_rate(State6).

%% @doc Process lost packets.
-spec on_packets_lost(cc_state(), non_neg_integer()) -> cc_state().
on_packets_lost(
    #bbr_state{
        bytes_in_flight = InFlight,
        loss_in_round = LossInRound
    } = State,
    LostBytes
) ->
    NewInFlight = max(0, InFlight - LostBytes),
    State#bbr_state{
        bytes_in_flight = NewInFlight,
        loss_in_round = LossInRound + LostBytes
    }.

%% @doc Handle a congestion event (packet loss detected).
-spec on_congestion_event(cc_state(), non_neg_integer()) -> cc_state().
%% SentTime is ms (from quic_connection); compare in µs internally.
on_congestion_event(
    #bbr_state{
        in_recovery = true,
        recovery_start_time = RecoveryStart
    } = State,
    SentTimeMs
) when (SentTimeMs * 1000) =< RecoveryStart ->
    %% Already in recovery for packets sent before recovery started
    State;
on_congestion_event(
    #bbr_state{
        in_recovery = true,
        recovery_start_time = RecoveryStart,
        min_recovery_duration = MinDuration
    } = State,
    _SentTimeMs
) ->
    Now = erlang:monotonic_time(microsecond),
    case Now - RecoveryStart < MinDuration of
        true ->
            %% Still within protected recovery period
            State;
        false ->
            do_bbr_congestion_event(State)
    end;
on_congestion_event(State, _SentTimeMs) ->
    do_bbr_congestion_event(State).

%% @private BBRv3 congestion response
do_bbr_congestion_event(
    #bbr_state{
        bytes_in_round = BytesInRound,
        loss_in_round = LossInRound,
        max_bw = MaxBw,
        bytes_in_flight = InFlight,
        inflight_hi = InflightHi
    } = State
) ->
    Now = erlang:monotonic_time(microsecond),

    %% Check if loss rate exceeds threshold (2%)
    LossRate =
        case BytesInRound > 0 of
            true -> LossInRound / BytesInRound;
            false -> 0.0
        end,

    State1 =
        case LossRate > ?LOSS_THRESH of
            true ->
                %% BBRv3: Reduce max_bw by Beta (0.7) on excessive loss
                NewMaxBw = trunc(MaxBw * ?BETA),
                %% Set inflight_hi to current in-flight
                NewInflightHi =
                    case InflightHi of
                        infinity -> InFlight;
                        _ -> min(InflightHi, InFlight)
                    end,
                ?LOG_DEBUG(
                    #{
                        what => bbr_loss_response,
                        loss_rate => LossRate,
                        old_max_bw => MaxBw,
                        new_max_bw => NewMaxBw,
                        inflight_hi => NewInflightHi
                    },
                    ?QUIC_LOG_META
                ),
                State#bbr_state{
                    max_bw = NewMaxBw,
                    inflight_hi = NewInflightHi
                };
            false ->
                State
        end,

    %% Enter recovery
    State1#bbr_state{
        in_recovery = true,
        recovery_start_time = Now,
        loss_in_round = 0,
        bytes_in_round = 0
    }.

%% @doc Handle ECN-CE signal.
-spec on_ecn_ce(cc_state(), non_neg_integer()) -> cc_state().
on_ecn_ce(#bbr_state{ecn_ce_counter = OldCount} = State, NewCECount) when NewCECount =< OldCount ->
    State;
on_ecn_ce(#bbr_state{max_bw = MaxBw} = State, NewCECount) ->
    %% BBRv3: Treat ECN-CE similar to loss
    Now = erlang:monotonic_time(microsecond),
    NewMaxBw = trunc(MaxBw * ?BETA),
    ?LOG_DEBUG(
        #{
            what => bbr_ecn_ce_response,
            old_max_bw => MaxBw,
            new_max_bw => NewMaxBw,
            ce_count => NewCECount
        },
        ?QUIC_LOG_META
    ),
    State#bbr_state{
        max_bw = NewMaxBw,
        ecn_ce_counter = NewCECount,
        in_recovery = true,
        recovery_start_time = Now
    }.

%% @doc Handle persistent congestion.
-spec on_persistent_congestion(cc_state()) -> cc_state().
on_persistent_congestion(#bbr_state{minimum_window = MinimumWindow} = State) ->
    %% Reset to Startup with minimum cwnd
    ?LOG_DEBUG(
        #{
            what => bbr_persistent_congestion,
            new_cwnd => MinimumWindow
        },
        ?QUIC_LOG_META
    ),
    State#bbr_state{
        state = startup,
        pacing_gain = ?STARTUP_PACING_GAIN,
        cwnd_gain = ?DEFAULT_CWND_GAIN,
        cwnd = MinimumWindow,
        max_bw = 0,
        max_bw_filter = [],
        min_rtt = infinity,
        in_recovery = false,
        recovery_start_time = 0,
        startup_full_bw = 0,
        startup_full_bw_count = 0,
        inflight_hi = infinity,
        %% Reset HyStart++ state
        hystart_rtt_sample_count = 0,
        hystart_last_rtt = 0,
        hystart_curr_rtt = infinity
    }.

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

%%====================================================================
%% Behavior Callbacks - Pacing
%%====================================================================

%% @doc Update pacing rate based on smoothed RTT.
%% Note: BBR primarily uses its own pacing_rate calculation,
%% but this callback allows external RTT info integration.
-spec update_pacing_rate(cc_state(), non_neg_integer()) -> cc_state().
update_pacing_rate(State, SmoothedRTT) when SmoothedRTT > 0 ->
    %% SmoothedRTT is ms from quic_loss; convert to µs internally.
    Now = erlang:monotonic_time(microsecond),
    RttUs = SmoothedRTT * 1000,
    State1 = update_min_rtt(State, RttUs, Now),
    %% HyStart++ threshold math is expressed in ms in RFC 9406 —
    %% keep the hystart tracker ms-based.
    update_hystart_rtt(State1, SmoothedRTT);
update_pacing_rate(State, _SmoothedRTT) ->
    State.

%% @doc Check if pacing allows sending Size bytes.
-spec pacing_allows(cc_state(), non_neg_integer()) -> boolean().
pacing_allows(#bbr_state{pacing_rate = 0}, _Size) ->
    true;
pacing_allows(
    #bbr_state{
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
get_pacing_tokens(#bbr_state{pacing_rate = 0} = State, Size) ->
    {Size, State};
get_pacing_tokens(
    #bbr_state{
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
    NewState = State#bbr_state{
        pacing_tokens = RemainingTokens,
        last_pacing_update = Now
    },
    {Allowed, NewState}.

%% @doc Calculate pacing delay.
-spec pacing_delay(cc_state(), non_neg_integer()) -> non_neg_integer().
pacing_delay(#bbr_state{pacing_rate = 0}, _Size) ->
    0;
pacing_delay(
    #bbr_state{
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
            %% Rate is bytes/sec; return delay in ms (timer granularity).
            %% Delay = deficit_bytes * 1000 / rate_bps (rounded up, min 1).
            Deficit = Size - CurrentTokens,
            SafeRate = max(Rate, 1),
            max(1, (Deficit * 1000 + SafeRate - 1) div SafeRate)
    end.

%% @doc Fused cwnd + pacing check for the hot send path.
-spec send_check(cc_state(), non_neg_integer(), non_neg_integer()) ->
    {ok, cc_state()}
    | {blocked_cwnd, non_neg_integer()}
    | {blocked_pacing, non_neg_integer()}.
send_check(
    #bbr_state{
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
            #bbr_state{
                pacing_tokens = Tokens,
                pacing_max_burst = MaxBurst,
                last_pacing_update = LastUpdate
            } = State,
            Now = erlang:monotonic_time(microsecond),
            Refreshed = refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now),
            case Refreshed >= Size of
                true ->
                    {ok, State#bbr_state{
                        pacing_tokens = Refreshed - Size,
                        last_pacing_update = Now
                    }};
                false ->
                    %% BBR pacing rate is bytes/sec; return delay in ms.
                    Deficit = Size - Refreshed,
                    SafeRate = max(Rate, 1),
                    DelayMs = max(1, (Deficit * 1000 + SafeRate - 1) div SafeRate),
                    {blocked_pacing, DelayMs}
            end
    end.

%%====================================================================
%% Behavior Callbacks - MTU Update
%%====================================================================

%% @doc Update congestion control state when MTU changes.
-spec update_mtu(cc_state(), pos_integer()) -> cc_state().
update_mtu(#bbr_state{max_datagram_size = OldMDS} = State, NewMTU) when NewMTU =:= OldMDS ->
    State;
update_mtu(#bbr_state{max_datagram_size = OldMDS, minimum_window = OldMinWin} = State, NewMTU) ->
    NewMinimumWindow = max(2 * NewMTU, (OldMinWin * NewMTU) div OldMDS),
    NewPacingMaxBurst = 12 * NewMTU,
    ?LOG_DEBUG(
        #{
            what => bbr_mtu_updated,
            old_mtu => OldMDS,
            new_mtu => NewMTU,
            new_minimum_window => NewMinimumWindow
        },
        ?QUIC_LOG_META
    ),
    State#bbr_state{
        max_datagram_size = NewMTU,
        minimum_window = NewMinimumWindow,
        pacing_max_burst = NewPacingMaxBurst
    }.

%%====================================================================
%% Behavior Callbacks - Queries
%%====================================================================

%% @doc Get the current congestion window.
-spec cwnd(cc_state()) -> non_neg_integer().
cwnd(#bbr_state{cwnd = Cwnd}) -> Cwnd.

%% @doc Drop bytes for a discarded packet number space. Not a
%% congestion event: no window or recovery change.
-spec on_packets_discarded(cc_state(), non_neg_integer()) -> cc_state().
on_packets_discarded(#bbr_state{bytes_in_flight = B} = State, Bytes) ->
    State#bbr_state{bytes_in_flight = max(0, B - Bytes)}.

%% @doc Start over after a Retry, keeping every configured value.
-spec reset_for_retry(cc_state()) -> cc_state().
reset_for_retry(#bbr_state{initial_window = IW} = State) ->
    State#bbr_state{
        cwnd = IW,
        bytes_in_flight = 0,
        in_recovery = false,
        recovery_start_time = 0,
        ecn_ce_counter = 0,
        prior_cwnd = 0,
        pacing_tokens = State#bbr_state.pacing_max_burst,
        pacing_rate = 0
    }.

%% @doc The window this controller was configured with.
-spec initial_window(cc_state()) -> non_neg_integer().
initial_window(#bbr_state{initial_window = IW}) -> IW.

%% @doc Get the slow start threshold.
%% BBR doesn't use ssthresh; returns infinity.
-spec ssthresh(cc_state()) -> non_neg_integer() | infinity.
ssthresh(_State) -> infinity.

%% @doc Get bytes currently in flight.
-spec bytes_in_flight(cc_state()) -> non_neg_integer().
bytes_in_flight(#bbr_state{bytes_in_flight = B}) -> B.

%% @doc Check if we can send more bytes.
-spec can_send(cc_state(), non_neg_integer()) -> boolean().
can_send(#bbr_state{cwnd = Cwnd, bytes_in_flight = InFlight}, Size) ->
    InFlight + Size =< Cwnd.

%% @doc Check if a control message can be sent.
-spec can_send_control(cc_state(), non_neg_integer()) -> boolean().
can_send_control(
    #bbr_state{cwnd = Cwnd, bytes_in_flight = InFlight, control_allowance = Allowance}, Size
) ->
    InFlight + Size =< Cwnd + Allowance.

%% @doc Get the available congestion window.
-spec available_cwnd(cc_state()) -> non_neg_integer().
available_cwnd(#bbr_state{cwnd = Cwnd, bytes_in_flight = InFlight}) ->
    max(0, Cwnd - InFlight).

%% @doc Check if in slow start phase (Startup state for BBR).
-spec in_slow_start(cc_state()) -> boolean().
in_slow_start(#bbr_state{state = startup}) -> true;
in_slow_start(_State) -> false.

%% @doc Check if in recovery phase.
-spec in_recovery(cc_state()) -> boolean().
in_recovery(#bbr_state{in_recovery = R}) -> R.

%% @doc Get the current max datagram size.
-spec max_datagram_size(cc_state()) -> pos_integer().
max_datagram_size(#bbr_state{max_datagram_size = MDS}) -> MDS.

%% @doc Get minimum recovery duration setting (milliseconds, matching
%% the public option contract; stored internally as microseconds).
-spec min_recovery_duration(cc_state()) -> non_neg_integer().
min_recovery_duration(#bbr_state{min_recovery_duration = D}) -> D div 1000.

%% @doc Get the current ECN-CE counter.
-spec ecn_ce_counter(cc_state()) -> non_neg_integer().
ecn_ce_counter(#bbr_state{ecn_ce_counter = C}) -> C.

%%====================================================================
%% Internal Functions - Delivery Rate
%%====================================================================

%% @private Update delivery rate from ACK feedback.
%% Works in microseconds: loopback ACK intervals are ~100-500 µs and
%% the old ms-granularity code rounded them to 0–1 ms, wedging
%% Interval to InitialRtt (100 ms) on every sample.
update_delivery_rate(
    #bbr_state{
        delivered_time = OldDeliveredTime,
        initial_rtt = InitialRtt,
        max_bw = MaxBw,
        max_bw_filter = Filter,
        round_count = RoundCount
    } = State,
    AckedBytes,
    _OldDeliveredTime,
    Now
) ->
    AckElapsed = Now - OldDeliveredTime,

    %% Below 200 µs the sample is unreliable (coalesced ACKs, burst
    %% arrivals); fall back to initial_rtt scaled to µs.
    Interval =
        case AckElapsed of
            A when A =< ?MIN_ACK_INTERVAL_US ->
                InitialRtt * 1000;
            A ->
                A
        end,

    %% delivery_rate = acked_bytes * 1_000_000 / interval_us → bytes/sec
    DeliveryRate = (AckedBytes * 1_000_000) div Interval,

    %% Update max_bw filter (windowed max over last 2 cycles)
    {NewMaxBw, NewFilter} = update_bw_filter(DeliveryRate, RoundCount, MaxBw, Filter),

    State#bbr_state{
        max_bw = NewMaxBw,
        max_bw_filter = NewFilter,
        delivered_time = Now
    }.

%% @private Windowed max filter for bandwidth
update_bw_filter(NewBw, RoundCount, _MaxBw, Filter) ->
    %% Add new sample
    NewFilter0 = [{RoundCount, NewBw} | Filter],

    %% Remove old samples (keep last MAX_BW_FILTER_LEN cycles)
    MinRound = max(0, RoundCount - ?MAX_BW_FILTER_LEN),
    NewFilter = [{R, B} || {R, B} <- NewFilter0, R >= MinRound],

    %% Find max in filter
    MaxBw =
        case NewFilter of
            [] -> NewBw;
            _ -> lists:max([B || {_, B} <- NewFilter])
        end,

    {MaxBw, NewFilter}.

%%====================================================================
%% Internal Functions - RTT
%%====================================================================

%% @private Update min_rtt from RTT sample
update_min_rtt(
    #bbr_state{
        min_rtt = MinRtt,
        min_rtt_stamp = MinRttStamp
    } = State,
    RttSample,
    Now
) ->
    %% Check if min_rtt filter has expired
    FilterExpired = (Now - MinRttStamp) > ?MIN_RTT_FILTER_LEN,

    NewMinRtt =
        case FilterExpired orelse RttSample < MinRtt of
            true -> RttSample;
            false -> MinRtt
        end,

    NewMinRttStamp =
        case NewMinRtt =:= RttSample of
            true -> Now;
            false -> MinRttStamp
        end,

    State#bbr_state{
        min_rtt = NewMinRtt,
        min_rtt_stamp = NewMinRttStamp
    }.

%%====================================================================
%% Internal Functions - Round Tracking
%%====================================================================

%% @private Check if a round has completed
check_round_completion(
    #bbr_state{
        delivered = Delivered,
        next_round_delivered = NextRoundDelivered,
        round_count = RoundCount,
        in_recovery = WasInRecovery,
        hystart_curr_rtt = CurrRTT
    } = State
) ->
    case Delivered >= NextRoundDelivered of
        true ->
            %% Round completed - reset per-round state including recovery
            %% BBRv3: Recovery state is reset per round, allowing fresh
            %% loss detection in the next round.
            %% Also reset inflight_hi when exiting recovery to allow
            %% cwnd to grow again (per BBRv3 spec).
            NewInflightHi =
                case WasInRecovery of
                    true -> infinity;
                    false -> State#bbr_state.inflight_hi
                end,
            %% HyStart++: Save current round's min RTT as last RTT for next round comparison
            NewLastRTT =
                case CurrRTT of
                    infinity -> 0;
                    _ -> CurrRTT
                end,
            State#bbr_state{
                round_count = RoundCount + 1,
                next_round_delivered = Delivered,
                loss_in_round = 0,
                bytes_in_round = 0,
                in_recovery = false,
                inflight_hi = NewInflightHi,
                %% HyStart++ round tracking
                hystart_last_rtt = NewLastRTT,
                hystart_curr_rtt = infinity,
                hystart_rtt_sample_count = 0
            };
        false ->
            State
    end.

%%====================================================================
%% Internal Functions - State Machine
%%====================================================================

%% @private Run the BBR state machine
run_state_machine(#bbr_state{state = startup} = State, Now) ->
    run_startup(State, Now);
run_state_machine(#bbr_state{state = drain} = State, Now) ->
    run_drain(State, Now);
run_state_machine(#bbr_state{state = probe_bw} = State, Now) ->
    run_probe_bw(State, Now);
run_state_machine(#bbr_state{state = probe_rtt} = State, Now) ->
    run_probe_rtt(State, Now).

%% @private Startup state logic
%% BBRv3: Exit STARTUP when bandwidth plateaus (no 25% growth for 3 rounds)
%% or when HyStart++ detects RTT increase (RFC 9406).
%% Loss is handled by reducing max_bw in on_congestion_event, NOT by exiting STARTUP.
%% This prevents premature exit to DRAIN where pacing_gain drops to 0.35x.
run_startup(
    #bbr_state{
        max_bw = MaxBw,
        startup_full_bw = FullBw,
        startup_full_bw_count = FullBwCount
    } = State,
    _Now
) ->
    %% Check for Startup exit condition:
    %% 1. Bandwidth hasn't grown by 25% for 3 consecutive rounds
    %% 2. HyStart++ RTT-based exit (RFC 9406)
    %% Note: Loss does NOT cause STARTUP exit per BBRv3 spec.
    %% Loss is handled separately by reducing max_bw in on_congestion_event.

    {NewFullBw, NewFullBwCount, ExitForBw} =
        case MaxBw >= trunc(FullBw * ?STARTUP_GROWTH_TARGET) of
            true ->
                %% Bandwidth grew by 25%+, reset counter
                {MaxBw, 0, false};
            false when FullBwCount + 1 >= ?STARTUP_FULL_BW_ROUNDS ->
                %% No growth for 3 rounds, exit
                {FullBw, FullBwCount + 1, true};
            false ->
                {FullBw, FullBwCount + 1, false}
        end,

    State1 = State#bbr_state{
        startup_full_bw = NewFullBw,
        startup_full_bw_count = NewFullBwCount
    },

    %% Check HyStart++ RTT-based exit
    ExitForHystart = hystart_should_exit(State1),

    case ExitForBw orelse ExitForHystart of
        true ->
            Reason =
                case ExitForBw of
                    true -> bandwidth_plateau;
                    false -> hystart_rtt_increase
                end,
            %% Exit Startup, enter Drain
            ?LOG_DEBUG(
                #{
                    what => bbr_exit_startup,
                    reason => Reason,
                    max_bw => MaxBw
                },
                ?QUIC_LOG_META
            ),
            exit_startup(State1);
        false ->
            State1
    end.

%% @private Exit startup and enter drain, resetting HyStart++ state
exit_startup(State) ->
    State#bbr_state{
        state = drain,
        pacing_gain = ?DRAIN_PACING_GAIN,
        cwnd_gain = ?DEFAULT_CWND_GAIN,
        %% Reset HyStart++ state
        hystart_rtt_sample_count = 0,
        hystart_last_rtt = 0,
        hystart_curr_rtt = infinity
    }.

%% @private Drain state logic
run_drain(
    #bbr_state{
        bytes_in_flight = InFlight,
        max_bw = MaxBw,
        min_rtt = MinRtt
    } = State,
    Now
) ->
    %% Exit Drain when inflight <= BDP
    BDP = calculate_bdp(MaxBw, MinRtt, State),

    case InFlight =< BDP of
        true ->
            %% Enter ProbeBW
            ?LOG_DEBUG(
                #{
                    what => bbr_exit_drain,
                    bytes_in_flight => InFlight,
                    bdp => BDP
                },
                ?QUIC_LOG_META
            ),
            enter_probe_bw(State, Now);
        false ->
            State
    end.

%% @private Enter ProbeBW state
enter_probe_bw(State, _Now) ->
    State#bbr_state{
        state = probe_bw,
        probe_bw_phase = cruise,
        pacing_gain = ?PROBE_BW_CRUISE_PACING_GAIN,
        cwnd_gain = ?DEFAULT_CWND_GAIN,
        cycle_count = 0
    }.

%% @private ProbeBW state logic
run_probe_bw(
    #bbr_state{
        probe_bw_phase = Phase,
        min_rtt_stamp = MinRttStamp
    } = State,
    Now
) ->
    %% Check if we need to enter ProbeRTT
    NeedProbeRtt = (Now - MinRttStamp) > ?PROBE_RTT_INTERVAL,

    case NeedProbeRtt of
        true ->
            enter_probe_rtt(State, Now);
        false ->
            advance_probe_bw_phase(State, Phase, Now)
    end.

%% @private Advance ProbeBW phase cycle
advance_probe_bw_phase(
    #bbr_state{
        bytes_in_flight = InFlight,
        max_bw = MaxBw,
        min_rtt = MinRtt,
        cycle_count = CycleCount
    } = State,
    Phase,
    _Now
) ->
    BDP = calculate_bdp(MaxBw, MinRtt, State),

    %% Cycle through phases: DOWN -> CRUISE -> REFILL -> UP -> DOWN
    case Phase of
        down when InFlight =< BDP ->
            %% Exit DOWN when inflight drains to BDP
            State#bbr_state{
                probe_bw_phase = cruise,
                pacing_gain = ?PROBE_BW_CRUISE_PACING_GAIN
            };
        cruise ->
            %% Stay in CRUISE for steady state
            %% Transition to REFILL to prepare for UP
            State#bbr_state{
                probe_bw_phase = refill,
                pacing_gain = ?PROBE_BW_REFILL_PACING_GAIN
            };
        refill when InFlight >= BDP ->
            %% Exit REFILL when pipe is refilled
            State#bbr_state{
                probe_bw_phase = up,
                pacing_gain = ?PROBE_BW_UP_PACING_GAIN
            };
        up ->
            %% After UP phase, go to DOWN
            State#bbr_state{
                probe_bw_phase = down,
                pacing_gain = ?PROBE_BW_DOWN_PACING_GAIN,
                cycle_count = CycleCount + 1
            };
        _ ->
            %% Stay in current phase
            State
    end.

%% @private Enter ProbeRTT state
enter_probe_rtt(#bbr_state{cwnd = Cwnd} = State, Now) ->
    ?LOG_DEBUG(
        #{
            what => bbr_enter_probe_rtt,
            prior_cwnd => Cwnd
        },
        ?QUIC_LOG_META
    ),
    State#bbr_state{
        state = probe_rtt,
        prior_cwnd = Cwnd,
        cwnd_gain = ?PROBE_RTT_CWND_GAIN,
        probe_rtt_done_stamp = Now + ?PROBE_RTT_DURATION,
        probe_rtt_min_stamp = Now
    }.

%% @private ProbeRTT state logic
run_probe_rtt(
    #bbr_state{
        probe_rtt_done_stamp = DoneStamp,
        bytes_in_flight = InFlight,
        minimum_window = MinWindow
    } = State,
    Now
) ->
    %% Stay in ProbeRTT until:
    %% 1. Duration has passed (200ms)
    %% 2. Inflight is drained to minimum
    DurationDone = Now >= DoneStamp,
    InFlightDrained = InFlight =< MinWindow,

    case DurationDone andalso InFlightDrained of
        true ->
            exit_probe_rtt(State, Now);
        false ->
            State
    end.

%% @private Exit ProbeRTT state
exit_probe_rtt(#bbr_state{prior_cwnd = PriorCwnd} = State, Now) ->
    ?LOG_DEBUG(
        #{
            what => bbr_exit_probe_rtt,
            restored_cwnd => PriorCwnd
        },
        ?QUIC_LOG_META
    ),
    %% Restore cwnd and return to ProbeBW
    State#bbr_state{
        state = probe_bw,
        probe_bw_phase = cruise,
        cwnd = PriorCwnd,
        cwnd_gain = ?DEFAULT_CWND_GAIN,
        pacing_gain = ?PROBE_BW_CRUISE_PACING_GAIN,
        min_rtt_stamp = Now
    }.

%%====================================================================
%% HyStart++ Implementation (RFC 9406)
%%====================================================================

%% @private Check if HyStart++ RTT-based exit should occur
hystart_should_exit(#bbr_state{
    hystart_enabled = true,
    hystart_rtt_sample_count = Samples,
    hystart_curr_rtt = CurrRTT,
    hystart_last_rtt = LastRTT
}) when
    Samples >= ?HYSTART_MIN_SAMPLES,
    is_integer(CurrRTT),
    CurrRTT > 0,
    LastRTT > 0
->
    %% Calculate dynamic RTT threshold (RFC 9406)
    RTTThresh = calculate_rtt_threshold(LastRTT),
    (CurrRTT - LastRTT) > RTTThresh;
hystart_should_exit(_) ->
    false.

%% @private Calculate dynamic RTT threshold (RFC 9406)
%% RttThresh = clamp(MIN, lastRTT/DIVISOR, MAX)
calculate_rtt_threshold(LastRTT) when LastRTT > 0 ->
    Threshold = LastRTT div ?HYSTART_MIN_RTT_DIVISOR,
    max(?HYSTART_MIN_RTT_THRESH, min(Threshold, ?HYSTART_MAX_RTT_THRESH));
calculate_rtt_threshold(_) ->
    ?HYSTART_MIN_RTT_THRESH.

%% @private Update HyStart++ RTT samples
%% Called from update_pacing_rate when in startup
update_hystart_rtt(
    #bbr_state{
        hystart_enabled = true,
        hystart_curr_rtt = CurrRTT,
        hystart_rtt_sample_count = SampleCount,
        state = startup
    } = State,
    RTT
) ->
    %% In startup, track RTT samples
    NewCurrRTT =
        case CurrRTT of
            infinity -> RTT;
            _ -> min(CurrRTT, RTT)
        end,
    State#bbr_state{
        hystart_curr_rtt = NewCurrRTT,
        hystart_rtt_sample_count = SampleCount + 1
    };
update_hystart_rtt(State, _RTT) ->
    State.

%%====================================================================
%% Internal Functions - CWND and Pacing
%%====================================================================

%% @private Calculate BDP. max_bw is bytes/sec, min_rtt is µs.
calculate_bdp(_MaxBw, infinity, #bbr_state{max_datagram_size = MDS}) ->
    %% No RTT sample yet, use minimum
    ?MIN_PIPE_CWND * MDS;
calculate_bdp(MaxBw, MinRttUs, #bbr_state{max_datagram_size = MDS}) ->
    BDP = (MaxBw * MinRttUs) div 1_000_000,
    max(BDP, ?MIN_PIPE_CWND * MDS).

%% @private Update cwnd based on current state
update_cwnd(
    #bbr_state{
        state = BbrState,
        max_bw = MaxBw,
        min_rtt = MinRtt,
        cwnd_gain = CwndGain,
        inflight_hi = InflightHi,
        minimum_window = MinWindow,
        max_datagram_size = MDS
    } = State
) ->
    %% cwnd = cwnd_gain * BDP
    BDP = calculate_bdp(MaxBw, MinRtt, State),
    TargetCwnd = trunc(CwndGain * BDP),

    %% Apply inflight_hi cap only in ProbeBW state (not in STARTUP/DRAIN)
    %% BBRv3: During STARTUP we want to probe the full BDP without caps
    CappedCwnd =
        case {BbrState, InflightHi} of
            {startup, _} -> TargetCwnd;
            {drain, _} -> TargetCwnd;
            {_, infinity} -> TargetCwnd;
            {_, _} -> min(TargetCwnd, InflightHi)
        end,

    %% Ensure minimum
    MinCwnd = max(MinWindow, ?MIN_PIPE_CWND * MDS),
    NewCwnd = max(CappedCwnd, MinCwnd),

    State#bbr_state{cwnd = NewCwnd}.

%% @private Update BBR's pacing rate (bytes/sec, matches max_bw unit).
update_bbr_pacing_rate(
    #bbr_state{
        max_bw = MaxBw,
        pacing_gain = PacingGain
    } = State
) ->
    PacingRate = trunc(PacingGain * MaxBw * ?PACING_MARGIN),
    State#bbr_state{pacing_rate = max(1, PacingRate)}.

%%====================================================================
%% Internal Functions - Pacing Token Bucket
%%====================================================================

%% @private Refill pacing tokens based on elapsed time.
%% Elapsed is µs, Rate is bytes/sec; Added = Elapsed * Rate / 1e6.
refill_tokens_at(Tokens, MaxBurst, Rate, LastUpdate, Now) ->
    Elapsed = max(0, Now - LastUpdate),
    Added = (Elapsed * Rate) div 1_000_000,
    min(MaxBurst, Tokens + Added).
