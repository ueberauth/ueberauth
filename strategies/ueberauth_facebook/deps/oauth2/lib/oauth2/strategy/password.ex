defmodule OAuth2.Strategy.Password do
  @moduledoc """
  The Resource Owner Password Credentials Authorization Strategy.

  http://tools.ietf.org/html/rfc6749#section-1.3.3

  The resource owner password credentials (i.e., username and password)
  can be used directly as an authorization grant to obtain an access
  token. The credentials should only be used when there is a high
  degree of trust between the resource owner and the client (e.g., the
  client is part of the device operating system or a highly privileged
  application), and when other authorization grant types are not
  available (such as an authorization code).

  Even though this grant type requires direct client access to the
  resource owner credentials, the resource owner credentials are used
  for a single request and are exchanged for an access token. This
  grant type can eliminate the need for the client to store the
  resource owner credentials for future use, by exchanging the
  credentials with a long-lived access token or refresh token.
  """

  use OAuth2.Strategy

  @doc """
  Not used for this strategy.
  """
  @impl true
  def authorize_url(_client, _params) do
    raise OAuth2.Error, reason: "This strategy does not implement `authorize_url`."
  end

  @doc """
  Retrieve an access token given the specified End User username and password.
  """
  @impl true
  def get_token(client, params, headers) do
    {username, params} = Keyword.pop(params, :username, client.params["username"])
    {password, params} = Keyword.pop(params, :password, client.params["password"])

    unless username && password do
      raise OAuth2.Error,
        reason: "Missing required keys `username` and `password` for #{inspect(__MODULE__)}"
    end

    client
    |> put_param(:username, username)
    |> put_param(:password, password)
    |> put_param(:grant_type, "password")
    |> merge_params(params)
    |> basic_auth()
    |> put_headers(headers)
  end
end
