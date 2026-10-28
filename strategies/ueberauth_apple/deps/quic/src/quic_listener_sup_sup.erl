%%% -*- erlang -*-
%%%
%%% QUIC Listener Pool Supervisor
%%% RFC 9000 Section 5 - Connections
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @private

-module(quic_listener_sup_sup).
-behaviour(supervisor).

-export([
    start_link/3,
    init/1
]).

-spec start_link(inet:port_number(), map(), pid()) -> supervisor:startlink_ret().
start_link(Port, Opts, Parent) ->
    supervisor:start_link(?MODULE, {Port, Opts, Parent}).

%%====================================================================
%% supervisor callbacks
%%====================================================================

init({Port, Opts, Parent}) ->
    PoolSize = 1 + maps:get(pool_size, Opts, 1),
    Intensity = ceil(math:log2(PoolSize)),
    SupFlags = #{strategy => one_for_one, intensity => Intensity, period => 5},

    %% Generate shared reset secret for consistent stateless resets
    ResetSecret = maps:get(reset_secret, Opts, crypto:strong_rand_bytes(32)),

    %% Configure pool options
    PoolOpts = Opts#{
        supervisor => Parent,
        reset_secret => ResetSecret,
        reuseport => PoolSize > 1
    },

    %% Create child specs for each listener in the pool
    Children = [
        #{
            id => {quic_listener, N},
            start => {quic_listener, start_link, [Port, PoolOpts]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [quic_listener]
        }
     || N <- lists:seq(1, PoolSize)
    ],

    {ok, {SupFlags, Children}}.
