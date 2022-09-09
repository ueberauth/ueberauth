defmodule Ueberauth.Strategy.Apple do
  @moduledoc """
  Implementation of an Ueberauth Strategy for "Sign In with Apple".

  ## Configuration

  This provider supports the following configuration:

    * **Callback URL**: (Required) The URI to which the authorization redirects. It must include a
      domain name and can’t be an IP address or localhost. Apple will check the provided URL against
      the domains and redirect URIs configured in your Service ID. Defaults to
      `[...]/auth/:provider/callback` according to the configured provider name.

    * **Response mode**: How response information will be sent back to the server during the
      callback phase.. Valid values are `"query"`, `"fragment"`, and `"form_post"`. If you requested
      any scopes, the value must be `form_post`. Defaults to `"query"` if no scopes are requested,
      `"form_post"` otherwise.

    * **Scopes**: The amount of user information requested from Apple. Valid values are `name` and
      `email`, with multiple values separated by spaces. You can request one, both, or none.
      Defaults to no scopes (`""`).

  """
  use Ueberauth.Strategy, uid_field: :uid, default_scope: ""

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra
  alias Ueberauth.Strategy.Apple.OAuth
  alias Ueberauth.Strategy.Apple.Token

  #
  # Request Phase
  #

  @doc """
  Handles initial request for Apple authentication.
  """
  @impl Ueberauth.Strategy
  @spec handle_request!(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_request!(conn) do
    params =
      [response_type: "code id_token"]
      |> with_scopes_and_response_mode(conn)
      |> with_param(:nonce, conn)
      |> with_state_param(conn)

    opts = oauth_client_options_from_conn(conn)

    conn
    |> modify_state_cookie(params)
    |> redirect!(OAuth.authorize_url!(params, opts))
  end

  # If the response_mode is "form_post", then the state cookie must use SameSite=None and Secure;
  @spec modify_state_cookie(Plug.Conn.t(), keyword) :: Plug.Conn.t()
  defp modify_state_cookie(conn, params) do
    if Keyword.get(params, :response_mode) == "form_post" do
      state_cookie = conn.resp_cookies["ueberauth.state_param"]
      modified_cookie = Map.merge(state_cookie, %{same_site: "None", secure: true})

      %{conn | resp_cookies: Map.put(conn.resp_cookies, "ueberauth.state_param", modified_cookie)}
    else
      conn
    end
  end

  #
  # Callback Phase
  #

  @doc """
  Handles the callback from Apple.
  """
  @impl Ueberauth.Strategy
  @spec handle_callback!(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_callback!(%Plug.Conn{params: %{"code" => code, "id_token" => token} = params} = conn) do
    opts = oauth_client_options_from_conn(conn)
    token_opts = with_optional([], :private_key, conn)

    with {:ok, %{"email" => email, "sub" => uid}} <- Token.payload(token, token_opts),
         user <- Map.merge(extract_user(params), %{"email" => email, "uid" => uid}),
         {:ok, token} <- OAuth.get_access_token([code: code], opts) do
      conn
      |> put_private(:apple_token, token)
      |> put_private(:apple_user, user)
    else
      {:error, {error_code, error_description}} ->
        set_errors!(conn, [error(error_code, error_description)])

      {:error, reason} ->
        set_errors!(conn, [error(to_string(reason), "Error while reading authentication token")])
    end
  end

  def handle_callback!(%Plug.Conn{params: %{"error" => error}} = conn) do
    set_errors!(conn, [error("auth_failed", error)])
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  # Only the first login callback has user information; subsequent callbacks do not.
  @spec extract_user(map) :: map
  defp extract_user(%{"user" => user}), do: Ueberauth.json_library().decode!(user)
  defp extract_user(_params), do: %{}

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

  # From Apple documentation:
  #
  # response_mode
  #   The type of response mode expected. Valid values are query, fragment, and form_post. If you
  #   requested any scopes, the value must be form_post.
  #
  defp with_scopes_and_response_mode(opts, conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    if scopes != "" do
      Keyword.merge(opts, response_mode: "form_post", scope: scopes)
    else
      with_optional(opts, :response_mode, conn)
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
