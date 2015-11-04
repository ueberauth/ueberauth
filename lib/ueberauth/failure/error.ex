defmodule Ueberauth.Failure.Error do
  @moduledoc """
  A specific error for a failed authentication attempt.
  The message_key may be used to identify fields or other machine interperated methods like translation
  The message field is for a human readable message indicating the cause of the error.
  """
  defstruct message_key: nil,
            message: nil
end
