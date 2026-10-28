defmodule Ueberauth.Strategy.HelpersTest do
  # Not async: the forwarded-header warning is logged once per VM, tracked in
  # :persistent_term, which these tests reset.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Ueberauth.Strategy.Helpers

  @warned_key {Helpers, :warned_untrusted_forwarded_headers}

  setup do
    :persistent_term.erase(@warned_key)
    on_exit(fn -> :persistent_term.erase(@warned_key) end)
  end

  defp conn_with_options(headers, options) do
    conn =
      Enum.reduce(headers, conn(:get, "/"), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    put_private(conn, :ueberauth_request_options, [callback_path: "/auth/p/callback"] ++ options)
  end

  describe "callback_url/1 with forwarded headers" do
    @forwarded [{"x-forwarded-host", "proxy.example.org"}, {"x-forwarded-proto", "https"}]

    test "uses the headers and warns once when trust_forwarded_headers is not set" do
      conn = conn_with_options(@forwarded, [])

      log =
        capture_log(fn ->
          assert Helpers.callback_url(conn) == "https://proxy.example.org/auth/p/callback"
        end)

      assert log =~ "X-Forwarded-Host or X-Forwarded-Proto"
      assert log =~ "trust_forwarded_headers"

      assert capture_log(fn -> Helpers.callback_url(conn) end) == ""
    end

    test "does not warn when no forwarded header changes the URL" do
      conn = conn_with_options([{"x-forwarded-proto", "http"}], [])

      assert capture_log(fn ->
               assert Helpers.callback_url(conn) == "http://www.example.com/auth/p/callback"
             end) == ""
    end

    test "ignores the headers when trust_forwarded_headers is false" do
      conn = conn_with_options(@forwarded, trust_forwarded_headers: false)

      assert capture_log(fn ->
               assert Helpers.callback_url(conn) == "http://www.example.com/auth/p/callback"
             end) == ""
    end

    test "uses the headers without warning when trust_forwarded_headers is true" do
      conn = conn_with_options(@forwarded, trust_forwarded_headers: true)

      assert capture_log(fn ->
               assert Helpers.callback_url(conn) == "https://proxy.example.org/auth/p/callback"
             end) == ""
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
