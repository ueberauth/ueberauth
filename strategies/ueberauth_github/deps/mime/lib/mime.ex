defmodule MIME do
  @moduledoc """
  Maps MIME types to its file extensions and vice versa.

  MIME types can be extended in your application configuration
  as follows:

      config :mime, :types, %{
        "application/vnd.api+json" => ["json-api"]
      }

  Note that defining a new type will completely override all
  previous extensions. You can use `MIME.extensions/1` to get
  the existing extension to keep when redefining.

  You can also customize the extensions for suffixes. For example,
  the mime type "application/custom+gzip" returns the extension
  `".gz"` because the suffix "gzip" maps to `["gz"]`:

      config :mime, :suffixes, %{
        "gzip" => ["gz"]
      }

  After adding the configuration, MIME needs to be recompiled
  if you are using an Elixir version earlier than v1.15. In such
  cases, it can be done with:

      $ mix deps.clean mime --build

  """

  types = %{
    "application/atom+xml" => ["atom"],
    "application/epub+zip" => ["epub"],
    "application/gzip" => ["gz"],
    "application/java-archive" => ["jar"],
    "application/javascript" => ["js"],
    "application/json" => ["json"],
    "application/json-patch+json" => ["json-patch"],
    "application/ld+json" => ["jsonld"],
    "application/manifest+json" => ["webmanifest"],
    "application/msword" => ["doc"],
    "application/octet-stream" => ["bin"],
    "application/ogg" => ["ogx"],
    "application/pdf" => ["pdf"],
    "application/postscript" => ["ps", "eps", "ai"],
    "application/rss+xml" => ["rss"],
    "application/rtf" => ["rtf"],
    "application/vnd.amazon.ebook" => ["azw"],
    "application/vnd.api+json" => ["json-api"],
    "application/vnd.apple.installer+xml" => ["mpkg"],
    "application/vnd.etsi.asic-e+zip" => ["asice", "sce"],
    "application/vnd.etsi.asic-s+zip" => ["asics", "scs"],
    "application/vnd.mozilla.xul+xml" => ["xul"],
    "application/vnd.ms-excel" => ["xls"],
    "application/vnd.ms-fontobject" => ["eot"],
    "application/vnd.ms-powerpoint" => ["ppt"],
    "application/vnd.oasis.opendocument.presentation" => ["odp"],
    "application/vnd.oasis.opendocument.spreadsheet" => ["ods"],
    "application/vnd.oasis.opendocument.text" => ["odt"],
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => ["pptx"],
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => ["xlsx"],
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ["docx"],
    "application/vnd.rar" => ["rar"],
    "application/vnd.visio" => ["vsd"],
    "application/wasm" => ["wasm"],
    "application/x-7z-compressed" => ["7z"],
    "application/x-abiword" => ["abw"],
    "application/x-bzip" => ["bz"],
    "application/x-bzip2" => ["bz2"],
    "application/x-cdf" => ["cda"],
    "application/x-csh" => ["csh"],
    "application/x-freearc" => ["arc"],
    "application/x-httpd-php" => ["php"],
    "application/x-msaccess" => ["mdb"],
    "application/x-sh" => ["sh"],
    "application/x-shockwave-flash" => ["swf"],
    "application/x-tar" => ["tar"],
    "application/xhtml+xml" => ["xhtml"],
    "application/xml" => ["xml"],
    "application/zip" => ["zip"],
    "application/zstd" => ["zst"],
    "audio/3gpp" => ["3gp"],
    "audio/3gpp2" => ["3g2"],
    "audio/aac" => ["aac"],
    "audio/midi" => ["mid", "midi"],
    "audio/mpeg" => ["mp3"],
    "audio/ogg" => ["oga"],
    "audio/opus" => ["opus"],
    "audio/wav" => ["wav"],
    "audio/webm" => ["weba"],
    "font/otf" => ["otf"],
    "font/ttf" => ["ttf"],
    "font/woff" => ["woff"],
    "font/woff2" => ["woff2"],
    "image/apng" => ["apng"],
    "image/avif" => ["avif"],
    "image/bmp" => ["bmp"],
    "image/gif" => ["gif"],
    "image/heic" => ["heic"],
    "image/heif" => ["heif"],
    "image/jp2" => ["jp2"],
    "image/jpeg" => ["jpg", "jpeg"],
    "image/jxl" => ["jxl"],
    "image/png" => ["png"],
    "image/svg+xml" => ["svg", "svgz"],
    "image/tiff" => ["tiff", "tif"],
    "image/vnd.adobe.photoshop" => ["psd"],
    "image/vnd.microsoft.icon" => ["ico"],
    "image/webp" => ["webp"],
    "text/calendar" => ["ics"],
    "text/css" => ["css"],
    "text/csv" => ["csv"],
    "text/html" => ["html", "htm"],
    "text/javascript" => ["js", "mjs"],
    "text/markdown" => ["md", "markdown"],
    "text/plain" => ["txt", "text"],
    "text/xml" => ["xml"],
    "video/3gpp" => ["3gp"],
    "video/3gpp2" => ["3g2"],
    "video/mp2t" => ["ts"],
    "video/mp4" => ["mp4"],
    "video/mpeg" => ["mpeg", "mpg"],
    "video/ogg" => ["ogv"],
    "video/quicktime" => ["mov"],
    "video/webm" => ["webm"],
    "video/x-ms-wmv" => ["wmv"],
    "video/x-msvideo" => ["avi"]
  }

  require Application
  custom_types = Application.compile_env(:mime, :types, %{})

  to_exts = fn map ->
    for {media, exts} <- map, ext <- exts, reduce: %{} do
      acc -> Map.update(acc, ext, media, &[media | List.wrap(&1)])
    end
  end

  all_types = Map.merge(types, custom_types)

  default_exts = %{
    "3g2" => "video/3gpp2",
    "3gp" => "video/3gpp",
    "js" => "text/javascript",
    "xml" => "text/xml"
  }

  custom_exts = Application.compile_env(:mime, :extensions, %{})
  all_exts = Map.merge(to_exts.(all_types), Map.merge(default_exts, custom_exts))

  # https://www.iana.org/assignments/media-type-structured-suffix/media-type-structured-suffix.xhtml
  default_suffixes = %{
    "gzip" => ["gz"],
    "json" => ["json"],
    "xml" => ["xml"],
    "zip" => ["zip"],
    "zstd" => ["zst"]
  }

  custom_suffixes = Application.compile_env(:mime, :suffixes, %{})
  suffixes = Map.merge(default_suffixes, custom_suffixes)

  @doc """
  Returns the custom types compiled into the MIME module.
  """
  def compiled_custom_types do
    unquote(Macro.escape(custom_types))
  end

  @doc """
  Returns a mapping of all known types to their extensions,
  including custom types compiled into the MIME module.

  ## Examples

      known_types()
      #=> %{"application/json" => ["json"], ...}

  """
  @doc since: "2.1.0"
  @spec known_types() :: %{required(String.t()) => [String.t()]}
  def known_types do
    unquote(Macro.escape(all_types))
  end

  @doc """
  Returns the extensions associated with a given MIME type.

  ## Examples

      iex> MIME.extensions("text/html")
      ["html", "htm"]

      iex> MIME.extensions("application/json")
      ["json"]

      iex> MIME.extensions("application/vnd.custom+xml")
      ["xml"]

      iex> MIME.extensions("foo/bar")
      []

  """
  @spec extensions(String.t()) :: [String.t()]
  def extensions(type) do
    mime =
      type
      |> strip_params()
      |> downcase("")

    mime_to_ext(mime) || suffix(mime) || []
  end

  defp suffix(type) do
    case String.split(type, "+") do
      [_type_subtype_without_suffix, suffix] -> suffix_to_ext(suffix)
      _ -> nil
    end
  end

  @default_type "application/octet-stream"

  @doc """
  Returns the MIME type associated with a file extension.

  If no MIME type is known for `file_extension`,
  `#{inspect(@default_type)}` is returned.

  ## Examples

      iex> MIME.type("html")
      "text/html"

      iex> MIME.type("foobarbaz")
      #{inspect(@default_type)}

  """
  @spec type(String.t()) :: String.t()
  def type(file_extension) do
    ext_to_mime(file_extension) || @default_type
  end

  @doc """
  Returns whether an extension has a MIME type registered.

  ## Examples

      iex> MIME.has_type?("html")
      true

      iex> MIME.has_type?("foobarbaz")
      false

  """
  @spec has_type?(String.t()) :: boolean
  def has_type?(file_extension) do
    is_binary(ext_to_mime(file_extension))
  end

  @doc """
  Guesses the MIME type based on the path's extension. See `type/1`.

  ## Examples

      iex> MIME.from_path("index.html")
      "text/html"

  """
  @spec from_path(Path.t()) :: String.t()
  def from_path(path) do
    case Path.extname(path) do
      "." <> ext -> type(downcase(ext, ""))
      _ -> @default_type
    end
  end

  defp strip_params(string) do
    string |> :binary.split(";") |> hd()
  end

  defp downcase(<<h, t::binary>>, acc) when h in ?A..?Z,
    do: downcase(t, <<acc::binary, h + 32>>)

  defp downcase(<<h, t::binary>>, acc), do: downcase(t, <<acc::binary, h>>)
  defp downcase(<<>>, acc), do: acc

  @spec ext_to_mime(String.t()) :: String.t() | nil
  defp ext_to_mime(type)

  for {ext, mimes} <- all_exts do
    case mimes do
      [first | _] ->
        raise """
        extension .#{ext} currently maps to different mime-types: #{inspect(mimes)}

        You must tell us which mime-type is preferred by defining the :extensions \
        configuration. For example:

            config :mime, :extensions, %{
              #{inspect(ext)} => #{inspect(first)}
            }

        """

      mime ->
        defp ext_to_mime(unquote(ext)), do: unquote(mime)
    end
  end

  defp ext_to_mime(_ext), do: nil

  @spec mime_to_ext(String.t()) :: list(String.t()) | nil
  defp mime_to_ext(type)

  for {type, exts} <- all_types do
    defp mime_to_ext(unquote(type)), do: unquote(List.wrap(exts))
  end

  defp mime_to_ext(_type), do: nil

  @spec suffix_to_ext(String.t()) :: list(String.t()) | nil
  defp suffix_to_ext(suffix)

  for {suffix, exts} <- suffixes do
    defp suffix_to_ext(unquote(suffix)), do: unquote(List.wrap(exts))
  end

  defp suffix_to_ext(_suffix), do: nil
end
