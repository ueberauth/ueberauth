defmodule Ueberauth.Failure do
  @moduledoc """
  The struct provided to indicate a failure of authentication.

  All errors are provided by the relevant strategy.
  """

  @typedoc """
  Captures the information pertaining to a request failure

  + `:errors` - Ueberauth.Failure.Error collection of strategy defined errors
  + `:provider` - The provider name as defined in the configuration
  + `:strategy` - The strategy module used
  + `:uid` - An identifier unique to the given provider, such as a Twitter user ID. Should be stored as a string
  """
  @type t :: %__MODULE__{
          errors: list(Ueberauth.Failure.Error),
          provider: binary(),
          strategy: module()
        }

  defstruct errors: [],
            provider: nil,
            strategy: nil
end
