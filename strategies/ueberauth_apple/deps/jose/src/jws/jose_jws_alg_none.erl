%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  23 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jws_alg_none).
-behaviour(jose_jws).
-behaviour(jose_jws_alg).

%% jose_jws callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jws_alg callbacks
-export([generate_key/2]).
-export([sign/3]).
-export([verify/4]).

%% API

%% Types
-type alg() :: none.

-export_type([alg/0]).

%%====================================================================
%% jose_jws callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"none">> }) ->
	{none, maps:remove(<<"alg">>, F)}.

to_map(none, F) ->
	F#{ <<"alg">> => <<"none">> }.

%%====================================================================
%% jose_jws_alg callbacks
%%====================================================================

generate_key(none, _Fields) ->
	erlang:error(not_supported).

sign(_Key, _Message, none) ->
	case jose_jwa:unsecured_signing() of
		true ->
			<<>>;
		_ ->
			erlang:error(not_supported)
	end.

verify(_Key, _Message, <<>>, none) ->
	case jose_jwa:unsecured_signing() of
		true ->
			true;
		_ ->
			false
	end;
verify(_Key, _Message, _Signature, none) ->
	false.

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
