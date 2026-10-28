defmodule Ueberauth.Strategy.TestTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Ueberauth.Auth
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra
  alias Ueberauth.Auth.Info
  alias Ueberauth.Failure
  alias Ueberauth.Failure.Error
  alias Ueberauth.Strategy.Test

  @routes Ueberauth.init()

  defp request(conn), do: Ueberauth.call(conn, @routes)

  describe "request phase" do
    test "redirects to the callback URL" do
      conn = :get |> conn("/auth/test") |> request()

      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["http://www.example.com/auth/test/callback"]
    end

    test "does not set a state cookie" do
      conn = :get |> conn("/auth/test") |> request()

      refute Map.has_key?(conn.resp_cookies, "ueberauth.state_param.test")
    end
  end

  describe "callback phase" do
    test "assigns default auth data when none is given" do
      conn = :get |> conn("/auth/test/callback") |> request()

      assert %Auth{
               provider: :test,
               strategy: Test,
               uid: "test-uid",
               info: %Info{},
               credentials: %Credentials{},
               extra: %Extra{}
             } = conn.assigns.ueberauth_auth
    end

    test "assigns the data given to put_auth/2" do
      conn =
        :get
        |> conn("/auth/test/callback")
        |> Test.put_auth(
          uid: "12345",
          info: %{email: "jane@example.com", name: "Jane Doe"},
          credentials: [token: "token", expires: false],
          extra: %Extra{raw_info: %{"login" => "jane"}}
        )
        |> request()

      assert %Auth{
               uid: "12345",
               info: %Info{email: "jane@example.com", name: "Jane Doe"},
               credentials: %Credentials{token: "token", expires: false},
               extra: %Extra{raw_info: %{"login" => "jane"}}
             } = conn.assigns.ueberauth_auth
    end

    test "uses the provider name it is configured under" do
      conn = :get |> conn("/auth/test_with_defaults/callback") |> request()

      assert conn.assigns.ueberauth_auth.provider == :test_with_defaults
    end

    test "falls back to provider options" do
      conn = :get |> conn("/auth/test_with_defaults/callback") |> request()

      assert %Auth{uid: "configured-uid", info: %Info{email: "configured@example.com"}} =
               conn.assigns.ueberauth_auth
    end

    test "put_auth/2 takes precedence over provider options per key" do
      conn =
        :get
        |> conn("/auth/test_with_defaults/callback")
        |> Test.put_auth(uid: "override-uid")
        |> request()

      assert %Auth{uid: "override-uid", info: %Info{email: "configured@example.com"}} =
               conn.assigns.ueberauth_auth
    end

    test "assigns a failure set with put_failure/3" do
      conn =
        :get
        |> conn("/auth/test/callback")
        |> Test.put_failure("invalid_code", "The code was invalid")
        |> request()

      refute Map.has_key?(conn.assigns, :ueberauth_auth)

      assert %Failure{
               provider: :test,
               strategy: Test,
               errors: [%Error{message_key: "invalid_code", message: "The code was invalid"}]
             } = conn.assigns.ueberauth_failure
    end

    test "put_failure/1 defaults to access_denied" do
      conn = :get |> conn("/auth/test/callback") |> Test.put_failure() |> request()

      assert [%Error{message_key: "access_denied"}] = conn.assigns.ueberauth_failure.errors
    end

    test "does not require a state param or state cookie" do
      conn = :get |> conn("/auth/test/callback", %{"state" => "anything"}) |> request()

      assert %Auth{} = conn.assigns.ueberauth_auth
    end
  end
end
