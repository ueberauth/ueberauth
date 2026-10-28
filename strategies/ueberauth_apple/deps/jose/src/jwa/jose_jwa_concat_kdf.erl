%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Concat KDF, as defined in Section 5.8.1 of NIST.800-56A
%%% See NIST.800-56A: https://dx.doi.org/10.6028/NIST.SP.800-56Ar2
%%% @end
%%% Created :  24 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_concat_kdf).

%% API
-export([kdf/3]).
-export([kdf/4]).

%%====================================================================
%% API functions
%%====================================================================

kdf(Hash, Z, OtherInfo) ->
	HashFun = resolve_hash(Hash),
	KeyDataLen = bit_size(HashFun(<<>>)),
	kdf(HashFun, Z, OtherInfo, KeyDataLen).

kdf(Hash, Z, OtherInfo, KeyDataLen)
		when is_function(Hash)
		andalso is_binary(Z)
		andalso is_binary(OtherInfo)
		andalso is_integer(KeyDataLen) ->
	HashLen = bit_size(Hash(<<>>)),
	Reps = ceiling(KeyDataLen / HashLen),
	case Reps of
		%% derive_key/6 counts up from 1, so it must never see Reps < 1.
		_ when KeyDataLen < 0 ->
			erlang:error({badarg, [Hash, Z, OtherInfo, KeyDataLen]});
		0 ->
			<<>>;
		1 ->
			Concatenation = << 0, 0, 0, 1, Z/binary, OtherInfo/binary >>,
			<< DerivedKey:KeyDataLen/bitstring, _/bitstring >> = Hash(Concatenation),
			DerivedKey;
		_ when Reps > 16#FFFFFFFF ->
			erlang:error({badarg, [Hash, Z, OtherInfo, KeyDataLen]});
		_ ->
			derive_key(Hash, 1, Reps, KeyDataLen, << Z/binary, OtherInfo/binary >>, <<>>)
	end;
kdf(Hash, Z, OtherInfo, KeyDataLen)
		when is_tuple(Hash)
		orelse is_atom(Hash) ->
	kdf(resolve_hash(Hash), Z, OtherInfo, KeyDataLen);
kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo}, KeyDataLen) ->
	kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, <<>>}, KeyDataLen);
kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, SuppPubInfo}, KeyDataLen) ->
	kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, SuppPubInfo, <<>>}, KeyDataLen);
kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, SuppPubInfo, SuppPrivInfo}, KeyDataLen)
		when is_binary(AlgorithmID)
		andalso is_binary(PartyUInfo)
		andalso is_binary(PartyVInfo)
		andalso is_binary(SuppPubInfo)
		andalso is_binary(SuppPrivInfo) ->
	kdf(Hash, Z, <<
		(byte_size(AlgorithmID)):1/unsigned-big-integer-unit:32, AlgorithmID/binary,
		(byte_size(PartyUInfo)):1/unsigned-big-integer-unit:32, PartyUInfo/binary,
		(byte_size(PartyVInfo)):1/unsigned-big-integer-unit:32, PartyVInfo/binary,
		SuppPubInfo/binary,
		SuppPrivInfo/binary
	>>, KeyDataLen);
kdf(Hash, Z, {undefined, PartyUInfo, PartyVInfo, SuppPubInfo, SuppPrivInfo}, KeyDataLen) ->
	kdf(Hash, Z, {<<>>, PartyUInfo, PartyVInfo, SuppPubInfo, SuppPrivInfo}, KeyDataLen);
kdf(Hash, Z, {AlgorithmID, undefined, PartyVInfo, SuppPubInfo, SuppPrivInfo}, KeyDataLen) ->
	kdf(Hash, Z, {AlgorithmID, <<>>, PartyVInfo, SuppPubInfo, SuppPrivInfo}, KeyDataLen);
kdf(Hash, Z, {AlgorithmID, PartyUInfo, undefined, SuppPubInfo, SuppPrivInfo}, KeyDataLen) ->
	kdf(Hash, Z, {AlgorithmID, PartyUInfo, <<>>, SuppPubInfo, SuppPrivInfo}, KeyDataLen);
kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, undefined, SuppPrivInfo}, KeyDataLen) ->
	kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, <<>>, SuppPrivInfo}, KeyDataLen);
kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, SuppPubInfo, undefined}, KeyDataLen) ->
	kdf(Hash, Z, {AlgorithmID, PartyUInfo, PartyVInfo, SuppPubInfo, <<>>}, KeyDataLen).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
ceiling(X) when X < 0 ->
	trunc(X);
ceiling(X) ->
	T = trunc(X),
	case X - T == 0 of
		false ->
			T + 1;
		true ->
			T
	end.

%% @private
derive_key(Hash, Reps, Reps, KeyDataLen, ZOtherInfo, DerivedKeyingMaterial) ->
	Concatenation = << Reps:1/unsigned-big-integer-unit:32, ZOtherInfo/binary >>,
	<< DerivedKey:KeyDataLen/bitstring, _/bitstring >> = << DerivedKeyingMaterial/binary, (Hash(Concatenation))/binary >>,
	DerivedKey;
derive_key(Hash, Counter, Reps, KeyDataLen, ZOtherInfo, DerivedKeyingMaterial) ->
	Concatenation = << Counter:1/unsigned-big-integer-unit:32, ZOtherInfo/binary >>,
	derive_key(Hash, Counter + 1, Reps, KeyDataLen, ZOtherInfo, << DerivedKeyingMaterial/binary, (Hash(Concatenation))/binary >>).

%% @private
resolve_hash(HashFun) when is_function(HashFun) ->
	HashFun;
resolve_hash(DigestType) when is_atom(DigestType) ->
	fun(Data) ->
		crypto:hash(DigestType, Data)
	end;
resolve_hash({hmac, DigestType, Key}) when is_atom(DigestType) ->
	fun(Data) ->
		jose_crypto_compat:mac(hmac, DigestType, Key, Data)
	end.
