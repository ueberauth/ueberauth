defmodule Ueberauth.Strategies.TestTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Ueberauth.Failure.Error
  alias Ueberauth.Strategy.Test

  describe "handle_callback!/1" do
    setup do
      user_data = %Test.UserData{
        uid: "123",
        credentials: %{token: "token"},
        extra: %{some: "extra"},
        info: %{name: "John Doe"},
        errors: []
      }

      [user_data: user_data]
    end

    test "handles empty errors", %{user_data: user_data} do
      conn = make_conn(user_data)
      assert Test.handle_callback!(conn) == conn
    end

    test "handles non-empty errors", %{user_data: user_data} do
      user_data = %Test.UserData{
        user_data
        | errors: [
            %Error{message_key: "an_error", message: "A Ueberauth error."}
          ]
      }

      conn = make_conn(user_data)
      result = Test.handle_callback!(conn)
      assert %Ueberauth.Failure{} = result.assigns.ueberauth_failure
    end
  end

  describe "handle_cleanup!/1" do
    test "cleans up private data" do
      conn = make_conn(%{})
      conn = Test.handle_cleanup!(conn)
      assert conn.private == %{ueberauth_testing_redirect: nil, ueberauth_testing_user: nil}
    end
  end

  describe "handle_request!/1" do
    test "redirects to default URL when no custom redirect is set" do
      conn = conn(:get, "/auth/simple")

      assert %Plug.Conn{
               halted: true,
               host: "www.example.com",
               method: "GET",
               resp_body:
                 "<html><body>You are being <a href=\"http://localhost:4002\">redirected</a>.</body></html>",
               resp_headers: [
                 {"cache-control", "max-age=0, private, must-revalidate"},
                 {"location", "http://localhost:4002"}
               ],
               status: 302
             } = Test.handle_request!(conn)
    end

    test "redirects to custom URL when set" do
      custom_url = "http://example.com"
      conn = conn(:get, "/auth/simple") |> Test.put_testing_url(custom_url)

      expected_body =
        "<html><body>You are being <a href=\"#{custom_url}\">redirected</a>.</body></html>"

      assert %Plug.Conn{
               halted: true,
               host: "www.example.com",
               method: "GET",
               resp_body: ^expected_body,
               resp_headers: [
                 {"cache-control", "max-age=0, private, must-revalidate"},
                 {"location", ^custom_url}
               ],
               status: 302
             } = Test.handle_request!(conn)
    end
  end

  describe "supplementary data functions" do
    setup do
      user_data = %Test.UserData{
        uid: "123",
        credentials: %{token: "token"},
        extra: %{some: "extra"},
        info: %{name: "John Doe"}
      }

      conn = make_conn(user_data)
      {:ok, conn: conn, user_data: user_data}
    end

    test "credentials/1 returns the correct data", %{conn: conn, user_data: user_data} do
      assert Test.credentials(conn) == user_data.credentials
    end

    test "extra/1 returns the correct data", %{conn: conn, user_data: user_data} do
      assert Test.extra(conn) == user_data.extra
    end

    test "uid/1 returns the correct data", %{conn: conn, user_data: user_data} do
      assert Test.uid(conn) == user_data.uid
    end

    test "info/1 returns the correct data", %{conn: conn, user_data: user_data} do
      assert Test.info(conn) == user_data.info
    end
  end

  defp make_conn(extra) do
    :get
    |> conn("/auth/simple/callback")
    |> Test.put_testing_user(extra)
  end
end
