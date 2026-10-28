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
-module(jose_jwe_enc_c20p).
-behaviour(jose_jwe).
-behaviour(jose_jwe_enc).

%% jose_jwe callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jwe_enc callbacks
-export([algorithm/1]).
-export([bits/1]).
-export([block_decrypt/4]).
-export([block_encrypt/4]).
-export([next_cek/1]).
-export([next_iv/1]).
%% API
-export([cipher_supported/0]).

%% Types
-type enc() :: {chacha20_poly1305, 256}.

-export_type([enc/0]).

%% Macros
-define(CHACHA20_POLY1305, {chacha20_poly1305, 256}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"enc">> := <<"C20P">> }) ->
	{?CHACHA20_POLY1305, maps:remove(<<"enc">>, F)}.

to_map(?CHACHA20_POLY1305, F) ->
	F#{ <<"enc">> => <<"C20P">> }.

%%====================================================================
%% jose_jwe_enc callbacks
%%====================================================================

algorithm(?CHACHA20_POLY1305) -> <<"C20P">>.

bits(?CHACHA20_POLY1305) -> 256.

block_decrypt({AAD, CipherText, CipherTag}, CEK, IV, ?CHACHA20_POLY1305) ->
	jose_jwa:block_decrypt(?CHACHA20_POLY1305, CEK, IV, {AAD, CipherText, CipherTag}).

block_encrypt({AAD, PlainText}, CEK, IV, ?CHACHA20_POLY1305) ->
	jose_jwa:block_encrypt(?CHACHA20_POLY1305, CEK, IV, {AAD, PlainText}).

next_cek(?CHACHA20_POLY1305) ->
	crypto:strong_rand_bytes(32).

next_iv(?CHACHA20_POLY1305) ->
	crypto:strong_rand_bytes(12).

%%====================================================================
%% API functions
%%====================================================================

cipher_supported() ->
	[chacha20_poly1305].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
