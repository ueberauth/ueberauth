%%% -*- erlang -*-
%%%
%%% QUIC Packet Encoding/Decoding
%%% RFC 9000 Section 17
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC packet encoding and decoding.
%%%
%%% This module handles encoding and decoding of QUIC packets including:
%%% - Long header packets (Initial, Handshake, 0-RTT, Retry)
%%% - Short header packets (1-RTT)
%%%
%%% == Packet Header Format ==
%%%
%%% Long Header:
%%% ```
%%% +-+-+-+-+-+-+-+-+
%%% |1|1|T T|X X X X|
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% |                         Version (32)                          |
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% | DCID Len (8)  |
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% |               Destination Connection ID (0..160)            ...
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% | SCID Len (8)  |
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% |                 Source Connection ID (0..160)               ...
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% '''
%%%
%%% Short Header:
%%% ```
%%% +-+-+-+-+-+-+-+-+
%%% |0|1|S|R|R|K|P P|
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% |                Destination Connection ID (0..160)           ...
%%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%% '''
%%%

-module(quic_packet).

-include("quic.hrl").

-export([
    encode_long/5,
    type_to_bits/2,
    bits_to_type/2,
    encode_short/4,
    encode_short/5,
    encode_retry/5,
    encode_version_negotiation/3,
    decode/2,
    decode_short_key_phase/1,
    encode_pn/2,
    decode_pn/2,
    pn_length/1
]).

-export_type([packet_type/0, packet/0]).

-type packet_type() :: initial | handshake | zero_rtt | one_rtt | retry.
-type packet() :: #quic_packet{}.

%% RFC 9000: Connection IDs MUST NOT exceed 20 bytes
-define(MAX_CID_LEN, 20).
%% RFC 9000: Maximum token length (practical limit)
-define(MAX_TOKEN_LEN, 512).

%%====================================================================
%% API
%%====================================================================

%% @doc Encode a long header packet.
%% Type is one of: initial, handshake, zero_rtt, retry
%% Returns the encoded packet header + payload.
%% Note: For Initial packets, Token is required.
%% Note: Packet number and payload should already be encrypted.
-spec encode_long(
    packet_type(),
    non_neg_integer(),
    binary(),
    binary(),
    #{token => binary(), pn => non_neg_integer(), payload => binary()}
) ->
    binary().
encode_long(Type, Version, DCID, SCID, Opts) ->
    TypeBits = type_to_bits(Type, Version),
    Token = maps:get(token, Opts, <<>>),
    PN = maps:get(pn, Opts, 0),
    Payload = maps:get(payload, Opts, <<>>),

    %% Reserved bits (R R) are 0, packet number length encoded in low 2 bits
    PNLen = pn_length(PN),
    % 0 = 1 byte, 1 = 2 bytes, etc.
    PNLenBits = PNLen - 1,

    %% First byte: 1 | 1 | Type (2) | Reserved (2) | PN Len (2)
    FirstByte = 2#11000000 bor (TypeBits bsl 4) bor PNLenBits,

    DCIDLen = byte_size(DCID),
    SCIDLen = byte_size(SCID),

    case Type of
        initial ->
            TokenLen = byte_size(Token),
            PNBin = encode_pn(PN, PNLen),
            PayloadLen = byte_size(Payload) + PNLen,
            <<FirstByte, Version:32, DCIDLen, DCID/binary, SCIDLen, SCID/binary,
                (quic_varint:encode(TokenLen))/binary, Token/binary,
                (quic_varint:encode(PayloadLen))/binary, PNBin/binary, Payload/binary>>;
        handshake ->
            PNBin = encode_pn(PN, PNLen),
            PayloadLen = byte_size(Payload) + PNLen,
            <<FirstByte, Version:32, DCIDLen, DCID/binary, SCIDLen, SCID/binary,
                (quic_varint:encode(PayloadLen))/binary, PNBin/binary, Payload/binary>>;
        zero_rtt ->
            PNBin = encode_pn(PN, PNLen),
            PayloadLen = byte_size(Payload) + PNLen,
            <<FirstByte, Version:32, DCIDLen, DCID/binary, SCIDLen, SCID/binary,
                (quic_varint:encode(PayloadLen))/binary, PNBin/binary, Payload/binary>>;
        retry ->
            %% Retry packets have no packet number
            %% Payload contains Retry Token + Retry Integrity Tag
            <<FirstByte, Version:32, DCIDLen, DCID/binary, SCIDLen, SCID/binary, Payload/binary>>
    end.

%% @doc Encode a QUIC Retry packet (RFC 9000 §17.2.5).
%%
%% `OriginalDCID' is the DCID from the Initial that triggered this
%% Retry; it's mixed into the integrity tag per RFC 9001 §5.8 and is
%% NOT part of the wire image. `DCID' is the client's SCID (the
%% client expects us to address it by that), `SCID' is the fresh
%% server-side connection ID the client must use as DCID on its
%% retried Initial. `Token' is opaque; the server later validates
%% its own HMAC over it when the client returns it in the next
%% Initial. Returns the fully signed on-wire packet.
-spec encode_retry(OriginalDCID, DCID, SCID, Token, Version) -> binary() when
    OriginalDCID :: binary(),
    DCID :: binary(),
    SCID :: binary(),
    Token :: binary(),
    Version :: non_neg_integer().
encode_retry(OriginalDCID, DCID, SCID, Token, Version) ->
    %% 1 | 1 | Type | Unused (4). The type bits are version-specific
    %% (v1 retry = 0b11, v2 retry = 0b00, RFC 9369 §3.2). Lower 4 bits
    %% are covered by the integrity tag so they can be anything; pick a
    %% fixed value so packet captures are stable.
    FirstByte = 16#C0 bor (type_to_bits(retry, Version) bsl 4),
    PacketWithoutTag = <<
        FirstByte,
        Version:32,
        (byte_size(DCID)):8,
        DCID/binary,
        (byte_size(SCID)):8,
        SCID/binary,
        Token/binary
    >>,
    Tag = quic_crypto:compute_retry_integrity_tag(
        OriginalDCID, PacketWithoutTag, Version
    ),
    <<PacketWithoutTag/binary, Tag/binary>>.

%% @doc Encode a Version Negotiation packet.
%% RFC 9000 Section 17.2.1 - Version Negotiation Packet
%% The server sends this when it receives a packet with an unsupported version.
%% The DCID and SCID are copied from the received packet (swapped).
%% Versions is a list of supported version numbers.
-spec encode_version_negotiation(binary(), binary(), [non_neg_integer()]) -> binary().
encode_version_negotiation(DCID, SCID, Versions) ->
    %% First byte: long header form (1) | fixed bit (1) | random bits (6)
    %% Using 0xC0 | random bits for unused bits
    RandomBits = rand:uniform(64) - 1,
    FirstByte = 16#C0 bor RandomBits,
    DCIDLen = byte_size(DCID),
    SCIDLen = byte_size(SCID),
    %% Version = 0 indicates Version Negotiation
    VersionsData = encode_vn_versions(Versions),
    <<FirstByte:8, 0:32, DCIDLen:8, DCID/binary, SCIDLen:8, SCID/binary, VersionsData/binary>>.

%% @doc Encode a short header (1-RTT) packet with default key phase 0.
%% DCIDLen is the expected DCID length (from connection state).
%% Returns the encoded packet.
-spec encode_short(binary(), non_neg_integer(), binary(), boolean()) -> binary().
encode_short(DCID, PN, Payload, SpinBit) ->
    encode_short(DCID, PN, Payload, SpinBit, 0).

%% @doc Encode a short header (1-RTT) packet with explicit key phase.
%% KeyPhase is 0 or 1, indicating which set of keys was used for encryption.
%% Returns the encoded packet.
-spec encode_short(binary(), non_neg_integer(), binary(), boolean(), 0 | 1) -> binary().
encode_short(DCID, PN, Payload, SpinBit, KeyPhase) ->
    PNLen = pn_length(PN),
    PNLenBits = PNLen - 1,

    %% First byte: 0 | 1 | S | Reserved (2) | Key Phase | PN Len (2)
    %% S = Spin bit (bit 5), Reserved (bits 3-4), Key Phase (bit 2), PN Len (bits 0-1)
    SpinBitVal =
        case SpinBit of
            true -> 1;
            false -> 0
        end,
    KeyPhaseBit = KeyPhase band 1,
    FirstByte = 2#01000000 bor (SpinBitVal bsl 5) bor (KeyPhaseBit bsl 2) bor PNLenBits,

    PNBin = encode_pn(PN, PNLen),
    <<FirstByte, DCID/binary, PNBin/binary, Payload/binary>>.

%% @doc Extract the key phase bit from a short header first byte.
%% The key phase bit is bit 2 of the first byte (after header protection removal).
%% Returns 0 or 1.
-spec decode_short_key_phase(non_neg_integer()) -> 0 | 1.
decode_short_key_phase(FirstByte) ->
    (FirstByte bsr 2) band 1.

%% @doc Decode a QUIC packet.
%% DCIDLen is used for short header packets where DCID length is implicit.
%% Returns {ok, Packet, Rest} or {error, Reason}.
-spec decode(binary(), non_neg_integer()) ->
    {ok, packet(), binary()} | {error, term()}.
decode(<<1:1, _:7, _/binary>> = Bin, _DCIDLen) ->
    decode_long(Bin);
decode(<<0:1, _:7, _/binary>> = Bin, DCIDLen) ->
    decode_short(Bin, DCIDLen);
decode(<<>>, _) ->
    {error, empty}.

%% @doc Encode a packet number.
-spec encode_pn(non_neg_integer(), 1..4) -> binary().
encode_pn(PN, 1) -> <<PN:8>>;
encode_pn(PN, 2) -> <<PN:16>>;
encode_pn(PN, 3) -> <<PN:24>>;
encode_pn(PN, 4) -> <<PN:32>>.

%% @doc Decode a packet number.
-spec decode_pn(binary(), 1..4) -> {non_neg_integer(), binary()}.
decode_pn(<<PN:8, Rest/binary>>, 1) -> {PN, Rest};
decode_pn(<<PN:16, Rest/binary>>, 2) -> {PN, Rest};
decode_pn(<<PN:24, Rest/binary>>, 3) -> {PN, Rest};
decode_pn(<<PN:32, Rest/binary>>, 4) -> {PN, Rest}.

%% @doc Calculate the minimum number of bytes needed for a packet number.
-spec pn_length(non_neg_integer()) -> 1..4.
pn_length(PN) when PN < 256 -> 1;
pn_length(PN) when PN < 65536 -> 2;
pn_length(PN) when PN < 16777216 -> 3;
pn_length(_) -> 4.

%%====================================================================
%% Internal Functions
%%====================================================================

decode_long(<<_FirstByte, 0:32, DCIDLen, Rest/binary>>) when
    DCIDLen =< ?MAX_CID_LEN
->
    %% Version = 0 indicates Version Negotiation packet (RFC 9000 Section 17.2.1)
    case Rest of
        <<DCID:DCIDLen/binary, SCIDLen, Rest2/binary>> when
            SCIDLen =< ?MAX_CID_LEN
        ->
            <<SCID:SCIDLen/binary, VersionsData/binary>> = Rest2,
            Versions = decode_vn_versions(VersionsData),
            {ok, {version_negotiation, DCID, SCID, Versions}};
        _ ->
            {error, invalid_cid_length}
    end;
decode_long(<<FirstByte, Version:32, DCIDLen, Rest/binary>>) when
    DCIDLen =< ?MAX_CID_LEN
->
    case Rest of
        <<DCID:DCIDLen/binary, SCIDLen, Rest2/binary>> when
            SCIDLen =< ?MAX_CID_LEN
        ->
            <<SCID:SCIDLen/binary, Rest3/binary>> = Rest2,
            Type = bits_to_type((FirstByte bsr 4) band 2#11, Version),
            PNLenBits = FirstByte band 2#11,
            PNLen = PNLenBits + 1,
            decode_long_body(Type, Version, DCID, SCID, PNLen, Rest3);
        _ ->
            {error, invalid_cid_length}
    end;
decode_long(<<_FirstByte, _Version:32, DCIDLen, _Rest/binary>>) when
    DCIDLen > ?MAX_CID_LEN
->
    {error, invalid_cid_length};
decode_long(_) ->
    {error, invalid_packet}.

decode_long_body(Type, Version, DCID, SCID, PNLen, Rest3) ->
    case Type of
        initial ->
            {TokenLen, Rest4} = quic_varint:decode(Rest3),
            case TokenLen > ?MAX_TOKEN_LEN of
                true ->
                    {error, token_too_large};
                false ->
                    <<Token:TokenLen/binary, Rest5/binary>> = Rest4,
                    {PayloadLen, Rest6} = quic_varint:decode(Rest5),
                    {PN, Rest7} = decode_pn(Rest6, PNLen),
                    PayloadSize = PayloadLen - PNLen,
                    <<Payload:PayloadSize/binary, Rest8/binary>> = Rest7,
                    Packet = #quic_packet{
                        type = initial,
                        version = Version,
                        dcid = DCID,
                        scid = SCID,
                        token = Token,
                        pn = PN,
                        payload = Payload
                    },
                    {ok, Packet, Rest8}
            end;
        handshake ->
            {PayloadLen, Rest4} = quic_varint:decode(Rest3),
            {PN, Rest5} = decode_pn(Rest4, PNLen),
            PayloadSize = PayloadLen - PNLen,
            <<Payload:PayloadSize/binary, Rest6/binary>> = Rest5,
            Packet = #quic_packet{
                type = handshake,
                version = Version,
                dcid = DCID,
                scid = SCID,
                pn = PN,
                payload = Payload
            },
            {ok, Packet, Rest6};
        zero_rtt ->
            {PayloadLen, Rest4} = quic_varint:decode(Rest3),
            {PN, Rest5} = decode_pn(Rest4, PNLen),
            PayloadSize = PayloadLen - PNLen,
            <<Payload:PayloadSize/binary, Rest6/binary>> = Rest5,
            Packet = #quic_packet{
                type = zero_rtt,
                version = Version,
                dcid = DCID,
                scid = SCID,
                pn = PN,
                payload = Payload
            },
            {ok, Packet, Rest6};
        retry ->
            %% Retry packet: no length field, rest is token + integrity tag
            Packet = #quic_packet{
                type = retry,
                version = Version,
                dcid = DCID,
                scid = SCID,
                payload = Rest3
            },
            {ok, Packet, <<>>}
    end.

decode_short(<<FirstByte, Rest/binary>>, DCIDLen) ->
    <<DCID:DCIDLen/binary, Rest2/binary>> = Rest,
    PNLenBits = FirstByte band 2#11,
    PNLen = PNLenBits + 1,
    {PN, Payload} = decode_pn(Rest2, PNLen),
    %% Note: Payload here is still encrypted and includes AEAD tag
    Packet = #quic_packet{
        type = one_rtt,
        dcid = DCID,
        pn = PN,
        payload = Payload
    },
    {ok, Packet, <<>>}.

%% Long-header packet type bits are version-specific: QUIC v2 rotates
%% them (RFC 9369 §3.2) precisely so that v1-only middleboxes cannot
%% classify v2 packets. Encoding v1 bits under a v2 version field
%% produces packets no conforming peer will parse.
type_to_bits(initial, ?QUIC_VERSION_2) -> 1;
type_to_bits(zero_rtt, ?QUIC_VERSION_2) -> 2;
type_to_bits(handshake, ?QUIC_VERSION_2) -> 3;
type_to_bits(retry, ?QUIC_VERSION_2) -> 0;
type_to_bits(initial, _) -> 0;
type_to_bits(zero_rtt, _) -> 1;
type_to_bits(handshake, _) -> 2;
type_to_bits(retry, _) -> 3.

bits_to_type(1, ?QUIC_VERSION_2) -> initial;
bits_to_type(2, ?QUIC_VERSION_2) -> zero_rtt;
bits_to_type(3, ?QUIC_VERSION_2) -> handshake;
bits_to_type(0, ?QUIC_VERSION_2) -> retry;
bits_to_type(0, _) -> initial;
bits_to_type(1, _) -> zero_rtt;
bits_to_type(2, _) -> handshake;
bits_to_type(3, _) -> retry.

%% Encode a list of versions for VN packet
encode_vn_versions([]) ->
    <<>>;
encode_vn_versions([Version | Rest]) ->
    RestBin = encode_vn_versions(Rest),
    <<Version:32, RestBin/binary>>.

%% Decode versions from VN packet
decode_vn_versions(<<>>) ->
    [];
decode_vn_versions(<<Version:32, Rest/binary>>) ->
    [Version | decode_vn_versions(Rest)];
decode_vn_versions(_) ->
    [].
