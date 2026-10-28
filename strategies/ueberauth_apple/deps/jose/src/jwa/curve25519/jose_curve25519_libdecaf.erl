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
-module(jose_curve25519_libdecaf).

-behaviour(jose_curve25519).

%% jose_curve25519 callbacks
-export([eddsa_keypair/0]).
-export([eddsa_keypair/1]).
-export([eddsa_secret_to_public/1]).
-export([ed25519_sign/2]).
-export([ed25519_verify/3]).
-export([ed25519ctx_sign/3]).
-export([ed25519ctx_verify/4]).
-export([ed25519ph_sign/2]).
-export([ed25519ph_sign/3]).
-export([ed25519ph_verify/3]).
-export([ed25519ph_verify/4]).
-export([x25519_keypair/0]).
-export([x25519_keypair/1]).
-export([x25519_secret_to_public/1]).
-export([x25519_shared_secret/2]).

%%====================================================================
%% jose_curve25519 callbacks
%%====================================================================

% EdDSA
eddsa_keypair() ->
	libdecaf_curve25519:eddsa_keypair().

eddsa_keypair(Seed) ->
	libdecaf_curve25519:eddsa_keypair(Seed).

eddsa_secret_to_public(SecretKey) ->
	libdecaf_curve25519:eddsa_secret_to_pk(SecretKey).

% Ed25519
ed25519_sign(Message, SecretKey) ->
	libdecaf_curve25519:ed25519_sign(Message, SecretKey).

ed25519_verify(Signature, Message, PublicKey) ->
	libdecaf_curve25519:ed25519_verify(Signature, Message, PublicKey).

% Ed25519ctx
ed25519ctx_sign(Message, SecretKey, Context) ->
	libdecaf_curve25519:ed25519ctx_sign(Message, SecretKey, Context).

ed25519ctx_verify(Signature, Message, PublicKey, Context) ->
	libdecaf_curve25519:ed25519ctx_verify(Signature, Message, PublicKey, Context).

% Ed25519ph
ed25519ph_sign(Message, SecretKey) ->
	libdecaf_curve25519:ed25519ph_sign(Message, SecretKey).

ed25519ph_sign(Message, SecretKey, Context) ->
	libdecaf_curve25519:ed25519ph_sign(Message, SecretKey, Context).

ed25519ph_verify(Signature, Message, PublicKey) ->
	libdecaf_curve25519:ed25519ph_verify(Signature, Message, PublicKey).

ed25519ph_verify(Signature, Message, PublicKey, Context) ->
	libdecaf_curve25519:ed25519ph_verify(Signature, Message, PublicKey, Context).

% X25519
x25519_keypair() ->
	libdecaf_curve25519:x25519_keypair().

x25519_keypair(Seed) ->
	libdecaf_curve25519:x25519_keypair(Seed).

x25519_secret_to_public(SecretKey) ->
	libdecaf_curve25519:x25519(SecretKey).

x25519_shared_secret(MySecretKey, YourPublicKey) ->
	libdecaf_curve25519:x25519(MySecretKey, YourPublicKey).
