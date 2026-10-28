defmodule EarmarkParser.Parser.FootnoteParser do
  alias EarmarkParser.{Block, Enum.Ext, Line}

  @moduledoc false
  def parse_fn_defs([fn_def | rest], result, options) do
    acc =
      {[fn_def.content], [%Block.FnList{blocks: [_block_fn_def(fn_def)]} | result], %{}, options}

    rest
    |> Ext.reduce_with_end(acc, &_parse_fn_def_reduce/2)
  end

  defp _parse_fn_def_reduce(ele_or_end, acc)

  defp _parse_fn_def_reduce({:element, %Line.FnDef{content: content} = fn_def}, acc) do
    {result1, footnotes, options1} = _complete_fn_def_block(acc, fn_def)
    {[content], result1, footnotes, options1}
  end

  defp _parse_fn_def_reduce({:element, %{line: line}}, acc) do
    _prepend_to_first_in4(line, acc)
  end

  defp _parse_fn_def_reduce(:end, acc) do
    {[fn_list | rest], footnotes, options} = _complete_fn_def_block(acc)
    {[%{fn_list | blocks: Enum.reverse(fn_list.blocks)} | rest], footnotes, options}
  end

  defp _prepend_to_first_in4(element, {a, b, c, d}) do
    {[element | a], b, c, d}
  end

  defp _block_fn_def(%Line.FnDef{} = fn_def) do
    %Block.FnDef{id: fn_def.id, lnb: fn_def.lnb}
  end

  defp _complete_fn_def_block(
         {input, [%Block.FnList{blocks: [open_fn | closed_fns]} | rest], footnotes, options},
         new_fn_def \\ nil
       ) do
    # `_footnotes1` should be empty but let us not change the shape of parse depending
    # on options or the value of recursive?
    {inner_blocks, _links, _footnotes1, options1} = EarmarkParser.Parser.parse(Enum.reverse(input), options, true)
    closed_fn = %{open_fn | blocks: inner_blocks}
    footnotes1 = Map.put(footnotes, closed_fn.id, closed_fn)

    fn_blocks =
      if new_fn_def do
        [_block_fn_def(new_fn_def), closed_fn | closed_fns]
      else
        [closed_fn | closed_fns]
      end

    {[%Block.FnList{blocks: fn_blocks} | rest], footnotes1, options1}
  end
end

#  SPDX-License-Identifier: Apache-2.0
