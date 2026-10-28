defmodule EarmarkParser.Ast.Emitter do
  @moduledoc false

  def emit(tag, content \\ [], atts \\ [], meta \\ %{})

  def emit(tag, content, atts, meta) when is_binary(content) or is_tuple(content) do
    {tag, _to_atts(atts), [content], meta}
  end

  def emit(tag, content, atts, meta) do
    {tag, _to_atts(atts), content, meta}
  end

  defp _to_atts(atts)

  defp _to_atts(nil) do
    []
  end

  defp _to_atts(atts) when is_map(atts) do
    atts
    |> Enum.into([])
    |> Enum.map(fn {name, value} -> {to_string(name), _to_string(value)} end)
  end

  defp _to_atts(atts) do
    atts
    |> Enum.map(fn {name, value} -> {to_string(name), _to_string(value)} end)
  end

  defp _to_string(value)

  defp _to_string(value) when is_list(value) do
    Enum.join(value, " ")
  end

  defp _to_string(value) do
    to_string(value)
  end
end

# SPDX-License-Identifier: Apache-2.0
