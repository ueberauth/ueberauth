defmodule ExDoc.Language do
  @moduledoc false

  @typedoc """
  The map has the following keys:

    * `:module` - the module

    * `:default_groups` - the default groups used by this module

    * `:docs` - the docs chunk

    * `:language` - the language callback

    * `:id` - module page name

    * `:title` - module display title

    * `:type` - module type

    * `:source_line` - the line where the module code is located, defmodule in Elixir, or -module in Erlang

    * `:source_file` - the source file the module code is located, defmodule in Elixir, or -module in Erlang

    * `:source_basedir` - the absolute directory where the Elixir/Erlang compiler was run.

    * `:nesting_info` - a `{nested_title, nested_context}` tuple or `nil`.
      For example, `"A.B.C"` becomes `{"C", "A.B."}`.

    * `:private` - a map with language-specific data
  """
  @type module_data() :: %{
          module: module(),
          default_groups: [binary()],
          docs: tuple(),
          language: module(),
          id: String.t(),
          title: String.t(),
          type: atom() | nil,
          source_basedir: String.t(),
          source_file: String.t() | nil,
          source_line: non_neg_integer(),
          nesting_info: {String.t(), String.t()} | nil,
          private: map()
        }

  @doc """
  Returns a map with module information.
  """
  @callback module_data(module(), tuple(), ExDoc.Config.t()) :: module_data() | false

  @doc """
  Returns a map with documentation information about a given node or `false`.

  The map has the following keys:

    * `:id_key` - the key used to namespace this entry

    * `:default_group` - the default group this definition falls under

    * `:doc_fallback` - if set, a 0-arity function that returns DocAST which
       will be used as fallback to empty docs on the function node

    * `:extra_annotations` - additional annotations

    * `:signature` - the function signature

    * `:source_file` - the source file where the code in located

    * `:source_line` - the line where the code is located, def/defp in Elixir, foo(...) in Erlang

    * `:specs` - a list of specs that will be later formatted by `c:typespec/2`

    * `:type` - the type of the doc (`:function`, `:macro`, `:type`, etc)

  """
  @callback doc_data(entry :: tuple(), module_data()) ::
              %{
                id_key: binary(),
                default_group: binary(),
                doc_fallback: (-> ExDoc.DocAST.t()),
                extra_annotations: [String.t()],
                signature: [binary()],
                source_file: String.t() | nil,
                source_line: non_neg_integer() | nil,
                specs: [ExDoc.DocNode.spec_ast()],
                type: atom()
              }
              | false

  @doc """
  Autolinks docs.
  """
  @callback autolink_doc(doc :: ExDoc.DocAST.t(), config :: ExDoc.Autolink.t()) ::
              ExDoc.DocAST.t()

  @doc """
  Autolinks typespecs.
  """
  @callback autolink_spec(spec :: term(), config :: ExDoc.Autolink.t()) :: iodata()

  @doc """
  Formats typespecs (without autolinking).
  """
  @callback format_spec(spec :: term()) :: iodata()

  @doc """
  Returns information for syntax highlighting.
  """
  @callback highlight_info() :: %{
              language_name: String.t(),
              lexer: module(),
              opts: keyword()
            }

  @doc """
  Return an attribute in the canonical representation.
  """
  @callback format_spec_attribute(%ExDoc.DocNode{}) :: String.t()

  @doc """
  Parse a module.function string and return it.
  """
  @callback parse_module_function(String.t()) ::
              {:local, function :: atom()}
              | {:remote, module :: module(), function :: atom()}
              | :error

  @doc """
  Parse a module string and return it.
  """
  @callback parse_module(String.t(), mode :: :regular_link | :custom_link) ::
              {:module, atom()} | :error

  @doc """
  Return a URL to autoimported function if atom+arity are autoimported
  """
  @callback try_autoimported_function(
              name :: atom(),
              arity :: non_neg_integer(),
              mode :: :regular_link | :custom_link,
              config :: ExDoc.Autolink.t(),
              original_text :: String.t()
            ) ::
              nil | String.t()

  @doc """
  Return a URL to built-in type if atom+arity are built-in
  """
  @callback try_builtin_type(
              name :: atom(),
              arity :: non_neg_integer(),
              mode :: :regular_link | :custom_link,
              config :: ExDoc.Autolink.t(),
              original_text :: String.t()
            ) ::
              nil | String.t()

  def get(:elixir, _module), do: {:ok, ExDoc.Language.Elixir}
  def get(:erlang, _module), do: {:ok, ExDoc.Language.Erlang}

  def get(language, module) when is_atom(language) and is_atom(module) do
    ExDoc.warn(
      "skipping module #{module}, reason: unsupported language (#{language})",
      []
    )

    :error
  end
end
