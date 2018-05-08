defmodule Ueberauth.Auth.Credentials do
  @moduledoc """
  Provides information about the credentials of a request.
  """

  @type t :: %__MODULE__{
          token: binary | nil,
          refresh_token: binary | nil,
          token_type: String.t() | nil,
          secret: binary | nil,
          expires: boolean | nil,
          expires_at: number | nil,
          scopes: list(String.t()),
          other: map
        }

  # Supplied by OAuth and OAuth 2.0 providers, the access token.
  defstruct token: nil,
            # Supplied by OAuth 2.0 providers as the refresh token.
            refresh_token: nil,
            # The type of token provided
            token_type: nil,
            # Supplied by OAuth providers, the access token secret.
            secret: nil,
            # Boolean indicating whether the access token has an expiry date
            expires: nil,
            # Timestamp of the expiry time. Facebook and Google Plus return this. Twitter, LinkedIn don't.
            expires_at: nil,
            # A list of scopes/permissions that were granted
            scopes: [],
            # Other credentials that may not fit in the other fields.
            other: %{}
end
