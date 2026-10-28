defmodule Earmark.Parser do
  @type ast_meta :: map()
  @type ast_tag :: binary()
  @type ast_attribute_name :: binary()
  @type ast_attribute_value :: binary()
  @type ast_attribute :: {ast_attribute_name(), ast_attribute_value()}
  @type ast_attributes :: list(ast_attribute())
  @type ast_tuple :: {ast_tag(), ast_attributes(), ast(), ast_meta()}
  @type ast_node :: binary() | ast_tuple()
  @type ast :: list(ast_node())

  @moduledoc ~S"""

  ### API

  #### Earmark.Parser.as_ast

  This is the structure of the result of `as_ast`.

      {:ok, ast, []}                   = Earmark.Parser.as_ast(markdown)
      {:ok, ast, deprecation_messages} = Earmark.Parser.as_ast(markdown)
      {:error, ast, error_messages}    = Earmark.Parser.as_ast(markdown)

  For examples see the functiondoc below.

  #### Options

  Options can be passed into `as_ast/2` according to the documentation of `Earmark.Parser.Options`.

      {status, ast, errors} = Earmark.Parser.as_ast(markdown, options)

  ## Supports

  Standard [Gruber markdown][gruber].

  [gruber]: <http://daringfireball.net/projects/markdown/syntax>

  ## Extensions

  ### Links

  #### Links supported by default

  ##### Oneline HTML Link tags

      iex(1)> Earmark.Parser.as_ast(~s{<a href="href">link</a>})
      {:ok, [{"a", [{"href", "href"}], ["link"], %{verbatim: true}}], []}

  ##### Markdown links

  New style ...

      iex(2)> Earmark.Parser.as_ast(~s{[title](destination)})
      {:ok,  [{"p", [], [{"a", [{"href", "destination"}], ["title"], %{}}], %{}}], []}

  and old style

      iex(3)> Earmark.Parser.as_ast("[foo]: /url \"title\"\n\n[foo]\n")
      {:ok, [{"p", [], [{"a", [{"href", "/url"}, {"title", "title"}], ["foo"], %{}}], %{}}], []}

  #### Autolinks

      iex(4)> Earmark.Parser.as_ast("<https://elixir-lang.com>")
      {:ok, [{"p", [], [{"a", [{"href", "https://elixir-lang.com"}], ["https://elixir-lang.com"], %{}}], %{}}], []}

  #### Additional link parsing via options


  #### Pure links

  **N.B.** that the `pure_links` option is `true` by default

      iex(5)> Earmark.Parser.as_ast("https://github.com")
      {:ok, [{"p", [], [{"a", [{"href", "https://github.com"}], ["https://github.com"], %{}}], %{}}], []}

  But can be deactivated

      iex(6)> Earmark.Parser.as_ast("https://github.com", pure_links: false)
      {:ok, [{"p", [], ["https://github.com"], %{}}], []}


    #### Wikilinks...

    are disabled by default

      iex(7)> Earmark.Parser.as_ast("[[page]]")
      {:ok, [{"p", [], ["[[page]]"], %{}}], []}

    and can be enabled

      iex(8)> Earmark.Parser.as_ast("[[page]]", wikilinks: true)
      {:ok, [{"p", [], [{"a", [{"href", "page"}], ["page"], %{wikilink: true}}], %{}}], []}


  ### Sub and Sup HTML Elements

  This feature is not enabled by default but can be enabled with the option `sub_sup: true`

  Therefore we will get

      iex(9)> Earmark.Parser.as_ast("H~2~O or a^n^ + b^n^ = c^n^")
      {:ok, [{"p", [], ["H~2~O or a^n^ + b^n^ = c^n^"], %{}}], []}

  But by specifying `sub_sup: true`

      iex(10)> Earmark.Parser.as_ast("H~2~O or a^n^ + b^n^ = c^n^", sub_sup: true)
      {:ok, [{"p", [], ["H", {"sub", [], ["2"], %{}}, "O or a", {"sup", [], ["n"], %{}}, " + b", {"sup", [], ["n"], %{}}, " = c", {"sup", [], ["n"], %{}}], %{}}], []}

  ### Github Flavored Markdown

  GFM is supported by default, however as GFM is a moving target and all GFM extension do not make sense in a general context, Earmark.Parser does not support all of it, here is a list of what is supported:

  #### Strike Through

      iex(11)> Earmark.Parser.as_ast("~~hello~~")
      {:ok, [{"p", [], [{"del", [], ["hello"], %{}}], %{}}], []}

  #### GFM Tables

  Are not enabled by default

      iex(12)> as_ast("a|b\\n-|-\\nc|d\\n")
      {:ok, [{"p", [], ["a|b\\n-|-\\nc|d\\n"], %{}}], []}

  But can be enabled with `gfm_tables: true`

      iex(13)> as_ast("a|b\n-|-\nc|d\n", gfm_tables: true)
      {:ok,
        [
          {
            "table",
            [],
            [
              {"thead", [], [{"tr", [], [{"th", [{"style", "text-align: left;"}], ["a"], %{}}, {"th", [{"style", "text-align: left;"}], ["b"], %{}}], %{}}], %{}},
              {"tbody", [], [{"tr", [], [{"td", [{"style", "text-align: left;"}], ["c"], %{}}, {"td", [{"style", "text-align: left;"}], ["d"], %{}}], %{}}], %{}}
            ],
            %{}
          }
        ],
        []}

  #### Syntax Highlighting

  All backquoted or fenced code blocks with a language string are rendered with the given
  language as a _class_ attribute of the _code_ tag.

  For example:

      iex(14)> [
      ...(14)>    "```elixir",
      ...(14)>    " @tag :hello",
      ...(14)>    "```"
      ...(14)> ] |> as_ast()
      {:ok, [{"pre", [], [{"code", [{"class", "elixir"}], [" @tag :hello"], %{}}], %{}}], []}

  will be rendered as shown in the doctest above.

  If you want to integrate with a syntax highlighter with different conventions you can add more classes by specifying prefixes that will be
  put before the language string.

  Prism.js for example needs a class `language-elixir`. In order to achieve that goal you can add `language-`
  as a `code_class_prefix` to `Earmark.Parser.Options`.

  In the following example we want more than one additional class, so we add more prefixes.

      iex(15)> [
      ...(15)>    "```elixir",
      ...(15)>    " @tag :hello",
      ...(15)>    "```"
      ...(15)> ] |> as_ast(%Earmark.Parser.Options{code_class_prefix: "lang- language-"})
      {:ok, [{"pre", [], [{"code", [{"class", "elixir lang-elixir language-elixir"}], [" @tag :hello"], %{}}], %{}}], []}


  #### Footnotes

  **N.B.** Footnotes are disabled by default, use `as_ast(..., footnotes: true)` to enable them

  Footnotes are now a **superset** of GFM Footnotes. This implies some changes

    - Footnote definitions (`[^footnote_id]`) must come at the end of your document (_GFM_)
    - Footnotes that are not referenced are not rendered anymore (_GFM_)
    - Footnote definitions can contain any markup with the exception of footnote definitions

          # iex(16)> markdown = [
          # ...(16)> "My reference[^to_footnote]",
          # ...(16)> "",
          # ...(16)> "[^1]: I am not rendered",
          # ...(16)> "[^to_footnote]: Important information"]
          # ...(16)> {:ok, ast, []} = as_ast(markdown, footnotes: true)
          # ...(16)> ast
          # [
          #   {"p", [], ["My reference",
          #     {"a",
          #     [{"href", "#fn:to_footnote"}, {"id", "fnref:to_footnote"}, {"class", "footnote"}, {"title", "see footnote"}],
          #     ["to_footnote"], %{}}
          #   ], %{}},
          #   {"div",
          #   [{"class", "footnotes"}],
          #   [{"hr", [], [], %{}},
          #     {"ol", [],
          #     [{"li", [{"id", "fn:to_footnote"}],
          #       [{"a", [{"title", "return to article"}, {"class", "reversefootnote"}, {"href", "#fnref:to_footnote"}], ["&#x21A9;"], %{}},
          #         {"p", [], ["Important information"], %{}}], %{}}
          #     ], %{}}], %{}}
          # ]

    For more complex examples of footnotes, please refer to
    [these tests](https://github.com/RobertDober/earmark_parser/tree/master/test/acceptance/ast/footnotes/multiple_fn_test.exs)

  #### Breaks

      Hard linebreaks are disabled by default

          iex(17)> ["* a","  b", "c"]
          ...(17)> |> as_ast()
          {:ok,
            [{"ul", [], [{"li", [], ["a\nb\nc"], %{}}], %{}}],
            []}

      But can be enabled with `breaks: true`

          iex(18)> ["* a","  b", "c"]
          ...(18)> |> as_ast(breaks: true)
          {:ok, [{"ul", [], [{"li", [], ["a", {"br", [], [], %{}}, "b", {"br", [], [], %{}}, "c"], %{}}], %{}}], []}

  #### Enabling **all** options that are disabled by default

      Can be achieved with the `all: true` option

          iex(19)> [
          ...(19)> "a^n^",
          ...(19)> "b~2~",
          ...(19)> "[[wikilink]]"]
          ...(19)> |> as_ast(all: true)
          {:ok, [
            {"p", [], ["a", {"sup", [], ["n"], %{}}, {"br", [], [], %{}}, "b", {"sub", [], ["2"], %{}}, {"br", [], [], %{}}, {"a", [{"href", "wikilink"}], ["wikilink"], %{wikilink: true}}], %{}}
            ],
            []}

  #### Tables

  Are supported as long as they are preceded by an empty line.

      State | Abbrev | Capital
      ----: | :----: | -------
      Texas | TX     | Austin
      Maine | ME     | Augusta

  Tables may have leading and trailing vertical bars on each line

      | State | Abbrev | Capital |
      | ----: | :----: | ------- |
      | Texas | TX     | Austin  |
      | Maine | ME     | Augusta |

  Tables need not have headers, in which case all column alignments
  default to left.

      | Texas | TX     | Austin  |
      | Maine | ME     | Augusta |

  Currently we assume there are always spaces around interior vertical unless
  there are exterior bars.

  However in order to be more GFM compatible the `gfm_tables: true` option
  can be used to interpret only interior vertical bars as a table if a separation
  line is given, therefore

       Language|Rating
       --------|------
       Elixir  | awesome

  is a table (if and only if `gfm_tables: true`) while

       Language|Rating
       Elixir  | awesome

  never is.

  #### HTML Blocks

  HTML is not parsed recursively or detected in all conditions right now, though GFM compliance
  is a goal.

  But for now the following holds:

  A HTML Block defined by a tag starting a line and the same tag starting a different line is parsed
  as one HTML AST node, marked with %{verbatim: true}

  E.g.

      iex(20)> lines = [ "<div><span>", "some</span><text>", "</div>more text" ]
      ...(20)> Earmark.Parser.as_ast(lines)
      {:ok, [{"div", [], ["<span>", "some</span><text>"], %{verbatim: true}}, "more text"], []}

  And a line starting with an opening tag and ending with the corresponding closing tag is parsed in similar
  fashion

      iex(21)> Earmark.Parser.as_ast(["<span class=\"superspan\">spaniel</span>"])
      {:ok, [{"span", [{"class", "superspan"}], ["spaniel"], %{verbatim: true}}], []}

  What is HTML?

  We differ from strict GFM by allowing **all** tags not only HTML5 tags this holds for one liners....

      iex(22)> {:ok, ast, []} = Earmark.Parser.as_ast(["<stupid />", "<not>better</not>"])
      ...(22)> ast
      [
        {"stupid", [], [], %{verbatim: true}},
        {"not", [], ["better"], %{verbatim: true}}]

  and for multi line blocks

      iex(23)> {:ok, ast, []} = Earmark.Parser.as_ast([ "<hello>", "world", "</hello>"])
      ...(23)> ast
      [{"hello", [], ["world"], %{verbatim: true}}]

  #### HTML Comments

  Are recognized if they start a line (after ws and are parsed until the next `-->` is found
  all text after the next '-->' is ignored

  E.g.

      iex(24)> Earmark.Parser.as_ast(" <!-- Comment\ncomment line\ncomment --> text -->\nafter")
      {:ok, [{:comment, [], [" Comment", "comment line", "comment "], %{comment: true}}, {"p", [], ["after"], %{}}], []}


  #### Lists

  Lists are pretty much GFM compliant, but some behaviors concerning the interpreation of the markdown inside a List Item's first
  paragraph seem not worth to be interpreted, examples are blockquote in a tight [list item](ttps://babelmark.github.io/?text=*+aa%0A++%3E+Second)
  which we can only have in a [loose one](https://babelmark.github.io/?text=*+aa%0A++%0A++%3E+Second)

  Or a headline in a [tight list item](https://babelmark.github.io/?text=*+bb%0A++%23+Headline) which, again is only available in the
  [loose version](https://babelmark.github.io/?text=*+bb%0A%0A++%23+Headline) in Earmark.Parser.

  furthermore [this example](https://babelmark.github.io/?text=*+aa%0A++%60%60%60%0ASecond%0A++%60%60%60) demonstrates how weird
  and definitely not useful GFM's own interpretation can get.

  Therefore we stick to a more predictable approach.

        iex(25)> markdown = [
        ...(25)> "* aa",
        ...(25)> "  ```",
        ...(25)> "Second",
        ...(25)> "  ```" ]
        ...(25)> as_ast(markdown)
        {:ok, [{"ul", [], [{"li", [], ["aa", {"pre", [], [{"code", [], ["Second"], %{}}], %{}}], %{}}], %{}}], []}

  Also we do support the immediate style of block content inside lists

        iex(26)> as_ast("* > Nota Bene!")
        {:ok, [{"ul", [], [{"li", [], [{"blockquote", [], [{"p", [], ["Nota Bene!"], %{}}], %{}}], %{}}], %{}}], []}

  or

        iex(27)> as_ast("1. # Breaking...")
        {:ok, [{"ol", [], [{"li", [], [{"h1", [], ["Breaking..."], %{}}], %{}}], %{}}], []}


  ### Adding Attributes with the IAL extension

  #### To block elements

  HTML attributes can be added to any block-level element. We use
  the Kramdown syntax: add the line `{:` _attrs_ `}` following the block.

      iex(28)> markdown = ["# Headline", "{:.from-next-line}"]
      ...(28)> as_ast(markdown)
      {:ok, [{"h1", [{"class", "from-next-line"}], ["Headline"], %{}}], []}

  Headers can also have the IAL string at the end of the line

      iex(29)> markdown = ["# Headline{:.from-same-line}"]
      ...(29)> as_ast(markdown)
      {:ok, [{"h1", [{"class", "from-same-line"}], ["Headline"], %{}}], []}

  A special use case is headers inside blockquotes which allow for some nifty styling in `ex_doc`*
  see [this PR](https://github.com/elixir-lang/ex_doc/pull/1400) if you are interested in the technical
  details

      iex(30)> markdown = ["> # Headline{:.warning}"]
      ...(30)> as_ast(markdown)
      {:ok, [{"blockquote", [], [{"h1", [{"class", "warning"}], ["Headline"], %{}}], %{}}], []}

  This also works for headers inside lists

      iex(31)> markdown = ["- # Headline{:.warning}"]
      ...(31)> as_ast(markdown)
      {:ok, [{"ul", [], [{"li", [], [{"h1", [{"class", "warning"}], ["Headline"], %{}}], %{}}], %{}}], []}

  It still works for inline code, as it did before

      iex(32)> markdown = "`Enum.map`{:lang=elixir}"
      ...(32)> as_ast(markdown)
      {:ok, [{"p", [], [{"code", [{"class", "inline"}, {"lang", "elixir"}], ["Enum.map"], %{}}], %{}}], []}


  _attrs_ can be one or more of:

    * `.className`
    * `#id`
    * name=value, name="value", or name='value'

  For example:

      # Warning
      {: .red}

      Do not turn off the engine
      if you are at altitude.
      {: .boxed #warning spellcheck="true"}

  #### To links or images

  It is possible to add IAL attributes to generated links or images in the following
  format.

      iex(33)> markdown = "[link](url) {: .classy}"
      ...(33)> Earmark.Parser.as_ast(markdown)
      { :ok, [{"p", [], [{"a", [{"class", "classy"}, {"href", "url"}], ["link"], %{}}], %{}}], []}

  For both cases, malformed attributes are ignored and warnings are issued.

      iex(34)> [ "Some text", "{:hello}" ] |> Enum.join("\n") |> Earmark.Parser.as_ast()
      {:error, [{"p", [], ["Some text"], %{}}], [{:warning, 2,"Illegal attributes [\"hello\"] ignored in IAL"}]}

  It is possible to escape the IAL in both forms if necessary

      iex(35)> markdown = "[link](url)\\{: .classy}"
      ...(35)> Earmark.Parser.as_ast(markdown)
      {:ok, [{"p", [], [{"a", [{"href", "url"}], ["link"], %{}}, "{: .classy}"], %{}}], []}

  This of course is not necessary in code blocks or text lines
  containing an IAL-like string, as in the following example

      iex(36)> markdown = "hello {:world}"
      ...(36)> Earmark.Parser.as_ast(markdown)
      {:ok, [{"p", [], ["hello {:world}"], %{}}], []}

  ## Limitations

    * Block-level HTML is correctly handled only if each HTML
      tag appears on its own line. So

          <div>
          <div>
          hello
          </div>
          </div>

      will work. However. the following won't

          <div>
          hello</div>

    * John Gruber's tests contain an ambiguity when it comes to
      lines that might be the start of a list inside paragraphs.

      One test says that

          This is the text
          * of a paragraph
          that I wrote

      is a single paragraph. The "*" is not significant. However, another
      test has

          *   A list item
              * an another

      and expects this to be a nested list. But, in reality, the second could just
      be the continuation of a paragraph.

      I've chosen always to use the second interpretation—a line that looks like
      a list item will always be a list item.

    * Rendering of block and inline elements.

      Block or void HTML elements that are at the absolute beginning of a line end
      the preceding paragraph.

      Thusly

          mypara
          <hr />

      Becomes

          <p>mypara</p>
          <hr />

      While

          mypara
           <hr />

      will be transformed into

          <p>mypara
           <hr /></p>

  ## Annotations

  **N.B.** this is an experimental feature from v1.4.16-pre on and might change or be removed again

  The idea is that each markdown line can be annotated, as such annotations change the semantics of Markdown
  they have to be enabled with the `annotations` option.

  If the `annotations` option is set to a string (only one string is supported right now, but a list might
  be implemented later on, hence the name), the last occurrence of that string in a line and all text following
  it will be added to the line as an annotation.

  Depending on how that line will eventually be parsed, this annotation will be added to the meta map (the 4th element
  in an AST quadruple) with the key `:annotation`

  In the current version the annotation will only be applied to verbatim HTML tags and paragraphs

  Let us show some examples now:

  ### Annotated Paragraphs

      iex(37)> as_ast("hello %> annotated", annotations: "%>")
      {:ok, [{"p", [], ["hello "], %{annotation: "%> annotated"}}], []}

  If we annotate more than one line in a para the first annotation takes precedence

      iex(38)> as_ast("hello %> annotated\nworld %> discarded", annotations: "%>")
      {:ok, [{"p", [], ["hello \nworld "], %{annotation: "%> annotated"}}], []}

  ### Annotated HTML elements

  In one line

      iex(39)> as_ast("<span>One Line</span> // a span", annotations: "//")
      {:ok, [{"span", [], ["One Line"], %{annotation: "// a span", verbatim: true}}], []}

  or block elements

      iex(40)> [
      ...(40)> "<div> : annotation",
      ...(40)> "  <span>text</span>",
      ...(40)> "</div> : discarded"
      ...(40)> ] |> as_ast(annotations: " : ")
      {:ok, [{"div", [], ["  <span>text</span>"], %{annotation: " : annotation", verbatim: true}}], []}

  ### Commenting your Markdown

  Although many markdown elements do not support annotations yet, they can be used to comment your markdown, w/o cluttering
  the generated AST with comments

      iex(41)> [
      ...(41)> "# Headline --> first line",
      ...(41)> "- item1 --> a list item",
      ...(41)> "- item2 --> another list item",
      ...(41)> "",
      ...(41)> "<http://somewhere/to/go> --> do not go there"
      ...(41)> ] |> as_ast(annotations: "-->")
      {:ok, [
        {"h1", [], ["Headline"], %{}},
        {"ul", [], [{"li", [], ["item1 "], %{}}, {"li", [], ["item2 "], %{}}], %{}},
        {"p", [], [{"a", [{"href", "http://somewhere/to/go"}], ["http://somewhere/to/go"], %{}}, " "], %{annotation: "--> do not go there"}}
        ], []
       }

  """

  alias Earmark.Parser.Options
  import Earmark.Parser.Message, only: [sort_messages: 1]

  @doc """
      iex(42)> markdown = "My `code` is **best**"
      ...(42)> {:ok, ast, []} = Earmark.Parser.as_ast(markdown)
      ...(42)> ast
      [{"p", [], ["My ", {"code", [{"class", "inline"}], ["code"], %{}}, " is ", {"strong", [], ["best"], %{}}], %{}}]



      iex(43)> markdown = "```elixir\\nIO.puts 42\\n```"
      ...(43)> {:ok, ast, []} = Earmark.Parser.as_ast(markdown, code_class_prefix: "lang-")
      ...(43)> ast
      [{"pre", [], [{"code", [{"class", "elixir lang-elixir"}], ["IO.puts 42"], %{}}], %{}}]

  **Rationale**:

  The AST is exposed in the spirit of [Floki's](https://hex.pm/packages/floki).
  """
  @spec as_ast([String.t()] | String.t(), Earmark.Options.options()) ::
          {:error, binary(), [any()]} | {:ok, binary(), [map()]}
  def as_ast(lines, options \\ %Options{})

  def as_ast(lines, %Options{} = options) do
    context = _as_ast(lines, options)

    messages = sort_messages(context)
    messages1 = Options.add_deprecations(options, messages)

    status =
      case Enum.any?(messages1, fn {severity, _, _} ->
             severity == :error || severity == :warning
           end) do
        true -> :error
        _ -> :ok
      end

    {status, context.value, messages1}
  end

  def as_ast(lines, options) when is_list(options) do
    as_ast(lines, struct(Options, options))
  end

  def as_ast(lines, options) when is_map(options) do
    as_ast(lines, struct(Options, options |> Map.delete(:__struct__) |> Enum.into([])))
  end

  def as_ast(_, options) do
    raise ArgumentError, "#{inspect(options)} not a legal options map or keyword list"
  end

  defp _as_ast(lines, options) do
    {blocks, context} = Earmark.Parser.Parser.parse_markdown(lines, Options.normalize(options))
    Earmark.Parser.AstRenderer.render(blocks, context)
  end

  @doc """
    Accesses current hex version of the `Earmark.Parser` application. Convenience for
    `iex` usage.
  """
  def version() do
    with {:ok, version} <- :application.get_key(:earmark_parser, :vsn),
         do: to_string(version)
  end
end

# SPDX-License-Identifier: Apache-2.0
