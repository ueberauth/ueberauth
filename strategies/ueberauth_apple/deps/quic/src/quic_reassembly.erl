%%% -*- erlang -*-
%%%
%%% Out-of-order reassembly buffers (RFC 9000 Section 2.2).
%%%
%%% A buffer is a `gb_trees' keyed by stream offset, holding chunks that
%%% arrived ahead of the data before them. These functions are pure: they
%%% take a buffer and return a buffer, and every one also reports how
%%% many bytes entered or left the tree so the caller can keep a running
%%% count instead of walking it.
%%%
%%% Used for both stream data and CRYPTO frames by `quic_connection'.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
-module(quic_reassembly).

-export([
    extract_contiguous_data/2,
    trim_reassembly_buffer/2,
    keep_longest_chunk/3,
    reassembly_buffer_bytes/1
]).

-type buffer() :: gb_trees:tree(non_neg_integer(), binary()).
-export_type([buffer/0]).

%% @doc Extract contiguous data from buffer starting at Offset.
%%
%% Uses a binary append accumulator, which is amortized O(1) thanks to
%% the refc binary optimization. Returns
%% `{Delivered, NewOffset, Buffer, Removed}': `Removed' is how many bytes
%% left the tree, delivered or trimmed away, so the caller can keep its
%% byte count without walking the tree.
-spec extract_contiguous_data(buffer(), non_neg_integer()) ->
    {binary(), non_neg_integer(), buffer(), non_neg_integer()}.
extract_contiguous_data(Buffer, Offset) ->
    extract_contiguous_data(Buffer, Offset, <<>>, 0).

extract_contiguous_data(Buffer, Offset, Acc, Removed) ->
    case gb_trees:take_any(Offset, Buffer) of
        {Data, NewBuffer} ->
            NextOffset = Offset + byte_size(Data),
            extract_contiguous_data(
                NewBuffer, NextOffset, <<Acc/binary, Data/binary>>, Removed + byte_size(Data)
            );
        error ->
            case gb_trees:is_empty(Buffer) orelse element(1, gb_trees:smallest(Buffer)) > Offset of
                true ->
                    {Acc, Offset, Buffer, Removed};
                false ->
                    {Trimmed, Gone} = trim_reassembly_buffer(Buffer, Offset),
                    case gb_trees:is_defined(Offset, Trimmed) of
                        true -> extract_contiguous_data(Trimmed, Offset, Acc, Removed + Gone);
                        false -> {Acc, Offset, Trimmed, Removed + Gone}
                    end
            end
    end.

%% @doc Drop buffered chunks that end at or before Offset and trim those
%% that straddle it, re-keying them to Offset.
%%
%% Keeps the longest chunk at each offset, so overlapping retransmissions
%% collapse instead of accumulating. Only chunks keyed below Offset can
%% qualify, so the ordered walk stops there; everything above is left
%% untouched. Returns `{Buffer, Removed}' with the bytes that left the
%% tree.
-spec trim_reassembly_buffer(buffer(), non_neg_integer()) -> {buffer(), integer()}.
trim_reassembly_buffer(Buffer, Offset) ->
    trim_reassembly_buffer(gb_trees:iterator(Buffer), Buffer, Offset, 0).

trim_reassembly_buffer(Iter0, Buffer, Offset, Removed) ->
    case gb_trees:next(Iter0) of
        {Off, Data, Iter} when Off < Offset ->
            End = Off + byte_size(Data),
            Buffer1 = gb_trees:delete(Off, Buffer),
            Removed1 = Removed + byte_size(Data),
            {Buffer2, Added} =
                case End > Offset of
                    true ->
                        Kept = binary:part(Data, Offset - Off, End - Offset),
                        keep_longest_chunk(Offset, Kept, Buffer1);
                    false ->
                        {Buffer1, 0}
                end,
            trim_reassembly_buffer(Iter, Buffer2, Offset, Removed1 - Added);
        _ ->
            {Buffer, Removed}
    end.

%% @doc Store Data at Off unless a longer chunk is already there.
%%
%% Returns `{Buffer, Delta}': the change in bytes held by the tree.
-spec keep_longest_chunk(non_neg_integer(), binary(), buffer()) -> {buffer(), integer()}.
keep_longest_chunk(Off, Data, Buffer) ->
    case gb_trees:lookup(Off, Buffer) of
        {value, Existing} when byte_size(Existing) >= byte_size(Data) ->
            {Buffer, 0};
        {value, Existing} ->
            {gb_trees:enter(Off, Data, Buffer), byte_size(Data) - byte_size(Existing)};
        none ->
            {gb_trees:enter(Off, Data, Buffer), byte_size(Data)}
    end.

%% @doc Total bytes held in a CRYPTO reassembly buffer.
%%
%% Stream buffers keep a running count instead and do not need this.
-spec reassembly_buffer_bytes(buffer()) -> non_neg_integer().
reassembly_buffer_bytes(Buffer) ->
    lists:foldl(fun(Data, Acc) -> Acc + byte_size(Data) end, 0, gb_trees:values(Buffer)).
