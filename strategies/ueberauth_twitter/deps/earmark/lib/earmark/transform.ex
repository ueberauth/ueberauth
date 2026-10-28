defmodule Earmark.Transform do
  import Earmark.Helpers, only: [replace: 3]

  alias Earmark.Options
  alias Earmark.TagSpecificProcessors, as: TSP
  alias Earmark.EarmarkParserProxy, as: Proxy
  alias __MODULE__.Pop

  @type node_or_string() :: Earmark.ast_node() | String.t()

  @compact_tags ~w[a code em strong del]
  # https://www.w3.org/TR/2011/WD-html-markup-20110113/syntax.html#void-element
  @void_elements ~W(area base br col command embed hr img input keygen link meta param source track wbr)

  @moduledoc ~S"""
  #### Structure Conserving Transformers

  For the convenience of processing the output of `Earmark.Parser.as_ast` we expose two structure conserving
  mappers.

  ##### `map_ast`

  Traverses an AST using a mapper function.

  The mapper function will be called for each node including text elements unless `map_ast` is called with
  the third positional parameter `ignore_strings`, which is optional and defaults to `false`, set to `true`.

  Depending on the return value of the mapper function the traversal will either

  - `{new_tag, new_atts, ignored, new_meta}`

    just replace the `tag`, `attribute` and `meta` values of the current node with the values of the returned
    quadruple (ignoring `ignored` for facilitating nodes w/o transformation)
    and then descend into the **original** content of the node.


  - `{:replace, node}`

    replaces the current node with `node` and does not descend anymore, but continues traversal on sibblings.


  - {new_function, {new_tag, new_atts, ignored, new_meta}}

    just replace the `tag`, `attribute` and `meta` values of the current node with the values of the returned
    quadruple (ignoring `ignored` for facilitating nodes w/o transformation)
    and then descend into the **original** content of the node but with the mapper function `new_function`
    used for transformation of the AST.

    **N.B.** The original mapper function will be used for transforming the sibbling nodes though.

  takes a function that will be called for each node of the AST, where a leaf node is either a quadruple
  like `{"code", [{"class", "inline"}], ["some code"], %{}}` or a text leaf like `"some code"`

  The result of the function call must be

  - for nodes → as described above

  - for strings → strings or nodes

  As an example let us transform an ast to have symbol keys

        iex(1)> input = [
        ...(1)> {"h1", [], ["Hello"], %{title: true}},
        ...(1)> {"ul", [], [{"li", [], ["alpha"], %{}}, {"li", [], ["beta"], %{}}], %{}}]
        ...(1)> map_ast(input, fn {t, a, _, m} -> {String.to_atom(t), a, nil, m} end, true)
        [ {:h1, [], ["Hello"], %{title: true}},
          {:ul, [], [{:li, [], ["alpha"], %{}}, {:li, [], ["beta"], %{}}], %{}} ]

  **N.B.** If this returning convention is not respected `map_ast` might not complain, but the resulting
  transformation might not be suitable for `Earmark.Transform.transform` anymore. From this follows that
  any function passed in as value of the `postprocessor:` option must obey to these conventions.

  ##### `map_ast_with`

  this is like `map_ast` but like a reducer an accumulator can also be passed through.

  For that reason the function is called with two arguments, the first element being the same value
  as in `map_ast` and the second the accumulator. The return values need to be equally augmented
  tuples.

  A simple example, annotating traversal order in the meta map's `:count` key, as we are not
  interested in text nodes we use the fourth parameter `ignore_strings` which defaults to `false`

         iex(2)>  input = [
         ...(2)>  {"ul", [], [{"li", [], ["one"], %{}}, {"li", [], ["two"], %{}}], %{}},
         ...(2)>  {"p", [], ["hello"], %{}}]
         ...(2)>  counter = fn {t, a, _, m}, c -> {{t, a, nil, Map.put(m, :count, c)}, c+1} end
         ...(2)>  map_ast_with(input, 0, counter, true)
         {[ {"ul", [], [{"li", [], ["one"], %{count: 1}}, {"li", [], ["two"], %{count: 2}}], %{count: 0}},
           {"p", [], ["hello"], %{count: 3}}], 4}

  Let us describe an implementation of a real world use case taken from [Elixir Forum](https://elixirforum.com/t/how-to-extend-earmark/47406)

  Simplifying the exact parsing of the text node in this example we only want to replace a text node of the form `#elixir` with
  a link to the Elixir home page _but_ only when inside a `{"p",....}` node

  We can achieve this as follows

        iex(3)> elixir_home = {"a", [{"href", "https://elixir-lang.org"}], ["Elixir"], %{}}
        ...(3)> transformer = fn {"p", atts, _, meta}, _ -> {{"p", atts, nil, meta}, true}
        ...(3)>                  "#elixir", true -> {elixir_home, false}
        ...(3)>                  text, _ when is_binary(text) -> {text, false}
        ...(3)>                  node, _ ->  {node, false} end
        ...(3)> ast = [
        ...(3)>  {"p", [],[ "#elixir"], %{}}, {"bold", [],[ "#elixir"], %{}},
        ...(3)>  {"ol", [], [{"li", [],[ "#elixir"], %{}}, {"p", [],[ "elixir"], %{}}, {"p", [], ["#elixir"], %{}}], %{}}
        ...(3)> ]
        ...(3)> map_ast_with(ast, false, transformer)
        {[
         {"p", [],[{"a", [{"href", "https://elixir-lang.org"}], ["Elixir"], %{}}], %{}}, {"bold", [],[ "#elixir"], %{}},
         {"ol", [], [{"li", [],[ "#elixir"], %{}}, {"p", [],[ "elixir"], %{}}, {"p", [], [{"a", [{"href", "https://elixir-lang.org"}], ["Elixir"], %{}}], %{}}], %{}}
        ], false}

  An alternate, maybe more elegant solution would be to change the mapper function during AST traversal
  as demonstrated [here](https://github.com/pragdave/earmark/blob/master/test/acceptance/transform/map_ast_with_fnchange_test.exs)

  #### Postprocessors and Convenience Functions

  These can be declared in the fields `postprocessor` and `registered_processors` in the `Options` struct,
  `postprocessor` is prepened to `registered_processors` and they are all applied to non string nodes (that
  is the quadtuples of the AST which are of the form `{tag, atts, content, meta}`

  All postprocessors can just be functions on nodes or a `TagSpecificProcessors` struct which will group
  function applications depending on tags, as a convienience tuples of the form `{tag, function}` will be
  transformed into a `TagSpecificProcessors` struct.

      iex(4)> add_class1 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class1")
      ...(4)> m1 = Earmark.Options.make_options!(postprocessor: add_class1) |> make_postprocessor()
      ...(4)> m1.({"a", [], nil, nil})
      {"a", [{"class", "class1"}], nil, nil}

  We can also use the `registered_processors` field:

      iex(5)> add_class1 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class1")
      ...(5)> m2 = Earmark.Options.make_options!(registered_processors: add_class1) |> make_postprocessor()
      ...(5)> m2.({"a", [], nil, nil})
      {"a", [{"class", "class1"}], nil, nil}

  Knowing that values on the same attributes are added onto the front the following doctest demonstrates
  the order in which the processors are executed

      iex(6)> add_class1 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class1")
      ...(6)> add_class2 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class2")
      ...(6)> add_class3 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class3")
      ...(6)> m = Earmark.Options.make_options!(postprocessor: add_class1, registered_processors: [add_class2, {"a", add_class3}])
      ...(6)> |> make_postprocessor()
      ...(6)> [{"a", [{"class", "link"}], nil, nil}, {"b", [], nil, nil}]
      ...(6)> |> Enum.map(m)
      [{"a", [{"class", "class3 class2 class1 link"}], nil, nil}, {"b", [{"class", "class2 class1"}], nil, nil}]

  We can see that the tuple form has been transformed into a tag specific transformation **only** as a matter of fact, the explicit definition would be:

      iex(7)> m = make_postprocessor(
      ...(7)>   %Earmark.Options{
      ...(7)>     registered_processors:
      ...(7)>       [Earmark.TagSpecificProcessors.new({"a", &Earmark.AstTools.merge_atts_in_node(&1, target: "_blank")})]})
      ...(7)> [{"a", [{"href", "url"}], nil, nil}, {"b", [], nil, nil}]
      ...(7)> |> Enum.map(m)
      [{"a", [{"href", "url"}, {"target", "_blank"}], nil, nil}, {"b", [], nil, nil}]

  We can also define a tag specific transformer in one step, which might (or might not) solve potential performance issues
  when running too many processors

      iex(8)> add_class4 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class4")
      ...(8)> add_class5 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class5")
      ...(8)> add_class6 = &Earmark.AstTools.merge_atts_in_node(&1, class: "class6")
      ...(8)> tsp = Earmark.TagSpecificProcessors.new([{"a", add_class5}, {"b", add_class5}])
      ...(8)> m = Earmark.Options.make_options!(
      ...(8)>       postprocessor: add_class4,
      ...(8)>       registered_processors: [tsp, add_class6])
      ...(8)> |> make_postprocessor()
      ...(8)> [{"a", [], nil, nil}, {"c", [], nil, nil}, {"b", [], nil, nil}]
      ...(8)> |> Enum.map(m)
      [{"a", [{"class", "class6 class5 class4"}], nil, nil}, {"c", [{"class", "class6 class4"}], nil, nil}, {"b", [{"class", "class6 class5 class4"}], nil, nil}]

  Of course the mechanics shown above is hidden if all we want is to trigger the postprocessor chain in `Earmark.as_html`, here goes a typical
  example

      iex(9)> add_target = fn node -> # This will only be applied to nodes as it will become a TagSpecificProcessors
      ...(9)>   if Regex.match?(~r{\.x\.com\z}, Earmark.AstTools.find_att_in_node(node, "href", "")), do:
      ...(9)>     Earmark.AstTools.merge_atts_in_node(node, target: "_blank"), else: node end
      ...(9)> options = [
      ...(9)> registered_processors: [{"a", add_target}, {"p", &Earmark.AstTools.merge_atts_in_node(&1, class: "example")}]]
      ...(9)> markdown = [
      ...(9)>   "http://hello.x.com",
      ...(9)>   "",
      ...(9)>   "[some](url)",
      ...(9)>  ]
      ...(9)> Earmark.as_html!(markdown, options)
      "<p class=\"example\">\n<a href=\"http://hello.x.com\" target=\"_blank\">http://hello.x.com</a></p>\n<p class=\"example\">\n<a href=\"url\">some</a></p>\n"

  ##### Use case: Modification of Link Attributes depending on the URL

  This would be done as follows

  ```elixir
          Earmark.as_html!(markdown, registered_processors: {"a", my_function_that_is_invoked_only_with_a_nodes})
  ```

  ##### Use case: Modification of the AST according to Annotations

  **N.B.** Annotation are an _experimental_ feature in 1.4.16-pre and are documented [here](https://github.com/RobertDober/earmark_parser/#annotations)

  By annotating our markdown source we can then influence the rendering. In this example we will just
  add some decoration

      iex(10)> markdown = [ "A joke %% smile", "", "Charming %% in_love" ]
      ...(10)> add_smiley = fn {_, _, _, meta} = quad, _acc ->
      ...(10)>                case Map.get(meta, :annotation) do
      ...(10)>                  "%% smile"   -> {quad, "\u1F601"}
      ...(10)>                  "%% in_love" -> {quad, "\u1F60d"}
      ...(10)>                  _            -> {quad, nil}
      ...(10)>                end
      ...(10)>                text, nil -> {text, nil}
      ...(10)>                text, ann -> {"#{text} #{ann}", nil}
      ...(10)>              end
      ...(10)> Earmark.as_ast!(markdown, annotations: "%%") |> Earmark.Transform.map_ast_with(nil, add_smiley) |> Earmark.transform
      "<p>\nA joke  ὠ1</p>\n<p>\nCharming  ὠd</p>\n"

  #### Structure Modifying Transformers

  For structure modifications a tree traversal is needed and no clear pattern of how to assist this task with
  tools has emerged yet.


  """
  @spec make_postprocessor(Options.options()) :: (node_or_string() -> node_or_string())
  def make_postprocessor(options)

  def make_postprocessor(%{postprocessor: nil, registered_processors: rps}),
    do: _make_postprocessor(rps)

  def make_postprocessor(%{postprocessor: pp, registered_processors: rps}),
    do: _make_postprocessor([pp | rps])

  @doc false
  @spec postprocessed_ast([String.t()] | String.t(), Options.options()) ::
          {:ok, Earmark.ast_node(), [Earmark.Error.t()]}
          | {:error, Earmark.ast_node(), [Earmark.Error.t()]}
  def postprocessed_ast(lines, options)

  def postprocessed_ast(lines, options) when is_binary(lines) do
    line_end_rgx = ~r{\n\r?}

    lines |> String.split(line_end_rgx) |> postprocessed_ast(options)
  end

  # This is an optimisation (buuuuuh) but we want a minimal impact of postprocessing code when it is not required
  # It is also a case of the mantra "Handle the simple case first" (yeeeeah)
  def postprocessed_ast(lines, %Options{registered_processors: [], postprocessor: nil} = options),
    do: Proxy.as_ast(lines, options)

  def postprocessed_ast(lines, %Options{} = options) do
    {status, ast, messages} = Proxy.as_ast(lines, options)
    prep = make_postprocessor(options)
    ast1 = map_ast(ast, prep, Map.get(options, :ignore_strings))
    {status, ast1, messages}
  end

  def postprocessed_ast(lines, options),
    do: postprocessed_ast(lines, Options.make_options!(options))

  @doc """
  Transforms an AST to html, also accepts the result of `map_ast_with` for convenience
  """
  @spec transform(Earmark.ast_node(), Options.options()) :: String.t()
  def transform(ast, options \\ %{initial_indent: 0, indent: 2, compact_output: false})
  def transform({ast, _}, options), do: transform(ast, options)

  def transform(ast, options) when is_list(options) do
    transform(ast, options |> Enum.into(%{initial_indent: 0, indent: 2, compact_output: false}))
  end

  def transform(ast, options) when is_map(options) do
    options1 =
      options
      |> Map.put_new(:indent, 2)
      |> Map.put_new(:compact_output, false)

    ast
    # |> IO.inspect
    |> _maybe_remove_paras(options1)
    |> to_html(options1)
  end

  @doc ~S"""
  This is a structure conserving transformation

      iex(11)> {:ok, ast, _} = Earmark.Parser.as_ast("- one\n- two\n")
      ...(11)> map_ast(ast, &(&1))
      [{"ul", [], [{"li", [], ["one"], %{}}, {"li", [], ["two"], %{}}], %{}}]

  A more useful transformation
      iex(12)> {:ok, ast, _} = Earmark.Parser.as_ast("- one\n- two\n")
      ...(12)> fun = fn {_, _, _, _}=n -> Earmark.AstTools.merge_atts_in_node(n, class: "private")
      ...(12)>           string      -> string end
      ...(12)> map_ast(ast, fun)
      [{"ul", [{"class", "private"}], [{"li", [{"class", "private"}], ["one"], %{}}, {"li", [{"class", "private"}], ["two"], %{}}], %{}}]

  However the usage of the `ignore_strings` option renders the code much simpler

      iex(13)> {:ok, ast, _} = Earmark.Parser.as_ast("- one\n- two\n")
      ...(13)> map_ast(ast, &Earmark.AstTools.merge_atts_in_node(&1, class: "private"), true)
      [{"ul", [{"class", "private"}], [{"li", [{"class", "private"}], ["one"], %{}}, {"li", [{"class", "private"}], ["two"], %{}}], %{}}]
  """
  @spec map_ast(Earmark.ast_node(), (Earmark.ast_node() -> Earmark.ast_node()), boolean()) ::
          Earmark.ast_node()
  def map_ast(ast, fun, ignore_strings \\ false) do
    _walk_ast(ast, fun, ignore_strings, [])
  end

  @doc ~S"""
  This too is a structure perserving transformation but a value is passed to the mapping function as an accumulator, and the mapping
  function needs to return the new node and the accumulator as a tuple, here is a simple example

      iex(14)> {:ok, ast, _} = Earmark.Parser.as_ast("- 1\n\n2\n- 3\n")
      ...(14)> summer = fn {"li", _, [v], _}=n, s -> {v_, _} = Integer.parse(v); {n, s + v_}
      ...(14)>             n, s -> {n, s} end
      ...(14)> map_ast_with(ast, 0, summer, true)
      {[{"ul", [], [{"li", [], ["1"], %{}}], %{}}, {"p", [], ["2"], %{}}, {"ul", [], [{"li", [], ["3"], %{}}], %{}}], 4}

  or summing all numbers

      iex(15)> {:ok, ast, _} = Earmark.Parser.as_ast("- 1\n\n2\n- 3\n")
      ...(15)> summer = fn {_, _, _, _}=n, s -> {n, s}
      ...(15)>             n, s -> {n_, _} = Integer.parse(n); {"*", s+n_} end
      ...(15)> map_ast_with(ast, 0, summer)
      {[{"ul", [], [{"li", [], ["*"], %{}}], %{}}, {"p", [], ["*"], %{}}, {"ul", [], [{"li", [], ["*"], %{}}], %{}}], 6}

  """
  @spec map_ast_with(
          Earmark.ast(),
          any(),
          (Earmark.ast_node(), any() -> {Earmark.ast_node(), any()}),
          boolean()
        ) ::
          {Earmark.ast(), any()}
  def map_ast_with(ast, value, fun, ignore_strings \\ false) do
    _walk_ast_with(ast, value, fun, ignore_strings, [])
  end

  defp _make_postprocessor(processors) do
    processors_ =
      processors
      |> Enum.map(fn
        %TSP{} = tsp -> TSP.make_postprocessor(tsp)
        just_a_fun -> just_a_fun
      end)

    fn node ->
      processors_
      |> Enum.reduce(node, fn processor, node -> processor.(node) end)
    end
  end

  defp _maybe_add_newline1(options)
  defp _maybe_add_newline1(%Options{compact_output: true}), do: []
  defp _maybe_add_newline1(_), do: ?\n

  defp _maybe_compact(element, options)
  defp _maybe_compact(element, %{compact_output: false}), do: element

  defp _maybe_compact(element, _options) do
    crlf_rgx = ~r{(?:\n\r?)+}
    String.replace(element, crlf_rgx, " ")
  end

  defp to_html(ast, options) do
    _to_html(ast, options, Map.get(options, :initial_indent, 0)) |> IO.iodata_to_binary()
  end

  defp _to_html(ast, options, level, verbatim \\ false)

  defp _to_html({:comment, _, content, _}, options, _level, _verbatim) do
    ["<!--", Enum.intersperse(content, ?\n), "-->", _maybe_add_newline1(options)]
  end

  defp _to_html({"code", atts, children, meta}, options, level, _verbatim) do
    verbatim = meta |> Map.get(:verbatim, false)

    [
      _open_tag1("code", atts),
      _to_html(children, Map.put(options, :smartypants, false), level, verbatim),
      "</code>"
    ]
  end

  defp _to_html({tag, atts, children, _}, options, level, verbatim) when tag in @compact_tags do
    [
      _open_tag1(tag, atts),
      children
      |> Enum.map(&_to_html(&1, options, level, verbatim)),
      "</",
      tag,
      ?>
    ]
  end

  defp _to_html({tag, atts, _, _}, options, level, _verbatim) when tag in @void_elements do
    [make_indent(options, level), _open_tag1(tag, atts), _maybe_add_newline1(options)]
  end

  defp _to_html(elements, options, level, verbatim) when is_list(elements) do
    elements
    |> Enum.map(&_to_html(&1, options, level, verbatim))
  end

  defp _to_html(element, options, _level, false) when is_binary(element) do
    element
    |> _maybe_compact(options)
    |> escape(options)
  end

  defp _to_html(element, options, level, true) when is_binary(element) do
    [make_indent(options, level), element]
  end

  defp _to_html({"pre", atts, children, meta}, options, level, _verbatim) do
    verbatim = meta |> Map.get(:verbatim, false)

    [
      make_indent(options, level),
      _open_tag1("pre", atts),
      _to_html(
        children,
        Map.merge(options, %{smartypants: false, compact_output: false}),
        level,
        verbatim
      ),
      "</pre>",
      _maybe_add_newline1(options)
    ]
  end

  defp _to_html({tag, atts, children, meta}, options, level, _verbatim) do
    verbatim = meta |> Map.get(:verbatim, false)

    [
      make_indent(options, level),
      _open_tag1(tag, atts),
      _maybe_add_newline1(options),
      _to_html(children, options, level + 1, verbatim),
      _close_tag1(tag, options, level)
    ]
  end

  defp _add_trailing_nl(node)
  defp _add_trailing_nl(text) when is_binary(text), do: [text, "\n"]
  defp _add_trailing_nl(node), do: node

  defp _close_tag1(tag, options, level) do
    [make_indent(options, level), "</", tag, ?>, _maybe_add_newline1(options)]
  end

  defp escape(element, options)

  defp escape("", _opions) do
    []
  end

  defp escape(element, %{smartypants: true} = options) do
    # Unfortunately these regexes still have to be left.
    # It doesn't seem possible to make _escape_to_iodata1
    # transform, for example, "--'" to "–‘" without
    # significantly complicating the code to the point
    # it outweights the performance benefit.
    element =
      element
      |> replace(~r{(^|[-–—/\(\[\{"”“\s])'}, "\\1‘")
      |> replace(~r{(^|[-–—/\(\[\{‘\s])\"}, "\\1“")

    escape = Map.get(options, :escape, true)
    _escape_to_iodata1(element, 0, element, [], true, escape, 0)
  end

  defp escape(element, %{escape: escape}) do
    _escape_to_iodata1(element, 0, element, [], false, escape, 0)
  end

  defp escape(element, _options) do
    _escape_to_iodata1(element, 0, element, [], false, true, 0)
  end

  defp _make_att1(name_value_pair, tag)

  defp _make_att1({name, value}, _) do
    [" ", name, "=\"", value, "\""]
  end

  defp make_indent(options, level)

  defp make_indent(%Options{compact_output: true}, _level) do
    ""
  end

  defp make_indent(%{indent: indent}, level) do
    Stream.cycle([" "])
    |> Enum.take(level * indent)
  end

  # Optimized HTML escaping + smartypants, insipred by Plug.HTML
  # https://github.com/elixir-plug/plug/blob/v1.11.0/lib/plug/html.ex

  # Do not escape HTML entities
  defp _escape_to_iodata1("&#x" <> rest, skip, original, acc, smartypants, escape, len) do
    _escape_to_iodata1(rest, skip, original, acc, smartypants, escape, len + 3)
  end

  escapes = [
    {?<, "&lt;"},
    {?>, "&gt;"},
    {?&, "&amp;"},
    {?", "&quot;"},
    {?', "&#39;"}
  ]

  # Can't use character codes for multibyte unicode characters
  smartypants_escapes = [
    {"---", "—"},
    {"--", "–"},
    {?', "’"},
    {?", "”"},
    {"...", "…"}
  ]

  # These match only if `smartypants` is true
  for {match, insert} <- smartypants_escapes do
    # Unlike HTML escape matches, smartypants matches may contain more than one character
    match_length = if is_binary(match), do: byte_size(match), else: 1

    defp _escape_to_iodata1(<<unquote(match), rest::bits>>, skip, original, acc, true, escape, 0) do
      _escape_to_iodata1(
        rest,
        skip + unquote(match_length),
        original,
        [acc | unquote(insert)],
        true,
        escape,
        0
      )
    end

    defp _escape_to_iodata1(
           <<unquote(match), rest::bits>>,
           skip,
           original,
           acc,
           true,
           escape,
           len
         ) do
      part = binary_part(original, skip, len)

      _escape_to_iodata1(
        rest,
        skip + len + unquote(match_length),
        original,
        [acc, part | unquote(insert)],
        true,
        escape,
        0
      )
    end
  end

  for {match, insert} <- escapes do
    defp _escape_to_iodata1(
           <<unquote(match), rest::bits>>,
           skip,
           original,
           acc,
           smartypants,
           true,
           0
         ) do
      _escape_to_iodata1(rest, skip + 1, original, [acc | unquote(insert)], smartypants, true, 0)
    end

    defp _escape_to_iodata1(
           <<unquote(match), rest::bits>>,
           skip,
           original,
           acc,
           smartypants,
           true,
           len
         ) do
      part = binary_part(original, skip, len)

      _escape_to_iodata1(
        rest,
        skip + len + 1,
        original,
        [acc, part | unquote(insert)],
        smartypants,
        true,
        0
      )
    end
  end

  defp _escape_to_iodata1(<<_char, rest::bits>>, skip, original, acc, smartypants, escape, len) do
    _escape_to_iodata1(rest, skip, original, acc, smartypants, escape, len + 1)
  end

  defp _escape_to_iodata1(<<>>, 0, original, _acc, _smartypants, _escape, _len) do
    original
  end

  defp _escape_to_iodata1(<<>>, skip, original, acc, _smartypants, _escape, len) do
    [acc | binary_part(original, skip, len)]
  end

  defp _maybe_remove_paras(ast, options)

  defp _maybe_remove_paras(ast, %Options{inner_html: true}) do
    Enum.map(ast, &_remove_para/1)
  end

  defp _maybe_remove_paras(ast, _), do: ast

  defp _open_tag1(tag, atts)

  defp _open_tag1(tag, atts) when tag in @void_elements do
    [?<, tag, Enum.map(atts, &_make_att1(&1, tag)), ">"]
  end

  defp _open_tag1(tag, atts) do
    [?<, tag, Enum.map(atts, &_make_att1(&1, tag)), ?>]
  end

  defp _pop_to_pop(result, intermediate \\ [])

  defp _pop_to_pop([%Pop{fun: fun}, {tag, atts, _, meta} | rest], intermediate) do
    {[{tag, atts, intermediate, meta} | rest], fun}
  end

  defp _pop_to_pop([continue | rest], intermediate) do
    _pop_to_pop(rest, [continue | intermediate])
  end

  defp _remove_para(ele_or_string)
  defp _remove_para({"p", _, content, _}), do: content |> Enum.map(&_add_trailing_nl/1)
  defp _remove_para(whatever), do: whatever

  defp _walk_ast(ast, fun, ignore_strings, result)
  defp _walk_ast([], _fun, _ignore_strings, result), do: Enum.reverse(result)

  defp _walk_ast([[] | rest], _fun, ignore_strings, result) do
    {popped_result, fun} = _pop_to_pop(result)
    _walk_ast(rest, fun, ignore_strings, popped_result)
  end

  defp _walk_ast([string | rest], fun, ignore_strings, result) when is_binary(string) do
    new = if ignore_strings, do: string, else: fun.(string)
    _walk_ast(rest, fun, ignore_strings, [new | result])
  end

  defp _walk_ast([{_, _, content, _} = tuple | rest], fun, ignore_strings, result) do
    case fun.(tuple) do
      {new_fun, {new_tag, new_atts, _, new_meta}} when is_function(new_fun) ->
        _walk_ast([content | rest], new_fun, ignore_strings, [
          %Pop{fun: fun},
          {new_tag, new_atts, [], new_meta} | result
        ])

      {new_tag, new_atts, _, new_meta} ->
        _walk_ast([content | rest], fun, ignore_strings, [
          %Pop{fun: fun},
          {new_tag, new_atts, [], new_meta} | result
        ])

      {:replace, content} ->
        _walk_ast(rest, fun, ignore_strings, [content | result])
    end
  end

  defp _walk_ast([[h | t] | rest], fun, ignore_strings, result) do
    _walk_ast([h, t | rest], fun, ignore_strings, result)
  end

  defp _walk_ast_with(ast, value, fun, ignore_strings, result)
  defp _walk_ast_with([], value, _fun, _ignore_strings, result), do: {Enum.reverse(result), value}

  defp _walk_ast_with([[] | rest], value, _fun, ignore_strings, result) do
    {popped_result, fun} = _pop_to_pop(result)
    _walk_ast_with(rest, value, fun, ignore_strings, popped_result)
  end

  defp _walk_ast_with([string | rest], value, fun, ignore_strings, result)
       when is_binary(string) do
    if ignore_strings do
      _walk_ast_with(rest, value, fun, ignore_strings, [string | result])
    else
      {news, newv} = fun.(string, value)
      _walk_ast_with(rest, newv, fun, ignore_strings, [news | result])
    end
  end

  defp _walk_ast_with([{_, _, content, _} = tuple | rest], value, fun, ignore_strings, result) do
    {{new_tag, new_atts, _, new_meta}, new_value} = fun.(tuple, value)

    _walk_ast_with([content | rest], new_value, fun, ignore_strings, [
      %Pop{fun: fun},
      {new_tag, new_atts, [], new_meta} | result
    ])
  end

  defp _walk_ast_with([[h | t] | rest], value, fun, ignore_strings, result) do
    _walk_ast_with([h, t | rest], value, fun, ignore_strings, result)
  end
end

#  SPDX-License-Identifier: Apache-2.0
