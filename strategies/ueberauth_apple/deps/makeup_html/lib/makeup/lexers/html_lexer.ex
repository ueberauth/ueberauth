defmodule Makeup.Lexers.HTMLLexer do
  @moduledoc """
  Lexer for the HTML language to be used
  with the Makeup package.
  """
  @behaviour Makeup.Lexer

  import NimbleParsec
  import Makeup.Lexer.Combinators
  import Makeup.Lexer.Groups
  import Makeup.Lexers.HTMLLexer.Combinators

  @attributes MapSet.new(get_attributes() ++ get_event_handler_attributes())

  ###################################################################
  # Step #1: tokenize the input (into a list of tokens)
  ###################################################################

  # Whitespaces
  wspace = ascii_string([?\r, ?\s, ?\n, ?\f], min: 1)

  whitespace =
    wspace
    |> token(:whitespace)

  # Doctype
  legacy_doctype_string =
    wspace
    |> optional()
    |> concat(anycase_string("SYSTEM"))
    |> optional(wspace)
    |> concat(
      choice([
        string("\"about:legacy-compat\""),
        string("'about:legacy-compat'")
      ])
    )

  doctype =
    "<!"
    |> string()
    |> concat(anycase_string("DOCTYPE"))
    |> optional(wspace)
    |> concat(anycase_string("html"))
    |> optional(legacy_doctype_string)
    |> optional(wspace)
    |> concat(string(">"))
    |> token(:comment_preproc)

  # Operators
  operators =
    "="
    |> string()
    |> token(:operator)

  # Combinators that highlight expressions surrounded by a pair of delimiters.
  comment_tag =
    string("<!--")
    |> concat(
      repeat(
        lookahead_not(string("-->"))
        |> utf8_string([], 1)
      )
    )
    |> string("-->")
    |> token(:comment)

  name_tag =
    ascii_string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-, ?:, ?.], min: 1)
    |> token(:name_tag)

  # Single punctuation symbols
  open_tag =
    "<"
    |> string()
    |> token(:punctuation)
    |> concat(name_tag)

  close_tag =
    ">"
    |> string()
    |> token(:punctuation)

  close_self_tag =
    "/>"
    |> string()
    |> token(:punctuation)

  open_closing_tag =
    "</"
    |> string()
    |> token(:punctuation)
    |> concat(name_tag)

  # Currently we match attributes anywhere in the text
  attributes = utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-, ?:, ?.], min: 1) |> token(:keyword)

  # Unmatched
  insensitive_char = utf8_char([]) |> token(:char)

  # Tag the tokens with the language name.
  # This makes it easier to postprocess files with multiple languages.
  @doc false
  def __as_html_language__({ttype, meta, value}) do
    {ttype, Map.put(meta, :language, :html), value}
  end

  root_element_combinator =
    choice([
      # Doctype
      doctype,
      # Operators
      operators,
      # Delimiters
      comment_tag,
      open_closing_tag,
      open_tag,
      close_self_tag,
      close_tag,
      # Text
      whitespace,
      attributes,
      insensitive_char
    ])

  ##############################################################################
  # Semi-public API: these two functions can be used by someone who wants to
  # embed this lexer into another lexer, but other than that, they are not
  # meant to be used by end-users
  ##############################################################################
  @inline Application.compile_env(:makeup_html, :inline, false)

  # @impl Makeup.Lexer
  defparsec(
    :root_element,
    root_element_combinator |> map({__MODULE__, :__as_html_language__, []}),
    inline: @inline
  )

  # @impl Makeup.Lexer
  defparsec(
    :root,
    repeat(parsec(:root_element)),
    inline: @inline
  )

  ###################################################################
  # Step #2: postprocess the list of tokens
  ###################################################################

  # Converts traces of the form [char]+ into a single string
  # Converts keywords before and after strings into a single string

  defp merge([{:char, attr, value} | tokens]),
    do: merge([{:string, attr, <<value::utf8>>} | tokens])

  defp merge([{tag, attr, value1}, {:char, _attr, value2} | tokens])
       when tag in [:keyword, :string],
       do: merge([{:string, attr, <<value1::binary, value2::utf8>>} | tokens])

  defp merge([{tag, attr, value1}, {:keyword, _attr, value2} | tokens])
       when tag in [:keyword, :string],
       do: merge([{:string, attr, value1 <> value2} | tokens])

  defp merge([{tag, attr, value1}, {:string, _attr, value2} | tokens])
       when tag in [:keyword, :string],
       do: merge([{:string, attr, value1 <> value2} | tokens])

  defp merge([token | tokens]),
    do: [token | merge(tokens)]

  defp merge([]), do: []

  # Converts the proper keywords into attributes

  defp attributify(
         [
           {:punctuation, _, "<"} = punctuation,
           {:name_tag, _, _} = name_tag,
           {:whitespace, _, _} = whitespace | tokens
         ],
         _
       ) do
    [punctuation, name_tag, whitespace | attributify(tokens, true)]
  end

  defp attributify([{:punctuation, _, ">"} = punctuation | tokens], _flag),
    do: [punctuation | attributify(tokens, false)]

  defp attributify([{:punctuation, _, "/>"} = punctuation | tokens], _flag),
    do: [punctuation | attributify(tokens, false)]

  # when using the HTMLLexer from HEEx, we often have to deal with
  # strings like <div class=>...</div> where an attribute starts, but is missing
  # a value. We special case this "missing attribute value" case here to avoid
  # formatting the closing tag as an attribute.
  defp attributify(
         [
           {:keyword, attr, value},
           {:operator, _, _} = operator,
           {:punctuation, attr2, value2} | tokens
         ],
         true
       ) do
    [
      {:name_attribute, attr, value},
      operator,
      {:punctuation, attr2, value2}
      | attributify(tokens, false)
    ]
  end

  defp attributify(
         [
           {:keyword, attr, value},
           {:operator, _, _} = operator,
           {_, attr2, value2} | tokens
         ],
         true
       ) do
    [
      {:name_attribute, attr, value},
      operator,
      {:string, attr2, value2}
      | attributify(tokens, true)
    ]
  end

  defp attributify([{:keyword, attr, value} | tokens], true),
    do: [{:name_attribute, attr, value} | attributify(tokens, true)]

  defp attributify([{:keyword, attr, value} | tokens], flag) do
    attribute =
      if Enum.member?(@attributes, value),
        do: {:name_attribute, attr, value},
        else: {:string, attr, value}

    [attribute | attributify(tokens, flag)]
  end

  defp attributify([token | tokens], flag),
    do: [token | attributify(tokens, flag)]

  defp attributify([], _), do: []

  # Converts the content of an element into a string

  defp buffer_to_acc("", acc), do: acc
  defp buffer_to_acc(string, acc), do: [{:string, %{language: :html}, string} | acc]

  defp stringify([{:punctuation, _, ">"} = punctuation | tokens], _, buffer),
    do: buffer_to_acc(buffer, [punctuation | stringify(tokens, true, "")])

  # We respect the comments
  defp stringify([{:comment, _, _} = comment | tokens], _, buffer),
    do: buffer_to_acc(buffer, [comment | stringify(tokens, true, "")])

  defp stringify([{:punctuation, _, "</"} = punctuation | tokens], true, buffer),
    do: buffer_to_acc(buffer, [punctuation | stringify(tokens, false, "")])

  defp stringify([{:punctuation, _, "<"} = punctuation | tokens], true, buffer),
    do: buffer_to_acc(buffer, [punctuation | stringify(tokens, false, "")])

  defp stringify([token | tokens], false, buffer),
    do: [token | stringify(tokens, false, buffer)]

  defp stringify([{_, _, value} | tokens], true, buffer),
    do: stringify(tokens, true, buffer <> value)

  defp stringify([], _, buffer),
    do: buffer_to_acc(buffer, [])

  @impl Makeup.Lexer
  def postprocess(tokens, _opts \\ []) do
    tokens
    |> merge()
    |> attributify(false)
    |> stringify(false, "")
  end

  #######################################################################
  # Step #3: highlight matching delimiters
  #######################################################################
  @impl Makeup.Lexer
  defgroupmatcher(:match_groups,
    start_closing_tag: [
      open: [[{:punctuation, _, "</"}]],
      close: [[{:punctuation, _, ">"}]]
    ],
    start_tag: [
      open: [[{:punctuation, _, "<"}]],
      close: [[{:punctuation, _, ">"}], [{:punctuation, _, "/>"}]]
    ]
  )

  # Finally, the public API for the lexer
  @impl Makeup.Lexer
  def lex(text, opts \\ []) do
    group_prefix = Keyword.get(opts, :group_prefix, random_prefix(10))
    {:ok, tokens, "", _, _, _} = root(text)

    tokens
    |> postprocess()
    |> match_groups(group_prefix)
  end
end
