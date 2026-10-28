defmodule Makeup.Lexer.Combinators do
  @moduledoc """
  Common components useful in many lexers.
  """
  import NimbleParsec

  @doc """
  Wraps the given combinator into a token of the given `ttype`.

  Instead of a combinator, the first argument can also be a string literal.
  """
  def token(literal, token_type) when is_binary(literal) do
    replace(string(literal), {token_type, %{}, literal})
  end

  def token(combinator, token_type) do
    combinator |> post_traverse({__MODULE__, :__token__, [token_type]})
  end

  def token(literal, token_type, attrs) when is_binary(literal) and is_map(attrs) do
    replace(string(literal), {token_type, attrs, literal})
  end

  def token(combinator, token_type, attrs) when is_map(attrs) do
    combinator |> post_traverse({__MODULE__, :__token__, [token_type, attrs]})
  end

  @doc """
  Joins the result of the given combinator into a single string.

  This is not usually necessary, but it can be useful if you want to match on the tokens.
  It's easier to match on the token `{:keyword, %{}, "unquote"}` than on something like
  `{:keyword, %{}, ["u", "nquote"]}`, even though both tokens will be treated the same way
  by the formatter.
  """
  def lexeme(combinator) do
    combinator |> post_traverse({__MODULE__, :__lexeme__, []})
  end

  @doc false
  def __token__(rest, [arg], context, _line, _offset, token_type) do
    {rest, [{token_type, %{}, arg}], context}
  end

  def __token__(rest, arg, context, _line, _offset, token_type) when is_binary(arg) do
    {rest, [{token_type, %{}, arg}], context}
  end

  def __token__(rest, args, context, _line, _offset, token_type) do
    {rest, [{token_type, %{}, args |> :lists.reverse()}], context}
  end

  @doc false
  def __token__(rest, [arg], context, _line, _offset, token_type, attrs) do
    {rest, [{token_type, attrs, arg}], context}
  end

  def __token__(rest, arg, context, _line, _offset, token_type, attrs) when is_binary(arg) do
    {rest, [{token_type, attrs, arg}], context}
  end

  def __token__(rest, args, context, _line, _offset, token_type, attrs) do
    {rest, [{token_type, attrs, args |> :lists.reverse()}], context}
  end

  @doc false
  def __lexeme__(rest, args, context, _line, _offset) do
    result = args |> List.wrap() |> :lists.reverse() |> to_string()
    {rest, [result], context}
  end

  defp reverse_sort(items) do
    Enum.sort(items, fn a, b -> {byte_size(a), a} > {byte_size(b), b} end)
  end

  @doc """
  Matches one of the literal strings in the list.

  The strings aren't matched in order: they are automatically sorted in a way
  that guarantees that the longest strings will be tried first.

  ## Examples

      keywords = word_from_list(~w[do end catch after rescue])
  """
  def word_from_list(words) do
    choice(for word <- reverse_sort(words), do: string(word))
  end

  @doc """
  Matches one of the literal strings in the list and wraps it in a token of the given type.

  This is is just a shorthand.

  The strings aren't matched in order: they are automatically sorted in a way
  that guarantees that the longest strings will be tried first.

  ## Examples

      keywords = word_from_list(~w[do end catch after rescue], :keyword)
  """
  def word_from_list(words, ttype) do
    choice(for word <- reverse_sort(words), do: string(word)) |> token(ttype)
  end

  @doc """
  Matches one of the literal strings in the list and wraps it in a token of the given `type`,
  with the given `attrs`.

  This is is just a shorthand.

  The strings aren't matched in order: they are automatically sorted in a way
  that guarantees that the longest strings will be tried first.
  """
  def word_from_list(words, ttype, attrs) do
    choice(for word <- reverse_sort(words), do: string(word)) |> token(ttype, attrs)
  end

  @doc """
  Matches a given combinator, repeated 0 or more times, surrounded by left and right delimiters.

  Delimiters can be combinators or literal strings (either both combinators or both literal strings).
  In case of literal strings, this function wraps the `right` and `left` delimiters
  into a token of the `ttype` option (default: `:punctuation`).

  It also succeeds if we get to the end of string and the closing delimiter is missing,
  to avoid parsing the program multiple times in case of mismatched delimeters or invalid programs.
  This behavior can be disabled by passing `eos: false` as option.
  """
  def many_surrounded_by(combinator, left, right, opts \\ [])

  def many_surrounded_by(combinator, left, right, opts) when is_list(opts) do
    ttype =
      Keyword.get_lazy(opts, :ttype, fn ->
        # when both left and right are literal strings, wrap them into a :punctuation token by default
        if is_binary(left) and is_binary(right) do
          :punctuation
        else
          nil
        end
      end)

    eos = Keyword.get(opts, :eos, true)
    lookahead_right = if is_binary(right), do: string(right), else: right

    maybe_wrap_token(left, ttype)
    |> concat(
      repeat(
        lookahead_not(lookahead_right)
        |> concat(combinator)
      )
    )
    |> maybe_concat_with_eos(maybe_wrap_token(right, ttype), eos)
  end

  # TODO: deprecate this to use ttype option instead
  def many_surrounded_by(combinator, left, right, ttype) do
    many_surrounded_by(combinator, left, right, ttype: ttype)
  end

  defp maybe_concat_with_eos(first, second, true), do: choice(first, [second, eos()])
  defp maybe_concat_with_eos(first, second, false), do: concat(first, second)

  defp maybe_wrap_token(token, nil), do: token
  defp maybe_wrap_token(token, ttype), do: token(token, ttype)

  @doc false
  def collect_raw_chars_and_binaries(rest, args, context, _line, _offset, ttype, attrs) do
    result = merge_chars_helper(ttype, attrs, [], args)
    {rest, result, context}
  end

  defp merge_chars_helper(_ttype, _attrs, [], []), do: []

  defp merge_chars_helper(ttype, attrs, acc, [next | rest])
       when is_integer(next) or is_binary(next) do
    merge_chars_helper(ttype, attrs, [next | acc], rest)
  end

  defp merge_chars_helper(ttype, attrs, [], [element | rest]) do
    [element | merge_chars_helper(ttype, attrs, [], rest)]
  end

  defp merge_chars_helper(ttype, attrs, acc, list) do
    tok = {ttype, attrs, acc}
    [tok | merge_chars_helper(ttype, attrs, [], list)]
  end

  @doc """
  A generic combinator for string-like syntactic structures.

  It takes the following parameters:

    * `left` - left delimiter for the string. Can be a binary or a general combinator.
    * `right` - right delimiter for the string. Can be a binary or a general combinator
    * `middle` - a list of parsers to run inside the string which parse entities
      that aren't characters.
      The most common example are special characters and string interpolation
      for languages that support it like Elixir.
    * `ttype` - the token type to use for the string delimiters and ordinary characters
      (tokens parsd by the )
    * `attrs` - metadata attributes for the string delimiters and ordinary characters

  ## Examples

      single_quoted_heredocs = string_like(
        "'''",
        "'''",
        combinators_inside_string,
        :string_char
      )

  The above is equivalent to the following more explicit version:

      single_quoted_heredocs = string_like(
        string("'''"),
        string("'''"),
        combinators_inside_string,
        :string_char
      )
  """
  def string_like(left, right, middle, ttype, attrs \\ %{}) when is_list(middle) do
    left_combinator =
      case is_binary(left) do
        true -> string(left)
        false -> left
      end

    right_combinator =
      case is_binary(right) do
        true -> string(right)
        false -> right
      end

    choices =
      case middle do
        [] -> utf8_char([])
        _ -> choice(middle ++ [utf8_char([])])
      end

    left_combinator
    |> repeat(lookahead_not(right_combinator) |> concat(choices))
    |> concat(right_combinator)
    |> post_traverse({__MODULE__, :collect_raw_chars_and_binaries, [ttype, attrs]})
  end
end
