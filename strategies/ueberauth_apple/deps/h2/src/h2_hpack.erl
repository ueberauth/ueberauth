%% @doc HPACK Header Compression for HTTP/2 (RFC 7541)
%%
%% This module provides HPACK encoding and decoding for HTTP/2 headers.
%%
%% HPACK uses:
%% - Static table: 61 predefined header name/value pairs
%% - Dynamic table: Runtime-populated entries (FIFO eviction)
%% - Huffman coding: Optional string compression
%% - Integer encoding: Variable-length prefix encoding
%%
-module(h2_hpack).

-export([new_context/0, new_context/1]).
-export([encode/2, decode/2]).
-export([set_max_table_size/2, get_max_table_size/1]).
-export([mark_pending_size_update/1, set_peer_max_table_size/2]).
-export([encode_integer/2, decode_integer/2]).
-export([huffman_encode/1, huffman_decode/1]).

-on_load(init_tables/0).

-include("h2.hrl").
-include("h2_hpack_huffman.hrl").

-define(PT_HUFFMAN_ENCODE, {?MODULE, huffman_encode_tuple}).
-define(PT_HUFFMAN_DECODE, {?MODULE, huffman_decode_sorted}).
-define(PT_STATIC_TABLE,   {?MODULE, static_table_tuple}).
%% Encoder lookups: {Name,Value} -> Index (exact) and Name -> first Index.
-define(PT_STATIC_EXACT,   {?MODULE, static_exact_index}).
-define(PT_STATIC_NAME,    {?MODULE, static_name_index}).

%% Context record for encoder/decoder state
-record(hpack_context, {
    max_table_size = ?DEFAULT_HEADER_TABLE_SIZE :: non_neg_integer(),
    table_size = 0 :: non_neg_integer(),
    %% Dynamic table as a map keyed by a monotonic insertion sequence, giving
    %% O(1) indexed lookup, insert, and oldest-eviction. HPACK dynamic index i
    %% (1 = newest) maps to sequence (dynamic_newest - (i - 1)); the oldest live
    %% sequence is (dynamic_newest - dynamic_table_length + 1).
    dynamic_entries = #{} :: #{pos_integer() => {binary(), binary()}},
    dynamic_newest = 0 :: non_neg_integer(),
    dynamic_table_length = 0 :: non_neg_integer(),
    %% RFC 7541 §4.2: when the peer lowers SETTINGS_HEADER_TABLE_SIZE,
    %% the next header block MUST begin with one or more dynamic-table
    %% size updates that reduce the size at or below the new limit.
    pending_size_update = false :: boolean(),
    %% RFC 7541 §4.3: peer-advertised cap (SETTINGS_HEADER_TABLE_SIZE on
    %% the wire). Decoder must reject any received size update larger
    %% than this with a COMPRESSION_ERROR. Defaults to the spec default.
    peer_max_table_size = ?DEFAULT_HEADER_TABLE_SIZE :: non_neg_integer()
}).

-type context() :: #hpack_context{}.
-type header() :: {binary(), binary()}.
-type headers() :: [header()].

-export_type([context/0, header/0, headers/0]).

%% Static table (RFC 7541 Appendix A)
-define(STATIC_TABLE, [
    {<<":authority">>, <<>>},           %% 1
    {<<":method">>, <<"GET">>},         %% 2
    {<<":method">>, <<"POST">>},        %% 3
    {<<":path">>, <<"/">>},             %% 4
    {<<":path">>, <<"/index.html">>},   %% 5
    {<<":scheme">>, <<"http">>},        %% 6
    {<<":scheme">>, <<"https">>},       %% 7
    {<<":status">>, <<"200">>},         %% 8
    {<<":status">>, <<"204">>},         %% 9
    {<<":status">>, <<"206">>},         %% 10
    {<<":status">>, <<"304">>},         %% 11
    {<<":status">>, <<"400">>},         %% 12
    {<<":status">>, <<"404">>},         %% 13
    {<<":status">>, <<"500">>},         %% 14
    {<<"accept-charset">>, <<>>},       %% 15
    {<<"accept-encoding">>, <<"gzip, deflate">>},  %% 16
    {<<"accept-language">>, <<>>},      %% 17
    {<<"accept-ranges">>, <<>>},        %% 18
    {<<"accept">>, <<>>},               %% 19
    {<<"access-control-allow-origin">>, <<>>},  %% 20
    {<<"age">>, <<>>},                  %% 21
    {<<"allow">>, <<>>},                %% 22
    {<<"authorization">>, <<>>},        %% 23
    {<<"cache-control">>, <<>>},        %% 24
    {<<"content-disposition">>, <<>>},  %% 25
    {<<"content-encoding">>, <<>>},     %% 26
    {<<"content-language">>, <<>>},     %% 27
    {<<"content-length">>, <<>>},       %% 28
    {<<"content-location">>, <<>>},     %% 29
    {<<"content-range">>, <<>>},        %% 30
    {<<"content-type">>, <<>>},         %% 31
    {<<"cookie">>, <<>>},               %% 32
    {<<"date">>, <<>>},                 %% 33
    {<<"etag">>, <<>>},                 %% 34
    {<<"expect">>, <<>>},               %% 35
    {<<"expires">>, <<>>},              %% 36
    {<<"from">>, <<>>},                 %% 37
    {<<"host">>, <<>>},                 %% 38
    {<<"if-match">>, <<>>},             %% 39
    {<<"if-modified-since">>, <<>>},    %% 40
    {<<"if-none-match">>, <<>>},        %% 41
    {<<"if-range">>, <<>>},             %% 42
    {<<"if-unmodified-since">>, <<>>},  %% 43
    {<<"last-modified">>, <<>>},        %% 44
    {<<"link">>, <<>>},                 %% 45
    {<<"location">>, <<>>},             %% 46
    {<<"max-forwards">>, <<>>},         %% 47
    {<<"proxy-authenticate">>, <<>>},   %% 48
    {<<"proxy-authorization">>, <<>>},  %% 49
    {<<"range">>, <<>>},                %% 50
    {<<"referer">>, <<>>},              %% 51
    {<<"refresh">>, <<>>},              %% 52
    {<<"retry-after">>, <<>>},          %% 53
    {<<"server">>, <<>>},               %% 54
    {<<"set-cookie">>, <<>>},           %% 55
    {<<"strict-transport-security">>, <<>>},  %% 56
    {<<"transfer-encoding">>, <<>>},    %% 57
    {<<"user-agent">>, <<>>},           %% 58
    {<<"vary">>, <<>>},                 %% 59
    {<<"via">>, <<>>},                  %% 60
    {<<"www-authenticate">>, <<>>}      %% 61
]).

%% @doc Create a new HPACK context with default settings.
-spec new_context() -> context().
new_context() ->
    new_context(?DEFAULT_HEADER_TABLE_SIZE).

%% @doc Create a new HPACK context with specified max table size.
-spec new_context(non_neg_integer()) -> context().
new_context(MaxTableSize) ->
    #hpack_context{max_table_size = MaxTableSize}.

%% @doc Set the maximum dynamic table size.
-spec set_max_table_size(non_neg_integer(), context()) -> context().
set_max_table_size(Size, Ctx) ->
    Ctx1 = Ctx#hpack_context{max_table_size = Size},
    evict_to_fit(0, Ctx1).

%% @doc Get the maximum dynamic table size.
-spec get_max_table_size(context()) -> non_neg_integer().
get_max_table_size(#hpack_context{max_table_size = Size}) ->
    Size.

%% @doc Mark the decoder so that the next header block MUST start with a
%% dynamic-table size update (RFC 7541 §4.2). Call this when the peer
%% lowers SETTINGS_HEADER_TABLE_SIZE.
-spec mark_pending_size_update(context()) -> context().
mark_pending_size_update(Ctx) ->
    Ctx#hpack_context{pending_size_update = true}.

%% @doc Record the peer-advertised SETTINGS_HEADER_TABLE_SIZE so the
%% decoder can reject incoming size updates larger than this value
%% (RFC 7541 §4.3). Also marks pending_size_update if reduced.
-spec set_peer_max_table_size(non_neg_integer(), context()) -> context().
set_peer_max_table_size(Max, #hpack_context{peer_max_table_size = OldMax} = Ctx) ->
    Ctx1 = Ctx#hpack_context{peer_max_table_size = Max},
    case Max < OldMax of
        true -> Ctx1#hpack_context{pending_size_update = true};
        false -> Ctx1
    end.

%% @doc Initialize Huffman lookup tables. Called at module load time.
-spec init_tables() -> ok.
init_tables() ->
    persistent_term:put(?PT_HUFFMAN_ENCODE,
                        list_to_tuple(?HUFFMAN_ENCODE_TABLE)),
    %% Decoder: an 8-bit state machine (see build_huffman_fsm/0) so decode does
    %% one tuple lookup per input byte rather than per-bit matching.
    persistent_term:put(?PT_HUFFMAN_DECODE, build_huffman_fsm()),
    persistent_term:put(?PT_STATIC_TABLE,
                        list_to_tuple(?STATIC_TABLE)),
    {StaticExact, StaticName} = build_static_indices(?STATIC_TABLE),
    persistent_term:put(?PT_STATIC_EXACT, StaticExact),
    persistent_term:put(?PT_STATIC_NAME, StaticName),
    ok.

%% Build the encoder index maps from the static table. Exact map keys every
%% {Name,Value} pair to its index; name map keys each Name to its first index
%% (matching the original linear scan, which returned the first name match).
build_static_indices(Table) ->
    {Exact, Name, _} = lists:foldl(
        fun({N, V}, {ExAcc, NmAcc, Idx}) ->
            NmAcc1 = case maps:is_key(N, NmAcc) of
                true  -> NmAcc;
                false -> NmAcc#{N => Idx}
            end,
            {ExAcc#{{N, V} => Idx}, NmAcc1, Idx + 1}
        end, {#{}, #{}, 1}, Table),
    {Exact, Name}.

%% @doc Encode a list of headers.
-spec encode(headers(), context()) -> {binary(), context()}.
encode(Headers, Ctx) ->
    encode_headers(Headers, Ctx, <<>>).

encode_headers([], Ctx, Acc) ->
    {Acc, Ctx};
encode_headers([{Name, Value}|Rest], Ctx, Acc) ->
    {Encoded, Ctx1} = encode_header(Name, Value, Ctx),
    encode_headers(Rest, Ctx1, <<Acc/binary, Encoded/binary>>).

encode_header(Name, Value, Ctx) ->
    %% Try to find an exact match in static or dynamic table
    case find_header(Name, Value, Ctx) of
        {indexed, Index} ->
            %% Indexed Header Field (Section 6.1)
            Encoded = encode_indexed(Index),
            {Encoded, Ctx};
        {name_indexed, Index} ->
            %% Literal Header with Incremental Indexing (Section 6.2.1)
            {Encoded, Ctx1} = encode_literal_indexed(Index, Value, Ctx),
            {Encoded, Ctx1};
        not_found ->
            %% Literal Header with Incremental Indexing, new name
            {Encoded, Ctx1} = encode_literal_new(Name, Value, Ctx),
            {Encoded, Ctx1}
    end.

encode_indexed(Index) ->
    encode_integer(Index, 7, 2#1).

encode_literal_indexed(NameIndex, Value, Ctx) ->
    IndexBin = encode_integer(NameIndex, 6, 2#01),
    ValueBin = encode_string(Value),
    Encoded = <<IndexBin/binary, ValueBin/binary>>,
    Ctx1 = add_to_dynamic_table(lookup_name(NameIndex, Ctx), Value, Ctx),
    {Encoded, Ctx1}.

encode_literal_new(Name, Value, Ctx) ->
    IndexBin = encode_integer(0, 6, 2#01),
    NameBin = encode_string(Name),
    ValueBin = encode_string(Value),
    Encoded = <<IndexBin/binary, NameBin/binary, ValueBin/binary>>,
    Ctx1 = add_to_dynamic_table(Name, Value, Ctx),
    {Encoded, Ctx1}.

encode_string(Str) ->
    %% Try Huffman encoding, use if shorter
    Huffman = huffman_encode(Str),
    if
        byte_size(Huffman) < byte_size(Str) ->
            Len = encode_integer(byte_size(Huffman), 7, 2#1),
            <<Len/binary, Huffman/binary>>;
        true ->
            Len = encode_integer(byte_size(Str), 7, 2#0),
            <<Len/binary, Str/binary>>
    end.

%% @doc Decode a HPACK-encoded header block.
-spec decode(binary(), context()) -> {ok, headers(), context()} | {error, term()}.
decode(Bin, Ctx) ->
    %% StateFlag: true means we've processed a non-size-update representation,
    %% and any subsequent size update MUST fail (RFC 7541 §4.2).
    decode_headers(Bin, Ctx, [], false).

decode_headers(<<>>, #hpack_context{pending_size_update = true}, _Acc, _HasOther) ->
    %% RFC 7541 §4.2: required size update never appeared → compression error.
    {error, missing_size_update};
decode_headers(<<>>, Ctx, Acc, _HasOther) ->
    {ok, lists:reverse(Acc), Ctx};
decode_headers(<<2#1:1, _/bits>> = Bin, Ctx, Acc, _HasOther) ->
    %% Indexed Header Field (Section 6.1)
    case Ctx#hpack_context.pending_size_update of
        true -> {error, missing_size_update};
        false ->
            case decode_integer(Bin, 7) of
                {ok, 0, _} ->
                    {error, invalid_index};
                {ok, Index, Rest} ->
                    case lookup(Index, Ctx) of
                        {ok, Name, Value} ->
                            decode_headers(Rest, Ctx, [{Name, Value}|Acc], true);
                        error ->
                            {error, {invalid_index, Index}}
                    end;
                {error, _} = Err ->
                    Err
            end
    end;
decode_headers(<<2#01:2, _/bits>> = Bin, Ctx, Acc, _HasOther) ->
    %% Literal Header with Incremental Indexing (Section 6.2.1)
    case Ctx#hpack_context.pending_size_update of
        true -> {error, missing_size_update};
        false ->
            case decode_literal(Bin, 6, Ctx) of
                {ok, Name, Value, Rest, Ctx1} ->
                    Ctx2 = add_to_dynamic_table(Name, Value, Ctx1),
                    decode_headers(Rest, Ctx2, [{Name, Value}|Acc], true);
                {error, _} = Err ->
                    Err
            end
    end;
decode_headers(<<2#0000:4, _/bits>> = Bin, Ctx, Acc, _HasOther) ->
    %% Literal Header without Indexing (Section 6.2.2)
    case Ctx#hpack_context.pending_size_update of
        true -> {error, missing_size_update};
        false ->
            case decode_literal(Bin, 4, Ctx) of
                {ok, Name, Value, Rest, Ctx1} ->
                    decode_headers(Rest, Ctx1, [{Name, Value}|Acc], true);
                {error, _} = Err ->
                    Err
            end
    end;
decode_headers(<<2#0001:4, _/bits>> = Bin, Ctx, Acc, _HasOther) ->
    %% Literal Header Never Indexed (Section 6.2.3)
    case Ctx#hpack_context.pending_size_update of
        true -> {error, missing_size_update};
        false ->
            case decode_literal(Bin, 4, Ctx) of
                {ok, Name, Value, Rest, Ctx1} ->
                    decode_headers(Rest, Ctx1, [{Name, Value}|Acc], true);
                {error, _} = Err ->
                    Err
            end
    end;
decode_headers(<<2#001:3, _/bits>> = Bin, Ctx, Acc, HasOther) ->
    %% Dynamic Table Size Update (Section 6.3)
    case HasOther of
        true ->
            %% Size updates MUST appear at the start of the block.
            {error, invalid_size_update};
        false ->
            case decode_integer(Bin, 5) of
                {ok, Size, _Rest} when Size > Ctx#hpack_context.peer_max_table_size ->
                    %% RFC 7541 §4.3: size update larger than peer-advertised
                    %% maximum is a COMPRESSION_ERROR.
                    {error, size_update_exceeds_peer_max};
                {ok, Size, Rest} ->
                    Ctx1 = set_max_table_size(Size, Ctx),
                    Ctx2 = Ctx1#hpack_context{pending_size_update = false},
                    decode_headers(Rest, Ctx2, Acc, false);
                {error, _} = Err ->
                    Err
            end
    end.

decode_literal(Bin, Prefix, Ctx) ->
    case decode_integer(Bin, Prefix) of
        {ok, 0, Rest} ->
            %% New name
            case decode_string(Rest) of
                {ok, Name, Rest1} ->
                    case decode_string(Rest1) of
                        {ok, Value, Rest2} ->
                            {ok, Name, Value, Rest2, Ctx};
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {ok, Index, Rest} ->
            %% Indexed name
            case lookup_name(Index, Ctx) of
                error ->
                    {error, {invalid_index, Index}};
                Name ->
                    case decode_string(Rest) of
                        {ok, Value, Rest1} ->
                            {ok, Name, Value, Rest1, Ctx};
                        {error, _} = Err ->
                            Err
                    end
            end;
        {error, _} = Err ->
            Err
    end.

%% Truncated input — caller supplied a header block that ended before the
%% string literal was complete (RFC 7541 §5.2). Return a tagged error
%% instead of crashing with function_clause.
decode_string(<<>>) ->
    {error, incomplete_string};
decode_string(<<2#1:1, _/bits>> = Bin) ->
    %% Huffman encoded
    case decode_integer(Bin, 7) of
        {ok, Len, Rest} when byte_size(Rest) >= Len ->
            <<Huffman:Len/binary, Rest1/binary>> = Rest,
            case huffman_decode(Huffman) of
                {ok, Str} -> {ok, Str, Rest1};
                {error, _} = Err -> Err
            end;
        {ok, Len, _} ->
            {error, {incomplete_string, Len}};
        {error, _} = Err ->
            Err
    end;
decode_string(<<2#0:1, _/bits>> = Bin) ->
    %% Raw string
    case decode_integer(Bin, 7) of
        {ok, Len, Rest} when byte_size(Rest) >= Len ->
            <<Str:Len/binary, Rest1/binary>> = Rest,
            {ok, Str, Rest1};
        {ok, Len, _} ->
            {error, {incomplete_string, Len}};
        {error, _} = Err ->
            Err
    end.

%% Table operations

find_header(Name, Value, Ctx) ->
    case find_in_static(Name, Value) of
        {indexed, _} = Found -> Found;
        {name_indexed, _} = Found ->
            %% Check dynamic table for exact match
            case find_in_dynamic(Name, Value, Ctx) of
                {indexed, _} = DFound -> DFound;
                _ -> Found
            end;
        not_found ->
            find_in_dynamic(Name, Value, Ctx)
    end.

find_in_static(Name, Value) ->
    case maps:find({Name, Value}, persistent_term:get(?PT_STATIC_EXACT)) of
        {ok, Index} ->
            {indexed, Index};
        error ->
            case maps:find(Name, persistent_term:get(?PT_STATIC_NAME)) of
                {ok, NameIndex} -> {name_indexed, NameIndex};
                error           -> not_found
            end
    end.

%% Encoder reverse lookup: scan the dynamic table from newest (DynIndex 1) to
%% oldest. O(n) over the dynamic table, but this is the response-encode path
%% with a small table, not the hot request-decode path.
find_in_dynamic(Name, Value, #hpack_context{dynamic_entries = Entries,
                                            dynamic_newest = Newest,
                                            dynamic_table_length = Len}) ->
    find_in_dynamic(Name, Value, Entries, Newest, 1, Len, not_found).

find_in_dynamic(_Name, _Value, _Entries, _Newest, DynIndex, Len, NameMatch)
  when DynIndex > Len ->
    NameMatch;
find_in_dynamic(Name, Value, Entries, Newest, DynIndex, Len, NameMatch) ->
    Index = ?HPACK_STATIC_TABLE_SIZE + DynIndex,
    case maps:get(Newest - (DynIndex - 1), Entries) of
        {Name, Value} ->
            {indexed, Index};
        {Name, _} when NameMatch =:= not_found ->
            find_in_dynamic(Name, Value, Entries, Newest, DynIndex + 1, Len,
                            {name_indexed, Index});
        _ ->
            find_in_dynamic(Name, Value, Entries, Newest, DynIndex + 1, Len,
                            NameMatch)
    end.

lookup(Index, _Ctx) when Index >= 1, Index =< ?HPACK_STATIC_TABLE_SIZE ->
    {Name, Value} = element(Index, persistent_term:get(?PT_STATIC_TABLE)),
    {ok, Name, Value};
lookup(Index, #hpack_context{dynamic_entries = Entries,
                             dynamic_newest = Newest,
                             dynamic_table_length = Len}) ->
    DynIndex = Index - ?HPACK_STATIC_TABLE_SIZE,
    if
        DynIndex >= 1, DynIndex =< Len ->
            {Name, Value} = maps:get(Newest - (DynIndex - 1), Entries),
            {ok, Name, Value};
        true ->
            error
    end.

lookup_name(Index, _Ctx) when Index >= 1, Index =< ?HPACK_STATIC_TABLE_SIZE ->
    {Name, _} = element(Index, persistent_term:get(?PT_STATIC_TABLE)),
    Name;
lookup_name(Index, #hpack_context{dynamic_entries = Entries,
                                  dynamic_newest = Newest,
                                  dynamic_table_length = Len}) ->
    DynIndex = Index - ?HPACK_STATIC_TABLE_SIZE,
    if
        DynIndex >= 1, DynIndex =< Len ->
            {Name, _} = maps:get(Newest - (DynIndex - 1), Entries),
            Name;
        true ->
            error
    end.

add_to_dynamic_table(Name, Value, Ctx) ->
    EntrySize = entry_size(Name, Value),
    Ctx1 = evict_to_fit(EntrySize, Ctx),
    #hpack_context{
        dynamic_entries = Entries,
        dynamic_newest = Newest,
        dynamic_table_length = Len,
        table_size = TableSize,
        max_table_size = MaxSize
    } = Ctx1,
    if
        EntrySize > MaxSize ->
            %% Entry too large for the table: RFC 7541 §4.4 clears it entirely.
            Ctx1#hpack_context{dynamic_entries = #{}, dynamic_newest = 0,
                               dynamic_table_length = 0, table_size = 0};
        true ->
            NewSeq = Newest + 1,
            Ctx1#hpack_context{
                dynamic_entries = maps:put(NewSeq, {Name, Value}, Entries),
                dynamic_newest = NewSeq,
                dynamic_table_length = Len + 1,
                table_size = TableSize + EntrySize
            }
    end.

evict_to_fit(NewEntrySize, #hpack_context{
    table_size = TableSize,
    max_table_size = MaxSize
} = Ctx) ->
    TargetSize = MaxSize - NewEntrySize,
    if
        TableSize =< TargetSize ->
            Ctx;
        true ->
            evict_oldest(Ctx, TargetSize)
    end.

%% Drop oldest entries (lowest live sequence) until the table fits TargetSize.
evict_oldest(#hpack_context{table_size = Size} = Ctx, Target) when Size =< Target ->
    Ctx;
evict_oldest(#hpack_context{dynamic_table_length = 0} = Ctx, _Target) ->
    Ctx#hpack_context{dynamic_newest = 0, table_size = 0};
evict_oldest(#hpack_context{dynamic_entries = Entries, dynamic_newest = Newest,
                            dynamic_table_length = Len,
                            table_size = Size} = Ctx, Target) ->
    OldestSeq = Newest - Len + 1,
    {N, V} = maps:get(OldestSeq, Entries),
    evict_oldest(Ctx#hpack_context{
        dynamic_entries = maps:remove(OldestSeq, Entries),
        dynamic_table_length = Len - 1,
        table_size = Size - entry_size(N, V)
    }, Target).

entry_size(Name, Value) ->
    byte_size(Name) + byte_size(Value) + 32.

%% Integer encoding (RFC 7541 Section 5.1)

%% @doc Encode an integer with given prefix size.
-spec encode_integer(non_neg_integer(), 1..8) -> binary().
encode_integer(Value, Prefix) ->
    encode_integer(Value, Prefix, 0).

encode_integer(Value, Prefix, Mask) ->
    MaxPrefix = (1 bsl Prefix) - 1,
    if
        Value < MaxPrefix ->
            <<(Mask bsl Prefix bor Value)>>;
        true ->
            encode_integer_continue(Value - MaxPrefix, <<(Mask bsl Prefix bor MaxPrefix)>>)
    end.

encode_integer_continue(Value, Acc) when Value < 128 ->
    <<Acc/binary, Value>>;
encode_integer_continue(Value, Acc) ->
    encode_integer_continue(Value bsr 7, <<Acc/binary, (128 bor (Value band 127))>>).

%% @doc Decode an integer with given prefix size.
-spec decode_integer(binary(), 1..8) -> {ok, non_neg_integer(), binary()} | {error, term()}.
decode_integer(<<>>, _Prefix) ->
    {error, incomplete};
decode_integer(Bin, Prefix) ->
    MaxPrefix = (1 bsl Prefix) - 1,
    Skip = 8 - Prefix,
    <<_:Skip, Value:Prefix, Rest/binary>> = Bin,
    if
        Value < MaxPrefix ->
            {ok, Value, Rest};
        true ->
            decode_integer_continue(Rest, MaxPrefix, 0)
    end.

decode_integer_continue(<<>>, _Value, _Shift) ->
    {error, incomplete};
decode_integer_continue(<<0:1, B:7, Rest/binary>>, Value, Shift) ->
    {ok, Value + (B bsl Shift), Rest};
decode_integer_continue(<<1:1, B:7, Rest/binary>>, Value, Shift) when Shift < 56 ->
    decode_integer_continue(Rest, Value + (B bsl Shift), Shift + 7);
decode_integer_continue(_, _, _) ->
    {error, integer_overflow}.

%% Huffman coding (RFC 7541 Section 5.2)

%% @doc Huffman encode a binary string.
-spec huffman_encode(binary()) -> binary().
huffman_encode(Bin) ->
    Bits = huffman_encode_bits(Bin, <<>>),
    %% Pad with EOS prefix (all 1s)
    PadLen = (8 - (bit_size(Bits) rem 8)) rem 8,
    Padding = (1 bsl PadLen) - 1,
    <<Bits/bits, Padding:PadLen>>.

huffman_encode_bits(Bin, Acc) ->
    huffman_encode_bits(Bin, Acc, persistent_term:get(?PT_HUFFMAN_ENCODE)).

huffman_encode_bits(<<>>, Acc, _Tab) ->
    Acc;
huffman_encode_bits(<<C, Rest/binary>>, Acc, Tab) ->
    {_, Code, Len} = element(C + 1, Tab),
    huffman_encode_bits(Rest, <<Acc/bits, Code:Len>>, Tab).

%% @doc Huffman decode a binary string.
%%
%% Uses a table-driven 8-bit state machine (built once at load time by
%% build_huffman_fsm/0): one tuple lookup per input byte yields the next state
%% and any bytes completed within that byte, with no per-bit work in the hot
%% loop. State is the 1-based index of the current trie node (root = 1).
-spec huffman_decode(binary()) -> {ok, binary()} | {error, term()}.
huffman_decode(Bin) ->
    {States, Ends} = persistent_term:get(?PT_HUFFMAN_DECODE),
    huffman_decode(Bin, 1, [], States, Ends).

huffman_decode(<<>>, State, Acc, _States, Ends) ->
    %% End of input: the leftover bits since the last symbol (this state's path
    %% from the root) must be valid EOS padding. Ends/1 classifies the state.
    case element(State, Ends) of
        ok    -> {ok, iolist_to_binary(Acc)};
        Error -> Error
    end;
huffman_decode(<<B, Rest/binary>>, State, Acc, States, Ends) ->
    case element(B + 1, element(State, States)) of
        {Next, <<>>, ok}   -> huffman_decode(Rest, Next, Acc, States, Ends);
        {Next, Emit, ok}   -> huffman_decode(Rest, Next, [Acc, Emit], States, Ends);
        {_, _, eos}        -> {error, eos_in_string}
    end.

%% Build the 8-bit decode FSM from the Huffman code table. Returns
%% {StatesTuple, EndsTuple} (both 1-indexed by dense state id, root = 1):
%%   StatesTuple: element(State) -> 256-tuple; element(Byte+1) ->
%%                {NextState, EmittedBytes::binary(), ok | eos}
%%   EndsTuple:   element(State) -> ok | {error, invalid_padding}
%%                                     | {error, incomplete_code}
build_huffman_fsm() ->
    %% Trie as an edge map {NodeId, Bit} => ChildId, a leaf map ChildId => Sym,
    %% and per-node {Depth, AllOnesPath}. Root is node 0.
    {Edges, Leaves, Meta, _Cnt} =
        lists:foldl(fun({Sym, Code, Len}, Acc) -> trie_insert(Sym, Code, Len, Acc) end,
                    {#{}, #{}, #{0 => {0, true}}, 1},
                    ?HUFFMAN_ENCODE_TABLE),
    %% States = internal nodes (root + branches), densely numbered from 1 in id
    %% order so root (id 0) becomes state 1.
    InternalIds = lists:sort([Id || Id <- maps:keys(Meta),
                                    not maps:is_key(Id, Leaves)]),
    Dense = maps:from_list(lists:zip(InternalIds, lists:seq(1, length(InternalIds)))),
    States = list_to_tuple([build_state_row(Id, Edges, Leaves, Dense)
                            || Id <- InternalIds]),
    Ends = list_to_tuple([end_result(maps:get(Id, Meta)) || Id <- InternalIds]),
    {States, Ends}.

trie_insert(Sym, Code, Len, Acc) ->
    Bits = [(Code bsr (Len - 1 - I)) band 1 || I <- lists:seq(0, Len - 1)],
    insert_path(0, Bits, Sym, Acc).

insert_path(Node, [Bit], Sym, {Edges, Leaves, Meta, Cnt}) ->
    {PD, PAO} = maps:get(Node, Meta),
    LeafId = Cnt,
    {Edges#{{Node, Bit} => LeafId}, Leaves#{LeafId => Sym},
     Meta#{LeafId => {PD + 1, PAO andalso Bit =:= 1}}, Cnt + 1};
insert_path(Node, [Bit | Rest], Sym, {Edges, Leaves, Meta, Cnt} = Acc) ->
    case maps:get({Node, Bit}, Edges, undefined) of
        undefined ->
            {PD, PAO} = maps:get(Node, Meta),
            ChildId = Cnt,
            insert_path(ChildId, Rest, Sym,
                        {Edges#{{Node, Bit} => ChildId}, Leaves,
                         Meta#{ChildId => {PD + 1, PAO andalso Bit =:= 1}}, Cnt + 1});
        ChildId ->
            insert_path(ChildId, Rest, Sym, Acc)
    end.

build_state_row(Id, Edges, Leaves, Dense) ->
    list_to_tuple([walk_byte(Id, B, Edges, Leaves, Dense) || B <- lists:seq(0, 255)]).

walk_byte(StartNode, Byte, Edges, Leaves, Dense) ->
    Bits = [(Byte bsr (7 - I)) band 1 || I <- lists:seq(0, 7)],
    walk_bits(StartNode, Bits, [], Edges, Leaves, Dense).

walk_bits(Node, [], Emit, _Edges, _Leaves, Dense) ->
    {maps:get(Node, Dense), list_to_binary(lists:reverse(Emit)), ok};
walk_bits(Node, [Bit | Rest], Emit, Edges, Leaves, Dense) ->
    Child = maps:get({Node, Bit}, Edges),
    case maps:get(Child, Leaves, internal) of
        internal -> walk_bits(Child, Rest, Emit, Edges, Leaves, Dense);
        256      -> {1, <<>>, eos};            %% full EOS code in the stream
        Sym      -> walk_bits(0, Rest, [Sym | Emit], Edges, Leaves, Dense)
    end.

%% RFC 7541 §5.2: trailing bits must be the EOS code's all-ones prefix and fewer
%% than 8 bits; anything else is a decode error.
end_result({Depth, _AllOnes}) when Depth >= 8 -> {error, incomplete_code};
end_result({_Depth, true})  -> ok;
end_result({_Depth, false}) -> {error, invalid_padding}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

new_context_test() ->
    Ctx = new_context(),
    ?assertEqual(?DEFAULT_HEADER_TABLE_SIZE, get_max_table_size(Ctx)).

integer_encode_decode_test_() ->
    [
        %% Examples from RFC 7541 Section C.1
        ?_assertEqual({ok, 10, <<>>}, decode_integer(encode_integer(10, 5), 5)),
        ?_assertEqual({ok, 1337, <<>>}, decode_integer(encode_integer(1337, 5), 5)),
        ?_assertEqual({ok, 42, <<>>}, decode_integer(encode_integer(42, 8), 8))
    ].

integer_roundtrip_test_() ->
    Values = [0, 1, 30, 31, 32, 127, 128, 255, 256, 1337, 16383, 16384, 100000],
    Prefixes = [1, 4, 5, 6, 7, 8],
    [?_assertEqual({ok, V, <<>>}, decode_integer(encode_integer(V, P), P))
     || V <- Values, P <- Prefixes].

huffman_encode_test() ->
    %% Test encoding "www.example.com" from RFC 7541 C.4.1
    Input = <<"www.example.com">>,
    Encoded = huffman_encode(Input),
    ?assertEqual({ok, Input}, huffman_decode(Encoded)).

huffman_roundtrip_test_() ->
    Strings = [
        <<>>,
        <<"a">>,
        <<"test">>,
        <<"Hello, World!">>,
        <<"www.example.com">>,
        <<"no-cache">>,
        <<"custom-key">>,
        <<"custom-value">>
    ],
    [?_assertEqual({ok, S}, huffman_decode(huffman_encode(S))) || S <- Strings].

%% Round-trip every byte value through the FSM decoder (covers all symbols).
huffman_all_bytes_roundtrip_test() ->
    S = list_to_binary(lists:seq(0, 255)),
    ?assertEqual({ok, S}, huffman_decode(huffman_encode(S))).

%% RFC 7541 §5.2 error paths the decoder must reject (guards interop: these
%% surface as COMPRESSION_ERROR upstream).
huffman_decode_errors_test_() ->
    [
        %% '0' (00000) then three 0 padding bits: padding must be all ones.
        ?_assertEqual({error, invalid_padding}, huffman_decode(<<0>>)),
        %% Eight 1 bits: a partial code >= 8 bits, never completed.
        ?_assertEqual({error, incomplete_code}, huffman_decode(<<16#ff>>)),
        %% A full EOS code (30 ones) embedded in the stream is illegal.
        ?_assertEqual({error, eos_in_string},
                      huffman_decode(<<16#ff, 16#ff, 16#ff, 16#ff>>))
    ].

encode_decode_test() ->
    Ctx = new_context(),
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"www.example.com">>}
    ],
    {Encoded, Ctx1} = encode(Headers, Ctx),
    {ok, Decoded, _Ctx2} = decode(Encoded, Ctx1),
    ?assertEqual(Headers, Decoded).

static_table_indexed_test() ->
    %% :method GET is index 2
    Ctx = new_context(),
    Headers = [{<<":method">>, <<"GET">>}],
    {Encoded, _} = encode(Headers, Ctx),
    %% Should be a single byte: 0x82 (indexed, index 2)
    ?assertEqual(<<16#82>>, Encoded).

dynamic_table_test() ->
    Ctx = new_context(),
    Headers1 = [{<<"custom-key">>, <<"custom-value">>}],
    {Encoded1, Ctx1} = encode(Headers1, Ctx),
    %% Decode to update receiver's dynamic table
    {ok, _, Ctx2} = decode(Encoded1, Ctx1),
    %% Second time should use indexed
    {Encoded2, _} = encode(Headers1, Ctx2),
    %% Should be shorter (indexed reference)
    ?assert(byte_size(Encoded2) < byte_size(Encoded1)).

%% RFC 7541 §4.3: a size update larger than the peer-advertised maximum
%% MUST be a decoding error (compression error in HTTP/2 terms).
size_update_exceeds_peer_max_test() ->
    Ctx = set_peer_max_table_size(1024, new_context()),
    %% Size-update representation: 001 prefix + 5-bit integer.
    SizeUpdate = encode_integer(2048, 5, 2#001),
    ?assertEqual({error, size_update_exceeds_peer_max}, decode(SizeUpdate, Ctx)),
    ok.

%% Lower peer max should set pending_size_update; raising should not.
peer_max_lower_marks_pending_test() ->
    Ctx0 = new_context(),
    Ctx1 = set_peer_max_table_size(1024, Ctx0),
    ?assertEqual(true, Ctx1#hpack_context.pending_size_update),
    Ctx2 = set_peer_max_table_size(8192, Ctx1#hpack_context{pending_size_update = false}),
    ?assertEqual(false, Ctx2#hpack_context.pending_size_update),
    ok.

-endif.
