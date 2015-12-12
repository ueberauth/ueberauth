defmodule Ueberauth.Strategy.Twitter.OAuth do
  @moduledoc """
  OAuth1 for Twitter.

  Add `consumer_key` and `consumer_secret` to your configuration:

  config :ueberauth, Ueberauth.Strategy.Twitter.OAuth,
    consumer_key: System.get_env("TWITTER_CONSUMER_KEY"),
    consumer_secret: System.get_env("TWITTER_CONSUMER_SECRET"),
    redirect_uri: System.get_env("TWITTER_REDIRECT_URI")
  """

  @defaults [access_token: "/oauth/access_token",
             authorize_url: "/oauth/authorize",
             request_token: "/oauth/request_token",
             site: "https://api.twitter.com"]

  def access_token({token, token_secret}, verifier, opts \\ []) do
    opts
    |> client
    |> to_url(:access_token)
    |> String.to_char_list
    |> :oauth.get([oauth_verifier: verifier], consumer(client), token, token_secret)
    |> decode_access_response
  end

  def access_token!(access_token, verifier, opts \\ []) do
    case access_token(access_token, verifier, opts) do
      {:ok, token} -> token
      {:error, error} -> raise error
    end
  end

  def authorize_url!({token, _token_secret}, opts \\ []) do
    opts
    |> client
    |> to_url(:authorize_url, %{"oauth_token" => List.to_string(token)})
  end

  def client(opts \\ []) do
    config = Application.get_env(:ueberauth, __MODULE__)

    @defaults
    |> Keyword.merge(config)
    |> Keyword.merge(opts)
    |> Enum.into(%{})
  end

  def get(url, access_token), do: get(url, [], access_token)
  def get(url, params, {token, token_secret}) do
    client
    |> to_url(url)
    |> String.to_char_list
    |> :oauth.get(params, consumer(client), token, token_secret)
  end

  def request_token(params \\ [], opts \\ []) do
    client = client(opts)
    params = Keyword.put_new(params, :oauth_callback, client.redirect_uri)

    client
    |> to_url(:request_token)
    |> String.to_char_list
    |> :oauth.get(params, consumer(client))
    |> decode_request_response
  end

  def request_token!(params \\ [], opts \\ []) do
    case request_token(params, opts) do
      {:ok, token} -> token
      {:error, error} -> raise error
    end
  end

  defp consumer(client), do: {client.consumer_key, client.consumer_secret, :hmac_sha1}

  defp decode_access_response({:ok, {{_, 200, _}, _, _} = resp}) do
    params = :oauth.params_decode(resp)
    token = :oauth.token(params)
    token_secret = :oauth.token_secret(params)

    {:ok, {token, token_secret}}
  end
  defp decode_access_response(error), do: {:error, error}

  defp decode_request_response({:ok, {{_, 200, _}, _, _} = resp}) do
    params = :oauth.params_decode(resp)
    token = :oauth.token(params)
    token_secret = :oauth.token_secret(params)

    {:ok, {token, token_secret}}
  end
  defp decode_request_response(error), do: {:error, error}

  defp endpoint("/" <> _path = endpoint, client), do: client.site <> endpoint
  defp endpoint(endpoint, _client), do: endpoint

  defp to_url(client, endpoint, params \\ nil) do
    endpoint =
      client
      |> Map.get(endpoint, endpoint)
      |> endpoint(client)

    unless params == nil do
      endpoint = endpoint <> "?" <> URI.encode_query(params)
    end

    endpoint
  end
end
