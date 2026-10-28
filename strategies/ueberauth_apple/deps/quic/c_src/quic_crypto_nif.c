/*
 * Batch/context AEAD NIF for erlang_quic.
 *
 * QUIC encrypts every ~1300-byte packet as its own AEAD unit. OTP's
 * crypto:crypto_one_time_aead/7 re-runs the key schedule on every
 * call, which dominates per-packet crypto cost on bulk transfers.
 * This NIF keeps an EVP_CIPHER_CTX per key as a NIF resource: the key
 * schedule runs once at context creation and each packet only resets
 * the nonce.
 *
 * Contexts are NOT thread-safe; a context must only be used from the
 * process that created it (one connection process in erlang_quic),
 * whose NIF calls are sequential.
 *
 * The pure-Erlang code path remains the fallback when this NIF is not
 * built or fails to load; see quic_aead_ctx.erl.
 */

#include <erl_nif.h>
#include <openssl/evp.h>
#include <string.h>

#define TAG_LEN 16
#define NONCE_LEN 12

typedef struct {
    EVP_CIPHER_CTX *ctx;
    int enc;     /* 1 = seal, 0 = open */
    int hp_chacha; /* header-protection context: 1 = ChaCha20, 0 = AES-ECB */
} qc_ctx;

static ErlNifResourceType *qc_ctx_type;

static ERL_NIF_TERM am_ok;
static ERL_NIF_TERM am_error;
static ERL_NIF_TERM am_true;
static ERL_NIF_TERM am_false;
static ERL_NIF_TERM am_not_loaded;
static ERL_NIF_TERM am_badarg;
static ERL_NIF_TERM am_key_phase;

static void
qc_ctx_dtor(ErlNifEnv *env, void *obj)
{
    qc_ctx *c = (qc_ctx *)obj;
    (void)env;
    if (c->ctx != NULL) {
        EVP_CIPHER_CTX_free(c->ctx);
        c->ctx = NULL;
    }
}

static const EVP_CIPHER *
cipher_from_atom(ErlNifEnv *env, ERL_NIF_TERM atom)
{
    char name[32];
    if (enif_get_atom(env, atom, name, sizeof(name), ERL_NIF_LATIN1) == 0)
        return NULL;
    if (strcmp(name, "aes_128_gcm") == 0)
        return EVP_aes_128_gcm();
    if (strcmp(name, "aes_256_gcm") == 0)
        return EVP_aes_256_gcm();
    if (strcmp(name, "chacha20_poly1305") == 0)
        return EVP_chacha20_poly1305();
    if (strcmp(name, "aes_128_ecb") == 0)
        return EVP_aes_128_ecb();
    if (strcmp(name, "aes_256_ecb") == 0)
        return EVP_aes_256_ecb();
    if (strcmp(name, "chacha20") == 0)
        return EVP_chacha20();
    return NULL;
}

/* Header-protection mask for one packet (RFC 9001 5.4.3 and 5.4.4).
 * AES: one ECB block of the 16-byte sample. ChaCha20: the sample is the
 * cipher's 16-byte IV (4-byte little-endian counter, 12-byte nonce),
 * and the mask is the first 5 keystream bytes; the key stays set on the
 * context, only the IV is reloaded per packet. Only mask[0..4] are used
 * by the callers, the rest is zeroed for ChaCha. */
static int
hp_mask(qc_ctx *hp, const unsigned char *sample, unsigned char mask[16])
{
    int mlen = 0;
    if (hp->hp_chacha) {
        static const unsigned char zeros[5] = {0, 0, 0, 0, 0};
        memset(mask, 0, 16);
        if (EVP_EncryptInit_ex(hp->ctx, NULL, NULL, NULL, sample) != 1)
            return 0;
        return EVP_EncryptUpdate(hp->ctx, mask, &mlen, zeros, 5) == 1 && mlen == 5;
    }
    return EVP_EncryptUpdate(hp->ctx, mask, &mlen, sample, 16) == 1 && mlen == 16;
}

/* new_aead_ctx(Cipher, Key, Enc) -> {ok, Ctx} | {error, Reason} */
static ERL_NIF_TERM
new_aead_ctx(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    const EVP_CIPHER *cipher;
    ErlNifBinary key;
    qc_ctx *c;
    ERL_NIF_TERM res;
    int enc;

    (void)argc;
    cipher = cipher_from_atom(env, argv[0]);
    if (cipher == NULL || enif_inspect_binary(env, argv[1], &key) == 0)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (enif_is_identical(argv[2], am_true))
        enc = 1;
    else if (enif_is_identical(argv[2], am_false))
        enc = 0;
    else
        return enif_make_tuple2(env, am_error, am_badarg);

    c = enif_alloc_resource(qc_ctx_type, sizeof(qc_ctx));
    c->ctx = EVP_CIPHER_CTX_new();
    c->enc = enc;
    if (c->ctx == NULL)
        goto fail;
    /* Set cipher + key once; nonce comes per packet. */
    if (EVP_CipherInit_ex(c->ctx, cipher, NULL, NULL, NULL, enc) != 1)
        goto fail;
    if (EVP_CIPHER_CTX_ctrl(c->ctx, EVP_CTRL_AEAD_SET_IVLEN, NONCE_LEN, NULL) != 1)
        goto fail;
    if ((size_t)EVP_CIPHER_CTX_key_length(c->ctx) != key.size)
        goto fail;
    if (EVP_CipherInit_ex(c->ctx, NULL, NULL, key.data, NULL, enc) != 1)
        goto fail;

    res = enif_make_resource(env, c);
    enif_release_resource(c);
    return enif_make_tuple2(env, am_ok, res);

fail:
    enif_release_resource(c);
    return enif_make_tuple2(env, am_error, am_badarg);
}

/* new_hp_ctx(Cipher, Key) -> {ok, Ctx} | {error, Reason}
 * Header-protection context: AES-ECB (aes_128_ecb, aes_256_ecb) or
 * ChaCha20 (chacha20), keyed once; see hp_mask(). */
static ERL_NIF_TERM
new_hp_ctx(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    const EVP_CIPHER *cipher;
    ErlNifBinary key;
    qc_ctx *c;
    ERL_NIF_TERM res;

    (void)argc;
    cipher = cipher_from_atom(env, argv[0]);
    if (cipher == NULL || enif_inspect_binary(env, argv[1], &key) == 0)
        return enif_make_tuple2(env, am_error, am_badarg);

    c = enif_alloc_resource(qc_ctx_type, sizeof(qc_ctx));
    c->ctx = EVP_CIPHER_CTX_new();
    c->enc = 1;
    c->hp_chacha = (cipher == EVP_chacha20());
    if (c->ctx == NULL)
        goto fail;
    if (EVP_EncryptInit_ex(c->ctx, cipher, NULL, NULL, NULL) != 1)
        goto fail;
    if ((size_t)EVP_CIPHER_CTX_key_length(c->ctx) != key.size)
        goto fail;
    if (EVP_EncryptInit_ex(c->ctx, NULL, NULL, key.data, NULL) != 1)
        goto fail;
    EVP_CIPHER_CTX_set_padding(c->ctx, 0);

    res = enif_make_resource(env, c);
    enif_release_resource(c);
    return enif_make_tuple2(env, am_ok, res);

fail:
    enif_release_resource(c);
    return enif_make_tuple2(env, am_error, am_badarg);
}

/* seal(Ctx, Nonce, AAD, Plain) -> CipherWithTag :: binary() | {error, _} */
static ERL_NIF_TERM
seal(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    qc_ctx *c;
    ErlNifBinary nonce, aad, plain;
    ERL_NIF_TERM out_term;
    unsigned char *out;
    int len = 0, len2 = 0;

    (void)argc;
    if (enif_get_resource(env, argv[0], qc_ctx_type, (void **)&c) == 0 || c->enc != 1 ||
        enif_inspect_binary(env, argv[1], &nonce) == 0 || nonce.size != NONCE_LEN ||
        enif_inspect_iolist_as_binary(env, argv[2], &aad) == 0 ||
        enif_inspect_iolist_as_binary(env, argv[3], &plain) == 0)
        return enif_make_tuple2(env, am_error, am_badarg);

    out = enif_make_new_binary(env, plain.size + TAG_LEN, &out_term);

    if (EVP_EncryptInit_ex(c->ctx, NULL, NULL, NULL, nonce.data) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (aad.size > 0 && EVP_EncryptUpdate(c->ctx, NULL, &len, aad.data, (int)aad.size) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (plain.size > 0 &&
        EVP_EncryptUpdate(c->ctx, out, &len, plain.data, (int)plain.size) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (EVP_EncryptFinal_ex(c->ctx, out + len, &len2) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (EVP_CIPHER_CTX_ctrl(c->ctx, EVP_CTRL_AEAD_GET_TAG, TAG_LEN, out + plain.size) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);

    return out_term;
}

/* open(Ctx, Nonce, AAD, CipherText, Tag) -> Plain :: binary() | error */
static ERL_NIF_TERM
open_(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    qc_ctx *c;
    ErlNifBinary nonce, aad, ct, tag;
    ERL_NIF_TERM out_term;
    unsigned char *out;
    int len = 0, len2 = 0;

    (void)argc;
    if (enif_get_resource(env, argv[0], qc_ctx_type, (void **)&c) == 0 || c->enc != 0 ||
        enif_inspect_binary(env, argv[1], &nonce) == 0 || nonce.size != NONCE_LEN ||
        enif_inspect_iolist_as_binary(env, argv[2], &aad) == 0 ||
        enif_inspect_iolist_as_binary(env, argv[3], &ct) == 0 ||
        enif_inspect_binary(env, argv[4], &tag) == 0 || tag.size != TAG_LEN)
        return enif_make_tuple2(env, am_error, am_badarg);

    out = enif_make_new_binary(env, ct.size, &out_term);

    if (EVP_DecryptInit_ex(c->ctx, NULL, NULL, NULL, nonce.data) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (aad.size > 0 && EVP_DecryptUpdate(c->ctx, NULL, &len, aad.data, (int)aad.size) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (ct.size > 0 && EVP_DecryptUpdate(c->ctx, out, &len, ct.data, (int)ct.size) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (EVP_CIPHER_CTX_ctrl(c->ctx, EVP_CTRL_AEAD_SET_TAG, TAG_LEN, tag.data) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (EVP_DecryptFinal_ex(c->ctx, out + len, &len2) != 1)
        return am_error; /* authentication failure */

    return out_term;
}

/* hp_block(Ctx, Sample16) -> Block16 :: binary() | {error, _}
 * One ECB block for AES header protection. */
static ERL_NIF_TERM
hp_block(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    qc_ctx *c;
    ErlNifBinary sample;
    ERL_NIF_TERM out_term;
    unsigned char *out;
    int len = 0;

    (void)argc;
    if (enif_get_resource(env, argv[0], qc_ctx_type, (void **)&c) == 0 || c->hp_chacha ||
        enif_inspect_binary(env, argv[1], &sample) == 0 || sample.size != 16)
        return enif_make_tuple2(env, am_error, am_badarg);

    out = enif_make_new_binary(env, 16, &out_term);
    if (EVP_EncryptUpdate(c->ctx, out, &len, sample.data, 16) != 1 || len != 16)
        return enif_make_tuple2(env, am_error, am_badarg);
    return out_term;
}

/* protect_run(AeadCtx, HpCtx, IV12, PN0, FirstByteBase, DCID, Payloads)
 *   -> [WirePacket] | {error, badarg}
 *
 * Seals a run of short-header packets with consecutive packet numbers
 * in one call. For I = 0..K-1 with PN = PN0 + I:
 *   PNLen   = 1..4 (smallest big-endian encoding of PN)
 *   header  = (FirstByteBase | (PNLen-1)) ++ DCID ++ PN[PNLen]
 *   nonce   = IV with PN xored into the low 64 bits
 *   body    = AEAD_seal(aead, nonce, header, Payload) ++ tag
 *   mask    = ECB(hp, body[4-PNLen .. +16])
 *   header protection: first byte ^= mask[0] & 0x1f (short header),
 *   PN bytes ^= mask[1..PNLen]
 * FirstByteBase must have the PN-length bits (0-1) clear. AES only -
 * the HP context is an ECB or ChaCha20 context, see hp_mask(); the per-packet
 * path.
 */
#define MAX_RUN 256

static ERL_NIF_TERM
protect_run(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    qc_ctx *aead, *hp;
    ErlNifBinary iv, dcid, plain;
    ErlNifUInt64 pn0;
    unsigned int fbase;
    ERL_NIF_TERM list, head, tail;
    ERL_NIF_TERM packets[MAX_RUN];
    unsigned k = 0, i;

    (void)argc;
    if (enif_get_resource(env, argv[0], qc_ctx_type, (void **)&aead) == 0 || aead->enc != 1 ||
        enif_get_resource(env, argv[1], qc_ctx_type, (void **)&hp) == 0 ||
        enif_inspect_binary(env, argv[2], &iv) == 0 || iv.size != NONCE_LEN ||
        enif_get_uint64(env, argv[3], &pn0) == 0 || enif_get_uint(env, argv[4], &fbase) == 0 ||
        fbase > 255 || enif_inspect_iolist_as_binary(env, argv[5], &dcid) == 0 ||
        dcid.size > 20)
        return enif_make_tuple2(env, am_error, am_badarg);

    list = argv[6];
    while (enif_get_list_cell(env, list, &head, &tail)) {
        ErlNifUInt64 pn = pn0 + k;
        unsigned char header[1 + 20 + 4];
        unsigned char nonce[NONCE_LEN];
        unsigned char mask[16], sample_off;
        unsigned pnlen, hlen;
        unsigned char *out, *body;
        ERL_NIF_TERM pkt;
        int len = 0, len2 = 0;

        if (k >= MAX_RUN || enif_inspect_iolist_as_binary(env, head, &plain) == 0 ||
            plain.size < 4)
            return enif_make_tuple2(env, am_error, am_badarg);

        pnlen = (pn < 0x100) ? 1 : (pn < 0x10000) ? 2 : (pn < 0x1000000) ? 3 : 4;
        header[0] = (unsigned char)(fbase | (pnlen - 1));
        memcpy(header + 1, dcid.data, dcid.size);
        for (i = 0; i < pnlen; i++)
            header[1 + dcid.size + i] = (unsigned char)(pn >> (8 * (pnlen - 1 - i)));
        hlen = 1 + (unsigned)dcid.size + pnlen;

        memcpy(nonce, iv.data, NONCE_LEN);
        for (i = 0; i < 8; i++)
            nonce[NONCE_LEN - 1 - i] ^= (unsigned char)(pn >> (8 * i));

        out = enif_make_new_binary(env, hlen + plain.size + TAG_LEN, &pkt);
        memcpy(out, header, hlen);
        body = out + hlen;

        if (EVP_EncryptInit_ex(aead->ctx, NULL, NULL, NULL, nonce) != 1 ||
            EVP_EncryptUpdate(aead->ctx, NULL, &len, header, (int)hlen) != 1 ||
            EVP_EncryptUpdate(aead->ctx, body, &len, plain.data, (int)plain.size) != 1 ||
            EVP_EncryptFinal_ex(aead->ctx, body + len, &len2) != 1 ||
            EVP_CIPHER_CTX_ctrl(aead->ctx, EVP_CTRL_AEAD_GET_TAG, TAG_LEN,
                                body + plain.size) != 1)
            return enif_make_tuple2(env, am_error, am_badarg);

        sample_off = (unsigned char)(4 - pnlen);
        if (!hp_mask(hp, body + sample_off, mask))
            return enif_make_tuple2(env, am_error, am_badarg);
        out[0] ^= mask[0] & 0x1f;
        for (i = 0; i < pnlen; i++)
            out[1 + dcid.size + i] ^= mask[1 + i];

        packets[k++] = pkt;
        list = tail;
    }
    if (!enif_is_empty_list(env, list))
        return enif_make_tuple2(env, am_error, am_badarg);

    return enif_make_list_from_array(env, packets, k);
}

/* RFC 9000 Appendix A packet number decoding. largest < 0 means no
 * packet received yet (use the truncated PN directly). */
static ErlNifUInt64
reconstruct_pn(ErlNifSInt64 largest, ErlNifUInt64 trunc_pn, unsigned pnlen)
{
    ErlNifUInt64 win, hwin, expected, candidate;

    if (largest < 0)
        return trunc_pn;
    win = (ErlNifUInt64)1 << (pnlen * 8);
    hwin = win >> 1;
    expected = (ErlNifUInt64)largest + 1;
    candidate = (expected & ~(win - 1)) | trunc_pn;
    if (candidate + hwin <= expected && candidate < (((ErlNifUInt64)1 << 62) - win))
        return candidate + win;
    if (candidate > expected + hwin && candidate >= win)
        return candidate - win;
    return candidate;
}

/* open_packet(AeadCtx, HpCtx, IV12, LargestRecv, ExpectedPhase,
 *             Header, EncPayload)
 *   -> {PN, FirstByte, Plain} | error | key_phase | {error, badarg}
 *
 * Fused short-header receive path: header unprotection, packet-number
 * reconstruction and AEAD open in one call. Header is the protected
 * first byte + DCID; EncPayload is PN bytes + ciphertext + tag.
 * Returns `key_phase' without decrypting when the unprotected key
 * phase bit differs from ExpectedPhase (caller reruns the generic
 * path with key selection); `error' on authentication failure. */
static ERL_NIF_TERM
open_packet(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    qc_ctx *aead, *hp;
    ErlNifBinary iv, header, payload;
    ErlNifSInt64 largest;
    unsigned int expphase;
    unsigned char mask[16], aad[1 + 20 + 4], nonce[NONCE_LEN], fb;
    unsigned pnlen, phase, i, aadlen, ctlen;
    ErlNifUInt64 trunc_pn = 0, pn;
    ERL_NIF_TERM plain_term;
    unsigned char *out;
    int len = 0, len2 = 0;

    (void)argc;
    if (enif_get_resource(env, argv[0], qc_ctx_type, (void **)&aead) == 0 || aead->enc != 0 ||
        enif_get_resource(env, argv[1], qc_ctx_type, (void **)&hp) == 0 ||
        enif_inspect_binary(env, argv[2], &iv) == 0 || iv.size != NONCE_LEN ||
        enif_get_int64(env, argv[3], &largest) == 0 ||
        enif_get_uint(env, argv[4], &expphase) == 0 || expphase > 1 ||
        enif_inspect_binary(env, argv[5], &header) == 0 || header.size < 1 ||
        header.size > 21 || enif_inspect_binary(env, argv[6], &payload) == 0 ||
        payload.size < 4 + 16)
        return enif_make_tuple2(env, am_error, am_badarg);

    /* Sample sits 4 bytes past the PN start; payload begins at the PN. */
    if (!hp_mask(hp, payload.data + 4, mask))
        return enif_make_tuple2(env, am_error, am_badarg);
    fb = header.data[0] ^ (mask[0] & 0x1f);
    pnlen = (fb & 0x03) + 1;
    phase = (fb >> 2) & 1;
    if (phase != expphase)
        return am_key_phase;
    if (payload.size < pnlen + TAG_LEN)
        return enif_make_tuple2(env, am_error, am_badarg);

    aad[0] = fb;
    memcpy(aad + 1, header.data + 1, header.size - 1);
    for (i = 0; i < pnlen; i++) {
        unsigned char b = payload.data[i] ^ mask[1 + i];
        aad[header.size + i] = b;
        trunc_pn = (trunc_pn << 8) | b;
    }
    aadlen = (unsigned)header.size + pnlen;
    pn = reconstruct_pn(largest, trunc_pn, pnlen);

    memcpy(nonce, iv.data, NONCE_LEN);
    for (i = 0; i < 8; i++)
        nonce[NONCE_LEN - 1 - i] ^= (unsigned char)(pn >> (8 * i));

    ctlen = (unsigned)payload.size - pnlen - TAG_LEN;
    out = enif_make_new_binary(env, ctlen, &plain_term);

    if (EVP_DecryptInit_ex(aead->ctx, NULL, NULL, NULL, nonce) != 1 ||
        EVP_DecryptUpdate(aead->ctx, NULL, &len, aad, (int)aadlen) != 1 ||
        (ctlen > 0 &&
         EVP_DecryptUpdate(aead->ctx, out, &len, payload.data + pnlen, (int)ctlen) != 1) ||
        EVP_CIPHER_CTX_ctrl(aead->ctx, EVP_CTRL_AEAD_SET_TAG, TAG_LEN,
                            (void *)(payload.data + payload.size - TAG_LEN)) != 1)
        return enif_make_tuple2(env, am_error, am_badarg);
    if (EVP_DecryptFinal_ex(aead->ctx, out + len, &len2) != 1)
        return am_error;

    return enif_make_tuple3(
        env, enif_make_uint64(env, pn), enif_make_uint(env, fb), plain_term);
}


/* ---- In-NIF QUIC frame parsing for the batched receive path ----
 * Produces term-identical output to quic_frame:decode/1 for the frame
 * types that dominate the hot path; anything else makes the whole
 * packet fall back to {raw, Plain} and the generic Erlang decoder,
 * which also owns all error semantics (unknown type, truncation,
 * empty packet). */

#define PF_MAX_FRAMES 64

static ERL_NIF_TERM am_padding_f, am_ping_f, am_ack_f, am_crypto_f,
    am_stream_f, am_max_data_f, am_max_stream_data_f, am_max_streams_f,
    am_bidi_f, am_uni_f, am_handshake_done_f, am_raw_f, am_undefined_f;

static int
rd_varint(const unsigned char *p, unsigned rem, ErlNifUInt64 *v, unsigned *used)
{
    unsigned len;
    if (rem < 1)
        return 0;
    len = 1u << (p[0] >> 6);
    if (rem < len)
        return 0;
    *v = p[0] & 0x3f;
    for (unsigned i = 1; i < len; i++)
        *v = (*v << 8) | p[i];
    *used = len;
    return 1;
}

/* Returns 1 and sets *out to the frames list (in wire order) on
 * success; 0 to request the raw fallback. */
static int
parse_quic_frames(ErlNifEnv *env, ERL_NIF_TERM plain, const unsigned char *d,
                  unsigned n, ERL_NIF_TERM *out)
{
    ERL_NIF_TERM frames[PF_MAX_FRAMES];
    unsigned nf = 0, off = 0;

    while (off < n) {
        unsigned char t = d[off];
        if (t == 0x00) { /* PADDING run: skip, no term (probing only) */
            off++;
            continue;
        }
        if (nf >= PF_MAX_FRAMES)
            return 0;
        if (t == 0x01) { /* PING */
            frames[nf++] = am_ping_f;
            off++;
            continue;
        }
        if (t == 0x02 || t == 0x03) { /* ACK [+ECN] */
            ErlNifUInt64 la, delay, cnt, fr;
            unsigned u;
            ERL_NIF_TERM ranges, ecn;
            unsigned i;
            off++;
            if (!rd_varint(d + off, n - off, &la, &u)) return 0;
            off += u;
            if (!rd_varint(d + off, n - off, &delay, &u)) return 0;
            off += u;
            if (!rd_varint(d + off, n - off, &cnt, &u)) return 0;
            off += u;
            if (!rd_varint(d + off, n - off, &fr, &u)) return 0;
            off += u;
            if (cnt > 1024) return 0;
            {
                ERL_NIF_TERM pairs[64];
                ERL_NIF_TERM tailride = enif_make_list(env, 0);
                if (cnt > 64) return 0;
                for (i = 0; i < cnt; i++) {
                    ErlNifUInt64 gap, rng;
                    if (!rd_varint(d + off, n - off, &gap, &u)) return 0;
                    off += u;
                    if (!rd_varint(d + off, n - off, &rng, &u)) return 0;
                    off += u;
                    pairs[i] = enif_make_tuple2(env,
                        enif_make_uint64(env, gap), enif_make_uint64(env, rng));
                }
                for (i = cnt; i > 0; i--)
                    tailride = enif_make_list_cell(env, pairs[i - 1], tailride);
                ranges = enif_make_list_cell(env,
                    enif_make_tuple2(env, enif_make_uint64(env, la),
                        enif_make_uint64(env, fr)),
                    tailride);
            }
            if (t == 0x03) {
                ErlNifUInt64 e0, e1, ce;
                if (!rd_varint(d + off, n - off, &e0, &u)) return 0;
                off += u;
                if (!rd_varint(d + off, n - off, &e1, &u)) return 0;
                off += u;
                if (!rd_varint(d + off, n - off, &ce, &u)) return 0;
                off += u;
                ecn = enif_make_tuple3(env, enif_make_uint64(env, e0),
                    enif_make_uint64(env, e1), enif_make_uint64(env, ce));
            } else {
                ecn = am_undefined_f;
            }
            frames[nf++] = enif_make_tuple4(env, am_ack_f, ranges,
                enif_make_uint64(env, delay), ecn);
            continue;
        }
        if (t == 0x06) { /* CRYPTO */
            ErlNifUInt64 o, len;
            unsigned u;
            off++;
            if (!rd_varint(d + off, n - off, &o, &u)) return 0;
            off += u;
            if (!rd_varint(d + off, n - off, &len, &u)) return 0;
            off += u;
            if (len > n - off) return 0;
            frames[nf++] = enif_make_tuple3(env, am_crypto_f,
                enif_make_uint64(env, o),
                enif_make_sub_binary(env, plain, off, (size_t)len));
            off += (unsigned)len;
            continue;
        }
        if (t >= 0x08 && t <= 0x0f) { /* STREAM */
            ErlNifUInt64 sid, o = 0, len;
            unsigned u;
            ERL_NIF_TERM data, fin;
            off++;
            if (!rd_varint(d + off, n - off, &sid, &u)) return 0;
            off += u;
            if (t & 0x04) {
                if (!rd_varint(d + off, n - off, &o, &u)) return 0;
                off += u;
            }
            fin = (t & 0x01) ? am_true : am_false;
            if (t & 0x02) {
                if (!rd_varint(d + off, n - off, &len, &u)) return 0;
                off += u;
                if (len > n - off) return 0;
                data = enif_make_sub_binary(env, plain, off, (size_t)len);
                off += (unsigned)len;
            } else {
                data = enif_make_sub_binary(env, plain, off, n - off);
                off = n;
            }
            frames[nf++] = enif_make_tuple5(env, am_stream_f,
                enif_make_uint64(env, sid), enif_make_uint64(env, o), data, fin);
            continue;
        }
        if (t == 0x10 || t == 0x11) { /* MAX_DATA / MAX_STREAM_DATA */
            ErlNifUInt64 a, b;
            unsigned u;
            off++;
            if (!rd_varint(d + off, n - off, &a, &u)) return 0;
            off += u;
            if (t == 0x10) {
                frames[nf++] = enif_make_tuple2(env, am_max_data_f,
                    enif_make_uint64(env, a));
            } else {
                if (!rd_varint(d + off, n - off, &b, &u)) return 0;
                off += u;
                frames[nf++] = enif_make_tuple3(env, am_max_stream_data_f,
                    enif_make_uint64(env, a), enif_make_uint64(env, b));
            }
            continue;
        }
        if (t == 0x12 || t == 0x13) { /* MAX_STREAMS bidi/uni */
            ErlNifUInt64 a;
            unsigned u;
            off++;
            if (!rd_varint(d + off, n - off, &a, &u)) return 0;
            off += u;
            frames[nf++] = enif_make_tuple3(env, am_max_streams_f,
                (t == 0x12) ? am_bidi_f : am_uni_f, enif_make_uint64(env, a));
            continue;
        }
        if (t == 0x1e) { /* HANDSHAKE_DONE */
            frames[nf++] = am_handshake_done_f;
            off++;
            continue;
        }
        return 0; /* anything else: raw fallback */
    }
    if (nf == 0)
        return 0; /* padding-only packet: Erlang owns the violation */
    *out = enif_make_list_from_array(env, frames, nf);
    return 1;
}

/* open_run(AeadCtx, HpCtx, IV12, LargestRecv, ExpectedPhase, DcidLen,
 *          Datagrams) -> {ok, [{PN, FirstByte, Plain}]} | {error, badarg}
 *
 * Batched open_packet over a train of short-header datagrams. Each
 * datagram is FirstByte + DCID(DcidLen) + PN bytes + ciphertext + tag;
 * the largest received PN is carried forward across the run for
 * packet-number reconstruction, matching sequential per-packet calls.
 * Stops at the first datagram that cannot be opened on this fast path
 * (size, key-phase mismatch, auth failure): the result list is the
 * consumed prefix and the caller reruns the rest generically. */
#define OPEN_RUN_MAX 256
static ERL_NIF_TERM
open_run(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    qc_ctx *aead, *hp;
    ErlNifBinary iv, dgram;
    ErlNifSInt64 largest;
    unsigned int expphase, dcidlen;
    ERL_NIF_TERM list, head, tail, results[OPEN_RUN_MAX];
    unsigned k = 0;

    (void)argc;
    if (enif_get_resource(env, argv[0], qc_ctx_type, (void **)&aead) == 0 || aead->enc != 0 ||
        enif_get_resource(env, argv[1], qc_ctx_type, (void **)&hp) == 0 ||
        enif_inspect_binary(env, argv[2], &iv) == 0 || iv.size != NONCE_LEN ||
        enif_get_int64(env, argv[3], &largest) == 0 ||
        enif_get_uint(env, argv[4], &expphase) == 0 || expphase > 1 ||
        enif_get_uint(env, argv[5], &dcidlen) == 0 || dcidlen > 20 ||
        enif_is_list(env, argv[6]) == 0)
        return enif_make_tuple2(env, am_error, am_badarg);

    list = argv[6];
    while (k < OPEN_RUN_MAX && enif_get_list_cell(env, list, &head, &tail)) {
        unsigned char mask[16], aad[1 + 20 + 4], nonce[NONCE_LEN], fb;
        unsigned pnlen, phase, i, aadlen, ctlen, hdrlen = 1 + dcidlen;
        ErlNifUInt64 trunc_pn = 0, pn;
        ERL_NIF_TERM plain_term;
        unsigned char *out, *payload;
        unsigned payload_size;
        int len = 0, len2 = 0;

        if (enif_inspect_binary(env, head, &dgram) == 0 ||
            dgram.size < hdrlen + 4 + 16)
            break;
        payload = dgram.data + hdrlen;
        payload_size = (unsigned)dgram.size - hdrlen;

        if (!hp_mask(hp, payload + 4, mask))
            break;
        fb = dgram.data[0] ^ (mask[0] & 0x1f);
        pnlen = (fb & 0x03) + 1;
        phase = (fb >> 2) & 1;
        if (phase != expphase)
            break;
        if (payload_size < pnlen + TAG_LEN)
            break;

        aad[0] = fb;
        memcpy(aad + 1, dgram.data + 1, dcidlen);
        for (i = 0; i < pnlen; i++) {
            unsigned char b = payload[i] ^ mask[1 + i];
            aad[hdrlen + i] = b;
            trunc_pn = (trunc_pn << 8) | b;
        }
        aadlen = hdrlen + pnlen;
        pn = reconstruct_pn(largest, trunc_pn, pnlen);

        memcpy(nonce, iv.data, NONCE_LEN);
        for (i = 0; i < 8; i++)
            nonce[NONCE_LEN - 1 - i] ^= (unsigned char)(pn >> (8 * i));

        ctlen = payload_size - pnlen - TAG_LEN;
        out = enif_make_new_binary(env, ctlen, &plain_term);

        if (EVP_DecryptInit_ex(aead->ctx, NULL, NULL, NULL, nonce) != 1 ||
            EVP_DecryptUpdate(aead->ctx, NULL, &len, aad, (int)aadlen) != 1 ||
            (ctlen > 0 &&
             EVP_DecryptUpdate(aead->ctx, out, &len, payload + pnlen, (int)ctlen) != 1) ||
            EVP_CIPHER_CTX_ctrl(aead->ctx, EVP_CTRL_AEAD_SET_TAG, TAG_LEN,
                                (void *)(payload + payload_size - TAG_LEN)) != 1)
            break;
        if (EVP_DecryptFinal_ex(aead->ctx, out + len, &len2) != 1)
            break;

        {
            ERL_NIF_TERM frames;
            ERL_NIF_TERM third;
            if (parse_quic_frames(env, plain_term, out, (unsigned)(len + len2), &frames))
                third = frames;
            else
                third = enif_make_tuple2(env, am_raw_f, plain_term);
            results[k++] = enif_make_tuple3(
                env, enif_make_uint64(env, pn), enif_make_uint(env, fb), third);
        }
        if ((ErlNifSInt64)pn > largest)
            largest = (ErlNifSInt64)pn;
        list = tail;
    }

    return enif_make_tuple2(env, am_ok, enif_make_list_from_array(env, results, k));
}

static ERL_NIF_TERM
is_loaded(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "true");
}

static int
load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)priv;
    (void)info;
    qc_ctx_type = enif_open_resource_type(
        env, NULL, "quic_crypto_ctx", qc_ctx_dtor, ERL_NIF_RT_CREATE, NULL);
    if (qc_ctx_type == NULL)
        return -1;
    am_ok = enif_make_atom(env, "ok");
    am_error = enif_make_atom(env, "error");
    am_true = enif_make_atom(env, "true");
    am_false = enif_make_atom(env, "false");
    am_not_loaded = enif_make_atom(env, "not_loaded");
    am_badarg = enif_make_atom(env, "badarg");
    am_key_phase = enif_make_atom(env, "key_phase");
    am_padding_f = enif_make_atom(env, "padding");
    am_ping_f = enif_make_atom(env, "ping");
    am_ack_f = enif_make_atom(env, "ack");
    am_crypto_f = enif_make_atom(env, "crypto");
    am_stream_f = enif_make_atom(env, "stream");
    am_max_data_f = enif_make_atom(env, "max_data");
    am_max_stream_data_f = enif_make_atom(env, "max_stream_data");
    am_max_streams_f = enif_make_atom(env, "max_streams");
    am_bidi_f = enif_make_atom(env, "bidi");
    am_uni_f = enif_make_atom(env, "uni");
    am_handshake_done_f = enif_make_atom(env, "handshake_done");
    am_raw_f = enif_make_atom(env, "raw");
    am_undefined_f = enif_make_atom(env, "undefined");
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"is_loaded", 0, is_loaded, 0},
    {"new_aead_ctx", 3, new_aead_ctx, 0},
    {"new_hp_ctx", 2, new_hp_ctx, 0},
    {"seal", 4, seal, 0},
    {"open", 5, open_, 0},
    {"hp_block", 2, hp_block, 0},
    {"protect_run", 7, protect_run, 0},
    {"open_packet", 7, open_packet, 0},
    {"open_run", 7, open_run, 0},
};

ERL_NIF_INIT(quic_crypto_nif, nif_funcs, load, NULL, NULL, NULL)
