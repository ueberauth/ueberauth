defmodule Ueberauth.Auth.Credentials do
  import Ueberauth.Utils

  defstruct token: nil,
            refresh_token: nil,
            secret: nil,
            expires: nil,
            expires_at: nil

  def from_params(params), do: struct_from_params(__MODULE__, params)
end
