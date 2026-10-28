defmodule ExDoc.Formatter.MARKDOWN.Templates do
  @moduledoc false

  require EEx
  import ExDoc.Utils, only: [h: 1]

  @doc """
  Returns the original markdown documentation from source_doc.
  """
  def node_doc(%{source_doc: %{"en" => source}}) when is_binary(source), do: source
  def node_doc(_), do: nil

  @doc """
  Computes the synopsis based on source_doc.
  """
  def synopsis(%{source_doc: %{"en" => source}}) when is_binary(source),
    do:
      source
      |> String.split(["\r\n\r\n", "\n\n"], parts: 2)
      |> hd()
      |> String.trim_trailing(":")
      |> then(&": #{&1}")

  def synopsis(_), do: nil

  EEx.function_from_file(
    :def,
    :module_template,
    Path.expand("templates/module_template.eex", __DIR__),
    [:config, :module],
    trim: true
  )

  EEx.function_from_file(
    :def,
    :api_reference_template,
    Path.expand("templates/api_reference_template.eex", __DIR__),
    [:config, :modules, :mix_tasks],
    trim: true
  )

  EEx.function_from_file(
    :def,
    :llms_txt_template,
    Path.expand("templates/llms_txt_template.eex", __DIR__),
    [:config, :modules, :mix_tasks, :extras],
    trim: true
  )

  EEx.function_from_file(
    :defp,
    :nav_group_template,
    Path.expand("templates/nav_group_template.eex", __DIR__),
    [:title, :groups],
    trim: true
  )

  EEx.function_from_file(
    :defp,
    :detail_template,
    Path.expand("templates/detail_template.eex", __DIR__),
    [:node, :module],
    trim: true
  )
end
