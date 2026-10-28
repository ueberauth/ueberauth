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
-module(jose_curve448).

%% Types
-type eddsa_public_key() :: <<_:456>>.
-type eddsa_secret_key() :: <<_:912>>.
-type eddsa_seed() :: <<_:456>>.
-type message() :: binary().
-type signature() :: <<_:912>>.
-type maybe_invalid_signature() :: signature() | binary().
-type context() :: binary().
-type x448_public_key() :: <<_:448>>.
-type x448_secret_key() :: <<_:448>>.
-type x448_seed() :: <<_:448>>.
-type x448_shared_secret() :: <<_:448>>.

-export_type([
	eddsa_public_key/0,
	eddsa_secret_key/0,
	eddsa_seed/0,
	message/0,
	signature/0,
	maybe_invalid_signature/0,
	context/0,
	x448_public_key/0,
	x448_secret_key/0,
	x448_seed/0,
	x448_shared_secret/0
]).

-callback eddsa_keypair() -> {PublicKey::eddsa_public_key(), SecretKey::eddsa_secret_key()}.
-callback eddsa_keypair(Seed::eddsa_seed()) -> {PublicKey::eddsa_public_key(), SecretKey::eddsa_secret_key()}.
-callback eddsa_secret_to_public(SecretKey::eddsa_secret_key()) -> PublicKey::eddsa_public_key().
-callback ed448_sign(Message::message(), SecretKey::eddsa_secret_key()) -> Signature::signature().
-callback ed448_sign(Message::message(), SecretKey::eddsa_secret_key(), Context::context()) -> Signature::signature().
-callback ed448_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key()) -> boolean().
-callback ed448_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key(), Context::context()) -> boolean().
-callback ed448ph_sign(Message::message(), SecretKey::eddsa_secret_key()) -> Signature::signature().
-callback ed448ph_sign(Message::message(), SecretKey::eddsa_secret_key(), Context::context()) -> Signature::signature().
-callback ed448ph_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key()) -> boolean().
-callback ed448ph_verify(Signature::maybe_invalid_signature(), Message::message(), PublicKey::eddsa_public_key(), Context::context()) -> boolean().
-callback x448_keypair() -> {PublicKey::eddsa_public_key(), SecretKey::eddsa_secret_key()}.
-callback x448_keypair(Seed::x448_seed()) -> {PublicKey::x448_public_key(), SecretKey::x448_secret_key()}.
-callback x448_secret_to_public(SecretKey::x448_secret_key()) -> PublicKey::x448_public_key().
-callback x448_shared_secret(MySecretKey::x448_secret_key(), YourPublicKey::x448_public_key()) -> SharedSecret::x448_shared_secret().

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
-define(JOSE_CURVE448, (jose:curve448_module())).

%%====================================================================
%% jose_curve448 callbacks
%%====================================================================

% EdDSA
-spec eddsa_keypair() -> {eddsa_public_key(), eddsa_secret_key()}.
eddsa_keypair() ->
	?JOSE_CURVE448:eddsa_keypair().

-spec eddsa_keypair(eddsa_seed()) -> {eddsa_public_key(), eddsa_secret_key()}.
eddsa_keypair(Seed) ->
	?JOSE_CURVE448:eddsa_keypair(Seed).

-spec eddsa_secret_to_public(eddsa_secret_key()) -> eddsa_public_key().
eddsa_secret_to_public(SecretKey) ->
	?JOSE_CURVE448:eddsa_secret_to_public(SecretKey).

% Ed448
-spec ed448_sign(message(), eddsa_secret_key()) -> signature().
ed448_sign(Message, SecretKey) ->
	?JOSE_CURVE448:ed448_sign(Message, SecretKey).

-spec ed448_sign(message(), eddsa_secret_key(), context()) -> signature().
ed448_sign(Message, SecretKey, Context) ->
	?JOSE_CURVE448:ed448_sign(Message, SecretKey, Context).

-spec ed448_verify(maybe_invalid_signature(), message(), eddsa_public_key()) -> boolean().
ed448_verify(Signature, Message, PublicKey) ->
	?JOSE_CURVE448:ed448_verify(Signature, Message, PublicKey).

-spec ed448_verify(maybe_invalid_signature(), message(), eddsa_public_key(), context()) -> boolean().
ed448_verify(Signature, Message, PublicKey, Context) ->
	?JOSE_CURVE448:ed448_verify(Signature, Message, PublicKey, Context).

% Ed448ph
-spec ed448ph_sign(message(), eddsa_secret_key()) -> signature().
ed448ph_sign(Message, SecretKey) ->
	?JOSE_CURVE448:ed448ph_sign(Message, SecretKey).

-spec ed448ph_sign(message(), eddsa_secret_key(), context()) -> signature().
ed448ph_sign(Message, SecretKey, Context) ->
	?JOSE_CURVE448:ed448ph_sign(Message, SecretKey, Context).

-spec ed448ph_verify(maybe_invalid_signature(), message(), eddsa_public_key()) -> boolean().
ed448ph_verify(Signature, Message, PublicKey) ->
	?JOSE_CURVE448:ed448ph_verify(Signature, Message, PublicKey).

-spec ed448ph_verify(maybe_invalid_signature(), message(), eddsa_public_key(), context()) -> boolean().
ed448ph_verify(Signature, Message, PublicKey, Context) ->
	?JOSE_CURVE448:ed448ph_verify(Signature, Message, PublicKey, Context).

% X448
-spec x448_keypair() -> {x448_public_key(), x448_secret_key()}.
x448_keypair() ->
	?JOSE_CURVE448:x448_keypair().

-spec x448_keypair(x448_seed()) -> {x448_public_key(), x448_secret_key()}.
x448_keypair(Seed) ->
	?JOSE_CURVE448:x448_keypair(Seed).

-spec x448_secret_to_public(x448_secret_key()) -> x448_public_key().
x448_secret_to_public(SecretKey) ->
	?JOSE_CURVE448:x448_secret_to_public(SecretKey).

-spec x448_shared_secret(MySecretKey :: x448_secret_key(), YourPublicKey :: x448_public_key()) -> x448_shared_secret().
x448_shared_secret(MySecretKey, YourPublicKey) ->
	?JOSE_CURVE448:x448_shared_secret(MySecretKey, YourPublicKey).
