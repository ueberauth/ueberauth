%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  23 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_alg).

-callback key_decrypt(Key, {ENCModule, ENC, EncryptedKey}, ALG) -> DecryptedKey
	when
		Key          :: any(),
		ENCModule    :: module(),
		ENC          :: any(),
		EncryptedKey :: iodata(),
		ALG          :: any(),
		DecryptedKey :: iodata().
-callback key_encrypt(Key, DecryptedKey, ALG) -> {EncryptedKey, NewALG}
	when
		Key          :: any(),
		DecryptedKey :: iodata(),
		ALG          :: any(),
		EncryptedKey :: iodata(),
		NewALG       :: any().
-callback next_cek(Key, {ENCModule, ENC}, ALG) -> {DecryptedKey, NewALG}
	when
		Key          :: any(),
		ENCModule    :: module(),
		ENC          :: any(),
		ALG          :: any(),
		DecryptedKey :: iodata(),
		NewALG       :: any().

%% API
-export([generate_key/3]).

%%====================================================================
%% API functions
%%====================================================================

generate_key(Parameters, Algorithm, Encryption) ->
	jose_jwk:merge(jose_jwk:generate_key(Parameters), #{
		<<"alg">> => Algorithm,
		<<"enc">> => Encryption,
		<<"use">> => <<"enc">>
	}).
