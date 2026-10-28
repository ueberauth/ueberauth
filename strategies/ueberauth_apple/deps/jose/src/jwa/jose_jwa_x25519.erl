%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Elliptic Curves for Security - X25519
%%% See https://tools.ietf.org/html/rfc7748
%%%
%%% SECURITY WARNING: this pure Erlang implementation is NOT constant-time.
%%%
%%% `curve25519/2' is operation-count balanced (every step performs exactly
%%% one `montgomery_add/3' and one `montgomery_double/1', and clamping fixes
%%% the recursion depth), so the coarse "skipped operation" leak is absent.
%%% It is still not constant-time: the ladder branches on individual bits of
%%% the secret scalar to route its operands, and the underlying Erlang bignum
%%% `*' / `rem' operations and the `expmod/3'-based field inversion all run in
%%% value-dependent time. Execution time is therefore correlated with the
%%% private scalar. Pure Erlang integer arithmetic cannot be made
%%% constant-time.
%%%
%%% This module is a last-resort fallback for platforms with no native
%%% implementation. `jose' prefers a native module
%%% (`libdecaf', `libsodium', or OTP `crypto') whenever one works, so this
%%% code is not reached for X25519 on a stock OTP build with `crypto' x25519
%%% support. Do not select it explicitly for long-lived private keys in a
%%% timing-observable context; use `jose_curve25519_crypto' (which calls
%%% `crypto:generate_key/3' and `crypto:compute_key/4' with `x25519') or a
%%% NIF-backed module instead.
%%% @end
%%% Created :  06 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_x25519).

%% API
-export([coordinate_to_edwards25519/1]).
-export([curve25519/2]).
-export([clamp_scalar/1]).
-export([decode_scalar/1]).
-export([montgomery_add/3]).
-export([montgomery_double/1]).
-export([scalarmult/2]).
-export([scalarmult_base/1]).
-export([x25519/2]).
-export([x25519_base/1]).
-export([keypair/0]).
-export([keypair/1]).
-export([sk_to_pk/1]).

%% Macros
-define(math, jose_jwa_math).
-define(inv(Z), ?math:expmod(Z, ?p - 2, ?p)). % $= z^{-1} \mod p$, for z != 0
% 4.1. Curve25519 - https://tools.ietf.org/html/rfc7748#section-4.1
-define(p, 57896044618658097711785492504343953926634992332820282019728792003956564819949). % ?math:intpow(2, 255) - 19
-define(A, 486662).
-define(order, 7237005577332262213973186563042994240857116359379907606001950938285454250989). % ?math:intpow(2, 252) + 16#14def9dea2f79cd65812631a5cf5d3ed
-define(cofactor, 8).
-define(u, 9).
-define(v, 14781619447589544791020593568409986887264606134616475288964881837755586237401).
-define(b, 256).
-define(a24, 121665). % (?A - 2) div 4
-define(scalarbytes, 32). % (?b + 7) div 8
-define(coordinatebytes, 32). % (?b + 7) div 8

-define(publickeybytes, 32). % ?coordinatebytes
-define(secretkeybytes, 32). % ?scalarbytes

%%====================================================================
%% API
%%====================================================================

coordinate_to_edwards25519(<< U:?b/unsigned-little-integer-unit:1 >>) ->
	Y = ?math:mod((U - 1) * ?inv(U + 1), ?p),
	Xp = jose_jwa_ed25519:xrecover(Y),
	X = case Xp band 1 of
		0 ->
			Xp;
		_ ->
			?p - Xp
	end,
	jose_jwa_ed25519:encode_point({X, Y, 1, X * Y}).

curve25519(N, Base) ->
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

clamp_scalar(K0) ->
	K1 = K0 band (bnot 7),
	K2 = K1 band (bnot (128 bsl (?b - 8))),
	K3 = K2 bor (64 bsl (?b - 8)),
	K3.

decode_scalar(<< K0:8/integer, KBody:(?b - 16)/bitstring, K31:8/integer >>) ->
	<< K:?b/unsigned-little-integer-unit:1 >> = << (K0 band 248):8/integer, KBody/bitstring, ((K31 band 127) bor 64):8/integer >>,
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
	R = curve25519(K, U),
	<< R:?b/unsigned-little-integer-unit:1 >>.

scalarmult_base(<< Kb:?b/unsigned-little-integer-unit:1 >>) ->
	K = clamp_scalar(Kb),
	R = curve25519(K, ?u),
	<< R:?b/unsigned-little-integer-unit:1 >>.

x25519(SK = << _:?secretkeybytes/binary >>, PK = << _:?publickeybytes/binary >>) ->
	scalarmult(SK, PK).

x25519_base(SK = << _:?secretkeybytes/binary >>) ->
	scalarmult_base(SK).

keypair() ->
	keypair(crypto:strong_rand_bytes(?secretkeybytes)).

keypair(SK = << _:?secretkeybytes/binary >>) ->
	PK = sk_to_pk(SK),
	{PK, SK}.

sk_to_pk(SK = << _:?secretkeybytes/binary >>) ->
	x25519_base(SK).
