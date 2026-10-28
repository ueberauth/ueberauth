%%% -*- erlang -*-
%%%
%%% QUIC-LB Connection ID Encoding
%%% RFC 9312 - QUIC-LB: Generating Routable QUIC Connection IDs
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC Load Balancer Connection ID encoding and decoding.
%%%
%%% This module implements RFC 9312 Connection ID encoding schemes
%%% that allow load balancers to route QUIC packets to the correct
%%% server based on server identity encoded in the Connection ID.
%%%
%%% == CID Format ==
%%%
%%% The first byte contains:
%%% - CR (Config Rotation): 3 bits identifying the configuration
%%% - Length: 5 bits (CID length - 1, so 0-19 maps to 1-20 bytes)
%%%
%%% <pre>
%%% +--------+----------------+--------+
%%% | CR:3   | Server ID      | Nonce  |
%%% | Len:5  | (1-15 bytes)   | (4-18) |
%%% +--------+----------------+--------+
%%% </pre>
%%%
%%% == Algorithms ==
%%%
%%% 1. Plaintext: No encryption, server_id visible in CID
%%% 2. Stream Cipher: AES-128-CTR encrypts first octet + server_id
%%% 3. Block Cipher: AES-128-ECB with Feistel network for non-16-byte
%%%
%%% @end

-module(quic_lb).

-export([
    new_config/1,
    new_cid_config/1,
    validate_config/1,
    generate_cid/1,
    generate_cid/2,
    decode_server_id/2,
    get_config_rotation/1,
    is_lb_routable/1,
    expected_cid_len/1
]).

-include("quic.hrl").

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new LB configuration from options map.
%%
%% Options:
%%   - server_id: binary() (required) - Server identifier (1-15 bytes)
%%   - algorithm: plaintext | stream_cipher | block_cipher (default: plaintext)
%%   - config_rotation: 0..6 (default: 0)
%%   - nonce_len: 4..18 (default: 4)
%%   - key: binary() - 16-byte AES key (required for cipher algorithms)
%%
%% @returns {ok, #lb_config{}} | {error, term()}
-spec new_config(map()) -> {ok, #lb_config{}} | {error, term()}.
new_config(Opts) when is_map(Opts) ->
    try
        ServerID = maps:get(server_id, Opts),
        ServerIDLen = byte_size(ServerID),
        Algorithm = maps:get(algorithm, Opts, plaintext),
        CR = maps:get(config_rotation, Opts, 0),
        NonceLen = maps:get(nonce_len, Opts, 4),
        Key = maps:get(key, Opts, undefined),

        Config = #lb_config{
            config_rotation = CR,
            algorithm = Algorithm,
            server_id = ServerID,
            server_id_len = ServerIDLen,
            nonce_len = NonceLen,
            key = Key
        },

        case validate_config(Config) of
            ok -> {ok, Config};
            {error, _} = Error -> Error
        end
    catch
        error:{badkey, server_id} ->
            {error, missing_server_id}
    end.

%% @doc Create a CID generation configuration from options map.
%%
%% Options:
%%   - lb_config: #lb_config{} | undefined - LB configuration
%%   - cid_len: 1..20 (default: 8) - Target CID length
%%   - reset_secret: binary() - Secret for reset token generation
%%
%% @returns {ok, #cid_config{}} | {error, term()}
-spec new_cid_config(map()) -> {ok, #cid_config{}} | {error, term()}.
new_cid_config(Opts) when is_map(Opts) ->
    LBConfig = maps:get(lb_config, Opts, undefined),
    CIDLen = maps:get(cid_len, Opts, 8),
    ResetSecret = maps:get(reset_secret, Opts, undefined),

    %% Validate CID length
    case CIDLen >= 1 andalso CIDLen =< 20 of
        true ->
            %% If LB config provided, CID length must match expected
            case LBConfig of
                undefined ->
                    {ok, #cid_config{
                        lb_config = undefined,
                        cid_len = CIDLen,
                        reset_secret = ResetSecret
                    }};
                #lb_config{} ->
                    ExpectedLen = expected_cid_len(LBConfig),
                    case CIDLen =:= ExpectedLen orelse CIDLen =:= 8 of
                        true ->
                            {ok, #cid_config{
                                lb_config = LBConfig,
                                cid_len = ExpectedLen,
                                reset_secret = ResetSecret
                            }};
                        false ->
                            {error, {cid_len_mismatch, CIDLen, ExpectedLen}}
                    end
            end;
        false ->
            {error, {invalid_cid_len, CIDLen}}
    end.

%% @doc Validate an LB configuration.
-spec validate_config(#lb_config{}) -> ok | {error, term()}.
validate_config(#lb_config{
    config_rotation = CR,
    algorithm = Algorithm,
    server_id = ServerID,
    server_id_len = ServerIDLen,
    nonce_len = NonceLen,
    key = Key
}) ->
    Validations = [
        {CR >= 0 andalso CR =< 6, {invalid_config_rotation, CR}},
        {
            lists:member(Algorithm, [plaintext, stream_cipher, block_cipher]),
            {invalid_algorithm, Algorithm}
        },
        {is_binary(ServerID), {invalid_server_id, not_binary}},
        {
            ServerIDLen >= 1 andalso ServerIDLen =< ?LB_MAX_SERVER_ID_LEN,
            {invalid_server_id_len, ServerIDLen}
        },
        {
            byte_size(ServerID) =:= ServerIDLen,
            {server_id_len_mismatch, byte_size(ServerID), ServerIDLen}
        },
        {
            NonceLen >= ?LB_MIN_NONCE_LEN andalso NonceLen =< ?LB_MAX_NONCE_LEN,
            {invalid_nonce_len, NonceLen}
        },
        {
            Algorithm =:= plaintext orelse
                (is_binary(Key) andalso byte_size(Key) =:= 16),
            {missing_or_invalid_key, Algorithm}
        }
    ],
    validate_list(Validations).

%% @doc Generate a CID using the configuration.
%% Uses a random nonce.
-spec generate_cid(#cid_config{}) -> binary().
generate_cid(#cid_config{lb_config = undefined, cid_len = Len}) ->
    crypto:strong_rand_bytes(Len);
generate_cid(#cid_config{lb_config = #lb_config{nonce_len = NonceLen}} = Config) ->
    Nonce = crypto:strong_rand_bytes(NonceLen),
    generate_cid(Config, Nonce).

%% @doc Generate a CID with an explicit nonce.
-spec generate_cid(#cid_config{}, binary()) -> binary().
generate_cid(#cid_config{lb_config = undefined, cid_len = Len}, _Nonce) ->
    crypto:strong_rand_bytes(Len);
generate_cid(#cid_config{lb_config = LBConfig}, Nonce) ->
    #lb_config{
        config_rotation = CR,
        algorithm = Algorithm,
        server_id = ServerID,
        server_id_len = ServerIDLen,
        nonce_len = NonceLen,
        key = Key
    } = LBConfig,

    %% Ensure nonce is correct length
    ActualNonce =
        case byte_size(Nonce) of
            NonceLen ->
                Nonce;
            N when N > NonceLen -> binary:part(Nonce, 0, NonceLen);
            N when N < NonceLen ->
                Pad = crypto:strong_rand_bytes(NonceLen - N),
                <<Nonce/binary, Pad/binary>>
        end,

    %% Calculate CID length (excluding first byte with CR/Len)
    CIDLen = 1 + ServerIDLen + NonceLen,

    %% First byte: CR (3 bits) | Length-1 (5 bits)
    FirstByte = (CR bsl 5) bor (CIDLen - 1),

    case Algorithm of
        plaintext ->
            encode_plaintext(FirstByte, ServerID, ActualNonce);
        stream_cipher ->
            encode_stream_cipher(FirstByte, ServerID, ActualNonce, Key);
        block_cipher ->
            encode_block_cipher(FirstByte, ServerID, ActualNonce, Key)
    end.

%% @doc Extract the server ID from a CID.
-spec decode_server_id(binary(), #lb_config{}) -> {ok, binary()} | {error, term()}.
decode_server_id(CID, #lb_config{algorithm = Algorithm} = Config) when byte_size(CID) >= 1 ->
    case Algorithm of
        plaintext ->
            decode_plaintext(CID, Config);
        stream_cipher ->
            decode_stream_cipher(CID, Config);
        block_cipher ->
            decode_block_cipher(CID, Config)
    end;
decode_server_id(_CID, _Config) ->
    {error, cid_too_short}.

%% @doc Get the config rotation bits from a CID's first byte.
-spec get_config_rotation(binary()) -> 0..7.
get_config_rotation(<<FirstByte, _/binary>>) ->
    FirstByte bsr 5;
get_config_rotation(_) ->
    ?LB_CR_UNROUTABLE.

%% @doc Check if a CID is LB-routable (CR != 0b111).
-spec is_lb_routable(binary()) -> boolean().
is_lb_routable(CID) ->
    get_config_rotation(CID) =/= ?LB_CR_UNROUTABLE.

%% @doc Calculate the expected CID length from configuration.
-spec expected_cid_len(#lb_config{}) -> pos_integer().
expected_cid_len(#lb_config{server_id_len = ServerIDLen, nonce_len = NonceLen}) ->
    1 + ServerIDLen + NonceLen.

%%====================================================================
%% Plaintext Encoding (RFC 9312 Section 4.1)
%%====================================================================

%% @private Encode plaintext CID
encode_plaintext(FirstByte, ServerID, Nonce) ->
    <<FirstByte, ServerID/binary, Nonce/binary>>.

%% @private Decode plaintext CID
decode_plaintext(<<_FirstByte, Rest/binary>>, #lb_config{server_id_len = ServerIDLen}) ->
    case Rest of
        <<ServerID:ServerIDLen/binary, _Nonce/binary>> ->
            {ok, ServerID};
        _ ->
            {error, cid_too_short}
    end.

%%====================================================================
%% Stream Cipher Encoding (RFC 9312 Section 4.2)
%%====================================================================

%% @private Encode using stream cipher (AES-128-CTR)
%% Encrypts first octet (only CR|Len portion masked) and server_id
encode_stream_cipher(FirstByte, ServerID, Nonce, Key) ->
    %% Build IV from nonce, zero-padded to 16 bytes
    IV = pad_to_16(Nonce),

    %% Encrypt first byte and server_id together
    %% Note: We need to preserve CR bits, only encrypt the length portion
    Plaintext = <<FirstByte, ServerID/binary>>,
    Encrypted = crypto:crypto_one_time(aes_128_ctr, Key, IV, Plaintext, true),

    %% Reconstruct first byte: keep CR bits from original, use encrypted length
    <<EncFirstByte, EncServerID/binary>> = Encrypted,
    CR = FirstByte bsr 5,
    EncLen = EncFirstByte band 16#1F,
    FinalFirstByte = (CR bsl 5) bor EncLen,

    <<FinalFirstByte, EncServerID/binary, Nonce/binary>>.

%% @private Decode stream cipher CID
decode_stream_cipher(
    <<FirstByte, Rest/binary>>,
    #lb_config{server_id_len = ServerIDLen, nonce_len = NonceLen, key = Key}
) ->
    EncServerIDLen = ServerIDLen,
    case Rest of
        <<EncServerID:EncServerIDLen/binary, Nonce:NonceLen/binary, _/binary>> ->
            %% Build IV from nonce
            IV = pad_to_16(Nonce),

            %% Decrypt first byte and server_id
            Ciphertext = <<FirstByte, EncServerID/binary>>,
            Decrypted = crypto:crypto_one_time(aes_128_ctr, Key, IV, Ciphertext, false),
            <<_DecFirstByte, ServerID/binary>> = Decrypted,
            {ok, ServerID};
        _ ->
            {error, cid_too_short}
    end.

%%====================================================================
%% Block Cipher Encoding (RFC 9312 Section 4.3)
%%====================================================================

%% @private Encode using block cipher (AES-128-ECB with Feistel)
%% RFC 9312 Section 4.3: CR bits are preserved (not encrypted) in all cases.
%% For < 16 bytes: 4-round Feistel network
%% For = 16 bytes: Direct AES-ECB on payload
%% For > 16 bytes: Truncated block cipher
%% Simplified approach: Only encrypt the payload (ServerID + Nonce), not the first byte.
encode_block_cipher(FirstByte, ServerID, Nonce, Key) ->
    %% Combine for encryption
    Data = <<FirstByte, ServerID/binary, Nonce/binary>>,
    DataLen = byte_size(Data),
    CR = FirstByte bsr 5,

    case DataLen of
        16 ->
            %% Exactly 16 bytes total: encrypt 15-byte payload with AES-CTR
            %% (AES-ECB requires exactly 16 bytes, so we use CTR mode for flexibility)
            encode_block_cipher_15(FirstByte, ServerID, Nonce, Key, CR);
        N when N < 16 ->
            %% Less than 16 bytes: use 4-round Feistel network
            encode_block_cipher_feistel(Data, Key, CR);
        N when N > 16 ->
            %% More than 16 bytes: truncated cipher
            encode_block_cipher_truncated(Data, Key, N, CR)
    end.

%% @private Encode for exactly 16-byte CID (15-byte payload)
%% Use AES-CTR mode since AES-ECB requires exact 16-byte blocks
%%
%% KNOWN LIMITATION (RFC 9312 conformance, not a QUIC security property):
%% the fixed IV makes the CTR keystream identical for every CID from this
%% server, so the encrypted Server ID bytes (a fixed plaintext) are
%% identical across CIDs — an observer can group CIDs by server, defeating
%% the obfuscation. The <16 and >16 paths mix the per-CID nonce and do not
%% have this issue. A conformant fix needs the nonce-mixed single-pass
%% construction (with matching decode); deferred.
encode_block_cipher_15(FirstByte, ServerID, Nonce, Key, CR) ->
    Payload = <<ServerID/binary, Nonce/binary>>,
    %% Use a fixed IV derived from the key (so decryption doesn't need the nonce)
    IV = derive_fixed_iv(Key),
    %% Encrypt payload using AES-CTR
    EncryptedPayload = crypto:crypto_one_time(aes_128_ctr, Key, IV, Payload, true),
    %% Reconstruct with original first byte (CR bits preserved)
    FinalFirstByte = (CR bsl 5) bor (FirstByte band 16#1F),
    <<FinalFirstByte, EncryptedPayload/binary>>.

%% @private Derive a fixed IV from the key for 16-byte block cipher
derive_fixed_iv(Key) ->
    %% Use AES-ECB on a fixed input to derive the IV
    crypto:crypto_one_time(aes_128_ecb, Key, <<0:128>>, true).

%% @private Feistel network for short CIDs (< 16 bytes)
%% RFC 9312 Section 4.3.1
%% Simplified: We only encrypt the payload (ServerID + Nonce), keeping the first byte intact.
%% This ensures CR bits are preserved and the Feistel roundtrip is correct.
encode_block_cipher_feistel(Data, Key, CR) ->
    <<FirstByte, Payload/binary>> = Data,
    PayloadLen = byte_size(Payload),

    %% Split payload into left and right halves
    HalfLen = PayloadLen div 2,
    LeftLen = HalfLen + (PayloadLen rem 2),
    <<Left:LeftLen/binary, Right:HalfLen/binary>> = Payload,

    %% 4-round Feistel encryption on payload only
    {FinalLeft, FinalRight} = feistel_encrypt(Left, Right, Key, 4),

    %% Reconstruct with original first byte (CR bits preserved)
    FinalFirstByte = (CR bsl 5) bor (FirstByte band 16#1F),
    <<FinalFirstByte, FinalLeft/binary, FinalRight/binary>>.

%% @private Truncated block cipher for long CIDs (> 16 bytes)
%% RFC 9312 Section 4.3.2
%% Simplified: Only encrypt the payload (ServerID + Nonce), not the first byte
encode_block_cipher_truncated(Data, Key, TotalLen, CR) ->
    <<FirstByte, Payload/binary>> = Data,
    PayloadLen = TotalLen - 1,

    %% Encrypt first 16 bytes of payload with AES-ECB
    <<PayloadFirst16:16/binary, PayloadRest/binary>> = Payload,
    EncPayloadFirst16 = crypto:crypto_one_time(aes_128_ecb, Key, PayloadFirst16, true),

    %% XOR remaining bytes with encrypted pad
    Pad = crypto:crypto_one_time(aes_128_ecb, Key, EncPayloadFirst16, true),
    RestLen = PayloadLen - 16,
    <<PadBytes:RestLen/binary, _/binary>> = Pad,
    EncPayloadRest = crypto:exor(PayloadRest, PadBytes),

    %% Reconstruct with original first byte (CR bits preserved)
    FinalFirstByte = (CR bsl 5) bor (FirstByte band 16#1F),
    <<FinalFirstByte, EncPayloadFirst16/binary, EncPayloadRest/binary>>.

%% @private Decode block cipher CID
decode_block_cipher(
    <<FirstByte, Rest/binary>> = CID,
    #lb_config{server_id_len = ServerIDLen, nonce_len = NonceLen, key = Key}
) ->
    DataLen = byte_size(CID),

    case DataLen of
        16 ->
            %% 16-byte CID: decrypt 15-byte payload with AES-CTR
            decode_block_cipher_15(Rest, ServerIDLen, NonceLen, Key);
        N when N < 16 ->
            %% Feistel decryption
            decode_block_cipher_feistel(FirstByte, Rest, ServerIDLen, Key, N);
        N when N > 16 ->
            %% Truncated cipher decryption
            decode_block_cipher_truncated(Rest, ServerIDLen, Key, N - 1)
    end.

%% @private Decode 16-byte CID (15-byte encrypted payload)
decode_block_cipher_15(EncryptedPayload, ServerIDLen, _NonceLen, Key) ->
    %% Use the same fixed IV as encryption
    IV = derive_fixed_iv(Key),
    %% Decrypt payload using AES-CTR
    DecryptedPayload = crypto:crypto_one_time(aes_128_ctr, Key, IV, EncryptedPayload, false),
    <<ServerID:ServerIDLen/binary, _Nonce/binary>> = DecryptedPayload,
    {ok, ServerID}.

%% @private Feistel decryption for short CIDs
%% Matches the simplified encryption: only the payload (after first byte) is encrypted
decode_block_cipher_feistel(_FirstByte, Rest, ServerIDLen, Key, _DataLen) ->
    %% Rest is the encrypted payload (ServerID + Nonce)
    PayloadLen = byte_size(Rest),

    %% Split payload into halves (same split as encryption)
    HalfLen = PayloadLen div 2,
    LeftLen = HalfLen + (PayloadLen rem 2),
    <<Left:LeftLen/binary, Right:HalfLen/binary>> = Rest,

    %% 4-round inverse Feistel
    {FinalLeft, FinalRight} = feistel_decrypt(Left, Right, Key, 4),

    %% Extract server_id from decrypted payload (starts at beginning)
    DecryptedPayload = <<FinalLeft/binary, FinalRight/binary>>,
    <<ServerID:ServerIDLen/binary, _Nonce/binary>> = DecryptedPayload,
    {ok, ServerID}.

%% @private Truncated cipher decryption for long CIDs
%% Matches the simplified encryption: only the payload (after first byte) is encrypted
decode_block_cipher_truncated(EncryptedPayload, ServerIDLen, Key, PayloadLen) ->
    %% Split encrypted payload into first 16 and rest
    <<EncFirst16:16/binary, EncRest/binary>> = EncryptedPayload,

    %% Decrypt first 16 bytes with AES-ECB
    DecFirst16 = crypto:crypto_one_time(aes_128_ecb, Key, EncFirst16, false),

    %% Decrypt XORed portion using pad from encrypted first 16
    Pad = crypto:crypto_one_time(aes_128_ecb, Key, EncFirst16, true),
    RestLen = PayloadLen - 16,
    <<PadBytes:RestLen/binary, _/binary>> = Pad,
    DecRest = crypto:exor(EncRest, PadBytes),

    %% Extract server_id from decrypted payload
    DecryptedPayload = <<DecFirst16/binary, DecRest/binary>>,
    <<ServerID:ServerIDLen/binary, _Nonce/binary>> = DecryptedPayload,
    {ok, ServerID}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Validate a list of conditions
validate_list([]) ->
    ok;
validate_list([{true, _Error} | Rest]) ->
    validate_list(Rest);
validate_list([{false, Error} | _Rest]) ->
    {error, Error}.

%% @private Pad binary to 16 bytes (for AES IV)
pad_to_16(Bin) when byte_size(Bin) >= 16 ->
    binary:part(Bin, 0, 16);
pad_to_16(Bin) ->
    PadLen = 16 - byte_size(Bin),
    <<Bin/binary, 0:(PadLen * 8)>>.

%% @private Feistel round function
%% PRF(Key, R) = AES-ECB(Key, pad(R)) truncated to desired length
feistel_prf(Key, Input, OutputLen) ->
    Padded = pad_to_16(Input),
    Encrypted = crypto:crypto_one_time(aes_128_ecb, Key, Padded, true),
    binary:part(Encrypted, 0, OutputLen).

%% @private 4-round Feistel encryption
%% Standard Feistel: L_{i+1} = R_i, R_{i+1} = L_i XOR F(R_i)
feistel_encrypt(Left, Right, Key, Rounds) ->
    feistel_encrypt_loop(Left, Right, Key, Rounds).

feistel_encrypt_loop(Left, Right, _Key, 0) ->
    {Left, Right};
feistel_encrypt_loop(Left, Right, Key, Rounds) ->
    LeftLen = byte_size(Left),
    %% F = PRF(Key, Right) truncated to length of Left
    F = feistel_prf(Key, Right, LeftLen),
    %% L' = L XOR F
    NewLeft = crypto:exor(Left, F),
    %% Swap: next round has (R, L')
    feistel_encrypt_loop(Right, NewLeft, Key, Rounds - 1).

%% @private 4-round inverse Feistel decryption
%% To reverse: we work backwards through the rounds
%% After encryption, we have (L_n, R_n) where n is the number of rounds
%% The last round was: L_n = R_{n-1}, R_n = L_{n-1} XOR F(R_{n-1})
%% So: R_{n-1} = L_n, L_{n-1} = R_n XOR F(L_n)
feistel_decrypt(Left, Right, Key, Rounds) ->
    feistel_decrypt_loop(Left, Right, Key, Rounds).

feistel_decrypt_loop(Left, Right, _Key, 0) ->
    {Left, Right};
feistel_decrypt_loop(Left, Right, Key, Rounds) ->
    RightLen = byte_size(Right),
    %% In the last encryption round: L_n = R_{n-1}, R_n = L_{n-1} XOR F(R_{n-1})
    %% So: R_{n-1} = L_n (current Left), L_{n-1} = R_n XOR F(L_n)
    %% F = PRF(Key, Left) truncated to length of Right
    F = feistel_prf(Key, Left, RightLen),
    %% NewRight = R XOR F(L)
    NewRight = crypto:exor(Right, F),
    %% Swap back: (NewRight, Left) becomes (L_{n-1}, R_{n-1})
    feistel_decrypt_loop(NewRight, Left, Key, Rounds - 1).
