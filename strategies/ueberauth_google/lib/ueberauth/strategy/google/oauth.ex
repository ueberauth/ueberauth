defmodule Ueberauth.Strategy.Google.OAuth do
  @moduledoc """
  OAuth2 for Google.

  Add `client_id` and `client_secret` to your configuration:

  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.get_env("GOOGLE_APP_ID"),
    client_secret: System.get_env("GOOGLE_APP_SECRET")
  """
  use OAuth2.Strategy

  @defaults [
     strategy: __MODULE__,
     site: "https://accounts.google.com",
     authorize_url: "/o/oauth2/v2/auth",
     token_url: "https://www.googleapis.com/oauth2/v4/token"
   ]

  @doc """
  Construct a client for requests to Google.

  This will be setup automatically for you in `Ueberauth.Strategy.Google`.

  These options are only useful for usage outside the normal callback phase of Ueberauth.
  """
  def client(opts \\ []) do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

    opts =
      @defaults
      |> Keyword.merge(config)
      |> Keyword.merge(opts)

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
    client([token: token])
    |> put_param("client_secret", client().client_secret)
    |> OAuth2.Client.get(url, headers, opts)
  end

  def get_token!(params \\ [], opts \\ []) do
    client =
      opts
      |> client
      |> OAuth2.Client.get_token!(params)
    client.token
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
end
