defmodule Ueberauth.Strategy.Slack.OAuth do
  @moduledoc false
  use OAuth2.Strategy

  @defaults [
    strategy: __MODULE__,
    site: "https://slack.com/api",
    authorize_url: "https://slack.com/oauth/authorize",
    token_url: "https://slack.com/api/oauth.access"
  ]

  def client(opts \\ []) do
    opts = opts ++ @defaults
    OAuth2.Client.new(opts)
  end

  def get(token, url, params \\ %{}, headers \\ [], opts \\ []) do
    url =
      [token: token]
      |> client()
      |> to_url(url, Map.put(params, "token", token.access_token))

    OAuth2.Client.get(client(), url, headers, opts)
  end

  def authorize_url!(params \\ [], opts \\ []) do
    opts
    |> client()
    |> OAuth2.Client.authorize_url!(params)
  end

  def get_token!(params \\ [], options \\ []) do
    options
    |> client()
    |> OAuth2.Client.get_token!(params)
    |> Map.get(:token)
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

  defp endpoint("/" <> _path = endpoint, client), do: client.site <> endpoint
  defp endpoint(endpoint, _client), do: endpoint

  defp to_url(client, endpoint, params) do
    client_endpoint =
      client
      |> Map.get(endpoint, endpoint)
      |> endpoint(client)

    final_endpoint =
      if params do
        client_endpoint <> "?" <> URI.encode_query(params)
      else
        client_endpoint
      end

    final_endpoint
  end
end
