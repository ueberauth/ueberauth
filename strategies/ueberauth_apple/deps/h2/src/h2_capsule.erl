%% @doc RFC 9297 Capsule Protocol
%%
%% Capsules are used to convey control information in HTTP CONNECT tunnels.
%% Used by HTTP/2 WebTransport for stream multiplexing within a CONNECT stream.
%%
%% Capsule format:
%% +------------+------------+
%% | Type (i)   | Length (i) |
%% +------------+------------+
%% | Payload (*)             |
%% +-------------------------+
%%
%% Type and Length are QUIC variable-length integers.
%%
-module(h2_capsule).

-export([encode/2, decode/1, decode_all/1]).
-export([encode_type/1, decode_type/1]).

%% Standard Capsule Types (RFC 9297)
-define(DATAGRAM, 16#00).

%% Convenience function for common capsules
-export([datagram/1]).

-type capsule_type() :: non_neg_integer() | atom().
-type capsule() :: {Type :: capsule_type(), Payload :: binary()}.

-export_type([capsule_type/0, capsule/0]).

%% ============================================================================
%% Constructors
%% ============================================================================

%% @doc Create a DATAGRAM capsule.
-spec datagram(binary()) -> capsule().
datagram(Payload) ->
    {datagram, Payload}.

%% ============================================================================
%% Encoding
%% ============================================================================

%% @doc Encode a capsule to binary.
-spec encode(capsule_type(), binary()) -> binary().
encode(Type, Payload) when is_atom(Type) ->
    encode(encode_type(Type), Payload);
encode(Type, Payload) when is_integer(Type) ->
    TypeBin = h2_varint:encode(Type),
    LengthBin = h2_varint:encode(byte_size(Payload)),
    <<TypeBin/binary, LengthBin/binary, Payload/binary>>.

%% @doc Convert capsule type atom to integer.
-spec encode_type(atom()) -> non_neg_integer().
encode_type(datagram) -> ?DATAGRAM.

%% ============================================================================
%% Decoding
%% ============================================================================

%% @doc Decode a single capsule from binary.
%% Returns {ok, {Type, Payload}, Rest} | {more, N} | {error, Reason}
-spec decode(binary()) -> {ok, capsule(), binary()} | {more, pos_integer()} | {error, term()}.
decode(Bin) ->
    case h2_varint:decode(Bin) of
        {error, incomplete} ->
            {more, 1};
        {ok, Type, Rest1} ->
            case h2_varint:decode(Rest1) of
                {error, incomplete} ->
                    {more, 1};
                {ok, Length, Rest2} ->
                    PayloadSize = byte_size(Rest2),
                    if
                        PayloadSize >= Length ->
                            <<Payload:Length/binary, Rest/binary>> = Rest2,
                            TypeName = decode_type(Type),
                            {ok, {TypeName, Payload}, Rest};
                        true ->
                            {more, Length - PayloadSize}
                    end
            end
    end.

%% @doc Convert capsule type integer to atom (if known).
-spec decode_type(non_neg_integer()) -> non_neg_integer() | atom().
decode_type(?DATAGRAM) -> datagram;
decode_type(N) -> N.

%% @doc Decode all capsules from binary.
-spec decode_all(binary()) -> {ok, [capsule()], binary()}.
decode_all(Bin) ->
    decode_all(Bin, []).

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};
decode_all(Bin, Acc) ->
    case decode(Bin) of
        {ok, Capsule, Rest} ->
            decode_all(Rest, [Capsule|Acc]);
        {more, _N} ->
            {ok, lists:reverse(Acc), Bin}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

encode_decode_test() ->
    Payload = <<"test payload">>,
    Encoded = encode(datagram, Payload),
    {ok, Decoded, <<>>} = decode(Encoded),
    ?assertEqual({datagram, Payload}, Decoded).

encode_numeric_type_test() ->
    %% Custom capsule type
    Payload = <<"custom">>,
    Encoded = encode(16#1234, Payload),
    {ok, Decoded, <<>>} = decode(Encoded),
    ?assertEqual({16#1234, Payload}, Decoded).

decode_incomplete_test() ->
    %% Just the type byte
    ?assertMatch({more, _}, decode(<<0>>)),
    %% Type and length but no payload
    ?assertMatch({more, _}, decode(<<0, 5>>)).

decode_all_test() ->
    C1 = encode(datagram, <<"one">>),
    C2 = encode(datagram, <<"two">>),
    C3 = encode(datagram, <<"three">>),
    Combined = <<C1/binary, C2/binary, C3/binary>>,
    {ok, Capsules, <<>>} = decode_all(Combined),
    ?assertEqual([
        {datagram, <<"one">>},
        {datagram, <<"two">>},
        {datagram, <<"three">>}
    ], Capsules).

decode_all_partial_test() ->
    C1 = encode(datagram, <<"one">>),
    %% Incomplete second capsule
    Partial = <<C1/binary, 0, 10, 1, 2, 3>>,
    {ok, Capsules, Rest} = decode_all(Partial),
    ?assertEqual([{datagram, <<"one">>}], Capsules),
    ?assertEqual(<<0, 10, 1, 2, 3>>, Rest).

empty_payload_test() ->
    Encoded = encode(datagram, <<>>),
    {ok, Decoded, <<>>} = decode(Encoded),
    ?assertEqual({datagram, <<>>}, Decoded).

large_type_test() ->
    %% Type requiring 4-byte varint
    LargeType = 16#12345678,
    Payload = <<"large type">>,
    Encoded = encode(LargeType, Payload),
    {ok, Decoded, <<>>} = decode(Encoded),
    ?assertEqual({LargeType, Payload}, Decoded).

large_payload_test() ->
    %% Payload larger than 63 bytes (requires 2-byte length)
    Payload = binary:copy(<<"x">>, 100),
    Encoded = encode(datagram, Payload),
    {ok, Decoded, <<>>} = decode(Encoded),
    ?assertEqual({datagram, Payload}, Decoded).

-endif.
