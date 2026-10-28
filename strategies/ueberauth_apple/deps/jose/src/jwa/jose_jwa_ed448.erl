%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Edwards-curve Digital Signature Algorithm (EdDSA) - Ed448, Ed448ph
%%% See https://datatracker.ietf.org/doc/html/rfc8032
%%% @end
%%% Created :  20 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_ed448).

%% API
-export([xrecover/2]).
-export([encode_point/1]).
-export([decode_point/1]).
-export([edwards_add/2]).
-export([edwards_double/1]).
-export([edwards_equal/2]).
-export([scalarmult/2]).
-export([scalarmult_base/1]).
-export([normalize_point/1]).
-export([secret/0]).
-export([secret_to_curve448/1]).
-export([secret_to_pk/1]).
-export([keypair/0]).
-export([keypair/1]).
-export([sk_to_secret/1]).
-export([sk_to_pk/1]).
-export([sk_to_curve448/1]).
-export([pk_to_curve448/1]).
-export([dom4/2]).
-export([sign_internal/4]).
-export([ed448_sign/2]).
-export([ed448_sign/3]).
-export([ed448ph_sign/2]).
-export([ed448ph_sign/3]).
-export([verify_internal/5]).
-export([ed448_verify/3]).
-export([ed448_verify/4]).
-export([ed448ph_verify/3]).
-export([ed448ph_verify/4]).

%% Macros
-define(math, jose_jwa_math).
-define(inv(Z), ?math:expmod(Z, ?p - 2, ?p)). % $= z^{-1} \mod p$, for z != 0
% 3. EdDSA Algorithm - https://datatracker.ietf.org/doc/html/rfc8032#section-3
% 5.2. Ed448ph and Ed448 - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2
-define(d, -39081). % -39081
% -define(d, 611975850744529176160423220965553317543219696871016626328968936415087860042636474891785599283666020414768678979989378147065462815545017).
%% 1. An odd prime power p.  EdDSA uses an elliptic curve over the
%%    finite field GF(p).
-define(p, 726838724295606890549323807888004534353641360687318060281490199180612328166730772686396383698676545930088884461843637361053498018365439). % ?math:intpow(2, 448) - ?math:intpow(2, 224) - 1
%% 2. An integer b with 2^(b-1) > p.  EdDSA public keys have exactly b
%%    bits, and EdDSA signatures have exactly 2*b bits.  b is
%%    recommended to be multiple of 8, so public key and signature
%%    lengths are integral number of octets.
-define(b, 456). % ?math:intpow(2, ?b - 1) > ?p
-define(b_curve448, 448).
%% 3. A (b-1)-bit encoding of elements of the finite field GF(p).
-define(GFp, <<
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FE,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,16#FF,
	16#00
>>). % << ?p:(?b - 1)/unsigned-little-integer-unit:1, 0:1 >>
%% 4. A cryptographic hash function H producing 2*b-bit output.
%%    Conservative hash functions are recommended and do not have much
%%    impact on the total cost of EdDSA.
-define(HBits, 912). % ?b * 2
-define(HBytes, 114). % (?Hbits + 7) div 8
% -define(H(M), jose_sha3:shake256(<< "SigEd448", 16#00, 16#00, M/binary >>, ?HBytes)).
-define(H(M), jose_sha3:shake256(M, ?HBytes)).
%% 5. An integer c that is 2 or 3.  Secret EdDSA scalars are multiples
%%    of 2^c.  The integer c is the base-2 logarithm of the so called
%%    cofactor.
-define(c, 2).
%% 6. An integer n with c <= n < b.  Secret EdDSA scalars have exactly
%%    n + 1 bits, with the top bit (the 2^n position) always set and
%%    the bottom c bits always cleared.
-define(n, 448). % ?c =< ?n andalso ?n < ?b
%% 7. A nonzero square element a of GF(p).  The usual recommendation
%%    for best performance is a = -1 if p mod 4 = 1, and a = 1 if p
%%    mod 4 = 3.
-define(a, 1).
%% 8. An element B != (0,1) of the set E = { (x,y) is a member of
%%    GF(p) x GF(p) such that a * x^2 + y^2 = 1 + d * x^2 * y^2 }.
-define(By, 298819210078481492676017930443930673437544040154080242095928241372331506189835876003536878655418784733982303233503462500531545062832660).
-define(Bx, 224580040295924300187604334099896036246789641632564134246125461686950415467406032909029192869357953282578032075146446173674602635247710). % xrecover(?By)
-define(B, {?Bx, ?By, 1}). % {?Bx, ?By, 1}
% (?a * ?math:intpow(?Bx, 2) + ?math:intpow(?By, 2)) rem ?p == (1 + ?d * ?math:intpow(?Bx, 2) * ?math:intpow(?By, 2)) rem ?p
%% 9. An odd prime l such that [l]B = 0 and 2^c * l = #E.  The number
%%    #E (the number of points on the curve) is part of the standard
%%    data provided for an elliptic curve E.
-define(l, 181709681073901722637330951972001133588410340171829515070372549795146003961539585716195755291692375963310293709091662304773755859649779). % ?math:intpow(2, 446) + 13818066809895115352007386748515426880336692474882178609894547503885
-define(E, ?math:intpow(2, ?c) * ?l).
%% 10. A "prehash" function PH.  PureEdDSA means EdDSA where PH is the
%%     identity function, i.e., PH(M) = M.  HashEdDSA means EdDSA where
%%     PH generates a short output, no matter how long the message is;
%%     for example, PH(M) = SHA-512(M).
-define(PHBits, 512).
-define(PHBytes, 64). % (?PHBits + 7) div 8
-define(PH(C, M), jose_sha3:shake256(<< "SigEd448", 16#02, (byte_size(C)):8/integer, C/binary, M/binary >>, ?PHBytes)).
% -define(PH(M), jose_sha3:shake256(M, ?PHBytes)).

-define(secretbytes,    57). % (?b + 7) div 8
-define(publickeybytes, 57). % (?b + 7) div 8
-define(secretkeybytes, 114). % ?secretbytes + ?publickeybytes

%%====================================================================
%% API
%%====================================================================

% 5.2.1. Modular arithmetic - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2.1

xrecover(Y, Xb) ->
	YY = Y * Y,
	U = (YY - 1),
	V = (?d * YY - 1),
	A = U * ?inv(V),
	X = ?math:expmod(A, (?p + 1) div 4, ?p),
	case ?math:mod((V * X * X), ?p) =:= ?math:mod(U, ?p) of
		true ->
			case X =:= 0 andalso Xb =:= 1 of
				true ->
					erlang:error(badarg);
				false ->
					case X rem 2 of
						Xb ->
							X;
						_ ->
							?p - X
					end
			end;
		false ->
			erlang:error(badarg)
	end.

% 5.2.2. Encoding - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2.2

encode_point({X, Y, Z}) ->
	Zi = ?inv(Z),
	Xp = ?math:mod((X * Zi), ?p),
	Yp = ?math:mod((Y * Zi), ?p),
	<< YpHead:(?b - 8)/bitstring, _:1/bitstring, YpTail:7/bitstring >> = << Yp:?b/unsigned-little-integer-unit:1 >>,
	<< YpHead/bitstring, (Xp band 1):1/integer, YpTail:7/bitstring >>.

% 5.2.3. Decoding - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2.3

decode_point(<< YpHead:(?b - 8)/bitstring, Xb:1, YpTail:7/bitstring >>) ->
	<< Y:?b/unsigned-little-integer-unit:1 >> = << YpHead/bitstring, 0:1, YpTail/bitstring >>,
	case Y >= ?p of
		true ->
			erlang:error(badarg);
		false ->
			X = xrecover(Y, Xb),
			{X, Y, 1}
	end.

% 5.2.4. Point addition - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2.4

edwards_add({X1, Y1, Z1}, {X2, Y2, Z2}) ->
	Xcp = (X1 * X2) rem ?p,
	Ycp = (Y1 * Y2) rem ?p,
	Zcp = (Z1 * Z2) rem ?p,
	B = (Zcp * Zcp) rem ?p,
	E = (?d * Xcp * Ycp) rem ?p,
	F = (B - E) rem ?p,
	G = (B + E) rem ?p,
	ZcpF = (Zcp * F) rem ?p,
	ZcpG = (Zcp * G) rem ?p,
	X3r = ((X1 + Y1) * (X2 + Y2) - Xcp - Ycp) rem ?p,
	Y3r = (Ycp - Xcp) rem ?p,
	X3 = ?math:mod((ZcpF * X3r), ?p),
	Y3 = ?math:mod((ZcpG * Y3r), ?p),
	Z3 = ?math:mod((F * G), ?p),
	{X3, Y3, Z3}.

edwards_double({X, Y, Z}) ->
	XX = (X * X) rem ?p,
	YY = (Y * Y) rem ?p,
	ZZ = (Z * Z) rem ?p,
	XY = (X + Y) rem ?p,
	F = (XX + YY) rem ?p,
	J = (F - (ZZ + ZZ)) rem ?p,
	XYXY = (XY * XY) rem ?p,
	X3 = ?math:mod(((XYXY - XX - YY) * J), ?p),
	Y3 = ?math:mod((F * (XX - YY)), ?p),
	Z3 = ?math:mod((F * J), ?p),
	{X3, Y3, Z3}.

edwards_equal({X1, Y1, Z1}, {X2, Y2, Z2}) ->
	Xn1 = ?math:mod((X1 * Z2), ?p),
	Xn2 = ?math:mod((X2 * Z1), ?p),
	Yn1 = ?math:mod((Y1 * Z2), ?p),
	Yn2 = ?math:mod((Y2 * Z1), ?p),
	Xn1 =:= Xn2 andalso Yn1 =:= Yn2.

scalarmult(_P, 0) ->
	{0, 1, 1};
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

normalize_point({X, Y, Z}) ->
	Zi = ?inv(Z),
	Xp = ?math:mod((X * Zi), ?p),
	Yp = ?math:mod((Y * Zi), ?p),
	Zp = ?math:mod((Z * Zi), ?p),
	{Xp, Yp, Zp}.

% 5.2.5. Key Generation - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2.5

secret() ->
	crypto:strong_rand_bytes(?secretbytes).

secret_to_curve448(Secret = << _:?secretbytes/binary >>) ->
	<< HHead0:6/bitstring, _:2/bitstring, HBody:54/binary, _:1/bitstring, HKnee0:7/bitstring, _HFoot0:8/integer, _/binary >> = ?H(Secret),
	<< HHead:8/integer >> = << HHead0:6/bitstring, 0:2/integer >>,
	<< HKnee:8/integer >> = << 0:1/integer, HKnee0:7/bitstring >>,
	HFoot = 0,
	<< Scalar:?b/unsigned-little-integer-unit:1 >> = << HHead:8/integer, HBody/binary, HKnee:8/integer, HFoot:8/integer >>,
	Clamped = jose_jwa_x448:clamp_scalar(Scalar),
	<< Clamped:?b_curve448/unsigned-little-integer-unit:1 >>.

secret_to_pk(Secret = << _:?secretbytes/binary >>) ->
	<< As:?b_curve448/unsigned-little-integer-unit:1 >> = secret_to_curve448(Secret),
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

sk_to_curve448(<< Secret:?secretbytes/binary, _:?publickeybytes/binary >>) ->
	secret_to_curve448(Secret).

pk_to_curve448(<< PK:?publickeybytes/binary >>) ->
	% u = y^2/x^2
	_A = {X, Y, _Z} = decode_point(PK),
	U = ?math:mod((Y * Y) * ?inv(X * X), ?p),
	% v = (2 - x^2 - y^2)*y/x^3
	<< U:?b_curve448/unsigned-little-integer-unit:1 >>.

% 5.2.6. Sign - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2.6

dom4(PHFlag, C) when (PHFlag =:= 0 orelse PHFlag =:= 1) andalso is_binary(C) ->
	<<"SigEd448", PHFlag:8, (byte_size(C)):8/integer, C/binary>>.

sign_internal(M, << Secret:?secretbytes/binary, PK:?publickeybytes/binary >>, PHFlag, C)
		when is_binary(M)
		andalso (PHFlag =:= 0 orelse PHFlag =:= 1)
		andalso is_binary(C) ->
	% Recalculate PK to prevent misuse as described in https://github.com/MystenLabs/ed25519-unsafe-libs
	PK = secret_to_pk(Secret),
	Dom4 = dom4(PHFlag, C),
	<< HHead0:6/bitstring, _:2/bitstring, HBody:54/binary, _:1/bitstring, HKnee0:7/bitstring, _HFoot0:8/integer, HTail:57/binary >> = ?H(Secret),
	<< HHead:8/integer >> = << HHead0:6/bitstring, 0:2/integer >>,
	<< HKnee:8/integer >> = << 0:1/integer, HKnee0:7/bitstring >>,
	HFoot = 0,
	<< Scalar:?b/unsigned-little-integer-unit:1 >> = << HHead:8/integer, HBody/binary, HKnee:8/integer, HFoot:8/integer >>,
	As = jose_jwa_x448:clamp_scalar(Scalar),
	<< Ri:?HBits/unsigned-little-integer-unit:1 >> = ?H(<< Dom4/binary, HTail/binary, M/binary >>),
	Rs = ?math:mod(Ri, ?l),
	R = encode_point(scalarmult(?B, Rs)),
	<< Ki:?HBits/unsigned-little-integer-unit:1 >> = ?H(<< Dom4/binary, R/binary, PK/binary, M/binary >>),
	K = ?math:mod(Ki, ?l),
	S = ?math:mod(Rs + (K * As), ?l),
	<< R/binary, S:?b/unsigned-little-integer-unit:1 >>.

ed448_sign(M, SK = << _:?secretkeybytes/binary >>) when is_binary(M) ->
	sign_internal(M, SK, 0, <<>>).

ed448_sign(M, SK = << _:?secretkeybytes/binary >>, C) when is_binary(M) andalso is_binary(C) ->
	sign_internal(M, SK, 0, C).

ed448ph_sign(M, SK = << _:?secretkeybytes/binary >>) when is_binary(M) ->
	sign_internal(?PH(<<>>, M), SK, 1, <<>>).

ed448ph_sign(M, SK = << _:?secretkeybytes/binary >>, C) when is_binary(M) andalso is_binary(C) ->
	sign_internal(?PH(C, M), SK, 1, C).

% 5.2.7. Verify - https://datatracker.ietf.org/doc/html/rfc8032#section-5.2.7

verify_internal(<< R:?b/bitstring, S:?b/unsigned-little-integer-unit:1 >>, M, PK = << _:?publickeybytes/binary >>, PHFlag, C)
		when is_binary(M)
		andalso (PHFlag =:= 0 orelse PHFlag =:= 1)
		andalso is_binary(C) ->
	Dom4 = dom4(PHFlag, C),
	A = decode_point(PK),
	<< Ki:?HBits/unsigned-little-integer-unit:1 >> = ?H(<< Dom4/binary, R/binary, PK/binary, M/binary >>),
	K = ?math:mod(Ki, ?l),
	edwards_equal(scalarmult(?B, S), edwards_add(decode_point(R), scalarmult(A, K)));
verify_internal(Sig, M, _PK = << _:?publickeybytes/binary >>, PHFlag, C)
		when is_binary(Sig)
		andalso is_binary(M)
		andalso (PHFlag =:= 0 orelse PHFlag =:= 1)
		andalso is_binary(C) ->
	false.

ed448_verify(Sig, M, PK = << _:?publickeybytes/binary >>) when is_binary(Sig) andalso is_binary(M) ->
	verify_internal(Sig, M, PK, 0, <<>>).

ed448_verify(Sig, M, PK = << _:?publickeybytes/binary >>, C) when is_binary(Sig) andalso is_binary(M) andalso is_binary(C) ->
	verify_internal(Sig, M, PK, 0, C).

ed448ph_verify(Sig, M, PK = << _:?publickeybytes/binary >>) when is_binary(Sig) andalso is_binary(M) ->
	verify_internal(Sig, ?PH(<<>>, M), PK, 1, <<>>).

ed448ph_verify(Sig, M, PK = << _:?publickeybytes/binary >>, C) when is_binary(Sig) andalso is_binary(M) andalso is_binary(C) ->
	verify_internal(Sig, ?PH(C, M), PK, 1, C).
