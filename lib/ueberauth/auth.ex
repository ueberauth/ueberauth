defmodule Ueberauth.Auth do
  @moduledoc """
  The struct provided to indicate a success of the callback phase.

  This struct is constructed by the strategy by using functions defined in the
  strategy and is provided to the downstream plug in the connections assigns
  `:ueberauth_auth` key.
  """

  alias Ueberauth.Auth
  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @type t :: %__MODULE__{
          uid: String.t(),
          provider: String.t() | atom,
          strategy: module,
          info: Info.t(),
          credentials: Credentials.t(),
          extra: Extra.t()
        }

  # An identifier unique to the given provider, such as a Twitter user ID. Should be stored as a string.
  defstruct uid: nil,
            # The provider name as defined in the configuration.
            provider: nil,
            # The strategy module used
            strategy: nil,
            # An info struct about the user. See Ueberauth.Auth.Info
            info: %Info{},
            # A struct containing information on the credentials. See Ueberauth.Auth.Credentials
            credentials: %Credentials{},
            # Any additional information that may be available. See Ueberauth.Auth.Extra
            extra: %Extra{}

  def valid?(%Auth{} = auth),
    do: !!(auth.uid && auth.provider && auth.info && Info.valid?(auth.info))

  def valid?(_), do: false
end
