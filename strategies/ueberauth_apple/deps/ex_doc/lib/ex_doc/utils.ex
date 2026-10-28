defmodule ExDoc.Utils do
  # General helpers used throughout ExDoc or extracted for testing.
  # Avoid adding functions to this module whenever possible,
  # instead prefer defining modules closer to the context they are used.
  @moduledoc false

  @doc """
  HTML escapes the given string.

      iex> ExDoc.Utils.h("<foo>")
      "&lt;foo&gt;"

  """
  def h(string) do
    String.replace(string, ~w|& < > "|, fn
      "&" -> "&amp;"
      "<" -> "&lt;"
      ">" -> "&gt;"
      ~S(") -> "&quot;"
    end)
  end

  @doc """
  Strips HTML tags from text leaving their text content
  """
  def strip_tags(text, replace_with \\ "") when is_binary(text) do
    clean_html_regex = ~r/<\/?\s*[a-zA-Z]+(?:[^>=]|='[^']*'|="[^"]*"|=[^'"][^\s>]*)*>/
    String.replace(text, clean_html_regex, replace_with)
  end

  @doc """
  Generates an ID from some text.

  Used primarily with titles, headings, and functions group names.
  """
  def text_to_id(atom) when is_atom(atom), do: text_to_id(Atom.to_string(atom))

  def text_to_id(text) when is_binary(text) do
    text
    |> String.replace(~r/&#\d+;/, "")
    |> String.replace(~r/&[A-Za-z0-9]+;/, "")
    |> String.replace(~r/\W+/u, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  @doc """
  Sorts mapped strings by natural order.
  """
  def natural_sort_by(enumerable, mapper) when is_function(mapper, 1) do
    Enum.sort_by(enumerable, fn elem ->
      elem
      |> mapper.()
      |> to_sortable_charlist()
    end)
  end

  defp to_sortable_charlist(string) do
    string
    |> :unicode.characters_to_nfkd_list()
    |> make_sortable()
  end

  @offset -1_000_000_000

  # Numbers come first, so group and pad them with offset
  defp make_sortable([digit | chars]) when digit in ?0..?9 do
    {digits, chars} = Enum.split_while(chars, &(&1 in ?0..?9))
    [@offset + List.to_integer([digit | digits]) | make_sortable(chars)]
  end

  # Then Elixir special punctuation - trailing bang `!`
  defp make_sortable([?! | chars]), do: [?0 | make_sortable(chars)]

  # Then Elixir special punctuation - question mark `?`
  defp make_sortable([?? | chars]), do: [?1 | make_sortable(chars)]

  # Then underscore
  defp make_sortable([?_ | chars]), do: [?2 | make_sortable(chars)]

  # Then uppercased letters and lowercased letters
  defp make_sortable([char | chars]) when char in ?a..?z do
    [char - 31.5 | make_sortable(chars)]
  end

  defp make_sortable([char | chars]), do: [char | make_sortable(chars)]
  defp make_sortable([]), do: []

  @doc """
  A very simple JSON encoder.

  We want to minimize the number of dependencies ExDoc has,
  because we don't want someone to be allowed to not upgrade
  their app due to an ExDoc restriction, so we ship with a
  simple JSON implementation.
  """
  # TODO: Remove this once we require Elixir v1.20+
  def to_json(nil), do: "null"
  def to_json(true), do: "true"
  def to_json(false), do: "false"

  def to_json(map) when is_map(map) do
    mapped =
      Enum.map_intersperse(Map.to_list(map), ?,, fn {key, value} ->
        [key |> Atom.to_string() |> inspect(), ?:, to_json(value)]
      end)

    [?{, mapped, ?}]
  end

  def to_json(list) when is_list(list) do
    mapped = Enum.map_intersperse(list, ?,, &to_json/1)
    [?[, mapped, ?]]
  end

  def to_json(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> inspect()
  end

  def to_json(binary) when is_binary(binary) do
    to_json_string(binary, "\"")
  end

  def to_json(integer) when is_integer(integer) do
    Integer.to_string(integer)
  end

  defp to_json_string(<<?\b, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\b">>)

  defp to_json_string(<<?\t, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\t">>)

  defp to_json_string(<<?\n, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\n">>)

  defp to_json_string(<<?\f, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\f">>)

  defp to_json_string(<<?\r, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\r">>)

  defp to_json_string(<<?\\, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\\\">>)

  defp to_json_string(<<?", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\\"">>)

  defp to_json_string(<<x, rest::binary>>, acc) when x <= 0x000F,
    do: to_json_string(rest, <<acc::binary, "\\u000", Integer.to_string(x, 16)::binary>>)

  defp to_json_string(<<x, rest::binary>>, acc) when x <= 0x001F,
    do: to_json_string(rest, <<acc::binary, "\\u00", Integer.to_string(x, 16)::binary>>)

  defp to_json_string(<<x, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, x>>)

  defp to_json_string(<<>>, acc), do: <<acc::binary, "\"">>
end
