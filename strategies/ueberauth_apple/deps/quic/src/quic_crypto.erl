%%% -*- erlang -*-
%%%
%%% QUIC TLS 1.3 Cryptographic Operations
%%% RFC 8446 - TLS 1.3
%%% RFC 9001 - Using TLS to Secure QUIC
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc TLS 1.3 key schedule and cryptographic operations for QUIC.
%%%
%%% This module implements the TLS 1.3 key schedule used by QUIC for
%%% deriving encryption keys at each handshake stage.
%%%
%%% == Key Schedule ==
%%%
%%% TLS 1.3 uses a three-stage key schedule:
%%% 1. Early Secret (from PSK, or zeros for non-PSK)
%%% 2. Handshake Secret (from ECDHE shared secret)
%%% 3. Master Secret (for application data)
%%%
%%% == Traffic Secrets ==
%%%
%%% From each secret, traffic secrets are derived for both client and
%%% server directions.
%%%

-module(quic_crypto).

-type group() :: x25519 | secp256r1 | secp384r1 | x25519mlkem768.
%% Private key material for a key exchange: raw curve key for ECDHE,
%% opaque {MlKemDecapsKey, X25519Priv} for the hybrid group.
-type kex_private() :: binary() | {binary(), binary()}.
-export_type([group/0, kex_private/0]).

-export([
    default_cipher_preference/0,
    aes_accelerated/0,
    aes_accelerated/1,
    %% Key Schedule
    derive_early_secret/0,
    derive_early_secret/1,
    derive_early_secret/2,
    derive_handshake_secret/2,
    derive_handshake_secret/3,
    derive_handshake_secret_psk_only/1,
    derive_handshake_secret_psk_only/2,
    derive_master_secret/1,
    derive_master_secret/2,

    %% Traffic Secrets
    derive_client_handshake_secret/2,
    derive_client_handshake_secret/3,
    derive_server_handshake_secret/2,
    derive_server_handshake_secret/3,
    derive_client_app_secret/2,
    derive_client_app_secret/3,
    derive_server_app_secret/2,
    derive_server_app_secret/3,

    %% 0-RTT (Early Data)
    derive_client_early_traffic_secret/2,
    derive_client_early_traffic_secret/3,
    derive_early_exporter_master_secret/2,
    compute_psk_binder/3,
    compute_psk_binder/4,

    %% Derive-Secret function
    derive_secret/3,
    derive_secret/4,

    %% Finished key and verify data
    derive_finished_key/1,
    derive_finished_key/2,
    compute_finished_verify/2,
    compute_finished_verify/3,

    %% Transcript hash
    transcript_hash/1,
    transcript_hash/2,
    hrr_transcript_prefix/2,

    %% Cipher to hash mapping
    cipher_to_hash/1,
    hash_len/1,

    %% ECDHE
    generate_key_pair/1,
    compute_shared_secret/3,
    server_key_exchange/2,
    group_supported/1,

    %% Retry Packet Integrity (RFC 9001 Section 5.8)
    verify_retry_integrity_tag/3,
    compute_retry_integrity_tag/3
]).

%% Hash length for SHA-256
-define(HASH_LEN, 32).
-define(HASH_LEN_384, 48).

%%====================================================================
%% Key Schedule (RFC 8446 Section 7.1)
%%====================================================================

%% @doc Derive early secret without PSK (zeros).
%% early_secret = HKDF-Extract(0, 0)
-spec derive_early_secret() -> binary().
derive_early_secret() ->
    derive_early_secret(<<0:?HASH_LEN/unit:8>>).

%% @doc Derive early secret with PSK.
%% early_secret = HKDF-Extract(0, PSK)
-spec derive_early_secret(binary()) -> binary().
derive_early_secret(PSK) ->
    %% Salt is all zeros
    Salt = <<0:?HASH_LEN/unit:8>>,
    quic_hkdf:extract(Salt, PSK).

%% @doc Derive early secret with cipher-specific hash.
-spec derive_early_secret(atom(), binary()) -> binary().
derive_early_secret(Cipher, PSK) ->
    Hash = cipher_to_hash(Cipher),
    HashLen = hash_len(Hash),
    Salt = <<0:HashLen/unit:8>>,
    quic_hkdf:extract(Hash, Salt, PSK).

%% @doc Derive handshake secret from early secret and ECDHE shared secret.
%% handshake_secret = HKDF-Extract(
%%     Derive-Secret(early_secret, "derived", ""),
%%     shared_secret)
-spec derive_handshake_secret(binary(), binary()) -> binary().
derive_handshake_secret(EarlySecret, SharedSecret) ->
    Salt = derive_secret(EarlySecret, <<"derived">>, <<>>),
    quic_hkdf:extract(Salt, SharedSecret).

%% @doc Derive handshake secret with cipher-specific hash.
-spec derive_handshake_secret(atom(), binary(), binary()) -> binary().
derive_handshake_secret(Cipher, EarlySecret, SharedSecret) ->
    Hash = cipher_to_hash(Cipher),
    Salt = derive_secret(Hash, EarlySecret, <<"derived">>, <<>>),
    quic_hkdf:extract(Hash, Salt, SharedSecret).

%% @doc Derive handshake secret for psk_ke (PSK-only, no DHE).
%% RFC 8446 §7.1: when (EC)DHE is not used, the IKM is a zero-vector
%% of the negotiated hash's length.
-spec derive_handshake_secret_psk_only(binary()) -> binary().
derive_handshake_secret_psk_only(EarlySecret) ->
    Salt = derive_secret(EarlySecret, <<"derived">>, <<>>),
    IKM = <<0:?HASH_LEN/unit:8>>,
    quic_hkdf:extract(Salt, IKM).

%% @doc Derive handshake secret for psk_ke with cipher-specific hash.
-spec derive_handshake_secret_psk_only(atom(), binary()) -> binary().
derive_handshake_secret_psk_only(Cipher, EarlySecret) ->
    Hash = cipher_to_hash(Cipher),
    HashLen = hash_len(Hash),
    Salt = derive_secret(Hash, EarlySecret, <<"derived">>, <<>>),
    IKM = <<0:HashLen/unit:8>>,
    quic_hkdf:extract(Hash, Salt, IKM).

%% @doc Derive master secret from handshake secret.
%% master_secret = HKDF-Extract(
%%     Derive-Secret(handshake_secret, "derived", ""),
%%     0)
-spec derive_master_secret(binary()) -> binary().
derive_master_secret(HandshakeSecret) ->
    Salt = derive_secret(HandshakeSecret, <<"derived">>, <<>>),
    IKM = <<0:?HASH_LEN/unit:8>>,
    quic_hkdf:extract(Salt, IKM).

%% @doc Derive master secret with cipher-specific hash.
-spec derive_master_secret(atom(), binary()) -> binary().
derive_master_secret(Cipher, HandshakeSecret) ->
    Hash = cipher_to_hash(Cipher),
    HashLen = hash_len(Hash),
    Salt = derive_secret(Hash, HandshakeSecret, <<"derived">>, <<>>),
    IKM = <<0:HashLen/unit:8>>,
    quic_hkdf:extract(Hash, Salt, IKM).

%%====================================================================
%% Traffic Secrets (RFC 8446 Section 7.1)
%%====================================================================

%% @doc Derive client handshake traffic secret.
%% client_handshake_traffic_secret = Derive-Secret(
%%     handshake_secret, "c hs traffic", ClientHello...ServerHello)
-spec derive_client_handshake_secret(binary(), binary()) -> binary().
derive_client_handshake_secret(HandshakeSecret, TranscriptHash) ->
    derive_secret(HandshakeSecret, <<"c hs traffic">>, TranscriptHash).

%% @doc Derive client handshake traffic secret with cipher-specific hash.
-spec derive_client_handshake_secret(atom(), binary(), binary()) -> binary().
derive_client_handshake_secret(Cipher, HandshakeSecret, TranscriptHash) ->
    Hash = cipher_to_hash(Cipher),
    derive_secret(Hash, HandshakeSecret, <<"c hs traffic">>, TranscriptHash).

%% @doc Derive server handshake traffic secret.
%% server_handshake_traffic_secret = Derive-Secret(
%%     handshake_secret, "s hs traffic", ClientHello...ServerHello)
-spec derive_server_handshake_secret(binary(), binary()) -> binary().
derive_server_handshake_secret(HandshakeSecret, TranscriptHash) ->
    derive_secret(HandshakeSecret, <<"s hs traffic">>, TranscriptHash).

%% @doc Derive server handshake traffic secret with cipher-specific hash.
-spec derive_server_handshake_secret(atom(), binary(), binary()) -> binary().
derive_server_handshake_secret(Cipher, HandshakeSecret, TranscriptHash) ->
    Hash = cipher_to_hash(Cipher),
    derive_secret(Hash, HandshakeSecret, <<"s hs traffic">>, TranscriptHash).

%% @doc Derive client application traffic secret.
%% client_application_traffic_secret_0 = Derive-Secret(
%%     master_secret, "c ap traffic", ClientHello...server Finished)
-spec derive_client_app_secret(binary(), binary()) -> binary().
derive_client_app_secret(MasterSecret, TranscriptHash) ->
    derive_secret(MasterSecret, <<"c ap traffic">>, TranscriptHash).

%% @doc Derive client application traffic secret with cipher-specific hash.
-spec derive_client_app_secret(atom(), binary(), binary()) -> binary().
derive_client_app_secret(Cipher, MasterSecret, TranscriptHash) ->
    Hash = cipher_to_hash(Cipher),
    derive_secret(Hash, MasterSecret, <<"c ap traffic">>, TranscriptHash).

%% @doc Derive server application traffic secret.
%% server_application_traffic_secret_0 = Derive-Secret(
%%     master_secret, "s ap traffic", ClientHello...server Finished)
-spec derive_server_app_secret(binary(), binary()) -> binary().
derive_server_app_secret(MasterSecret, TranscriptHash) ->
    derive_secret(MasterSecret, <<"s ap traffic">>, TranscriptHash).

%% @doc Derive server application traffic secret with cipher-specific hash.
-spec derive_server_app_secret(atom(), binary(), binary()) -> binary().
derive_server_app_secret(Cipher, MasterSecret, TranscriptHash) ->
    Hash = cipher_to_hash(Cipher),
    derive_secret(Hash, MasterSecret, <<"s ap traffic">>, TranscriptHash).

%%====================================================================
%% 0-RTT / Early Data (RFC 8446 Section 7.1)
%%====================================================================

%% @doc Derive client early traffic secret.
%% client_early_traffic_secret = Derive-Secret(early_secret, "c e traffic", ClientHello)
%% This is used to encrypt 0-RTT data before the handshake completes.
-spec derive_client_early_traffic_secret(binary(), binary()) -> binary().
derive_client_early_traffic_secret(EarlySecret, ClientHelloHash) ->
    derive_secret(EarlySecret, <<"c e traffic">>, ClientHelloHash).

%% @doc Derive client early traffic secret with cipher-specific hash.
-spec derive_client_early_traffic_secret(atom(), binary(), binary()) -> binary().
derive_client_early_traffic_secret(Cipher, EarlySecret, ClientHelloHash) ->
    Hash = cipher_to_hash(Cipher),
    derive_secret(Hash, EarlySecret, <<"c e traffic">>, ClientHelloHash).

%% @doc Derive early exporter master secret.
%% early_exporter_master_secret = Derive-Secret(early_secret, "e exp master", ClientHello)
-spec derive_early_exporter_master_secret(binary(), binary()) -> binary().
derive_early_exporter_master_secret(EarlySecret, ClientHelloHash) ->
    derive_secret(EarlySecret, <<"e exp master">>, ClientHelloHash).

%% @doc Compute PSK binder value for a pre_shared_key extension.
%% RFC 8446 Section 4.2.11.2:
%%   binder_key = Derive-Secret(early_secret, "res binder" | "ext binder", "")
%%   binder = HMAC(binder_key, Transcript-Hash(Truncated ClientHello))
%% For resumption PSK, use "res binder". For external PSK, use "ext binder".
-spec compute_psk_binder(binary(), binary(), resumption | external) -> binary().
compute_psk_binder(EarlySecret, TruncatedClientHelloHash, Type) ->
    compute_psk_binder(sha256, EarlySecret, TruncatedClientHelloHash, Type).

%% @doc Compute PSK binder with cipher-specific hash.
-spec compute_psk_binder(atom(), binary(), binary(), resumption | external) -> binary().
compute_psk_binder(Cipher, EarlySecret, TruncatedClientHelloHash, Type) ->
    Hash = cipher_to_hash(Cipher),
    Label =
        case Type of
            resumption -> <<"res binder">>;
            external -> <<"ext binder">>
        end,
    %% binder_key = Derive-Secret(early_secret, label, "")
    %% For empty context, derive_secret uses Hash("") as per RFC 8446.
    BinderKey = derive_secret(Hash, EarlySecret, Label, <<>>),
    %% The binder is a Finished MAC keyed by binder_key (RFC 8446 §4.2.11.2:
    %% computed "in the same way as the Finished message", §4.4.4), so the
    %% HMAC key is the finished_key derived from binder_key, not binder_key
    %% itself:
    %%   finished_key = HKDF-Expand-Label(binder_key, "finished", "", Hash.len)
    %%   binder       = HMAC(finished_key, Transcript-Hash(Truncated ClientHello))
    FinishedKey = derive_finished_key(Cipher, BinderKey),
    crypto:mac(hmac, Hash, FinishedKey, TruncatedClientHelloHash).

%%====================================================================
%% Derive-Secret Function
%%====================================================================

%% @doc Derive-Secret with raw messages (will be hashed).
%% Derive-Secret(Secret, Label, Messages) =
%%     HKDF-Expand-Label(Secret, Label, Transcript-Hash(Messages), Hash.length)
-spec derive_secret(binary(), binary(), binary()) -> binary().
derive_secret(Secret, Label, Messages) ->
    derive_secret(sha256, Secret, Label, Messages).

%% @doc Derive-Secret with specified hash algorithm.
-spec derive_secret(atom(), binary(), binary(), binary()) -> binary().
derive_secret(Hash, Secret, Label, Messages) ->
    HashLen = hash_len(Hash),
    %% If Messages is already hash-length, assume it's pre-hashed
    %% Otherwise, compute Transcript-Hash(Messages) = Hash(Messages)
    %% RFC 8446: Even for empty Messages, use Hash("") not empty binary
    Context =
        case byte_size(Messages) of
            HashLen -> Messages;
            % Includes empty case: Hash("")
            _ -> transcript_hash(Hash, Messages)
        end,
    quic_hkdf:expand_label(Hash, Secret, Label, Context, HashLen).

%%====================================================================
%% Finished Key and Verify Data (RFC 8446 Section 4.4.4)
%%====================================================================

%% @doc Derive the finished key from a traffic secret.
%% finished_key = HKDF-Expand-Label(BaseKey, "finished", "", Hash.length)
-spec derive_finished_key(binary()) -> binary().
derive_finished_key(TrafficSecret) ->
    quic_hkdf:expand_label(TrafficSecret, <<"finished">>, <<>>, ?HASH_LEN).

%% @doc Derive the finished key with cipher-specific hash.
-spec derive_finished_key(atom(), binary()) -> binary().
derive_finished_key(Cipher, TrafficSecret) ->
    Hash = cipher_to_hash(Cipher),
    HashLen = hash_len(Hash),
    quic_hkdf:expand_label(Hash, TrafficSecret, <<"finished">>, <<>>, HashLen).

%% @doc Compute the Finished verify_data.
%% verify_data = HMAC(finished_key, Transcript-Hash(Handshake Context))
-spec compute_finished_verify(binary(), binary()) -> binary().
compute_finished_verify(FinishedKey, TranscriptHash) ->
    crypto:mac(hmac, sha256, FinishedKey, TranscriptHash).

%% @doc Compute the Finished verify_data with cipher-specific hash.
-spec compute_finished_verify(atom(), binary(), binary()) -> binary().
compute_finished_verify(Cipher, FinishedKey, TranscriptHash) ->
    Hash = cipher_to_hash(Cipher),
    crypto:mac(hmac, Hash, FinishedKey, TranscriptHash).

%%====================================================================
%% Transcript Hash
%%====================================================================

%% @doc Compute transcript hash of handshake messages (default SHA-256).
-spec transcript_hash(binary()) -> binary().
transcript_hash(Messages) ->
    crypto:hash(sha256, Messages).

%% @doc Compute transcript hash with specified hash algorithm or cipher.
%% Accepts both hash atoms (sha256, sha384) and cipher atoms (aes_128_gcm, aes_256_gcm).
-spec transcript_hash(atom(), binary()) -> binary().
transcript_hash(HashOrCipher, Messages) ->
    %% Always go through cipher_to_hash which passes through sha256/sha384 unchanged
    Hash = cipher_to_hash(HashOrCipher),
    crypto:hash(Hash, Messages).

%% @doc Synthetic `message_hash' handshake message that replaces
%% ClientHello1 in the transcript after a HelloRetryRequest
%% (RFC 8446 §4.4.1). `HashClientHello1' is the digest over the
%% complete CH1 handshake message. Both peers prepend the result
%% to the post-HRR transcript.
-spec hrr_transcript_prefix(atom(), binary()) -> binary().
hrr_transcript_prefix(HashOrCipher, HashClientHello1) ->
    HashLen = hash_len(cipher_to_hash(HashOrCipher)),
    <<254:8, HashLen:24, HashClientHello1/binary>>.

%%====================================================================
%% Cipher to Hash Mapping
%%====================================================================

%% @doc Map cipher suite to corresponding hash algorithm.
-spec cipher_to_hash(atom()) -> atom().
cipher_to_hash(aes_128_gcm) -> sha256;
cipher_to_hash(aes_256_gcm) -> sha384;
cipher_to_hash(chacha20_poly1305) -> sha256;
% Pass-through for hash atoms
cipher_to_hash(sha256) -> sha256;
cipher_to_hash(sha384) -> sha384;
% Default to SHA-256
cipher_to_hash(_) -> sha256.

%%====================================================================
%% ECDHE Key Exchange
%%====================================================================

%% @doc Generate a key-exchange key pair for the specified group.
%% Returns {PublicShare, PrivateKey}. For the classical ECDHE groups
%% PublicShare/PrivateKey are the raw curve keys. For the post-quantum
%% hybrid group x25519mlkem768 (draft-ietf-tls-ecdhe-mlkem) the public
%% share is the 1216-byte concatenation of the ML-KEM-768 encapsulation
%% key and the X25519 public key, and the private key is an opaque
%% {MlKemDecapsKey, X25519Priv} pair; both are only ever consumed by
%% compute_shared_secret/3.
-spec generate_key_pair(group()) -> {binary(), kex_private()}.
generate_key_pair(x25519mlkem768) ->
    {MlKemEK, MlKemDK} = crypto:generate_key(mlkem768, []),
    {XPub, XPriv} = crypto:generate_key(ecdh, x25519),
    {<<MlKemEK/binary, XPub/binary>>, {MlKemDK, XPriv}};
generate_key_pair(Curve) ->
    {PubKey, PrivKey} = crypto:generate_key(ecdh, Curve),
    {PubKey, PrivKey}.

%% @doc Compute the key-exchange shared secret (client side for the
%% hybrid group). For ECDHE groups: ECDH(our_private, their_public).
%% For x25519mlkem768 the peer share is the server's 1120-byte
%% concatenation of the ML-KEM ciphertext and X25519 public key, and
%% the shared secret is mlkem_secret || x25519_secret (64 bytes).
%% A peer share whose length does not match the group, or a group that
%% does not match the private key we hold, is `{error,
%% illegal_parameter}': the caller turns it into a TLS alert rather
%% than letting crypto raise mid-handshake.
-spec compute_shared_secret(group(), kex_private(), binary()) ->
    binary() | {error, illegal_parameter | internal_error}.
compute_shared_secret(
    x25519mlkem768, {MlKemDK, XPriv}, <<CipherText:1088/binary, SXPub:32/binary>>
) ->
    case safe_mlkem_decapsulate(MlKemDK, CipherText) of
        {ok, MlKemSecret} ->
            case safe_ecdh(x25519, XPriv, SXPub) of
                {ok, XSecret} -> <<MlKemSecret/binary, XSecret/binary>>;
                {error, illegal_parameter} = Error -> Error
            end;
        {error, internal_error} = Error ->
            Error
    end;
compute_shared_secret(Curve, OurPrivate, TheirPublic) when is_binary(OurPrivate) ->
    case peer_share_size(Curve) =:= byte_size(TheirPublic) of
        true ->
            case safe_ecdh(Curve, OurPrivate, TheirPublic) of
                {ok, SharedSecret} -> SharedSecret;
                {error, illegal_parameter} = Error -> Error
            end;
        false ->
            {error, illegal_parameter}
    end;
compute_shared_secret(_Group, _OurPrivate, _TheirPublic) ->
    {error, illegal_parameter}.

%% @doc Server-side key exchange against a client key share.
%% Returns {ServerShare, ServerPrivate, SharedSecret}. For ECDHE groups
%% this generates a server key pair and computes ECDH; ServerPrivate is
%% the curve private key (kept for parity with the previous behaviour).
%% For x25519mlkem768 the server encapsulates against the client's
%% ML-KEM encapsulation key: the server share is ciphertext || x25519
%% public (1120 bytes), the shared secret is mlkem || x25519 (64 bytes),
%% and there is no retained private key (the exchange is complete).
%% A client share whose length does not match the group is `{error,
%% illegal_parameter}'.
-spec server_key_exchange(group(), binary()) ->
    {binary(), kex_private() | undefined, binary()} | {error, illegal_parameter}.
server_key_exchange(x25519mlkem768, <<MlKemEK:1184/binary, CXPub:32/binary>>) ->
    case safe_mlkem_encapsulate(MlKemEK) of
        {ok, MlKemSecret, CipherText} ->
            {SXPub, SXPriv} = crypto:generate_key(ecdh, x25519),
            case safe_ecdh(x25519, SXPriv, CXPub) of
                {ok, XSecret} ->
                    ServerShare = <<CipherText/binary, SXPub/binary>>,
                    {ServerShare, undefined, <<MlKemSecret/binary, XSecret/binary>>};
                {error, illegal_parameter} = Error ->
                    Error
            end;
        {error, illegal_parameter} = Error ->
            Error
    end;
server_key_exchange(x25519mlkem768, _Malformed) ->
    {error, illegal_parameter};
server_key_exchange(Curve, ClientPub) ->
    case peer_share_size(Curve) =:= byte_size(ClientPub) of
        true ->
            {PubKey, PrivKey} = generate_key_pair(Curve),
            case compute_shared_secret(Curve, PrivKey, ClientPub) of
                SharedSecret when is_binary(SharedSecret) ->
                    {PubKey, PrivKey, SharedSecret};
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, illegal_parameter}
    end.

%% @private The hybrid draft assigns peer-controlled validation failures
%% to precise TLS alerts. Normalise crypto backend exceptions here so the
%% connection process can send those alerts instead of terminating.
safe_mlkem_encapsulate(EncapsulationKey) ->
    try crypto:encapsulate_key(mlkem768, EncapsulationKey) of
        {Secret, CipherText} when byte_size(Secret) =:= 32, byte_size(CipherText) =:= 1088 ->
            {ok, Secret, CipherText};
        _ ->
            {error, illegal_parameter}
    catch
        _:_ -> {error, illegal_parameter}
    end.

safe_mlkem_decapsulate(DecapsulationKey, CipherText) ->
    try crypto:decapsulate_key(mlkem768, DecapsulationKey, CipherText) of
        Secret when byte_size(Secret) =:= 32 -> {ok, Secret};
        _ -> {error, internal_error}
    catch
        _:_ -> {error, internal_error}
    end.

safe_ecdh(Curve, PrivateKey, PeerPublic) ->
    try crypto:compute_key(ecdh, PeerPublic, PrivateKey, Curve) of
        SharedSecret when is_binary(SharedSecret) ->
            case is_all_zero(SharedSecret) of
                true -> {error, illegal_parameter};
                false -> {ok, SharedSecret}
            end
    catch
        _:_ -> {error, illegal_parameter}
    end.

%% Constant-time: hash_equals/2 does not short-circuit, so the comparison
%% cannot leak how many leading bytes of the secret are zero.
is_all_zero(Binary) ->
    crypto:hash_equals(Binary, binary:copy(<<0>>, byte_size(Binary))).

%% @private Length of a peer's key share for a classical group. TLS 1.3
%% mandates the uncompressed point format (RFC 8446 §4.2.8.2), so each
%% group has exactly one valid length. `undefined' for anything we
%% cannot negotiate, which never matches a share size.
peer_share_size(x25519) -> 32;
peer_share_size(secp256r1) -> 65;
peer_share_size(secp384r1) -> 97;
peer_share_size(_) -> undefined.

%% @doc Whether this runtime can negotiate the given group: it must be
%% one quic_tls has a wire code for, and the hybrid group also needs
%% ML-KEM-768 support in crypto (OTP 28.1+).
-spec group_supported(group()) -> boolean().
group_supported(x25519mlkem768) ->
    case code:ensure_loaded(crypto) of
        {module, crypto} ->
            erlang:function_exported(crypto, encapsulate_key, 2) andalso
                erlang:function_exported(crypto, decapsulate_key, 3) andalso
                lists:member(mlkem768, proplists:get_value(kems, crypto:supports(), []));
        _ ->
            false
    end;
group_supported(Group) ->
    lists:member(Group, [x25519, secp256r1, secp384r1]).

%%====================================================================
%% Retry Packet Integrity (RFC 9001 Section 5.8)
%%====================================================================

%% RFC 9001 Section 5.8 - Retry Integrity Key and Nonce for QUIC v1
-define(RETRY_INTEGRITY_KEY_V1,
    <<16#be, 16#0c, 16#69, 16#0b, 16#9f, 16#66, 16#57, 16#5a, 16#1d, 16#76, 16#6b, 16#54, 16#e3,
        16#68, 16#c8, 16#4e>>
).
-define(RETRY_INTEGRITY_NONCE_V1,
    <<16#46, 16#15, 16#99, 16#d3, 16#5d, 16#63, 16#2b, 16#f2, 16#23, 16#98, 16#25, 16#bb>>
).

%% RFC 9001 Section 5.8 - Retry Integrity Key and Nonce for QUIC v2
%% RFC 9369 §3.3.3; the previous values were from a pre-RFC draft.
-define(RETRY_INTEGRITY_KEY_V2,
    <<16#8f, 16#b4, 16#b0, 16#1b, 16#56, 16#ac, 16#48, 16#e2, 16#60, 16#fb, 16#cb, 16#ce, 16#ad,
        16#7c, 16#cc, 16#92>>
).
-define(RETRY_INTEGRITY_NONCE_V2,
    <<16#d8, 16#69, 16#69, 16#bc, 16#2d, 16#7c, 16#6d, 16#99, 16#90, 16#ef, 16#b0, 16#4a>>
).

%% @doc Verify the integrity tag of a Retry packet.
%% RFC 9001 Section 5.8:
%% - Retry Pseudo-Packet = &lt;ODCID length&gt; &lt;ODCID&gt; &lt;Retry packet without tag&gt;
%% - Tag = AES-128-GCM(Key, Nonce, AAD=Pseudo-Packet, "")
%% Returns true if the tag is valid, false otherwise.
-spec verify_retry_integrity_tag(binary(), binary(), non_neg_integer()) -> boolean().
verify_retry_integrity_tag(OriginalDCID, RetryPacket, Version) ->
    %% The Retry packet includes the 16-byte integrity tag at the end
    case byte_size(RetryPacket) >= 16 of
        true ->
            PacketLen = byte_size(RetryPacket) - 16,
            <<PacketWithoutTag:PacketLen/binary, IntegrityTag:16/binary>> = RetryPacket,
            ExpectedTag = compute_retry_integrity_tag(OriginalDCID, PacketWithoutTag, Version),
            IntegrityTag =:= ExpectedTag;
        false ->
            false
    end.

%% @doc Compute the integrity tag for a Retry packet.
%% Used by servers to generate tags and by clients to verify.
-spec compute_retry_integrity_tag(binary(), binary(), non_neg_integer()) -> binary().
compute_retry_integrity_tag(OriginalDCID, RetryPacketWithoutTag, Version) ->
    {Key, Nonce} = retry_integrity_secrets(Version),
    ODCIDLen = byte_size(OriginalDCID),
    %% Retry Pseudo-Packet per RFC 9001 Section 5.8
    PseudoPacket = <<ODCIDLen, OriginalDCID/binary, RetryPacketWithoutTag/binary>>,
    %% AEAD encrypt with empty plaintext (tag only)
    %% crypto_one_time_aead returns {Ciphertext, Tag} for encryption
    {<<>>, Tag} = crypto:crypto_one_time_aead(
        aes_128_gcm, Key, Nonce, <<>>, PseudoPacket, 16, true
    ),
    Tag.

%% Get the retry integrity key and nonce for a QUIC version
retry_integrity_secrets(Version) when Version =:= 16#00000001 orelse Version =:= 1 ->
    %% QUIC v1 (RFC 9000)
    {?RETRY_INTEGRITY_KEY_V1, ?RETRY_INTEGRITY_NONCE_V1};
retry_integrity_secrets(Version) when Version =:= 16#6b3343cf ->
    %% QUIC v2 (RFC 9369)
    {?RETRY_INTEGRITY_KEY_V2, ?RETRY_INTEGRITY_NONCE_V2};
retry_integrity_secrets(_Version) ->
    %% Default to v1 for unknown versions
    {?RETRY_INTEGRITY_KEY_V1, ?RETRY_INTEGRITY_NONCE_V1}.

%%====================================================================
%% Internal Functions
%%====================================================================

hash_len(sha256) -> 32;
hash_len(sha384) -> 48;
hash_len(sha512) -> 64.

%% Cipher suites to offer or accept, in preference order, when the
%% `ciphers' option is not given. AES-GCM first on a CPU with AES
%% instructions; ChaCha20-Poly1305 first without them, where AES runs
%% in software and ChaCha is markedly cheaper.
-spec default_cipher_preference() -> [aes_128_gcm | aes_256_gcm | chacha20_poly1305].
default_cipher_preference() ->
    case aes_accelerated() of
        true -> [aes_128_gcm, aes_256_gcm, chacha20_poly1305];
        false -> [chacha20_poly1305, aes_128_gcm, aes_256_gcm]
    end.

%% Whether this CPU has AES instructions, from the Linux cpuinfo flags
%% (x86 `flags', arm64 `Features'); cached. Unknown platforms count as
%% accelerated so the historical default holds there.
-spec aes_accelerated() -> boolean().
aes_accelerated() ->
    case persistent_term:get({?MODULE, aes_accelerated}, undefined) of
        undefined ->
            V =
                case file:read_file("/proc/cpuinfo") of
                    {ok, Info} -> aes_accelerated(Info);
                    _ -> true
                end,
            persistent_term:put({?MODULE, aes_accelerated}, V),
            V;
        V ->
            V
    end.

-spec aes_accelerated(binary()) -> boolean().
aes_accelerated(CpuInfo) ->
    Lines = binary:split(CpuInfo, <<"\n">>, [global]),
    FlagLines = [
        L
     || L <- Lines,
        binary:match(L, <<"flags">>) =:= {0, 5} orelse binary:match(L, <<"Features">>) =:= {0, 8}
    ],
    case FlagLines of
        [] ->
            true;
        _ ->
            lists:any(
                fun(L) ->
                    Words = binary:split(L, [<<" ">>, <<"\t">>], [global]),
                    lists:member(<<"aes">>, Words)
                end,
                FlagLines
            )
    end.
