%%% -*- erlang -*-
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QPACK header compression for HTTP/3 (RFC 9204).
%%%
%%% This module provides QPACK encoding and decoding for HTTP/3 header
%%% compression. It supports both stateless (static table only) and stateful
%%% (with dynamic table) operation.
%%%
%%% == Quick Start ==
%%%
%%% Stateless encoding/decoding (static table only):
%%% ```
%%% Headers = [{<<":method">>, <<"GET">>}, {<<":path">>, <<"/">>}],
%%% Encoded = quic_qpack:encode(Headers),
%%% {ok, Headers} = quic_qpack:decode(Encoded).
%%% '''
%%%
%%% Stateful encoding with dynamic table:
%%% ```
%%% State0 = quic_qpack:new(#{max_dynamic_size => 4096}),
%%% {Encoded, State1} = quic_qpack:encode(Headers, State0),
%%% {{ok, Headers}, State2} = quic_qpack:decode(Encoded, State1).
%%% '''
%%%
%%% @end
-module(quic_qpack).

%% Stateless API
-export([
    encode/1,
    decode/1
]).

%% Stateful API
-export([
    new/0,
    new/1,
    encode/2,
    encode/3,
    decode/2
]).

%% Dynamic table management
-export([
    set_dynamic_capacity/2,
    get_dynamic_capacity/1,
    get_insert_count/1,
    get_last_ric/1,
    get_known_received_count/1
]).

%% Encoder stream processing (instructions FROM encoder)
-export([
    process_encoder_instructions/2
]).

%% Decoder stream processing (instructions FROM decoder)
-export([
    process_decoder_instructions/2
]).

%% Generate instructions for encoder/decoder streams
-export([
    get_encoder_instructions/1,
    clear_encoder_instructions/1,
    encode_section_ack/1,
    encode_insert_count_increment/1,
    encode_stream_cancel/1
]).

%%====================================================================
%% Types
%%====================================================================

-type header() :: {Name :: binary(), Value :: binary()}.
-type headers() :: [header()].

-export_type([state/0, header/0, headers/0]).

-include("quic_qpack_static_table.hrl").

%% State record for stateful encoding/decoding
-record(qpack, {
    %% Dynamic table configuration
    use_dynamic = false :: boolean(),
    %% Dynamic table - maps for O(1) lookup
    dyn_field_index = #{} :: #{header() => pos_integer()},
    dyn_name_index = #{} :: #{binary() => pos_integer()},
    %% Dynamic table entries: [{AbsoluteIndex, {Name, Value}, Size}]
    dyn_entries = [] :: [{pos_integer(), header(), non_neg_integer()}],
    dyn_size = 0 :: non_neg_integer(),
    dyn_max_size = 0 :: non_neg_integer(),
    %% RFC 9204 §3.2.1: the encoder MUST NOT set the dynamic table capacity
    %% higher than the decoder's advertised SETTINGS_QPACK_MAX_TABLE_CAPACITY.
    %% For a decoder state, this is our advertised ceiling.
    max_allowed_capacity = 0 :: non_neg_integer(),
    %% Insert count (absolute index for next entry)
    insert_count = 0 :: non_neg_integer(),
    %% Known received count - decoder has acked up to this
    known_received_count = 0 :: non_neg_integer(),
    %% Pending encoder instructions to send
    encoder_instructions = [] :: [binary()],
    %% Required insert count for last encoded block
    last_ric = 0 :: non_neg_integer(),
    %% Map of StreamId -> queue of outstanding RIC values (oldest first)
    pending_sections = #{} :: #{non_neg_integer() => queue:queue(non_neg_integer())}
}).

-opaque state() :: #qpack{}.

%%====================================================================
%% Stateless API
%%====================================================================

%% @doc Encode headers using QPACK (stateless, static table only).
-spec encode(headers()) -> binary().
encode(Headers) ->
    {Encoded, _} = encode(Headers, #qpack{}),
    Encoded.

%% @doc Decode QPACK-encoded headers (stateless).
-spec decode(binary()) -> {ok, headers()} | {error, term()}.
decode(Data) ->
    {Result, _} = decode(Data, #qpack{}),
    Result.

%%====================================================================
%% Stateful API
%%====================================================================

%% @doc Initialize QPACK state (static-only mode).
-spec new() -> state().
new() ->
    #qpack{}.

%% @doc Initialize QPACK state with options.
%% Options:
%%   max_dynamic_size - Enable dynamic table with given max size (default: 0 = disabled)
%%   max_allowed_capacity - Negotiation ceiling (SETTINGS_QPACK_MAX_TABLE_CAPACITY)
%%       without enabling the table (default: max_dynamic_size). Used by an
%%       encoder to seed the ceiling while staying static until a capacity is
%%       negotiated via set_dynamic_capacity/2, so 0-RTT early-data requests
%%       remain static-only until the peer's real SETTINGS arrive
%%       (RFC 9114 §7.2.4.2).
-spec new(#{atom() => term()}) -> state().
new(Opts) ->
    MaxDynSize = maps:get(max_dynamic_size, Opts, 0),
    MaxAllowed = maps:get(max_allowed_capacity, Opts, MaxDynSize),
    #qpack{
        use_dynamic = MaxDynSize > 0,
        dyn_max_size = MaxDynSize,
        max_allowed_capacity = MaxAllowed
    }.

%% @doc Encode headers using QPACK with state.
-spec encode(headers(), state()) -> {binary(), state()}.
encode(Headers, State) ->
    %% Base is the reference frame for the dynamic relative indices in this
    %% field section (RFC 9204 Section 3.2.6). The field lines below encode
    %% each RelIndex relative to the insert count at section start, so snapshot
    %% it and signal it as the Base. Entries referenced here were inserted (and
    %% acknowledged) before this section, so their absolute index < BaseIC; the
    %% running insert count must not be used, as inserts during this section
    %% would shift the frame between field lines.
    BaseIC = State#qpack.insert_count,
    {EncodedHeaders, NewState, MaxRefIndex} = encode_headers_tracking(
        Headers, BaseIC, State, <<>>, -1
    ),

    %% Required Insert Count: 1 + the largest absolute index referenced, or 0
    %% when no dynamic entry was referenced (RFC 9204 Section 4.5.1.1).
    RIC =
        case MaxRefIndex >= 0 of
            true -> MaxRefIndex + 1;
            false -> 0
        end,

    %% Encoded Field Section Prefix (RFC 9204 Section 4.5.1): the Required
    %% Insert Count, then the Base as a Sign bit and Delta Base. Base = BaseIC
    %% >= RIC, so per Section 4.5.1.2 the Sign bit is 0 and DeltaBase =
    %% BaseIC - RIC. A static-only section has BaseIC = RIC = 0, giving the
    %% two prefix bytes 00 00.
    %% Both fields are prefix integers (Section 4.5.1.1: 8-bit prefix for the
    %% Required Insert Count, 7-bit for Delta Base). Encoding them as raw bytes
    %% silently corrupts the section once a value reaches the prefix maximum
    %% (e.g. an encoded insert count of 255 on a long-lived dynamic table),
    %% because the decoder then reads a continuation byte that was never sent.
    RICEncoded = encode_prefixed_int(encode_ric(RIC, State#qpack.max_allowed_capacity), 8, 0),
    BaseEncoded = encode_prefixed_int(BaseIC - RIC, 7, 0),
    Prefix = <<RICEncoded/binary, BaseEncoded/binary>>,

    {<<Prefix/binary, EncodedHeaders/binary>>, NewState#qpack{last_ric = RIC}}.

%% @doc Encode headers with stream tracking for section acknowledgment.
%% This variant tracks the RIC per stream for proper section_ack handling.
-spec encode(headers(), non_neg_integer(), state()) -> {binary(), state()}.
encode(Headers, StreamId, State) ->
    {Encoded, State1} = encode(Headers, State),
    RIC = State1#qpack.last_ric,
    %% Append RIC to queue for this stream (FIFO: ack removes from front)
    OldQueue = maps:get(StreamId, State1#qpack.pending_sections, queue:new()),
    NewQueue = queue:in(RIC, OldQueue),
    NewPending = maps:put(StreamId, NewQueue, State1#qpack.pending_sections),
    {Encoded, State1#qpack{pending_sections = NewPending}}.

%% @doc Decode QPACK-encoded headers with state.
-spec decode(binary(), state()) ->
    {{ok, headers()} | {blocked, non_neg_integer()} | {error, term()}, state()}.
decode(Data, State) ->
    try
        {{RIC, Base}, Rest} = decode_prefix(Data, State),
        %% Check if we have all required dynamic table entries
        case RIC > State#qpack.insert_count of
            true ->
                %% Blocked: need more encoder stream instructions
                {{blocked, RIC}, State};
            false ->
                {Headers, NewState} = decode_headers(Rest, RIC, Base, State, []),
                {{ok, Headers}, NewState}
        end
    catch
        throw:incomplete ->
            {{error, incomplete}, State};
        _:Reason ->
            {{error, Reason}, State}
    end.

%%====================================================================
%% Dynamic Table Management API
%%====================================================================

%% @doc Set dynamic table capacity.
%% This generates a Set Dynamic Table Capacity instruction for the encoder
%% stream. RFC 9204 §4.3: the capacity MUST NOT exceed the peer-advertised
%% maximum (`max_allowed_capacity'). Values above the max are clamped to
%% the max so callers cannot produce a non-conformant instruction.
-spec set_dynamic_capacity(non_neg_integer(), state()) -> state().
set_dynamic_capacity(Capacity, #qpack{max_allowed_capacity = Max} = State) ->
    Effective = min(Capacity, Max),
    Instruction = encode_prefixed_int(Effective, 5, 2#001),
    State1 = State#qpack{
        dyn_max_size = Effective,
        use_dynamic = Effective > 0,
        encoder_instructions = [Instruction | State#qpack.encoder_instructions]
    },
    evict_to_fit(0, State1).

%% @doc Get dynamic table capacity.
-spec get_dynamic_capacity(state()) -> non_neg_integer().
get_dynamic_capacity(#qpack{dyn_max_size = MaxSize}) ->
    MaxSize.

%% @doc Get current insert count.
-spec get_insert_count(state()) -> non_neg_integer().
get_insert_count(#qpack{insert_count = IC}) ->
    IC.

%% @doc Get last Required Insert Count from encoding.
-spec get_last_ric(state()) -> non_neg_integer().
get_last_ric(#qpack{last_ric = RIC}) ->
    RIC.

%% @doc Get known received count (acknowledged by decoder).
-spec get_known_received_count(state()) -> non_neg_integer().
get_known_received_count(#qpack{known_received_count = KRC}) ->
    KRC.

%% @doc Get pending encoder instructions.
%% These should be sent on the encoder stream.
-spec get_encoder_instructions(state()) -> binary().
get_encoder_instructions(#qpack{encoder_instructions = Instructions}) ->
    iolist_to_binary(lists:reverse(Instructions)).

%% @doc Clear pending encoder instructions after sending.
-spec clear_encoder_instructions(state()) -> state().
clear_encoder_instructions(State) ->
    State#qpack{encoder_instructions = []}.

%% @doc Encode a Section Acknowledgment for the decoder stream.
%% StreamId should be the stream where headers were decoded.
-spec encode_section_ack(non_neg_integer()) -> binary().
encode_section_ack(StreamId) ->
    %% Section Acknowledgment: 1xxxxxxx
    encode_prefixed_int(StreamId, 7, 2#1).

%% @doc Encode an Insert Count Increment for the decoder stream.
-spec encode_insert_count_increment(non_neg_integer()) -> binary().
encode_insert_count_increment(Increment) ->
    %% Insert Count Increment: 00xxxxxx
    encode_prefixed_int(Increment, 6, 2#00).

%% @doc Encode a Stream Cancellation for the decoder stream.
%% Used when a stream is cancelled before headers are fully decoded.
-spec encode_stream_cancel(non_neg_integer()) -> binary().
encode_stream_cancel(StreamId) ->
    %% Stream Cancellation: 01xxxxxx
    encode_prefixed_int(StreamId, 6, 2#01).

%%====================================================================
%% Encoder Stream Processing
%%====================================================================

%% @doc Process encoder instructions from the peer's encoder stream.
%% Updates the dynamic table based on received instructions.
%% Returns {ok, State} when all data is processed,
%% {incomplete, RemainingData, State} when more data is needed,
%% or {error, Reason} on error.
-spec process_encoder_instructions(binary(), state()) ->
    {ok, state()} | {incomplete, binary(), state()} | {error, term()}.
process_encoder_instructions(<<>>, State) ->
    {ok, State};
process_encoder_instructions(Data, State) ->
    try decode_encoder_instruction(Data, State#qpack.dyn_max_size) of
        {ok, Instruction, Rest} ->
            case apply_encoder_instruction(Instruction, State) of
                {ok, State1} ->
                    process_encoder_instructions(Rest, State1);
                {error, _} = Error ->
                    Error
            end;
        incomplete ->
            {incomplete, Data, State};
        {error, _} = Error ->
            Error
    catch
        throw:incomplete ->
            %% Return remaining data AND current state (progress preserved)
            {incomplete, Data, State};
        throw:{qpack_encoder_stream_error, Reason} ->
            %% An announced length no insertable entry could need. Refusing
            %% before the bytes arrive is the point: buffering them is what
            %% a peer would otherwise get for free.
            {error, Reason};
        throw:{qpack_decompression_failed, Reason} ->
            %% Thrown from the shared string and integer decoders. Without
            %% this clause it escapes and takes the caller down with it.
            {error, {qpack_decompression_failed, Reason}}
    end.

-spec decode_encoder_instruction(binary(), non_neg_integer()) ->
    {ok, term(), binary()} | incomplete | {error, term()}.
decode_encoder_instruction(<<2#1:1, S:1, _:6, _/binary>> = Data, Capacity) ->
    %% Insert With Name Reference: 1Sxxxxxx
    decode_insert_with_name_ref(Data, S, Capacity);
decode_encoder_instruction(<<2#01:2, H:1, _:5, _/binary>> = Data, Capacity) ->
    %% Insert With Literal Name: 01Hxxxxx
    decode_insert_literal_name(Data, H, Capacity);
decode_encoder_instruction(<<2#000:3, _:5, _/binary>> = Data, _Capacity) ->
    %% Duplicate: 000xxxxx
    decode_duplicate(Data);
decode_encoder_instruction(<<2#001:3, _:5, _/binary>> = Data, _Capacity) ->
    %% Set Dynamic Table Capacity: 001xxxxx
    decode_set_capacity(Data);
decode_encoder_instruction(<<>>, _Capacity) ->
    incomplete;
decode_encoder_instruction(_, _Capacity) ->
    {error, invalid_encoder_instruction}.

-spec decode_insert_with_name_ref(binary(), 0 | 1, non_neg_integer()) ->
    {ok, term(), binary()} | incomplete.
decode_insert_with_name_ref(Data, Static, Capacity) ->
    <<FirstByte, Rest0/binary>> = Data,
    IndexBits = FirstByte band 16#3F,
    {Index, Rest1} =
        case IndexBits < 63 of
            true -> {IndexBits, Rest0};
            false -> decode_multi_byte_int(Rest0, IndexBits, 0)
        end,
    {Value, Rest2} = decode_insert_string(Rest1, Capacity),
    {ok, {insert_name_ref, Static, Index, Value}, Rest2}.

-spec decode_insert_literal_name(binary(), 0 | 1, non_neg_integer()) ->
    {ok, term(), binary()} | incomplete.
decode_insert_literal_name(Data, H, Capacity) ->
    <<_:3, NameLenBits:5, Rest0/binary>> = Data,
    {NameLen, Rest1} =
        case NameLenBits < 31 of
            true -> {NameLenBits, Rest0};
            false -> decode_multi_byte_int(Rest0, NameLenBits, 0)
        end,
    ok = check_insert_length(H, NameLen, Capacity),
    case byte_size(Rest1) >= NameLen of
        true ->
            {Name, Rest2} = decode_string_with_huffman(H, NameLen, Rest1),
            {Value, Rest3} = decode_insert_string(Rest2, Capacity),
            {ok, {insert_literal, Name, Value}, Rest3};
        false ->
            incomplete
    end.

%% A string on the encoder stream belongs to an entry the peer wants in
%% the table, so its length is bounded by the capacity in force. The same
%% decoder serves field sections, whose bound is the field section size,
%% so only the insert path comes through here.
decode_insert_string(<<H:1, 127:7, _/binary>> = Data, Capacity) ->
    {Len, _} = decode_multi_byte_int(binary:part(Data, 1, byte_size(Data) - 1), 127, 0),
    ok = check_insert_length(H, Len, Capacity),
    decode_string(Data);
decode_insert_string(<<H:1, Len:7, _/binary>> = Data, Capacity) ->
    ok = check_insert_length(H, Len, Capacity),
    decode_string(Data);
decode_insert_string(Data, _Capacity) ->
    decode_string(Data).

%% What no insertable entry could need. An entry has to fit the capacity
%% (RFC 9204 §3.2.2), so with no capacity negotiated nothing can be
%% inserted at all. A literal string is its own decoded length. Huffman
%% can expand as well as shrink, up to 30 bits for a byte against the
%% 8-bit minimum, so it is allowed four times the capacity before the
%% decoded entry could not possibly fit.
check_insert_length(_H, _Len, 0) ->
    throw({qpack_encoder_stream_error, insert_without_capacity});
check_insert_length(0, Len, Capacity) when Len > Capacity ->
    throw({qpack_encoder_stream_error, {literal_beyond_capacity, Len, Capacity}});
check_insert_length(1, Len, Capacity) when Len > 4 * Capacity ->
    throw({qpack_encoder_stream_error, {huffman_beyond_capacity, Len, Capacity}});
check_insert_length(_H, _Len, _Capacity) ->
    ok.

-spec decode_duplicate(binary()) -> {ok, term(), binary()}.
decode_duplicate(Data) ->
    <<_:3, IndexBits:5, Rest0/binary>> = Data,
    {Index, Rest1} =
        case IndexBits < 31 of
            true -> {IndexBits, Rest0};
            false -> decode_multi_byte_int(Rest0, IndexBits, 0)
        end,
    {ok, {duplicate, Index}, Rest1}.

-spec decode_set_capacity(binary()) -> {ok, term(), binary()}.
decode_set_capacity(Data) ->
    <<_:3, CapBits:5, Rest0/binary>> = Data,
    {Capacity, Rest1} =
        case CapBits < 31 of
            true -> {CapBits, Rest0};
            false -> decode_multi_byte_int(Rest0, CapBits, 0)
        end,
    {ok, {set_capacity, Capacity}, Rest1}.

-spec apply_encoder_instruction(term(), state()) -> {ok, state()} | {error, term()}.
apply_encoder_instruction({insert_name_ref, 1, Index, Value}, State) ->
    %% Static table reference (get_static_entry throws on invalid index)
    {Name, _} = get_static_entry(Index),
    insert_entry(Name, Value, State);
apply_encoder_instruction({insert_name_ref, 0, Index, Value}, State) ->
    %% Dynamic table reference
    case get_dynamic_entry_by_relative(Index, State) of
        {Name, _} ->
            insert_entry(Name, Value, State);
        undefined ->
            {error, invalid_dynamic_index}
    end;
apply_encoder_instruction({insert_literal, Name, Value}, State) ->
    insert_entry(Name, Value, State);
apply_encoder_instruction({duplicate, Index}, State) ->
    case get_dynamic_entry_by_relative(Index, State) of
        {Name, Value} ->
            insert_entry(Name, Value, State);
        undefined ->
            {error, invalid_dynamic_index}
    end;
apply_encoder_instruction(
    {set_capacity, Capacity}, #qpack{max_allowed_capacity = Max} = _State
) when Capacity > Max ->
    {error, {set_capacity_exceeds_max, Capacity, Max}};
apply_encoder_instruction({set_capacity, Capacity}, State) ->
    {ok, evict_to_fit(0, State#qpack{dyn_max_size = Capacity, use_dynamic = Capacity > 0})}.

%%====================================================================
%% Decoder Stream Processing
%%====================================================================

%% @doc Process decoder instructions from the peer's decoder stream.
%% Updates known_received_count based on acknowledgments.
%% Returns {ok, State} when all data is processed,
%% {incomplete, RemainingData, State} when more data is needed,
%% or {error, Reason} on error.
-spec process_decoder_instructions(binary(), state()) ->
    {ok, state()} | {incomplete, binary(), state()} | {error, term()}.
process_decoder_instructions(<<>>, State) ->
    {ok, State};
process_decoder_instructions(Data, State) ->
    try decode_decoder_instruction(Data) of
        {ok, Instruction, Rest} ->
            case apply_decoder_instruction(Instruction, State) of
                {error, _} = Error ->
                    Error;
                State1 ->
                    process_decoder_instructions(Rest, State1)
            end;
        incomplete ->
            {incomplete, Data, State};
        {error, _} = Error ->
            Error
    catch
        throw:incomplete ->
            {incomplete, Data, State}
    end.

-spec decode_decoder_instruction(binary()) ->
    {ok, term(), binary()} | incomplete | {error, term()}.
decode_decoder_instruction(<<2#1:1, _:7, _/binary>> = Data) ->
    %% Section Acknowledgment: 1xxxxxxx
    {StreamId, Rest} = decode_prefixed_int(Data, 7),
    {ok, {section_ack, StreamId}, Rest};
decode_decoder_instruction(<<2#01:2, _:6, _/binary>> = Data) ->
    %% Stream Cancellation: 01xxxxxx
    {StreamId, Rest} = decode_prefixed_int(Data, 6),
    {ok, {stream_cancel, StreamId}, Rest};
decode_decoder_instruction(<<2#00:2, _:6, _/binary>> = Data) ->
    %% Insert Count Increment: 00xxxxxx
    {Increment, Rest} = decode_prefixed_int(Data, 6),
    {ok, {insert_count_increment, Increment}, Rest};
decode_decoder_instruction(<<>>) ->
    incomplete;
decode_decoder_instruction(_) ->
    {error, invalid_decoder_instruction}.

-spec apply_decoder_instruction(term(), state()) -> state() | {error, term()}.
apply_decoder_instruction({section_ack, StreamId}, State) ->
    %% Section Acknowledgment: removes oldest outstanding section for stream
    case maps:get(StreamId, State#qpack.pending_sections, undefined) of
        undefined ->
            %% No pending sections for this stream, ignore
            State;
        Queue ->
            case queue:out(Queue) of
                {{value, AckedRIC}, NewQueue} ->
                    NewKRC = max(State#qpack.known_received_count, AckedRIC),
                    NewPending =
                        case queue:is_empty(NewQueue) of
                            true -> maps:remove(StreamId, State#qpack.pending_sections);
                            false -> maps:put(StreamId, NewQueue, State#qpack.pending_sections)
                        end,
                    State#qpack{
                        known_received_count = NewKRC,
                        pending_sections = NewPending
                    };
                {empty, _} ->
                    %% No pending sections, ignore ack
                    State
            end
    end;
apply_decoder_instruction({stream_cancel, StreamId}, State) ->
    %% Stream Cancellation: remove all pending sections for this stream
    NewPending = maps:remove(StreamId, State#qpack.pending_sections),
    State#qpack{pending_sections = NewPending};
apply_decoder_instruction({insert_count_increment, Increment}, State) when
    is_integer(Increment), Increment > 0
->
    NewKRC = State#qpack.known_received_count + Increment,
    case NewKRC > State#qpack.insert_count of
        true ->
            {error, {invalid_increment, Increment, State#qpack.insert_count}};
        false ->
            State#qpack{known_received_count = NewKRC}
    end;
apply_decoder_instruction({insert_count_increment, Increment}, _State) ->
    {error, {invalid_increment, Increment}}.

%%====================================================================
%% Internal - Encoding
%%====================================================================

%% Encode Required Insert Count per Section 4.5.1.1
%% No entry fits in what we advertised, so a field section cannot be
%% referring to one.
decode_required_insert_count(0, _MaxEntries, _InsertCount) ->
    0;
decode_required_insert_count(_ERIC, 0, _InsertCount) ->
    throw({qpack_decompression_failed, required_insert_count_without_capacity});
decode_required_insert_count(ERIC, MaxEntries, InsertCount) ->
    quic_qpack_prefix:decode_ric(ERIC, MaxEntries, InsertCount).

%% ERIC = (RIC mod (2 * MaxEntries)) + 1
-spec encode_ric(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
encode_ric(0, _MaxSize) ->
    0;
encode_ric(RIC, MaxSize) ->
    case MaxSize div ?ENTRY_OVERHEAD of
        0 -> 0;
        MaxEntries -> (RIC rem (2 * MaxEntries)) + 1
    end.

%% Encode headers while tracking the maximum dynamic table index referenced.
%% `BaseIC` is the fixed Base (insert count at section start) that every
%% dynamic relative index is encoded against.
-spec encode_headers_tracking(headers(), non_neg_integer(), state(), binary(), integer()) ->
    {binary(), state(), integer()}.
encode_headers_tracking([], _BaseIC, State, Acc, MaxRef) ->
    {Acc, State, MaxRef};
encode_headers_tracking([Header | Rest], BaseIC, State, Acc, MaxRef) ->
    {Encoded, NewState, RefIndex} = encode_header_tracking(Header, BaseIC, State),
    NewMaxRef =
        case RefIndex of
            none -> MaxRef;
            Idx -> max(MaxRef, Idx)
        end,
    encode_headers_tracking(Rest, BaseIC, NewState, <<Acc/binary, Encoded/binary>>, NewMaxRef).

%% Encode header with tracking of referenced dynamic index
%% This function also inserts entries into the dynamic table when appropriate
-spec encode_header_tracking(header(), non_neg_integer(), state()) ->
    {binary(), state(), integer() | none}.
encode_header_tracking({Name, Value}, BaseIC, #qpack{use_dynamic = true} = State) ->
    case find_dynamic_match(Name, Value, State) of
        {exact, AbsIndex} ->
            %% Check if peer has received this entry (can reference)
            case can_reference(AbsIndex, State) of
                true ->
                    RelIndex = BaseIC - AbsIndex - 1,
                    {encode_indexed_dynamic(RelIndex), State, AbsIndex};
                false ->
                    %% Entry exists but peer hasn't acked, use literal
                    encode_with_insertion({Name, Value}, State)
            end;
        {name, AbsIndex} ->
            case can_reference(AbsIndex, State) of
                true ->
                    RelIndex = BaseIC - AbsIndex - 1,
                    {encode_literal_with_dynamic_name_ref(RelIndex, Value), State, AbsIndex};
                false ->
                    encode_with_insertion({Name, Value}, State)
            end;
        none ->
            %% No match in dynamic table, try to insert
            encode_with_insertion({Name, Value}, State)
    end;
encode_header_tracking({Name, Value}, _BaseIC, State) ->
    {Encoded, NewState} = encode_header_static({Name, Value}, State),
    {Encoded, NewState, none}.

%% Check if an entry can be referenced (peer has acknowledged it)
-spec can_reference(non_neg_integer(), state()) -> boolean().
can_reference(AbsIndex, #qpack{known_received_count = KRC}) ->
    %% AbsIndex is 0-based, KRC indicates entries 0..(KRC-1) are acknowledged
    AbsIndex < KRC.

%% Decide whether to insert and encode header
%% NOTE: Per RFC 9204, we MUST NOT reference dynamic table entries that the peer
%% hasn't received yet. When we insert a new entry, we encode as literal because
%% the encoder instruction hasn't been acknowledged. The entry is added to the
%% dynamic table for future requests where it will be acknowledged.
-spec encode_with_insertion(header(), state()) -> {binary(), state(), integer() | none}.
encode_with_insertion({Name, Value}, State) ->
    case should_insert(Name, Value, State) of
        true ->
            %% Insert into dynamic table and generate encoder instruction
            {State1, Instruction} = generate_insert_instruction(Name, Value, State),
            %% Insert the entry
            {ok, State2} = insert_entry(Name, Value, State1),
            %% Queue the encoder instruction
            State3 = State2#qpack{
                encoder_instructions = [Instruction | State2#qpack.encoder_instructions]
            },
            %% Encode as literal - we can't reference the entry yet because
            %% the peer hasn't received the encoder instruction. The entry will
            %% be available for future requests once acknowledged.
            {Encoded, _} = encode_header_static({Name, Value}, State3),
            {Encoded, State3, none};
        false ->
            %% Don't insert, encode as literal
            {Encoded, NewState} = encode_header_static({Name, Value}, State),
            {Encoded, NewState, none}
    end.

%% Decide whether to insert a header into the dynamic table
-spec should_insert(binary(), binary(), state()) -> boolean().
should_insert(Name, Value, #qpack{dyn_max_size = MaxSize}) ->
    %% Don't insert if:
    %% - Entry is too large for the table
    %% - Name starts with ":" (pseudo-headers are well-covered by static table)
    EntrySize = entry_size(Name, Value),
    case EntrySize > MaxSize of
        true ->
            false;
        false ->
            %% Don't insert pseudo-headers (already in static table)
            case Name of
                <<":", _/binary>> -> false;
                _ -> true
            end
    end.

%% Generate encoder stream instruction for inserting an entry
-spec generate_insert_instruction(binary(), binary(), state()) -> {state(), binary()}.
generate_insert_instruction(Name, Value, State) ->
    %% Try to use static table name reference first
    case maps:find(Name, ?STATIC_NAME_MAP) of
        {ok, StaticIndex} ->
            %% Insert With Name Reference (static): 11xxxxxx
            {State, encode_insert_with_static_name_ref(StaticIndex, Value)};
        error ->
            %% Check if name exists in dynamic table and is referenceable
            case maps:find(Name, State#qpack.dyn_name_index) of
                {ok, AbsIndex} when AbsIndex < State#qpack.known_received_count ->
                    %% Insert With Name Reference (dynamic): 10xxxxxx
                    RelIndex = State#qpack.insert_count - AbsIndex - 1,
                    {State, encode_insert_with_dynamic_name_ref(RelIndex, Value)};
                _ ->
                    %% Insert With Literal Name: 01Hxxxxx
                    {State, encode_insert_with_literal_name(Name, Value)}
            end
    end.

%% Encoder stream: Insert With Name Reference (static) - 11xxxxxx
-spec encode_insert_with_static_name_ref(non_neg_integer(), binary()) -> binary().
encode_insert_with_static_name_ref(Index, Value) ->
    IndexEnc = encode_prefixed_int(Index, 6, 2#11),
    ValueEnc = encode_string(Value),
    <<IndexEnc/binary, ValueEnc/binary>>.

%% Encoder stream: Insert With Name Reference (dynamic) - 10xxxxxx
-spec encode_insert_with_dynamic_name_ref(non_neg_integer(), binary()) -> binary().
encode_insert_with_dynamic_name_ref(RelIndex, Value) ->
    IndexEnc = encode_prefixed_int(RelIndex, 6, 2#10),
    ValueEnc = encode_string(Value),
    <<IndexEnc/binary, ValueEnc/binary>>.

%% Encoder stream: Insert With Literal Name - 01Hxxxxx (H=0 for no huffman)
-spec encode_insert_with_literal_name(binary(), binary()) -> binary().
encode_insert_with_literal_name(Name, Value) ->
    NameLen = byte_size(Name),
    %% Opcode bits 010 (01 = Insert With Literal Name, H=0): the 3-bit
    %% prefix pattern is 2#010, i.e. 2#10 left of the 5-bit name length.
    %% 2#01 here produced 001xxxxx, which the decoder reads as Set
    %% Dynamic Table Capacity (RFC 9204 Section 4.3.3 vs 4.3.1).
    NameLenEnc = encode_prefixed_int(NameLen, 5, 2#10),
    ValueEnc = encode_string(Value),
    <<NameLenEnc/binary, Name/binary, ValueEnc/binary>>.

%% Encode using static table or literal
-spec encode_header_static(header(), state()) -> {binary(), state()}.
encode_header_static({Name, Value}, State) ->
    case find_static_match(Name, Value) of
        {exact, Index} ->
            %% Indexed Field Line (static) - 11xxxxxx
            {encode_indexed_static(Index), State};
        {name, Index} ->
            %% Literal Field Line With Name Reference (static)
            {encode_literal_with_name_ref(Index, Value), State};
        none ->
            %% Literal Field Line With Literal Name
            {encode_literal(Name, Value), State}
    end.

%% Indexed Field Line - 11xxxxxx for static
-spec encode_indexed_static(non_neg_integer()) -> binary().
encode_indexed_static(Index) ->
    encode_prefixed_int(Index, 6, 2#11).

%% Indexed Field Line - 10xxxxxx for dynamic
-spec encode_indexed_dynamic(non_neg_integer()) -> binary().
encode_indexed_dynamic(RelIndex) ->
    encode_prefixed_int(RelIndex, 6, 2#10).

%% Literal with name reference - 0101xxxx (N=0, T=1 for static)
-spec encode_literal_with_name_ref(non_neg_integer(), binary()) -> binary().
encode_literal_with_name_ref(Index, Value) ->
    NameRef = encode_prefixed_int(Index, 4, 2#0101),
    ValueEnc = encode_string(Value),
    <<NameRef/binary, ValueEnc/binary>>.

%% Literal with dynamic name reference - 0100xxxx (N=0, T=0 for dynamic)
-spec encode_literal_with_dynamic_name_ref(non_neg_integer(), binary()) -> binary().
encode_literal_with_dynamic_name_ref(RelIndex, Value) ->
    NameRef = encode_prefixed_int(RelIndex, 4, 2#0100),
    ValueEnc = encode_string(Value),
    <<NameRef/binary, ValueEnc/binary>>.

%% Literal with literal name - 0010xxxx (N=0, H=0 for no huffman on name)
-spec encode_literal(binary(), binary()) -> binary().
encode_literal(Name, Value) ->
    NameLen = byte_size(Name),
    ValueEnc = encode_string(Value),
    case NameLen < 7 of
        true ->
            FirstByte = 2#00100000 bor NameLen,
            <<FirstByte, Name/binary, ValueEnc/binary>>;
        false ->
            FirstByte = 2#00100111,
            LenCont = encode_multi_byte_int(NameLen - 7),
            <<FirstByte, LenCont/binary, Name/binary, ValueEnc/binary>>
    end.

-spec encode_string(binary()) -> binary().
encode_string(Str) ->
    HuffSize = quic_qpack_huffman:encoded_size(Str),
    case HuffSize < byte_size(Str) of
        true ->
            Encoded = quic_qpack_huffman:encode(Str),
            LenEnc = encode_prefixed_int(HuffSize, 7, 1),
            <<LenEnc/binary, Encoded/binary>>;
        false ->
            LenEnc = encode_prefixed_int(byte_size(Str), 7, 0),
            <<LenEnc/binary, Str/binary>>
    end.

-spec encode_prefixed_int(non_neg_integer(), 1..8, non_neg_integer()) -> binary().
encode_prefixed_int(Value, PrefixBits, Prefix) when Value < (1 bsl PrefixBits) - 1 ->
    <<(Prefix bsl PrefixBits bor Value)>>;
encode_prefixed_int(Value, PrefixBits, Prefix) ->
    MaxPrefix = (1 bsl PrefixBits) - 1,
    FirstByte = Prefix bsl PrefixBits bor MaxPrefix,
    Remaining = Value - MaxPrefix,
    <<FirstByte, (encode_multi_byte_int(Remaining))/binary>>.

-spec encode_multi_byte_int(non_neg_integer()) -> binary().
encode_multi_byte_int(Value) when Value < 128 ->
    <<Value>>;
encode_multi_byte_int(Value) ->
    <<(128 bor (Value band 127)), (encode_multi_byte_int(Value bsr 7))/binary>>.

%%====================================================================
%% Internal - Decoding
%%====================================================================

-spec decode_prefix(binary(), state()) -> {{non_neg_integer(), non_neg_integer()}, binary()}.
decode_prefix(<<>>, _State) ->
    throw(incomplete);
decode_prefix(<<_>>, _State) ->
    throw(incomplete);
decode_prefix(Data, State) ->
    %% Decode ERIC with 8-bit prefix
    {ERIC, Rest0} = decode_prefixed_int(Data, 8),
    case Rest0 of
        <<>> ->
            throw(incomplete);
        <<SBit:1, DeltaBits:7, Rest1/binary>> ->
            %% Decode DeltaBase
            {DeltaBase, Rest2} =
                case DeltaBits < 127 of
                    true -> {DeltaBits, Rest1};
                    false -> decode_multi_byte_int(Rest1, DeltaBits, 0)
                end,
            %% Reconstruct RIC using modulo arithmetic
            %% RFC 9204 §4.5.1.1: the count is encoded against the
            %% capacity we advertised, not the one in force, so a field
            %% section that arrives before Set Capacity still decodes.
            MaxEntries = State#qpack.max_allowed_capacity div ?ENTRY_OVERHEAD,
            RIC = decode_required_insert_count(ERIC, MaxEntries, State#qpack.insert_count),
            %% Reconstruct Base per RFC 9204 Section 4.5.1.2.
            Base = quic_qpack_prefix:decode_base(SBit, RIC, DeltaBase),
            {{RIC, Base}, Rest2}
    end.

%% Decode headers with Required Insert Count (RIC) and Base from prefix
-spec decode_headers(binary(), non_neg_integer(), non_neg_integer(), state(), headers()) ->
    {headers(), state()}.
decode_headers(<<>>, _RIC, _Base, State, Acc) ->
    {lists:reverse(Acc), State};
decode_headers(<<2#11:2, _:6, _/binary>> = Data, RIC, Base, State, Acc) ->
    %% Indexed Field Line (static) - 11xxxxxx
    {Index, Rest} = decode_prefixed_int(Data, 6),
    Header = get_static_entry(Index),
    decode_headers(Rest, RIC, Base, State, [Header | Acc]);
decode_headers(<<2#10:2, _:6, _/binary>> = Data, RIC, Base, State, Acc) ->
    %% Indexed Field Line (dynamic, pre-base) - 10xxxxxx
    {RelIndex, Rest} = decode_prefixed_int(Data, 6),
    %% Convert relative index to absolute using Base
    AbsIndex = Base - RelIndex - 1,
    case get_dynamic_entry_by_absolute(AbsIndex, State) of
        {Name, Value} ->
            decode_headers(Rest, RIC, Base, State, [{Name, Value} | Acc]);
        undefined ->
            throw({invalid_dynamic_index, AbsIndex})
    end;
decode_headers(<<2#01:2, _N:1, T:1, _:4, _/binary>> = Data, RIC, Base, State, Acc) ->
    %% Literal Field Line with Name Reference - 01NTxxxx
    FirstByte = hd(binary_to_list(Data)),
    IndexBits = FirstByte band 16#0F,
    <<_, Rest0/binary>> = Data,
    {Index, Rest1} =
        case IndexBits < 15 of
            true -> {IndexBits, Rest0};
            false -> decode_multi_byte_int(Rest0, IndexBits, 0)
        end,
    {Value, Rest2} = decode_string(Rest1),
    case T of
        1 ->
            %% Static table reference
            {Name, _} = get_static_entry(Index),
            decode_headers(Rest2, RIC, Base, State, [{Name, Value} | Acc]);
        0 ->
            %% Dynamic table reference (pre-base)
            AbsIndex = Base - Index - 1,
            case get_dynamic_entry_by_absolute(AbsIndex, State) of
                {Name, _} ->
                    decode_headers(Rest2, RIC, Base, State, [{Name, Value} | Acc]);
                undefined ->
                    throw({invalid_dynamic_index, AbsIndex})
            end
    end;
decode_headers(<<2#0010:4, H:1, NameLenPrefix:3, Rest0/binary>>, RIC, Base, State, Acc) ->
    %% Literal with literal name - 0010Hxxx
    {NameLen, Rest1} =
        case NameLenPrefix < 7 of
            true -> {NameLenPrefix, Rest0};
            false -> decode_multi_byte_int(Rest0, NameLenPrefix, 0)
        end,
    {Name, Rest2} = decode_string_with_huffman(H, NameLen, Rest1),
    {Value, Rest3} = decode_string(Rest2),
    decode_headers(Rest3, RIC, Base, State, [{Name, Value} | Acc]);
decode_headers(<<2#0011:4, H:1, NameLenPrefix:3, Rest0/binary>>, RIC, Base, State, Acc) ->
    %% Literal with literal name, N=1 (never indexed) - 0011Hxxx.
    %% RFC 9204 §4.5.6: this representation MUST NOT be added to the
    %% dynamic table by any party. Our decoder never auto-inserts literals,
    %% so the bit is preserved by simply emitting the field as-is. A
    %% future proxy use-case will need to surface this bit to callers.
    {NameLen, Rest1} =
        case NameLenPrefix < 7 of
            true -> {NameLenPrefix, Rest0};
            false -> decode_multi_byte_int(Rest0, NameLenPrefix, 0)
        end,
    {Name, Rest2} = decode_string_with_huffman(H, NameLen, Rest1),
    {Value, Rest3} = decode_string(Rest2),
    decode_headers(Rest3, RIC, Base, State, [{Name, Value} | Acc]);
decode_headers(<<2#0001:4, _:4, _/binary>> = Data, RIC, Base, State, Acc) ->
    %% Indexed Header Field with Post-Base Index - 0001xxxx
    FirstByte = hd(binary_to_list(Data)),
    IndexBits = FirstByte band 16#0F,
    <<_, Rest0/binary>> = Data,
    {PostBaseIndex, Rest1} =
        case IndexBits < 15 of
            true -> {IndexBits, Rest0};
            false -> decode_multi_byte_int(Rest0, IndexBits, 0)
        end,
    %% Post-base index: AbsIndex = Base + PostBaseIndex
    AbsIndex = Base + PostBaseIndex,
    case get_dynamic_entry_by_absolute(AbsIndex, State) of
        {Name, Value} ->
            decode_headers(Rest1, RIC, Base, State, [{Name, Value} | Acc]);
        undefined ->
            throw({invalid_dynamic_index, AbsIndex})
    end;
decode_headers(<<2#0000:4, _N:1, _:3, _/binary>> = Data, RIC, Base, State, Acc) ->
    %% Literal with post-base name reference - 0000Nxxx
    FirstByte = hd(binary_to_list(Data)),
    IndexBits = FirstByte band 16#07,
    <<_, Rest0/binary>> = Data,
    {PostBaseIndex, Rest1} =
        case IndexBits < 7 of
            true -> {IndexBits, Rest0};
            false -> decode_multi_byte_int(Rest0, IndexBits, 0)
        end,
    {Value, Rest2} = decode_string(Rest1),
    %% Post-base index: AbsIndex = Base + PostBaseIndex
    AbsIndex = Base + PostBaseIndex,
    case get_dynamic_entry_by_absolute(AbsIndex, State) of
        {Name, _} ->
            decode_headers(Rest2, RIC, Base, State, [{Name, Value} | Acc]);
        undefined ->
            throw({invalid_dynamic_index, AbsIndex})
    end;
decode_headers(<<Byte, _/binary>>, _RIC, _Base, _State, _Acc) ->
    throw({unknown_instruction, Byte}).

-spec decode_prefixed_int(binary(), 1..8) -> {non_neg_integer(), binary()}.
decode_prefixed_int(<<>>, _PrefixBits) ->
    throw(incomplete);
decode_prefixed_int(Data, PrefixBits) ->
    MaxPrefix = (1 bsl PrefixBits) - 1,
    <<First, Rest/binary>> = Data,
    Value = First band MaxPrefix,
    case Value < MaxPrefix of
        true ->
            {Value, Rest};
        false ->
            decode_multi_byte_int(Rest, Value, 0)
    end.

-spec decode_multi_byte_int(binary(), non_neg_integer(), non_neg_integer()) ->
    {non_neg_integer(), binary()}.
decode_multi_byte_int(<<>>, _Acc, _Shift) ->
    throw(incomplete);
decode_multi_byte_int(_Data, _Acc, Shift) when Shift > 56 ->
    %% RFC 9204 / RFC 7541 §5.1 prefixed integers are unbounded in spec but
    %% bounded in practice; cap at 8 continuation bytes (>= 2^63) to prevent
    %% resource exhaustion via crafted continuation chains.
    throw({qpack_decompression_failed, prefixed_int_too_long});
decode_multi_byte_int(<<Byte, Rest/binary>>, Acc, Shift) ->
    NewAcc = Acc + ((Byte band 127) bsl Shift),
    case Byte band 128 of
        0 -> {NewAcc, Rest};
        _ -> decode_multi_byte_int(Rest, NewAcc, Shift + 7)
    end.

-spec decode_string(binary()) -> {binary(), binary()}.
decode_string(<<>>) ->
    throw(incomplete);
decode_string(<<0:1, 127:7, Rest/binary>>) ->
    {ActualLen, Rest2} = decode_multi_byte_int(Rest, 127, 0),
    case byte_size(Rest2) >= ActualLen of
        true ->
            <<Str:ActualLen/binary, Rest3/binary>> = Rest2,
            {Str, Rest3};
        false ->
            throw(incomplete)
    end;
decode_string(<<1:1, 127:7, Rest/binary>>) ->
    {ActualLen, Rest2} = decode_multi_byte_int(Rest, 127, 0),
    case byte_size(Rest2) >= ActualLen of
        true ->
            <<Encoded:ActualLen/binary, Rest3/binary>> = Rest2,
            Decoded = huffman_decode_validated(Encoded),
            {Decoded, Rest3};
        false ->
            throw(incomplete)
    end;
decode_string(<<0:1, Len:7, Rest/binary>>) when byte_size(Rest) >= Len ->
    <<Str:Len/binary, Rest2/binary>> = Rest,
    {Str, Rest2};
decode_string(<<1:1, Len:7, Rest/binary>>) when byte_size(Rest) >= Len ->
    <<Encoded:Len/binary, Rest2/binary>> = Rest,
    %% Validate EOS/padding like the long-length path (RFC 7541 §5.2).
    Decoded = huffman_decode_validated(Encoded),
    {Decoded, Rest2};
decode_string(<<_:1, _Len:7, _Rest/binary>>) ->
    %% String length byte present but insufficient data
    throw(incomplete).

-spec decode_string_with_huffman(0 | 1, non_neg_integer(), binary()) ->
    {binary(), binary()}.
decode_string_with_huffman(HuffFlag, Len, Data) when byte_size(Data) >= Len ->
    <<Encoded:Len/binary, Rest/binary>> = Data,
    case HuffFlag of
        1 ->
            Decoded = huffman_decode_validated(Encoded),
            {Decoded, Rest};
        0 ->
            {Encoded, Rest}
    end;
decode_string_with_huffman(_HuffFlag, _Len, _Data) ->
    throw(incomplete).

%% RFC 7541 §5.2: reject EOS symbol and padding violations. Raise a thrown
%% {qpack_decompression_failed, Reason} so the parent try/catch (in
%% decode/encode instruction handlers) maps it to QPACK_DECOMPRESSION_FAILED.
huffman_decode_validated(Encoded) ->
    case quic_qpack_huffman:decode_safe(Encoded) of
        {ok, Decoded} -> Decoded;
        {error, Reason} -> throw({qpack_decompression_failed, Reason})
    end.

%%====================================================================
%% Internal - Static Table Lookup (O(1))
%%====================================================================

%% Find match in static table using maps - O(1)
-spec find_static_match(binary(), binary()) ->
    {exact, non_neg_integer()} | {name, non_neg_integer()} | none.
find_static_match(Name, Value) ->
    Header = {Name, Value},
    case maps:find(Header, ?STATIC_FIELD_MAP) of
        {ok, Index} ->
            {exact, Index};
        error ->
            case maps:find(Name, ?STATIC_NAME_MAP) of
                {ok, Index} ->
                    {name, Index};
                error ->
                    none
            end
    end.

%% Get static table entry by index - O(1)
-spec get_static_entry(non_neg_integer()) -> header().
get_static_entry(Index) when Index >= 0, Index =< 98 ->
    element(Index + 1, ?STATIC_TABLE);
get_static_entry(Index) ->
    throw({invalid_static_index, Index}).

%%====================================================================
%% Internal - Dynamic Table Management
%%====================================================================

%% @doc Insert an entry into the dynamic table.
%% Evicts old entries if necessary to make room.
-spec insert_entry(binary(), binary(), state()) -> {ok, state()} | {error, term()}.
insert_entry(Name, Value, State) ->
    EntrySize = entry_size(Name, Value),
    case EntrySize > State#qpack.dyn_max_size of
        true ->
            %% RFC 9204 §3.2.2: an entry larger than the capacity is an
            %% encoder stream error. Dropping it silently also skipped the
            %% insert count, so our view of the table drifted from the
            %% peer's and every later reference was off by one.
            {error, {entry_larger_than_capacity, EntrySize, State#qpack.dyn_max_size}};
        false ->
            %% Evict entries to make room
            State1 = evict_to_fit(EntrySize, State),
            %% Insert new entry
            AbsIndex = State1#qpack.insert_count,
            Header = {Name, Value},
            NewEntries = [{AbsIndex, Header, EntrySize} | State1#qpack.dyn_entries],
            NewFieldIndex = maps:put(Header, AbsIndex, State1#qpack.dyn_field_index),
            NewNameIndex = maps:put(Name, AbsIndex, State1#qpack.dyn_name_index),
            {ok, State1#qpack{
                dyn_entries = NewEntries,
                dyn_field_index = NewFieldIndex,
                dyn_name_index = NewNameIndex,
                dyn_size = State1#qpack.dyn_size + EntrySize,
                insert_count = AbsIndex + 1
            }}
    end.

%% @doc Calculate size of a dynamic table entry.
%% Per RFC 9204 Section 3.2.1: size = name_length + value_length + 32
-spec entry_size(binary(), binary()) -> non_neg_integer().
entry_size(Name, Value) ->
    byte_size(Name) + byte_size(Value) + ?ENTRY_OVERHEAD.

%% @doc Evict entries until there's room for an entry of the given size.
%% RFC 9204 §3.2.1: an entry MUST NOT be evicted while still referenced by
%% an unacknowledged section. We approximate this on the encoder by refusing
%% to evict any entry whose absolute index is >= the smallest RIC across all
%% pending sections. If no eviction is possible, leave the table as-is so
%% the new insert is silently dropped.
-spec evict_to_fit(non_neg_integer(), state()) -> state().
evict_to_fit(RequiredSize, #qpack{dyn_size = Size, dyn_max_size = MaxSize} = State) when
    Size + RequiredSize =< MaxSize
->
    State;
evict_to_fit(_RequiredSize, #qpack{dyn_entries = []} = State) ->
    %% No entries to evict
    State;
evict_to_fit(RequiredSize, #qpack{dyn_entries = Entries} = State) ->
    [{AbsIndex, _Header, _Sz} | _] = lists:reverse(Entries),
    case is_entry_pinned(AbsIndex, State) of
        true ->
            %% Oldest entry is still referenced by an unacknowledged section;
            %% bail out without evicting (§3.2.1).
            State;
        false ->
            evict_oldest(RequiredSize, Entries, State)
    end.

evict_oldest(RequiredSize, Entries, State) ->
    {Oldest, RestEntries} = lists:split(length(Entries) - 1, Entries),
    [{AbsIndex, Header, EntrySize}] = RestEntries,
    {Name, _Value} = Header,
    NewFieldIndex =
        case maps:get(Header, State#qpack.dyn_field_index, undefined) of
            AbsIndex -> maps:remove(Header, State#qpack.dyn_field_index);
            _ -> State#qpack.dyn_field_index
        end,
    NewNameIndex =
        case maps:get(Name, State#qpack.dyn_name_index, undefined) of
            AbsIndex -> maps:remove(Name, State#qpack.dyn_name_index);
            _ -> State#qpack.dyn_name_index
        end,
    State1 = State#qpack{
        dyn_entries = Oldest,
        dyn_field_index = NewFieldIndex,
        dyn_name_index = NewNameIndex,
        dyn_size = State#qpack.dyn_size - EntrySize
    },
    evict_to_fit(RequiredSize, State1).

%% True if AbsIndex is referenced by any pending (unacked) section. A section
%% with RIC R references entries [0..R-1], so entries with AbsIndex < R are
%% pinned. We pin if AbsIndex < smallest pending RIC across all streams.
is_entry_pinned(AbsIndex, #qpack{pending_sections = Pending}) when map_size(Pending) =:= 0 ->
    AbsIndex >= 0 andalso false;
is_entry_pinned(AbsIndex, #qpack{pending_sections = Pending}) ->
    MinRIC = maps:fold(
        fun(_StreamId, Q, Acc) ->
            case queue:peek(Q) of
                empty -> Acc;
                {value, R} when Acc =:= undefined orelse R < Acc -> R;
                _ -> Acc
            end
        end,
        undefined,
        Pending
    ),
    case MinRIC of
        undefined -> false;
        _ -> AbsIndex < MinRIC
    end.

%% @doc Get dynamic table entry by relative index.
%% Relative index 0 is the most recently inserted entry.
-spec get_dynamic_entry_by_relative(non_neg_integer(), state()) -> header() | undefined.
get_dynamic_entry_by_relative(RelIndex, #qpack{insert_count = IC} = State) ->
    %% Relative index 0 = most recent = IC - 1
    AbsIndex = IC - RelIndex - 1,
    get_dynamic_entry_by_absolute(AbsIndex, State).

%% @doc Get dynamic table entry by absolute index.
-spec get_dynamic_entry_by_absolute(non_neg_integer(), state()) -> header() | undefined.
get_dynamic_entry_by_absolute(AbsIndex, #qpack{dyn_entries = Entries}) ->
    case lists:keyfind(AbsIndex, 1, Entries) of
        {AbsIndex, Header, _Size} -> Header;
        false -> undefined
    end.

%% @doc Find a match in the dynamic table.
%% Returns {exact, AbsIndex}, {name, AbsIndex}, or none.
%% Note: Only called when use_dynamic = true (checked by caller).
-spec find_dynamic_match(binary(), binary(), state()) ->
    {exact, non_neg_integer()} | {name, non_neg_integer()} | none.
find_dynamic_match(Name, Value, #qpack{dyn_field_index = FieldIndex, dyn_name_index = NameIndex}) ->
    Header = {Name, Value},
    case maps:find(Header, FieldIndex) of
        {ok, AbsIndex} ->
            {exact, AbsIndex};
        error ->
            case maps:find(Name, NameIndex) of
                {ok, AbsIndex} ->
                    {name, AbsIndex};
                error ->
                    none
            end
    end.
