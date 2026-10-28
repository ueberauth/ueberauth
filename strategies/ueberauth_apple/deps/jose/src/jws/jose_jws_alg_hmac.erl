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
-module(jose_jws_alg_hmac).
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
-type alg() :: 'HS256' | 'HS384' | 'HS512'.

-export_type([alg/0]).

%%====================================================================
%% jose_jws callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"HS256">> }) ->
	{'HS256', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"HS384">> }) ->
	{'HS384', maps:remove(<<"alg">>, F)};
from_map(F = #{ <<"alg">> := <<"HS512">> }) ->
	{'HS512', maps:remove(<<"alg">>, F)}.

to_map('HS256', F) ->
	F#{ <<"alg">> => <<"HS256">> };
to_map('HS384', F) ->
	F#{ <<"alg">> => <<"HS384">> };
to_map('HS512', F) ->
	F#{ <<"alg">> => <<"HS512">> }.

%%====================================================================
%% jose_jws_alg callbacks
%%====================================================================

generate_key('HS256', _Fields) ->
	jose_jws_alg:generate_key({oct, 32}, <<"HS256">>);
generate_key('HS384', _Fields) ->
	jose_jws_alg:generate_key({oct, 48}, <<"HS384">>);
generate_key('HS512', _Fields) ->
	jose_jws_alg:generate_key({oct, 64}, <<"HS512">>).

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
