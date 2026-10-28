defmodule ExDoc.Formatter.EPUB do
  @moduledoc false

  @mimetype "application/epub+zip"
  @assets_dir "OEBPS/assets"
  alias __MODULE__.{Assets, Templates}
  alias ExDoc.Formatter

  @doc false
  def autolink_options do
    [extension: ".xhtml", highlight_tag: "samp"]
  end

  @doc """
  Generates EPUB documentation for the given modules.
  """
  def run(config, project_nodes, extras) when is_map(config) do
    config = normalize_config(config)
    File.rm_rf!(config.output)
    File.mkdir_p!(Path.join(config.output, "OEBPS"))

    static_files =
      Formatter.copy_assets(config.assets, Path.join(config.output, "OEBPS")) ++
        Formatter.copy_assets(additional_assets(config), config.output)

    Formatter.copy_logo(config, Path.join(@assets_dir, "logo"))
    Formatter.copy_cover(config, Path.join(@assets_dir, "cover"))

    {modules, tasks} = Enum.split_with(project_nodes, &(&1.type != :task))
    generate_content(config, modules, tasks, extras, static_files)
    generate_nav(config, modules, tasks, extras)
    generate_title(config)
    generate_extras(config, extras)
    generate_modules(config, modules)
    generate_modules(config, tasks)

    {:ok, epub} = generate_epub(config.output)
    File.rm_rf!(config.output)
    entrypoint = Path.relative_to_cwd(epub)
    %{entrypoint: entrypoint, build: [entrypoint]}
  end

  defp normalize_config(config) do
    output = Path.join(config.output, "#{config.project}")
    %{config | output: output}
  end

  defp generate_extras(config, extras) do
    for %ExDoc.ExtraNode{} = node <- extras do
      output = "#{config.output}/OEBPS/#{node.id}.xhtml"
      html = Templates.extra_template(config, node)

      if File.regular?(output) do
        ExDoc.warn("file #{Path.relative_to_cwd(output)} already exists", [])
      end

      File.write!(output, html)
    end
  end

  defp generate_content(config, modules, tasks, extras, static_files) do
    uuid = "urn:uuid:#{uuid4()}"
    datetime = format_datetime()

    static_files =
      for name <- static_files,
          String.contains?(name, "OEBPS"),
          media_type = Templates.media_type(Path.extname(name)),
          do: {Path.relative_to(name, "OEBPS"), media_type}

    content =
      Templates.content_template(config, modules, tasks, extras, uuid, datetime, static_files)

    File.write!("#{config.output}/OEBPS/content.opf", content)
  end

  defp generate_nav(config, modules, tasks, extras) do
    modules = group_by_group(modules)
    tasks = group_by_group(tasks)
    extras = group_by_group(extras)

    content = Templates.nav_template(config, modules, tasks, extras)
    File.write!("#{config.output}/OEBPS/nav.xhtml", content)
  end

  defp group_by_group(nodes) do
    nodes
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(&{hd(&1).group, &1})
  end

  defp generate_title(config) do
    content = Templates.title_template(config)
    File.write!("#{config.output}/OEBPS/title.xhtml", content)
  end

  defp generate_modules(config, nodes) do
    nodes
    |> Task.async_stream(
      fn module_node ->
        content = Templates.module_template(config, module_node)
        File.write!("#{config.output}/OEBPS/#{module_node.id}.xhtml", content)
      end,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp generate_epub(output) do
    :zip.create(
      String.to_charlist("#{output}.epub"),
      [{~c"mimetype", @mimetype} | files_to_add(output)],
      compress: ~w[.css .xhtml .html .ncx .js .opf .jpg .png .xml]c
    )
  end

  ## Helpers

  defp additional_assets(config) do
    [
      {Assets.dist(config.proglang), "OEBPS/dist"},
      {Assets.metainfo(), "META-INF"}
    ]
  end

  defp files_to_add(path) do
    Enum.reduce(Path.wildcard(Path.join(path, "**/*")), [], fn file, acc ->
      case File.read(file) do
        {:ok, bin} ->
          [{file |> Path.relative_to(path) |> String.to_charlist(), bin} | acc]

        {:error, _} ->
          acc
      end
    end)
  end

  # Helper to format Erlang datetime tuple
  defp format_datetime do
    {{year, month, day}, {hour, min, sec}} = :calendar.universal_time()
    list = [year, month, day, hour, min, sec]

    "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ"
    |> :io_lib.format(list)
    |> IO.iodata_to_binary()
  end

  @two_power_16 65536
  @two_power_32 4_294_967_296
  @two_power_48 281_474_976_710_656

  defp uuid4 do
    Enum.map_join(
      [
        <<:rand.uniform(@two_power_32) - 1::32>>,
        <<:rand.uniform(@two_power_16) - 1::16>>,
        <<:rand.uniform(@two_power_16) - 1::16>>,
        <<:rand.uniform(@two_power_16) - 1::16>>,
        <<:rand.uniform(@two_power_48) - 1::48>>
      ],
      <<45>>,
      &Base.encode16(&1, case: :lower)
    )
  end
end
