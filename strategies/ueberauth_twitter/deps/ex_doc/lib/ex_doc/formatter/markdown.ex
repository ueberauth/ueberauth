defmodule ExDoc.Formatter.MARKDOWN do
  @moduledoc false

  alias __MODULE__.Templates

  def run(config, project_nodes, extras) when is_map(config) do
    File.mkdir_p!(config.output)

    static_files =
      if Enum.all?(config.assets, fn {_k, target_dir} ->
           config.output |> Path.join(target_dir) |> File.exists?()
         end) do
        []
      else
        ExDoc.Formatter.copy_assets(config.assets, config.output)
      end

    {modules, tasks} =
      project_nodes
      |> Enum.filter(&(&1.source_format == "text/markdown"))
      |> Enum.split_with(&(&1.type != :task))

    all_files =
      generate_nav(config, modules, tasks, extras) ++
        generate_api_reference(config, modules, tasks) ++
        generate_extras(config, extras) ++
        generate_list(config, modules) ++
        generate_list(config, tasks) ++
        static_files

    entrypoint = config.output |> Path.join("llms.txt") |> Path.relative_to_cwd()
    %{entrypoint: entrypoint, build: List.flatten(all_files)}
  end

  defp normalize_output(output) do
    output
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp generate_nav(config, modules, tasks, extras) do
    modules = group_by_group(modules)
    mix_tasks = group_by_group(tasks)
    extras = group_by_group(extras)

    content =
      config
      |> Templates.llms_txt_template(modules, mix_tasks, extras)
      |> normalize_output()

    filename = "llms.txt"

    write!(config, filename, content)

    [filename]
  end

  defp generate_api_reference(%{api_reference: false}, _modules, _tasks) do
    []
  end

  defp generate_api_reference(config, modules, tasks) do
    modules = group_by_group(modules)
    mix_tasks = group_by_group(tasks)

    content =
      config
      |> Templates.api_reference_template(modules, mix_tasks)
      |> normalize_output()

    filename = "api-reference.md"

    write!(config, filename, content)

    [filename]
  end

  defp group_by_group(nodes) do
    nodes
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(&{hd(&1).group, &1})
  end

  defp generate_extras(config, extras) do
    for %ExDoc.ExtraNode{id: id, source_doc: content} <- extras do
      filename = "#{id}.md"

      write!(config, filename, content)

      filename
    end
  end

  defp generate_list(config, nodes) do
    nodes
    |> Task.async_stream(&generate_module(config, &1), timeout: :infinity)
    |> Enum.map(&elem(&1, 1))
  end

  ## Helpers

  defp generate_module(config, module_node) do
    content =
      config
      |> Templates.module_template(module_node)
      |> normalize_output()

    filename = "#{module_node.id}.md"

    write!(config, filename, content)

    filename
  end

  defp write!(config, filename, content) do
    config.output
    |> Path.join(filename)
    |> File.write!(content)
  end
end
