%%% -*- erlang -*-
%%%
%%% HTTP/3 frame encoding and decoding (RFC 9114)
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc HTTP/3 frame encoding and decoding.
%%%
%%% HTTP/3 frames use QUIC variable-length integer encoding for
%%% frame type and length fields.
%%% @end

-module(quic_h3_frame).

-export([
    %% Frame encoding
    encode/1,
    encode_data/1,
    encode_headers/1,
    encode_settings/1,
    encode_goaway/1,
    encode_max_push_id/1,
    encode_cancel_push/1,
    encode_push_promise/2,
    %% Frame decoding
    decode/1,
    decode_streaming/2,
    decode_all/1,
    decode_stream_type/1,
    %% Settings helpers
    default_settings/0,
    encode_settings_payload/1,
    decode_settings_payload/1,
    %% Stream type encoding
    encode_stream_type/1,
    %% Validation
    is_reserved_frame_type/1,
    is_reserved_setting/1
]).

-include("quic_h3.hrl").

-type frame() ::
    {data, binary()}
    | {headers, binary()}
    | {cancel_push, non_neg_integer()}
    | {settings, map()}
    | {push_promise, non_neg_integer(), binary()}
    | {goaway, non_neg_integer()}
    | {max_push_id, non_neg_integer()}
    | {unknown, non_neg_integer(), binary()}.

-export_type([frame/0]).

%%====================================================================
%% Frame Encoding
%%====================================================================

%% @doc Encode an HTTP/3 frame to binary.
-spec encode(frame()) -> binary().
encode({data, Payload}) ->
    encode_data(Payload);
encode({headers, Payload}) ->
    encode_headers(Payload);
encode({cancel_push, PushId}) ->
    encode_cancel_push(PushId);
encode({settings, Settings}) ->
    encode_settings(Settings);
encode({push_promise, PushId, HeaderBlock}) ->
    encode_push_promise(PushId, HeaderBlock);
encode({goaway, StreamId}) ->
    encode_goaway(StreamId);
encode({max_push_id, PushId}) ->
    encode_max_push_id(PushId).

%% @doc Encode a DATA frame.
-spec encode_data(binary()) -> binary().
encode_data(Payload) ->
    encode_frame(?H3_FRAME_DATA, Payload).

%% @doc Encode a HEADERS frame.
-spec encode_headers(binary()) -> binary().
encode_headers(HeaderBlock) ->
    encode_frame(?H3_FRAME_HEADERS, HeaderBlock).

%% @doc Encode a SETTINGS frame.
-spec encode_settings(map()) -> binary().
encode_settings(Settings) ->
    Payload = encode_settings_payload(Settings),
    encode_frame(?H3_FRAME_SETTINGS, Payload).

%% @doc Encode a GOAWAY frame.
-spec encode_goaway(non_neg_integer()) -> binary().
encode_goaway(StreamId) ->
    encode_frame(?H3_FRAME_GOAWAY, quic_varint:encode(StreamId)).

%% @doc Encode a MAX_PUSH_ID frame.
-spec encode_max_push_id(non_neg_integer()) -> binary().
encode_max_push_id(PushId) ->
    encode_frame(?H3_FRAME_MAX_PUSH_ID, quic_varint:encode(PushId)).

%% @doc Encode a CANCEL_PUSH frame.
-spec encode_cancel_push(non_neg_integer()) -> binary().
encode_cancel_push(PushId) ->
    encode_frame(?H3_FRAME_CANCEL_PUSH, quic_varint:encode(PushId)).

%% @doc Encode a PUSH_PROMISE frame.
-spec encode_push_promise(non_neg_integer(), binary()) -> binary().
encode_push_promise(PushId, HeaderBlock) ->
    PushIdEnc = quic_varint:encode(PushId),
    encode_frame(?H3_FRAME_PUSH_PROMISE, <<PushIdEnc/binary, HeaderBlock/binary>>).

%% @doc Encode stream type for unidirectional streams.
-spec encode_stream_type(control | qpack_encoder | qpack_decoder | push | non_neg_integer()) ->
    binary().
encode_stream_type(control) ->
    quic_varint:encode(?H3_STREAM_CONTROL);
encode_stream_type(qpack_encoder) ->
    quic_varint:encode(?H3_STREAM_QPACK_ENCODER);
encode_stream_type(qpack_decoder) ->
    quic_varint:encode(?H3_STREAM_QPACK_DECODER);
encode_stream_type(push) ->
    quic_varint:encode(?H3_STREAM_PUSH);
encode_stream_type(Type) when is_integer(Type) ->
    quic_varint:encode(Type).

%% Internal: encode a frame with type and payload
-spec encode_frame(non_neg_integer(), binary()) -> binary().
encode_frame(Type, Payload) ->
    TypeEnc = quic_varint:encode(Type),
    LenEnc = quic_varint:encode(byte_size(Payload)),
    <<TypeEnc/binary, LenEnc/binary, Payload/binary>>.

%%====================================================================
%% Frame Decoding
%%====================================================================

%% @doc Decode an HTTP/3 frame from binary.
%% Returns {ok, Frame, Rest} | {error, Reason} | {more, N}.
-spec decode(binary()) ->
    {ok, frame(), binary()} | {error, term()} | {more, non_neg_integer()}.
decode(Data) when byte_size(Data) < 2 ->
    %% Need at least 2 bytes for type and length
    {more, 2 - byte_size(Data)};
decode(Data) ->
    case decode_type_and_length(Data) of
        {ok, Type, Length, Rest} ->
            decode_with_payload(Type, Length, Rest);
        Other ->
            Other
    end.

%% @doc Decode the next frame on a request or push stream, handing out
%% DATA payload as it arrives instead of waiting for the whole frame.
%% `Remaining' is what the previous call left of a DATA frame, 0 between
%% frames. A DATA piece comes back as `{data, Piece, Remaining, Rest}';
%% other frames decode as in decode/1, capped at ?H3_MAX_FRAME_SIZE.
-spec decode_streaming(binary(), non_neg_integer()) ->
    {data, binary(), non_neg_integer(), binary()}
    | {ok, frame(), binary()}
    | {error, term()}
    | {more, non_neg_integer()}.
decode_streaming(Data, Remaining) when Remaining > 0 ->
    take_data(Remaining, Data);
decode_streaming(Data, 0) ->
    case decode_type_and_length(Data) of
        {ok, ?H3_FRAME_DATA, Length, Rest} ->
            take_data(Length, Rest);
        {ok, Type, Length, Rest} ->
            decode_with_payload(Type, Length, Rest);
        Other ->
            Other
    end.

take_data(Length, Data) ->
    Size = min(Length, byte_size(Data)),
    <<Piece:Size/binary, Rest/binary>> = Data,
    {data, Piece, Length - Size, Rest}.

%% Internal: decode frame type and length varints
-spec decode_type_and_length(binary()) ->
    {ok, non_neg_integer(), non_neg_integer(), binary()} | {more, non_neg_integer()}.
decode_type_and_length(Data) ->
    try quic_varint:decode(Data) of
        {Type, Rest1} ->
            try quic_varint:decode(Rest1) of
                {Length, Rest2} -> {ok, Type, Length, Rest2}
            catch
                error:{incomplete, _} -> {more, 1};
                error:badarg -> {more, 1}
            end
    catch
        error:{incomplete, _} -> {more, 1};
        error:badarg -> {more, 1}
    end.

%% Internal: decode frame payload given type and length
-spec decode_with_payload(non_neg_integer(), non_neg_integer(), binary()) ->
    {ok, frame(), binary()} | {error, term()} | {more, non_neg_integer()}.
decode_with_payload(_Type, Length, _Data) when Length > ?H3_MAX_FRAME_SIZE ->
    %% RFC 9114 §7.1 / §7.2: bound payload size to avoid resource exhaustion.
    {error, {frame_error, oversized, Length}};
decode_with_payload(Type, Length, Data) when byte_size(Data) >= Length ->
    <<Payload:Length/binary, Rest/binary>> = Data,
    case decode_frame_payload(Type, Payload) of
        {error, _} = Err -> Err;
        Frame -> {ok, Frame, Rest}
    end;
decode_with_payload(_Type, Length, Data) ->
    {more, Length - byte_size(Data)}.

%% @doc Decode all frames from binary buffer.
-spec decode_all(binary()) -> {ok, [frame()], binary()} | {error, term()}.
decode_all(Data) ->
    decode_all(Data, []).

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};
decode_all(Data, Acc) ->
    case decode(Data) of
        {ok, Frame, Rest} ->
            decode_all(Rest, [Frame | Acc]);
        {error, _} = Err ->
            Err;
        {more, _} ->
            {ok, lists:reverse(Acc), Data}
    end.

%% Internal: decode frame payload by type
-spec decode_frame_payload(non_neg_integer(), binary()) -> frame() | {error, term()}.
decode_frame_payload(?H3_FRAME_DATA, Payload) ->
    {data, Payload};
decode_frame_payload(?H3_FRAME_HEADERS, Payload) ->
    {headers, Payload};
decode_frame_payload(?H3_FRAME_CANCEL_PUSH, Payload) ->
    try quic_varint:decode(Payload) of
        {PushId, <<>>} -> {cancel_push, PushId};
        {_PushId, _Extra} -> {error, {frame_error, cancel_push, extra_data}}
    catch
        _:_ -> {error, {frame_error, cancel_push, malformed_varint}}
    end;
decode_frame_payload(?H3_FRAME_SETTINGS, Payload) ->
    case decode_settings_payload(Payload) of
        {ok, Settings} -> {settings, Settings};
        {error, Reason} -> {error, {frame_error, settings, Reason}}
    end;
decode_frame_payload(?H3_FRAME_PUSH_PROMISE, Payload) ->
    try quic_varint:decode(Payload) of
        {PushId, HeaderBlock} -> {push_promise, PushId, HeaderBlock}
    catch
        _:_ -> {error, {frame_error, push_promise, malformed_varint}}
    end;
decode_frame_payload(?H3_FRAME_GOAWAY, Payload) ->
    try quic_varint:decode(Payload) of
        {StreamId, <<>>} -> {goaway, StreamId};
        {_StreamId, _Extra} -> {error, {frame_error, goaway, extra_data}}
    catch
        _:_ -> {error, {frame_error, goaway, malformed_varint}}
    end;
decode_frame_payload(?H3_FRAME_MAX_PUSH_ID, Payload) ->
    try quic_varint:decode(Payload) of
        {PushId, <<>>} -> {max_push_id, PushId};
        {_PushId, _Extra} -> {error, {frame_error, max_push_id, extra_data}}
    catch
        _:_ -> {error, {frame_error, max_push_id, malformed_varint}}
    end;
%% RFC 9114 §7.2.8: frame types used by HTTP/2 that are reserved in HTTP/3
%% MUST be treated as a connection error of type H3_FRAME_UNEXPECTED.
decode_frame_payload(16#02, _Payload) ->
    {error, {h2_reserved_frame, 16#02}};
decode_frame_payload(16#06, _Payload) ->
    {error, {h2_reserved_frame, 16#06}};
decode_frame_payload(16#08, _Payload) ->
    {error, {h2_reserved_frame, 16#08}};
decode_frame_payload(16#09, _Payload) ->
    {error, {h2_reserved_frame, 16#09}};
decode_frame_payload(Type, Payload) ->
    %% Unknown or reserved grease frame type (0x1f*N+0x21) - ignore per §9
    {unknown, Type, Payload}.

%% @doc Decode stream type from unidirectional stream.
-spec decode_stream_type(binary()) ->
    {ok, control | qpack_encoder | qpack_decoder | push | {unknown, non_neg_integer()}, binary()}
    | {more, non_neg_integer()}.
decode_stream_type(<<>>) ->
    {more, 1};
decode_stream_type(Data) ->
    try quic_varint:decode(Data) of
        {?H3_STREAM_CONTROL, Rest} -> {ok, control, Rest};
        {?H3_STREAM_PUSH, Rest} -> {ok, push, Rest};
        {?H3_STREAM_QPACK_ENCODER, Rest} -> {ok, qpack_encoder, Rest};
        {?H3_STREAM_QPACK_DECODER, Rest} -> {ok, qpack_decoder, Rest};
        {Type, Rest} -> {ok, {unknown, Type}, Rest}
    catch
        error:{incomplete, _} -> {more, 1};
        error:badarg -> {more, 1}
    end.

%%====================================================================
%% Settings Helpers
%%====================================================================

%% @doc Return default HTTP/3 settings.
-spec default_settings() -> map().
default_settings() ->
    #{
        qpack_max_table_capacity => ?H3_DEFAULT_QPACK_MAX_TABLE_CAPACITY,
        max_field_section_size => ?H3_DEFAULT_MAX_FIELD_SECTION_SIZE,
        qpack_blocked_streams => ?H3_DEFAULT_QPACK_BLOCKED_STREAMS,
        enable_connect_protocol => 0
    }.

%% @doc Encode settings map to SETTINGS frame payload.
-spec encode_settings_payload(map()) -> binary().
encode_settings_payload(Settings) ->
    encode_settings_pairs(maps:to_list(Settings), <<>>).

encode_settings_pairs([], Acc) ->
    Acc;
encode_settings_pairs([{Key, Value} | Rest], Acc) ->
    Id = setting_to_id(Key),
    IdEnc = quic_varint:encode(Id),
    ValueEnc = quic_varint:encode(Value),
    encode_settings_pairs(Rest, <<Acc/binary, IdEnc/binary, ValueEnc/binary>>).

%% @doc Decode SETTINGS frame payload to settings map.
-spec decode_settings_payload(binary()) -> {ok, map()} | {error, term()}.
decode_settings_payload(Data) ->
    try
        {ok, decode_settings_pairs(Data, #{})}
    catch
        _:Reason -> {error, Reason}
    end.

decode_settings_pairs(<<>>, Acc) ->
    Acc;
decode_settings_pairs(Data, Acc) ->
    {Id, Rest1} = quic_varint:decode(Data),
    {Value, Rest2} = quic_varint:decode(Rest1),
    %% RFC 9114 Section 7.2.4.1: Reject HTTP/2 settings that have no meaning in HTTP/3
    case is_forbidden_setting(Id) of
        true ->
            throw({forbidden_setting, Id});
        false ->
            %% RFC 9114 §7.2.4.1: unknown setting IDs MUST be ignored.
            %% "Ignored" means not applied to connection behaviour; the
            %% identifier is still surfaced in the decoded map (as its
            %% integer ID) so upper layers can observe extension settings
            %% (e.g. WebTransport over HTTP/3, draft-15 §9.2) without
            %% requiring a new atom mapping for every draft revision.
            Key = id_to_setting(Id),
            case maps:is_key(Key, Acc) of
                true -> throw({duplicate_setting, Key});
                false -> decode_settings_pairs(Rest2, Acc#{Key => Value})
            end
    end.

%% RFC 9114 Section 7.2.4.1: HTTP/2 settings forbidden in HTTP/3
%% These settings are defined for HTTP/2 but have no meaning in HTTP/3
-spec is_forbidden_setting(non_neg_integer()) -> boolean().
%% ENABLE_PUSH (HTTP/2)
is_forbidden_setting(16#02) -> true;
%% MAX_CONCURRENT_STREAMS (HTTP/2)
is_forbidden_setting(16#03) -> true;
%% INITIAL_WINDOW_SIZE (HTTP/2)
is_forbidden_setting(16#04) -> true;
%% MAX_FRAME_SIZE (HTTP/2)
is_forbidden_setting(16#05) -> true;
is_forbidden_setting(_) -> false.

-spec setting_to_id(atom() | non_neg_integer()) -> non_neg_integer().
setting_to_id(qpack_max_table_capacity) -> ?H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY;
setting_to_id(max_field_section_size) -> ?H3_SETTINGS_MAX_FIELD_SECTION_SIZE;
setting_to_id(qpack_blocked_streams) -> ?H3_SETTINGS_QPACK_BLOCKED_STREAMS;
setting_to_id(enable_connect_protocol) -> ?H3_SETTINGS_ENABLE_CONNECT_PROTOCOL;
setting_to_id(h3_datagram) -> ?H3_SETTINGS_H3_DATAGRAM;
setting_to_id(wt_enabled) -> ?H3_SETTINGS_WT_ENABLED;
setting_to_id(wt_initial_max_data) -> ?H3_SETTINGS_WT_INITIAL_MAX_DATA;
setting_to_id(wt_initial_max_streams_uni) -> ?H3_SETTINGS_WT_INITIAL_MAX_STREAMS_UNI;
setting_to_id(wt_initial_max_streams_bidi) -> ?H3_SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI;
setting_to_id(Id) when is_integer(Id) -> Id.

-spec id_to_setting(non_neg_integer()) -> atom() | non_neg_integer().
id_to_setting(?H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY) -> qpack_max_table_capacity;
id_to_setting(?H3_SETTINGS_MAX_FIELD_SECTION_SIZE) -> max_field_section_size;
id_to_setting(?H3_SETTINGS_QPACK_BLOCKED_STREAMS) -> qpack_blocked_streams;
id_to_setting(?H3_SETTINGS_ENABLE_CONNECT_PROTOCOL) -> enable_connect_protocol;
id_to_setting(?H3_SETTINGS_H3_DATAGRAM) -> h3_datagram;
id_to_setting(?H3_SETTINGS_WT_ENABLED) -> wt_enabled;
id_to_setting(?H3_SETTINGS_WT_INITIAL_MAX_DATA) -> wt_initial_max_data;
id_to_setting(?H3_SETTINGS_WT_INITIAL_MAX_STREAMS_UNI) -> wt_initial_max_streams_uni;
id_to_setting(?H3_SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI) -> wt_initial_max_streams_bidi;
id_to_setting(Id) -> Id.

%%====================================================================
%% Frame Validation (RFC 9114 Section 7.2.8)
%%====================================================================

%% @doc Check if a frame type is reserved (grease).
%% Reserved types are 0x1f * N + 0x21 for any non-negative integer N.
-spec is_reserved_frame_type(non_neg_integer()) -> boolean().
is_reserved_frame_type(Type) ->
    (Type - 16#21) rem 16#1f =:= 0.

%% @doc Check if a settings identifier is reserved (grease).
%% Reserved identifiers are 0x1f * N + 0x21 for any non-negative integer N.
-spec is_reserved_setting(non_neg_integer()) -> boolean().
is_reserved_setting(Id) ->
    (Id - 16#21) rem 16#1f =:= 0.
