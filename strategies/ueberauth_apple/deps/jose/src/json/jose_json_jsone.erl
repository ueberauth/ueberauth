%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  20 Aug 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_json_jsone).
-behaviour(jose_json).

%% jose_json callbacks
-export([decode/1]).
-export([encode/1]).

%%====================================================================
%% jose_json callbacks
%%====================================================================

decode(Binary) ->
	jsone:decode(Binary).

encode(Term) ->
	jsone:encode(Term, [canonical_form]).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
