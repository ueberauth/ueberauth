%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  14 Sep 2019 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_alg_c20p_kw).
-behaviour(jose_jwe).
-behaviour(jose_jwe_alg).

-include("jose_jwk.hrl").

%% jose_jwe callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jwe_alg callbacks
-export([generate_key/3]).
-export([key_decrypt/3]).
-export([key_encrypt/3]).
-export([next_cek/3]).
%% API

%% Types
-record(jose_jwe_alg_c20p_kw, {
	iv  = undefined :: undefined | binary(),
	tag = undefined :: undefined | binary()
}).

-type alg() :: #jose_jwe_alg_c20p_kw{}.

-export_type([alg/0]).

%% Macros
-define(BITS, 256).
-define(C20PKW, #jose_jwe_alg_c20p_kw{}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"C20PKW">> }) ->
	from_map_c20p(?C20PKW, maps:remove(<<"alg">>, F)).

to_map(A = ?C20PKW, F) ->
	to_map_c20p(A, F#{ <<"alg">> => <<"C20PKW">> }).

%%====================================================================
%% jose_jwe_alg callbacks
%%====================================================================

generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_c20p_kw{}) ->
	jose_jwe_alg:generate_key({oct, (?BITS div 8)}, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC)).

key_decrypt(DerivedKey, {_ENCModule, _ENC, EncryptedKey}, #jose_jwe_alg_c20p_kw{iv=IV, tag=TAG})
		when is_binary(DerivedKey)
		andalso bit_size(DerivedKey) =:= ?BITS
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	jose_jwa:block_decrypt({chacha20_poly1305, ?BITS}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(#jose_jwk{kty={KTYModule, KTY}}, EncryptedKey, JWEC20PKW=#jose_jwe_alg_c20p_kw{}) ->
	key_decrypt(KTYModule:derive_key(KTY), EncryptedKey, JWEC20PKW).

key_encrypt(DerivedKey, DecryptedKey, JWEC20PKW=#jose_jwe_alg_c20p_kw{iv=IV})
		when is_binary(DerivedKey)
		andalso bit_size(DerivedKey) =:= ?BITS
		andalso is_binary(IV) ->
	{CipherText, CipherTag} = jose_jwa:block_encrypt({chacha20_poly1305, ?BITS}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEC20PKW#jose_jwe_alg_c20p_kw{ tag = CipherTag }};
key_encrypt(DerivedKey, DecryptedKey, JWEC20PKW=#jose_jwe_alg_c20p_kw{iv=undefined}) ->
	key_encrypt(DerivedKey, DecryptedKey, JWEC20PKW#jose_jwe_alg_c20p_kw{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(#jose_jwk{kty={KTYModule, KTY}}, DecryptedKey, JWEC20PKW=#jose_jwe_alg_c20p_kw{}) ->
	key_encrypt(KTYModule:derive_key(KTY), DecryptedKey, JWEC20PKW).

next_cek(_Key, {ENCModule, ENC}, ALG=#jose_jwe_alg_c20p_kw{}) ->
	{ENCModule:next_cek(ENC), ALG}.

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map_c20p(A, F=#{ <<"iv">> := IV }) ->
	from_map_c20p(A#jose_jwe_alg_c20p_kw{ iv = jose_jwa_base64url:decode(IV) }, maps:remove(<<"iv">>, F));
from_map_c20p(A, F=#{ <<"tag">> := TAG }) ->
	from_map_c20p(A#jose_jwe_alg_c20p_kw{ tag = jose_jwa_base64url:decode(TAG) }, maps:remove(<<"tag">>, F));
from_map_c20p(A, F) ->
	{A, F}.

%% @private
to_map_c20p(#jose_jwe_alg_c20p_kw{ iv = undefined, tag = undefined }, F) ->
	F;
to_map_c20p(A=#jose_jwe_alg_c20p_kw{ iv = IV }, F) when is_binary(IV) ->
	to_map_c20p(A#jose_jwe_alg_c20p_kw{ iv = undefined }, F#{ <<"iv">> => jose_jwa_base64url:encode(IV) });
to_map_c20p(A=#jose_jwe_alg_c20p_kw{ tag = TAG }, F) when is_binary(TAG) ->
	to_map_c20p(A#jose_jwe_alg_c20p_kw{ tag = undefined }, F#{ <<"tag">> => jose_jwa_base64url:encode(TAG) }).
