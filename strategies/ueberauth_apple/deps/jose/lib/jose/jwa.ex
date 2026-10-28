defmodule JOSE.JWA do
  @moduledoc ~S"""
  JWA stands for JSON Web Algorithms which is defined in [RFC 7518](https://tools.ietf.org/html/rfc7518).

  ## Cryptographic Algorithm Fallback

  Native implementations of all cryptographic and public key algorithms
  required by the JWA specifications are not present in current versions
  of Elixir and OTP.

  JOSE will detect whether a specific algorithm is natively supported or not
  and, by default, it will mark the algorithm as unsupported if a native
  implementation is not found.

  However, JOSE also has pure Erlang versions of many of the missing algorithms
  which can be used as a fallback by calling `JOSE.crypto_fallback/1` and
  passing `true`.
  """

  ## Crypto API

  @doc """
  Decrypts `cipher_text` according to `cipher` block cipher.

  Currently supported block ciphers:

    * `{:aes_ecb, 128}` - AES ECB with 128-bit `key` size
    * `{:aes_ecb, 192}` - AES ECB with 192-bit `key` size
    * `{:aes_ecb, 256}` - AES ECB with 256-bit `key` size
  """
  @spec block_decrypt(term(), binary(), binary()) :: binary()
  defdelegate block_decrypt(cipher, key, cipher_text), to: :jose_jwa

  @doc """
  Decrypts `cipher_text` according to `cipher` block cipher.

  Currently supported block ciphers:

    * `{:aes_cbc, 128}` - AES CBC with 128-bit `key` size and 128-bit `iv` size
    * `{:aes_cbc, 192}` - AES CBC with 192-bit `key` size and 128-bit `iv` size
    * `{:aes_cbc, 256}` - AES CBC with 256-bit `key` size and 128-bit `iv` size
    * `{:aes_gcm, 128}` - AES GCM with 128-bit `key` size and variable `iv` size
    * `{:aes_gcm, 192}` - AES GCM with 192-bit `key` size and variable `iv` size
    * `{:aes_gcm, 256}` - AES GCM with 256-bit `key` size and variable `iv` size
    * `{:chacha20_poly1305, 256}` - ChaCha20/Poly1305 with 256-bit `key` size and 96-bit `iv` size
  """
  @spec block_decrypt(term(), binary(), binary(), binary()) :: binary()
  defdelegate block_decrypt(cipher, key, iv, cipher_text), to: :jose_jwa

  @doc """
  Encrypts `plain_text` according to `cipher` block cipher.

  Currently supported block ciphers:

    * `{:aes_ecb, 128}` - AES ECB with 128-bit `key` size
    * `{:aes_ecb, 192}` - AES ECB with 192-bit `key` size
    * `{:aes_ecb, 256}` - AES ECB with 256-bit `key` size
  """
  @spec block_encrypt(term(), binary(), binary()) :: binary()
  defdelegate block_encrypt(cipher, key, plain_text), to: :jose_jwa

  @doc """
  Encrypts `plain_text` according to `cipher` block cipher.

  Currently supported block ciphers:

    * `{:aes_cbc, 128}` - AES CBC with 128-bit `key` size and 128-bit `iv` size
    * `{:aes_cbc, 192}` - AES CBC with 192-bit `key` size and 128-bit `iv` size
    * `{:aes_cbc, 256}` - AES CBC with 256-bit `key` size and 128-bit `iv` size
    * `{:aes_gcm, 128}` - AES GCM with 128-bit `key` size and variable `iv` size
    * `{:aes_gcm, 192}` - AES GCM with 192-bit `key` size and variable `iv` size
    * `{:aes_gcm, 256}` - AES GCM with 256-bit `key` size and variable `iv` size
    * `{:chacha20_poly1305, 256}` - ChaCha20/Poly1305 with 256-bit `key` size and 96-bit `iv` size
  """
  @spec block_encrypt(term(), binary(), binary(), binary()) :: binary()
  defdelegate block_encrypt(cipher, key, iv, plain_text), to: :jose_jwa

  ## Public Key API

  @doc """
  Decrypts `cipher_text` using the `private_key`.

  ## Options

    * `:rsa_padding` - one of `:rsa_pkcs1_oaep_padding` or `:rsa_pkcs1_padding`
    * `:rsa_oaep_md` - sets the hashing algorithm for `:rsa_pkcs1_oaep_padding`, defaults to `:sha`
    * `:rsa_oaep_label` - sets the label for `:rsa_pkcs1_oaep_padding`, defaults to `<<>>`
  """
  @spec decrypt_private(binary(), :public_key.rsa_private_key(), atom() | keyword()) :: binary()
  defdelegate decrypt_private(cipher_text, private_key, options), to: :jose_jwa

  @doc """
  Encrypts `plain_text` using the `public_key`.

  ## Options

    * `:rsa_padding` - one of `:rsa_pkcs1_oaep_padding` or `:rsa_pkcs1_padding`
    * `:rsa_oaep_md` - sets the hashing algorithm for `:rsa_pkcs1_oaep_padding`, defaults to `:sha`
    * `:rsa_oaep_label` - sets the label for `:rsa_pkcs1_oaep_padding`, defaults to `<<>>`
  """
  @spec encrypt_public(binary(), :public_key.rsa_public_key(), atom() | keyword()) :: binary()
  defdelegate encrypt_public(plain_text, public_key, options), to: :jose_jwa

  @doc """
  Signs the digested `message` using the `digest_type` and `private_key`.

  ## Options

    * `:rsa_padding` - one of `:rsa_pkcs1_pss_padding` or `:rsa_pkcs1_padding`
    * `:rsa_pss_saltlen` - sets the salt length for `:rsa_pkcs1_pss_padding`, defaults to `-1`
      * `-2` - use maximum for salt length
      * `-1` - use hash length for salt length
      * any number higher than `-1` is used as the actual salt length
  """
  @spec sign(binary() | {:digest, binary()}, :public_key.digest_type(), :public_key.private_key(), atom() | keyword()) :: binary()
  defdelegate sign(message, digest_type, private_key, options), to: :jose_jwa

  @doc """
  Verifies the `signature` with the digested `message` using the `digest_type` and `public_key`.

  ## Options

    * `:rsa_padding` - one of `:rsa_pkcs1_pss_padding` or `:rsa_pkcs1_padding`
    * `:rsa_pss_saltlen` - sets the salt length for `:rsa_pkcs1_pss_padding`, defaults to `-1`
      * `-2` - automatically determine based on the PSS block structure
      * `-1` - use hash length for salt length
      * any number higher than `-1` is used as the actual salt length
  """
  @spec verify(binary() | {:digest, binary()}, :public_key.digest_type(), binary(), :public_key.public_key(), atom() | keyword()) ::
          boolean()
  defdelegate verify(message, digest_type, signature, public_key, options), to: :jose_jwa

  ## API

  @doc """
  Returns the current module and first argument for the specified `cipher`.

      iex> JOSE.JWA.block_cipher({:aes_cbc, 128})
      {:crypto, :aes_cbc128}
      iex> JOSE.JWA.block_cipher({:aes_cbc, 192})
      {:jose_jwa_unsupported, {:aes_cbc, 192}}
      iex> JOSE.crypto_fallback(true)
      :ok
      iex> JOSE.JWA.block_cipher({:aes_cbc, 192})
      {:jose_jwa_aes, {:aes_cbc, 192}}

  """
  @spec block_cipher(term()) :: {module(), term()}
  defdelegate block_cipher(cipher), to: :jose_jwa

  @doc """
  Returns the current block ciphers and their associated modules.

      iex> JOSE.JWA.crypto_ciphers()
      [{{:aes_cbc, 128}, :crypto}, {{:aes_cbc, 192}, :crypto},
       {{:aes_cbc, 256}, :crypto}, {{:aes_ecb, 128}, :crypto},
       {{:aes_ecb, 192}, :crypto}, {{:aes_ecb, 256}, :crypto},
       {{:aes_gcm, 128}, :crypto}, {{:aes_gcm, 192}, :crypto},
       {{:aes_gcm, 256}, :crypto},
       {{:chacha20_poly1305, 256}, :jose_chacha20_poly1305}]

  """
  @spec crypto_ciphers() :: [{term(), module()}]
  defdelegate crypto_ciphers(), to: :jose_jwa

  @doc """
  See `JOSE.crypto_fallback/0`
  """
  @spec crypto_fallback() :: boolean()
  defdelegate crypto_fallback(), to: :jose_jwa

  @doc """
  See `JOSE.crypto_fallback/1`
  """
  @spec crypto_fallback(boolean()) :: :ok
  defdelegate crypto_fallback(boolean), to: :jose_jwa

  @doc """
  Returns the current listing of supported `:crypto` and `:public_key` algorithms.

      iex> JOSE.JWA.crypto_supports()
      [ciphers: [aes_cbc: 128, aes_cbc: 192, aes_cbc: 256, aes_ecb: 128, aes_ecb: 192,
        aes_ecb: 256, aes_gcm: 128, aes_gcm: 192, aes_gcm: 256,
        chacha20_poly1305: 256],
       hashs: [:md5, :poly1305, :sha, :sha256, :sha384, :sha512, :shake256],
       public_keys: [:ec_gf2m, :ecdh, :ecdsa, :ed25519, :ed25519ph, :ed448, :ed448ph,
        :rsa, :x25519, :x448], rsa_crypt: [:rsa1_5, :rsa_oaep, :rsa_oaep_256],
       rsa_sign: [:rsa_pkcs1_padding, :rsa_pkcs1_pss_padding]]

  """
  @spec crypto_supports() :: keyword()
  defdelegate crypto_supports(), to: :jose_jwa

  @doc """
  Performs a constant time comparison between two binaries to help avoid [timing attacks](https://en.wikipedia.org/wiki/Timing_attack).
  """
  @spec constant_time_compare(binary(), binary()) :: boolean()
  defdelegate constant_time_compare(a, b), to: :jose_jwa

  @doc """
  Returns either `:binary` or `:list` depending on the detected runtime behavior for EC keys.
  """
  @spec ec_key_mode() :: :binary | :list
  defdelegate ec_key_mode(), to: :jose_jwa

  @doc """
  Checks whether the `cipher` is natively supported by `:crypto` or not.
  """
  @spec is_block_cipher_supported(term()) :: boolean()
  defdelegate is_block_cipher_supported(cipher), to: :jose_jwa

  @doc """
  Checks whether ChaCha20/Poly1305 support is available or not.
  """
  @spec is_chacha20_poly1305_supported() :: boolean()
  defdelegate is_chacha20_poly1305_supported(), to: :jose_jwa

  @doc """
  Checks whether the `padding` is natively supported by `:public_key` or not.
  """
  @spec is_rsa_crypt_supported(atom()) :: boolean()
  defdelegate is_rsa_crypt_supported(padding), to: :jose_jwa

  @doc """
  Checks whether the `padding` is natively supported by `:public_key` or not.
  """
  @spec is_rsa_sign_supported(atom()) :: boolean()
  defdelegate is_rsa_sign_supported(padding), to: :jose_jwa

  @doc """
  Returns the current listing of supported JOSE algorithms.

      iex> JOSE.JWA.supports()
      [{:jwe,
        {:alg,
         ["A128GCMKW", "A128KW", "A192GCMKW", "A192KW", "A256GCMKW", "A256KW",
          "ECDH-ES", "ECDH-ES+A128KW", "ECDH-ES+A192KW", "ECDH-ES+A256KW",
          "PBES2-HS256+A128KW", "PBES2-HS384+A192KW", "PBES2-HS512+A256KW",
          "RSA-OAEP", "RSA-OAEP-256", "RSA1_5", "dir"]},
        {:enc,
         ["A128CBC-HS256", "A128GCM", "A192CBC-HS384", "A192GCM", "A256CBC-HS512",
          "A256GCM", "ChaCha20/Poly1305"]}, {:zip, ["DEF"]}},
       {:jwk, {:kty, ["EC", "OKP", "RSA", "oct"]},
        {:kty_OKP_crv,
         ["Ed25519", "Ed25519ph", "Ed448", "Ed448ph", "X25519", "X448"]}},
       {:jws,
        {:alg,
         ["ES256", "ES384", "ES512", "Ed25519", "Ed25519ph", "Ed448", "Ed448ph",
          "HS256", "HS384", "HS512", "PS256", "PS384", "PS512", "Poly1305", "RS256",
          "RS384", "RS512", "none"]}}]

  """
  @spec supports() :: [{:jwe | :jwk | :jws, keyword()}, ...]
  defdelegate supports(), to: :jose_jwa

  @doc """
  See `JOSE.unsecured_signing/0`
  """
  @spec unsecured_signing() :: boolean()
  defdelegate unsecured_signing(), to: :jose_jwa

  @doc """
  See `JOSE.unsecured_signing/1`
  """
  @spec unsecured_signing(boolean()) :: :ok
  defdelegate unsecured_signing(boolean), to: :jose_jwa
end
