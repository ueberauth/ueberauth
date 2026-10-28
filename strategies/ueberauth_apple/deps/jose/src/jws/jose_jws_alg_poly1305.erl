%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  08 Aug 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jws_alg_poly1305).
-behaviour(jose_jws).
-behaviour(jose_jws_alg).

-include("jose_jwk.hrl").

%% jose_jws callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jws_alg callbacks
-export([generate_key/2]).
-export([presign/2]).
-export([sign/3]).
-export([verify/4]).
%% API

%% Types
-record('Poly1305', {
	nonce = undefined :: undefined | << _:12 >>
}).

-type alg() :: #'Poly1305'{}.

-export_type([alg/0]).

%%====================================================================
%% jose_jws callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"Poly1305">> }) ->
	from_map(maps:remove(<<"alg">>, F), #'Poly1305'{}).

to_map(#'Poly1305'{nonce=undefined}, F) ->
	F#{ <<"alg">> => <<"Poly1305">> };
to_map(#'Poly1305'{nonce=Nonce}, F) ->
	F#{ <<"alg">> => <<"Poly1305">>, <<"nonce">> => jose_jwa_base64url:encode(Nonce) }.

%%====================================================================
%% jose_jws_alg callbacks
%%====================================================================

generate_key(#'Poly1305'{}, _Fields) ->
	jose_jws_alg:generate_key({oct, 32}, <<"Poly1305">>).

presign(_Key, ALG=#'Poly1305'{nonce=undefined}) ->
	Nonce = crypto:strong_rand_bytes(12),
	ALG#'Poly1305'{nonce=Nonce};
presign(_Key, ALG) ->
	ALG.

sign(#jose_jwk{kty={KTYModule, KTY}}, Message, ALG=#'Poly1305'{nonce=Nonce})
		when is_binary(Nonce) andalso bit_size(Nonce) == 96 ->
	KTYModule:sign(Message, ALG, KTY).

verify(_Key, _Message, _Signature, #'Poly1305'{nonce=undefined}) ->
	false;
verify(#jose_jwk{kty={KTYModule, KTY}}, Message, Signature, ALG=#'Poly1305'{nonce=Nonce})
		when is_binary(Nonce) andalso bit_size(Nonce) == 96 ->
	KTYModule:verify(Message, ALG, Signature, KTY).

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map(F = #{ <<"nonce">> := Nonce }, ALG) ->
	from_map(maps:remove(<<"nonce">>, F), ALG#'Poly1305'{nonce=jose_jwa_base64url:decode(Nonce)});
from_map(F, ALG) ->
	{ALG, F}.
