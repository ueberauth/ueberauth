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
-module(jose_jwe_alg_ecdh_es).
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

-record(jose_jwe_alg_ecdh_es, {
	epk  = undefined :: undefined | {ec_public_key(), map()},
	apu  = undefined :: undefined | binary(),
	apv  = undefined :: undefined | binary(),
	wrap = undefined :: undefined | aes_gcm_kw | aes_kw | c20p_kw | xc20p_kw,
	bits = undefined :: undefined | 128 | 192 | 256,
	iv   = undefined :: undefined | binary(),
	tag  = undefined :: undefined | binary()
}).

-type alg() :: #jose_jwe_alg_ecdh_es{}.

-export_type([alg/0]).

-define(ECDH_ES,           #jose_jwe_alg_ecdh_es{}).
-define(ECDH_ES_A128GCMKW, #jose_jwe_alg_ecdh_es{wrap=aes_gcm_kw, bits=128}).
-define(ECDH_ES_A192GCMKW, #jose_jwe_alg_ecdh_es{wrap=aes_gcm_kw, bits=192}).
-define(ECDH_ES_A256GCMKW, #jose_jwe_alg_ecdh_es{wrap=aes_gcm_kw, bits=256}).
-define(ECDH_ES_A128KW,    #jose_jwe_alg_ecdh_es{wrap=aes_kw, bits=128}).
-define(ECDH_ES_A192KW,    #jose_jwe_alg_ecdh_es{wrap=aes_kw, bits=192}).
-define(ECDH_ES_A256KW,    #jose_jwe_alg_ecdh_es{wrap=aes_kw, bits=256}).
-define(ECDH_ES_C20PKW,    #jose_jwe_alg_ecdh_es{wrap=c20p_kw, bits=256}).
-define(ECDH_ES_XC20PKW,   #jose_jwe_alg_ecdh_es{wrap=xc20p_kw, bits=256}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"ECDH-ES">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+A128GCMKW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_A128GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+A192GCMKW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_A192GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+A256GCMKW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_A256GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+A128KW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_A128KW);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+A192KW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_A192KW);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+A256KW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_A256KW);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+C20PKW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_C20PKW);
from_map(F = #{ <<"alg">> := <<"ECDH-ES+XC20PKW">> }) ->
	from_map_ecdh_es(maps:remove(<<"alg">>, F), ?ECDH_ES_XC20PKW).

to_map(A = ?ECDH_ES_A128GCMKW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+A128GCMKW">> }, A);
to_map(A = ?ECDH_ES_A192GCMKW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+A192GCMKW">> }, A);
to_map(A = ?ECDH_ES_A256GCMKW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+A256GCMKW">> }, A);
to_map(A = ?ECDH_ES_A128KW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+A128KW">> }, A);
to_map(A = ?ECDH_ES_A192KW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+A192KW">> }, A);
to_map(A = ?ECDH_ES_A256KW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+A256KW">> }, A);
to_map(A = ?ECDH_ES_C20PKW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+C20PKW">> }, A);
to_map(A = ?ECDH_ES_XC20PKW, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES+XC20PKW">> }, A);
to_map(A = ?ECDH_ES, F) ->
	to_map_ecdh_es(F#{ <<"alg">> => <<"ECDH-ES">> }, A).

%%====================================================================
%% jose_jwe_alg callbacks
%%====================================================================

generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_ecdh_es{epk=EphemeralPublicJWK=#jose_jwk{}}) ->
	jose_jwe_alg:generate_key(EphemeralPublicJWK, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC));
generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_ecdh_es{}) ->
	jose_jwe_alg:generate_key({ec, <<"X25519">>}, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC)).

key_decrypt({UEphemeralKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}}, EncryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UEphemeralKey) =:= jose_jwk:thumbprint(UEphemeralPublicKey) of
		true ->
			key_decrypt(VStaticSecretKey, EncryptedKey, JWEECDHES);
		false ->
			error
	end;
key_decrypt({UEphemeralPublicKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}}, EncryptedKey, JWEECDHES0=#jose_jwe_alg_ecdh_es{epk=undefined}) ->
	JWEECDHES = JWEECDHES0#jose_jwe_alg_ecdh_es{epk=UEphemeralPublicKey},
	key_decrypt(VStaticSecretKey, EncryptedKey, JWEECDHES);
key_decrypt(VStaticSecretKey=#jose_jwk{}, EncryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	Z = jose_jwk:shared_secret(UEphemeralPublicKey, VStaticSecretKey),
	key_decrypt(Z, EncryptedKey, JWEECDHES);
key_decrypt(Z, {ENCModule, ENC, <<>>}, #jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=undefined, bits=undefined}) when is_binary(Z) ->
	Algorithm = ENCModule:algorithm(ENC),
	KeyDataLen = ENCModule:bits(ENC),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	DerivedKey;
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=aes_gcm_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({aes_gcm, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=aes_kw, bits=KeyDataLen}) when is_binary(Z) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa_aes_kw:unwrap(EncryptedKey, DerivedKey);
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=c20p_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({chacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=xc20p_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({xchacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG}).

key_encrypt(_Key, _DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{wrap=undefined, bits=undefined}) ->
	{<<>>, JWEECDHES};
key_encrypt({VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UEphemeralSecretKey) =:= jose_jwk:thumbprint(UEphemeralPublicKey) of
		true ->
			Z = jose_jwk:shared_secret(VStaticPublicKey, UEphemeralSecretKey),
			key_encrypt(Z, DecryptedKey, JWEECDHES);
		false ->
			error
	end;
key_encrypt({VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, DecryptedKey, JWEECDHES0=#jose_jwe_alg_ecdh_es{epk=undefined}) ->
	UEphemeralPublicKey = jose_jwk:to_public(UEphemeralSecretKey),
	JWEECDHES1 = JWEECDHES0#jose_jwe_alg_ecdh_es{epk=UEphemeralPublicKey},
	key_encrypt({VStaticPublicKey, UEphemeralSecretKey}, DecryptedKey, JWEECDHES1);
key_encrypt(#jose_jwk{kty={KTYModule, KTY}}, DecryptedKey, JWEECDHES) ->
	DerivedKey = KTYModule:derive_key(KTY),
	key_encrypt(DerivedKey, DecryptedKey, JWEECDHES);
key_encrypt(Z, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=aes_gcm_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({aes_gcm, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDHES#jose_jwe_alg_ecdh_es{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=aes_kw, bits=KeyDataLen}) when is_binary(Z) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{jose_jwa_aes_kw:wrap(DecryptedKey, DerivedKey), JWEECDHES};
key_encrypt(Z, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=c20p_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({chacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDHES#jose_jwe_alg_ecdh_es{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=xc20p_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDHES),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({xchacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDHES#jose_jwe_alg_ecdh_es{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{wrap=aes_gcm_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDHES#jose_jwe_alg_ecdh_es{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Z, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{wrap=c20p_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDHES#jose_jwe_alg_ecdh_es{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Z, DecryptedKey, JWEECDHES=#jose_jwe_alg_ecdh_es{wrap=xc20p_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDHES#jose_jwe_alg_ecdh_es{ iv = crypto:strong_rand_bytes(24) }).

next_cek({VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, {ENCModule, ENC}, JWEECDHES=#jose_jwe_alg_ecdh_es{bits=undefined, epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UEphemeralSecretKey) =:= jose_jwk:thumbprint(UEphemeralPublicKey) of
		true ->
			Z = jose_jwk:shared_secret(VStaticPublicKey, UEphemeralSecretKey),
			next_cek(Z, {ENCModule, ENC}, JWEECDHES);
		false ->
			error
	end;
next_cek({VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, {ENCModule, ENC}, JWEECDHES0=#jose_jwe_alg_ecdh_es{wrap=undefined, bits=undefined, epk=undefined}) ->
	UEphemeralPublicKey = jose_jwk:to_public(UEphemeralSecretKey),
	JWEECDHES1 = JWEECDHES0#jose_jwe_alg_ecdh_es{epk=UEphemeralPublicKey},
	next_cek({VStaticPublicKey, UEphemeralSecretKey}, {ENCModule, ENC}, JWEECDHES1);
next_cek(#jose_jwk{kty={KTYModule, KTY}}, {ENC, ENCModule}, JWEECDHES=#jose_jwe_alg_ecdh_es{wrap=undefined, bits=undefined}) ->
	DerivedKey = KTYModule:derive_key(KTY),
	next_cek(DerivedKey, {ENCModule, ENC}, JWEECDHES);
next_cek(Z, {ENCModule, ENC}, JWEECDHES=#jose_jwe_alg_ecdh_es{apu=APU, apv=APV, wrap=undefined, bits=undefined}) when is_binary(Z) ->
	Algorithm = ENCModule:algorithm(ENC),
	KeyDataLen = ENCModule:bits(ENC),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{DerivedKey, JWEECDHES};
next_cek(_Key, {ENCModule, ENC}, JWEECDHES=#jose_jwe_alg_ecdh_es{}) ->
	{ENCModule:next_cek(ENC), JWEECDHES}.

%%====================================================================
%% API functions
%%====================================================================

algorithm(?ECDH_ES_A128GCMKW) -> <<"ECDH-ES+A128GCMKW">>;
algorithm(?ECDH_ES_A192GCMKW) -> <<"ECDH-ES+A192GCMKW">>;
algorithm(?ECDH_ES_A256GCMKW) -> <<"ECDH-ES+A256GCMKW">>;
algorithm(?ECDH_ES_A128KW)    -> <<"ECDH-ES+A128KW">>;
algorithm(?ECDH_ES_A192KW)    -> <<"ECDH-ES+A192KW">>;
algorithm(?ECDH_ES_A256KW)    -> <<"ECDH-ES+A256KW">>;
algorithm(?ECDH_ES_C20PKW)    -> <<"ECDH-ES+C20PKW">>;
algorithm(?ECDH_ES_XC20PKW)   -> <<"ECDH-ES+XC20PKW">>;
algorithm(?ECDH_ES)           -> <<"ECDH-ES">>.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map_ecdh_es(F = #{ <<"epk">> := EPK }, H) ->
	from_map_ecdh_es(maps:remove(<<"epk">>, F), H#jose_jwe_alg_ecdh_es{ epk = jose_jwk:from_map(EPK) });
from_map_ecdh_es(F = #{ <<"apu">> := APU }, H) ->
	from_map_ecdh_es(maps:remove(<<"apu">>, F), H#jose_jwe_alg_ecdh_es{ apu = jose_jwa_base64url:decode(APU) });
from_map_ecdh_es(F = #{ <<"apv">> := APV }, H) ->
	from_map_ecdh_es(maps:remove(<<"apv">>, F), H#jose_jwe_alg_ecdh_es{ apv = jose_jwa_base64url:decode(APV) });
from_map_ecdh_es(F=#{ <<"iv">> := IV }, H) ->
	from_map_ecdh_es(maps:remove(<<"iv">>, F), H#jose_jwe_alg_ecdh_es{ iv = jose_jwa_base64url:decode(IV) });
from_map_ecdh_es(F=#{ <<"tag">> := TAG }, H) ->
	from_map_ecdh_es(maps:remove(<<"tag">>, F), H#jose_jwe_alg_ecdh_es{ tag = jose_jwa_base64url:decode(TAG) });
from_map_ecdh_es(F, H) ->
	{H, F}.

%% @private
to_map_ecdh_es(F, H=#jose_jwe_alg_ecdh_es{ epk = EPK = #jose_jwk{} }) ->
	to_map_ecdh_es(F#{ <<"epk">> => element(2, jose_jwk:to_public_map(EPK)) }, H#jose_jwe_alg_ecdh_es{ epk = undefined });
to_map_ecdh_es(F, H=#jose_jwe_alg_ecdh_es{ apu = APU }) when is_binary(APU) ->
	to_map_ecdh_es(F#{ <<"apu">> => jose_jwa_base64url:encode(APU) }, H#jose_jwe_alg_ecdh_es{ apu = undefined });
to_map_ecdh_es(F, H=#jose_jwe_alg_ecdh_es{ apv = APV }) when is_binary(APV) ->
	to_map_ecdh_es(F#{ <<"apv">> => jose_jwa_base64url:encode(APV) }, H#jose_jwe_alg_ecdh_es{ apv = undefined });
to_map_ecdh_es(F, H=#jose_jwe_alg_ecdh_es{ iv = IV }) when is_binary(IV) ->
	to_map_ecdh_es(F#{ <<"iv">> => jose_jwa_base64url:encode(IV) }, H#jose_jwe_alg_ecdh_es{ iv = undefined });
to_map_ecdh_es(F, H=#jose_jwe_alg_ecdh_es{ tag = TAG }) when is_binary(TAG) ->
	to_map_ecdh_es(F#{ <<"tag">> => jose_jwa_base64url:encode(TAG) }, H#jose_jwe_alg_ecdh_es{ tag = undefined });
to_map_ecdh_es(F, _) ->
	F.
