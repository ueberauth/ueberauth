defmodule Ueberauth.Strategy.HelpersTest do
  # Not async: sets application config for :ueberauth_helpers_test.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Ueberauth.Strategy.Helpers

  defp conn_with_options(headers, options) do
    conn =
      Enum.reduce(headers, conn(:get, "/"), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    put_private(conn, :ueberauth_request_options, [callback_path: "/auth/p/callback"] ++ options)
  end

  describe "callback_url/1 with forwarded headers" do
    @forwarded [{"x-forwarded-host", "proxy.example.org"}, {"x-forwarded-proto", "https"}]

    test "ignores the headers when trust_forwarded_headers is not set" do
      conn = conn_with_options(@forwarded, [])
      assert Helpers.callback_url(conn) == "http://www.example.com/auth/p/callback"
    end

    test "ignores the headers when trust_forwarded_headers is false" do
      conn = conn_with_options(@forwarded, trust_forwarded_headers: false)
      assert Helpers.callback_url(conn) == "http://www.example.com/auth/p/callback"
    end

    test "uses the headers when trust_forwarded_headers is true" do
      conn = conn_with_options(@forwarded, trust_forwarded_headers: true)
      assert Helpers.callback_url(conn) == "https://proxy.example.org/auth/p/callback"
    end

    test "uses values applied by Plug.RewriteOn" do
      conn =
        [{"x-forwarded-host", "proxy.example.org"}, {"x-forwarded-proto", "https"}]
        |> conn_with_options([])
        |> Plug.RewriteOn.call(Plug.RewriteOn.init([:x_forwarded_host, :x_forwarded_proto]))

      assert Helpers.callback_url(conn) == "https://proxy.example.org/auth/p/callback"
    end
  end

  describe "state_cookie_name/1" do
    test "includes the provider name" do
      conn = put_private(conn(:get, "/"), :ueberauth_request_options, strategy_name: :github)
      assert Helpers.state_cookie_name(conn) == "ueberauth.state_param.github"
    end

    test "falls back to the shared name without provider options" do
      assert Helpers.state_cookie_name(conn(:get, "/")) == "ueberauth.state_param"
    end
  end

  describe "callback_url/1 host parsing" do
    test "supports IPv6 literal hosts" do
      conn =
        conn_with_options([{"x-forwarded-host", "[::1]:4000"}], trust_forwarded_headers: true)

      assert Helpers.callback_url(conn) == "http://[::1]:4000/auth/p/callback"
    end

    for host <- ["evil.com:abc", "evil.com:99999", "user@evil.com", "evil.com/path", "a b", ""] do
      test "falls back to the connection host for #{inspect(host)}" do
        conn =
          conn_with_options([{"x-forwarded-host", unquote(host)}], trust_forwarded_headers: true)

        assert Helpers.callback_url(conn) == "http://www.example.com/auth/p/callback"
      end
    end
  end

  describe "trust_forwarded_headers option" do
    setup do
      Application.put_env(:ueberauth_helpers_test, Ueberauth, trust_forwarded_headers: false)
      on_exit(fn -> Application.delete_env(:ueberauth_helpers_test, Ueberauth) end)
    end

    test "is read from the provider options" do
      conn =
        Ueberauth.run_request(
          conn(:get, "/auth/p", id: "foo"),
          "p",
          {Support.SimpleProvider, [trust_forwarded_headers: true]}
        )

      assert conn.private.ueberauth_request_options.trust_forwarded_headers == true
    end

    test "falls back to the application config" do
      conn =
        Ueberauth.run_request(conn(:get, "/auth/p", id: "foo"), "p", {Support.SimpleProvider, []},
          otp_app: :ueberauth_helpers_test
        )

      assert conn.private.ueberauth_request_options.trust_forwarded_headers == false
    end

    test "provider options take precedence over the application config" do
      conn =
        Ueberauth.run_request(
          conn(:get, "/auth/p", id: "foo"),
          "p",
          {Support.SimpleProvider, [trust_forwarded_headers: true]},
          otp_app: :ueberauth_helpers_test
        )

      assert conn.private.ueberauth_request_options.trust_forwarded_headers == true
    end
  end
end
