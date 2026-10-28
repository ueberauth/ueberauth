%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  06 Aug 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_app).
-behaviour(application).

%% Application callbacks
-export([start/2]).
-export([stop/1]).
-export([config_change/3]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

start(_Type, _Args) ->
	jose_sup:start_link().

stop(_State) ->
	ok.

config_change(_Changed, _New, _Removed) ->
	jose_server:config_change().
