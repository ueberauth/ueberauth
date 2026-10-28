defmodule ExDoc do
  @moduledoc """
  Main entry point for generating docs.
  """
  @ex_doc_version Mix.Project.config()[:version]

  @doc """
  Returns the ExDoc version (used in templates).
  """
  @spec version :: String.t()
  def version, do: @ex_doc_version

  @doc """
  Emits a warning.
  """
  def warn(message, stacktrace_info) do
    :persistent_term.put({__MODULE__, :warned?}, true)
    IO.warn(message, stacktrace_info)
  end

  defp unset_warned() do
    warned? = :persistent_term.get({__MODULE__, :warned?}, false)
    :persistent_term.erase({__MODULE__, :warned?})
    warned?
  end

  @doc ~S"""
  Generates documentation for the given `project`, `vsn` (version),
  `source_beams` directories, and `options`.

  By default it generates HTML, Markdown, and EPUB documents.

  ## Options

    * `:annotations_for_docs` - a function that receives metadata and returns a list
      of annotations to be added to the signature. The metadata received will also
      contain `:module`, `:name`, `:arity` and `:kind` to help identify which entity is
      currently being processed.

    * `:api_reference` - Whether to generate `api-reference.html`; default: `true`.
      If this is set to false, `:main` must also be set.

    * `:assets` - A map of source => target directories that will be copied as is to
      the output path. It defaults to an empty map.

    * `:authors` - List of authors for the generated docs or epub.

    * `:before_closing_body_tag` - a function that takes as argument an atom specifying
      the formatter being used (`:html` or `:epub`) and returns a literal HTML string
      to be included just before the closing body tag (`</body>`).
      The atom given as argument can be used to include different content in both formats.
      Useful to inject custom assets, such as Javascript.

    * `:before_closing_head_tag` - a function that takes as argument an atom specifying
      the formatter being used (`:html` or `:epub`) and returns a literal HTML string
      to be included just before the closing head tag (`</head>`).
      The atom given as argument can be used to include different content in both formats.
      Useful to inject custom assets, such as CSS stylesheets.

    * `:before_closing_footer_tag` - a function that takes as argument an atom specifying
      the formatter being used (`:html`) and returns a literal HTML string
      to be included just before the closing footer tag (`</footer>`).
      This option only has effect on the html formatter.
      Useful if you want to inject an extra footer into the documentation.

    * `:canonical` - String that defines the preferred URL with the rel="canonical"
      element; defaults to no canonical path.

    * `:cover` - Path to the epub cover image (only PNG or JPEG accepted)
      The image size should be around 1600x2400. When specified, the cover will be placed under
      the "assets" directory in the output path under the name "cover" and the
      appropriate extension. This option has no effect when using the "html" formatter.

    * `:deps` - A keyword list application names and their documentation URL.
      ExDoc will by default include all dependencies and assume they are hosted on
      HexDocs. This can be overridden by your own values. Example: `[plug: "https://myserver/plug/"]`

    * `:description` - A brief description of the project, currently included in Hex.pm and the generated
      `llms.txt` file

    * `:extra_section` - String that defines the section title of the additional
      Markdown and plain text pages; default: "Pages". Example: "Guides"

    * `:extras` - List of paths to additional Markdown (`.md` extension), Live Markdown
      (`.livemd` extension), Cheatsheets (`.cheatmd` extension), external urls (`:url` option),
      and plain text pages to add to the documentation. You can also specify keyword pairs to
      customize the generated filename, title and source file, and search content of each extra page;
      default: `[]`. Example: `["README.md", "LICENSE", "CONTRIBUTING.md": [filename: "contributing",
      title: "Contributing", source: "CONTRIBUTING.mdx"]]` See the Customizing Extras section for
      more.

    * `:favicon` - Path to a favicon image file for the project. Must be PNG, JPEG or SVG. When
      specified, the image file will be placed in the output "assets" directory, named
      "favicon.EXTENSION". If using SVG, ensure appropriate width, height and viewBox attributes
      are present in order to ensure predictable sizing and cropping.

    * `:filter_modules` - Include only modules that match the given value. The
      value can be a regex, a string (representing a regex), or a two-arity
      function that receives the module and its metadata and returns true if the
      module must be included. If a string or a regex is given, it will be matched
      against the complete module name (which includes the "Elixir." prefix for
      Elixir modules). If a module has `@moduledoc false`, then it is always excluded.

    * `:formatters` - Formatter to use; default: ["html", "markdown", "epub"], options: "html", "markdown", "epub".

    * `:footer` - When false, does not render the footer on all pages, except for
      the required "Built with ExDoc" note.

    * `:groups_for_extras`, `:groups_for_modules`, `:groups_for_docs`, and `:default_group_for_doc` -
      See the "Groups" section.

    * `:ignore_apps` - Apps to be ignored when generating documentation in an umbrella project.
      Receives a list of atoms. Example: `[:first_app, :second_app]`.

    * `:language` - Identify the primary language of the documents, its value must be
      a valid [BCP 47](https://tools.ietf.org/html/bcp47) language tag. Default: "en".

    * `:logo` - Path to a logo image file for the project. Must be PNG, JPEG or SVG. When
      specified, the image file will be placed in the output "assets" directory, named
      "logo.EXTENSION". The image will be shown within a 48x48px area. If using SVG, ensure
      appropriate width, height and viewBox attributes are present in order to ensure
      predictable sizing and cropping.

    * `:main` - Main page of the documentation. It may be a module or a
      generated page, like "Plug" or "api-reference". Default: "api-reference".

    * `:markdown_processor` - The markdown processor to use,
      either `module()` or `{module(), keyword()}` to provide configuration options.

    * `:nest_modules_by_prefix` - See the "Nesting" section.

    * `:output` - Output directory for the generated docs. Default: "doc".
      May be overridden by command line argument.

    * `:redirects` - A map or list of tuples, where the key is the path to redirect from and the
       value is the path to redirect to. The extension is omitted in both cases, i.e `%{"old-readme" => "readme"}`.
       The destination may include an anchor, i.e `%{"old-readme" => "readme#section"}`.
       See the "Changing documentation over time" section below for more.

    * `:search` - A list of search engine configurations. See the "Search engines" section.

    * `:skip_undefined_reference_warnings_on` - ExDoc warns when it can't create a `Mod.fun/arity`
      reference in the current project docs (for example, because of a typo). This option controls when to
      skip such warnings. This option can be a list of strings that will be checked for exact matches,
      or a function that takes a *reference* and must return a boolean (`true` means "skip this").
      *References* that are checked against this option (either whether they're in the given
      list or whether they match the given function) are the relative filename, the "ID" of
      the node (like `User.exists?/1`), or the module name. Examples for this option:
        * `["Foo", "Bar.baz/0"]` - skip warnings for `Foo` and `Bar.baz/0`
        * `&String.match?(&1, ~r/Foo/)` - skip warnings for any reference that matches the regex
        * `["pages/deprecations.md"]` - skip warnings for any reference in the
          `pages/deprecations.md` file

    * `:skip_code_autolink_to` - Similar to `:skip_undefined_reference_warnings_on`, this option
      controls which terms will be skipped by ExDoc when building documentation.
      Useful for example if you want to highlight private modules or functions without warnings.
      This option can be a function from a term to a boolean (e.g.: `&String.match?(&1, ~r/PrivateModule/)`)
      or a list of terms (e.g.:`["PrivateModule", "PrivateModule.func/1"]`);
      default is nothing to be skipped.

    * `:source_beam` - Path to the beam directory; default: mix's compile path.

    * `:source_url` - The source URL fallback if `:source_url` is not given at the project
      configuration. See the following sections.

    * `:source_ref` - The branch/commit/tag used for source link inference.
      Default: "main".

    * `:source_url_pattern` - Public URL of the project for source links. This is derived
      automatically from the project's `:source_url` and `:source_ref` when using one of
      the supported public hosting services (currently GitHub, GitLab, or Bitbucket). If
      you are using one of those services with their default public hostname, you do not
      need to set this configuration.

      However, if using a different solution, or self-hosting, you will need to set this
      configuration variable to a pattern for source code links. The value must be a string or
      a function.

      If a string, then it should be the full URI to use for links with the following
      variables available for interpolation:

        * `%{path}`: the path of a file in the repo
        * `%{line}`: the line number in the file

      For self-hosted GitLab/GitHub:

      ```text
      https://mydomain.org/user_or_team/repo_name/blob/main/%{path}#L%{line}
      ```

      For self-hosted Bitbucket:

      ```text
      https://mydomain.org/user_or_team/repo_name/src/main/%{path}#cl-%{line}
      ```

      If a function, then it must be a function that takes two arguments, path and line,
      where path is either an relative path from the cwd, or an absolute path. The function
      must return the full URI as it should be placed in the documentation.

  ### Using `:source_url` and `:source_ref` together

  A common setup for a project or library is to set both `:source_url` and `:source_ref`. Setting
  both of them will allow ExDoc to link to a specific version of the code for a function or module
  that matches the version of the docs. If the docs have been generated for version 1.0.5,
  clicking on the source link in the docs will take the browser to the source code for the 1.0.5
  version of the code instead of the primary ref (for example, `main`).

  An example setup:

      @version "0.30.10"
      def project do
        [
          ...
          version: @version,
          source_url: "https://github.com/USER/PROJECT",
          docs: &docs/0
        ]
      end

      def docs do
        [
          ...
          source_ref: "v#{@version}"
        ]
      end

  If you use `source_ref: "v#{@version}"`, you should run `git tag vVERSION` and push the tag when
  publishing a new version of your package; ExDoc will generate links to the specific version for
  which the docs were generated.

  ## Additional pages (extras)

  It is possible to attach additional pages to the documentation. Markdown extensions (and variations)
  such as `.md`, `.livemd`, and `.cheatmd` rendered by extension. Other extensions are added as is.

  When specifying extras, the allowed configuration is:

    * `:title` - The title of the extra page. If not provided, the title will be inferred from the filename.
    * `:filename` - The name of the generated file. If not provided, the filename will be inferred from
       the source file.
    * `:source` - The source file of the extra page. This is useful if you want to customize the filename or
       title but keep the source file unchanged.
    * `:search_data` - A list of terms to be indexed for autocomplete and search. If not provided, the content
       of the extra page will be indexed for search. See the section below for more.

  It is also possible to specify URLs, which are added as links to the sidebar:

    * `:title` - The title of the extra page. If not provided, the title will be inferred from the extra name.
    * `:url` - The external url to link to from the sidebar.

  ### Customizing search data

  It is possible to fully customize the way a given extra is indexed, both in autocomplete and in search.
  In most cases, this makes sense for _generated_ documentation. If `search_data` is provided, it completely
  overrides the built in logic for indexing your document based on the headers and content of the document.
  The following fields can be provided in a list of maps for `search_data`.

    * `:anchor` - The anchor link for the search result. Use `""` to point to the top of the page.
    * `:title` - The title of the result.
    * `:type` - The type of the search result, such as "module", "function" or "section".
    * `:body` - The main content or body of the search result, _as markdown_. Used in search, not autocomplete.

  ## Groups

  ExDoc content can be organized in groups. This is done via the `:groups_for_extras`
  and `:groups_for_modules`. For example, imagine you are storing extra guides in
  your documentation which are organized per directory. In the extras section you
  have:

      extras: [
        "guides/introduction/foo.md",
        "guides/introduction/bar.md",

        ...

        "guides/advanced/baz.md",
        "guides/advanced/bat.md"
      ]

  You can have those grouped as follows:

      groups_for_extras: [
        "Introduction": Path.wildcard("guides/introduction/*.md"),
        "Advanced": Path.wildcard("guides/advanced/*.md")
      ]

  Or via a regex:

      groups_for_extras: [
        "Introduction": ~r"/introduction/",
        "Advanced": ~r"/advanced/"
      ]

  External extras from a URL can also be grouped:

      groups_for_extras: [
        "Elixir": ~r"https://elixir-lang.org/",
        "Erlang": ~r"https://www.erlang.org/"
      ]

  Similar can be done for modules:

      groups_for_modules: [
        "Data types": [Atom, Regex, URI],
        "Collections": [Enum, MapSet, Stream]
      ]

  A regex or the string name of the module is also supported.

  ### Grouping functions, types, and callbacks

  Types, functions, and callbacks inside a module can also be organized in groups.

  #### Group metadata

  By default, ExDoc respects the `:group` metadata field to determine in which
  group an element belongs:

      @doc group: "Queries"
      def get_by(schema, fields)

  The function above will be automatically listed under the "Queries" section in
  the sidebar. The benefit of using `:group` is that it can also be used by tools
  such as IEx during autocompletion. These groups are then displayed in the sidebar.

  It is also possible to tell ExDoc to either enrich the group metadata or lookup a
  different field via the `:default_group_for_doc` configuration. The default is:

      default_group_for_doc: fn metadata -> metadata[:group] end

  The `metadata` received contains all of the documentation metadata, such as `:group`,
  but also `:module`, `:name`, `:arity` and `:kind` to help identify which entity is
  currently being processed. For example, projects like Nx have a custom function that
  converts "Queries" into "Function: Queries":

      default_group_for_doc: fn metadata ->
        if group = metadata[:group] do
          "Functions: #{group}"
        end
      end

  Finally, you can also use the `:groups_for_docs` which works similarly as the
  one for modules/extra pages.

  `:groups_for_docs` is a keyword list of group titles and filtering functions
  that receive the documentation metadata and must return a boolean.
  For example, imagine that you have an API client library with a large surface
  area for all the API endpoints you need to support. It would be helpful to
  group the functions with similar responsibilities together. In this case in
  your module you might have:

      defmodule APIClient do
        @doc section: :auth
        def refresh_token(params \\ [])

        @doc subject: :object
        def update_status(id, new_status)

        @doc permission: :grant
        def grant_privilege(resource, privilege)
      end

  And then in the configuration you can group these with:

      groups_for_docs: [
        Authentication: & &1[:section] == :auth,
        Resource: & &1[:subject] == :object,
        Admin: & &1[:permission] in [:grant, :write]
      ]

  A function can belong to a single group only. The first group that matches
  will be the one used. In case no group is found in `:groups_for_docs`,
  the `:default_group_for_doc` callback is invoked. If it returns nil, it
  then falls back to the appropriate "Functions", "Types" or "Callbacks"
  section respectively.

  #### Group descriptions

  It is possible to display a description for each group under its respective section
  in a module's page. This helps to better explain what is the intended usage of each
  group elements instead of describing everything in the displayed `@moduledoc`.

  Descriptions can be provided as `@moduledoc` metadata. Groups without descriptions are
  also supported to define group ordering.

      @moduledoc groups: [
        "Main API",
        %{title: "Helpers", description: "Functions shared with other modules."}
      ]

  Descriptions can also be given in the `:default_group_for_doc` configuration:

      default_group_for_doc: fn metadata ->
        case metadata[:group] do
          :main_api -> "Main API"
          :helpers -> [title: "Helpers", description: "Functions shared with other modules."]
          _ -> nil
        end
      end

  Keyword lists or maps are supported in either case.

  When using `:groups_for_docs`, if all the elements for a given group are matched then the
  `:default_group_for_doc` is never invoked and ExDoc will not know about the description.
  In that case, the description should be provided in the `@moduledoc` `:groups` metadata.

  Whenever using the `:group` key, the groups will be ordered alphabetically.
  If you also want control over the group order, you can also use the `:groups_for_docs`
  which works similarly as the one for modules/extra pages.

  #### Group ordering

  Groups in the sidebar and main page body are ordered according to the following
  rules:

    * First, groups defined as `@moduledoc groups: [...]` in the given order.
    * Then groups defined as keys in the `:groups_for_docs` configuration.
    * Then default groups: Types, Callbacks and Functions.
    * Finally, other groups returned by `:default_group_for_doc` by alphabetical order.

  ## Nesting

  ExDoc also allows module names in the sidebar to appear nested under a given
  prefix. The `:nest_modules_by_prefix` expects a list of module names, such as
  `[Foo.Bar, Bar.Baz]`. In this case, a module named `Foo.Bar.Baz` will appear
  nested within `Foo.Bar` and only the name `Baz` will be shown in the sidebar.
  Note the `Foo.Bar` module itself is not affected.

  This option is mainly intended to improve the display of long module names in
  the sidebar, particularly when they are too long for the sidebar or when many
  modules share a long prefix. If you mean to group modules logically or call
  attention to them in the docs, you should probably use `:groups_for_modules`
  (which can be used in conjunction with `:nest_modules_by_prefix`).

  ## HTML-specific configuration

  ### Search engines

  ExDoc allows custom search engines via the `:search` key. Each search engine
  is a map with the following keys:

    * `:name` - The display name of the search engine (required)
    * `:help` - A help text describing what the search engine does (required)
    * `:url` - The optional search URL template, usually ending with `q=`
    * `:packages` - An optional list of packages (or package-versions) to search on
      https://hexdocs.pm. For example: `[:plug, :phoenix, ecto: "3.0.0", ecto_sql: "3.0.0"]`.
      If no version is specified, it uses the package latest

  If none of `:url` or `:packages` are given, ExDoc will use its default search engine
  powered by Lunr.

  When multiple search engines are configured, a dropdown selector will appear next to
  the search bar allowing users to choose which engine to use. For example:

      search: [
        %{name: "FooBar", help: "Search on FooBar", url: "https://example.com/?q="},
        %{name: "Local", help: "In-browser search"}
      ]

  If only one search engine is configured, the dropdown selector will be hidden.
  If no search engine is configured, only the built-in Lunr's is shown.

  ### Redirects and changing documentation over time

  As your project grows, your documentation may change, perhaps even structurally.
  There are a few important things to consider in this regard:

    * Links to your *extras* will break if you change or move file names.
    * Links to your *modules, and mix tasks* will change if you change their name.
    * Links to *functions* are actually links to modules with anchor links.
      If you change the function name, the link does not break but will leave users
      at the top of the module's documentation.

  Because these docs are static files, the behaviour of a missing page will depend on where
  they are hosted. In particular, [hexdocs.pm](https://hexdocs.pm) will show a 404 page.

  You can improve the developer experience on everything but function names changing
  by using the `redirects` configuration. For example, if you changed the module `MyApp.MyModule`
  to `MyApp.My.Module` and the extra `get-started.md` to `quickstart.md`, you can
  setup the following redirects:

      redirects: %{
        "MyApp.MyModule" => "MyApp.My.Module",
        "get-started" => "quickstart"
      }

  The destination may also include an anchor to redirect to a specific section:

      redirects: %{
        "old-page" => "new-page#relevant-section"
      }

  ### Meta tags configuration

  It is also possible to configure some of ExDoc's behaviour using meta tags.

    * `exdoc:autocomplete` - when set to "off", disables autocompletion.

    * `exdoc:autocomplete-limit` - Set to an integer to configure how many results
      appear in the autocomplete dropdown. Defaults to 10.

  You can insert meta tags using the `before_closing_head_tag` option.

  ### Version dropdown menu

  ExDoc will automatically render a version dropdown on HTML pages if a
  `docs_config.js` file is placed within the documentation.
  This file may define the following global variables in JavaScript:

    * `versionNodes` - an array of `{"version":"vNUMBER", "url":url}` listing
      all documented versions and their URLs. ExDoc will automatically match
      the version of the package with the one in the array to mark as current.
  """
  @spec generate(String.t(), String.t(), [Path.t()], Keyword.t()) ::
          [%{entrypoint: String.t(), warned?: boolean(), formatter: module()}]
  def generate(project, version, source_beams, options)
      when is_binary(project) and is_binary(version) and is_list(source_beams) and
             is_list(options) do
    # Clear it up for tests
    _ = unset_warned()

    retriever = Keyword.get(options, :retriever, ExDoc.Retriever)
    extras_input = Keyword.get(options, :extras, [])

    # Build configs independently (build both upfront for validation)
    retriever_config = ExDoc.Config.build(options)
    formatter_config = ExDoc.Formatter.Config.build(project, version, options)

    # Retriever phase (run once for all formatters)
    {modules, filtered} = retriever.docs_from_dir(source_beams, retriever_config)
    extras = ExDoc.Extras.build(extras_input, retriever_config)

    for formatter <- formatter_config.formatters do
      formatter = find_formatter(formatter)
      entrypoint = ExDoc.Formatter.run(formatter, formatter_config, modules, filtered, extras)
      %{entrypoint: entrypoint, warned?: unset_warned(), formatter: formatter}
    end
  end

  defp find_formatter(modname) when is_atom(modname),
    do: modname

  defp find_formatter("ExDoc.Formatter." <> _ = name),
    do: Module.concat([name])

  defp find_formatter(name),
    do: Module.concat([ExDoc.Formatter, String.upcase(name)])
end
