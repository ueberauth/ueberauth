%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  22 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_alg_rsa).
-behaviour(jose_jwe).
-behaviour(jose_jwe_alg).

-include("jose_jwk.hrl").

%% jose_jwe callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jwe_alg callbacks
-export([generate_key/3]).
-export([key_decrypt/3]).
-export([key_encrypt/3]).
-export([next_cek/3]).
%% API

%% Types
-record(jose_jwe_alg_rsa, {
	algorithm = undefined :: undefined | rsa1_5 | rsa_oaep | rsa_oaep_256
}).

-type alg() :: #jose_jwe_alg_rsa{}.

-export_type([alg/0]).

-define(RSA1_5,       #jose_jwe_alg_rsa{algorithm=rsa1_5}).
-define(RSA_OAEP,     #jose_jwe_alg_rsa{algorithm=rsa_oaep}).
-define(RSA_OAEP_256, #jose_jwe_alg_rsa{algorithm=rsa_oaep_256}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"RSA1_5">> }) ->
	{?RSA1_5, maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"RSA-OAEP">> }) ->
	{?RSA_OAEP, maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"RSA-OAEP-256">> }) ->
	{?RSA_OAEP_256, maps:remove(<<"alg">>, F)}.

to_map(?RSA1_5, F) ->
	F#{ <<"alg">> => <<"RSA1_5">> };
to_map(?RSA_OAEP, F) ->
	F#{ <<"alg">> => <<"RSA-OAEP">> };
to_map(?RSA_OAEP_256, F) ->
	F#{ <<"alg">> => <<"RSA-OAEP-256">> }.

%%====================================================================
%% jose_jwe_alg callbacks
%%====================================================================

generate_key(_Fields, {ENCModule, ENC}, ?RSA1_5) ->
	jose_jwe_alg:generate_key({rsa, 2048}, <<"RSA1_5">>, ENCModule:algorithm(ENC));
generate_key(_Fields, {ENCModule, ENC}, ?RSA_OAEP) ->
	jose_jwe_alg:generate_key({rsa, 2048}, <<"RSA-OAEP">>, ENCModule:algorithm(ENC));
generate_key(_Fields, {ENCModule, ENC}, ?RSA_OAEP_256) ->
	jose_jwe_alg:generate_key({rsa, 2048}, <<"RSA-OAEP-256">>, ENCModule:algorithm(ENC)).

%% RFC 7516, Section 11.5 (and RFC 3218): the recipient MUST NOT distinguish
%% between format, padding, and length errors of the JWE Encrypted Key, and
%% SHOULD substitute a randomly generated CEK when the encrypted key is
%% improperly formatted. Without this, RSAES-PKCS1-v1_5 ("RSA1_5") unwrapping
%% hands the caller a one-bit padding-conformance signal, which is exactly the
%% oracle a Bleichenbacher adaptive chosen-ciphertext attack consumes.
%%
%% Generate the substitute CEK unconditionally and funnel malformed encrypted
%% keys into the content authentication check. This hides the padding error
%% result, but does not make the underlying RSA operation constant-time.
%% Prefer RSA-OAEP or RSA-OAEP-256 for new applications.
key_decrypt(#jose_jwk{kty={KTYModule, KTY}}, {ENCModule, ENC, EncryptedKey}, #jose_jwe_alg_rsa{algorithm=Algorithm}) ->
	RandomKey = ENCModule:next_cek(ENC),
	try KTYModule:decrypt_private(EncryptedKey, Algorithm, KTY) of
		DecryptedKey when is_binary(DecryptedKey)
				andalso byte_size(DecryptedKey) =:= byte_size(RandomKey) ->
			DecryptedKey;
		_BadDecryptedKey ->
			RandomKey
	catch
		_:_ ->
			RandomKey
	end.

key_encrypt(#jose_jwk{kty={KTYModule, KTY}}, DecryptedKey, JWERSA=#jose_jwe_alg_rsa{algorithm=Algorithm}) ->
	{KTYModule:encrypt_public(DecryptedKey, Algorithm, KTY), JWERSA}.

next_cek(_Key, {ENCModule, ENC}, ALG=#jose_jwe_alg_rsa{}) ->
	{ENCModule:next_cek(ENC), ALG}.

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
