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
-module(jose_jwk_kty_ec).
-behaviour(jose_jwk).
-behaviour(jose_jwk_kty).
-behaviour(jose_jwk_use_enc).
-behaviour(jose_jwk_use_sig).

-include_lib("public_key/include/public_key.hrl").

%% jose_jwk callbacks
-export([from_map/1]).
-export([to_key/1]).
-export([to_map/2]).
-export([to_public_map/2]).
-export([to_thumbprint_map/2]).
%% jose_jwk_kty callbacks
-export([generate_key/1]).
-export([generate_key/2]).
-export([key_encryptor/3]).
%% jose_jwk_use_enc callbacks
-export([block_encryptor/2]).
-export([derive_key/2]).
%% jose_jwk_use_sig callbacks
-export([sign/3]).
-export([signer/2]).
-export([verifier/2]).
-export([verify/4]).
%% API
-export([from_der/1]).
-export([from_der/2]).
-export([from_key/1]).
-export([from_pem/1]).
-export([from_pem/2]).
-export([to_der/1]).
-export([to_der/2]).
-export([to_pem/1]).
-export([to_pem/2]).

%% Types
-type key() :: #'ECPrivateKey'{} | {#'ECPoint'{}, {namedCurve, Oid::tuple()} | #'ECParameters'{}}.

-export_type([key/0]).

%% Macros
-ifdef(OTP_RELEASE).
-if(?OTP_RELEASE >= 28).
-define(EC_PRIVATE_KEY_VERSION, ecPrivkeyVer1).
-define(EC_PRIVATE_KEY_VERSION_COMPAT, 1).
-else.
-define(EC_PRIVATE_KEY_VERSION, 1).
-define(EC_PRIVATE_KEY_VERSION_COMPAT, ecPrivkeyVer1).
-endif.
-else.
-define(EC_PRIVATE_KEY_VERSION, 1).
-define(EC_PRIVATE_KEY_VERSION_COMPAT, ecPrivkeyVer1).
-endif.

%%====================================================================
%% jose_jwk callbacks
%%====================================================================

from_map(F = #{ <<"kty">> := <<"EC">>, <<"d">> := _ }) ->
	from_map_ec_private_key(jose_jwa:ec_key_mode(), maps:remove(<<"kty">>, F), #'ECPrivateKey'{ version = ?EC_PRIVATE_KEY_VERSION });
from_map(F = #{ <<"kty">> := <<"EC">> }) ->
	from_map_ec_public_key(maps:remove(<<"kty">>, F), {#'ECPoint'{}, undefined}).

to_key(ECPrivateKey=#'ECPrivateKey'{}) ->
	ECPrivateKey;
to_key(ECPublicKey={#'ECPoint'{}, _}) ->
	ECPublicKey.

to_map(#'ECPrivateKey'{
		version = ?EC_PRIVATE_KEY_VERSION,
		privateKey = D,
		parameters = {namedCurve, Parameters},
		publicKey = PublicKey}, Fields) when is_binary(D) andalso is_binary(PublicKey) ->
	{X, Y} = public_key_to_x_y(PublicKey),
	Fields#{
		<<"d">> => jose_jwa_base64url:encode(D),
		<<"crv">> => parameters_to_crv(Parameters),
		<<"kty">> => <<"EC">>,
		<<"x">> => jose_jwa_base64url:encode(X),
		<<"y">> => jose_jwa_base64url:encode(Y)
	};
to_map({#'ECPoint'{
		point = PublicKey },
		{namedCurve, Parameters}}, Fields) ->
	{X, Y} = public_key_to_x_y(PublicKey),
	Fields#{
		<<"crv">> => parameters_to_crv(Parameters),
		<<"kty">> => <<"EC">>,
		<<"x">> => jose_jwa_base64url:encode(X),
		<<"y">> => jose_jwa_base64url:encode(Y)
	};
to_map(ECPrivateKey0=#'ECPrivateKey'{
		version = ?EC_PRIVATE_KEY_VERSION,
		privateKey = D,
		parameters = {namedCurve, _Parameters},
		publicKey = {_, PublicKey}}, Fields) when is_list(D) andalso is_binary(PublicKey) ->
	ECPrivateKey = ECPrivateKey0#'ECPrivateKey'{
		privateKey = list_to_binary(D),
		publicKey = PublicKey},
	to_map(ECPrivateKey, Fields);
to_map(ECPrivateKey0=#'ECPrivateKey'{version = ?EC_PRIVATE_KEY_VERSION_COMPAT}, Fields) ->
	ECPrivateKey = ECPrivateKey0#'ECPrivateKey'{version = ?EC_PRIVATE_KEY_VERSION},
	to_map(ECPrivateKey, Fields).

to_public_map(K=#'ECPrivateKey'{}, F) ->
	maps:without([<<"d">>], to_map(K, F));
to_public_map(K={#'ECPoint'{}, _}, F) ->
	to_map(K, F).

to_thumbprint_map(K, F) ->
	maps:with([<<"crv">>, <<"kty">>, <<"x">>, <<"y">>], to_public_map(K, F)).

%%====================================================================
%% jose_jwk_kty callbacks
%%====================================================================

generate_key(P=#'ECParameters'{}) ->
	{public_key:generate_key(P), #{}};
generate_key({namedCurve, P}) when is_atom(P) ->
	generate_key({namedCurve, pubkey_cert_records:namedCurves(P)});
generate_key(P={namedCurve, _}) ->
	{public_key:generate_key(P), #{}};
generate_key(#'ECPrivateKey'{ parameters = P }) ->
	generate_key(P);
generate_key({#'ECPoint'{}, P}) ->
	generate_key(P);
generate_key(P) when is_atom(P) ->
	generate_key({namedCurve, P});
generate_key(<<"secp256k1">>) ->
	generate_key(secp256k1);
generate_key(<<"P-256">>) ->
	generate_key(secp256r1);
generate_key(<<"P-384">>) ->
	generate_key(secp384r1);
generate_key(<<"P-521">>) ->
	generate_key(secp521r1);
generate_key({ec, P=#'ECParameters'{}}) ->
	generate_key(P);
generate_key({ec, P=#'ECPrivateKey'{}}) ->
	generate_key(P);
generate_key({ec, P={#'ECPoint'{}, _}}) ->
	generate_key(P);
generate_key({ec, P={namedCurve, _}}) ->
	generate_key(P);
generate_key({ec, P}) when is_atom(P) ->
	generate_key(P);
generate_key({ec, P}) when is_binary(P) ->
	generate_key(P).

generate_key(KTY, Fields) ->
	{NewKTY, OtherFields} = generate_key(KTY),
	{NewKTY, maps:merge(maps:remove(<<"kid">>, Fields), OtherFields)}.

key_encryptor(KTY, Fields, Key) ->
	jose_jwk_kty:key_encryptor(KTY, Fields, Key).

%%====================================================================
%% jose_jwk_use_enc callbacks
%%====================================================================

block_encryptor(_KTY, Fields=#{ <<"alg">> := ALG, <<"enc">> := ENC, <<"use">> := <<"enc">> }) ->
	Folder = fun
		(K, V, F)
				when K =:= <<"apu">>
				orelse K =:= <<"apv">>
				orelse K =:= <<"epk">>
				orelse K =:= <<"skid">> ->
			maps:put(K, V, F);
		(_K, _V, F) ->
			F
	end,
	maps:fold(Folder, #{
		<<"alg">> => ALG,
		<<"enc">> => ENC
	}, Fields);
block_encryptor(KTY, Fields=#{ <<"alg">> := <<"ECDH-1PU", _/binary>> }) ->
	block_encryptor(KTY, maps:merge(Fields, #{
		<<"enc">> => case jose_jwa:is_block_cipher_supported({aes_gcm, 128}) of
			false -> <<"A128CBC-HS256">>;
			true  -> <<"A128GCM">>
		end,
		<<"use">> => <<"enc">>
	}));
block_encryptor(KTY, Fields=#{ <<"alg">> := <<"ECDH-SS", _/binary>> }) ->
	block_encryptor(KTY, maps:merge(Fields, #{
		<<"enc">> => case jose_jwa:is_block_cipher_supported({aes_gcm, 128}) of
			false -> <<"A128CBC-HS256">>;
			true  -> <<"A128GCM">>
		end,
		<<"use">> => <<"enc">>
	}));
block_encryptor(KTY, Fields) ->
	block_encryptor(KTY, maps:merge(Fields, #{
		<<"alg">> => <<"ECDH-ES">>,
		<<"enc">> => case jose_jwa:is_block_cipher_supported({aes_gcm, 128}) of
			false -> <<"A128CBC-HS256">>;
			true  -> <<"A128GCM">>
		end,
		<<"use">> => <<"enc">>
	})).

derive_key({ECPoint=#'ECPoint'{}, _}, ECPrivateKey=#'ECPrivateKey'{}) ->
	public_key:compute_key(ECPoint, ECPrivateKey);
derive_key(#'ECPrivateKey'{parameters=ECParameters, publicKey=Octets}, ECPrivateKey=#'ECPrivateKey'{}) ->
	ECPoint = #'ECPoint'{point=Octets},
	ECPublicKey = {ECPoint, ECParameters},
	derive_key(ECPublicKey, ECPrivateKey).

%%====================================================================
%% jose_jwk_use_sig callbacks
%%====================================================================

sign(Message, JWSALG, ECPrivateKey=#'ECPrivateKey'{}) ->
	DigestType = jws_alg_to_digest_type(ECPrivateKey, JWSALG),
	DERSignature = public_key:sign(Message, DigestType, ECPrivateKey),
	#'ECDSA-Sig-Value'{ r = R, s = S } = public_key:der_decode('ECDSA-Sig-Value', DERSignature),
	RBin = int_to_bin(R),
	SBin = int_to_bin(S),
	Size = jws_alg_to_r_s_size(JWSALG),
	RPad = pad(RBin, Size),
	SPad = pad(SBin, Size),
	Signature = << RPad/binary, SPad/binary >>,
	Signature;
sign(_Message, _JWSALG, {#'ECPoint'{}, _}) ->
	erlang:error(not_supported).

signer(#'ECPrivateKey'{}, #{ <<"alg">> := ALG, <<"use">> := <<"sig">> }) ->
	#{
		<<"alg">> => ALG
	};
signer(#'ECPrivateKey'{parameters={namedCurve, Parameters}}, _Fields) ->
	#{
		<<"alg">> => case parameters_to_crv(Parameters) of
			<<"secp256k1">> -> <<"ES256K">>;
			<<"P-256">> -> <<"ES256">>;
			<<"P-384">> -> <<"ES384">>;
			<<"P-521">> -> <<"ES512">>
		end
	}.

verifier(_KTY, #{ <<"alg">> := ALG, <<"use">> := <<"sig">> }) ->
	[ALG];
verifier(#'ECPrivateKey'{parameters=ECParameters, publicKey=Octets0}, Fields) ->
	Octets = case Octets0 of
		{_, Octets1} ->
			Octets1;
		_ ->
			Octets0
	end,
	ECPoint = #'ECPoint'{point=Octets},
	ECPublicKey = {ECPoint, ECParameters},
	verifier(ECPublicKey, Fields);
verifier({#'ECPoint'{}, {namedCurve, Parameters}}, _Fields) ->
	[
		case parameters_to_crv(Parameters) of
			<<"secp256k1">> -> <<"ES256K">>;
			<<"P-256">> -> <<"ES256">>;
			<<"P-384">> -> <<"ES384">>;
			<<"P-521">> -> <<"ES512">>
		end
	].

verify(Message, JWSALG, Signature, ECPublicKey={#'ECPoint'{}, _}) ->
	try jws_alg_to_digest_type(ECPublicKey, JWSALG) of
		DigestType ->
			%% Safe: jws_alg_to_digest_type/2 has already rejected every
			%% JWSALG that jws_alg_to_r_s_size/1 does not handle.
			RSSize = jws_alg_to_r_s_size(JWSALG),
			%% RFC 7518 3.4 fixes the JWS Signature to the octet sequence
			%% R || S, where each of R and S is left zero-padded to the
			%% byte length of the curve order.  Any other length MUST be
			%% rejected: splitting on byte_size(Signature) div 2 and then
			%% relying on crypto:bytes_to_integer/1 (which ignores leading
			%% zero octets) would otherwise accept an unbounded family of
			%% distinct, re-padded encodings of the same (R, S) pair.
			case Signature of
				<< RBin:RSSize/binary, SBin:RSSize/binary >> ->
					R = crypto:bytes_to_integer(RBin),
					S = crypto:bytes_to_integer(SBin),
					DERSignature = public_key:der_encode('ECDSA-Sig-Value', #'ECDSA-Sig-Value'{ r = R, s = S }),
					public_key:verify(Message, DigestType, DERSignature, ECPublicKey);
				_ ->
					false
			end
	catch
		error:{not_supported, _} ->
			false
	end;
verify(Message, JWSALG, Signature, #'ECPrivateKey'{parameters=ECParameters, publicKey=Octets0}) ->
	Octets = case Octets0 of
		{_, Octets1} ->
			Octets1;
		_ ->
			Octets0
	end,
	ECPoint = #'ECPoint'{point=Octets},
	ECPublicKey = {ECPoint, ECParameters},
	verify(Message, JWSALG, Signature, ECPublicKey).

%%====================================================================
%% API functions
%%====================================================================

from_der(DERBinary) when is_binary(DERBinary) ->
	case jose_jwk_der:from_binary(DERBinary) of
		{?MODULE, {Key, Fields}} ->
			{Key, Fields}
	end.

from_der(Password, PEMBinary) when is_binary(PEMBinary) ->
	case jose_jwk_der:from_binary(Password, PEMBinary) of
		{?MODULE, {Key, Fields}} ->
			{Key, Fields};
		PEMError ->
			PEMError
	end.

from_key(ECPrivateKey=#'ECPrivateKey'{}) ->
	{ECPrivateKey, #{}};
from_key(ECPublicKey={#'ECPoint'{}, _}) ->
	{ECPublicKey, #{}}.

from_pem(PEMBinary) when is_binary(PEMBinary) ->
	case jose_jwk_pem:from_binary(PEMBinary) of
		{?MODULE, {Key, Fields}} ->
			{Key, Fields};
		PEMError ->
			PEMError
	end.

from_pem(Password, PEMBinary) when is_binary(PEMBinary) ->
	case jose_jwk_pem:from_binary(Password, PEMBinary) of
		{?MODULE, {Key, Fields}} ->
			{Key, Fields};
		PEMError ->
			PEMError
	end.

to_der(ECPrivateKey=#'ECPrivateKey'{}) ->
	jose_public_key:der_encode('PrivateKeyInfo', ECPrivateKey);
to_der(ECPublicKey={#'ECPoint'{}, _ECParameters}) ->
	jose_public_key:der_encode('SubjectPublicKeyInfo', ECPublicKey).

to_der(Password, ECPrivateKey=#'ECPrivateKey'{}) ->
	jose_jwk_der:to_binary(Password, 'PrivateKeyInfo', ECPrivateKey);
to_der(Password, ECPublicKey={#'ECPoint'{}, _ECParameters}) ->
	erlang:error({badarg, [Password, ECPublicKey]}).

to_pem(ECPrivateKey=#'ECPrivateKey'{}) ->
	PEMEntry = jose_public_key:pem_entry_encode('PrivateKeyInfo', ECPrivateKey),
	jose_public_key:pem_encode([PEMEntry]);
to_pem(ECPublicKey={#'ECPoint'{}, _ECParameters}) ->
	PEMEntry = jose_public_key:pem_entry_encode('SubjectPublicKeyInfo', ECPublicKey),
	jose_public_key:pem_encode([PEMEntry]).

to_pem(Password, ECPrivateKey=#'ECPrivateKey'{}) ->
	jose_jwk_pem:to_binary(Password, 'PrivateKeyInfo', ECPrivateKey);
to_pem(Password, ECPublicKey={#'ECPoint'{}, _ECParameters}) ->
	erlang:error({badarg, [Password, ECPublicKey]}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map_ec_private_key(binary, F = #{ <<"d">> := D }, Key) ->
	from_map_ec_private_key(binary, maps:remove(<<"d">>, F), Key#'ECPrivateKey'{ privateKey = jose_jwa_base64url:decode(D) });
from_map_ec_private_key(list, F = #{ <<"d">> := D }, Key) ->
	from_map_ec_private_key(list, maps:remove(<<"d">>, F), Key#'ECPrivateKey'{ privateKey = binary_to_list(jose_jwa_base64url:decode(D)) });
from_map_ec_private_key(ECMode, F = #{ <<"crv">> := <<"secp256k1">> }, Key) ->
	from_map_ec_private_key(ECMode, maps:remove(<<"crv">>, F), Key#'ECPrivateKey'{ parameters = {namedCurve, pubkey_cert_records:namedCurves(secp256k1)} });
from_map_ec_private_key(ECMode, F = #{ <<"crv">> := <<"P-256">> }, Key) ->
	from_map_ec_private_key(ECMode, maps:remove(<<"crv">>, F), Key#'ECPrivateKey'{ parameters = {namedCurve, pubkey_cert_records:namedCurves(secp256r1)} });
from_map_ec_private_key(ECMode, F = #{ <<"crv">> := <<"P-384">> }, Key) ->
	from_map_ec_private_key(ECMode, maps:remove(<<"crv">>, F), Key#'ECPrivateKey'{ parameters = {namedCurve, pubkey_cert_records:namedCurves(secp384r1)} });
from_map_ec_private_key(ECMode, F = #{ <<"crv">> := <<"P-521">> }, Key) ->
	from_map_ec_private_key(ECMode, maps:remove(<<"crv">>, F), Key#'ECPrivateKey'{ parameters = {namedCurve, pubkey_cert_records:namedCurves(secp521r1)} });
from_map_ec_private_key(binary, F = #{ <<"x">> := X, <<"y">> := Y }, Key) ->
	from_map_ec_private_key(binary, maps:without([<<"x">>, <<"y">>], F), Key#'ECPrivateKey'{ publicKey = << 16#04, (jose_jwa_base64url:decode(X))/binary, (jose_jwa_base64url:decode(Y))/binary >> });
from_map_ec_private_key(list, F = #{ <<"x">> := X, <<"y">> := Y }, Key) ->
	from_map_ec_private_key(list, maps:without([<<"x">>, <<"y">>], F), Key#'ECPrivateKey'{ publicKey = {0, << 16#04, (jose_jwa_base64url:decode(X))/binary, (jose_jwa_base64url:decode(Y))/binary >>} });
from_map_ec_private_key(_ECMode, F, Key) ->
	{Key, F}.

%% @private
from_map_ec_public_key(F = #{ <<"crv">> := <<"secp256k1">> }, {Point, _Params}) ->
	from_map_ec_public_key(maps:remove(<<"crv">>, F), {Point, {namedCurve, pubkey_cert_records:namedCurves(secp256k1)}});
from_map_ec_public_key(F = #{ <<"crv">> := <<"P-256">> }, {Point, _Params}) ->
	from_map_ec_public_key(maps:remove(<<"crv">>, F), {Point, {namedCurve, pubkey_cert_records:namedCurves(secp256r1)}});
from_map_ec_public_key(F = #{ <<"crv">> := <<"P-384">> }, {Point, _Params}) ->
	from_map_ec_public_key(maps:remove(<<"crv">>, F), {Point, {namedCurve, pubkey_cert_records:namedCurves(secp384r1)}});
from_map_ec_public_key(F = #{ <<"crv">> := <<"P-521">> }, {Point, _Params}) ->
	from_map_ec_public_key(maps:remove(<<"crv">>, F), {Point, {namedCurve, pubkey_cert_records:namedCurves(secp521r1)}});
from_map_ec_public_key(F = #{ <<"x">> := X, <<"y">> := Y }, {Point, Params}) ->
	from_map_ec_public_key(maps:without([<<"x">>, <<"y">>], F), {Point#'ECPoint'{ point = << 16#04, (jose_jwa_base64url:decode(X))/binary, (jose_jwa_base64url:decode(Y))/binary >> }, Params});
from_map_ec_public_key(F, Key) ->
	{Key, F}.

%% @private
int_to_bin(X) when X < 0 -> int_to_bin_neg(X, []);
int_to_bin(X) -> int_to_bin_pos(X, []).

%% @private
int_to_bin_pos(0,Ds=[_|_]) ->
	list_to_binary(Ds);
int_to_bin_pos(X,Ds) ->
	int_to_bin_pos(X bsr 8, [(X band 255)|Ds]).

%% @private
int_to_bin_neg(-1, Ds=[MSB|_]) when MSB >= 16#80 ->
	list_to_binary(Ds);
int_to_bin_neg(X,Ds) ->
	int_to_bin_neg(X bsr 8, [(X band 255)|Ds]).

%% @private
jws_alg_to_digest_type(<<"secp256k1">>, 'ES256K') ->
	sha256;
jws_alg_to_digest_type(<<"P-256">>, 'ES256') ->
	sha256;
jws_alg_to_digest_type(<<"P-384">>, 'ES384') ->
	sha384;
jws_alg_to_digest_type(<<"P-521">>, 'ES512') ->
	sha512;
jws_alg_to_digest_type(#'ECPrivateKey'{parameters={namedCurve, Parameters}}, ALG) ->
	jws_alg_to_digest_type(parameters_to_crv(Parameters), ALG);
jws_alg_to_digest_type({#'ECPoint'{}, {namedCurve, Parameters}}, ALG) ->
	jws_alg_to_digest_type(parameters_to_crv(Parameters), ALG);
jws_alg_to_digest_type(KeyOrCurve, ALG) ->
	erlang:error({not_supported, [KeyOrCurve, ALG]}).

%% @private
jws_alg_to_r_s_size('ES256K') ->
  32;
jws_alg_to_r_s_size('ES256') ->
  32;
jws_alg_to_r_s_size('ES384') ->
  48;
jws_alg_to_r_s_size('ES512') ->
  66.

%% @private
pad(Bin, Size) when byte_size(Bin) =:= Size ->
	Bin;
pad(Bin, Size) ->
	pad(<< 0, Bin/binary >>, Size).

%% @private
parameters_to_crv(secp256k1) ->
	<<"secp256k1">>;
parameters_to_crv(secp256r1) ->
	<<"P-256">>;
parameters_to_crv(secp384r1) ->
	<<"P-384">>;
parameters_to_crv(secp521r1) ->
	<<"P-521">>;
parameters_to_crv(Parameters) when is_tuple(Parameters) ->
	parameters_to_crv(pubkey_cert_records:namedCurves(Parameters)).

%% @private
public_key_to_x_y(<< 16#04, X:32/binary, Y:32/binary >>) ->
	{X, Y};
public_key_to_x_y(<< 16#04, X:48/binary, Y:48/binary >>) ->
	{X, Y};
public_key_to_x_y(<< 16#04, X:66/binary, Y:66/binary >>) ->
	{X, Y}.
