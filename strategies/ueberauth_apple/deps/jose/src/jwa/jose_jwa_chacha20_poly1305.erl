%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc ChaCha20 and Poly1305 for IETF Protocols
%%% See https://tools.ietf.org/html/rfc7539
%%% @end
%%% Created :  08 Aug 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_chacha20_poly1305).

-behaviour(jose_chacha20_poly1305).

%% jose_chacha20_poly1305 callbacks
-export([decrypt/5]).
-export([encrypt/4]).
-export([authenticate/3]).
-export([verify/4]).

%% Internal API
-export([pad16/1]).
-export([poly1305_key_gen/2]).

%%====================================================================
%% jose_chacha20_poly1305 callbacks
%%====================================================================

decrypt(CipherText, CipherTag, AAD, IV, CEK) ->
	OTK = poly1305_key_gen(CEK, IV),
	MacData = <<
		AAD/binary,
		(pad16(AAD))/binary,
		CipherText/binary,
		(pad16(CipherText))/binary,
		(byte_size(AAD)):64/unsigned-little-integer-unit:1,
		(byte_size(CipherText)):64/unsigned-little-integer-unit:1
	>>,
	Challenge = jose_jwa_poly1305:mac(MacData, OTK),
	case jose_jwa:constant_time_compare(CipherTag, Challenge) of
		true ->
			PlainText = jose_jwa_chacha20:encrypt(CEK, 1, IV, CipherText),
			PlainText;
		false ->
			error
	end.

encrypt(PlainText, AAD, IV, CEK) ->
	OTK = poly1305_key_gen(CEK, IV),
	CipherText = jose_jwa_chacha20:encrypt(CEK, 1, IV, PlainText),
	MacData = <<
		AAD/binary,
		(pad16(AAD))/binary,
		CipherText/binary,
		(pad16(CipherText))/binary,
		(byte_size(AAD)):64/unsigned-little-integer-unit:1,
		(byte_size(CipherText)):64/unsigned-little-integer-unit:1
	>>,
	CipherTag = jose_jwa_poly1305:mac(MacData, OTK),
	{CipherText, CipherTag}.

authenticate(Message, Key, Nonce) ->
	OTK = poly1305_key_gen(Key, Nonce),
	jose_jwa_poly1305:mac(Message, OTK).

verify(MAC, Message, Key, Nonce) ->
	Challenge = authenticate(Message, Key, Nonce),
	jose_jwa:constant_time_compare(MAC, Challenge).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
pad16(X) when (byte_size(X) rem 16) == 0 ->
	<<>>;
pad16(X) ->
	binary:copy(<< 0 >>, 16 - (byte_size(X) rem 16)).

%% @private
poly1305_key_gen(Key, Nonce) ->
	Counter = 0,
	<< Block:32/binary, _/binary >> = jose_jwa_chacha20:block(Key, Counter, Nonce),
	Block.
