%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024 Benoit Chesneau
%%%
%%% @doc Supervisor for hackney_conn connection processes.
%%%
%%% This is a simple_one_for_one supervisor that dynamically starts
%%% hackney_conn gen_statem processes for each connection.

-module(hackney_conn_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_conn/1]).
-export([stop_conn/1]).
-export([stop_all/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Start a new connection process.
%% Opts is a map with at least host, port, and transport.
-spec start_conn(map()) -> {ok, pid()} | {error, term()}.
start_conn(Opts) ->
    supervisor:start_child(?SERVER, [Opts]).

%% @doc Stop a connection process gracefully.
%% Tolerates a connection that is already gone or that dies while stopping:
%% callers are only asking for it to be off.
-spec stop_conn(pid()) -> ok.
stop_conn(Pid) ->
    try hackney_conn:stop(Pid) catch _:_ -> ok end.

%% @doc Stop all connection processes gracefully.
%% Useful for test cleanup.
-spec stop_all() -> ok.
stop_all() ->
    try
        Children = supervisor:which_children(?SERVER),
        lists:foreach(fun({_, Pid, _, _}) when is_pid(Pid) ->
            try
                hackney_conn:stop(Pid)
            catch
                _:_ -> ok
            end;
        (_) -> ok
        end, Children),
        ok
    catch
        exit:{noproc, _} -> ok;
        _:_ -> ok
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },
    ChildSpec = #{
        id => hackney_conn,
        start => {hackney_conn, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [hackney_conn]
    },
    {ok, {SupFlags, [ChildSpec]}}.
