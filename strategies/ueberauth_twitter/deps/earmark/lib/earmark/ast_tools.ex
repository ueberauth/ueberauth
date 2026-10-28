defmodule Earmark.AstTools do
  @moduledoc """
  Tools for AST manipulation
  """

  @doc """

  A helper to merge attributes in their cannonical representation


      iex(1)> merge_atts([{"href", "url"}], target: "_blank")
      [{"href", "url"}, {"target", "_blank"}]

      iex(2)> merge_atts([{"href", "url"}, {"target", "nonsense"}], %{"target" => "_blank"})
      [{"href", "url"}, {"target", "_blank nonsense"}]

      iex(3)>  merge_atts([{"href", "url"}, {"target", "nonsense"}, {"alt", "nowhere"}],
      ...(3)>              [{"target", "_blank"}, title: "where?"])
      [{"alt", "nowhere"}, {"href", "url"}, {"target", "_blank nonsense"}, {"title", "where?"}]
  """
  @spec merge_atts(Earmark.ast_attributes(), map() | Keyword.t()) :: Earmark.ast_attributes()
  def merge_atts(attrs, new)

  def merge_atts(attrs, new) do
    attrs
    |> Enum.into(%{})
    |> Map.merge(_stringyfy(new), &_combine_atts/3)
    |> Enum.into([])
  end

  @doc """
  Convenience function to access an attribute from an AST node or a list of attributes

      iex(4)> find_att_in_node({"a", [{"class", "link"}], [], %{}}, "class")
      "link"

      iex(5)> find_att_in_node({"a", [{"class", "link"}], [], %{}}, "target")
      nil

      iex(6)> find_att_in_node([{"class", "link"}], "class")
      "link"

      iex(7)> find_att_in_node([{"class", "link"}], "target")
      nil


  """
  @spec find_att_in_node(Earmark.ast_node() | Earmark.ast_attributes(), binary()) :: any()
  def find_att_in_node(node_or_atts, att), do: _find_att(node_or_atts, att)

  @doc """
  Convenience function to access an attribute from an AST node or a list of attributes with a default value.

      iex(8)> find_att_in_node({"a", [{"class", "link"}], [], %{}}, "target", :default)
      :default


      iex(9)> find_att_in_node([{"class", "link"}], "target", :default)
      :default

  """

  @spec find_att_in_node(Earmark.ast_node() | Earmark.ast_attributes(), binary(), any()) :: any()
  def find_att_in_node(node_or_atts, att, default),
    do: _find_att_with_default(node_or_atts, att, default)

  @doc """
  A convenience function that extracts the original attributes to be merged with new attributes
  and puts the result into the node again

      iex(10)> merge_atts_in_node({"img", [{"src", "there"}, {"alt", "there"}], [], %{some: "meta"}}, alt: "here")
      {"img", [{"alt", "here there"}, {"src", "there"}], [], %{some: "meta"}}

  """
  @spec merge_atts_in_node(Earmark.ast_node(), map() | Keyword.t()) :: Earmark.ast_node()
  def merge_atts_in_node({tag, atts, content, meta}, new_atts) do
    {tag, merge_atts(atts, new_atts), content, meta}
  end

  @doc """
  Wrap a function that can only be called on nodes

      iex(11)> f = fn {t, _, _, _} -> t end
      ...(11)> f_ = node_only_fn(f)
      ...(11)> {f_.({"p", [], [], %{}}), f_.("text")}
      {"p", "text"}

  """
  @spec node_only_fn((Earmark.ast_node() -> any())) :: (Earmark.ast_node() | binary() -> any())
  def node_only_fn(fun),
    do: fn
      {_, _, _, _} = quad -> fun.(quad)
      text -> text
    end

  defp _combine_atts(_key, original, new), do: "#{new} #{original}"

  defp _find_att(node_or_atts, att)
  defp _find_att({_, atts, _, _}, att), do: _find_att(atts, att)

  defp _find_att(atts, att) do
    atts
    |> Enum.find_value(fn {key, value} -> if att == key, do: value end)
  end

  defp _find_att_with_default(node_or_atts, att, default)

  defp _find_att_with_default({_, atts, _, _}, att, default),
    do: _find_att_with_default(atts, att, default)

  defp _find_att_with_default(atts, att, default) do
    atts
    |> Enum.find_value(default, fn {key, value} -> if att == key, do: value end)
  end

  defp _stringyfy(mappy)

  defp _stringyfy(map) when is_map(map) do
    map |> Enum.into([]) |> _stringyfy()
  end

  defp _stringyfy(list) when is_list(list) do
    list |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.into(%{})
  end
end

#  SPDX-License-Identifier: Apache-2.0
