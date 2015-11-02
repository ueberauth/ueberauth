defmodule Ueberauth.Auth.Info do
  import Ueberauth.Utils

  alias Ueberauth.Auth.Info

  defstruct name: nil,
            first_name: nil,
            last_name: nil,
            nickname: nil,
            email: nil,
            location: nil,
            description: nil,
            image: nil,
            phone: nil,
            urls: %{}

  def valid?(%Info{ name: name}) when is_binary(name), do: true
  def valid?(_), do: false

  def from_params(params), do: struct_from_params(__MODULE__, params)
end
