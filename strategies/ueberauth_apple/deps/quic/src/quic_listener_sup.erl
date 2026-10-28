%%% -*- erlang -*-
%%%
%%% QUIC Listener Pool Supervisor
%%% RFC 9000 Section 5 - Connections
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Supervisor for a pool of QUIC listeners using SO_REUSEPORT.
%%%
%%% This module provides horizontal scaling for QUIC servers by running
%%% multiple listener processes that share the same port via reuseport.
%%% The kernel distributes incoming packets across the listeners.
%%%
%%% == Usage ==
%%%
%%% Single listener (default):
%%% ```
%%% quic_listener:start_link(Port, Opts)
%%% '''
%%%
%%% Pooled listeners for scalability:
%%% ```
%%% quic_listener_sup:start_link(Port, Opts#{pool_size => 4})
%%% '''
%%%
%%% @see quic_listener

-module(quic_listener_sup).
-behaviour(supervisor).

-export([
    start_link/2,
    stop/1,
    get_listeners/1
]).

%% supervisor callbacks
-export([init/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a pool of QUIC listeners on the given port.
%% Options:
%%   - pool_size: Number of listener processes (default 1)
%%   - All other options are passed to quic_listener
-spec start_link(inet:port_number(), map()) -> {ok, pid()} | {error, term()}.
start_link(Port, Opts) ->
    supervisor:start_link(?MODULE, {Port, Opts}).

%% @doc Stop the listener pool supervisor.
-spec stop(pid()) -> ok.
stop(Sup) ->
    %% First terminate all children, then stop the supervisor
    _ = [supervisor:terminate_child(Sup, Id) || {Id, _, _, _} <- supervisor:which_children(Sup)],
    exit(Sup, shutdown),
    ok.

%% @doc Get list of listener PIDs in the pool.
%% Navigates to quic_listener_sup_sup to find actual quic_listener processes.
-spec get_listeners(pid()) -> [pid()].
get_listeners(Sup) ->
    Children = supervisor:which_children(Sup),
    case lists:keyfind(quic_listener_sup_sup, 1, Children) of
        {quic_listener_sup_sup, SupSupPid, _, _} when is_pid(SupSupPid) ->
            %% Get actual listeners from the listener_sup_sup
            [
                Pid
             || {{quic_listener, _}, Pid, _, _} <- supervisor:which_children(SupSupPid),
                is_pid(Pid)
            ];
        _ ->
            []
    end.

%%====================================================================
%% supervisor callbacks
%%====================================================================

init({Port, Opts}) ->
    Self = self(),

    %% Register with server registry if name is provided
    %% This handles both initial start and supervisor restarts
    case maps:get(name, Opts, undefined) of
        undefined ->
            ok;
        Name when is_atom(Name) ->
            %% Ignore errors in case registry isn't started (standalone listener_sup usage)
            try
                quic_server_registry:register(Name, Self, Port, Opts)
            catch
                _:_ -> ok
            end
    end,

    SupFlags = #{strategy => rest_for_one, intensity => 10, period => 5},

    Manager = #{
        id => quic_listener_manager,
        start => {quic_listener_manager, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [quic_listener_manager]
    },

    ListenerSupSup = #{
        id => quic_listener_sup_sup,
        start => {quic_listener_sup_sup, start_link, [Port, Opts, Self]},
        restart => permanent,
        type => supervisor,
        modules => [quic_listener_sup_sup]
    },

    {ok, {SupFlags, [Manager, ListenerSupSup]}}.
