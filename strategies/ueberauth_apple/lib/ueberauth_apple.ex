defmodule UeberauthApple do
  @moduledoc """
  UeberauthApple is a convenience module related to the Apple strategy for Ueberauth.

  For more information, see the [Overview](README.md).
  """

  @default_expires_in 86400 * 180

  @doc """
  Generate a Client Secret from the given options.

  This function does not concern itself with caching. Because generation of the Client Secret can
  be costly on every request, it is recommended to wrap this function with a cache-aware function.

  ## Options

    * `:client_id`: (**Required**) Reverse-domain Services ID configured for _Sign In with Apple_.

    * `:expires_in`: Duration, in number of seconds, for the secret to be valid. Apple specifies
      a maximum duration of `#{@default_expires_in}` seconds (6 months), which is the default.

    * `:key_id`: (**Required**) Key ID for the Apple-generated Private Key associated with the
      Services ID given in `:client_id`.

    * `:private_key` (**Required**) Full text of the Apple-generated Private Key file associated
      with the Services ID given in `:client_id`.

    * `:team_id`: (**Required**) Apple Developer Program team ID, as found in the top-right of the
      Apple Developer Console.

  ## Examples

  Below is an example of a client secret generator that maintains an expiring cache of the secret.

      defmodule MyApp.Apple
        @expiration_sec 86400 * 180

        @spec client_secret(keyword) :: String.t()
        def client_secret(_config \\\\ []) do
          with {:error, :not_found} <- get_client_secret_from_cache() do
            secret =
              UeberauthApple.generate_client_secret(%{
                client_id: Application.fetch_env!(:my_app, :apple_client_id),
                expires_in: @expiration_sec,
                key_id: Application.fetch_env!(:my_app, :apple_private_key_id),
                team_id: Application.fetch_env!(:my_app, :apple_team_id),
                private_key: Application.fetch_env!(:my_app, :apple_private_key)
              })

            put_client_secret_in_cache(secret, @expiration_sec)
            secret
          end
        end
      end
  """
  @spec generate_client_secret(map | keyword) :: String.t()
  def generate_client_secret(opts) do
    opts = Enum.into(opts, %{expires_in: @default_expires_in})
    now = DateTime.utc_now() |> DateTime.to_unix()

    jwk = JOSE.JWK.from_pem(opts.private_key)
    jws = %{"alg" => "ES256", "kid" => opts.key_id}

    jwt = %{
      "iss" => opts.team_id,
      "iat" => now,
      "exp" => now + opts.expires_in,
      "aud" => "https://appleid.apple.com",
      "sub" => opts.client_id
    }

    {_, token} = jwk |> JOSE.JWT.sign(jws, jwt) |> JOSE.JWS.compact()
    token
  end
end
