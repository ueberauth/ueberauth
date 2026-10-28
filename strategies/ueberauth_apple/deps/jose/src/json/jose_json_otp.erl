%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(jose_json_otp).
-behaviour(jose_json).

%% jose_json callbacks
-export([decode/1]).
-export([encode/1]).

%%====================================================================
%% jose_json callbacks
%%====================================================================

-spec decode(binary()) -> dynamic().
decode(Binary) -> json:decode(Binary).

-spec encode(dynamic()) -> binary().
encode(Term) -> iolist_to_binary(json:encode(Term, fun encoder/2)).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
-compile({inline, [dynamic_cast/1]}).
-spec dynamic_cast(term()) -> dynamic().
dynamic_cast(X) -> X.

%% @private
-spec encoder(dynamic(), json:encoder()) -> iodata().
encoder(List, Encoder) when is_list(List) ->
    json:encode_list(List, Encoder);
encoder(Map, Encoder) when is_map(Map) ->
    KeyValueList = maps:to_list(dynamic_cast(maps:iterator(Map, ordered))),
    json:encode_key_value_list(KeyValueList, Encoder);
encoder('nil', Encoder) ->
    json:encode_atom(null, Encoder);
encoder(Value, Encoder) ->
    json:encode_value(Value, Encoder).
