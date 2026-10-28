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
-module(jose_jwe_alg_aes_kw).
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
-record(jose_jwe_alg_aes_kw, {
	bits = undefined :: undefined | 128 | 192 | 256,
	gcm  = false     :: boolean(),
	iv   = undefined :: undefined | binary(),
	tag  = undefined :: undefined | binary()
}).

-type alg() :: #jose_jwe_alg_aes_kw{}.

-export_type([alg/0]).

-define(A128KW,    #jose_jwe_alg_aes_kw{bits=128, gcm=false}).
-define(A192KW,    #jose_jwe_alg_aes_kw{bits=192, gcm=false}).
-define(A256KW,    #jose_jwe_alg_aes_kw{bits=256, gcm=false}).
-define(A128GCMKW, #jose_jwe_alg_aes_kw{bits=128, gcm=true}).
-define(A192GCMKW, #jose_jwe_alg_aes_kw{bits=192, gcm=true}).
-define(A256GCMKW, #jose_jwe_alg_aes_kw{bits=256, gcm=true}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"A128KW">> }) ->
	{?A128KW, maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"A192KW">> }) ->
	{?A192KW, maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"A256KW">> }) ->
	{?A256KW, maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"A128GCMKW">> }) ->
	from_map_aes_gcm(?A128GCMKW, maps:remove(<<"alg">>, F));
from_map(F = #{ <<"alg">> := <<"A192GCMKW">> }) ->
	from_map_aes_gcm(?A192GCMKW, maps:remove(<<"alg">>, F));
from_map(F = #{ <<"alg">> := <<"A256GCMKW">> }) ->
	from_map_aes_gcm(?A256GCMKW, maps:remove(<<"alg">>, F)).

to_map(?A128KW, F) ->
	F#{ <<"alg">> => <<"A128KW">> };
to_map(?A192KW, F) ->
	F#{ <<"alg">> => <<"A192KW">> };
to_map(?A256KW, F) ->
	F#{ <<"alg">> => <<"A256KW">> };
to_map(A = ?A128GCMKW, F) ->
	to_map_aes_gcm(A, F#{ <<"alg">> => <<"A128GCMKW">> });
to_map(A = ?A192GCMKW, F) ->
	to_map_aes_gcm(A, F#{ <<"alg">> => <<"A192GCMKW">> });
to_map(A = ?A256GCMKW, F) ->
	to_map_aes_gcm(A, F#{ <<"alg">> => <<"A256GCMKW">> }).

%%====================================================================
%% jose_jwe_alg callbacks
%%====================================================================

generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_aes_kw{bits=Bits}) ->
	jose_jwe_alg:generate_key({oct, (Bits div 8)}, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC)).

key_decrypt(DerivedKey, {_ENCModule, _ENC, EncryptedKey}, #jose_jwe_alg_aes_kw{bits=Bits, gcm=false})
		when is_binary(DerivedKey)
		andalso bit_size(DerivedKey) =:= Bits ->
	jose_jwa_aes_kw:unwrap(EncryptedKey, DerivedKey);
key_decrypt(DerivedKey, {_ENCModule, _ENC, EncryptedKey}, #jose_jwe_alg_aes_kw{bits=Bits, gcm=true, iv=IV, tag=TAG})
		when is_binary(DerivedKey)
		andalso bit_size(DerivedKey) =:= Bits
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	jose_jwa:block_decrypt({aes_gcm, Bits}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(#jose_jwk{kty={KTYModule, KTY}}, EncryptedKey, JWEAESKW=#jose_jwe_alg_aes_kw{}) ->
	key_decrypt(KTYModule:derive_key(KTY), EncryptedKey, JWEAESKW).

key_encrypt(DerivedKey, DecryptedKey, JWEAESKW=#jose_jwe_alg_aes_kw{bits=Bits, gcm=false})
		when is_binary(DerivedKey)
		andalso bit_size(DerivedKey) =:= Bits ->
	{jose_jwa_aes_kw:wrap(DecryptedKey, DerivedKey), JWEAESKW};
key_encrypt(DerivedKey, DecryptedKey, JWEAESKW=#jose_jwe_alg_aes_kw{bits=Bits, gcm=true, iv=IV})
		when is_binary(DerivedKey)
		andalso bit_size(DerivedKey) =:= Bits
		andalso is_binary(IV) ->
	{CipherText, CipherTag} = jose_jwa:block_encrypt({aes_gcm, Bits}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEAESKW#jose_jwe_alg_aes_kw{ tag = CipherTag }};
key_encrypt(DerivedKey, DecryptedKey, JWEAESKW=#jose_jwe_alg_aes_kw{gcm=true, iv=undefined}) ->
	key_encrypt(DerivedKey, DecryptedKey, JWEAESKW#jose_jwe_alg_aes_kw{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(#jose_jwk{kty={KTYModule, KTY}}, DecryptedKey, JWEAESKW=#jose_jwe_alg_aes_kw{}) ->
	key_encrypt(KTYModule:derive_key(KTY), DecryptedKey, JWEAESKW).

next_cek(_Key, {ENCModule, ENC}, ALG=#jose_jwe_alg_aes_kw{}) ->
	{ENCModule:next_cek(ENC), ALG}.

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map_aes_gcm(A, F=#{ <<"iv">> := IV }) ->
	from_map_aes_gcm(A#jose_jwe_alg_aes_kw{ iv = jose_jwa_base64url:decode(IV) }, maps:remove(<<"iv">>, F));
from_map_aes_gcm(A, F=#{ <<"tag">> := TAG }) ->
	from_map_aes_gcm(A#jose_jwe_alg_aes_kw{ tag = jose_jwa_base64url:decode(TAG) }, maps:remove(<<"tag">>, F));
from_map_aes_gcm(A, F) ->
	{A, F}.

%% @private
to_map_aes_gcm(#jose_jwe_alg_aes_kw{ iv = undefined, tag = undefined }, F) ->
	F;
to_map_aes_gcm(A=#jose_jwe_alg_aes_kw{ iv = IV }, F) when is_binary(IV) ->
	to_map_aes_gcm(A#jose_jwe_alg_aes_kw{ iv = undefined }, F#{ <<"iv">> => jose_jwa_base64url:encode(IV) });
to_map_aes_gcm(A=#jose_jwe_alg_aes_kw{ tag = TAG }, F) when is_binary(TAG) ->
	to_map_aes_gcm(A#jose_jwe_alg_aes_kw{ tag = undefined }, F#{ <<"tag">> => jose_jwa_base64url:encode(TAG) }).
