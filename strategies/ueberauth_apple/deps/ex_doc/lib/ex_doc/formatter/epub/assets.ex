defmodule ExDoc.Formatter.EPUB.Assets do
  @moduledoc false

  defmacrop embed_pattern(pattern) do
    ["formatters/epub", pattern]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(fn path ->
      Module.put_attribute(__CALLER__.module, :external_resource, path)
      {Path.basename(path), File.read!(path)}
    end)
  end

  defp dist_js(), do: embed_pattern("dist/*.js")
  defp dist_css(:elixir), do: embed_pattern("dist/epub-elixir-*.css")
  defp dist_css(:erlang), do: embed_pattern("dist/epub-erlang-*.css")

  ## Assets

  def dist(proglang), do: dist_js() ++ dist_css(proglang)
  def metainfo, do: embed_pattern("metainfo/*")

  ## Filenames

  def js_filename(), do: dist_js() |> extract_filename!()
  def css_filename(language), do: dist_css(language) |> extract_filename!()

  ## Helpers

  defp extract_filename!([{location, _}]), do: location
end
