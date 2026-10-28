%%% -*- erlang -*-
%%%
%%% QUIC TLS 1.3 Message Handling
%%% RFC 8446 - TLS 1.3
%%% RFC 9001 - Using TLS to Secure QUIC
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc TLS 1.3 message generation and parsing for QUIC.
%%%
%%% This module handles TLS 1.3 handshake messages as they appear in
%%% QUIC CRYPTO frames. Messages are encoded without the TLS record layer.
%%%
%%% == TLS Messages in QUIC ==
%%%
%%% QUIC uses TLS 1.3 for the cryptographic handshake, but without the
%%% TLS record layer. TLS handshake messages are sent directly in
%%% CRYPTO frames.
%%%

-module(quic_tls).

-include("quic.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([
    %% ClientHello
    build_client_hello/1,

    %% Server message parsing (client-side)
    parse_server_hello/1,
    parse_encrypted_extensions/1,
    parse_certificate/1,
    parse_certificate_verify/1,
    parse_finished/1,

    %% Client Finished
    build_finished/1,
    verify_finished/3,
    verify_finished/4,

    %% Server-side message building
    parse_client_hello/1,
    build_server_hello/1,
    build_hello_retry_request/3,
    build_encrypted_extensions/1,
    build_certificate/2,
    build_certificate_verify/3,

    %% Transport parameters
    encode_transport_params/1,
    decode_transport_params/1,
    validate_transport_param_constraints/1,

    %% Preferred address (RFC 9000 Section 9.6)
    encode_preferred_address/1,
    decode_preferred_address/1,

    %% TLS message framing
    encode_handshake_message/2,
    decode_handshake_message/1,

    %% Client certificate support (mutual TLS)
    build_certificate_request/1,
    build_certificate_request/2,
    parse_certificate_request/1,
    build_certificate_verify_client/3,
    verify_certificate_verify/4,

    %% TLS 1.3 External PSK (RFC 8446 §4.2.11)
    select_psk/4,
    verify_resumption_binder/5,
    parse_extensions_ordered/1
]).

%%====================================================================
%% ClientHello
%%====================================================================

%% @doc Build a TLS 1.3 ClientHello message for QUIC.
%% Options:
%%   - server_name: SNI hostname (binary)
%%   - alpn: List of ALPN protocols (list of binaries)
%%   - transport_params: QUIC transport parameters (map)
%%   - session_ticket: #session_ticket{} for resumption with PSK (optional)
%%
%% Returns: {ClientHelloMsg, PrivateKey, Random}
-spec build_client_hello(map()) -> {binary(), quic_crypto:kex_private(), binary()}.
build_client_hello(Opts) ->
    %% Key-share group: the head of `groups' (default x25519). The
    %% remaining groups are advertised in supported_groups so the
    %% server can request one via HelloRetryRequest.
    Groups = maps:get(groups, Opts, default_groups()),
    %% Group that gets the key_share entry: the head of `groups', or an
    %% explicit override (used by a HelloRetryRequest retry where
    %% supported_groups is unchanged but the share moves to the
    %% server-selected group).
    HeadGroup = maps:get(key_share_group, Opts, hd(Groups)),
    {PubKey, PrivKey} = quic_crypto:generate_key_pair(HeadGroup),

    %% On a HelloRetryRequest retry, CH2 MUST reuse CH1's random and
    %% legacy_session_id (RFC 8446 §4.1.2).
    Random =
        case maps:get(retry_random, Opts, undefined) of
            undefined -> crypto:strong_rand_bytes(32);
            R when is_binary(R) -> R
        end,
    Opts1 = Opts#{
        groups => Groups,
        head_group => HeadGroup,
        session_id => maps:get(retry_session_id, Opts, <<>>)
    },

    %% Resolve PSK offer (resumption ticket or external PSK). The
    %% caller is responsible for ensuring at most one is supplied;
    %% psk_offer_from_opts/1 raises {bad_opts, psk_conflict} otherwise.
    case psk_offer_from_opts(Opts1) of
        undefined ->
            build_client_hello_standard(Random, PubKey, PrivKey, Opts1);
        #psk_offer{} = Offer ->
            build_client_hello_with_psk(Random, PubKey, PrivKey, Opts1, Offer)
    end.

%% @private Default key-exchange groups (wire-compatible with the
%% pre-multigroup behaviour: x25519 only).
default_groups() -> [x25519].

%% @private Default advertised signature schemes, identical to the
%% historical hardcoded ClientHello list.
default_sig_algs() ->
    [ecdsa_secp256r1_sha256, rsa_pss_rsae_sha256, rsa_pkcs1_sha256, ed25519].

%% @private Named-group atom to RFC 8446 §4.2.7 wire code.
group_to_code(x25519) -> ?GROUP_X25519;
group_to_code(secp256r1) -> ?GROUP_SECP256R1;
group_to_code(secp384r1) -> ?GROUP_SECP384R1;
group_to_code(x25519mlkem768) -> ?GROUP_X25519MLKEM768.

%% @private Signature-scheme atom to RFC 8446 §4.2.3 wire code.
sig_alg_to_code(ecdsa_secp256r1_sha256) -> ?SIG_ECDSA_SECP256R1_SHA256;
sig_alg_to_code(ecdsa_secp384r1_sha384) -> ?SIG_ECDSA_SECP384R1_SHA384;
sig_alg_to_code(rsa_pss_rsae_sha256) -> ?SIG_RSA_PSS_RSAE_SHA256;
sig_alg_to_code(rsa_pss_rsae_sha384) -> ?SIG_RSA_PSS_RSAE_SHA384;
sig_alg_to_code(rsa_pss_rsae_sha512) -> ?SIG_RSA_PSS_RSAE_SHA512;
sig_alg_to_code(ed25519) -> ?SIG_ED25519;
sig_alg_to_code(rsa_pkcs1_sha256) -> ?SIG_RSA_PKCS1_SHA256.

%% @private Resolve external_psk/session_ticket into a #psk_offer{}.
psk_offer_from_opts(Opts) ->
    Ticket = maps:get(session_ticket, Opts, undefined),
    Ext = maps:get(external_psk, Opts, undefined),
    case {Ticket, Ext} of
        {undefined, undefined} -> undefined;
        {_, undefined} -> psk_offer_from_ticket(Ticket);
        {undefined, _} -> psk_offer_from_external(Ext);
        {_, _} -> error({bad_opts, psk_conflict})
    end.

psk_offer_from_ticket(#session_ticket{} = Ticket) ->
    Secret = quic_ticket:derive_psk(Ticket#session_ticket.resumption_secret, Ticket),
    Now = erlang:system_time(second),
    TicketAge = (Now - Ticket#session_ticket.received_at) * 1000,
    Age = (TicketAge + Ticket#session_ticket.age_add) band 16#FFFFFFFF,
    #psk_offer{
        type = resumption,
        identity = Ticket#session_ticket.ticket,
        age = Age,
        secret = Secret,
        cipher = Ticket#session_ticket.cipher,
        modes = [psk_dhe_ke],
        early_data = Ticket#session_ticket.max_early_data > 0
    }.

psk_offer_from_external({Identity, Secret}) ->
    psk_offer_from_external({Identity, Secret, [psk_dhe_ke]});
psk_offer_from_external({Identity, Secret, Modes}) when
    is_binary(Identity),
    byte_size(Identity) > 0,
    is_binary(Secret),
    byte_size(Secret) > 0,
    is_list(Modes),
    Modes =/= []
->
    %% Currently only TLS_AES_128_GCM_SHA256 is supported; binder
    %% length, key schedule hash and HKDF all key off this. When more
    %% suites land, surface a `cipher' option here.
    #psk_offer{
        type = external,
        identity = Identity,
        age = 0,
        secret = Secret,
        cipher = aes_128_gcm,
        modes = validate_psk_modes(Modes)
    };
psk_offer_from_external(Other) ->
    error({bad_opts, {external_psk, Other}}).

validate_psk_modes(Modes) ->
    Allowed = [psk_dhe_ke, psk_ke],
    case [M || M <- Modes, not lists:member(M, Allowed)] of
        [] -> Modes;
        Bad -> error({bad_opts, {unsupported_psk_modes, Bad}})
    end.

%% The offered suites come from the `ciphers' option; the hardcoded
%% AES-128-only offer meant the server's choice was never really a
%% choice, and a peer that requires another suite failed the handshake.
client_cipher_suites(Opts) ->
    Ciphers = maps:get(ciphers, Opts, quic_crypto:default_cipher_preference()),
    <<<<(suite_from_cipher(C)):16>> || C <- Ciphers>>.

suite_from_cipher(aes_128_gcm) -> ?TLS_AES_128_GCM_SHA256;
suite_from_cipher(aes_256_gcm) -> ?TLS_AES_256_GCM_SHA384;
suite_from_cipher(chacha20_poly1305) -> ?TLS_CHACHA20_POLY1305_SHA256.

%% Build standard ClientHello without PSK
build_client_hello_standard(Random, PubKey, PrivKey, Opts) ->
    %% Build extensions
    Extensions = build_client_hello_extensions(PubKey, Opts),

    %% Legacy session ID (empty for TLS 1.3, or CH1's value on retry)
    SessionId = maps:get(session_id, Opts, <<>>),

    %% Cipher suites (TLS 1.3 only)
    CipherSuites = client_cipher_suites(Opts),

    %% Legacy compression methods (null only)
    CompressionMethods = <<1, 0>>,

    %% Build ClientHello body
    ClientHello = <<
        % legacy_version (always 0x0303)
        ?TLS_VERSION_1_2:16,
        % random
        Random:32/binary,
        % legacy_session_id length
        (byte_size(SessionId)):8,
        % legacy_session_id
        SessionId/binary,
        % cipher_suites length
        (byte_size(CipherSuites)):16,
        % cipher_suites
        CipherSuites/binary,
        % legacy_compression_methods
        CompressionMethods/binary,
        % extensions length
        (byte_size(Extensions)):16,
        % extensions
        Extensions/binary
    >>,

    %% Wrap in handshake message
    Msg = encode_handshake_message(?TLS_CLIENT_HELLO, ClientHello),
    {Msg, PrivKey, Random}.

%% Build ClientHello with `pre_shared_key' extension for either a
%% resumption ticket or an external PSK.
%% RFC 8446 §4.2.11: pre_shared_key MUST be the last extension; the
%% binder is computed over the truncated ClientHello (everything
%% before the binders section).
build_client_hello_with_psk(Random, PubKey, PrivKey, Opts, #psk_offer{} = Offer) ->
    #psk_offer{
        identity = Identity,
        age = Age,
        secret = Secret,
        cipher = Cipher,
        modes = Modes,
        type = OfferType,
        early_data = OfferEarlyData
    } = Offer,

    %% Base extensions advertise the configured PSK modes (drives the
    %% server's `psk_key_exchange_modes' decision).
    OptsWithModes = Opts#{psk_modes => Modes},
    BaseExtensions0 = build_client_hello_extensions(PubKey, OptsWithModes),
    %% RFC 8446 §4.2.10 / RFC 9001 §4.6.1: offer 0-RTT by carrying an empty
    %% early_data extension in the ClientHello (before pre_shared_key, which
    %% must remain the last extension), and only on a ticket that allows it.
    BaseExtensions =
        case OfferEarlyData of
            true ->
                <<BaseExtensions0/binary, (encode_extension(?EXT_EARLY_DATA, <<>>))/binary>>;
            false ->
                BaseExtensions0
        end,

    %% Binder length comes from the negotiated hash (32 for SHA-256, 48 for SHA-384).
    Hash = quic_crypto:cipher_to_hash(Cipher),
    BinderLen = quic_crypto:hash_len(Hash),

    %% PskIdentity: identity<1..2^16-1>, obfuscated_ticket_age.
    %% External PSK uses age = 0 per RFC 8446 §4.2.11.
    IdentityLen = byte_size(Identity),
    PskIdentity = <<IdentityLen:16, Identity/binary, Age:32>>,
    IdentitiesLen = byte_size(PskIdentity),
    Identities = <<IdentitiesLen:16, PskIdentity/binary>>,

    BinderPlaceholder = <<0:BinderLen/unit:8>>,
    BindersSection = <<(BinderLen + 1):16, BinderLen:8, BinderPlaceholder/binary>>,

    PskExtBody = <<Identities/binary, BindersSection/binary>>,
    PskExtLen = byte_size(PskExtBody),
    PskExt = <<?EXT_PRE_SHARED_KEY:16, PskExtLen:16, PskExtBody/binary>>,

    AllExtensions = <<BaseExtensions/binary, PskExt/binary>>,
    ExtensionsLen = byte_size(AllExtensions),

    SessionId = maps:get(session_id, Opts, <<>>),
    CipherSuites = client_cipher_suites(Opts),
    CompressionMethods = <<1, 0>>,

    ClientHelloBody = <<
        ?TLS_VERSION_1_2:16,
        Random:32/binary,
        (byte_size(SessionId)):8,
        SessionId/binary,
        (byte_size(CipherSuites)):16,
        CipherSuites/binary,
        CompressionMethods/binary,
        ExtensionsLen:16,
        AllExtensions/binary
    >>,

    %% Truncate before the binders section to feed the binder HMAC.
    BindersSectionLen = byte_size(BindersSection),
    TruncatedLen = byte_size(ClientHelloBody) - BindersSectionLen,
    <<TruncatedBody:TruncatedLen/binary, _/binary>> = ClientHelloBody,
    %% RFC 8446 §4.2.11.2: the binder transcript keeps every length field
    %% (including the handshake-message length) at its final post-binder
    %% value; only the binder bytes are removed. So encode the full body and
    %% strip the binders off the end, preserving the full-length header.
    FullMsg = encode_handshake_message(?TLS_CLIENT_HELLO, ClientHelloBody),
    TruncatedMsg = binary:part(FullMsg, 0, byte_size(FullMsg) - BindersSectionLen),

    EarlySecret = quic_crypto:derive_early_secret(Cipher, Secret),
    TruncatedHash = quic_crypto:transcript_hash(Cipher, TruncatedMsg),
    Binder = quic_crypto:compute_psk_binder(Cipher, EarlySecret, TruncatedHash, OfferType),

    FinalBindersSection = <<(BinderLen + 1):16, BinderLen:8, Binder/binary>>,
    FinalClientHello = <<TruncatedBody/binary, FinalBindersSection/binary>>,

    Msg = encode_handshake_message(?TLS_CLIENT_HELLO, FinalClientHello),
    {Msg, PrivKey, Random}.

%% Build ClientHello extensions
build_client_hello_extensions(PubKey, Opts) ->
    ServerName = maps:get(server_name, Opts, undefined),
    Alpn = maps:get(alpn, Opts, []),
    TransportParams = maps:get(transport_params, Opts, #{}),

    %% Supported versions (TLS 1.3 only)
    %% Length is in bytes (2 bytes per version), not version count
    SupportedVersions = encode_extension(
        ?EXT_SUPPORTED_VERSIONS,
        <<2, ?TLS_VERSION_1_3:16>>
    ),

    %% Supported groups: every entry the client offers (head gets a
    %% key_share below; the rest are HRR-eligible).
    Groups = maps:get(groups, Opts, default_groups()),
    GroupCodes = iolist_to_binary([<<(group_to_code(G)):16>> || G <- Groups]),
    SupportedGroups = encode_extension(
        ?EXT_SUPPORTED_GROUPS,
        <<(byte_size(GroupCodes)):16, GroupCodes/binary>>
    ),

    %% Signature algorithms (caller-configurable; defaults to the
    %% historical wire list).
    SigAlgAtoms = maps:get(signature_algs, Opts, default_sig_algs()),
    SigAlgCodes = iolist_to_binary([<<(sig_alg_to_code(A)):16>> || A <- SigAlgAtoms]),
    SigAlgs = encode_extension(
        ?EXT_SIGNATURE_ALGORITHMS,
        <<(byte_size(SigAlgCodes)):16, SigAlgCodes/binary>>
    ),

    %% Key share: single entry for the head group.
    HeadGroup = maps:get(head_group, Opts, hd(Groups)),
    KeyShareEntry = <<(group_to_code(HeadGroup)):16, (byte_size(PubKey)):16, PubKey/binary>>,
    KeyShare = encode_extension(
        ?EXT_KEY_SHARE,
        <<(byte_size(KeyShareEntry)):16, KeyShareEntry/binary>>
    ),

    %% Server Name Indication
    SNI =
        case ServerName of
            undefined ->
                <<>>;
            Name when is_binary(Name) ->
                NameLen = byte_size(Name),
                NameList = <<0, NameLen:16, Name/binary>>,
                encode_extension(
                    ?EXT_SERVER_NAME,
                    <<(byte_size(NameList)):16, NameList/binary>>
                )
        end,

    %% ALPN
    AlpnExt =
        case Alpn of
            [] ->
                <<>>;
            Protocols ->
                ProtocolList = encode_alpn_list(Protocols),
                encode_extension(
                    ?EXT_ALPN,
                    <<(byte_size(ProtocolList)):16, ProtocolList/binary>>
                )
        end,

    %% QUIC Transport Parameters
    TransportParamsData = encode_transport_params(TransportParams),
    TransportParamsExt = encode_extension(
        ?EXT_QUIC_TRANSPORT_PARAMS,
        TransportParamsData
    ),

    %% PSK Key Exchange Modes — list of bytes per RFC 8446 §4.2.9.
    %% Defaults to `psk_dhe_ke' only; callers offering external PSK
    %% may pass `psk_modes => [psk_ke, psk_dhe_ke]` etc.
    Modes = maps:get(psk_modes, Opts, [psk_dhe_ke]),
    ModeBytes = iolist_to_binary([encode_psk_mode(M) || M <- Modes]),
    PskModes = encode_extension(
        ?EXT_PSK_KEY_EXCHANGE_MODES,
        <<(byte_size(ModeBytes)):8, ModeBytes/binary>>
    ),

    iolist_to_binary([
        SupportedVersions,
        SupportedGroups,
        SigAlgs,
        KeyShare,
        SNI,
        AlpnExt,
        TransportParamsExt,
        PskModes
    ]).

encode_alpn_list(Protocols) ->
    iolist_to_binary([<<(byte_size(P)):8, P/binary>> || P <- Protocols]).

%%====================================================================
%% Server Message Parsing
%%====================================================================

%% @doc Parse a ServerHello message.
%% Returns server's public key and selected cipher suite.
-spec parse_server_hello(binary()) ->
    {ok, #{
        public_key := binary() | undefined,
        selected_group := atom() | undefined,
        cipher := atom(),
        random := binary(),
        selected_psk_identity => non_neg_integer()
    }}
    | {hrr, #{cipher := atom(), selected_group := atom() | unknown, extensions := map()}}
    | {error, term()}.
parse_server_hello(<<
    % legacy_version
    ?TLS_VERSION_1_2:16,
    Random:32/binary,
    SessionIdLen:8,
    SessionId:SessionIdLen/binary,
    CipherSuite:16,
    % legacy_compression_method
    0,
    ExtensionsLen:16,
    Extensions:ExtensionsLen/binary,
    _Rest/binary
>>) ->
    case parse_extensions(Extensions) of
        {ok, ExtMap} when Random =:= ?TLS_HRR_RANDOM ->
            %% HelloRetryRequest (RFC 8446 §4.1.4): a ServerHello whose
            %% random is the HRR sentinel. Its key_share extension
            %% carries only the selected group (KeyShareHelloRetryRequest).
            Cipher = cipher_from_suite(CipherSuite),
            case maps:find(?EXT_KEY_SHARE, ExtMap) of
                {ok, <<GroupCode:16>>} ->
                    {hrr, #{
                        cipher => Cipher,
                        selected_group => code_to_group(GroupCode),
                        extensions => ExtMap
                    }};
                _ ->
                    {error, hrr_missing_key_share}
            end;
        {ok, ExtMap} ->
            Cipher = cipher_from_suite(CipherSuite),
            SelectedPsk =
                case maps:find(?EXT_PRE_SHARED_KEY, ExtMap) of
                    {ok, <<Idx:16>>} -> Idx;
                    _ -> undefined
                end,
            KeyShareResult =
                case maps:find(?EXT_KEY_SHARE, ExtMap) of
                    {ok, KeyShareData} ->
                        parse_server_key_share(KeyShareData);
                    error when SelectedPsk =/= undefined ->
                        %% psk_ke handshake: no DHE → public_key=undefined.
                        {ok, {undefined, undefined}};
                    error ->
                        {error, missing_key_share}
                end,
            case KeyShareResult of
                {ok, {SelectedGroup, PubKey}} ->
                    Base = #{
                        public_key => PubKey,
                        selected_group => SelectedGroup,
                        cipher => Cipher,
                        random => Random,
                        session_id => SessionId,
                        extensions => ExtMap
                    },
                    Result =
                        case SelectedPsk of
                            undefined -> Base;
                            Idx2 -> Base#{selected_psk_identity => Idx2}
                        end,
                    {ok, Result};
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
parse_server_hello(_) ->
    {error, invalid_server_hello}.

%% @doc Parse EncryptedExtensions message.
%% The `early_data' field signals whether the server accepted 0-RTT by
%% echoing an empty `early_data' extension (RFC 8446 §4.2.10, RFC 9001
%% §4.6.2). Presence is the entire signal; the extension body is empty
%% on the EE path.
-spec parse_encrypted_extensions(binary()) ->
    {ok, #{alpn => binary(), transport_params => map(), early_data => boolean()}}
    | {error, term()}.
parse_encrypted_extensions(<<ExtensionsLen:16, Extensions:ExtensionsLen/binary, _Rest/binary>>) ->
    case parse_extensions(Extensions) of
        {ok, ExtMap} ->
            Alpn =
                case maps:find(?EXT_ALPN, ExtMap) of
                    {ok, <<_ListLen:16, ProtoLen:8, Proto:ProtoLen/binary, _/binary>>} ->
                        Proto;
                    _ ->
                        undefined
                end,
            TransportParams =
                case maps:find(?EXT_QUIC_TRANSPORT_PARAMS, ExtMap) of
                    {ok, TPData} ->
                        case decode_transport_params(TPData) of
                            {ok, TP} -> TP;
                            _ -> #{}
                        end;
                    _ ->
                        #{}
                end,
            EarlyData = maps:is_key(?EXT_EARLY_DATA, ExtMap),
            {ok, #{
                alpn => Alpn,
                transport_params => TransportParams,
                early_data => EarlyData
            }};
        Error ->
            Error
    end;
parse_encrypted_extensions(_) ->
    {error, invalid_encrypted_extensions}.

%% @doc Parse Certificate message.
-spec parse_certificate(binary()) ->
    {ok, #{context := binary(), certificates := [binary()]}}
    | {error, term()}.
parse_certificate(
    <<ContextLen:8, Context:ContextLen/binary, CertsLen:24, CertsData:CertsLen/binary,
        _Rest/binary>>
) ->
    Certs = parse_certificate_list(CertsData),
    {ok, #{context => Context, certificates => Certs}};
parse_certificate(_) ->
    {error, invalid_certificate}.

parse_certificate_list(<<>>) ->
    [];
parse_certificate_list(
    <<CertLen:24, Cert:CertLen/binary, ExtLen:16, _Ext:ExtLen/binary, Rest/binary>>
) ->
    [Cert | parse_certificate_list(Rest)].

%% @doc Parse CertificateVerify message.
-spec parse_certificate_verify(binary()) ->
    {ok, #{algorithm := non_neg_integer(), signature := binary()}}
    | {error, term()}.
parse_certificate_verify(<<Algorithm:16, SigLen:16, Signature:SigLen/binary, _Rest/binary>>) ->
    {ok, #{algorithm => Algorithm, signature => Signature}};
parse_certificate_verify(_) ->
    {error, invalid_certificate_verify}.

%% @doc Parse Finished message.
-spec parse_finished(binary()) -> {ok, binary()} | {error, term()}.
parse_finished(VerifyData) when byte_size(VerifyData) >= 32 ->
    %% The verify_data length depends on the negotiated hash (32 for
    %% SHA-256, 48 for SHA-384), so return the whole body and let
    %% verification compare.
    {ok, VerifyData};
parse_finished(_) ->
    {error, invalid_finished}.

%%====================================================================
%% Client Finished
%%====================================================================

%% @doc Build a Finished message.
%% VerifyData should be computed using quic_crypto:compute_finished_verify/2.
-spec build_finished(binary()) -> binary().
build_finished(VerifyData) ->
    encode_handshake_message(?TLS_FINISHED, VerifyData).

%% @doc Verify a Finished message (default SHA-256).
%% TrafficSecret is the sender's traffic secret.
%% TranscriptHash is the hash of all messages up to (but not including) Finished.
-spec verify_finished(binary(), binary(), binary()) -> boolean().
verify_finished(ReceivedVerifyData, TrafficSecret, TranscriptHash) ->
    FinishedKey = quic_crypto:derive_finished_key(TrafficSecret),
    ExpectedVerifyData = quic_crypto:compute_finished_verify(FinishedKey, TranscriptHash),
    hash_equals(ReceivedVerifyData, ExpectedVerifyData).

%% @doc Verify a Finished message with cipher-specific hash.
-spec verify_finished(binary(), binary(), binary(), atom()) -> boolean().
verify_finished(ReceivedVerifyData, TrafficSecret, TranscriptHash, Cipher) ->
    FinishedKey = quic_crypto:derive_finished_key(Cipher, TrafficSecret),
    ExpectedVerifyData = quic_crypto:compute_finished_verify(Cipher, FinishedKey, TranscriptHash),
    hash_equals(ReceivedVerifyData, ExpectedVerifyData).

%% crypto:hash_equals/2 raises badarg on length mismatch; a wrong-length
%% verify_data is a verification failure, not a crash.
hash_equals(A, B) when byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
hash_equals(_, _) ->
    false.

%%====================================================================
%% Transport Parameters
%%====================================================================

%% @doc Encode QUIC transport parameters.
%% Params is a map with keys like:
%%   original_dcid, max_idle_timeout, max_udp_payload_size,
%%   initial_max_data, initial_max_stream_data_bidi_local, etc.
-spec encode_transport_params(map()) -> binary().
encode_transport_params(Params) ->
    Encoded = maps:fold(
        fun(Key, Value, Acc) ->
            case encode_transport_param(Key, Value) of
                <<>> -> Acc;
                Bin -> [Bin | Acc]
            end
        end,
        [],
        Params
    ),
    iolist_to_binary(lists:reverse(Encoded)).

encode_transport_param(original_dcid, Value) ->
    encode_tp(?TP_ORIGINAL_DCID, Value);
encode_transport_param(version_information, {Chosen, Available}) ->
    %% RFC 9368 §3: Chosen Version followed by Available Versions.
    Avail = <<<<V:32>> || V <- Available>>,
    encode_tp(?TP_VERSION_INFORMATION, <<Chosen:32, Avail/binary>>);
encode_transport_param(max_idle_timeout, Value) ->
    encode_tp(?TP_MAX_IDLE_TIMEOUT, quic_varint:encode(Value));
encode_transport_param(max_udp_payload_size, Value) ->
    encode_tp(?TP_MAX_UDP_PAYLOAD_SIZE, quic_varint:encode(Value));
encode_transport_param(initial_max_data, Value) ->
    encode_tp(?TP_INITIAL_MAX_DATA, quic_varint:encode(Value));
encode_transport_param(initial_max_stream_data_bidi_local, Value) ->
    encode_tp(?TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL, quic_varint:encode(Value));
encode_transport_param(initial_max_stream_data_bidi_remote, Value) ->
    encode_tp(?TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE, quic_varint:encode(Value));
encode_transport_param(initial_max_stream_data_uni, Value) ->
    encode_tp(?TP_INITIAL_MAX_STREAM_DATA_UNI, quic_varint:encode(Value));
encode_transport_param(initial_max_streams_bidi, Value) ->
    encode_tp(?TP_INITIAL_MAX_STREAMS_BIDI, quic_varint:encode(Value));
encode_transport_param(initial_max_streams_uni, Value) ->
    encode_tp(?TP_INITIAL_MAX_STREAMS_UNI, quic_varint:encode(Value));
encode_transport_param(ack_delay_exponent, Value) ->
    encode_tp(?TP_ACK_DELAY_EXPONENT, quic_varint:encode(Value));
encode_transport_param(max_ack_delay, Value) ->
    encode_tp(?TP_MAX_ACK_DELAY, quic_varint:encode(Value));
encode_transport_param(disable_active_migration, true) ->
    encode_tp(?TP_DISABLE_ACTIVE_MIGRATION, <<>>);
encode_transport_param(active_connection_id_limit, Value) ->
    encode_tp(?TP_ACTIVE_CONNECTION_ID_LIMIT, quic_varint:encode(Value));
encode_transport_param(initial_scid, Value) ->
    encode_tp(?TP_INITIAL_SCID, Value);
encode_transport_param(retry_scid, Value) ->
    encode_tp(?TP_RETRY_SCID, Value);
encode_transport_param(stateless_reset_token, Value) ->
    encode_tp(?TP_STATELESS_RESET_TOKEN, Value);
encode_transport_param(preferred_address, #preferred_address{} = PA) ->
    encode_tp(?TP_PREFERRED_ADDRESS, encode_preferred_address(PA));
encode_transport_param(max_datagram_frame_size, Value) when Value > 0 ->
    encode_tp(?TP_MAX_DATAGRAM_FRAME_SIZE, quic_varint:encode(Value));
%% draft-ietf-quic-reliable-stream-reset-07 - Reliable RESET_STREAM
encode_transport_param(reset_stream_at, true) ->
    encode_tp(?TP_RESET_STREAM_AT, <<>>);
encode_transport_param(_, _) ->
    <<>>.

encode_tp(Id, Value) ->
    IdBin = quic_varint:encode(Id),
    LenBin = quic_varint:encode(byte_size(Value)),
    <<IdBin/binary, LenBin/binary, Value/binary>>.

%% @doc Decode QUIC transport parameters.
%% RFC 9000 Section 7.4: Validates against duplicate parameters and semantic constraints
-spec decode_transport_params(binary()) -> {ok, map()} | {error, term()}.
decode_transport_params(Data) ->
    try
        case decode_transport_params_loop(Data, #{}) of
            {ok, Params} -> validate_transport_params(Params);
            Error -> Error
        end
    catch
        error:_ -> {error, invalid_transport_params}
    end.

decode_transport_params_loop(<<>>, Acc) ->
    {ok, Acc};
decode_transport_params_loop(Data, Acc) ->
    {Id, Rest1} = quic_varint:decode(Data),
    {Len, Rest2} = quic_varint:decode(Rest1),
    <<Value:Len/binary, Rest3/binary>> = Rest2,
    Key = tp_id_to_key(Id),
    %% RFC 9000 Section 7.4: Duplicate transport parameters MUST be treated as error
    case maps:is_key(Key, Acc) of
        true ->
            {error, {transport_parameter_error, duplicate_parameter, Key}};
        false ->
            DecodedValue = decode_tp_value(Id, Value),
            decode_transport_params_loop(Rest3, maps:put(Key, DecodedValue, Acc))
    end.

%% @doc Validate transport parameter semantic constraints
%% RFC 9000 Section 18.2
-spec validate_transport_params(map()) -> {ok, map()} | {error, term()}.
validate_transport_params(Params) ->
    case validate_transport_param_constraints(Params) of
        ok -> {ok, Params};
        {error, _} = Error -> Error
    end.

%% @doc Check the peer's transport parameters against the RFC 9000 §18.2
%% bounds. Returns `ok' or the offending parameter; the caller decides what
%% to do about it, since a connection defers its close until its own
%% handshake flight has been sent.
-spec validate_transport_param_constraints(map()) -> ok | {error, term()}.
validate_transport_param_constraints(Params) ->
    %% RFC 9000 Section 18.2: active_connection_id_limit MUST be >= 2
    case maps:get(active_connection_id_limit, Params, 2) of
        N when N < 2 ->
            {error, {transport_parameter_error, active_connection_id_limit_too_small, N}};
        _ ->
            validate_ack_delay_exponent(Params)
    end.

validate_ack_delay_exponent(Params) ->
    %% RFC 9000 Section 18.2: ack_delay_exponent MUST be <= 20
    case maps:get(ack_delay_exponent, Params, 3) of
        N when N > 20 ->
            {error, {transport_parameter_error, ack_delay_exponent_too_large, N}};
        _ ->
            validate_max_udp_payload_size(Params)
    end.

validate_max_udp_payload_size(Params) ->
    %% RFC 9000 Section 18.2: max_udp_payload_size MUST be >= 1200
    case maps:get(max_udp_payload_size, Params, 65527) of
        N when N < 1200 ->
            {error, {transport_parameter_error, max_udp_payload_size_too_small, N}};
        _ ->
            validate_max_ack_delay(Params)
    end.

validate_max_ack_delay(Params) ->
    %% RFC 9000 Section 18.2: max_ack_delay MUST be < 2^14 (16384)
    case maps:get(max_ack_delay, Params, 25) of
        N when N >= 16384 ->
            {error, {transport_parameter_error, max_ack_delay_too_large, N}};
        _ ->
            ok
    end.

tp_id_to_key(?TP_ORIGINAL_DCID) -> original_dcid;
tp_id_to_key(?TP_MAX_IDLE_TIMEOUT) -> max_idle_timeout;
tp_id_to_key(?TP_STATELESS_RESET_TOKEN) -> stateless_reset_token;
tp_id_to_key(?TP_MAX_UDP_PAYLOAD_SIZE) -> max_udp_payload_size;
tp_id_to_key(?TP_INITIAL_MAX_DATA) -> initial_max_data;
tp_id_to_key(?TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL) -> initial_max_stream_data_bidi_local;
tp_id_to_key(?TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE) -> initial_max_stream_data_bidi_remote;
tp_id_to_key(?TP_INITIAL_MAX_STREAM_DATA_UNI) -> initial_max_stream_data_uni;
tp_id_to_key(?TP_INITIAL_MAX_STREAMS_BIDI) -> initial_max_streams_bidi;
tp_id_to_key(?TP_INITIAL_MAX_STREAMS_UNI) -> initial_max_streams_uni;
tp_id_to_key(?TP_ACK_DELAY_EXPONENT) -> ack_delay_exponent;
tp_id_to_key(?TP_MAX_ACK_DELAY) -> max_ack_delay;
tp_id_to_key(?TP_DISABLE_ACTIVE_MIGRATION) -> disable_active_migration;
tp_id_to_key(?TP_PREFERRED_ADDRESS) -> preferred_address;
tp_id_to_key(?TP_ACTIVE_CONNECTION_ID_LIMIT) -> active_connection_id_limit;
tp_id_to_key(?TP_INITIAL_SCID) -> initial_scid;
tp_id_to_key(?TP_RETRY_SCID) -> retry_scid;
tp_id_to_key(?TP_VERSION_INFORMATION) -> version_information;
tp_id_to_key(?TP_MAX_DATAGRAM_FRAME_SIZE) -> max_datagram_frame_size;
tp_id_to_key(?TP_RESET_STREAM_AT) -> reset_stream_at;
tp_id_to_key(Id) -> {unknown, Id}.

decode_tp_value(?TP_ORIGINAL_DCID, Value) ->
    Value;
decode_tp_value(?TP_VERSION_INFORMATION, <<Chosen:32, Rest/binary>>) ->
    {Chosen, [V || <<V:32>> <= Rest]};
decode_tp_value(?TP_STATELESS_RESET_TOKEN, Value) ->
    Value;
decode_tp_value(?TP_INITIAL_SCID, Value) ->
    Value;
decode_tp_value(?TP_RETRY_SCID, Value) ->
    Value;
decode_tp_value(?TP_DISABLE_ACTIVE_MIGRATION, <<>>) ->
    true;
decode_tp_value(?TP_RESET_STREAM_AT, <<>>) ->
    true;
decode_tp_value(?TP_RESET_STREAM_AT, _) ->
    %% Non-empty value is a TRANSPORT_PARAMETER_ERROR per spec
    error({transport_parameter_error, reset_stream_at_non_empty});
decode_tp_value(?TP_PREFERRED_ADDRESS, Value) ->
    decode_preferred_address(Value);
%% Known integer parameters (varints)
decode_tp_value(Id, Value) when
    Id =:= ?TP_MAX_IDLE_TIMEOUT;
    Id =:= ?TP_MAX_UDP_PAYLOAD_SIZE;
    Id =:= ?TP_INITIAL_MAX_DATA;
    Id =:= ?TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL;
    Id =:= ?TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE;
    Id =:= ?TP_INITIAL_MAX_STREAM_DATA_UNI;
    Id =:= ?TP_INITIAL_MAX_STREAMS_BIDI;
    Id =:= ?TP_INITIAL_MAX_STREAMS_UNI;
    Id =:= ?TP_ACK_DELAY_EXPONENT;
    Id =:= ?TP_MAX_ACK_DELAY;
    Id =:= ?TP_ACTIVE_CONNECTION_ID_LIMIT;
    Id =:= ?TP_MAX_DATAGRAM_FRAME_SIZE
->
    %% Known integer parameters are varints
    {Int, _} = quic_varint:decode(Value),
    Int;
decode_tp_value(_Id, Value) ->
    %% RFC 9000 Section 18: Unknown transport parameters MUST be ignored.
    %% Store raw value to avoid decode errors on unknown/extension parameters.
    Value.

%% @doc Decode preferred_address transport parameter (RFC 9000 Section 18.2).
%% Format:
%%   IPv4 address:     4 bytes
%%   IPv4 port:        2 bytes
%%   IPv6 address:    16 bytes
%%   IPv6 port:        2 bytes
%%   CID length:       1 byte
%%   Connection ID:    variable (0-20 bytes)
%%   Stateless reset: 16 bytes
-spec decode_preferred_address(binary()) -> #preferred_address{}.
decode_preferred_address(<<
    IPv4_A:8,
    IPv4_B:8,
    IPv4_C:8,
    IPv4_D:8,
    IPv4Port:16,
    IPv6_1:16,
    IPv6_2:16,
    IPv6_3:16,
    IPv6_4:16,
    IPv6_5:16,
    IPv6_6:16,
    IPv6_7:16,
    IPv6_8:16,
    IPv6Port:16,
    CIDLen:8,
    CID:CIDLen/binary,
    StatelessResetToken:16/binary,
    _Rest/binary
>>) ->
    %% Parse IPv4 - zero address means not present
    {IPv4Addr, IPv4PortVal} =
        case {IPv4_A, IPv4_B, IPv4_C, IPv4_D, IPv4Port} of
            {0, 0, 0, 0, 0} -> {undefined, undefined};
            _ -> {{IPv4_A, IPv4_B, IPv4_C, IPv4_D}, IPv4Port}
        end,
    %% Parse IPv6 - zero address means not present
    {IPv6Addr, IPv6PortVal} =
        case {IPv6_1, IPv6_2, IPv6_3, IPv6_4, IPv6_5, IPv6_6, IPv6_7, IPv6_8, IPv6Port} of
            {0, 0, 0, 0, 0, 0, 0, 0, 0} -> {undefined, undefined};
            _ -> {{IPv6_1, IPv6_2, IPv6_3, IPv6_4, IPv6_5, IPv6_6, IPv6_7, IPv6_8}, IPv6Port}
        end,
    #preferred_address{
        ipv4_addr = IPv4Addr,
        ipv4_port = IPv4PortVal,
        ipv6_addr = IPv6Addr,
        ipv6_port = IPv6PortVal,
        cid = CID,
        stateless_reset_token = StatelessResetToken
    }.

%% @doc Encode preferred_address transport parameter (RFC 9000 Section 18.2).
-spec encode_preferred_address(#preferred_address{}) -> binary().
encode_preferred_address(#preferred_address{
    ipv4_addr = IPv4Addr,
    ipv4_port = IPv4Port,
    ipv6_addr = IPv6Addr,
    ipv6_port = IPv6Port,
    cid = CID,
    stateless_reset_token = Token
}) ->
    %% Encode IPv4 (zeros if not present)
    IPv4Bin =
        case IPv4Addr of
            {A, B, C, D} -> <<A, B, C, D, IPv4Port:16>>;
            undefined -> <<0, 0, 0, 0, 0:16>>
        end,
    %% Encode IPv6 (zeros if not present)
    IPv6Bin =
        case IPv6Addr of
            {V1, V2, V3, V4, V5, V6, V7, V8} ->
                <<V1:16, V2:16, V3:16, V4:16, V5:16, V6:16, V7:16, V8:16, IPv6Port:16>>;
            undefined ->
                <<0:128, 0:16>>
        end,
    CIDLen = byte_size(CID),
    <<IPv4Bin/binary, IPv6Bin/binary, CIDLen:8, CID/binary, Token/binary>>.

%%====================================================================
%% TLS Message Framing
%%====================================================================

%% @doc Encode a TLS handshake message with type and length.
-spec encode_handshake_message(non_neg_integer(), binary()) -> binary().
encode_handshake_message(Type, Body) ->
    Length = byte_size(Body),
    <<Type:8, Length:24, Body/binary>>.

%% @doc Decode a TLS handshake message.
%% Returns {Type, Body, Rest} or {error, Reason}.
-spec decode_handshake_message(binary()) ->
    {ok, {non_neg_integer(), binary()}, binary()}
    | {error, term()}.
decode_handshake_message(<<Type:8, Length:24, Body:Length/binary, Rest/binary>>) ->
    {ok, {Type, Body}, Rest};
decode_handshake_message(<<_Type:8, Length:24, Data/binary>>) when byte_size(Data) < Length ->
    {error, incomplete};
%% Fewer than 4 bytes: the message header itself is split across CRYPTO
%% frames. There is no invalid framing at this layer, only insufficient
%% data; malformed content is rejected by the per-message parsers.
decode_handshake_message(_) ->
    {error, incomplete}.

%%====================================================================
%% Internal Functions
%%====================================================================

encode_extension(Type, Data) ->
    <<Type:16, (byte_size(Data)):16, Data/binary>>.

parse_extensions(Data) ->
    case parse_extensions_ordered(Data) of
        {ok, Ordered} ->
            {ok, maps:from_list([{T, D} || {T, D, _Off, _Sz} <- Ordered])};
        Error ->
            Error
    end.

%% @doc Parse an extensions blob preserving order and byte offsets.
%% Returns [{Type, Data, ByteOffset, ByteSize}] where ByteOffset is the
%% position of `Type' within `Data'. Rejects duplicate extension types
%% per RFC 8446 §4.2 with {error, {duplicate_extension, Type}}; the
%% caller maps that to an illegal_parameter alert.
-spec parse_extensions_ordered(binary()) ->
    {ok, [{non_neg_integer(), binary(), non_neg_integer(), non_neg_integer()}]}
    | {error, term()}.
parse_extensions_ordered(Data) ->
    parse_extensions_ordered(Data, 0, [], #{}).

parse_extensions_ordered(<<>>, _Off, Acc, _Seen) ->
    {ok, lists:reverse(Acc)};
parse_extensions_ordered(<<Type:16, Len:16, ExtData:Len/binary, Rest/binary>>, Off, Acc, Seen) ->
    case maps:is_key(Type, Seen) of
        true ->
            {error, {duplicate_extension, Type}};
        false ->
            Entry = {Type, ExtData, Off, 4 + Len},
            parse_extensions_ordered(
                Rest, Off + 4 + Len, [Entry | Acc], maps:put(Type, true, Seen)
            )
    end;
parse_extensions_ordered(<<Type:16, Len:16, Data/binary>>, _Off, _Acc, _Seen) when
    byte_size(Data) < Len
->
    {error, {extension_truncated, Type, Len, byte_size(Data)}};
parse_extensions_ordered(Data, _Off, _Acc, _Seen) when byte_size(Data) < 4 ->
    {error, {extension_header_incomplete, byte_size(Data)}};
parse_extensions_ordered(_, _, _, _) ->
    {error, invalid_extensions}.

parse_server_key_share(<<?GROUP_X25519:16, 32:16, PubKey:32/binary>>) ->
    {ok, {x25519, PubKey}};
parse_server_key_share(<<?GROUP_SECP256R1:16, 65:16, PubKey:65/binary>>) ->
    {ok, {secp256r1, PubKey}};
parse_server_key_share(<<?GROUP_SECP384R1:16, 97:16, PubKey:97/binary>>) ->
    {ok, {secp384r1, PubKey}};
parse_server_key_share(<<?GROUP_X25519MLKEM768:16, 1120:16, Share:1120/binary>>) ->
    %% ML-KEM-768 ciphertext (1088) || X25519 public (32)
    {ok, {x25519mlkem768, Share}};
parse_server_key_share(_) ->
    {error, illegal_parameter}.

cipher_from_suite(?TLS_AES_128_GCM_SHA256) -> aes_128_gcm;
cipher_from_suite(?TLS_AES_256_GCM_SHA384) -> aes_256_gcm;
cipher_from_suite(?TLS_CHACHA20_POLY1305_SHA256) -> chacha20_poly1305;
cipher_from_suite(_) -> aes_128_gcm.

%% @private Encode a single psk_key_exchange_mode byte (RFC 8446 §4.2.9).
encode_psk_mode(psk_ke) -> <<?PSK_KE_MODE_KE:8>>;
encode_psk_mode(psk_dhe_ke) -> <<?PSK_KE_MODE_DHE_KE:8>>.

%%====================================================================
%% Server-side TLS Functions
%%====================================================================

%% @doc Parse a ClientHello message.
%% Returns a map with:
%%   - random: 32-byte client random
%%   - session_id: Legacy session ID
%%   - cipher_suites: List of cipher suites offered
%%   - extensions: Map of extensions
%%   - key_share: Client's public key for key exchange
%%   - server_name: SNI hostname (if present)
%%   - alpn_protocols: List of ALPN protocols (if present)
%%   - transport_params: QUIC transport parameters (if present)
-spec parse_client_hello(binary()) ->
    {ok, map()} | {error, term()}.
parse_client_hello(<<
    % Legacy version
    ?TLS_VERSION_1_2:16,
    Random:32/binary,
    SessionIdLen:8,
    SessionId:SessionIdLen/binary,
    CipherSuitesLen:16,
    CipherSuites:CipherSuitesLen/binary,
    CompressionLen:8,
    _Compression:CompressionLen/binary,
    ExtLen:16,
    Extensions:ExtLen/binary,
    _Rest/binary
>>) ->
    %% Parse cipher suites
    Ciphers = parse_cipher_suites(CipherSuites),

    %% Parse extensions preserving order so PSK validation can assert
    %% pre_shared_key is the last extension and capture the binders
    %% offset for binder verification.
    case parse_extensions_ordered(Extensions) of
        {ok, OrderedExts} ->
            ExtMap = maps:from_list([{T, D} || {T, D, _Off, _Sz} <- OrderedExts]),

            %% Validate pre_shared_key placement (must be last per RFC 8446 §4.2.11).
            case validate_psk_extension_placement(OrderedExts) of
                ok ->
                    finalise_client_hello(
                        Random, SessionId, Ciphers, OrderedExts, ExtMap, Extensions
                    );
                {error, _} = Err ->
                    Err
            end;
        {error, Reason} ->
            {error, Reason}
    end;
parse_client_hello(Data) when is_binary(Data) ->
    %% Provide detailed error for debugging ClientHello parsing failures
    case Data of
        <<Version:16, _/binary>> when Version =/= ?TLS_VERSION_1_2 ->
            {error, {invalid_legacy_version, Version}};
        <<_:16, _Random:32/binary, SessionIdLen:8, Rest1/binary>> when
            byte_size(Rest1) < SessionIdLen
        ->
            {error, {session_id_too_short, SessionIdLen, byte_size(Rest1)}};
        <<_:16, _:32/binary, SessionIdLen:8, _:SessionIdLen/binary, CipherSuitesLen:16,
            Rest2/binary>> when byte_size(Rest2) < CipherSuitesLen ->
            {error, {cipher_suites_too_short, CipherSuitesLen, byte_size(Rest2)}};
        % Minimum: 2 + 32 + 1 + 2 + 1 = 38 bytes
        _ when byte_size(Data) < 38 ->
            {error, {client_hello_too_short, byte_size(Data)}};
        _ ->
            {error, {invalid_client_hello, byte_size(Data)}}
    end;
parse_client_hello(_) ->
    {error, invalid_client_hello_not_binary}.

%% @doc Build a ServerHello message.
%% Options:
%%   - random: Server random (32 bytes, generated if not provided)
%%   - session_id: Legacy session ID to echo
%%   - cipher_suite: Selected cipher suite
%%   - key_share: Server's public key
-spec build_server_hello(map()) -> {binary(), binary()}.
build_server_hello(Opts) ->
    %% Generate server random
    Random = maps:get(random, Opts, crypto:strong_rand_bytes(32)),

    %% Echo session ID from client
    SessionId = maps:get(session_id, Opts, <<>>),
    SessionIdLen = byte_size(SessionId),

    %% Selected cipher suite
    CipherSuite = maps:get(cipher_suite, Opts, ?TLS_AES_128_GCM_SHA256),

    %% Generate ECDHE key pair if not provided
    {PubKey, PrivKey} =
        case maps:find(key_pair, Opts) of
            {ok, {Pub, Priv}} -> {Pub, Priv};
            error -> crypto:generate_key(ecdh, x25519)
        end,

    %% Build extensions
    Extensions = build_server_hello_extensions(PubKey, Opts),
    ExtLen = byte_size(Extensions),

    %% Build ServerHello
    ServerHello = <<
        % Legacy version (TLS 1.2)
        ?TLS_VERSION_1_2:16,
        Random:32/binary,
        SessionIdLen:8,
        SessionId/binary,
        CipherSuite:16,
        % Legacy compression method (null)
        0:8,
        ExtLen:16,
        Extensions/binary
    >>,

    %% Wrap with handshake header
    Message = encode_handshake_message(?TLS_SERVER_HELLO, ServerHello),
    {Message, PrivKey}.

%% @doc Build a HelloRetryRequest (RFC 8446 §4.1.4). Wire-encoded as
%% a ServerHello with the HRR sentinel random; its key_share carries
%% only the selected group (no public key). Echoes the client's
%% legacy_session_id and the negotiated cipher suite.
-spec build_hello_retry_request(binary(), non_neg_integer(), atom()) -> binary().
build_hello_retry_request(SessionId, CipherSuite, SelectedGroup) ->
    SessionIdLen = byte_size(SessionId),
    SupportedVersions = encode_extension(
        ?EXT_SUPPORTED_VERSIONS,
        <<?TLS_VERSION_1_3:16>>
    ),
    KeyShare = encode_extension(
        ?EXT_KEY_SHARE,
        <<(group_to_code(SelectedGroup)):16>>
    ),
    Extensions = <<SupportedVersions/binary, KeyShare/binary>>,
    Body = <<
        ?TLS_VERSION_1_2:16,
        (?TLS_HRR_RANDOM)/binary,
        SessionIdLen:8,
        SessionId/binary,
        CipherSuite:16,
        0:8,
        (byte_size(Extensions)):16,
        Extensions/binary
    >>,
    encode_handshake_message(?TLS_SERVER_HELLO, Body).

%% @doc Build EncryptedExtensions message.
%% Options:
%%   - alpn: Selected ALPN protocol
%%   - transport_params: QUIC transport parameters
-spec build_encrypted_extensions(map()) -> binary().
build_encrypted_extensions(Opts) ->
    Extensions = build_encrypted_extensions_list(Opts),
    ExtLen = byte_size(Extensions),
    Body = <<ExtLen:16, Extensions/binary>>,
    encode_handshake_message(?TLS_ENCRYPTED_EXTENSIONS, Body).

%% @doc Build Certificate message.
%% Certs is a list of DER-encoded certificates (server cert first).
-spec build_certificate(binary(), [binary()]) -> binary().
build_certificate(Context, Certs) ->
    CertList = build_cert_list(Certs),
    CertListLen = byte_size(CertList),
    ContextLen = byte_size(Context),
    Body = <<ContextLen:8, Context/binary, CertListLen:24, CertList/binary>>,
    encode_handshake_message(?TLS_CERTIFICATE, Body).

%% @doc Build CertificateVerify message.
%% PrivateKey is the server's private key.
%% TranscriptHash is the hash of all handshake messages up to (not including) CertificateVerify.
-spec build_certificate_verify(non_neg_integer(), crypto:key_id(), binary()) -> binary().
build_certificate_verify(SignatureAlgorithm, PrivateKey, TranscriptHash) ->
    %% Build the content to sign
    %% RFC 8446 Section 4.4.3:
    %% Content = 64 spaces + "TLS 1.3, server CertificateVerify" + 0x00 + TranscriptHash
    Spaces = binary:copy(<<32>>, 64),
    ContextString = <<"TLS 1.3, server CertificateVerify">>,
    Content = <<Spaces/binary, ContextString/binary, 0, TranscriptHash/binary>>,

    %% Sign with the appropriate algorithm
    {SigAlg, HashAlg, SignOpts} = get_signature_params(SignatureAlgorithm),
    CryptoKey = convert_private_key(SigAlg, PrivateKey),
    Signature = crypto:sign(SigAlg, HashAlg, Content, CryptoKey, SignOpts),

    SigLen = byte_size(Signature),
    Body = <<SignatureAlgorithm:16, SigLen:16, Signature/binary>>,
    encode_handshake_message(?TLS_CERTIFICATE_VERIFY, Body).

%%====================================================================
%% Server-side Internal Functions
%%====================================================================

parse_cipher_suites(<<>>) ->
    [];
parse_cipher_suites(<<Suite:16, Rest/binary>>) ->
    [Suite | parse_cipher_suites(Rest)].

parse_client_key_shares(<<Len:16, Data:Len/binary, _/binary>>) ->
    parse_key_share_entries(Data);
parse_client_key_shares(_) ->
    undefined.

parse_key_share_entries(<<>>) ->
    [];
parse_key_share_entries(<<Group:16, Len:16, KeyData:Len/binary, Rest/binary>>) ->
    [{Group, KeyData} | parse_key_share_entries(Rest)];
parse_key_share_entries(_) ->
    [].

parse_server_name_ext(<<Len:16, Data:Len/binary, _/binary>>) ->
    parse_server_name_list(Data);
parse_server_name_ext(_) ->
    undefined.

parse_server_name_list(<<0:8, NameLen:16, Name:NameLen/binary, _/binary>>) ->
    % Type 0 = hostname
    Name;
parse_server_name_list(_) ->
    undefined.

parse_alpn_ext(<<Len:16, Data:Len/binary, _/binary>>) ->
    parse_alpn_list(Data);
parse_alpn_ext(_) ->
    [].

parse_alpn_list(<<>>) ->
    [];
parse_alpn_list(<<Len:8, Proto:Len/binary, Rest/binary>>) ->
    [Proto | parse_alpn_list(Rest)];
parse_alpn_list(_) ->
    [].

%% Parse pre_shared_key extension from ClientHello
%% RFC 8446 Section 4.2.11
%% Returns: #{identities => [{Ticket, ObfuscatedAge}], binders => [Binder]}
parse_pre_shared_key_ext(
    <<IdentitiesLen:16, IdentitiesData:IdentitiesLen/binary, BindersLen:16,
        BindersData:BindersLen/binary>>
) ->
    Identities = parse_psk_identities(IdentitiesData),
    Binders = parse_psk_binders(BindersData),
    #{identities => Identities, binders => Binders};
parse_pre_shared_key_ext(_) ->
    undefined.

%% @private
%% Reject ClientHellos where pre_shared_key is not the final extension
%% (RFC 8446 §4.2.11). Mapping `{error, psk_not_last}` to an
%% illegal_parameter alert is the caller's responsibility.
validate_psk_extension_placement(OrderedExts) ->
    case lists:reverse(OrderedExts) of
        [] ->
            ok;
        [{Last, _, _, _} | RestRev] ->
            case lists:keyfind(?EXT_PRE_SHARED_KEY, 1, RestRev) of
                false when Last =:= ?EXT_PRE_SHARED_KEY -> ok;
                false -> ok;
                _Found -> {error, psk_not_last}
            end
    end.

%% @private
%% Continue building the ClientHello map once extension order has
%% been validated. Captures the binders-section offset *within the
%% extensions blob* so the caller can compute the truncated
%% ClientHello for binder verification.
finalise_client_hello(Random, SessionId, Ciphers, OrderedExts, ExtMap, ExtBlob) ->
    KeyShare =
        case maps:find(?EXT_KEY_SHARE, ExtMap) of
            {ok, KsData} -> parse_client_key_shares(KsData);
            error -> undefined
        end,
    ServerName =
        case maps:find(?EXT_SERVER_NAME, ExtMap) of
            {ok, SniData} -> parse_server_name_ext(SniData);
            error -> undefined
        end,
    ALPNProtocols =
        case maps:find(?EXT_ALPN, ExtMap) of
            {ok, AlpnData} -> parse_alpn_ext(AlpnData);
            error -> []
        end,
    TransportParams =
        case maps:find(?EXT_QUIC_TRANSPORT_PARAMS, ExtMap) of
            {ok, TpData} ->
                case decode_transport_params(TpData) of
                    {ok, TP} -> TP;
                    {error, _} -> #{}
                end;
            error ->
                #{}
        end,
    PSK =
        case maps:find(?EXT_PRE_SHARED_KEY, ExtMap) of
            {ok, PskData} -> parse_pre_shared_key_ext(PskData);
            error -> undefined
        end,
    PskModes =
        case maps:find(?EXT_PSK_KEY_EXCHANGE_MODES, ExtMap) of
            {ok, ModesData} -> parse_psk_modes_ext(ModesData);
            error -> []
        end,
    SupportedGroups =
        case maps:find(?EXT_SUPPORTED_GROUPS, ExtMap) of
            {ok, SgData} -> parse_supported_groups_ext(SgData);
            error -> []
        end,
    SignatureAlgs =
        case maps:find(?EXT_SIGNATURE_ALGORITHMS, ExtMap) of
            {ok, SaData} -> parse_signature_algorithms_ext(SaData);
            error -> []
        end,
    EarlyData = maps:is_key(?EXT_EARLY_DATA, ExtMap),

    %% Binders-section offset within the extension data of the PSK
    %% extension, plus the absolute offset within ExtBlob. The
    %% caller combines these with the handshake-message header to
    %% truncate the ClientHello for binder verification.
    PskBinders = psk_binders_offset(OrderedExts, ExtBlob),

    {ok, #{
        random => Random,
        session_id => SessionId,
        cipher_suites => Ciphers,
        extensions => ExtMap,
        ordered_extensions => OrderedExts,
        key_share => KeyShare,
        server_name => ServerName,
        alpn_protocols => ALPNProtocols,
        transport_params => TransportParams,
        pre_shared_key => PSK,
        psk_key_exchange_modes => PskModes,
        psk_binders => PskBinders,
        supported_groups => SupportedGroups,
        signature_algorithms => SignatureAlgs,
        early_data => EarlyData
    }}.

%% @private Parse supported_groups (RFC 8446 §4.2.7) into recognised
%% group atoms; unknown codes are dropped (they can't be selected).
parse_supported_groups_ext(<<ListLen:16, Codes:ListLen/binary, _/binary>>) ->
    [code_to_group(C) || <<C:16>> <= Codes, code_to_group(C) =/= unknown];
parse_supported_groups_ext(_) ->
    [].

%% @private Parse signature_algorithms (RFC 8446 §4.2.3) into the
%% list of wire codes (integers) in the order offered.
parse_signature_algorithms_ext(<<ListLen:16, Codes:ListLen/binary, _/binary>>) ->
    [C || <<C:16>> <= Codes];
parse_signature_algorithms_ext(_) ->
    [].

%% @private Named-group wire code to atom (unknown -> unknown).
code_to_group(?GROUP_X25519) -> x25519;
code_to_group(?GROUP_SECP256R1) -> secp256r1;
code_to_group(?GROUP_SECP384R1) -> secp384r1;
code_to_group(?GROUP_X25519MLKEM768) -> x25519mlkem768;
code_to_group(_) -> unknown.

%% @private
%% Parse the psk_key_exchange_modes extension into a list of atoms.
%% RFC 8446 §4.2.9: <<Len:8, Modes:Len/binary>>.
parse_psk_modes_ext(<<Len:8, Modes:Len/binary, _/binary>>) ->
    [decode_psk_mode(M) || <<M:8>> <= Modes];
parse_psk_modes_ext(_) ->
    [].

decode_psk_mode(?PSK_KE_MODE_KE) -> psk_ke;
decode_psk_mode(?PSK_KE_MODE_DHE_KE) -> psk_dhe_ke;
decode_psk_mode(Other) -> {unknown, Other}.

%% @private
%% Locate the pre_shared_key extension and compute the offset (within
%% the extensions blob) of the binders-length field. Returns a map
%% `#{ext_offset, binders_offset, binders_size}` or `undefined' if no
%% PSK was offered.
psk_binders_offset(OrderedExts, _ExtBlob) ->
    case lists:keyfind(?EXT_PRE_SHARED_KEY, 1, OrderedExts) of
        false ->
            undefined;
        {?EXT_PRE_SHARED_KEY, PskData, ExtOffset, _ExtSize} ->
            %% PskData = <<IdentitiesLen:16, Identities..., BindersLen:16, Binders...>>
            case PskData of
                <<IdentitiesLen:16, _Identities:IdentitiesLen/binary, BindersLen:16,
                    _Binders:BindersLen/binary>> ->
                    %% Header of pre_shared_key extension is type(2)+len(2) = 4 bytes,
                    %% so the binders-length field sits at:
                    %%   ext_offset (start of type:16) + 4 (skip header)
                    %%                                 + 2 (skip IdentitiesLen:16)
                    %%                                 + IdentitiesLen
                    BindersOff = ExtOffset + 4 + 2 + IdentitiesLen,
                    BindersTotal = 2 + BindersLen,
                    #{
                        ext_offset => ExtOffset,
                        binders_offset => BindersOff,
                        binders_size => BindersTotal
                    };
                _ ->
                    undefined
            end
    end.

%% @doc Select a PSK from a ClientHello and verify the binder.
%%
%% `ClientHelloMap' is the result of `parse_client_hello/1'.
%% `FullHandshakeMsg' is the raw 4-byte-headered handshake bytes for
%%   ClientHello (msg_type + length + body) — needed to compute the
%%   truncated ClientHello hash for binder verification.
%% `PskConfig' is `#{psk_callback => Fn | undefined,
%%                   psks => Map | undefined}`.
%% `ServerModes' is the list of psk_key_exchange modes the server is
%%   willing to negotiate (defaults to `[psk_dhe_ke]`).
%%
%% Returns:
%%   `{ok, #{identity_idx => N, secret => Secret, mode => Mode}}` on
%%   successful selection (identity found, binder verified, modes
%%   compatible);
%%   `none' when the client didn't offer pre_shared_key OR offered
%%   identities don't match local config OR no compatible mode
%%   (caller falls through to cert path or sends
%%   unknown_psk_identity);
%%   `{error, bad_binder}` when an identity matched but the binder
%%   didn't verify — caller MUST send decrypt_error (no cert fallback).
-spec select_psk(map(), binary(), map(), [psk_dhe_ke | psk_ke]) ->
    {ok, map()} | none | {error, bad_binder}.
select_psk(#{pre_shared_key := undefined}, _FullMsg, _PskConfig, _ServerModes) ->
    none;
select_psk(#{pre_shared_key := #{identities := []}}, _FullMsg, _PskConfig, _ServerModes) ->
    none;
select_psk(
    #{
        pre_shared_key := #{identities := Identities, binders := Binders},
        psk_key_exchange_modes := ClientModes,
        psk_binders := PskBindersInfo,
        cipher_suites := CipherSuites
    },
    FullHandshakeMsg,
    PskConfig,
    ServerModes
) ->
    case mode_intersection(ClientModes, ServerModes) of
        [] ->
            none;
        [SelectedMode | _] ->
            Cipher = select_cipher(CipherSuites),
            TruncatedHash = truncated_client_hello_hash(
                FullHandshakeMsg, PskBindersInfo, Cipher
            ),
            try_psk_identities(
                Identities,
                Binders,
                0,
                PskConfig,
                SelectedMode,
                Cipher,
                TruncatedHash
            )
    end;
select_psk(_, _, _, _) ->
    none.

mode_intersection(Client, Server) ->
    [M || M <- Client, lists:member(M, Server)].

select_cipher(CipherSuites) ->
    case lists:member(?TLS_AES_128_GCM_SHA256, CipherSuites) of
        true -> aes_128_gcm;
        false -> aes_128_gcm
    end.

%% @private
%% Slice the full handshake bytes down to the truncated ClientHello
%% and compute its transcript hash.
truncated_client_hello_hash(FullHandshakeMsg, #{binders_offset := BindersOffInExt}, Cipher) ->
    %% Handshake header = 4 bytes (msg_type:8, length:24).
    %% After that comes the body: legacy_version(2) + random(32) +
    %% session_id(1+N) + cipher_suites(2+N) + compression(1+N) +
    %% extensions(2+N). The binders offset is relative to the start
    %% of the extensions blob, so we need the absolute offset within
    %% FullHandshakeMsg.
    <<_MsgType:8, _Len:24, Body/binary>> = FullHandshakeMsg,
    ExtBlobOffsetInBody = extensions_offset_in_body(Body),
    AbsoluteBindersOff = 4 + ExtBlobOffsetInBody + BindersOffInExt,
    %% RFC 8446 §4.2.11.2: keep every length field (including the
    %% handshake-message length) at its final post-binder value; only the
    %% binder bytes are removed. FullHandshakeMsg already carries the
    %% full-length header, so hash its prefix as-is without rewrapping.
    <<TruncatedBytes:AbsoluteBindersOff/binary, _/binary>> = FullHandshakeMsg,
    quic_crypto:transcript_hash(Cipher, TruncatedBytes).

%% @private — find where the extensions blob starts within a
%% ClientHello body.
extensions_offset_in_body(
    <<_LegacyVersion:16, _Random:32/binary, SessionIdLen:8, _SessionId:SessionIdLen/binary,
        CipherSuitesLen:16, _CipherSuites:CipherSuitesLen/binary, CompressionLen:8,
        _Compression:CompressionLen/binary, _ExtLen:16, _/binary>>
) ->
    2 + 32 + 1 + SessionIdLen + 2 + CipherSuitesLen + 1 + CompressionLen + 2.

try_psk_identities([], _Binders, _Idx, _PskConfig, _Mode, _Cipher, _TruncatedHash) ->
    none;
try_psk_identities(
    [{Identity, _Age} | RestIds],
    [Binder | RestBinders],
    Idx,
    PskConfig,
    Mode,
    Cipher,
    TruncatedHash
) ->
    case lookup_psk_secret(Identity, PskConfig) of
        {ok, Secret} ->
            case verify_psk_binder(Secret, Cipher, TruncatedHash, Binder) of
                true ->
                    {ok, #{
                        identity_idx => Idx,
                        identity => Identity,
                        secret => Secret,
                        mode => Mode
                    }};
                false ->
                    %% Identity matched but binder failed: per plan rule
                    %% 3, this is fatal — no cert-path fallback.
                    {error, bad_binder}
            end;
        not_found ->
            try_psk_identities(
                RestIds,
                RestBinders,
                Idx + 1,
                PskConfig,
                Mode,
                Cipher,
                TruncatedHash
            )
    end;
try_psk_identities(_, _, _, _, _, _, _) ->
    none.

lookup_psk_secret(Identity, #{psk_callback := Fn} = Config) when is_function(Fn, 1) ->
    case safe_callback(Fn, Identity) of
        {ok, Secret} when is_binary(Secret) ->
            {ok, Secret};
        _ ->
            lookup_in_psk_map(Identity, Config)
    end;
lookup_psk_secret(Identity, Config) ->
    lookup_in_psk_map(Identity, Config).

lookup_in_psk_map(Identity, #{psks := Map}) when is_map(Map) ->
    case maps:find(Identity, Map) of
        {ok, Secret} when is_binary(Secret) -> {ok, Secret};
        _ -> not_found
    end;
lookup_in_psk_map(_Identity, _) ->
    not_found.

safe_callback(Fn, Identity) ->
    try Fn(Identity) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            logger:warning(
                #{
                    what => psk_callback_failed,
                    class => Class,
                    reason => Reason,
                    stack => Stack
                },
                #{domain => [erlang_quic, tls]}
            ),
            not_found
    end.

verify_psk_binder(Secret, Cipher, TruncatedHash, OfferedBinder) ->
    EarlySecret = quic_crypto:derive_early_secret(Cipher, Secret),
    Expected = quic_crypto:compute_psk_binder(
        Cipher, EarlySecret, TruncatedHash, external
    ),
    hash_equals(Expected, OfferedBinder).

%% @doc Verify a resumption PSK binder against a parsed ClientHello.
%% `Secret' is the resumption PSK, `PskBindersInfo' is the `psk_binders'
%% map from `parse_client_hello/1', and `OfferedBinder' is the binder the
%% client sent. Uses the "res binder" label (RFC 8446 §4.2.11.2).
-spec verify_resumption_binder(binary(), atom(), binary(), map(), binary()) -> boolean().
verify_resumption_binder(Secret, Cipher, FullClientHello, PskBindersInfo, OfferedBinder) when
    is_map(PskBindersInfo)
->
    TruncatedHash = truncated_client_hello_hash(FullClientHello, PskBindersInfo, Cipher),
    EarlySecret = quic_crypto:derive_early_secret(Cipher, Secret),
    Expected = quic_crypto:compute_psk_binder(
        Cipher, EarlySecret, TruncatedHash, resumption
    ),
    hash_equals(Expected, OfferedBinder);
verify_resumption_binder(_Secret, _Cipher, _FullClientHello, _PskBindersInfo, _OfferedBinder) ->
    %% Missing binder offset info — cannot verify, fail closed.
    false.

parse_psk_identities(<<>>) ->
    [];
parse_psk_identities(
    <<IdentityLen:16, Identity:IdentityLen/binary, ObfuscatedAge:32, Rest/binary>>
) ->
    [{Identity, ObfuscatedAge} | parse_psk_identities(Rest)];
parse_psk_identities(_) ->
    [].

parse_psk_binders(<<>>) ->
    [];
parse_psk_binders(<<BinderLen:8, Binder:BinderLen/binary, Rest/binary>>) ->
    [Binder | parse_psk_binders(Rest)];
parse_psk_binders(_) ->
    [].

build_server_hello_extensions(PubKey, Opts) ->
    %% Supported versions extension (mandatory for TLS 1.3)
    SupportedVersions = encode_extension(?EXT_SUPPORTED_VERSIONS, <<?TLS_VERSION_1_3:16>>),

    %% Key share extension — included for psk_dhe_ke and standard
    %% handshakes; omitted for psk_ke (PSK-only, no DHE per RFC 8446
    %% §4.2.9).
    KeyShare =
        case maps:get(selected_psk_mode, Opts, undefined) of
            psk_ke ->
                <<>>;
            _ ->
                Group = maps:get(key_share_group, Opts, x25519),
                encode_extension(
                    ?EXT_KEY_SHARE,
                    <<(group_to_code(Group)):16, (byte_size(PubKey)):16, PubKey/binary>>
                )
        end,

    %% pre_shared_key extension echo when a PSK was selected
    %% (RFC 8446 §4.2.11 — ServerHello carries just selected_identity).
    PskExt =
        case maps:find(selected_psk_identity, Opts) of
            {ok, Idx} when is_integer(Idx) ->
                encode_extension(?EXT_PRE_SHARED_KEY, <<Idx:16>>);
            _ ->
                <<>>
        end,

    <<SupportedVersions/binary, KeyShare/binary, PskExt/binary>>.

build_encrypted_extensions_list(Opts) ->
    %% ALPN extension (if ALPN was negotiated)
    ALPNExt =
        case maps:find(alpn, Opts) of
            {ok, ALPN} when is_binary(ALPN), byte_size(ALPN) > 0 ->
                ALPNLen = byte_size(ALPN),
                encode_extension(?EXT_ALPN, <<(ALPNLen + 1):16, ALPNLen:8, ALPN/binary>>);
            _ ->
                <<>>
        end,

    %% QUIC transport parameters
    TPExt =
        case maps:find(transport_params, Opts) of
            {ok, TP} when map_size(TP) > 0 ->
                TPData = encode_transport_params(TP),
                encode_extension(?EXT_QUIC_TRANSPORT_PARAMS, TPData);
            _ ->
                <<>>
        end,

    %% Early data indication (RFC 8446 Section 4.2.10)
    %% When server accepts early data, include empty early_data extension
    EarlyDataExt =
        case maps:get(early_data, Opts, false) of
            true ->
                encode_extension(?EXT_EARLY_DATA, <<>>);
            false ->
                <<>>
        end,

    <<ALPNExt/binary, TPExt/binary, EarlyDataExt/binary>>.

build_cert_list([]) ->
    <<>>;
build_cert_list([Cert | Rest]) ->
    CertLen = byte_size(Cert),
    RestCerts = build_cert_list(Rest),
    %% Each cert entry: cert_data<1..2^24-1> extensions<0..2^16-1>
    <<CertLen:24, Cert/binary, 0:16, RestCerts/binary>>.

get_signature_params(?SIG_RSA_PSS_RSAE_SHA256) ->
    {rsa, sha256, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]};
get_signature_params(?SIG_RSA_PSS_RSAE_SHA384) ->
    {rsa, sha384, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]};
get_signature_params(?SIG_RSA_PSS_RSAE_SHA512) ->
    {rsa, sha512, [{rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, -1}]};
get_signature_params(?SIG_ECDSA_SECP256R1_SHA256) ->
    {ecdsa, sha256, []};
get_signature_params(?SIG_ECDSA_SECP384R1_SHA384) ->
    {ecdsa, sha384, []};
get_signature_params(?SIG_ED25519) ->
    %% EdDSA pre-hashes internally; no separate hash and no padding.
    %% The curve atom rides in the key list (see convert_private_key).
    {eddsa, none, []};
get_signature_params(Scheme) ->
    %% No silent fallback — an unsupported scheme must fail loudly
    %% rather than sign/verify with the wrong algorithm.
    error({unsupported_signature_scheme, Scheme}).

%% Convert private key to format expected by crypto:sign
convert_private_key(
    ecdsa, {'ECPrivateKey', _, PrivKeyBin, {namedCurve, {1, 2, 840, 10045, 3, 1, 7}}, _, _}
) ->
    %% secp256r1 / P-256
    [PrivKeyBin, secp256r1];
convert_private_key(ecdsa, {'ECPrivateKey', _, PrivKeyBin, {namedCurve, {1, 3, 132, 0, 34}}, _, _}) ->
    %% secp384r1 / P-384
    [PrivKeyBin, secp384r1];
convert_private_key(ecdsa, {'ECPrivateKey', _, PrivKeyBin, _, _, _}) ->
    %% Default EC curve
    [PrivKeyBin, secp256r1];
convert_private_key(rsa, {'RSAPrivateKey', _, N, E, D, _P, _Q, _Dp, _Dq, _Qi, _}) ->
    %% crypto:sign expects [E, N, D] list format for RSA
    [E, N, D];
convert_private_key(rsa, Key) when is_list(Key) ->
    %% Already in list format
    Key;
convert_private_key(eddsa, {ed_pri, ed25519, _Pub, Priv}) ->
    %% crypto:sign(eddsa, none, Msg, [PrivKeyBin, ed25519])
    [Priv, ed25519];
convert_private_key(eddsa, {'ECPrivateKey', _, PrivKeyBin, {namedCurve, {1, 3, 101, 112}}, _, _}) ->
    [PrivKeyBin, ed25519];
convert_private_key(_, Key) ->
    Key.

%%====================================================================
%% Client Certificate Support (Mutual TLS)
%%====================================================================

%% @doc Build a CertificateRequest message (RFC 8446 §4.3.2) with the
%% default advertised signature schemes.
-spec build_certificate_request(binary()) -> binary().
build_certificate_request(Context) ->
    build_certificate_request(Context, [
        ecdsa_secp256r1_sha256, rsa_pss_rsae_sha256, rsa_pkcs1_sha256, ed25519
    ]).

%% @doc Build a CertificateRequest advertising the given signature
%% schemes (RFC 8446 §4.3.2; signature_algorithms is required).
-spec build_certificate_request(binary(), [atom()]) -> binary().
build_certificate_request(Context, SigAlgAtoms) ->
    SigAlgs = iolist_to_binary([<<(sig_alg_to_code(A)):16>> || A <- SigAlgAtoms]),
    SigAlgsLen = byte_size(SigAlgs),
    SigAlgsExt =
        <<?EXT_SIGNATURE_ALGORITHMS:16, (SigAlgsLen + 2):16, SigAlgsLen:16, SigAlgs/binary>>,
    ExtLen = byte_size(SigAlgsExt),
    ContextLen = byte_size(Context),
    Body = <<ContextLen:8, Context/binary, ExtLen:16, SigAlgsExt/binary>>,
    encode_handshake_message(?TLS_CERTIFICATE_REQUEST, Body).

%% @doc Parse a CertificateRequest message. Returns the context and
%% the advertised signature_algorithms (wire codes) so an mTLS client
%% can pick a compatible CertificateVerify scheme.
-spec parse_certificate_request(binary()) -> {ok, map()} | {error, term()}.
parse_certificate_request(
    <<ContextLen:8, Context:ContextLen/binary, ExtLen:16, Extensions:ExtLen/binary, _/binary>>
) ->
    SigAlgs =
        case parse_extensions(Extensions) of
            {ok, ExtMap} ->
                case maps:find(?EXT_SIGNATURE_ALGORITHMS, ExtMap) of
                    {ok, SaData} -> parse_signature_algorithms_ext(SaData);
                    error -> []
                end;
            _ ->
                []
        end,
    {ok, #{context => Context, signature_algorithms => SigAlgs}};
parse_certificate_request(_) ->
    {error, invalid_certificate_request}.

%% @doc Build a CertificateVerify message for client (RFC 8446 Section 4.4.3).
%% Uses "TLS 1.3, client CertificateVerify" context string.
-spec build_certificate_verify_client(non_neg_integer(), term(), binary()) -> binary().
build_certificate_verify_client(SignatureAlgorithm, PrivateKey, TranscriptHash) ->
    %% RFC 8446 Section 4.4.3: Client uses different context string
    Spaces = binary:copy(<<32>>, 64),
    ContextString = <<"TLS 1.3, client CertificateVerify">>,
    Content = <<Spaces/binary, ContextString/binary, 0, TranscriptHash/binary>>,

    {SigAlg, HashAlg, SignOpts} = get_signature_params(SignatureAlgorithm),
    CryptoKey = convert_private_key(SigAlg, PrivateKey),
    Signature = crypto:sign(SigAlg, HashAlg, Content, CryptoKey, SignOpts),

    SigLen = byte_size(Signature),
    Body = <<SignatureAlgorithm:16, SigLen:16, Signature/binary>>,
    encode_handshake_message(?TLS_CERTIFICATE_VERIFY, Body).

%% @doc Verify CertificateVerify signature.
%% Role is 'client' or 'server' - determines context string.
-spec verify_certificate_verify(binary(), binary(), binary(), client | server) -> boolean().
verify_certificate_verify(Body, PeerCertDER, TranscriptHash, Role) ->
    case parse_certificate_verify(Body) of
        {ok, #{algorithm := Algorithm, signature := Signature}} ->
            case extract_public_key_for_verify(PeerCertDER, Algorithm) of
                {ok, PublicKey} ->
                    %% Build content that was signed
                    Spaces = binary:copy(<<32>>, 64),
                    ContextString =
                        case Role of
                            client -> <<"TLS 1.3, client CertificateVerify">>;
                            server -> <<"TLS 1.3, server CertificateVerify">>
                        end,
                    Content = <<Spaces/binary, ContextString/binary, 0, TranscriptHash/binary>>,

                    %% Verify signature
                    {SigAlg, HashAlg, VerifyOpts} = get_signature_params(Algorithm),
                    try
                        crypto:verify(SigAlg, HashAlg, Content, Signature, PublicKey, VerifyOpts)
                    catch
                        _:_ -> false
                    end;
                {error, _} ->
                    false
            end;
        {error, _} ->
            false
    end.

%% @doc Extract public key from DER certificate and convert to crypto:verify format.
-spec extract_public_key_for_verify(binary(), non_neg_integer()) ->
    {ok, term()} | {error, term()}.
extract_public_key_for_verify(CertDER, Algorithm) ->
    try
        OTPCert = public_key:pkix_decode_cert(CertDER, otp),
        TBSCert = OTPCert#'OTPCertificate'.tbsCertificate,
        SubjectPKInfo = TBSCert#'OTPTBSCertificate'.subjectPublicKeyInfo,
        convert_public_key_for_verify(SubjectPKInfo, Algorithm)
    catch
        _:Reason -> {error, Reason}
    end.

%% Convert public key info to format expected by crypto:verify/6
convert_public_key_for_verify(
    #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{algorithm = ?'id-ecPublicKey', parameters = Params},
        subjectPublicKey = #'ECPoint'{point = ECPoint}
    },
    Algorithm
) when
    Algorithm =:= ?SIG_ECDSA_SECP256R1_SHA256;
    Algorithm =:= ?SIG_ECDSA_SECP384R1_SHA384
->
    %% ECDSA: [ECPoint, NamedCurve]
    Curve =
        case Params of
            {namedCurve, ?'secp256r1'} -> secp256r1;
            {namedCurve, ?'secp384r1'} -> secp384r1;
            _ -> secp256r1
        end,
    {ok, [ECPoint, Curve]};
convert_public_key_for_verify(
    #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{algorithm = ?'rsaEncryption'},
        subjectPublicKey = #'RSAPublicKey'{modulus = N, publicExponent = E}
    },
    _Algorithm
) ->
    %% RSA: [E, N]
    {ok, [E, N]};
convert_public_key_for_verify(
    #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{algorithm = {1, 3, 101, 112}},
        subjectPublicKey = #'ECPoint'{point = PubKey}
    },
    ?SIG_ED25519
) ->
    %% Ed25519 (OID 1.3.101.112): OTP wraps the 32-byte public key in
    %% an ECPoint.
    {ok, [PubKey, ed25519]};
convert_public_key_for_verify(
    #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{algorithm = {1, 3, 101, 112}},
        subjectPublicKey = PubKey
    },
    ?SIG_ED25519
) when is_binary(PubKey) ->
    {ok, [PubKey, ed25519]};
convert_public_key_for_verify(_, _) ->
    {error, unsupported_key_type}.
