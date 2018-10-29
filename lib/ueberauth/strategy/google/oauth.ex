defmodule Ueberauth.Strategy.Google.OAuth do
  @moduledoc """
  OAuth2 for Google.

  Add `client_id` and `client_secret` to your configuration:

  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: System.get_env("GOOGLE_APP_ID"),
    client_secret: System.get_env("GOOGLE_APP_SECRET")

  You may overwrite this by setting client_id and client_secret in your options when creating the client.
  """
  use OAuth2.Strategy

  @defaults [
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
    config = fetch_config(opts)

    opts =
      @defaults
      |> Keyword.merge(opts)
      |> Keyword.merge(config)

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
    case OAuth2.Client.authorize_url(client, params) do
      {_client, url} -> url
      _ -> nil
    end
  end

  def get_token(client, params, headers) do
    client
    |> put_param("client_secret", client.client_secret)
    |> put_header("Accept", "application/json")
    |> OAuth2.Client.get_token(params, headers)
  end

  defp fetch_config(opts) do
    config_from_opts = Keyword.take(opts, [:client_id, :client_secret])

    config =
      if length(config_from_opts) == 2 do
        config_from_opts
      else
        Application.get_env(:ueberauth, __MODULE__)
      end

    case config do
      nil -> raise "unconfigured oauth strategy"
      configs ->
        if length(config) < 2 do
          raise "unconfigured oauth strategy"
        else
          configs
        end
    end
  end
end
