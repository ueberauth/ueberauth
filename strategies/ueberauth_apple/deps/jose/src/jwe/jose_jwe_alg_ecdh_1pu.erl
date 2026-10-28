%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Key Agreement with Elliptic Curve Diffie-Hellman One-Pass Unified Model (ECDH-1PU)
%%% See https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04
%%%
%%% @end
%%% Created :  29 Dec 2019 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_alg_ecdh_1pu).
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

-record(jose_jwe_alg_ecdh_1pu, {
	epk  = undefined :: undefined | {ec_public_key(), map()},
	apu  = undefined :: undefined | binary(),
	apv  = undefined :: undefined | binary(),
	wrap = undefined :: undefined | aes_gcm_kw | aes_kw | c20p_kw | xc20p_kw,
	bits = undefined :: undefined | 128 | 192 | 256,
	iv   = undefined :: undefined | binary(),
	tag  = undefined :: undefined | binary()
}).

-type alg() :: #jose_jwe_alg_ecdh_1pu{}.

-export_type([alg/0]).

-define(ECDH_1PU,           #jose_jwe_alg_ecdh_1pu{}).
-define(ECDH_1PU_A128GCMKW, #jose_jwe_alg_ecdh_1pu{wrap=aes_gcm_kw, bits=128}).
-define(ECDH_1PU_A192GCMKW, #jose_jwe_alg_ecdh_1pu{wrap=aes_gcm_kw, bits=192}).
-define(ECDH_1PU_A256GCMKW, #jose_jwe_alg_ecdh_1pu{wrap=aes_gcm_kw, bits=256}).
-define(ECDH_1PU_A128KW,    #jose_jwe_alg_ecdh_1pu{wrap=aes_kw, bits=128}).
-define(ECDH_1PU_A192KW,    #jose_jwe_alg_ecdh_1pu{wrap=aes_kw, bits=192}).
-define(ECDH_1PU_A256KW,    #jose_jwe_alg_ecdh_1pu{wrap=aes_kw, bits=256}).
-define(ECDH_1PU_C20PKW,    #jose_jwe_alg_ecdh_1pu{wrap=c20p_kw, bits=256}).
-define(ECDH_1PU_XC20PKW,   #jose_jwe_alg_ecdh_1pu{wrap=xc20p_kw, bits=256}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"ECDH-1PU">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+A128GCMKW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_A128GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+A192GCMKW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_A192GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+A256GCMKW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_A256GCMKW);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+A128KW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_A128KW);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+A192KW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_A192KW);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+A256KW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_A256KW);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+C20PKW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_C20PKW);
from_map(F = #{ <<"alg">> := <<"ECDH-1PU+XC20PKW">> }) ->
	from_map_ecdh_1pu(maps:remove(<<"alg">>, F), ?ECDH_1PU_XC20PKW).

to_map(A = ?ECDH_1PU_A128GCMKW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+A128GCMKW">> }, A);
to_map(A = ?ECDH_1PU_A192GCMKW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+A192GCMKW">> }, A);
to_map(A = ?ECDH_1PU_A256GCMKW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+A256GCMKW">> }, A);
to_map(A = ?ECDH_1PU_A128KW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+A128KW">> }, A);
to_map(A = ?ECDH_1PU_A192KW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+A192KW">> }, A);
to_map(A = ?ECDH_1PU_A256KW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+A256KW">> }, A);
to_map(A = ?ECDH_1PU_C20PKW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+C20PKW">> }, A);
to_map(A = ?ECDH_1PU_XC20PKW, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU+XC20PKW">> }, A);
to_map(A = ?ECDH_1PU, F) ->
	to_map_ecdh_1pu(F#{ <<"alg">> => <<"ECDH-1PU">> }, A).

%%====================================================================
%% jose_jwe_alg callbacks
%%====================================================================

generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_ecdh_1pu{epk=EphemeralPublicJWK=#jose_jwk{}}) ->
	jose_jwe_alg:generate_key(EphemeralPublicJWK, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC));
generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_ecdh_1pu{}) ->
	jose_jwe_alg:generate_key({ec, <<"X25519">>}, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC)).

key_decrypt({UStaticPublicKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}, UEphemeralKey=#jose_jwk{}}, EncryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UEphemeralKey) =:= jose_jwk:thumbprint(UEphemeralPublicKey) of
		true ->
			key_decrypt({UStaticPublicKey, VStaticSecretKey}, EncryptedKey, JWEECDH1PU);
		false ->
			error
	end;
key_decrypt({UStaticPublicKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}, UEphemeralPublicKey=#jose_jwk{}}, EncryptedKey, JWEECDH1PU0=#jose_jwe_alg_ecdh_1pu{epk=undefined}) ->
	JWEECDH1PU = JWEECDH1PU0#jose_jwe_alg_ecdh_1pu{epk=UEphemeralPublicKey},
	key_decrypt({UStaticPublicKey, VStaticSecretKey}, EncryptedKey, JWEECDH1PU);
key_decrypt({UStaticPublicKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}}, EncryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	Ze = jose_jwk:shared_secret(UEphemeralPublicKey, VStaticSecretKey),
	Zs = jose_jwk:shared_secret(UStaticPublicKey, VStaticSecretKey),
	Z = <<Ze/binary, Zs/binary>>,
	key_decrypt(Z, EncryptedKey, JWEECDH1PU);
key_decrypt(Z, {ENCModule, ENC, <<>>}, #jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=undefined, bits=undefined}) when is_binary(Z) ->
	Algorithm = ENCModule:algorithm(ENC),
	KeyDataLen = ENCModule:bits(ENC),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	DerivedKey;
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=aes_gcm_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({aes_gcm, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=aes_kw, bits=KeyDataLen}) when is_binary(Z) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa_aes_kw:unwrap(EncryptedKey, DerivedKey);
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=c20p_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({chacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Z, {_ENCModule, _ENC, EncryptedKey}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=xc20p_kw, bits=KeyDataLen, iv=IV, tag=TAG})
		when is_binary(Z)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	jose_jwa:block_decrypt({xchacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, EncryptedKey, TAG}).

key_encrypt(_Key, _DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{wrap=undefined, bits=undefined}) ->
	{<<>>, JWEECDH1PU};
key_encrypt({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UEphemeralSecretKey) =:= jose_jwk:thumbprint(UEphemeralPublicKey) of
		true ->
			Ze = jose_jwk:shared_secret(VStaticPublicKey, UEphemeralSecretKey),
			Zs = jose_jwk:shared_secret(VStaticPublicKey, UStaticSecretKey),
			Z = <<Ze/binary, Zs/binary>>,
			key_encrypt(Z, DecryptedKey, JWEECDH1PU);
		false ->
			error
	end;
key_encrypt({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, DecryptedKey, JWEECDH1PU0=#jose_jwe_alg_ecdh_1pu{wrap=undefined, bits=undefined, epk=undefined}) ->
	UEphemeralPublicKey = jose_jwk:to_public(UEphemeralSecretKey),
	JWEECDH1PU1 = JWEECDH1PU0#jose_jwe_alg_ecdh_1pu{epk=UEphemeralPublicKey},
	key_encrypt({VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey}, DecryptedKey, JWEECDH1PU1);
key_encrypt(#jose_jwk{kty={KTYModule, KTY}}, DecryptedKey, JWEECDH1PU) ->
	DerivedKey = KTYModule:derive_key(KTY),
	key_encrypt(DerivedKey, DecryptedKey, JWEECDH1PU);
key_encrypt(Z, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=aes_gcm_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({aes_gcm, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDH1PU#jose_jwe_alg_ecdh_1pu{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=aes_kw, bits=KeyDataLen}) when is_binary(Z) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{jose_jwa_aes_kw:wrap(DecryptedKey, DerivedKey), JWEECDH1PU};
key_encrypt(Z, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=c20p_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({chacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDH1PU#jose_jwe_alg_ecdh_1pu{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=xc20p_kw, bits=KeyDataLen, iv=IV})
		when is_binary(Z)
		andalso is_binary(IV) ->
	Algorithm = algorithm(JWEECDH1PU),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({xchacha20_poly1305, KeyDataLen}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEECDH1PU#jose_jwe_alg_ecdh_1pu{ tag = CipherTag }};
key_encrypt(Z, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{wrap=aes_gcm_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDH1PU#jose_jwe_alg_ecdh_1pu{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Z, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{wrap=c20p_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDH1PU#jose_jwe_alg_ecdh_1pu{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Z, DecryptedKey, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{wrap=xc20p_kw, iv=undefined}) when is_binary(Z) ->
	key_encrypt(Z, DecryptedKey, JWEECDH1PU#jose_jwe_alg_ecdh_1pu{ iv = crypto:strong_rand_bytes(24) }).

next_cek({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, {ENCModule, ENC}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{bits=undefined, epk=UEphemeralPublicKey=#jose_jwk{}}) ->
	case jose_jwk:thumbprint(UEphemeralSecretKey) =:= jose_jwk:thumbprint(UEphemeralPublicKey) of
		true ->
			Ze = jose_jwk:shared_secret(VStaticPublicKey, UEphemeralSecretKey),
			Zs = jose_jwk:shared_secret(VStaticPublicKey, UStaticSecretKey),
			Z = <<Ze/binary, Zs/binary>>,
			next_cek(Z, {ENCModule, ENC}, JWEECDH1PU);
		false ->
			error
	end;
next_cek({VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}}, {ENCModule, ENC}, JWEECDH1PU0=#jose_jwe_alg_ecdh_1pu{wrap=undefined, bits=undefined, epk=undefined}) ->
	UEphemeralPublicKey = jose_jwk:to_public(UEphemeralSecretKey),
	JWEECDH1PU1 = JWEECDH1PU0#jose_jwe_alg_ecdh_1pu{epk=UEphemeralPublicKey},
	next_cek({VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey}, {ENCModule, ENC}, JWEECDH1PU1);
next_cek(#jose_jwk{kty={KTYModule, KTY}}, {ENC, ENCModule}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{wrap=undefined, bits=undefined}) ->
	DerivedKey = KTYModule:derive_key(KTY),
	next_cek(DerivedKey, {ENCModule, ENC}, JWEECDH1PU);
next_cek(Z, {ENCModule, ENC}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{apu=APU, apv=APV, wrap=undefined, bits=undefined}) when is_binary(Z) ->
	Algorithm = ENCModule:algorithm(ENC),
	KeyDataLen = ENCModule:bits(ENC),
	SuppPubInfo = << KeyDataLen:1/unsigned-big-integer-unit:32 >>,
	DerivedKey = jose_jwa_concat_kdf:kdf(sha256, Z, {Algorithm, APU, APV, SuppPubInfo}, KeyDataLen),
	{DerivedKey, JWEECDH1PU};
next_cek(_Key, {ENCModule, ENC}, JWEECDH1PU=#jose_jwe_alg_ecdh_1pu{}) ->
	{ENCModule:next_cek(ENC), JWEECDH1PU}.

%%====================================================================
%% API functions
%%====================================================================

algorithm(?ECDH_1PU_A128GCMKW) -> <<"ECDH-1PU+A128GCMKW">>;
algorithm(?ECDH_1PU_A192GCMKW) -> <<"ECDH-1PU+A192GCMKW">>;
algorithm(?ECDH_1PU_A256GCMKW) -> <<"ECDH-1PU+A256GCMKW">>;
algorithm(?ECDH_1PU_A128KW)    -> <<"ECDH-1PU+A128KW">>;
algorithm(?ECDH_1PU_A192KW)    -> <<"ECDH-1PU+A192KW">>;
algorithm(?ECDH_1PU_A256KW)    -> <<"ECDH-1PU+A256KW">>;
algorithm(?ECDH_1PU_C20PKW)    -> <<"ECDH-1PU+C20PKW">>;
algorithm(?ECDH_1PU_XC20PKW)   -> <<"ECDH-1PU+XC20PKW">>;
algorithm(?ECDH_1PU)           -> <<"ECDH-1PU">>.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map_ecdh_1pu(F = #{ <<"epk">> := EPK }, H) ->
	from_map_ecdh_1pu(maps:remove(<<"epk">>, F), H#jose_jwe_alg_ecdh_1pu{ epk = jose_jwk:from_map(EPK) });
from_map_ecdh_1pu(F = #{ <<"apu">> := APU }, H) ->
	from_map_ecdh_1pu(maps:remove(<<"apu">>, F), H#jose_jwe_alg_ecdh_1pu{ apu = jose_jwa_base64url:decode(APU) });
from_map_ecdh_1pu(F = #{ <<"apv">> := APV }, H) ->
	from_map_ecdh_1pu(maps:remove(<<"apv">>, F), H#jose_jwe_alg_ecdh_1pu{ apv = jose_jwa_base64url:decode(APV) });
from_map_ecdh_1pu(F=#{ <<"iv">> := IV }, H) ->
	from_map_ecdh_1pu(maps:remove(<<"iv">>, F), H#jose_jwe_alg_ecdh_1pu{ iv = jose_jwa_base64url:decode(IV) });
from_map_ecdh_1pu(F=#{ <<"tag">> := TAG }, H) ->
	from_map_ecdh_1pu(maps:remove(<<"tag">>, F), H#jose_jwe_alg_ecdh_1pu{ tag = jose_jwa_base64url:decode(TAG) });
from_map_ecdh_1pu(F, H) ->
	{H, F}.

%% @private
to_map_ecdh_1pu(F, H=#jose_jwe_alg_ecdh_1pu{ epk = EPK = #jose_jwk{} }) ->
	to_map_ecdh_1pu(F#{ <<"epk">> => element(2, jose_jwk:to_public_map(EPK)) }, H#jose_jwe_alg_ecdh_1pu{ epk = undefined });
to_map_ecdh_1pu(F, H=#jose_jwe_alg_ecdh_1pu{ apu = APU }) when is_binary(APU) ->
	to_map_ecdh_1pu(F#{ <<"apu">> => jose_jwa_base64url:encode(APU) }, H#jose_jwe_alg_ecdh_1pu{ apu = undefined });
to_map_ecdh_1pu(F, H=#jose_jwe_alg_ecdh_1pu{ apv = APV }) when is_binary(APV) ->
	to_map_ecdh_1pu(F#{ <<"apv">> => jose_jwa_base64url:encode(APV) }, H#jose_jwe_alg_ecdh_1pu{ apv = undefined });
to_map_ecdh_1pu(F, H=#jose_jwe_alg_ecdh_1pu{ iv = IV }) when is_binary(IV) ->
	to_map_ecdh_1pu(F#{ <<"iv">> => jose_jwa_base64url:encode(IV) }, H#jose_jwe_alg_ecdh_1pu{ iv = undefined });
to_map_ecdh_1pu(F, H=#jose_jwe_alg_ecdh_1pu{ tag = TAG }) when is_binary(TAG) ->
	to_map_ecdh_1pu(F#{ <<"tag">> => jose_jwa_base64url:encode(TAG) }, H#jose_jwe_alg_ecdh_1pu{ tag = undefined });
to_map_ecdh_1pu(F, _) ->
	F.
