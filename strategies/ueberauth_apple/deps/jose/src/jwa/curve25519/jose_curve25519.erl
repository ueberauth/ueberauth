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
-module(jose_curve25519).

%% Types
-type eddsa_public_key() :: <<_:256>>.
-type eddsa_secret_key() :: <<_:512>>.
-type eddsa_seed() :: <<_:256>>.
-type message() :: binary().
-type signature() :: <<_:512>>.
-type maybe_invalid_signature() :: signature() | binary().
-type context() :: binary().
-type x25519_public_key() :: <<_:256>>.
-type x25519_secret_key() :: <<_:256>>.
-type x25519_seed() :: <<_:256>>.
-type x25519_shared_secret() :: <<_:256>>.

-export_type([
	eddsa_public_key/0,
	eddsa_secret_key/0,
	eddsa_seed/0,
	message/0,
	signature/0,
	maybe_invalid_signature/0,
	context/0,
	x25519_public_key/0,
	x25519_secret_key/0,
	x25519_seed/0,
	x25519_shared_secret/0
]).

-callback eddsa_keypair() -> {PublicKey::eddsa_public_key(), SecretKey::eddsa_secret_key()}.
-callback eddsa_keypair(Seed::eddsa_seed()) -> {PublicKey::eddsa_public_key(), SecretKey::eddsa_secret_key()}.
-callback eddsa_secret_to_public(SecretKey::eddsa_secret_key()) -> PublicKey::eddsa_public_key().
-callback ed25519_sign(Message::message(), SecretKey::eddsa_secret_key()) -> Signature::signature().
-callback ed25519_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key()) -> boolean().
-callback ed25519ctx_sign(Message::message(), SecretKey::eddsa_secret_key(), Context::context()) -> Signature::signature().
-callback ed25519ctx_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key(), Context::context()) -> boolean().
-callback ed25519ph_sign(Message::message(), SecretKey::eddsa_secret_key()) -> Signature::signature().
-callback ed25519ph_sign(Message::message(), SecretKey::eddsa_secret_key(), Context::context()) -> Signature::signature().
-callback ed25519ph_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key()) -> boolean().
-callback ed25519ph_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key(), Context::context()) -> boolean().
-callback x25519_keypair() -> {PublicKey::x25519_public_key(), SecretKey::x25519_secret_key()}.
-callback x25519_keypair(Seed::x25519_seed()) -> {PublicKey::x25519_public_key(), SecretKey::x25519_secret_key()}.
-callback x25519_secret_to_public(SecretKey::x25519_secret_key()) -> PublicKey::x25519_public_key().
-callback x25519_shared_secret(MySecretKey::x25519_secret_key(), YourPublicKey::x25519_public_key()) -> SharedSecret::x25519_shared_secret().

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
-define(JOSE_CURVE25519, (jose:curve25519_module())).

%%====================================================================
%% jose_curve25519 callbacks
%%====================================================================

% EdDSA
-spec eddsa_keypair() -> {eddsa_public_key(), eddsa_secret_key()}.
eddsa_keypair() ->
	?JOSE_CURVE25519:eddsa_keypair().

-spec eddsa_keypair(eddsa_seed()) -> {eddsa_public_key(), eddsa_secret_key()}.
eddsa_keypair(Seed) ->
	?JOSE_CURVE25519:eddsa_keypair(Seed).

-spec eddsa_secret_to_public(eddsa_secret_key()) -> eddsa_public_key().
eddsa_secret_to_public(SecretKey) ->
	?JOSE_CURVE25519:eddsa_secret_to_public(SecretKey).

% Ed25519
-spec ed25519_sign(message(), eddsa_secret_key()) -> signature().
ed25519_sign(Message, SecretKey) ->
	?JOSE_CURVE25519:ed25519_sign(Message, SecretKey).

-spec ed25519_verify(maybe_invalid_signature(), message(), eddsa_public_key()) -> boolean().
ed25519_verify(Signature, Message, PublicKey) ->
	?JOSE_CURVE25519:ed25519_verify(Signature, Message, PublicKey).

% Ed25519ctx
-spec ed25519ctx_sign(message(), eddsa_secret_key(), context()) -> signature().
ed25519ctx_sign(Message, SecretKey, Context) ->
	?JOSE_CURVE25519:ed25519ctx_sign(Message, SecretKey, Context).

-spec ed25519ctx_verify(maybe_invalid_signature(), message(), eddsa_public_key(), context()) -> boolean().
ed25519ctx_verify(Signature, Message, PublicKey, Context) ->
	?JOSE_CURVE25519:ed25519ctx_verify(Signature, Message, PublicKey, Context).

% Ed25519ph
-spec ed25519ph_sign(message(), eddsa_secret_key()) -> signature().
ed25519ph_sign(Message, SecretKey) ->
	?JOSE_CURVE25519:ed25519ph_sign(Message, SecretKey).

-spec ed25519ph_sign(message(), eddsa_secret_key(), context()) -> signature().
ed25519ph_sign(Message, SecretKey, Context) ->
	?JOSE_CURVE25519:ed25519ph_sign(Message, SecretKey, Context).

-spec ed25519ph_verify(maybe_invalid_signature(), message(), eddsa_public_key()) -> boolean().
ed25519ph_verify(Signature, Message, PublicKey) ->
	?JOSE_CURVE25519:ed25519ph_verify(Signature, Message, PublicKey).

-spec ed25519ph_verify(maybe_invalid_signature(), message(), eddsa_public_key(), context()) -> boolean().
ed25519ph_verify(Signature, Message, PublicKey, Context) ->
	?JOSE_CURVE25519:ed25519ph_verify(Signature, Message, PublicKey, Context).

% X25519
-spec x25519_keypair() -> {x25519_public_key(), x25519_secret_key()}.
x25519_keypair() ->
	?JOSE_CURVE25519:x25519_keypair().

-spec x25519_keypair(x25519_seed()) -> {x25519_public_key(), x25519_secret_key()}.
x25519_keypair(Seed) ->
	?JOSE_CURVE25519:x25519_keypair(Seed).

-spec x25519_secret_to_public(x25519_secret_key()) -> x25519_public_key().
x25519_secret_to_public(SecretKey) ->
	?JOSE_CURVE25519:x25519_secret_to_public(SecretKey).

-spec x25519_shared_secret(MySecretKey :: x25519_secret_key(), YourPublicKey :: x25519_public_key()) -> x25519_shared_secret().
x25519_shared_secret(MySecretKey, YourPublicKey) ->
	?JOSE_CURVE25519:x25519_shared_secret(MySecretKey, YourPublicKey).
