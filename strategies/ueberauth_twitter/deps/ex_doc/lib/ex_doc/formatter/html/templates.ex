defmodule ExDoc.Formatter.HTML.Templates do
  @moduledoc false
  require EEx
  alias ExDoc.Formatter.HTML.Assets

  import ExDoc.Utils, only: [h: 1, text_to_id: 1]

  defp enc(binary), do: ExDoc.Utils.h(URI.encode(binary))

  @doc """
  Get the pretty name of a function node
  """
  def pretty_type(%{type: t}) do
    Atom.to_string(t)
  end

  @doc """
  Returns the title with `<wbr />` after each fullstop, allowing word breaks in long module names.
  """
  def breakable_module_title(title) when is_binary(title) do
    String.replace(title, ".", ".<wbr />")
  end

  @doc """
  Returns the HTML formatted title for the module page.
  """
  def module_type(%{type: :task}), do: ""
  def module_type(%{type: :module}), do: ""
  def module_type(%{type: type}), do: "<small>#{type}</small>"

  @doc """
  Renders a "Copy Markdown" link if markdown formatter is enabled.
  """
  def copy_markdown_link(config, path) do
    if "markdown" in config.formatters do
      """
      <a href="#{enc(path)}" title="Copy Markdown (hold Ctrl/Cmd and click it to open as Markdown)" class="copy-markdown icon-action" rel="help">
        <i class="ri-markdown-line" aria-hidden="true"></i>
        <span class="sr-only">Copy Markdown</span>
      </a>
      """
    else
      ""
    end
  end

  @doc """
  Create a JS object which holds all the items displayed in the sidebar area
  """
  def create_sidebar_items(config, modules, tasks, extras) do
    nodes =
      [modules: modules, tasks: tasks]
      |> Enum.map(&sidebar_module/1)
      |> Map.new()
      |> Map.put(:extras, api_reference(config, modules, tasks) ++ sidebar_extras(extras))

    ["sidebarNodes=" | ExDoc.Utils.to_json(nodes)]
  end

  defp api_reference(%{api_reference: false}, _modules, _tasks), do: []

  defp api_reference(_config, modules, tasks) do
    headers =
      if(modules != [], do: [%{id: "Modules", anchor: "modules"}], else: []) ++
        if(tasks != [], do: [%{id: "Mix Tasks", anchor: "tasks"}], else: [])

    [%{id: "api-reference", title: "API Reference", group: "", headers: headers}]
  end

  defp sidebar_extras(extras) do
    for extra <- extras do
      %{id: id, title: title, group: group} = extra
      item = %{id: to_string(id), title: to_string(title), group: to_string(group)}

      case extra do
        %{search_data: search_data} when is_list(search_data) ->
          search_data =
            Enum.map(search_data, fn search_item ->
              %{
                anchor: search_item.anchor,
                id: search_item.title,
                labels: [search_item.type]
              }
            end)

          item
          |> Map.put(:headers, headers(extra.doc))
          |> Map.put(:searchData, search_data)

        %{url: url} when is_binary(url) ->
          Map.put(item, :url, url)

        _ ->
          Map.put(item, :headers, headers(extra.doc))
      end
    end
  end

  defp sidebar_module({id, modules}) do
    modules =
      for module <- modules do
        groups =
          case module.docs_groups do
            [] -> []
            entries -> [nodeGroups: Enum.map(entries, &sidebar_entries/1)]
          end

        pairs =
          for key <- [:id, :title, :nested_title, :nested_context],
              value = Map.get(module, key),
              do: {key, value}

        others = [
          deprecated: not is_nil(module.deprecated),
          sections: headers(module.doc || []),
          group: to_string(module.group)
        ]

        Map.new(groups ++ pairs ++ others)
      end

    {id, modules}
  end

  defp sidebar_entries(group) do
    nodes =
      for node <- group.docs do
        id =
          if "struct" in node.annotations do
            node.signature
          else
            if node.name == nil do
              "nil/#{node.arity}"
            else
              "#{node.name}/#{node.arity}"
            end
          end

        deprecated? = not is_nil(node.deprecated)

        %{id: id, title: node.signature, anchor: URI.encode(node.id), deprecated: deprecated?}
      end

    %{key: text_to_id(group.title), name: group.title, nodes: nodes}
  end

  defp headers(doc) do
    doc
    |> ExDoc.DocAST.extract_headers_with_ids([:h2])
    |> Enum.map(fn {:h2, text, anchor} ->
      %{id: text, anchor: anchor}
    end)
  end

  defp favicon_path(%{favicon: favicon}), do: "assets/favicon#{Path.extname(favicon)}"

  defp logo_path(%{logo: logo}), do: "assets/logo#{Path.extname(logo)}"

  defp sidebar_type(:exception), do: "modules"
  defp sidebar_type(:module), do: "modules"
  defp sidebar_type(:behaviour), do: "modules"
  defp sidebar_type(:protocol), do: "modules"
  defp sidebar_type(:task), do: "tasks"

  defp sidebar_type(:search), do: "search"
  defp sidebar_type(:cheatmd), do: "extras"
  defp sidebar_type(:livemd), do: "extras"
  defp sidebar_type(:extra), do: "extras"

  @section_header_class_name "section-heading"

  @doc """
  Renders the document in the page.

  For now it enriches the document by adding fancy anchors
  around h2 and h3 tags with IDs.
  """
  def render_doc(nil), do: ""

  def render_doc(ast) do
    ast
    |> add_fancy_anchors()
    |> add_nofollow()
    |> ExDoc.DocAST.to_html()
  end

  @official_domains ~w(hex.pm hexdocs.pm elixir-lang.org erlang.org)

  defp add_nofollow(ast) do
    ExDoc.DocAST.map_tags(ast, fn
      {:a, attrs, inner, meta} ->
        href = Keyword.get(attrs, :href, "")

        if nofollow?(href) do
          {:a, Keyword.put(attrs, :rel, "nofollow"), inner, meta}
        else
          {:a, attrs, inner, meta}
        end

      other ->
        other
    end)
  end

  defp nofollow?(href) do
    uri = URI.parse(href)
    uri.scheme in ["http", "https"] and not official_host?(uri.host)
  end

  defp official_host?(nil), do: false

  defp official_host?(host) do
    Enum.any?(@official_domains, fn domain ->
      host == domain or String.ends_with?(host, "." <> domain)
    end)
  end

  defp add_fancy_anchors(ast) do
    ExDoc.DocAST.map_tags(ast, fn
      {tag, attrs, inner, meta} = ast
      when tag in [:h2, :h3] and not is_map_key(meta, :verbatim) ->
        if id = Keyword.get(attrs, :id) do
          attrs =
            Keyword.update(
              attrs,
              :class,
              @section_header_class_name,
              &(&1 <> " " <> @section_header_class_name)
            )

          {tag, attrs,
           [
             {:a, [href: "##{id}", class: "hover-link"],
              [
                {:i, [class: "ri-link-m", "aria-hidden": "true"], [], %{}}
              ], %{}},
             {:span, [class: "text"], inner, %{}}
           ], meta}
        else
          ast
        end

      ast ->
        ast
    end)
  end

  templates = [
    detail_template: [:node, :module],
    footer_template: [:config, :source_path],
    head_template: [:config, :title, :noindex],
    module_template: [:config, :module],
    not_found_template: [:config],
    api_reference_entry_template: [:module_node],
    api_reference_template: [:config, :modules, :tasks],
    extra_template: [:config, :node, :refs],
    search_template: [:config],
    sidebar_template: [:config, :type],
    summary_template: [:name, :nodes],
    redirect_template: [:config, :redirect_to]
  ]

  Enum.each(templates, fn {name, args} ->
    filename = Path.expand("templates/#{name}.eex", __DIR__)
    @doc false
    EEx.function_from_file(:def, name, filename, args, trim: true)
  end)
end
