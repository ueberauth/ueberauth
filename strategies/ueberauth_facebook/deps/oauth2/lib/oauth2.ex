defmodule OAuth2 do
  @moduledoc """
  The OAuth2 specification

  [RFC6749](http://tools.ietf.org/html/rfc6749)

  The OAuth 2.0 authorization framework enables a third-party
  application to obtain limited access to an HTTP service, either on
  behalf of a resource owner by orchestrating an approval interaction
  between the resource owner and the HTTP service, or by allowing the
  third-party application to obtain access on its own behalf.

  ## API

  Currently implemented strategies:

  - Authorization Code
  - Password
  - Client Credentials

  ### Authorization Code Flow (AuthCode Strategy)

  Initialize a client with your `client_id`, `client_secret`, and `site`.

      client = OAuth2.Client.new([
        strategy: OAuth2.Strategy.AuthCode, # default strategy is AuthCode
        client_id: "client_id",
        client_secret: "abc123",
        site: "https://auth.example.com",
        redirect_uri: "https://example.com/auth/callback"
      ])

  Generate the authorization URL and redirect the user to the provider.

      OAuth2.Client.authorize_url(client)
      # => "https://auth.example.com/oauth/authorize?client_id=client_id&redirect_uri=https%3A%2F%2Fexample.com%2Fauth%2Fcallback&response_type=code"

  Use the authorization code returned from the provider to obtain an access token.

      client = OAuth2.Client.get_token!(client, code: "someauthcode")

  Use the access token to make a request for resources

      resource = OAuth2.Client.get!(client, "/api/resource").body
  """
end
