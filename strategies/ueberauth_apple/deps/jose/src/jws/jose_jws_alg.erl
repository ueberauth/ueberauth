%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  29 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jws_alg).

-callback generate_key(ALG, Fields) -> JWK
	when
		ALG    :: any(),
		Fields :: map(),
		JWK    :: jose_jwk:key().
-callback sign(Key, Message, ALG) -> Signature
	when
		Key       :: any(),
		Message   :: iodata(),
		ALG       :: any(),
		Signature :: iodata().
-callback verify(Key, Message, Signature, ALG) -> boolean()
	when
		Key       :: any(),
		Message   :: iodata(),
		Signature :: iodata(),
		ALG       :: any().

-callback presign(Key, ALG) -> NewALG
	when
		Key    :: any(),
		ALG    :: any(),
		NewALG :: any().

-optional_callbacks([presign/2]).

%% API
-export([generate_key/2]).

%%====================================================================
%% API functions
%%====================================================================

generate_key(Parameters, Algorithm) ->
	jose_jwk:merge(jose_jwk:generate_key(Parameters), #{
		<<"alg">> => Algorithm,
		<<"use">> => <<"sig">>
	}).
