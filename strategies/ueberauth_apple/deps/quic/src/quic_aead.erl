%%% -*- erlang -*-
%%%
%%% QUIC AEAD Packet Protection
%%% RFC 9001 Section 5 - Packet Protection
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc AEAD encryption/decryption for QUIC packet protection.
%%%
%%% QUIC uses AEAD algorithms (AES-GCM, ChaCha20-Poly1305) to protect
%%% packet payloads. Header protection is applied to hide the packet
%%% number and certain header flags.
%%%
%%% == Packet Protection ==
%%%
%%% The nonce for AEAD is computed by XORing the IV with the packet
%%% number (left-padded to 12 bytes).
%%%
%%% == Header Protection ==
%%%
%%% A sample from the encrypted payload is used to generate a mask
%%% that protects the first header byte and packet number bytes.
%%%

-module(quic_aead).

%% Suppress dialyzer warnings for cipher patterns not yet exercised
-dialyzer([no_match]).

-export([
    ecb_mask/3,
    otp_seal/5,
    otp_open/5,
    encrypt/5,
    encrypt/6,
    decrypt/5,
    decrypt/6,
    protect_header/4,
    protect_header/5,
    unprotect_header/4,
    unprotect_header/5,
    compute_nonce/2,
    compute_hp_mask/3,
    %% Consolidated packet protection API
    protect_short_packet/8,
    protect_long_packet/7,
    unprotect_short_packet/7,
    unprotect_long_packet/7,
    %% 2-stage short header receive API (for key-phase handling)
    unprotect_short_header/4,
    unprotect_short_header/5,
    decrypt_short_payload/8
]).

-export_type([cipher/0]).

-type cipher() :: aes_128_gcm | aes_256_gcm | chacha20_poly1305.

%% Tag length for AEAD algorithms (16 bytes)
-define(TAG_LEN, 16).

%% Header protection sample offset from start of encrypted payload
-define(HP_SAMPLE_OFFSET, 4).
-define(HP_SAMPLE_LEN, 16).

%% Minimum payload size for header protection sample
-define(MIN_PAYLOAD_FOR_SAMPLE, ?HP_SAMPLE_OFFSET + ?HP_SAMPLE_LEN).

%%====================================================================
%% API
%%====================================================================

%% @doc Encrypt a QUIC packet payload using AEAD.
%%
%% Key: AEAD key
%% IV: AEAD initialization vector
%% PN: Packet number (used with IV to create nonce)
%% AAD: Additional authenticated data (unprotected header)
%% Plaintext: Payload to encrypt
%%
%% Returns: Ciphertext with authentication tag appended
-spec encrypt(binary(), binary(), non_neg_integer(), binary(), binary()) ->
    binary().
encrypt(Key, IV, PN, AAD, Plaintext) ->
    Cipher = cipher_for_key(Key),
    encrypt(Key, IV, PN, AAD, Plaintext, Cipher).

%% @doc Encrypt with explicit cipher type.
%% Useful for ChaCha20-Poly1305 which also uses 32-byte keys.
-spec encrypt(binary(), binary(), non_neg_integer(), binary(), binary(), cipher()) ->
    binary().
encrypt(Key, IV, PN, AAD, Plaintext, Cipher) ->
    Nonce = compute_nonce(IV, PN),
    aead_seal(Cipher, Key, Nonce, AAD, Plaintext).

%% @doc Decrypt a QUIC packet payload using AEAD.
%%
%% Returns: {ok, Plaintext} | {error, bad_tag}
-spec decrypt(binary(), binary(), non_neg_integer(), binary(), binary()) ->
    {ok, binary()} | {error, bad_tag}.
decrypt(Key, IV, PN, AAD, CiphertextWithTag) ->
    Cipher = cipher_for_key(Key),
    decrypt(Key, IV, PN, AAD, CiphertextWithTag, Cipher).

%% @doc Decrypt with explicit cipher type.
%% Useful for ChaCha20-Poly1305 which also uses 32-byte keys.
-spec decrypt(binary(), binary(), non_neg_integer(), binary(), binary(), cipher()) ->
    {ok, binary()} | {error, bad_tag}.
decrypt(Key, IV, PN, AAD, CiphertextWithTag, Cipher) ->
    Nonce = compute_nonce(IV, PN),
    case aead_open(Cipher, Key, Nonce, AAD, CiphertextWithTag) of
        Plaintext when is_binary(Plaintext) ->
            {ok, Plaintext};
        error ->
            {error, bad_tag}
    end.

%% @doc Apply header protection to a QUIC packet.
%%
%% HP: Header protection key
%% Header: The packet header (first byte + rest + PN)
%% EncryptedPayload: The AEAD-encrypted payload (ciphertext + tag)
%% PNOffset: Offset of packet number in the header
%%
%% The sample is taken starting 4 bytes after the start of the Packet Number.
%% Since PN is at the end of Header, and ciphertext comes after PN:
%% sample_offset = 4 - PNLen (where PNLen is encoded in the first byte)
%%
%% Returns: Protected header (first byte and PN bytes masked), or
%%          {error, payload_too_short} if payload is too small for sampling.
-spec protect_header(binary(), binary(), binary(), non_neg_integer()) ->
    binary() | {error, payload_too_short}.
protect_header(HP, Header, EncryptedPayload, PNOffset) ->
    %% Infer the cipher from the key length. Ambiguous for 32-byte keys
    %% (AES-256-GCM vs ChaCha20-Poly1305); callers that know the cipher
    %% should use protect_header/5.
    protect_header(cipher_for_key(HP), HP, Header, EncryptedPayload, PNOffset).

%% @doc Apply header protection with an explicit cipher (avoids the
%% 32-byte key ambiguity between AES-256-GCM and ChaCha20-Poly1305).
-spec protect_header(cipher(), binary(), binary(), binary(), non_neg_integer()) ->
    binary() | {error, payload_too_short}.
protect_header(Cipher, HP, Header, EncryptedPayload, PNOffset) ->
    <<FirstByte, _/binary>> = Header,
    PNLen = (FirstByte band 16#03) + 1,
    %% Sample starts (4 - PNLen) bytes into ciphertext
    %% This is because sample_offset = pn_offset + 4 in the full packet
    %% And ciphertext starts at pn_offset + PNLen
    SampleOffset = max(0, 4 - PNLen),
    RequiredLen = SampleOffset + ?HP_SAMPLE_LEN,
    case byte_size(EncryptedPayload) >= RequiredLen of
        true ->
            Sample = binary:part(EncryptedPayload, SampleOffset, ?HP_SAMPLE_LEN),
            Mask = compute_hp_mask(Cipher, HP, Sample),
            apply_header_mask(Header, Mask, PNOffset);
        false ->
            {error, payload_too_short}
    end.

%% @doc Remove header protection from a QUIC packet.
%%
%% HP: Header protection key
%% ProtectedHeader: The protected header bytes (up to but not including PN)
%% EncryptedPayload: PN bytes + ciphertext + tag
%% PNOffset: Offset of packet number in the full header (= byte_size(ProtectedHeader))
%%
%% The sample is taken at position 4 from the start of PN.
%% Since EncryptedPayload starts with PN, sample is at position 4.
%%
%% Returns: {UnprotectedHeader, PNLength} or {error, payload_too_short}
-spec unprotect_header(binary(), binary(), binary(), non_neg_integer()) ->
    {binary(), pos_integer()} | {error, payload_too_short}.
unprotect_header(HP, ProtectedHeader, EncryptedPayload, PNOffset) ->
    %% See protect_header/4 re: the 32-byte key ambiguity.
    unprotect_header(cipher_for_key(HP), HP, ProtectedHeader, EncryptedPayload, PNOffset).

%% @doc Remove header protection with an explicit cipher.
-spec unprotect_header(cipher(), binary(), binary(), binary(), non_neg_integer()) ->
    {binary(), pos_integer()} | {error, payload_too_short}.
unprotect_header(Cipher, HP, ProtectedHeader, EncryptedPayload, _PNOffset) ->
    case byte_size(EncryptedPayload) >= ?MIN_PAYLOAD_FOR_SAMPLE of
        false ->
            {error, payload_too_short};
        true ->
            %% Sample is at position 4 from start of PN
            %% PN is at position 0 of EncryptedPayload
            Sample = binary:part(EncryptedPayload, ?HP_SAMPLE_OFFSET, ?HP_SAMPLE_LEN),
            Mask = compute_hp_mask(Cipher, HP, Sample),

            <<ProtectedFirstByte, HeaderRest/binary>> = ProtectedHeader,
            <<MaskByte0, MaskByte1, MaskByte2, MaskByte3, MaskByte4, _/binary>> = Mask,

            %% Unmask first byte to get PN length
            IsLongHeader = (ProtectedFirstByte band 16#80) =:= 16#80,
            FirstByteMask =
                case IsLongHeader of
                    true -> MaskByte0 band 16#0f;
                    false -> MaskByte0 band 16#1f
                end,
            FirstByte = ProtectedFirstByte bxor FirstByteMask,

            %% Get PN length from unmasked first byte
            PNLen = (FirstByte band 16#03) + 1,

            %% PN is at the start of EncryptedPayload. Unmask inline
            %% to avoid a crypto:exor/2 NIF call per packet — the PN
            %% is only 1-4 bytes so pure-Erlang XOR is cheaper.
            PN = xor_pn_bytes(
                EncryptedPayload, PNLen, MaskByte1, MaskByte2, MaskByte3, MaskByte4
            ),

            %% Return unprotected header (first byte + rest) with PN appended
            UnprotectedHeader = <<FirstByte, HeaderRest/binary, PN/binary>>,
            {UnprotectedHeader, PNLen}
    end.

%% Pure-Erlang XOR for the 1-4 byte packet-number mask. Replaces
%% crypto:exor/2 on the hot send/receive paths; only the first PNLen
%% bytes of the input are consumed.
xor_pn_bytes(<<B1, _/binary>>, 1, M1, _M2, _M3, _M4) ->
    <<(B1 bxor M1)>>;
xor_pn_bytes(<<B1, B2, _/binary>>, 2, M1, M2, _M3, _M4) ->
    <<(B1 bxor M1), (B2 bxor M2)>>;
xor_pn_bytes(<<B1, B2, B3, _/binary>>, 3, M1, M2, M3, _M4) ->
    <<(B1 bxor M1), (B2 bxor M2), (B3 bxor M3)>>;
xor_pn_bytes(<<B1, B2, B3, B4, _/binary>>, 4, M1, M2, M3, M4) ->
    <<(B1 bxor M1), (B2 bxor M2), (B3 bxor M3), (B4 bxor M4)>>.

%% @doc Compute the nonce for AEAD by XORing IV with packet number.
%% RFC 9001 Section 5.3: The 64 bits of the reconstructed QUIC packet number
%% in network byte order are left-padded with zeros to the size of the IV.
-spec compute_nonce(binary(), non_neg_integer()) -> binary().
compute_nonce(<<IV0:32, IV1:64>>, PN) ->
    <<IV0:32, (IV1 bxor PN):64>>.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Determine cipher type from key length
cipher_for_key(Key) when byte_size(Key) =:= 16 -> aes_128_gcm;
cipher_for_key(Key) when byte_size(Key) =:= 32 -> aes_256_gcm.
%% Note: ChaCha20-Poly1305 also uses 32-byte keys, but we'd need
%% additional context to distinguish it from AES-256-GCM.

%% Compute header protection mask
compute_hp_mask(aes_128_gcm, HP, Sample) ->
    %% AES-ECB encryption of sample
    quic_aead_ctx:hp_block(aes_128_ecb, HP, Sample);
compute_hp_mask(aes_256_gcm, HP, Sample) ->
    %% HP for AES-256 is 32 bytes, use aes_256_ecb
    quic_aead_ctx:hp_block(aes_256_ecb, HP, Sample);
compute_hp_mask(chacha20_poly1305, HP, Sample) ->
    %% ChaCha20 with counter=0 and the sample as nonce
    %% Sample is 16 bytes: first 4 = counter, last 12 = nonce
    <<Counter:32/little, Nonce:12/binary>> = Sample,
    %% Generate 5 bytes of mask using ChaCha20
    Zeros = <<0, 0, 0, 0, 0>>,
    crypto:crypto_one_time(chacha20, HP, <<Counter:32/little, Nonce/binary>>, Zeros, true).

%% Header protection runs on every packet in both directions, and
%% crypto:crypto_one_time/4 re-runs the key schedule on each call: a
%% 16-byte ECB block costs 0.77us against 0.88us for a 1200-byte AEAD
%% seal, so nearly all of it is per-call setup. Keeping the cipher
%% context alive drops that to 0.55us. ECB blocks are independent, so a
%% reused context yields byte-identical output.
%%
%% The context is a NIF resource and is not thread-safe, so it is cached
%% in the calling process. A connection holds two HP keys per cipher at
%% once, one per direction, and they alternate packet by packet: a
%% single-entry cache makes them evict each other and re-runs the key
%% schedule anyway. Both are kept, and a key update (a third key) drops
%% the pair rather than letting the cache grow.
%% Header-protection block on a cached ECB context (the pure-Erlang
%% path; quic_aead_ctx:hp_block/3 falls back to this without the NIF).
ecb_mask(Cipher, Key, Sample) ->
    crypto:crypto_update(ecb_ctx(Cipher, Key), Sample).

%% @private
%% Seal one packet, returning Ciphertext||Tag. Tries the optional
%% crypto NIF first; otp_seal/5 below is what it degrades to.
aead_seal(Cipher, Key, Nonce, AAD, Plaintext) ->
    quic_aead_ctx:aead_encrypt(Cipher, Key, Nonce, Plaintext, AAD).

%% @private
%% Open one packet, taking Ciphertext||Tag and returning the plaintext
%% or `error'. Same layering as aead_seal/5.
aead_open(Cipher, Key, Nonce, AAD, CiphertextWithTag) ->
    quic_aead_ctx:aead_decrypt(Cipher, Key, Nonce, CiphertextWithTag, AAD).

%% @private
%% Seal on OTP crypto alone, with a reusable cipher context where the
%% running release has one. Reached from quic_aead_ctx when the NIF is
%% absent, so it must not call back into it.
%%
%% crypto:crypto_one_time_aead/7 re-runs the key schedule on every
%% call, and QUIC seals each packet as its own AEAD unit, so that cost
%% lands on every packet. crypto_one_time_aead_init/4 (OTP 28+) returns
%% a handle usable across nonces; without it this is the old one-shot.
otp_seal(Cipher, Key, Nonce, AAD, Plaintext) ->
    case aead_ctx(Cipher, Key, true) of
        undefined ->
            {Ciphertext, Tag} = crypto:crypto_one_time_aead(
                Cipher, Key, Nonce, Plaintext, AAD, ?TAG_LEN, true
            ),
            <<Ciphertext/binary, Tag/binary>>;
        Ctx ->
            crypto:crypto_one_time_aead(Ctx, Nonce, Plaintext, AAD)
    end.

%% @private
%% Open on OTP crypto alone. Takes Ciphertext||Tag and returns the
%% plaintext or `error'. Input too short to hold a tag is rejected here: the context
%% API raises on it, and splitting it by hand would fail the binary
%% match, so neither path may be handed one.
otp_open(_Cipher, _Key, _Nonce, _AAD, CiphertextWithTag) when
    byte_size(CiphertextWithTag) < ?TAG_LEN
->
    error;
otp_open(Cipher, Key, Nonce, AAD, CiphertextWithTag) ->
    case aead_ctx(Cipher, Key, false) of
        undefined ->
            CipherLen = byte_size(CiphertextWithTag) - ?TAG_LEN,
            <<Ciphertext:CipherLen/binary, Tag:?TAG_LEN/binary>> = CiphertextWithTag,
            crypto:crypto_one_time_aead(Cipher, Key, Nonce, Ciphertext, AAD, Tag, false);
        Ctx ->
            crypto:crypto_one_time_aead(Ctx, Nonce, CiphertextWithTag, AAD)
    end.

%% Same caching shape and rationale as ecb_ctx/2: two keys per
%% direction are live across a key update, a third drops the pair.
%% `undefined' means the running OTP has no context API.
aead_ctx(Cipher, Key, Enc) ->
    case aead_ctx_api() andalso byte_size(Key) =:= aead_key_len(Cipher) of
        false ->
            undefined;
        true ->
            CacheKey = {aead_ctx, Cipher, Enc},
            Cache =
                case erlang:get(CacheKey) of
                    undefined -> #{};
                    M -> M
                end,
            case Cache of
                #{Key := Ctx} ->
                    Ctx;
                _ ->
                    Ctx = crypto:crypto_one_time_aead_init(Cipher, Key, ?TAG_LEN, Enc),
                    Kept =
                        case map_size(Cache) >= 2 of
                            true -> #{};
                            false -> Cache
                        end,
                    erlang:put(CacheKey, Kept#{Key => Ctx}),
                    Ctx
            end
    end.

%% crypto:crypto_one_time_aead_init/4 does not check the key length and
%% takes the emulator down on a wrong one, where the one-shot raises
%% badarg. Keep the context path to lengths we have checked ourselves,
%% so a bad key fails the same way it always did.
aead_key_len(aes_128_gcm) -> 16;
aead_key_len(aes_256_gcm) -> 32;
aead_key_len(chacha20_poly1305) -> 32;
aead_key_len(_) -> undefined.

%% OTP 28+. Checked through module_info so the lookup loads crypto
%% rather than answering false because it is not loaded yet, and cached
%% because this is on the per-packet path.
aead_ctx_api() ->
    case erlang:get(aead_ctx_api) of
        undefined ->
            V = lists:member({crypto_one_time_aead_init, 4}, crypto:module_info(exports)),
            erlang:put(aead_ctx_api, V),
            V;
        V ->
            V
    end.

ecb_ctx(Cipher, Key) ->
    Cache =
        case erlang:get({hp_ctx, Cipher}) of
            undefined -> #{};
            M -> M
        end,
    case Cache of
        #{Key := Ctx} ->
            Ctx;
        _ ->
            Ctx = crypto:crypto_init(Cipher, Key, true),
            Kept =
                case map_size(Cache) >= 2 of
                    true -> #{};
                    false -> Cache
                end,
            erlang:put({hp_ctx, Cipher}, Kept#{Key => Ctx}),
            Ctx
    end.

%% Apply mask to header (for protection)
apply_header_mask(Header, Mask, PNOffset) ->
    <<FirstByte, Rest/binary>> = Header,
    <<MaskByte0, MaskByte1, MaskByte2, MaskByte3, MaskByte4, _/binary>> = Mask,

    %% Determine PN length from first byte (bits 0-1 for short, bits 0-1 for long)
    %% The PN length is encoded in the two least significant bits + 1
    PNLen = (FirstByte band 16#03) + 1,

    %% Mask first byte: for long header, mask lower 4 bits; for short, mask lower 5 bits
    IsLongHeader = (FirstByte band 16#80) =:= 16#80,
    FirstByteMask =
        case IsLongHeader of
            % Long header: mask bits 0-3
            true -> MaskByte0 band 16#0f;
            % Short header: mask bits 0-4
            false -> MaskByte0 band 16#1f
        end,
    ProtectedFirstByte = FirstByte bxor FirstByteMask,

    %% Split header at PN offset

    % -1 because we already split off first byte
    BeforePNLen = PNOffset - 1,
    <<BeforePN:BeforePNLen/binary, PN:PNLen/binary, AfterPN/binary>> = Rest,

    %% Inline pure-Erlang XOR for the PN bytes (see xor_pn_bytes/6).
    ProtectedPN = xor_pn_bytes(
        PN, PNLen, MaskByte1, MaskByte2, MaskByte3, MaskByte4
    ),

    <<ProtectedFirstByte, BeforePN/binary, ProtectedPN/binary, AfterPN/binary>>.

%%====================================================================
%% Consolidated Packet Protection API
%%====================================================================

%% @doc Protect a short header (1-RTT) packet.
%% Performs encryption and header protection in a single call.
%%
%% Cipher: AEAD cipher type
%% Key: AEAD key
%% IV: AEAD initialization vector
%% HP: Header protection key
%% PN: Packet number
%% FirstByte: First byte of header (includes spin bit, key phase, etc.)
%% DCID: Destination Connection ID
%% Plaintext: Payload to encrypt
%%
%% Returns: Complete protected packet binary
-spec protect_short_packet(
    cipher(),
    binary(),
    binary(),
    binary(),
    non_neg_integer(),
    byte(),
    binary(),
    iodata()
) -> binary().
protect_short_packet(Cipher, Key, IV, HP, PN, FirstByte, DCID, Plaintext) ->
    PNLen = pn_length(PN),
    PNBin = encode_pn(PN, PNLen),
    HeaderPrefix = <<FirstByte, DCID/binary>>,
    protect_packet_common(Cipher, Key, IV, HP, PN, HeaderPrefix, PNBin, Plaintext).

%% @doc Protect a long header (Initial/Handshake/0-RTT) packet.
%% Performs encryption and header protection in a single call.
%%
%% Cipher: AEAD cipher type
%% Key: AEAD key
%% IV: AEAD initialization vector
%% HP: Header protection key
%% PN: Packet number
%% HeaderPrefix: Long header up to (but not including) the packet number
%% Plaintext: Payload to encrypt
%%
%% Returns: Complete protected packet binary
-spec protect_long_packet(
    cipher(),
    binary(),
    binary(),
    binary(),
    non_neg_integer(),
    binary(),
    iodata()
) -> binary().
protect_long_packet(Cipher, Key, IV, HP, PN, HeaderPrefix, Plaintext) ->
    PNLen = pn_length(PN),
    PNBin = encode_pn(PN, PNLen),
    protect_packet_common(Cipher, Key, IV, HP, PN, HeaderPrefix, PNBin, Plaintext).

%% @doc Shared core for packet protection.
%% Encrypts payload with AEAD, then applies header protection.
protect_packet_common(Cipher, Key, IV, HP, PN, HeaderPrefix, PNBin, Plaintext) ->
    AAD = <<HeaderPrefix/binary, PNBin/binary>>,
    Nonce = compute_nonce(IV, PN),
    EncryptedPayload = aead_seal(Cipher, Key, Nonce, AAD, Plaintext),
    PNOffset = byte_size(HeaderPrefix),
    ProtectedHeader = protect_header(Cipher, HP, AAD, EncryptedPayload, PNOffset),
    <<ProtectedHeader/binary, EncryptedPayload/binary>>.

%% @doc Unprotect and decrypt a short header (1-RTT) packet.
%%
%% Cipher: AEAD cipher type
%% Key: AEAD key
%% IV: AEAD initialization vector
%% HP: Header protection key
%% Header: Protected header (first byte + DCID, without PN)
%% EncryptedPayload: PN bytes + ciphertext + tag
%% LargestRecv: Largest received packet number for PN reconstruction
%%
%% Returns: {ok, PN, UnprotectedHeader, Plaintext} | {error, term()}
-spec unprotect_short_packet(
    cipher(),
    binary(),
    binary(),
    binary(),
    binary(),
    binary(),
    non_neg_integer() | undefined
) ->
    {ok, non_neg_integer(), binary(), binary()} | {error, term()}.
unprotect_short_packet(Cipher, Key, IV, HP, Header, EncryptedPayload, LargestRecv) ->
    unprotect_packet_common(Cipher, Key, IV, HP, Header, EncryptedPayload, LargestRecv).

%% @doc Unprotect and decrypt a long header (Initial/Handshake/0-RTT) packet.
%%
%% Cipher: AEAD cipher type
%% Key: AEAD key
%% IV: AEAD initialization vector
%% HP: Header protection key
%% Header: Protected header up to (but not including) the PN
%% EncryptedPayload: PN bytes + ciphertext + tag
%% LargestRecv: Largest received packet number for PN reconstruction
%%
%% Returns: {ok, PN, UnprotectedHeader, Plaintext} | {error, term()}
-spec unprotect_long_packet(
    cipher(),
    binary(),
    binary(),
    binary(),
    binary(),
    binary(),
    non_neg_integer() | undefined
) ->
    {ok, non_neg_integer(), binary(), binary()} | {error, term()}.
unprotect_long_packet(Cipher, Key, IV, HP, Header, EncryptedPayload, LargestRecv) ->
    unprotect_packet_common(Cipher, Key, IV, HP, Header, EncryptedPayload, LargestRecv).

%% @doc Shared core for packet unprotection.
%% Removes header protection, reconstructs PN, and decrypts payload.
unprotect_packet_common(Cipher, Key, IV, HP, Header, EncryptedPayload, LargestRecv) ->
    PNOffset = byte_size(Header),
    case unprotect_header(Cipher, HP, Header, EncryptedPayload, PNOffset) of
        {error, Reason} ->
            {error, {header_unprotect_failed, Reason}};
        {UnprotectedHeader, PNLen} ->
            %% Extract truncated PN
            UnprotHeaderLen = byte_size(UnprotectedHeader),
            <<_:((UnprotHeaderLen - PNLen) * 8), TruncatedPN:PNLen/unit:8>> = UnprotectedHeader,

            %% Reconstruct full PN
            PN = reconstruct_pn(LargestRecv, TruncatedPN, PNLen),

            %% AAD is the full unprotected header
            AAD = UnprotectedHeader,

            %% Ciphertext starts after PN bytes
            <<_:PNLen/binary, Ciphertext/binary>> = EncryptedPayload,

            %% Decrypt
            Nonce = compute_nonce(IV, PN),
            case aead_open(Cipher, Key, Nonce, AAD, Ciphertext) of
                Plaintext when is_binary(Plaintext) ->
                    {ok, PN, UnprotectedHeader, Plaintext};
                error ->
                    {error, decryption_failed}
            end
    end.

%%====================================================================
%% 2-Stage Short Header Receive API
%%====================================================================
%% For 1-RTT packets, key selection depends on the key_phase bit which
%% is header-protected. This 2-stage API allows:
%% 1. Unprotect header to recover key_phase, then select correct keys
%% 2. Decrypt payload with selected keys

%% @doc Stage 1: Unprotect short header to recover key_phase and PN info.
%% Uses HP key (same regardless of key phase) to unprotect header.
%%
%% HP: Header protection key
%% Header: Protected header (first byte + DCID)
%% EncryptedPayload: PN bytes + ciphertext + tag
%% PNOffset: Offset to packet number in header (= byte_size(Header))
%%
%% Returns: {ok, KeyPhase, PNLen, TruncatedPN, UnprotectedHeader} | {error, term()}
-spec unprotect_short_header(binary(), binary(), binary(), non_neg_integer()) ->
    {ok, 0 | 1, 1..4, non_neg_integer(), binary()} | {error, term()}.
unprotect_short_header(HP, Header, EncryptedPayload, PNOffset) ->
    %% Guesses the cipher from the HP key length, which cannot tell
    %% AES-256-GCM from ChaCha20-Poly1305. Prefer the /5 variant.
    unprotect_short_header(cipher_for_key(HP), HP, Header, EncryptedPayload, PNOffset).

%% @doc Like unprotect_short_header/4 but with the cipher given by the
%% caller, which is required when ChaCha20-Poly1305 is negotiated: its
%% 32-byte HP key is indistinguishable from AES-256-GCM's, and the two
%% mask constructions are unrelated.
-spec unprotect_short_header(cipher(), binary(), binary(), binary(), non_neg_integer()) ->
    {ok, 0 | 1, 1..4, non_neg_integer(), binary()} | {error, term()}.
unprotect_short_header(Cipher, HP, Header, EncryptedPayload, PNOffset) ->
    case unprotect_header(Cipher, HP, Header, EncryptedPayload, PNOffset) of
        {error, Reason} ->
            {error, {header_unprotect_failed, Reason}};
        {UnprotectedHeader, PNLen} ->
            %% Extract key_phase from unprotected first byte (bit 2)
            <<FirstByte, _/binary>> = UnprotectedHeader,
            KeyPhase = (FirstByte bsr 2) band 1,

            %% Extract truncated PN
            UnprotHeaderLen = byte_size(UnprotectedHeader),
            <<_:((UnprotHeaderLen - PNLen) * 8), TruncatedPN:PNLen/unit:8>> = UnprotectedHeader,

            {ok, KeyPhase, PNLen, TruncatedPN, UnprotectedHeader}
    end.

%% @doc Stage 2: Decrypt short packet payload after key selection.
%% Called after unprotect_short_header with the correct keys based on key_phase.
%%
%% Cipher: AEAD cipher type
%% Key: AEAD key (selected based on key_phase from stage 1)
%% IV: AEAD IV (selected based on key_phase from stage 1)
%% UnprotectedHeader: From stage 1 (used as AAD)
%% PNLen: From stage 1
%% TruncatedPN: From stage 1
%% EncryptedPayload: PN bytes + ciphertext + tag
%% LargestRecv: Largest received packet number for PN reconstruction
%%
%% Returns: {ok, PN, Plaintext} | {error, term()}
-spec decrypt_short_payload(
    cipher(),
    binary(),
    binary(),
    binary(),
    1..4,
    non_neg_integer(),
    binary(),
    non_neg_integer() | undefined
) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.
decrypt_short_payload(
    Cipher, Key, IV, UnprotectedHeader, PNLen, TruncatedPN, EncryptedPayload, LargestRecv
) ->
    %% Reconstruct full PN
    PN = reconstruct_pn(LargestRecv, TruncatedPN, PNLen),

    %% AAD is the full unprotected header
    AAD = UnprotectedHeader,

    %% Ciphertext starts after PN bytes
    <<_:PNLen/binary, Ciphertext/binary>> = EncryptedPayload,

    %% Decrypt
    Nonce = compute_nonce(IV, PN),
    case aead_open(Cipher, Key, Nonce, AAD, Ciphertext) of
        Plaintext when is_binary(Plaintext) ->
            {ok, PN, Plaintext};
        error ->
            {error, decryption_failed}
    end.

%% Reconstruct full packet number from truncated PN (RFC 9000 Appendix A)
reconstruct_pn(undefined, TruncatedPN, _PNLen) ->
    %% No previous packets, use truncated PN directly
    TruncatedPN;
reconstruct_pn(LargestRecv, TruncatedPN, PNLen) ->
    %% RFC 9000 Appendix A: Packet Number Decoding
    PNWin = 1 bsl (PNLen * 8),
    PNHalfWin = PNWin div 2,
    %% Expected PN is one more than largest received
    ExpectedPN = LargestRecv + 1,
    %% Candidate PN in the expected range
    CandidatePN = (ExpectedPN band (bnot (PNWin - 1))) bor TruncatedPN,
    %% Adjust candidate based on window
    adjust_candidate_pn(CandidatePN, ExpectedPN, PNWin, PNHalfWin).

%% Check if candidate is in the valid window and adjust
adjust_candidate_pn(CandidatePN, ExpectedPN, PNWin, PNHalfWin) when
    CandidatePN =< ExpectedPN - PNHalfWin, CandidatePN < (1 bsl 62) - PNWin
->
    CandidatePN + PNWin;
adjust_candidate_pn(CandidatePN, ExpectedPN, PNWin, PNHalfWin) when
    CandidatePN > ExpectedPN + PNHalfWin, CandidatePN >= PNWin
->
    CandidatePN - PNWin;
adjust_candidate_pn(CandidatePN, _ExpectedPN, _PNWin, _PNHalfWin) ->
    CandidatePN.

%% Local packet number helpers (avoid circular dependency with quic_packet)
pn_length(PN) when PN < 256 -> 1;
pn_length(PN) when PN < 65536 -> 2;
pn_length(PN) when PN < 16777216 -> 3;
pn_length(_) -> 4.

encode_pn(PN, 1) -> <<PN:8>>;
encode_pn(PN, 2) -> <<PN:16>>;
encode_pn(PN, 3) -> <<PN:24>>;
encode_pn(PN, 4) -> <<PN:32>>.
