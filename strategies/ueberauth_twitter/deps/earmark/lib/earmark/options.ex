defmodule Earmark.Options do
  @moduledoc """
  This is a superset of the options that need to be passed into `Earmark.Parser.as_ast/2`

  The following options are proper to `Earmark` only and therefore explained in detail

  - `compact_output`: boolean indicating to avoid indentation and minimize whitespace
  - `eex`: Allows usage of an `EEx` template to be expanded to markdown before conversion
  - `file`: Name of file passed in from the CLI
  - `line`: 1 but might be set to an offset for better error messages in some integration cases
  - `smartypants`: boolean use [Smarty Pants](https://daringfireball.net/projects/smartypants/) in the output
  - `ignore_strings`, `postprocessor` and `registered_processors`: processors that modify the AST returned from

     Earmark.Parser.as_ast/`2` before rendering (`post` because preprocessing is done on the markdown, e.g. `eex`)
     Refer to the moduledoc of Earmark.`Transform` for details

  All other options are passed onto Earmark.Parser.as_ast/`2`
  """

  @type t :: %__MODULE__{
          annotations: String.t() | nil,
          breaks: boolean(),
          code_class_prefix: String.t() | nil,
          compact_output: boolean(),
          eex: boolean(),
          escape: boolean(),
          file: String.t() | nil,
          footnote_offset: non_neg_integer(),
          footnotes: boolean(),
          gfm: boolean(),
          gfm_tables: boolean(),
          ignore_strings: boolean(),
          inner_html: boolean(),
          line: non_neg_integer(),
          mapper: (list(any()), function() -> {:ok, list(any())} | {:error, any()}),
          mapper_with_timeout:
            (list(any()), function(), integer() -> {:ok, list(any())} | {:error, any()}),
          messages: list(Earmark.Error.t()) | [],
          pedantic: boolean(),
          postprocessor: function() | nil,
          pure_links: boolean(),
          sub_sup: boolean(),
          registered_processors: list(any()),
          smartypants: boolean(),
          template: boolean(),
          timeout: integer() | nil,
          wikilinks: boolean()
        }
  defstruct annotations: nil,
            breaks: false,
            code_class_prefix: nil,
            compact_output: false,
            # Internal—only override if you're brave
            eex: false,
            escape: true,
            file: nil,
            footnote_offset: 1,
            footnotes: false,
            gfm: true,
            gfm_tables: false,
            ignore_strings: false,
            inner_html: false,
            line: 1,
            mapper: &Earmark.pmap/2,
            mapper_with_timeout: &Earmark.pmap/3,
            messages: [],
            pedantic: false,
            postprocessor: nil,
            pure_links: true,
            sub_sup: false,
            registered_processors: [],
            smartypants: true,
            template: false,
            timeout: nil,
            wikilinks: false

  @type options ::
          t()
          | Earmark.Parser.Options.t()
          | map()
          | maybe_improper_list()
          | Keyword.t()

  @doc ~S"""
  Make a legal and normalized Option struct from, maps or keyword lists

  Without a param or an empty input we just get a new Option struct

  iex(1)> { make_options(), make_options(%{}) }
  { {:ok, %Earmark.Options{}}, {:ok, %Earmark.Options{}} }

  The same holds for the bang version of course

  iex(2)> { make_options!(), make_options!(%{}) }
  { %Earmark.Options{}, %Earmark.Options{} }


  We check for unallowed keys

  iex(3)> make_options(no_such_option: true)
  {:error, [{:warning, 0, "Unrecognized option no_such_option: true"}]}

  Of course we do not let our users discover one error after another

  iex(4)> make_options(no_such_option: true, gfm: false, still_not_an_option: 42)
  {:error, [{:warning, 0, "Unrecognized option no_such_option: true"}, {:warning, 0, "Unrecognized option still_not_an_option: 42"}]}

  And the bang version will raise an `Earmark.Error` as excepted (sic)

  iex(5)> make_options!(no_such_option: true, gfm: false, still_not_an_option: 42)
  ** (Earmark.Error) [{:warning, 0, "Unrecognized option no_such_option: true"}, {:warning, 0, "Unrecognized option still_not_an_option: 42"}]

  Some values need to be numeric

  iex(6)> make_options(line: "42")
  {:error, [{:error, 0, "line option must be numeric"}]}

  iex(7)> make_options(%Earmark.Options{footnote_offset: "42"})
  {:error, [{:error, 0, "footnote_offset option must be numeric"}]}

  iex(8)> make_options(%{line: "42", footnote_offset: nil})
  {:error, [{:error, 0, "footnote_offset option must be numeric"}, {:error, 0, "line option must be numeric"}]}

  """
  @spec make_options(options()) ::
          {:ok, options()}
          | {:error, [{atom(), integer(), String.t()}]}

  def make_options(options \\ [])

  def make_options(%__MODULE__{} = options) do
    options
    |> Map.from_struct()
    |> make_options()
  end

  def make_options(options) when is_list(options) do
    legal_keys =
      __MODULE__
      |> struct()
      |> Map.keys()
      |> MapSet.new()

    given_keys =
      options
      |> Keyword.keys()
      |> MapSet.new()

    illegal_key_errors =
      given_keys
      |> MapSet.difference(legal_keys)
      |> _format_illegal_key_errors(options)

    case illegal_key_errors do
      [] -> _make_and_check(struct(__MODULE__, options))
      errors -> {:error, _format_errors(errors)}
    end
  end

  def make_options(options) when is_map(options) do
    options
    |> Enum.into([])
    |> make_options()
  end

  def make_options!(options \\ []) do
    case make_options(options) do
      {:ok, options_} -> options_
      {:error, errors} -> raise Earmark.Error, inspect(errors)
    end
  end

  @doc ~S"""
  Allows to compute the path of a relative file name (starting with `"./"`) from the file in options
  and return an updated options struct

  iex(9)> options = %Earmark.Options{file: "some/path/xxx.md"}
  ...(9)> options_ = relative_filename(options, "./local.md")
  ...(9)> options_.file
  "some/path/local.md"

  For your convenience you can just use a keyword list

  iex(10)> options = relative_filename([file: "some/path/_.md", breaks: true], "./local.md")
  ...(10)> {options.file, options.breaks}
  {"some/path/local.md", true}

  If the filename is not absolute it just replaces the file in options

  iex(11)> options = %Earmark.Options{file: "some/path/xxx.md"}
  ...(11)> options_ = relative_filename(options, "local.md")
  ...(11)> options_.file
  "local.md"

  And there is a special case when processing stdin, meaning that `file: nil` we replace file
  verbatim in that case

  iex(12)> options = %Earmark.Options{}
  ...(12)> options_ = relative_filename(options, "./local.md")
  ...(12)> options_.file
  "./local.md"

  """
  @spec relative_filename(options(), String.t()) :: options()
  def relative_filename(options, filename)

  def relative_filename(options, filename) when is_list(options) do
    options
    |> make_options!()
    |> relative_filename(filename)
  end

  def relative_filename(%__MODULE__{file: nil} = options, filename),
    do: %{options | file: filename}

  def relative_filename(%__MODULE__{file: calling_filename} = options, "./" <> filename) do
    dirname = Path.dirname(calling_filename)
    %{options | file: Path.join(dirname, filename)}
  end

  def relative_filename(%__MODULE__{} = options, filename), do: %{options | file: filename}

  @doc """
  A convenience constructor
  """
  def with_postprocessor(pp, rps \\ []),
    do: %__MODULE__{postprocessor: pp, registered_processors: rps}

  defp _assure_applicable(fun_or_tuple_or_tsp)
  defp _assure_applicable({_, _} = tf), do: Earmark.TagSpecificProcessors.new(tf)
  defp _assure_applicable(f), do: f

  defp _check_options!(options)

  defp _check_options!(%__MODULE__{line: line, footnote_offset: fno} = options)
       when is_number(line) and is_number(fno) do
    options
  end

  defp _check_options!(%__MODULE__{line: line}) when is_number(line) do
    {:error, [{:error, 0, "footnote_offset option must be numeric"}]}
  end

  defp _check_options!(%__MODULE__{footnote_offset: fno}) when is_number(fno) do
    {:error, [{:error, 0, "line option must be numeric"}]}
  end

  defp _check_options!(%__MODULE__{}) do
    {:error,
     [
       {:error, 0, "footnote_offset option must be numeric"},
       {:error, 0, "line option must be numeric"}
     ]}
  end

  defp _format_errors(errors) do
    errors
    |> Enum.map(&{:warning, 0, &1})
  end

  defp _format_illegal_key_errors(violators, options) do
    violators
    |> Enum.map(&_format_illegal_key_error(&1, options))
  end

  defp _format_illegal_key_error(violator, options) do
    "Unrecognized option #{violator}: #{Keyword.get(options, violator) |> inspect()}"
  end

  defp _make_and_check(%__MODULE__{} = options) do
    case _check_options!(options) do
      {:error, _} = e -> e
      _ -> {:ok, options |> _normalize()}
    end
  end

  defp _normalize(%__MODULE__{registered_processors: {_, _} = t} = options),
    do: _normalize(%{options | registered_processors: [t]})

  defp _normalize(%__MODULE__{registered_processors: rps} = options) when is_list(rps) do
    %{options | registered_processors: Enum.map(rps, &_assure_applicable/1)}
  end

  defp _normalize(%__MODULE__{registered_processors: f} = options) when is_function(f) do
    %{options | registered_processors: [f]}
  end
end

# SPDX-License-Identifier: Apache-2.0
