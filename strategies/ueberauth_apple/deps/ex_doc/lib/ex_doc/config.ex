defmodule ExDoc.Config do
  # Config used by retriever and extras
  @moduledoc false

  # Defaults
  @default_source_ref "main"
  def default_group_for_doc(metadata), do: metadata[:group]
  def filter_modules(_module, _metadata), do: true
  def annotations_for_docs(_), do: []
  def source_url_pattern(_, _), do: nil

  defstruct filter_modules: &__MODULE__.filter_modules/2,
            groups_for_modules: [],
            group_for_doc: &__MODULE__.default_group_for_doc/1,
            annotations_for_docs: &__MODULE__.annotations_for_docs/1,
            docs_groups: [],
            source_ref: @default_source_ref,
            groups_for_extras: [],
            source_url_pattern: &__MODULE__.source_url_pattern/2,
            nest_modules_by_prefix: [],
            proglang: :elixir,
            markdown_processor: {ExDoc.Markdown.Earmark, []}

  @type t :: %__MODULE__{
          filter_modules: (module, map -> boolean),
          groups_for_modules: [{binary(), term()}],
          group_for_doc: (keyword() -> String.t() | nil),
          annotations_for_docs: (map() -> list()),
          docs_groups: [String.t()],
          source_ref: nil | String.t(),
          groups_for_extras: [{binary(), term()}],
          source_url_pattern: (String.t(), integer() -> String.t() | nil),
          nest_modules_by_prefix: [String.t()],
          proglang: :elixir | :erlang,
          markdown_processor: {module(), keyword()} | module()
        }

  def build(options) do
    proglang = Keyword.get(options, :proglang, :elixir)
    filter_modules = Keyword.get(options, :filter_modules, &filter_modules/2)
    nest_modules_by_prefix = Keyword.get(options, :nest_modules_by_prefix, [])

    options =
      if groups_for_functions = options[:groups_for_functions] do
        IO.warn(":groups_for_functions is deprecated, please use :groups_for_docs instead")
        Keyword.put_new(options, :groups_for_docs, groups_for_functions)
      else
        options
      end

    apps = Keyword.get(options, :apps, [])

    groups_for_docs = Keyword.get(options, :groups_for_docs, [])
    groups_for_extras = Keyword.get(options, :groups_for_extras, [])

    groups_for_modules =
      Keyword.get(options, :groups_for_modules, default_groups_for_modules(apps))

    default_group_for_doc =
      Keyword.get(options, :default_group_for_doc, &default_group_for_doc/1)

    source_url_pattern =
      Keyword.get_lazy(options, :source_url_pattern, fn ->
        guess_url(options[:source_url], options[:source_ref] || @default_source_ref)
      end)

    preconfig = %__MODULE__{
      filter_modules: normalize_filter_modules(filter_modules),
      docs_groups: for({group, _} <- groups_for_docs, do: to_string(group)),
      group_for_doc: normalize_groups_for_docs(groups_for_docs, default_group_for_doc),
      groups_for_extras: normalize_groups(groups_for_extras),
      groups_for_modules:
        normalize_groups(
          # TODO: The default module groups must be returned by the language
          groups_for_modules ++
            [Deprecated: &deprecated?/1, Exceptions: &exception?/1]
        ),
      nest_modules_by_prefix: normalize_nest_modules_by_prefix(nest_modules_by_prefix),
      proglang: normalize_proglang(proglang),
      source_url_pattern: normalize_source_url_pattern(source_url_pattern)
    }

    retriever_options =
      Keyword.take(options, [
        :annotations_for_docs,
        :markdown_processor,
        :source_ref
      ])

    struct!(preconfig, retriever_options)
  end

  # Helper functions

  defp normalize_proglang(binary) when is_binary(binary) do
    binary |> String.to_atom() |> normalize_proglang()
  end

  defp normalize_proglang(proglang) when proglang in [:elixir, :erlang] do
    proglang
  end

  defp normalize_proglang(proglang) do
    raise ArgumentError, "#{inspect(proglang)} is not supported"
  end

  defp normalize_filter_modules(string) when is_binary(string),
    do: normalize_filter_modules(Regex.compile!(string))

  defp normalize_filter_modules(%Regex{} = regex),
    do: fn module, _ -> Atom.to_string(module) =~ regex end

  defp normalize_filter_modules(fun) when is_function(fun, 2),
    do: fun

  defp normalize_groups_for_docs(groups, default) do
    groups = normalize_groups(groups)

    fn metadata ->
      Enum.find_value(groups, fn {group, function} ->
        function.(metadata) && group
      end) || default.(metadata)
    end
  end

  defp normalize_groups(groups) do
    for {k, v} <- groups, do: {to_string(k), v}
  end

  defp normalize_nest_modules_by_prefix(nest_modules_by_prefix) do
    nest_modules_by_prefix
    |> Enum.map(&inspect_atoms/1)
    |> Enum.sort()
    |> Enum.reverse()
  end

  defp inspect_atoms(atom) when is_atom(atom), do: inspect(atom)
  defp inspect_atoms(binary) when is_binary(binary), do: binary

  defp deprecated?(metadata), do: metadata[:deprecated] != nil
  defp exception?(metadata), do: metadata[:kind] == :exception

  defp normalize_source_url_pattern(function) when is_function(function, 2), do: function
  defp normalize_source_url_pattern(nil), do: &source_url_pattern/2

  defp normalize_source_url_pattern(binary) when is_binary(binary) do
    case :binary.split(binary, "%{path}") do
      [left, right] ->
        case :binary.split(left, "%{line}") do
          [line_left, line_right] ->
            fn path, line ->
              line_left <> Integer.to_string(line) <> line_right <> path <> right
            end

          [_] ->
            case :binary.split(right, "%{line}") do
              [line_left, line_right] ->
                fn path, line ->
                  left <> path <> line_left <> Integer.to_string(line) <> line_right
                end

              [_] ->
                fn path, _ -> left <> path <> right end
            end
        end

      [_] ->
        case :binary.split(binary, "%{line}") do
          [left, right] ->
            fn _, line -> left <> Integer.to_string(line) <> right end

          [_] ->
            fn _, _ -> binary end
        end
    end
  end

  defp normalize_source_url_pattern(other) do
    raise ArgumentError,
          ":source_url_pattern must be a string, a two-arity function or nil, got: #{inspect(other)}"
  end

  defp guess_url(url, ref) do
    with {:ok, host_with_path} <- http_or_https(url),
         {:ok, pattern} <- known_pattern(host_with_path, ref) do
      "https://" <> append_slash(host_with_path) <> pattern
    else
      _ -> url
    end
  end

  defp http_or_https("http://" <> rest),
    do: {:ok, rest}

  defp http_or_https("https://" <> rest),
    do: {:ok, rest}

  defp http_or_https(_),
    do: :error

  defp known_pattern("github.com/" <> _, ref),
    do: {:ok, "blob/#{ref}/%{path}#L%{line}"}

  defp known_pattern("gitlab.com/" <> _, ref),
    do: {:ok, "blob/#{ref}/%{path}#L%{line}"}

  defp known_pattern("bitbucket.org/" <> _, ref),
    do: {:ok, "src/#{ref}/%{path}#cl-%{line}"}

  defp known_pattern(_host_with_path, _ref),
    do: :error

  defp append_slash(url) do
    if :binary.last(url) == ?/, do: url, else: url <> "/"
  end

  defp default_groups_for_modules([_app]) do
    []
  end

  defp default_groups_for_modules(apps) do
    Enum.map(apps, fn app ->
      Application.load(app)
      {app, Application.spec(app, :modules)}
    end)
  end

  # Group matching helpers

  @doc """
  Finds the index of a given group.
  """
  def index(groups, group) do
    Enum.find_index(groups, fn {k, _v} -> k == group end) || -1
  end

  @doc """
  Finds a matching group for the given module name, id, and metadata.
  """
  def match_module(group_patterns, module, id, metadata) do
    match_group_patterns(group_patterns, fn pattern ->
      case pattern do
        %Regex{} = regex -> Regex.match?(regex, id)
        string when is_binary(string) -> id == string
        atom when is_atom(atom) -> atom == module
        function when is_function(function) -> function.(metadata)
      end
    end)
  end

  @doc """
  Finds a matching group for the given filename or url.
  """
  def match_extra(group_patterns, path) do
    match_group_patterns(group_patterns, fn pattern ->
      case pattern do
        %Regex{} = regex -> Regex.match?(regex, path)
        string when is_binary(string) -> path == string
      end
    end)
  end

  defp match_group_patterns(group_patterns, matcher) do
    Enum.find_value(group_patterns, fn {group, patterns} ->
      patterns = List.wrap(patterns)
      Enum.any?(patterns, matcher) && group
    end)
  end
end
