defmodule Ueberauth.Failure.Error do
  @moduledoc """
  A specific error for a failed authentication attempt.

  The message_key may be used to identify fields or other machine interpreted
  methods like translation. The message field is for a human readable message
  indicating the cause of the error.
  """
  @type t :: %__MODULE__{
              message_key: binary,
              message: binary
             }

  defstruct message_key: nil,
            message: nil
end
