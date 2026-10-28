defmodule Earmark.Message do
  alias Earmark.Options
  @moduledoc false

  def emit_messages(messages, %Options{file: file}) do
    messages
    |> Enum.each(&emit_message(file, &1))
  end

  def emit_messages(messages, proplist) when is_list(proplist) do
    messages
    |> Enum.each(&emit_message(proplist[:file], &1))
  end

  defp emit_message(filename, msg), do: IO.puts(:stderr, format_message(filename, msg))

  defp format_message(filenale, message)

  defp format_message(nil, {type, line, text}) do
    "<no file>:#{line}: #{type}: #{text}"
  end

  defp format_message(filename, {type, line, text}) do
    "#{filename}:#{line}: #{type}: #{text}"
  end
end

# SPDX-License-Identifier: Apache-2.0
