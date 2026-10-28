%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  10 Aug 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_block_encryptor).

-callback block_decrypt(Cipher, Key, CipherText) -> PlainText | error
	when
		Cipher     :: {atom(), pos_integer()},
		Key        :: bitstring(),
		CipherText :: binary(),
		PlainText  :: binary().
-callback block_encrypt(Cipher, Key, PlainText) -> CipherText
	when
		Cipher     :: {atom(), pos_integer()},
		Key        :: bitstring(),
		PlainText  :: binary(),
		CipherText :: binary().

-optional_callbacks([block_decrypt/3]).
-optional_callbacks([block_encrypt/3]).

-callback block_decrypt(Cipher, Key, IV, CipherText) -> PlainText | error
	when
		Cipher     :: {atom(), pos_integer()},
		Key        :: bitstring(),
		IV         :: bitstring(),
		CipherText :: binary() | {binary(), binary(), binary()},
		PlainText  :: binary().
-callback block_encrypt(Cipher, Key, IV, PlainText) -> CipherText
	when
		Cipher     :: {atom(), pos_integer()},
		Key        :: bitstring(),
		IV         :: bitstring(),
		PlainText  :: binary() | {binary(), binary()},
		CipherText :: binary() | {binary(), binary()}.
