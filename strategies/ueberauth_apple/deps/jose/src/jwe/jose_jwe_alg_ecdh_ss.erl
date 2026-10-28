%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Use of Static-Static ECDH in JSON Object Signing and Encryption (JOSE)
%%% See https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00
%%%
%%% @end
%%% Created :  01 Sep 2022 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_alg_ecdh_ss).
-behaviour(jose_jwe).
-behaviour(jose_jwe_alg).

-include_lib("public_key/include/public_key.hrl").

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
-export([algorithm/1]).

%% Types
-type ec_public_key() :: {#'ECPoint'{},{namedCurve, Oid::tuple()} | #'ECParameters'{}} | term().

-record(jose_jwe_alg_ecdh_ss, {
	spk  = undefined :: undefined | {ec_public_key(), map()},
	apu  = undefined :: undefined | binary(),
	apv  = undefined :: undefined | binary(),
	wrap = undefined :: undefined | aes_gcm_kw | aes_kw | c20p_kw | xc20p_kw,
	bits = undefined :: undefined | 128 | 192 | 256,
	iv   = undefined :: undefined | binary(),
	tag  = undefined :: undefined | binary()
}).

-type alg() :: #jose_jwe_alg_ecdh_ss{}.

-export_type([alg/0]).

-define(ECDH_SS,           #jose_jwe_alg_ecdh_ss{}).
-define(ECDH_SS_A128GCMKW, #jose_jwe_alg_ecdh_ss{wrap=aes_gcm_kw, bits=128}).
-define(ECDH_SS_A192GCMKW, #jose_jwe_alg_ecdh_ss{wrap=aes_gcm_kw, bits=192}).
-define(ECDH_SS_A256GCMKW, #jose_jwe_alg_ecdh_ss{wrap=aes_gcm_kw, bits=256}).
-define(ECDH_SS_A128KW,    #jose_jwe_alg_ecdh_ss{wrap=aes_kw, bits=128}).
-define(ECDH_SS_A192KW,    #jose_jwe_alg_ecdh_ss{wrap=aes_kw, bits=192}).
-define(ECDH_SS_A256KW,    #jose_jwe_alg_ecdh_ss{wrap=aes_kw, bits=256}).
-define(ECDH_SS_C20PKW,    #jose_jwe_alg_ecdh_ss{wrap=c20p_kw, bits=256}).
-define(ECDH_SS_XC20PKW,   #jose_jwe_alg_ecdh_ss{wrap=xc20p_kw, bits=256}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"ECDH-SS">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+A128GCMKW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_A128GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+A192GCMKW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_A192GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+A256GCMKW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_A256GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+A128KW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_A128KW);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+A192KW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_A192KW);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+A256KW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_A256KW);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+C20PKW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_C20PKW);
from_map(F = #{ <<"alg">> := <<"ECDH-SS+XC20PKW">> }) ->
	from_map_ecdh_ss(maps:remove(<<"alg">>, F), ?ECDH_SS_XC20PKW).

to_map(A = ?ECDH_SS_A128GCMKW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+A128GCMKW">> }, A);
to_map(A = ?ECDH_SS_A192GCMKW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+A192GCMKW">> }, A);
to_map(A = ?ECDH_SS_A256GCMKW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+A256GCMKW">> }, A);
to_map(A = ?ECDH_SS_A128KW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+A128KW">> }, A);
to_map(A = ?ECDH_SS_A192KW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+A192KW">> }, A);
to_map(A = ?ECDH_SS_A256KW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+A256KW">> }, A);
to_map(A = ?ECDH_SS_C20PKW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+C20PKW">> }, A);
to_map(A = ?ECDH_SS_XC20PKW, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS+XC20PKW">> }, A);
to_map(A = ?ECDH_SS, F) ->
	to_map_ecdh_ss(F#{ <<"alg">> => <<"ECDH-SS">> }, A).

%%====================================================================
%% jose_jwe_alg callbacks
%%====================================================================

generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_ecdh_ss{spk=USenderPublicKey=#jose_jwk{}}) ->
	jose_jwe_alg:generate_key(USenderPublicKey, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC));
generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_ecdh_ss{}) ->
	jose_jwe_alg:generate_key({ec, <<"X25519">>}, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC)).

key_decrypt({UStaticPublicKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}}, EncryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{spk=USenderPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UStaticPublicKey) =:= jose_jwk:thumbprint(USenderPublicKey) of
		true ->
            Z = jose_jwk:shared_secret(UStaticPublicKey, VStaticSecretKey),
			key_decrypt(Z, EncryptedKey, JWEECDHSS);
		false ->
			error
	end;
key_decrypt({UStaticPublicKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}}, EncryptedKey, JWEECDHSS0=#jose_jwe_alg_ecdh_ss{spk=undefined}) ->
	JWEECDHSS = JWEECDHSS0#jose_jwe_alg_ecdh_ss{spk=UStaticPublicKey},
	key_decrypt({UStaticPublicKey, VStaticSecretKey}, EncryptedKey, JWEECDHSS);
key_decrypt(VStaticSecretKey=#jose_jwk{}, EncryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{spk=USenderPublicKey=#jose_jwk{}}) ->
	Z = jose_jwk:shared_secret(USenderPublicKey, VStaticSecretKey),
	key_decrypt(Z, EncryptedKey, JWEECDHSS);
key_decrypt(Z, {ENCModule, ENC, <<>>}, #jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=undefined, bits=undefined}) when is_binary(Z) ->
	Algorithm = ENCModule:algorithm(ENC),
	KeyDataLen = ENCModule:bits(ENC),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	DerivedKey;
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=aes_gcm_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({aes_gcm, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=aes_kw, bits=KeyDataLen}) when is_binary(Z) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa_aes_kw:unwrap(EncryptedKey, DerivedKey);
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=c20p_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({chacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=xc20p_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({xchacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG}).

key_encrypt(_Key, _DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{wrap=undefined, bits=undefined}) ->
	{<<>>, JWEECDHSS};
key_encrypt({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}}, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{spk=USenderPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UStaticSecretKey) =:= jose_jwk:thumbprint(USenderPublicKey) of
		true ->
			Z = jose_jwk:shared_secret(VStaticPublicKey, UStaticSecretKey),
			key_encrypt(Z, DecryptedKey, JWEECDHSS);
		false ->
			error
	end;
key_encrypt({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}}, DecryptedKey, JWEECDHSS0=#jose_jwe_alg_ecdh_ss{wrap=undefined, bits=undefined, spk=undefined}) ->
	USenderPublicKey = jose_jwk:to_public(UStaticSecretKey),
	JWEECDHSS1 = JWEECDHSS0#jose_jwe_alg_ecdh_ss{spk=USenderPublicKey},
	key_encrypt({VStaticPublicKey, UStaticSecretKey}, DecryptedKey, JWEECDHSS1);
key_encrypt(#jose_jwk{kty={KTYModule, KTY}}, DecryptedKey, JWEECDHSS) ->
	DerivedKey = KTYModule:derive_key(KTY),
	key_encrypt(DerivedKey, DecryptedKey, JWEECDHSS);
key_encrypt(Z, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=aes_gcm_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({aes_gcm, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDHSS#jose_jwe_alg_ecdh_ss{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=aes_kw, bits=KeyDataLen}) when is_binary(Z) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{jose_jwa_aes_kw:wrap(DecryptedKey, DerivedKey), JWEECDHSS};
key_encrypt(Z, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=c20p_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({chacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDHSS#jose_jwe_alg_ecdh_ss{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=xc20p_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDHSS),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({xchacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDHSS#jose_jwe_alg_ecdh_ss{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{wrap=aes_gcm_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDHSS#jose_jwe_alg_ecdh_ss{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Z, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{wrap=c20p_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDHSS#jose_jwe_alg_ecdh_ss{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Z, DecryptedKey, JWEECDHSS=#jose_jwe_alg_ecdh_ss{wrap=xc20p_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDHSS#jose_jwe_alg_ecdh_ss{ iv = crypto:strong_rand_bytes(24) }).

next_cek({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}}, {ENCModule, ENC}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{bits=undefined, spk=USenderPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UStaticSecretKey) =:= jose_jwk:thumbprint(USenderPublicKey) of
		true ->
			Z = jose_jwk:shared_secret(VStaticPublicKey, UStaticSecretKey),
			next_cek(Z, {ENCModule, ENC}, JWEECDHSS);
		false ->
			error
	end;
next_cek({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}}, {ENCModule, ENC}, JWEECDHSS0=#jose_jwe_alg_ecdh_ss{wrap=undefined, bits=undefined, spk=undefined}) ->
	USenderPublicKey = jose_jwk:to_public(UStaticSecretKey),
	JWEECDHSS1 = JWEECDHSS0#jose_jwe_alg_ecdh_ss{spk=USenderPublicKey},
	next_cek({VStaticPublicKey, UStaticSecretKey}, {ENCModule, ENC}, JWEECDHSS1);
next_cek(#jose_jwk{kty={KTYModule, KTY}}, {ENC, ENCModule}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{wrap=undefined, bits=undefined}) ->
	DerivedKey = KTYModule:derive_key(KTY),
	next_cek(DerivedKey, {ENCModule, ENC}, JWEECDHSS);
next_cek(Z, {ENCModule, ENC}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{apu=APU, apv=APV, wrap=undefined, bits=undefined}) when is_binary(Z) ->
	Algorithm = ENCModule:algorithm(ENC),
	KeyDataLen = ENCModule:bits(ENC),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{DerivedKey, JWEECDHSS};
next_cek(_Key, {ENCModule, ENC}, JWEECDHSS=#jose_jwe_alg_ecdh_ss{}) ->
	{ENCModule:next_cek(ENC), JWEECDHSS}.

%%====================================================================
%% API functions
%%====================================================================

algorithm(?ECDH_SS_A128GCMKW) -> <<"ECDH-SS+A128GCMKW">>;
algorithm(?ECDH_SS_A192GCMKW) -> <<"ECDH-SS+A192GCMKW">>;
algorithm(?ECDH_SS_A256GCMKW) -> <<"ECDH-SS+A256GCMKW">>;
algorithm(?ECDH_SS_A128KW)    -> <<"ECDH-SS+A128KW">>;
algorithm(?ECDH_SS_A192KW)    -> <<"ECDH-SS+A192KW">>;
algorithm(?ECDH_SS_A256KW)    -> <<"ECDH-SS+A256KW">>;
algorithm(?ECDH_SS_C20PKW)    -> <<"ECDH-SS+C20PKW">>;
algorithm(?ECDH_SS_XC20PKW)   -> <<"ECDH-SS+XC20PKW">>;
algorithm(?ECDH_SS)           -> <<"ECDH-SS">>.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map_ecdh_ss(F = #{ <<"spk">> := SPK }, H) ->
	from_map_ecdh_ss(maps:remove(<<"spk">>, F), H#jose_jwe_alg_ecdh_ss{ spk = jose_jwk:from_map(SPK) });
from_map_ecdh_ss(F = #{ <<"apu">> := APU }, H) ->
	from_map_ecdh_ss(maps:remove(<<"apu">>, F), H#jose_jwe_alg_ecdh_ss{ apu = jose_jwa_base64url:decode(APU) });
from_map_ecdh_ss(F = #{ <<"apv">> := APV }, H) ->
	from_map_ecdh_ss(maps:remove(<<"apv">>, F), H#jose_jwe_alg_ecdh_ss{ apv = jose_jwa_base64url:decode(APV) });
from_map_ecdh_ss(F=#{ <<"iv">> := IV }, H) ->
	from_map_ecdh_ss(maps:remove(<<"iv">>, F), H#jose_jwe_alg_ecdh_ss{ iv = jose_jwa_base64url:decode(IV) });
from_map_ecdh_ss(F=#{ <<"tag">> := TAG }, H) ->
	from_map_ecdh_ss(maps:remove(<<"tag">>, F), H#jose_jwe_alg_ecdh_ss{ tag = jose_jwa_base64url:decode(TAG) });
from_map_ecdh_ss(F, H) ->
	{H, F}.

%% @private
to_map_ecdh_ss(F, H=#jose_jwe_alg_ecdh_ss{ spk = SPK = #jose_jwk{} }) ->
	to_map_ecdh_ss(F#{ <<"spk">> => element(2, jose_jwk:to_public_map(SPK)) }, H#jose_jwe_alg_ecdh_ss{ spk = undefined });
to_map_ecdh_ss(F, H=#jose_jwe_alg_ecdh_ss{ apu = APU }) when is_binary(APU) ->
	to_map_ecdh_ss(F#{ <<"apu">> => jose_jwa_base64url:encode(APU) }, H#jose_jwe_alg_ecdh_ss{ apu = undefined });
to_map_ecdh_ss(F, H=#jose_jwe_alg_ecdh_ss{ apv = APV }) when is_binary(APV) ->
	to_map_ecdh_ss(F#{ <<"apv">> => jose_jwa_base64url:encode(APV) }, H#jose_jwe_alg_ecdh_ss{ apv = undefined });
to_map_ecdh_ss(F, H=#jose_jwe_alg_ecdh_ss{ iv = IV }) when is_binary(IV) ->
	to_map_ecdh_ss(F#{ <<"iv">> => jose_jwa_base64url:encode(IV) }, H#jose_jwe_alg_ecdh_ss{ iv = undefined });
to_map_ecdh_ss(F, H=#jose_jwe_alg_ecdh_ss{ tag = TAG }) when is_binary(TAG) ->
	to_map_ecdh_ss(F#{ <<"tag">> => jose_jwa_base64url:encode(TAG) }, H#jose_jwe_alg_ecdh_ss{ tag = undefined });
to_map_ecdh_ss(F, _) ->
	F.
