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
-module(jose_curve448_fallback).

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
-define(MAYBE_FALLBACK_MOD,
	case jose:crypto_fallback() of
		true ->
			jose_jwa_curve448;
		false ->
			jose_curve448_unsupported
	end).

%%====================================================================
%% jose_curve448 callbacks
%%====================================================================

% EdDSA
-spec eddsa_keypair() -> {jose_curve448:eddsa_public_key(), jose_curve448:eddsa_secret_key()}.
eddsa_keypair() ->
	?MAYBE_FALLBACK_MOD:eddsa_keypair().

-spec eddsa_keypair(jose_curve448:eddsa_seed()) -> {jose_curve448:eddsa_public_key(), jose_curve448:eddsa_secret_key()}.
eddsa_keypair(Seed) ->
	?MAYBE_FALLBACK_MOD:eddsa_keypair(Seed).

-spec eddsa_secret_to_public(jose_curve448:eddsa_secret_key()) -> jose_curve448:eddsa_public_key().
eddsa_secret_to_public(SecretKey) ->
	?MAYBE_FALLBACK_MOD:eddsa_secret_to_public(SecretKey).

% Ed448
-spec ed448_sign(jose_curve448:message(), jose_curve448:eddsa_secret_key()) -> jose_curve448:signature().
ed448_sign(Message, SecretKey) ->
	?MAYBE_FALLBACK_MOD:ed448_sign(Message, SecretKey).

-spec ed448_sign(jose_curve448:message(), jose_curve448:eddsa_secret_key(), jose_curve448:context()) -> jose_curve448:signature().
ed448_sign(Message, SecretKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed448_sign(Message, SecretKey, Context).

-spec ed448_verify(jose_curve448:maybe_invalid_signature(), jose_curve448:message(), jose_curve448:eddsa_public_key()) -> boolean().
ed448_verify(Signature, Message, PublicKey) ->
	?MAYBE_FALLBACK_MOD:ed448_verify(Signature, Message, PublicKey).

-spec ed448_verify(jose_curve448:maybe_invalid_signature(), jose_curve448:message(), jose_curve448:eddsa_public_key(), jose_curve448:context()) -> boolean().
ed448_verify(Signature, Message, PublicKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed448_verify(Signature, Message, PublicKey, Context).

% Ed448ph
-spec ed448ph_sign(jose_curve448:message(), jose_curve448:eddsa_secret_key()) -> jose_curve448:signature().
ed448ph_sign(Message, SecretKey) ->
	?MAYBE_FALLBACK_MOD:ed448ph_sign(Message, SecretKey).

-spec ed448ph_sign(jose_curve448:message(), jose_curve448:eddsa_secret_key(), jose_curve448:context()) -> jose_curve448:signature().
ed448ph_sign(Message, SecretKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed448ph_sign(Message, SecretKey, Context).

-spec ed448ph_verify(jose_curve448:maybe_invalid_signature(), jose_curve448:message(), jose_curve448:eddsa_secret_key()) -> boolean().
ed448ph_verify(Signature, Message, PublicKey) ->
	?MAYBE_FALLBACK_MOD:ed448ph_verify(Signature, Message, PublicKey).

-spec ed448ph_verify(jose_curve448:maybe_invalid_signature(), jose_curve448:message(), jose_curve448:eddsa_secret_key(), jose_curve448:context()) -> boolean().
ed448ph_verify(Signature, Message, PublicKey, Context) ->
	?MAYBE_FALLBACK_MOD:ed448ph_verify(Signature, Message, PublicKey, Context).

% X448
-spec x448_keypair() -> {jose_curve448:x448_public_key(), jose_curve448:x448_secret_key()}.
x448_keypair() ->
	?MAYBE_FALLBACK_MOD:x448_keypair().

-spec x448_keypair(jose_curve448:x448_seed()) -> {jose_curve448:x448_public_key(), jose_curve448:x448_secret_key()}.
x448_keypair(Seed) ->
	?MAYBE_FALLBACK_MOD:x448_keypair(Seed).

-spec x448_secret_to_public(jose_curve448:x448_secret_key()) -> jose_curve448:x448_public_key().
x448_secret_to_public(SecretKey) ->
	?MAYBE_FALLBACK_MOD:x448_secret_to_public(SecretKey).

-spec x448_shared_secret(MySecretKey :: jose_curve448:x448_secret_key(), YourPublicKey :: jose_curve448:x448_public_key()) -> jose_curve448:x448_shared_secret().
x448_shared_secret(MySecretKey, YourPublicKey) ->
	?MAYBE_FALLBACK_MOD:x448_shared_secret(MySecretKey, YourPublicKey).
