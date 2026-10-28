defmodule EarmarkParser.Ast.Renderer.FootnoteRenderer do
  import EarmarkParser.Ast.Emitter
  alias EarmarkParser.{AstRenderer, Block, Context, Message}
  import Context, only: [clear_value: 1, prepend: 2]

  @moduledoc false

  @empty_set MapSet.new([])

  def render_defined_fns(%Block.FnList{blocks: footnotes}, context) do
    {elements, errors} = render_footnote_blocks(footnotes, context)

    ast =
      emit(
        "div",
        [
          emit("hr"),
          emit("ol", elements)
        ],
        class: "footnotes"
      )

    prepend(context, ast) |> Message.add_messages(errors)
  end

  defp _render_footnote_def(%Block.FnDef{blocks: blocks, id: id}, {ast, errors, context} = acc) do
    if MapSet.member?(context.referenced_footnote_ids, id) do
      context1 = AstRenderer.render(blocks, clear_value(context))
      a_attrs = %{title: "return to article", class: "reversefootnote", href: "#fnref:#{id}"}

      footnote_li_ast =
        emit("li", [emit("a", ["&#x21A9;"], a_attrs, %{verbatim: true}) | context1.value], id: "fn:#{id}")

      {[footnote_li_ast | ast], MapSet.union(errors, context1.options.messages), context}
    else
      acc
    end
  end

  defp render_footnote_blocks(footnotes, context) do
    {elements, errors, _} =
      footnotes
      |> Enum.reduce({[], @empty_set, context}, &_render_footnote_def/2)

    {elements |> Enum.reverse(), errors}
  end
end

#  SPDX-License-Identifier: Apache-2.0
