%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  08 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_sha3).

%% API
-export([rol64/2]).
-export([load64/1]).
-export([store64/1]).
-export([keccak_f_1600/1]).
-export([load_lanes/1]).
-export([store_lanes/1]).
-export([keccak/5]).
-export([keccak_absorb/4]).
-export([keccak_pad/4]).
-export([shake128/2]).
-export([shake256/2]).
-export([sha3_224/1]).
-export([sha3_256/1]).
-export([sha3_384/1]).
-export([sha3_512/1]).

%%====================================================================
%% API functions
%%====================================================================

rol64(A, N) ->
	((A bsr (64 - (N rem 64))) + (A bsl (N rem 64))) rem (1 bsl 64).

keccak_f_1600_on_lanes(Lanes) ->
	keccak_f_1600_on_lanes(Lanes, 1, 0).

keccak_f_1600_on_lanes(Lanes, _R, 24) ->
	Lanes;
keccak_f_1600_on_lanes(Lanes, R, Round) ->
	% θ
	Lanes0 = theta(Lanes),
	% ρ and π
	Lanes1 = rho_and_pi(mget(Lanes0, 1, 0), Lanes0, 1, 0, 0),
	% χ
	Lanes2 = chi(Lanes1, 0),
	% ι
	{Lanes3, Rn} = iota(Lanes2, R, 0),
	keccak_f_1600_on_lanes(Lanes3, Rn, Round + 1).

%% @private
theta(Lanes) ->
	C = list_to_tuple([begin
		E = mget(Lanes, X),
		mget(E, 0) bxor mget(E, 1) bxor mget(E, 2) bxor mget(E, 3) bxor mget(E, 4)
	end || X <- lists:seq(0, 4)]),
	D = list_to_tuple([begin
		mget(C, (X + 4) rem 5) bxor rol64(mget(C, (X + 1) rem 5), 1)
	end || X <- lists:seq(0, 4)]),
	list_to_tuple([begin
		list_to_tuple([begin
			mget(Lanes, X, Y) bxor mget(D, X)
		end || Y <- lists:seq(0, 4)])
	end || X <- lists:seq(0, 4)]).

%% @private
rho_and_pi(_Current, Lanes, _X, _Y, 24) ->
	Lanes;
rho_and_pi(Current, Lanes, X, Y, T) ->
	Xn = Y,
	Yn = ((2 * X) + (3 * Y)) rem 5,
	Zn = rol64(Current, ((T + 1) * (T + 2)) div 2),
	rho_and_pi(mget(Lanes, Xn, Yn), mput(Lanes, Xn, Yn, Zn), Xn, Yn, T + 1).

%% @private
chi(Lanes, 5) ->
	Lanes;
chi(Lanes, Y) ->
	T = list_to_tuple([mget(Lanes, X, Y) || X <- lists:seq(0, 4)]),
	chi(Lanes, T, Y, 0).

chi(Lanes, _T, Y, 5) ->
	chi(Lanes, Y + 1);
chi(Lanes, T, Y, X) ->
	V = mget(T, X) bxor ((bnot mget(T, (X + 1) rem 5)) band mget(T, (X + 2) rem 5)),
	chi(mput(Lanes, X, Y, V), T, Y, X + 1).

%% @private
iota(Lanes, R, 7) ->
	{Lanes, R};
iota(Lanes, R, J) ->
	Rn = ((R bsl 1) bxor ((R bsr 7) * 16#71)) rem 256,
	case Rn band 2 of
		0 ->
			iota(Lanes, Rn, J + 1);
		_ ->
			Right = (1 bsl ((1 bsl J) - 1)),
			Left = mget(Lanes, 0, 0),
			Down = Left bxor Right,
			V = Down,
			iota(mput(Lanes, 0, 0, V), Rn, J + 1)
	end.

load64(<< B:64/unsigned-little-integer-unit:1 >>) ->
	B.

store64(B) when is_integer(B) ->
	<< B:64/unsigned-little-integer-unit:1 >>.

keccak_f_1600(State) ->
	Lanes0 = load_lanes(State),
	Lanes1 = keccak_f_1600_on_lanes(Lanes0),
	store_lanes(Lanes1).

load_lanes(State) ->
	load_lanes(State, 0, 0, [], []).

%% @private
load_lanes(_State, 5, _Y, [], Lanes) ->
	list_to_tuple(lists:reverse(Lanes));
load_lanes(State, X, 5, Lane, Lanes) ->
	load_lanes(State, X + 1, 0, [], [list_to_tuple(lists:reverse(Lane)) | Lanes]);
load_lanes(State, X, Y, Lane, Lanes) ->
	Pos = 8 * (X + 5 * Y),
	Len = 8,
	load_lanes(State, X, Y + 1, [load64(binary:part(State, Pos, Len)) | Lane], Lanes).

store_lanes(Lanes) ->
	store_lanes(Lanes, 0, 0, << 0:1600 >>).

store_lanes(_Lanes, 5, _Y, StateBytes) ->
	StateBytes;
store_lanes(Lanes, X, 5, StateBytes) ->
	store_lanes(Lanes, X + 1, 0, StateBytes);
store_lanes(Lanes, X, Y, StateBytes) ->
	V = mget(Lanes, X, Y),
	Pos = 8 * (X + 5 * Y),
	Len = 8,
	<< StateHead:Pos/binary, _:Len/binary, StateTail/binary >> = StateBytes,
	store_lanes(Lanes, X, Y + 1, << StateHead/binary, (store64(V))/binary, StateTail/binary >>).

keccak(Rate, Capacity, InputBytes, DelimitedSuffix, OutputByteLen) ->
	case (Rate + Capacity) =/= 1600 orelse (Rate rem 8) =/= 0 of
		true ->
			erlang:error(badarg);
		false ->
			{RateInBytes, StateBytes} = keccak_absorb(Rate div 8, InputBytes, << 0:1600 >>, DelimitedSuffix),
			keccak_squeeze(RateInBytes, OutputByteLen, StateBytes, <<>>)
	end.

% Absorb all the input blocks
keccak_absorb(RateInBytes, InputBytes, StateBytes, DelimitedSuffix)
		when is_integer(RateInBytes)
		andalso byte_size(InputBytes) >= RateInBytes ->
	<< InputHead:RateInBytes/binary, InputTail/binary >> = InputBytes,
	<< StateHead:RateInBytes/binary, StateTail/binary >> = StateBytes,
	State = << (crypto:exor(StateHead, InputHead))/binary, StateTail/binary >>,
	keccak_absorb(RateInBytes, InputTail, keccak_f_1600(State), DelimitedSuffix);
keccak_absorb(RateInBytes, InputBytes, StateBytes, DelimitedSuffix) ->
	BlockSize = byte_size(InputBytes),
	<< StateHead:BlockSize/binary, StateTail/binary >> = StateBytes,
	State = << (crypto:exor(StateHead, InputBytes))/binary, StateTail/binary >>,
	keccak_pad(RateInBytes, BlockSize, State, DelimitedSuffix).

% Do the padding and switch to the squeezing phase
keccak_pad(RateInBytes, BlockSize, StateBytes, DelimitedSuffix) ->
	<< StateHead:BlockSize/binary, S:8/integer, StateTail/binary >> = StateBytes,
	State0 = << StateHead/binary, (S bxor DelimitedSuffix):8/integer, StateTail/binary >>,
	State1 = case (DelimitedSuffix band 16#80) =/= 0 andalso BlockSize =:= (RateInBytes - 1) of
		false ->
			State0;
		true ->
			keccak_f_1600(State0)
	end,
	RateInBytesSubOne = RateInBytes - 1,
	<< XHead:RateInBytesSubOne/binary, X:8/integer, XTail/binary >> = State1,
	State2 = << XHead/binary, (X bxor 16#80):8/integer, XTail/binary >>,
	State3 = keccak_f_1600(State2),
	{RateInBytes, State3}.

% Squeeze out all the output blocks
keccak_squeeze(RateInBytes, OutputByteLen, StateBytes, OutputBytes)
		when OutputByteLen > 0 ->
	BlockSize = min(OutputByteLen, RateInBytes),
	<< StateBlock:BlockSize/binary, _/binary >> = StateBytes,
	NewOutputByteLen = OutputByteLen - BlockSize,
	State = case NewOutputByteLen > 0 of
		true ->
			keccak_f_1600(StateBytes);
		false ->
			StateBytes
	end,
	keccak_squeeze(RateInBytes, NewOutputByteLen, State, << OutputBytes/binary, StateBlock/binary >>);
keccak_squeeze(_RateInBytes, _OutputByteLen, _StateBytes, OutputBytes) ->
	OutputBytes.

shake128(InputBytes, OutputByteLen)
		when is_binary(InputBytes)
		andalso is_integer(OutputByteLen)
		andalso OutputByteLen >= 0 ->
	keccak(1344, 256, InputBytes, 16#1F, OutputByteLen).

shake256(InputBytes, OutputByteLen)
		when is_binary(InputBytes)
		andalso is_integer(OutputByteLen)
		andalso OutputByteLen >= 0 ->
	keccak(1088, 512, InputBytes, 16#1F, OutputByteLen).

sha3_224(InputBytes) ->
	keccak(1152, 448, InputBytes, 16#06, 224 div 8).

sha3_256(InputBytes) ->
	keccak(1088, 512, InputBytes, 16#06, 256 div 8).

sha3_384(InputBytes) ->
	keccak(832, 768, InputBytes, 16#06, 384 div 8).

sha3_512(InputBytes) ->
	keccak(576, 1024, InputBytes, 16#06, 512 div 8).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
mget(M, X) ->
	element(X + 1, M).

%% @private
mget(M, X, Y) ->
	mget(mget(M, X), Y).

%% @private
mput({E0, E1, E2, E3, E4}, 0, Y, V) ->
	{mput(E0, Y, V), E1, E2, E3, E4};
mput({E0, E1, E2, E3, E4}, 1, Y, V) ->
	{E0, mput(E1, Y, V), E2, E3, E4};
mput({E0, E1, E2, E3, E4}, 2, Y, V) ->
	{E0, E1, mput(E2, Y, V), E3, E4};
mput({E0, E1, E2, E3, E4}, 3, Y, V) ->
	{E0, E1, E2, mput(E3, Y, V), E4};
mput({E0, E1, E2, E3, E4}, 4, Y, V) ->
	{E0, E1, E2, E3, mput(E4, Y, V)}.

%% @private
mput({_, V1, V2, V3, V4}, 0, V0) ->
	{V0, V1, V2, V3, V4};
mput({V0, _, V2, V3, V4}, 1, V1) ->
	{V0, V1, V2, V3, V4};
mput({V0, V1, _, V3, V4}, 2, V2) ->
	{V0, V1, V2, V3, V4};
mput({V0, V1, V2, _, V4}, 3, V3) ->
	{V0, V1, V2, V3, V4};
mput({V0, V1, V2, V3, _}, 4, V4) ->
	{V0, V1, V2, V3, V4}.
