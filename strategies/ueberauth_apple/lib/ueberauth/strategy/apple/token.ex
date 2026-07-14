defmodule Ueberauth.Strategy.Apple.Token do
  @apple_issuer "https://appleid.apple.com"
  @public_key_url "https://appleid.apple.com/auth/keys"
  @default_key_function {__MODULE__, :fetch_public_keys, []}
  @clock_skew_seconds 60

  @moduledoc """
  Provides helpers for working with Apple-generated tokens.

  Apple provides a public list of keys that may be used for token signing at #{@public_key_url}.
  Additional documentation about the Identity Token issued by Apple can be found
  [here](https://developer.apple.com/documentation/signinwithapplejs/authorizationi/id_token).
  """

  @typedoc "ID Token supplied by the Apple Auth API"
  @type t :: String.t()

  @typedoc "Public Key used by Apple to sign ID Tokens"
  @type public_key :: map

  @doc """
  Decode an ID Token provided by the Apple Auth API.

  ## Options

    * `:client_id`: The expected audience of the token. This is required.

    * `:issuer`: The expected issuer of the token. Defaults to `#{inspect(@apple_issuer)}`.

    * `:public_keys`: `{Module, :function, args}` to call in order to get a list of public keys.
      The returned data must be in the form `{:ok, keys}` where `keys` is a list of maps matching
      the structure found at #{@public_key_url}. Defaults to a function that uses HTTPoison to
      request the keys on every call.

  """
  @spec payload(t, keyword) :: {:ok, map} | {:error, term}
  def payload(id_token, opts \\ []) do
    {key_mod, key_fun, key_args} = Keyword.get(opts, :public_keys, @default_key_function)

    with {:ok, keys} <- apply(key_mod, key_fun, key_args),
         {:ok, key} <- choose_key(keys, id_token),
         {true, %JOSE.JWT{fields: fields}, _JWS} <-
           JOSE.JWT.verify_strict(key, [key["alg"]], id_token),
         {:ok, validated_fields} <- validate_claims(fields, opts) do
      {:ok, validated_fields}
    else
      {false, _, _} -> {:error, :invalid_signature}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec fetch_public_keys :: {:ok, [public_key]}
  def fetch_public_keys do
    with {:ok, %HTTPoison.Response{status_code: 200, body: body}} <-
           HTTPoison.get(@public_key_url),
         {:ok, response} <- Ueberauth.json_library().decode(body),
         %{"keys" => keys} <- response do
      {:ok, keys}
    else
      {:ok, %HTTPoison.Response{}} -> {:error, :invalid_response}
      {:error, %HTTPoison.Error{}} -> {:error, :request_error}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_keys}
    end
  end

  @spec choose_key([public_key], t) :: {:ok, public_key} | {:error, :no_matching_key}
  defp choose_key(keys, id_token) do
    %JOSE.JWS{fields: %{"kid" => kid}} = JOSE.JWT.peek_protected(id_token)

    case Enum.find(keys, fn x -> x["kid"] == kid end) do
      nil -> {:error, :no_matching_key}
      key -> {:ok, key}
    end
  end

  @spec validate_claims(map, keyword) :: {:ok, map} | {:error, term}
  defp validate_claims(fields, opts) do
    with :ok <- validate_issuer(fields, Keyword.get(opts, :issuer, @apple_issuer)),
         :ok <- validate_audience(fields, Keyword.get(opts, :client_id)),
         :ok <- validate_issued_time(fields),
         :ok <- validate_expiration_time(fields),
         :ok <- validate_nonce(fields, Keyword.get(opts, :nonce)) do
      {:ok, fields}
    end
  end

  # Apple documentation:
  #
  # The audience registered claim identifies the recipient of the identity token. Because the
  # token is for your app, the value is the client_id from your developer account.
  #
  @spec validate_audience(map, String.t() | nil) ::
          :ok | {:error, :missing_expected_audience | :invalid_audience}
  defp validate_audience(_fields, nil), do: {:error, :missing_expected_audience}
  defp validate_audience(_fields, ""), do: {:error, :missing_expected_audience}
  defp validate_audience(%{"aud" => expected_audience}, expected_audience), do: :ok
  defp validate_audience(_fields, _expected_audience), do: {:error, :invalid_audience}

  # Apple documentation:
  #
  # The expiration time registered claim identifies the time that the identity token expires, in
  # the number of seconds since the Unix epoch in UTC. The value must be greater than the current
  # date and time when verifying the token.
  #
  @spec validate_expiration_time(map) :: :ok | {:error, :expired_token}
  defp validate_expiration_time(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.os_time(:second) - @clock_skew_seconds do
      :ok
    else
      {:error, :expired_token}
    end
  end

  defp validate_expiration_time(_fields), do: {:error, :expired_token}

  # Apple does not issue an `nbf` claim, so we validate the `iat` claim instead (if present).
  #
  @spec validate_issued_time(map) :: :ok | {:error, :not_yet_valid_token}
  defp validate_issued_time(%{"iat" => iat}) when is_integer(iat) do
    if iat <= System.os_time(:second) + @clock_skew_seconds do
      :ok
    else
      {:error, :not_yet_valid_token}
    end
  end

  defp validate_issued_time(_fields), do: :ok

  # Apple documentation:
  #
  # The issuer registered claim identifies the principal that issues the identity token. Because
  # Apple generates the token, the value is https://appleid.apple.com.
  #
  @spec validate_issuer(map, String.t()) :: :ok | {:error, :invalid_issuer}
  defp validate_issuer(%{"iss" => expected_issuer}, expected_issuer), do: :ok
  defp validate_issuer(_fields, _expected_issuer), do: {:error, :invalid_issuer}

  # Apple documentation:
  #
  # nonce
  #
  # A string for associating a client session with the identity token. This value mitigates replay
  # attacks and is present only if you pass it in the authorization request.
  #
  # nonce_supported
  #
  # A Boolean value that indicates whether the transaction is on a platform that supports
  # anti-replay values. If you send an anti-replay value in the authorization request, but don’t
  # see the anti-replay value claim in the identity token, check this claim to determine how to
  # proceed. If this claim returns true, treat nonce as mandatory and fail the transaction;
  # otherwise, you can proceed treating the anti-replay value as optional.
  #
  @spec validate_nonce(map, String.t() | nil) :: :ok | {:error, :invalid_nonce}
  defp validate_nonce(_fields, nil), do: :ok
  defp validate_nonce(_fields, ""), do: :ok
  defp validate_nonce(%{"nonce" => expected_nonce}, expected_nonce), do: :ok
  defp validate_nonce(%{"nonce_supported" => false}, _expected_nonce), do: :ok
  defp validate_nonce(_fields, _expected_nonce), do: {:error, :invalid_nonce}
end
