defmodule JOSE do
  @moduledoc ~S"""
  JOSE stands for JSON Object Signing and Encryption which is a is a set of
  standards established by the [JOSE Working Group](https://datatracker.ietf.org/wg/jose).

  JOSE is split into 5 main components:

    * `JOSE.JWA` - JSON Web Algorithms (JWA) [RFC 7518](https://tools.ietf.org/html/rfc7518)
    * `JOSE.JWE` - JSON Web Encryption (JWE) [RFC 7516](https://tools.ietf.org/html/rfc7516)
    * `JOSE.JWK` - JSON Web Key (JWK)        [RFC 7517](https://tools.ietf.org/html/rfc7517)
    * `JOSE.JWS` - JSON Web Signature (JWS)  [RFC 7515](https://tools.ietf.org/html/rfc7515)
    * `JOSE.JWT` - JSON Web Token (JWT)      [RFC 7519](https://tools.ietf.org/html/rfc7519)

  Additional specifications and drafts implemented:

    * JSON Web Key (JWK) Thumbprint [RFC 7638](https://tools.ietf.org/html/rfc7638)
    * JWS Unencoded Payload Option  [RFC 7797](https://tools.ietf.org/html/rfc7797)
  """

  ## Functions

  @doc """
  Gets the current ChaCha20/Poly1305 module used by `jose_chacha20_poly1305`.

  See `chacha20_poly1305_module/1` for default.
  """
  @spec chacha20_poly1305_module() :: module()
  defdelegate chacha20_poly1305_module(), to: :jose

  @doc """
  Sets the current ChaCha20/Poly1305 module used by `jose_chacha20_poly1305`.

  Currently supported ChaCha20/Poly1305 modules (first found is used as default):

    * `crypto` - only when 96-bit nonce is supported
    * [`libsodium`](https://github.com/potatosalad/erlang-libsodium)
    * `jose_jwa_chacha20_poly1305` - only supported when `crypto_fallback/0` is `true`

  Additional modules that implement the `jose_chacha20_poly1305` behavior may also be used.
  """
  @spec chacha20_poly1305_module(module()) :: :ok
  defdelegate chacha20_poly1305_module(module), to: :jose

  @doc """
  Gets the current Cryptographic Algorithm Fallback state

  Defaults to `false`.
  """
  @spec crypto_fallback() :: boolean()
  defdelegate crypto_fallback(), to: :jose

  @doc """
  Sets the current Cryptographic Algorithm Fallback state.
  """
  @spec crypto_fallback(boolean()) :: :ok
  defdelegate crypto_fallback(boolean), to: :jose

  @doc """
  Gets the current Curve25519 module used by `jose_curve25519`

  See `curve25519_module/1` for default.
  """
  @spec curve25519_module() :: module()
  defdelegate curve25519_module(), to: :jose

  @doc """
  Sets the current Curve25519 module used by `jose_curve25519`.

  Currently supported Curve25519 modules (first found is used as default):

    * [`libdecaf`](https://github.com/potatosalad/erlang-libdecaf)
    * [`libsodium`](https://github.com/potatosalad/erlang-libsodium)
    * `jose_jwa_curve25519` - only supported when `crypto_fallback/0` is `true`

  Additional modules that implement the `jose_curve25519` behavior may also be used.
  """
  @spec curve25519_module(module()) :: :ok
  defdelegate curve25519_module(module), to: :jose

  @doc """
  Gets the current Curve448 module used by `jose_curve448`

  See `curve448_module/1` for default.
  """
  @spec curve448_module() :: module()
  defdelegate curve448_module(), to: :jose

  @doc """
  Sets the current Curve448 module used by `jose_curve448`.

  Currently supported Curve448 modules (first found is used as default):

    * [`libdecaf`](https://github.com/potatosalad/erlang-libdecaf)
    * `jose_jwa_curve448` - only supported when `crypto_fallback/0` is `true`

  Additional modules that implement the `jose_curve448` behavior may also be used.
  """
  @spec curve448_module(module()) :: :ok
  defdelegate curve448_module(module), to: :jose

  @doc """
  Decodes JSON to a term using the module returned by `json_module/0`.

  Returns the decoded term, or raises if `binary` contains invalid JSON.
  """
  @spec decode(binary()) :: term()
  defdelegate decode(binary), to: :jose

  @doc """
  Encodes a term to JSON using the module returned by `json_module/0`.

  Returns the encoded JSON, or raises if `term` cannot be encoded.
  """
  @spec encode(term()) :: binary()
  defdelegate encode(term), to: :jose

  @doc """
  Gets the current JSON module used by `decode/1` and `encode/1`, see `json_module/1` for default.
  """
  @spec json_module() :: module()
  defdelegate json_module(), to: :jose

  @doc """
  Sets the current JSON module used by `decode/1` and `encode/1`.

  Currently supported JSON modules (first found is used as default):

    * [`ojson`](https://github.com/potatosalad/erlang-ojson)
    * [`Jason`](https://github.com/michalmuskala/jason)
    * [`Poison`](https://github.com/devinus/poison)
    * [`jiffy`](https://github.com/davisp/jiffy)
    * [`jsone`](https://github.com/sile/jsone)
    * [`jsx`](https://github.com/talentdeficit/jsx)

  Additional modules that implement the `:jose_json` behavior may also be used.
  """
  @spec json_module(module()) :: :ok
  defdelegate json_module(module), to: :jose

  @doc """
  Gets the current SHA3 module used by `jose_sha3`, see `sha3_module/1` for default.
  """
  @spec sha3_module() :: module()
  defdelegate sha3_module(), to: :jose

  @doc """
  Sets the current SHA3 module used by `jose_sha3`.

  Currently supported SHA3 modules (first found is used as default):

    * [`keccakf1600`](https://github.com/potatosalad/erlang-keccakf1600)
    * [`libdecaf`](https://github.com/potatosalad/erlang-libdecaf)
    * `jose_jwa_sha3` - only supported when `crypto_fallback/0` is `true`

  Additional modules that implement the `jose_sha3` behavior may also be used.
  """
  @spec sha3_module(module()) :: :ok
  defdelegate sha3_module(module), to: :jose

  @doc """
  Gets the current Unsecured Signing state, defaults to `false`.
  """
  @spec unsecured_signing() :: boolean()
  defdelegate unsecured_signing(), to: :jose

  @doc """
  Sets the current Unsecured Signing state.

  Enables/disables the `"none"` algorithm used for signing and verifying.

  See [Critical vulnerabilities in JSON Web Token libraries](https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/) for more information.
  """
  @spec unsecured_signing(boolean()) :: :ok
  defdelegate unsecured_signing(boolean), to: :jose
end
