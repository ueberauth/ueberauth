defmodule Ueberauth.Auth.Extra do
  @moduledoc """
  Provides a place for all raw information that was accumulated during the
  processing of the callback phase.
  """

  @typedoc """
  The Extra module contains a `raw_info` field that includes all information gathered about a use.
  In the example of Twitter, this will represent the user's information returned from the Twitter API.
  """
  @type t :: %__MODULE__{
    raw_info: map
  }

  defstruct raw_info: %{}
end
