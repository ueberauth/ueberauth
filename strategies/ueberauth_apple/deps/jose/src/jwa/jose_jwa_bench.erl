%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: nil; st-rulers: [132] -*-
%% vim: ts=4 sw=4 ft=erlang et
%%% % @format
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  06 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_bench).

%% API
-export([bench/2]).
-export([bench/3]).
-export([compare/3]).

%% Records
-record(stat, {
    acc = 0 :: non_neg_integer(),
    min = 0 :: non_neg_integer(),
    max = 0 :: non_neg_integer()
}).

%% Types
-type arguments_list(Type) :: [Type].
-type arguments_function(Type) ::
    fun(() -> arguments_list(Type)).
-type arguments(Type) :: arguments_function(Type) | arguments_list(Type).
-type arguments() :: arguments(term()).

-export_type([arguments/1]).
-export_type([arguments/0]).

-type metric() :: #{
    acc := non_neg_integer(),
    avg := float(),
    min := non_neg_integer(),
    max := non_neg_integer()
}.

-export_type([metric/0]).

-type stats() :: #{
    reds := metric(),
    time := metric()
}.

-export_type([stats/0]).

%%====================================================================
%% API
%%====================================================================

-spec bench(function(), arguments()) -> stats().
bench(Function, Arguments) ->
    bench(Function, Arguments, 1).

-spec bench(function(), arguments(), non_neg_integer()) -> stats().
bench(Function, Arguments, N) when
    is_function(Function) andalso
        (is_list(Arguments) orelse is_function(Arguments, 0)) andalso
        (is_integer(N) andalso N > 0)
->
    {Time, Reds} = bench_loop(N, erlang:self(), #stat{}, #stat{}, Function, Arguments),
    #{
        time => stat_final(Time, N),
        reds => stat_final(Reds, N)
    }.

-spec compare([{atom(), function()}], arguments(), non_neg_integer()) -> [{atom(), stats()}].
compare(Groups, Arguments, N) when
    is_list(Groups) andalso
        (is_list(Arguments) orelse is_function(Arguments, 0)) andalso
        (is_integer(N) andalso N > 0)
->
    ResolvedArguments = resolve(Arguments),
    [
        begin
            {Label, bench(Function, ResolvedArguments, N)}
        end
     || {Label, Function} <- Groups, is_atom(Label) andalso is_function(Function)
    ].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
bench_loop(0, _Self, Time, Reds, _Function, _Arguments) ->
    {Time, Reds};
bench_loop(I, Self, Time0, Reds0, Function, Arguments) ->
    Args = resolve(Arguments),
    T1 = erlang:monotonic_time(microsecond),
    {reductions, R1} = erlang:process_info(Self, reductions),
    _ = erlang:apply(Function, Args),
    {reductions, R2} = erlang:process_info(Self, reductions),
    T2 = erlang:monotonic_time(microsecond),
    Time1 = stat_update(Time0, T2 - T1),
    Reds1 = stat_update(Reds0, R2 - R1),
    bench_loop(I - 1, Self, Time1, Reds1, Function, Arguments).

%% @private
resolve(Arguments) when is_function(Arguments, 0) ->
    resolve(Arguments());
resolve(Arguments) when is_list(Arguments) ->
    Arguments.

%% @private
stat_final(#stat{acc = Acc, min = Min, max = Max}, N) ->
    #{
        acc => Acc,
        avg => (Acc / N),
        min => Min,
        max => Max
    }.

%% @private
stat_update(Stat = #stat{acc = Acc, min = Min, max = Max}, Val) ->
    Stat#stat{
        acc = Acc + Val,
        min =
            case Val < Min of
                _ when Min =:= 0 ->
                    Val;
                true ->
                    Val;
                false ->
                    Min
            end,
        max =
            case Val > Max of
                true ->
                    Val;
                false ->
                    Max
            end
    }.
