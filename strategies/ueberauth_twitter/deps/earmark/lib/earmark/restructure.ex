defmodule Earmark.Restructure do

  @doc ~S"""

  Walks an AST and allows you to process it (storing details in acc) and/or
  modify it as it is walked.

  items is the AST you got from Earmark.Parser.as_ast()

  acc is the initial value of an accumulator that is passed to both
  process_item_fn and process_list_fn and accumulated. If your functions
  do not need to use or store any state, you can pass nil.

  The process_item_fn function is required. It takes two parameters, the
  single item to process (which will either be a string or a 4-tuple) and
  the accumulator, and returns a tuple {processed_item, updated_acc}.
  Returning the empty list for processed_item will remove the item processed
  the AST.

  The process_list_fn function is optional and defaults to no modification of
  items or accumulator. It takes two parameters, the list of items that
  are the sub-items of a given element in the AST (or the top-level list of
  items), and the accumulator, and returns a tuple
  {processed_items_list, updated_acc}.

  This function ends up returning {ast, acc}.

  Here is an example using a custom format to make `<em>` nodes and allowing
  commented text to be left out

      iex(1)> is_comment? = fn item -> is_binary(item) && Regex.match?(~r/\A\s*--/, item) end
      ...(1)> comment_remover =
      ...(1)>   fn items, acc -> {Enum.reject(items, is_comment?), acc} end
      ...(1)> italics_maker = fn
      ...(1)>   item, acc when is_binary(item) ->
      ...(1)>     new_item = Restructure.split_by_regex(
      ...(1)>       item,
      ...(1)>       ~r/\/([[:graph:]].*?[[:graph:]]|[[:graph:]])\//,
      ...(1)>       fn [_, content] ->
      ...(1)>         {"em", [], [content], %{}}
      ...(1)>       end
      ...(1)>     )
      ...(1)>     {new_item, acc}
      ...(1)>   item, "a" -> {item, nil}
      ...(1)>   {name, _, _, _}=item, _ -> {item, name}
      ...(1)> end
      ...(1)> markdown = """
      ...(1)> [no italics in links](http://example.io/some/path)
      ...(1)> but /here/
      ...(1)>
      ...(1)> -- ignore me
      ...(1)>
      ...(1)> text
      ...(1)> """
      ...(1)> {:ok, ast, []} = Earmark.Parser.as_ast(markdown)
      ...(1)> Restructure.walk_and_modify_ast(ast, nil, italics_maker, comment_remover)
      {[
        {"p", [],
          [
            {"a", [{"href", "http://example.io/some/path"}], ["no italics in links"],
            %{}},
            "\nbut ",
            {"em", [], ["here"], %{}},
            ""
          ], %{}},
          {"p", [], [], %{}},
          {"p", [], ["text"], %{}}
        ], "p"}

  """
  def walk_and_modify_ast(items, acc, process_item_fn, process_list_fn \\ &({&1, &2}))
  when is_list(items) and is_function(process_item_fn) and is_function(process_list_fn)
  do
    {items, acc} = process_list_fn.(items, acc)
    {ast, acc} = Enum.map_reduce(items, acc, fn (item, acc) ->
      walk_and_modify_ast_item(item, acc, process_item_fn, process_list_fn)
    end)
    {List.flatten(ast), acc}
  end

  defp walk_and_modify_ast_item(item, acc, process_item_fn, process_list_fn) do
    case process_item_fn.(item, acc) do
      {{type, attribs, items, annotations}, acc}
      when (is_binary(type) or is_atom(type)) and is_list(attribs) and is_list(items) and is_map(annotations) ->
        {items, acc} = walk_and_modify_ast(items, acc, process_item_fn, process_list_fn)
        {{type, attribs, List.flatten(items), annotations}, acc}
      {item_or_items, acc} when is_binary(item_or_items) or is_list(item_or_items) ->
        {item_or_items, acc}
    end
  end

  @doc """
  Utility for creating a restructuring that parses text by splitting it into
  parts "of interest" vs. "other parts" using a regular expression.
  Returns a list of parts where the parts matching regex have been processed
  by invoking map_captures_fn on each part, and a list of remaining parts,
  preserving the order of parts from what it was in the plain text item.

        iex(2)> input = "This is ::all caps::, right?"
        ...(2)> split_by_regex(input, ~r/::(.*?)::/, fn [_, inner|_] -> String.upcase(inner) end)
        ["This is ", "ALL CAPS", ", right?"]
  """
  def split_by_regex(item, regex, map_captures_fn)
  when is_binary(item) and is_function(map_captures_fn) do
    interest_parts = Regex.scan(regex, item)
    |> Enum.map(map_captures_fn)
    other_parts = Regex.split(regex, item)
    # If the match is at the front of 'item', Regex.split will
    # return an empty string "before" the split. Therefore
    # the interest_parts always has either the same number of
    # elements as the other_parts list, or one fewer.
    merge_lists(other_parts, interest_parts)
  end

  @doc """
  Given two lists that are either of equal length, or with the first list
  exactly one element longer than the second, returns a list that begins with
  the first element from the first list, then the first element from the second
  list, and so forth until both lists are empty.
  """
  def merge_lists(first, second, acc \\ [])
  def merge_lists([], [], acc) do
    Enum.reverse(acc)
  end
  def merge_lists([first|first_rest], second, acc) do
    merge_lists(second, first_rest, [first|acc])
  end
  def merge_lists([], _, _) do
    raise ArgumentError, "merge_lists takes two lists where the first list is not shorter and at most 1 longer than the second list"
  end
end
# SPDX-License-Identifier: Apache-2.0
