defmodule Ueberauth.Strategy.Twitter.OAuth.Internal do
  @moduledoc """
  A layer to handle OAuth signing, etc.
  """

  def get(url, extraparams, {consumer_key, consumer_secret, _}, token \\ "", token_secret \\ "") do
    creds =
      OAuther.credentials(
        consumer_key: consumer_key,
        consumer_secret: consumer_secret,
        token: token,
        token_secret: token_secret
      )

    {header, params} =
      "get"
      |> OAuther.sign(url, extraparams, creds)
      |> OAuther.header()

    response = HTTPoison.get(url, [header, {"Accept", "application/json"}], params: params)

    response
    |> decode_body()
  end

  def decode_body({:ok, response}) do
    content_type =
      Enum.find_value(response.headers, fn
        {"content-type", val} -> val
        _ -> nil
      end)

    case content_type do
      "application/json" <> _ ->
        json_body = Ueberauth.json_library().decode!(response.body)
        json_response = %{response | body: json_body}
        {:ok, json_response}

      _ ->
        {:ok, response}
    end
  end

  def decode_body(other), do: other

  def params_decode(resp) do
    URI.decode_query(resp)
  end

  def token(params) do
    params["oauth_token"]
  end

  def token_secret(params) do
    params["oauth_token_secret"]
  end
end
