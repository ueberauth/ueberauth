%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  18 Aug 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk_oct).

-callback from_oct(OCTBinary) -> {KTY, Fields}
	when
		OCTBinary :: binary(),
		KTY       :: any(),
		Fields    :: map().
-callback to_oct(KTY) -> OCTBinary
	when
		KTY       :: any(),
		OCTBinary :: binary().

%% API
-export([from_binary/1]).

%%====================================================================
%% API functions
%%====================================================================

from_binary(OCTBinary) when is_binary(OCTBinary) ->
	jose_jwk_kty:from_oct(OCTBinary).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
