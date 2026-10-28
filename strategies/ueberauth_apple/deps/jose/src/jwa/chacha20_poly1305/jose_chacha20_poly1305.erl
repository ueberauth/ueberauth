%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  31 May 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_chacha20_poly1305).

-behaviour(jose_block_encryptor).

%% Types
-type additional_authenticated_data() :: binary().
-type cipher_text() :: binary().
-type message() :: binary().
-type plain_text() :: binary().
-type poly1305_mac() :: <<_:128>>.
-type chacha20_key() :: <<_:256>>.
-type chacha20_nonce() :: <<_:96>>.

-export_type([
	additional_authenticated_data/0,
	cipher_text/0,
	message/0,
	plain_text/0,
	poly1305_mac/0,
	chacha20_key/0,
	chacha20_nonce/0
]).

-callback decrypt(CipherText, CipherTag, AAD, IV, Key) -> PlainText | error
	when
		CipherText :: cipher_text(),
		CipherTag  :: poly1305_mac(),
		AAD        :: additional_authenticated_data(),
		IV         :: chacha20_nonce(),
		Key        :: chacha20_key(),
		PlainText  :: binary().
-callback encrypt(PlainText, AAD, IV, Key) -> {CipherText, CipherTag}
	when
		PlainText  :: plain_text(),
		AAD        :: additional_authenticated_data(),
		IV         :: chacha20_nonce(),
		Key        :: chacha20_key(),
		CipherText :: cipher_text(),
		CipherTag  :: poly1305_mac().
-callback authenticate(Message, Key, Nonce) -> MAC
	when
		Message :: message(),
		Key     :: chacha20_key(),
		Nonce   :: chacha20_nonce(),
		MAC     :: poly1305_mac().
-callback verify(MAC, Message, Key, Nonce) -> boolean()
	when
		MAC     :: poly1305_mac(),
		Message :: message(),
		Key     :: chacha20_key(),
		Nonce   :: chacha20_nonce().

%% jose_block_encryptor callbacks
-export([block_decrypt/4]).
-export([block_encrypt/4]).
%% jose_chacha20_poly1305 callbacks
-export([decrypt/5]).
-export([encrypt/4]).
-export([authenticate/3]).
-export([verify/4]).

%% Macros
-define(JOSE_CHACHA20_POLY1305, (jose:chacha20_poly1305_module())).

%%====================================================================
%% jose_block_encryptor callbacks
%%====================================================================

block_decrypt({chacha20_poly1305, 256}, Key, IV, {AAD, CipherText, CipherTag}) ->
	decrypt(CipherText, CipherTag, AAD, IV, Key).

block_encrypt({chacha20_poly1305, 256}, Key, IV, {AAD, PlainText}) ->
	encrypt(PlainText, AAD, IV, Key).

%%====================================================================
%% jose_chacha20_poly1305 callbacks
%%====================================================================

decrypt(CipherText, CipherTag, AAD, IV, CEK) ->
	?JOSE_CHACHA20_POLY1305:decrypt(CipherText, CipherTag, AAD, IV, CEK).

encrypt(PlainText, AAD, IV, CEK) ->
	?JOSE_CHACHA20_POLY1305:encrypt(PlainText, AAD, IV, CEK).

authenticate(Message, Key, Nonce) ->
	?JOSE_CHACHA20_POLY1305:authenticate(Message, Key, Nonce).

verify(MAC, Message, Key, Nonce) ->
	?JOSE_CHACHA20_POLY1305:verify(MAC, Message, Key, Nonce).
