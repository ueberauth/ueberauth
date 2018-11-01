defmodule Ueberauth.Strategy.Slack do
  @moduledoc """
  Implements an ÜeberauthSlack strategy for authentication with slack.com.

  When configuring the strategy in the Üeberauth providers, you can specify some defaults.

  * `uid_field` - The field to use as the UID field. This can be any populated field in the info struct. Default `:email`
  * `default_scope` - The scope to request by default from slack (permissions). Default "users:read"
  * `oauth2_module` - The OAuth2 module to use. Default Ueberauth.Strategy.Slack.OAuth

  ````elixir

  config :ueberauth, Ueberauth,
    providers: [
      slack: { Ueberauth.Strategy.Slack, [uid_field: :nickname, default_scope: "users:read,users:write"] }
    ]
  """

  @behaviour Ueberauth.Stragtegy

  @type challenge_url_params :: %{
    required(:callback_url) => String.t,
    optional(:conn) => Plug.Conn.t,
    optional(:scope) => String.t,
    optional(:state) => String.t,
  }

  @type options :: [
    {:client_id, String.t},
    {:client_secret, String.t},
    {:oauth2_module, module},
    {:scope, String.t},
    {:team, String.t},
  ]

  @type authenticate_params :: %{
    required(:callback_url) => String.t,
    optional(:conn) => Plug.Conn.t,
    optional(:code) => String.t,
    optional(:state) => String.t,
  }

  @defaults [
    uid_field: :email,
    default_scope: "users:read",
    oauth2_module: __MODULE__.OAuth,
  ]

  import Ueberauth.Strategy.Helpers

  alias Ueberauth.{
    Auth,
    Auth.Info,
    Auth.Credentials,
    Auth.Extra,
  }

  @spec challenge_url(request_url_params, options) :: String.t
  def challenge_url(%{conn: conn} = params, opts) do
    opts = opts ++ @defaults
    scope = conn.params["scope"] || Keyword.get(opts, :default_scope, @default_scope)
    state = conn.params["state"] || Keyword.get(opts, :state)

    params
    |> put_non_nil(:scope, scope)
    |> put_non_nil(:state, state)
    |> put_non_nil(:team, Keyword.get(opts, :team))
    |> challenge_url(opts)
  end

  def challenge_url(%{callback_url: url} = params, opts) do
    opts = opts ++ @defaults
    scopes = Map.get(params, :scope, Keyword.get(opts, :default_scope, @default_scope))
    params = Map.put(params, :scope, scopes)


    call_opts =
      params
      |> Map.take([:scope, :state, :team])
      |> Enum.into([])
      |> Keyword.put(:redirect_uri, callback_url)
      |> Keyword.put(:client_id, Keyword.get(opts, :client_id))

    module = Keyword.get(opts, :oauth2_module)

    case validate_options(call_opts, [:client_id, :redirect_uri]) do
      {:ok, copts} -> {:ok, module.authorize_url!(copts, opts)}
      {:error, _reason} = err -> err
    end
  end

  @spec authenticate(Ueberauth.Strategy.provider_name, authenticate_params, options) :: {:ok, Auth.t} | {:error, Failure.t}
  def authenticate(provider, %{conn: conn, query: %{"code" => _code} = params}, opts) do
    params =
      params
      |> map_string_to_atom([:state, :code])
      |> put_non_nil(:callback_url, conn.request_url)

    authenticate(provider, params, opts)
  end

  def authenticate(provider, %{code: code, callback_url: url} = params, opts) do
    opts = opts ++ @defaults
    module = Keyword.get(opts, :oauth2_module)

    case validate_options(opts, [:client_id, :client_secret]) do
      {:ok, _} ->
        token =
          params
          |> Map.take([:code])
          |> put_non_nil(:redirect_uri, url)
          |> put_non_nil(:client_id, Keyword.get(opts, :client_id))
          |> put_non_nil(:client_secret, Keyword.get(opts, :client_secret))
          |> module.get_token!(opts)

        with {:access_token, token, at} when not is_nil(at) <- token.access_token,
             {:fetch_auth, slack_auth} <- fetch_auth(token, opts)

    end

    call_opts = Map.take(params, [:code])

  end

  def authenticate(provider, _, opts) do
    {:error, create_failure(provider, __MODULE__, [error(:invalid_callback_params, "invalid callback params")])}
  end

  # When handling the callback, if there was no errors we need to
  # make two calls. The first, to fetch the slack auth is so that we can get hold of
  # the user id so we can make a query to fetch the user info.
  # So that it is available later to build the auth struct, we put it in the private section of the conn.
  @doc false
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    module  = option(conn, :oauth2_module)


    params  = [code: code]
    redirect_uri = get_redirect_uri(conn)
    options = %{
      options: [
        client_options: [redirect_uri: redirect_uri]
      ]
    }
    token = apply(module, :get_token!, [params, options])

    if token.access_token == nil do
      set_errors!(conn, [error(token.other_params["error"], token.other_params["error_description"])])
    else
      conn
      |> store_token(token)
      |> fetch_auth(token)
      |> fetch_user(token)
      |> fetch_team(token)
    end
  end

  # If we don't match code, then we have an issue
  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  # We store the token for use later when fetching the slack auth and user and constructing the auth struct.
  @doc false
  defp store_token(conn, token) do
    put_private(conn, :slack_token, token)
  end

  # Remove the temporary storage in the conn for our data. Run after the auth struct has been built.
  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:slack_auth, nil)
    |> put_private(:slack_user, nil)
    |> put_private(:slack_token, nil)
  end

  # The structure of the requests is such that it is difficult to provide cusomization for the uid field.
  # instead, we allow selecting any field from the info struct
  @doc false
  def uid(conn) do
    Map.get(info(conn), option(conn, :uid_field))
  end

  @doc false
  def credentials(conn) do
    token        = conn.private.slack_token
    auth         = conn.private.slack_auth
    user         = conn.private[:slack_user]
    scope_string = (token.other_params["scope"] || "")
    scopes       = String.split(scope_string, ",")

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: token.expires_at,
      token_type: token.token_type,
      expires: !!token.expires_at,
      scopes: scopes,
      other: Map.merge(%{
        user: auth["user"],
        user_id: auth["user_id"],
        team: auth["team"],
        team_id: auth["team_id"],
        team_url: auth["url"],
      }, user_credentials(user))
    }
  end

  @doc false
  def info(conn) do
    user = conn.private[:slack_user]
    auth = conn.private.slack_auth
    image_urls = (user["profile"] || %{})
    |> Map.keys
    |> Enum.filter(&(&1 =~ ~r/^image_/))
    |> Enum.map(&({&1, user["profile"][&1]}))
    |> Enum.into(%{})

    %Info{
      name: name_from_user(user),
      nickname: user["name"],
      email: user["profile"]["email"],
      image: user["profile"]["image_48"],
      urls: Map.merge(
        image_urls,
        %{
          team_url: auth["url"],
        }
      )
    }
  end

  @doc false
  def extra(conn) do
    %Extra {
      raw_info: %{
        auth: conn.private[:slack_auth],
        token: conn.private[:slack_token],
        user: conn.private[:slack_user],
        team: conn.private[:slack_team]
      }
    }
  end

  defp user_credentials(nil), do: %{}
  defp user_credentials(user) do
    %{has_2fa: user["has_2fa"],
      is_admin: user["is_admin"],
      is_owner: user["is_owner"],
      is_primary_owner: user["is_primary_owner"],
      is_restricted: user["is_restricted"],
      is_ultra_restricted: user["is_ultra_restricted"]}
  end

  # Before we can fetch the user, we first need to fetch the auth to find out what the user id is.
  defp fetch_auth(conn, token) do
    case Ueberauth.Strategy.Slack.OAuth.get(token, "/auth.test") do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])
      {:ok, %OAuth2.Response{status_code: status_code, body: auth}} when status_code in 200..399 ->
        if auth["ok"] do
          put_private(conn, :slack_auth, auth)
        else
          set_errors!(conn, [error(auth["error"], auth["error"])])
        end
      {:error, %OAuth2.Error{reason: reason}} ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  # If the call to fetch the auth fails, we're going to have failures already in place.
  # If this happens don't try and fetch the user and just let it fail.
  defp fetch_user(%Plug.Conn{assigns: %{ueberauth_failure: _fails}} = conn, _), do: conn

  # Given the auth and token we can now fetch the user.
  defp fetch_user(conn, token) do
    auth = conn.private.slack_auth
    scope_string = (token.other_params["scope"] || "")
    scopes       = String.split(scope_string, ",")

    case "users:read" in scopes do
      false -> conn
      true ->
        case Ueberauth.Strategy.Slack.OAuth.get(token, "/users.info", %{user: auth["user_id"]}) do
          {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
            set_errors!(conn, [error("token", "unauthorized")])
          {:ok, %OAuth2.Response{status_code: status_code, body: user}} when status_code in 200..399 ->
            if user["ok"] do
              put_private(conn, :slack_user, user["user"])
            else
              set_errors!(conn, [error(user["error"], user["error"])])
            end
          {:error, %OAuth2.Error{reason: reason}} ->
            set_errors!(conn, [error("OAuth2", reason)])
        end
    end
  end

  defp fetch_team(%Plug.Conn{assigns: %{ueberauth_failure: _fails}} = conn, _), do: conn

  defp fetch_team(conn, token) do
    scope_string = (token.other_params["scope"] || "")
    scopes       = String.split(scope_string, ",")

    case "team:read" in scopes do
      false -> conn
      true  ->
        case Ueberauth.Strategy.Slack.OAuth.get(token, "/team.info") do
          {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
            set_errors!(conn, [error("token", "unauthorized")])
          {:ok, %OAuth2.Response{status_code: status_code, body: team}} when status_code in 200..399 ->
            if team["ok"] do
              put_private(conn, :slack_team, team["team"])
            else
              set_errors!(conn, [error(team["error"], team["error"])])
            end
          {:error, %OAuth2.Error{reason: reason}} ->
            set_errors!(conn, [error("OAuth2", reason)])
        end
    end
  end

  # Fetch the name to use. We try to start with the most specific name avaialble and
  # fallback to the least.
  defp name_from_user(user) do
    [
      user["profile"]["real_name_normalized"],
      user["profile"]["real_name"],
      user["real_name"],
      user["name"],
    ]
    |> Enum.reject(&(&1 == "" || &1 == nil))
    |> List.first
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end

  defp get_redirect_uri(%Plug.Conn{} = conn) do
    config = Application.get_env(:ueberauth, Ueberauth)
    redirect_uri = Keyword.get(config, :redirect_uri)

    if is_nil(redirect_uri) do
      callback_url(conn)
    else
      redirect_uri
    end
  end
end
