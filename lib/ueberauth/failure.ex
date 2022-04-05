defmodule Ueberauth.Failure do
  @moduledoc """
  The struct provided to indicate a failure of authentication.

  All errors are provided by the relevant strategy.
  """

  @type t :: %__MODULE__{
          provider: atom,
          strategy: module,
          errors: list(Ueberauth.Failure.Error.t())
        }

  # the provider name
  defstruct provider: nil,
            # the strategy module that ran
            strategy: nil,
            # Ueberauth.Failure.Error collection of strategy defined errors
            errors: []
end
