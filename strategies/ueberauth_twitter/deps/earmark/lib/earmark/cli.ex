defmodule Earmark.Cli do
  @moduledoc """
  The Earmark CLI

  Entry point of the escript, this is the **only** point that does IO with output and it uses the `Earmark.File` module which
  is the **only** point that does IO with input.

  """
  @doc """
  This is the entry point of the escript
  """
  def main(argv) do
    argv
    |> Earmark.Cli.Implementation.run()
    |> output()
  end

  @doc ~S"""
  A convenience wrapper around `Earmark.Cli.Implementation.run/1` it will return `str` in case `{:stdio, str}` is returned
  or raise an error otherwise

      iex(0)> run!(["test/fixtures/short1.md"])
      "<h1>\nHeadline1</h1>\n<hr class=\"thin\">\n<h2>\nHeadline2</h2>\n"
  """
  def run!(argv) do
    case Earmark.Cli.Implementation.run(argv) do
      {:stdio, output} -> output
      {_, error} -> raise Earmark.Error, error
    end
  end

  defp output({device, string}) do
    IO.puts(device, string)
    if device == :stderr, do: exit(1)
  end
end

#  SPDX-License-Identifier: Apache-2.0
