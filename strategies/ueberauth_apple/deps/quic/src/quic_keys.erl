%%% -*- erlang -*-
%%%
%%% QUIC Key Derivation
%%% RFC 9001 Section 5 - Packet Protection
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC key derivation for packet protection.
%%%
%%% This module derives the cryptographic keys used for QUIC packet
%%% protection at each encryption level (Initial, Handshake, Application).
%%%
%%% == Initial Keys ==
%%%
%%% Initial keys are derived from the Destination Connection ID using
%%% a fixed salt defined in RFC 9001.
%%%
%%% == Key Derivation ==
%%%
%%% Keys are derived using HKDF-Expand-Label with the following labels:
%%% - "quic key" for the AEAD key
%%% - "quic iv" for the AEAD IV/nonce
%%% - "quic hp" for header protection key
%%%

-module(quic_keys).

-include("quic.hrl").

-export([
    derive_initial_secret/1,
    derive_initial_secret/2,
    derive_initial_client/1,
    derive_initial_client/2,
    derive_initial_server/1,
    derive_initial_server/2,
    derive_keys/2,
    derive_keys/3,
    derive_traffic_keys/1,
    %% Key Update (RFC 9001 Section 6)
    derive_updated_secret/2,
    derive_updated_secret/3,
    derive_updated_keys/2,
    derive_updated_keys/3
]).

-export_type([keys/0]).

-type keys() :: {Key :: binary(), IV :: binary(), HP :: binary()}.

%%====================================================================
%% API
%%====================================================================

%% @doc Derive the initial secret from DCID using QUIC v1 salt.
-spec derive_initial_secret(binary()) -> binary().
derive_initial_secret(DCID) ->
    derive_initial_secret(DCID, ?QUIC_VERSION_1).

%% @doc Derive the initial secret from DCID.
%% Version determines which salt to use.
-spec derive_initial_secret(binary(), non_neg_integer()) -> binary().
derive_initial_secret(DCID, Version) ->
    Salt = initial_salt(Version),
    quic_hkdf:extract(Salt, DCID).

%% @doc Derive initial client keys from DCID.
%% Returns {Key, IV, HP} for client Initial packets.
-spec derive_initial_client(binary()) -> keys().
derive_initial_client(DCID) ->
    derive_initial_client(DCID, ?QUIC_VERSION_1).

%% @doc Derive initial client keys from DCID with version.
-spec derive_initial_client(binary(), non_neg_integer()) -> keys().
derive_initial_client(DCID, Version) ->
    InitialSecret = derive_initial_secret(DCID, Version),
    ClientSecret = quic_hkdf:expand_label(InitialSecret, ?QUIC_LABEL_CLIENT_IN, <<>>, 32),
    derive_keys(ClientSecret, aes_128_gcm, Version).

%% @doc Derive initial server keys from DCID.
%% Returns {Key, IV, HP} for server Initial packets.
-spec derive_initial_server(binary()) -> keys().
derive_initial_server(DCID) ->
    derive_initial_server(DCID, ?QUIC_VERSION_1).

%% @doc Derive initial server keys from DCID with version.
-spec derive_initial_server(binary(), non_neg_integer()) -> keys().
derive_initial_server(DCID, Version) ->
    InitialSecret = derive_initial_secret(DCID, Version),
    ServerSecret = quic_hkdf:expand_label(InitialSecret, ?QUIC_LABEL_SERVER_IN, <<>>, 32),
    derive_keys(ServerSecret, aes_128_gcm, Version).

%% @doc Derive keys from a traffic secret.
%% Returns {Key, IV, HP} for the given secret.
-spec derive_keys(binary(), aes_128_gcm | aes_256_gcm | chacha20_poly1305) -> keys().
derive_keys(Secret, Cipher) ->
    derive_keys(Secret, Cipher, ?QUIC_VERSION_1).

%% @doc Derive keys from a traffic secret for a specific QUIC version.
%% QUIC v2 uses its own HKDF labels (RFC 9369 §3.3.1); deriving with the
%% v1 labels on a v2 connection yields keys no other implementation has.
-spec derive_keys(
    binary(), aes_128_gcm | aes_256_gcm | chacha20_poly1305, non_neg_integer()
) -> keys().
derive_keys(Secret, Cipher, Version) ->
    {Hash, KeyLen, HPLen} = cipher_params(Cipher),
    {LKey, LIV, LHP} = packet_labels(Version),
    Key = quic_hkdf:expand_label(Hash, Secret, LKey, <<>>, KeyLen),
    IV = quic_hkdf:expand_label(Hash, Secret, LIV, <<>>, 12),
    HP = quic_hkdf:expand_label(Hash, Secret, LHP, <<>>, HPLen),
    {Key, IV, HP}.

%% @doc Derive traffic keys (Key, IV, HP) from a traffic secret.
%% Uses AES-128-GCM key sizes (16-byte key, 12-byte IV, 16-byte HP).
%% This is used for Initial and Handshake encryption levels.
-spec derive_traffic_keys(binary()) -> keys().
derive_traffic_keys(Secret) ->
    derive_keys(Secret, aes_128_gcm).

%% @doc Derive an updated application secret for key update (RFC 9001 Section 6).
%% The next application secret is computed as:
%%   updated_secret = HKDF-Expand-Label(current_secret, "quic ku", "", hash_len)
%% where "quic ku" is the label for key update.
-spec derive_updated_secret(binary(), aes_128_gcm | aes_256_gcm | chacha20_poly1305) -> binary().
derive_updated_secret(CurrentSecret, Cipher) ->
    derive_updated_secret(CurrentSecret, Cipher, ?QUIC_VERSION_1).

-spec derive_updated_secret(
    binary(), aes_128_gcm | aes_256_gcm | chacha20_poly1305, non_neg_integer()
) -> binary().
derive_updated_secret(CurrentSecret, aes_256_gcm, Version) ->
    %% AES-256-GCM uses SHA-384, so secret length is 48 bytes
    quic_hkdf:expand_label(sha384, CurrentSecret, ku_label(Version), <<>>, 48);
derive_updated_secret(CurrentSecret, _Cipher, Version) ->
    %% AES-128-GCM and ChaCha20-Poly1305 use SHA-256, so secret length is 32 bytes
    quic_hkdf:expand_label(sha256, CurrentSecret, ku_label(Version), <<>>, 32).

%% @doc Derive updated keys from an updated application secret.
%% This performs the full key update: derives the new secret and then derives keys.
%% Returns {UpdatedSecret, {Key, IV, HP}}.
-spec derive_updated_keys(binary(), aes_128_gcm | aes_256_gcm | chacha20_poly1305) ->
    {UpdatedSecret :: binary(), keys()}.
derive_updated_keys(CurrentSecret, Cipher) ->
    derive_updated_keys(CurrentSecret, Cipher, ?QUIC_VERSION_1).

-spec derive_updated_keys(
    binary(), aes_128_gcm | aes_256_gcm | chacha20_poly1305, non_neg_integer()
) ->
    {UpdatedSecret :: binary(), keys()}.
derive_updated_keys(CurrentSecret, Cipher, Version) ->
    UpdatedSecret = derive_updated_secret(CurrentSecret, Cipher, Version),
    Keys = derive_keys(UpdatedSecret, Cipher, Version),
    {UpdatedSecret, Keys}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% HKDF labels for packet protection, by version (RFC 9369 §3.3.1)
packet_labels(?QUIC_VERSION_2) ->
    {<<"quicv2 key">>, <<"quicv2 iv">>, <<"quicv2 hp">>};
packet_labels(_) ->
    {?QUIC_LABEL_QUIC_KEY, ?QUIC_LABEL_QUIC_IV, ?QUIC_LABEL_QUIC_HP}.

ku_label(?QUIC_VERSION_2) -> <<"quicv2 ku">>;
ku_label(_) -> <<"quic ku">>.

%% Get cipher parameters: {Hash, KeyLen, HPLen}
cipher_params(aes_128_gcm) -> {sha256, 16, 16};
cipher_params(aes_256_gcm) -> {sha384, 32, 32};
cipher_params(chacha20_poly1305) -> {sha256, 32, 32}.

%% Get the initial salt for a QUIC version
initial_salt(?QUIC_VERSION_1) ->
    ?QUIC_V1_INITIAL_SALT;
initial_salt(?QUIC_VERSION_2) ->
    ?QUIC_V2_INITIAL_SALT;
initial_salt(_) ->
    %% Default to v1 salt for unknown versions
    ?QUIC_V1_INITIAL_SALT.
