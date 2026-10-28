%%% -*- erlang -*-
%%%
%%% AEAD dispatch: NIF-accelerated contexts with OTP crypto fallback.
%%%
%%% QUIC seals/opens every packet as its own AEAD unit, and the OTP
%%% one-shot API re-runs the key schedule on each call. When the
%%% optional quic_crypto_nif is loaded, this module keeps an
%%% EVP context per {direction, cipher, key} in the calling process's
%%% dictionary (contexts are single-process; connection processes are
%%% the only callers) so the key schedule runs once per key. Without
%%% the NIF every function degrades to crypto:crypto_one_time_aead /
%%% crypto:crypto_one_time with identical semantics.

-module(quic_aead_ctx).

-export([
    aead_encrypt/5,
    aead_decrypt/5,
    hp_block/3,
    protect_run/8,
    open_packet/8,
    open_run/8
]).

-define(TAG_LEN, 16).
%% Current and previous key phase, encrypt and decrypt, plus the two
%% header-protection contexts, which do not rotate on a key update.
-define(MAX_CACHED_CTX, 6).

%% @doc Seal: returns Ciphertext||Tag.
-spec aead_encrypt(atom(), binary(), binary(), binary(), binary()) -> binary().
aead_encrypt(Cipher, Key, Nonce, Plaintext, AAD) ->
    case nif_enabled() of
        true ->
            case ctx(qc_enc, Cipher, Key) of
                {ok, Ctx} ->
                    case quic_crypto_nif:seal(Ctx, Nonce, AAD, Plaintext) of
                        Out when is_binary(Out) -> Out;
                        {error, _} -> fallback_encrypt(Cipher, Key, Nonce, Plaintext, AAD)
                    end;
                error ->
                    fallback_encrypt(Cipher, Key, Nonce, Plaintext, AAD)
            end;
        false ->
            fallback_encrypt(Cipher, Key, Nonce, Plaintext, AAD)
    end.

%% @doc Open: takes Ciphertext||Tag; returns Plaintext | error. The
%% whole thing is passed in so the length check lives in one place:
%% both the NIF and the OTP path need the tag split off, and neither
%% may be handed input too short to hold one.
-spec aead_decrypt(atom(), binary(), binary(), binary(), binary()) ->
    binary() | error.
aead_decrypt(_Cipher, _Key, _Nonce, CiphertextWithTag, _AAD) when
    byte_size(CiphertextWithTag) < ?TAG_LEN
->
    error;
aead_decrypt(Cipher, Key, Nonce, CiphertextWithTag, AAD) ->
    case nif_enabled() of
        true ->
            CipherLen = byte_size(CiphertextWithTag) - ?TAG_LEN,
            <<Ciphertext:CipherLen/binary, Tag:?TAG_LEN/binary>> = CiphertextWithTag,
            case ctx(qc_dec, Cipher, Key) of
                {ok, Ctx} ->
                    case quic_crypto_nif:open(Ctx, Nonce, AAD, Ciphertext, Tag) of
                        Out when is_binary(Out) -> Out;
                        error -> error;
                        {error, _} -> fallback_decrypt(Cipher, Key, Nonce, CiphertextWithTag, AAD)
                    end;
                error ->
                    fallback_decrypt(Cipher, Key, Nonce, CiphertextWithTag, AAD)
            end;
        false ->
            fallback_decrypt(Cipher, Key, Nonce, CiphertextWithTag, AAD)
    end.

%% @doc One ECB block for AES header protection (mask source).
-spec hp_block(aes_128_ecb | aes_256_ecb, binary(), binary()) -> binary().
hp_block(Cipher, Key, Sample) ->
    case nif_enabled() of
        true ->
            case hp_ctx(Cipher, Key) of
                {ok, Ctx} ->
                    case quic_crypto_nif:hp_block(Ctx, Sample) of
                        Out when is_binary(Out) -> Out;
                        {error, _} -> quic_aead:ecb_mask(Cipher, Key, Sample)
                    end;
                error ->
                    quic_aead:ecb_mask(Cipher, Key, Sample)
            end;
        false ->
            quic_aead:ecb_mask(Cipher, Key, Sample)
    end.

%% @doc Seal a run of short-header packets with consecutive PNs in one
%% NIF call (header build + nonce + AEAD + header protection fused).
%% Returns `{ok, [WirePacket]}' or `fallback' when the NIF is not
%% loaded, the cipher is ChaCha (its HP is not ECB) or the NIF rejects
%% the input - callers then take the per-packet path.
-spec protect_run(
    atom(),
    binary(),
    binary(),
    binary(),
    non_neg_integer(),
    byte(),
    binary(),
    [iodata()]
) -> {ok, [binary()]} | fallback.
protect_run(Cipher, Key, IV, HP, PN0, FirstByteBase, DCID, Payloads) ->
    case nif_enabled() of
        true ->
            case {ctx(qc_enc, Cipher, Key), hp_ctx(hp_cipher(Cipher), HP)} of
                {{ok, AeadCtx}, {ok, HpCtx}} ->
                    case
                        quic_crypto_nif:protect_run(
                            AeadCtx, HpCtx, IV, PN0, FirstByteBase, DCID, Payloads
                        )
                    of
                        Packets when is_list(Packets) -> {ok, Packets};
                        {error, _} -> fallback
                    end;
                _ ->
                    fallback
            end;
        false ->
            fallback
    end.

%% Header-protection cipher for an AEAD: AES-ECB for the GCM suites,
%% ChaCha20 (sample as IV, five keystream bytes) for ChaCha20-Poly1305.
hp_cipher(aes_128_gcm) -> aes_128_ecb;
hp_cipher(aes_256_gcm) -> aes_256_ecb;
hp_cipher(chacha20_poly1305) -> chacha20.

%% @doc Fused short-header receive: header unprotection, PN
%% reconstruction and AEAD open in one NIF call. Returns
%% `{ok, PN, UnprotectedFirstByte, Plaintext}', `error' on
%% authentication failure, or `fallback' (NIF missing, ChaCha, or the
%% packet's key phase differs from ExpectedPhase - the caller then
%% runs the generic path with key selection).
-spec open_packet(
    atom(),
    binary(),
    binary(),
    binary(),
    non_neg_integer() | undefined,
    0 | 1,
    binary(),
    binary()
) -> {ok, non_neg_integer(), byte(), binary()} | error | fallback.
open_packet(Cipher, Key, IV, HP, LargestRecv, ExpectedPhase, Header, EncPayload) ->
    with_open_ctx(Cipher, Key, HP, LargestRecv, fun(DecCtx, HpCtx, Largest) ->
        case
            quic_crypto_nif:open_packet(
                DecCtx, HpCtx, IV, Largest, ExpectedPhase, Header, EncPayload
            )
        of
            {PN, FirstByte, Plain} -> {ok, PN, FirstByte, Plain};
            error -> error;
            key_phase -> fallback;
            {error, _} -> fallback
        end
    end).

%% @doc Batched open_packet over a train of short-header datagrams
%% (FirstByte + DCID + PN + ciphertext + tag each). Returns the opened
%% prefix; a shorter list than Datagrams means the remainder must be
%% run through the generic per-packet path. `fallback' when the NIF is
%% unavailable or the cipher is ChaCha.
-spec open_run(
    atom(),
    binary(),
    binary(),
    binary(),
    non_neg_integer() | undefined,
    0 | 1,
    non_neg_integer(),
    [binary()]
) -> {ok, [{non_neg_integer(), byte(), [term()] | {raw, binary()}}]} | fallback.
open_run(Cipher, Key, IV, HP, LargestRecv, ExpectedPhase, DcidLen, Datagrams) ->
    with_open_ctx(Cipher, Key, HP, LargestRecv, fun(DecCtx, HpCtx, Largest) ->
        case
            quic_crypto_nif:open_run(
                DecCtx, HpCtx, IV, Largest, ExpectedPhase, DcidLen, Datagrams
            )
        of
            {ok, _Results} = Ok -> Ok;
            {error, _} -> fallback
        end
    end).

%% Run Fun with the decrypt and header-protection contexts and the
%% largest-received PN in NIF form (-1 for none); `fallback' without
%% the NIF.
with_open_ctx(Cipher, Key, HP, LargestRecv, Fun) ->
    case nif_enabled() of
        true ->
            Largest =
                case LargestRecv of
                    undefined -> -1;
                    _ -> LargestRecv
                end,
            case {ctx(qc_dec, Cipher, Key), hp_ctx(hp_cipher(Cipher), HP)} of
                {{ok, DecCtx}, {ok, HpCtx}} -> Fun(DecCtx, HpCtx, Largest);
                _ -> fallback
            end;
        false ->
            fallback
    end.

%%====================================================================
%% Internal
%%====================================================================

%% Without the NIF, OTP crypto still reuses a cipher context where the
%% running release has one; quic_aead owns that so this cannot recurse.
fallback_encrypt(Cipher, Key, Nonce, Plaintext, AAD) ->
    quic_aead:otp_seal(Cipher, Key, Nonce, AAD, Plaintext).

fallback_decrypt(Cipher, Key, Nonce, CiphertextWithTag, AAD) ->
    quic_aead:otp_open(Cipher, Key, Nonce, AAD, CiphertextWithTag).

%% Cache the NIF-availability flag per process: checked on every
%% packet, and a process dictionary read beats a NIF call.
nif_enabled() ->
    case erlang:get(qc_nif) of
        undefined ->
            V = quic_crypto_nif:is_loaded(),
            erlang:put(qc_nif, V),
            V;
        V ->
            V
    end.

%% Per-process context cache. A connection holds a handful of live
%% keys (current + previous key phase per direction); stale entries
%% from key updates are few and die with the process.
ctx(Kind, Cipher, Key) ->
    cached({Kind, Cipher, Key}, fun() ->
        quic_crypto_nif:new_aead_ctx(Cipher, Key, Kind =:= qc_enc)
    end).

hp_ctx(Cipher, Key) ->
    cached({qc_hp, Cipher, Key}, fun() -> quic_crypto_nif:new_hp_ctx(Cipher, Key) end).

%% Look the context up, creating it on a miss. A creation failure
%% returns `error' rather than raising: every caller then takes the OTP
%% crypto path, which is the point of the NIF being optional.
cached(PdKey, New) ->
    case erlang:get(PdKey) of
        undefined ->
            case New() of
                {ok, Ctx} ->
                    erlang:put(PdKey, Ctx),
                    retain(PdKey),
                    {ok, Ctx};
                {error, _} ->
                    error
            end;
        Ctx ->
            {ok, Ctx}
    end.

%% Bound the cache. RFC 9001 section 6 keeps at most the current and
%% previous key phase live, but a key update fires every
%% ?AEAD_CONFIDENTIALITY_LIMIT packets and derives fresh keys each
%% time, so without eviction a long-lived bulk connection accumulates
%% one live EVP context per update. Evicting the oldest only costs
%% recreating it if it is asked for again.
retain(PdKey) ->
    Prev =
        case erlang:get(qc_ctx_live) of
            undefined -> [];
            L -> L
        end,
    Live = [PdKey | lists:delete(PdKey, Prev)],
    case length(Live) > ?MAX_CACHED_CTX of
        true ->
            {Keep, [Evict]} = lists:split(?MAX_CACHED_CTX, Live),
            erlang:erase(Evict),
            erlang:put(qc_ctx_live, Keep);
        false ->
            erlang:put(qc_ctx_live, Live)
    end.
