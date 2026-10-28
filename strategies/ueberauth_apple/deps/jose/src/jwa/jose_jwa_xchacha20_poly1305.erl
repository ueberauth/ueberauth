%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc XChaCha: eXtended-nonce ChaCha and AEAD_XChaCha20_Poly1305
%%% See https://tools.ietf.org/html/draft-irtf-cfrg-xchacha
%%% @end
%%% Created :  14 Sep 2019 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_xchacha20_poly1305).

-behaviour(jose_xchacha20_poly1305).

%% jose_xchacha20_poly1305 callbacks
-export([decrypt/5]).
-export([encrypt/4]).
-export([authenticate/3]).
-export([verify/4]).

%%====================================================================
%% jose_chacha20_poly1305 callbacks
%%====================================================================

decrypt(CipherText, CipherTag, AAD, IV, CEK) ->
	{Subkey, Nonce} = jose_jwa_xchacha20:subkey_and_nonce(CEK, IV),
	jose_chacha20_poly1305:block_decrypt({chacha20_poly1305, 256}, Subkey, Nonce, {AAD, CipherText, CipherTag}).

encrypt(PlainText, AAD, IV, CEK) ->
	{Subkey, Nonce} = jose_jwa_xchacha20:subkey_and_nonce(CEK, IV),
	jose_chacha20_poly1305:block_encrypt({chacha20_poly1305, 256}, Subkey, Nonce, {AAD, PlainText}).

authenticate(Message, Key, Nonce0) ->
	{Subkey, Nonce} = jose_jwa_xchacha20:subkey_and_nonce(Key, Nonce0),
	jose_chacha20_poly1305:authenticate(Message, Subkey, Nonce).

verify(MAC, Message, Key, Nonce0) ->
	{Subkey, Nonce} = jose_jwa_xchacha20:subkey_and_nonce(Key, Nonce0),
	jose_chacha20_poly1305:verify(MAC, Message, Subkey, Nonce).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
