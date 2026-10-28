%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  02 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_curve448_unsupported).

-behaviour(jose_curve448).

%% jose_curve448 callbacks
-export([eddsa_keypair/0]).
-export([eddsa_keypair/1]).
-export([eddsa_secret_to_public/1]).
-export([ed448_sign/2]).
-export([ed448_sign/3]).
-export([ed448_verify/3]).
-export([ed448_verify/4]).
-export([ed448ph_sign/2]).
-export([ed448ph_sign/3]).
-export([ed448ph_verify/3]).
-export([ed448ph_verify/4]).
-export([x448_keypair/0]).
-export([x448_keypair/1]).
-export([x448_secret_to_public/1]).
-export([x448_shared_secret/2]).

%% Macros
-define(unsupported, erlang:error(operation_not_supported)).

%%====================================================================
%% jose_curve448 callbacks
%%====================================================================

% EdDSA
eddsa_keypair() ->
	?unsupported.

eddsa_keypair(_Seed) ->
	?unsupported.

eddsa_secret_to_public(_SecretKey) ->
	?unsupported.

% Ed448
ed448_sign(_Message, _SecretKey) ->
	?unsupported.

ed448_sign(_Message, _SecretKey, _Context) ->
	?unsupported.

ed448_verify(_Signature, _Message, _PublicKey) ->
	?unsupported.

ed448_verify(_Signature, _Message, _PublicKey, _Context) ->
	?unsupported.

% Ed448ph
ed448ph_sign(_Message, _SecretKey) ->
	?unsupported.

ed448ph_sign(_Message, _SecretKey, _Context) ->
	?unsupported.

ed448ph_verify(_Signature, _Message, _PublicKey) ->
	?unsupported.

ed448ph_verify(_Signature, _Message, _PublicKey, _Context) ->
	?unsupported.

% X448
x448_keypair() ->
	?unsupported.

x448_keypair(_Seed) ->
	?unsupported.

x448_secret_to_public(_SecretKey) ->
	?unsupported.

x448_shared_secret(_MySecretKey, _YourPublicKey) ->
	?unsupported.
