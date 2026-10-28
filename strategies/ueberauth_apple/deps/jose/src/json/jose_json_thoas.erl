%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Michael Klishin <michael@clojurewerkz.org>
%%% @copyright 2022, Michael Klishin
%%% @doc
%%%
%%% @end
%%% Created :  30 Jul 2022 by Michael Klishin <michael@clojurewerkz.org>
%%%-------------------------------------------------------------------
-module(jose_json_thoas).
-behaviour(jose_json).

%% jose_json callbacks
-export([decode/1]).
-export([encode/1]).

%%====================================================================
%% jose_json callbacks
%%====================================================================

decode(Binary) ->
	case thoas:decode(Binary) of
		{ok, Value} -> Value;
		{error, _} = Error ->
			error(Error)
	end.

encode(Term) ->
	thoas:encode(Term).
