%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  24 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk_kty).

-include("jose_public_key.hrl").

-callback generate_key(Parameters) -> KTY
	when
		Parameters :: any(),
		KTY        :: any().
-callback generate_key(KTY, Fields) -> NewKTY
	when
		KTY    :: any(),
		Fields :: map(),
		NewKTY :: any().
-callback key_encryptor(KTY, Fields, Key) -> JWEMap
	when
		KTY    :: any(),
		Fields :: map(),
		Key    :: any(),
		JWEMap :: map().

%% API
-export([from_key/1]).
-export([from_oct/1]).
-export([generate_key/1]).
-export([key_encryptor/3]).

-define(KTY_EC_MODULE,  jose_jwk_kty_ec).
-define(KTY_OCT_MODULE, jose_jwk_kty_oct).
-define(KTY_RSA_MODULE, jose_jwk_kty_rsa).

-define(KTY_OKP_Ed25519_MODULE,   jose_jwk_kty_okp_ed25519).
-define(KTY_OKP_Ed25519ph_MODULE, jose_jwk_kty_okp_ed25519ph).
-define(KTY_OKP_X25519_MODULE,    jose_jwk_kty_okp_x25519).
-define(KTY_OKP_Ed448_MODULE,     jose_jwk_kty_okp_ed448).
-define(KTY_OKP_Ed448ph_MODULE,   jose_jwk_kty_okp_ed448ph).
-define(KTY_OKP_X448_MODULE,      jose_jwk_kty_okp_x448).

%%====================================================================
%% API functions
%%====================================================================

from_key(ECPrivateKey=#'ECPrivateKey'{}) ->
	{?KTY_EC_MODULE, ?KTY_EC_MODULE:from_key(ECPrivateKey)};
from_key({#'ECPoint'{point = PublicKey}, {namedCurve, ?'jose_id-EdDSA25519'}}) ->
	{?KTY_OKP_Ed25519_MODULE, ?KTY_OKP_Ed25519_MODULE:from_key(#'jose_EdDSA25519PublicKey'{ publicKey = PublicKey })};
from_key({#'ECPoint'{point = PublicKey}, {namedCurve, ?'jose_id-EdDSA448'}}) ->
	{?KTY_OKP_Ed448_MODULE, ?KTY_OKP_Ed448_MODULE:from_key(#'jose_EdDSA448PublicKey'{ publicKey = PublicKey })};
from_key(ECPublicKey={#'ECPoint'{}, _}) ->
	{?KTY_EC_MODULE, ?KTY_EC_MODULE:from_key(ECPublicKey)};
from_key(EdDSA25519PrivateKey=#'jose_EdDSA25519PrivateKey'{}) ->
	{?KTY_OKP_Ed25519_MODULE, ?KTY_OKP_Ed25519_MODULE:from_key(EdDSA25519PrivateKey)};
from_key(EdDSA25519PublicKey=#'jose_EdDSA25519PublicKey'{}) ->
	{?KTY_OKP_Ed25519_MODULE, ?KTY_OKP_Ed25519_MODULE:from_key(EdDSA25519PublicKey)};
from_key(EdDSA448PrivateKey=#'jose_EdDSA448PrivateKey'{}) ->
	{?KTY_OKP_Ed448_MODULE, ?KTY_OKP_Ed448_MODULE:from_key(EdDSA448PrivateKey)};
from_key(EdDSA448PublicKey=#'jose_EdDSA448PublicKey'{}) ->
	{?KTY_OKP_Ed448_MODULE, ?KTY_OKP_Ed448_MODULE:from_key(EdDSA448PublicKey)};
from_key(X25519PrivateKey=#'jose_X25519PrivateKey'{}) ->
	{?KTY_OKP_X25519_MODULE, ?KTY_OKP_X25519_MODULE:from_key(X25519PrivateKey)};
from_key(X25519PublicKey=#'jose_X25519PublicKey'{}) ->
	{?KTY_OKP_X25519_MODULE, ?KTY_OKP_X25519_MODULE:from_key(X25519PublicKey)};
from_key(X448PrivateKey=#'jose_X448PrivateKey'{}) ->
	{?KTY_OKP_X448_MODULE, ?KTY_OKP_X448_MODULE:from_key(X448PrivateKey)};
from_key(X448PublicKey=#'jose_X448PublicKey'{}) ->
	{?KTY_OKP_X448_MODULE, ?KTY_OKP_X448_MODULE:from_key(X448PublicKey)};
from_key(RSAPrivateKey=#'RSAPrivateKey'{}) ->
	{?KTY_RSA_MODULE, ?KTY_RSA_MODULE:from_key(RSAPrivateKey)};
from_key(RSAPublicKey=#'RSAPublicKey'{}) ->
	{?KTY_RSA_MODULE, ?KTY_RSA_MODULE:from_key(RSAPublicKey)};
from_key(#'PrivateKeyInfo'{privateKeyAlgorithm=#'PrivateKeyInfo_privateKeyAlgorithm'{algorithm=?rsaEncryption}, privateKey=PrivateKey}) ->
	from_key(public_key:der_decode('RSAPrivateKey', PrivateKey));
from_key(#'PrivateKeyInfo'{privateKeyAlgorithm=#'PrivateKeyInfo_privateKeyAlgorithm'{algorithm=?'id-ecPublicKey'}, privateKey=PrivateKey}) ->
	from_key(public_key:der_decode('ECPrivateKey', PrivateKey));
%% OTP 29+
from_key(#'PrivateKeyInfo'{privateKeyAlgorithm={'PrivateKeyAlgorithmIdentifier', ?rsaEncryption, _}, privateKey=PrivateKey}) ->
	from_key(public_key:der_decode('RSAPrivateKey', PrivateKey));
from_key(#'PrivateKeyInfo'{privateKeyAlgorithm={'PrivateKeyAlgorithmIdentifier', ?'id-ecPublicKey', _}, privateKey=PrivateKey}) ->
	from_key(public_key:der_decode('ECPrivateKey', PrivateKey));
from_key(UnknownKey) ->
	{error, {unknown_key, UnknownKey}}.

from_oct(OCTBinary) when is_binary(OCTBinary) ->
	{?KTY_OCT_MODULE, ?KTY_OCT_MODULE:from_oct(OCTBinary)};
from_oct(UnknownKey) ->
	{error, {unknown_key, UnknownKey}}.

generate_key(P=#'ECParameters'{}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P=#'ECPrivateKey'{}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={#'ECPoint'{}, _}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={namedCurve, _}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P) when is_atom(P) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P=#'RSAPrivateKey'{}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_RSA_MODULE }, P});
generate_key(P=#'RSAPublicKey'{}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_RSA_MODULE }, P});
generate_key(P) when is_integer(P) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OCT_MODULE }, P});
generate_key(P={ec, #'ECParameters'{}}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={ec, #'ECPrivateKey'{}}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={ec, {#'ECPoint'{}, _}}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={ec, {namedCurve, _}}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={ec, Atom}) when is_atom(Atom) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={ec, Binary}) when is_binary(Binary) ->
	jose_jwk:generate_key({#{ kty => ?KTY_EC_MODULE }, P});
generate_key(P={oct, Size}) when is_integer(Size) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OCT_MODULE }, P});
generate_key(P={okp, 'Ed25519'}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed25519_MODULE }, P});
generate_key(P={okp, 'Ed25519ph'}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed25519ph_MODULE }, P});
generate_key(P={okp, 'X25519'}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_X25519_MODULE }, P});
generate_key(P={okp, 'Ed25519', Seed}) when is_binary(Seed) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed25519_MODULE }, P});
generate_key(P={okp, 'Ed25519ph', Seed}) when is_binary(Seed) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed25519ph_MODULE }, P});
generate_key(P={okp, 'X25519', Seed}) when is_binary(Seed) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_X25519_MODULE }, P});
generate_key(P={okp, 'Ed448'}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed448_MODULE }, P});
generate_key(P={okp, 'Ed448ph'}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed448ph_MODULE }, P});
generate_key(P={okp, 'X448'}) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_X448_MODULE }, P});
generate_key(P={okp, 'Ed448', Seed}) when is_binary(Seed) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed448_MODULE }, P});
generate_key(P={okp, 'Ed448ph', Seed}) when is_binary(Seed) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_Ed448ph_MODULE }, P});
generate_key(P={okp, 'X448', Seed}) when is_binary(Seed) ->
	jose_jwk:generate_key({#{ kty => ?KTY_OKP_X448_MODULE }, P});
generate_key(P={rsa, ModulusSize}) when is_integer(ModulusSize) ->
	jose_jwk:generate_key({#{ kty => ?KTY_RSA_MODULE }, P});
generate_key(P={rsa, ModulusSize, ExponentSize})
		when is_integer(ModulusSize)
		andalso is_integer(ExponentSize) ->
	jose_jwk:generate_key({#{ kty => ?KTY_RSA_MODULE }, P}).

key_encryptor(_KTY, _Fields, Key) when is_binary(Key) ->
	#{
		<<"alg">> => <<"PBES2-HS256+A128KW">>,
		<<"cty">> => <<"jwk+json">>,
		<<"enc">> => case jose_jwa:is_block_cipher_supported({aes_gcm, 128}) of
			false -> <<"A128CBC-HS256">>;
			true  -> <<"A128GCM">>
		end,
		<<"p2c">> => 4096,
		<<"p2s">> => jose_jwa_base64url:encode(crypto:strong_rand_bytes(16))
	}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
