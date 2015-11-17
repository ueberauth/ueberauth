defmodule UeberauthTest do
  use ExUnit.Case, async: true
  use Plug.Test
  doctest Ueberauth

  alias Support.SpecRouter

  @opts Support.SpecRouter.init([])

  test "simple request phase" do
    conn = conn(:get, "/auth/simple")
    resp = SpecRouter.call(conn, @opts)
    assert resp.resp_body == "simple_request_phase"
  end

  test "simple callback phase" do
    conn = conn(:get, "/auth/simple/callback") |> SpecRouter.call(@opts)
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

  test "redirecting a request phase" do
    conn = conn(:get, "/auth/redirector") |> SpecRouter.call(@opts)
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

  test "setting callback phase path" do
    conn = conn(:get, "/login_callback") |> SpecRouter.call(@opts)
    auth = conn.assigns.ueberauth_auth

    assert auth.provider == :with_callback_path
    assert auth.strategy == Support.SimpleCallback
    assert auth.extra.raw_info.request_path == "/auth/with_callback_path"
    assert auth.extra.raw_info.callback_path == "/login_callback"
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
    conn = put_private(conn, :ueberauth_request_options, [callback_path: "/auth/provider/callback"])
    assert Ueberauth.Strategy.Helpers.callback_url(conn) ==
      "https://www.example.com/auth/provider/callback"
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
    assert info.urls == %{ "Blog" => "http://foo.com", "Thing" => "http://thing.com" }
  end

  defp assert_standard_credentials(auth) do
    creds = auth.credentials

    assert creds.token == "Some token"
    assert creds.refresh_token == "Some refresh token"
    assert creds.secret == "Some secret"
    assert creds.expires == true
    assert creds.expires_at == 1111
    assert creds.other == %{ password: "sekrit" }
  end
end
