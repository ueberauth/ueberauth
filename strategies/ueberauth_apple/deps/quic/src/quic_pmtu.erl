%%% -*- erlang -*-
%%%
%%% QUIC Path MTU Discovery (DPLPMTUD)
%%% RFC 8899 - Packetization Layer Path MTU Discovery
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC Path MTU Discovery implementation.
%%%
%%% Implements Datagram Packetization Layer Path MTU Discovery (DPLPMTUD)
%%% to dynamically discover the optimal packet size for a path.
%%%
%%% == State Machine ==
%%%
%%% The PMTU discovery follows RFC 8899 states:
%%% <ul>
%%% <li>`disabled' - PMTU discovery not active</li>
%%% <li>`base' - Using base MTU (1200), ready to probe</li>
%%% <li>`searching' - Binary search for optimal MTU in progress</li>
%%% <li>`search_complete' - Found optimal MTU</li>
%%% <li>`error' - Black hole detected, fell back to base MTU</li>
%%% </ul>
%%%
%%% == Binary Search Algorithm ==
%%%
%%% The module uses binary search between 1200 and max_mtu,
%%% stopping when the search range is less than 10 bytes.
%%%

-module(quic_pmtu).

-include("quic.hrl").
-include_lib("kernel/include/logger.hrl").

-define(QUIC_LOG_META, #{domain => [erlang_quic, pmtu]}).

-export([
    %% State management
    new/0,
    new/1,

    %% Connection lifecycle
    on_connection_established/2,
    on_path_change/1,
    on_raise_timer/1,

    %% Probe lifecycle
    should_probe/1,
    create_probe_packet/2,
    on_probe_sent/2,
    on_probe_acked/3,
    on_probe_lost/3,
    on_probe_timeout/1,

    %% Black hole detection
    on_packet_lost/2,
    on_loss_event/2,
    on_ack_event/2,
    on_packet_acked/1,

    %% Queries
    current_mtu/1,
    is_enabled/1,
    get_state/1,
    get_generation/1,

    %% Timer management
    cancel_timers/1,
    set_probe_timer/2,
    set_raise_timer/2
]).

-type pmtu_opts() :: #{
    pmtu_enabled => boolean(),
    pmtu_max_mtu => pos_integer(),
    pmtu_probe_timeout => pos_integer(),
    pmtu_raise_interval => pos_integer()
}.

-export_type([pmtu_opts/0]).

%%====================================================================
%% State Management
%%====================================================================

%% @doc Create a new PMTU state with default settings.
-spec new() -> #pmtu_state{}.
new() ->
    new(#{}).

%% @doc Create a new PMTU state with options.
%%
%% Options:
%% - `pmtu_enabled': Enable PMTU discovery (default: true)
%% - `pmtu_max_mtu': Maximum MTU to probe (default: 1500)
%%
%% @param Opts Configuration options
%% @returns New PMTU state record
-spec new(pmtu_opts()) -> #pmtu_state{}.
new(Opts) ->
    Enabled = maps:get(pmtu_enabled, Opts, true),
    MaxMTU = maps:get(pmtu_max_mtu, Opts, 1500),
    BaseMTU = 1200,

    %% When disabled, set max_mtu = base_mtu to prevent probing
    %% on_connection_established will check if there's room to probe
    EffectiveMaxMTU =
        case Enabled of
            true -> MaxMTU;
            false -> BaseMTU
        end,

    #pmtu_state{
        state = disabled,
        base_mtu = BaseMTU,
        current_mtu = BaseMTU,
        max_mtu = EffectiveMaxMTU,
        search_min = BaseMTU,
        lost = [EffectiveMaxMTU, undefined, undefined],
        last_probe_lost = false,
        generation = 0
    }.

%%====================================================================
%% Connection Lifecycle
%%====================================================================

%% @doc Initialize PMTU probing after connection is established.
%%
%% Called when the QUIC handshake completes. Uses the peer's
%% `max_udp_payload_size' transport parameter to set the upper bound.
-spec on_connection_established(pos_integer() | undefined, #pmtu_state{}) -> #pmtu_state{}.
on_connection_established(PeerMax, #pmtu_state{max_mtu = ConfigMax, base_mtu = BaseMTU} = State) ->
    %% Determine effective max MTU
    EffectiveMax =
        case PeerMax of
            undefined -> ConfigMax;
            _ -> min(PeerMax, ConfigMax)
        end,

    %% Only enable probing if there's room to grow
    case EffectiveMax > BaseMTU of
        true ->
            ?LOG_DEBUG(
                #{
                    what => pmtu_enabled,
                    base_mtu => BaseMTU,
                    max_mtu => EffectiveMax,
                    peer_max => PeerMax,
                    config_max => ConfigMax
                },
                ?QUIC_LOG_META
            ),
            State#pmtu_state{
                state = base,
                max_mtu = EffectiveMax,
                lost = [EffectiveMax, undefined, undefined]
            };
        false ->
            %% No room to probe - stay disabled
            State
    end.

%% @doc Reset PMTU state on path change (connection migration).
%%
%% RFC 8899 Section 5.3.3: PMTU should be reset on path change
%% since the new path may have different MTU characteristics.
%%
%% @param PMTUState Current PMTU state
%% @returns Reset PMTU state at base MTU
-spec on_path_change(#pmtu_state{}) -> #pmtu_state{}.
on_path_change(#pmtu_state{state = disabled} = State) ->
    State;
on_path_change(#pmtu_state{base_mtu = BaseMTU, max_mtu = MaxMTU, generation = Gen} = State) ->
    %% Cancel any pending timers
    State1 = cancel_timers(State),
    ?LOG_DEBUG(
        #{
            what => pmtu_path_change,
            old_mtu => State#pmtu_state.current_mtu,
            new_mtu => BaseMTU,
            generation => Gen + 1
        },
        ?QUIC_LOG_META
    ),
    State1#pmtu_state{
        state = base,
        current_mtu = BaseMTU,
        probe_size = 0,
        probe_pn = undefined,
        search_min = BaseMTU,
        lost = [MaxMTU, undefined, undefined],
        last_probe_lost = false,
        generation = Gen + 1,
        black_hole_count = 0
    }.

%% @doc Handle raise timer expiration for periodic re-probing.
%%
%% Unlike on_path_change, this keeps current_mtu and probes higher.
%% Used for periodic attempts to increase MTU without dropping throughput.
%%
%% @param PMTUState Current PMTU state
%% @returns Updated PMTU state ready to probe upward
-spec on_raise_timer(#pmtu_state{}) -> #pmtu_state{}.
on_raise_timer(#pmtu_state{state = disabled} = State) ->
    State;
on_raise_timer(#pmtu_state{state = searching} = State) ->
    %% Already searching, just clear timer
    State#pmtu_state{raise_timer = undefined};
on_raise_timer(#pmtu_state{current_mtu = CurrentMTU, max_mtu = MaxMTU} = State) ->
    case CurrentMTU >= MaxMTU of
        true ->
            %% Already at max, nothing to probe
            State#pmtu_state{raise_timer = undefined};
        false ->
            %% Start probing from current MTU upward
            ?LOG_DEBUG(
                #{what => pmtu_raise_timer, current_mtu => CurrentMTU, max_mtu => MaxMTU},
                ?QUIC_LOG_META
            ),
            State#pmtu_state{
                state = searching,
                search_min = CurrentMTU,
                lost = [MaxMTU, undefined, undefined],
                last_probe_lost = false,
                probe_size = 0,
                probe_pn = undefined,
                raise_timer = undefined
            }
    end.

%%====================================================================
%% Probe Lifecycle
%%====================================================================

%% @doc Check if we should send a probe packet.
%%
%% Returns true if:
%% - State is `base' (ready to start probing)
%% - State is `searching' and no probe is in flight
%% - State is `error' and raise timer expired
%%
%% @param PMTUState Current PMTU state
%% @returns true if a probe should be sent
-spec should_probe(#pmtu_state{}) -> boolean().
should_probe(#pmtu_state{state = disabled}) ->
    false;
should_probe(#pmtu_state{state = base}) ->
    true;
should_probe(#pmtu_state{state = searching, probe_pn = undefined}) ->
    true;
should_probe(#pmtu_state{state = error, raise_timer = undefined}) ->
    %% Ready to re-probe after error recovery
    true;
should_probe(_) ->
    false.

%% @doc Create a probe packet (PING + PADDING frames).
%%
%% Creates a packet with PING frame and PADDING to reach the target size.
%% The probe size is calculated using binary search.
%%
%% @param PMTUState Current PMTU state
%% @param HeaderSize Size of packet headers (to account for in padding)
%% @returns {ProbeSize, Frames} where Frames is [ping, {padding, N}]
-spec create_probe_packet(#pmtu_state{}, pos_integer()) ->
    {pos_integer(), [term()]}.
create_probe_packet(#pmtu_state{state = State} = PMTUState, HeaderSize) when
    State =:= base; State =:= searching; State =:= error
->
    ProbeSize = next_probe_size(PMTUState),
    %% Calculate padding needed
    %% Packet = Header + PING (1 byte) + PADDING
    PingSize = 1,
    PaddingNeeded = max(0, ProbeSize - HeaderSize - PingSize),
    Frames = [ping, {padding, PaddingNeeded}],
    {ProbeSize, Frames};
create_probe_packet(PMTUState, _HeaderSize) ->
    %% Not in a probing state - return current MTU with empty frames
    {PMTUState#pmtu_state.current_mtu, []}.

%% @doc Record that a probe packet was sent.
%%
%% @param PacketNumber Packet number of the sent probe
%% @param PMTUState Current PMTU state
%% @returns {Generation, UpdatedPMTUState} tuple with generation for tracking
-spec on_probe_sent(non_neg_integer(), #pmtu_state{}) -> {non_neg_integer(), #pmtu_state{}}.
on_probe_sent(PacketNumber, #pmtu_state{state = State, generation = Gen} = PMTUState) when
    State =:= base; State =:= error
->
    ProbeSize = next_probe_size(PMTUState),
    ?LOG_DEBUG(
        #{
            what => pmtu_probe_sent,
            pn => PacketNumber,
            probe_size => ProbeSize,
            state => State,
            generation => Gen
        },
        ?QUIC_LOG_META
    ),
    {Gen, PMTUState#pmtu_state{
        state = searching,
        probe_size = ProbeSize,
        probe_pn = PacketNumber
    }};
on_probe_sent(
    PacketNumber, #pmtu_state{state = searching, probe_size = 0, generation = Gen} = PMTUState
) ->
    %% Starting a new probe after previous succeeded
    ProbeSize = next_probe_size(PMTUState),
    ?LOG_DEBUG(
        #{
            what => pmtu_probe_sent,
            pn => PacketNumber,
            probe_size => ProbeSize,
            state => searching,
            generation => Gen
        },
        ?QUIC_LOG_META
    ),
    {Gen, PMTUState#pmtu_state{
        probe_size = ProbeSize,
        probe_pn = PacketNumber
    }};
on_probe_sent(PacketNumber, #pmtu_state{state = searching, generation = Gen} = PMTUState) ->
    %% Retrying a probe that was lost or timed out
    ProbeSize = PMTUState#pmtu_state.probe_size,
    ?LOG_DEBUG(
        #{
            what => pmtu_probe_retry,
            pn => PacketNumber,
            probe_size => ProbeSize,
            generation => Gen
        },
        ?QUIC_LOG_META
    ),
    {Gen, PMTUState#pmtu_state{probe_pn = PacketNumber}};
on_probe_sent(_PacketNumber, #pmtu_state{generation = Gen} = PMTUState) ->
    {Gen, PMTUState}.

%% @doc Handle probe packet ACK.
%%
%% Called when the probe packet is acknowledged.
%% On success, updates search bounds and MTU using the loss array algorithm.
%%
%% @param PacketNumber Packet number that was ACKed
%% @param Generation Generation when probe was sent (for stale detection)
%% @param PMTUState Current PMTU state
%% @returns Updated PMTU state
-spec on_probe_acked(non_neg_integer(), non_neg_integer(), #pmtu_state{}) -> #pmtu_state{}.
on_probe_acked(
    PacketNumber,
    Gen,
    #pmtu_state{
        state = searching,
        probe_pn = PacketNumber,
        generation = Gen
    } = PMTUState
) ->
    #pmtu_state{probe_size = ProbeSize, lost = Lost} = PMTUState,

    %% Probe succeeded - update search_min and remove smaller losses
    NewLost = remove_losses_below(ProbeSize, Lost),

    ?LOG_DEBUG(
        #{
            what => pmtu_probe_acked,
            pn => PacketNumber,
            probe_size => ProbeSize,
            new_mtu => ProbeSize,
            generation => Gen
        },
        ?QUIC_LOG_META
    ),

    State1 = PMTUState#pmtu_state{
        search_min = ProbeSize,
        current_mtu = ProbeSize,
        lost = NewLost,
        last_probe_lost = false,
        probe_size = 0,
        probe_pn = undefined,
        black_hole_count = 0
    },

    case search_done(State1) of
        true ->
            ?LOG_INFO(
                #{what => pmtu_search_complete, final_mtu => ProbeSize},
                ?QUIC_LOG_META
            ),
            State1#pmtu_state{state = search_complete};
        false ->
            State1
    end;
on_probe_acked(PacketNumber, Gen, #pmtu_state{generation = CurrentGen} = PMTUState) when
    Gen =/= CurrentGen
->
    %% Stale ACK from previous generation - ignore
    ?LOG_DEBUG(
        #{
            what => pmtu_probe_acked_stale,
            pn => PacketNumber,
            probe_gen => Gen,
            current_gen => CurrentGen
        },
        ?QUIC_LOG_META
    ),
    PMTUState;
on_probe_acked(_PacketNumber, _Gen, PMTUState) ->
    %% Not our probe packet
    PMTUState.

%% @doc Handle probe packet loss.
%%
%% Called when the probe packet is detected as lost.
%% Uses loss array algorithm: inserts loss into array and adjusts search.
%%
%% @param PacketNumber Packet number that was lost
%% @param Generation Generation when probe was sent (for stale detection)
%% @param PMTUState Current PMTU state
%% @returns Updated PMTU state
-spec on_probe_lost(non_neg_integer(), non_neg_integer(), #pmtu_state{}) -> #pmtu_state{}.
on_probe_lost(
    PacketNumber,
    Gen,
    #pmtu_state{
        state = searching,
        probe_pn = PacketNumber,
        generation = Gen
    } = PMTUState
) ->
    #pmtu_state{probe_size = ProbeSize, lost = Lost, search_min = Min} = PMTUState,

    ?LOG_DEBUG(
        #{
            what => pmtu_probe_lost,
            pn => PacketNumber,
            probe_size => ProbeSize,
            generation => Gen
        },
        ?QUIC_LOG_META
    ),

    %% Insert this size into loss array
    NewLost = insert_loss(ProbeSize, Lost),

    State1 = PMTUState#pmtu_state{
        lost = NewLost,
        last_probe_lost = true,
        probe_pn = undefined,
        probe_size = 0
    },

    case search_done(State1) of
        true ->
            ?LOG_INFO(
                #{what => pmtu_search_complete, final_mtu => Min},
                ?QUIC_LOG_META
            ),
            State1#pmtu_state{state = search_complete, current_mtu = Min};
        false ->
            State1
    end;
on_probe_lost(PacketNumber, Gen, #pmtu_state{generation = CurrentGen} = PMTUState) when
    Gen =/= CurrentGen
->
    %% Stale loss from previous generation - ignore
    ?LOG_DEBUG(
        #{
            what => pmtu_probe_lost_stale,
            pn => PacketNumber,
            probe_gen => Gen,
            current_gen => CurrentGen
        },
        ?QUIC_LOG_META
    ),
    PMTUState;
on_probe_lost(_PacketNumber, _Gen, PMTUState) ->
    PMTUState.

%% @doc Handle probe timeout.
%%
%% Called when the probe timer fires.
%% Treats timeout as loss and uses loss array algorithm.
%%
%% @param PMTUState Current PMTU state
%% @returns Updated PMTU state
-spec on_probe_timeout(#pmtu_state{}) -> #pmtu_state{}.
on_probe_timeout(#pmtu_state{state = searching} = PMTUState) ->
    #pmtu_state{
        probe_size = ProbeSize,
        lost = Lost,
        search_min = Min,
        probe_pn = ProbePn
    } = PMTUState,

    ?LOG_DEBUG(
        #{what => pmtu_probe_timeout, probe_size => ProbeSize},
        ?QUIC_LOG_META
    ),

    State1 = PMTUState#pmtu_state{probe_timer = undefined},

    case ProbePn of
        undefined ->
            %% No probe in flight
            State1;
        _ ->
            %% Treat timeout as loss - insert into loss array
            NewLost = insert_loss(ProbeSize, Lost),
            State2 = State1#pmtu_state{
                lost = NewLost,
                last_probe_lost = true,
                probe_pn = undefined,
                probe_size = 0
            },
            case search_done(State2) of
                true ->
                    State2#pmtu_state{state = search_complete, current_mtu = Min};
                false ->
                    State2
            end
    end;
on_probe_timeout(PMTUState) ->
    PMTUState#pmtu_state{probe_timer = undefined}.

%%====================================================================
%% Black Hole Detection
%%====================================================================

%% @doc Track packet loss for black hole detection.
%%
%% Only counts losses of packets near the current MTU size (within 100 bytes).
%% Small packet losses are not indicative of MTU black holes.
%%
%% @param PacketSize Size of the lost packet
%% @param PMTUState Current PMTU state
%% @returns Updated PMTU state, possibly in error state
-spec on_packet_lost(pos_integer(), #pmtu_state{}) -> #pmtu_state{}.
on_packet_lost(PacketSize, State) ->
    on_loss_event([PacketSize], State).

%% @doc One loss event (one ACK's worth of newly declared losses) with
%% the sizes of the packets it lost. Counts as one black-hole strike
%% when any of them was large: a burst of tens of full-size packets
%% lost together, the normal shape of congestion or queue loss, is one
%% signal, not one per packet. Black hole detection is looking for a
%% path that has stopped passing large packets, not a lossy one.
-spec on_loss_event([pos_integer()], #pmtu_state{}) -> #pmtu_state{}.
on_loss_event(_Sizes, #pmtu_state{state = disabled} = State) ->
    State;
on_loss_event(Sizes, #pmtu_state{state = search_complete, current_mtu = CurrentMTU} = State) ->
    %% Only large packets (within 100 bytes of the current MTU) count.
    case [S || S <- Sizes, S >= CurrentMTU - 100] of
        [PacketSize | _] ->
            #pmtu_state{
                black_hole_count = Count,
                black_hole_threshold = Threshold,
                base_mtu = BaseMTU,
                max_mtu = MaxMTU
            } = State,
            NewCount = Count + 1,
            case NewCount >= Threshold of
                true ->
                    %% Black hole detected - fall back to base MTU
                    ?LOG_WARNING(
                        #{
                            what => pmtu_black_hole_detected,
                            losses => NewCount,
                            packet_size => PacketSize,
                            old_mtu => CurrentMTU,
                            new_mtu => BaseMTU
                        },
                        ?QUIC_LOG_META
                    ),
                    State1 = cancel_timers(State),
                    State1#pmtu_state{
                        state = error,
                        current_mtu = BaseMTU,
                        search_min = BaseMTU,
                        lost = [MaxMTU, undefined, undefined],
                        last_probe_lost = false,
                        black_hole_count = 0,
                        probe_size = 0,
                        probe_pn = undefined
                    };
                false ->
                    State#pmtu_state{black_hole_count = NewCount}
            end;
        [] ->
            %% Small packet losses are not indicative of an MTU black hole
            State
    end;
on_loss_event(_Sizes, State) ->
    State.

%% @doc Reset black hole counter on successful ACK.
-spec on_packet_acked(#pmtu_state{}) -> #pmtu_state{}.
on_packet_acked(#pmtu_state{black_hole_count = 0} = State) ->
    State;
on_packet_acked(State) ->
    State#pmtu_state{black_hole_count = 0}.

%% @doc One ACK event with the sizes of the packets it acknowledged. A
%% large packet getting through proves the path still passes them, so
%% the strike count restarts; ACKs of small packets say nothing about
%% it and leave the count alone.
-spec on_ack_event([pos_integer()], #pmtu_state{}) -> #pmtu_state{}.
on_ack_event(_Sizes, #pmtu_state{black_hole_count = 0} = State) ->
    State;
on_ack_event(Sizes, #pmtu_state{current_mtu = CurrentMTU} = State) ->
    case lists:any(fun(S) -> S >= CurrentMTU - 100 end, Sizes) of
        true -> on_packet_acked(State);
        false -> State
    end.

%%====================================================================
%% Queries
%%====================================================================

%% @doc Get the current effective MTU.
-spec current_mtu(#pmtu_state{}) -> pos_integer().
current_mtu(#pmtu_state{current_mtu = MTU}) ->
    MTU.

%% @doc Check if PMTU discovery is enabled.
-spec is_enabled(#pmtu_state{}) -> boolean().
is_enabled(#pmtu_state{state = disabled}) ->
    false;
is_enabled(_) ->
    true.

%% @doc Get the current state.
-spec get_state(#pmtu_state{}) -> disabled | base | searching | search_complete | error.
get_state(#pmtu_state{state = State}) ->
    State.

%% @doc Get the current generation.
-spec get_generation(#pmtu_state{}) -> non_neg_integer().
get_generation(#pmtu_state{generation = Gen}) ->
    Gen.

%%====================================================================
%% Timer Management
%%====================================================================

%% @doc Cancel all pending timers.
-spec cancel_timers(#pmtu_state{}) -> #pmtu_state{}.
cancel_timers(#pmtu_state{probe_timer = ProbeTimer, raise_timer = RaiseTimer} = State) ->
    cancel_timer(ProbeTimer),
    cancel_timer(RaiseTimer),
    State#pmtu_state{
        probe_timer = undefined,
        raise_timer = undefined
    }.

%% @doc Set the probe timeout timer.
-spec set_probe_timer(reference(), #pmtu_state{}) -> #pmtu_state{}.
set_probe_timer(TimerRef, State) ->
    cancel_timer(State#pmtu_state.probe_timer),
    State#pmtu_state{probe_timer = TimerRef}.

%% @doc Set the raise timer for periodic re-probing.
-spec set_raise_timer(reference(), #pmtu_state{}) -> #pmtu_state{}.
set_raise_timer(TimerRef, State) ->
    cancel_timer(State#pmtu_state.raise_timer),
    State#pmtu_state{raise_timer = TimerRef}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Get effective max from loss array (first defined value).
%% The loss array is sorted ascending, so the first defined value is the smallest loss.
-spec get_max(#pmtu_state{}) -> pos_integer().
get_max(#pmtu_state{lost = Lost}) ->
    hd([V || V <- Lost, V =/= undefined]).

%% @private Check if search is done (within threshold).
-spec search_done(#pmtu_state{}) -> boolean().
search_done(#pmtu_state{search_min = Min} = State) ->
    Max = get_max(State),
    Max - Min =< ?PMTU_SEARCH_THRESHOLD.

%% @private Calculate the next probe size using the quic-go loss array algorithm.
%% If last probe was lost: probe (search_min + lost[0]) / 2
%% Otherwise: probe (search_min + get_max()) / 2
-spec next_probe_size(#pmtu_state{}) -> pos_integer().
next_probe_size(#pmtu_state{state = searching, probe_size = ProbeSize}) when ProbeSize > 0 ->
    %% In active search - use current probe size
    ProbeSize;
next_probe_size(#pmtu_state{search_min = Min, last_probe_lost = true, lost = [Lost0 | _]}) when
    Lost0 =/= undefined
->
    %% After loss, probe between min and smallest loss point
    (Min + Lost0) div 2;
next_probe_size(#pmtu_state{search_min = Min} = State) ->
    %% Normal case: probe between min and max
    Max = get_max(State),
    (Min + Max) div 2.

%% @private Insert loss into array (sorted ascending, max 3 elements).
%% This implements the quic-go pattern where we track up to 3 loss points.
-spec insert_loss(pos_integer(), [pos_integer() | undefined]) -> [pos_integer() | undefined].
insert_loss(Size, Lost) ->
    Defined = [V || V <- Lost, V =/= undefined],
    %% Insert and sort
    Sorted = lists:sort([Size | Defined]),
    %% Keep only first 3 (smallest values)
    Trimmed = lists:sublist(Sorted, 3),
    %% Pad to 3 elements with undefined
    Trimmed ++ lists:duplicate(3 - length(Trimmed), undefined).

%% @private Remove losses smaller than confirmed size.
%% When a probe succeeds at size S, all losses < S are no longer relevant.
-spec remove_losses_below(pos_integer(), [pos_integer() | undefined]) ->
    [pos_integer() | undefined].
remove_losses_below(Size, Lost) ->
    Filtered = [V || V <- Lost, V =/= undefined, V > Size],
    Filtered ++ lists:duplicate(3 - length(Filtered), undefined).

%% @private Cancel a timer if it's set.
-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(undefined) ->
    ok;
cancel_timer(TimerRef) ->
    erlang:cancel_timer(TimerRef),
    ok.
