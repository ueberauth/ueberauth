defmodule Makeup.Lexers.ErlangLexer do
  @moduledoc """
  A `Makeup` lexer for the `Erlang` language.
  """

  @behaviour Makeup.Lexer

  import NimbleParsec
  import Makeup.Lexer.Combinators
  import Makeup.Lexer.Groups
  import Makeup.Lexers.ErlangLexer.Helper

  ###################################################################
  # Step #1: tokenize the input (into a list of tokens)
  ###################################################################

  whitespace = ascii_string([?\s, ?\f, ?\r, ?\n, ?\t], min: 1) |> token(:whitespace)

  # This is the combinator that ensures that the lexer will never reject a file
  # because of invalid input syntax
  any_char = utf8_char([]) |> token(:error)

  comment =
    ascii_char([?%])
    |> optional(utf8_string([not: ?\n], min: 1))
    |> token(:comment_single)

  hashbang =
    string("\n#!")
    |> utf8_string([not: ?\n], min: 1)
    |> string("\n")
    |> token(:comment_hashbang)

  escape_octal = ascii_string([?0..?7], min: 1, max: 3)

  escape_char = ascii_char([?\b, ?\d, ?\e, ?\f, ?\n, ?\r, ?\s, ?\t, ?\v, ?\', ?\", ?\\])

  escape_hex =
    choice([
      string("x") |> ascii_string([?0..?9, ?a..?f, ?A..?F], 2),
      string("x{") |> ascii_string([?0..?9, ?a..?f, ?A..?F], min: 1) |> string("}")
    ])

  escape_ctrl = string("^") |> ascii_char([?a..?z, ?A..?Z])

  escape =
    choice([
      escape_char,
      escape_octal,
      escape_hex,
      escape_ctrl
    ])

  numeric_base =
    choice([
      ascii_char([?1..?2]) |> ascii_char([?0..?9]),
      string("3") |> ascii_char([?0..?6]),
      ascii_char([?2..?9])
    ])

  # Numbers
  #
  # Erlang/OTP 27 added underscore separators in numeric literals
  # (`1_000_000`, `16#FF_FF`, `0.1_5e1_0`). Lexer-tolerant: underscores are
  # accepted anywhere inside the digit run; we don't validate position.
  digits = ascii_string([?0..?9, ?_], min: 1)

  number_integer =
    optional(ascii_char([?+, ?-]))
    |> ascii_char([?0..?9])
    |> optional(ascii_string([?0..?9, ?_], min: 1))
    |> token(:number_integer)

  number_integer_in_weird_base =
    optional(ascii_char([?+, ?-]))
    |> concat(numeric_base)
    |> string("#")
    |> ascii_string([?0..?9, ?a..?z, ?A..?Z, ?_], min: 1)
    |> token(:number_integer)

  # Floating point numbers
  float_scientific_notation_part =
    ascii_string([?e, ?E], 1)
    |> optional(ascii_char([?+, ?-]))
    |> concat(digits)

  number_float =
    optional(ascii_char([?+, ?-]))
    |> concat(digits)
    |> string(".")
    |> concat(digits)
    |> optional(float_scientific_notation_part)
    |> token(:number_float)

  variable_name =
    ascii_string([?A..?Z, ?_], 1)
    |> optional(ascii_string([?a..?z, ?_, ?0..?9, ?A..?Z], min: 1))

  # An underscore followed by at least one identifier character (`_5`,
  # `_X`, `_unused`). Bare `_` stays as a punctuation token (the wildcard
  # pattern), but `_<id>` is a variable in Erlang grammar and should
  # render as `:name`. Without this rule the `_` is matched first by
  # the `punctuation` rule and the rest of the identifier falls through.
  underscore_identifier =
    string("_")
    |> ascii_string([?a..?z, ?_, ?0..?9, ?A..?Z], min: 1)
    |> token(:name)

  simple_atom_name =
    ascii_string([?a..?z], 1)
    |> optional(ascii_string([?a..?z, ?_, ?@, ?0..?9, ?A..?Z], min: 1))
    |> reduce({Enum, :join, []})

  single_quote_escape = string("\\'")

  quoted_atom_name_middle =
    lookahead_not(string("'"))
    |> choice([
      single_quote_escape,
      utf8_string([not: ?\n, not: ?', not: ?\\], min: 1),
      escape
    ])

  quoted_atom_name =
    string("'")
    |> repeat(quoted_atom_name_middle)
    |> concat(string("'"))

  atom_name =
    choice([
      simple_atom_name,
      quoted_atom_name
    ])

  atom = token(atom_name, :string_symbol)

  namespace =
    token(atom_name, :name_class)
    |> concat(token(":", :punctuation))

  function =
    atom_name
    |> lexeme()
    |> token(:name_function)
    |> concat(optional(whitespace))
    |> concat(token("(", :punctuation))

  # Can also be a function name
  variable =
    variable_name
    # Check if you need to use the lexeme parser
    # (i.e. if you need the token value to be a string)
    # If not, just delete the lexeme parser
    |> lexeme()
    |> token(:name)

  macro_name = choice([variable_name, atom_name])

  # Parameterised macro reference: `?FOO(arg1, arg2)`. Tokenised
  # separately from the parameterless form so themes can render the two
  # distinctly (matches `makeup_elixir`'s split between `@foo` and
  # `@foo(...)`). The macro head emits as `:name_function`; the trailing
  # `(` opens the standard punctuation group so paren matching still
  # works.
  macro_call =
    string("?")
    |> concat(macro_name)
    |> token(:name_function)
    |> concat(optional(whitespace))
    |> concat(token("(", :punctuation))

  # Parameterless macro: `?FOO`. Constants by convention.
  macro =
    string("?")
    |> concat(macro_name)
    |> token(:name_constant)

  label =
    string("#")
    |> concat(atom_name)
    |> optional(string(".") |> concat(atom_name))
    |> token(:name_label)

  # `$\xFF`, `$\x{1F600}`, `$\077`, `$\^A`, plus simple `$\n` / `$\t` / `$\\` /
  # `$\"` / `$\'` etc. The structured escapes (octal, hex, ctrl) must be tried
  # before the single-char fallback so multi-character sequences are consumed
  # whole.
  character_escape =
    string("\\")
    |> choice([
      escape_hex,
      escape_octal,
      escape_ctrl,
      utf8_char([])
    ])

  character =
    string("$")
    |> choice([
      character_escape,
      utf8_char(not: ?\\)
    ])
    |> token(:string_char)

  string_interpol =
    string("~")
    |> optional(ascii_string([?0..?9, ?., ?*], min: 1))
    |> ascii_char(to_charlist("~#+BPWXb-ginpswx"))
    |> token(:string_interpol)

  # Sub-token emitted inside string literals for escape sequences. Mirrors
  # the `character_escape` shape so multi-character escapes (`\xFF`,
  # `\x{1F600}`, `\077`, `\^A`) are consumed whole instead of getting
  # cut at the first byte. Themes can render these distinctly.
  escaped_char =
    string("\\")
    |> choice([
      escape_hex,
      escape_octal,
      escape_ctrl,
      utf8_char([])
    ])
    |> token(:string_escape)

  erlang_string = string_like(~s/"/, ~s/"/, [escaped_char, string_interpol], :string)

  # Multi-quoted strings (OTP 27+). The opening run of `"""` (or more) on
  # its own line opens the string; a matching run on its own line closes
  # it. Use a quadruple/quintuple opener when the body needs to contain
  # `"""` literally. Each variant is a separate rule because NimbleParsec
  # doesn't support dynamic delimiter lengths; longer-quote variants must
  # be tried first so the triple-quote rule doesn't claim them prematurely.
  quintuple_quoted_string =
    lookahead_string(
      string(~s/"""""\n/),
      string(~s/\n"""""/),
      [escaped_char, string_interpol]
    )

  quadruple_quoted_string =
    lookahead_string(
      string(~s/""""\n/),
      string(~s/\n""""/),
      [escaped_char, string_interpol]
    )

  triple_quoted_string =
    lookahead_string(string(~s/"""\n/), string(~s/\n"""/), [escaped_char, string_interpol])

  # Longer-quote variants must come first so the longest matching delimiter
  # wins for sigils like `~"""""..."""""` (quintuple) or `~""""..."""" `
  # (quadruple) — these are needed when the sigil body has to contain
  # `"""` or `""""` literally, mirroring the rule for plain multi-quoted
  # strings above.
  sigil_delimiters = [
    {~s["""""\n], ~s[\n"""""]},
    {"'''''\n", "\n'''''"},
    {~s[""""\n], ~s[\n""""]},
    {"''''\n", "\n''''"},
    {~s["""\n], ~s[\n"""]},
    {"'''\n", "\n'''"},
    {"\"", "\""},
    {"'", "'"},
    {"/", "/"},
    {"{", "}"},
    {"[", "]"},
    {"(", ")"},
    {"<", ">"},
    {"|", "|"},
    {"`", "`"},
    {"#", "#"}
  ]

  default_sigil_interpol =
    for {ldelim, rdelim} <- sigil_delimiters do
      sigil(ldelim, rdelim, nil, [escaped_char, string_interpol])
    end

  sigils_interpol =
    for {ldelim, rdelim} <- sigil_delimiters do
      sigil(ldelim, rdelim, [?b, ?s], [escaped_char, string_interpol])
    end

  sigils_no_interpol =
    for {ldelim, rdelim} <- sigil_delimiters do
      sigil(ldelim, rdelim, [?B, ?S], [string_interpol])
    end

  all_sigils = default_sigil_interpol ++ sigils_interpol ++ sigils_no_interpol

  # Combinators that highlight expressions surrounded by a pair of delimiters.
  punctuation =
    word_from_list(
      [","] ++ ~w[\[ \] : _ @ \" . \#{ { } ( ) | ; => := << >> || -> \# &&],
      :punctuation
    )

  tuple = many_surrounded_by(parsec(:root_element), "{", "}")

  syntax_operators =
    word_from_list(
      ~W[+ - +? ++ = == -- * / < > /= =:= =/= =< >= ==? <- <:- <= <:= ! ? ?! ?=],
      :operator
    )

  # OTP 29 native records relax the record-name rule: per the spec
  # (https://www.erlang.org/doc/system/data_types.html), "it is not necessary
  # to quote atoms that look like variable names or keywords." So `#State{}`,
  # `#div{}`, `#case{}` are all valid record references even though `State`
  # is variable-shape and `div`/`case` are reserved words. Tuple-based records
  # don't allow these forms, but the lexer can't tell the two record kinds
  # apart from local context — so accept the union.
  #
  # The `record_name: true` meta marker tells postprocess to skip the
  # keyword / builtin / word-operator conversion for this position. Without
  # it, `#case{}` would tokenise as `[#, keyword case, {]` — visually
  # confusing because `case` here names a record, not an expression keyword.
  record_name =
    choice([
      token(atom_name, :string_symbol, %{record_name: true}),
      token(variable_name, :string_symbol, %{record_name: true})
    ])

  # External native record construction / pattern / field access:
  #     #Module:Name{F = V}
  #     #Module:Name.field
  # The `Module:Name` shape between `#` and `{` (or `.`) was added in OTP 29
  # alongside native records. Local construction (`#Name{...}`) is identical
  # in shape to a tuple-based record and is handled by the rule below.
  native_record_external =
    token(string("#"), :operator)
    |> concat(token(atom_name, :name_class))
    |> concat(token(":", :punctuation))
    |> concat(record_name)
    |> choice([
      token("{", :punctuation),
      token(".", :punctuation)
    ])

  record =
    token(string("#"), :operator)
    |> concat(record_name)
    |> choice([
      token("{", :punctuation),
      token(".", :punctuation)
    ])

  # We need to match on the new line here as to not tokenize a function call as a module attribute.
  # Without the newline matching, the expression `a(X) - b(Y)` would tokenize
  # `b(Y)` as a module attribute definition instead of a function call.
  module_attribute =
    token("\n", :whitespace)
    |> optional(whitespace)
    |> concat(token("-", :punctuation))
    |> optional(whitespace)
    |> concat(atom_name |> token(:name_attribute))
    |> optional(whitespace)
    |> optional(token("(", :punctuation))

  function_arity =
    atom
    |> concat(token("/", :punctuation))
    |> concat(number_integer)

  # Erlang prompt. Anchored to a line boundary by requiring the leading
  # whitespace to contain at least one `\n`. The original rule required
  # the `\n` immediately before the prompt body, which broke when the
  # generic `whitespace` rule had already consumed the trailing `\n` of
  # a multi-character whitespace block (see makeup_elixir #28). Allowing
  # any leading non-newline whitespace before the `\n` and any further
  # whitespace after lets the rule match in those cases without
  # false-positiving on `1 > 2` or `x. 1> a.` (neither contains a `\n`
  # in the relevant position).
  erl_prompt =
    ascii_string([?\s, ?\f, ?\r, ?\t], min: 0)
    |> string("\n")
    |> optional(ascii_string([?\s, ?\f, ?\r, ?\n, ?\t], min: 1))
    |> token(:whitespace)
    |> concat(
      optional(string("(") |> concat(atom_name) |> string(")"))
      |> optional(digits)
      |> string("> ")
      |> token(:generic_prompt, %{selectable: false})
    )

  # Error in shell
  erl_shell_error =
    token("\n", :whitespace)
    |> concat(
      string("* ")
      |> utf8_string([not: ?\n], min: 1)
      |> token(:generic_traceback)
    )

  erl_shell_multiline_error =
    token("\n", :whitespace)
    |> concat(
      string("** ")
      |> utf8_string([not: ?\n], min: 1)
      |> repeat(
        string("\n    ")
        |> utf8_string([not: ?\n], min: 1)
      )
      |> token(:generic_traceback)
    )

  # Tag the tokens with the language name.
  # This makes it easier to postprocess files with multiple languages.
  @doc false
  def __as_erlang_language__({ttype, meta, value}) do
    {ttype, Map.put(meta, :language, :erlang), value}
  end

  root_element_combinator =
    choice(
      [
        erl_prompt,
        erl_shell_error,
        erl_shell_multiline_error,
        module_attribute,
        hashbang,
        whitespace,
        comment,
        quintuple_quoted_string,
        quadruple_quoted_string,
        triple_quoted_string,
        erlang_string
      ] ++
        all_sigils ++
        [
          native_record_external,
          record,
          underscore_identifier,
          # Macros must be tried before `syntax_operators`, since the
          # operator list contains `?` and `?=` and would otherwise eat the
          # leading `?` of `?FOO` / `?FOO(X)`.
          macro_call,
          macro,
          punctuation,
          # `tuple` might be unnecessary
          tuple,
          syntax_operators,
          # Numbers
          number_integer_in_weird_base,
          number_float,
          number_integer,
          # Variables
          variable,
          namespace,
          function_arity,
          function,
          atom,
          character,
          label,
          # If we can't parse any of the above, we highlight the next character as an error
          # and proceed from there.
          # A lexer should always consume any string given as input.
          any_char
        ]
    )

  ##############################################################################
  # Semi-public API: these two functions can be used by someone who wants to
  # embed this lexer into another lexer, but other than that, they are not
  # meant to be used by end-users
  ##############################################################################

  @impl Makeup.Lexer
  defparsec(
    :root_element,
    root_element_combinator |> map({__MODULE__, :__as_erlang_language__, []})
  )

  @impl Makeup.Lexer
  defparsec(
    :root,
    repeat(parsec(:root_element))
  )

  ###################################################################
  # Step #2: postprocess the list of tokens
  ###################################################################

  @keywords ~W[after begin case catch cond end fun if let of query receive try when maybe else]

  # Auto-imported BIFs, sourced at compile time from `erl_internal:bif/2` —
  # the same predicate the Erlang compiler uses to decide what's auto-imported.
  # Refreshed every time `makeup_erlang` is rebuilt, so the list stays in sync
  # with the OTP version we compile against and never bit-rots.
  @builtins :erlang.module_info(:exports)
            |> Enum.filter(fn {name, arity} -> :erl_internal.bif(name, arity) end)
            |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)
            |> Enum.uniq()
            |> Enum.sort()

  @word_operators ~W[and andalso band bnot bor bsl bsr bxor div not or orelse rem xor]

  # Record names tagged by the `record_name` combinator should not be
  # reclassified as keywords / builtins / word-operators even if their
  # text happens to match. Strip the marker after acting on it so it
  # doesn't leak into the rendered output.
  defp postprocess_helper([{:string_symbol, %{record_name: true} = meta, value} | tokens]),
    do: [{:string_symbol, Map.delete(meta, :record_name), value} | postprocess_helper(tokens)]

  defp postprocess_helper([{:string_symbol, meta, value} | tokens]) when value in @keywords,
    do: [{:keyword, meta, value} | postprocess_helper(tokens)]

  # Keywords followed by `(` are first matched by the `function` rule and
  # tagged `:name_function`. Recover them here. The most common case is
  # `fun(X) -> ... end`; the rule also covers any other keyword that gets
  # written next to `(` (e.g. `if(X)` in a teaching example of invalid
  # syntax).
  defp postprocess_helper([{:name_function, meta, value} | tokens]) when value in @keywords,
    do: [{:keyword, meta, value} | postprocess_helper(tokens)]

  defp postprocess_helper([{:string_symbol, meta, value} | tokens]) when value in @builtins,
    do: [{:name_builtin, meta, value} | postprocess_helper(tokens)]

  # Same recovery for builtins: when a BIF is called as `length(L)` it is
  # first matched by the `function` rule and tagged `:name_function`. Closes
  # makeup_erlang #13.
  defp postprocess_helper([{:name_function, meta, value} | tokens]) when value in @builtins,
    do: [{:name_builtin, meta, value} | postprocess_helper(tokens)]

  defp postprocess_helper([{:string_symbol, meta, value} | tokens]) when value in @word_operators,
    do: [{:operator_word, meta, value} | postprocess_helper(tokens)]

  defp postprocess_helper([token | tokens]), do: [token | postprocess_helper(tokens)]

  defp postprocess_helper([]), do: []

  # By default, return the list of tokens unchanged
  @impl Makeup.Lexer
  def postprocess(tokens, _opts \\ []), do: postprocess_helper(tokens)

  #######################################################################
  # Step #3: highlight matching delimiters
  # By default, this includes delimiters that are used in many languages,
  # but feel free to delete these or add more.
  #######################################################################

  @impl Makeup.Lexer
  defgroupmatcher(:match_groups,
    parentheses: [
      open: [[{:punctuation, %{language: :erlang}, "("}]],
      close: [[{:punctuation, %{language: :erlang}, ")"}]]
    ],
    list: [
      open: [
        [{:punctuation, %{language: :erlang}, "["}]
      ],
      close: [
        [{:punctuation, %{language: :erlang}, "]"}]
      ]
    ],
    binary: [
      open: [
        [{:punctuation, %{language: :erlang}, "<<"}]
      ],
      close: [
        [{:punctuation, %{language: :erlang}, ">>"}]
      ]
    ],
    tuple: [
      open: [
        [{:punctuation, %{language: :erlang}, "{"}]
      ],
      close: [
        [{:punctuation, %{language: :erlang}, "}"}]
      ]
    ],
    map: [
      open: [
        [{:punctuation, %{language: :erlang}, "\#{"}]
      ],
      close: [
        [{:punctuation, %{language: :erlang}, "}"}]
      ]
    ]
  )

  defp remove_initial_newline([{ttype, meta, text} | tokens]) do
    case to_string(text) do
      "\n" -> tokens
      "\n" <> rest -> [{ttype, meta, rest} | tokens]
    end
  end

  # Finally, the public API for the lexer
  @impl Makeup.Lexer
  def lex(text, opts \\ []) do
    group_prefix = Keyword.get(opts, :group_prefix, random_prefix(10))
    {:ok, tokens, "", _, _, _} = root("\n" <> text)

    tokens
    |> remove_initial_newline()
    |> postprocess()
    |> match_groups(group_prefix)
  end
end
