%%% -*- erlang -*-
%%%
%%% This file is part of metrics released under the BSD license.
%%% See the LICENSE for more information.
%%%

-module('metrics').

%% API exports
-export([init/1]).
-export([
    new/3,
    delete/2,
    increment_counter/2,
    increment_counter/3,
    decrement_counter/2,
    decrement_counter/3,
    update_histogram/3,
    update_gauge/3,
    update_meter/3]).


-record(metrics_ng, {mod}).

-type metrics_engine() :: #metrics_ng{}.
-type metric() :: counter | histogram | gauge | meter.

-export_types([metrics_engine/0,
               metric/0]).

%%====================================================================
%% API functions
%%====================================================================

%% @doc set the module to use for metrics.
%% Types are: counter, histograme, gauge, meter
%%
%% modules supported are:
%% <ul>
%% <li>`metrics_folsom': to interface folsom</li>
%% <li>`metrics_exometer': to interface to exometer</li>
%% <li>`metrics_dummy': a dummy module to use by default.</li>
%% </ul>
-spec init(Mod :: atom()) -> metrics_engine().
init(Mod) ->
    %% check the module
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, new, 2) of
        false ->
            error(badarg);
        true ->
            ok
    end,
    #metrics_ng{mod=Mod}.


%% @doc create a new metric
-spec new(metrics_engine(), metric(), any()) -> ok | {error, term()}.
new(#metrics_ng{mod=Mod}, Type, Name) ->
    Mod:new(Type, Name).

%% @doc delete a metric
-spec delete(metrics_engine(), any()) -> ok.
delete(#metrics_ng{mod=Mod}, Name) ->
    Mod:delete(Name).


%% @doc increment a counter with 1
-spec increment_counter(metrics_engine(), any()) -> ok | {error, term()}.
increment_counter(#metrics_ng{mod=Mod}, Name) ->
    Mod:increment_counter(Name).

%% @doc increment a counter with Value
-spec increment_counter(metrics_engine(), any(), pos_integer()) ->  ok | {error, term()}.
increment_counter(#metrics_ng{mod=Mod}, Name, Value) ->
    Mod:increment_counter(Name, Value).

%% @doc decrement a counter with 1
-spec decrement_counter(metrics_engine(), any()) ->  ok | {error, term()}.
decrement_counter(#metrics_ng{mod=Mod}, Name) ->
    Mod:decrement_counter(Name).

%% @doc decrement a counter with value
-spec decrement_counter(metrics_engine(), any(), pos_integer()) ->  ok | {error, term()}.
decrement_counter(#metrics_ng{mod=Mod}, Name, Value) ->
    Mod:decrement_counter(Name, Value).


%% @doc update an histogram with a value or the duration of a function. When
%% passing a function the result will be returned once the metric have been
%% updated with the duration.
-spec update_histogram
        (metrics_engine(), any(), number()) ->  ok | {error, term()};
        (metrics_engine(), any(), function()) ->  ok | {error, term()}.
update_histogram(#metrics_ng{mod=Mod}, Name, ValueOrFun) ->
    Mod:update_histogram(Name, ValueOrFun).

%% @doc update a gauge with a value
-spec update_gauge(metrics_engine(), any(), number()) ->  ok | {error, term()}.
update_gauge(#metrics_ng{mod=Mod}, Name, Value) ->
    Mod:update_gauge(Name, Value).

%% @doc update a meter with a valyue
-spec update_meter(metrics_engine(), any(), number()) ->  ok | {error, term()}.
update_meter(#metrics_ng{mod=Mod}, Name, Value) ->
    Mod:update_meter(Name, Value).
