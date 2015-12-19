defmodule Ueberauth.Strategy.Twitter do
  @moduledoc """
  Twitter Strategy for Überauth.
  """

  use Ueberauth.Strategy, uid_field: :id_str

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra
  alias Ueberauth.Strategy.Twitter

  @doc """
  Handles initial request for Twitter authentication.
  """
  def handle_request!(conn) do
    token = Twitter.OAuth.request_token!([], [redirect_uri: callback_url(conn)])

    conn
    |> put_session(:twitter_token, token)
    |> redirect!(Twitter.OAuth.authorize_url!(token))
  end

  @doc """
  Handles the callback from Twitter.
  """
  def handle_callback!(%Plug.Conn{params: %{"oauth_verifier" => oauth_verifier}} = conn) do
    token = get_session(conn, :twitter_token)
    case Twitter.OAuth.access_token(token, oauth_verifier) do
      {:ok, access_token} -> fetch_user(conn, access_token)
      {:error, error} -> set_errors!(conn, [error(error.code, error.reason)])
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc false
  def handle_cleanup!(conn) do
    conn
    |> put_private(:twitter_user, nil)
    |> put_session(:twitter_token, nil)
  end

  @doc """
  Fetches the uid field from the response.
  """
  def uid(conn) do
    uid_field =
      conn
      |> option(:uid_field)
      |> to_string

    conn.private.twitter_user[uid_field]
  end

  @doc """
  Includes the credentials from the twitter response.
  """
  def credentials(conn) do
    {token, secret} = conn.private.twitter_token

    %Credentials{token: token, secret: secret}
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.twitter_user

    %Info{
      email: user["email"],
      image: user["profile_image_url"],
      name: user["name"],
      nickname: user["screen_name"],
      description: user["description"],
      urls: %{
        Twitter: "https://twitter.com/#{user["screen_name"]}",
        Website: user["url"]
      }
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from the twitter callback.
  """
  def extra(conn) do
    {token, _secret} = get_session(conn, :twitter_token)

    %Extra{
      raw_info: %{
        token: token,
        user: conn.private.twitter_user
      }
    }
  end

  defp fetch_user(conn, token) do
    params = [include_entities: false, skip_status: true, include_email: true]
    case Twitter.OAuth.get("/1.1/account/verify_credentials.json", params, token) do
      {:ok, {{_, 401, _}, _, _}} ->
        set_errors!(conn, [error("token", "unauthorized")])
      {:ok, {{_, status_code, _}, _, body}} when status_code in 200..399 ->
        body = body |> List.to_string |> Poison.decode!

        conn
        |> put_private(:twitter_token, token)
        |> put_private(:twitter_user, body)
      {:ok, {_, _, body}} ->
        body = body |> List.to_string |> Poison.decode!

        error = List.first(body["errors"])
        set_errors!(conn, [error("token", error["message"])])
    end
  end

  defp option(conn, key) do
    Dict.get(options(conn), key, Dict.get(default_options, key))
  end
end
