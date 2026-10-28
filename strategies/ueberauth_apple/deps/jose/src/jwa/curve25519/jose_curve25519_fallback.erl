%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  31 Aug 2022 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_curve25519_fallback).

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

%% Macros
-define(MAYBE_FALLBACK_MOD,
	case jose:crypto_fallback() of
		true ->
			jose_jwa_curve25519;
		false ->
			jose_curve25519_unsupported
	end).

%%====================================================================
%% jose_curve25519 callbacks
%%====================================================================

% EdDSA
-spec eddsa_keypair() -> {jose_curve25519:eddsa_public_key(), jose_curve25519:eddsa_secret_key()}.
eddsa_keypair() ->
	?MAYBE_FALLBACK_MOD:eddsa_keypair().

-spec eddsa_keypair(jose_curve25519:eddsa_seed()) -> {jose_curve25519:eddsa_public_key(), jose_curve25519:eddsa_secret_key()}.
eddsa_keypair(Seed) ->
	?MAYBE_FALLBACK_MOD:eddsa_keypair(Seed).

-spec eddsa_secret_to_public(jose_curve25519:eddsa_secret_key()) -> jose_curve25519:eddsa_public_key().
eddsa_secret_to_public(SecretKey) ->
	?MAYBE_FALLBACK_MOD:eddsa_secret_to_public(SecretKey).

% Ed25519
-spec ed25519_sign(jose_curve25519:message(), jose_curve25519:eddsa_secret_key()) -> jose_curve25519:signature().
ed25519_sign(Message, SecretKey) ->
	?MAYBE_FALLBACK_MOD:ed25519_sign(Message, SecretKey).

-spec ed25519_verify(jose_curve25519:maybe_invalid_signature(), jose_curve25519:message(), jose_curve25519:eddsa_public_key()) -> boolean().
ed25519_verify(Signature, Message, PublicKey) ->
	?MAYBE_FALLBACK_MOD:ed25519_verify(Signature, Message, PublicKey).

% Ed25519ctx
-spec ed25519ctx_sign(jose_curve25519:message(), jose_curve25519:eddsa_secret_key(), jose_curve25519:context()) -> jose_curve25519:signature().
ed25519ctx_sign(Message, SecretKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed25519ctx_sign(Message, SecretKey, Context).

-spec ed25519ctx_verify(jose_curve25519:maybe_invalid_signature(), jose_curve25519:message(), jose_curve25519:eddsa_public_key(), jose_curve25519:context()) -> boolean().
ed25519ctx_verify(Signature, Message, PublicKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed25519ctx_verify(Signature, Message, PublicKey, Context).

% Ed25519ph
-spec ed25519ph_sign(jose_curve25519:message(), jose_curve25519:eddsa_secret_key()) -> jose_curve25519:signature().
ed25519ph_sign(Message, SecretKey) ->
	?MAYBE_FALLBACK_MOD:ed25519ph_sign(Message, SecretKey).

-spec ed25519ph_sign(jose_curve25519:message(), jose_curve25519:eddsa_secret_key(), jose_curve25519:context()) -> jose_curve25519:signature().
ed25519ph_sign(Message, SecretKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed25519ph_sign(Message, SecretKey, Context).

-spec ed25519ph_verify(jose_curve25519:maybe_invalid_signature(), jose_curve25519:message(), jose_curve25519:eddsa_public_key()) -> boolean().
ed25519ph_verify(Signature, Message, PublicKey) ->
	?MAYBE_FALLBACK_MOD:ed25519ph_verify(Signature, Message, PublicKey).

-spec ed25519ph_verify(jose_curve25519:maybe_invalid_signature(), jose_curve25519:message(), jose_curve25519:eddsa_public_key(), jose_curve25519:context()) -> boolean().
ed25519ph_verify(Signature, Message, PublicKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed25519ph_verify(Signature, Message, PublicKey, Context).

% X25519
-spec x25519_keypair() -> {jose_curve25519:x25519_public_key(), jose_curve25519:x25519_secret_key()}.
x25519_keypair() ->
	?MAYBE_FALLBACK_MOD:x25519_keypair().

-spec x25519_keypair(jose_curve25519:x25519_seed()) -> {jose_curve25519:x25519_public_key(), jose_curve25519:x25519_secret_key()}.
x25519_keypair(Seed) ->
	?MAYBE_FALLBACK_MOD:x25519_keypair(Seed).

-spec x25519_secret_to_public(jose_curve25519:x25519_secret_key()) -> jose_curve25519:x25519_public_key().
x25519_secret_to_public(SecretKey) ->
	?MAYBE_FALLBACK_MOD:x25519_secret_to_public(SecretKey).

-spec x25519_shared_secret(MySecretKey :: jose_curve25519:x25519_secret_key(), YourPublicKey :: jose_curve25519:x25519_public_key()) -> jose_curve25519:x25519_shared_secret().
x25519_shared_secret(MySecretKey, YourPublicKey) ->
	?MAYBE_FALLBACK_MOD:x25519_shared_secret(MySecretKey, YourPublicKey).
