defmodule Ueberauth.Strategy.Slack do
  @moduledoc """
  Implements an ÜeberauthSlack strategy for authentication with slack.com.

  When configuring the strategy in the Üeberauth providers, you can specify some defaults.

  * `uid_field` - The field to use as the UID field. This can be any populated field in the info struct. Default `:email`
  * `default_scope` - The scope to request by default from slack (permissions). Default "users:read"
  * `oauth2_module` - The OAuth2 module to use. Default Ueberauth.Strategy.Slack.OAuth

  ```elixir
  config :ueberauth, Ueberauth,
  providers: [
  slack: { Ueberauth.Strategy.Slack, [uid_field: :nickname, default_scope: "users:read,users:write"] }
  ]
  ```
  """

  @behaviour Ueberauth.Strategy

  @type challenge_params :: %{
    required(:callback_url) => String.t(),
    optional(:conn) => Plug.Conn.t(),
    optional(:scope) => String.t(),
    optional(:state) => String.t()
  }

  @type options :: [
    {:client_id, String.t()},
    {:client_secret, String.t()},
    {:oauth2_module, module},
    {:scope, String.t()},
    {:team, String.t()},
    {:uid_field, atom | (Auth.t() -> String.t())}
  ]

  @type authenticate_params :: %{
    required(:callback_url) => String.t(),
    optional(:conn) => Plug.Conn.t(),
    optional(:code) => String.t(),
    optional(:state) => String.t()
  }

  @default_scope "users:read"

  @defaults [
    uid_field: :email,
    scope: @default_scope,
    oauth2_module: __MODULE__.OAuth
  ]

  import Ueberauth.Strategy.Helpers

  alias Ueberauth.{
    Auth,
    Auth.Info,
    Auth.Credentials,
    Auth.Extra,
    Failure.Error,
    Strategy.Slack.OAuth
  }

  @impl true
  def challenge(%{conn: conn} = params, opts) do
    opts = opts ++ @defaults
    scope = conn.params["scope"] || Keyword.get(opts, :default_scope, @default_scope)
    state = conn.params["state"] || Keyword.get(opts, :state)

    params
    |> put_non_nil(:scope, scope)
    |> put_non_nil(:state, state)
    |> put_non_nil(:team, Keyword.get(opts, :team))
    |> Map.drop([:conn])
    |> challenge(opts)
  end

  @impl true
  def challenge(%{callback_url: callback_url} = params, opts) do
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
      {:ok, copts} ->
        {:ok, copts |> module.authorize_url!(opts) |> URI.parse()}

      {:error, _reason} = err ->
        err
    end
  end

  def challenge(_, _), do: {:error, :invalid_params}

  @impl true
  @spec authenticate(Ueberauth.Strategy.provider_name(), authenticate_params, options) ::
  {:ok, Auth.t()} | {:error, Failure.t()}
  def authenticate(provider, %{conn: conn, query: %{"code" => _code} = params}, opts) do
    auth_url = %{request_uri(conn) | query: nil}

    params =
      params
      |> map_string_to_atom([:state, :code])
      |> put_non_nil(:callback_url, to_string(auth_url))

    authenticate(provider, params, opts)
  end

  @impl true
  def authenticate(provider, %{code: _code, callback_url: url} = params, opts) do
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
          |> Enum.into([])
          |> module.get_token!(opts)

          with {:access_token, token, at} when not is_nil(at) <- {:access_token, token, token.access_token},
               {:fetch_auth, {:ok, slack_auth}} <- {:fetch_auth, fetch_auth(token)},
               {:fetch_user, {:ok, slack_user}} <- {:fetch_user, fetch_user(token, slack_auth)},
               {:fetch_team, {:ok, slack_team}} <- {:fetch_team, fetch_team(token)} do
                 {:ok, construct_auth(provider, token, slack_auth, slack_user, slack_team, opts)}
          else
            {:access_token, token, nil} ->
              {:error,
                create_failure(provider, __MODULE__, [
                  error(token.other_params["error"], token.other_params["error_description"])
                ])}

            {_, {:error, %Error{} = err}} ->
              {:error, create_failure(provider, __MODULE__, [err])}
               end

      {:error, reason} when is_atom(reason) ->
        reason_string = to_string(reason)
        create_failure(provider, __MODULE__, [error(reason, reason_string)])
    end
  end

  def authenticate(provider, _, _opts) do
    {:error,
      create_failure(provider, __MODULE__, [
        error(:invalid_callback_params, "invalid callback params")
      ])}
  end

  defp construct_auth(provider, token, slack_auth, slack_user, slack_team, opts) do
    auth = %Auth{
      provider: provider,
      strategy: __MODULE__,
      credentials: credentials(token, slack_auth, slack_user),
      info: info(slack_auth, slack_user),
      extra: extra(token, slack_auth, slack_user, slack_team)
    }

    apply_uid(auth, opts)
  end

  defp fetch_auth(token) do
    case Ueberauth.Strategy.Slack.OAuth.get(token, "/auth.test") do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        {:error, error("token", "unauthorized")}

        {:ok, %OAuth2.Response{status_code: status_code, body: auth}}
      when status_code in 200..399 ->
        if auth["ok"] do
          {:ok, auth}
        else
          {:error, error(auth["error"], auth["error"])}
        end

      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, error("OAuth2", reason)}
    end
  end

  defp fetch_user(token, %{"user_id" => user_id}) do
    scopes =
      token
      |> Map.get("scope", "")
      |> String.split(",")

    with true <- "users:read" in scopes,
         {:ok, %{status_code: status} = resp} when status in 200..399 <- OAuth.get(token, "/users.info", %{user: user_id}),
         %{"ok" => true, "user" => user} <- Map.get(resp, :body)
    do
      user
    else
      false ->
        {:ok, nil}

      {:ok, %{status_code: 401}} ->
        {:error, error("token", "unauthorized")}

      {:error, %{reason: reason}} ->
        {:error, error("OAuth2", reason)}

      %{"error" => error} ->
        {:error, error("Slack", error)}
    end
  end

  defp fetch_team(token) do
    scopes =
      token
      |> Map.get("scope", "")
      |> String.split(",")

    with true <- "team:read" in scopes,
         {:ok, %{status_code: status} = resp} when status in 200..399 <- OAuth.get(token, "/team.info"),
         %{"ok" => true, "team" => team} <- Map.get(resp, :body)
    do
      team
    else
      false ->
        {:ok, nil}

      {:ok, %{status_code: 401}} ->
        {:error, error("token", "unauthorized")}

      {:error, %{reason: reason}} ->
        {:error, error("OAuth2", reason)}

      %{"error" => error} ->
        {:error, error("Slack", error)}
    end
  end

  defp apply_uid(%Auth{} = auth, opts) do
    field = Keyword.get(opts, :uid_field)

    cond do
      is_atom(field) ->
        %{auth | uid: Map.get(auth.info, field)}

      is_function(field) ->
        uid = apply(field, [auth])
        %{auth | uid: uid}
    end
  end

  @doc false
  def credentials(token, auth, user) do
    scopes =
      token
      |> Map.get("scope", "")
      |> String.split(",")

    %Credentials{
      expires: not is_nil(token.expires_at),
      expires_at: token.expires_at,
      refresh_token: token.refresh_token,
      scopes: scopes,
      token: token.access_token,
      token_type: token.token_type,
      other:
      Map.merge(
        %{
          user: auth["user"],
          user_id: auth["user_id"],
          team: auth["team"],
          team_id: auth["team_id"],
          team_url: auth["url"]
        },
        user_credentials(user)
      )
    }
  end

  @doc false
  def info(auth, nil) do
    %{
      urls: %{
        team_url: auth["url"]
      }
    }
  end

  def info(auth, user) do
    profile = Map.get(user, "profile", %{})

    image_urls =
      profile
      |> Map.keys()
      |> Enum.filter(&(&1 =~ ~r/^image_/))
      |> Enum.into(%{}, &({&1, user["profile"][&1]}))

    %Info{
      name: name_from_user(user),
      nickname: user["name"],
      email: profile["email"],
      image: profile["image_48"],
      urls: Map.merge(
        image_urls,
        %{
          team_url: auth["url"],
        }
      )
    }
  end

  @doc false
  def extra(token, auth, user, team) do
    %Extra{
      raw_info: %{
        auth: auth,
        token: token,
        user: user,
        team: team
      }
    }
  end

  defp user_credentials(nil), do: %{}

  defp user_credentials(user) do
    %{
      has_2fa: user["has_2fa"],
      is_admin: user["is_admin"],
      is_owner: user["is_owner"],
      is_primary_owner: user["is_primary_owner"],
      is_restricted: user["is_restricted"],
      is_ultra_restricted: user["is_ultra_restricted"]
    }
  end

  # Fetch the name to use. We try to start with the most specific name avaialble and
  # fallback to the least.
  defp name_from_user(user) do
    [
      user["profile"]["real_name_normalized"],
      user["profile"]["real_name"],
      user["real_name"],
      user["name"]
    ]
    |> Enum.reject(&(&1 in ["", nil]))
    |> List.first()
  end
end
