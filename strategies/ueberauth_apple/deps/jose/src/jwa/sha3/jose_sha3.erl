%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  11 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_sha3).

-callback sha3_224(InputBytes::binary()) -> OutputBytes::binary().
-callback sha3_256(InputBytes::binary()) -> OutputBytes::binary().
-callback sha3_384(InputBytes::binary()) -> OutputBytes::binary().
-callback sha3_512(InputBytes::binary()) -> OutputBytes::binary().
-callback shake128(InputBytes::binary(), OutputByteLen::integer()) -> OutputBytes::binary().
-callback shake256(InputBytes::binary(), OutputByteLen::integer()) -> OutputBytes::binary().

%% jose_sha3 callbacks
-export([sha3_224/1]).
-export([sha3_256/1]).
-export([sha3_384/1]).
-export([sha3_512/1]).
-export([shake128/2]).
-export([shake256/2]).

%% Macros
-define(JOSE_SHA3, (jose:sha3_module())).

%%====================================================================
%% jose_sha3 callbacks
%%====================================================================

sha3_224(InputBytes) ->
	?JOSE_SHA3:sha3_224(InputBytes).

sha3_256(InputBytes) ->
	?JOSE_SHA3:sha3_256(InputBytes).

sha3_384(InputBytes) ->
	?JOSE_SHA3:sha3_384(InputBytes).

sha3_512(InputBytes) ->
	?JOSE_SHA3:sha3_512(InputBytes).

shake128(InputBytes, OutputByteLen) ->
	?JOSE_SHA3:shake128(InputBytes, OutputByteLen).

shake256(InputBytes, OutputByteLen) ->
	?JOSE_SHA3:shake256(InputBytes, OutputByteLen).
