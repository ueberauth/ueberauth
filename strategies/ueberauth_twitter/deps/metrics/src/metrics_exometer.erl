%%% -*- erlang -*-
%%%
%%% This file is part of metrics released under the BSD license.
%%% See the LICENSE for more information.
%%%
%%% @doc metrics module for exometer
-module(metrics_exometer).


-export([
    new/2,
    delete/1,
    increment_counter/1,
    increment_counter/2,
    decrement_counter/1,
    decrement_counter/2,
    update_histogram/2,
    update_gauge/2,
    update_meter/2]).

-spec new(atom(), any()) -> ok | {error, metric_exists | unsupported_type}.
new(counter, Name) ->
    exometer:ensure(Name, counter, []);
new(histogram, Name) ->
    exometer:ensure(Name, histogram, []);
new(gauge, Name) ->
    exometer:ensure(Name, gauge, []);
new(meter, Name) ->
    exometer:ensure(Name, meter, []);
new(_, _) ->
    {error, unsupported_type}.

delete(Name) ->
    exometer:delete(Name).

-spec increment_counter(any()) -> ok | {error, term()}.
increment_counter(Name) ->
    notify(Name, 1, counter).

-spec increment_counter(any(), pos_integer()) ->  ok | {error, term()}.
increment_counter(Name, Value) ->
    notify(Name, Value, counter).

-spec decrement_counter(any()) ->  ok | {error, term()}.
decrement_counter(Name) ->
    notify(Name, -1, counter).

-spec decrement_counter(any(), pos_integer()) ->  ok | {error, term()}.
decrement_counter(Name, Value) ->
    notify(Name, -Value, counter).

-spec update_histogram(any(), number()) ->  ok | {error, term()};
                      (any(), function()) ->  ok | {error, term()}.
update_histogram(Name, Fun) when is_function(Fun, 0) ->
    Begin = os:timestamp(),
    Result = Fun(),
    Duration = timer:now_diff(os:timestamp(), Begin) div 1000,
    case notify(Name, Duration, histogram) of
        ok -> Result;
        Error -> throw(Error)
    end;
update_histogram(Name, Value) when is_number(Value) ->
    notify(Name, Value, histogram).

-spec update_gauge(any(), number()) ->  ok | {error, term()}.
update_gauge(Name, Value) ->
    notify(Name, Value, gauge).

-spec update_meter(any(), number()) ->  ok | {error, term()}.
update_meter(Name, Value) ->
    notify(Name, Value, meter).



-spec notify(any(), any(), atom()) ->  ok | {error, term()}.
notify(Name, Op, Type) ->
    exometer:update_or_create(Name, Op, Type, []).
