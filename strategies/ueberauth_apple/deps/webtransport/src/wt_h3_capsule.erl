%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc HTTP/3 WebTransport capsules and stream/datagram headers.
%%
%% HTTP/3 WebTransport uses:
%% - capsules on the CONNECT stream for session control and flow control
%% - native QUIC stream headers for data streams
%% - HTTP Datagram framing for unreliable datagrams
%%
-module(wt_h3_capsule).

-export([encode/1, decode/1, decode_all/1]).
-export([type_name/1]).

%% Capsule constructors
-export([max_data/1, data_blocked/1]).
-export([max_streams_bidi/1, max_streams_uni/1]).
-export([streams_blocked_bidi/1, streams_blocked_uni/1]).
-export([close_session/1, close_session/2, drain_session/0]).

%% Native stream helpers
-export([encode_uni_stream_header/1, encode_bidi_stream_header/1]).
-export([decode_stream_header/1]).

%% HTTP Datagram helpers
-export([encode_datagram/2, decode_datagram/1]).
-export([quarter_stream_id/1, session_id_from_quarter_stream_id/1]).

-include("webtransport.hrl").

-type capsule() ::
    {max_data, non_neg_integer()} |
    {data_blocked, non_neg_integer()} |
    {max_streams_bidi, non_neg_integer()} |
    {max_streams_uni, non_neg_integer()} |
    {streams_blocked_bidi, non_neg_integer()} |
    {streams_blocked_uni, non_neg_integer()} |
    {close_session, non_neg_integer(), binary()} |
    {drain_session} |
    {unknown, non_neg_integer(), binary()}.

-type stream_kind() :: bidi | uni.

-export_type([capsule/0, stream_kind/0]).

%% ============================================================================
%% Constructors
%% ============================================================================

%% @doc Construct a MAX_DATA capsule with the given connection-level limit.
-spec max_data(non_neg_integer()) -> capsule().
max_data(Limit) ->
    {max_data, Limit}.

%% @doc Construct a DATA_BLOCKED capsule indicating the connection-level limit reached.
-spec data_blocked(non_neg_integer()) -> capsule().
data_blocked(Limit) ->
    {data_blocked, Limit}.

%% @doc Construct a MAX_STREAMS capsule for bidirectional streams.
-spec max_streams_bidi(non_neg_integer()) -> capsule().
max_streams_bidi(Limit) ->
    {max_streams_bidi, Limit}.

%% @doc Construct a MAX_STREAMS capsule for unidirectional streams.
-spec max_streams_uni(non_neg_integer()) -> capsule().
max_streams_uni(Limit) ->
    {max_streams_uni, Limit}.

%% @doc Construct a STREAMS_BLOCKED capsule for bidirectional streams.
-spec streams_blocked_bidi(non_neg_integer()) -> capsule().
streams_blocked_bidi(Limit) ->
    {streams_blocked_bidi, Limit}.

%% @doc Construct a STREAMS_BLOCKED capsule for unidirectional streams.
-spec streams_blocked_uni(non_neg_integer()) -> capsule().
streams_blocked_uni(Limit) ->
    {streams_blocked_uni, Limit}.

%% @doc Construct a CLOSE_SESSION capsule with the given error code and no reason.
-spec close_session(non_neg_integer()) -> capsule().
close_session(ErrorCode) ->
    {close_session, ErrorCode, <<>>}.

%% @doc Construct a CLOSE_SESSION capsule with the given error code and reason.
%% draft-15 §5: the Reason field MUST be at most 1024 UTF-8 bytes.
-spec close_session(non_neg_integer(), binary()) -> capsule() | {error, reason_too_long}.
close_session(_ErrorCode, Reason) when byte_size(Reason) > 1024 ->
    {error, reason_too_long};
close_session(ErrorCode, Reason) ->
    {close_session, ErrorCode, Reason}.

%% @doc Construct a DRAIN_SESSION capsule to signal graceful shutdown.
-spec drain_session() -> capsule().
drain_session() ->
    {drain_session}.

%% ============================================================================
%% Encoding
%% ============================================================================

%% @doc Encode a capsule record into its wire-format binary.
-spec encode(capsule()) -> binary().
encode({max_data, Limit}) ->
    h2_capsule:encode(?WT_MAX_DATA, h2_varint:encode(Limit));
encode({data_blocked, Limit}) ->
    h2_capsule:encode(?WT_DATA_BLOCKED, h2_varint:encode(Limit));
encode({max_streams_bidi, Limit}) ->
    h2_capsule:encode(?WT_MAX_STREAMS_BIDI, h2_varint:encode(Limit));
encode({max_streams_uni, Limit}) ->
    h2_capsule:encode(?WT_MAX_STREAMS_UNI, h2_varint:encode(Limit));
encode({streams_blocked_bidi, Limit}) ->
    h2_capsule:encode(?WT_STREAMS_BLOCKED_BIDI, h2_varint:encode(Limit));
encode({streams_blocked_uni, Limit}) ->
    h2_capsule:encode(?WT_STREAMS_BLOCKED_UNI, h2_varint:encode(Limit));
encode({close_session, ErrorCode, Reason}) ->
    Payload = <<(h2_varint:encode(ErrorCode))/binary, Reason/binary>>,
    h2_capsule:encode(?WT_CLOSE_SESSION_H3, Payload);
encode({drain_session}) ->
    h2_capsule:encode(?WT_DRAIN_SESSION_H3, <<>>).

%% ============================================================================
%% Decoding
%% ============================================================================

%% @doc Decode the first capsule from a binary, returning the capsule and remaining bytes.
-spec decode(binary()) -> {ok, capsule(), binary()} | {more, pos_integer()} | {error, term()}.
decode(Bin) ->
    case h2_capsule:decode(Bin) of
        {ok, {Type, Payload}, Rest} ->
            case decode_payload(Type, Payload) of
                {ok, Capsule} -> {ok, Capsule, Rest};
                {error, _} = Err -> Err
            end;
        {more, N} ->
            {more, N}
    end.

decode_payload(?WT_MAX_DATA, Payload) ->
    decode_limit(max_data, Payload);
decode_payload(?WT_DATA_BLOCKED, Payload) ->
    decode_limit(data_blocked, Payload);
decode_payload(?WT_MAX_STREAMS_BIDI, Payload) ->
    decode_limit(max_streams_bidi, Payload);
decode_payload(?WT_MAX_STREAMS_UNI, Payload) ->
    decode_limit(max_streams_uni, Payload);
decode_payload(?WT_STREAMS_BLOCKED_BIDI, Payload) ->
    decode_limit(streams_blocked_bidi, Payload);
decode_payload(?WT_STREAMS_BLOCKED_UNI, Payload) ->
    decode_limit(streams_blocked_uni, Payload);
decode_payload(?WT_CLOSE_SESSION_H3, Payload) ->
    case h2_varint:decode(Payload) of
        {ok, _ErrorCode, Reason} when byte_size(Reason) > 1024 ->
            {error, reason_too_long};
        {ok, ErrorCode, Reason} ->
            {ok, {close_session, ErrorCode, Reason}};
        {error, _} = Err ->
            Err
    end;
decode_payload(?WT_DRAIN_SESSION_H3, <<>>) ->
    {ok, {drain_session}};
decode_payload(?WT_DRAIN_SESSION_H3, _) ->
    {error, extra_data};
decode_payload(Type, Payload) when is_integer(Type) ->
    {ok, {unknown, Type, Payload}}.

%% @doc Decode all capsules from a binary, returning the list and any trailing bytes.
-spec decode_all(binary()) -> {ok, [capsule()], binary()} | {error, term()}.
decode_all(Bin) ->
    decode_all(Bin, []).

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};
decode_all(Bin, Acc) ->
    case decode(Bin) of
        {ok, Capsule, Rest} ->
            decode_all(Rest, [Capsule | Acc]);
        {more, _} ->
            {ok, lists:reverse(Acc), Bin};
        {error, _} = Err ->
            Err
    end.

decode_limit(Name, Payload) ->
    case h2_varint:decode(Payload) of
        {ok, Limit, <<>>} -> {ok, {Name, Limit}};
        {ok, _, _} -> {error, extra_data};
        {error, _} = Err -> Err
    end.

%% ============================================================================
%% Native Stream Headers
%% ============================================================================

%% @doc Encode a unidirectional WebTransport stream header for the given session.
-spec encode_uni_stream_header(non_neg_integer()) -> binary().
encode_uni_stream_header(SessionId) ->
    validate_session_id(SessionId),
    <<(h2_varint:encode(?WT_UNI_STREAM_TYPE))/binary, (h2_varint:encode(SessionId))/binary>>.

%% @doc Encode a bidirectional WebTransport stream header for the given session.
-spec encode_bidi_stream_header(non_neg_integer()) -> binary().
encode_bidi_stream_header(SessionId) ->
    validate_session_id(SessionId),
    <<(h2_varint:encode(?WT_BIDI_SIGNAL))/binary, (h2_varint:encode(SessionId))/binary>>.

%% @doc Decode a WebTransport stream header, returning the session ID and stream kind.
-spec decode_stream_header(binary()) ->
    {ok, non_neg_integer(), stream_kind(), binary()} | {more, pos_integer()} | {error, term()}.
decode_stream_header(Bin) ->
    case h2_varint:decode(Bin) of
        {ok, ?WT_UNI_STREAM_TYPE, Rest} ->
            decode_stream_session_id(uni, Rest);
        {ok, ?WT_BIDI_SIGNAL, Rest} ->
            decode_stream_session_id(bidi, Rest);
        {ok, Type, _Rest} ->
            {error, {unknown_stream_header, Type}};
        {error, incomplete} ->
            {more, 1}
    end.

decode_stream_session_id(Kind, Bin) ->
    case h2_varint:decode(Bin) of
        {ok, SessionId, Rest} -> {ok, SessionId, Kind, Rest};
        {error, incomplete} -> {more, 1}
    end.

%% ============================================================================
%% HTTP Datagrams
%% ============================================================================

%% @doc Convert a session ID to its quarter stream ID for datagram framing.
-spec quarter_stream_id(non_neg_integer()) -> non_neg_integer().
quarter_stream_id(SessionId) when is_integer(SessionId), SessionId >= 0, SessionId rem 4 =:= 0 ->
    SessionId div 4;
quarter_stream_id(SessionId) ->
    error({invalid_session_id, SessionId}).

%% @doc Convert a quarter stream ID back to the original session ID.
-spec session_id_from_quarter_stream_id(non_neg_integer()) -> non_neg_integer().
session_id_from_quarter_stream_id(QuarterStreamId) when is_integer(QuarterStreamId), QuarterStreamId >= 0 ->
    QuarterStreamId * 4.

%% @doc Encode an HTTP Datagram payload with the quarter stream ID prefix.
-spec encode_datagram(non_neg_integer(), binary()) -> binary().
encode_datagram(SessionId, Data) ->
    QuarterStreamId = quarter_stream_id(SessionId),
    <<(h2_varint:encode(QuarterStreamId))/binary, Data/binary>>.

%% @doc Decode an HTTP Datagram, returning the session ID and payload.
-spec decode_datagram(binary()) ->
    {ok, non_neg_integer(), binary()} | {more, pos_integer()} | {error, term()}.
decode_datagram(Bin) ->
    case h2_varint:decode(Bin) of
        {ok, QuarterStreamId, Data} ->
            {ok, session_id_from_quarter_stream_id(QuarterStreamId), Data};
        {error, incomplete} ->
            {more, 1}
    end.

%% ============================================================================
%% Helpers
%% ============================================================================

%% @doc Return the human-readable atom for a capsule type code.
-spec type_name(non_neg_integer()) -> atom() | non_neg_integer().
type_name(?WT_MAX_DATA) -> max_data;
type_name(?WT_DATA_BLOCKED) -> data_blocked;
type_name(?WT_MAX_STREAMS_BIDI) -> max_streams_bidi;
type_name(?WT_MAX_STREAMS_UNI) -> max_streams_uni;
type_name(?WT_STREAMS_BLOCKED_BIDI) -> streams_blocked_bidi;
type_name(?WT_STREAMS_BLOCKED_UNI) -> streams_blocked_uni;
type_name(?WT_CLOSE_SESSION_H3) -> close_session;
type_name(?WT_DRAIN_SESSION_H3) -> drain_session;
type_name(N) -> N.

validate_session_id(SessionId) when is_integer(SessionId), SessionId >= 0, SessionId rem 4 =:= 0 ->
    ok;
validate_session_id(SessionId) ->
    error({invalid_session_id, SessionId}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

capsule_roundtrip_test_() ->
    Capsules = [
        max_data(1000),
        data_blocked(999),
        max_streams_bidi(10),
        max_streams_uni(11),
        streams_blocked_bidi(5),
        streams_blocked_uni(6),
        close_session(16#42, <<"done">>),
        drain_session()
    ],
    [?_assertEqual({ok, Capsule, <<>>}, decode(encode(Capsule))) || Capsule <- Capsules].

stream_header_roundtrip_test_() ->
    SessionId = 16,
    [
        ?_assertEqual({ok, SessionId, bidi, <<>>}, decode_stream_header(encode_bidi_stream_header(SessionId))),
        ?_assertEqual({ok, SessionId, uni, <<>>}, decode_stream_header(encode_uni_stream_header(SessionId)))
    ].

datagram_roundtrip_test() ->
    Encoded = encode_datagram(8, <<"payload">>),
    ?assertEqual({ok, 8, <<"payload">>}, decode_datagram(Encoded)).

invalid_session_id_test() ->
    ?assertError({invalid_session_id, 3}, encode_bidi_stream_header(3)).

close_session_reason_length_test_() ->
    Boundary = binary:copy(<<"x">>, 1024),
    TooLong = <<Boundary/binary, "!">>,
    [
        ?_assertMatch({close_session, 1, _}, close_session(1, Boundary)),
        ?_assertEqual({error, reason_too_long}, close_session(1, TooLong))
    ].

close_session_decode_reason_too_long_test() ->
    Payload = <<(h2_varint:encode(7))/binary, (binary:copy(<<"z">>, 2048))/binary>>,
    Encoded = h2_capsule:encode(?WT_CLOSE_SESSION_H3, Payload),
    ?assertEqual({error, reason_too_long}, decode(Encoded)).

-endif.
