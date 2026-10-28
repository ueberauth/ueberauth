defmodule Earmark.Error do

  @moduledoc false

  defexception [:message]

  @type t :: %__MODULE__{message: binary()}

  @doc false
  def exception(msg), do: %__MODULE__{message: msg}

end

# SPDX-License-Identifier: Apache-2.0
