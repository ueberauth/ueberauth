%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  14 Sep 2019 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_enc_xc20p).
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
-type enc() :: {xchacha20_poly1305, 256}.

-export_type([enc/0]).

%% Macros
-define(XCHACHA20_POLY1305, {xchacha20_poly1305, 256}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"enc">> := <<"XC20P">> }) ->
	{?XCHACHA20_POLY1305, maps:remove(<<"enc">>, F)}.

to_map(?XCHACHA20_POLY1305, F) ->
	F#{ <<"enc">> => <<"XC20P">> }.

%%====================================================================
%% jose_jwe_enc callbacks
%%====================================================================

algorithm(?XCHACHA20_POLY1305) -> <<"XC20P">>.

bits(?XCHACHA20_POLY1305) -> 256.

block_decrypt({AAD, CipherText, CipherTag}, CEK, IV, ?XCHACHA20_POLY1305) ->
	jose_jwa:block_decrypt(?XCHACHA20_POLY1305, CEK, IV, {AAD, CipherText, CipherTag}).

block_encrypt({AAD, PlainText}, CEK, IV, ?XCHACHA20_POLY1305) ->
	jose_jwa:block_encrypt(?XCHACHA20_POLY1305, CEK, IV, {AAD, PlainText}).

next_cek(?XCHACHA20_POLY1305) ->
	crypto:strong_rand_bytes(32).

next_iv(?XCHACHA20_POLY1305) ->
	crypto:strong_rand_bytes(24).

%%====================================================================
%% API functions
%%====================================================================

cipher_supported() ->
	[xchacha20_poly1305].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
