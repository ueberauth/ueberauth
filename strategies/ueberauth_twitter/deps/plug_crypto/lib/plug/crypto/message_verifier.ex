defmodule Plug.Crypto.MessageVerifier do
  @moduledoc """
  `MessageVerifier` makes it easy to generate and verify messages
  which are signed to prevent tampering.

  For example, the cookie store uses this verifier to send data
  to the client. The data can be read by the client, but cannot be
  tampered with.

  The message and its verification are base64url encoded and returned
  to you.

  The current algorithm used is HMAC-SHA, with SHA256, SHA384, and
  SHA512 as supported digest types.
  """

  @doc """
  Signs a message according to the given secret.
  """
  def sign(message, secret, digest_type \\ :sha256)

  def sign(message, secret, digest_type)
      when is_binary(message) and byte_size(secret) > 0 and
             digest_type in [:sha256, :sha384, :sha512] do
    hmac_sha2_sign(message, secret, digest_type)
  rescue
    e -> reraise e, Plug.Crypto.prune_args_from_stacktrace(__STACKTRACE__)
  end

  def sign(_message, _secret, _digest_type) do
    raise ArgumentError,
          "expected a binary message, a non-empty binary secret and a digest type " <>
            "of :sha256, :sha384 or :sha512"
  end

  @doc """
  Decodes and verifies the encoded binary was not tampered with.
  """
  def verify(signed, secret) when is_binary(signed) and byte_size(secret) > 0 do
    hmac_sha2_verify(signed, secret)
  rescue
    e -> reraise e, Plug.Crypto.prune_args_from_stacktrace(__STACKTRACE__)
  end

  def verify(_signed, _secret) do
    raise ArgumentError, "expected a binary token and a non-empty binary secret"
  end

  ## Signature Algorithms

  defp hmac_sha2_to_protected(:sha256), do: "SFMyNTY"
  defp hmac_sha2_to_protected(:sha384), do: "SFMzODQ"
  defp hmac_sha2_to_protected(:sha512), do: "SFM1MTI"

  defp hmac_sha2_to_digest_type("SFMyNTY"), do: :sha256
  defp hmac_sha2_to_digest_type("SFMzODQ"), do: :sha384
  defp hmac_sha2_to_digest_type("SFM1MTI"), do: :sha512

  defp hmac_sha2_sign(payload, key, digest_type) do
    protected = hmac_sha2_to_protected(digest_type)
    plain_text = [protected, ?., Base.url_encode64(payload, padding: false)]
    signature = :crypto.mac(:hmac, digest_type, key, plain_text)
    IO.iodata_to_binary([plain_text, ".", Base.url_encode64(signature, padding: false)])
  end

  defp hmac_sha2_verify(signed, key) when is_binary(signed) and is_binary(key) do
    with [protected, payload, signature] when protected in ["SFMyNTY", "SFMzODQ", "SFM1MTI"] <-
           :binary.split(signed, ".", [:global]),
         plain_text = [protected, ?., payload],
         {:ok, payload} <- Base.url_decode64(payload, padding: false),
         {:ok, signature} <- Base.url_decode64(signature, padding: false) do
      digest_type = hmac_sha2_to_digest_type(protected)
      challenge = :crypto.mac(:hmac, digest_type, key, plain_text)

      if Plug.Crypto.secure_compare(challenge, signature) do
        {:ok, payload}
      else
        :error
      end
    else
      _ ->
        :error
    end
  end
end
