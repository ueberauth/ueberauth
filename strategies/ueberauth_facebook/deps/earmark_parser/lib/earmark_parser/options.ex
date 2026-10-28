defmodule EarmarkParser.Options do
  # What we use to render
  defstruct renderer: EarmarkParser.HtmlRenderer,
            # Inline style options
            all: false,
            gfm: true,
            gfm_tables: false,
            breaks: false,
            footnotes: false,
            footnote_offset: 1,
            wikilinks: false,
            parse_inline: true,

            # allow for annotations
            annotations: nil,
            # additional prefies for class of code blocks
            code_class_prefix: nil,

            # Filename and initial line number of the markdown block passed in
            # for meaningful error messages
            file: "<no file>",
            line: 1,
            # [{:error|:warning, lnb, text},...]
            messages: MapSet.new([]),
            pure_links: true,
            sub_sup: false,
            math: false,

            # deprecated
            pedantic: false,
            smartypants: false,
            timeout: nil

  @type t :: %__MODULE__{
          renderer: module(),
          all: boolean(),
          gfm: boolean(),
          gfm_tables: boolean(),
          breaks: boolean(),
          footnotes: boolean(),
          footnote_offset: non_neg_integer(),
          wikilinks: boolean(),
          parse_inline: boolean(),

          # allow for annotations
          annotations: nil | String.t() | Regex.t(),
          # additional prefies for class of code blocks
          code_class_prefix: nil | String.t(),

          # Filename and initial line number of the markdown block passed in
          # for meaningful error messages
          file: String.t(),
          line: non_neg_integer(),
          # [{:error|:warning, lnb, text},...]
          messages: MapSet.t(EarmarkParser.Message.t()),
          pure_links: boolean(),
          sub_sup: boolean(),
          math: boolean(),

          # deprecated
          pedantic: boolean(),
          smartypants: boolean(),
          timeout: nil | non_neg_integer()
        }

  @doc false
  def add_deprecations(options, messages)

  def add_deprecations(%__MODULE__{smartypants: true} = options, messages) do
    add_deprecations(
      %{options | smartypants: false},
      [
        {:deprecated, 0, "The smartypants option has no effect anymore and will be removed in EarmarkParser 1.5"}
        | messages
      ]
    )
  end

  def add_deprecations(%__MODULE__{timeout: timeout} = options, messages) when timeout != nil do
    add_deprecations(
      %{options | timeout: nil},
      [
        {:deprecated, 0, "The timeout option has no effect anymore and will be removed in EarmarkParser 1.5"}
        | messages
      ]
    )
  end

  def add_deprecations(%__MODULE__{pedantic: true} = options, messages) do
    add_deprecations(
      %{options | pedantic: false},
      [
        {:deprecated, 0, "The pedantic option has no effect anymore and will be removed in EarmarkParser 1.5"}
        | messages
      ]
    )
  end

  def add_deprecations(_options, messages) do
    messages
  end

  @doc ~S"""
  Use normalize before passing it into any API function

        iex(1)> options = normalize(annotations: "%%")
        ...(1)> Regex.source(options.annotations)
        "\\A(.*)(%%.*)"
  """
  @spec normalize(t() | keyword()) :: t()
  def normalize(options)

  def normalize(%__MODULE__{} = options) do
    options
    |> _normalize_annotations()
    |> _set_all_if_applicable()
    |> _deprecate_old_messages()
  end

  def normalize(options) do
    struct(__MODULE__, options) |> normalize()
  end

  defp _normalize_annotations(%__MODULE__{annotations: %Regex{}} = options) do
    options
  end

  defp _normalize_annotations(%__MODULE__{annotations: nil} = options) do
    options
  end

  defp _normalize_annotations(%__MODULE__{annotations: annotations} = options) do
    %{options | annotations: Regex.compile!("\\A(.*)(#{Regex.escape(annotations)}.*)")}
  end

  defp _deprecate_old_messages(options)

  defp _deprecate_old_messages(%__MODULE__{messages: %MapSet{}} = options) do
    options
  end

  defp _deprecate_old_messages(%__MODULE__{} = options) do
    %{
      options
      | messages:
          MapSet.new([
            {:deprecated, 0, "messages is an internal option that is ignored and will be removed from the API in v1.5"}
          ])
    }
  end

  defp _set_all_if_applicable(options)

  defp _set_all_if_applicable(%{all: true} = options) do
    %{options | breaks: true, footnotes: true, gfm_tables: true, sub_sup: true, wikilinks: true}
  end

  defp _set_all_if_applicable(options) do
    options
  end
end

# SPDX-License-Identifier: Apache-2.0
