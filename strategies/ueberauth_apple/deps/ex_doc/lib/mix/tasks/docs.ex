defmodule Mix.Tasks.Docs do
  use Mix.Task

  @shortdoc "Generate documentation for the project"
  @requirements ["compile"]

  @moduledoc ~S"""
  Uses ExDoc to generate a static web page from the project documentation.

  ## Command line options

    * `--canonical`, `-n` - Indicate the preferred URL with
      `rel="canonical"` link element, defaults to no canonical path

    * `--formatter`, `-f` - Which formatters to use, `html`,
      `epub`, or `markdown`. This option can be given more than once. By default,
      `html`, `epub`, and `markdown` are generated.

    * `--language` - Specifies the language to annotate the
      EPUB output in valid [BCP 47](https://tools.ietf.org/html/bcp47)

    * `--open` - open browser window pointed to the documentation

    * `--output`, `-o` - Output directory for the generated
      docs, default: `"doc"`

    * `--proglang` - Chooses the main programming language: `elixir`
      or `erlang`

    * `--warnings-as-errors` - Exits with non-zero exit code if any warnings are found

  The command line options have higher precedence than the options
  specified in your `mix.exs` file below.

  ## Configuration

  ExDoc will automatically pull in information from your project,
  like the application and version. However, you may want to set
  `:name`, `:source_url` and `:homepage_url` to have a nicer output
  from ExDoc, for example:

      def project do
        [
          app: :my_app,
          version: "0.1.0-dev",
          deps: deps(),

          # Docs
          name: "My App",
          source_url: "https://github.com/USER/PROJECT",
          homepage_url: "http://YOUR_PROJECT_HOMEPAGE",
          docs: [
            main: "MyApp", # The main page in the docs
            favicon: "path/to/favicon.png",
            logo: "path/to/logo.png",
            extras: ["README.md"]
          ]
        ]
      end

  ExDoc also allows configuration specific to the documentation to
  be set. The following options should be put under the `:docs` key
  in your project's main configuration. The `:docs` options should
  be a keyword list or a function returning a keyword list that will
  be lazily executed. See all supported options in `ExDoc.generate/4`.

  ## Umbrella project

  ExDoc can be used in an umbrella project and generates a single documentation
  for all child apps. You can use the `:ignore_apps` configuration to exclude
  certain projects in the umbrella from documentation.

  Generating documentation per each child app can be achieved by running:

      mix cmd mix docs

  See `mix help cmd` for more information.
  """

  @switches [
    canonical: :string,
    formatter: :keep,
    language: :string,
    open: :boolean,
    output: :string,
    proglang: :string,
    warnings_as_errors: :boolean
  ]

  @aliases [
    f: :formatter,
    n: :canonical,
    o: :output
  ]

  @doc false
  def run(args, config \\ Mix.Project.config(), generator \\ &ExDoc.generate/4) do
    {:ok, _} = Application.ensure_all_started(:ex_doc)

    unless Code.ensure_loaded?(ExDoc.Formatter.Config) do
      Mix.raise(
        "Could not load ExDoc configuration. Please make sure you are running the " <>
          "docs task in the same Mix environment it is listed in your deps"
      )
    end

    {cli_opts, args, _} = OptionParser.parse(args, aliases: @aliases, switches: @switches)

    if args != [] do
      Mix.raise("Extraneous arguments on the command line")
    end

    project =
      to_string(
        config[:name] || config[:app] ||
          Mix.raise("expected :name or :app to be found in the project definition in mix.exs")
      )

    version = config[:version] || "dev"

    cli_opts =
      Keyword.update(cli_opts, :proglang, :elixir, fn proglang ->
        if proglang not in ~w(erlang elixir) do
          Mix.raise("--proglang must be elixir or erlang")
        end

        String.to_atom(proglang)
      end)

    options =
      config
      |> get_docs_opts()
      |> Keyword.merge(cli_opts)
      # accepted at root level config
      |> normalize_source_url(config)
      # accepted at root level config
      |> normalize_homepage_url(config)
      # accepted at root level config
      |> normalize_description(config)
      |> normalize_apps(config)
      |> normalize_main()
      |> normalize_deps()
      |> normalize_formatters()
      |> put_package(config)

    source_beams = source_beams(options, config)
    Code.prepend_path(source_beams)

    for path <- Keyword.get_values(options, :paths),
        path <- Path.wildcard(path) do
      Code.prepend_path(path)
    end

    Mix.shell().info("Generating docs...")
    generated_docs = generator.(project, version, source_beams, options)

    Enum.each(generated_docs, fn %{entrypoint: entrypoint, formatter: formatter} ->
      extension = formatter_module_to_extension(formatter)
      Mix.shell().info([:green, "View #{extension} docs at #{inspect(entrypoint)}"])
    end)

    open? = Keyword.get(cli_opts, :open, false)

    with [%{entrypoint: entrypoint} | _] when open? <- generated_docs do
      browser_open(entrypoint)
    end

    warned = Enum.filter(generated_docs, & &1.warned?)

    if options[:warnings_as_errors] == true and warned != [] do
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

  defp normalize_formatters(options) do
    formatters =
      case Keyword.get_values(options, :formatter) do
        [] -> options[:formatters] || ["html", "markdown", "epub"]
        values -> values
      end

    options
    |> Keyword.delete(:formatter)
    |> Keyword.put(:formatters, formatters)
  end

  defp get_docs_opts(config) do
    docs = config[:docs]

    cond do
      is_function(docs, 0) -> docs.()
      is_nil(docs) -> []
      true -> docs
    end
  end

  defp normalize_source_url(options, config) do
    if source_url = config[:source_url] do
      Keyword.put(options, :source_url, source_url)
    else
      options
    end
  end

  defp normalize_homepage_url(options, config) do
    if homepage_url = config[:homepage_url] do
      Keyword.put(options, :homepage_url, homepage_url)
    else
      options
    end
  end

  defp normalize_description(options, config) do
    if description = config[:description] do
      Keyword.put(options, :description, description)
    else
      options
    end
  end

  defp source_beams(options, config) do
    if Mix.Project.umbrella?(config) do
      umbrella_compile_paths(Keyword.get(options, :ignore_apps, []))
    else
      [Mix.Project.compile_path()]
    end
  end

  defp umbrella_compile_paths(ignored_apps) do
    build = Mix.Project.build_path()

    for {app, _} <- Mix.Project.apps_paths(),
        app not in ignored_apps do
      Path.join([build, "lib", Atom.to_string(app), "ebin"])
    end
  end

  defp normalize_apps(options, config) do
    if Mix.Project.umbrella?(config) do
      ignore = Keyword.get(options, :ignore_apps, [])

      apps =
        for {app, _} <- Mix.Project.apps_paths(), app not in ignore do
          app
        end

      Keyword.put(options, :apps, Enum.sort(apps))
    else
      Keyword.put(options, :apps, List.wrap(config[:app]))
    end
  end

  defp normalize_main(options) do
    main = options[:main]

    cond do
      is_nil(main) ->
        Keyword.delete(options, :main)

      is_atom(main) ->
        Keyword.put(options, :main, inspect(main))

      is_binary(main) ->
        options
    end
  end

  defp normalize_deps(options) do
    user_deps = Keyword.get(options, :deps, [])

    deps =
      for {app, doc} <- Keyword.merge(get_deps(), user_deps),
          lib_dir = :code.lib_dir(app),
          is_list(lib_dir),
          do: {app, doc}

    Keyword.put(options, :deps, deps)
  end

  defp get_deps do
    for {key, _} <- Mix.Project.deps_paths(),
        _ = Application.load(key),
        vsn = Application.spec(key, :vsn) do
      {key, "https://hexdocs.pm/#{key}/#{vsn}/"}
    end
  end

  defp put_package(options, config) do
    if package = config[:package] do
      Keyword.put(options, :package, package[:name] || config[:app])
    else
      options
    end
  end

  defp browser_open(path) do
    {cmd, args, options} =
      case :os.type() do
        {:win32, _} ->
          dirname = Path.dirname(path)
          basename = Path.basename(path)
          {"cmd", ["/c", "start", basename], [cd: dirname]}

        {:unix, :darwin} ->
          {"open", [path], []}

        {:unix, _} ->
          {"xdg-open", [path], []}
      end

    System.cmd(cmd, args, options)
  end
end
