defmodule UeberauthAppleTest do
  use ExUnit.Case

  @fake_private_key """
  -----BEGIN EC PRIVATE KEY-----
  MHcCAQEEIOAhEcYDdkJT7QZw56H7+IXPKX5zLTZjAc/ZJz16e/AkoAoGCCqGSM49
  AwEHoUQDQgAEx76p7zhaMjrVVV1SfYOMWLvDPQ4sZG/DF41om2i1aKa0jE92ptRp
  DBYomhI7Y5IoN7buLZpUixZZV00bl2xQOg==
  -----END EC PRIVATE KEY-----
  """

  describe "generate_client_secret/1" do
    test "generates a token" do
      token =
        UeberauthApple.generate_client_secret(
          client_id: "com.example.my-app",
          key_id: "key-abc123",
          private_key: @fake_private_key,
          team_id: "team-abc123"
        )

      assert is_binary(token)

      assert %JOSE.JWS{alg: {:jose_jws_alg_ecdsa, :ES256}, fields: %{"kid" => "key-abc123"}} =
               JOSE.JWT.peek_protected(token)
    end
  end
end
