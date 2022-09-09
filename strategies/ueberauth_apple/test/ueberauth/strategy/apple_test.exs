defmodule Ueberauth.Strategy.AppleTest do
  use ExUnit.Case
  use Plug.Test

  alias Ueberauth.Strategy.Apple

  describe "handle_request!/1" do
    setup do
      conn =
        conn(:get, "/auth/apple", %{})
        |> put_private(:ueberauth_request_options, %{
          callback_methods: ["POST"],
          callback_params: nil,
          callback_path: "/auth/apple/callback",
          callback_port: nil,
          callback_scheme: nil,
          callback_url: "https://my-app.example.com/auth/apple/callback",
          options: [
            callback_url: "https://my-app.example.com/auth/apple/callback",
            default_scope: "name email",
            callback_methods: ["POST"]
          ],
          request_path: "/auth/apple",
          request_port: nil,
          request_scheme: nil,
          strategy: Ueberauth.Strategy.Apple,
          strategy_name: :apple
        })
        |> put_private(:ueberauth_state_param, "state-abc123")
        |> put_resp_cookie("ueberauth.state_param", "state-abc123")

      %{conn: conn}
    end

    test "redirects to Apple sign-in", %{conn: conn} do
      conn = Apple.handle_request!(conn)
      assert {302, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page} = Enum.into(headers, %{})
      assert sign_in_page =~ "https://appleid.apple.com/auth/authorize"
    end

    # Scopes

    test "allows a custom scope parameter", %{conn: conn} do
      conn = %{conn | params: %{"scope" => "email"}}
      conn = Apple.handle_request!(conn)
      assert {302, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page} = Enum.into(headers, %{})
      assert sign_in_page =~ "scope=email"
    end

    test "uses GET callbacks when no scopes are used", %{conn: conn} do
      conn = %{conn | params: %{"scope" => ""}}
      conn = Apple.handle_request!(conn)
      assert {302, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page} = Enum.into(headers, %{})
      refute sign_in_page =~ "response_mode"
    end

    test "uses POST callbacks when scopes are used", %{conn: conn} do
      conn = Apple.handle_request!(conn)
      assert {302, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page} = Enum.into(headers, %{})
      assert sign_in_page =~ "response_mode=form_post"
    end

    # Nonce

    test "allows a custom nonce parameter", %{conn: conn} do
      conn = %{conn | params: %{"nonce" => "nonce-abc123"}}
      conn = Apple.handle_request!(conn)
      assert {302, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page} = Enum.into(headers, %{})
      assert sign_in_page =~ "nonce=nonce-abc123"
    end

    # State

    test "sets state cookie", %{conn: conn} do
      conn = Apple.handle_request!(conn)
      assert {_status, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page, "set-cookie" => cookie} = Enum.into(headers, %{})
      assert cookie =~ "ueberauth.state_param=state-abc123"
      assert cookie =~ "secure"
      assert cookie =~ "SameSite=None"
      assert sign_in_page =~ "state=state-abc123"
    end

    test "forces SameSite=None and Secure cookies for POST callbacks", %{conn: conn} do
      conn = Apple.handle_request!(conn)
      assert {_status, headers, _body} = sent_resp(conn)
      assert %{"set-cookie" => cookie} = Enum.into(headers, %{})
      assert cookie =~ "secure"
      assert cookie =~ "SameSite=None"
    end

    # Client

    test "sets client ID based on configuration", %{conn: conn} do
      conn = Apple.handle_request!(conn)
      assert {302, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page} = Enum.into(headers, %{})
      assert sign_in_page =~ "client_id=com.example.my-app"
    end

    # Redirect URI

    test "sets redirect URI based on configuration", %{conn: conn} do
      conn = Apple.handle_request!(conn)
      assert {302, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page} = Enum.into(headers, %{})

      assert sign_in_page =~
               "redirect_uri=https%3A%2F%2Fmy-app.example.com%2Fauth%2Fapple%2Fcallback"
    end
  end

  describe "handle_callback!/1" do
    setup do
      conn =
        conn(:post, "/auth/apple/callback", %{
          "code" => "code-abc123",
          "id_token" => "token-abc123",
          "state" => "state-abc123"
        })
        |> put_private(:ueberauth_request_options, %{
          callback_methods: ["POST"],
          callback_params: nil,
          callback_path: "/auth/apple/callback",
          callback_port: nil,
          callback_scheme: nil,
          callback_url: "https://my-app.example.com/auth/apple/callback",
          options: [
            callback_url: "https://my-app.example.com/auth/apple/callback",
            default_scope: "name email",
            callback_methods: ["POST"],
            public_keys: {UeberauthApple.Keys, :public_keys, []}
          ],
          request_path: "/auth/apple",
          request_port: nil,
          request_scheme: nil,
          strategy: Ueberauth.Strategy.Apple,
          strategy_name: :apple
        })

      jwk = UeberauthApple.Keys.private_key()

      token =
        JOSE.JWT.sign(jwk, %{"alg" => "RS256", "kid" => "key-abc123"}, %{
          "aud" => "com.example.my-app",
          "email" => "email-abc123@privaterelay.appleid.com",
          "email_verified" => "true",
          "exp" => 1_662_834_127,
          "iat" => 1_662_747_727,
          "is_private_email" => "true",
          "iss" => "https://appleid.apple.com",
          "nonce_supported" => true,
          "sub" => "uid-abc123"
        })
        |> JOSE.JWS.compact()
        |> elem(1)

      %{conn: conn, token: token}
    end

    test "handles an error response", %{conn: conn} do
      conn = %{conn | params: %{"error" => "some error"}}
      conn = Apple.handle_callback!(conn)
      assert conn.assigns[:ueberauth_failure]
    end

    test "does stuff", %{conn: conn, token: token} do
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)
      # ...
    end
  end
end
