defmodule Earmark.Parser.Parser.ListParser do
  alias Earmark.Parser.{Block, Line, Options}
  alias Earmark.Parser.Parser.ListInfo

  import Earmark.Parser.Helpers.StringHelpers, only: [behead: 2]
  import Earmark.Parser.Message, only: [add_message: 2]
  import ListInfo

  @moduledoc false

  @not_pending {nil, 0}

  def parse_list(lines, result, options \\ %Options{}) do
    {items, rest, options1} = _parse_list_items_init(lines, [], options)
    list = _make_list(items, _empty_list(items))
    {[list | result], rest, options1}
  end

  defp _parse_list_items_init([item | rest], list_items, options) do
    options1 = %{options | line: item.lnb}

    _parse_list_items_start(
      rest,
      _make_and_prepend_list_item(item, list_items),
      new(item, options1)
    )
  end

  defp _parse_list_items_spaced(input, items, list_info)

  defp _parse_list_items_spaced(input, items, %{pending: @not_pending} = list_info) do
    _parse_list_items_spaced_np(input, items, list_info)
  end

  defp _parse_list_items_spaced(input, items, list_info) do
    _parse_list_items_spaced_pdg(input, items, list_info)
  end

  defp _parse_list_items_spaced_np([%Line.Blank{} | rest], items, list_info) do
    list_info1 = %{
      list_info
      | lines: ["" | list_info.lines],
        options: %{list_info.options | line: list_info.options.line + 1}
    }

    _parse_list_items_spaced_np(rest, items, list_info1)
  end

  defp _parse_list_items_spaced_np([%Line.Ruler{} | _] = lines, items, list_info) do
    _finish_list_items(lines, items, false, list_info)
  end

  defp _parse_list_items_spaced_np(
         [%Line.ListItem{indent: ii} = item | _] = input,
         list_items,
         %{width: w} = list_info
       )
       when ii < w do
    if _starts_list?(item, list_items) do
      _finish_list_items(input, list_items, false, list_info)
    else
      {items1, options1} = _finish_list_item(list_items, false, _loose(list_info))
      _parse_list_items_init(input, items1, options1)
    end
  end

  defp _parse_list_items_spaced_np(
         [%Line.Indent{indent: ii} = item | rest],
         list_items,
         %{width: w} = list_info
       )
       when ii >= w do
    indented = _behead_spaces(item.line, w)
    _parse_list_items_spaced(rest, list_items, update_list_info(list_info, indented, item, true))
  end

  defp _parse_list_items_spaced_np([%Line.ListItem{} = line | rest], items, list_info) do
    indented = _behead_spaces(line.line, list_info.width)
    _parse_list_items_start(rest, items, update_list_info(list_info, indented, line))
  end

  # BUG: Still do not know how much to indent here???
  defp _parse_list_items_spaced_np(
         [%{indent: indent, line: str_line} = line | rest],
         items,
         %{width: width} = list_info
       )
       when indent >= width do
    _parse_list_items_spaced(
      rest,
      items,
      update_list_info(list_info, behead(str_line, width), line, true)
    )
  end

  defp _parse_list_items_spaced_np(input, items, list_info) do
    _finish_list_items(input, items, false, list_info)
  end

  defp _parse_list_items_spaced_pdg(input, items, list_info)

  defp _parse_list_items_spaced_pdg([], items, %{pending: {pending, lnb}} = list_info) do
    options1 =
      add_message(
        list_info.options,
        {:warning, lnb, "Closing unclosed backquotes #{pending} at end of input"}
      )

    _finish_list_items([], items, false, %{list_info | options: options1})
  end

  defp _parse_list_items_spaced_pdg([line | rest], items, list_info) do
    indented = _behead_spaces(line.line, list_info.width)
    _parse_list_items_spaced(rest, items, update_list_info(list_info, indented, line, true))
  end

  defp _parse_list_items_start(input, list_items, list_info)

  defp _parse_list_items_start(input, list_items, %{pending: @not_pending} = list_info) do
    _parse_list_items_start_np(input, list_items, list_info)
  end

  defp _parse_list_items_start(input, list_items, list_info) do
    _parse_list_items_start_pdg(input, list_items, list_info)
  end

  defp _parse_list_items_start_np(input, list_items, list_info)

  defp _parse_list_items_start_np([%Line.Blank{} | input], items, list_info) do
    _parse_list_items_spaced(input, items, prepend_line(list_info, ""))
  end

  defp _parse_list_items_start_np([], list_items, list_info) do
    _finish_list_items([], list_items, true, list_info)
  end

  defp _parse_list_items_start_np([%Line.Ruler{} | _] = input, list_items, list_info) do
    _finish_list_items(input, list_items, true, list_info)
  end

  defp _parse_list_items_start_np([%Line.Heading{} | _] = input, list_items, list_info) do
    _finish_list_items(input, list_items, true, list_info)
  end

  defp _parse_list_items_start_np(
         [%Line.ListItem{indent: ii} = item | _] = input,
         list_items,
         %{width: w} = list_info
       )
       when ii < w do
    if _starts_list?(item, list_items) do
      _finish_list_items(input, list_items, true, list_info)
    else
      {items1, options1} = _finish_list_item(list_items, true, list_info)
      _parse_list_items_init(input, items1, options1)
    end
  end

  # Slurp in everything else before a first blank line
  defp _parse_list_items_start_np([%{line: str_line} = line | rest], items, list_info) do
    indented = _behead_spaces(str_line, list_info.width)
    _parse_list_items_start(rest, items, update_list_info(list_info, indented, line))
  end

  defp _parse_list_items_start_pdg(input, items, list_info)

  defp _parse_list_items_start_pdg([], items, list_info) do
    _finish_list_items([], items, true, list_info)
  end

  defp _parse_list_items_start_pdg([%{line: str_line} = line | rest], items, list_info) do
    indented = _behead_spaces(str_line, list_info.width)
    _parse_list_items_start(rest, items, update_list_info(list_info, indented, line))
  end

  defp _behead_spaces(str, len) do
    Regex.replace(~r/\A\s{1,#{len}}/, str, "")
  end

  # INLINE CANDIDATE
  defp _empty_list([%Block.ListItem{loose?: loose?, type: type} | _]) do
    %Block.List{loose?: loose?, type: type}
  end

  defp _extract_start(%{bullet: bullet}) do
    start_number_rgx = ~r{\A0*(\d+)\.}

    case Regex.run(start_number_rgx, bullet) do
      nil -> ""
      [_, "1"] -> ""
      [_, start] -> ~s{ start="#{start}"}
    end
  end

  defp _finish_list_item([%Block.ListItem{} = item | items], _at_start?, list_info) do
    {blocks, _, _, options1} =
      list_info.lines
      |> Enum.reverse()
      |> Earmark.Parser.Parser.parse(%{list_info.options | line: item.lnb}, :list)

    loose1? = _already_loose?(items) || list_info.loose?
    {[%{item | blocks: blocks, loose?: loose1?} | items], options1}
  end

  defp _finish_list_items(input, items, at_start?, list_info) do
    {items1, options1} = _finish_list_item(items, at_start?, list_info)
    {items1, input, options1}
  end

  defp _make_and_prepend_list_item(
         %Line.ListItem{bullet: bullet, lnb: lnb, type: type},
         list_items
       ) do
    [%Block.ListItem{bullet: bullet, lnb: lnb, spaced?: false, type: type} | list_items]
  end

  defp _make_list(items, list)

  defp _make_list(
         [%Block.ListItem{bullet: bullet, lnb: lnb} = item],
         %Block.List{loose?: loose?} = list
       ) do
    %{
      list
      | blocks: [%{item | loose?: loose?} | list.blocks],
        bullet: bullet,
        lnb: lnb,
        start: _extract_start(item)
    }
  end

  defp _make_list([%Block.ListItem{} = item | rest], %Block.List{loose?: loose?} = list) do
    _make_list(rest, %{list | blocks: [%{item | loose?: loose?} | list.blocks]})
  end

  defp _already_loose?(items)
  defp _already_loose?([]), do: false
  defp _already_loose?([%{loose?: loose?} | _]), do: loose?

  defp _loose(list_info), do: %{list_info | loose?: true}

  defp _starts_list?(%{bullet: bullet1}, [%Block.ListItem{bullet: bullet2} | _]) do
    String.last(bullet1) != String.last(bullet2)
  end
end

# SPDX-License-Identifier: Apache-2.0
