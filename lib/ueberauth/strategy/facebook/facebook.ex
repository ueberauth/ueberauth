defmodule Ueberauth.Strategy.Facebook do
  @moduledoc """
  Facebook Strategy for Überauth.

  See https://developers.facebook.com/docs/facebook-login/manually-build-a-login-flow
  """

  @behaviour Ueberauth.Strategy

  import Ueberauth.Strategy.Helpers

  alias Ueberauth.{
    Auth,
    Auth.Credentials,
    Auth.Extra,
    Auth.Info,
    Failure.Error
  }

  @defaults [
    scope: "email,public_profile",
    profile_fields: "id,email,gender,link,locale,name,timezone,updated_time,verified",
    uid_field: :id,
    allowed_request_params: [
      :auth_type,
      :scope,
      :locale,
      :state,
      :display
    ]
  ]

  @type challenge_params :: %{
          required(:callback_url) => String.t(),
          optional(:conn) => Plug.Conn.t(),
          optional(:auth_type) => String.t(),
          optional(:display) => String.t(),
          optional(:locale) => String.t(),
          optional(:scope) => String.t(),
          optional(:state) => String.t(),
          optional(atom) => String.t()
        }

  @type options :: [
          {:client_id, String.t()},
          {:client_secret, String.t()},
          {:oauth2_module, module},
          {:scope, String.t()},
          {:profile_fields, String.t()},
          {:uid_field, atom | (Auth.t() -> String.t())},
          {:allowed_request_params, [atom]},
          {:response_type, String.t()}
        ]

  @type authenticate_params :: %{
          optional(:callback_url) => String.t(),
          optional(:code) => String.t(),
          optional(:token) => String.t(),
          optional(:state) => String.t()
        }

  @impl true
  @spec challenge(challenge_params, options) :: {:ok, URI.t()} | {:error, any}
  @doc """
  Handles the initial redirect to the facebook authentication page.
  """
  def challenge(%{callback_url: url, conn: conn}, opts) do
    opts = opts ++ @defaults
    allowed_params = Keyword.get(opts, :allowed_request_params)

    conn.params
    |> map_string_to_atom(allowed_params)
    |> Map.take(allowed_params)
    |> Map.put(:callback_url, url)
    |> challenge(opts)
  end

  @impl true
  def challenge(%{callback_url: url} = params, opts) do
    opts = opts ++ @defaults

    with {:ok, _} <- validate_options(opts, [:client_id]) do
      allowed_params = Keyword.get(opts, :allowed_request_params)
      param_opts = Enum.into(params, []) ++ opts

      uri =
        param_opts
        |> Keyword.take(allowed_params)
        |> put_non_nil(:response_type, Keyword.get(opts, :response_type))
        |> Keyword.put(:redirect_uri, url)
        |> __MODULE__.OAuth.authorize_url!(opts)
        |> URI.parse()

      {:ok, uri}
    end
  end

  def challenge(_, _), do: {:error, :invalid_params}

  @impl true
  @spec authenticate(Ueberauth.Strategy.provider_name(), authenticate_params, options) ::
          {:ok, Auth.t()} | {:error, Failure.t()}
  def authenticate(provider, %{query: params, conn: conn}, opts) do
    callback_uri = %{request_uri(conn) | query: nil}

    params =
      params
      |> map_string_to_atom([
        :code,
        :token,
        :state,
        :granted_scopes,
        :error,
        :error_reason,
        :error_description
      ])
      |> Map.put(:callback_url, to_string(callback_uri))

    authenticate(provider, params, opts)
  end

  def authenticate(provider, %{error: _err, error_reason: reason, error_description: desc}, _),
    do: {:error, create_failure(provider, __MODULE__, [error(reason, desc)])}

  def authenticate(provider, %{callback_url: _url, code: _code} = params, opts) do
    opts = opts ++ @defaults

    with {:ok, _} <- validate_options(opts, [:client_id, :client_secret]),
         {:token, %{access_token: at} = token} when not is_nil(at) <-
           {:token, exchange_code_for_token(params, opts)},
         {:user, {:ok, user}} <- {:user, fetch_user(token, opts)} do
      {:ok, construct_auth(provider, token, user, opts)}
    else
      {:token, token} ->
        {:error,
         create_failure(provider, __MODULE__, [
           error(token.other_params["error"], token.other_params["error_description"])
         ])}

      {_, {:error, %Error{} = err}} ->
        {:error, create_failure(provider, __MODULE__, [err])}

      {:error, %Error{} = err} ->
        {:error, create_failure(provider, __MODULE__, [err])}

      {:error, reason} ->
        {:error, create_failure(provider, __MODULE__, [error("unkonwn_error", reason)])}
    end
  end

  def authenticate(provider, %{token: access_token}, opts) when not is_nil(access_token) do
    opts = opts ++ @defaults
    token = OAuth2.AccessToken.new(access_token)

    with {:ok, _} <- validate_options(opts, [:client_id, :client_secret]),
         {:user, user} <- fetch_user(token, opts) do
      {:ok, construct_auth(provider, token, user, opts)}
    else
      {:user, {:error, %Error{} = err}} ->
        {:errro, create_failure(provider, __MODULE__, [err])}

      {:error, %Error{} = err} ->
        {:error, create_failure(provider, __MODULE__, [err])}

      {:error, reason} ->
        {:error, create_failure(provider, __MODULE__, [error("unknown_error", reason)])}
    end
  end

  def authenticate(provider, _, _opts),
    do: {:error, create_failure(provider, __MODULE__, [error("OAuth2", "invalid params")])}

  defp construct_auth(provider, token, user, opts) do
    auth = %Auth{
      provider: provider,
      strategy: __MODULE__,
      credentials: credentials(token),
      info: info(user),
      extra: extra(token, user)
    }

    apply_uid(auth, opts)
  end

  defp exchange_code_for_token(%{callback_url: url, code: code}, opts) do
    [code: code, redirect_uri: url]
    |> Ueberauth.Strategy.Facebook.OAuth.get_token!(opts)
    |> Map.get(:token)
  end

  defp fetch_user(token, opts) do
    client = __MODULE__.OAuth.client([token: token] ++ opts)

    query = user_query(token, opts)

    path = "/me?#{query}"

    case OAuth2.Client.get(client, path) do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        {:error, error("token", "unauthorized")}

      {:ok, %OAuth2.Response{status_code: status_code, body: user}}
      when status_code in 200..399 ->
        {:ok, user}

      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, error("OAuth2", reason)}
    end
  end

  defp apply_uid(auth, opts) do
    uid =
      case Keyword.get(opts, :uid_field) do
        f when is_function(f) ->
          f.(auth)

        f ->
          Map.get(auth.extra.raw_info.user, to_string(f))
      end

    %{auth | uid: uid}
  end

  defp credentials(token) do
    scopes =
      token
      |> Map.get("scope", "")
      |> String.split(",")

    %Credentials{
      expires: not is_nil(token.expires_at),
      expires_at: token.expires_at,
      scopes: scopes,
      token: token.access_token
    }
  end

  defp info(user) do
    %Info{
      description: user["bio"],
      email: user["email"],
      first_name: user["first_name"],
      image: fetch_image(user["id"]),
      last_name: user["last_name"],
      name: user["name"],
      urls: %{
        facebook: user["link"],
        website: user["website"]
      }
    }
  end

  def extra(token, user) do
    %Extra{
      raw_info: %{
        token: token,
        user: user
      }
    }
  end

  defp fetch_image(uid) do
    "https://graph.facebook.com/#{uid}/picture?type=square"
  end

  defp user_query(token, opts) do
    %{"appsecret_proof" => appsecret_proof(token, opts)}
    |> Map.merge(query_params(:locale, opts))
    |> Map.merge(query_params(:profile, opts))
    |> URI.encode_query()
  end

  defp appsecret_proof(token, opts) do
    client_secret = Keyword.get(opts, :client_secret)

    token.access_token
    |> hmac(:sha256, client_secret)
    |> Base.encode16(case: :lower)
  end

  defp hmac(data, type, key) do
    :crypto.hmac(type, key, data)
  end

  defp query_params(:profile, opts) do
    %{"fields" => Keyword.get(opts, :profile_fields)}
  end

  defp query_params(:locale, opts) do
    case Keyword.get(opts, :locale) do
      nil -> %{}
      locale -> %{"locale" => locale}
    end
  end
end
