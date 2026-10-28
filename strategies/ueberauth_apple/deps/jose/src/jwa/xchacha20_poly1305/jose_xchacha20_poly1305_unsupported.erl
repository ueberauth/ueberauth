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
-module(jose_xchacha20_poly1305_unsupported).

-behaviour(jose_xchacha20_poly1305).

%% jose_xchacha20_poly1305 callbacks
-export([decrypt/5]).
-export([encrypt/4]).
-export([authenticate/3]).
-export([verify/4]).

%% Macros
-define(unsupported, erlang:error(operation_not_supported)).

%%====================================================================
%% jose_xchacha20_poly1305 callbacks
%%====================================================================

decrypt(_CipherText, _CipherTag, _AAD, _IV, _Key) ->
	?unsupported.

encrypt(_PlainText, _AAD, _IV, _Key) ->
	?unsupported.

authenticate(_Message, _Key, _Nonce) ->
	?unsupported.

verify(_MAC, _Message, _Key, _Nonce) ->
	?unsupported.
