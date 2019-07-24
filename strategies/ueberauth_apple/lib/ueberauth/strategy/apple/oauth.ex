defmodule Ueberauth.Strategy.Apple.OAuth do
  @moduledoc """
  OAuth2 for Apple.

  Add `client_id` and `client_secret` to your configuration:

  config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
    client_id: System.get_env("APPLE_CLIENT_ID"),
    key_id: System.get_env("APPLE_KEY_ID"),
    private_key: System.get_env("APPLE_PRIVATE_KEY"),
    team_id: System.get_env("APPLE_TEAM_ID")
  """
  use OAuth2.Strategy

  @defaults [
    strategy: __MODULE__,
    site: "https://appleid.apple.com",
    authorize_url: "/auth/authorize",
    token_url: "/auth/token"
  ]

  @doc """
  Construct a client for requests to Apple.

  This will be setup automatically for you in `Ueberauth.Strategy.Apple`.

  These options are only useful for usage outside the normal callback phase of Ueberauth.
  """
  def client(opts \\ []) do
    config = Application.get_env(:ueberauth, __MODULE__, [])
    opts = @defaults |> Keyword.merge(opts) |> Keyword.merge(config) |> resolve_values()

    opts
    |> add_client_secret()
    |> OAuth2.Client.new()
  end

  def generate_client_secret(
        %{client_id: client_id, key_id: key_id, team_id: team_id, private_key: private_key} =
          options
      ) do
    opts = Enum.into(options, %{expires_in: 86400 * 180})
    now = DateTime.utc_now() |> DateTime.to_unix()
    jwk = JOSE.JWK.from_pem(private_key)
    jws = %{"alg" => "ES256", "kid" => key_id}

    jwt = %{
      "iss" => team_id,
      "iat" => now,
      "exp" => now + opts[:expires_in],
      "aud" => "https://appleid.apple.com",
      "sub" => client_id
    }

    {_, token} = jwk |> JOSE.JWT.sign(jws, jwt) |> JOSE.JWS.compact()
    token
  end

  def generate_client_secret(opts), do: opts |> Enum.into(%{}) |> generate_client_secret()

  @doc """
  Provides the authorize url for the request phase of Ueberauth. No need to call this usually.
  """
  def authorize_url!(params \\ [], opts \\ []) do
    opts
    |> client
    |> OAuth2.Client.authorize_url!(params)
  end

  def get(token, url, headers \\ [], opts \\ []) do
    [token: token]
    |> client
    |> put_param("client_secret", client().client_secret)
    |> OAuth2.Client.get(url, headers, opts)
  end

  def get_access_token(params \\ [], opts \\ []) do
    case opts |> client |> OAuth2.Client.get_token(params) do
      {:error, %{body: %{"error" => error, "error_description" => description}}} ->
        {:error, {error, description}}

      {:ok, %{token: %{access_token: nil} = token}} ->
        %{"error" => error, "error_description" => description} = token.other_params
        {:error, {error, description}}

      {:ok, %{token: token}} ->
        {:ok, token}
    end
  end

  # Strategy Callbacks

  def authorize_url(client, params) do
    OAuth2.Strategy.AuthCode.authorize_url(client, params)
  end

  def get_token(client, params, headers) do
    client
    |> put_param("client_secret", client.client_secret)
    |> put_header("Accept", "application/json")
    |> OAuth2.Strategy.AuthCode.get_token(params, headers)
  end

  defp add_client_secret(opts) do
    if opts[:client_secret] do
      opts
    else
      Keyword.put(opts, :client_secret, generate_client_secret(opts))
    end
  end

  defp resolve_values(list) do
    for {key, value} <- list do
      {key, resolve_value(value)}
    end
  end

  defp resolve_value({m, f, a}) when is_atom(m) and is_atom(f), do: apply(m, f, a)
  defp resolve_value(v), do: v
end
