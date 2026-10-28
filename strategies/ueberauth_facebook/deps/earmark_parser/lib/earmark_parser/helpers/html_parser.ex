defmodule EarmarkParser.Helpers.HtmlParser do
  @moduledoc false

  import EarmarkParser.Helpers.StringHelpers, only: [behead: 2]
  import EarmarkParser.LineScanner, only: [void_tag?: 1]

  def parse_html(lines)

  def parse_html([tag_line | rest]) do
    case _parse_tag(tag_line) do
      {:ok, tag, ""} -> [_parse_rest(rest, tag, [])]
      {:ok, tag, suffix} -> [_parse_rest(rest, tag, [suffix])]
      {:ext, tag, ""} -> [_parse_rest(rest, tag, [])]
      {:ext, tag, suffix} -> [_parse_rest(rest, tag, []), [suffix]]
    end
  end

  # Parse One Tag
  # -------------

  defp _parse_atts(string, tag, atts) do
    quoted_attr = ~r{\A ([-\w]+) \s* = \s* (["']) (.*?) \2 \s*}x

    case Regex.run(quoted_attr, string) do
      [all, name, _delim, value] ->
        _parse_atts(behead(string, all), tag, [{name, value} | atts])

      _ ->
        unquoted_attr = ~r{\A ([-\w]+) (?: \s* = \s* ([^&\s>]*))? \s*}x

        case Regex.run(unquoted_attr, string) do
          [all, name, value] -> _parse_atts(behead(string, all), tag, [{name, value} | atts])
          [all, name] -> _parse_atts(behead(string, all), tag, [{name, name} | atts])
          _ -> _parse_tag_tail(string, tag, atts)
        end
    end
  end

  # Are leading and trailing "-"s ok?
  defp _parse_tag(string) do
    tag_head = ~r{\A \s* <([-\w]+) \s*}x

    case Regex.run(tag_head, string) do
      [all, tag] -> _parse_atts(behead(string, all), tag, [])
    end
  end

  defp _parse_tag_tail(string, tag, atts) do
    tag_tail = ~r{\A .*? (/?)> \s* (.*) \z}x

    case Regex.run(tag_tail, string) do
      [_, closing, suffix] ->
        suffix1 = String.replace(suffix, ~r{\s*</#{tag}>.*}, "")
        _close_tag_tail(tag, atts, closing != "", suffix1)
    end
  end

  defp _close_tag_tail(tag, atts, closing?, suffix) do
    if closing? || void_tag?(tag) do
      {:ext, {tag, Enum.reverse(atts)}, suffix}
    else
      {:ok, {tag, Enum.reverse(atts)}, suffix}
    end
  end

  # Iterate over lines inside a tag
  # -------------------------------

  @verbatim %{verbatim: true}
  defp _parse_rest(rest, tag_tpl, lines)

  defp _parse_rest([], tag_tpl, lines) do
    _tag_append(tag_tpl, lines)
  end

  defp _parse_rest([last_line], {tag, _} = tag_tpl, lines) do
    case Regex.run(~r{\A\s*</#{tag}>\s*(.*)}, last_line) do
      nil -> _tag_append(tag_tpl, [last_line | lines])
      [_, ""] -> _tag_append(tag_tpl, lines)
      [_, suffix] -> [_tag_append(tag_tpl, lines), suffix]
    end
  end

  defp _parse_rest([inner_line | rest], tag_tpl, lines) do
    _parse_rest(rest, tag_tpl, [inner_line | lines])
  end

  defp _tag_append(tag_tpl, lines) do
    tag_tpl
    |> Tuple.insert_at(2, Enum.reverse(lines))
    |> Tuple.insert_at(3, @verbatim)
  end
end

# SPDX-License-Identifier: Apache-2.0
