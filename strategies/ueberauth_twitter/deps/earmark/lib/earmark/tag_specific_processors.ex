defmodule Earmark.TagSpecificProcessors do
  @moduledoc """
  This struct represents a list of tuples `{tag, function}` from which a postprocessing function
  can be constructed

  General Usage Examples:

      iex(0)> tsp = new({"p", &Earmark.AstTools.merge_atts_in_node(&1, class: "one")})
      ...(0)> tsp = prepend_tag_function(tsp, "i", &Earmark.AstTools.merge_atts_in_node(&1, class: "two"))
      ...(0)> make_postprocessor(tsp).({"p", [], nil, nil})
      {"p", [{"class", "one"}], nil, nil}

      iex(1)> tsp = new({"p", &Earmark.AstTools.merge_atts_in_node(&1, class: "one")})
      ...(1)> tsp = prepend_tag_function(tsp, "i", &Earmark.AstTools.merge_atts_in_node(&1, class: "two"))
      ...(1)> make_postprocessor(tsp).({"i", [{"class", "i"}], nil, nil})
      {"i", [{"class", "two i"}], nil, nil}

      iex(2)> tsp = new({"p", &Earmark.AstTools.merge_atts_in_node(&1, class: "one")})
      ...(2)> tsp = prepend_tag_function(tsp, "i", &Earmark.AstTools.merge_atts_in_node(&1, class: "two"))
      ...(2)> make_postprocessor(tsp).({"x", [], nil, nil})
      {"x", [], nil, nil}
  """
  @type t :: %__MODULE__{tag_functions: list()}
  defstruct tag_functions: []

  @doc """
  Constructs a postprocessor function from this struct which will find the function associated
  to the tag of the node, and apply the node to it if such a function was found.
  """
  def make_postprocessor(%__MODULE__{tag_functions: tfs}) do
    fn
      {_, _, _, _} = node -> _postprocess(node, tfs)
      other -> other
    end
  end

  @doc """
  Convenience construction

      iex(3)> new()
      %Earmark.TagSpecificProcessors{}

  """
  def new, do: %__MODULE__{}
  def new({_, _} = tf), do: %__MODULE__{tag_functions: [tf]}
  def new(tfs), do: %__MODULE__{tag_functions: tfs}

  @doc """
  Prepends a tuple {tag, function} to the list of such tuples.
  """
  def prepend_tag_function(tsp, tag, function), do: prepend_tag_function(tsp, {tag, function})

  def prepend_tag_function(%__MODULE__{tag_functions: tfs} = tsp, tf) do
    %{tsp | tag_functions: [tf | tfs]}
  end

  defp _postprocess({t, _, _, _} = node, tfs) do
    fun =
      tfs
      |> Enum.find_value(fn {t_, f} -> if t == t_, do: f end)

    if fun, do: fun.(node), else: node
  end
end

#  SPDX-License-Identifier: Apache-2.0
