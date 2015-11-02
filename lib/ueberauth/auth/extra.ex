defmodule Ueberauth.Auth.Extra do
  import Ueberauth.Utils

  defstruct raw_info: %{}

  def from_params(params), do: struct_from_params(__MODULE__, params)
end
