%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  21 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa).

-include_lib("public_key/include/public_key.hrl").

%% Crypto API
-export([block_decrypt/3]).
-export([block_encrypt/3]).
-export([block_decrypt/4]).
-export([block_encrypt/4]).
%% Public Key API
-export([decrypt_private/3]).
-export([encrypt_public/3]).
-export([sign/4]).
-export([verify/5]).
%% API
-export([block_cipher/1]).
-export([crypto_ciphers/0]).
-export([crypto_fallback/0]).
-export([crypto_fallback/1]).
-export([crypto_supports/0]).
-export([constant_time_compare/2]).
-export([ec_key_mode/0]).
-export([is_block_cipher_supported/1]).
-export([is_chacha20_poly1305_supported/0]).
-export([is_rsa_crypt_supported/1]).
-export([is_rsa_sign_supported/1]).
-export([is_xchacha20_poly1305_supported/0]).
-export([supports/0]).
-export([unsecured_signing/0]).
-export([unsecured_signing/1]).

-define(TAB, ?MODULE).

-define(MAYBE_START_JOSE(F), try
	F
catch
	_:_ ->
		_ = jose:start(),
		F
end).

%%====================================================================
%% Crypto API functions
%%====================================================================

block_decrypt(Cipher, Key, CipherText)
		when is_binary(CipherText) ->
	case block_cipher(Cipher) of
		{crypto, BlockCipher} ->
			jose_crypto_compat:crypto_one_time(BlockCipher, Key, CipherText, false);
		{Module, BlockCipher} ->
			Module:block_decrypt(BlockCipher, Key, CipherText)
	end.

block_encrypt(Cipher, Key, PlainText)
		when is_binary(PlainText) ->
	case block_cipher(Cipher) of
		{crypto, BlockCipher} ->
			jose_crypto_compat:crypto_one_time(BlockCipher, Key, PlainText, true);
		{Module, BlockCipher} ->
			Module:block_encrypt(BlockCipher, Key, PlainText)
	end.

block_decrypt(Cipher, Key, IV, CipherText)
		when is_binary(CipherText) ->
	case block_cipher(Cipher) of
		{crypto, BlockCipher} ->
			jose_crypto_compat:crypto_one_time(BlockCipher, Key, IV, CipherText, false);
		{Module, BlockCipher} ->
			Module:block_decrypt(BlockCipher, Key, IV, CipherText)
	end;
%% Every AEAD cipher reachable through this dispatcher (AES-GCM,
%% ChaCha20-Poly1305 and XChaCha20-Poly1305) authenticates with a
%% 128-bit tag.  The tag arrives straight from the attacker-supplied
%% JWE token, so a truncated tag must never be verified: doing so
%% would only compare bit_size(CipherTag) bits of the real tag and
%% drop forgery resistance to 2^-bit_size(CipherTag).  Reject any tag
%% that is not exactly 128 bits, using the same `error' return that a
%% failed authentication uses.
block_decrypt(_Cipher, _Key, _IV, {AAD, CipherText, CipherTag})
		when is_binary(AAD)
		andalso is_binary(CipherText)
		andalso is_binary(CipherTag)
		andalso bit_size(CipherTag) =/= 128 ->
	error;
block_decrypt(Cipher, Key, IV, {AAD, CipherText, CipherTag})
		when is_binary(AAD)
		andalso is_binary(CipherText)
		andalso is_binary(CipherTag) ->
	case block_cipher(Cipher) of
		{crypto, BlockCipher} ->
			jose_crypto_compat:crypto_one_time(BlockCipher, Key, IV, {AAD, CipherText, CipherTag}, false);
		{Module, BlockCipher} ->
			Module:block_decrypt(BlockCipher, Key, IV, {AAD, CipherText, CipherTag})
	end.

block_encrypt(Cipher, Key, IV, PlainText)
		when is_binary(PlainText) ->
	case block_cipher(Cipher) of
		{crypto, BlockCipher} ->
			jose_crypto_compat:crypto_one_time(BlockCipher, Key, IV, PlainText, true);
		{Module, BlockCipher} ->
			Module:block_encrypt(BlockCipher, Key, IV, PlainText)
	end;
block_encrypt(Cipher, Key, IV, {AAD, PlainText})
		when is_binary(AAD)
		andalso is_binary(PlainText) ->
	case block_cipher(Cipher) of
		{crypto, BlockCipher} ->
			jose_crypto_compat:crypto_one_time(BlockCipher, Key, IV, {AAD, PlainText}, true);
		{Module, BlockCipher} ->
			Module:block_encrypt(BlockCipher, Key, IV, {AAD, PlainText})
	end.

%%====================================================================
%% Public Key API functions
%%====================================================================

decrypt_private(CipherText, RSAPrivateKey=#'RSAPrivateKey'{}, Algorithm)
		when is_atom(Algorithm) ->
	{Module, Options} = rsa_crypt(Algorithm),
	Module:decrypt_private(CipherText, RSAPrivateKey, Options);
decrypt_private(CipherText, PrivateKey, Options) ->
	public_key:decrypt_private(CipherText, PrivateKey, Options).

encrypt_public(PlainText, RSAPublicKey=#'RSAPublicKey'{}, Algorithm)
		when is_atom(Algorithm) ->
	{Module, Options} = rsa_crypt(Algorithm),
	Module:encrypt_public(PlainText, RSAPublicKey, Options);
encrypt_public(PlainText, PublicKey, Options) ->
	public_key:encrypt_public(PlainText, PublicKey, Options).

sign(Message, DigestType, RSAPrivateKey=#'RSAPrivateKey'{}, Padding)
		when is_atom(Padding) ->
	case rsa_sign(Padding) of
		{Module, undefined} ->
			Module:sign(Message, DigestType, RSAPrivateKey);
		{Module, Options} ->
			Module:sign(Message, DigestType, RSAPrivateKey, Options)
	end;
sign(Message, DigestType, PrivateKey, _Options) ->
	public_key:sign(Message, DigestType, PrivateKey).

verify(Message, DigestType, Signature, RSAPublicKey=#'RSAPublicKey'{}, Padding)
		when is_atom(Padding) ->
	case rsa_sign(Padding) of
		{Module, undefined} ->
			Module:verify(Message, DigestType, Signature, RSAPublicKey);
		{Module, Options} ->
			Module:verify(Message, DigestType, Signature, RSAPublicKey, Options)
	end;
verify(Message, DigestType, Signature, PublicKey, _Options) ->
	public_key:verify(Message, DigestType, Signature, PublicKey).

%%====================================================================
%% API functions
%%====================================================================

block_cipher(Cipher) ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, {cipher, Cipher}, 2)).

crypto_ciphers() ->
	?MAYBE_START_JOSE(ets:select(?TAB, [{
		{{cipher, '$1'}, {'$2', '_'}},
		[{'=/=', '$2', 'jose_jwa_unsupported'}],
		[{{'$1', '$2'}}]
	}])).

crypto_fallback() ->
	application:get_env(jose, crypto_fallback, false).

crypto_fallback(Boolean) when is_boolean(Boolean) ->
	application:set_env(jose, crypto_fallback, Boolean),
	?MAYBE_START_JOSE(jose_server:config_change()).

crypto_supports() ->
	Ciphers = ?MAYBE_START_JOSE(ets:select(?TAB, [{
		{{cipher, '$1'}, {'$2', '_'}},
		[{'=/=', '$2', 'jose_jwa_unsupported'}],
		['$1']
	}])),
	RSACrypt = ?MAYBE_START_JOSE(ets:select(?TAB, [{
		{{rsa_crypt, '$1'}, {'$2', '_'}},
		[{'=/=', '$2', 'jose_jwa_unsupported'}],
		['$1']
	}])),
	RSASign = ?MAYBE_START_JOSE(ets:select(?TAB, [{
		{{rsa_sign, '$1'}, {'$2', '_'}},
		[{'=/=', '$2', 'jose_jwa_unsupported'}],
		['$1']
	}])),
	ExternalHashs = external_checks([
		{poly1305, fun() -> jose_chacha20_poly1305:authenticate(<<>>, <<0:256>>, <<0:96>>) end},
		{shake256, fun() -> jose_sha3:shake256(<<>>, 0) end}
	]),
	ExternalPublicKeys = external_checks([
		{ed25519, fun jose_curve25519:eddsa_keypair/0},
		{ed25519ph, fun jose_curve25519:eddsa_keypair/0},
		{ed448, fun jose_curve448:eddsa_keypair/0},
		{ed448ph, fun jose_curve448:eddsa_keypair/0},
		{x25519, fun jose_curve25519:x25519_keypair/0},
		{x448, fun jose_curve448:x448_keypair/0}
	]),
	Supports = crypto:supports(),
	RecommendedHashs = [md5, poly1305, sha, sha256, sha384, sha512, shake256],
	Hashs = RecommendedHashs -- ((RecommendedHashs -- proplists:get_value(hashs, Supports)) -- ExternalHashs),
	RecommendedPublicKeys = [ec_gf2m, ecdh, ecdsa, ed25519, ed25519ph, ed448, ed448ph, rsa, x25519, x448],
	PublicKeys = RecommendedPublicKeys -- ((RecommendedPublicKeys -- proplists:get_value(public_keys, Supports)) -- ExternalPublicKeys),
	[
		{ciphers, Ciphers},
		{hashs, Hashs},
		{public_keys, PublicKeys},
		{rsa_crypt, RSACrypt},
		{rsa_sign, RSASign}
	].

constant_time_compare(<<>>, _) ->
	false;
constant_time_compare(_, <<>>) ->
	false;
constant_time_compare(A, B)
		when is_binary(A) andalso is_binary(B)
		andalso (byte_size(A) =/= byte_size(B)) ->
	false;
constant_time_compare(A, B)
		when is_binary(A) andalso is_binary(B)
		andalso (byte_size(A) =:= byte_size(B)) ->
	constant_time_compare(A, B, 0).

ec_key_mode() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, ec_key_mode, 2)).

is_block_cipher_supported(Cipher) ->
	try block_cipher(Cipher) of
		{crypto, _} ->
			true;
		_ ->
			false
	catch
		_:_ ->
			false
	end.

is_chacha20_poly1305_supported() ->
	try ?MAYBE_START_JOSE(ets:lookup_element(?TAB, chacha20_poly1305_module, 2)) of
		jose_chacha20_poly1305_unsupported ->
			false;
		_ ->
			true
	catch
		_:_ ->
			true
	end.

is_rsa_crypt_supported(Padding) ->
	try rsa_crypt(Padding) of
		{public_key, _} ->
			true;
		_ ->
			false
	catch
		_:_ ->
			false
	end.

is_rsa_sign_supported(Padding) ->
	try rsa_sign(Padding) of
		{public_key, _} ->
			true;
		_ ->
			false
	catch
		_:_ ->
			false
	end.

is_xchacha20_poly1305_supported() ->
	try ?MAYBE_START_JOSE(ets:lookup_element(?TAB, xchacha20_poly1305_module, 2)) of
		jose_xchacha20_poly1305_unsupported ->
			false;
		_ ->
			true
	catch
		_:_ ->
			true
	end.

supports() ->
	Supports = crypto_supports(),
	JWEALG = support_check([
		{<<"A128GCMKW">>, ciphers, {aes_gcm, 128}},
		{<<"A192GCMKW">>, ciphers, {aes_gcm, 192}},
		{<<"A256GCMKW">>, ciphers, {aes_gcm, 256}},
		{<<"A128KW">>, ciphers, {aes_ecb, 128}},
		{<<"A192KW">>, ciphers, {aes_ecb, 192}},
		{<<"A256KW">>, ciphers, {aes_ecb, 256}},
		{<<"C20PKW">>, ciphers, {chacha20_poly1305, 256}},
		<<"ECDH-1PU">>,
		{<<"ECDH-1PU+A128GCMKW">>, ciphers, {aes_gcm, 128}},
		{<<"ECDH-1PU+A192GCMKW">>, ciphers, {aes_gcm, 192}},
		{<<"ECDH-1PU+A256GCMKW">>, ciphers, {aes_gcm, 256}},
		<<"ECDH-1PU+A128KW">>,
		<<"ECDH-1PU+A192KW">>,
		<<"ECDH-1PU+A256KW">>,
		{<<"ECDH-1PU+C20PKW">>, ciphers, {chacha20_poly1305, 256}},
		{<<"ECDH-1PU+XC20PKW">>, ciphers, {xchacha20_poly1305, 256}},
		<<"ECDH-ES">>,
		{<<"ECDH-ES+A128GCMKW">>, ciphers, {aes_gcm, 128}},
		{<<"ECDH-ES+A192GCMKW">>, ciphers, {aes_gcm, 192}},
		{<<"ECDH-ES+A256GCMKW">>, ciphers, {aes_gcm, 256}},
		<<"ECDH-ES+A128KW">>,
		<<"ECDH-ES+A192KW">>,
		<<"ECDH-ES+A256KW">>,
		{<<"ECDH-ES+C20PKW">>, ciphers, {chacha20_poly1305, 256}},
		{<<"ECDH-ES+XC20PKW">>, ciphers, {xchacha20_poly1305, 256}},
		<<"ECDH-SS">>,
		{<<"ECDH-SS+A128GCMKW">>, ciphers, {aes_gcm, 128}},
		{<<"ECDH-SS+A192GCMKW">>, ciphers, {aes_gcm, 192}},
		{<<"ECDH-SS+A256GCMKW">>, ciphers, {aes_gcm, 256}},
		<<"ECDH-SS+A128KW">>,
		<<"ECDH-SS+A192KW">>,
		<<"ECDH-SS+A256KW">>,
		{<<"ECDH-SS+C20PKW">>, ciphers, {chacha20_poly1305, 256}},
		{<<"ECDH-SS+XC20PKW">>, ciphers, {xchacha20_poly1305, 256}},
		{<<"PBES2-HS256+A128GCMKW">>, ciphers, {aes_gcm, 128}},
		{<<"PBES2-HS384+A192GCMKW">>, ciphers, {aes_gcm, 192}},
		{<<"PBES2-HS512+A256GCMKW">>, ciphers, {aes_gcm, 256}},
		{<<"PBES2-HS256+A128KW">>, ciphers, {aes_ecb, 128}},
		{<<"PBES2-HS384+A192KW">>, ciphers, {aes_ecb, 192}},
		{<<"PBES2-HS512+A256KW">>, ciphers, {aes_ecb, 256}},
		{<<"PBES2-HS512+C20PKW">>, ciphers, {chacha20_poly1305, 256}},
		{<<"PBES2-HS512+XC20PKW">>, ciphers, {xchacha20_poly1305, 256}},
		{<<"RSA1_5">>, rsa_crypt, rsa1_5},
		{<<"RSA-OAEP">>, rsa_crypt, rsa_oaep},
		{<<"RSA-OAEP-256">>, rsa_crypt, rsa_oaep_256},
		{<<"XC20PKW">>, ciphers, {xchacha20_poly1305, 256}},
		<<"dir">>
	], Supports, []),
	JWEENC = support_check([
		{<<"A128CBC-HS256">>, ciphers, {aes_cbc, 128}},
		{<<"A192CBC-HS384">>, ciphers, {aes_cbc, 192}},
		{<<"A256CBC-HS512">>, ciphers, {aes_cbc, 256}},
		{<<"A128GCM">>, ciphers, {aes_gcm, 128}},
		{<<"A192GCM">>, ciphers, {aes_gcm, 192}},
		{<<"A256GCM">>, ciphers, {aes_gcm, 256}},
		{<<"C20P">>, ciphers, {chacha20_poly1305, 256}},
		{<<"XC20P">>, ciphers, {xchacha20_poly1305, 256}}
	], Supports, []),
	JWEZIP = support_check([
		<<"DEF">>
	], Supports, []),
	JWKKTY = support_check([
		<<"EC">>,
		<<"oct">>,
		<<"OKP">>,
		<<"RSA">>
	], Supports, []),
	JWKKTYOKPcrv = support_check([
		{<<"Ed25519">>, public_keys, ed25519},
		{<<"Ed25519ph">>, public_keys, ed25519ph},
		{<<"Ed448">>, public_keys, ed448},
		{<<"Ed448ph">>, public_keys, ed448ph},
		{<<"X25519">>, public_keys, x25519},
		{<<"X448">>, public_keys, x448}
	], Supports, []),
	JWSALG = support_check([
		{<<"Ed25519">>, public_keys, ed25519},
		{<<"Ed25519ph">>, public_keys, ed25519ph},
		{<<"Ed448">>, public_keys, ed448},
		{<<"Ed448ph">>, public_keys, ed448ph},
		{<<"EdDSA">>, public_keys, ed25519},
		{<<"ES256">>, public_keys, ecdsa},
		{<<"ES256K">>, public_keys, ecdsa},
		{<<"ES384">>, public_keys, ecdsa},
		{<<"ES512">>, public_keys, ecdsa},
		<<"HS256">>,
		<<"HS384">>,
		<<"HS512">>,
		{<<"PS256">>, rsa_sign, rsa_pkcs1_pss_padding},
		{<<"PS384">>, rsa_sign, rsa_pkcs1_pss_padding},
		{<<"PS512">>, rsa_sign, rsa_pkcs1_pss_padding},
		{<<"Poly1305">>, hashs, poly1305},
		{<<"RS1">>, rsa_sign, rsa_pkcs1_padding},
		{<<"RS256">>, rsa_sign, rsa_pkcs1_padding},
		{<<"RS384">>, rsa_sign, rsa_pkcs1_padding},
		{<<"RS512">>, rsa_sign, rsa_pkcs1_padding},
		{<<"none">>, fun unsecured_signing/0}
	], Supports, []),
	[
		{jwe,
			{alg, JWEALG},
			{enc, JWEENC},
			{zip, JWEZIP}},
		{jwk,
			{kty, JWKKTY},
			{kty_OKP_crv, JWKKTYOKPcrv}},
		{jws,
			{alg, JWSALG}}
	].

unsecured_signing() ->
	jose:unsecured_signing().

unsecured_signing(Boolean) when is_boolean(Boolean) ->
	application:set_env(jose, unsecured_signing, Boolean),
	?MAYBE_START_JOSE(jose_server:config_change()).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
constant_time_compare(<< AH, AT/binary >>, << BH, BT/binary >>, R) ->
	constant_time_compare(AT, BT, R bor (BH bxor AH));
constant_time_compare(<<>>, <<>>, R) ->
	R =:= 0.

%% @private
external_checks(Checks) ->
	external_checks(Checks, []).

%% @private
external_checks([{Key, Check} | Checks], Acc) ->
	try
		Check(),
		external_checks(Checks, [Key | Acc])
	catch
		_:_ ->
			external_checks(Checks, Acc)
	end;
external_checks([], Acc) ->
	lists:reverse(Acc).

%% @private
rsa_crypt(Algorithm) ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, {rsa_crypt, Algorithm}, 2)).

%% @private
rsa_sign(Padding) ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, {rsa_sign, Padding}, 2)).

%% @private
support_check([], _Supports, Acc) ->
	lists:usort(Acc);
support_check([{ALG, Key, Val} | Rest], Supports, Acc) ->
	case lists:member(Val, proplists:get_value(Key, Supports)) of
		false ->
			support_check(Rest, Supports, Acc);
		true ->
			support_check(Rest, Supports, [ALG | Acc])
	end;
support_check([{ALG, Check} | Rest], Supports, Acc) when is_function(Check, 0) ->
	case Check() of
		false ->
			support_check(Rest, Supports, Acc);
		true ->
			support_check(Rest, Supports, [ALG | Acc])
	end;
support_check([ALG | Rest], Supports, Acc) when is_binary(ALG) ->
	support_check(Rest, Supports, [ALG | Acc]).
