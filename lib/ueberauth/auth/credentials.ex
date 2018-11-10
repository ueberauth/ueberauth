defmodule Ueberauth.Auth.Credentials do
  @moduledoc """
  Provides information about the credentials of a request.
  """

  @typedoc """
  Information relating to the credentials of a request

  + `:token` - Supplied by OAuth and OAuth 2.0 providers, the access token
  + `:refresh_token` - Supplied by OAuth 2.0 providers as the refresh token
  + `:token_type` - The type of token provided
  + `:secret` - Supplied by OAuth providers, the access token secret
  + `:expires` - Boolean indicating whether the access token has an expiry date
  + `:expires_at` - Timestamp of the expiry time. Facebook and Google Plus return this, Twitter and LinkedIn do not
  + `:scopes` - A list of scopes/permissions that were granted
  + `:other` - Other credentials that may not fit in the other fields.
  """
  @type t :: %__MODULE__{
    expires: boolean | nil,
    expires_at: number | nil,
    other: map(),
    refresh_token: binary | nil,
    scopes: list(String.t()),
    secret: binary | nil,
    token: binary | nil,
    token_type: String.t() | nil
  }

  defstruct expires: nil,
            expires_at: nil,
            other: %{},
            refresh_token: nil,
            scopes: [],
            secret: nil,
            token: nil,
            token_type: nil
end
