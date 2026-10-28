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
-module(jose_jws_alg_ecdsa).
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
-type alg() :: 'ES256K' | 'ES256' | 'ES384' | 'ES512'.

-export_type([alg/0]).

%%====================================================================
%% jose_jws callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"ES256K">> }) ->
	{'ES256K', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"ES256">> }) ->
	{'ES256', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"ES384">> }) ->
	{'ES384', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"ES512">> }) ->
	{'ES512', maps:remove(<<"alg">>, F)}.

to_map('ES256K', F) ->
	F#{ <<"alg">> => <<"ES256K">> };
to_map('ES256', F) ->
	F#{ <<"alg">> => <<"ES256">> };
to_map('ES384', F) ->
	F#{ <<"alg">> => <<"ES384">> };
to_map('ES512', F) ->
	F#{ <<"alg">> => <<"ES512">> }.

%%====================================================================
%% jose_jws_alg callbacks
%%====================================================================

generate_key('ES256K', _Fields) ->
	jose_jws_alg:generate_key({ec, <<"secp256k1">>}, <<"ES256K">>);
generate_key('ES256', _Fields) ->
	jose_jws_alg:generate_key({ec, <<"P-256">>}, <<"ES256">>);
generate_key('ES384', _Fields) ->
	jose_jws_alg:generate_key({ec, <<"P-384">>}, <<"ES384">>);
generate_key('ES512', _Fields) ->
	jose_jws_alg:generate_key({ec, <<"P-521">>}, <<"ES512">>).

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
