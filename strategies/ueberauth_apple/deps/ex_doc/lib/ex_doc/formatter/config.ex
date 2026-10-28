defmodule ExDoc.Formatter.Config do
  @moduledoc """
  Configuration used by formatters.

  Contains project metadata, output settings, and various
  customization options for generating documentation.
  """

  @doc false
  def before_closing_head_tag(_), do: ""
  @doc false
  def before_closing_footer_tag(_), do: ""
  @doc false
  def before_closing_body_tag(_), do: ""
  @doc false
  def skip_undefined_reference_warnings_on(_string), do: false
  @doc false
  def skip_code_autolink_to(_string), do: false

  defstruct output: "./doc",
            project: nil,
            version: nil,
            main: "api-reference",
            api_reference: true,
            canonical: nil,
            redirects: %{},
            assets: %{},
            logo: nil,
            cover: nil,
            favicon: nil,
            extra_section: "Pages",
            footer: true,
            formatters: [],
            search: [%{name: "Default", help: "In-browser search", url: "search.html?q="}],
            homepage_url: nil,
            source_url: nil,
            language: "en",
            proglang: :elixir,
            authors: nil,
            package: nil,
            title: nil,
            description: nil,
            nest_modules_by_prefix: [],
            before_closing_head_tag: &__MODULE__.before_closing_head_tag/1,
            before_closing_body_tag: &__MODULE__.before_closing_body_tag/1,
            before_closing_footer_tag: &__MODULE__.before_closing_footer_tag/1,
            # Autolink fields
            apps: [],
            deps: [],
            skip_undefined_reference_warnings_on:
              &__MODULE__.skip_undefined_reference_warnings_on/1,
            skip_code_autolink_to: &__MODULE__.skip_code_autolink_to/1

  @type t :: %__MODULE__{
          output: Path.t(),
          project: nil | String.t(),
          version: nil | String.t(),
          main: nil | String.t(),
          api_reference: boolean(),
          canonical: nil | String.t(),
          redirects: %{optional(String.t()) => String.t()} | [{String.t(), String.t()}],
          assets: %{binary() => binary()},
          logo: nil | Path.t(),
          cover: nil | Path.t(),
          favicon: nil | Path.t(),
          extra_section: String.t(),
          footer: boolean(),
          formatters: [String.t()],
          search: [%{name: String.t(), help: String.t(), url: String.t()}],
          homepage_url: nil | String.t(),
          source_url: nil | String.t(),
          language: String.t(),
          authors: nil | [String.t()],
          package: :atom | nil,
          title: nil | String.t(),
          description: nil | String.t(),
          nest_modules_by_prefix: [String.t()],
          before_closing_head_tag: (atom() -> String.t()) | mfa() | map(),
          before_closing_body_tag: (atom() -> String.t()) | mfa() | map(),
          before_closing_footer_tag: (atom() -> String.t()) | mfa() | map(),
          apps: [atom()],
          deps: [{ebin_path :: String.t(), doc_url :: String.t()}],
          skip_undefined_reference_warnings_on: (String.t() -> boolean),
          skip_code_autolink_to: (String.t() -> boolean),
          proglang: :elixir | :erlang
        }

  @doc false
  def build(project, version, options) do
    output = Keyword.get(options, :output, "./doc")
    nest_modules_by_prefix = Keyword.get(options, :nest_modules_by_prefix, [])
    proglang = Keyword.get(options, :proglang, :elixir)

    skip_undefined_reference_warnings_on =
      Keyword.get(
        options,
        :skip_undefined_reference_warnings_on,
        &skip_undefined_reference_warnings_on/1
      )

    skip_code_autolink_to =
      Keyword.get(options, :skip_code_autolink_to, &skip_code_autolink_to/1)

    search = Keyword.get(options, :search, [])

    before_closing_head_tag =
      Keyword.get(options, :before_closing_head_tag, &before_closing_head_tag/1)

    before_closing_body_tag =
      Keyword.get(options, :before_closing_body_tag, &before_closing_body_tag/1)

    before_closing_footer_tag =
      Keyword.get(options, :before_closing_footer_tag, &before_closing_footer_tag/1)

    preconfig = %__MODULE__{
      nest_modules_by_prefix: normalize_nest_modules_by_prefix(nest_modules_by_prefix),
      output: normalize_output(output),
      proglang: normalize_proglang(proglang),
      project: project,
      search: normalize_search(search),
      skip_undefined_reference_warnings_on:
        normalize_skip_list_function(skip_undefined_reference_warnings_on),
      skip_code_autolink_to: normalize_skip_list_function(skip_code_autolink_to),
      before_closing_head_tag: normalize_callback(before_closing_head_tag),
      before_closing_body_tag: normalize_callback(before_closing_body_tag),
      before_closing_footer_tag: normalize_callback(before_closing_footer_tag),
      version: version
    }

    formatter_options =
      Keyword.take(options, [
        :main,
        :api_reference,
        :canonical,
        :redirects,
        :assets,
        :logo,
        :cover,
        :favicon,
        :extra_section,
        :footer,
        :formatters,
        :homepage_url,
        :source_url,
        :language,
        :authors,
        :package,
        :title,
        :description,
        :apps,
        :deps
      ])

    config = struct!(preconfig, formatter_options)

    if not is_map(config.assets) do
      raise ArgumentError,
            ":assets configuration in ExDoc expects a map from %{source => target}, got: #{config.assets}"
    end

    config
  end

  # Helper functions

  defp normalize_output(output) do
    Path.expand(String.trim_trailing(output, "/"))
  end

  defp normalize_proglang(binary) when is_binary(binary) do
    binary |> String.to_atom() |> normalize_proglang()
  end

  defp normalize_proglang(proglang) when proglang in [:elixir, :erlang] do
    proglang
  end

  defp normalize_proglang(proglang) do
    raise ArgumentError, "#{inspect(proglang)} is not supported"
  end

  defp normalize_nest_modules_by_prefix(nest_modules_by_prefix) do
    nest_modules_by_prefix
    |> Enum.map(&inspect_atoms/1)
    |> Enum.sort()
    |> Enum.reverse()
  end

  defp inspect_atoms(atom) when is_atom(atom), do: inspect(atom)
  defp inspect_atoms(binary) when is_binary(binary), do: binary

  defp normalize_skip_list_function(strings) when is_list(strings),
    do: &(&1 in strings)

  defp normalize_skip_list_function(fun) when is_function(fun, 1),
    do: fun

  defp normalize_callback({m, f, a}) do
    fn module -> apply(m, f, [module | a]) end
  end

  defp normalize_callback(callback) when is_map(callback) do
    fn module -> Map.get(callback, module, "") end
  end

  defp normalize_callback(callback) when is_function(callback, 1) do
    callback
  end

  defp normalize_search([]) do
    [%{name: "Default", help: "In-browser search", url: "search.html?q="}]
  end

  defp normalize_search(search) when is_list(search) do
    Enum.map(search, fn
      %{packages: _, url: _} ->
        raise ArgumentError, "search must provide either :url or :packages, but not both"

      %{url: url} = engine when not is_binary(url) ->
        bad_search!(engine)

      %{name: name, help: help} = engine
      when is_binary(name) and is_binary(help) ->
        engine
        |> Map.delete(:packages)
        |> Map.put_new_lazy(:url, fn ->
          if packages = engine[:packages] do
            "https://hexdocs.pm/?packages=#{normalize_package_search(packages)}&q="
          else
            "search.html?q="
          end
        end)

      other ->
        bad_search!(other)
    end)
  end

  defp normalize_search(other) do
    raise ArgumentError, "search must be a list of maps, got: #{inspect(other)}"
  end

  defp normalize_package_search([]) do
    raise ArgumentError, ":packages requires a non-empty list"
  end

  defp normalize_package_search(packages) do
    packages
    |> Enum.map_join(",", fn
      package when is_atom(package) ->
        "#{package}:latest"

      {package, version} when is_atom(package) and is_binary(version) ->
        "#{package}:#{version}"

      other ->
        raise ArgumentError,
              "entries in :packages must be either a package name or a package-version tuple, got: #{inspect(other)}"
    end)
    |> URI.encode_www_form()
  end

  defp bad_search!(other) do
    raise ArgumentError,
          """
          search entries must be a map with:

            * required :name as string
            * required :help as string
            * optional :url as a string
            * optional :packages as a non-empty list of packages and versions

          got: #{inspect(other)}
          """
  end
end
