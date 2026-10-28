%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  08 Aug 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_chacha20_poly1305_crypto).

-behaviour(jose_chacha20_poly1305).

%% jose_chacha20_poly1305 callbacks
-export([decrypt/5]).
-export([encrypt/4]).
-export([authenticate/3]).
-export([verify/4]).
%% Internal API
-export([poly1305_key_gen/2]).

%% Types
-type chacha20_key() :: <<_:256>>.
-type chacha20_nonce() :: <<_:96>>.
-type poly1305_otk() :: <<_:256>>.

%%====================================================================
%% jose_chacha20_poly1305 callbacks
%%====================================================================

decrypt(CipherText, CipherTag, AAD, IV, CEK) ->
	crypto:crypto_one_time_aead(chacha20_poly1305, CEK, IV, CipherText, AAD, CipherTag, false).

encrypt(PlainText, AAD, IV, CEK) ->
	crypto:crypto_one_time_aead(chacha20_poly1305, CEK, IV, PlainText, AAD, true).

authenticate(Message, Key, Nonce) ->
	OTK = poly1305_key_gen(Key, Nonce),
	jose_crypto_compat:mac(poly1305, OTK, Message).

verify(MAC, Message, Key, Nonce) ->
	Challenge = authenticate(Message, Key, Nonce),
	jose_jwa:constant_time_compare(MAC, Challenge).

%%====================================================================
%% Internal API Functions
%%====================================================================

-spec poly1305_key_gen(
	Key :: chacha20_key(),
	Nonce :: chacha20_nonce()
) -> poly1305_otk().
poly1305_key_gen(
	<<Key:256/bitstring>>,
	<<Nonce:96/bitstring>>
) ->
	crypto:crypto_one_time(chacha20, Key, <<0:32, Nonce:96/bits>>, <<0:256>>, true).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
