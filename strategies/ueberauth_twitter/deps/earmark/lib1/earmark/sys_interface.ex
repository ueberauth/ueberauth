defmodule Earmark.SysInterface do

  @doc """
  A proxy to IO.stream(..., :line) or usage with a filename
  """
  def readlines(device_or_filename)
  def readlines(filename) when is_binary(filename) do
    case File.open(filename, [:utf8]) do
      {:ok, device} -> readlines(device)
      {:error, _} = error    -> error
    end
  end
  def readlines(device) do
    IO.stream(device, :line)
  end
end
#  SPDX-License-Identifier: Apache-2.0
