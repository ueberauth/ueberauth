defmodule ExDoc.Formatter.HTML.SearchData do
  @moduledoc false

  def create(nodes, extras, proglang) do
    items = Enum.flat_map(nodes, &module/1) ++ Enum.flat_map(extras, &extra/1)

    data = %{
      items: items,
      content_type: "text/markdown",
      proglang: proglang,
      producer: %{
        name: "ex_doc",
        version: to_string(Application.spec(:ex_doc)[:vsn])
      }
    }

    ["searchData=" | ExDoc.Utils.to_json(data)]
  end

  defp extra(%ExDoc.URLNode{}), do: []

  defp extra(%ExDoc.ExtraNode{search_data: search_data} = map) when is_list(search_data) do
    Enum.map(search_data, fn item ->
      link =
        if item.anchor === "" do
          "#{URI.encode(map.id)}.html"
        else
          "#{URI.encode(map.id)}.html##{URI.encode(item.anchor)}"
        end

      encode(link, item.title <> " - #{map.id}", item.type, clean_markdown(item.body))
    end)
  end

  defp extra(%ExDoc.ExtraNode{} = map) do
    page = URI.encode(map.id) <> ".html"
    {intro, sections} = extract_sections_from_markdown(map.source_doc, "")

    intro = encode(page, map.title, :extras, intro)
    [intro | render_sections(sections, page, map.title, :extras)]
  end

  defp module(%ExDoc.ModuleNode{} = node) do
    page = URI.encode(node.id) <> ".html"
    {intro, sections} = extract_sections(node.source_format, node, "module-")
    module = encode(page, node.title, node.type, intro)

    docs =
      node.docs_groups
      |> Enum.flat_map(& &1.docs)
      |> Enum.flat_map(&node_child(&1, node, page))

    [module] ++ render_sections(sections, page, node.title, node.type) ++ docs
  end

  defp node_child(node, module_node, page) do
    title = "#{module_node.id}.#{node.name}/#{node.arity}"
    {intro, sections} = extract_sections(module_node.source_format, node, node.id <> "-")

    child = encode("#{page}##{URI.encode(node.id)}", title, node.type, intro)
    [child | render_sections(sections, page, title, node.type)]
  end

  defp encode(ref, title, type, doc) do
    %{ref: ref, title: title, type: type, doc: doc}
  end

  defp extract_sections("text/markdown", %{source_doc: %{"en" => doc}}, prefix) do
    extract_sections_from_markdown(doc, prefix)
  end

  defp extract_sections(_format, %{doc: nil}, _prefix) do
    {"", []}
  end

  defp extract_sections(_format, %{doc: doc}, _prefix) do
    {ExDoc.DocAST.text(doc, " "), []}
  end

  defp extract_sections_from_markdown(string, prefix) do
    [intro | headers_sections] =
      Regex.split(~r/(?<!#)###? (?<header>\b.+)/, string, include_captures: true)

    sections =
      headers_sections
      |> Enum.chunk_every(2)
      |> Enum.map(fn [header, section] ->
        # Hardcoded markdown processor because we use it only for header matching
        opts = [markdown_processor: ExDoc.Markdown.Earmark]
        [{tag, attrs, content, meta}] = ExDoc.Markdown.to_ast(header, opts)
        {tag, [section: section] ++ attrs, content, meta}
      end)
      |> ExDoc.DocAST.add_ids_to_headers([:h2, :h3], prefix)
      |> Enum.map(fn {_, attrs, inner, _} ->
        id = Keyword.fetch!(attrs, :id)
        section = Keyword.fetch!(attrs, :section)
        {ExDoc.DocAST.text(inner), id, clean_markdown(section)}
      end)

    {clean_markdown(intro), sections}
  end

  defp clean_markdown(text) do
    text
    |> ExDoc.Utils.strip_tags(" ")
    |> drop_ignorable_codeblocks()
    |> String.trim()
  end

  defp render_sections(sections, page, title, type) do
    for {header, anchor, body} <- sections do
      encode("#{page}##{anchor}", header <> " - " <> title, type, body)
    end
  end

  @ignored_codeblocks ~w[vega-lite]

  defp drop_ignorable_codeblocks(section) do
    block_names = Enum.join(@ignored_codeblocks, "|")
    String.replace(section, ~r/^```(?:#{block_names})\n(?:[\s\S]*?)```$/m, "")
  end
end
