defmodule ExDoc.Formatter.EPUB.Templates do
  @moduledoc false

  require EEx

  import ExDoc.Utils, only: [h: 1, text_to_id: 1]

  alias ExDoc.Formatter.HTML.Templates, as: H
  alias ExDoc.Formatter.EPUB.Assets

  # The actual rendering happens here
  defp render_doc(ast), do: ast && ExDoc.DocAST.to_html(ast)

  @doc """
  Generated ID for static file.
  """
  def static_file_to_id(static_file) do
    static_file |> Path.basename() |> text_to_id()
  end

  @doc """
  Creates the Package Document Definition.

  this definition encapsulates the publication metadata and the resource
  information that constitute the EPUB publication. This definition also
  includes the default reading order.

  See http://www.idpf.org/epub/30/spec/epub30-publications.html#sec-package-def.
  """
  EEx.function_from_file(
    :def,
    :content_template,
    Path.expand("templates/content_template.eex", __DIR__),
    [:config, :modules, :tasks, :extras, :uuid, :datetime, :static_files],
    trim: true
  )

  @doc """
  Creates a chapter which contains all the details about an individual module.

  This chapter can include the following sections: *functions*, *types*, *callbacks*.
  """
  EEx.function_from_file(
    :def,
    :module_template,
    Path.expand("templates/module_template.eex", __DIR__),
    [:config, :module],
    trim: true
  )

  @doc """
  Creates the table of contents.

  This template follows the EPUB Navigation Document Definition.

  See http://www.idpf.org/epub/30/spec/epub30-contentdocs.html#sec-xhtml-nav.
  """
  EEx.function_from_file(
    :def,
    :nav_template,
    Path.expand("templates/nav_template.eex", __DIR__),
    [:config, :modules, :tasks, :extras],
    trim: true
  )

  @doc """
  Creates a new chapter when the user provides additional files.
  """
  EEx.function_from_file(
    :def,
    :extra_template,
    Path.expand("templates/extra_template.eex", __DIR__),
    [:config, :node],
    trim: true
  )

  @doc """
  Creates the cover page for the EPUB document.
  """
  EEx.function_from_file(
    :def,
    :title_template,
    Path.expand("templates/title_template.eex", __DIR__),
    [:config],
    trim: true
  )

  EEx.function_from_file(
    :defp,
    :head_template,
    Path.expand("templates/head_template.eex", __DIR__),
    [:config, :title],
    trim: true
  )

  EEx.function_from_file(
    :defp,
    :nav_grouped_item_template,
    Path.expand("templates/nav_grouped_item_template.eex", __DIR__),
    [:nodes],
    trim: true
  )

  EEx.function_from_file(
    :defp,
    :toc_item_template,
    Path.expand("templates/toc_item_template.eex", __DIR__),
    [:nodes],
    trim: true
  )

  "templates/media-types.txt"
  |> Path.expand(__DIR__)
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    [extension, media] = String.split(line, ",")

    def media_type("." <> unquote(extension)) do
      unquote(media)
    end
  end)

  def media_type(_arg), do: nil
end
