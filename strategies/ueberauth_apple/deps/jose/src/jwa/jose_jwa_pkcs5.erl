%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc PKCS #5: Password-Based Cryptography Specification Version 2.0
%%% See RFC 2898: https://tools.ietf.org/html/rfc2898
%%% @end
%%% Created :  27 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_pkcs5).

%% API
-export([pbkdf1/3]).
-export([pbkdf1/4]).
-export([pbkdf1/5]).
-export([pbkdf2/3]).
-export([pbkdf2/4]).
-export([pbkdf2/5]).

%%====================================================================
%% API functions
%%====================================================================

pbkdf1(Hash, Password, Salt) ->
	pbkdf1(Hash, Password, Salt, 1).

pbkdf1(Hash, Password, Salt, Iterations) ->
	HashFun = resolve_hash(Hash),
	DerivedKeyLen = byte_size(HashFun(<<>>)),
	pbkdf1(HashFun, Password, Salt, Iterations, DerivedKeyLen).

pbkdf1(Hash, Password, Salt, Iterations, DerivedKeyLen)
		when is_function(Hash, 1)
		andalso is_binary(Password)
		andalso is_binary(Salt)
		andalso Iterations >= 1
		andalso is_integer(DerivedKeyLen)
		andalso DerivedKeyLen >= 0 ->
	HashLen = byte_size(Hash(<<>>)),
	case DerivedKeyLen > HashLen of
		false ->
			{ok, derive_pbkdf1(Hash, 1, Iterations, DerivedKeyLen, << Password/binary, Salt/binary >>)};
		true ->
			{error, derived_key_too_long}
	end;
pbkdf1(Hash, Password, Salt, Iterations, DerivedKeyLen)
		when is_tuple(Hash)
		orelse is_atom(Hash) ->
	pbkdf1(resolve_hash(Hash), Password, Salt, Iterations, DerivedKeyLen).

pbkdf2(Mac, Password, Salt) ->
	pbkdf2(Mac, Password, Salt, 1).

pbkdf2(Mac, Password, Salt, Iterations) ->
	MacFun = resolve_mac(Mac),
	DerivedKeyLen = byte_size(MacFun(<<>>, <<>>)),
	pbkdf2(MacFun, Password, Salt, Iterations, DerivedKeyLen).

pbkdf2(Mac, Password, Salt, Iterations, DerivedKeyLen)
		when is_function(Mac, 2)
		andalso is_binary(Password)
		andalso is_binary(Salt)
		andalso is_integer(Iterations)
		andalso Iterations >= 1
		andalso is_integer(DerivedKeyLen)
		andalso DerivedKeyLen >= 0 ->
	MacLen = byte_size(Mac(<<>>, <<>>)),
	case DerivedKeyLen > (16#FFFFFFFF * MacLen) of
		false ->
			Reps = ceiling(DerivedKeyLen / MacLen),
			{ok, derive_pbkdf2(Mac, 1, Reps, Iterations, DerivedKeyLen, Password, Salt, <<>>)};
		true ->
			{error, derived_key_too_long}
	end;
pbkdf2(Mac, Password, Salt, Iterations, DerivedKeyLen)
		when is_tuple(Mac)
		orelse is_atom(Mac) ->
	pbkdf2(resolve_mac(Mac), Password, Salt, Iterations, DerivedKeyLen).

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
derive_pbkdf1(Hash, Reps, Reps, DerivedKeyLen, DerivedKeyingMaterial) ->
	<< DerivedKey:DerivedKeyLen/binary, _/binary >> = Hash(DerivedKeyingMaterial),
	DerivedKey;
derive_pbkdf1(Hash, Counter, Reps, DerivedKeyLen, DerivedKeyingMaterial) ->
	derive_pbkdf1(Hash, Counter + 1, Reps, DerivedKeyLen, Hash(DerivedKeyingMaterial)).

%% @private
derive_pbkdf2(Mac, Reps, Reps, Iterations, DerivedKeyLen, Password, Salt, DerivedKeyingMaterial) ->
	<< DerivedKey:DerivedKeyLen/binary, _/binary >> = << DerivedKeyingMaterial/binary, (derive_pbkdf2_exor(Mac, Password, Salt, 1, Iterations, Reps, <<>>, <<>>))/binary >>,
	DerivedKey;
derive_pbkdf2(Mac, Counter, Reps, Iterations, DerivedKeyLen, Password, Salt, DerivedKeyingMaterial) ->
	derive_pbkdf2(Mac, Counter + 1, Reps, Iterations, DerivedKeyLen, Password, Salt, << DerivedKeyingMaterial/binary, (derive_pbkdf2_exor(Mac, Password, Salt, 1, Iterations, Counter, <<>>, <<>>))/binary >>).

%% @private
derive_pbkdf2_exor(_Mac, _Password, _Salt, I, Iterations, _Counter, _Prev, Acc) when I > Iterations ->
	Acc;
derive_pbkdf2_exor(Mac, Password, Salt, I = 1, Iterations, Counter, <<>>, <<>>) ->
	Next = Mac(Password, << Salt/binary, Counter:1/unsigned-big-integer-unit:32 >>),
	derive_pbkdf2_exor(Mac, Password, Salt, I + 1, Iterations, Counter, Next, Next);
derive_pbkdf2_exor(Mac, Password, Salt, I, Iterations, Counter, Prev, Acc) ->
	Next = Mac(Password, Prev),
	derive_pbkdf2_exor(Mac, Password, Salt, I + 1, Iterations, Counter, Next, crypto:exor(Next, Acc)).

%% @private
resolve_hash(HashFun) when is_function(HashFun, 1) ->
	HashFun;
resolve_hash(DigestType) when is_atom(DigestType) ->
	fun(Data) ->
		crypto:hash(DigestType, Data)
	end;
resolve_hash({hmac, DigestType, Key}) when is_atom(DigestType) ->
	fun(Data) ->
		jose_crypto_compat:mac(hmac, DigestType, Key, Data)
	end.

%% @private
resolve_mac(MacFun) when is_function(MacFun, 2) ->
	MacFun;
resolve_mac(DigestType) when is_atom(DigestType) ->
	resolve_mac({hmac, DigestType});
resolve_mac({hmac, DigestType}) when is_atom(DigestType) ->
	fun(Key, Data) ->
		jose_crypto_compat:mac(hmac, DigestType, Key, Data)
	end.
