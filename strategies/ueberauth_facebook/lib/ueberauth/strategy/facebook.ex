defmodule Ueberauth.Strategy.Facebook do
  @moduledoc """
  Facebook Strategy for Überauth.
  """

  use Ueberauth.Strategy, uid_field: :id, default_scope: "email"

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles initial request for Facebook authentication.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)
    opts = [ scope: scopes ]
    if conn.params["state"], do: opts = Keyword.put(opts, :state, conn.params["state"])
    opts = Keyword.put(opts, :redirect_uri, callback_url(conn))
    IO.inspect opts
    redirect!(conn, Ueberauth.Strategy.Facebook.OAuth.authorize_url!(opts))
  end

  @doc """
  Handles the callback from Facebook.
  """
  def handle_callback!(%Plug.Conn{ params: %{ "code" => code } } = conn) do
    token = Ueberauth.Strategy.Facebook.OAuth.get_token!(code: code)

    if token.access_token == nil do
      set_errors!(conn, [error(token.other_params["error"], token.other_params["error_description"])])
    else
      fetch_user(conn, token)
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
    scopes = (token.other_params["scope"] || "")
              |> String.split(",")

    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes,
      token: token.access_token
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
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
      nickname: user["username"],
      urls: %{
        facebook: user["link"],
        website: user["website"]
      }
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from the facebook callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.facebook_token,
        user: conn.private.facebook_user
      }
    }
  end

  defp fetch_image(uid), do: "http://graph.facebook.com/#{uid}/picture?type=square"

  defp fetch_user(conn, token) do
    conn = put_private(conn, :facebook_token, token)
    case OAuth2.AccessToken.get(token, "/me") do
      { :ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])
      { :ok, %OAuth2.Response{status_code: status_code, body: user} } when status_code in 200..399 ->
        put_private(conn, :facebook_user, user)
      { :error, %OAuth2.Error{reason: reason} } ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  defp option(conn, key) do
    Dict.get(options(conn), key, Dict.get(default_options, key))
  end
end
