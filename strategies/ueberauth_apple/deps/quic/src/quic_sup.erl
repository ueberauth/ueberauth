%%% -*- erlang -*-
%%%
%%% QUIC Application Supervisor
%%% RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Top-level supervisor for the QUIC application.
%%%
%%% This module supervises:
%%% - quic_server_registry: ETS-based registry for named server lookup
%%% - quic_server_sup: Dynamic supervisor for server pools
%%%
%%% Supervision tree:
%%% ```
%%% quic_sup (one_for_one)
%%%   |-- quic_server_registry (worker)
%%%   `-- quic_server_sup (supervisor)
%%%         |-- {server_name_1, quic_listener_sup} (supervisor)
%%%         |-- {server_name_2, quic_listener_sup} (supervisor)
%%%         `-- ...
%%% '''

-module(quic_sup).
-behaviour(supervisor).

-export([
    start_link/0,
    init/1
]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the top-level QUIC supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    %% Create discovery ETS table for quic_discovery_static
    %% This must be created early as distribution may need it during startup
    case ets:info(quic_discovery_static_nodes) of
        undefined ->
            ets:new(
                quic_discovery_static_nodes,
                [named_table, public, set, {read_concurrency, true}]
            );
        _ ->
            ok
    end,

    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    %% Get distribution options for NAT support
    DistOpts = application:get_env(quic, dist, []),

    Children = [
        #{
            id => quic_server_registry,
            start => {quic_server_registry, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [quic_server_registry]
        },
        #{
            id => quic_token_cache,
            start => {quic_token_cache, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [quic_token_cache]
        },
        #{
            id => quic_server_sup,
            start => {quic_server_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [quic_server_sup]
        },
        #{
            id => quic_conn_sup,
            start => {quic_conn_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [quic_conn_sup]
        },
        #{
            id => quic_happy_sup,
            start => {quic_happy_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [quic_happy_sup]
        },
        #{
            id => quic_dist_sup,
            start => {quic_dist_sup, start_link, [DistOpts]},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [quic_dist_sup]
        }
    ],

    {ok, {SupFlags, Children}}.
