# JOSE

[![Build Status](https://github.com/potatosalad/erlang-jose/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/potatosalad/erlang-jose/actions) [![Hex.pm](https://img.shields.io/hexpm/v/jose.svg)](https://hex.pm/packages/jose)

JSON Object Signing and Encryption (JOSE) for Erlang and Elixir.

## Installation

Add `jose` to your project's dependencies in `mix.exs`

```elixir
defp deps() do
  [
    {:jose, "~> 1.11"}
  ]
end
```

If you are using deployment tools (`exrm`, etc.) and your app depends
on `jose` directly, you will need to include `jose` in your
applications list in `mix.exs` to ensure they get compiled into your
release:

```elixir
def application() do
  [
    mod: {YourApp, []},
    applications: [:jose]
  ]
end
```

Add `jose` to your project's dependencies in your `Makefile` for [`erlang.mk`](https://github.com/ninenines/erlang.mk) or the following to your `rebar.config`

```erlang
{deps, [
  jose
]}.
```

#### JSON Encoder/Decoder

_NOTE:_ The following only applies to versions prior to Erlang/OTP 27 when the `json` module was included.  If present, the builtin `json` module will be used unless overridden as described below.

You will also need to specify either [jiffy](https://github.com/davisp/jiffy), [jsone](https://github.com/sile/jsone), [jsx](https://github.com/talentdeficit/jsx), [ojson](https://github.com/potatosalad/erlang-ojson), [Poison](https://github.com/devinus/poison), or [Jason](https://github.com/michalmuskala/jason) as a dependency.

For example, with Elixir and `mix.exs`

```elixir
defp deps() do
  [
    {:jose, "~> 1.11"},
    {:jason, "~> 1.4"}
  ]
end
```

Or with Erlang and `rebar.config`

```erlang
{deps, [
  jose,
  ojson
]}.
```

`jose` will attempt to find a suitable JSON encoder/decoder and will try to use (in order) ojson, Jason, Poison, jiffy, jsone, or jsx.

You may also specify a different `json_module` as an application environment variable to `jose` or by using `jose:json_module/1` or `JOSE.json_module/1`.

#### ChaCha20/Poly1305 Support

ChaCha20/Poly1305 encryption and one-time message authentication functions are experimentally supported based on [RFC 7539](https://tools.ietf.org/html/rfc7539).

Fallback support for `ChaCha20/Poly1305` encryption and `Poly1305` signing is also provided.  See [`crypto_fallback`](#cryptographic-algorithm-fallback) below.

External support is also provided by the following libraries:

 * [libsodium](https://github.com/potatosalad/erlang-libsodium) - `ChaCha20/Poly1305` encryption and `Poly1305` signing

Other modules which implement the `jose_chacha20_poly1305` behavior may also be used as follows:

```elixir
# ChaCha20/Poly1305
JOSE.chacha20_poly1305_module(:libsodium)                  # uses a fast Erlang port driver for libsodium
JOSE.chacha20_poly1305_module(:jose_jwa_chacha20_poly1305) # uses the pure Erlang implementation (slow)
```

#### Curve25519 and Curve448 Support

Curve25519 and Curve448 and their associated signing/key exchange functions are supported now that [RFC 8037](https://tools.ietf.org/html/rfc8037) has been published.

Fallback support for `Ed25519`, `Ed25519ph`, `Ed448`, `Ed448ph`, `X25519`, and `X448` is provided.  See [`crypto_fallback`](#cryptographic-algorithm-fallback) below.

External support is also provided by the following libraries:

 * [libdecaf](https://github.com/potatosalad/erlang-libdecaf) - `Ed25519`, `Ed25519ph`, `Ed448`, `Ed448ph`, `X25519`, `X448`
 * [libsodium](https://github.com/potatosalad/erlang-libsodium) - `Ed25519`, `Ed25519ph`, `X25519`

If both libraries are present, libdecaf will be used by default.  Other modules which implement the `jose_curve25519` or `jose_curve448` behaviors may also be used as follows:

```elixir
# Curve25519
JOSE.curve25519_module(:libdecaf)            # uses a fast Erlang NIF for libdecaf
JOSE.curve25519_module(:jose_jwa_curve25519) # uses the pure Erlang implementation (slow)

# Curve448
JOSE.curve448_module(:libdecaf)          # uses a fast Erlang NIF for libdecaf
JOSE.curve448_module(:jose_jwa_curve448) # uses the pure Erlang implementation (slow)
```

#### SHA-3 Support

SHA-3 is experimentally supported for use with `Ed448` and `Ed448ph` signing functions.

Fallback support for SHA-3 is provided.  See [`crypto_fallback`](#cryptographic-algorithm-fallback) below.

External support for SHA-3 is provided by the [keccakf1600](https://github.com/potatosalad/erlang-keccakf1600) and [libdecaf](https://github.com/potatosalad/erlang-libdecaf) libraries.  If present, keccakf1600 will be used by default.  Other modules which implement the `jose_sha3` behaviors may also be used as follows:

```elixir
JOSE.sha3_module(:keccakf1600)   # uses a NIF written in C with timeslice reductions
JOSE.sha3_module(:jose_jwa_sha3) # uses the pure Erlang implementation (slow)
```

#### Cryptographic Algorithm Fallback

`jose` strives to support [all](#algorithm-support) of the cryptographic algorithms specified in the [JOSE RFCs](https://tools.ietf.org/wg/jose/).

However, not all of the required algorithms are supported natively by Erlang/Elixir.  For algorithms unsupported by the native [`crypto`](http://www.erlang.org/doc/man/crypto.html) and [`public_key`](http://www.erlang.org/doc/man/public_key.html), `jose` has a pure Erlang implementation that may be used as a fallback.

See [ALGORITHMS.md](https://github.com/potatosalad/erlang-jose/blob/main/ALGORITHMS.md) for more information about algorithm support for specific OTP versions.

By default, the algorithm fallback is disabled, but can be enabled by setting the `crypto_fallback` application environment variable for `jose` to `true` or by calling `jose:crypto_fallback/1` or `JOSE.crypto_fallback/1` with `true`.

> [!WARNING]
> **The pure Erlang fallback implementations are not constant-time.**
>
> The pure Erlang elliptic curve modules (`jose_jwa_curve25519`/`jose_jwa_x25519` and `jose_jwa_curve448`/`jose_jwa_x448`) perform scalar multiplication with Erlang bignum arithmetic, whose execution time depends on operand values. They therefore leak timing information about the private scalar and should not be used with long-lived private keys in any context where an attacker can observe operation timing.
>
> These modules exist as a last-resort fallback for platforms with no native implementation. `jose` probes `libdecaf`, `libsodium`, and then OTP `crypto` for Curve25519, and `libdecaf` and OTP `crypto` for Curve448. The selected provider handles X25519/X448 when it supports those operations. The OTP provider still delegates unsupported EdDSA context and prehash operations to the fallback. Setting `crypto_fallback` to `true` enables the pure Erlang implementation for unavailable operations; it does not override a working native module. Release 1.11.13 corrects the shipped application environment to disable fallback by default, as documented above.
>
> Selecting the pure Erlang curve modules explicitly (for example `jose:curve25519_module(jose_jwa_curve25519)` or `JOSE.curve25519_module(:jose_jwa_curve25519)`) opts out of the native provider path. Do not do this with long-lived keys in production.

For new JWE applications, prefer `RSA-OAEP` or `RSA-OAEP-256` over `RSA1_5`. JWE decryption substitutes a random content encryption key on RSA unwrap failure and authenticates the content before returning plaintext. This normalizes the unwrap error result; it is not a guarantee against timing attacks on the underlying RSA provider. The low-level `jose_jwa_pkcs1` RSA padding helpers report padding failures and must not be exposed as a decryption service for untrusted ciphertexts.

RSA private JWKs containing only `(n, e, d)` require CRT factor recovery. This search accepts moduli up to 8192 bits and uses at most 32 random trials and 256 modular squares. It checks a 200 ms work deadline before each expensive operation, or 500 ms for moduli of 6145–8192 bits. An in-progress native operation can finish after the deadline. Very large keys, unusually difficult keys or a slow runtime can exhaust this budget even for a valid key; supply `p`, `q`, `dp`, `dq` and `qi` to import without recovery. Random trials preserve keys that a fixed small-base search can miss. These limits bound recovery work, not total request CPU or wall time on every platform.

You may also review which algorithms are currently supported with the `jose_jwa:supports/0` or `JOSE.JWA.supports/0` functions.  For example, on Elixir 1.9.4 and OTP 22:

```elixir
# crypto_fallback defaults to false
JOSE.JWA.supports()

[
  {:jwe,
   {:alg,
    ["A128GCMKW", "A128KW", "A192GCMKW", "A192KW", "A256GCMKW", "A256KW",
     "C20PKW", "ECDH-1PU", "ECDH-1PU+A128GCMKW", "ECDH-1PU+A128KW",
     "ECDH-1PU+A192GCMKW", "ECDH-1PU+A192KW", "ECDH-1PU+A256GCMKW",
     "ECDH-1PU+A256KW", "ECDH-1PU+C20PKW", "ECDH-1PU+XC20PKW", "ECDH-ES",
     "ECDH-ES+A128GCMKW", "ECDH-ES+A128KW", "ECDH-ES+A192GCMKW",
     "ECDH-ES+A192KW", "ECDH-ES+A256GCMKW", "ECDH-ES+A256KW", "ECDH-ES+C20PKW",
     "ECDH-ES+XC20PKW", "ECDH-SS", "ECDH-SS+A128GCMKW", "ECDH-SS+A128KW",
     "ECDH-SS+A192GCMKW", "ECDH-SS+A192KW", "ECDH-SS+A256GCMKW",
     "ECDH-SS+A256KW", "ECDH-SS+C20PKW", "ECDH-SS+XC20PKW",
     "PBES2-HS256+A128GCMKW", "PBES2-HS256+A128KW", "PBES2-HS384+A192GCMKW",
     "PBES2-HS384+A192KW", "PBES2-HS512+A256GCMKW", "PBES2-HS512+A256KW",
     "PBES2-HS512+C20PKW", "PBES2-HS512+XC20PKW", "RSA-OAEP", "RSA-OAEP-256",
     "RSA1_5", "XC20PKW", "dir"]},
   {:enc,
    ["A128CBC-HS256", "A128GCM", "A192CBC-HS384", "A192GCM", "A256CBC-HS512",
     "A256GCM", "C20P", "XC20P"]}, {:zip, ["DEF"]}},
  {:jwk, {:kty, ["EC", "OKP", "RSA", "oct"]},
   {:kty_OKP_crv,
    ["Ed25519", "Ed25519ph", "Ed448", "Ed448ph", "X25519", "X448"]}},
  {:jws,
   {:alg,
    ["ES256", "ES256K", "ES384", "ES512", "Ed25519", "Ed25519ph", "Ed448",
     "Ed448ph", "EdDSA", "HS256", "HS384", "HS512", "PS256", "PS384", "PS512",
     "Poly1305", "RS1", "RS256", "RS384", "RS512"]}}
]

# setting crypto_fallback to true
JOSE.crypto_fallback(true)

# additional algorithms are now available for use
JOSE.JWA.supports()

[
  {:jwe,
   {:alg,
    ["A128GCMKW", "A128KW", "A192GCMKW", "A192KW", "A256GCMKW", "A256KW",
     "C20PKW", "ECDH-1PU", "ECDH-1PU+A128GCMKW", "ECDH-1PU+A128KW",
     "ECDH-1PU+A192GCMKW", "ECDH-1PU+A192KW", "ECDH-1PU+A256GCMKW",
     "ECDH-1PU+A256KW", "ECDH-1PU+C20PKW", "ECDH-1PU+XC20PKW", "ECDH-ES",
     "ECDH-ES+A128GCMKW", "ECDH-ES+A128KW", "ECDH-ES+A192GCMKW",
     "ECDH-ES+A192KW", "ECDH-ES+A256GCMKW", "ECDH-ES+A256KW", "ECDH-ES+C20PKW",
     "ECDH-ES+XC20PKW", "ECDH-SS", "ECDH-SS+A128GCMKW", "ECDH-SS+A128KW",
     "ECDH-SS+A192GCMKW", "ECDH-SS+A192KW", "ECDH-SS+A256GCMKW",
     "ECDH-SS+A256KW", "ECDH-SS+C20PKW", "ECDH-SS+XC20PKW",
     "PBES2-HS256+A128GCMKW", "PBES2-HS256+A128KW", "PBES2-HS384+A192GCMKW",
     "PBES2-HS384+A192KW", "PBES2-HS512+A256GCMKW", "PBES2-HS512+A256KW",
     "PBES2-HS512+C20PKW", "PBES2-HS512+XC20PKW", "RSA-OAEP", "RSA-OAEP-256",
     "RSA1_5", "XC20PKW", "dir"]},
   {:enc,
    ["A128CBC-HS256", "A128GCM", "A192CBC-HS384", "A192GCM", "A256CBC-HS512",
     "A256GCM", "C20P", "XC20P"]}, {:zip, ["DEF"]}},
  {:jwk, {:kty, ["EC", "OKP", "RSA", "oct"]},
   {:kty_OKP_crv,
    ["Ed25519", "Ed25519ph", "Ed448", "Ed448ph", "X25519", "X448"]}},
  {:jws,
   {:alg,
    ["ES256", "ES256K", "ES384", "ES512", "Ed25519", "Ed25519ph", "Ed448",
     "Ed448ph", "EdDSA", "HS256", "HS384", "HS512", "PS256", "PS384", "PS512",
     "Poly1305", "RS1", "RS256", "RS384", "RS512"]}}
]
```

#### Unsecured Signing Vulnerability

The [`"none"`](https://tools.ietf.org/html/rfc7515#appendix-A.5) signing algorithm is disabled by default to prevent accidental verification of empty signatures (read about the vulnerability [here](https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/)).

If you want to further restrict the signature algorithms allowed for a token, use `JOSE.JWT.verify_strict/3`:

```elixir
# Signed Compact JSON Web Token (JWT) with HS256
token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEzMDA4MTkzODAsImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlLCJpc3MiOiJqb2UifQ.shLcxOl_HBBsOTvPnskfIlxHUibPN7Y9T4LhPB-iBwM"

# JSON Web Key (JWK)
jwk = %{
  "kty" => "oct",
  "k" => :jose_base64url.encode("symmetric key")
}

{verified, _, _} = JOSE.JWT.verify_strict(jwk, ["HS256"], token)
# {true, _, _}

{verified, _, _} = JOSE.JWT.verify_strict(jwk, ["RS256"], token)
# {false, _, _}
```

If you need to inspect the contents of a JSON Web token (JWT) prior to verifying it, use `JOSE.JWT.peek_payload/1` or `JOSE.JWT.peek_protected/1`:

```elixir
token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEzMDA4MTkzODAsImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlLCJpc3MiOiJqb2UifQ.shLcxOl_HBBsOTvPnskfIlxHUibPN7Y9T4LhPB-iBwM"

payload = JOSE.JWT.peek_payload(token)
# %JOSE.JWT{fields: %{"exp" => 1300819380, "http://example.com/is_root" => true,
#    "iss" => "joe"}}

protected = JOSE.JWT.peek_protected(token)
# %JOSE.JWS{alg: {:jose_jws_alg_hmac, {:jose_jws_alg_hmac, :sha256}},
#  b64: :undefined, fields: %{"typ" => "JWT"}}

# If you want to inspect the JSON, you can convert it back to a regular map:
{_, protected_map} = JOSE.JWS.to_map(protected)
# {_, %{"alg" => "HS256", "typ" => "JWT"}}
```

You may also enable the `"none"` algorithm as an application environment variable for `jose` or by using `jose:unsecured_signing/1` or `JOSE.unsecured_signing/1`.

```elixir
# unsecured_signing defaults to false
JOSE.JWA.supports[:jws]

{:alg,
 ["ES256", "ES256K", "ES384", "ES512", "Ed25519", "Ed25519ph", "Ed448",
  "Ed448ph", "EdDSA", "HS256", "HS384", "HS512", "PS256", "PS384", "PS512",
  "Poly1305", "RS1", "RS256", "RS384", "RS512"]}

# setting unsecured_signing to true
JOSE.unsecured_signing(true)

# the "none" algorithm is now available for use
JOSE.JWA.supports[:jws]

{:alg,
 ["ES256", "ES256K", "ES384", "ES512", "Ed25519", "Ed25519ph", "Ed448",
  "Ed448ph", "EdDSA", "HS256", "HS384", "HS512", "PS256", "PS384", "PS512",
  "Poly1305", "RS1", "RS256", "RS384", "RS512", "none"]}
```

## Usage

##### JSON Web Signature (JWS) of JSON Web Token (JWT) using HMAC using SHA-256 (HS256) with JSON Web Key (JWK)

_Elixir_

```elixir
# JSON Web Key (JWK)
jwk = %{
  "kty" => "oct",
  "k" => :jose_base64url.encode("symmetric key")
}

# JSON Web Signature (JWS)
jws = %{
  "alg" => "HS256"
}

# JSON Web Token (JWT)
jwt = %{
  "iss" => "joe",
  "exp" => 1300819380,
  "http://example.com/is_root" => true
}

signed = JOSE.JWT.sign(jwk, jws, jwt)
# {%{alg: :jose_jws_alg_hmac},
#  %{"payload" => "eyJleHAiOjEzMDA4MTkzODAsImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlLCJpc3MiOiJqb2UifQ",
#    "protected" => "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
#    "signature" => "shLcxOl_HBBsOTvPnskfIlxHUibPN7Y9T4LhPB-iBwM"}}

compact_signed = JOSE.JWS.compact(signed)
# {%{alg: :jose_jws_alg_hmac},
#  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEzMDA4MTkzODAsImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlLCJpc3MiOiJqb2UifQ.shLcxOl_HBBsOTvPnskfIlxHUibPN7Y9T4LhPB-iBwM"}

verified = JOSE.JWT.verify(jwk, compact_signed)
# {true,
#  %JOSE.JWT{fields: %{"exp" => 1300819380, "http://example.com/is_root" => true,
#     "iss" => "joe"}},
#  %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined,
#   fields: %{"typ" => "JWT"}}}

verified == JOSE.JWT.verify(jwk, signed)
# true
```

_Erlang_

```erlang
% JSON Web Key (JWK)
JWK = #{
  <<"kty">> => <<"oct">>,
  <<"k">> => jose_base64url:encode(<<"symmetric key">>)
}.

% JSON Web Signature (JWS)
JWS = #{
  <<"alg">> => <<"HS256">>
}.

% JSON Web Token (JWT)
JWT = #{
  <<"iss">> => <<"joe">>,
  <<"exp">> => 1300819380,
  <<"http://example.com/is_root">> => true
}.

Signed = jose_jwt:sign(JWK, JWS, JWT).
% {#{alg => jose_jws_alg_hmac},
%  #{<<"payload">> => <<"eyJleHAiOjEzMDA4MTkzODAsImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlLCJpc3MiOiJqb2UifQ">>,
%    <<"protected">> => <<"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9">>,
%    <<"signature">> => <<"shLcxOl_HBBsOTvPnskfIlxHUibPN7Y9T4LhPB-iBwM">>}}

CompactSigned = jose_jws:compact(Signed).
% {#{alg => jose_jws_alg_hmac},
%  <<"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEzMDA4MTkzODAsImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlLCJpc3MiOiJqb2UifQ.shLcxOl_HBBsOTvPnskfIlxHUibPN7Y9T4LhPB-iBwM">>}

Verified = jose_jwt:verify(JWK, CompactSigned).
% {true,
%     #jose_jwt{
%         fields =
%             #{<<"exp">> => 1300819380,
%               <<"http://example.com/is_root">> => true,
%               <<"iss">> => <<"joe">>}},
%     #jose_jws{
%         alg = {jose_jws_alg_hmac,'HS256'},
%         b64 = undefined,
%         fields = #{<<"typ">> => <<"JWT">>}}}

Verified =:= jose_jwt:verify(JWK, Signed).
% true
```

##### Reading JSON Web Keys (JWK) from PEM files

The examples below use three keys created with `openssl`:

```bash
# RSA Private Key
openssl genrsa -out rsa-2048.pem 2048

# EC Private Key (Alice)
openssl ecparam -name secp256r1 -genkey -noout -out ec-secp256r1-alice.pem

# EC Private Key (Bob)
openssl ecparam -name secp256r1 -genkey -noout -out ec-secp256r1-bob.pem
```

_Elixir_

```elixir
# RSA examples
rsa_private_jwk = JOSE.JWK.from_pem_file("rsa-2048.pem")
rsa_public_jwk  = JOSE.JWK.to_public(rsa_private_jwk)

## Sign and Verify (defaults to PS256)
message = "my message"
signed = JOSE.JWK.sign(message, rsa_private_jwk)
{true, ^message, _} = JOSE.JWK.verify(signed, rsa_public_jwk)

## Sign and Verify (specify RS256)
signed = JOSE.JWK.sign(message, %{ "alg" => "RS256" }, rsa_private_jwk)
{true, ^message, _} = JOSE.JWK.verify(signed, rsa_public_jwk)

## Encrypt and Decrypt (defaults to RSA-OAEP with A128CBC-HS256)
plain_text = "my plain text"
encrypted = JOSE.JWK.block_encrypt(plain_text, rsa_public_jwk)
{^plain_text, _} = JOSE.JWK.block_decrypt(encrypted, rsa_private_jwk)

## Encrypt and Decrypt (specify RSA-OAEP-256 with A128GCM)
encrypted = JOSE.JWK.block_encrypt(plain_text, %{ "alg" => "RSA-OAEP-256", "enc" => "A128GCM" }, rsa_public_jwk)
{^plain_text, _} = JOSE.JWK.block_decrypt(encrypted, rsa_private_jwk)

# EC examples
alice_private_jwk = JOSE.JWK.from_pem_file("ec-secp256r1-alice.pem")
alice_public_jwk  = JOSE.JWK.to_public(alice_private_jwk)
bob_private_jwk   = JOSE.JWK.from_pem_file("ec-secp256r1-bob.pem")
bob_public_jwk    = JOSE.JWK.to_public(bob_private_jwk)

## Sign and Verify (defaults to ES256)
message = "my message"
signed = JOSE.JWK.sign(message, alice_private_jwk)
{true, ^message, _} = JOSE.JWK.verify(signed, alice_public_jwk)

## Encrypt and Decrypt (defaults to ECDH-ES with A128GCM)
### Alice sends Bob a secret message using Bob's public key and Alice's private key
alice_to_bob = "For Bob's eyes only."
encrypted = JOSE.JWK.box_encrypt(alice_to_bob, bob_public_jwk, alice_private_jwk)
### Only Bob can decrypt the message using his private key (Alice's public key is embedded in the JWE header)
{^alice_to_bob, _} = JOSE.JWK.box_decrypt(encrypted, bob_private_jwk)
```

_Erlang_

```erlang
% RSA examples
RSAPrivateJWK = jose_jwk:from_pem_file("rsa-2048.pem"),
RSAPublicJWK  = jose_jwk:to_public(RSAPrivateJWK).

%% Sign and Verify (defaults to PS256)
Message = <<"my message">>,
SignedPS256 = jose_jwk:sign(Message, RSAPrivateJWK),
{true, Message, _} = jose_jwk:verify(SignedPS256, RSAPublicJWK).

%% Sign and Verify (specify RS256)
SignedRS256 = jose_jwk:sign(Message, #{ <<"alg">> => <<"RS256">> }, RSAPrivateJWK),
{true, Message, _} = jose_jwk:verify(SignedRS256, RSAPublicJWK).

%% Encrypt and Decrypt (defaults to RSA-OAEP with A128CBC-HS256)
PlainText = <<"my plain text">>,
EncryptedRSAOAEP = jose_jwk:block_encrypt(PlainText, RSAPublicJWK),
{PlainText, _} = jose_jwk:block_decrypt(EncryptedRSAOAEP, RSAPrivateJWK).

%% Encrypt and Decrypt (specify RSA-OAEP-256 with A128GCM)
EncryptedRSAOAEP256 = jose_jwk:block_encrypt(PlainText, #{ <<"alg">> => <<"RSA-OAEP-256">>, <<"enc">> => <<"A128GCM">> }, RSAPublicJWK),
{PlainText, _} = jose_jwk:block_decrypt(EncryptedRSAOAEP256, RSAPrivateJWK).

% EC examples
AlicePrivateJWK = jose_jwk:from_pem_file("ec-secp256r1-alice.pem"),
AlicePublicJWK  = jose_jwk:to_public(AlicePrivateJWK),
BobPrivateJWK   = jose_jwk:from_pem_file("ec-secp256r1-bob.pem"),
BobPublicJWK    = jose_jwk:to_public(BobPrivateJWK).

%% Sign and Verify (defaults to ES256)
Message = <<"my message">>,
SignedES256 = jose_jwk:sign(Message, AlicePrivateJWK),
{true, Message, _} = jose_jwk:verify(SignedES256, AlicePublicJWK).

%% Encrypt and Decrypt (defaults to ECDH-ES with A128GCM)
%%% Alice sends Bob a secret message using Bob's public key and Alice's private key
AliceToBob = <<"For Bob's eyes only.">>,
EncryptedECDHES = jose_jwk:box_encrypt(AliceToBob, BobPublicJWK, AlicePrivateJWK),
%%% Only Bob can decrypt the message using his private key (Alice's public key is embedded in the JWE header)
{AliceToBob, _} = jose_jwk:box_decrypt(EncryptedECDHES, BobPrivateJWK).
```

## Algorithm Support

### JSON Web Encryption (JWE) [RFC 7516](https://tools.ietf.org/html/rfc7516)

#### `"alg"` [RFC 7518 Section 4](https://tools.ietf.org/html/rfc7518#section-4)

- [X] `A128GCMKW`
- [X] `A192GCMKW`
- [X] `A256GCMKW`
- [X] `A128KW`
- [X] `A192KW`
- [X] `A256KW`
- [X] `C20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02)</sup>
- [X] `dir`
- [X] `ECDH-1PU` <sup>[draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+A128GCMKW` <sup>non-standard, [draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+A192GCMKW` <sup>non-standard, [draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+A256GCMKW` <sup>non-standard, [draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+A128KW` <sup>[draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+A192KW` <sup>[draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+A256KW` <sup>[draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+C20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02), [draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-1PU+XC20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02), [draft-madden-jose-ecdh-1pu](https://datatracker.ietf.org/doc/html/draft-madden-jose-ecdh-1pu-04)</sup>
- [X] `ECDH-ES`
- [X] `ECDH-ES+A128GCMKW` <sup>non-standard</sup>
- [X] `ECDH-ES+A192GCMKW` <sup>non-standard</sup>
- [X] `ECDH-ES+A256GCMKW` <sup>non-standard</sup>
- [X] `ECDH-ES+A128KW`
- [X] `ECDH-ES+A192KW`
- [X] `ECDH-ES+A256KW`
- [X] `ECDH-ES+C20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02)</sup>
- [X] `ECDH-ES+XC20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02)</sup>
- [X] `ECDH-SS` <sup>[draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+A128GCMKW` <sup>non-standard, [draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+A192GCMKW` <sup>non-standard, [draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+A256GCMKW` <sup>non-standard, [draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+A128KW` <sup>[draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+A192KW` <sup>[draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+A256KW` <sup>[draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+C20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02), [draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `ECDH-SS+XC20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02), [draft-amringer-jose-ecdh-ss](https://datatracker.ietf.org/doc/html/draft-amringer-jose-ecdh-ss-00)</sup>
- [X] `PBES2-HS256+A128GCMKW` <sup>non-standard</sup>
- [X] `PBES2-HS384+A192GCMKW` <sup>non-standard</sup>
- [X] `PBES2-HS512+A256GCMKW` <sup>non-standard</sup>
- [X] `PBES2-HS256+A128KW`
- [X] `PBES2-HS384+A192KW`
- [X] `PBES2-HS512+A256KW`
- [X] `PBES2-HS512+C20PKW` <sup>non-standard</sup>
- [X] `PBES2-HS512+XC20PKW` <sup>non-standard</sup>
- [X] `RSA1_5`
- [X] `RSA-OAEP`
- [X] `RSA-OAEP-256`
- [X] `XC20PKW` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02)</sup>

#### `"enc"` [RFC 7518 Section 5](https://tools.ietf.org/html/rfc7518#section-5)

- [X] `A128CBC-HS256`
- [X] `A192CBC-HS384`
- [X] `A256CBC-HS512`
- [X] `A128GCM`
- [X] `A192GCM`
- [X] `A256GCM`
- [X] `C20P` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02)</sup>
- [X] `XC20P` <sup>[draft-amringer-jose-chacha](https://datatracker.ietf.org/doc/html/draft-amringer-jose-chacha-02)</sup>

#### `"zip"` [RFC 7518 Section 7.3](https://tools.ietf.org/html/rfc7518#section-7.3)

- [X] `DEF`

### JSON Web Key (JWK) [RFC 7517](https://tools.ietf.org/html/rfc7517)

#### `"alg"` [RFC 7518 Section 6](https://tools.ietf.org/html/rfc7518#section-6)

- [X] `EC`
- [X] `oct`
- [X] `OKP` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037)</sup>
- [X] `OKP` with `{"crv":"Ed25519"}` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.1)</sup>
- [X] `OKP` with `{"crv":"Ed25519ph"}` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.1)</sup>
- [X] `OKP` with `{"crv":"Ed448"}` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.2)</sup>
- [X] `OKP` with `{"crv":"Ed448ph"}` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.2)</sup>
- [X] `OKP` with `{"crv":"X25519"}` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 7748](https://tools.ietf.org/html/rfc7748#section-5)</sup>
- [X] `OKP` with `{"crv":"X448"}` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 7748](https://tools.ietf.org/html/rfc7748#section-5)</sup>
- [X] `RSA`

### JSON Web Signature (JWS) [RFC 7515](https://tools.ietf.org/html/rfc7515)

#### `"alg"` [RFC 7518 Section 3](https://tools.ietf.org/html/rfc7518#section-3)

- [X] `Ed25519` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.1)</sup>
- [X] `Ed25519ph` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.1)</sup>
- [X] `Ed448` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.2)</sup>
- [X] `Ed448ph` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032#section-5.2)</sup>
- [X] `EdDSA` <sup>[RFC 8037](https://tools.ietf.org/html/rfc8037), [RFC 8032](https://tools.ietf.org/html/rfc8032)</sup>
- [X] `ES256K` <sup>[RFC 8812](https://datatracker.ietf.org/doc/html/rfc8812)</sup>
- [X] `ES256`
- [X] `ES384`
- [X] `ES512`
- [X] `HS256`
- [X] `HS384`
- [X] `HS512`
- [X] `Poly1305` <sup>non-standard</sup>
- [X] `PS256`
- [X] `PS384`
- [X] `PS512`
- [X] `RS1` <sup>deprecated, [RFC 8812](https://datatracker.ietf.org/doc/html/rfc8812)</sup>
- [X] `RS256`
- [X] `RS384`
- [X] `RS512`
- [X] `none` <sup>[unsecured](#footnote-unsecured)</sup>

### Additional Specifications

- [X] JSON Web Key (JWK) Thumbprint [RFC 7638](https://tools.ietf.org/html/rfc7638)
- [X] JWS Unencoded Payload Option [RFC 7797](https://tools.ietf.org/html/rfc7797)

<sup><a name="footnote-unsecured">unsecured</a></sup> This algorithm is disabled by default due to the unsecured signing vulnerability.  Use the [`unsecured_signing`](#unsecured-signing-vulnerability) setting to enable this algorithm.
