defmodule Ueberauth.Strategy.Github do
  @moduledoc """
  Provides an Ueberauth strategy for authenticating with Github.

  ### Setup

  Create an application in Github for you to use.

  Register a new application at: [your github developer page](https://github.com/settings/developers) and get the `client_id` and `client_secret`.

  Include the provider in your configuration for Ueberauth

      config :ueberauth, Ueberauth,
        providers: [
          github: { Ueberauth.Strategy.Github, [] }
        ]

  Then include the configuration for github.

      config :ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: System.get_env("GITHUB_CLIENT_ID"),
        client_secret: System.get_env("GITHUB_CLIENT_SECRET")

  If you haven't already, create a pipeline and setup routes for your callback handler

      pipeline :auth do
        Ueberauth.plug "/auth"
      end

      scope "/auth" do
        pipe_through [:browser, :auth]

        get "/:provider/callback", AuthController, :callback
      end


  Create an endpoint for the callback where you will handle the `Ueberauth.Auth` struct

      defmodule MyApp.AuthController do
        use MyApp.Web, :controller

        def callback_phase(%{ assigns: %{ ueberauth_failure: fails } } = conn, _params) do
          # do things with the failure
        end

        def callback_phase(%{ assigns: %{ ueberauth_auth: auth } } = conn, params) do
          # do things with the auth
        end
      end

  You can edit the behaviour of the Strategy by including some options when you register your provider.

  To set the `uid_field`

      config :ueberauth, Ueberauth,
        providers: [
          github: { Ueberauth.Strategy.Github, [uid_field: :email] }
        ]

  Default is `:id`

  To set the default 'scopes' (permissions):

      config :ueberauth, Ueberauth,
        providers: [
          github: { Ueberauth.Strategy.Github, [default_scope: "user,public_repo"] }
        ]

  Default is empty ("") which "Grants read-only access to public information (includes public user profile info, public repository info, and gists)"
  """
  @behaviour Ueberauth.Strategy

  import Ueberauth.Strategy.Helpers

  alias Ueberauth.{
    Auth,
    Auth.Info,
    Auth.Credentials,
    Auth.Extra
  }

  @default_uid_field :id
  @default_scope ""
  @oauth2_module __MODULE__.OAuth

  @defaults [
    uid_field: @default_uid_field,
    scope: @default_scope,
    oauth2_module: @oauth2_module
  ]

  @type challenge_params :: %{
          required(:callback_url) => String.t(),
          optional(:conn) => Plug.Conn.t(),
          optional(:scope) => String.t(),
          optional(:state) => String.t()
        }

  @type options :: [
          {:send_redirect_url, boolean},
          {:client_id, String.t()},
          {:client_secret, String.t()},
          {:oauth2_module, module},
          {:scope, String.t()},
          {:uid_field, atom | (Auth.t() -> String.t())}
        ]

  @type authenticate_params :: %{
          optional(:code) => String.t(),
          optional(:state) => String.t()
        }

  @spec challenge(challenge_params, options) :: {:ok, URI.t()} | {:error, any}
  @doc """
  Handles the initial redirect to the github authentication page.

  To customize the scope (permissions) that are requested by github include them as part of your url:

      "/auth/github?scope=user,public_repo,gist"

  You can also include a `state` param that github will return to you.
  """
  @impl true
  def challenge(%{conn: conn} = params, opts) do
    params
    |> Map.drop([:conn])
    |> put_non_nil(:scope, conn.params["scope"])
    |> put_non_nil(:state, conn.params["state"])
    |> challenge(opts)
  end

  @impl true
  def challenge(%{callback_url: url} = params, opts) do
    opts = opts ++ @defaults

    with {:ok, _} <- validate_options(opts, [:client_id, :client_secret]) do
      scopes = Map.get(params, :scope, Keyword.get(opts, :scope))
      send_redirect_uri = Keyword.get(opts, :send_redirect_uri, true)
      mod = Keyword.get(opts, :oauth2_module, @oauth2_module)

      query_params =
        if send_redirect_uri do
          [redirect_uri: url, scope: scopes]
        else
          [scope: scopes]
        end

      authorization_url =
        query_params
        |> put_non_nil(:state, Map.get(params, :state))
        |> mod.authorize_url!(opts)
        |> URI.parse()

      {:ok, authorization_url}
    end
  end

  @impl true
  def challenge(_, _), do: {:error, :invalid_params}

  @impl true
  @spec authenticate(Ueberauth.Strategy.provider_name(), authenticate_params, options) ::
          {:ok, Auth.t()} | {:error, Failure.t()}
  def authenticate(provider, %{query: %{"code" => _code} = params}, opts) do
    params = map_string_to_atom(params, [:code, :state])
    authenticate(provider, params, opts)
  end

  @impl true
  def authenticate(provider, params, opts) do
    opts = opts ++ @defaults

    with {:ok, _} <- validate_options(opts, [:client_id, :client_secret]) do
      module = Keyword.get(opts, :oauth2_module, @oauth2_module)
      state = Map.get(params, :state)

      with {:token_params, {:ok, token_params}} <-
             {:token_params, fetch_token_params(params, opts)},
           {:token, token} <- module.get_token!(token_params, opts),
           {:access_token, token, at} when not is_nil(at) <-
             {:access_token, token, token.access_token},
           {:state_match, true} <- {:state_match, token_state_matches?(token, state)} do
        token
        |> fetch_user(opts)
        |> build_auth_from_user(token, provider, opts)
      else
        {:token_params, {:error, _}} ->
          {:error,
           create_failure(provider, __MODULE__, [error("missing_code", "No code received")])}

        {:access_token, token, nil} ->
          {:error,
           create_failure(
             provider,
             __MODULE__,
             [error(token.other_params["error"], token.other_params["error_description"])]
           )}

        {:state_match, false} ->
          {:error,
           create_failure(provider, __MODULE__, [error("state_mismatch", "State does not match")])}
      end
    end
  end

  defp fetch_token_params(%{code: code}, _opts), do: {:ok, [code: code]}
  defp fetch_token_params(_, _opts), do: {:error, "missing code param"}

  defp token_state_matches?(token, expected_state) do
    state = token.other_params["state"]

    case {state, expected_state} do
      {a, b} when a in ["", nil] and b in ["", nil] -> true
      {a, a} -> true
      _ -> false
    end
  end

  defp build_auth_from_user({:error, error}, _, provider, _opts),
    do: {:error, create_failure(provider, __MODULE__, [error])}

  defp build_auth_from_user({:ok, user}, token, provider, opts) do
    auth = %Auth{
      uid: fetch_uid_field(user, opts),
      provider: provider,
      strategy: __MODULE__,
      credentials: build_credentials(token),
      info: build_info(user),
      extra: build_extra(user, token)
    }

    {:ok, auth}
  end

  defp fetch_uid_field(user, opts) do
    opts
    |> Keyword.get(:uid_field, @default_uid_field)
    |> to_string()
    |> fetch_uid(user)
  end

  defp build_credentials(%{other_params: others} = token) do
    scopes =
      others
      |> Map.get("scope", "")
      |> String.split(",")

    %Credentials{
      expires: not is_nil(token.expires_at),
      expires_at: token.expires_at,
      refresh_token: token.refresh_token,
      scopes: scopes,
      token: token.access_token,
      token_type: token.token_type
    }
  end

  defp build_info(user) do
    %Info{
      name: user["name"],
      description: user["bio"],
      nickname: user["login"],
      email: fetch_email!(user),
      location: user["location"],
      image: user["avatar_url"],
      urls: %{
        followers_url: user["followers_url"],
        avatar_url: user["avatar_url"],
        events_url: user["events_url"],
        starred_url: user["starred_url"],
        blog: user["blog"],
        subscriptions_url: user["subscriptions_url"],
        organizations_url: user["organizations_url"],
        gists_url: user["gists_url"],
        following_url: user["following_url"],
        api_url: user["url"],
        html_url: user["html_url"],
        received_events_url: user["received_events_url"],
        repos_url: user["repos_url"]
      }
    }
  end

  defp build_extra(user, token) do
    %Extra{
      raw_info: %{
        token: token,
        user: user
      }
    }
  end

  defp fetch_uid("email", user) do
    # private email will not be available as :email and must be fetched
    fetch_email!(user)
  end

  defp fetch_uid(field, user) do
    Map.get(user, field)
  end

  defp fetch_email!(user) do
    user["email"] || get_primary_email!(user)
  end

  defp get_primary_email!(user) do
    unless user["emails"] && Enum.count(user["emails"]) > 0 do
      raise "Unable to access the user's email address"
    end

    Enum.find(user["emails"], & &1["primary"])["email"]
  end

  defp fetch_user(token, opts) do
    with {:ok, %OAuth2.Response{status_code: status_code, body: user}}
         when status_code in 200..299 <- __MODULE__.OAuth.get(token, "/user", [], opts) do
      with {:ok, %OAuth2.Response{status_code: status_code, body: emails}}
           when status_code in 200..299 <- __MODULE__.OAuth.get(token, "/user/emails", [], opts) do
        {:ok, Map.put(user, "emails", emails)}
      else
        _ -> {:ok, user}
      end
    else
      {:ok, %OAuth2.Response{status_code: 401}} ->
        {:error, error("token", "unauthorized")}

      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, error("OAuth2", reason)}
    end
  end
end
