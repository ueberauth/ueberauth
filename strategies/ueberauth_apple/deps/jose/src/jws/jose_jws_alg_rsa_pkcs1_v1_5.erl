%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  23 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jws_alg_rsa_pkcs1_v1_5).
-behaviour(jose_jws).
-behaviour(jose_jws_alg).

-include("jose_jwk.hrl").

%% jose_jws callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jws_alg callbacks
-export([generate_key/2]).
-export([sign/3]).
-export([verify/4]).

%% API

%% Types
-type alg() :: 'RS1' | 'RS256' | 'RS384' | 'RS512'.

-export_type([alg/0]).

%%====================================================================
%% jose_jws callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"RS1">> }) ->
	{'RS1', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"RS256">> }) ->
	{'RS256', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"RS384">> }) ->
	{'RS384', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"RS512">> }) ->
	{'RS512', maps:remove(<<"alg">>, F)}.

to_map('RS1', F) ->
	F#{ <<"alg">> => <<"RS1">> };
to_map('RS256', F) ->
	F#{ <<"alg">> => <<"RS256">> };
to_map('RS384', F) ->
	F#{ <<"alg">> => <<"RS384">> };
to_map('RS512', F) ->
	F#{ <<"alg">> => <<"RS512">> }.

%%====================================================================
%% jose_jws_alg callbacks
%%====================================================================

generate_key('RS1', _Fields) ->
	jose_jws_alg:generate_key({rsa, 2048}, <<"RS1">>);
generate_key('RS256', _Fields) ->
	jose_jws_alg:generate_key({rsa, 2048}, <<"RS256">>);
generate_key('RS384', _Fields) ->
	jose_jws_alg:generate_key({rsa, 3072}, <<"RS384">>);
generate_key('RS512', _Fields) ->
	jose_jws_alg:generate_key({rsa, 4096}, <<"RS512">>).

sign(#jose_jwk{kty={KTYModule, KTY}}, Message, ALG) ->
	KTYModule:sign(Message, ALG, KTY).

verify(#jose_jwk{kty={KTYModule, KTY}}, Message, Signature, ALG) ->
	KTYModule:verify(Message, ALG, Signature, KTY).

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
