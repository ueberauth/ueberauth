defmodule Ueberauth.Strategy.Google do
  @behaviour Ueberauth.Strategy

  require Logger

  alias Ueberauth.{
    Auth,
    Auth.Credentials,
    Auth.Info,
    Auth.Extra,
    Strategy.Helpers,
  }

  @default_scope "email"
  @uid_field :sub

  # handle plug based request
  def request_url(%{callback_url: url, conn: conn}, opts) do
    scopes = conn.params["scope"] || Keyword.get(opts, :scope, @default_scope)

    params =
      [scope: scopes]
      |> with_optional(:hd, opts)
      |> with_optional(:prompt, opts)
      |> with_optional(:access_type, opts)
      |> with_param(:access_type, conn)
      |> with_param(:prompt, conn)
      |> with_param(:state, conn)

    (opts ++ [redirect_uri: url])
    |> __MODULE__.OAuth.client()
    |> __MODULE__.OAuth.authorize_url(params)
  end

  # handle in-app request url call
  def request_url(%{callback_url: url} = params, opts) do
    scopes =
      params
      |> Map.get(:scope, Keyword.get(opts, :scope, @default_scope))

    params =
      [scope: scopes]
      |> with_optional(:hd, opts)
      |> with_optional(:prompt, opts)
      |> with_optional(:access_type, opts)
      |> with_param(:access_type, params)
      |> with_param(:prompt, params)
      |> with_param(:state, params)
      |> with_param("access_type", params)
      |> with_param("prompt", params)
      |> with_param("state", params)

    (opts ++ [redirect_uri: url])
    |> __MODULE__.OAuth.client()
    |> __MODULE__.OAuth.authorize_url(params)
  end

  def authenticate(provider, %{query: %{"code" => code}}, opts),
    do: authenticate(provider, %{code: code}, opts)

  def authenticate(provider, %{query: %{"token" => token}}, opts),
    do: authenticate(provider, %{token: token}, opts)

  def authenticate(provider, params, opts) do
    params =
      params
      |> Map.take([:code, :token])
      |> Enum.into([])

    with {:access, {:ok, token}} <- {:access, __MODULE__.OAuth.get_access_token(params, opts)},
         {:user, {:ok, user}} <- {:user, fetch_user(token, opts)} do

      {:ok, auth(provider, token, user, opts)}
    else
      {:access, {:error, {error_code, error_description}}} ->
        {:error, Helpers.create_failure(provider, __MODULE__, [Helpers.error(error_code, error_description)])}
      {:user, {:error, error}} ->
        Logger.warn("[#{__MODULE__}] could not fetch user #{inspect(error)}")
        {:error, Helpers.create_failure(provider, __MODULE__, [Helpers.error("user_lookup_error", "could not lookup user")])}
    end
  end

  defp fetch_user(token, _opts) do
    # userinfo_endpoint from https://accounts.google.com/.well-known/openid-configuration
    path = "https://www.googleapis.com/oauth2/v3/userinfo"
    resp = Ueberauth.Strategy.Google.OAuth.get(token, path)

    case resp do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        {:error, Helpers.error("token", "unauthorized")}
      {:ok, %OAuth2.Response{status_code: status_code, body: user}} when status_code in 200..399 ->
        {:ok, user}
      {:error, %OAuth2.Response{status_code: status_code}} ->
        {:error, Helpers.error("OAuth2", status_code)}
      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, Helpers.error("OAuth2", reason)}
    end
  end

  defp auth(provider, token, user, opts) do
    scopes =
      (token.other_params["scope"] || "")
      |> String.split(",")

    %Auth{
      provider: provider,
      uid: uid(user, opts),
      credentials: %Credentials{
        expires: !!token.expires_at,
        expires_at: token.expires_at,
        scopes: scopes,
        token_type: Map.get(token, :token_type),
        refresh_token: token.refresh_token,
        token: token.access_token,
      },
      info: %Info{
        email: user["email"],
        first_name: user["given_name"],
        image: user["picture"],
        last_name: user["family_name"],
        name: user["name"],
        urls: %{
          profile: user["profile"],
          website: user["hd"],
        }
      },
      extra: %Extra{
        raw_info: %{
          token: token,
          user: user,
        }
      }
    }
  end

  defp uid(user, opts) do
    case Keyword.get(opts, :uid_field, @uid_field) do
      f when is_function(f) -> f.(user)
      f -> Map.get(user, to_string(f))
    end
  end

  defp with_optional(params, key, opts) do
    if Keyword.get(opts, key) do
      Keyword.put(params, key, Keyword.get(opts, key))
    else
      params
    end
  end

  defp with_param(params, key, %Plug.Conn{} = conn) do
    if value = conn.params[to_string(key)] do
      Keyword.put(params, key, value)
    else
      params
    end
  end

  defp with_param(params, key, incomming_params) when is_map(incomming_params) do
    if Map.has_key?(incomming_params, key) do
      Keyword.put(params, key, Map.get(incomming_params, key))
    else
      params
    end
  end
end
