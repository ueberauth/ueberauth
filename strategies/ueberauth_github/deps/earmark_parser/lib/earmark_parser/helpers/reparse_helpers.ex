defmodule EarmarkParser.Helpers.ReparseHelpers do
  @moduledoc false

  alias EarmarkParser.Line

  @doc """
    Extract the verbatim text of `%EarmarkParser.Line.t` elements with less alignment so that
    it can be reparsed (as elements of footnotes or indented code)
  """
  # Add additional spaces for any indentation past level 1
  def properly_indent(%Line.Indent{level: level, content: content}, target_level)
      when level == target_level do
    content
  end

  def properly_indent(%Line.Indent{level: level, content: content}, target_level)
      when level > target_level do
    String.duplicate("    ", level - target_level) <> content
  end

  def properly_indent(line, _) do
    line.content
  end
end

# SPDX-License-Identifier: Apache-2.0
