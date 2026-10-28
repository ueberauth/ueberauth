defmodule ExDoc.Extras do
  @moduledoc false

  alias ExDoc.{Config, Markdown, Utils}

  @reserved_filenames ~w(404.html search.html)

  @doc """
  Build a list of `ExDoc.ExtraNode` and `ExDoc.URLNode`.
  """
  def build(extras_input, config) do
    groups = config.groups_for_extras

    extras =
      extras_input
      |> Enum.map(&build_extra(&1, groups, config))

    validate_no_reserved_filenames!(extras)
    validate_no_duplicate_extras!(extras)

    ids_count = Enum.reduce(extras, %{}, &Map.update(&2, &1.id, 1, fn c -> c + 1 end))

    extras
    |> Enum.map_reduce(1, fn extra, idx ->
      if ids_count[extra.id] > 1, do: {disambiguate_id(extra, idx), idx + 1}, else: {extra, idx}
    end)
    |> elem(0)
    |> Enum.sort_by(fn extra -> Config.index(groups, extra.group) end)
  end

  defp validate_no_reserved_filenames!(extras) do
    conflicts =
      extras
      |> Enum.filter(&match?(%ExDoc.ExtraNode{}, &1))
      |> Enum.filter(fn extra -> "#{extra.id}.html" in @reserved_filenames end)

    if conflicts != [] do
      entries =
        Enum.map_join(conflicts, ", ", fn extra ->
          "#{inspect(extra.source_path)} would generate #{extra.id}.html"
        end)

      raise ArgumentError,
            "extra(s) would conflict with built-in ExDoc page(s): #{entries}; " <>
              "rename your extra file(s) or use the :filename option to set different output filename(s)"
    end
  end

  # Detects duplicate ExtraNode entries by checking for collisions on the
  # {source_path, id} pair.
  #   - URLNodes are excluded since they don't produce output files.
  #   - Two nodes are duplicates when they share both source_path and ID — meaning
  #     the same file would generate the same output page.
  #   - Nodes with different source paths or different IDs (e.g. via the
  #     :filename option) are not duplicates.
  #   - Nodes from different source files that happen to share an ID are handled
  #     by disambiguate_id/2 instead.
  defp validate_no_duplicate_extras!(extras) do
    duplicates =
      extras
      |> Enum.filter(&match?(%ExDoc.ExtraNode{}, &1))
      |> Enum.frequencies_by(fn extra -> {extra.source_path, extra.id} end)
      |> Enum.filter(fn {_, count} -> count > 1 end)

    if duplicates != [] do
      entries = Enum.map_join(duplicates, ", ", fn {{source, _}, _} -> inspect(source) end)

      raise ArgumentError,
            "duplicate extras: #{entries}"
    end
  end

  defp disambiguate_id(extra, discriminator) do
    Map.put(extra, :id, "#{extra.id}-#{discriminator}")
  end

  defp build_extra(input, groups, config) when is_binary(input) do
    build_extra({input, %{}}, groups, config)
  end

  defp build_extra({input, opts}, groups, config) when is_list(opts) do
    build_extra({input, Map.new(opts)}, groups, config)
  end

  defp build_extra({input, %{url: _} = input_options}, groups, _config) do
    input = to_string(input)
    title = validate_extra_string!(input_options, :title) || input
    url = validate_extra_string!(input_options, :url)
    group = Config.match_extra(groups, url)

    %ExDoc.URLNode{
      group: group,
      id: Utils.text_to_id(title),
      title: title,
      url: url
    }
  end

  defp build_extra({input, input_options}, groups, config) do
    input = to_string(input)

    id =
      validate_extra_string!(input_options, :filename) ||
        input |> filename_to_title() |> Utils.text_to_id()

    source_file = validate_extra_string!(input_options, :source) || input
    opts = [file: source_file, line: 1, markdown_processor: config.markdown_processor]

    {extension, source, ast} =
      case extension_name(input) do
        extension when extension in ["", ".txt"] ->
          source = File.read!(input)
          ast = [{:pre, [], ["\n" <> source], %{}}]
          {extension, source, ast}

        extension when extension in [".md", ".livemd", ".cheatmd"] ->
          source = File.read!(input)

          ast =
            source
            |> Markdown.to_ast(opts)
            |> ExDoc.DocAST.add_ids_to_headers([:h2, :h3])

          {extension, source, ast}

        _ ->
          raise ArgumentError,
                "file extension not recognized, allowed extension is either .cheatmd, .livemd, .md, .txt or no extension"
      end

    {title_doc, title_text, ast} =
      case ExDoc.DocAST.extract_title(ast) do
        {:ok, title_doc, ast} -> {title_doc, ExDoc.DocAST.text(title_doc), ast}
        :error -> {nil, nil, ast}
      end

    title =
      validate_extra_string!(input_options, :title) || title_text || filename_to_title(input)

    group = Config.match_extra(groups, input)
    source_path = source_file |> Path.relative_to(File.cwd!()) |> String.replace_leading("./", "")
    source_url = config.source_url_pattern.(source_path, 1)
    search_data = validate_search_data!(input_options[:search_data])

    %ExDoc.ExtraNode{
      type: extra_type(extension),
      source_doc: source,
      group: group,
      id: id,
      doc: ast,
      source_path: source_path,
      source_url: source_url,
      search_data: search_data,
      title: title,
      title_doc: title_doc || title
    }
  end

  defp validate_extra_string!(input_options, key) do
    case input_options[key] do
      nil ->
        nil

      binary when is_binary(binary) ->
        binary

      other ->
        raise ArgumentError,
              "extra field #{inspect(key)} must be a string, got: #{inspect(other)}"
    end
  end

  @search_data_keys [:anchor, :body, :title, :type]

  defp validate_search_data!(nil), do: nil

  defp validate_search_data!(search_data) when is_list(search_data) do
    Enum.each(search_data, fn search_data ->
      has_keys = Map.keys(search_data)

      if Enum.sort(has_keys) != @search_data_keys do
        raise ArgumentError,
              "expected search data to be a list of maps with the keys: #{inspect(@search_data_keys)}, " <>
                "found keys: #{inspect(has_keys)}"
      end
    end)

    search_data
  end

  defp validate_search_data!(search_data) do
    raise ArgumentError,
          "expected search data to be a list of maps with the keys: #{inspect(@search_data_keys)}, " <>
            "found: #{inspect(search_data)}"
  end

  defp extension_name(input) do
    input
    |> Path.extname()
    |> String.downcase()
  end

  defp filename_to_title(input) do
    input |> Path.basename() |> Path.rootname()
  end

  defp extra_type(".cheatmd"), do: :cheatmd
  defp extra_type(".livemd"), do: :livemd
  defp extra_type(_), do: :extra
end
