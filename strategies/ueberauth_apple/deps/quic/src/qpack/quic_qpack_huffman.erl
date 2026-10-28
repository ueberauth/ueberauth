%%% -*- erlang -*-
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Huffman encoding and decoding for QPACK (RFC 9204).
%%%
%%% RFC 7541 Appendix B defines the Huffman code table used by both
%%% HPACK (HTTP/2) and QPACK (HTTP/3). This module provides encoding
%%% and decoding functions.
%%% @end

-module(quic_qpack_huffman).

-export([
    encode/1,
    decode/1,
    decode_safe/1,
    encoded_size/1
]).

-include("quic_qpack_huffman_enc.hrl").
-include("quic_qpack_huffman_dec.hrl").

%%====================================================================
%% API
%%====================================================================

%% @doc Encode a binary string using Huffman coding.
%% Returns the Huffman-encoded binary, padded with EOS bits.
-spec encode(binary()) -> binary().
encode(Data) ->
    encode(Data, 0, <<>>).

%% @doc Decode a Huffman-encoded binary.
%% Returns the decoded binary string.
%% Note: This function does not validate EOS padding per RFC 7541 Section 5.2.
%% Use decode_safe/1 for strict validation.
-spec decode(binary()) -> binary().
decode(Data) ->
    decode(Data, byte_size(Data), 0, <<>>).

%% @doc Decode a Huffman-encoded binary with strict validation.
%% Returns {ok, Decoded} on success, {error, Reason} on failure.
%% Per RFC 7541 Section 5.2:
%% - Padding MUST be the most-significant bits of EOS symbol (all 1s)
%% - Padding MUST NOT be more than 7 bits
%% - A string literal containing EOS MUST be treated as decoding error
-spec decode_safe(binary()) -> {ok, binary()} | {error, term()}.
decode_safe(Data) ->
    try
        Decoded = decode_validated(Data, byte_size(Data), 0, <<>>),
        %% A non-empty Huffman string must decode to at least one symbol
        %% (padding is only the <= 7 trailing bits after the last symbol).
        %% An empty result from non-empty input means the whole input was
        %% padding, which exceeds the 7-bit maximum (RFC 7541 §5.2).
        case Data =/= <<>> andalso Decoded =:= <<>> of
            true -> {error, invalid_padding};
            false -> {ok, Decoded}
        end
    catch
        throw:{huffman_error, Reason} -> {error, Reason}
    end.

%% @doc Calculate the size in bytes of Huffman-encoded data.
%% Useful for deciding whether Huffman encoding is beneficial.
-spec encoded_size(binary()) -> non_neg_integer().
encoded_size(Data) ->
    Bits = encoded_bits(Data, 0),
    (Bits + 7) div 8.

%%====================================================================
%% Internal - Encoding
%%====================================================================

-spec encode(binary(), non_neg_integer(), binary()) -> binary().
encode(<<>>, 0, Acc) ->
    Acc;
encode(<<>>, N, Acc) when N > 0 ->
    %% Pad with EOS prefix (all 1s) to byte boundary
    %% N is 1-7 here, so Pad is also 1-7
    Pad = 8 - N,
    PadBits = (1 bsl Pad) - 1,
    <<Acc/bits, PadBits:Pad>>;
encode(<<Byte, Rest/binary>>, N, Acc) ->
    {Code, Bits} = element(Byte + 1, ?HUFFMAN_ENCODE_TABLE),
    encode(Rest, (N + Bits) band 7, <<Acc/bits, Code:Bits>>).

-spec encoded_bits(binary(), non_neg_integer()) -> non_neg_integer().
encoded_bits(<<>>, Acc) ->
    Acc;
encoded_bits(<<Byte, Rest/binary>>, Acc) ->
    {_, Bits} = element(Byte + 1, ?HUFFMAN_ENCODE_TABLE),
    encoded_bits(Rest, Acc + Bits).

%%====================================================================
%% Internal - Decoding
%%====================================================================

-spec decode(binary(), non_neg_integer(), non_neg_integer(), binary()) -> binary().
decode(<<A:4, B:4, R/bits>>, Len, State0, Acc) when Len > 1 ->
    {_, CharA, State1} = dec_huffman_lookup(State0, A),
    {_, CharB, State} = dec_huffman_lookup(State1, B),
    NewAcc =
        case {CharA, CharB} of
            {undefined, undefined} -> Acc;
            {C, undefined} -> <<Acc/binary, C>>;
            {undefined, C} -> <<Acc/binary, C>>;
            {C1, C2} -> <<Acc/binary, C1, C2>>
        end,
    decode(R, Len - 1, State, NewAcc);
decode(<<A:4, B:4, _Rest/bits>>, 1, State0, Acc) ->
    {_, CharA, State} = dec_huffman_lookup(State0, A),
    case dec_huffman_lookup(State, B) of
        {ok, CharB, _} ->
            case {CharA, CharB} of
                {undefined, undefined} -> Acc;
                {C, undefined} -> <<Acc/binary, C>>;
                {undefined, C} -> <<Acc/binary, C>>;
                {C1, C2} -> <<Acc/binary, C1, C2>>
            end;
        {more, _, _} ->
            case CharA of
                undefined -> Acc;
                C -> <<Acc/binary, C>>
            end
    end;
decode(_Rest, 0, _, Acc) ->
    Acc.

%% Validated decoding - same as decode/4 but validates EOS padding
-spec decode_validated(binary(), non_neg_integer(), non_neg_integer(), binary()) -> binary().
decode_validated(<<A:4, B:4, R/bits>>, Len, State0, Acc) when Len > 1 ->
    {_, CharA, State1} = lookup_or_fail(State0, A),
    {_, CharB, State} = lookup_or_fail(State1, B),
    NewAcc =
        case {CharA, CharB} of
            {undefined, undefined} -> Acc;
            {C, undefined} -> <<Acc/binary, C>>;
            {undefined, C} -> <<Acc/binary, C>>;
            {C1, C2} -> <<Acc/binary, C1, C2>>
        end,
    decode_validated(R, Len - 1, State, NewAcc);
decode_validated(<<A:4, B:4, _Rest/bits>>, 1, State0, Acc) ->
    {_StatusA, CharA, State1} = lookup_or_fail(State0, A),
    {StatusB, CharB, FinalState} = lookup_or_fail(State1, B),
    %% Validate termination per RFC 7541 Section 5.2
    case StatusB of
        ok when FinalState =:= 16#00 ->
            %% Clean symbol boundary, always valid
            append_chars(Acc, CharA, CharB);
        ok ->
            %% Ended with a complete symbol but not at reset state
            %% This is OK - the symbol is complete
            append_chars(Acc, CharA, CharB);
        more ->
            %% Mid-symbol - validate that remaining bits are valid EOS padding
            %% The nibble B should have all consumed bits as 1s
            case is_valid_padding(State1, B) of
                true ->
                    case CharA of
                        undefined -> Acc;
                        C -> <<Acc/binary, C>>
                    end;
                false ->
                    throw({huffman_error, invalid_padding})
            end
    end;
decode_validated(_Rest, 0, _, Acc) ->
    Acc.

%% dec_huffman_lookup/2 returns the bare atom `error' on an invalid state
%% transition; turn that into a thrown huffman_error so decode_safe/1
%% reports {error, _} instead of crashing on a badmatch.
lookup_or_fail(State, Nibble) ->
    case dec_huffman_lookup(State, Nibble) of
        error -> throw({huffman_error, invalid_code});
        Result -> Result
    end.

%% Check if the padding nibble is valid EOS padding
%% Valid padding must be the most-significant bits of EOS (all 1s)
-spec is_valid_padding(non_neg_integer(), non_neg_integer()) -> boolean().
is_valid_padding(_State, 16#F) ->
    %% 1111 - all bits are 1, valid for any amount of padding
    true;
is_valid_padding(State, Nibble) ->
    %% For states that accept partial symbols, check if Nibble
    %% represents valid EOS prefix bits
    %% The EOS symbol is all 1s, so valid padding nibbles are:
    %% - 1111 (0xF) for 4+ bits of padding
    %% - 1110 (0xE) for 3 bits of padding
    %% - 1100 (0xC) for 2 bits of padding
    %% - 1000 (0x8) for 1 bit of padding
    %% But we need to know how many bits were actually consumed
    %% For simplicity, we check if the nibble has all high bits set
    %% based on common padding patterns
    case dec_huffman_lookup(State, 16#F) of
        {ok, undefined, 16#00} ->
            %% State accepts 1111 as valid termination
            %% Check if Nibble is a prefix of 1111
            is_eos_prefix(Nibble);
        _ ->
            %% Conservative: only accept all-1s padding
            Nibble =:= 16#F
    end.

%% Check if nibble is a valid EOS prefix (high bits are 1)
-spec is_eos_prefix(non_neg_integer()) -> boolean().
%% 1111 - 4 bits of 1
is_eos_prefix(16#F) -> true;
%% 1110 - 3 bits of 1, 1 bit unused
is_eos_prefix(16#E) -> true;
%% 1100 - 2 bits of 1, 2 bits unused
is_eos_prefix(16#C) -> true;
%% 1000 - 1 bit of 1, 3 bits unused
is_eos_prefix(16#8) -> true;
is_eos_prefix(_) -> false.

%% Append characters to accumulator
-spec append_chars(binary(), non_neg_integer() | undefined, non_neg_integer() | undefined) ->
    binary().
append_chars(Acc, undefined, undefined) -> Acc;
append_chars(Acc, C, undefined) -> <<Acc/binary, C>>;
append_chars(Acc, undefined, C) -> <<Acc/binary, C>>;
append_chars(Acc, C1, C2) -> <<Acc/binary, C1, C2>>.
