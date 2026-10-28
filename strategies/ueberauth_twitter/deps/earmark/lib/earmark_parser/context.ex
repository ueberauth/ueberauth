defmodule Earmark.Parser.Context do
  @moduledoc false
  alias Earmark.Parser.Options

  @type t :: %__MODULE__{
          options: Earmark.Parser.Options.t(),
          links: map(),
          footnotes: map(),
          referenced_footnote_ids: MapSet.t(String.t()),
          value: String.t() | [String.t()]
        }

  defstruct options: %Earmark.Parser.Options{},
            links: Map.new(),
            rules: nil,
            footnotes: Map.new(),
            referenced_footnote_ids: MapSet.new([]),
            value: []

  ##############################################################################
  # Handle adding option specific rules and processors                         #
  ##############################################################################

  @doc false
  def modify_value(%__MODULE__{value: value} = context, fun) do
    nv = fun.(value)
    %{context | value: nv}
  end

  @doc false
  def prepend(context1, ast_or_context, context2_or_nil \\ nil)

  def prepend(%__MODULE__{} = context1, %__MODULE__{} = context2, nil) do
    context1
    |> _merge_contexts(context2)
    |> _prepend(context2.value)
  end

  def prepend(%__MODULE__{} = context1, ast, nil) do
    context1
    |> _prepend(ast)
  end

  def prepend(%__MODULE__{} = context1, ast, %__MODULE__{} = context2) do
    context1
    |> _merge_contexts(context2)
    |> _prepend(ast)
  end

  defp _merge_contexts(
         %__MODULE__{referenced_footnote_ids: orig} = context1,
         %__MODULE__{referenced_footnote_ids: new} = context2
       ) do
    context_ = _merge_messages(context1, context2)
    %{context_| referenced_footnote_ids: MapSet.union(orig, new)}
  end

  defp _merge_messages(context, context_or_messages)
  defp _merge_messages(context, %__MODULE__{options: %Options{messages: messages}}) do
    _merge_messages(context, messages)
  end
  defp _merge_messages(context, messages) do
    %{context | options: %{context.options|messages: MapSet.union(context.options.messages, messages)}}
  end


  defp _prepend(ctxt, []), do: ctxt

  defp _prepend(%{value: value} = ctxt, {:comment, _, _, _} = ct),
    do: %{ctxt | value: [ct | value]}

  defp _prepend(%{value: value} = ctxt, tuple) when is_tuple(tuple) do
    %{ctxt | value: [tuple | value] |> List.flatten()}
  end

  defp _prepend(%{value: value} = ctxt, list) when is_list(list),
    do: %{ctxt | value: List.flatten(list ++ value)}

  @doc """
  Convenience method to prepend to the value list
  """
  def set_value(%__MODULE__{} = ctx, value) do
    %{ctx | value: value}
  end

  def clear_value(%__MODULE__{} = ctx), do: %{ctx | value: []}

  # this is called by the command line processor to update
  # the inline-specific rules in light of any options
  def update_context(context = %Earmark.Parser.Context{options: options}) do
    %{context | rules: rules_for(options)}
  end

  #                 ( "[" .*? "]"n or anything w/o {"[", "]"}* or "]" ) *
  @link_text ~S{(?:\[[^]]*\]|[^][]|\])*}
  # "
  # @href ~S{\s*<?(.*?)>?(?:\s+['"](.*?)['"])?\s*}

  defp basic_rules do
    [
      br: ~r<^ {2,}\n(?!\s*$)>,
      text: ~r<^[\s\S]+?(?=[\\<!\[_*`]| {2,}\n|$)>
    ]
  end

  defp rules_for(options) do
    subsup =
      if options.sub_sup do
        "~^"
      else
        ""
      end
    rule_updates =
      if options.gfm do
        rules = [
          text: ~r{^[\s\S]+?(?=~~|[\\<!\[_*`#{subsup}]|https?://| \{2,\}\n|$)}
        ]

        if options.breaks do
          break_updates = [
            br: ~r{^ *\n(?!\s*$)},
            text: ~r{^[\s\S]+?(?=~~|[\\<!\[_*`#{subsup}]|https?://| *\n|$)}
          ]

          Keyword.merge(rules, break_updates)
        else
          rules
        end
      else
        []
      end

    footnote = if options.footnotes, do: ~r{^\[\^(#{@link_text})\]}, else: ~r{\z\A}
    rule_updates = Keyword.merge(rule_updates, footnote: footnote)

    Keyword.merge(basic_rules(), rule_updates)
    |> Enum.into(%{})
  end
end

# SPDX-License-Identifier: Apache-2.0
