defmodule Ueberauth.Strategy.GoogleTest do
  use ExUnit.Case, async: true
  use Plug.Test

  import Mock
  import Plug.Conn
  import Ueberauth.Strategy.Helpers

  setup_with_mocks([
    {OAuth2.Client, [:passthrough],
     [
       get_token: &oauth2_get_token/2,
       get: &oauth2_get/4
     ]}
  ]) do
    # Create a connection with Ueberauth's CSRF cookies so they can be recycled during tests
    routes = Ueberauth.init([])
    csrf_conn = conn(:get, "/auth/google", %{}) |> Ueberauth.call(routes)
    csrf_state = with_state_param([], csrf_conn) |> Keyword.get(:state)

    {:ok, csrf_conn: csrf_conn, csrf_state: csrf_state}
  end

  def set_options(routes, conn, opt) do
    case Enum.find_index(routes, &(elem(&1, 0) == {conn.request_path, conn.method})) do
      nil ->
        routes

      idx ->
        update_in(routes, [Access.at(idx), Access.elem(1), Access.elem(2)], &%{&1 | options: opt})
    end
  end

  defp token(client, opts), do: {:ok, %{client | token: OAuth2.AccessToken.new(opts)}}
  defp response(body, code \\ 200), do: {:ok, %OAuth2.Response{status_code: code, body: body}}

  def oauth2_get_token(client, code: "success_code"), do: token(client, "success_token")
  def oauth2_get_token(client, code: "uid_code"), do: token(client, "uid_token")
  def oauth2_get_token(client, code: "userinfo_code"), do: token(client, "userinfo_token")

  def oauth2_get(%{token: %{access_token: "success_token"}}, _url, _, _),
    do: response(%{"sub" => "1234_fred", "name" => "Fred Jones", "email" => "fred_jones@example.com"})

  def oauth2_get(%{token: %{access_token: "uid_token"}}, _url, _, _),
    do: response(%{"uid_field" => "1234_daphne", "name" => "Daphne Blake"})

  def oauth2_get(%{token: %{access_token: "userinfo_token"}}, "https://www.googleapis.com/oauth2/v3/userinfo", _, _),
    do: response(%{"sub" => "1234_velma", "name" => "Velma Dinkley"})

  def oauth2_get(%{token: %{access_token: "userinfo_token"}}, "example.com/shaggy", _, _),
    do: response(%{"sub" => "1234_shaggy", "name" => "Norville Rogers"})

  def oauth2_get(%{token: %{access_token: "userinfo_token"}}, "example.com/scooby", _, _),
    do: response(%{"sub" => "1234_scooby", "name" => "Scooby Doo"})

  defp set_csrf_cookies(conn, csrf_conn) do
    conn
    |> init_test_session(%{})
    |> recycle_cookies(csrf_conn)
    |> fetch_cookies()
  end

  test "handle_request! redirects to appropriate auth uri" do
    conn = conn(:get, "/auth/google", %{})
    # Make sure the hd and scope params are included for good measure
    routes = Ueberauth.init() |> set_options(conn, hd: "example.com", default_scope: "email openid")

    resp = Ueberauth.call(conn, routes)

    assert resp.status == 302
    assert [location] = get_resp_header(resp, "location")

    redirect_uri = URI.parse(location)
    assert redirect_uri.host == "accounts.google.com"
    assert redirect_uri.path == "/o/oauth2/v2/auth"

    assert %{
             "client_id" => "client_id",
             "redirect_uri" => "http://www.example.com/auth/google/callback",
             "response_type" => "code",
             "scope" => "email openid",
             "hd" => "example.com"
           } = Plug.Conn.Query.decode(redirect_uri.query)
  end

  test "handle_callback! assigns required fields on successful auth", %{csrf_state: csrf_state, csrf_conn: csrf_conn} do
    conn =
      conn(:get, "/auth/google/callback", %{code: "success_code", state: csrf_state}) |> set_csrf_cookies(csrf_conn)

    routes = Ueberauth.init([])
    assert %Plug.Conn{assigns: %{ueberauth_auth: auth}} = Ueberauth.call(conn, routes)
    assert auth.credentials.token == "success_token"
    assert auth.info.name == "Fred Jones"
    assert auth.info.email == "fred_jones@example.com"
    assert auth.uid == "1234_fred"
  end

  test "uid_field is picked according to the specified option", %{csrf_state: csrf_state, csrf_conn: csrf_conn} do
    conn = conn(:get, "/auth/google/callback", %{code: "uid_code", state: csrf_state}) |> set_csrf_cookies(csrf_conn)
    routes = Ueberauth.init() |> set_options(conn, uid_field: "uid_field")
    assert %Plug.Conn{assigns: %{ueberauth_auth: auth}} = Ueberauth.call(conn, routes)
    assert auth.info.name == "Daphne Blake"
    assert auth.uid == "1234_daphne"
  end

  test "userinfo is fetched according to userinfo_endpoint", %{csrf_state: csrf_state, csrf_conn: csrf_conn} do
    conn =
      conn(:get, "/auth/google/callback", %{code: "userinfo_code", state: csrf_state}) |> set_csrf_cookies(csrf_conn)

    routes = Ueberauth.init() |> set_options(conn, userinfo_endpoint: "example.com/shaggy")
    assert %Plug.Conn{assigns: %{ueberauth_auth: auth}} = Ueberauth.call(conn, routes)
    assert auth.info.name == "Norville Rogers"
  end

  test "userinfo can be set via runtime config with default", %{csrf_state: csrf_state, csrf_conn: csrf_conn} do
    conn =
      conn(:get, "/auth/google/callback", %{code: "userinfo_code", state: csrf_state}) |> set_csrf_cookies(csrf_conn)

    routes = Ueberauth.init() |> set_options(conn, userinfo_endpoint: {:system, "NOT_SET", "example.com/shaggy"})
    assert %Plug.Conn{assigns: %{ueberauth_auth: auth}} = Ueberauth.call(conn, routes)
    assert auth.info.name == "Norville Rogers"
  end

  test "userinfo uses default library value if runtime env not found", %{csrf_state: csrf_state, csrf_conn: csrf_conn} do
    conn =
      conn(:get, "/auth/google/callback", %{code: "userinfo_code", state: csrf_state}) |> set_csrf_cookies(csrf_conn)

    routes = Ueberauth.init() |> set_options(conn, userinfo_endpoint: {:system, "NOT_SET"})
    assert %Plug.Conn{assigns: %{ueberauth_auth: auth}} = Ueberauth.call(conn, routes)
    assert auth.info.name == "Velma Dinkley"
  end

  test "userinfo can be set via runtime config", %{csrf_state: csrf_state, csrf_conn: csrf_conn} do
    conn =
      conn(:get, "/auth/google/callback", %{code: "userinfo_code", state: csrf_state}) |> set_csrf_cookies(csrf_conn)

    routes = Ueberauth.init() |> set_options(conn, userinfo_endpoint: {:system, "UEBERAUTH_SCOOBY_DOO"})
    System.put_env("UEBERAUTH_SCOOBY_DOO", "example.com/scooby")
    assert %Plug.Conn{assigns: %{ueberauth_auth: auth}} = Ueberauth.call(conn, routes)
    assert auth.info.name == "Scooby Doo"
    System.delete_env("UEBERAUTH_SCOOBY_DOO")
  end

  test "state param is present in the redirect uri" do
    conn = conn(:get, "/auth/google", %{})

    routes = Ueberauth.init()
    resp = Ueberauth.call(conn, routes)

    assert [location] = get_resp_header(resp, "location")

    redirect_uri = URI.parse(location)

    assert redirect_uri.query =~ "state="
  end
end
