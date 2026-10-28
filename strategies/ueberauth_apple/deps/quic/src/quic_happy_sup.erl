%%% -*- erlang -*-
%%%
%%% Dynamic supervisor for Happy Eyeballs coordinator processes. One
%%% coordinator runs per multi-address connect; children are temporary
%%% and identified by a unique reference.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-module(quic_happy_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/1, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a supervised coordinator. `Args' is the argument list for
%% `quic_happy:start_coordinator/1'. Returns the coordinator pid.
-spec start_child(list()) -> {ok, pid()} | {error, term()}.
start_child(Args) ->
    Spec = #{
        id => {quic_happy, make_ref()},
        start => {quic_happy, start_coordinator, Args},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [quic_happy]
    },
    supervisor:start_child(?MODULE, Spec).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.
