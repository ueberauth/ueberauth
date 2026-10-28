defmodule Earmark.Parser.Options do

  @moduledoc """
    Determines how markdown is parsed into an abstract syntax tree (AST) and subsequently rendered to HTML.
  """

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
          annotations: String.t() | nil,
          code_class_prefix: String.t() | nil,
          file: String.t() | nil,
          line: non_neg_integer(),
          messages: MapSet.t(),
          pure_links: boolean(),
          sub_sup: boolean(),
          pedantic: boolean(),
          smartypants: boolean(),
          timeout: integer() | nil
        }
  # What we use to render
  defstruct renderer: Earmark.Parser.HtmlRenderer,
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

            # deprecated
            pedantic: false,
            smartypants: false,
            timeout: nil

  @doc false
  def add_deprecations(options, messages)

  def add_deprecations(%__MODULE__{smartypants: true} = options, messages) do
    add_deprecations(
      %{options | smartypants: false},
      [
        {:deprecated, 0,
         "The smartypants option has no effect anymore and will be removed in Earmark.Parser 1.5"}
        | messages
      ]
    )
  end

  def add_deprecations(%__MODULE__{timeout: timeout} = options, messages) when timeout != nil do
    add_deprecations(
      %{options | timeout: nil},
      [
        {:deprecated, 0,
         "The timeout option has no effect anymore and will be removed in Earmark.Parser 1.5"}
        | messages
      ]
    )
  end

  def add_deprecations(%__MODULE__{pedantic: true} = options, messages) do
    add_deprecations(
      %{options | pedantic: false},
      [
        {:deprecated, 0,
         "The pedantic option has no effect anymore and will be removed in Earmark.Parser 1.5"}
        | messages
      ]
    )
  end

  def add_deprecations(_options, messages), do: messages

  @doc ~S"""
  Use normalize before passing it into any API function

        iex(1)> options = normalize(annotations: "%%")
        ...(1)> options.annotations
        ~r{\A(.*)(%%.*)}
  """
  @spec normalize(Earmark.Options.options()) :: Earmark.Options.options()
  def normalize(options)

  def normalize(%__MODULE__{} = options) do
    case options.annotations do
      %Regex{} ->
        options

      nil ->
        options

      _ ->
        %{
          options
          | annotations: Regex.compile!("\\A(.*)(#{Regex.escape(options.annotations)}.*)")
        }
    end
    |> _set_all_if_applicable()
    |> _deprecate_old_messages()
  end

  def normalize(options), do: struct(__MODULE__, options) |> normalize()

  defp _deprecate_old_messages(opitons)
  defp _deprecate_old_messages(%__MODULE__{messages: %MapSet{}} = options), do: options

  defp _deprecate_old_messages(%__MODULE__{} = options) do
    %{
      options
      | messages:
          MapSet.new([
            {:deprecated, 0,
             "messages is an internal option that is ignored and will be removed from the API in v1.5"}
          ])
    }
  end

  defp _set_all_if_applicable(options)

  defp _set_all_if_applicable(%{all: true} = options) do
    %{options | breaks: true, footnotes: true, gfm_tables: true, sub_sup: true, wikilinks: true}
  end

  defp _set_all_if_applicable(options), do: options
end

# SPDX-License-Identifier: Apache-2.0
