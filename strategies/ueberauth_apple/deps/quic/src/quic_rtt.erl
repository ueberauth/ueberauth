%%% -*- erlang -*-
%%%
%%% QUIC RTT estimation (RFC 9002 Section 5).
%%%
%%% The estimate belongs to the path, not to a packet number space: a
%%% sample taken from an Initial acknowledgement moves the same numbers
%%% the application space reads. That is why it sits beside the
%%% per-space loss state rather than inside it.
%%%
%%% The caller decides how much of the peer's reported ACK delay to
%%% subtract before calling update/3. That cap depends on handshake
%%% confirmation and on the peer's max_ack_delay, which are loss
%%% detection's business, not the estimator's.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
-module(quic_rtt).

-export([
    new/0,
    new/1,
    reset/1,
    update/3,
    latest/1,
    smoothed/1,
    var/1,
    min/1,
    has_sample/1
]).

-export_type([state/0]).

%% RFC 9002 default is 333ms, but 100ms is more aggressive for faster ramp-up
-define(DEFAULT_INITIAL_RTT, 100).

-record(rtt_state, {
    latest = 0 :: non_neg_integer(),
    smoothed = ?DEFAULT_INITIAL_RTT :: non_neg_integer(),
    var = ?DEFAULT_INITIAL_RTT div 2 :: non_neg_integer(),
    min = infinity :: non_neg_integer() | infinity,
    %% Until the first real sample arrives the values above are the
    %% defaults, and the first sample replaces them outright rather than
    %% being averaged into them (RFC 9002 Section 5.2).
    first_sample = false :: boolean()
}).

-opaque state() :: #rtt_state{}.

-spec new() -> state().
new() ->
    new(?DEFAULT_INITIAL_RTT).

-spec new(non_neg_integer()) -> state().
new(InitialRTT) ->
    #rtt_state{smoothed = InitialRTT, var = InitialRTT div 2}.

%% @doc Forget the estimate. A new path has its own characteristics, and
%% carrying the old one over sizes probes for a route that is gone
%% (RFC 9002 Section 9.4).
-spec reset(state()) -> state().
reset(#rtt_state{}) ->
    new().

%% @doc Take a sample. `AckDelay' is what the caller has already decided
%% to subtract, in milliseconds.
-spec update(state(), non_neg_integer(), non_neg_integer()) -> state().
update(#rtt_state{first_sample = false}, LatestRTT, _AckDelay) ->
    #rtt_state{
        latest = LatestRTT,
        smoothed = LatestRTT,
        var = LatestRTT div 2,
        min = LatestRTT,
        first_sample = true
    };
update(#rtt_state{smoothed = SRTT, var = RTTVAR, min = MinRTT} = State, LatestRTT, AckDelay) ->
    NewMinRTT = erlang:min(MinRTT, LatestRTT),
    %% Only subtract the delay when doing so leaves the sample above the
    %% minimum: below that it is noise, not the peer's delay.
    AdjustedRTT =
        case LatestRTT >= NewMinRTT + AckDelay of
            true -> LatestRTT - AckDelay;
            false -> LatestRTT
        end,
    %% rttvar = 3/4 * rttvar + 1/4 * |smoothed_rtt - adjusted_rtt|
    %% smoothed_rtt = 7/8 * smoothed_rtt + 1/8 * adjusted_rtt
    State#rtt_state{
        latest = LatestRTT,
        smoothed = (7 * SRTT + AdjustedRTT) div 8,
        var = (3 * RTTVAR + abs(SRTT - AdjustedRTT)) div 4,
        min = NewMinRTT
    }.

-spec latest(state()) -> non_neg_integer().
latest(#rtt_state{latest = L}) -> L.

-spec smoothed(state()) -> non_neg_integer().
smoothed(#rtt_state{smoothed = S}) -> S.

-spec var(state()) -> non_neg_integer().
var(#rtt_state{var = V}) -> V.

-spec min(state()) -> non_neg_integer() | infinity.
min(#rtt_state{min = M}) -> M.

%% @doc Whether a real sample has arrived, as opposed to the defaults.
-spec has_sample(state()) -> boolean().
has_sample(#rtt_state{first_sample = F}) -> F.
