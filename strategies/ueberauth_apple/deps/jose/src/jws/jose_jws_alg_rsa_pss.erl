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
-module(jose_jws_alg_rsa_pss).
-behaviour(jose_jws).
-behaviour(jose_jws_alg).

-include("jose_jwk.hrl").

%% jose_jws callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jws_alg callbacks
-export([generate_key/2]).
-export([sign/3]).
-export([verify/4]).

%% API

%% Types
-type alg() :: 'PS256' | 'PS384' | 'PS512'.

-export_type([alg/0]).

%%====================================================================
%% jose_jws callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"PS256">> }) ->
	{'PS256', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"PS384">> }) ->
	{'PS384', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"PS512">> }) ->
	{'PS512', maps:remove(<<"alg">>, F)}.

to_map('PS256', F) ->
	F#{ <<"alg">> => <<"PS256">> };
to_map('PS384', F) ->
	F#{ <<"alg">> => <<"PS384">> };
to_map('PS512', F) ->
	F#{ <<"alg">> => <<"PS512">> }.

%%====================================================================
%% jose_jws_alg callbacks
%%====================================================================

generate_key('PS256', _Fields) ->
	jose_jws_alg:generate_key({rsa, 2048}, <<"PS256">>);
generate_key('PS384', _Fields) ->
	jose_jws_alg:generate_key({rsa, 3072}, <<"PS384">>);
generate_key('PS512', _Fields) ->
	jose_jws_alg:generate_key({rsa, 4096}, <<"PS512">>).

sign(#jose_jwk{kty={KTYModule, KTY}}, Message, ALG) ->
	KTYModule:sign(Message, ALG, KTY).

verify(#jose_jwk{kty={KTYModule, KTY}}, Message, Signature, ALG) ->
	KTYModule:verify(Message, ALG, Signature, KTY).

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
