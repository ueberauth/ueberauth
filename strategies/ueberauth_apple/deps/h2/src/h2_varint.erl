%% @doc QUIC-style Variable-Length Integer Encoding (RFC 9000 Section 16)
%%
%% Used by HTTP/3 and the Capsule Protocol (RFC 9297).
%% Integers use a variable-length encoding with 1, 2, 4, or 8 bytes.
%% The two most significant bits indicate the encoding length.
%%
%% 2MSB | Length | Usable Bits | Range
%% -----|--------|-------------|------------------
%% 00   | 1      | 6           | 0-63
%% 01   | 2      | 14          | 0-16383
%% 10   | 4      | 30          | 0-1073741823
%% 11   | 8      | 62          | 0-4611686018427387903
%%
-module(h2_varint).

-export([encode/1, decode/1, decode_with_rest/1]).
-export([encoded_size/1]).

%% Maximum value that can be encoded
-define(MAX_VARINT, 4611686018427387903). %% 2^62 - 1

%% @doc Encode an integer to QUIC variable-length format.
-spec encode(non_neg_integer()) -> binary().
encode(N) when N >= 0, N =< 63 ->
    <<N:8>>;
encode(N) when N >= 0, N =< 16383 ->
    <<1:2, N:14>>;
encode(N) when N >= 0, N =< 1073741823 ->
    <<2:2, N:30>>;
encode(N) when N >= 0, N =< ?MAX_VARINT ->
    <<3:2, N:62>>;
encode(N) when N > ?MAX_VARINT ->
    error({varint_overflow, N});
encode(N) when N < 0 ->
    error({varint_negative, N}).

%% @doc Decode a QUIC variable-length integer from binary.
%% Returns {ok, Value, Rest} or {error, Reason}.
-spec decode(binary()) -> {ok, non_neg_integer(), binary()} | {error, term()}.
decode(Bin) ->
    decode_with_rest(Bin).

%% @doc Decode with explicit rest return.
-spec decode_with_rest(binary()) -> {ok, non_neg_integer(), binary()} | {error, term()}.
decode_with_rest(<<0:2, V:6, Rest/binary>>) ->
    {ok, V, Rest};
decode_with_rest(<<1:2, V:14, Rest/binary>>) ->
    {ok, V, Rest};
decode_with_rest(<<2:2, V:30, Rest/binary>>) ->
    {ok, V, Rest};
decode_with_rest(<<3:2, V:62, Rest/binary>>) ->
    {ok, V, Rest};
decode_with_rest(<<>>) ->
    {error, incomplete};
decode_with_rest(<<0:2, _:6>>) ->
    {error, incomplete};
decode_with_rest(<<1:2, _/bits>> = Bin) when byte_size(Bin) < 2 ->
    {error, incomplete};
decode_with_rest(<<2:2, _/bits>> = Bin) when byte_size(Bin) < 4 ->
    {error, incomplete};
decode_with_rest(<<3:2, _/bits>> = Bin) when byte_size(Bin) < 8 ->
    {error, incomplete}.

%% @doc Return the encoded size of an integer in bytes.
-spec encoded_size(non_neg_integer()) -> 1 | 2 | 4 | 8.
encoded_size(N) when N >= 0, N =< 63 -> 1;
encoded_size(N) when N >= 0, N =< 16383 -> 2;
encoded_size(N) when N >= 0, N =< 1073741823 -> 4;
encoded_size(N) when N >= 0, N =< ?MAX_VARINT -> 8.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

encode_decode_test_() ->
    [
        %% 1-byte encoding (0-63)
        ?_assertEqual(<<0>>, encode(0)),
        ?_assertEqual(<<63>>, encode(63)),

        %% 2-byte encoding (64-16383)
        ?_assertEqual(<<64, 64>>, encode(64)),
        ?_assertEqual(<<127, 255>>, encode(16383)),

        %% 4-byte encoding (16384-1073741823)
        ?_assertEqual(<<128, 0, 64, 0>>, encode(16384)),
        ?_assertEqual(<<191, 255, 255, 255>>, encode(1073741823)),

        %% 8-byte encoding
        ?_assertEqual(<<192, 0, 0, 0, 64, 0, 0, 0>>, encode(1073741824))
    ].

roundtrip_test_() ->
    Values = [0, 1, 63, 64, 100, 16383, 16384, 100000,
              1073741823, 1073741824, ?MAX_VARINT],
    [?_assertEqual({ok, V, <<>>}, decode(encode(V))) || V <- Values].

decode_with_rest_test_() ->
    [
        ?_assertEqual({ok, 42, <<"hello">>}, decode(<<42, "hello">>)),
        ?_assertEqual({ok, 100, <<1, 2, 3>>}, decode(<<64, 100, 1, 2, 3>>))
    ].

incomplete_test_() ->
    [
        ?_assertEqual({error, incomplete}, decode(<<>>)),
        ?_assertEqual({error, incomplete}, decode(<<64>>)),  %% Need 2 bytes
        ?_assertEqual({error, incomplete}, decode(<<128, 0, 0>>)),  %% Need 4 bytes
        ?_assertEqual({error, incomplete}, decode(<<192, 0, 0, 0, 0, 0, 0>>))  %% Need 8 bytes
    ].

encoded_size_test_() ->
    [
        ?_assertEqual(1, encoded_size(0)),
        ?_assertEqual(1, encoded_size(63)),
        ?_assertEqual(2, encoded_size(64)),
        ?_assertEqual(2, encoded_size(16383)),
        ?_assertEqual(4, encoded_size(16384)),
        ?_assertEqual(4, encoded_size(1073741823)),
        ?_assertEqual(8, encoded_size(1073741824))
    ].

-endif.
