%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2017-2019, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  11 May 2017 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------

-ifndef(JOSE_BASE_HRL).

-define(bnotzero(X),
	((((X) bor ((bnot (X)) + 1)) bsr 7) band 1)).

-define(is_iodata(I),
	(is_binary(I) orelse is_list(I))).

-define(to_binary(I),
	(case I of
		_ when is_binary(I) ->
			I;
		_ when is_list(I) ->
			erlang:iolist_to_binary(I)
	end)).

-define(JOSE_BASE_HRL, 1).

-endif.
