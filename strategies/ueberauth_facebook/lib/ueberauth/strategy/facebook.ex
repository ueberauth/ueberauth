defmodule Ueberauth.Strategy.Facebook do
  @moduledoc """
  Facebook Strategy for Überauth.
  """

  use Ueberauth.Strategy,
    default_scope: "email,public_profile",
    profile_fields: "id,email,gender,link,locale,name,timezone,updated_time,verified",
    uid_field: :id,
    allowed_request_params: [
      :auth_type,
      :scope,
      :locale,
      :state,
      :display
    ]

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles initial request for Facebook authentication.
  """
  def handle_request!(conn) do
    allowed_params =
      conn
      |> option(:allowed_request_params)
      |> Enum.map(&to_string/1)

    opts = oauth_client_options_from_conn(conn)

    authorize_url =
      conn.params
      |> maybe_replace_param(conn, "auth_type", :auth_type)
      |> maybe_replace_param(conn, "scope", :default_scope)
      |> maybe_replace_param(conn, "state", :state)
      |> maybe_replace_param(conn, "display", :display)
      |> Enum.filter(fn {k, _v} -> Enum.member?(allowed_params, k) end)
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Keyword.put(:redirect_uri, callback_url(conn))
      |> Ueberauth.Strategy.Facebook.OAuth.authorize_url!(opts)

    redirect!(conn, authorize_url)
  end

  @doc """
  Handles the callback from Facebook.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    opts = oauth_client_options_from_conn(conn)

    config =
      :ueberauth
      |> Application.get_env(Ueberauth.Strategy.Facebook.OAuth, [])
      |> Keyword.merge(opts)

    try do
      client = Ueberauth.Strategy.Facebook.OAuth.get_token!([code: code], opts)
      token = client.token

      if token.access_token == nil do
        err = token.other_params["error"]
        desc = token.other_params["error_description"]
        set_errors!(conn, [error(err, desc)])
      else
        fetch_user(conn, client, config)
      end
    rescue
      OAuth2.Error ->
        set_errors!(conn, [error("invalid_code", "The code has been used or has expired")])
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:facebook_user, nil)
    |> put_private(:facebook_token, nil)
  end

  @doc """
  Fetches the uid field from the response.
  """
  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string

    conn.private.facebook_user[uid_field]
  end

  @doc """
  Includes the credentials from the facebook response.
  """
  def credentials(conn) do
    token = conn.private.facebook_token
    scopes = token.other_params["scope"] || ""
    scopes = String.split(scopes, ",")

    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes,
      token: token.access_token
    }
  end

  @doc """
  Fetches the fields to populate the info section of the
  `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.facebook_user

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

  @doc """
  Stores the raw information (including the token) obtained from
  the facebook callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.facebook_token,
        user: conn.private.facebook_user
      }
    }
  end

  defp fetch_image(uid) do
    "https://graph.facebook.com/#{uid}/picture?type=large"
  end

  defp fetch_user(conn, client, config) do
    conn = put_private(conn, :facebook_token, client.token)
    query = user_query(conn, client.token, config)
    path = "/me?#{query}"

    case OAuth2.Client.get(client, path) do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])

      {:ok, %OAuth2.Response{status_code: status_code, body: user}}
      when status_code in 200..399 ->
        put_private(conn, :facebook_user, user)

      {:error, %OAuth2.Error{reason: reason}} ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  defp user_query(conn, token, config) do
    %{"appsecret_proof" => appsecret_proof(token, config)}
    |> Map.merge(query_params(conn, :locale))
    |> Map.merge(query_params(conn, :profile))
    |> URI.encode_query()
  end

  defp appsecret_proof(token, config) do
    client_secret = Keyword.get(config, :client_secret)

    token.access_token
    |> hmac(:sha256, client_secret)
    |> Base.encode16(case: :lower)
  end

  @compile {:no_warn_undefined, {:crypto, :mac, 4}}
  @compile {:no_warn_undefined, {:crypto, :hmac, 3}}
  defp hmac(data, type, key) do
    if function_exported?(:crypto, :mac, 4) do
      :crypto.mac(:hmac, type, key, data)
    else
      :crypto.hmac(type, key, data)
    end
  end

  defp query_params(conn, :profile) do
    %{"fields" => option(conn, :profile_fields)}
  end

  defp query_params(conn, :locale) do
    case option(conn, :locale) do
      nil -> %{}
      locale -> %{"locale" => locale}
    end
  end

  defp option(conn, key) do
    default = Keyword.get(default_options(), key)

    conn
    |> options
    |> Keyword.get(key, default)
  end

  defp option(nil, conn, key), do: option(conn, key)
  defp option(value, _conn, _key), do: value

  defp maybe_replace_param(params, conn, name, config_key) do
    if params[name] || is_nil(option(params[name], conn, config_key)) do
      params
    else
      Map.put(
        params,
        name,
        option(params[name], conn, config_key)
      )
    end
  end

  defp oauth_client_options_from_conn(conn) do
    base_options = [redirect_uri: callback_url(conn)]
    request_options = conn.private[:ueberauth_request_options].options

    case {request_options[:client_id], request_options[:client_secret]} do
      {nil, _} -> base_options
      {_, nil} -> base_options
      {id, secret} -> [client_id: id, client_secret: secret] ++ base_options
    end
  end
end
