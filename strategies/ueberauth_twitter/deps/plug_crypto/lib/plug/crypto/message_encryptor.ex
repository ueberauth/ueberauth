defmodule Plug.Crypto.MessageEncryptor do
  @moduledoc ~S"""
  `MessageEncryptor` is a simple way to encrypt values which get stored
  somewhere you don't trust.

  The encrypted key, initialization vector, cipher text, and cipher tag
  are base64url encoded and returned to you.

  This can be used in situations similar to the `Plug.Crypto.MessageVerifier`,
  but where you don't want users to be able to determine the value of the payload.

  The current algorithm used is XChaCha20-Poly1305.

  ## Example

      iex> secret_key_base = "072d1e0157c008193fe48a670cce031faa4e..."
      ...> encrypted_cookie_salt = "encrypted cookie"
      ...> secret = KeyGenerator.generate(secret_key_base, encrypted_cookie_salt)
      ...>
      ...> data = "José"
      ...> encrypted = MessageEncryptor.encrypt(data, secret, "UNUSED")
      ...> MessageEncryptor.decrypt(encrypted, secret, "UNUSED")
      {:ok, "José"}

  """

  @doc """
  Encrypts a message using authenticated encryption.

  The `sign_secret` is currently only used on decryption
  for backwards compatibility.

  A custom authentication message can be provided.
  It defaults to "A128GCM" for backwards compatibility.
  """
  def encrypt(message, aad \\ "A128GCM", secret, sign_secret)

  def encrypt(message, aad, secret, sign_secret)
      when is_binary(message) and (is_binary(aad) or is_list(aad)) and
             bit_size(secret) == 256 and
             is_binary(sign_secret) do
    iv = :crypto.strong_rand_bytes(24)
    {subkey, nonce} = xchacha20_subkey_and_nonce(secret, iv)
    {cipher_text, cipher_tag} = block_encrypt(:chacha20_poly1305, subkey, nonce, {aad, message})
    "XCP." <> Base.url_encode64(iv <> cipher_tag <> cipher_text, padding: false)
  rescue
    e -> reraise e, Plug.Crypto.prune_args_from_stacktrace(__STACKTRACE__)
  end

  def encrypt(_message, _aad, _secret, _sign_secret) do
    raise ArgumentError,
          "expected a binary message, a binary or iolist aad, a 256-bit secret " <>
            "and a binary sign secret"
  end

  @doc """
  Decrypts a message using authenticated encryption.
  """
  def decrypt(encrypted, aad \\ "A128GCM", secret, sign_secret)

  def decrypt(encrypted, aad, secret, sign_secret)
      when is_binary(encrypted) and (is_binary(aad) or is_list(aad)) and
             bit_size(secret) in [128, 192, 256] and
             is_binary(sign_secret) do
    unguarded_decrypt(encrypted, aad, secret, sign_secret)
  rescue
    e -> reraise e, Plug.Crypto.prune_args_from_stacktrace(__STACKTRACE__)
  end

  def decrypt(_encrypted, _aad, _secret, _sign_secret) do
    raise ArgumentError,
          "expected a binary token, a binary or iolist aad, a 128, 192 or 256-bit secret " <>
            "and a binary sign secret"
  end

  defp unguarded_decrypt("XCP." <> iv_cipher_text_cipher_tag, aad, secret, _sign_secret)
       when bit_size(secret) == 256 do
    with {:ok, <<iv::192-bits, cipher_tag::128-bits, cipher_text::binary>>} <-
           Base.url_decode64(iv_cipher_text_cipher_tag, padding: false),
         {subkey, nonce} = xchacha20_subkey_and_nonce(secret, iv),
         plain_text when is_binary(plain_text) <-
           block_decrypt(:chacha20_poly1305, subkey, nonce, {aad, cipher_text, cipher_tag}) do
      {:ok, plain_text}
    else
      _ -> :error
    end
  end

  # Messages from Plug.Crypto v1.x
  defp unguarded_decrypt("QTEyOEdDTQ." <> rest, aad, secret, sign_secret) do
    with [encrypted_key, iv, cipher_text, cipher_tag] <- :binary.split(rest, ".", [:global]),
         {:ok, encrypted_key} <- Base.url_decode64(encrypted_key, padding: false),
         {:ok, iv} when bit_size(iv) === 96 <- Base.url_decode64(iv, padding: false),
         {:ok, cipher_text} <- Base.url_decode64(cipher_text, padding: false),
         {:ok, cipher_tag} when bit_size(cipher_tag) === 128 <-
           Base.url_decode64(cipher_tag, padding: false),
         {:ok, key} <- aes_gcm_key_unwrap(encrypted_key, secret, sign_secret),
         plain_text when is_binary(plain_text) <-
           block_decrypt(:aes_gcm, key, iv, {aad, cipher_text, cipher_tag}) do
      {:ok, plain_text}
    else
      _ -> :error
    end
  end

  defp unguarded_decrypt(_rest, _aad, _secret, _sign_secret) do
    :error
  end

  defp block_encrypt(cipher, key, iv, {aad, payload}) do
    cipher = cipher_alias(cipher, bit_size(key))
    :crypto.crypto_one_time_aead(cipher, key, iv, payload, aad, true)
  catch
    :error, :notsup -> raise_notsup(cipher)
  end

  defp block_decrypt(cipher, key, iv, {aad, payload, tag}) do
    cipher = cipher_alias(cipher, bit_size(key))
    :crypto.crypto_one_time_aead(cipher, key, iv, payload, aad, tag, false)
  catch
    :error, :notsup -> raise_notsup(cipher)
  end

  defp cipher_alias(:aes_gcm, 128), do: :aes_128_gcm
  defp cipher_alias(:aes_gcm, 192), do: :aes_192_gcm
  defp cipher_alias(:aes_gcm, 256), do: :aes_256_gcm
  defp cipher_alias(other, _), do: other

  defp raise_notsup(algo) do
    raise "the algorithm #{inspect(algo)} is not supported by your Erlang/OTP installation. " <>
            "Please make sure it was compiled with the correct OpenSSL/BoringSSL bindings"
  end

  defp xchacha20_subkey_and_nonce(<<key::256-bits>>, <<nonce0::128-bits, nonce1::64-bits>>) do
    subkey = hchacha20(key, nonce0)
    nonce = <<0::32, nonce1::64-bits>>
    {subkey, nonce}
  end

  defp hchacha20(<<key::256-bits>>, <<nonce::128-bits>>) do
    # ChaCha20 has an internal blocksize of 512-bits (64-bytes).
    # Let's use a Mask of random 64-bytes to blind the intermediate keystream.
    mask = <<mask_h::128-bits, _::256-bits, mask_t::128-bits>> = :crypto.strong_rand_bytes(64)

    <<state_2h::128-bits, _::256-bits, state_2t::128-bits>> =
      :crypto.crypto_one_time(:chacha20, key, nonce, mask, true)

    <<
      x00::32-unsigned-little-integer,
      x01::32-unsigned-little-integer,
      x02::32-unsigned-little-integer,
      x03::32-unsigned-little-integer,
      x12::32-unsigned-little-integer,
      x13::32-unsigned-little-integer,
      x14::32-unsigned-little-integer,
      x15::32-unsigned-little-integer
    >> =
      :crypto.exor(
        <<mask_h::128-bits, mask_t::128-bits>>,
        <<state_2h::128-bits, state_2t::128-bits>>
      )

    ## The final step of ChaCha20 is `State2 = State0 + State1', so let's
    ## recover `State1' with subtraction: `State1 = State2 - State0'
    <<
      y00::32-unsigned-little-integer,
      y01::32-unsigned-little-integer,
      y02::32-unsigned-little-integer,
      y03::32-unsigned-little-integer,
      y12::32-unsigned-little-integer,
      y13::32-unsigned-little-integer,
      y14::32-unsigned-little-integer,
      y15::32-unsigned-little-integer
    >> = <<"expand 32-byte k", nonce::128-bits>>

    <<
      x00 - y00::32-unsigned-little-integer,
      x01 - y01::32-unsigned-little-integer,
      x02 - y02::32-unsigned-little-integer,
      x03 - y03::32-unsigned-little-integer,
      x12 - y12::32-unsigned-little-integer,
      x13 - y13::32-unsigned-little-integer,
      x14 - y14::32-unsigned-little-integer,
      x15 - y15::32-unsigned-little-integer
    >>
  end

  # Unwraps an encrypted content encryption key (CEK) with secret and
  # sign_secret using AES GCM mode. Accepts keys of 128, 192, or 256
  # bits based on the length of the secret key.
  #
  # See: https://tools.ietf.org/html/rfc7518#section-4.7
  defp aes_gcm_key_unwrap(wrapped_cek, secret, sign_secret)
       when bit_size(secret) in [128, 192, 256] and is_binary(sign_secret) do
    wrapped_cek
    |> case do
      <<cipher_text::128-bitstring, cipher_tag::128-bitstring, iv::96-bitstring>> ->
        block_decrypt(:aes_gcm, secret, iv, {sign_secret, cipher_text, cipher_tag})

      <<cipher_text::192-bitstring, cipher_tag::128-bitstring, iv::96-bitstring>> ->
        block_decrypt(:aes_gcm, secret, iv, {sign_secret, cipher_text, cipher_tag})

      <<cipher_text::256-bitstring, cipher_tag::128-bitstring, iv::96-bitstring>> ->
        block_decrypt(:aes_gcm, secret, iv, {sign_secret, cipher_text, cipher_tag})

      _ ->
        :error
    end
    |> case do
      cek when bit_size(cek) in [128, 192, 256] -> {:ok, cek}
      _ -> :error
    end
  end
end
