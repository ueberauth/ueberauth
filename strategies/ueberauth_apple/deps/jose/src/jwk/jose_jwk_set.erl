%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  21 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk_set).

-include("jose_jwk.hrl").

%% API
-export([from_map/1]).
-export([to_map/2]).

%%====================================================================
%% API functions
%%====================================================================

from_map(F=#{ <<"keys">> := Keys }) ->
	{[jose_jwk:from_map(Key) || Key <- Keys], maps:remove(<<"keys">>, F)}.

to_map(Keys, F) ->
	F#{
		<<"keys">> => [element(2, jose_jwk:to_map(Key)) || Key <- Keys]
	}.
