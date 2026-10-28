defmodule Ueberauth.Strategy.AppleTest do
  use ExUnit.Case, async: false
  use Mimic
  import Plug.Conn
  import Plug.Test

  alias Ueberauth.Strategy.Apple

  setup do
    OAuth2.Client
    |> stub(:get_token, fn _client, _params ->
      {:ok,
       %OAuth2.Client{
         token: %OAuth2.AccessToken{
           access_token: "access-abc123",
           expires_at: 1_662_751_328,
           other_params: %{
             "id_token" => "token-abc123"
           },
           refresh_token: "refresh-abc123",
           token_type: "Bearer"
         }
       }}
    end)

    :ok
  end

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
        |> put_resp_cookie("ueberauth.state_param.apple", "state-abc123")

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

    # Nonce (Ueberauth State)

    test "sets state cookie and uses it as nonce", %{conn: conn} do
      conn = Apple.handle_request!(conn)
      assert {_status, headers, _body} = sent_resp(conn)
      assert %{"location" => sign_in_page, "set-cookie" => cookie} = Enum.into(headers, %{})
      assert cookie =~ "ueberauth.state_param.apple=state-abc123"
      assert cookie =~ "secure"
      assert cookie =~ "SameSite=None"

      # We use "nonce" as an anti-replay mechanism.
      assert sign_in_page =~ "nonce=state-abc123"

      # Ueberauth requires uses "state" as a CSRF protection mechanism.
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
        |> put_req_cookie("ueberauth.state_param.apple", "nonce-abc123")

      token = sign_id_token()

      %{conn: conn, token: token}
    end

    test "handles an error response", %{conn: conn} do
      conn = %{conn | params: %{"error" => "some error"}}
      conn = Apple.handle_callback!(conn)
      assert conn.assigns[:ueberauth_failure]
    end

    test "retrieves Apple user and token", %{conn: conn, token: token} do
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)
      assert %OAuth2.AccessToken{access_token: "access-abc123"} = conn.private[:apple_token]

      assert conn.private[:apple_user] == %{
               "email" => "email-abc123@privaterelay.appleid.com",
               "uid" => "uid-abc123"
             }
    end

    test "rejects callback with invalid issuer", %{conn: conn} do
      token = sign_id_token(%{"iss" => "https://evil.example"})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert conn.assigns[:ueberauth_failure]

      assert [
               %{
                 message: "Error while reading authentication token",
                 message_key: "invalid_issuer"
               }
             ] =
               conn.assigns.ueberauth_failure.errors
    end

    test "rejects callback with invalid audience", %{conn: conn} do
      token = sign_id_token(%{"aud" => "com.example.other-app"})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert conn.assigns[:ueberauth_failure]

      assert [
               %{
                 message: "Error while reading authentication token",
                 message_key: "invalid_audience"
               }
             ] = conn.assigns.ueberauth_failure.errors
    end

    test "allows callback with expired token within clock skew", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = sign_id_token(%{"exp" => now - 55})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      refute conn.assigns[:ueberauth_failure]
    end

    test "rejects callback with expired token", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = sign_id_token(%{"exp" => now - 65})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert conn.assigns[:ueberauth_failure]

      assert [
               %{
                 message: "Error while reading authentication token",
                 message_key: "expired_token"
               }
             ] =
               conn.assigns.ueberauth_failure.errors
    end

    test "rejects callback with null-signed token", %{conn: conn} do
      JOSE.unsecured_signing(true)

      now = DateTime.utc_now() |> DateTime.to_unix()

      claims = %{
        "aud" => "com.example.my-app",
        "email" => "email-abc123@privaterelay.appleid.com",
        "email_verified" => "true",
        "exp" => now + 600,
        "iat" => now - 60,
        "is_private_email" => "true",
        "iss" => "https://appleid.apple.com",
        "nonce" => "nonce-abc123",
        "nonce_supported" => true,
        "sub" => "uid-abc123"
      }

      kid = UeberauthApple.Keys.private_key().fields["kid"]

      token =
        JOSE.JWT.sign(%JOSE.JWK{}, %{"alg" => "none", "typ" => "JWT", "kid" => kid}, claims)
        |> JOSE.JWS.compact()
        |> elem(1)

      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert conn.assigns[:ueberauth_failure]

      assert [
               %{
                 message: "Error while reading authentication token",
                 message_key: "invalid_signature"
               }
             ] =
               conn.assigns.ueberauth_failure.errors
    end

    test "accepts callback when iat is within skew", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = sign_id_token(%{"iat" => now + 30})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert %OAuth2.AccessToken{access_token: "access-abc123"} = conn.private[:apple_token]
    end

    test "rejects callback when iat is beyond skew", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = sign_id_token(%{"iat" => now + 120})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert conn.assigns[:ueberauth_failure]

      assert [
               %{
                 message: "Error while reading authentication token",
                 message_key: "not_yet_valid_token"
               }
             ] = conn.assigns.ueberauth_failure.errors
    end

    test "rejects callback when expected audience is unavailable", %{conn: conn, token: token} do
      original_oauth_config = Application.get_env(:ueberauth, Ueberauth.Strategy.Apple.OAuth, [])

      on_exit(fn ->
        Application.put_env(:ueberauth, Ueberauth.Strategy.Apple.OAuth, original_oauth_config)
      end)

      oauth_config_without_client_id = Keyword.delete(original_oauth_config, :client_id)

      Application.put_env(
        :ueberauth,
        Ueberauth.Strategy.Apple.OAuth,
        oauth_config_without_client_id
      )

      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert conn.assigns[:ueberauth_failure]

      assert [
               %{
                 message: "Error while reading authentication token",
                 message_key: "missing_expected_audience"
               }
             ] = conn.assigns.ueberauth_failure.errors
    end

    test "rejects callback when nonce is supported but does not match", %{conn: conn} do
      token = sign_id_token(%{"nonce" => "nonce-xyz789"})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert conn.assigns[:ueberauth_failure]

      assert [
               %{
                 message: "Error while reading authentication token",
                 message_key: "invalid_nonce"
               }
             ] = conn.assigns.ueberauth_failure.errors
    end

    test "accepts empty nonce when nonce is not supported", %{conn: conn} do
      token = sign_id_token(%{"nonce_supported" => false, "nonce" => nil})
      conn = %{conn | params: %{conn.params | "id_token" => token}}
      conn = Apple.handle_callback!(conn)

      assert %OAuth2.AccessToken{access_token: "access-abc123"} = conn.private[:apple_token]
    end
  end

  describe "cleanup" do
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
        |> put_private(:apple_token, %OAuth2.AccessToken{
          access_token: "access-abc123",
          expires_at: 1_662_751_328,
          other_params: %{"id_token" => "token-abc123"},
          refresh_token: "refresh-abc123",
          token_type: "Bearer"
        })
        |> put_private(:apple_user, %{
          "email" => "email-abc123@privaterelay.appleid.com",
          "uid" => "uid-abc123"
        })

      %{conn: conn}
    end

    test "collects UID, credentials, and info", %{conn: conn} do
      assert Apple.uid(conn) == "uid-abc123"

      assert %Ueberauth.Auth.Credentials{
               expires: true,
               expires_at: 1_662_751_328,
               scopes: ["name", "email"],
               token_type: "Bearer",
               refresh_token: "refresh-abc123",
               token: "access-abc123"
             } = Apple.credentials(conn)

      assert %Ueberauth.Auth.Info{email: "email-abc123@privaterelay.appleid.com"} =
               Apple.info(conn)
    end
  end

  defp sign_id_token(overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    claims =
      Map.merge(
        %{
          "aud" => "com.example.my-app",
          "email" => "email-abc123@privaterelay.appleid.com",
          "email_verified" => "true",
          "exp" => now + 600,
          "iat" => now - 60,
          "is_private_email" => "true",
          "iss" => "https://appleid.apple.com",
          "nonce" => "nonce-abc123",
          "nonce_supported" => true,
          "sub" => "uid-abc123"
        },
        overrides
      )

    UeberauthApple.Keys.private_key()
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "key-abc123"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
