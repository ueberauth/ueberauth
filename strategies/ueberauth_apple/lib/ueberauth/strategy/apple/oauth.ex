defmodule Ueberauth.Strategy.Apple.OAuth do
  @moduledoc """
  OAuth2 for Apple.

  Add `client_id` and `client_secret` to your configuration:

  config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
    client_id: System.get_env("APPLE_CLIENT_ID"),
    client_secreat: System.get_env("APPLE_CLIENT_SECRET")
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

    opts =
      @defaults
      |> Keyword.merge(opts)
      |> Keyword.merge(config)
      |> resolve_values()
      |> generate_secret()

    OAuth2.Client.new(opts)
  end

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
      {:error, %{body: %{"error" => error}}} ->
        {:error, {error, "error requesting token"}}

      {:ok, %{token: %{access_token: nil} = token}} ->
        %{"error" => error} = token.other_params
        {:error, {error, "no access token"}}

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

  defp resolve_values(list) do
    for {key, value} <- list do
      {key, resolve_value(value)}
    end
  end

  defp resolve_value({m, f, a}) when is_atom(m) and is_atom(f), do: apply(m, f, a)
  defp resolve_value(v), do: v

  defp generate_secret(opts) do
    if is_tuple(opts[:client_secret]) do
      {module, fun} = opts[:client_secret]
      secret = apply(module, fun, [opts])
      Keyword.put(opts, :client_secret, secret)
    else
      opts
    end
  end
end
