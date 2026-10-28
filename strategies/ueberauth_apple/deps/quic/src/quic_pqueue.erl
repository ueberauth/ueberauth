%%% -*- erlang -*-
%%%
%%% Bucket-based priority queue for stream send urgency (RFC 9218).
%%%
%%% Eight buckets, one per urgency level 0 to 7, held in a tuple. Insert
%%% and dequeue are constant time: dequeue walks at most eight buckets.
%%% Lowest urgency wins, so bucket 0 drains first.
%%%
%%% This is the queue behind `#state.send_queue' in `quic_connection'.
%%% It is pure: entries are opaque to it, and it holds no connection
%%% state of its own.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
-module(quic_pqueue).

-export([
    new/0,
    in/3,
    in_front/3,
    out/1,
    peek/1,
    is_empty/1
]).

-type urgency() :: 0..7.
-type pqueue() :: {
    queue:queue(),
    queue:queue(),
    queue:queue(),
    queue:queue(),
    queue:queue(),
    queue:queue(),
    queue:queue(),
    queue:queue()
}.

-export_type([pqueue/0, urgency/0]).

%% @doc An empty queue: eight empty buckets.
-spec new() -> pqueue().
new() ->
    {
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new(),
        queue:new()
    }.

%% @doc Append an entry to its urgency bucket.
-spec in(term(), urgency(), pqueue()) -> pqueue().
in(Entry, Urgency, PQ) when Urgency >= 0, Urgency =< 7 ->
    Bucket = element(Urgency + 1, PQ),
    NewBucket = queue:in(Entry, Bucket),
    setelement(Urgency + 1, PQ, NewBucket).

%% @doc Insert at the front of the urgency bucket. Used when a drain pops
%% an entry and must put back an unsent remainder: appending it at the
%% back would order it behind higher-offset entries of the same stream,
%% and a later stream-flow-control block at the head then strands it
%% forever (the peer cannot extend the window across the resulting data
%% hole).
-spec in_front(term(), urgency(), pqueue()) -> pqueue().
in_front(Entry, Urgency, PQ) when Urgency >= 0, Urgency =< 7 ->
    Bucket = element(Urgency + 1, PQ),
    NewBucket = queue:in_r(Entry, Bucket),
    setelement(Urgency + 1, PQ, NewBucket).

%% @doc Remove and return the highest priority (lowest urgency) entry.
-spec out(pqueue()) -> {{value, term()}, pqueue()} | {empty, pqueue()}.
out(PQ) ->
    out(PQ, 0).

out(_PQ, 8) ->
    {empty, new()};
out(PQ, Urgency) ->
    Bucket = element(Urgency + 1, PQ),
    case queue:out(Bucket) of
        {empty, _} ->
            out(PQ, Urgency + 1);
        {{value, Entry}, NewBucket} ->
            NewPQ = setelement(Urgency + 1, PQ, NewBucket),
            {{value, Entry}, NewPQ}
    end.

%% @doc Peek at the highest priority entry without removing it.
-spec peek(pqueue()) -> {value, term()} | empty.
peek(PQ) ->
    peek(PQ, 0).

peek(_PQ, 8) ->
    empty;
peek(PQ, Urgency) ->
    Bucket = element(Urgency + 1, PQ),
    case queue:peek(Bucket) of
        empty ->
            peek(PQ, Urgency + 1);
        {value, Entry} ->
            {value, Entry}
    end.

%% @doc True when every bucket is empty.
-spec is_empty(pqueue()) -> boolean().
is_empty(PQ) ->
    is_empty(PQ, 0).

is_empty(_PQ, 8) ->
    true;
is_empty(PQ, Urgency) ->
    case queue:is_empty(element(Urgency + 1, PQ)) of
        true -> is_empty(PQ, Urgency + 1);
        false -> false
    end.
