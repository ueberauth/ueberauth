%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Advanced Encryption Standard (AES) Key Wrap Algorithm
%%% See RFC 3394 [https://tools.ietf.org/html/rfc3394]
%%% @end
%%% Created :  22 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_aes_kw).

%% API
-export([wrap/2]).
-export([wrap/3]).
-export([unwrap/2]).
-export([unwrap/3]).

-define(MSB64,      1/unsigned-big-integer-unit:64).
-define(DEFAULT_IV, << 16#A6A6A6A6A6A6A6A6:?MSB64 >>).

%%====================================================================
%% API functions
%%====================================================================

wrap(PlainText, KEK) ->
	wrap(PlainText, KEK, ?DEFAULT_IV).

wrap(PlainText, KEK, IV)
		when (byte_size(PlainText) rem 8) =:= 0
		andalso (bit_size(KEK) =:= 128
			orelse bit_size(KEK) =:= 192
			orelse bit_size(KEK) =:= 256) ->
	Buffer = << IV/binary, PlainText/binary >>,
	BlockCount = (byte_size(Buffer) div 8) - 1,
	do_wrap(Buffer, 0, BlockCount, KEK).

unwrap(CipherText, KEK) ->
	unwrap(CipherText, KEK, ?DEFAULT_IV).

unwrap(CipherText, KEK, IV)
		when (byte_size(CipherText) rem 8) =:= 0
		andalso (bit_size(KEK) =:= 128
			orelse bit_size(KEK) =:= 192
			orelse bit_size(KEK) =:= 256) ->
	BlockCount = (byte_size(CipherText) div 8) - 1,
	IVSize = byte_size(IV),
	case do_unwrap(CipherText, 5, BlockCount, KEK) of
		<< IV:IVSize/binary, PlainText/binary >> ->
			PlainText;
		_ ->
			erlang:error({badarg, [CipherText, KEK, IV]})
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
do_wrap(Buffer, 6, _BlockCount, _KEK) ->
	Buffer;
do_wrap(Buffer, J, BlockCount, KEK) ->
	do_wrap(do_wrap(Buffer, J, 1, BlockCount, KEK), J + 1, BlockCount, KEK).

%% @private
do_wrap(Buffer, _J, I, BlockCount, _KEK) when I > BlockCount ->
	Buffer;
do_wrap(<< A0:8/binary, Rest/binary >>, J, I, BlockCount, KEK) ->
	HeadSize = (I - 1) * 8,
	<< Head:HeadSize/binary, B0:8/binary, Tail/binary >> = Rest,
	Round = (BlockCount * J) + I,
	Data = << A0/binary, B0/binary >>,
	<< A1:?MSB64, B1/binary >> = jose_jwa:block_encrypt({aes_ecb, bit_size(KEK)}, KEK, Data),
	A2 = A1 bxor Round,
	do_wrap(<< A2:?MSB64, Head/binary, B1/binary, Tail/binary >>, J, I + 1, BlockCount, KEK).

%% @private
do_unwrap(Buffer, J, _BlockCount, _KEK) when J < 0 ->
	Buffer;
do_unwrap(Buffer, J, BlockCount, KEK) ->
	do_unwrap(do_unwrap(Buffer, J, BlockCount, BlockCount, KEK), J - 1, BlockCount, KEK).

%% @private
do_unwrap(Buffer, _J, I, _BlockCount, _KEK) when I < 1 ->
	Buffer;
do_unwrap(<< A0:?MSB64, Rest/binary >>, J, I, BlockCount, KEK) ->
	HeadSize = (I - 1) * 8,
	<< Head:HeadSize/binary, B0:8/binary, Tail/binary >> = Rest,
	Round = (BlockCount * J) + I,
	A1 = A0 bxor Round,
	Data = << A1:?MSB64, B0/binary >>,
	<< A2:8/binary, B1/binary >> = jose_jwa:block_decrypt({aes_ecb, bit_size(KEK)}, KEK, Data),
	do_unwrap(<< A2/binary, Head/binary, B1/binary, Tail/binary >>, J, I - 1, BlockCount, KEK).
