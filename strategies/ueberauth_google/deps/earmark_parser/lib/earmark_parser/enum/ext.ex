defmodule EarmarkParser.Enum.Ext do
  @moduledoc ~S"""
    Some extensions of Enum functions
  """

  @doc ~S"""
  `reduce_with_end` is like `Enum.reduce` for lists, but the reducer function is called for
  each element of the list with the tuple `{:element, element}` and the accumulator and once
  more at the end with `:end` and the accumulator

      iex(1)> reducer =
      ...(1)>   fn {:element, nil}, {partial, result} -> {[], [Enum.sum(partial)|result]}
      ...(1)>      {:element, val}, {partial, result} -> {[val|partial], result}
      ...(1)>      :end,            {partial, result} -> [Enum.sum(partial)|result] |> Enum.reverse
      ...(1)>   end
      ...(1)> [1, 2, nil, 4, 1, 0, nil, 3, 2, 2]
      ...(1)> |> reduce_with_end({[], []}, reducer)
      [3, 5, 7]

  **N.B.** that in the treatment of `:end` we can change the shape of the accumulator w/o any
  penalty concerning the complexity of the reducer function
  """
  def reduce_with_end(collection, initial_acc, reducer_fn)

  def reduce_with_end([], acc, reducer_fn) do
    reducer_fn.(:end, acc)
  end

  def reduce_with_end([ele | rest], acc, reducer_fn) do
    reduce_with_end(rest, reducer_fn.({:element, ele}, acc), reducer_fn)
  end

  @doc ~S"""

    Like map_reduce but reversing the list

      iex(2)> replace_nil_and_count = fn ele, acc ->
      ...(2)>   if ele, do: {ele, acc}, else: {"", acc + 1}
      ...(2)> end
      ...(2)> ["y", nil, "u", nil, nil, "a", nil] |> reverse_map_reduce(0, replace_nil_and_count)
      { ["", "a", "", "", "u", "", "y"], 4 }

  """
  def reverse_map_reduce(list, initial, fun) do
    _reverse_map_reduce(list, initial, [], fun)
  end

  # Helpers {{{
  defp _reverse_map_reduce(list, acc, result, fun)

  defp _reverse_map_reduce([], acc, result, _fun) do
    {result, acc}
  end

  defp _reverse_map_reduce([fst | rst], acc, result, fun) do
    {new_ele, new_acc} = fun.(fst, acc)
    _reverse_map_reduce(rst, new_acc, [new_ele | result], fun)
  end

  # }}}
end

#  SPDX-License-Identifier: Apache-2.0
