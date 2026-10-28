%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%% 
%%% @end
%%% Created :  06 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_math).

%% Public API
-export([expmod/3]).
-export([exprem/3]).
-export([intpow/2]).
-export([mod/2]).
-export([mod_pow/3]).

%% Private API
-export([expmod_fast/3]).
-export([expmod_slow/3]).
-export([exprem_fast/3]).
-export([exprem_slow/3]).

%%====================================================================
%% Public API
%%====================================================================

expmod(B, E, M) ->
	expmod_fast(B, E, M).

exprem(B, E, M) ->
	exprem_fast(B, E, M).

intpow(B, E) when is_integer(B) andalso is_integer(E) andalso E >= 0 ->
	case B of
		0 ->
			0;
		1 ->
			1;
		2 ->
			1 bsl E;
		_ ->
			intpow(B, E, 1)
	end.

mod(B, M) ->
	(B rem M + M) rem M.

mod_pow(B, E, M) ->
	Bytes = crypto:mod_pow(B, E, M),
	Size = byte_size(Bytes),
	<< ((crypto:bytes_to_integer(Bytes) + M) rem M):Size/signed-big-integer-unit:8 >>.

%%====================================================================
%% Private API
%%====================================================================

% @private
expmod_fast(B, E, M) ->
	(exprem_fast(B, E, M) + M) rem M.

% @private
expmod_slow(B, E, M) ->
	(exprem_slow(B, E, M) + M) rem M.

% @private
exprem_fast(B, E, M) when B < 0 andalso E rem 2 =/= 0 ->
	-exprem_fast(abs(B), E, M);
exprem_fast(B, E, M) when B < 0 ->
	exprem_fast(abs(B), E, M);
exprem_fast(B, E, M) ->
	crypto:bytes_to_integer(crypto:mod_pow(B, E, M)).

%% @private
exprem_slow(_B, 0, _M) ->
	1;
exprem_slow(B, E, M) ->
	T0 = exprem_slow(B, E div 2, M),
	T = (T0 * T0) rem M,
	case E rem 2 of
		0 ->
			T band M;
		_ ->
			(T * B) rem M
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
intpow(B, E, R) when (E rem 2) =:= 0 ->
	intpow(B * B, E div 2, R);
intpow(B, E, R) when (E div 2) =:= 0 ->
	B * R;
intpow(B, E, R) ->
	intpow(B * B, E div 2, B * R).
