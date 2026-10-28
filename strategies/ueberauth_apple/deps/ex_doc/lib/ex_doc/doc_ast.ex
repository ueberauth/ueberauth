defmodule ExDoc.DocAST do
  # General helpers for dealing with the documentation AST
  # (which is the Markdown -> HTML AST).
  @moduledoc false

  @type t :: term()

  alias ExDoc.Markdown

  @doc """
  Parses given `doc_content` according to `doc_format`.
  """
  def parse!(doc_content, doc_format, options \\ [])

  def parse!(markdown, "text/markdown", opts) do
    parse_markdown(markdown, opts)
  end

  def parse!(ast, "application/erlang+html", _options) do
    parse_erl_ast(ast)
  end

  def parse!(_ast, other, _opts) do
    raise "content type #{inspect(other)} is not supported"
  end

  # https://www.w3.org/TR/2011/WD-html-markup-20110113/syntax.html#void-element
  @void_elements ~W(area base br col command embed hr img input keygen link
    meta param source track wbr)a

  @doc """
  Transform AST into HTML string.
  """
  def to_html(binary) do
    IO.iodata_to_binary(to_iodata(binary))
  end

  defp to_iodata(binary) when is_binary(binary) do
    ExDoc.Utils.h(binary)
  end

  defp to_iodata(list) when is_list(list) do
    Enum.map(list, &to_iodata/1)
  end

  defp to_iodata({:comment, _attrs, inner, _meta}) do
    ["<!--", inner, "-->"]
  end

  defp to_iodata({tag, attrs, _inner, _meta}) when tag in @void_elements do
    "<#{tag}#{ast_attributes_to_string(attrs)}/>"
  end

  defp to_iodata({tag, attrs, inner, %{verbatim: true}}) do
    ["<#{tag}#{ast_attributes_to_string(attrs)}>", inner, "</#{tag}>"]
  end

  defp to_iodata({tag, attrs, inner, _meta}) do
    ["<#{tag}#{ast_attributes_to_string(attrs)}>", to_iodata(inner), "</#{tag}>"]
  end

  defp ast_attributes_to_string(attrs) do
    Enum.map(attrs, fn {key, val} -> " #{key}=\"#{ExDoc.Utils.h(val)}\"" end)
  end

  ## parse markdown

  defp parse_markdown(markdown, opts) do
    Markdown.to_ast(markdown, opts)
  end

  ## parse erlang+html

  defp parse_erl_ast(binary) when is_binary(binary) do
    binary
  end

  defp parse_erl_ast(list) when is_list(list) do
    Enum.map(list, &parse_erl_ast/1)
  end

  defp parse_erl_ast({:pre, attrs, content}) do
    case content do
      # if we already have <pre><code>...</code></pre>, carry on
      [{:code, _, _}] ->
        {:pre, attrs, parse_erl_ast(content), %{}}

      # otherwise, turn <pre>...</pre> into <pre><code>...</code></pre>
      _ ->
        content = [{:code, [], parse_erl_ast(content), %{}}]
        {:pre, attrs, content, %{}}
    end
  end

  defp parse_erl_ast({tag, attrs, content}) when is_atom(tag) do
    {tag, attrs, parse_erl_ast(content), %{}}
  end

  @doc """
  Extracts leading title element from the given AST.

  If found, the title element is stripped from the resulting AST.
  """
  def extract_title(ast)

  def extract_title([{:comment, _, _, _} | ast]), do: extract_title(ast)
  def extract_title([{:h1, _attrs, inner, _meta} | ast]), do: {:ok, inner, ast}
  def extract_title(_ast), do: :error

  @doc """
  Extracts the headers which have anchors (aka ids) in them.
  """
  def extract_headers_with_ids(ast, headers) do
    ast
    |> reduce_tags([], fn {tag, attrs, inner, _}, acc ->
      with true <- tag in headers,
           id = Keyword.get(attrs, :id, ""),
           text = ExDoc.DocAST.text(inner),
           true <- id != "" and text != "" do
        [{tag, text, id} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Adds an id attribute to the given headers.

  A prefix for the id attribute can be given,
  which is automatically URL encoded to avoid
  issues.
  """
  def add_ids_to_headers(doc_ast, headers, prefix \\ "") do
    prefix = URI.encode(prefix)

    doc_ast
    |> map_reduce_tags(%{}, fn {tag, attrs, inner, meta} = ast, seen ->
      if tag in headers and not Keyword.has_key?(attrs, :id) do
        possible_id = inner |> text() |> ExDoc.Utils.text_to_id()
        id_count = Map.get(seen, possible_id, 0)
        partial_id = if id_count >= 1, do: "#{possible_id}-#{id_count}", else: possible_id
        seen = Map.put(seen, possible_id, id_count + 1)
        {{tag, [id: prefix <> partial_id] ++ attrs, inner, meta}, seen}
      else
        {ast, seen}
      end
    end)
    |> elem(0)
  end

  @doc """
  Compute a synopsis from a document by looking at its first paragraph.
  """
  def synopsis({:p, _attrs, [_ | _] = inner, meta}) do
    inner =
      case Enum.split(inner, -1) do
        {pre, [post]} when is_binary(post) ->
          pre ++ [String.trim_trailing(post, ":")]

        _ ->
          inner
      end

    to_html({:p, [], remove_ids(inner), meta})
  end

  def synopsis([{:comment, _, _, _} | rest]), do: synopsis(rest)
  def synopsis([head | _]), do: synopsis(head)
  def synopsis(_other), do: ""

  defp remove_ids(ast) do
    map_tags(ast, fn {tag, attrs, inner, meta} ->
      {tag, Keyword.delete(attrs, :id), inner, meta}
    end)
  end

  @doc """
  Returns text content from the given AST.
  """
  def text(ast, joiner \\ "") do
    ast
    |> do_text(joiner)
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp do_text(ast, joiner) when is_list(ast),
    do: Enum.map_intersperse(ast, joiner, &do_text(&1, joiner))

  defp do_text(ast, _joiner) when is_binary(ast),
    do: ast

  defp do_text({_tag, _attr, ast, _meta}, joiner),
    do: do_text(ast, joiner)

  @doc """
  Wraps a list of HTML nodes into `<section>` tags whenever `headers` returns true.
  """
  def sectionize(list, headers), do: sectionize(list, headers, [])

  defp sectionize(list, headers, acc) do
    case pivot(list, acc, headers) do
      {acc, {header_tag, header_attrs, _, _} = header, rest} ->
        {inner, rest} = Enum.split_while(rest, &not_tag?(&1, header_tag))
        class = String.trim_trailing("#{header_tag} #{header_attrs[:class]}")
        section = {:section, [class: class], [header | sectionize(inner, headers, [])], %{}}
        sectionize(rest, headers, [section | acc])

      acc ->
        acc
    end
  end

  defp not_tag?({tag, _, _, _}, tag), do: false
  defp not_tag?(_, _tag), do: true

  defp pivot([{tag, _, _, _} = head | tail], acc, headers) do
    if tag in headers do
      {acc, head, tail}
    else
      pivot(tail, [head | acc], headers)
    end
  end

  defp pivot([head | tail], acc, headers), do: pivot(tail, [head | acc], headers)
  defp pivot([], acc, _headers), do: Enum.reverse(acc)

  @doc """
  Highlights the code blocks in the AST.
  """
  def highlight(ast, language, opts \\ []) do
    highlight_info = language.highlight_info()

    map_tags(ast, fn
      {:pre, pre_attrs, [{:code, code_attrs, [code], code_meta}], pre_meta} = ast
      when is_binary(code) ->
        {lang, code_attrs} = Keyword.pop(code_attrs, :class, "")

        case pick_language_and_lexer(lang, highlight_info, code) do
          {_lang, nil, _lexer_opts} ->
            ast

          {lang, lexer, lexer_opts} ->
            try do
              Makeup.highlight_inner_html(code,
                lexer: lexer,
                lexer_options: lexer_opts,
                formatter_options: opts
              )
            rescue
              exception ->
                ExDoc.warn(
                  [
                    "crashed while highlighting #{lang} snippet:\n\n",
                    ExDoc.DocAST.to_html(ast),
                    "\n\n",
                    Exception.format_banner(:error, exception, __STACKTRACE__)
                  ],
                  __STACKTRACE__
                )

                ast
            else
              highlighted ->
                code_attrs = [class: "makeup #{lang}", translate: "no"] ++ code_attrs
                code_meta = Map.put(code_meta, :verbatim, true)
                {:pre, pre_attrs, [{:code, code_attrs, [highlighted], code_meta}], pre_meta}
            end
        end

      ast ->
        ast
    end)
  end

  defp pick_language_and_lexer("", _highlight_info, "$ " <> _) do
    {"shell", ExDoc.ShellLexer, []}
  end

  defp pick_language_and_lexer("output", highlight_info, _code) do
    {"output", highlight_info.lexer, highlight_info.opts}
  end

  defp pick_language_and_lexer("", highlight_info, _code) do
    {highlight_info.language_name, highlight_info.lexer, highlight_info.opts}
  end

  defp pick_language_and_lexer(lang, _highlight_info, _code) do
    case Makeup.Registry.fetch_lexer_by_name(lang) do
      {:ok, {lexer, opts}} -> {lang, lexer, opts}
      :error -> {lang, nil, []}
    end
  end

  ## Traversal helpers

  @doc """
  Maps the tags in the AST, first mapping children tags, then the tag itself.
  """
  def map_tags({tag, attrs, inner, meta}, fun),
    do: fun.({tag, attrs, Enum.map(inner, &map_tags(&1, fun)), meta})

  def map_tags(list, fun) when is_list(list),
    do: Enum.map(list, &map_tags(&1, fun))

  def map_tags(other, _fun),
    do: other

  @doc """
  Reduces the tags in the AST, first reducing children tags, then the tag itself.
  """
  def reduce_tags({tag, attrs, inner, meta}, acc, fun),
    do: fun.({tag, attrs, inner, meta}, Enum.reduce(inner, acc, &reduce_tags(&1, &2, fun)))

  def reduce_tags(list, acc, fun) when is_list(list),
    do: Enum.reduce(list, acc, &reduce_tags(&1, &2, fun))

  def reduce_tags(_other, acc, _fun),
    do: acc

  @doc """
  Map-reduces the tags in the AST, first mapping children tags, then the tag itself.
  """
  def map_reduce_tags({tag, attrs, inner, meta}, acc, fun) do
    {inner, acc} = Enum.map_reduce(inner, acc, &map_reduce_tags(&1, &2, fun))
    fun.({tag, attrs, inner, meta}, acc)
  end

  def map_reduce_tags(list, acc, fun) when is_list(list),
    do: Enum.map_reduce(list, acc, &map_reduce_tags(&1, &2, fun))

  def map_reduce_tags(other, acc, _fun),
    do: {other, acc}
end
