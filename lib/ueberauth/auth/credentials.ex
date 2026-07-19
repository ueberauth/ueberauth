defmodule Ueberauth.Auth.Credentials do
  @moduledoc """
  Provides information about the credentials of a request.
  """

  @typedoc """
  Information about the credentials of a request.

  - `token` - The access token supplied by OAuth and OAuth 2.0 providers.
  - `refresh_token` - The refresh token supplied by OAuth 2.0 providers.
  - `token_type` - The type of token provided.
  - `secret` - The access token secret supplied by OAuth providers.
  - `expires` - Boolean indicating whether the access token has an expiry date.
  - `expires_at` - Timestamp of the expiry time. Facebook and Google return
    this. Twitter, LinkedIn don't.
  - `scopes` - A list of scopes/permissions that were granted.
  - `other` - Other credentials that may not fit in the other fields.
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

  defstruct token: nil,
            refresh_token: nil,
            token_type: nil,
            secret: nil,
            expires: nil,
            expires_at: nil,
            scopes: [],
            other: %{}
end
