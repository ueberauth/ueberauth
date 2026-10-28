defmodule OAuth2.Strategy do
  @moduledoc ~S"""
  The OAuth2 strategy specification.

  This module defines the required callbacks for all strategies.

  ## Examples

  Here's an example strategy for authenticating with GitHub.

      defmodule GitHub do
        use OAuth2.Strategy

        # Public API

        def new do
          OAuth2.Client.new([
            strategy: __MODULE__,
            client_id: "abc123",
            client_secret: "abcdefg",
            redirect_uri: "http://myapp.com/auth/callback",
            site: "https://api.github.com",
            authorize_url: "https://github.com/login/oauth/authorize",
            token_url: "https://github.com/login/oauth/access_token"
          ])
        end

        def authorize_url!(params \\ []) do
          new()
          |> put_param(:scope, "user,public_repo")
          |> OAuth2.Client.authorize_url!(params)
        end

        def get_token!(params \\ [], headers \\ []) do
          OAuth2.Client.get_token!(new(), params, headers)
        end

        # Strategy Callbacks

        def authorize_url(client, params) do
          OAuth2.Strategy.AuthCode.authorize_url(client, params)
        end

        def get_token(client, params, headers) do
          client
          |> put_header("Accept", "application/json")
          |> OAuth2.Strategy.AuthCode.get_token(params, headers)
        end
      end

  ## Usage

  Generate the authorize URL and redirect the client for authorization.

      GitHub.authorize_url!

  Capture the `code` in your callback route on your server and use it to obtain an access token.

      token = GitHub.get_token!(code: code)

  Use the access token to access desired resources.

      user = OAuth2.AccessToken.get!(token, "/user")
  """

  alias OAuth2.Client

  @doc """
  Builds the URL to the authorization endpoint.

  ## Example

      def authorize_url(client, params) do
        client
        |> put_param(:response_type, "code")
        |> put_param(:client_id, client.client_id)
        |> put_param(:redirect_uri, client.redirect_uri)
        |> merge_params(params)
      end
  """
  @callback authorize_url(Client.t(), Client.params()) :: Client.t()

  @doc """
  Builds the URL to the token endpoint.

  ## Example

      def get_token(client, params, headers) do
        client
        |> put_param(:code, params[:code])
        |> put_param(:grant_type, "authorization_code")
        |> put_param(:client_id, client.client_id)
        |> put_param(:client_secret, client.client_secret)
        |> put_param(:redirect_uri, client.redirect_uri)
        |> merge_params(params)
        |> put_headers(headers)
      end
  """
  @callback get_token(Client.t(), Client.params(), Client.headers()) :: Client.t()

  defmacro __using__(_) do
    quote do
      @behaviour OAuth2.Strategy
      import OAuth2.Client
    end
  end
end
