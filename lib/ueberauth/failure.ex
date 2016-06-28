defmodule Ueberauth.Failure do
  @moduledoc """
  The struct provided to indicate a failure of authentication.

  All errors are provided by the relevant strategy.
  """

  @type t :: %__MODULE__{
              provider: binary,
              strategy: module,
              errors: list(Ueberauth.Failure.Error)
             }

  defstruct provider: nil, # the provider name
            strategy: nil, # the strategy module tha ran
            errors: [] # Ueberauth.Failure.Error collection of strategy defined errors
end
