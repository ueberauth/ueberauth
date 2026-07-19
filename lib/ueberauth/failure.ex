defmodule Ueberauth.Failure do
  @moduledoc """
  The struct provided to indicate a failure of authentication.

  All errors are provided by the relevant strategy.
  """

  @typedoc """
  Holds information about a failed callback phase.

  - `provider` - The provider name.
  - `strategy` - The strategy module used.
  - `error` - `Ueberauth.Failure.Error` collection of strategy defined errors.
  """
  @type t :: %__MODULE__{
          provider: atom,
          strategy: module,
          errors: list(Ueberauth.Failure.Error.t())
        }

  defstruct provider: nil,
            strategy: nil,
            errors: []
end
