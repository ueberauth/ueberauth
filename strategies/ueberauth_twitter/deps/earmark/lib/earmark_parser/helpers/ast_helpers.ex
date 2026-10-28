defmodule Earmark.Parser.Helpers.AstHelpers do
  @moduledoc false

  import Earmark.Parser.Ast.Emitter
  import Earmark.Parser.Helpers

  alias Earmark.Parser.Block

  @doc false
  def annotate(node, from_block)
  def annotate(node, %{annotation: nil}), do: node

  def annotate({tag, atts, children, meta}, %{annotation: annotation}),
    do: {tag, atts, children, Map.put(meta, :annotation, annotation)}

  def annotate({tag, atts, children, meta}, annotation),
    do: {tag, atts, children, Map.put(meta, :annotation, annotation)}

  @doc false
  def attrs_to_string_keys(key_value_pair)

  def attrs_to_string_keys({k, vs}) when is_list(vs) do
    {to_string(k), Enum.join(vs, " ")}
  end

  def attrs_to_string_keys({k, vs}) do
    {to_string(k), to_string(vs)}
  end

  @doc false
  def augment_tag_with_ial(tags, ial, src)
  def augment_tag_with_ial([{t, a, c, m}|tags], atts, _src) do
    [{t, merge_attrs(a, atts), c, m}|tags]
  end
  def augment_tag_with_ial([], _atts, _src) do
    []
  end
  def augment_tag_with_ial([any], _atts, src) do
    [any <> src]
  end

  @doc false
  def code_classes(language, prefix) do
    classes =
      ["" | String.split(prefix || "")]
      |> Enum.map(fn pfx -> "#{pfx}#{language}" end)

    {"class", classes |> Enum.join(" ")}
  end

  @doc false
  def codespan(text) do
    emit("code", text, class: "inline")
  end

  @doc false
  def render_footnote_link(ref, backref, number) do
    emit("a", to_string(number),
      href: "##{ref}",
      id: backref,
      class: "footnote",
      title: "see footnote"
    )
  end

  @doc false
  def render_code(%Block.Code{lines: lines}) do
    lines |> Enum.join("\n")
  end

  @doc false
  def render_image(text, href, title) do
    regex = ~r{ \\ (?! \\ ) }x

    alt = text |> escape() |> String.replace(regex, "")

    if title do
      emit("img", [], src: href, alt: alt, title: title)
    else
      emit("img", [], src: href, alt: alt)
    end
  end

  @doc false
  def render_link(url, text) do
    emit("a", text, href: _encode(url))
  end

  ##############################################
  # add attributes to the outer tag in a block #
  ##############################################

  defp _encode(url) do
    regex = ~r<%[\da-f]{2}>i

    url
    |> String.split(regex, include_captures: true)
    |> Enum.chunk_every(2)
    |> Enum.map(&_encode_chunk/1)
    |> IO.chardata_to_string()
  end

  defp _encode_chunk([encodable, verbatim]), do: [URI.encode(encodable), verbatim]
  defp _encode_chunk([encodable]), do: URI.encode(encodable)

  @doc false
  def merge_attrs(maybe_atts, new_atts)
  def merge_attrs(nil, new_atts), do: new_atts

  def merge_attrs(atts, new) when is_list(atts) do
    atts
    |> Enum.into(%{})
    |> merge_attrs(new)
  end

  def merge_attrs(atts, new) do
    atts
    |> Map.merge(new, &_value_merger/3)
    |> Enum.into([])
    |> Enum.map(&attrs_to_string_keys/1)
  end

  defp _value_merger(key, val1, val2)

  defp _value_merger(_, val1, val2) when is_list(val1) do
    val1 ++ [val2]
  end

  defp _value_merger(_, val1, val2) do
    [val1, val2]
  end
end

# SPDX-License-Identifier: Apache-2.0
