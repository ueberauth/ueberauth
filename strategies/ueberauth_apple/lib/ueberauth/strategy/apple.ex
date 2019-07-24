defmodule Ueberauth.Strategy.Apple do
  @moduledoc """
  Google Strategy for Überauth.
  """

  use Ueberauth.Strategy, uid_field: :uid, default_scope: "name email"

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @public_key_url "https://appleid.apple.com/auth/keys"

  @doc """
  Handles initial request for Apple authentication.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    params =
      [scope: scopes]
      |> with_optional(:prompt, conn)
      |> with_optional(:access_type, conn)
      |> with_param(:access_type, conn)
      |> with_param(:prompt, conn)
      |> with_param(:state, conn)

    opts = oauth_client_options_from_conn(conn)
    redirect!(conn, Ueberauth.Strategy.Apple.OAuth.authorize_url!(params, opts))
  end

  @doc """
  Handles the callback from Apple.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    params = [code: code]
    opts = oauth_client_options_from_conn(conn)

    case Ueberauth.Strategy.Apple.OAuth.get_access_token(params, opts) do
      {:ok, token} ->
        user =
          %{}
          |> Map.put("uid", uid_from_id_token(token.other_params["id_token"]))

        conn
        |> put_private(:apple_token, token)
        |> put_private(:apple_user, user)

      {:error, {error_code, error_description}} ->
        set_errors!(conn, [error(error_code, error_description)])
    end
  end

  @doc false
  def handle_callback!(%Plug.Conn{params: %{"error" => error}} = conn) do
    set_errors!(conn, [error("auth_failed", error)])
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:apple_user, nil)
    |> put_private(:apple_token, nil)
  end

  @doc """
  Fetches the uid field from the response.
  """
  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string

    conn.private.apple_user[uid_field]
  end

  @doc """
  Includes the credentials from the Apple response.
  """
  def credentials(conn) do
    token = conn.private.apple_token
    scope_string = token.other_params["scope"] || ""
    scopes = String.split(scope_string, ",")

    %Credentials{
      expires: !!token.expires_at,
      expires_at: token.expires_at,
      scopes: scopes,
      token_type: Map.get(token, :token_type),
      refresh_token: token.refresh_token,
      token: token.access_token
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.apple_user
    name = user["name"]

    %Info{
      email: user["email"],
      first_name: name && name["firstName"],
      last_name: name && name["lastName"]
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from the google callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.apple_token,
        user: conn.private.apple_user
      }
    }
  end

  defp uid_from_id_token(id_token) do
    with {:ok, %{body: response_body}} <- HTTPoison.get(@public_key_url),
         {true, %JOSE.JWT{fields: fields}, _jws} <-
           Ueberauth.json_library().decode!(response_body)["keys"]
           |> List.first()
           |> JOSE.JWT.verify(id_token),
         {:ok, uid} <- {:ok, fields["sub"]} do
      uid
    end
  end

  defp with_param(opts, key, conn) do
    if value = conn.params[to_string(key)], do: Keyword.put(opts, key, value), else: opts
  end

  defp with_optional(opts, key, conn) do
    if option(conn, key), do: Keyword.put(opts, key, option(conn, key)), else: opts
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

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end
end
