defmodule Earmark do
  if Version.compare(System.version(), "1.12.0") == :lt do
    IO.puts(
      :stderr,
      "DEPRECATION WARNING: versions < 1.12.0 of Elixir are not tested anymore and will not be supported in Earmark v1.5"
    )
  end

  @type ast_meta :: map()
  @type ast_tag :: binary()
  @type ast_attribute_name :: binary()
  @type ast_attribute_value :: binary()
  @type ast_attribute :: {ast_attribute_name(), ast_attribute_value()}
  @type ast_attributes :: list(ast_attribute())
  @type ast_tuple :: {ast_tag(), ast_attributes(), ast(), ast_meta()}
  @type ast_node :: binary() | ast_tuple()
  @type ast :: list(ast_node())

  @moduledoc """

  ## Earmark

  ### Abstract Syntax Tree and Rendering

  The AST generation has now been moved out to [`EarmarkParser`](https://github.com/robertdober/earmark_parser)
  which is installed as a dependency.

  This brings some changes to this documentation and also deprecates the usage of `Earmark.as_ast`

  Earmark takes care of rendering the AST to HTML, exposing some AST Transformation Tools and providing a CLI as escript.

  Therefore you will not find a detailed description of the supported Markdown here anymore as this is done in
  [here](https://hexdocs.pm/earmark_parser/EarmarkParser.html).



  #### Earmark.as_ast

  WARNING: This is just a proxy towards `Earmark.Parser.as_ast` and is deprecated, it will be removed in version 1.5!

  Replace your calls to `Earmark.as_ast` with `EarmarkParse.as_ast` as soon as possible.

  **N.B.** If all you use is `Earmark.as_ast` consider _only_ using `Earmark.Parser`.

  Also please refer yourself to the documentation of [`EarmarkParser`](https://hexdocs.pm/earmark_parser/EarmarkParser.html).


  The function is described below and the other two API functions `as_html` and `as_html!` are now based upon
  the structure of the result of `as_ast`.

      {:ok, ast, []}                   = Earmark.Parser.as_ast(markdown)
      {:ok, ast, deprecation_messages} = Earmark.Parser.as_ast(markdown)
      {:error, ast, error_messages}    = Earmark.Parser.as_ast(markdown)

  #### Earmark.as_html

      {:ok, html_doc, []}                   = Earmark.as_html(markdown)
      {:ok, html_doc, deprecation_messages} = Earmark.as_html(markdown)
      {:error, html_doc, error_messages}    = Earmark.as_html(markdown)

  #### Earmark.as_html!

      html_doc = Earmark.as_html!(markdown, options)

  Formats the error_messages returned by `as_html` and adds the filename to each.
  Then prints them to stderr and just returns the html_doc

  #### Options

  Options can be passed into as `as_html/2` or `as_html!/2` according to the documentation.
  A keyword list with legal options (c.f. `Earmark.Options`) or an `Earmark.Options` struct are accepted.

      {status, html_doc, errors} = Earmark.as_html(markdown, options)
      html_doc = Earmark.as_html!(markdown, options)
      {status, ast, errors} = Earmark.Parser.as_ast(markdown, options)

  ### Rendering

  All options passed through to `Earmark.Parser.as_ast` are defined therein, however some options concern only
  the rendering of the returned AST

  These are:

  * `compact_output:` defaults to `false`

  Normally `Earmark` aims to produce _Human Readable_ output.

  This will give results like these:

      iex(1)> markdown = "# Hello\\nWorld"
      ...(1)> Earmark.as_html!(markdown, compact_output: false)
      "<h1>\\nHello</h1>\\n<p>\\nWorld</p>\\n"


  But sometimes whitespace is not desired:

      iex(2)> markdown = "# Hello\\nWorld"
      ...(2)> Earmark.as_html!(markdown, compact_output: true)
      "<h1>Hello</h1><p>World</p>"

  Be cautions though when using this options, lines will become loooooong.


  #### `escape:` defaulting to `true`

  If set HTML will be properly escaped

        iex(3)> markdown = "Hello<br>World"
        ...(3)> Earmark.as_html!(markdown)
        "<p>\\nHello&lt;br&gt;World</p>\\n"

  However disabling `escape:` gives you maximum control of the created document, which in some
  cases (e.g. inside tables) might even be necessary

        iex(4)> markdown = "Hello<br>World"
        ...(4)> Earmark.as_html!(markdown, escape: false)
        "<p>\\nHello<br>World</p>\\n"

  #### `inner_html:` defaulting to `false`

  This is especially useful inside templates, when a block element will disturb the layout as
  in this case

  ```html
  <span><%= Earmark.as_html!(....)%></span>
  <span><%= Earmark.as_html!(....)%></span>
  ```

  By means of the `inner_html` option the disturbing paragraph can be removed from `as_html!`'s
  output

        iex(5)> markdown = "Hello<br>World"
        ...(5)> Earmark.as_html!(markdown, escape: false, inner_html: true)
        "Hello<br>World\\n"

  **N.B.** that this applies only to top level paragraphs, as can be seen here

        iex(6)> markdown = "- Item\\n\\nPara"
        ...(6)> Earmark.as_html!(markdown, inner_html: true)
        "<ul>\\n  <li>\\nItem  </li>\\n</ul>\\nPara\\n"


  * `postprocessor:` defaults to nil

  Before rendering, the AST is transformed by a postprocessor.
  For details, see the description of `Earmark.Transform.map_ast` below which will accept the same postprocessor.
  As a matter of fact, specifying `postprocessor: fun` is conceptually the same as

  ```elixir
            markdown
            |> Earmark.Parser.as_ast
            |> Earmark.Transform.map_ast(fun)
            |> Earmark.Transform.transform
  ```

  with all the necessary bookkeeping for options and messages

  * `renderer:` defaults to `Earmark.HtmlRenderer`

    The module used to render the final document.

  #### `smartypants:` defaulting to `true`

  If set the following replacements will be made during rendering of inline text

      "---" → "—"
      "--" → "–"
      "' → "’"
      ?" → "”"
      "..." → "…"

  ### Command line

  ```sh
      $ mix escript.build
      $ ./earmark file.md
  ```

  Some options defined in the `Earmark.Options` struct can be specified as command line switches.

  Use

  ```sh
      $ ./earmark --help
  ```

  to find out more, but here is a short example

  ```sh
      $ ./earmark --smartypants false --code-class-prefix "a- b-" file.md
  ```

  will call

  ```sh
      Earmark.as_html!( ..., %Earmark.Options{smartypants: false, code_class_prefix: "a- b-"})
  ```

  ### Timeouts

  By default, that is if the `timeout` option is not set Earmark uses parallel mapping as implemented in `Earmark.pmap/2`,
  which uses `Task.await` with its default timeout of 5000ms.

  In rare cases that might not be enough.

  By indicating a longer `timeout` option in milliseconds Earmark will use parallel mapping as implemented in `Earmark.pmap/3`,
  which will pass `timeout` to `Task.await`.

  In both cases one can override the mapper function with either the `mapper` option (used if and only if `timeout` is nil) or the
  `mapper_with_timeout` function (used otherwise).

  For the escript only the `timeout` command line argument can be used.

  ### Security


  Please be aware that Markdown is not a secure format. It produces
  HTML from Markdown and HTML. It is your job to sanitize and or
  filter the output of `Earmark.as_html` if you cannot trust the input
  and are to serve the produced HTML on the Web.
  """

  alias Earmark.{Internal, Options, Transform}
  alias Earmark.EarmarkParserProxy, as: Proxy

  defdelegate as_ast!(markdown, options \\ []), to: Internal
  defdelegate as_html(lines, options \\ []), to: Internal
  defdelegate as_html!(lines, options \\ []), to: Internal

  @doc """
  DEPRECATED call `Earmark.Parser.as_ast` instead
  """
  def as_ast(lines, options \\ %Options{}) do
    {status, ast, messages} = _as_ast(lines, options)

    message =
      {:warning, 0,
       "DEPRECATION: Earmark.as_ast will be removed in version 1.5, please use Earmark.Parser.as_ast, which is of the same type"}

    messages1 = [message | messages]
    {status, ast, messages1}
  end

  @doc """
  A convenience method that *always* returns an HTML representation of the markdown document passed in.
  In case of the presence of any error messages they are printed to stderr.

  Otherwise it behaves exactly as `as_html`.
  """

  defdelegate from_file!(filename, options \\ []), to: Internal

  @default_timeout_in_ms 5000
  defdelegate pmap(collection, func, timeout \\ @default_timeout_in_ms), to: Internal

  defdelegate transform(ast, options \\ []), to: Transform

  @doc """
    Accesses current hex version of the `Earmark` application. Convenience for
    `iex` usage.
  """
  @spec version :: String.t()
  def version() do
    with {:ok, version} <- :application.get_key(:earmark, :vsn),
         do: to_string(version)
  end

  defp _as_ast(lines, options)

  defp _as_ast(lines, %Options{} = options) do
    Proxy.as_ast(lines, options |> Map.delete(:__struct__) |> Enum.into([]))
  end

  defp _as_ast(lines, options) do
    Proxy.as_ast(lines, options)
  end
end

# SPDX-License-Identifier: Apache-2.0
