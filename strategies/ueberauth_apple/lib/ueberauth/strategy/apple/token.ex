defmodule Ueberauth.Strategy.Apple.Token do
  @public_key_url "https://appleid.apple.com/auth/keys"
  @default_key_function {__MODULE__, :fetch_public_keys, []}

  @moduledoc """
  Provides helpers for working with Apple-generated tokens.

  Apple provides a public list of keys that may be used for token signing at #{@public_key_url}.
  """

  @typedoc "ID Token supplied by the Apple Auth API"
  @type t :: String.t()

  @typedoc "Public Key used by Apple to sign ID Tokens"
  @type public_key :: map

  @doc """
  Decode an ID Token provided by the Apple Auth API.

  ## Options

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
         {true, %JOSE.JWT{fields: fields}, _JWS} <- JOSE.JWT.verify(key, id_token) do
      {:ok, fields}
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

  @spec choose_key([public_key], t) :: {:ok, t} | {:error, :no_matching_key}
  defp choose_key(keys, id_token) do
    %JOSE.JWS{fields: %{"kid" => kid}} = JOSE.JWT.peek_protected(id_token)

    case Enum.find(keys, fn x -> x["kid"] == kid end) do
      nil -> {:error, :no_matching_key}
      key -> {:ok, key}
    end
  end
end
