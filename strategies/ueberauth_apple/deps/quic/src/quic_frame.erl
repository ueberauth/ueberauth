%%% -*- erlang -*-
%%%
%%% QUIC Frame Encoding/Decoding
%%% RFC 9000 Section 12
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC frame encoding and decoding.
%%%
%%% This module handles encoding and decoding of all 21 QUIC frame types
%%% as defined in RFC 9000 Section 12.4.
%%%

-module(quic_frame).

-include("quic.hrl").

-export([
    encode/1,
    encode_iodata/1,
    decode/1,
    decode_all/1
]).

-export_type([frame/0]).

%% Frame types
-type frame() ::
    padding
    | ping
    | {ack, AckRanges :: [{non_neg_integer(), non_neg_integer()}], AckDelay :: non_neg_integer(),
        ECNCounts :: ecn_counts() | undefined}
    | {reset_stream, StreamId :: non_neg_integer(), ErrorCode :: non_neg_integer(),
        FinalSize :: non_neg_integer()}
    | {reset_stream_at, StreamId :: non_neg_integer(), ErrorCode :: non_neg_integer(),
        FinalSize :: non_neg_integer(), ReliableSize :: non_neg_integer()}
    | {stop_sending, StreamId :: non_neg_integer(), ErrorCode :: non_neg_integer()}
    | {crypto, Offset :: non_neg_integer(), Data :: binary()}
    | {new_token, Token :: binary()}
    | {stream, StreamId :: non_neg_integer(), Offset :: non_neg_integer(), Data :: binary(),
        Fin :: boolean()}
    | {max_data, MaxData :: non_neg_integer()}
    | {max_stream_data, StreamId :: non_neg_integer(), MaxData :: non_neg_integer()}
    | {max_streams, bidi | uni, MaxStreams :: non_neg_integer()}
    | {data_blocked, Limit :: non_neg_integer()}
    | {stream_data_blocked, StreamId :: non_neg_integer(), Limit :: non_neg_integer()}
    | {streams_blocked, bidi | uni, Limit :: non_neg_integer()}
    | {new_connection_id, SeqNum :: non_neg_integer(), RetirePrior :: non_neg_integer(),
        CID :: binary(), StatelessResetToken :: binary()}
    | {retire_connection_id, SeqNum :: non_neg_integer()}
    | {path_challenge, Data :: binary()}
    | {path_response, Data :: binary()}
    | {connection_close, transport | application, ErrorCode :: non_neg_integer(),
        FrameType :: non_neg_integer() | undefined, Reason :: binary()}
    | handshake_done
    | {datagram, Data :: binary()}
    | {datagram_with_length, Data :: binary()}.

-type ecn_counts() :: {
    ECT0 :: non_neg_integer(), ECT1 :: non_neg_integer(), ECNCE :: non_neg_integer()
}.

%% Maximum frame data length to prevent memory exhaustion
-define(MAX_FRAME_DATA_LEN, 65535).

%%====================================================================
%% API
%%====================================================================

%% @doc Encode a frame to binary.
-spec encode(frame()) -> binary().

%% PADDING (0x00)
encode(padding) ->
    <<0>>;
%% PING (0x01)
encode(ping) ->
    <<1>>;
%% ACK (0x02 or 0x03)
encode({ack, Ranges, AckDelay, undefined}) ->
    encode_ack(Ranges, AckDelay, false);
encode({ack, Ranges, AckDelay, {ECT0, ECT1, ECNCE}}) ->
    AckBin = encode_ack(Ranges, AckDelay, true),
    ECNBin = <<
        (quic_varint:encode(ECT0))/binary,
        (quic_varint:encode(ECT1))/binary,
        (quic_varint:encode(ECNCE))/binary
    >>,
    <<AckBin/binary, ECNBin/binary>>;
%% RESET_STREAM (0x04)
encode({reset_stream, StreamId, ErrorCode, FinalSize}) ->
    <<?FRAME_RESET_STREAM, (quic_varint:encode(StreamId))/binary,
        (quic_varint:encode(ErrorCode))/binary, (quic_varint:encode(FinalSize))/binary>>;
%% RESET_STREAM_AT (0x24) - draft-ietf-quic-reliable-stream-reset-07
encode({reset_stream_at, StreamId, ErrorCode, FinalSize, ReliableSize}) ->
    <<?FRAME_RESET_STREAM_AT, (quic_varint:encode(StreamId))/binary,
        (quic_varint:encode(ErrorCode))/binary, (quic_varint:encode(FinalSize))/binary,
        (quic_varint:encode(ReliableSize))/binary>>;
%% STOP_SENDING (0x05)
encode({stop_sending, StreamId, ErrorCode}) ->
    <<?FRAME_STOP_SENDING, (quic_varint:encode(StreamId))/binary,
        (quic_varint:encode(ErrorCode))/binary>>;
%% CRYPTO (0x06)
encode({crypto, Offset, Data}) ->
    <<?FRAME_CRYPTO, (quic_varint:encode(Offset))/binary,
        (quic_varint:encode(byte_size(Data)))/binary, Data/binary>>;
%% NEW_TOKEN (0x07)
encode({new_token, Token}) ->
    <<?FRAME_NEW_TOKEN, (quic_varint:encode(byte_size(Token)))/binary, Token/binary>>;
%% STREAM (0x08-0x0f)
encode({stream, StreamId, Offset, Data, Fin}) ->
    Header = stream_frame_header(StreamId, Offset, byte_size(Data), Fin),
    <<Header/binary, Data/binary>>;
%% MAX_DATA (0x10)
encode({max_data, MaxData}) ->
    <<?FRAME_MAX_DATA, (quic_varint:encode(MaxData))/binary>>;
%% MAX_STREAM_DATA (0x11)
encode({max_stream_data, StreamId, MaxData}) ->
    <<?FRAME_MAX_STREAM_DATA, (quic_varint:encode(StreamId))/binary,
        (quic_varint:encode(MaxData))/binary>>;
%% MAX_STREAMS (0x12 bidi, 0x13 uni)
encode({max_streams, bidi, MaxStreams}) ->
    <<?FRAME_MAX_STREAMS_BIDI, (quic_varint:encode(MaxStreams))/binary>>;
encode({max_streams, uni, MaxStreams}) ->
    <<?FRAME_MAX_STREAMS_UNI, (quic_varint:encode(MaxStreams))/binary>>;
%% DATA_BLOCKED (0x14)
encode({data_blocked, Limit}) ->
    <<?FRAME_DATA_BLOCKED, (quic_varint:encode(Limit))/binary>>;
%% STREAM_DATA_BLOCKED (0x15)
encode({stream_data_blocked, StreamId, Limit}) ->
    <<?FRAME_STREAM_DATA_BLOCKED, (quic_varint:encode(StreamId))/binary,
        (quic_varint:encode(Limit))/binary>>;
%% STREAMS_BLOCKED (0x16 bidi, 0x17 uni)
encode({streams_blocked, bidi, Limit}) ->
    <<?FRAME_STREAMS_BLOCKED_BIDI, (quic_varint:encode(Limit))/binary>>;
encode({streams_blocked, uni, Limit}) ->
    <<?FRAME_STREAMS_BLOCKED_UNI, (quic_varint:encode(Limit))/binary>>;
%% NEW_CONNECTION_ID (0x18)
encode({new_connection_id, SeqNum, RetirePrior, CID, StatelessResetToken}) when
    byte_size(StatelessResetToken) =:= 16
->
    CIDLen = byte_size(CID),
    <<?FRAME_NEW_CONNECTION_ID, (quic_varint:encode(SeqNum))/binary,
        (quic_varint:encode(RetirePrior))/binary, CIDLen, CID/binary, StatelessResetToken/binary>>;
%% RETIRE_CONNECTION_ID (0x19)
encode({retire_connection_id, SeqNum}) ->
    <<?FRAME_RETIRE_CONNECTION_ID, (quic_varint:encode(SeqNum))/binary>>;
%% PATH_CHALLENGE (0x1a)
encode({path_challenge, Data}) when byte_size(Data) =:= 8 ->
    <<?FRAME_PATH_CHALLENGE, Data/binary>>;
%% PATH_RESPONSE (0x1b)
encode({path_response, Data}) when byte_size(Data) =:= 8 ->
    <<?FRAME_PATH_RESPONSE, Data/binary>>;
%% CONNECTION_CLOSE (0x1c transport, 0x1d application)
encode({connection_close, transport, ErrorCode, FrameType, Reason}) ->
    <<?FRAME_CONNECTION_CLOSE, (quic_varint:encode(ErrorCode))/binary,
        (quic_varint:encode(FrameType))/binary, (quic_varint:encode(byte_size(Reason)))/binary,
        Reason/binary>>;
encode({connection_close, application, ErrorCode, _FrameType, Reason}) ->
    <<?FRAME_CONNECTION_CLOSE_APP, (quic_varint:encode(ErrorCode))/binary,
        (quic_varint:encode(byte_size(Reason)))/binary, Reason/binary>>;
%% HANDSHAKE_DONE (0x1e)
encode(handshake_done) ->
    <<?FRAME_HANDSHAKE_DONE>>;
%% DATAGRAM (0x30 - no length, data to end of packet)
encode({datagram, Data}) ->
    <<?FRAME_DATAGRAM, Data/binary>>;
%% DATAGRAM_WITH_LENGTH (0x31 - includes length)
encode({datagram_with_length, Data}) ->
    <<?FRAME_DATAGRAM_WITH_LEN, (quic_varint:encode(byte_size(Data)))/binary, Data/binary>>.

%% @doc Encode a frame as iodata. For STREAM frames with a binary Data
%% this returns `[Header, Data]' without copying the payload into the
%% frame binary, avoiding one full copy per chunk on the bulk-send hot
%% path. For all other frame types (and STREAM with iolist Data) this
%% falls back to `encode/1' wrapped in a list — `iolist_to_binary/1'
%% over the result equals `encode/1' for any frame.
-spec encode_iodata(frame()) -> iodata().
encode_iodata({stream, StreamId, Offset, Data, Fin}) when is_binary(Data) ->
    Header = stream_frame_header(StreamId, Offset, byte_size(Data), Fin),
    [Header, Data];
encode_iodata(Frame) ->
    [encode(Frame)].

%% Build the STREAM frame header (everything before Data). Shared by
%% encode/1 (flat-binary output) and encode_iodata/1 (zero-copy output)
%% so the wire format stays identical.
stream_frame_header(StreamId, Offset, Length, Fin) ->
    Type =
        ?FRAME_STREAM bor
            (case Offset of
                0 -> 0;
                _ -> ?STREAM_FLAG_OFF
            end) bor
            ?STREAM_FLAG_LEN bor
            (case Fin of
                true -> ?STREAM_FLAG_FIN;
                false -> 0
            end),
    OffsetBin =
        case Offset of
            0 -> <<>>;
            _ -> quic_varint:encode(Offset)
        end,
    <<Type, (quic_varint:encode(StreamId))/binary, OffsetBin/binary,
        (quic_varint:encode(Length))/binary>>.

%% @doc Decode a single frame from binary.
%% Returns {Frame, Rest} or {error, Reason}.
-spec decode(binary()) -> {frame(), binary()} | {error, term()}.

decode(<<0, Rest/binary>>) ->
    {padding, Rest};
decode(<<1, Rest/binary>>) ->
    {ping, Rest};
decode(<<2, Rest/binary>>) ->
    ack(Rest, 2);
decode(<<3, Rest/binary>>) ->
    ack(Rest, 3);
decode(<<?FRAME_MAX_DATA, P1:2, MaxData:((8 bsl P1) - 2), Rest/binary>>) ->
    {{max_data, MaxData}, Rest};
decode(
    <<?FRAME_MAX_STREAM_DATA, P1:2, StreamId:((8 bsl P1) - 2), P2:2, MaxData:((8 bsl P2) - 2),
        Rest/binary>>
) ->
    {{max_stream_data, StreamId, MaxData}, Rest};
decode(<<?FRAME_RESET_STREAM, Rest/binary>>) ->
    {StreamId, Rest1} = quic_varint:decode(Rest),
    {ErrorCode, Rest2} = quic_varint:decode(Rest1),
    {FinalSize, Rest3} = quic_varint:decode(Rest2),
    {{reset_stream, StreamId, ErrorCode, FinalSize}, Rest3};
decode(<<?FRAME_RESET_STREAM_AT, Rest/binary>>) ->
    {StreamId, Rest1} = quic_varint:decode(Rest),
    {ErrorCode, Rest2} = quic_varint:decode(Rest1),
    {FinalSize, Rest3} = quic_varint:decode(Rest2),
    {ReliableSize, Rest4} = quic_varint:decode(Rest3),
    {{reset_stream_at, StreamId, ErrorCode, FinalSize, ReliableSize}, Rest4};
decode(<<?FRAME_STOP_SENDING, Rest/binary>>) ->
    {StreamId, Rest1} = quic_varint:decode(Rest),
    {ErrorCode, Rest2} = quic_varint:decode(Rest1),
    {{stop_sending, StreamId, ErrorCode}, Rest2};
decode(<<?FRAME_CRYPTO, Rest/binary>>) ->
    {Offset, Rest1} = quic_varint:decode(Rest),
    {Length, Rest2} = quic_varint:decode(Rest1),
    case Length > ?MAX_FRAME_DATA_LEN of
        true ->
            {error, frame_too_large};
        false ->
            <<Data:Length/binary, Rest3/binary>> = Rest2,
            {{crypto, Offset, Data}, Rest3}
    end;
decode(<<?FRAME_NEW_TOKEN, Rest/binary>>) ->
    {Length, Rest1} = quic_varint:decode(Rest),
    case Length > ?MAX_FRAME_DATA_LEN of
        true ->
            {error, frame_too_large};
        false ->
            <<Token:Length/binary, Rest2/binary>> = Rest1,
            {{new_token, Token}, Rest2}
    end;
decode(<<Type, Rest/binary>>) when Type >= ?FRAME_STREAM, Type =< 16#0f ->
    stream(Type, Rest);
decode(<<?FRAME_MAX_DATA, Rest/binary>>) ->
    {MaxData, Rest1} = quic_varint:decode(Rest),
    {{max_data, MaxData}, Rest1};
decode(<<?FRAME_MAX_STREAM_DATA, Rest/binary>>) ->
    {StreamId, Rest1} = quic_varint:decode(Rest),
    {MaxData, Rest2} = quic_varint:decode(Rest1),
    {{max_stream_data, StreamId, MaxData}, Rest2};
decode(<<?FRAME_MAX_STREAMS_BIDI, Rest/binary>>) ->
    {MaxStreams, Rest1} = quic_varint:decode(Rest),
    {{max_streams, bidi, MaxStreams}, Rest1};
decode(<<?FRAME_MAX_STREAMS_UNI, Rest/binary>>) ->
    {MaxStreams, Rest1} = quic_varint:decode(Rest),
    {{max_streams, uni, MaxStreams}, Rest1};
decode(<<?FRAME_DATA_BLOCKED, Rest/binary>>) ->
    {Limit, Rest1} = quic_varint:decode(Rest),
    {{data_blocked, Limit}, Rest1};
decode(<<?FRAME_STREAM_DATA_BLOCKED, Rest/binary>>) ->
    {StreamId, Rest1} = quic_varint:decode(Rest),
    {Limit, Rest2} = quic_varint:decode(Rest1),
    {{stream_data_blocked, StreamId, Limit}, Rest2};
decode(<<?FRAME_STREAMS_BLOCKED_BIDI, Rest/binary>>) ->
    {Limit, Rest1} = quic_varint:decode(Rest),
    {{streams_blocked, bidi, Limit}, Rest1};
decode(<<?FRAME_STREAMS_BLOCKED_UNI, Rest/binary>>) ->
    {Limit, Rest1} = quic_varint:decode(Rest),
    {{streams_blocked, uni, Limit}, Rest1};
decode(<<?FRAME_NEW_CONNECTION_ID, Rest/binary>>) ->
    {SeqNum, Rest1} = quic_varint:decode(Rest),
    {RetirePrior, Rest2} = quic_varint:decode(Rest1),
    case Rest2 of
        %% RFC 9000 §19.15: connection ID length is 1..20 octets.
        <<CIDLen, Rest3/binary>> when CIDLen >= 1, CIDLen =< 20, byte_size(Rest3) >= CIDLen + 16 ->
            <<CID:CIDLen/binary, StatelessResetToken:16/binary, Rest4/binary>> = Rest3,
            {{new_connection_id, SeqNum, RetirePrior, CID, StatelessResetToken}, Rest4};
        _ ->
            {error, frame_encoding_error}
    end;
decode(<<?FRAME_RETIRE_CONNECTION_ID, Rest/binary>>) ->
    {SeqNum, Rest1} = quic_varint:decode(Rest),
    {{retire_connection_id, SeqNum}, Rest1};
decode(<<?FRAME_PATH_CHALLENGE, Data:8/binary, Rest/binary>>) ->
    {{path_challenge, Data}, Rest};
decode(<<?FRAME_PATH_RESPONSE, Data:8/binary, Rest/binary>>) ->
    {{path_response, Data}, Rest};
decode(<<?FRAME_CONNECTION_CLOSE, Rest/binary>>) ->
    {ErrorCode, Rest1} = quic_varint:decode(Rest),
    {FrameType, Rest2} = quic_varint:decode(Rest1),
    {ReasonLen, Rest3} = quic_varint:decode(Rest2),
    case ReasonLen > ?MAX_FRAME_DATA_LEN of
        true ->
            {error, frame_too_large};
        false ->
            <<Reason:ReasonLen/binary, Rest4/binary>> = Rest3,
            {{connection_close, transport, ErrorCode, FrameType, Reason}, Rest4}
    end;
decode(<<?FRAME_CONNECTION_CLOSE_APP, Rest/binary>>) ->
    {ErrorCode, Rest1} = quic_varint:decode(Rest),
    {ReasonLen, Rest2} = quic_varint:decode(Rest1),
    case ReasonLen > ?MAX_FRAME_DATA_LEN of
        true ->
            {error, frame_too_large};
        false ->
            <<Reason:ReasonLen/binary, Rest3/binary>> = Rest2,
            {{connection_close, application, ErrorCode, undefined, Reason}, Rest3}
    end;
decode(<<?FRAME_HANDSHAKE_DONE, Rest/binary>>) ->
    {handshake_done, Rest};
%% DATAGRAM (0x30 - data extends to end of packet)
decode(<<?FRAME_DATAGRAM, Data/binary>>) ->
    {{datagram, Data}, <<>>};
%% DATAGRAM_WITH_LENGTH (0x31)
decode(<<?FRAME_DATAGRAM_WITH_LEN, Rest/binary>>) ->
    {Length, Rest1} = quic_varint:decode(Rest),
    case Length > ?MAX_FRAME_DATA_LEN of
        true ->
            {error, frame_too_large};
        false ->
            <<Data:Length/binary, Rest2/binary>> = Rest1,
            {{datagram_with_length, Data}, Rest2}
    end;
decode(<<Type, _/binary>>) ->
    {error, {unknown_frame_type, Type}};
decode(<<>>) ->
    {error, empty}.

%% @doc Decode all frames from a packet payload.
%% Returns a list of frames.
-spec decode_all(binary()) -> {ok, [frame()]} | {error, term()}.
decode_all(Bin) ->
    decode_all(Bin, []).

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
decode_all(Bin, Acc) ->
    case decode(Bin) of
        {error, _} = Error ->
            Error;
        {Frame, Rest} ->
            decode_all(Rest, [Frame | Acc])
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

encode_ack(Ranges, AckDelay, WithECN) ->
    Type =
        case WithECN of
            false -> ?FRAME_ACK;
            true -> ?FRAME_ACK_ECN
        end,
    [{LargestAcked, FirstRange} | RestRanges] = Ranges,
    RangeCount = length(RestRanges),
    %% Encode additional ranges
    RangesBin = encode_ack_ranges(Ranges),
    <<Type, (quic_varint:encode(LargestAcked))/binary, (quic_varint:encode(AckDelay))/binary,
        (quic_varint:encode(RangeCount))/binary, (quic_varint:encode(FirstRange))/binary,
        RangesBin/binary>>.

encode_ack_ranges([_First]) ->
    <<>>;
encode_ack_ranges([{_Largest1, _First1}, {Gap, Range} | Rest]) ->
    %% Gap and Range are encoded as-is (adjusted by caller)
    <<
        (quic_varint:encode(Gap))/binary,
        (quic_varint:encode(Range))/binary,
        (encode_ack_ranges([{0, 0} | Rest]))/binary
    >>;
encode_ack_ranges([_First, _ | _] = Ranges) ->
    %% For simplicity, encode remaining ranges
    encode_ack_ranges_tail(tl(Ranges)).

encode_ack_ranges_tail([]) ->
    <<>>;
encode_ack_ranges_tail([{Gap, Range} | Rest]) ->
    <<
        (quic_varint:encode(Gap))/binary,
        (quic_varint:encode(Range))/binary,
        (encode_ack_ranges_tail(Rest))/binary
    >>.

decode_ack(Bin, WithECN) ->
    {LargestAcked, Rest1} = quic_varint:decode(Bin),
    {AckDelay, Rest2} = quic_varint:decode(Rest1),
    {RangeCount, Rest3} = quic_varint:decode(Rest2),
    {FirstRange, Rest4} = quic_varint:decode(Rest3),
    {RestRanges, Rest5} = decode_ack_ranges(RangeCount, Rest4),
    Ranges = [{LargestAcked, FirstRange} | RestRanges],
    case WithECN of
        false ->
            {{ack, Ranges, AckDelay, undefined}, Rest5};
        true ->
            {ECT0, Rest6} = quic_varint:decode(Rest5),
            {ECT1, Rest7} = quic_varint:decode(Rest6),
            {ECNCE, Rest8} = quic_varint:decode(Rest7),
            {{ack, Ranges, AckDelay, {ECT0, ECT1, ECNCE}}, Rest8}
    end.

%% Hot frames: each varint is matched in the head (RFC 9000 §16: a 2-bit
%% prefix P gives 6, 14, 30 or 62 value bits), which keeps the match
%% context where quic_varint:decode/1 builds a tuple and a sub-binary
%% per field. Input the fast clauses do not match (truncated, oversized)
%% goes to the field-by-field decoder, which keeps its error behaviour.
stream(
    Type,
    <<P1:2, StreamId:((8 bsl P1) - 2), P2:2, Offset:((8 bsl P2) - 2), P3:2, Len:((8 bsl P3) - 2),
        Data:Len/binary, Rest/binary>>
) when (Type band 16#fe) =:= 16#0e, Len =< ?MAX_FRAME_DATA_LEN ->
    stream_frame(Type, StreamId, Offset, Data, Rest);
stream(
    Type,
    <<P1:2, StreamId:((8 bsl P1) - 2), P2:2, Len:((8 bsl P2) - 2), Data:Len/binary, Rest/binary>>
) when
    (Type band 16#fe) =:= 16#0a, Len =< ?MAX_FRAME_DATA_LEN
->
    stream_frame(Type, StreamId, 0, Data, Rest);
stream(Type, <<P1:2, StreamId:((8 bsl P1) - 2), P2:2, Offset:((8 bsl P2) - 2), Data/binary>>) when
    (Type band 16#fe) =:= 16#0c
->
    stream_frame(Type, StreamId, Offset, Data, <<>>);
stream(Type, <<P1:2, StreamId:((8 bsl P1) - 2), Data/binary>>) when (Type band 16#fe) =:= 16#08 ->
    stream_frame(Type, StreamId, 0, Data, <<>>);
stream(Type, <<Rest/binary>>) ->
    stream_generic(Type, Rest).

stream_frame(Type, StreamId, Offset, Data, Rest) ->
    {{stream, StreamId, Offset, Data, (Type band 1) =:= 1}, Rest}.

stream_generic(Type, Rest) ->
    HasOff = (Type band ?STREAM_FLAG_OFF) =/= 0,
    HasLen = (Type band ?STREAM_FLAG_LEN) =/= 0,
    Fin = (Type band ?STREAM_FLAG_FIN) =/= 0,
    {StreamId, Rest1} = quic_varint:decode(Rest),
    {Offset, Rest2} =
        case HasOff of
            true -> quic_varint:decode(Rest1);
            false -> {0, Rest1}
        end,
    case HasLen of
        true ->
            {Length, R} = quic_varint:decode(Rest2),
            case Length > ?MAX_FRAME_DATA_LEN of
                true ->
                    {error, frame_too_large};
                false ->
                    <<D:Length/binary, R2/binary>> = R,
                    {{stream, StreamId, Offset, D, Fin}, R2}
            end;
        false ->
            %% Data extends to end of packet
            {{stream, StreamId, Offset, Rest2, Fin}, <<>>}
    end.

ack(
    <<P1:2, Largest:((8 bsl P1) - 2), P2:2, Delay:((8 bsl P2) - 2), P3:2, Count:((8 bsl P3) - 2),
        P4:2, First:((8 bsl P4) - 2), Rest/binary>>,
    Type
) ->
    ack_ranges(Rest, Count, [{Largest, First}], Delay, Type);
ack(<<Rest/binary>>, Type) ->
    decode_ack(Rest, Type =:= 3).

%% ACK ranges, then the ECN counts for type 0x03, all in one match context.
ack_ranges(
    <<P1:2, Gap:((8 bsl P1) - 2), P2:2, Range:((8 bsl P2) - 2), Rest/binary>>, N, Acc, Delay, Type
) when N > 0 ->
    ack_ranges(Rest, N - 1, [{Gap, Range} | Acc], Delay, Type);
ack_ranges(<<Rest/binary>>, 0, Acc, Delay, 2) ->
    {{ack, lists:reverse(Acc), Delay, undefined}, Rest};
ack_ranges(
    <<P1:2, ECT0:((8 bsl P1) - 2), P2:2, ECT1:((8 bsl P2) - 2), P3:2, ECNCE:((8 bsl P3) - 2),
        Rest/binary>>,
    0,
    Acc,
    Delay,
    3
) ->
    {{ack, lists:reverse(Acc), Delay, {ECT0, ECT1, ECNCE}}, Rest};
ack_ranges(<<Bin/binary>>, N, _Acc, _Delay, _Type) ->
    %% Truncated: raise what the field-by-field decoder raises.
    {_, Rest1} = quic_varint:decode(Bin),
    {_, Rest2} = quic_varint:decode(Rest1),
    _ = N > 0 orelse quic_varint:decode(Rest2),
    error(badarg).

decode_ack_ranges(0, Bin) ->
    {[], Bin};
decode_ack_ranges(N, Bin) ->
    {Gap, Rest1} = quic_varint:decode(Bin),
    {Range, Rest2} = quic_varint:decode(Rest1),
    {RestRanges, Rest3} = decode_ack_ranges(N - 1, Rest2),
    {[{Gap, Range} | RestRanges], Rest3}.
