defmodule ExDoc.Formatter do
  @moduledoc """
  Specifies the custom formatter API.
  """

  @doc """
  The callback that must be implemented by formatters.

  It receives the configuration, a list of nodes,
  and it must return the documentation entrypoint
  plus a list of files built inside the output folder.
  """
  @callback run(
              ExDoc.Formatter.Config.t(),
              [ExDoc.ModuleNode.t()],
              [ExDoc.ExtraNode.t() | ExDoc.URLNode.t()]
            ) :: %{entrypoint: String.t(), build: [String.t()]}

  @doc """
  A list of options to configure autolinking behaviour.
  """
  @callback autolink_options() :: [highlight_tag: String.t(), extension: String.t()]

  @optional_callbacks autolink_options: 0

  @doc false
  def run(formatter, formatter_config, module_nodes, filtered_nodes, extras) do
    if not Code.ensure_loaded?(formatter) do
      raise "formatter module #{inspect(formatter)} not found"
    end

    build_file = build_file_path(formatter, formatter_config)
    cleanup_build_file(build_file, formatter_config)

    {module_nodes, extras} =
      if function_exported?(formatter, :autolink_options, 0) do
        autolink_opts = formatter.autolink_options()
        autolink(formatter_config, module_nodes, filtered_nodes, extras, autolink_opts)
      else
        {module_nodes, extras}
      end

    %{entrypoint: entrypoint, build: build} =
      formatter.run(formatter_config, module_nodes, extras)

    write_build_file(build_file, build)
    entrypoint
  end

  defp build_file_path(formatter, config) do
    extension =
      case formatter do
        # For backwards compatibility
        ExDoc.Formatter.HTML ->
          ""

        _ ->
          formatter
          |> Module.split()
          |> List.last()
          |> String.downcase()
          |> then(&".#{&1}")
      end

    Path.join(config.output, ".build#{extension}")
  end

  defp cleanup_build_file(build_file, config) do
    if File.exists?(build_file) do
      build_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Path.join(config.output, &1))
      |> Enum.each(&File.rm/1)
    end
  end

  defp write_build_file(_build_file, []) do
    :ok
  end

  defp write_build_file(build_file, files) do
    entries =
      files
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&[&1, "\n"])

    File.mkdir_p!(Path.dirname(build_file))
    File.write!(build_file, entries)
  end

  ## Assets/image helpers

  @doc """
  Copy `assets` to the given `output` folder.
  """
  def copy_assets(assets, output) do
    Enum.flat_map(assets, fn {dir_or_files, relative_target_dir} ->
      target_dir = Path.join(output, relative_target_dir)
      File.mkdir_p!(target_dir)

      cond do
        is_list(dir_or_files) ->
          Enum.map(dir_or_files, fn {name, content} ->
            target = Path.join(target_dir, name)
            File.write(target, content)
            Path.relative_to(target, output)
          end)

        is_binary(dir_or_files) and File.dir?(dir_or_files) ->
          dir_or_files
          |> File.cp_r!(target_dir, dereference_symlinks: true)
          |> Enum.reduce([], fn path, acc ->
            # Omit directories in .build file
            if File.dir?(path) do
              acc
            else
              [Path.relative_to(path, output) | acc]
            end
          end)
          |> Enum.reverse()

        is_binary(dir_or_files) ->
          []

        true ->
          raise ":assets must be a map of source directories to target directories"
      end
    end)
  end

  @doc """
  Copies the logo to the given location in the output directory.
  """
  def copy_logo(%{logo: nil}, _target) do
    []
  end

  def copy_logo(%{output: output, logo: logo}, target) do
    copy_image(output, logo, target)
  end

  @doc """
  Copies the favicon to the given location in the output directory.
  """
  def copy_favicon(%{favicon: nil}, _target) do
    []
  end

  def copy_favicon(%{output: output, favicon: favicon}, target) do
    copy_image(output, favicon, target)
  end

  @doc """
  Copies the cover to the given location in the output directory.
  """
  def copy_cover(%{cover: nil}, _target) do
    []
  end

  def copy_cover(%{output: output, cover: cover}, target) do
    copy_image(output, cover, target)
  end

  defp copy_image(output, source, target) do
    extname = source |> Path.extname() |> String.downcase()

    if extname in ~w(.png .jpg .jpeg .svg) do
      filename = "#{target}#{extname}"
      target = Path.join(output, filename)
      File.mkdir_p!(Path.dirname(target))
      File.copy!(source, target)
      [filename]
    else
      raise ArgumentError, "image format not recognized, allowed formats are: .png, .jpg, .svg"
    end
  end

  ## Autolinking

  @doc false
  def autolink(config, nodes, filtered_nodes, extras, opts) do
    {ext, highlight_opts} = Keyword.pop!(opts, :extension)

    language =
      case config.proglang do
        :erlang -> ExDoc.Language.Erlang
        _ -> ExDoc.Language.Elixir
      end

    base_config = %ExDoc.Autolink{
      apps: config.apps,
      deps: config.deps,
      ext: ext,
      extras: extra_paths(extras),
      skip_undefined_reference_warnings_on: config.skip_undefined_reference_warnings_on,
      skip_code_autolink_to: config.skip_code_autolink_to,
      filtered_modules: filtered_nodes,
      assets: config.assets
    }

    extras =
      extras
      |> Task.async_stream(
        &autolink_extra(&1, language, base_config, highlight_opts),
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, res} -> res end)

    # Render project nodes with autolinked extras
    nodes =
      nodes
      |> Task.async_stream(
        &autolink_node(&1, base_config, highlight_opts),
        timeout: :infinity
      )
      |> Enum.map(&elem(&1, 1))

    {nodes, extras}
  end

  defp autolink_node(node, base_config, highlight_opts) do
    language = node.language

    autolink_config = %{
      base_config
      | current_module: node.module,
        module_id: node.id,
        language: language
    }

    docs_groups =
      for group <- node.docs_groups do
        docs =
          for child_node <- group.docs do
            child_config = %{
              autolink_config
              | id: id(node, child_node),
                line: child_node.doc_line,
                file: child_node.doc_file,
                current_kfa: {child_node.type, child_node.name, child_node.arity}
            }

            specs =
              Enum.map(child_node.source_specs, &language.autolink_spec(&1, child_config))

            child_node = %{child_node | specs: specs}
            autolink_doc(child_node, language, child_config, highlight_opts)
          end

        %{autolink_doc(group, language, autolink_config, highlight_opts) | docs: docs}
      end

    module_config = %{
      autolink_config
      | id: node.id,
        file: node.moduledoc_file,
        line: node.moduledoc_line
    }

    %{
      autolink_doc(node, language, module_config, highlight_opts)
      | docs_groups: docs_groups
    }
  end

  defp autolink_doc(%{doc: nil} = node, _language, _autolink_opts, _opts),
    do: node

  defp autolink_doc(%{doc: doc} = node, language, autolink_opts, opts) do
    doc = autolink_and_highlight(doc, language, autolink_opts, opts)
    %{node | doc: doc}
  end

  defp autolink_extra(%ExDoc.URLNode{} = extra, _language, _autolink_opts, _opts),
    do: extra

  defp autolink_extra(%ExDoc.ExtraNode{doc: nil} = extra, _language, _autolink_opts, _opts),
    do: extra

  defp autolink_extra(
         %ExDoc.ExtraNode{doc: doc, source_path: source_path, id: id} = extra,
         language,
         base_config,
         opts
       ) do
    extra_config = %{base_config | file: source_path, id: id, language: language}
    doc = autolink_and_highlight(doc, language, extra_config, opts)
    %{extra | doc: doc}
  end

  defp id(%{id: mod_id}, %{id: "c:" <> id}) do
    "c:" <> mod_id <> "." <> id
  end

  defp id(%{id: mod_id}, %{id: "t:" <> id}) do
    "t:" <> mod_id <> "." <> id
  end

  defp id(%{id: mod_id}, %{id: id}) do
    mod_id <> "." <> id
  end

  defp autolink_and_highlight(doc, language, autolink_opts, opts) do
    doc
    |> language.autolink_doc(autolink_opts)
    |> ExDoc.DocAST.highlight(language, opts)
  end

  defp extra_paths(extras) do
    Enum.reduce(extras, %{}, fn
      %ExDoc.URLNode{}, acc ->
        acc

      %ExDoc.ExtraNode{source_path: source_path, id: id}, acc when is_binary(source_path) ->
        base = Path.basename(source_path)
        Map.put(acc, base, id)

      _extra, acc ->
        acc
    end)
  end
end
