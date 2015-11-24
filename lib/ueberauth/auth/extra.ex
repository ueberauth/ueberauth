defmodule Ueberauth.Auth.Extra do
  @moduledoc """
  Provides a place for all raw information that was accumulated during the
  processing of the callback phase.
  """

  @type t :: %__MODULE__{
              raw_info: map
             }
  defstruct raw_info: %{} # A map of all information gathered about a user in the format it was gathered. For example, for Twitter users this is a map representing the JSON hash returned from the Twitter API.
end
