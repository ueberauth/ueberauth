%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%%
%%% @doc Per-host connection load regulation using ETS counting semaphore.
%%%
%%% This module provides per-host connection limits using an atomic
%%% counting semaphore pattern. It tracks the number of active connections
%%% per {Host, Port} and blocks new requests when the limit is reached.
%%%
%%% Usage:
%%% ```
%%% case hackney_load_regulation:acquire(Host, Port, MaxPerHost, Timeout) of
%%%     ok ->
%%%         try
%%%             %% Do work with connection
%%%         after
%%%             hackney_load_regulation:release(Host, Port)
%%%         end;
%%%     {error, timeout} ->
%%%         {error, checkout_timeout}
%%% end.
%%% '''

-module(hackney_load_regulation).

%% API
-export([
    init/0,
    acquire/4,
    release/2,
    current/2,
    reset/2
]).

-define(TABLE, hackney_host_limits).
-define(BACKOFF_MS, 10).

%%====================================================================
%% API
%%====================================================================

%% @doc Initialize the load regulation ETS table.
%% Should be called once during application startup.
-spec init() -> ok.
init() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ?TABLE = ets:new(?TABLE, [
                public,
                set,
                named_table,
                {write_concurrency, true},
                {read_concurrency, true}
            ]),
            ok;
        _Tid ->
            ok
    end.

%% @doc Acquire a slot for the given host.
%% Blocks with exponential backoff until a slot is available or timeout.
%% Returns ok if slot acquired, {error, timeout} otherwise.
-spec acquire(Host :: string() | binary(), Port :: inet:port_number(),
              MaxPerHost :: pos_integer(), Timeout :: timeout()) ->
    ok | {error, timeout}.
acquire(Host, Port, MaxPerHost, Timeout) ->
    Key = normalize_key(Host, Port),
    Deadline = deadline(Timeout),
    acquire_loop(Key, MaxPerHost, Deadline).

%% @doc Release a slot for the given host.
%% Should always be called after acquire, typically in an after block.
-spec release(Host :: string() | binary(), Port :: inet:port_number()) -> ok.
release(Host, Port) ->
    Key = normalize_key(Host, Port),
    try
        _ = ets:update_counter(?TABLE, Key, {2, -1, 0, 0}),
        ok
    catch
        error:badarg ->
            %% Key doesn't exist, nothing to release
            ok
    end.

%% @doc Get the current number of active connections for a host.
-spec current(Host :: string() | binary(), Port :: inet:port_number()) ->
    non_neg_integer().
current(Host, Port) ->
    Key = normalize_key(Host, Port),
    case ets:lookup(?TABLE, Key) of
        [{_, Count}] -> max(0, Count);
        [] -> 0
    end.

%% @doc Reset the counter for a host (for testing).
-spec reset(Host :: string() | binary(), Port :: inet:port_number()) -> ok.
reset(Host, Port) ->
    Key = normalize_key(Host, Port),
    ets:delete(?TABLE, Key),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private Normalize host to lowercase binary for consistent keys.
normalize_key(Host, Port) when is_list(Host) ->
    normalize_key(list_to_binary(Host), Port);
normalize_key(Host, Port) when is_binary(Host) ->
    {string:lowercase(Host), Port}.

%% @private Calculate deadline from timeout.
deadline(infinity) ->
    infinity;
deadline(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout.

%% @private Check if deadline has passed.
check_deadline(infinity) ->
    ok;
check_deadline(Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> ok;
        false -> timeout
    end.

%% @private Main acquire loop with backoff.
acquire_loop(Key, Max, Deadline) ->
    %% Atomically increment counter, creating entry if needed
    Count = ets:update_counter(?TABLE, Key, {2, 1}, {Key, 0}),
    case Count =< Max of
        true ->
            %% Got a slot
            ok;
        false ->
            %% Over limit - decrement back and retry
            _ = ets:update_counter(?TABLE, Key, {2, -1}),
            case check_deadline(Deadline) of
                ok ->
                    timer:sleep(?BACKOFF_MS),
                    acquire_loop(Key, Max, Deadline);
                timeout ->
                    {error, timeout}
            end
    end.
