%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc RFC 4648, Section 5: https://tools.ietf.org/html/rfc4648#section-5
%%%
%%% @end
%%% Created :  29 Jul 2019 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_base64url).

%% API
-export([decode/1]).
-export([encode/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

decode(Input) ->
	jose_base64url:'decode!'(Input).

encode(Input) ->
	jose_base64url:encode(Input, #{ padding => false }).
