%%% -*- erlang -*-
%%%
%%% QUIC Congestion Control Behavior and Facade
%%% RFC 9002 Section 7 - Congestion Control
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC congestion control behavior and facade.
%%%
%%% This module defines the behavior for pluggable congestion control
%%% algorithms and provides a facade that delegates to the selected
%%% implementation.
%%%
%%% == Available Algorithms ==
%%%
%%% - `newreno' (default): RFC 9002 NewReno implementation
%%% - `bbr': BBRv3 (future implementation)
%%%
%%% == Usage ==
%%%
%%% ```
%%% %% Create with default algorithm (NewReno)
%%% State = quic_cc:new(),
%%% State = quic_cc:new(#{initial_window => 65536}),
%%%
%%% %% Create with explicit algorithm
%%% State = quic_cc:new(newreno, #{}),
%%% State = quic_cc:new(bbr, #{}).
%%% '''

-module(quic_cc).

%% API - State management
-export([
    new/0,
    new/1,
    new/2
]).

%% API - Congestion control events
-export([
    on_packet_sent/2,
    on_packets_acked/2,
    on_packets_acked/3,
    on_packets_lost/2,
    on_congestion_event/2,
    on_ecn_ce/2,
    on_persistent_congestion/1,
    detect_persistent_congestion/3,
    update_pacing_rate/2,
    update_mtu/2
]).

%% API - Queries
-export([
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

%% API - Algorithm info
-export([
    algorithm/1
]).

%%====================================================================
%% Behavior Definition
%%====================================================================

%% State management
-callback new(Opts :: cc_opts()) -> State :: term().

%% Congestion control events
-callback on_packet_sent(State :: term(), Size :: non_neg_integer()) -> State :: term().
-callback on_packets_acked(State :: term(), AckedBytes :: non_neg_integer()) -> State :: term().
-callback on_packets_acked(
    State :: term(), AckedBytes :: non_neg_integer(), LargestAckedSentTime :: non_neg_integer()
) -> State :: term().
-callback on_packets_lost(State :: term(), LostBytes :: non_neg_integer()) -> State :: term().
-callback on_congestion_event(State :: term(), SentTime :: non_neg_integer()) -> State :: term().
-callback on_ecn_ce(State :: term(), ECNCE :: non_neg_integer()) -> State :: term().
-callback on_persistent_congestion(State :: term()) -> State :: term().
-callback detect_persistent_congestion(
    LostInfo :: [{non_neg_integer(), non_neg_integer()}],
    PTO :: non_neg_integer(),
    State :: term()
) -> boolean().

%% Pacing
-callback update_pacing_rate(State :: term(), SmoothedRTT :: non_neg_integer()) -> State :: term().
-callback pacing_allows(State :: term(), Size :: non_neg_integer()) -> boolean().
-callback get_pacing_tokens(State :: term(), Size :: non_neg_integer()) ->
    {non_neg_integer(), State :: term()}.
-callback pacing_delay(State :: term(), Size :: non_neg_integer()) -> non_neg_integer().

%% Fused send check (cwnd + pacing) used by the hot send path.
%% Urgency 0 uses the control-allowance variant of the cwnd check.
%% Returns one of:
%%   {ok, NewState}          — cwnd + pacing both allow; tokens consumed
%%   {blocked_cwnd, Avail}   — cwnd would overflow; Avail = max(0, cwnd - inflight)
%%   {blocked_pacing, Delay} — pacing blocks for Delay ms
-callback send_check(
    State :: term(),
    Size :: non_neg_integer(),
    Urgency :: non_neg_integer()
) ->
    {ok, State :: term()}
    | {blocked_cwnd, non_neg_integer()}
    | {blocked_pacing, non_neg_integer()}.

%% MTU update
-callback update_mtu(State :: term(), NewMTU :: pos_integer()) -> State :: term().

%% Queries
-callback cwnd(State :: term()) -> non_neg_integer().
-callback initial_window(State :: term()) -> non_neg_integer().
-callback on_packets_discarded(State :: term(), Bytes :: non_neg_integer()) -> State :: term().
-callback reset_for_retry(State :: term()) -> State :: term().
-callback ssthresh(State :: term()) -> non_neg_integer() | infinity.
-callback bytes_in_flight(State :: term()) -> non_neg_integer().
-callback can_send(State :: term(), Size :: non_neg_integer()) -> boolean().
-callback can_send_control(State :: term(), Size :: non_neg_integer()) -> boolean().
-callback available_cwnd(State :: term()) -> non_neg_integer().
-callback in_slow_start(State :: term()) -> boolean().
-callback in_recovery(State :: term()) -> boolean().
-callback max_datagram_size(State :: term()) -> pos_integer().
-callback min_recovery_duration(State :: term()) -> non_neg_integer().
-callback ecn_ce_counter(State :: term()) -> non_neg_integer().

%%====================================================================
%% Types
%%====================================================================

%% CC algorithm type
-type cc_algorithm() :: newreno | bbr | cubic.

%% CC options type for implementations
-type cc_opts() :: #{
    initial_window => pos_integer(),
    minimum_window => pos_integer(),
    min_recovery_duration => non_neg_integer(),
    max_datagram_size => pos_integer(),
    algorithm => cc_algorithm()
}.

%% Wrapper state that holds algorithm module and its state
-record(cc_wrapper, {
    algorithm :: module(),
    state :: term()
}).

-opaque cc_state() :: #cc_wrapper{}.

-export_type([cc_state/0, cc_opts/0, cc_algorithm/0]).

%%====================================================================
%% State Management
%%====================================================================

%% @doc Create a new congestion control state with default algorithm (NewReno).
-spec new() -> cc_state().
new() ->
    new(#{}).

%% @doc Create a new congestion control state with options.
%% Uses the algorithm specified in options, or NewReno by default.
%%
%% Options:
%%   - algorithm: CC algorithm (`newreno' | `bbr'), default: `newreno'
%%   - max_datagram_size: Maximum datagram size (default: 1200)
%%   - initial_window: Override initial congestion window
%%   - minimum_window: Lower bound for cwnd after congestion events
%%   - min_recovery_duration: Minimum time in recovery before exit (ms)
-spec new(cc_opts()) -> cc_state().
new(Opts) ->
    Algorithm = maps:get(algorithm, Opts, newreno),
    new(Algorithm, Opts).

%% @doc Create a new congestion control state with explicit algorithm.
%%
%% Algorithm: `newreno' | `bbr'
%% Options: Same as new/1 (algorithm option is ignored)
-spec new(cc_algorithm(), cc_opts()) -> cc_state().
new(Algorithm, Opts) ->
    Module = algorithm_to_module(Algorithm),
    %% Remove algorithm from opts before passing to implementation
    ImplOpts = maps:remove(algorithm, Opts),
    State = Module:new(ImplOpts),
    #cc_wrapper{
        algorithm = Module,
        state = State
    }.

%%====================================================================
%% Congestion Control Events
%%====================================================================

%% @doc Record that a packet was sent.
-spec on_packet_sent(cc_state(), non_neg_integer()) -> cc_state().
on_packet_sent(#cc_wrapper{algorithm = Mod, state = State} = W, Size) ->
    W#cc_wrapper{state = Mod:on_packet_sent(State, Size)}.

%% @doc Process acknowledged packets.
-spec on_packets_acked(cc_state(), non_neg_integer()) -> cc_state().
on_packets_acked(#cc_wrapper{algorithm = Mod, state = State} = W, AckedBytes) ->
    W#cc_wrapper{state = Mod:on_packets_acked(State, AckedBytes)}.

%% @doc Process acknowledged packets with largest acked sent time.
-spec on_packets_acked(cc_state(), non_neg_integer(), non_neg_integer()) -> cc_state().
on_packets_acked(
    #cc_wrapper{algorithm = Mod, state = State} = W, AckedBytes, LargestAckedSentTime
) ->
    W#cc_wrapper{state = Mod:on_packets_acked(State, AckedBytes, LargestAckedSentTime)}.

%% @doc Process lost packets.
-spec on_packets_lost(cc_state(), non_neg_integer()) -> cc_state().
on_packets_lost(#cc_wrapper{algorithm = Mod, state = State} = W, LostBytes) ->
    W#cc_wrapper{state = Mod:on_packets_lost(State, LostBytes)}.

%% @doc Handle a congestion event (packet loss detected).
-spec on_congestion_event(cc_state(), non_neg_integer()) -> cc_state().
on_congestion_event(#cc_wrapper{algorithm = Mod, state = State} = W, SentTime) ->
    W#cc_wrapper{state = Mod:on_congestion_event(State, SentTime)}.

%% @doc Handle ECN-CE signal.
-spec on_ecn_ce(cc_state(), non_neg_integer()) -> cc_state().
on_ecn_ce(#cc_wrapper{algorithm = Mod, state = State} = W, ECNCE) ->
    W#cc_wrapper{state = Mod:on_ecn_ce(State, ECNCE)}.

%% @doc Handle persistent congestion.
-spec on_persistent_congestion(cc_state()) -> cc_state().
on_persistent_congestion(#cc_wrapper{algorithm = Mod, state = State} = W) ->
    W#cc_wrapper{state = Mod:on_persistent_congestion(State)}.

%% @doc Detect persistent congestion from lost packets.
-spec detect_persistent_congestion(
    [{non_neg_integer(), non_neg_integer()}],
    non_neg_integer(),
    cc_state()
) -> boolean().
detect_persistent_congestion(LostInfo, PTO, #cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:detect_persistent_congestion(LostInfo, PTO, State).

%% @doc Update pacing rate based on smoothed RTT.
-spec update_pacing_rate(cc_state(), non_neg_integer()) -> cc_state().
update_pacing_rate(#cc_wrapper{algorithm = Mod, state = State} = W, SmoothedRTT) ->
    W#cc_wrapper{state = Mod:update_pacing_rate(State, SmoothedRTT)}.

%% @doc Update congestion control state when MTU changes.
-spec update_mtu(cc_state(), pos_integer()) -> cc_state().
update_mtu(#cc_wrapper{algorithm = Mod, state = State} = W, NewMTU) ->
    W#cc_wrapper{state = Mod:update_mtu(State, NewMTU)}.

%%====================================================================
%% Queries
%%====================================================================

%% @doc Get the current congestion window.
-spec cwnd(cc_state()) -> non_neg_integer().
cwnd(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:cwnd(State).

%% @doc Remove bytes for packets whose packet number space was
%% discarded. Not a congestion event: the packets were neither
%% acknowledged nor lost, they simply stopped existing, so the window
%% and recovery state are untouched (RFC 9002 Section 6.4).
-spec on_packets_discarded(cc_state(), non_neg_integer()) -> cc_state().
on_packets_discarded(#cc_wrapper{algorithm = Mod, state = State} = W, Bytes) ->
    W#cc_wrapper{state = Mod:on_packets_discarded(State, Bytes)}.

%% @doc Start the window over after a Retry (RFC 9002 Section 6.3),
%% keeping the algorithm, MTU and configured windows. Rebuilding the
%% controller instead would silently drop those.
-spec reset_for_retry(cc_state()) -> cc_state().
reset_for_retry(#cc_wrapper{algorithm = Mod, state = State} = W) ->
    W#cc_wrapper{state = Mod:reset_for_retry(State)}.

%% @doc The congestion window this controller was configured with.
%% cwnd evolves away from it, so a reset needs it to restore the
%% configured value rather than a hardcoded default.
-spec initial_window(cc_state()) -> non_neg_integer().
initial_window(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:initial_window(State).

%% @doc Get the slow start threshold.
-spec ssthresh(cc_state()) -> non_neg_integer() | infinity.
ssthresh(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:ssthresh(State).

%% @doc Get bytes currently in flight.
-spec bytes_in_flight(cc_state()) -> non_neg_integer().
bytes_in_flight(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:bytes_in_flight(State).

%% @doc Check if we can send more bytes.
-spec can_send(cc_state(), non_neg_integer()) -> boolean().
can_send(#cc_wrapper{algorithm = Mod, state = State}, Size) ->
    Mod:can_send(State, Size).

%% @doc Check if a control message can be sent.
-spec can_send_control(cc_state(), non_neg_integer()) -> boolean().
can_send_control(#cc_wrapper{algorithm = Mod, state = State}, Size) ->
    Mod:can_send_control(State, Size).

%% @doc Get the available congestion window.
-spec available_cwnd(cc_state()) -> non_neg_integer().
available_cwnd(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:available_cwnd(State).

%% @doc Check if in slow start phase.
-spec in_slow_start(cc_state()) -> boolean().
in_slow_start(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:in_slow_start(State).

%% @doc Check if in recovery phase.
-spec in_recovery(cc_state()) -> boolean().
in_recovery(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:in_recovery(State).

%% @doc Check if pacing allows sending.
-spec pacing_allows(cc_state(), non_neg_integer()) -> boolean().
pacing_allows(#cc_wrapper{algorithm = Mod, state = State}, Size) ->
    Mod:pacing_allows(State, Size).

%% @doc Get pacing tokens for sending.
-spec get_pacing_tokens(cc_state(), non_neg_integer()) -> {non_neg_integer(), cc_state()}.
get_pacing_tokens(#cc_wrapper{algorithm = Mod, state = State} = W, Size) ->
    {Allowed, NewState} = Mod:get_pacing_tokens(State, Size),
    {Allowed, W#cc_wrapper{state = NewState}}.

%% @doc Calculate pacing delay.
-spec pacing_delay(cc_state(), non_neg_integer()) -> non_neg_integer().
pacing_delay(#cc_wrapper{algorithm = Mod, state = State}, Size) ->
    Mod:pacing_delay(State, Size).

%% @doc Fused send check (cwnd + pacing) for the hot send path.
%% See the behavior callback for the return shape.
-spec send_check(cc_state(), non_neg_integer(), non_neg_integer()) ->
    {ok, cc_state()}
    | {blocked_cwnd, non_neg_integer()}
    | {blocked_pacing, non_neg_integer()}.
send_check(#cc_wrapper{algorithm = Mod, state = State} = W, Size, Urgency) ->
    case Mod:send_check(State, Size, Urgency) of
        {ok, NewState} -> {ok, W#cc_wrapper{state = NewState}};
        Other -> Other
    end.

%% @doc Batched send_check: approve up to MaxK packets of Size in one
%% pass. Native for newreno; other algorithms fold send_check/3 with
%% identical results.
-spec send_check_run(cc_state(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), cc_state()}.
send_check_run(
    #cc_wrapper{algorithm = quic_cc_newreno, state = State} = W, Size, MaxK, Urgency
) ->
    {K, NewState} = quic_cc_newreno:send_check_run(State, Size, MaxK, Urgency),
    {K, W#cc_wrapper{state = NewState}};
send_check_run(W, Size, MaxK, Urgency) ->
    send_check_run_iter(W, Size, MaxK, Urgency, 0).

send_check_run_iter(W, _Size, MaxK, _Urgency, K) when K >= MaxK ->
    {K, W};
send_check_run_iter(W, Size, MaxK, Urgency, K) ->
    case send_check(W, Size, Urgency) of
        {ok, W1} -> send_check_run_iter(W1, Size, MaxK, Urgency, K + 1);
        _ -> {K, W}
    end.

%% @doc Batched on_packet_sent for a run: one update for newreno, a
%% fold for other algorithms.
-spec on_packets_sent(cc_state(), [non_neg_integer()]) -> cc_state().
on_packets_sent(#cc_wrapper{algorithm = quic_cc_newreno, state = State} = W, Sizes) ->
    W#cc_wrapper{state = quic_cc_newreno:on_packets_sent(State, Sizes)};
on_packets_sent(W, Sizes) ->
    lists:foldl(fun(Size, Acc) -> on_packet_sent(Acc, Size) end, W, Sizes).

%% @doc Get the current max datagram size.
-spec max_datagram_size(cc_state()) -> pos_integer().
max_datagram_size(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:max_datagram_size(State).

%% @doc Get minimum recovery duration setting.
-spec min_recovery_duration(cc_state()) -> non_neg_integer().
min_recovery_duration(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:min_recovery_duration(State).

%% @doc Get the current ECN-CE counter.
-spec ecn_ce_counter(cc_state()) -> non_neg_integer().
ecn_ce_counter(#cc_wrapper{algorithm = Mod, state = State}) ->
    Mod:ecn_ce_counter(State).

%% @doc Get the algorithm name for this CC state.
-spec algorithm(cc_state()) -> cc_algorithm().
algorithm(#cc_wrapper{algorithm = Mod}) ->
    module_to_algorithm(Mod).

%%====================================================================
%% Internal Functions
%%====================================================================

%% Map algorithm atom to implementation module
-spec algorithm_to_module(cc_algorithm()) -> module().
algorithm_to_module(newreno) -> quic_cc_newreno;
algorithm_to_module(bbr) -> quic_cc_bbr;
algorithm_to_module(cubic) -> quic_cc_cubic.

%% Map implementation module to algorithm atom
-spec module_to_algorithm(module()) -> cc_algorithm().
module_to_algorithm(quic_cc_newreno) -> newreno;
module_to_algorithm(quic_cc_bbr) -> bbr;
module_to_algorithm(quic_cc_cubic) -> cubic.
