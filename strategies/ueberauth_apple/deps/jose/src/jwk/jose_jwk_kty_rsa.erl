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
-module(jose_jwk_kty_rsa).
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
-export([decrypt_private/3]).
-export([encrypt_public/3]).
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
-type key() :: #'RSAPrivateKey'{} | #'RSAPublicKey'{}.

-export_type([key/0]).

%% Recovery accepts at most 8192-bit moduli and n-sized exponents before
%% calling the uninterruptible crypto:mod_pow/3 NIF. CRT imports do not
%% perform this search and are not subject to these recovery limits.
-define(SFM_MAX_MODULUS_BITS, 8192).
%% Random bases avoid rejecting valid keys whose factors have matching
%% quadratic characters for every small deterministic base. Each trial
%% performs one exponentiation, then reuses successive modular squares.
-define(SFM_MAX_TRIALS, 32).
-define(SFM_MAX_SQUARES, 256).
%% Check before every expensive operation; a NIF already in progress may
%% finish after this deadline. The outer 1000 ms watchdog is a last resort,
%% not the recovery work budget. Supply CRT parameters on budget exhaustion.
-define(SFM_BUDGET_MS, 200).
%% Large legitimate imports need several more costly trials. The separate
%% deadline still leaves room for one bounded NIF before the outer watchdog.
-define(SFM_LARGE_BUDGET_MS, 500).

%%====================================================================
%% jose_jwk callbacks
%%====================================================================

from_map(F = #{ <<"kty">> := <<"RSA">>, <<"d">> := _ }) ->
	from_map_rsa_private_key(maps:remove(<<"kty">>, F), #'RSAPrivateKey'{ version = 'two-prime', otherPrimeInfos = 'asn1_NOVALUE' });
from_map(F = #{ <<"kty">> := <<"RSA">> }) ->
	from_map_rsa_public_key(maps:remove(<<"kty">>, F), #'RSAPublicKey'{}).

to_key(RSAPrivateKey=#'RSAPrivateKey'{}) ->
	RSAPrivateKey;
to_key(RSAPublicKey=#'RSAPublicKey'{}) ->
	RSAPublicKey.

to_map(RSAPrivateKey=#'RSAPrivateKey'{version = 0}, F) ->
	to_map(RSAPrivateKey#'RSAPrivateKey'{version = 'two-prime'}, F);
to_map(RSAPrivateKey=#'RSAPrivateKey'{version = 1}, F) ->
	to_map(RSAPrivateKey#'RSAPrivateKey'{version = 'multi'}, F);
to_map(#'RSAPrivateKey'{
		version = 'two-prime',
		otherPrimeInfos = 'asn1_NOVALUE',
		privateExponent = D,
		exponent1 = DP,
		exponent2 = DQ,
		publicExponent = E,
		modulus = N,
		prime1 = P,
		prime2 = Q,
		coefficient = QI}, F) ->
	F#{
		<<"d">> => jose_jwa_base64url:encode(int_to_bin(D)),
		<<"dp">> => jose_jwa_base64url:encode(int_to_bin(DP)),
		<<"dq">> => jose_jwa_base64url:encode(int_to_bin(DQ)),
		<<"e">> => jose_jwa_base64url:encode(int_to_bin(E)),
		<<"kty">> => <<"RSA">>,
		<<"n">> => jose_jwa_base64url:encode(int_to_bin(N)),
		<<"p">> => jose_jwa_base64url:encode(int_to_bin(P)),
		<<"q">> => jose_jwa_base64url:encode(int_to_bin(Q)),
		<<"qi">> => jose_jwa_base64url:encode(int_to_bin(QI))
	};
to_map(#'RSAPrivateKey'{
		version = 'multi',
		otherPrimeInfos = OTH,
		privateExponent = D,
		exponent1 = DP,
		exponent2 = DQ,
		publicExponent = E,
		modulus = N,
		prime1 = P,
		prime2 = Q,
		coefficient = QI}, F) ->
	F#{
		<<"d">> => jose_jwa_base64url:encode(int_to_bin(D)),
		<<"dp">> => jose_jwa_base64url:encode(int_to_bin(DP)),
		<<"dq">> => jose_jwa_base64url:encode(int_to_bin(DQ)),
		<<"e">> => jose_jwa_base64url:encode(int_to_bin(E)),
		<<"kty">> => <<"RSA">>,
		<<"n">> => jose_jwa_base64url:encode(int_to_bin(N)),
		<<"oth">> => [begin
			#{
				<<"d">> => jose_jwa_base64url:encode(int_to_bin(OD)),
				<<"r">> => jose_jwa_base64url:encode(int_to_bin(OR)),
				<<"t">> => jose_jwa_base64url:encode(int_to_bin(OT))
			}
		end || #'OtherPrimeInfo'{
			prime = OR,
			exponent = OD,
			coefficient = OT} <- OTH],
		<<"p">> => jose_jwa_base64url:encode(int_to_bin(P)),
		<<"q">> => jose_jwa_base64url:encode(int_to_bin(Q)),
		<<"qi">> => jose_jwa_base64url:encode(int_to_bin(QI))
	};
to_map(#'RSAPublicKey'{
		publicExponent = E,
		modulus = N}, F) ->
	F#{
		<<"e">> => jose_jwa_base64url:encode(int_to_bin(E)),
		<<"kty">> => <<"RSA">>,
		<<"n">> => jose_jwa_base64url:encode(int_to_bin(N))
	}.

to_public_map(K=#'RSAPrivateKey'{}, F) ->
	maps:without([<<"d">>, <<"dp">>, <<"dq">>, <<"p">>, <<"q">>, <<"qi">>, <<"oth">>], to_map(K, F));
to_public_map(K=#'RSAPublicKey'{}, F) ->
	to_map(K, F).

to_thumbprint_map(K, F) ->
	maps:with([<<"e">>, <<"kty">>, <<"n">>], to_public_map(K, F)).

%%====================================================================
%% jose_jwk_kty callbacks
%%====================================================================

generate_key(#'RSAPrivateKey'{ modulus = N, publicExponent = E }) ->
	generate_key({rsa, int_to_bit_size(N), E});
generate_key(#'RSAPublicKey'{ modulus = N, publicExponent = E }) ->
	generate_key({rsa, int_to_bit_size(N), E});
generate_key({rsa, ModulusSize}) when is_integer(ModulusSize) ->
	generate_key({rsa, ModulusSize, 65537});
generate_key({rsa, ModulusSize, ExponentSize})
		when is_integer(ModulusSize)
		andalso is_integer(ExponentSize) ->
	try_generate_key([
		public_key,
		cutkey
	], ModulusSize, ExponentSize).

generate_key(KTY, Fields) ->
	{NewKTY, OtherFields} = generate_key(KTY),
	{NewKTY, maps:merge(maps:remove(<<"kid">>, Fields), OtherFields)}.

key_encryptor(KTY, Fields, Key) ->
	jose_jwk_kty:key_encryptor(KTY, Fields, Key).

%%====================================================================
%% jose_jwk_use_enc callbacks
%%====================================================================

block_encryptor(_KTY, #{ <<"alg">> := ALG, <<"enc">> := ENC, <<"use">> := <<"enc">> }) ->
	#{
		<<"alg">> => ALG,
		<<"enc">> => ENC
	};
block_encryptor(_KTY, _Fields) ->
	#{
		<<"alg">> => case jose_jwa:is_rsa_crypt_supported(rsa_oaep) of
			false -> <<"RSA1_5">>;
			true  -> <<"RSA-OAEP">>
		end,
		<<"enc">> => case jose_jwa:is_block_cipher_supported({aes_gcm, 128}) of
			false -> <<"A128CBC-HS256">>;
			true  -> <<"A128GCM">>
		end
	}.

decrypt_private(CipherText, Options, RSAPrivateKey=#'RSAPrivateKey'{}) ->
	jose_jwa:decrypt_private(CipherText, RSAPrivateKey, Options).

encrypt_public(PlainText, Options, RSAPublicKey=#'RSAPublicKey'{}) ->
	jose_jwa:encrypt_public(PlainText, RSAPublicKey, Options);
encrypt_public(PlainText, Options, #'RSAPrivateKey'{modulus=Modulus, publicExponent=PublicExponent}) ->
	RSAPublicKey = #'RSAPublicKey'{modulus=Modulus, publicExponent=PublicExponent},
	encrypt_public(PlainText, Options, RSAPublicKey).

%%====================================================================
%% jose_jwk_use_sig callbacks
%%====================================================================

sign(Message, JWSALG, RSAPrivateKey=#'RSAPrivateKey'{}) ->
	{Padding, DigestType} = jws_alg_to_digest_type(JWSALG),
	jose_jwa:sign(Message, DigestType, RSAPrivateKey, Padding).

signer(#'RSAPrivateKey'{}, #{ <<"alg">> := ALG, <<"use">> := <<"sig">> }) ->
	#{
		<<"alg">> => ALG
	};
signer(#'RSAPrivateKey'{}, _Fields) ->
	#{
		<<"alg">> => case jose_jwa:is_rsa_sign_supported(rsa_pkcs1_pss_padding) of
			false -> <<"RS256">>;
			true  -> <<"PS256">>
		end
	}.

verifier(_KTY, #{ <<"alg">> := ALG, <<"use">> := <<"sig">> }) ->
	[ALG];
verifier(#'RSAPrivateKey'{modulus=Modulus, publicExponent=PublicExponent}, Fields) ->
	RSAPublicKey = #'RSAPublicKey'{modulus=Modulus, publicExponent=PublicExponent},
	verifier(RSAPublicKey, Fields);
verifier(#'RSAPublicKey'{}, _Fields) ->
	case jose_jwa:is_rsa_sign_supported(rsa_pkcs1_pss_padding) of
		false ->
			[<<"RS256">>, <<"RS384">>, <<"RS512">>];
		true ->
			[<<"PS256">>, <<"PS384">>, <<"PS512">>, <<"RS256">>, <<"RS384">>, <<"RS512">>]
	end.

verify(Message, JWSALG, Signature, RSAPublicKey=#'RSAPublicKey'{}) ->
	try jws_alg_to_digest_type(JWSALG) of
		{Padding, DigestType} ->
			jose_jwa:verify(Message, DigestType, Signature, RSAPublicKey, Padding)
	catch
		error:{not_supported, _} ->
			false
	end;
verify(Message, JWSALG, Signature, #'RSAPrivateKey'{modulus=Modulus, publicExponent=PublicExponent}) ->
	RSAPublicKey = #'RSAPublicKey'{modulus=Modulus, publicExponent=PublicExponent},
	verify(Message, JWSALG, Signature, RSAPublicKey).

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

from_key(RSAPrivateKey=#'RSAPrivateKey'{}) ->
	{RSAPrivateKey, #{}};
from_key(RSAPublicKey=#'RSAPublicKey'{}) ->
	{RSAPublicKey, #{}}.

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

to_der(RSAPrivateKey=#'RSAPrivateKey'{}) ->
	jose_public_key:der_encode('PrivateKeyInfo', RSAPrivateKey);
to_der(RSAPublicKey=#'RSAPublicKey'{}) ->
	jose_public_key:der_encode('RSAPublicKey', RSAPublicKey).

to_der(Password, RSAPrivateKey=#'RSAPrivateKey'{}) ->
	jose_jwk_der:to_binary(Password, 'PrivateKeyInfo', RSAPrivateKey);
to_der(Password, RSAPublicKey=#'RSAPublicKey'{}) ->
	jose_jwk_der:to_binary(Password, 'RSAPublicKey', RSAPublicKey).

to_pem(RSAPrivateKey=#'RSAPrivateKey'{}) ->
	PEMEntry = jose_public_key:pem_entry_encode('PrivateKeyInfo', RSAPrivateKey),
	jose_public_key:pem_encode([PEMEntry]);
to_pem(RSAPublicKey=#'RSAPublicKey'{}) ->
	PEMEntry = jose_public_key:pem_entry_encode('RSAPublicKey', RSAPublicKey),
	jose_public_key:pem_encode([PEMEntry]).

to_pem(Password, RSAPrivateKey=#'RSAPrivateKey'{}) ->
	jose_jwk_pem:to_binary(Password, 'PrivateKeyInfo', RSAPrivateKey);
to_pem(Password, RSAPublicKey=#'RSAPublicKey'{}) ->
	jose_jwk_pem:to_binary(Password, 'RSAPublicKey', RSAPublicKey).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
convert_sfm_to_crt(Key=#'RSAPrivateKey'{
		version = 'two-prime',
		otherPrimeInfos = 'asn1_NOVALUE',
		privateExponent = D,
		exponent1 = undefined,
		exponent2 = undefined,
		publicExponent = E,
		modulus = N,
		prime1 = undefined,
		prime2 = undefined,
		coefficient = undefined})
		when is_integer(D)
		andalso is_integer(E)
		andalso is_integer(N) ->
	KTOT = convert_sfm_to_crt_ktot(D, E, N),
	T = convert_sfm_to_crt_find_t(KTOT),
	Budget = case N < (1 bsl 6144) of
		true -> ?SFM_BUDGET_MS;
		false -> ?SFM_LARGE_BUDGET_MS
	end,
	Deadline = erlang:monotonic_time(millisecond) + Budget,
	P0 = convert_sfm_to_crt_find_p(T, KTOT div T, N,
		?SFM_MAX_TRIALS, ?SFM_MAX_SQUARES, Deadline),
	Q0 = N div P0,
	%% A recovered factor alone does not validate the supplied exponents.
	true = (P0 > 1 andalso Q0 > 1 andalso P0 * Q0 =:= N
		andalso KTOT rem (P0 - 1) =:= 0 andalso KTOT rem (Q0 - 1) =:= 0),
	{P, Q} = case Q0 > P0 of
	  true ->
	    {Q0, P0};
	  false ->
	    {P0, Q0}
	end,
	DP = jose_jwa_math:mod(D, P - 1),
	DQ = jose_jwa_math:mod(D, Q - 1),
	QI = convert_sfm_to_crt_mod_inverse(Q, P),
	true = is_integer(QI),
	Key#'RSAPrivateKey'{
		exponent1 = DP,
		exponent2 = DQ,
		prime1 = P,
		prime2 = Q,
		coefficient = QI
	}.

%% @private
%% Reject structurally invalid triples before attacker-sized arithmetic.
%% ed - 1 must be a positive even multiple of lambda(n) for a valid key.
%% The recovery trials below also check this consistency for each base.
convert_sfm_to_crt_ktot(D, E, N)
		when N > 3
		andalso (N band 1) =:= 1
		andalso N < (1 bsl ?SFM_MAX_MODULUS_BITS)
		andalso E > 2
		andalso E < N
		andalso (E band 1) =:= 1
		andalso D > 0
		andalso D < N
		andalso (D band 1) =:= 1 ->
	D * E - 1;
convert_sfm_to_crt_ktot(_D, _E, _N) ->
	erlang:error(badarg).

%% @private
convert_sfm_to_crt_egcd(0, B) ->
	{B, 0, 1};
convert_sfm_to_crt_egcd(A, B) ->
	{G, Y, X} = convert_sfm_to_crt_egcd(jose_jwa_math:mod(B, A), A),
	{G, X - (B div A) * Y, Y}.

%% @private
convert_sfm_to_crt_find_p(_T, _S, _N, 0, _Squares, _Deadline) ->
	erlang:error(badarg);
convert_sfm_to_crt_find_p(T, S, N, Trials, Squares, Deadline) ->
	ok = convert_sfm_to_crt_check_budget(Squares, Deadline),
	%% The extra 128 random bits make reduction bias negligible while
	%% avoiding an unbounded rejection-sampling loop.
	Bytes = byte_size(binary:encode_unsigned(N)) + 16,
	A = 2 + (crypto:bytes_to_integer(crypto:strong_rand_bytes(Bytes)) rem (N - 3)),
	case convert_sfm_to_crt_gcd(A, N) of
		1 ->
			C = jose_jwa_math:expmod(A, T, N),
			case convert_sfm_to_crt_square(C, S, N, Squares, Deadline) of
				{factor, P} -> P;
				{next, Remaining} ->
					convert_sfm_to_crt_find_p(T, S, N, Trials - 1, Remaining, Deadline)
			end;
		_ ->
			%% A shared factor skips the A^(ed-1) = 1 (mod n) consistency
			%% check, so it must not be returned as a prime. Valid two-prime
			%% moduli practically never reach this; moduli with small factors
			%% (e.g. 2^k - 1) would otherwise import inconsistent keys.
			convert_sfm_to_crt_find_p(T, S, N, Trials - 1, Squares, Deadline)
	end.

%% @private
convert_sfm_to_crt_square(C, _S, N, Squares, _Deadline) when C =:= 1; C =:= N - 1 ->
	{next, Squares};
convert_sfm_to_crt_square(_C, 1, _N, _Squares, _Deadline) ->
	%% A valid key must reach 1 (mod n) after all the squarings.
	erlang:error(badarg);
convert_sfm_to_crt_square(C, S, N, Squares, Deadline) ->
	ok = convert_sfm_to_crt_check_budget(Squares, Deadline),
	case (C * C) rem N of
		1 -> {factor, convert_sfm_to_crt_gcd(C + 1, N)};
		Next -> convert_sfm_to_crt_square(Next, S div 2, N, Squares - 1, Deadline)
	end.

%% @private
convert_sfm_to_crt_check_budget(Squares, Deadline) ->
	case Squares > 0 andalso erlang:monotonic_time(millisecond) < Deadline of
		true -> ok;
		false -> erlang:error(badarg)
	end.

%% @private
convert_sfm_to_crt_find_t(T) when T > 0 andalso T rem 2 =:= 0 ->
	convert_sfm_to_crt_find_t(T div 2);
convert_sfm_to_crt_find_t(T) ->
	T.

%% @private
convert_sfm_to_crt_gcd(A, 0) ->
	A;
convert_sfm_to_crt_gcd(A, B) ->
	convert_sfm_to_crt_gcd(B, jose_jwa_math:mod(A, B)).

%% @private
convert_sfm_to_crt_mod_inverse(A, M) ->
	case convert_sfm_to_crt_egcd(A, M) of
		{1, X, _Y} ->
			jose_jwa_math:mod(X, M);
		_ ->
			no_inverse
	end.

%% @private
from_map_rsa_private_key(F = #{ <<"d">> := D }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"d">>, F), Key#'RSAPrivateKey'{ privateExponent = crypto:bytes_to_integer(jose_jwa_base64url:decode(D)) });
from_map_rsa_private_key(F = #{ <<"dp">> := DP }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"dp">>, F), Key#'RSAPrivateKey'{ exponent1 = crypto:bytes_to_integer(jose_jwa_base64url:decode(DP)) });
from_map_rsa_private_key(F = #{ <<"dq">> := DQ }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"dq">>, F), Key#'RSAPrivateKey'{ exponent2 = crypto:bytes_to_integer(jose_jwa_base64url:decode(DQ)) });
from_map_rsa_private_key(F = #{ <<"e">> := E }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"e">>, F), Key#'RSAPrivateKey'{ publicExponent = crypto:bytes_to_integer(jose_jwa_base64url:decode(E)) });
from_map_rsa_private_key(F = #{ <<"n">> := N }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"n">>, F), Key#'RSAPrivateKey'{ modulus = crypto:bytes_to_integer(jose_jwa_base64url:decode(N)) });
from_map_rsa_private_key(F = #{ <<"p">> := P }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"p">>, F), Key#'RSAPrivateKey'{ prime1 = crypto:bytes_to_integer(jose_jwa_base64url:decode(P)) });
from_map_rsa_private_key(F = #{ <<"q">> := Q }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"q">>, F), Key#'RSAPrivateKey'{ prime2 = crypto:bytes_to_integer(jose_jwa_base64url:decode(Q)) });
from_map_rsa_private_key(F = #{ <<"qi">> := QI }, Key) ->
	from_map_rsa_private_key(maps:remove(<<"qi">>, F), Key#'RSAPrivateKey'{ coefficient = crypto:bytes_to_integer(jose_jwa_base64url:decode(QI)) });
from_map_rsa_private_key(F = #{ <<"oth">> := OTH }, Key) ->
	OtherPrimeInfos = [begin
		#'OtherPrimeInfo'{
			prime = crypto:bytes_to_integer(jose_jwa_base64url:decode(OR)),
			exponent = crypto:bytes_to_integer(jose_jwa_base64url:decode(OD)),
			coefficient = crypto:bytes_to_integer(jose_jwa_base64url:decode(OT))}
	end || #{ <<"d">> := OD, <<"r">> := OR, <<"t">> := OT } <- OTH],
	from_map_rsa_private_key(maps:remove(<<"oth">>, F), Key#'RSAPrivateKey'{ version = 'multi', otherPrimeInfos = OtherPrimeInfos });
from_map_rsa_private_key(F, Key0=#'RSAPrivateKey'{
		version = 'two-prime',
		otherPrimeInfos = 'asn1_NOVALUE',
		privateExponent = D,
		exponent1 = undefined,
		exponent2 = undefined,
		publicExponent = E,
		modulus = N,
		prime1 = undefined,
		prime2 = undefined,
		coefficient = undefined})
		when is_integer(D)
		andalso is_integer(E)
		andalso is_integer(N) ->
	Ref = erlang:make_ref(),
	Parent = self(),
	{Child, Monitor} = spawn_monitor(fun() ->
		%% A rejected key exits quietly: the DOWN clauses below already
		%% turn any failure into {badarg, [Key0]}, and letting the
		%% exception escape would log the attacker supplied integers.
		try convert_sfm_to_crt(Key0) of
			Key ->
				Parent ! {Ref, Key}
		catch
			_:_ ->
				ok
		end,
		exit(normal)
	end),
	receive
		{Ref, Key} ->
			_ = erlang:demonitor(Monitor, [flush]),
			from_map_rsa_private_key(F, Key);
		{'DOWN', Monitor, process, Child, _Reason} ->
			erlang:error({badarg, [Key0]})
	after
		1000 ->
			true = erlang:exit(Child, kill),
			receive
				{Ref, Key} ->
					_ = erlang:demonitor(Monitor, [flush]),
					from_map_rsa_private_key(F, Key);
				{'DOWN', Monitor, process, Child, _Reason} ->
					erlang:error({badarg, [Key0]})
			end
	end;
from_map_rsa_private_key(F, Key) ->
	{Key, F}.

%% @private
from_map_rsa_public_key(F = #{ <<"e">> := E }, Key) ->
	from_map_rsa_public_key(maps:remove(<<"e">>, F), Key#'RSAPublicKey'{ publicExponent = crypto:bytes_to_integer(jose_jwa_base64url:decode(E)) });
from_map_rsa_public_key(F = #{ <<"n">> := N }, Key) ->
	from_map_rsa_public_key(maps:remove(<<"n">>, F), Key#'RSAPublicKey'{ modulus = crypto:bytes_to_integer(jose_jwa_base64url:decode(N)) });
from_map_rsa_public_key(F, Key) ->
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
int_to_bit_size(I) ->
	int_to_bit_size(I, 0).

%% @private
int_to_bit_size(0, B) ->
	B;
int_to_bit_size(I, B) ->
	int_to_bit_size(I bsr 1, B + 1).

%% @private
jws_alg_to_digest_type('PS256') ->
	{rsa_pkcs1_pss_padding, sha256};
jws_alg_to_digest_type('PS384') ->
	{rsa_pkcs1_pss_padding, sha384};
jws_alg_to_digest_type('PS512') ->
	{rsa_pkcs1_pss_padding, sha512};
jws_alg_to_digest_type('RS1') ->
	{rsa_pkcs1_padding, sha};
jws_alg_to_digest_type('RS256') ->
	{rsa_pkcs1_padding, sha256};
jws_alg_to_digest_type('RS384') ->
	{rsa_pkcs1_padding, sha384};
jws_alg_to_digest_type('RS512') ->
	{rsa_pkcs1_padding, sha512};
jws_alg_to_digest_type(ALG) ->
	erlang:error({not_supported, [ALG]}).

%% @private
try_generate_key([public_key | Methods], ModulusSize, ExponentSize) ->
	case code:ensure_loaded(crypto) of
		{module, crypto} ->
			case code:ensure_loaded(public_key) of
				{module, public_key} ->
					_ = application:ensure_all_started(public_key),
					case erlang:function_exported(crypto, generate_key, 2) andalso erlang:function_exported(crypto, generate_key, 3) of
						true ->
							try public_key:generate_key({rsa, ModulusSize, ExponentSize}) of
								Key = #'RSAPrivateKey'{} ->
									{Key, #{}}
							catch
								Class:Reason ->
									erlang:error({public_key_error, {Class, Reason}})
							end;
						false ->
							try_generate_key(Methods, ModulusSize, ExponentSize)
					end;
				_ ->
					try_generate_key(Methods, ModulusSize, ExponentSize)
			end;
		_ ->
			try_generate_key(Methods, ModulusSize, ExponentSize)
	end;
try_generate_key([cutkey | Methods], ModulusSize, ExponentSize) ->
	case code:ensure_loaded(cutkey) of
		{module, cutkey} ->
			_ = application:ensure_all_started(cutkey),
			try cutkey:rsa(ModulusSize, ExponentSize, [{return, key}]) of
				{ok, Key=#'RSAPrivateKey'{}} ->
					{Key, #{}};
				{error, Reason} ->
					erlang:error({cutkey_error, Reason})
			catch
				Class:Reason ->
					erlang:error({cutkey_error, {Class, Reason}})
			end;
		_ ->
			try_generate_key(Methods, ModulusSize, ExponentSize)
	end;
try_generate_key([], ModulusSize, ExponentSize) ->
	erlang:error({not_supported, [{rsa, ModulusSize, ExponentSize}]}).
