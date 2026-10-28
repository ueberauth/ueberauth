%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  01 Mar 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_curve448_libdecaf).

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

%%====================================================================
%% jose_curve448 callbacks
%%====================================================================

% EdDSA
eddsa_keypair() ->
	libdecaf_curve448:eddsa_keypair().

eddsa_keypair(Seed) ->
	libdecaf_curve448:eddsa_keypair(Seed).

eddsa_secret_to_public(SecretKey) ->
	libdecaf_curve448:eddsa_secret_to_pk(SecretKey).

% Ed448
ed448_sign(Message, SecretKey) ->
	libdecaf_curve448:ed448_sign(Message, SecretKey).

ed448_sign(Message, SecretKey, Context) ->
	libdecaf_curve448:ed448_sign(Message, SecretKey, Context).

ed448_verify(Signature, Message, PublicKey) ->
	libdecaf_curve448:ed448_verify(Signature, Message, PublicKey).

ed448_verify(Signature, Message, PublicKey, Context) ->
	libdecaf_curve448:ed448_verify(Signature, Message, PublicKey, Context).

% Ed448ph
ed448ph_sign(Message, SecretKey) ->
	libdecaf_curve448:ed448ph_sign(Message, SecretKey).

ed448ph_sign(Message, SecretKey, Context) ->
	libdecaf_curve448:ed448ph_sign(Message, SecretKey, Context).

ed448ph_verify(Signature, Message, PublicKey) ->
	libdecaf_curve448:ed448ph_verify(Signature, Message, PublicKey).

ed448ph_verify(Signature, Message, PublicKey, Context) ->
	libdecaf_curve448:ed448ph_verify(Signature, Message, PublicKey, Context).

% X448
x448_keypair() ->
	libdecaf_curve448:x448_keypair().

x448_keypair(Seed) ->
	libdecaf_curve448:x448_keypair(Seed).

x448_secret_to_public(SecretKey) ->
	libdecaf_curve448:x448(SecretKey).

x448_shared_secret(MySecretKey, YourPublicKey) ->
	libdecaf_curve448:x448(MySecretKey, YourPublicKey).
