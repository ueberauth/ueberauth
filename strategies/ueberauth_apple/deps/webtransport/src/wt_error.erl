%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc Application error code mapping (draft-ietf-webtrans-http3-15 §3.3).
%%
%% WebTransport application error codes are 32-bit integers local to the
%% session. On the wire (QUIC / H/2 capsule) they must be carried as
%% values that do not collide with HTTP/3 reserved error codes of the
%% form `0x1f * N + 0x21'. The draft specifies a reversible mapping:
%%
%%   to_quic(App)   = WT_APP_ERROR_FIRST + App + App div 30
%%   from_quic(Q)   = inverse, or `error' when Q falls on a reserved slot
%%
%% The `+ App div 30' factor reserves one QUIC code per 30 consecutive
%% application codes so the HTTP/3 reserved pattern always lands in a
%% skipped slot.
-module(wt_error).

-include("webtransport.hrl").

-export([to_quic/1, from_quic/1]).
-export([app_error_range/0]).

-define(WT_APP_ERROR_LAST, ?WT_APP_ERROR_FIRST + 16#ffffffff + (16#ffffffff div 30)).

%% @doc Return the {First, Last} QUIC error code range reserved for WT app errors.
-spec app_error_range() -> {non_neg_integer(), non_neg_integer()}.
app_error_range() ->
    {?WT_APP_ERROR_FIRST, ?WT_APP_ERROR_LAST}.

%% @doc Map a 32-bit application error code to its QUIC wire representation.
-spec to_quic(non_neg_integer()) -> non_neg_integer().
to_quic(App) when is_integer(App), App >= 0, App =< 16#ffffffff ->
    ?WT_APP_ERROR_FIRST + App + App div 30.

%% @doc Map a QUIC wire error code back to the application error, or error if out of range.
-spec from_quic(non_neg_integer()) -> {ok, non_neg_integer()} | error.
from_quic(Q) when is_integer(Q), Q >= ?WT_APP_ERROR_FIRST, Q =< ?WT_APP_ERROR_LAST ->
    Diff = Q - ?WT_APP_ERROR_FIRST,
    Cand = Diff - Diff div 31,
    case to_quic(Cand) of
        Q -> {ok, Cand};
        _ -> error
    end;
from_quic(_) ->
    error.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

roundtrip_small_test_() ->
    [?_assertEqual({ok, N}, from_quic(to_quic(N))) || N <- lists:seq(0, 100)].

roundtrip_boundary_test_() ->
    [
        ?_assertEqual({ok, 0}, from_quic(to_quic(0))),
        ?_assertEqual({ok, 16#ffffffff}, from_quic(to_quic(16#ffffffff))),
        ?_assertEqual({ok, 16#7fffffff}, from_quic(to_quic(16#7fffffff)))
    ].

reserved_slots_return_error_test_() ->
    %% The slots we skip (to_quic(30) - 1, to_quic(31) - 1, etc.) must
    %% round-trip to `error', not spuriously match a neighbouring app code.
    [?_assertEqual(error, from_quic(?WT_APP_ERROR_FIRST + 30 + K * 31))
     || K <- lists:seq(0, 20)].

out_of_range_test_() ->
    [
        ?_assertEqual(error, from_quic(?WT_APP_ERROR_FIRST - 1)),
        ?_assertEqual(error, from_quic(0)),
        ?_assertEqual(error, from_quic(16#100))
    ].

to_quic_rejects_negative_test() ->
    ?assertError(function_clause, to_quic(-1)).

to_quic_rejects_over_32bit_test() ->
    ?assertError(function_clause, to_quic(16#100000000)).

-endif.
