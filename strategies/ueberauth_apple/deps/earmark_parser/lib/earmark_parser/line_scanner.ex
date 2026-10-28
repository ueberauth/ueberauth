defmodule EarmarkParser.LineScanner do
  @moduledoc false

  alias EarmarkParser.{Helpers, Line, Options}
  import EarmarkParser.LineScanner.Rgx

  # This is the re that matches the ridiculous "[id]: url title" syntax

  @doc false
  def void_tag?(tag) do
    Regex.match?(void_tag_rgx(), "<#{tag}>")
  end

  def scan_lines(lines, options, recursive) do
    _lines_with_count(lines, options.line - 1)
    |> _with_lookahead(options, recursive)
  end

  def type_of(line, recursive)
      when is_boolean(recursive) do
    type_of(line, %Options{}, recursive)
  end

  def type_of({line, lnb}, options = %Options{annotations: annotations}, recursive)
      when is_binary(line) do
    {line1, annotation} = line |> Helpers.expand_tabs() |> Helpers.remove_line_ending(annotations)
    %{_type_of(line1, options, recursive) | annotation: annotation, lnb: lnb}
  end

  def type_of({line, lnb}, _, _) do
    raise ArgumentError, "line number #{lnb} #{inspect(line)} is not a binary"
  end

  defp _type_of(line, options = %Options{}, recursive) do
    {ial, stripped_line} = Helpers.extract_ial(line)
    {content, indent} = _count_indent(line, 0)
    lt_four? = indent < 4

    cond do
      content == "" ->
        _create_text(line, content, indent)

      lt_four? && !recursive && html_comment_matches(content) ->
        %Line.HtmlComment{complete: true, indent: indent, line: line}

      lt_four? && !recursive && html_comment_start_matches(content) ->
        %Line.HtmlComment{complete: false, indent: indent, line: line}

      lt_four? && dash_ruler_matches(content) ->
        %Line.Ruler{type: "-", indent: indent, line: line}

      lt_four? && star_ruler_matches(content) ->
        %Line.Ruler{type: "*", indent: indent, line: line}

      lt_four? && underline_ruler_matches(content) ->
        %Line.Ruler{type: "_", indent: indent, line: line}

      match = heading_matches(stripped_line) ->
        [_, level, heading] = match

        %Line.Heading{
          level: String.length(level),
          content: String.trim(heading),
          indent: 0,
          ial: ial,
          line: line
        }

      match = lt_four? && block_quote_matches(content) ->
        [_, quote] = match
        %Line.BlockQuote{content: quote, indent: indent, ial: ial, line: line}

      match = indent_matches(line) ->
        [_, spaces, more_spaces, rest] = match
        sl = byte_size(spaces)

        %Line.Indent{
          level: div(sl, 4),
          content: more_spaces <> rest,
          indent: byte_size(more_spaces) + sl,
          line: line
        }

      match = fence_matches(line) ->
        [_, leading, fence, language] = match

        %Line.Fence{
          delimiter: fence,
          language: _attribute_escape(language),
          indent: byte_size(leading),
          line: line
        }

      # Although no block tags I still think they should close a preceding para as do many other
      # implementations.
      match = !recursive && void_tag_matches(line) ->
        [_, tag] = match
        %Line.HtmlOneLine{tag: tag, content: line, indent: 0, line: line}

      match = !recursive && html_one_line_matches(line) ->
        [_, tag] = match
        %Line.HtmlOneLine{tag: tag, content: line, indent: 0, line: line}

      match = !recursive && html_self_closing_matches(line) ->
        [_, tag] = match
        %Line.HtmlOneLine{tag: tag, content: line, indent: 0, line: line}

      match = !recursive && html_open_tag_matches(line) ->
        [_, tag] = match
        %Line.HtmlOpenTag{tag: tag, content: line, indent: 0, line: line}

      match = lt_four? && !recursive && html_close_tag_matches(content) ->
        [_, tag] = match
        %Line.HtmlCloseTag{tag: tag, indent: indent, line: line}

      match = lt_four? && id_def_matches(content) ->
        [_, id, url | title] = match

        title =
          if(Enum.empty?(title)) do
            ""
          else
            hd(title)
          end

        %Line.IdDef{id: id, url: url, title: title, indent: indent, line: line}

      match = options.footnotes && footnote_def_matches(line) ->
        [_, id, first_line] = match
        %Line.FnDef{id: id, content: first_line, indent: 0, line: line}

      match = lt_four? && bullet_list_item_matches(content) ->
        [_, bullet, spaces, text] = match

        %Line.ListItem{
          type: :ul,
          bullet: bullet,
          content: spaces <> text,
          indent: indent,
          list_indent: String.length(bullet <> spaces) + indent + 1,
          line: line
        }

      match = lt_four? && numbered_list_item_matches(content) ->
        _create_list_item(match, indent, line)

      match = table_line_matches(content) ->
        [body] = match

        body =
          body
          |> String.trim()
          |> String.trim("|")

        columns = _split_table_columns(body)

        %Line.TableLine{
          content: line,
          columns: columns,
          is_header: _determine_if_header(columns),
          indent: indent,
          line: line
        }

      line
      |> String.replace(table_header_rgx(), "")
      |> String.match?(table_first_column_rgx()) ->
        columns = _split_table_columns(line)

        %Line.TableLine{
          content: line,
          columns: columns,
          is_header: _determine_if_header(columns),
          indent: indent,
          line: line
        }

      options.gfm_tables &&
          line |> String.replace(table_header_rgx(), "") |> String.match?(table_column_rgx()) ->
        columns = _split_table_columns(line)

        %Line.TableLine{
          content: line,
          columns: columns,
          is_header: _determine_if_header(columns),
          needs_header: true,
          indent: indent,
          line: line
        }

      match = set_ext_underline_matches(line) ->
        [_, type] = match

        level =
          if(String.starts_with?(type, "=")) do
            1
          else
            2
          end

        %Line.SetextUnderlineHeading{level: level, indent: 0, line: line}

      match = lt_four? && ial_matches(content) ->
        [_, ial] = match
        %Line.Ial{attrs: String.trim(ial), verbatim: ial, indent: indent, line: line}

      true ->
        _create_text(line, content, indent)
    end
  end

  defp _attribute_escape(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
  end

  defp _create_list_item(match, indent, line)

  defp _create_list_item([_, bullet, spaces, text], indent, line) do
    sl = byte_size(spaces)

    sl1 =
      if sl > 3 do
        1
      else
        sl + 1
      end

    sl2 = sl1 + byte_size(bullet)

    %Line.ListItem{
      type: :ol,
      bullet: bullet,
      content: spaces <> text,
      indent: indent,
      list_indent: indent + sl2,
      line: line
    }
  end

  defp _create_text(line) do
    {content, indent} = _count_indent(line, 0)
    _create_text(line, content, indent)
  end

  defp _create_text(line, "", indent) do
    %Line.Blank{indent: indent, line: line}
  end

  defp _create_text(line, content, indent) do
    %Line.Text{content: content, indent: indent, line: line}
  end

  defp _count_indent(<<space, rest::binary>>, indent) when space in [?\s, ?\t] do
    _count_indent(rest, indent + 1)
  end

  defp _count_indent(rest, indent) do
    {rest, indent}
  end

  defp _lines_with_count(lines, offset) do
    Enum.zip(lines, offset..(offset + Enum.count(lines)))
  end

  defp _with_lookahead([line_lnb | lines], options, recursive) do
    case type_of(line_lnb, options, recursive) do
      %Line.Fence{delimiter: delimiter, indent: 0} = fence ->
        stop = ~r/\A (\s*) (?: #{delimiter} ) \s* ([^`\s]*) \s* \z/xu
        [fence | _lookahead_until_match(lines, stop, options, recursive)]

      %Line.HtmlComment{complete: false} = html_comment ->
        [html_comment | _lookahead_until_match(lines, ~r/-->/u, options, recursive)]

      other ->
        [other | _with_lookahead(lines, options, recursive)]
    end
  end

  defp _with_lookahead([], _options, _recursive) do
    []
  end

  defp _lookahead_until_match([], _, _, _) do
    []
  end

  defp _lookahead_until_match([{line, lnb} | lines], regex, options, recursive) do
    if line =~ regex do
      [type_of({line, lnb}, options, recursive) | _with_lookahead(lines, options, recursive)]
    else
      [
        %{_create_text(line) | lnb: lnb}
        | _lookahead_until_match(lines, regex, options, recursive)
      ]
    end
  end

  defp _determine_if_header(columns) do
    column_rgx = ~r{\A[\s|:-]+\z}

    columns
    |> Enum.all?(fn col -> Regex.run(column_rgx, col) end)
  end

  defp _split_table_columns(line) do
    col_sep_rgx = ~r/\\\|/

    line
    |> String.split(~r{(?<!\\)\|})
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn col -> Regex.replace(col_sep_rgx, col, "|") end)
  end
end

#  SPDX-License-Identifier: Apache-2.0
