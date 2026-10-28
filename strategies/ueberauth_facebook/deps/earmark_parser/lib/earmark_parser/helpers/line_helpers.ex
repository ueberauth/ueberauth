defmodule EarmarkParser.Helpers.LineHelpers do
  @moduledoc false

  alias EarmarkParser.Line

  def blank?(%Line.Blank{}) do
    true
  end

  def blank?(_) do
    false
  end

  def blockquote_or_text?(%Line.BlockQuote{}) do
    true
  end

  def blockquote_or_text?(struct) do
    text?(struct)
  end

  def indent_or_blank?(%Line.Indent{}) do
    true
  end

  def indent_or_blank?(line) do
    blank?(line)
  end

  # Gruber's tests have
  #
  #   para text...
  #   * and more para text
  #
  # So list markers inside paragraphs are ignored. But he also has
  #
  #   *   line
  #       * line
  #
  # And expects it to be a nested list. These seem to be in conflict
  #
  # I think the second is a better interpretation, so I commented
  # out the 2nd match below.
  def text?(%Line.Text{}) do
    true
  end

  def text?(%Line.TableLine{}) do
    true
  end

  #  def text?(%Line.ListItem{}), do: true
  def text?(_) do
    false
  end
end

# SPDX-License-Identifier: Apache-2.0
