defmodule OAuth2.Strategy.Refresh do
  @moduledoc """
  The Refresh Token Strategy.

  https://tools.ietf.org/html/rfc6749#section-1.5

  Refresh tokens are credentials used to obtain access tokens. Refresh
  tokens are issued to the client by the authorization server and are
  used to obtain a new access token when the current access token
  becomes invalid or expires, or to obtain additional access tokens
  with identical or narrower scope (access tokens may have a shorter
  lifetime and fewer permissions than authorized by the resource
  owner). Issuing a refresh token is optional at the discretion of the
  authorization server. If the authorization server issues a refresh
  token, it is included when issuing an access token.

  A refresh token is a string representing the authorization granted to
  the client by the resource owner. The string is usually opaque to
  the client. The token denotes an identifier used to retrieve the
  authorization information. Unlike access tokens, refresh tokens are
  intended for use only with authorization servers and are never sent
  to resource servers.
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
  Refresh an access token given the specified validation code.
  """
  @impl true
  def get_token(client, params, headers) do
    {token, params} = Keyword.pop(params, :refresh_token, client.params["refresh_token"])

    unless token do
      raise OAuth2.Error,
        reason: "Missing required key `refresh_token` for `#{inspect(__MODULE__)}`"
    end

    client
    |> put_param(:refresh_token, token)
    |> put_param(:grant_type, "refresh_token")
    |> merge_params(params)
    |> basic_auth()
    |> put_headers(headers)
  end
end
