defmodule UeberauthApple do
  @default_expires_in 86400 * 180
  @public_key_url "https://appleid.apple.com/auth/keys"

  def uid_from_id_token(id_token) do
    with keys <- fetch_public_keys(),
         key <- get_appropriate_key(keys, id_token),
         {true, %JOSE.JWT{fields: fields}, _JWS} <- JOSE.JWT.verify(key, id_token),
         {:ok, uid} <- {:ok, fields["sub"]} do
      uid
    end
  end

  # As of Feb 12th 2020, this fetches a list of public keys from Apple
  defp fetch_public_keys() do
    {:ok, %{body: response_body}} = HTTPoison.get(@public_key_url)

    Ueberauth.json_library().decode!(response_body)["keys"]
  end

  defp get_appropriate_key(keys, id_token) do
    # Extracts the Key ID (kid) from JWT headers
    %JOSE.JWS{fields: %{"kid" => kid}} = JOSE.JWT.peek_protected(id_token)

    # Select the public key corresponding to the right kid
    Enum.find(keys, fn x -> x["kid"] == kid end)
  end

  @doc """
  Generates client secret.
  """
  def generate_client_secret(
        %{client_id: client_id, key_id: key_id, team_id: team_id, private_key: private_key} =
          options
      ) do
    opts = Enum.into(options, %{expires_in: @default_expires_in})
    now = DateTime.utc_now() |> DateTime.to_unix()
    jwk = JOSE.JWK.from_pem(private_key)
    jws = %{"alg" => "ES256", "kid" => key_id}

    jwt = %{
      "iss" => team_id,
      "iat" => now,
      "exp" => now + opts[:expires_in],
      "aud" => "https://appleid.apple.com",
      "sub" => client_id
    }

    {_, token} = jwk |> JOSE.JWT.sign(jws, jwt) |> JOSE.JWS.compact()
    token
  end

  def generate_client_secret(opts) when is_list(opts),
    do: opts |> Enum.into(%{}) |> generate_client_secret()
end
