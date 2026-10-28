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
-module(jose_jwa_xchacha20).

%% API
-export([encrypt/4]).
-export([subkey_and_nonce/2]).

%%====================================================================
%% API functions
%%====================================================================

encrypt(Key, Counter, Nonce0, Plaintext) ->
	{Subkey, Nonce} = subkey_and_nonce(Key, Nonce0),
	jose_jwa_chacha20:encrypt(Subkey, Counter, Nonce, Plaintext).

subkey_and_nonce(Key, << Nonce0:128/bitstring, Nonce1:64/bitstring >>) ->
	Subkey = jose_jwa_hchacha20:hash(Key, Nonce0),
	Nonce = << 0:32, Nonce1:64/bitstring >>,
	{Subkey, Nonce}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
