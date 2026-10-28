%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%

-module(hackney_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include("hackney.hrl").

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  {ok, Pid} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
  %% start the pool handler
  PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
  ok = PoolHandler:start(),
  %% finish to start the application
  {ok, Pid}.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
  %% initialize the config table
  _ = ets:new(?CONFIG, [set, named_table, public]),

  %% initialize per-host load regulation
  hackney_load_regulation:init(),

  %% initialize the TLS options key memo table
  ok = hackney_ssl:init_key_cache(),

  %% initialize the HTTP/3 connection table
  ok = hackney_h3:init_table(),

  Specs = [
           %% manager
           ?CHILD(hackney_manager, worker),
           %% connection process supervisor
           ?CHILD(hackney_conn_sup, supervisor)
          ],

  {ok, { {one_for_one, 10000, 1}, Specs}}.

