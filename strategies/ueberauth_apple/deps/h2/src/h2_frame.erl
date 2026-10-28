%% @doc HTTP/2 Frame Encoding and Decoding (RFC 7540 Section 4)
%%
%% All frames begin with a fixed 9-octet header followed by a payload
%% of variable length:
%%
%% +-----------------------------------------------+
%% |                 Length (24)                   |
%% +---------------+---------------+---------------+
%% |   Type (8)    |   Flags (8)   |
%% +-+-------------+---------------+-------------------------------+
%% |R|                 Stream Identifier (31)                      |
%% +=+=============================================================+
%% |                   Frame Payload (0...)                        |
%% +---------------------------------------------------------------+
%%
-module(h2_frame).

-export([encode/1, encode_iodata/1, decode/1, decode/2, decode_header/1]).
-export([data/3, data/4]).
-export([headers/3, headers/4, headers/5]).
-export([priority/4]).
-export([rst_stream/2]).
-export([settings/1, settings_ack/0]).
-export([push_promise/4]).
-export([ping/1, ping_ack/1]).
-export([goaway/3]).
-export([window_update/2]).
-export([continuation/3]).

-include("h2.hrl").

-define(FRAME_HEADER_SIZE, 9).

%% Frame types
-type frame_type() :: data | headers | priority | rst_stream | settings |
                      push_promise | ping | goaway | window_update |
                      continuation | {unknown, 0..255}.

-type frame() :: #h2_frame{} | frame_data().

-type frame_data() ::
    {data, StreamId :: non_neg_integer(), Data :: binary(), EndStream :: boolean()} |
    %% Internal-only variant produced by decode/1,2 when padding is present so
    %% the connection layer can charge the full padded payload against flow
    %% control (RFC 9113 §6.1). The constructor data/3 never emits this.
    {data, StreamId :: non_neg_integer(), Data :: binary(), EndStream :: boolean(),
     FlowControlled :: non_neg_integer()} |
    {headers, StreamId :: non_neg_integer(), HeaderBlock :: binary(), EndStream :: boolean(), EndHeaders :: boolean()} |
    {headers, StreamId :: non_neg_integer(), HeaderBlock :: binary(), EndStream :: boolean(), EndHeaders :: boolean(),
     Priority :: {Exclusive :: boolean(), DependsOn :: non_neg_integer(), Weight :: 1..256}} |
    {priority, StreamId :: non_neg_integer(), Exclusive :: boolean(), DependsOn :: non_neg_integer(), Weight :: 1..256} |
    {rst_stream, StreamId :: non_neg_integer(), ErrorCode :: non_neg_integer()} |
    {settings, Settings :: [{non_neg_integer(), non_neg_integer()}]} |
    {settings_ack} |
    {push_promise, StreamId :: non_neg_integer(), PromisedId :: non_neg_integer(), HeaderBlock :: binary(), EndHeaders :: boolean()} |
    {ping, Data :: binary()} |
    {ping_ack, Data :: binary()} |
    {goaway, LastStreamId :: non_neg_integer(), ErrorCode :: non_neg_integer(), DebugData :: binary()} |
    {window_update, StreamId :: non_neg_integer(), Increment :: pos_integer()} |
    {continuation, StreamId :: non_neg_integer(), HeaderBlock :: binary(), EndHeaders :: boolean()} |
    %% RFC 9113 §4.1: unknown frame types MUST be ignored and discarded.
    %% Surfaced to the connection layer so the decoder remains total.
    {unknown_frame, Type :: non_neg_integer(), Flags :: non_neg_integer(),
     StreamId :: non_neg_integer(), Payload :: binary()}.

-export_type([frame_type/0, frame/0, frame_data/0]).

%% ============================================================================
%% Frame Constructors
%% ============================================================================

%% @doc Create a DATA frame.
-spec data(non_neg_integer(), binary(), boolean()) -> frame_data().
data(StreamId, Data, EndStream) ->
    {data, StreamId, Data, EndStream}.

%% @doc Create a DATA frame with padding.
-spec data(non_neg_integer(), binary(), boolean(), binary()) -> #h2_frame{}.
data(StreamId, Data, EndStream, Padding) when byte_size(Padding) =< 255 ->
    PadLen = byte_size(Padding),
    Flags = flags([{?FLAG_END_STREAM, EndStream}, {?FLAG_PADDED, PadLen > 0}]),
    Payload = if
        PadLen > 0 -> <<PadLen, Data/binary, Padding/binary>>;
        true -> Data
    end,
    #h2_frame{type = ?DATA, flags = Flags, stream_id = StreamId, payload = Payload}.

%% @doc Create a HEADERS frame.
-spec headers(non_neg_integer(), binary(), boolean()) -> frame_data().
headers(StreamId, HeaderBlock, EndStream) ->
    {headers, StreamId, HeaderBlock, EndStream, true}.

%% @doc Create a HEADERS frame with end headers flag.
-spec headers(non_neg_integer(), binary(), boolean(), boolean()) -> frame_data().
headers(StreamId, HeaderBlock, EndStream, EndHeaders) ->
    {headers, StreamId, HeaderBlock, EndStream, EndHeaders}.

%% @doc Create a HEADERS frame with priority.
-spec headers(non_neg_integer(), binary(), boolean(), boolean(),
              {boolean(), non_neg_integer(), 1..256}) -> frame_data().
headers(StreamId, HeaderBlock, EndStream, EndHeaders, Priority) ->
    {headers, StreamId, HeaderBlock, EndStream, EndHeaders, Priority}.

%% @doc Create a PRIORITY frame.
-spec priority(non_neg_integer(), boolean(), non_neg_integer(), 1..256) -> frame_data().
priority(StreamId, Exclusive, DependsOn, Weight) ->
    {priority, StreamId, Exclusive, DependsOn, Weight}.

%% @doc Create a RST_STREAM frame.
-spec rst_stream(non_neg_integer(), non_neg_integer() | atom()) -> frame_data().
rst_stream(StreamId, ErrorCode) when is_atom(ErrorCode) ->
    rst_stream(StreamId, h2_error:code(ErrorCode));
rst_stream(StreamId, ErrorCode) ->
    {rst_stream, StreamId, ErrorCode}.

%% @doc Create a SETTINGS frame.
-spec settings([{atom() | non_neg_integer(), non_neg_integer()}]) -> frame_data().
settings(Settings) ->
    {settings, Settings}.

%% @doc Create a SETTINGS ACK frame.
-spec settings_ack() -> frame_data().
settings_ack() ->
    {settings_ack}.

%% @doc Create a PUSH_PROMISE frame.
-spec push_promise(non_neg_integer(), non_neg_integer(), binary(), boolean()) -> frame_data().
push_promise(StreamId, PromisedId, HeaderBlock, EndHeaders) ->
    {push_promise, StreamId, PromisedId, HeaderBlock, EndHeaders}.

%% @doc Create a PING frame.
-spec ping(binary()) -> frame_data().
ping(Data) when byte_size(Data) =:= 8 ->
    {ping, Data}.

%% @doc Create a PING ACK frame.
-spec ping_ack(binary()) -> frame_data().
ping_ack(Data) when byte_size(Data) =:= 8 ->
    {ping_ack, Data}.

%% @doc Create a GOAWAY frame.
-spec goaway(non_neg_integer(), non_neg_integer() | atom(), binary()) -> frame_data().
goaway(LastStreamId, ErrorCode, DebugData) when is_atom(ErrorCode) ->
    goaway(LastStreamId, h2_error:code(ErrorCode), DebugData);
goaway(LastStreamId, ErrorCode, DebugData) ->
    {goaway, LastStreamId, ErrorCode, DebugData}.

%% @doc Create a WINDOW_UPDATE frame.
-spec window_update(non_neg_integer(), pos_integer()) -> frame_data().
window_update(StreamId, Increment) when Increment > 0 ->
    {window_update, StreamId, Increment}.

%% @doc Create a CONTINUATION frame.
-spec continuation(non_neg_integer(), binary(), boolean()) -> frame_data().
continuation(StreamId, HeaderBlock, EndHeaders) ->
    {continuation, StreamId, HeaderBlock, EndHeaders}.

%% ============================================================================
%% Encoding
%% ============================================================================

%% @doc Encode a frame to binary.
-spec encode(frame() | frame_data()) -> binary().
encode(#h2_frame{type = Type, flags = Flags, stream_id = StreamId, payload = Payload}) ->
    Length = byte_size(Payload),
    <<Length:24, Type:8, Flags:8, 0:1, StreamId:31, Payload/binary>>;

encode({data, StreamId, Data, EndStream}) ->
    Flags = flags([{?FLAG_END_STREAM, EndStream}]),
    Length = byte_size(Data),
    <<Length:24, ?DATA:8, Flags:8, 0:1, StreamId:31, Data/binary>>;

encode({headers, StreamId, HeaderBlock, EndStream, EndHeaders}) ->
    Flags = flags([{?FLAG_END_STREAM, EndStream}, {?FLAG_END_HEADERS, EndHeaders}]),
    Length = byte_size(HeaderBlock),
    <<Length:24, ?HEADERS:8, Flags:8, 0:1, StreamId:31, HeaderBlock/binary>>;

encode({headers, StreamId, HeaderBlock, EndStream, EndHeaders, {Exclusive, DependsOn, Weight}}) ->
    Flags = flags([{?FLAG_END_STREAM, EndStream}, {?FLAG_END_HEADERS, EndHeaders}, {?FLAG_PRIORITY, true}]),
    E = if Exclusive -> 1; true -> 0 end,
    Payload = <<E:1, DependsOn:31, (Weight - 1):8, HeaderBlock/binary>>,
    Length = byte_size(Payload),
    <<Length:24, ?HEADERS:8, Flags:8, 0:1, StreamId:31, Payload/binary>>;

encode({priority, StreamId, Exclusive, DependsOn, Weight}) ->
    E = if Exclusive -> 1; true -> 0 end,
    Payload = <<E:1, DependsOn:31, (Weight - 1):8>>,
    <<5:24, ?PRIORITY:8, 0:8, 0:1, StreamId:31, Payload/binary>>;

encode({rst_stream, StreamId, ErrorCode}) ->
    <<4:24, ?RST_STREAM:8, 0:8, 0:1, StreamId:31, ErrorCode:32>>;

encode({settings, Settings}) ->
    Payload = encode_settings(Settings, <<>>),
    Length = byte_size(Payload),
    <<Length:24, ?SETTINGS:8, 0:8, 0:1, 0:31, Payload/binary>>;

encode({settings_ack}) ->
    <<0:24, ?SETTINGS:8, ?FLAG_ACK:8, 0:1, 0:31>>;

encode({push_promise, StreamId, PromisedId, HeaderBlock, EndHeaders}) ->
    Flags = flags([{?FLAG_END_HEADERS, EndHeaders}]),
    Payload = <<0:1, PromisedId:31, HeaderBlock/binary>>,
    Length = byte_size(Payload),
    <<Length:24, ?PUSH_PROMISE:8, Flags:8, 0:1, StreamId:31, Payload/binary>>;

encode({ping, Data}) ->
    <<8:24, ?PING:8, 0:8, 0:1, 0:31, Data:8/binary>>;

encode({ping_ack, Data}) ->
    <<8:24, ?PING:8, ?FLAG_ACK:8, 0:1, 0:31, Data:8/binary>>;

encode({goaway, LastStreamId, ErrorCode, DebugData}) ->
    Payload = <<0:1, LastStreamId:31, ErrorCode:32, DebugData/binary>>,
    Length = byte_size(Payload),
    <<Length:24, ?GOAWAY:8, 0:8, 0:1, 0:31, Payload/binary>>;

encode({window_update, StreamId, Increment}) ->
    <<4:24, ?WINDOW_UPDATE:8, 0:8, 0:1, StreamId:31, 0:1, Increment:31>>;

encode({continuation, StreamId, HeaderBlock, EndHeaders}) ->
    Flags = flags([{?FLAG_END_HEADERS, EndHeaders}]),
    Length = byte_size(HeaderBlock),
    <<Length:24, ?CONTINUATION:8, Flags:8, 0:1, StreamId:31, HeaderBlock/binary>>.

%% @doc Like encode/1 but returns iodata. For DATA frames the (possibly large)
%% payload is emitted as a separate element rather than copied into a new binary,
%% so the wire bytes are identical to encode/1 without the body copy. Other
%% frame types fall back to encode/1.
-spec encode_iodata(frame_data()) -> iodata().
encode_iodata({data, StreamId, Data, EndStream}) ->
    Flags = flags([{?FLAG_END_STREAM, EndStream}]),
    Length = byte_size(Data),
    [<<Length:24, ?DATA:8, Flags:8, 0:1, StreamId:31>>, Data];
encode_iodata(Frame) ->
    encode(Frame).

encode_settings([], Acc) -> Acc;
encode_settings([{Id, Value}|Rest], Acc) when is_integer(Id) ->
    encode_settings(Rest, <<Acc/binary, Id:16, Value:32>>);
encode_settings([{Name, Value}|Rest], Acc) when is_atom(Name) ->
    Id = setting_id(Name),
    encode_settings(Rest, <<Acc/binary, Id:16, Value:32>>).

setting_id(header_table_size) -> ?SETTINGS_HEADER_TABLE_SIZE;
setting_id(enable_push) -> ?SETTINGS_ENABLE_PUSH;
setting_id(max_concurrent_streams) -> ?SETTINGS_MAX_CONCURRENT_STREAMS;
setting_id(initial_window_size) -> ?SETTINGS_INITIAL_WINDOW_SIZE;
setting_id(max_frame_size) -> ?SETTINGS_MAX_FRAME_SIZE;
setting_id(max_header_list_size) -> ?SETTINGS_MAX_HEADER_LIST_SIZE;
setting_id(enable_connect_protocol) -> ?SETTINGS_ENABLE_CONNECT_PROTOCOL.

flags(Flags) ->
    lists:foldl(fun
        ({Flag, true}, Acc) -> Acc bor Flag;
        ({_, false}, Acc) -> Acc
    end, 0, Flags).

%% ============================================================================
%% Decoding
%% ============================================================================

%% @doc Decode binary to frame.
%% Returns {ok, Frame, Rest} | {more, N} | {error, Reason}
-spec decode(binary()) -> {ok, frame_data(), binary()} | {more, non_neg_integer()} | {error, term()} | {error, {stream_error, non_neg_integer(), atom()}, binary()}.
decode(Bin) ->
    decode(Bin, infinity).

%% @doc Decode binary to frame, rejecting frames larger than MaxFrameSize
%% with frame_size_error (RFC 7540 §4.2).
-spec decode(binary(), pos_integer() | infinity) ->
    {ok, frame_data(), binary()} | {more, non_neg_integer()} | {error, term()} | {error, {stream_error, non_neg_integer(), atom()}, binary()}.
decode(Bin, _MaxFrameSize) when byte_size(Bin) < ?FRAME_HEADER_SIZE ->
    {more, ?FRAME_HEADER_SIZE - byte_size(Bin)};
decode(<<Length:24, _Type:8, _Flags:8, _:1, _StreamId:31, _/binary>>, MaxFrameSize)
  when is_integer(MaxFrameSize), Length > MaxFrameSize ->
    {error, frame_size_error};
decode(<<Length:24, _Type:8, _Flags:8, _:1, _StreamId:31, Rest/binary>> = Bin, _MaxFrameSize)
  when byte_size(Rest) < Length ->
    {more, ?FRAME_HEADER_SIZE + Length - byte_size(Bin)};
decode(<<Length:24, Type:8, Flags:8, _:1, StreamId:31, Payload:Length/binary, Rest/binary>>, _MaxFrameSize) ->
    case decode_frame(Type, Flags, StreamId, Payload) of
        {ok, Frame} -> {ok, Frame, Rest};
        %% Stream-scoped errors carry Rest so the caller can keep decoding.
        {error, {stream_error, _, _} = SE} -> {error, SE, Rest};
        {error, _} = Err -> Err
    end.

%% @doc Decode just the frame header (for peeking).
-spec decode_header(binary()) -> {ok, {non_neg_integer(), frame_type(), 0..255, non_neg_integer()}, binary()} | {more, non_neg_integer()}.
decode_header(Bin) when byte_size(Bin) < ?FRAME_HEADER_SIZE ->
    {more, ?FRAME_HEADER_SIZE - byte_size(Bin)};
decode_header(<<Length:24, Type:8, Flags:8, _:1, StreamId:31, Rest/binary>>) ->
    {ok, {Length, type_name(Type), Flags, StreamId}, Rest}.

decode_frame(?DATA, _Flags, 0, _Payload) ->
    {error, protocol_error};  %% DATA MUST have non-zero stream ID
decode_frame(?DATA, Flags, StreamId, Payload) ->
    EndStream = (Flags band ?FLAG_END_STREAM) =/= 0,
    Padded = (Flags band ?FLAG_PADDED) =/= 0,
    case strip_padding(Padded, Payload) of
        %% FlowControlled = the full payload size on the wire (incl. pad).
        {ok, Data} -> {ok, {data, StreamId, Data, EndStream, byte_size(Payload)}};
        {error, _} = Err -> Err
    end;

decode_frame(?HEADERS, _Flags, 0, _Payload) ->
    {error, protocol_error};  %% HEADERS MUST have non-zero stream ID
decode_frame(?HEADERS, Flags, StreamId, Payload) ->
    EndStream = (Flags band ?FLAG_END_STREAM) =/= 0,
    EndHeaders = (Flags band ?FLAG_END_HEADERS) =/= 0,
    Padded = (Flags band ?FLAG_PADDED) =/= 0,
    HasPriority = (Flags band ?FLAG_PRIORITY) =/= 0,
    case strip_padding(Padded, Payload) of
        {ok, Data} ->
            case decode_headers_payload(HasPriority, Data) of
                {ok, HeaderBlock, undefined} ->
                    {ok, {headers, StreamId, HeaderBlock, EndStream, EndHeaders}};
                {ok, HeaderBlock, Priority} ->
                    {ok, {headers, StreamId, HeaderBlock, EndStream, EndHeaders, Priority}};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end;

decode_frame(?PRIORITY, _Flags, 0, _Payload) ->
    {error, protocol_error};  %% PRIORITY MUST have non-zero stream ID
decode_frame(?PRIORITY, _Flags, StreamId, <<E:1, DependsOn:31, Weight:8>>) ->
    {ok, {priority, StreamId, E =:= 1, DependsOn, Weight + 1}};
%% RFC 9113 §6.3: PRIORITY frame with length != 5 is a *stream* error
%% FRAME_SIZE_ERROR, not a connection error.
decode_frame(?PRIORITY, _Flags, StreamId, _Payload) ->
    {error, {stream_error, StreamId, frame_size_error}};

decode_frame(?RST_STREAM, _Flags, 0, _Payload) ->
    {error, protocol_error};  %% RST_STREAM MUST have non-zero stream ID
decode_frame(?RST_STREAM, _Flags, StreamId, <<ErrorCode:32>>) ->
    {ok, {rst_stream, StreamId, ErrorCode}};
decode_frame(?RST_STREAM, _Flags, _StreamId, _Payload) ->
    {error, frame_size_error};

decode_frame(?SETTINGS, Flags, 0, Payload) ->
    IsAck = (Flags band ?FLAG_ACK) =/= 0,
    if
        IsAck, byte_size(Payload) =:= 0 ->
            {ok, {settings_ack}};
        IsAck ->
            {error, frame_size_error};
        true ->
            case decode_settings(Payload) of
                {ok, Settings} -> {ok, {settings, Settings}};
                {error, _} = Err -> Err
            end
    end;
decode_frame(?SETTINGS, _Flags, _StreamId, _Payload) ->
    {error, protocol_error}; %% SETTINGS must be on stream 0

decode_frame(?PUSH_PROMISE, _Flags, 0, _Payload) ->
    {error, protocol_error};  %% PUSH_PROMISE MUST have non-zero stream ID
decode_frame(?PUSH_PROMISE, Flags, StreamId, Payload) ->
    EndHeaders = (Flags band ?FLAG_END_HEADERS) =/= 0,
    Padded = (Flags band ?FLAG_PADDED) =/= 0,
    case strip_padding(Padded, Payload) of
        {ok, <<_:1, PromisedId:31, HeaderBlock/binary>>} ->
            {ok, {push_promise, StreamId, PromisedId, HeaderBlock, EndHeaders}};
        {ok, _} ->
            {error, frame_size_error};
        {error, _} = Err ->
            Err
    end;

decode_frame(?PING, Flags, 0, Data) when byte_size(Data) =:= 8 ->
    IsAck = (Flags band ?FLAG_ACK) =/= 0,
    if
        IsAck -> {ok, {ping_ack, Data}};
        true -> {ok, {ping, Data}}
    end;
decode_frame(?PING, _Flags, 0, _Payload) ->
    {error, frame_size_error};
decode_frame(?PING, _Flags, _StreamId, _Payload) ->
    {error, protocol_error}; %% PING must be on stream 0

decode_frame(?GOAWAY, _Flags, 0, <<_:1, LastStreamId:31, ErrorCode:32, DebugData/binary>>) ->
    {ok, {goaway, LastStreamId, ErrorCode, DebugData}};
decode_frame(?GOAWAY, _Flags, 0, _Payload) ->
    {error, frame_size_error};
decode_frame(?GOAWAY, _Flags, _StreamId, _Payload) ->
    {error, protocol_error}; %% GOAWAY must be on stream 0

decode_frame(?WINDOW_UPDATE, _Flags, StreamId, <<_:1, Increment:31>>) when Increment > 0 ->
    {ok, {window_update, StreamId, Increment}};
decode_frame(?WINDOW_UPDATE, _Flags, 0, <<_:1, 0:31>>) ->
    {error, protocol_error}; %% Connection-level: GOAWAY
decode_frame(?WINDOW_UPDATE, _Flags, StreamId, <<_:1, 0:31>>) ->
    %% RFC 9113 §6.9.1: zero increment on a non-zero stream is a STREAM error.
    {error, {stream_error, StreamId, protocol_error}};
decode_frame(?WINDOW_UPDATE, _Flags, _StreamId, _Payload) ->
    {error, frame_size_error};

decode_frame(?CONTINUATION, _Flags, 0, _Payload) ->
    {error, protocol_error};  %% CONTINUATION MUST have non-zero stream ID
decode_frame(?CONTINUATION, Flags, StreamId, HeaderBlock) ->
    EndHeaders = (Flags band ?FLAG_END_HEADERS) =/= 0,
    {ok, {continuation, StreamId, HeaderBlock, EndHeaders}};

decode_frame(Type, Flags, StreamId, Payload) ->
    %% Unknown frame types are ignored per RFC 7540
    {ok, {unknown_frame, Type, Flags, StreamId, Payload}}.

strip_padding(false, Data) ->
    {ok, Data};
strip_padding(true, <<PadLength, Rest/binary>>) when PadLength =< byte_size(Rest) ->
    %% RFC 7540 §6.1: pad_length's value MUST be less than the frame payload
    %% length (which is 1 + byte_size(Rest) here since payload includes the
    %% pad-length byte). So PadLength =< byte_size(Rest) is the valid bound.
    DataLen = byte_size(Rest) - PadLength,
    <<Data:DataLen/binary, _Padding:PadLength/binary>> = Rest,
    {ok, Data};
strip_padding(true, _) ->
    {error, protocol_error}.

decode_headers_payload(false, HeaderBlock) ->
    {ok, HeaderBlock, undefined};
decode_headers_payload(true, <<E:1, DependsOn:31, Weight:8, HeaderBlock/binary>>) ->
    {ok, HeaderBlock, {E =:= 1, DependsOn, Weight + 1}};
decode_headers_payload(true, _) ->
    {error, frame_size_error}.

decode_settings(Bin) ->
    decode_settings(Bin, []).

decode_settings(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
decode_settings(<<Id:16, Value:32, Rest/binary>>, Acc) ->
    decode_settings(Rest, [{Id, Value}|Acc]);
decode_settings(_, _) ->
    {error, frame_size_error}.

type_name(?DATA) -> data;
type_name(?HEADERS) -> headers;
type_name(?PRIORITY) -> priority;
type_name(?RST_STREAM) -> rst_stream;
type_name(?SETTINGS) -> settings;
type_name(?PUSH_PROMISE) -> push_promise;
type_name(?PING) -> ping;
type_name(?GOAWAY) -> goaway;
type_name(?WINDOW_UPDATE) -> window_update;
type_name(?CONTINUATION) -> continuation;
type_name(N) -> {unknown, N}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

data_test() ->
    Frame = data(1, <<"hello">>, true),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({data, 1, <<"hello">>, true, 5}, Decoded).

data_no_end_stream_test() ->
    Frame = data(1, <<"hello">>, false),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({data, 1, <<"hello">>, false, 5}, Decoded).

%% RFC 9113 §6.1: padding must be counted against receive flow control.
%% Verify decoder reports the full padded payload as FlowControlled.
data_padded_flow_controlled_test() ->
    Frame = data(1, <<"hi">>, false, <<1,2,3>>),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    %% Data = <<"hi">> (2 bytes), Payload = 1 (padlen byte) + 2 (data) + 3 (pad) = 6.
    ?assertEqual({data, 1, <<"hi">>, false, 6}, Decoded).

headers_test() ->
    Frame = headers(1, <<"header_block">>, true),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({headers, 1, <<"header_block">>, true, true}, Decoded).

headers_with_priority_test() ->
    Frame = headers(1, <<"header_block">>, true, true, {true, 0, 16}),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({headers, 1, <<"header_block">>, true, true, {true, 0, 16}}, Decoded).

priority_test() ->
    Frame = priority(1, false, 0, 16),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({priority, 1, false, 0, 16}, Decoded).

rst_stream_test() ->
    Frame = rst_stream(1, 8),  %% CANCEL
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({rst_stream, 1, 8}, Decoded).

rst_stream_atom_test() ->
    Frame = rst_stream(1, cancel),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({rst_stream, 1, 8}, Decoded).

settings_test() ->
    Frame = settings([{1, 4096}, {4, 65535}]),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({settings, [{1, 4096}, {4, 65535}]}, Decoded).

settings_ack_test() ->
    Frame = settings_ack(),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({settings_ack}, Decoded).

ping_test() ->
    Data = <<1,2,3,4,5,6,7,8>>,
    Frame = ping(Data),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({ping, Data}, Decoded).

ping_ack_test() ->
    Data = <<1,2,3,4,5,6,7,8>>,
    Frame = ping_ack(Data),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({ping_ack, Data}, Decoded).

goaway_test() ->
    Frame = goaway(1, 0, <<"debug">>),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({goaway, 1, 0, <<"debug">>}, Decoded).

window_update_test() ->
    Frame = window_update(1, 1000),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({window_update, 1, 1000}, Decoded).

%% RFC 9113 §6.9.1: WINDOW_UPDATE with increment 0 is a stream error on a
%% non-zero stream, a connection error on stream 0.
window_update_zero_stream_level_test() ->
    %% Stream id 5, increment 0
    Bin = <<4:24, ?WINDOW_UPDATE:8, 0:8, 0:1, 5:31, 0:1, 0:31>>,
    ?assertMatch({error, {stream_error, 5, protocol_error}, <<>>}, decode(Bin)).

window_update_zero_connection_level_test() ->
    %% Stream id 0, increment 0
    Bin = <<4:24, ?WINDOW_UPDATE:8, 0:8, 0:1, 0:31, 0:1, 0:31>>,
    ?assertEqual({error, protocol_error}, decode(Bin)).

continuation_test() ->
    Frame = continuation(1, <<"more_headers">>, true),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({continuation, 1, <<"more_headers">>, true}, Decoded).

push_promise_test() ->
    Frame = push_promise(1, 2, <<"header_block">>, true),
    Bin = encode(Frame),
    {ok, Decoded, <<>>} = decode(Bin),
    ?assertEqual({push_promise, 1, 2, <<"header_block">>, true}, Decoded).

decode_incomplete_test() ->
    %% Less than frame header
    ?assertEqual({more, 5}, decode(<<0,0,0,0>>)),
    %% Frame header but missing payload
    ?assertEqual({more, 5}, decode(<<0,0,10, 0, 0, 0,0,0,1, 1,2,3,4,5>>)).

multiple_frames_test() ->
    Frame1 = encode(data(1, <<"hello">>, false)),
    Frame2 = encode(data(1, <<"world">>, true)),
    Combined = <<Frame1/binary, Frame2/binary>>,
    {ok, D1, Rest} = decode(Combined),
    ?assertEqual({data, 1, <<"hello">>, false, 5}, D1),
    {ok, D2, <<>>} = decode(Rest),
    ?assertEqual({data, 1, <<"world">>, true, 5}, D2).

%% ---- Spec-compliance: frame validation ----

max_frame_size_receive_test() ->
    Big = binary:copy(<<"x">>, 20000),
    Bin = encode(data(1, Big, true)),
    ?assertEqual({error, frame_size_error}, decode(Bin, 16384)),
    %% At the default settings-max, it decodes cleanly
    {ok, _, <<>>} = decode(Bin, 16#FFFFFF).

data_on_stream_zero_rejected_test() ->
    Bin = encode(data(0, <<"oops">>, true)),
    ?assertEqual({error, protocol_error}, decode(Bin)).

headers_on_stream_zero_rejected_test() ->
    Bin = encode(headers(0, <<"hdr">>, true)),
    ?assertEqual({error, protocol_error}, decode(Bin)).

priority_on_stream_zero_rejected_test() ->
    Bin = encode(priority(0, false, 0, 16)),
    ?assertEqual({error, protocol_error}, decode(Bin)).

rst_stream_on_stream_zero_rejected_test() ->
    Bin = encode(rst_stream(0, 0)),
    ?assertEqual({error, protocol_error}, decode(Bin)).

push_promise_on_stream_zero_rejected_test() ->
    Bin = encode(push_promise(0, 2, <<"hdr">>, true)),
    ?assertEqual({error, protocol_error}, decode(Bin)).

continuation_on_stream_zero_rejected_test() ->
    Bin = encode(continuation(0, <<"hdr">>, true)),
    ?assertEqual({error, protocol_error}, decode(Bin)).

settings_on_stream_nonzero_rejected_test() ->
    %% Craft a SETTINGS frame on stream 1 manually
    Bin = <<0:24, ?SETTINGS:8, 0:8, 0:1, 1:31>>,
    ?assertEqual({error, protocol_error}, decode(Bin)).

ping_on_stream_nonzero_rejected_test() ->
    Bin = <<8:24, ?PING:8, 0:8, 0:1, 1:31, 0,0,0,0,0,0,0,0>>,
    ?assertEqual({error, protocol_error}, decode(Bin)).

goaway_on_stream_nonzero_rejected_test() ->
    Bin = <<8:24, ?GOAWAY:8, 0:8, 0:1, 1:31, 0:1, 0:31, 0:32>>,
    ?assertEqual({error, protocol_error}, decode(Bin)).

padding_equal_payload_accepted_test() ->
    %% PadLength=5 with 0 data bytes and 5 padding bytes: payload size = 1+0+5 = 6
    %% This is legal per RFC 7540 §6.1 since pad value (5) < payload length (6).
    Frame = data(1, <<>>, true, <<1,2,3,4,5>>),
    Bin = encode(Frame),
    {ok, {data, 1, <<>>, true, 6}, <<>>} = decode(Bin).

padding_over_payload_rejected_test() ->
    %% Manually craft a DATA frame where PadLength claims more bytes than follow.
    %% Payload = <<5, 1,2>> (PadLength=5 but only 2 bytes of data+padding).
    Payload = <<5, 1, 2>>,
    Bin = <<(byte_size(Payload)):24, ?DATA:8, ?FLAG_PADDED:8, 0:1, 1:31, Payload/binary>>,
    ?assertEqual({error, protocol_error}, decode(Bin)).

settings_ack_with_payload_rejected_test() ->
    %% SETTINGS frame with ACK flag set MUST NOT have a payload (RFC 7540 §6.5).
    Payload = <<0,1, 0:32>>,
    Bin = <<(byte_size(Payload)):24, ?SETTINGS:8, ?FLAG_ACK:8, 0:1, 0:31, Payload/binary>>,
    ?assertEqual({error, frame_size_error}, decode(Bin)).

unknown_frame_ignored_test() ->
    %% Type 0xFA is not defined; decode returns unknown_frame for upper layer
    %% to ignore (RFC 7540 §4.1).
    Payload = <<"anything">>,
    Bin = <<(byte_size(Payload)):24, 16#FA:8, 0:8, 0:1, 1:31, Payload/binary>>,
    {ok, {unknown_frame, 16#FA, 0, 1, Payload}, <<>>} = decode(Bin).

-endif.
