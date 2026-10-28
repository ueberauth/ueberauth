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
-module(jose_chacha20_poly1305_libsodium).

-behaviour(jose_chacha20_poly1305).

%% jose_chacha20_poly1305 callbacks
-export([decrypt/5]).
-export([encrypt/4]).
-export([authenticate/3]).
-export([verify/4]).

%%====================================================================
%% jose_chacha20_poly1305 callbacks
%%====================================================================

decrypt(CipherText, CipherTag, AAD, IV, CEK) ->
	case libsodium_crypto_aead_chacha20poly1305:ietf_decrypt_detached(CipherText, CipherTag, AAD, IV, CEK) of
		-1 ->
			error;
		PlainText when is_binary(PlainText) ->
			PlainText
	end.

encrypt(PlainText, AAD, IV, CEK) ->
	libsodium_crypto_aead_chacha20poly1305:ietf_encrypt_detached(PlainText, AAD, IV, CEK).

authenticate(Message, Key, Nonce) ->
	OTK = one_time_key(Key, Nonce),
	libsodium_crypto_onetimeauth_poly1305:crypto_onetimeauth_poly1305(Message, OTK).

verify(MAC, Message, Key, Nonce) ->
	OTK = one_time_key(Key, Nonce),
	case libsodium_crypto_onetimeauth_poly1305:verify(MAC, Message, OTK) of
		0 ->
			true;
		_ ->
			false
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
one_time_key(Key, Nonce) ->
	libsodium_crypto_stream_chacha20:ietf_xor_ic(<< 0:256 >>, Nonce, 0, Key).
