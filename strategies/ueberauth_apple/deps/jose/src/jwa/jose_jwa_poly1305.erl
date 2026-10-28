%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc ChaCha20 and Poly1305 for IETF Protocols
%%% See https://tools.ietf.org/html/rfc7539
%%% @end
%%% Created :  31 May 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_poly1305).

%% API
-export([mac/2]).
-export([mac_init/1]).
-export([mac_update/2]).
-export([mac_final/1]).

%% Macros
-define(math, jose_jwa_math).
-define(clamp(R), R band 16#0ffffffc0ffffffc0ffffffc0fffffff).
-define(p, 16#3fffffffffffffffffffffffffffffffb).

%%====================================================================
%% API functions
%%====================================================================

mac(M, K)
		when is_binary(M)
		andalso is_binary(K)
		andalso bit_size(K) =:= 256 ->
	mac_final(mac_update(mac_init(K), M)).

mac_init(<< R:128/unsigned-little-integer-unit:1, S:128/unsigned-little-integer-unit:1 >>) ->
	A = 0,
	<<
		(?clamp(R)):128/unsigned-little-integer-unit:1,
		A:136/unsigned-little-integer-unit:1,
		S:128/unsigned-little-integer-unit:1,
		0:1656
	>>.

mac_update(C = << _:392, 0:1656 >>, <<>>) ->
	C;
mac_update(<<
			R:128/unsigned-little-integer-unit:1,
			A:136/unsigned-little-integer-unit:1,
			S:128/unsigned-little-integer-unit:1,
			0:1656
		>>, <<
			Block:128/bitstring,
			Rest/binary
		>>) ->
	<< B:136/unsigned-little-integer-unit:1 >> = <<
		Block:128/bitstring,
		1:8/unsigned-little-integer-unit:1
	>>,
	mac_update(<<
		R:128/unsigned-little-integer-unit:1,
		(?math:mod((A + B) * R, ?p)):136/unsigned-little-integer-unit:1,
		S:128/unsigned-little-integer-unit:1,
		0:1656
	>>, Rest);
mac_update(<<
			R:128/unsigned-little-integer-unit:1,
			A:136/unsigned-little-integer-unit:1,
			S:128/unsigned-little-integer-unit:1,
			0:1656
		>>, <<
			Block/binary
		>>) ->
	BlockBits = bit_size(Block),
	PadBits = 136 - BlockBits - 8,
	<< B:136/unsigned-little-integer-unit:1 >> = <<
		Block/binary,
		1:8/unsigned-little-integer-unit:1,
		0:PadBits/unsigned-little-integer-unit:1
	>>,
	<<
		R:128/unsigned-little-integer-unit:1,
		(?math:mod((A + B) * R, ?p)):136/unsigned-little-integer-unit:1,
		S:128/unsigned-little-integer-unit:1,
		0:1656
	>>.

mac_final(<<
			_R:128/unsigned-little-integer-unit:1,
			A:136/unsigned-little-integer-unit:1,
			S:128/unsigned-little-integer-unit:1,
			0:1656
		>>) ->
	<< (A + S):128/unsigned-little-integer-unit:1 >>.
