defmodule ExDoc.CLI do
  @moduledoc false

  @doc """
  Handles the command line parsing for the escript.
  """
  def main(args, generator \\ &ExDoc.generate/4) do
    {:ok, _} = Application.ensure_all_started(:ex_doc)

    {opts, args} =
      OptionParser.parse!(args,
        aliases: [
          c: :config,
          f: :formatter,
          l: :logo,
          m: :main,
          o: :output,
          q: :quiet,
          u: :source_url,
          v: :version
        ],
        switches: [
          canonical: :string,
          config: :string,
          favicon: :string,
          footer: :boolean,
          formatter: [:keep, :string],
          homepage_url: :string,
          language: :string,
          logo: :string,
          main: :string,
          output: :string,
          package: :string,
          package: :string,
          paths: [:keep, :string],
          proglang: :string,
          quiet: :boolean,
          source_ref: :string,
          source_url: :string,
          version: :boolean,
          warnings_as_errors: :boolean
        ]
      )

    if List.keymember?(opts, :version, 0) do
      IO.puts("ExDoc v#{ExDoc.version()}")
    else
      generate(args, opts, generator)
    end
  end

  defp generate(args, opts, generator) do
    [project, version | source_beams] = parse_args(args)
    Code.prepend_paths(source_beams)

    for path <- Keyword.get_values(opts, :paths),
        path <- Path.wildcard(path) do
      Code.prepend_path(path)
      app(path) |> Application.load()
    end

    # Start all applications with the makeup prefix
    for {app, _, _} <- Application.loaded_applications(),
        match?("makeup_" <> _, Atom.to_string(app)) do
      Application.ensure_all_started(app)
    end

    opts =
      opts
      |> Keyword.put(:apps, Enum.map(source_beams, &app/1))
      |> merge_config()
      |> normalize_formatters()

    quiet? = Keyword.get(opts, :quiet, false)
    generated_docs = generator.(project, version, source_beams, opts)

    unless quiet? do
      Enum.each(generated_docs, fn %{entrypoint: entrypoint, formatter: formatter} ->
        extension = formatter_module_to_extension(formatter)
        IO.puts(IO.ANSI.format([:green, "View #{extension} docs at #{inspect(entrypoint)}"]))
      end)
    end

    warned = Enum.filter(generated_docs, & &1.warned?)

    if opts[:warnings_as_errors] == true and warned != [] do
      formatters = Enum.map(warned, &formatter_module_to_extension(&1.formatter))

      format_message =
        case formatters do
          [formatter] -> "#{formatter} format"
          _ -> "#{Enum.join(formatters, ", ")} formats"
        end

      message =
        "Documents have been generated, but generation for #{format_message} failed " <>
          "due to warnings while using the --warnings-as-errors option"

      message_formatted = IO.ANSI.format([:red, message, :reset])
      IO.puts(:stderr, message_formatted)
      exit({:shutdown, 1})
    else
      Enum.map(generated_docs, & &1.entrypoint)
    end
  end

  defp formatter_module_to_extension(module) do
    module |> Module.split() |> List.last() |> String.downcase()
  end

  defp normalize_formatters(opts) do
    formatters =
      case Keyword.get_values(opts, :formatter) do
        [] -> opts[:formatters] || ["html", "markdown", "epub"]
        values -> values
      end

    opts
    |> Keyword.delete(:formatter)
    |> Keyword.put(:formatters, formatters)
  end

  defp app(source_beam) do
    case Path.wildcard(Path.join([source_beam, "*.app"])) do
      [path] ->
        path |> Path.basename(".app") |> String.to_atom()

      _ ->
        raise "cannot find .app file in #{inspect(source_beam)}"
    end
  end

  defp merge_config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} ->
        opts_without_config = Keyword.delete(opts, :config)
        Keyword.merge(read_config(config), opts_without_config)

      _ ->
        opts
    end
  end

  defp read_config(path) do
    case Path.extname(path) do
      ".exs" ->
        read_config_exs(path)

      ".config" ->
        read_config_erl(path)

      other ->
        raise "expected config to have .exs or .config extension, got: #{inspect(other)}"
    end
  end

  defp read_config_exs(path) do
    config = File.read!(path)
    {result, _} = Code.eval_string(config)

    unless is_list(result) do
      raise "expected a keyword list from config file: #{inspect(path)}"
    end

    result
  end

  defp read_config_erl(path) do
    case :file.consult(path) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise "error parsing #{path}: #{inspect(reason)}"
    end
  end

  defp parse_args([_project, _version | _source_beams] = args), do: args

  defp parse_args(_) do
    IO.puts("Too few arguments.\n")
    print_usage()
    exit({:shutdown, 1})
  end

  defp print_usage do
    IO.puts(~S"""
    Usage:
      ex_doc PROJECT VERSION BEAMS [OPTIONS]

    Examples:
      ex_doc "Ecto" "0.8.0" "_build/dev/lib/ecto/ebin" -u "https://github.com/elixir-ecto/ecto"
      ex_doc "Project" "1.0.0" "_build/dev/lib/project/ebin" -c "docs.exs"

    Options:
      PROJECT                   Project name
      VERSION                   Version number
      BEAMS                     Path to compiled beam files
          --canonical           Indicate the preferred URL with rel="canonical" link element
      -c, --config              Give configuration through a file instead of a command line.
                                See "Custom config" section below for more information.
          --favicon             Path to a favicon image for the project. Must be PNG, JPEG or SVG. The image
                                will be placed in the output "assets" directory.
      -f, --formatter           Docs formatter to use (html or epub), default: html and epub
          --no-footer           Do not render the footer (except for the required "Built with ExDoc" note)
          --homepage-url        URL to link to for the site name
          --language            Identify the primary language of the documents, its value must be
                                a valid [BCP 47](https://tools.ietf.org/html/bcp47) language tag, default: "en"
      -l, --logo                Path to a logo image for the project. Must be PNG, JPEG or SVG. The image will
                                be placed in the output "assets" directory.
      -m, --main                The entry-point page in docs, default: "api-reference"
      -o, --output              Path to output docs, default: "doc"
          --package             Hex package name
          --paths               Prepends the given path to Erlang code path. The path might contain a glob
                                pattern but in that case, remember to quote it: --paths "_build/dev/lib/*/ebin".
                                This option can be given multiple times.
          --proglang            The project's programming language, default: "elixir".
      -q, --quiet               Only output warnings and errors.
          --source-ref          Branch/commit/tag used for source link inference, default: "master".
      -u, --source-url          URL to the source code.
      -v, --version             Print ExDoc version.
          --warnings-as-errors  Exit with non-zero status if doc generation produces warnings.

    ## Custom config

    A custom config can be given with the --config option.

    The file must either have ".exs" or ".config" extension.

    The file with the ".exs" extension must be an Elixir script that returns
    a keyword list with the same options declares in `ExDoc.generate/4`.
    Here is an example:

        [
          extras: Path.wildcard("lib/elixir/pages/*.md"),
          groups_for_docs: [
            Guards: & &1[:guard] == true
          ],
          skip_undefined_reference_warnings_on: ["compatibility-and-deprecations"],
          groups_for_modules: [
            ...
          ]
        ]

    The file with the ".config" extension must contain Erlang terms separated by ".".
    See `:file.consult/1` for more information. Here is an example:

        {extras, [<<"README.md">>, <<"CHANGELOG.md">>]}.
        {main, <<"readme">>}.
        {proglang, erlang}.

    ## Source linking

    ExDoc by default provides links to the source code implementation as
    long as --source-url or --source-url-pattern is provided. If you
    provide --source-url, ExDoc will inflect the url pattern automatically
    for GitHub, GitLab, and Bitbucket URLs. For example:

        --source-url "https://github.com/elixir-ecto/ecto"

    Will be inflected as:

        https://github.com/elixir-ecto/ecto/blob/master/%{path}#L%{line}

    To specify a particular branch or commit, use the `--source-ref` option:

        --source-url "https://github.com/elixir-ecto/ecto" --source-ref "v1.0"

    will result in the following URL pattern:

        https://github.com/elixir-ecto/ecto/blob/v1.0/%{path}#L%{line}

    """)
  end
end
