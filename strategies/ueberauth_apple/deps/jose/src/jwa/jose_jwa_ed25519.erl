%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Edwards-Curve Digital Signature Algorithm (EdDSA) - Ed25519, Ed25519ctx, Ed25519ph
%%% See https://datatracker.ietf.org/doc/html/rfc8032
%%% @end
%%% Created :  06 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_ed25519).

%% API
-export([xrecover/1]).
-export([encode_point/1]).
-export([decode_point/1]).
-export([edwards_add/2]).
-export([edwards_double/1]).
-export([edwards_equal/2]).
-export([scalarmult/2]).
-export([scalarmult_base/1]).
-export([normalize_point/1]).
-export([secret/0]).
-export([secret_to_curve25519/1]).
-export([secret_to_pk/1]).
-export([keypair/0]).
-export([keypair/1]).
-export([sk_to_secret/1]).
-export([sk_to_pk/1]).
-export([sk_to_curve25519/1]).
-export([pk_to_curve25519/1]).
-export([dom2/2]).
-export([sign_internal/4]).
-export([ed25519_sign/2]).
-export([ed25519ctx_sign/3]).
-export([ed25519ph_sign/2]).
-export([ed25519ph_sign/3]).
-export([verify_internal/5]).
-export([ed25519_verify/3]).
-export([ed25519ctx_verify/4]).
-export([ed25519ph_verify/3]).
-export([ed25519ph_verify/4]).

%% Macros
-define(math, jose_jwa_math).
-define(inv(Z), ?math:expmod(Z, ?p - 2, ?p)). % $= z^{-1} \mod p$, for z != 0
% 3. EdDSA Algorithm - https://datatracker.ietf.org/doc/html/rfc8032#section-3
% 5.1. Ed25519ph and Ed25519 - https://datatracker.ietf.org/doc/html/rfc8032-01#section-5.1
-define(d, -4513249062541557337682894930092624173785641285191125241628941591882900924598840740). % (-121665) * ?inv(121666)
-define(I, 19681161376707505956807079304988542015446066515923890162744021073123829784752). % ?math:expmod(2, (?p - 1) div 4, ?p)
%% 1. An odd prime power p.  EdDSA uses an elliptic curve over the
%%    finite field GF(p).
-define(p, 57896044618658097711785492504343953926634992332820282019728792003956564819949). % ?math:intpow(2, 255) - 19
%% 2. An integer b with 2^(b-1) > p.  EdDSA public keys have exactly b
%%    bits, and EdDSA signatures have exactly 2*b bits.  b is
%%    recommended to be multiple of 8, so public key and signature
%%    lengths are integral number of octets.
-define(b, 256). % ?math:intpow(2, ?b - 1) > ?p
%% 3. A (b-1)-bit encoding of elements of the finite field GF(p).
-define(GFp, <<
	16#ED,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FE
>>). % << ?p:(?b - 1)/unsigned-little-integer-unit:1, 0:1 >>
%% 4. A cryptographic hash function H producing 2*b-bit output.
%%    Conservative hash functions are recommended and do not have much
%%    impact on the total cost of EdDSA.
-define(H(M), crypto:hash(sha512, M)).
-define(HBits, 512). % ?b * 2
%% 5. An integer c that is 2 or 3.  Secret EdDSA scalars are multiples
%%    of 2^c.  The integer c is the base-2 logarithm of the so called
%%    cofactor.
-define(c, 3).
%% 6. An integer n with c <= n < b.  Secret EdDSA scalars have exactly
%%    n + 1 bits, with the top bit (the 2^n position) always set and
%%    the bottom c bits always cleared.
-define(n, 254). % ?c =< ?n andalso ?n < ?b
%% 7. A nonzero square element a of GF(p).  The usual recommendation
%%    for best performance is a = -1 if p mod 4 = 1, and a = 1 if p
%%    mod 4 = 3.
-define(a, -1).
%% 8. An element B != (0,1) of the set E = { (x,y) is a member of
%%    GF(p) x GF(p) such that a * x^2 + y^2 = 1 + d * x^2 * y^2 }.
-define(By, 46316835694926478169428394003475163141307993866256225615783033603165251855960). % 4 * ?inv(5)
-define(Bx, 15112221349535400772501151409588531511454012693041857206046113283949847762202). % xrecover(?By)
-define(B, {?Bx, ?By, 1, 46827403850823179245072216630277197565144205554125654976674165829533817101731}). % {?Bx, ?By, 1, (?Bx * ?Bx) rem ?p}
% (?a * ?math:intpow(?Bx, 2) + ?math:intpow(?By, 2)) rem ?p == (1 + ?d * ?math:intpow(?Bx, 2) * ?math:intpow(?By, 2)) rem ?p
%% 9. An odd prime l such that [l]B = 0 and 2^c * l = #E.  The number
%%    #E (the number of points on the curve) is part of the standard
%%    data provided for an elliptic curve E.
-define(l, 7237005577332262213973186563042994240857116359379907606001950938285454250989). % ?math:intpow(2, 252) + 27742317777372353535851937790883648493
-define(E, ?math:intpow(2, ?c) * ?l).
%% 10. A "prehash" function PH.  PureEdDSA means EdDSA where PH is the
%%     identity function, i.e., PH(M) = M.  HashEdDSA means EdDSA where
%%     PH generates a short output, no matter how long the message is;
%%     for example, PH(M) = SHA-512(M).
-define(PH(M), crypto:hash(sha512, M)).

-define(secretbytes,    32). % (?b + 7) div 8
-define(publickeybytes, 32). % (?b + 7) div 8
-define(secretkeybytes, 64). % ?secretbytes + ?publickeybytes

%%====================================================================
%% API
%%====================================================================

% 5.1.1. Modular arithmetic - https://datatracker.ietf.org/doc/html/rfc8032#section-5.1.1

xrecover(Y) ->
	YY = Y * Y,
	A = (YY - 1) * ?inv((?d * YY) + 1),
	X = ?math:expmod(A, (?p + 3) div 8, ?p),
	case ((X * X) - A) rem ?p =:= 0 of
		true -> % x^2 = a (mod p).  Then x is a square root.
			case X rem 2 of
				0 ->
					X;
				_ ->
					?p - X
			end;
		false ->
			case ((X * X) + A) rem ?p =:= 0 of
				true -> % x^2 = -a (mod p).  Then 2^((p-1)/4) x is a square root.
					Xi = (X * ?I) rem ?p,
					case Xi rem 2 of
						0 ->
							Xi;
						_ ->
							?p - Xi
					end;
				false -> % a is not a square modulo p.
					erlang:error(badarg)
			end
	end.

% 5.1.2. Encoding - https://datatracker.ietf.org/doc/html/rfc8032#section-5.1.2

encode_point({X, Y, Z, _T}) ->
	Zi = ?inv(Z),
	Xp = ?math:mod((X * Zi), ?p),
	Yp = ?math:mod((Y * Zi), ?p),
	<< YpHead:(?b - 8)/bitstring, YpTail:8/integer >> = << Yp:?b/unsigned-little-integer-unit:1 >>,
	<< YpHead/bitstring, (YpTail bxor (16#80 * (Xp band 1))):8/integer >>.

% 5.1.3. Decoding - https://datatracker.ietf.org/doc/html/rfc8032#section-5.1.3

decode_point(<< YpHead:(?b - 8)/bitstring, Xb:1, YpTail:7/bitstring >>) ->
	<< Yp:?b/unsigned-little-integer-unit:1 >> = << YpHead/bitstring, 0:1, YpTail/bitstring >>,
	case Yp >= ?p of
		true ->
			erlang:error(badarg);
		false ->
			Xp = xrecover(Yp),
			X = case Xp band 1 of
				Xb ->
					Xp;
				_ ->
					?p - Xp
			end,
			{X, Yp, 1, (X * Yp) rem ?p}
	end.

% 5.1.4. Point addition - https://datatracker.ietf.org/doc/html/rfc8032#section-5.1.4

edwards_add({X1, Y1, Z1, T1}, {X2, Y2, Z2, T2}) ->
	A = ((Y1 - X1) * (Y2 - X2)) rem ?p,
	B = ((Y1 + X1) * (Y2 + X2)) rem ?p,
	C = (T1 * 2 * ?d * T2) rem ?p,
	D = (Z1 * 2 * Z2) rem ?p,
	E = B - A,
	F = D - C,
	G = D + C,
	H = B + A,
	X3 = E * F,
	Y3 = G * H,
	T3 = E * H,
	Z3 = F * G,
	{X3 rem ?p, Y3 rem ?p, Z3 rem ?p, T3 rem ?p}.

edwards_double(P) ->
	edwards_add(P, P).

edwards_equal({X1, Y1, Z1, _T1}, {X2, Y2, Z2, _T2}) ->
	Z1i = ?inv(Z1),
	X1p = ?math:mod((X1 * Z1i), ?p),
	Y1p = ?math:mod((Y1 * Z1i), ?p),
	Z2i = ?inv(Z2),
	X2p = ?math:mod((X2 * Z2i), ?p),
	Y2p = ?math:mod((Y2 * Z2i), ?p),
	{X1p, Y1p} =:= {X2p, Y2p}.

scalarmult(_P, 0) ->
	{0, 1, 1, 0};
scalarmult(P, E) ->
	Q = scalarmult(P, E div 2),
	QQ = edwards_double(Q),
	case E band 1 of
		0 ->
			QQ;
		1 ->
			edwards_add(QQ, P)
	end.

scalarmult_base(E) ->
	scalarmult(?B, E).

normalize_point({X, Y, Z, _T}) ->
	Zi = ?inv(Z),
	Xp = ?math:mod((X * Zi), ?p),
	Yp = ?math:mod((Y * Zi), ?p),
	Zp = ?math:mod((Z * Zi), ?p),
	{Xp, Yp, Zp, ?math:mod((Xp * Yp), ?p)}.

% 5.1.5. Key Generation - https://datatracker.ietf.org/doc/html/rfc8032#section-5.1.5

secret() ->
	crypto:strong_rand_bytes(?secretbytes).

secret_to_curve25519(Secret = << _:?secretbytes/binary >>) ->
	<< HHead0:8/integer, HBody:30/binary, HFoot0:8/integer, _/binary >> = ?H(Secret),
	HHead = HHead0 band 248,
	HFoot = (HFoot0 band 63) bor 64,
	<< HHead:8/integer, HBody/binary, HFoot:8/integer >>.

secret_to_pk(Secret = << _:?secretbytes/binary >>) ->
	<< As:?b/unsigned-little-integer-unit:1 >> = secret_to_curve25519(Secret),
	A = scalarmult(?B, As),
	encode_point(A).

keypair() ->
	Secret = secret(),
	keypair(Secret).

keypair(Secret = << _:?secretbytes/binary >>) ->
	PK = secret_to_pk(Secret),
	SK = << Secret/binary, PK/binary >>,
	{PK, SK}.

sk_to_secret(<< Secret:?secretbytes/binary, _:?publickeybytes/binary >>) ->
	Secret.

sk_to_pk(<< _:?secretbytes/binary, PK:?publickeybytes/binary >>) ->
	PK.

sk_to_curve25519(<< Secret:?secretbytes/binary, _:?publickeybytes/binary >>) ->
	secret_to_curve25519(Secret).

pk_to_curve25519(<< PK:?publickeybytes/binary >>) ->
	_A = {_X, Y, _Z, _T} = decode_point(PK),
	U = ?math:mod((1 + Y) * ?inv(1 - Y), ?p),
	<< U:?b/unsigned-little-integer-unit:1 >>.

% 5.1.6. Sign - https://datatracker.ietf.org/doc/html/rfc8032#section-5.1.6

dom2(0, <<>>) ->
	<<>>;
dom2(PHFlag, C) when (PHFlag =:= 0 orelse PHFlag =:= 1) andalso is_binary(C) ->
	<<"SigEd25519 no Ed25519 collisions", PHFlag:8, (byte_size(C)):8/integer, C/binary>>.

sign_internal(M, << Secret:?secretbytes/binary, PK:?publickeybytes/binary >>, PHFlag, C)
		when is_binary(M)
		andalso (PHFlag =:= 0 orelse PHFlag =:= 1)
		andalso is_binary(C) ->
	% Recalculate PK to prevent misuse as described in https://github.com/MystenLabs/ed25519-unsafe-libs
	PK = secret_to_pk(Secret),
	Dom2 = dom2(PHFlag, C),
	<< HHead0:8/integer, HBody:30/binary, HFoot0:8/integer, HTail:32/binary >> = ?H(Secret),
	HHead = HHead0 band 248,
	HFoot = (HFoot0 band 63) bor 64,
	<< As:?b/unsigned-little-integer-unit:1 >> = << HHead:8/integer, HBody/binary, HFoot:8/integer >>,
	<< Rs:?HBits/unsigned-little-integer-unit:1 >> = ?H(<< Dom2/binary, HTail/binary, M/binary >>),
	R = encode_point(scalarmult(?B, Rs)),
	<< K:?HBits/unsigned-little-integer-unit:1 >> = ?H(<< Dom2/binary, R/binary, PK/binary, M/binary >>),
	S = ?math:mod(Rs + (K * As), ?l),
	<< R/binary, S:?b/unsigned-little-integer-unit:1 >>.

ed25519_sign(M, SK = << _:?secretkeybytes/binary >>) when is_binary(M) ->
	sign_internal(M, SK, 0, <<>>).

ed25519ctx_sign(M, SK = << _:?secretkeybytes/binary >>, C) when is_binary(M) andalso is_binary(C) ->
	sign_internal(M, SK, 0, C).

ed25519ph_sign(M, SK = << _:?secretkeybytes/binary >>) when is_binary(M) ->
	sign_internal(?PH(M), SK, 1, <<>>).

ed25519ph_sign(M, SK = << _:?secretkeybytes/binary >>, C) when is_binary(M) andalso is_binary(C) ->
	sign_internal(?PH(M), SK, 1, C).

% 5.1.7. Verify - https://datatracker.ietf.org/doc/html/rfc8032#section-5.1.7

verify_internal(<< R:?b/bitstring, S:?b/unsigned-little-integer-unit:1 >>, M, PK = << _:?publickeybytes/binary >>, PHFlag, C)
		when is_binary(M)
		andalso (PHFlag =:= 0 orelse PHFlag =:= 1)
		andalso is_binary(C) ->
	Dom2 = dom2(PHFlag, C),
	A = decode_point(PK),
	<< K:?HBits/unsigned-little-integer-unit:1 >> = ?H(<< Dom2/binary, R/binary, PK/binary, M/binary >>),
	edwards_equal(scalarmult(?B, S), edwards_add(decode_point(R), scalarmult(A, K)));
verify_internal(Sig, M, _PK = << _:?publickeybytes/binary >>, PHFlag, C)
		when is_binary(Sig)
		andalso is_binary(M)
		andalso (PHFlag =:= 0 orelse PHFlag =:= 1)
		andalso is_binary(C) ->
	false.

ed25519_verify(Sig, M, PK = << _:?publickeybytes/binary >>) when is_binary(Sig) andalso is_binary(M) ->
	verify_internal(Sig, M, PK, 0, <<>>).

ed25519ctx_verify(Sig, M, PK = << _:?publickeybytes/binary >>, C) when is_binary(Sig) andalso is_binary(M) andalso is_binary(C) ->
	verify_internal(Sig, M, PK, 0, C).

ed25519ph_verify(Sig, M, PK = << _:?publickeybytes/binary >>) when is_binary(Sig) andalso is_binary(M) ->
	verify_internal(Sig, ?PH(M), PK, 1, <<>>).

ed25519ph_verify(Sig, M, PK = << _:?publickeybytes/binary >>, C) when is_binary(Sig) andalso is_binary(M) andalso is_binary(C) ->
	verify_internal(Sig, ?PH(M), PK, 1, C).
