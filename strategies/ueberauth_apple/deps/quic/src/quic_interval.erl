%%% -*- erlang -*-
%%%
%%% Sorted lists of disjoint inclusive integer intervals.
%%%
%%% `quic_connection' tracks reclaimed stream ids this way: a stream id
%%% normalised to `StreamId bsr 2' becomes a point in one of these lists,
%%% so a frame for an already-reclaimed stream can be told apart from a
%%% genuinely new one without keeping per-stream state (RFC 9000 Section
%%% 2.1: stream ids are never reused).
%%%
%%% Adjacent intervals merge: a gap of zero on the normalised index,
%%% which is stride-4 on the raw stream id.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
-module(quic_interval).

-export([add/2, member/2]).

-type interval() :: {integer(), integer()}.
-type intervals() :: [interval()].
-export_type([interval/0, intervals/0]).

%% @doc Insert Idx, merging adjacent and overlapping ranges.
-spec add(integer(), intervals()) -> intervals().
add(Idx, []) ->
    [{Idx, Idx}];
add(Idx, [{Lo, _Hi} | _] = Ranges) when Idx < Lo - 1 ->
    [{Idx, Idx} | Ranges];
add(Idx, [{Lo, Hi} | Rest]) when Idx =:= Lo - 1 ->
    [{Idx, Hi} | Rest];
add(Idx, [{Lo, Hi} | Rest]) when Idx >= Lo, Idx =< Hi ->
    [{Lo, Hi} | Rest];
add(Idx, [{Lo, Hi} | Rest]) when Idx =:= Hi + 1 ->
    merge_next({Lo, Idx}, Rest);
add(Idx, [{Lo, Hi} | Rest]) ->
    [{Lo, Hi} | add(Idx, Rest)].

merge_next({Lo, Hi}, [{Lo2, Hi2} | Rest]) when Lo2 =< Hi + 1 ->
    [{Lo, max(Hi, Hi2)} | Rest];
merge_next(Interval, Rest) ->
    [Interval | Rest].

%% @doc True when Idx falls inside one of the intervals.
-spec member(integer(), intervals()) -> boolean().
member(_Idx, []) ->
    false;
member(Idx, [{Lo, Hi} | _]) when Idx >= Lo, Idx =< Hi ->
    true;
member(Idx, [{Lo, _Hi} | _]) when Idx < Lo ->
    false;
member(Idx, [_ | Rest]) ->
    member(Idx, Rest).
