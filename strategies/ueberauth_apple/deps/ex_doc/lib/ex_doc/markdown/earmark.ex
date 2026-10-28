defmodule ExDoc.Markdown.Earmark do
  @moduledoc """
  ExDoc extension for the EarmarkParser Markdown parser.
  """

  @behaviour ExDoc.Markdown

  @admonition_classes ~w(warning error info tip neutral)

  @impl true
  def available? do
    match?({:ok, _}, Application.ensure_all_started(:earmark_parser)) and
      Code.ensure_loaded?(EarmarkParser)
  end

  @doc """
  Generate HTML AST.

  ## Options

    * `:gfm` - (boolean) turns on Github Flavored Markdown extensions. Defaults to `true`.

    * `:breaks` - (boolean) only applicable if `gfm` is enabled. Makes all line
      breaks significant (so every line in the input is a new line in the output).

  """
  @impl true
  def to_ast(text, opts) do
    options = [
      gfm: true,
      line: 1,
      file: "nofile",
      breaks: false,
      pure_links: true,
      math: true
    ]

    options = Keyword.merge(options, opts)

    case EarmarkParser.as_ast(text, options) do
      {:ok, ast, messages} ->
        print_messages(messages, options)
        fixup(ast)

      {:error, ast, messages} ->
        print_messages(messages, options)
        fixup(ast)
    end
  end

  defp print_messages(messages, options) do
    for {_severity, line, message} <- messages do
      ExDoc.warn(message, file: options[:file], line: line)
    end
  end

  defp fixup(list) when is_list(list) do
    fixup_list(list, [])
  end

  defp fixup(binary) when is_binary(binary) do
    binary
  end

  defp fixup({tag, attrs, ast}) do
    fixup({tag, attrs, ast, %{}})
  end

  # Rewrite math back to the original syntax, it's up to the user to render it

  defp fixup({"code", [{"class", "math-inline"}], [content], _}) do
    "$#{content}$"
  end

  defp fixup({"code", [{"class", "math-display"}], [content], _}) do
    "$$\n#{content}\n$$"
  end

  # Convert admonition blockquotes to sections for screen reader accessibility
  defp fixup(
         {"blockquote", blockquote_attrs, [{tag, h_attrs, h_content, h_meta} | rest] = ast,
          blockquote_meta}
       )
       when tag in ["h3", "h4"] do
    h_admonition =
      with {{"class", classes}, attrs} <- List.keytake(h_attrs, "class", 0),
           class_list <- String.split(classes, " "),
           adm_classes = [_ | _] <- Enum.filter(class_list, &(&1 in @admonition_classes)) do
        {"admonition " <> Enum.join(adm_classes, " "),
         [{"class", "admonition-title #{classes}"} | attrs]}
      else
        _ -> nil
      end

    section_attrs_fn = fn admonition_classes ->
      {classes, attrs} =
        case List.keytake(blockquote_attrs, "class", 0) do
          nil ->
            {admonition_classes, blockquote_attrs}

          {{"class", classes}, attrs} ->
            {"#{admonition_classes} #{classes}", attrs}
        end

      [{"role", "note"}, {"class", classes} | attrs]
    end

    if h_admonition do
      {admonition_classes, h_attrs} = h_admonition
      section_attrs = section_attrs_fn.(admonition_classes)
      h_elem = {tag, h_attrs, h_content, h_meta}

      fixup({"section", section_attrs, [h_elem | rest], blockquote_meta})
    else
      # regular blockquote, copied fixup/1 here to avoid infinite loop
      {:blockquote, Enum.map(blockquote_attrs, &fixup_attr/1), fixup(ast), blockquote_meta}
    end
  end

  defp fixup({tag, attrs, ast, meta}) when is_binary(tag) and is_list(attrs) and is_map(meta) do
    {fixup_tag(tag), Enum.map(attrs, &fixup_attr/1), fixup(ast), meta}
  end

  defp fixup({:comment, _, _, _} = comment) do
    comment
  end

  # We are matching on Livebook outputs here, because we prune comments at this point
  defp fixup_list(
         [
           {:comment, _, [~s/ livebook:{"output":true} /], %{comment: true}},
           {"pre", pre_attrs, [{"code", code_attrs, [source], code_meta}], pre_meta}
           | ast
         ],
         acc
       ) do
    code_attrs =
      case Enum.split_with(code_attrs, &match?({"class", _}, &1)) do
        {[], attrs} -> [{"class", "output"} | attrs]
        {[{"class", class}], attrs} -> [{"class", "#{class} output"} | attrs]
      end

    code_node = {"code", code_attrs, [source], code_meta}
    fixup_list([{"pre", pre_attrs, [code_node], pre_meta} | ast], acc)
  end

  defp fixup_list([head | tail], acc) do
    fixed = fixup(head)

    if fixed == [] do
      fixup_list(tail, acc)
    else
      fixup_list(tail, [fixed | acc])
    end
  end

  defp fixup_list([], acc) do
    Enum.reverse(acc)
  end

  defp fixup_tag(tag) do
    String.to_atom(tag)
  end

  defp fixup_attr({name, value}) do
    {String.to_atom(name), value}
  end
end
