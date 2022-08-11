defmodule UeberauthTest do
  use ExUnit.Case, async: true
  use Plug.Test
  doctest Ueberauth

  alias Support.SpecRouter

  @opts Support.SpecRouter.init([])
  @session_options Plug.Session.init(
                     store: Plug.Session.COOKIE,
                     key: "_hello_key",
                     signing_salt: "CXlmrshG"
                   )

  test "simple request phase" do
    conn = conn(:get, "/auth/simple")
    resp = SpecRouter.call(conn, @opts)
    assert resp.resp_body == "simple_request_phase"
  end

  test "simple callback phase" do
    conn =
      :get
      |> conn("/auth/simple/callback")
      |> SpecRouter.call(@opts)

    auth = conn.assigns.ueberauth_auth

    assert auth.uid == "Elixir.Support.SimpleCallback-uid"
    assert auth.provider == :simple
    assert auth.strategy == Support.SimpleCallback

    assert_standard_info(auth)
    assert_standard_credentials(auth)

    extra = auth.extra
    assert extra.raw_info.request_path == "/auth/simple"
    assert extra.raw_info.callback_path == "/auth/simple/callback"

    assert extra.raw_info.request_url == "http://www.example.com/auth/simple"
    assert extra.raw_info.callback_url == "http://www.example.com/auth/simple/callback"
  end

  test "simple request and callback phase for same url but different method" do
    conn = conn(:get, "/auth/post_callback_and_same_request_path")
    resp = SpecRouter.call(conn, @opts)
    assert resp.resp_body == "ok"

    conn =
      :post
      |> conn("/auth/post_callback_and_same_request_path")
      |> SpecRouter.call(@opts)

    auth = conn.assigns.ueberauth_auth
    assert auth.provider == :post_callback_and_same_request_path
  end

  test "redirecting a request phase without trailing slash" do
    conn = conn(:get, "/auth/redirector") |> SpecRouter.call(@opts)
    assert get_resp_header(conn, "location") == ["https://redirectme.example.com/foo"]
  end

  test "redirecting a request phase with trailing slash" do
    conn = conn(:get, "/auth/redirector/") |> SpecRouter.call(@opts)
    assert get_resp_header(conn, "location") == ["https://redirectme.example.com/foo"]
  end

  test "setting request phase path" do
    conn = conn(:get, "/login") |> SpecRouter.call(@opts)
    assert get_resp_header(conn, "location") == ["https://redirectme.example.com/foo"]

    conn = conn(:get, "/auth/with_request_path/callback") |> SpecRouter.call(@opts)
    auth = conn.assigns.ueberauth_auth

    assert auth.provider == :with_request_path
    assert auth.strategy == Support.Redirector
    assert auth.extra.raw_info.request_path == "/login"
    assert auth.extra.raw_info.callback_path == "/auth/with_request_path/callback"
  end

  test "setting request phase path with multiple conn script names" do
    conn = conn(:get, "/auth/with_request_path/callback")
    conn = %Plug.Conn{conn | script_name: ["v1", "auth"]} |> SpecRouter.call(@opts)
    auth = conn.assigns.ueberauth_auth

    assert auth.extra.raw_info.request_path == "/v1/auth/login"
  end

  test "setting callback phase path" do
    conn = conn(:get, "/login_callback") |> SpecRouter.call(@opts)
    auth = conn.assigns.ueberauth_auth

    assert auth.provider == :with_callback_path
    assert auth.strategy == Support.SimpleCallback
    assert auth.extra.raw_info.request_path == "/auth/with_callback_path"
    assert auth.extra.raw_info.callback_path == "/login_callback"
  end

  test "setting callback phase path with multiple conn script names" do
    conn = conn(:get, "/login_callback")
    conn = %Plug.Conn{conn | script_name: ["v1", "auth"]} |> SpecRouter.call(@opts)
    auth = conn.assigns.ueberauth_auth

    assert auth.extra.raw_info.callback_path == "/v1/auth/login_callback"
  end

  test "using default options" do
    conn = conn(:get, "/auth/using_default_options/callback") |> SpecRouter.call(@opts)
    auth = conn.assigns.ueberauth_auth
    assert auth.uid == "default uid"
  end

  test "using custom options" do
    conn = conn(:get, "/auth/using_custom_options/callback") |> SpecRouter.call(@opts)
    auth = conn.assigns.ueberauth_auth
    assert auth.uid == "custom uid"
  end

  test "returning errors" do
    conn = conn(:get, "/auth/with_errors/callback") |> SpecRouter.call(@opts)

    assert conn.assigns[:ueberauth_auth] == nil
    assert conn.assigns[:ueberauth_failure] != nil

    failure = conn.assigns.ueberauth_failure
    assert failure.provider == :with_errors
    assert failure.strategy == Support.WithErrors

    assert length(failure.errors) == 2

    [first | second] = failure.errors
    second = hd(second)

    assert first.message_key == "one"
    assert first.message == "error one"
    assert second.message_key == "two"
    assert second.message == "error two"
  end

  test "setting the callback http method" do
    conn = conn(:get, "/auth/post_callback/callback") |> SpecRouter.call(@opts)
    assert conn.status == 404
    assert conn.assigns[:ueberauth_auth] == nil
    assert conn.assigns[:ueberauth_failure] == nil

    conn = conn(:post, "/auth/post_callback/callback") |> SpecRouter.call(@opts)
    assert conn.status == 200
    assert conn.assigns[:ueberauth_failure] == nil
    assert conn.assigns[:ueberauth_auth] != nil

    auth = conn.assigns[:ueberauth_auth]

    assert auth.provider == :post_callback
    assert auth.strategy == Support.SimpleCallback
  end

  test "callback_url port" do
    conn = %{conn(:get, "/") | scheme: :https, port: 80}
    conn = put_private(conn, :ueberauth_request_options, callback_path: "/auth/provider/callback")
    conn = %{conn | params: %{}}

    assert Ueberauth.Strategy.Helpers.callback_url(conn) ==
             "https://www.example.com/auth/provider/callback"
  end

  test "callback_url forwarded protocol" do
    conn = %{
      (conn(:get, "/")
       |> put_req_header("x-forwarded-proto", "https"))
      | scheme: :http,
        port: 80
    }

    conn = put_private(conn, :ueberauth_request_options, callback_path: "/auth/provider/callback")

    assert Ueberauth.Strategy.Helpers.callback_url(conn) ==
             "https://www.example.com/auth/provider/callback"
  end

  test "callback_url uses forwarded host" do
    conn = %{
      (conn(:get, "/")
       |> put_req_header("x-forwarded-host", "changelog.com"))
      | scheme: :http,
        port: 80
    }

    conn = put_private(conn, :ueberauth_request_options, callback_path: "/auth/provider/callback")

    assert Ueberauth.Strategy.Helpers.callback_url(conn) ==
             "http://changelog.com/auth/provider/callback"
  end

  test "callback_url has custom scheme" do
    conn = %{
      conn(:get, "/")
      | scheme: :http,
        port: 80
    }

    conn =
      put_private(conn, :ueberauth_request_options,
        callback_path: "/auth/provider/callback",
        callback_scheme: "https"
      )

    assert Ueberauth.Strategy.Helpers.callback_url(conn) ==
             "https://www.example.com/auth/provider/callback"
  end

  test "callback_url has custom port" do
    conn = %{
      conn(:get, "/")
      | scheme: :http,
        port: 80
    }

    conn =
      put_private(conn, :ueberauth_request_options,
        callback_path: "/auth/provider/callback",
        callback_port: 4000
      )

    assert Ueberauth.Strategy.Helpers.callback_url(conn) ==
             "http://www.example.com:4000/auth/provider/callback"
  end

  test "callback_url has extra params" do
    conn = conn(:get, "/")
    conn = put_private(conn, :ueberauth_request_options, callback_params: ["type"])
    conn = %{conn | params: %{"type" => "user", "param_2" => "param_2"}}
    assert Ueberauth.Strategy.Helpers.callback_url(conn) == "http://www.example.com?type=user"
  end

  test "run_request" do
    conn =
      conn(:get, "/oauth/simple-provider/", id: "foo")
      |> Ueberauth.run_request(
        "simple-provider",
        {Support.SimpleProvider, [callback_path: "/oauth/simple-provider/callback"]}
      )

    location = conn |> Plug.Conn.get_resp_header("location") |> List.first()
    assert location === "/oauth/simple-provider/callback?code=foo"
  end

  test "run_request with a state param by default" do
    conn =
      conn(:get, "/oauth/simple-provider/", id: "foo")
      |> Ueberauth.run_request(
        "simple-provider",
        {Support.ProviderWithCsrfAttackEnabled,
         [callback_path: "/oauth/simple-provider/callback"]}
      )
      |> Plug.Conn.fetch_cookies()

    assert conn.cookies["ueberauth.state_param"] != nil
    assert conn.private[:ueberauth_state_param] != nil
  end

  test "run_request with a custom state param cookie samesite" do
    conn =
      conn(:get, "/oauth/simple-provider/", id: "foo")
      |> Ueberauth.run_request(
        "simple-provider",
        {Support.ProviderWithCustomCookieSameSite,
         [callback_path: "/oauth/simple-provider/callback"]}
      )

    assert conn.resp_cookies["ueberauth.state_param"][:same_site] == "None"
  end

  test "run_request with state param disabled" do
    conn =
      conn(:get, "/oauth/simple-provider/", id: "foo")
      |> Ueberauth.run_request(
        "simple-provider",
        {Support.SimpleProvider, [callback_path: "/oauth/simple-provider/callback"]}
      )

    assert conn.private[:ueberauth_state_param] == nil
  end

  test "run_callback" do
    conn =
      conn(:get, "/oauth/simple-provider/callback", id: "foo", code: "simple-code")
      |> Plug.Session.call(@session_options)
      |> Ueberauth.run_callback(
        "simple-provider",
        {Support.SimpleProvider, [token_prefix: "token-"]}
      )

    assert conn.assigns[:ueberauth_auth].credentials.token === "token-simple-code"
  end

  test "run_callback triggers an error if the state does not match" do
    conn =
      conn(:get, "/oauth/simple-provider/callback", id: "foo", code: "simple-code")
      |> Plug.Session.call(@session_options)
      |> Ueberauth.run_callback(
        "simple-provider",
        {Support.ProviderWithCsrfAttackEnabled, [token_prefix: "token-"]}
      )

    assert conn.assigns.ueberauth_failure != nil
    assert List.first(conn.assigns.ueberauth_failure.errors).message_key == "csrf_attack"
  end

  test "make ensure run_callback properly clean the internal state param in cookie" do
    conn =
      :get
      |> conn("/oauth/simple-provider/", id: "foo")
      |> Ueberauth.run_request(
        "simple-provider",
        {Support.ProviderWithCsrfAttackEnabled,
         [callback_path: "/oauth/simple-provider/callback"]}
      )
      |> Plug.Conn.fetch_cookies()

    state = conn.private[:ueberauth_state_param]
    code = "simple-code"

    conn =
      :get
      |> conn("/oauth/simple-provider/callback",
        next_url: "http://localhost/fetch_user",
        id: "foo",
        code: code,
        state: state
      )
      |> Map.put(:cookies, conn.cookies)
      |> Map.put(:req_cookies, conn.req_cookies)
      |> Plug.Session.call(@session_options)
      |> Ueberauth.run_callback(
        "simple-provider",
        {Support.ProviderWithCsrfAttackEnabled, []}
      )

    assert conn.halted == true and conn.cookies == %{}
    assert conn.resp_body =~ ~s|http://localhost/fetch_user?code=#{code}|
  end

  defp assert_standard_info(auth) do
    info = auth.info

    assert info.name == "Some name"
    assert info.first_name == "First name"
    assert info.last_name == "Last name"
    assert info.nickname == "Nickname"
    assert info.email == "email@foo.com"
    assert info.location == "Some location"
    assert info.description == "Some description"
    assert info.phone == "555-555-5555"
    assert info.birthday == "2000-01-01"
    assert info.urls == %{"Blog" => "http://foo.com", "Thing" => "http://thing.com"}
  end

  defp assert_standard_credentials(auth) do
    creds = auth.credentials

    assert creds.token == "Some token"
    assert creds.refresh_token == "Some refresh token"
    assert creds.secret == "Some secret"
    assert creds.expires == true
    assert creds.expires_at == 1111
    assert creds.other == %{password: "sekrit"}
  end
end
