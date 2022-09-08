defmodule Ueberauth.Strategy.Apple do
  @moduledoc """
  Implementation of an Ueberauth Strategy for "Sign In with Apple".
  """
  use Ueberauth.Strategy, uid_field: :uid, default_scope: "name email"

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  #
  # Request Phase
  #

  @doc """
  Handles initial request for Apple authentication.
  """
  @impl Ueberauth.Strategy
  @spec handle_request!(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    params =
      [scope: scopes]
      |> with_optional(:prompt, conn)
      |> with_optional(:access_type, conn)
      |> with_param(:access_type, conn)
      |> with_param(:prompt, conn)
      |> with_param(:response_mode, conn)
      |> with_param(:state, conn)

    opts = oauth_client_options_from_conn(conn)
    redirect!(conn, Ueberauth.Strategy.Apple.OAuth.authorize_url!(params, opts))
  end

  #
  # Callback Phase
  #

  @doc """
  Handles the callback from Apple.
  """
  @impl Ueberauth.Strategy
  @spec handle_callback!(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_callback!(%Plug.Conn{params: %{"code" => code} = params} = conn) do
    user = (params["user"] && Ueberauth.json_library().decode!(params["user"])) || %{}
    opts = oauth_client_options_from_conn(conn)

    case Ueberauth.Strategy.Apple.OAuth.get_access_token([code: code], opts) do
      {:ok, token} ->
        %{"email" => user_email, "sub" => user_uid} =
          UeberauthApple.id_token_payload(token.other_params["id_token"])

        apple_user =
          user
          |> Map.put("uid", user_uid)
          |> Map.put("email", user_email)

        conn
        |> put_private(:apple_token, token)
        |> put_private(:apple_user, apple_user)

      {:error, {error_code, error_description}} ->
        set_errors!(conn, [error(error_code, error_description)])
    end
  end

  def handle_callback!(%Plug.Conn{params: %{"error" => error}} = conn) do
    set_errors!(conn, [error("auth_failed", error)])
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  #
  # Other Callbacks
  #

  @doc false
  @impl Ueberauth.Strategy
  @spec handle_cleanup!(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_cleanup!(conn) do
    conn
    |> put_private(:apple_user, nil)
    |> put_private(:apple_token, nil)
  end

  @doc """
  Fetches the uid field from the response.
  """
  @impl Ueberauth.Strategy
  @spec uid(Plug.Conn.t()) :: binary | nil
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
  @impl Ueberauth.Strategy
  @spec credentials(Plug.Conn.t()) :: Ueberauth.Auth.Credentials.t()
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
  @impl Ueberauth.Strategy
  @spec info(Plug.Conn.t()) :: Ueberauth.Auth.Info.t()
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
  @impl Ueberauth.Strategy
  @spec extra(Plug.Conn.t()) :: Ueberauth.Auth.Extra.t()
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.apple_token,
        user: conn.private.apple_user
      }
    }
  end

  #
  # Configuration Helpers
  #

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
