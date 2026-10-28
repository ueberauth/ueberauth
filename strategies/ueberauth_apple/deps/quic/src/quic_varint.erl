%%% -*- erlang -*-
%%%
%%% QUIC Variable-Length Integer Encoding
%%% RFC 9000 Section 16
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Variable-length integer encoding/decoding for QUIC.
%%%
%%% QUIC uses a variable-length integer encoding scheme where the
%%% two most significant bits of the first byte indicate the length:
%%%
%%% <ul>
%%%   <li>`2#00xxxxxx' - 1 byte, 6-bit value (0-63)</li>
%%%   <li>`2#01xxxxxx' - 2 bytes, 14-bit value (0-16383)</li>
%%%   <li>`2#10xxxxxx' - 4 bytes, 30-bit value (0-1073741823)</li>
%%%   <li>`2#11xxxxxx' - 8 bytes, 62-bit value (0-4611686018427387903)</li>
%%% </ul>
%%%

-module(quic_varint).

-export([
    encode/1,
    decode/1,
    encode_len/1,
    max_value/1
]).

%% Maximum values for each encoding length

% 2^6 - 1
-define(MAX_1BYTE, 63).
% 2^14 - 1
-define(MAX_2BYTE, 16383).
% 2^30 - 1
-define(MAX_4BYTE, 1073741823).
% 2^62 - 1
-define(MAX_8BYTE, 4611686018427387903).

%%====================================================================
%% API
%%====================================================================

%% @doc Encode an integer as a QUIC variable-length integer.
%% Returns the encoded binary.
%% Raises error:badarg for negative values or values > 2^62-1.
-spec encode(non_neg_integer()) -> binary().
encode(V) when is_integer(V), V >= 0, V =< ?MAX_1BYTE ->
    <<0:2, V:6>>;
encode(V) when is_integer(V), V > ?MAX_1BYTE, V =< ?MAX_2BYTE ->
    <<1:2, V:14>>;
encode(V) when is_integer(V), V > ?MAX_2BYTE, V =< ?MAX_4BYTE ->
    <<2:2, V:30>>;
encode(V) when is_integer(V), V > ?MAX_4BYTE, V =< ?MAX_8BYTE ->
    <<3:2, V:62>>;
encode(_) ->
    error(badarg).

%% @doc Decode a QUIC variable-length integer from a binary.
%% Returns {Value, Rest} where Rest is the remaining binary.
%% Raises error:badarg for invalid input.
-spec decode(binary()) -> {non_neg_integer(), binary()}.
decode(<<0:2, V:6, Rest/binary>>) ->
    {V, Rest};
decode(<<1:2, V:14, Rest/binary>>) ->
    {V, Rest};
decode(<<2:2, V:30, Rest/binary>>) ->
    {V, Rest};
decode(<<3:2, V:62, Rest/binary>>) ->
    {V, Rest};
decode(<<>>) ->
    error(badarg);
decode(Bin) when is_binary(Bin) ->
    %% Insufficient bytes for the indicated length
    error({incomplete, needed_bytes(Bin)}).

%% @doc Return the number of bytes needed to encode a value.
-spec encode_len(non_neg_integer()) -> 1 | 2 | 4 | 8.
encode_len(V) when V >= 0, V =< ?MAX_1BYTE -> 1;
encode_len(V) when V =< ?MAX_2BYTE -> 2;
encode_len(V) when V =< ?MAX_4BYTE -> 4;
encode_len(V) when V =< ?MAX_8BYTE -> 8;
encode_len(_) -> error(badarg).

%% @doc Return the maximum value that can be encoded in N bytes.
-spec max_value(1 | 2 | 4 | 8) -> non_neg_integer().
max_value(1) -> ?MAX_1BYTE;
max_value(2) -> ?MAX_2BYTE;
max_value(4) -> ?MAX_4BYTE;
max_value(8) -> ?MAX_8BYTE.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Calculate how many bytes are needed based on first byte prefix
%% First byte determines encoding length:
%% 0b00xxxxxx = 1 byte
%% 0b01xxxxxx = 2 bytes
%% 0b10xxxxxx = 4 bytes
%% 0b11xxxxxx = 8 bytes
needed_bytes(<<First, _/binary>>) ->
    case First bsr 6 of
        0 -> 1;
        1 -> 2;
        2 -> 4;
        3 -> 8
    end;
needed_bytes(<<>>) ->
    1.
