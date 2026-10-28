%%% -*- erlang -*-
%%%
%%% QUIC ACK Frame Processing
%%% RFC 9000 Section 13 - Packetization and Reliability
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC ACK frame generation and processing.
%%%
%%% Two independent things live here. They share the range form below and
%%% nothing else, so read whichever one you came for and ignore the other.
%%%
%%% == The connection's ACK path (stateless) ==
%%%
%%% Plain functions over a range list, no state record. `quic_connection'
%%% drives these: it keeps its ranges in `#pn_space.ack_ranges' and never
%%% builds an `#ack_state{}'. Range accumulation, the retained-range cap,
%%% ACK frame construction, and the frame classification deciding whether
%%% a packet needs acknowledging. `quic_loss' calls `ack_frame_to_ranges/3'
%%% from this half when an ACK arrives.
%%%
%%% == The #ack_state{} accumulator (stateful) ==
%%%
%%% A self-contained receiver: `new/0', then `record_received/2,3' per
%%% packet, then `generate_ack/1,2', `needs_ack/1' and `process_ack/2,3'.
%%% No production code drives it; only tests do. It is not dead weight:
%%% it carries the ACK delay and ECN arithmetic that the stateless half
%%% has no equivalent for, and it is the only coverage of that arithmetic.
%%%
%%% == ACK Ranges ==
%%%
%%% Both halves use the same form: a list of {Start, End} tuples where
%%% Start =&lt; End, sorted in descending order by Start.
%%% Example: [{100, 105}, {90, 95}, {80, 82}] acknowledges packets
%%% 100-105, 90-95, and 80-82.
%%%

-module(quic_ack).

-include("quic.hrl").

-export([
    %% The connection's ACK path: stateless, no #ack_state{}.
    %% Range accumulation
    add_to_ranges/2,
    merge_ranges/1,
    cap_ack_ranges/1,
    update_pn_space_recv/3,

    %% Frame construction
    build_ack_frame_tuple/1,
    build_ack_frame/1,
    convert_ack_ranges_for_encode/1,
    ranges_to_ack_format/1,

    %% Frame classification for ACK policy
    contains_ack_eliciting_frames/1,
    is_ack_eliciting_frame/1,

    %% ACK frame decoding, used by both halves. quic_loss calls
    %% ack_frame_to_ranges/3.
    ack_frame_to_pn_list/3,
    ack_frame_to_ranges/3,

    %% The #ack_state{} accumulator: stateful, driven by tests only.
    new/0,
    record_received/2,
    record_received/3,
    generate_ack/1,
    generate_ack/2,
    needs_ack/1,
    mark_ack_sent/1,
    process_ack/2,
    process_ack/3,

    %% Queries on #ack_state{}
    largest_received/1,
    largest_acked/1,
    ack_ranges/1,
    ack_eliciting_in_flight/1
]).

%% ACK tracking state
-record(ack_state, {
    %% Receive tracking
    largest_recv :: non_neg_integer() | undefined,
    % monotonic milliseconds
    recv_time :: non_neg_integer() | undefined,
    ack_ranges = [] :: [{non_neg_integer(), non_neg_integer()}],

    %% Send tracking
    largest_acked :: non_neg_integer() | undefined,
    ack_eliciting_in_flight = 0 :: non_neg_integer(),

    %% ACK generation
    ack_pending = false :: boolean(),
    ack_eliciting_received = 0 :: non_neg_integer(),

    %% Configuration
    ack_delay_exponent = ?DEFAULT_ACK_DELAY_EXPONENT :: non_neg_integer(),
    max_ack_delay = ?DEFAULT_MAX_ACK_DELAY :: non_neg_integer()
}).

-opaque ack_state() :: #ack_state{}.
-export_type([ack_state/0]).

%% Maximum ACK range size to prevent memory exhaustion
-define(MAX_ACK_RANGE, 65536).

%% Max ACK ranges retained per PN space (RFC 9000 §13.2.4 allows the
%% receiver to limit these). Under burst loss an unbounded list
%% fragments into hundreds of ranges, and since every outgoing ACK
%% encodes the full list (and the peer decodes it), ACK processing cost
%% grows O(ranges) per packet on both ends. Distinct from ?MAX_ACK_RANGE,
%% which bounds the span of a single range.
-define(MAX_ACK_RANGE_COUNT, 64).

%%%===================================================================
%%% The #ack_state{} accumulator (stateful)
%%%
%%% Everything from here to "Queries on #ack_state{}" belongs to the
%%% self-contained receiver. No production code drives it; only tests.
%%% It holds the ACK delay and ECN arithmetic the stateless half lacks.
%%%===================================================================

%%====================================================================
%% ACK State Management
%%====================================================================

%% @doc Create a new ACK tracking state.
-spec new() -> ack_state().
new() ->
    #ack_state{}.

%%====================================================================
%% Packet Reception Tracking
%%====================================================================

%% @doc Record that a packet was received.
-spec record_received(ack_state(), non_neg_integer()) -> ack_state().
record_received(State, PacketNumber) ->
    record_received(State, PacketNumber, true).

%% @doc Record that a packet was received, optionally marking it as ACK-eliciting.
-spec record_received(ack_state(), non_neg_integer(), boolean()) -> ack_state().
record_received(
    #ack_state{
        largest_recv = Largest,
        ack_ranges = Ranges,
        ack_eliciting_received = AckEliciting
    } = State,
    PacketNumber,
    IsAckEliciting
) ->
    Now = erlang:monotonic_time(millisecond),

    %% Update largest received
    {NewLargest, NewTime} =
        case Largest of
            undefined -> {PacketNumber, Now};
            L when PacketNumber > L -> {PacketNumber, Now};
            _ -> {Largest, State#ack_state.recv_time}
        end,

    %% Update ACK ranges
    NewRanges = add_to_ranges(PacketNumber, Ranges),

    %% Update ACK-eliciting count
    NewAckEliciting =
        case IsAckEliciting of
            true -> AckEliciting + 1;
            false -> AckEliciting
        end,

    State#ack_state{
        largest_recv = NewLargest,
        recv_time = NewTime,
        ack_ranges = NewRanges,
        ack_pending = IsAckEliciting orelse State#ack_state.ack_pending,
        ack_eliciting_received = NewAckEliciting
    }.

%%====================================================================
%% ACK Frame Generation
%%====================================================================

%% @doc Generate an ACK frame for the current state.
%% Returns {ok, AckFrame} or {error, no_packets}.
-spec generate_ack(ack_state()) -> {ok, term()} | {error, no_packets}.
generate_ack(State) ->
    generate_ack(State, erlang:monotonic_time(millisecond)).

%% @doc Generate an ACK frame with a specific timestamp.
-spec generate_ack(ack_state(), non_neg_integer()) -> {ok, term()} | {error, no_packets}.
generate_ack(#ack_state{largest_recv = undefined}, _Now) ->
    {error, no_packets};
generate_ack(
    #ack_state{
        largest_recv = Largest,
        recv_time = RecvTime,
        ack_ranges = Ranges,
        ack_delay_exponent = Exp
    },
    Now
) ->
    %% Calculate ACK delay in microseconds, then encode
    AckDelayUs = (Now - RecvTime) * 1000,
    AckDelayEncoded = AckDelayUs bsr Exp,

    %% Convert ranges to ACK frame format
    %% First range count is the number of packets in the first range - 1
    [{FirstStart, FirstEnd} | RestRanges] = Ranges,
    FirstAckRange = FirstEnd - FirstStart,

    %% Convert remaining ranges to gap/range pairs, with the same guard the
    %% connection's path applies to a malformed or oversized range.
    AckRanges = convert_rest_ranges(FirstStart, RestRanges),

    AckFrame = {ack, Largest, AckDelayEncoded, FirstAckRange, AckRanges},
    {ok, AckFrame}.

%% @doc Check if an ACK needs to be sent.
-spec needs_ack(ack_state()) -> boolean().
needs_ack(#ack_state{ack_pending = Pending, ack_eliciting_received = Count}) ->
    Pending andalso Count > 0.

%% @doc Mark that an ACK was sent.
-spec mark_ack_sent(ack_state()) -> ack_state().
mark_ack_sent(State) ->
    State#ack_state{
        ack_pending = false,
        ack_eliciting_received = 0
    }.

%%====================================================================
%% ACK Frame Processing
%%====================================================================

%% @doc Process a received ACK frame.
%% Returns {NewState, AckedPackets} where AckedPackets is a list of
%% newly acknowledged packet numbers.
-spec process_ack(ack_state(), term()) ->
    {ack_state(), [non_neg_integer()]}.
process_ack(State, AckFrame) ->
    process_ack(State, AckFrame, #{}).

%% @doc Process a received ACK frame with sent packet info.
%% SentPackets is a map of PacketNumber => SentPacketInfo
-spec process_ack(ack_state(), term(), map()) ->
    {ack_state(), [non_neg_integer()]} | {error, ack_range_too_large}.
process_ack(State, {ack, LargestAcked, _AckDelay, FirstRange, AckRanges}, SentPackets) ->
    %% Build list of acknowledged packet numbers
    case ack_frame_to_pn_list(LargestAcked, FirstRange, AckRanges) of
        {error, _} = Error ->
            Error;
        AckedPNs ->
            %% Filter to only packets we actually sent
            NewlyAcked =
                case maps:size(SentPackets) of
                    0 -> AckedPNs;
                    _ -> [PN || PN <- AckedPNs, maps:is_key(PN, SentPackets)]
                end,

            %% Update largest acked
            NewLargestAcked =
                case State#ack_state.largest_acked of
                    undefined -> LargestAcked;
                    Old when LargestAcked > Old -> LargestAcked;
                    Old -> Old
                end,

            %% Update ACK-eliciting in flight count
            AckElicitingAcked = length([
                PN
             || PN <- NewlyAcked,
                maps:is_key(PN, SentPackets),
                is_ack_eliciting(maps:get(PN, SentPackets))
            ]),
            NewInFlight = max(0, State#ack_state.ack_eliciting_in_flight - AckElicitingAcked),

            NewState = State#ack_state{
                largest_acked = NewLargestAcked,
                ack_eliciting_in_flight = NewInFlight
            },

            {NewState, NewlyAcked}
    end;
process_ack(
    State, {ack_ecn, LargestAcked, AckDelay, FirstRange, AckRanges, ECT0, ECT1, ECNCE}, SentPackets
) ->
    %% Process ACK and return ECN counts for congestion control
    {NewState, NewlyAcked} = process_ack(
        State, {ack, LargestAcked, AckDelay, FirstRange, AckRanges}, SentPackets
    ),
    {NewState, NewlyAcked, {ecn, ECT0, ECT1, ECNCE}}.

%%====================================================================
%% Queries on #ack_state{}
%%====================================================================

%% @doc Get the largest received packet number.
-spec largest_received(ack_state()) -> non_neg_integer() | undefined.
largest_received(#ack_state{largest_recv = L}) -> L.

%% @doc Get the largest acknowledged packet number.
-spec largest_acked(ack_state()) -> non_neg_integer() | undefined.
largest_acked(#ack_state{largest_acked = L}) -> L.

%% @doc Get the current ACK ranges.
-spec ack_ranges(ack_state()) -> [{non_neg_integer(), non_neg_integer()}].
ack_ranges(#ack_state{ack_ranges = R}) -> R.

%% @doc Get the number of ACK-eliciting packets in flight.
-spec ack_eliciting_in_flight(ack_state()) -> non_neg_integer().
ack_eliciting_in_flight(#ack_state{ack_eliciting_in_flight = N}) -> N.

%%%===================================================================
%%% The connection's ACK path (stateless)
%%%
%%% Everything from here to "ACK frame decoding" is plain functions over
%%% a range list. quic_connection drives them, keeping its ranges in
%%% #pn_space.ack_ranges and holding no #ack_state{}.
%%%===================================================================

%%====================================================================
%% Range accumulation
%%====================================================================

%% @doc Add a packet number to a descending, disjoint range list.
%%
%% Ranges touching the new packet number are extended, and extending
%% downward may close a gap, so the head is re-merged.
-spec add_to_ranges(non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]) ->
    [{non_neg_integer(), non_neg_integer()}].
add_to_ranges(PN, []) ->
    [{PN, PN}];
add_to_ranges(PN, [{_Start, End} | _Rest] = Ranges) when PN > End + 1 ->
    %% New range before current
    [{PN, PN} | Ranges];
add_to_ranges(PN, [{Start, End} | Rest]) when PN =:= End + 1 ->
    %% Extend current range upward
    [{Start, PN} | Rest];
add_to_ranges(PN, [{Start, End} | Rest]) when PN >= Start, PN =< End ->
    %% Already in range
    [{Start, End} | Rest];
add_to_ranges(PN, [{Start, End} | Rest]) when PN =:= Start - 1 ->
    %% Extend current range downward, possibly merge with next
    merge_ranges([{PN, End} | Rest]);
add_to_ranges(PN, [Range | Rest]) ->
    %% Check remaining ranges
    [Range | add_to_ranges(PN, Rest)].

%% @doc Merge the head range with the next when they touch or overlap.
-spec merge_ranges([{non_neg_integer(), non_neg_integer()}]) ->
    [{non_neg_integer(), non_neg_integer()}].
merge_ranges([{S1, E1}, {S2, E2} | Rest]) when E2 + 1 >= S1 ->
    merge_ranges([{S2, max(E1, E2)} | Rest]);
merge_ranges(Ranges) ->
    Ranges.

%% @doc Drop the lowest ranges beyond ?MAX_ACK_RANGE_COUNT.
%%
%% The list is descending, so the newest packet numbers are kept. Packets
%% below the lowest retained range are retransmitted by the peer and
%% dropped as duplicates.
-spec cap_ack_ranges([{non_neg_integer(), non_neg_integer()}]) ->
    [{non_neg_integer(), non_neg_integer()}].
cap_ack_ranges([_, _ | Tail] = Ranges) when Tail =/= [] ->
    case length(Ranges) > ?MAX_ACK_RANGE_COUNT of
        true -> lists:sublist(Ranges, ?MAX_ACK_RANGE_COUNT);
        false -> Ranges
    end;
cap_ack_ranges(Ranges) ->
    Ranges.

%% @doc Record a received packet number in a packet-number space.
%%
%% A packet continuing the receive sequence extends the head range in
%% place, so the range count cannot grow and the cap scan is skipped.
-spec update_pn_space_recv(non_neg_integer(), #pn_space{}, non_neg_integer()) -> #pn_space{}.
update_pn_space_recv(PN, PNSpace, Now) ->
    #pn_space{largest_recv = LargestRecv, ack_ranges = Ranges} = PNSpace,
    NewLargest =
        case LargestRecv of
            undefined -> PN;
            L when PN > L -> PN;
            L -> L
        end,
    NewRanges =
        case LargestRecv =/= undefined andalso PN =:= LargestRecv + 1 of
            true -> add_to_ranges(PN, Ranges);
            false -> cap_ack_ranges(add_to_ranges(PN, Ranges))
        end,
    PNSpace#pn_space{
        largest_recv = NewLargest,
        recv_time = Now,
        ack_ranges = NewRanges
    }.

%%====================================================================
%% ACK frame construction
%%
%% The connection's send path builds ACK frames straight from its
%% #pn_space.ack_ranges, holding no #ack_state{}.
%%====================================================================

%% @doc Build an unencoded ACK frame tuple from internal ranges.
%%
%% The delay is zero: the frame is built at send time, so there is no
%% accumulated delay to report.
-spec build_ack_frame_tuple([{non_neg_integer(), non_neg_integer()}]) ->
    {ack, [{non_neg_integer(), non_neg_integer()}], non_neg_integer(), undefined}.
build_ack_frame_tuple(Ranges) ->
    EncoderRanges = convert_ack_ranges_for_encode(Ranges),
    AckDelay = 0,
    {ack, EncoderRanges, AckDelay, undefined}.

%% @doc Build an encoded ACK frame from internal ranges.
-spec build_ack_frame([{non_neg_integer(), non_neg_integer()}]) -> binary().
build_ack_frame(Ranges) ->
    quic_frame:encode(build_ack_frame_tuple(Ranges)).

%% @doc Convert internal ACK ranges to encoder format.
%%
%% Internal form is [{Start, End}, ...] descending, where Start =&lt; End.
%% The encoder expects [{LargestAcked, FirstRange}, {Gap, Range}, ...].
%% The first range is capped at ?MAX_ACK_RANGE so the receiver does not
%% reject the frame.
-spec convert_ack_ranges_for_encode([{non_neg_integer(), non_neg_integer()}]) ->
    [{non_neg_integer(), non_neg_integer()}].
convert_ack_ranges_for_encode([{Start, End} | Rest]) ->
    FirstRange = min(End - Start, ?MAX_ACK_RANGE),
    AdjustedStart = End - FirstRange,
    RestConverted = convert_rest_ranges(AdjustedStart, Rest),
    [{End, FirstRange} | RestConverted].

%% @doc Split the codec's range list into the shape quic_loss takes.
%%
%% Drops the largest acked, which the caller already holds.
-spec ranges_to_ack_format([{non_neg_integer(), non_neg_integer()}]) ->
    {non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]}.
ranges_to_ack_format([{_LargestAcked, FirstRange} | RestRanges]) ->
    {FirstRange, RestRanges}.

%%====================================================================
%% Frame classification for ACK policy
%%====================================================================

%% @doc Is any frame in the list ack-eliciting?
%%
%% The single stream frame produced by every chunked send takes a fast
%% path rather than the list walk.
-spec contains_ack_eliciting_frames([term()]) -> boolean().
contains_ack_eliciting_frames([{stream, _, _, _, _}]) ->
    true;
contains_ack_eliciting_frames([]) ->
    false;
contains_ack_eliciting_frames([Frame | Rest]) ->
    case is_ack_eliciting_frame(Frame) of
        true -> true;
        false -> contains_ack_eliciting_frames(Rest)
    end.

%% @doc Is a decoded frame ack-eliciting?
%%
%% Per RFC 9002, ACK, PADDING and CONNECTION_CLOSE are not.
-spec is_ack_eliciting_frame(term()) -> boolean().
is_ack_eliciting_frame(padding) -> false;
is_ack_eliciting_frame({ack, _, _, _}) -> false;
is_ack_eliciting_frame({connection_close, _, _, _, _}) -> false;
is_ack_eliciting_frame(_) -> true.

%%====================================================================
%% ACK frame decoding
%%
%% Reached from both halves: process_ack/3 expands a frame to packet
%% numbers, and quic_loss calls ack_frame_to_ranges/3 to keep the ranges.
%%====================================================================

%% @doc Convert an ACK frame to the list of packet numbers it covers.
%%
%% Prefer ack_frame_to_ranges/3 for wide ranges: this expands every
%% packet number into the list.
-spec ack_frame_to_pn_list(non_neg_integer(), non_neg_integer(), list()) ->
    [non_neg_integer()] | {error, ack_range_too_large}.
ack_frame_to_pn_list(LargestAcked, FirstRange, AckRanges) ->
    %% First range: LargestAcked - FirstRange to LargestAcked
    FirstEnd = LargestAcked,
    FirstStart = LargestAcked - FirstRange,
    case FirstEnd - FirstStart > ?MAX_ACK_RANGE of
        true ->
            {error, ack_range_too_large};
        false ->
            FirstPNs = lists:seq(FirstStart, FirstEnd),
            %% Process remaining ranges
            case ack_ranges_to_pn_list(FirstStart, AckRanges) of
                {error, _} = Error -> Error;
                RestPNs -> FirstPNs ++ RestPNs
            end
    end.

ack_ranges_to_pn_list(_PrevStart, []) ->
    [];
ack_ranges_to_pn_list(PrevStart, [{Gap, Range} | Rest]) ->
    %% End of this range
    End = PrevStart - Gap - 2,
    Start = End - Range,
    case End - Start > ?MAX_ACK_RANGE of
        true ->
            {error, ack_range_too_large};
        false ->
            PNs = lists:seq(Start, End),
            case ack_ranges_to_pn_list(Start, Rest) of
                {error, _} = Error -> Error;
                RestPNs -> PNs ++ RestPNs
            end
    end.

%% @doc Convert ACK frame to list of ranges instead of expanded list.
%% Returns a list of `{Start, End}' tuples where Start is less than or equal to End.
%% Much more efficient than ack_frame_to_pn_list for large ranges.
%% Example: `{100, 5, [{2, 3}]}' becomes `[{95, 100}, {89, 92}]'
-spec ack_frame_to_ranges(non_neg_integer(), non_neg_integer(), list()) ->
    [{non_neg_integer(), non_neg_integer()}] | {error, ack_range_too_large}.
ack_frame_to_ranges(LargestAcked, FirstRange, AckRanges) ->
    %% First range: LargestAcked - FirstRange to LargestAcked
    FirstEnd = LargestAcked,
    FirstStart = LargestAcked - FirstRange,
    case FirstEnd - FirstStart > ?MAX_ACK_RANGE of
        true ->
            {error, ack_range_too_large};
        false ->
            FirstRangeT = {FirstStart, FirstEnd},
            case ack_ranges_to_range_list(FirstStart, AckRanges) of
                {error, _} = Error -> Error;
                RestRanges -> [FirstRangeT | RestRanges]
            end
    end.

ack_ranges_to_range_list(_PrevStart, []) ->
    [];
ack_ranges_to_range_list(PrevStart, [{Gap, Range} | Rest]) ->
    %% End of this range
    End = PrevStart - Gap - 2,
    Start = End - Range,
    case End - Start > ?MAX_ACK_RANGE of
        true ->
            {error, ack_range_too_large};
        false ->
            RangeT = {Start, End},
            case ack_ranges_to_range_list(Start, Rest) of
                {error, _} = Error -> Error;
                RestRanges -> [RangeT | RestRanges]
            end
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Convert the remaining ranges to gap/range pairs. A malformed range is
%% skipped rather than encoded as a negative varint. Used by both halves.
convert_rest_ranges(_PrevStart, []) ->
    [];
convert_rest_ranges(PrevStart, [{Start, End} | Rest]) ->
    Gap = PrevStart - End - 2,
    Range = End - Start,
    case Gap >= 0 andalso Range >= 0 andalso Range =< ?MAX_ACK_RANGE of
        true ->
            [{Gap, Range} | convert_rest_ranges(Start, Rest)];
        false ->
            %% Keep PrevStart so the next gap stays correct.
            convert_rest_ranges(PrevStart, Rest)
    end.

%% Does a sent packet record count as ACK-eliciting? Takes #sent_packet{},
%% unlike is_ack_eliciting_frame/1, which classifies a decoded frame.
is_ack_eliciting(#sent_packet{ack_eliciting = AE}) ->
    AE;
is_ack_eliciting(Info) when is_map(Info) ->
    maps:get(ack_eliciting, Info, false);
is_ack_eliciting(_) ->
    false.
