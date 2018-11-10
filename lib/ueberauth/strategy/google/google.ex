defmodule Ueberauth.Strategy.Google do
  @behaviour Ueberauth.Strategy

  require Logger

  import Ueberauth.Strategy.Helpers

  alias Ueberauth.{
    Auth,
    Auth.Credentials,
    Auth.Info,
    Auth.Extra,
    Strategy.Helpers
  }

  @default_scope "email"
  @uid_field :sub

  # handle plug based request
  def challenge(%{callback_url: url, conn: conn}, opts) do
    scopes = conn.params["scope"] || Keyword.get(opts, :scope, @default_scope)

    %{scope: scopes, callback_url: url}
    |> put_non_nil(:access_type, conn.params["access_type"])
    |> put_non_nil(:prompt, conn.params["prompt"])
    |> put_non_nil(:state, conn.params["state"])
    |> challenge(opts)
  end

  # handle in-app request url call
  def challenge(%{callback_url: url} = params, opts) do
    with {:ok, _} <- validate_options(opts, [:client_id, :client_secret]) do
      scopes =
        params
        |> Map.get(:scope, Keyword.get(opts, :scope, @default_scope))

      params =
        [scope: scopes]
        |> put_non_nil(:hd, Keyword.get(opts, :hd))
        |> put_non_nil(:prompt, Keyword.get(opts, :prompt))
        |> put_non_nil(:access_type, Keyword.get(opts, :access_type))
        |> put_non_nil(:hd, Map.get(params, :hd))
        |> put_non_nil(:state, Map.get(params, :state))
        |> put_non_nil(:prompt, Map.get(params, :prompt))
        |> put_non_nil(:access_type, Map.get(params, :access_type))

      url =
        opts
        |> Keyword.put(:redirect_uri, url)
        |> __MODULE__.OAuth.client()
        |> __MODULE__.OAuth.authorize_url(params)
        |> URI.parse()

      {:ok, url}
    end
  end

  def challenge(_, _), do: {:error, :invalid_params}

  def authenticate(provider, %{query: %{"code" => code}}, opts),
    do: authenticate(provider, %{code: code}, opts)

  def authenticate(provider, %{query: %{"token" => token}}, opts),
    do: authenticate(provider, %{token: token}, opts)

  def authenticate(provider, params, opts) do
    with {:ok, _} <- validate_options(opts, [:client_id, :client_secret]) do
      params =
        params
        |> Map.take([:code, :token])
        |> Enum.into([])

      with {:access, {:ok, token}} <- {:access, __MODULE__.OAuth.get_access_token(params, opts)},
           {:user, {:ok, user}} <- {:user, fetch_user(token, opts)} do
        {:ok, auth(provider, token, user, opts)}
      else
        {:access, {:error, {error_code, error_description}}} ->
          {:error,
           Helpers.create_failure(provider, __MODULE__, [
             Helpers.error(error_code, error_description)
           ])}

        {:user, {:error, error}} ->
          Logger.warn("[#{__MODULE__}] could not fetch user #{inspect(error)}")

          {:error,
           Helpers.create_failure(provider, __MODULE__, [
             Helpers.error("user_lookup_error", "could not lookup user")
           ])}
      end
    end
  end

  defp fetch_user(token, _opts) do
    # userinfo_endpoint from https://accounts.google.com/.well-known/openid-configuration
    path = "https://www.googleapis.com/oauth2/v3/userinfo"
    resp = Ueberauth.Strategy.Google.OAuth.get(token, path)

    case resp do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        {:error, Helpers.error("token", "unauthorized")}

      {:ok, %OAuth2.Response{status_code: status_code, body: user}}
      when status_code in 200..399 ->
        {:ok, user}

      {:error, %OAuth2.Response{status_code: status_code}} ->
        {:error, Helpers.error("OAuth2", status_code)}

      {:error, %OAuth2.Error{reason: reason}} ->
        {:error, Helpers.error("OAuth2", reason)}
    end
  end

  defp auth(provider, token, user, opts) do
    scopes =
      token.other_params
      |> Map.get("scope", "")
      |> String.split(",")

    auth = %Auth{
      provider: provider,
      credentials: %Credentials{
        expires: !!token.expires_at,
        expires_at: token.expires_at,
        scopes: scopes,
        token_type: Map.get(token, :token_type),
        refresh_token: token.refresh_token,
        token: token.access_token
      },
      info: %Info{
        email: user["email"],
        first_name: user["given_name"],
        image: user["picture"],
        last_name: user["family_name"],
        name: user["name"],
        urls: %{
          profile: user["profile"],
          website: user["hd"]
        }
      },
      extra: %Extra{
        raw_info: %{
          token: token,
          user: user
        }
      }
    }

    %{auth | uid: resolve_uid(auth, opts)}
  end

  defp resolve_uid(auth, opts) do
    case Keyword.get(opts, :uid_field, @uid_field) do
      f when is_atom(f) ->
        Map.get(auth.extra.raw_info.user, f)

      f when is_function(f) ->
        f.(auth)
    end
  end
end
