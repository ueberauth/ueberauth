%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Elliptic Curves for Security - X448
%%% See https://tools.ietf.org/html/rfc7748
%%% @end
%%% Created :  07 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_x448).

%% API
-export([coordinate_to_edwards448_4isogeny/1]).
-export([vrecover/1]).
-export([xrecover/1]).
-export([curve448/2]).
-export([clamp_scalar/1]).
-export([decode_scalar/1]).
-export([montgomery_add/3]).
-export([montgomery_double/1]).
-export([scalarmult/2]).
-export([scalarmult_base/1]).
-export([x448/2]).
-export([x448_base/1]).
-export([keypair/0]).
-export([keypair/1]).
-export([sk_to_pk/1]).

%% Macros
-define(math, jose_jwa_math).
-define(inv(Z), ?math:expmod(Z, ?p - 2, ?p)). % $= z^{-1} \mod p$, for z != 0
-define(d, 611975850744529176160423220965553317543219696871016626328968936415087860042636474891785599283666020414768678979989378147065462815545017).
% 4.2. Curve448 - https://tools.ietf.org/html/rfc7748#section-4.2
-define(p, 726838724295606890549323807888004534353641360687318060281490199180612328166730772686396383698676545930088884461843637361053498018365439). % ?math:intpow(2, 448) - ?math:intpow(2, 224) - 1
-define(A, 156326).
-define(A2sqrt, 528950257000142451010969798134146496096806208096258258133290419984524923934728256972792120570883515182233459997657945594599653183173011). % ?math:expmod((?A - 2), (?p + 1) div 4, ?p)
-define(order, 181709681073901722637330951972001133588410340171829515070372549795146003961539585716195755291692375963310293709091662304773755859649779). % ?math:intpow(2, 446) - 16#8335dc163bb124b65129c96fde933d8d723a70aadc873d6d54a7bb0d
-define(cofactor, 4).
-define(u, 5).
-define(v, 355293926785568175264127502063783334808976399387714271831880898435169088786967410002932673765864550910142774147268105838985595290606362).
-define(b, 448).
-define(a24, 39081). % (?A - 2) div 4
-define(scalarbytes, 56). % (?b + 7) div 8
-define(coordinatebytes, 56). % (?b + 7) div 8

-define(publickeybytes, 56). % ?coordinatebytes
-define(secretkeybytes, 56). % ?scalarbytes

%%====================================================================
%% API
%%====================================================================

coordinate_to_edwards448_4isogeny(<< U:?b/unsigned-little-integer-unit:1 >>) ->
	V = vrecover(U),
	% -(u^5 - 2*u^3 - 4*u*v^2 + u)/(u^5 - 2*u^2*v^2 - 2*u^3 - 2*v^2 + u)
	U2 = ?math:expmod(U, 2, ?p),
	U3 = ?math:expmod(U, 3, ?p),
	U5 = ?math:mod(U2*U3, ?p),
	V2 = ?math:expmod(V, 2, ?p),
	YN = ?math:mod(-(U5 - (2*U3) - (4*U*V2) + U), ?p),
	YD = ?inv((U5 - (2*U2*V2) - (2*U3) - (2*V2) + U)),
	Y = ?math:mod(YN*YD, ?p),
	% 4*v*(u^2 - 1)/(u^4 - 2*u^2 + 4*v^2 + 1)
	U4 = ?math:mod(U2*U2, ?p),
	XN = ?math:mod((4*V*(U2 - 1)), ?p),
	XD = ?inv((U4 - (2*U2) + (4*V2) + 1)),
	X = ?math:mod(XN*XD, ?p),
	jose_jwa_ed448:encode_point({X, Y, 1}).

vrecover(U) ->
	Y = ?math:mod(((1 + U) * ?inv(1 - U)), ?p),
	X = xrecover(Y),
	UX = (U * ?inv(X)) rem ?p,
	V = (?A2sqrt * UX) rem ?p,
	case V rem 2 of
		0 ->
			V;
		_ ->
			?p - V
	end.

xrecover(Y) ->
	YY = Y * Y,
	U = (YY - 1) rem ?p,
	V = ((?d * YY) - 1) rem ?p,
	A = (U * ?inv(V)) rem ?p,
	X = ?math:expmod(A, (?p + 1) div 4, ?p),
	case ((X * X) - A) rem ?p =:= 0 of
		true -> % x^2 = a (mod p).  Then x is a square root.
			case X rem 2 of
				0 ->
					X;
				_ ->
					?p - X
			end;
		false -> % a is not a square modulo p.
			erlang:error(badarg)
	end.

curve448(N, Base) ->
	One = {Base, 1},
	Two = montgomery_double(One),
	% f(m) evaluates to a tuple containing the mth multiple and the
	% (m+1)th multiple of base.
	F = fun
		F(1) ->
			{One, Two};
		F(M) when (M band 1) =:= 1 ->
			{Pm, Pm1} = F(M div 2),
			{montgomery_add(Pm, Pm1, One), montgomery_double(Pm1)};
		F(M) ->
			{Pm, Pm1} = F(M div 2),
			{montgomery_double(Pm), montgomery_add(Pm, Pm1, One)}
	end,
	{{X, Z}, _} = F(N),
	(X * ?inv(Z)) rem ?p.

% 5. The X25519 and X448 functions - https://tools.ietf.org/html/rfc7748#section-5

clamp_scalar(K0) when is_integer(K0) ->
	K1 = K0 band (bnot 3),
	K2 = K1 bor (128 bsl (?b - 8)),
	K2.

decode_scalar(<< K0:8/integer, KBody:(?b - 16)/bitstring, K55:8/integer >>) ->
	<< K:?b/unsigned-little-integer-unit:1 >> = << (K0 band 252):8/integer, KBody/bitstring, (K55 bor 128):8/integer >>,
	K.

montgomery_add({Xn, Zn}, {Xm, Zm}, {Xd, Zd}) ->
	Z0 = (Xm * Xn) - (Zm * Zn),
	Z1 = (Xm * Zn) - (Zm * Xn),
	X = 4 * Z0 * Z0 * Zd,
	Z = 4 * Z1 * Z1 * Xd,
	{X rem ?p, Z rem ?p}.

montgomery_double({Xn, Zn}) ->
	Xn2 = Xn * Xn,
	Zn2 = Zn * Zn,
	X = (Xn2 - Zn2),
	X2 = X * X,
	Z = 4 * Xn * Zn * (Xn2 + (?A * Xn * Zn) + Zn2),
	{X2 rem ?p, Z rem ?p}.

scalarmult(<< Kb:?b/unsigned-little-integer-unit:1 >>, << U:?b/unsigned-little-integer-unit:1 >>) ->
	K = clamp_scalar(Kb),
	R = curve448(K, U),
	<< R:?b/unsigned-little-integer-unit:1 >>.

scalarmult_base(<< Kb:?b/unsigned-little-integer-unit:1 >>) ->
	K = clamp_scalar(Kb),
	R = curve448(K, ?u),
	<< R:?b/unsigned-little-integer-unit:1 >>.

x448(SK = << _:?secretkeybytes/binary >>, PK = << _:?publickeybytes/binary >>) ->
	scalarmult(SK, PK).

x448_base(SK = << _:?secretkeybytes/binary >>) ->
	scalarmult_base(SK).

keypair() ->
	keypair(crypto:strong_rand_bytes(?secretkeybytes)).

keypair(SK = << _:?secretkeybytes/binary >>) ->
	PK = sk_to_pk(SK),
	{PK, SK}.

sk_to_pk(SK = << _:?secretkeybytes/binary >>) ->
	x448_base(SK).
