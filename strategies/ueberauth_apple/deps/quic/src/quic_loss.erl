%%% -*- erlang -*-
%%%
%%% QUIC Loss Detection
%%% RFC 9002 - Loss Detection and Congestion Control
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC loss detection implementation.
%%%
%%% This module implements:
%%% - Packet loss detection using time and packet thresholds
%%% - RTT estimation (smoothed RTT, RTT variance)
%%% - Probe Timeout (PTO) calculation
%%% - Loss detection timer management
%%%
%%% == Loss Detection Methods ==
%%%
%%% 1. Packet Threshold: A packet is lost if a packet sent more than
%%%    kPacketThreshold (3) later has been acknowledged.
%%%
%%% 2. Time Threshold: A packet is lost if it was sent more than
%%%    max(kTimeThreshold * smoothed_rtt, kGranularity) ago and a
%%%    later packet has been acknowledged.
%%%

-module(quic_loss).

-include("quic.hrl").

-export([
    reset_for_new_path/1,
    %% Loss detection state
    new/0,
    new/1,

    %% Packet tracking
    on_packet_sent/5,
    on_packet_sent/6,
    on_packet_sent/7,
    on_packets_sent_run/4,
    on_ack_received/4,

    %% Retransmission
    retransmittable_frames/1,
    stream_has_unacked_below/3,

    %% Loss detection
    detect_lost_packets/3,
    get_loss_time_and_space/1,
    largest_acked/2,

    %% RTT
    update_rtt/3,
    rtt/1,

    %% PTO
    get_pto/2,
    discard_space/2,
    reset_for_retry/2,
    get_pto_time_and_space/3,
    persistent_congestion_pto/1,
    on_pto_expired/1,

    %% Peer transport parameters and handshake confirmation
    set_peer_ack_params/3,
    on_handshake_confirmed/1,

    %% Queries
    sent_packets/2,
    bytes_in_flight/1,
    last_progress/1,
    pto_count/1,
    oldest_unacked/2,
    handshake_confirmed/1
]).

%% Constants from RFC 9002
-define(PACKET_THRESHOLD, 3).
% 9/8
-define(TIME_THRESHOLD, 1.125).
% 1 millisecond
-define(MAX_PTO_MS, 5000).
-define(GRANULARITY, 1).
% RFC 9002 default is 333ms, but 100ms is more aggressive for faster ramp-up
-define(DEFAULT_INITIAL_RTT, 100).

%% Loss detection state.
%%
%% Each space's `sent_q' is an oldest-first queue of #sent_packet{}. Because sent
%% packet numbers are strictly monotonically increasing, the queue's
%% insertion order is also PN order and time_sent order, so:
%%   - on_packet_sent: queue:in/2 at the tail (amortised O(1))
%%   - oldest unacked: queue:peek/1 at the head (O(1))
%%   - loss-time / ACK classification: walk head to tail, stopping
%%     once PNs exceed the relevant threshold.
%% This replaces the previous dual map + gb_sets representation,
%% which paid O(log n) per send/ack/loss-scan and showed up in the
%% profile as the dominant CPU cost (gb_sets:*).
%% Per-packet-number-space loss state (RFC 9002 Appendix A.3). Packet
%% numbers restart per space, so a queue shared across spaces would let
%% a Handshake ACK of PN 0..N acknowledge the first N application
%% packets.
-record(pn_loss, {
    sent_q = queue:new() :: queue:queue(#sent_packet{}),
    loss_time = undefined :: non_neg_integer() | undefined,
    largest_acked = undefined :: non_neg_integer() | undefined,

    %% When the most recent ack-eliciting packet went out, which is what
    %% the PTO deadline is measured from, and how many are outstanding.
    last_ae_sent = undefined :: integer() | undefined,
    ae_in_flight = 0 :: non_neg_integer()
}).

-record(loss_state, {
    %% One per space. Only `app' is populated until the connection
    %% registers Initial and Handshake sends.
    initial = #pn_loss{} :: #pn_loss{},
    handshake = #pn_loss{} :: #pn_loss{},
    app = #pn_loss{} :: #pn_loss{},

    %% RTT estimation, which belongs to the path rather than to any one
    %% space (RFC 9002 Section 5).
    rtt = quic_rtt:new() :: quic_rtt:state(),

    %% Loss detection. loss_time is per space, in #pn_loss{}.
    time_of_last_ack = undefined :: non_neg_integer() | undefined,

    %% When the current outstanding burst started: set whenever an
    %% ack-eliciting packet is sent while nothing was in flight. Used
    %% together with time_of_last_ack as the anchor for the disconnect
    %% timeout, so a fresh send after a quiet period cannot trip it.
    outstanding_since = undefined :: non_neg_integer() | undefined,

    %% PTO
    pto_count = 0 :: non_neg_integer(),

    %% Bytes in flight
    bytes_in_flight = 0 :: non_neg_integer(),

    %% Configuration. The peer's values arrive with its transport
    %% parameters (set_peer_ack_params/3).
    max_ack_delay = ?DEFAULT_MAX_ACK_DELAY :: non_neg_integer(),
    ack_delay_exponent = ?DEFAULT_ACK_DELAY_EXPONENT :: non_neg_integer(),

    %% max_ack_delay only caps RTT samples and joins the PTO once the
    %% handshake is confirmed (RFC 9002 Sections 5.3 and 6.2.1).
    handshake_confirmed = false :: boolean()
}).

-opaque loss_state() :: #loss_state{}.

%% A packet number space (RFC 9000 Section 12.3). 0-RTT and 1-RTT share
%% `app'. Named `space' rather than `pn_space' so specs mentioning both
%% this and the `#pn_space{}' record stay readable.
-type space() :: initial | handshake | app.

-export_type([loss_state/0, space/0]).

%% RFC 9002 §9.4 path-change reset: RTT and PTO state belong to the
%% old path, but the sent-packet tracking must survive - dropping it
%% orphans every in-flight packet (no ACK match, no loss declaration,
%% no PTO since bytes_in_flight reads 0) and any lost data in that set
%% is never retransmitted.
-spec reset_for_new_path(loss_state() | undefined) -> loss_state().
reset_for_new_path(undefined) ->
    new();
reset_for_new_path(#loss_state{} = S) ->
    S#loss_state{
        rtt = quic_rtt:reset(S#loss_state.rtt),
        pto_count = 0,
        initial = clear_loss_time(S#loss_state.initial),
        handshake = clear_loss_time(S#loss_state.handshake),
        app = clear_loss_time(S#loss_state.app)
    }.

clear_loss_time(#pn_loss{} = P) -> P#pn_loss{loss_time = undefined}.

%% largest_acked only ever moves forward: a reordered ACK naming a
%% smaller largest must not pull it back (RFC 9002 Appendix A.7).
newest(undefined, New) -> New;
newest(Old, New) when New > Old -> New;
newest(Old, _New) -> Old.

%%====================================================================
%% Packet number spaces
%%====================================================================

%% Read and write one space's state. Three clauses rather than a map:
%% a maps:get/put per packet is exactly the per-send cost the queue
%% representation was introduced to remove.
-spec pn(space(), loss_state()) -> #pn_loss{}.
pn(app, #loss_state{app = P}) -> P;
pn(initial, #loss_state{initial = P}) -> P;
pn(handshake, #loss_state{handshake = P}) -> P.

-spec set_pn(space(), #pn_loss{}, loss_state()) -> loss_state().
set_pn(app, P, S) -> S#loss_state{app = P};
set_pn(initial, P, S) -> S#loss_state{initial = P};
set_pn(handshake, P, S) -> S#loss_state{handshake = P}.

%%====================================================================
%% Loss Detection State
%%====================================================================

%% @doc Create a new loss detection state.
-spec new() -> loss_state().
new() ->
    new(#{}).

%% @doc Create a new loss detection state with options.
%% Options:
%%   - max_ack_delay: Maximum ACK delay (default: 25ms)
%%   - initial_rtt: Initial RTT estimate in ms (default: 100ms)
-spec new(map()) -> loss_state().
new(Opts) ->
    InitialRTT = maps:get(initial_rtt, Opts, ?DEFAULT_INITIAL_RTT),
    #loss_state{
        rtt = quic_rtt:new(InitialRTT),
        max_ack_delay = maps:get(max_ack_delay, Opts, ?DEFAULT_MAX_ACK_DELAY)
    }.

%%====================================================================
%% Packet Tracking
%%====================================================================

%% @doc Record that a packet was sent (without frames).
-spec on_packet_sent(space(), loss_state(), non_neg_integer(), non_neg_integer(), boolean()) ->
    loss_state().
on_packet_sent(Space, State, PacketNumber, Size, AckEliciting) ->
    on_packet_sent(Space, State, PacketNumber, Size, AckEliciting, []).

%% @doc Record that a packet was sent with frames. Samples the send
%% time itself. Callers that already hold a Now should use
%% on_packet_sent/7 to avoid a duplicate monotonic_time/1 BIF call.
-spec on_packet_sent(
    space(), loss_state(), non_neg_integer(), non_neg_integer(), boolean(), [term()]
) ->
    loss_state().
on_packet_sent(Space, State, PacketNumber, Size, AckEliciting, Frames) ->
    Now = erlang:monotonic_time(millisecond),
    on_packet_sent(Space, State, PacketNumber, Size, AckEliciting, Frames, Now).

%% @doc Like on_packet_sent/5 but uses the caller-supplied monotonic
%% millisecond timestamp. The connection send loop reuses one Now
%% per packet for both loss tracking and last_activity, saving a
%% BIF call.
-spec on_packet_sent(
    space(),
    loss_state(),
    non_neg_integer(),
    non_neg_integer(),
    boolean(),
    [term()],
    integer()
) -> loss_state().
on_packet_sent(
    Space,
    #loss_state{bytes_in_flight = InFlight} = State,
    PacketNumber,
    Size,
    AckEliciting,
    Frames,
    Now
) ->
    #pn_loss{sent_q = Q, ae_in_flight = AE} = P = pn(Space, State),
    SentPacket = #sent_packet{
        pn = PacketNumber,
        time_sent = Now,
        ack_eliciting = AckEliciting,
        in_flight = true,
        size = Size,
        frames = Frames
    },
    NewInFlight =
        case AckEliciting of
            true -> InFlight + Size;
            false -> InFlight
        end,
    OutstandingSince =
        case AckEliciting andalso InFlight =:= 0 of
            true -> Now;
            false -> State#loss_state.outstanding_since
        end,
    {LastAE, NewAE} =
        case AckEliciting of
            true -> {Now, AE + 1};
            false -> {P#pn_loss.last_ae_sent, AE}
        end,
    %% NOTE: pto_count is NOT reset here per RFC 9002.
    %% PTO count is only reset when receiving an ACK (in on_ack_received).
    %% Resetting on send would break exponential backoff for probe retransmissions.
    State1 = State#loss_state{
        bytes_in_flight = NewInFlight,
        outstanding_since = OutstandingSince
    },
    set_pn(
        Space,
        P#pn_loss{sent_q = queue:in(SentPacket, Q), last_ae_sent = LastAE, ae_in_flight = NewAE},
        State1
    ).

%% @doc Batched on_packet_sent for a run of ack-eliciting packets sent
%% at the same instant: one queue fold and one record update. Tracked
%% is [{PN, Size, Frame}] in ascending PN order.
-spec on_packets_sent_run(
    space(), loss_state(), [{non_neg_integer(), non_neg_integer(), term()}], integer()
) -> loss_state().
on_packets_sent_run(Space, #loss_state{bytes_in_flight = InFlight} = State, Tracked, Now) ->
    #pn_loss{sent_q = Q, ae_in_flight = AE} = P = pn(Space, State),
    {Q1, Total, Count} = lists:foldl(
        fun({PN, Size, Frame}, {QAcc, TAcc, N}) ->
            SentPacket = #sent_packet{
                pn = PN,
                time_sent = Now,
                ack_eliciting = true,
                in_flight = true,
                size = Size,
                frames = [Frame]
            },
            {queue:in(SentPacket, QAcc), TAcc + Size, N + 1}
        end,
        {Q, 0, 0},
        Tracked
    ),
    OutstandingSince =
        case InFlight =:= 0 andalso Total > 0 of
            true -> Now;
            false -> State#loss_state.outstanding_since
        end,
    LastAE =
        case Count > 0 of
            true -> Now;
            false -> P#pn_loss.last_ae_sent
        end,
    State1 = State#loss_state{
        bytes_in_flight = InFlight + Total,
        outstanding_since = OutstandingSince
    },
    set_pn(
        Space,
        P#pn_loss{sent_q = Q1, last_ae_sent = LastAE, ae_in_flight = AE + Count},
        State1
    ).

%% @doc Process an ACK frame.
%% Returns {NewState, AckedPackets, LostPackets, AckMeta} or {error, ack_range_too_large}
%% AckMeta is a map containing:
%%   - acked_bytes: total bytes from ack-eliciting packets that were acknowledged
%%   - largest_ae_time: sent_time of the largest ack-eliciting packet acknowledged
%%
%% Implementation: three passes over the sent queue.
%%   1. classify_ack_q: split queue into (acked, kept-unacked) by the
%%      ACK ranges in a single head-to-tail walk. Stops early once we
%%      pass LargestAcked.
%%   2. maybe_update_rtt: RTT sample derived from the largest acked
%%      ack-eliciting packet, if present.
%%   3. detect_lost_q: over the kept survivors, apply packet-threshold
%%      and time-threshold loss criteria using the freshly updated SRTT.
-spec on_ack_received(space(), loss_state(), term(), non_neg_integer()) ->
    {loss_state(), [#sent_packet{}], [#sent_packet{}], map()} | {error, ack_range_too_large}.
on_ack_received(Space, State, {ack, LargestAcked, AckDelay, FirstRange, AckRanges}, Now) ->
    case quic_ack:ack_frame_to_ranges(LargestAcked, FirstRange, AckRanges) of
        {error, _} = Error ->
            Error;
        AckedRanges ->
            %% Phase 1: walk the sent queue ONLY through packets with
            %% PN =< LargestAcked. Those are the ones this ACK can
            %% decide about; anything newer stays in the tail untouched.
            %% This keeps per-ACK work proportional to the ACK window,
            %% not to the full outstanding queue.
            {AckedList, KeptAccList, AckedBytes, MaxAckEliciting, TailQ} =
                classify_ack_head(
                    (pn(Space, State))#pn_loss.sent_q,
                    LargestAcked,
                    AckedRanges,
                    [],
                    [],
                    0,
                    undefined
                ),

            NewState1 = maybe_update_rtt(State, LargestAcked, AckedList, AckDelay, Now),

            %% Phase 2: loss detection over the survivors from phase 1
            %% (KeptAccList is newest-first, reverse to oldest-first so
            %% largest-lost bookkeeping works).
            KeptList = lists:reverse(KeptAccList),
            {LostList, SurvHeadQ, LostBytes, LargestLostSentTime} =
                detect_lost_q(
                    KeptList,
                    loss_delay_rtt(NewState1),
                    LargestAcked,
                    Now,
                    [],
                    queue:new(),
                    0,
                    undefined
                ),

            %% Phase 3: stitch survivors back together with the untouched
            %% tail (packets with PN > LargestAcked).
            NewQ = queue:join(SurvHeadQ, TailQ),

            NewInFlight = max(0, State#loss_state.bytes_in_flight - AckedBytes - LostBytes),
            Settled =
                length([P || #sent_packet{ack_eliciting = true} = P <- AckedList]) +
                    length([P || #sent_packet{ack_eliciting = true} = P <- LostList]),
            PApp = pn(Space, NewState1),
            NewState2 = set_pn(
                Space,
                PApp#pn_loss{
                    sent_q = NewQ,
                    largest_acked = newest(PApp#pn_loss.largest_acked, LargestAcked),
                    ae_in_flight = max(0, PApp#pn_loss.ae_in_flight - Settled)
                },
                NewState1#loss_state{
                    bytes_in_flight = NewInFlight,
                    time_of_last_ack = Now,
                    pto_count = 0
                }
            ),

            LargestAETime =
                case MaxAckEliciting of
                    undefined -> Now;
                    {_AckPN, AckTimeSent} -> AckTimeSent
                end,
            AckMeta = #{
                acked_bytes => AckedBytes,
                largest_ae_time => LargestAETime,
                has_ack_eliciting => MaxAckEliciting =/= undefined,
                lost_bytes => LostBytes,
                largest_lost_sent_time => LargestLostSentTime
            },

            {NewState2, AckedList, LostList, AckMeta}
    end;
on_ack_received(
    Space, State, {ack_ecn, LargestAcked, AckDelay, FirstRange, AckRanges, _, _, _}, Now
) ->
    on_ack_received(Space, State, {ack, LargestAcked, AckDelay, FirstRange, AckRanges}, Now).

%% Pop packets from the head of the queue while PN =< LargestAcked,
%% classifying each as acked (in ranges) or kept-unacked.
%% Returns {AckedList, KeptAccList (newest-first), AckedBytes,
%%          MaxAckEliciting, TailQ} where TailQ is the remainder of
%% the sent queue that was never touched (PN > LargestAcked or empty).
classify_ack_head(Q, LargestAcked, Ranges, AckedAcc, KeptAcc, AckedBytes, MaxAE) ->
    case queue:out(Q) of
        {empty, _} ->
            {AckedAcc, KeptAcc, AckedBytes, MaxAE, Q};
        {{value, #sent_packet{pn = PN}}, _Q1} when PN > LargestAcked ->
            %% Stop: this packet (and everything after) can't be decided
            %% by this ACK. Push back and return Q unchanged.
            {AckedAcc, KeptAcc, AckedBytes, MaxAE, Q};
        {{value, #sent_packet{pn = PN, size = Size, ack_eliciting = AE, time_sent = TS} = P}, Q1} ->
            case pn_in_ranges(PN, Ranges) of
                true ->
                    {NewBytes, NewMaxAE} = update_acked_stats(
                        AE, Size, PN, TS, AckedBytes, MaxAE
                    ),
                    classify_ack_head(
                        Q1, LargestAcked, Ranges, [P | AckedAcc], KeptAcc, NewBytes, NewMaxAE
                    );
                false ->
                    classify_ack_head(
                        Q1, LargestAcked, Ranges, AckedAcc, [P | KeptAcc], AckedBytes, MaxAE
                    )
            end
    end.

%% Look up the largest-acked ack-eliciting packet's time_sent in the
%% acked list, if present. Used only to drive the RTT sample update.
maybe_update_rtt(State, LargestAcked, AckedList, AckDelay, Now) ->
    case lists:keyfind(LargestAcked, #sent_packet.pn, AckedList) of
        #sent_packet{ack_eliciting = true, time_sent = TS} ->
            LatestRTT = Now - TS,
            AckDelayMs = ack_delay_to_ms(AckDelay, State),
            update_rtt(State, LatestRTT, AckDelayMs);
        _ ->
            State
    end.

%%====================================================================
%% Loss Detection
%%====================================================================

%% @doc Detect lost packets based on time and packet thresholds.
%% Scans the sent queue head-to-tail (oldest first) and splits into
%% {Lost, Surviving}. Returns the new loss_state and the lost packets.
-spec detect_lost_packets(space(), loss_state(), non_neg_integer()) ->
    {loss_state(), [#sent_packet{}]}.
detect_lost_packets(
    Space,
    #loss_state{} = State,
    LargestAcked
) ->
    P = pn(Space, State),
    Now = erlang:monotonic_time(millisecond),
    SentList = queue:to_list(P#pn_loss.sent_q),
    %% RFC 9002 §6.1.2: the time threshold uses max(smoothed_rtt,
    %% latest_rtt). With the EWMA alone, an RTT spike that outruns it
    %% (receiver queueing, bufferbloat) mass-declares in-flight packets
    %% lost while their ACKs are merely late; each spurious loss both
    %% retransmits data and collapses the congestion window.
    RTT = loss_delay_rtt(State),
    {LostPackets, SurvQ, LostBytes, _LargestLostSentTime} =
        detect_lost_q(SentList, RTT, LargestAcked, Now, [], queue:new(), 0, undefined),
    LostAE = length([L || #sent_packet{ack_eliciting = true} = L <- LostPackets]),
    NewState = set_pn(
        Space,
        P#pn_loss{
            sent_q = SurvQ,
            ae_in_flight = max(0, P#pn_loss.ae_in_flight - LostAE)
        },
        State#loss_state{
            bytes_in_flight = max(0, State#loss_state.bytes_in_flight - LostBytes)
        }
    ),
    {NewState, LostPackets}.

%% Core loss-detection walk over an oldest-first list of sent packets.
%% Returns {LostList, SurvivingQ, LostBytes, LargestLostSentTime} where
%% LargestLostSentTime is the time_sent of the highest-PN lost packet
%% (used by the CC congestion-event reporter).
detect_lost_q([], _SRTT, _LargestAcked, _Now, LostAcc, SurvQ, LostBytes, LargestLost) ->
    {LostAcc, SurvQ, LostBytes, largest_lost_ts(LargestLost)};
detect_lost_q(
    [#sent_packet{pn = PN} = P | Rest], _SRTT, LargestAcked, _Now, LostAcc, SurvQ, LostBytes, LL
) when
    PN >= LargestAcked
->
    %% PN >= LargestAcked: can't be declared lost yet. Keep this and
    %% every subsequent packet (they are newer still).
    SurvQ1 = lists:foldl(fun queue:in/2, queue:in(P, SurvQ), Rest),
    {LostAcc, SurvQ1, LostBytes, largest_lost_ts(LL)};
detect_lost_q(
    [
        #sent_packet{
            pn = PN, size = Size, in_flight = true, ack_eliciting = AE, time_sent = TS
        } = P
        | Rest
    ],
    SRTT,
    LargestAcked,
    Now,
    LostAcc,
    SurvQ,
    LostBytes,
    LL
) ->
    LossDelay = max(trunc(?TIME_THRESHOLD * SRTT), ?GRANULARITY),
    LossThreshold = LargestAcked - ?PACKET_THRESHOLD + 1,
    %% >=, not >: get_loss_time_and_space/1 arms the timer for exactly
    %% TS + LossDelay, so detection has to declare at that instant or
    %% the timer re-arms at zero and spins until the clock moves.
    case (PN < LossThreshold) orelse ((Now - TS) >= LossDelay) of
        true ->
            NewBytes =
                case AE of
                    true -> LostBytes + Size;
                    false -> LostBytes
                end,
            %% Only ack-eliciting losses drive the congestion event
            %% (largest_lost_sent_time feeds on_congestion_event). A lost
            %% non-ack-eliciting packet, a PMTU probe in particular, is
            %% not a congestion signal (RFC 9000 §14.4).
            NewLL =
                case AE of
                    false ->
                        LL;
                    true ->
                        case LL of
                            undefined -> {PN, TS};
                            {OldPN, _} when PN > OldPN -> {PN, TS};
                            _ -> LL
                        end
                end,
            detect_lost_q(Rest, SRTT, LargestAcked, Now, [P | LostAcc], SurvQ, NewBytes, NewLL);
        false ->
            detect_lost_q(
                Rest, SRTT, LargestAcked, Now, LostAcc, queue:in(P, SurvQ), LostBytes, LL
            )
    end;
detect_lost_q(
    [#sent_packet{} = P | Rest], SRTT, LargestAcked, Now, LostAcc, SurvQ, LostBytes, LL
) ->
    %% Not in_flight (defensive, shouldn't happen for queue-managed packets).
    detect_lost_q(Rest, SRTT, LargestAcked, Now, LostAcc, queue:in(P, SurvQ), LostBytes, LL).

largest_lost_ts(undefined) -> undefined;
largest_lost_ts({_PN, TS}) -> TS.

%% @doc Get the loss time for setting timers.
-spec get_loss_time_and_space(loss_state()) -> {non_neg_integer(), space()} | none.
get_loss_time_and_space(#loss_state{} = State) ->
    LossDelay = max(trunc(?TIME_THRESHOLD * loss_delay_rtt(State)), ?GRANULARITY),
    lists:foldl(
        fun(Space, Best) -> earlier_loss(space_loss_time(Space, State, LossDelay), Best) end,
        none,
        [initial, handshake, app]
    ).

%% RFC 9002 Appendix A.10: only a packet an acknowledgement has already
%% overtaken can be declared lost on time. Until one has, nothing in the
%% space has a deadline, and it is the probe timer's job rather than
%% this one's.
space_loss_time(Space, State, LossDelay) ->
    case pn(Space, State) of
        #pn_loss{largest_acked = undefined} ->
            none;
        #pn_loss{largest_acked = LargestAcked, sent_q = Q} ->
            %% Oldest first, packet numbers rising with the queue, and
            %% every entry in flight: the head is the only candidate.
            case queue:peek(Q) of
                {value, #sent_packet{pn = PN, time_sent = TS}} when PN < LargestAcked ->
                    {TS + LossDelay, Space};
                _ ->
                    none
            end
    end.

earlier_loss(none, Best) -> Best;
earlier_loss(Candidate, none) -> Candidate;
earlier_loss({T1, _} = C, {T2, _}) when T1 < T2 -> C;
earlier_loss(_C, Best) -> Best.

%%====================================================================
%% RTT Estimation (RFC 9002 Section 5)
%%====================================================================

%% @doc Update RTT estimates with a new sample.
-spec update_rtt(loss_state(), non_neg_integer(), non_neg_integer()) -> loss_state().
update_rtt(
    #loss_state{rtt = RTT, max_ack_delay = MaxAckDelay, handshake_confirmed = Confirmed} = State,
    LatestRTT,
    AckDelay0
) ->
    %% RFC 9002 Section 5.3: cap the peer's reported delay at its
    %% max_ack_delay only once the handshake is confirmed. How much to
    %% subtract is decided here; the estimator is told the result.
    AckDelay =
        case Confirmed of
            true -> min(AckDelay0, MaxAckDelay);
            false -> AckDelay0
        end,
    State#loss_state{rtt = quic_rtt:update(RTT, LatestRTT, AckDelay)}.

%% RFC 9002 Section 6.1.2: the time threshold uses max(smoothed_rtt,
%% latest_rtt). With the EWMA alone, an RTT spike that outruns it
%% mass-declares in-flight packets lost while their acknowledgements are
%% merely late, and each spurious loss both retransmits and collapses the
%% congestion window.
loss_delay_rtt(#loss_state{rtt = RTT}) ->
    max(quic_rtt:smoothed(RTT), quic_rtt:latest(RTT)).

%% @doc The highest packet number acknowledged in a space, or 0 before
%% anything has been.
-spec largest_acked(loss_state(), space()) -> non_neg_integer().
largest_acked(#loss_state{} = State, Space) ->
    case (pn(Space, State))#pn_loss.largest_acked of
        undefined -> 0;
        LargestAcked -> LargestAcked
    end.

%% @doc The path's RTT estimate, read through quic_rtt.
-spec rtt(loss_state()) -> quic_rtt:state().
rtt(#loss_state{rtt = RTT}) -> RTT.

%%====================================================================
%% Probe Timeout (RFC 9002 Section 6.2)
%%====================================================================

%% @doc Drop a packet number space whose keys are gone (RFC 9002
%% Appendix A.11). Returns the bytes removed so the caller can subtract
%% the same amount from congestion control, which keeps its own count.
%%
%% Without this the space keeps its packets in flight forever: nothing
%% can acknowledge them, so they hold the connection's in-flight byte
%% count above zero and keep winning the probe selector.
-spec discard_space(space(), loss_state()) -> {loss_state(), non_neg_integer()}.
discard_space(Space, #loss_state{bytes_in_flight = InFlight} = State) ->
    P = pn(Space, State),
    Bytes = lists:sum([
        Sz
     || #sent_packet{size = Sz, in_flight = true} <- queue:to_list(P#pn_loss.sent_q)
    ]),
    Cleared = set_pn(
        Space,
        #pn_loss{},
        State#loss_state{bytes_in_flight = max(0, InFlight - Bytes), pto_count = 0}
    ),
    {Cleared, Bytes}.

%% @doc Reset recovery state after a Retry (RFC 9002 Section 6.3), and
%% hand back the packets that were in flight so the caller can decide
%% what to resend.
%%
%% They come back keyed by space: #sent_packet{} carries no space and
%% packet numbers restart in each one, so a flat list could not tell an
%% Initial packet from a 0-RTT one. Only the application entry is worth
%% replaying; the Initial flight is rebuilt from the retained TLS state
%% with the Retry token in it, so replaying it from here too would send
%% the ClientHello twice.
%%
%% The RTT estimate goes back to its default rather than adopting the
%% Initial-to-Retry sample, which RFC 9002 permits but does not require.
-spec reset_for_retry(loss_state(), integer()) ->
    {loss_state(), #{space() => [#sent_packet{}]}}.
reset_for_retry(#loss_state{} = State, _Now) ->
    Discarded = maps:from_list([
        {Space, queue:to_list((pn(Space, State))#pn_loss.sent_q)}
     || Space <- [initial, handshake, app]
    ]),
    Reset = State#loss_state{
        initial = #pn_loss{},
        handshake = #pn_loss{},
        app = #pn_loss{},
        rtt = quic_rtt:reset(State#loss_state.rtt),
        pto_count = 0,
        bytes_in_flight = 0,
        outstanding_since = undefined,
        time_of_last_ack = undefined
    },
    {Reset, Discarded}.

%% @doc The PTO for one packet number space. max_ack_delay applies only
%% to Application Data: the peer is expected not to delay Initial or
%% Handshake acknowledgements (RFC 9002 Section 6.2.1).
-spec get_pto(loss_state(), space()) -> non_neg_integer().
get_pto(#loss_state{max_ack_delay = MaxAckDelay} = State, app) ->
    pto(State, MaxAckDelay);
get_pto(#loss_state{} = State, Space) when Space =:= initial; Space =:= handshake ->
    pto(State, 0).

%% @doc RFC 9002 Appendix A.8 GetPtoTimeAndSpace: the earliest probe
%% deadline and the space it belongs to, as an absolute monotonic
%% millisecond time, or `none' when no probe should be armed.
%%
%% Two rules here carry the weight. With nothing ack-eliciting in flight
%% anywhere the peer cannot have completed address validation, so an
%% anti-deadlock probe is armed from now to keep the client sending;
%% that is the client's job, and a server blocked at its amplification
%% limit is stopped before this by the caller. And Application Data is
%% skipped entirely until the handshake is confirmed, which Section
%% 6.2.1 makes a MUST NOT rather than a preference.
-spec get_pto_time_and_space(loss_state(), integer(), #handshake_status{}) ->
    {integer(), space()} | none.
get_pto_time_and_space(#loss_state{} = State, Now, #handshake_status{} = HS) ->
    case total_ae_in_flight(State) of
        0 ->
            anti_deadlock_pto(State, Now, HS);
        _ ->
            earliest_pto(State, [initial, handshake, app], none)
    end.

anti_deadlock_pto(_State, _Now, #handshake_status{peer_completed_address_validation = true}) ->
    none;
anti_deadlock_pto(State, Now, #handshake_status{has_handshake_keys = true}) ->
    {Now + get_pto(State, handshake), handshake};
anti_deadlock_pto(State, Now, #handshake_status{}) ->
    {Now + get_pto(State, initial), initial}.

earliest_pto(_State, [], Best) ->
    Best;
earliest_pto(#loss_state{handshake_confirmed = false}, [app | _Rest], Best) ->
    %% RFC 9002 Section 6.2.1: stop before Application Data while the
    %% handshake is unconfirmed rather than skipping past it.
    Best;
earliest_pto(State, [Space | Rest], Best) ->
    case pn(Space, State) of
        #pn_loss{ae_in_flight = 0} ->
            earliest_pto(State, Rest, Best);
        #pn_loss{last_ae_sent = undefined} ->
            earliest_pto(State, Rest, Best);
        #pn_loss{last_ae_sent = Sent} ->
            earliest_pto(State, Rest, earlier({Sent + get_pto(State, Space), Space}, Best))
    end.

earlier(Candidate, none) -> Candidate;
earlier({T1, _} = C, {T2, _}) when T1 < T2 -> C;
earlier(_C, Best) -> Best.

total_ae_in_flight(#loss_state{initial = I, handshake = H, app = A}) ->
    I#pn_loss.ae_in_flight + H#pn_loss.ae_in_flight + A#pn_loss.ae_in_flight.

%% @doc The PTO the persistent congestion window is built from
%% (RFC 9002 Section 7.6.1): max_ack_delay whatever the packet number space,
%% and no backoff, so the window does not widen during the blackout it is
%% meant to detect.
-spec persistent_congestion_pto(loss_state()) -> non_neg_integer().
persistent_congestion_pto(#loss_state{
    rtt = RTT, max_ack_delay = MaxAckDelay
}) ->
    quic_rtt:smoothed(RTT) + max(4 * quic_rtt:var(RTT), ?GRANULARITY) + MaxAckDelay.

pto(#loss_state{rtt = RTT, pto_count = PTOCount}, MaxAckDelay) ->
    PTO = quic_rtt:smoothed(RTT) + max(4 * quic_rtt:var(RTT), ?GRANULARITY) + MaxAckDelay,
    %% Exponential backoff
    %% Exponential backoff, capped: uncapped doubling reaches tens of
    %% seconds after a loss streak, and a probe that arrives after the
    %% peer's patience is a probe that never happened. Probes are tiny,
    %% so a bounded worst-case interval costs nothing while keeping
    %% recovery inside real-world request timeouts.
    min(PTO bsl PTOCount, ?MAX_PTO_MS).

%% @doc Adopt the peer's ack_delay_exponent and max_ack_delay (ms), from
%% its transport parameters.
-spec set_peer_ack_params(loss_state(), non_neg_integer(), non_neg_integer()) -> loss_state().
set_peer_ack_params(#loss_state{} = State, Exponent, MaxAckDelay) ->
    State#loss_state{ack_delay_exponent = Exponent, max_ack_delay = MaxAckDelay}.

%% @doc Mark the handshake confirmed (RFC 9001 Section 4.1.2), from which
%% point max_ack_delay caps RTT samples and joins the PTO.
-spec on_handshake_confirmed(loss_state()) -> loss_state().
on_handshake_confirmed(#loss_state{} = State) ->
    State#loss_state{handshake_confirmed = true}.

%% @doc Handle PTO expiration.
-spec on_pto_expired(loss_state()) -> loss_state().
on_pto_expired(#loss_state{pto_count = Count} = State) ->
    State#loss_state{pto_count = Count + 1}.

%%====================================================================
%% Queries
%%====================================================================

%% @doc The packets still unacked in one space, keyed by packet number.
%% Built on demand from the queue; for tests and diagnostics, not the hot
%% path. Keyed per space because packet numbers restart in each one.
-spec sent_packets(space(), loss_state()) -> #{non_neg_integer() => #sent_packet{}}.
sent_packets(Space, #loss_state{} = State) ->
    Q = (pn(Space, State))#pn_loss.sent_q,
    maps:from_list([{P#sent_packet.pn, P} || P <- queue:to_list(Q)]).

%% @doc Get bytes currently in flight.
-spec bytes_in_flight(loss_state()) -> non_neg_integer().
bytes_in_flight(#loss_state{bytes_in_flight = B}) -> B.

%% @doc Get current PTO count.
-spec pto_count(loss_state()) -> non_neg_integer().
pto_count(#loss_state{pto_count = C}) -> C.

%% @doc Latest sign of forward progress for the disconnect timeout: the
%% last received ACK, or the start of the current outstanding burst,
%% whichever is later. undefined until either has happened.
-spec last_progress(loss_state()) -> non_neg_integer() | undefined.
last_progress(#loss_state{time_of_last_ack = undefined, outstanding_since = O}) -> O;
last_progress(#loss_state{time_of_last_ack = A, outstanding_since = undefined}) -> A;
last_progress(#loss_state{time_of_last_ack = A, outstanding_since = O}) -> max(A, O).

%% @doc Get the oldest unacked packet (for PTO probe selection).
%% Returns {ok, #sent_packet{}} or none. Head of the sent queue is
%% by construction the oldest in-flight packet.
-spec oldest_unacked(space(), loss_state()) -> {ok, #sent_packet{}} | none.
oldest_unacked(Space, #loss_state{} = State) ->
    Q = (pn(Space, State))#pn_loss.sent_q,
    case queue:peek(Q) of
        empty -> none;
        {value, Packet} -> {ok, Packet}
    end.

%% @doc Whether the handshake has been confirmed (RFC 9001 Section 4.1.2).
-spec handshake_confirmed(loss_state()) -> boolean().
handshake_confirmed(#loss_state{handshake_confirmed = Confirmed}) -> Confirmed.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Update acked bytes + track the largest ack-eliciting acked PN so
%% the caller can derive an RTT sample from that packet's time_sent.
%% Non-ack-eliciting packets don't contribute to bytes_in_flight, so
%% we also don't count them toward acked bytes here.
update_acked_stats(true, Size, PN, TimeSent, BytesAcc, undefined) ->
    {BytesAcc + Size, {PN, TimeSent}};
update_acked_stats(true, Size, PN, TimeSent, BytesAcc, {OldPN, _}) when PN > OldPN ->
    {BytesAcc + Size, {PN, TimeSent}};
update_acked_stats(true, Size, _PN, _TimeSent, BytesAcc, MaxAE) ->
    {BytesAcc + Size, MaxAE};
update_acked_stats(false, _Size, _PN, _TimeSent, BytesAcc, MaxAE) ->
    {BytesAcc, MaxAE}.

%% Check if a packet number is in any of the acknowledged ranges.
%% Ranges is a list of {Start, End} tuples where Start =< End,
%% sorted in descending order (highest PN first).
pn_in_ranges(_PN, []) ->
    false;
pn_in_ranges(PN, [{Start, End} | _Rest]) when PN >= Start, PN =< End ->
    true;
pn_in_ranges(PN, [{_Start, End} | _Rest]) when PN > End ->
    %% Early exit: ranges are sorted descending, so if PN > End of current range,
    %% it can't be in any subsequent range (they all have lower End values)
    false;
pn_in_ranges(PN, [_Range | Rest]) ->
    pn_in_ranges(PN, Rest).

%% Convert encoded ACK delay to milliseconds
ack_delay_to_ms(AckDelay, #loss_state{ack_delay_exponent = Exp}) ->
    %% The field counts units of 2^Exp microseconds, Exp being the
    %% peer's ack_delay_exponent (RFC 9000 Section 19.3).
    (AckDelay bsl Exp) div 1000.

%%====================================================================
%% Retransmission Helpers
%%====================================================================

%% @doc Filter frames to get only retransmittable ones.
%% Per RFC 9002, PADDING, ACK, and CONNECTION_CLOSE frames are not retransmitted.
-spec retransmittable_frames([term()]) -> [term()].
retransmittable_frames(Frames) ->
    lists:filter(fun is_retransmittable/1, Frames).

%% True if any in-flight sent packet carries STREAM data for StreamId that
%% starts before ReliableSize. Data at/after ReliableSize is never retransmitted
%% for a RESET_STREAM_AT stream, so it does not gate the reliable obligation.
-spec stream_has_unacked_below(loss_state(), non_neg_integer(), non_neg_integer()) ->
    boolean().
stream_has_unacked_below(#loss_state{} = State, StreamId, ReliableSize) ->
    Q = (pn(app, State))#pn_loss.sent_q,
    lists:any(
        fun(#sent_packet{frames = Fs}) ->
            lists:any(
                fun
                    ({stream, S, Off, _Data, _Fin}) ->
                        S =:= StreamId andalso Off < ReliableSize;
                    (_) ->
                        false
                end,
                Fs
            )
        end,
        queue:to_list(Q)
    ).

%% Check if a frame is retransmittable
is_retransmittable(padding) -> false;
is_retransmittable({padding, _}) -> false;
is_retransmittable({ack, _, _, _}) -> false;
is_retransmittable({ack, _, _, _, _}) -> false;
is_retransmittable({ack_ecn, _, _, _, _, _, _, _}) -> false;
is_retransmittable({connection_close, _, _, _, _}) -> false;
%% DATAGRAM frames (RFC 9221) are unreliable and never retransmitted
is_retransmittable({datagram, _}) -> false;
is_retransmittable({datagram_with_length, _}) -> false;
is_retransmittable(_) -> true.
