%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%

-module(hackney_app).

-behaviour(application).

%% Application callbacks
-export([start/2,
         stop/1,
         get_app_env/1, get_app_env/2]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
  hackney_sup:start_link().

stop(_State) ->
  ok.

%% @doc return a config value
get_app_env(Key) ->
  get_app_env(Key, undefined).

%% @doc return a config value
get_app_env(Key, Default) ->
  case application:get_env(hackney, Key) of
    {ok, Val} -> Val;
    undefined -> Default
  end.
