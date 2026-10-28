%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  07 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_curve448).

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
	jose_jwa_ed448:keypair().

eddsa_keypair(Seed)
		when is_binary(Seed) ->
	jose_jwa_ed448:keypair(Seed).

eddsa_secret_to_public(SecretKey)
		when is_binary(SecretKey) ->
	jose_jwa_ed448:secret_to_pk(SecretKey).

% Ed448
ed448_sign(Message, SecretKey)
		when is_binary(Message)
		andalso is_binary(SecretKey) ->
	jose_jwa_ed448:ed448_sign(Message, SecretKey).

ed448_sign(Message, SecretKey, Context)
		when is_binary(Message)
		andalso is_binary(SecretKey)
		andalso is_binary(Context) ->
	jose_jwa_ed448:ed448_sign(Message, SecretKey, Context).

ed448_verify(Signature, Message, PublicKey)
		when is_binary(Signature)
		andalso is_binary(Message)
		andalso is_binary(PublicKey) ->
	try
		jose_jwa_ed448:ed448_verify(Signature, Message, PublicKey)
	catch
		_:_ ->
			false
	end.

ed448_verify(Signature, Message, PublicKey, Context)
		when is_binary(Signature)
		andalso is_binary(Message)
		andalso is_binary(PublicKey)
		andalso is_binary(Context) ->
	try
		jose_jwa_ed448:ed448_verify(Signature, Message, PublicKey, Context)
	catch
		_:_ ->
			false
	end.

% Ed448ph
ed448ph_sign(Message, SecretKey)
		when is_binary(Message)
		andalso is_binary(SecretKey) ->
	jose_jwa_ed448:ed448ph_sign(Message, SecretKey).

ed448ph_sign(Message, SecretKey, Context)
		when is_binary(Message)
		andalso is_binary(SecretKey)
		andalso is_binary(Context) ->
	jose_jwa_ed448:ed448ph_sign(Message, SecretKey, Context).

ed448ph_verify(Signature, Message, PublicKey)
		when is_binary(Signature)
		andalso is_binary(Message)
		andalso is_binary(PublicKey) ->
	try
		jose_jwa_ed448:ed448ph_verify(Signature, Message, PublicKey)
	catch
		_:_ ->
			false
	end.

ed448ph_verify(Signature, Message, PublicKey, Context)
		when is_binary(Signature)
		andalso is_binary(Message)
		andalso is_binary(PublicKey)
		andalso is_binary(Context) ->
	try
		jose_jwa_ed448:ed448ph_verify(Signature, Message, PublicKey, Context)
	catch
		_:_ ->
			false
	end.

% X448
x448_keypair() ->
	jose_jwa_x448:keypair().

x448_keypair(Seed)
		when is_binary(Seed) ->
	jose_jwa_x448:keypair(Seed).

x448_secret_to_public(SecretKey)
		when is_binary(SecretKey) ->
	jose_jwa_x448:sk_to_pk(SecretKey).

x448_shared_secret(MySecretKey, YourPublicKey)
		when is_binary(MySecretKey)
		andalso is_binary(YourPublicKey) ->
	jose_jwa_x448:x448(MySecretKey, YourPublicKey).
