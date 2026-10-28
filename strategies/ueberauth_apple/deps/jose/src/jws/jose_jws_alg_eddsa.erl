%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  31 Dec 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jws_alg_eddsa).
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

%% Types
-type alg() :: 'Ed25519' | 'Ed25519ph' | 'Ed448' | 'Ed448ph' | 'EdDSA'.

-export_type([alg/0]).

%%====================================================================
%% jose_jws callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"Ed25519">> }) ->
	{'Ed25519', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"Ed25519ph">> }) ->
	{'Ed25519ph', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"Ed448">> }) ->
	{'Ed448', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"Ed448ph">> }) ->
	{'Ed448ph', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"EdDSA">> }) ->
	{'EdDSA', maps:remove(<<"alg">>, F)}.

to_map('Ed25519', F) ->
	F#{ <<"alg">> => <<"Ed25519">> };
to_map('Ed25519ph', F) ->
	F#{ <<"alg">> => <<"Ed25519ph">> };
to_map('Ed448', F) ->
	F#{ <<"alg">> => <<"Ed448">> };
to_map('Ed448ph', F) ->
	F#{ <<"alg">> => <<"Ed448ph">> };
to_map('EdDSA', F) ->
	F#{ <<"alg">> => <<"EdDSA">> }.

%%====================================================================
%% jose_jws_alg callbacks
%%====================================================================

generate_key(ALG, _Fields)
		when ALG =:= 'Ed25519'
		orelse ALG =:= 'Ed25519ph'
		orelse ALG =:= 'Ed448'
		orelse ALG =:= 'Ed448ph' ->
	jose_jws_alg:generate_key({okp, ALG}, atom_to_binary(ALG, unicode));
generate_key('EdDSA', _Fields) ->
	jose_jws_alg:generate_key({okp, 'Ed25519'}, <<"EdDSA">>).

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
