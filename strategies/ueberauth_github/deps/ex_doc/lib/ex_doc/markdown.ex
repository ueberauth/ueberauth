defmodule ExDoc.Markdown do
  @moduledoc """
  Adapter behaviour and conveniences for converting Markdown to HTML.

  ExDoc is compatible with any markdown processor that implements the
  functions defined in this module. The markdown processor can be changed
  via the `:markdown_processor` option. Note that doing such change is global.

  ExDoc supports the following Markdown parsers out of the box:

    * [EarmarkParser](https://github.com/robertdober/earmark_parser)

  ExDoc uses EarmarkParser by default.
  """

  @doc """
  Converts markdown into HTML.
  """
  @callback to_ast(String.t(), Keyword.t()) :: term()

  @doc """
  Returns true if all dependencies necessary are available.
  """
  @callback available?() :: boolean()

  @doc """
  Converts the given markdown document to HTML AST.

  ## Options

    * `:markdown_processor` - The markdown processor to use,
      either as a module or a `{module, keyword}` tuple

  All other options are passed through to the markdown processor.
  """
  def to_ast(text, opts \\ []) when is_binary(text) do
    {processor_pair, options} = Keyword.pop!(opts, :markdown_processor)

    {processor, options} =
      case processor_pair do
        {processor, processor_options} when is_atom(processor) and is_list(processor_options) ->
          {processor, Keyword.merge(processor_options, options)}

        processor when is_atom(processor) and processor != nil ->
          {processor, options}

        _ ->
          raise ArgumentError,
                ":markdown_processor must be either `Mod` or `{Mod, options}`, got: #{inspect(processor_pair)}"
      end

    processor.to_ast(text, options)
  end
end
