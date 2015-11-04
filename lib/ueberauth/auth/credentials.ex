defmodule Ueberauth.Auth.Credentials do
  @moduledoc """
  Provides information about the credentials of a request.
  """
  defstruct token: nil, # Supplied by OAuth and OAuth 2.0 providers, the access token.
            refresh_token: nil, # Supplied by OAuth 2.0 providers as the refresh token.
            secret: nil, # Supplied by OAuth providers, the access token secret.
            expires: nil, # Boolean indicating whether the access token has an expiry date
            expires_at: nil, # Timestamp of the expiry time. Facebook and Google Plus return this. Twitter, LinkedIn don't.
            other: %{} # Other credentials that may not fit in the other fields.
end
