defmodule ExDoc.Autolink do
  # Encapsulates all functionality related to autolinking,
  # decoupled from language and ExDoc structs.
  @moduledoc false

  # * `:apps` - the apps that the docs are being generated for. When linking modules they are
  #   checked if they are part of the app and based on that the links are relative or absolute.
  #
  # * `:current_module` - the module that the docs are being generated for. Used to link local
  #   calls and see if remote calls are in the same app.
  #
  # * `:current_kfa` - the kind, function, arity that the docs are being generated for. Is nil
  #    if there is no such thing. Used to generate more accurate warnings.
  #
  # * `:module_id` - id of the module being documented (e.g.: `"String"`)
  #
  # * `:file` - source file location
  #
  # * `:line` - line number of the beginning of the documentation
  #
  # * `:language` - the language call-back module to use
  #
  # * `:id` - a module/function/etc being documented (e.g.: `"String.upcase/2"`)
  #
  # * `:ext` - the extension (`".html"`, "`.xhtml"`, etc)
  #
  # * `:extras` - map of extras
  #
  # * `:skip_undefined_reference_warnings_on` - function that will be called with
  #    a module/function/file/etc and return a boolean whether to skip warning on it.
  #
  # * `:skip_code_autolink_to` - function that will be called with a term and return a boolean
  #    whether to skip autolinking to it.
  #
  # * `:filtered_modules` - A list of module nodes that were filtered by the retriever
  #
  # * `:warnings` - one of:
  #
  #     * `:emit` (default)
  #
  #     * `:raise` (useful for tests)
  #
  #     * `:send` - send back to caller (useful for tests)

  alias ExDoc.Refs

  defstruct [
    :current_module,
    :module_id,
    :id,
    :line,
    :language,
    file: "nofile",
    apps: [],
    extras: [],
    deps: [],
    ext: ".html",
    current_kfa: nil,
    siblings: [],
    skip_undefined_reference_warnings_on:
      &ExDoc.Formatter.Config.skip_undefined_reference_warnings_on/1,
    skip_code_autolink_to: &ExDoc.Formatter.Config.skip_code_autolink_to/1,
    force_module_prefix: nil,
    filtered_modules: [],
    assets: %{},
    warnings: :emit
  ]

  @hexdocs "https://hexdocs.pm/"
  @otpappdocs "https://www.erlang.org/doc/apps/"

  def app_module_url(tool, module, anchor \\ "#content", config)

  def app_module_url(:no_tool, _, _, _), do: nil

  def app_module_url(tool, module, anchor, config) do
    base_url =
      case tool do
        :ex_doc -> @hexdocs
        :otp -> @otpappdocs
      end

    path = module |> inspect() |> String.trim_leading(":")
    app_url(base_url, module, config, path, config.ext, "#{anchor}")
  end

  defp string_app_module_url(tool, module, anchor, config) do
    if Enum.any?(config.filtered_modules, &(&1.module == module)) do
      warn(config, "reference to a filtered module")
      nil
    else
      app_module_url(tool, module, anchor, config)
    end
  end

  @doc false
  def ex_doc_app_url(module, config, path, ext, suffix) do
    app_url(@hexdocs, module, config, path, ext, suffix)
  end

  defp app_url(base_url, module, config, path, ext, suffix) do
    if app = app(module) do
      if app in config.apps do
        path <> ext <> suffix
      else
        config.deps
        |> Keyword.get_lazy(app, fn -> base_url <> "#{app}" end)
        |> String.trim_trailing("/")
        |> Kernel.<>("/" <> path <> ".html" <> suffix)
      end
    else
      path <> ext <> suffix
    end
  end

  defp app(module) do
    case :code.which(module) do
      :preloaded ->
        :erts

      maybe_path ->
        case :application.get_application(module) do
          {:ok, app} ->
            app

          _ ->
            with true <- is_list(maybe_path),
                 [_, "ebin", app, "lib" | _] <- maybe_path |> Path.split() |> Enum.reverse() do
              String.split(app, "-") |> hd() |> String.to_atom()
            else
              _ -> nil
            end
        end
    end
  end

  @doc false
  def tool(module, config) do
    if match?("Elixir." <> _, Atom.to_string(module)) do
      :ex_doc
    else
      app = app(module)

      if is_app_otp(app) and app not in config.apps and not Keyword.has_key?(config.deps, app) do
        :otp
      else
        :ex_doc
      end
    end
  end

  defp is_app_otp(app) do
    maybe_lib_dir_path = :code.lib_dir(app)
    is_list(maybe_lib_dir_path) and List.starts_with?(maybe_lib_dir_path, :code.root_dir())
  end

  def maybe_warn(config, ref, visibility, metadata) do
    file = Path.relative_to_cwd(config.file)

    unless Enum.any?(
             [config.id, config.module_id, file],
             config.skip_undefined_reference_warnings_on
           ) do
      warn(config, ref, visibility, metadata)
    end
  end

  defp ref_regex, do: ~r/^`(.+)`$/

  def custom_link(attrs, config) do
    case Keyword.fetch(attrs, :href) do
      {:ok, href} ->
        case Regex.scan(ref_regex(), href) do
          [[_, custom_link]] ->
            custom_link
            |> url(:custom_link, config)
            |> remove_and_warn_if_invalid(custom_link, config)

          [] ->
            build_extra_link(href, config)
        end

      _ ->
        nil
    end
  end

  def url(string = "mix help " <> name, mode, config) do
    name |> mix_task(string, mode, config) |> maybe_remove_link(mode)
  end

  def url(string = "mix " <> name, mode, config) do
    name |> mix_task(string, mode, config) |> maybe_remove_link(mode)
  end

  def url(string, mode, config) do
    if config.skip_code_autolink_to.(string) do
      nil
    else
      parse_url(string, mode, config)
    end
  end

  defp remove_and_warn_if_invalid(nil, reference, config) do
    warn(
      config,
      ~s[documentation references "#{reference}" but it is invalid]
    )

    :remove_link
  end

  defp remove_and_warn_if_invalid(result, _, _), do: result

  @builtin_ext [".livemd", ".cheatmd", ".md", ".txt", ""]

  defp build_extra_link(link, config) do
    with %{scheme: nil, host: nil, path: path} = uri <- URI.parse(link),
         true <- is_binary(path) and path != "" and not (path =~ ref_regex()),
         true <- Path.extname(path) in @builtin_ext do
      cond do
        file = config.extras[Path.basename(path)] ->
          append_fragment(file <> config.ext, uri.fragment)

        asset_file?(path, config.assets) ->
          nil

        true ->
          maybe_warn(config, nil, nil, %{file_path: path, original_text: link})
          nil
      end
    else
      _ -> nil
    end
  end

  defp asset_file?(path, assets) do
    Enum.any?(assets, fn {source_dir, target_dir} ->
      prefix = String.trim_trailing(target_dir, "/") <> "/"

      if String.starts_with?(path, prefix) do
        path
        |> String.trim_leading(prefix)
        |> Path.expand(source_dir)
        |> File.exists?()
      end
    end)
  end

  defp maybe_remove_link(nil, :custom_link) do
    :remove_link
  end

  defp maybe_remove_link(result, _mode) do
    result
  end

  defp mix_task(name, string, mode, config) do
    {module, url, visibility} =
      if name =~ ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/ do
        parts = name |> String.split(".") |> Enum.map(&Macro.camelize/1)
        module = Module.concat([Mix, Tasks | parts])

        {module, module_url(module, :regular_link, config, string),
         Refs.get_visibility({:module, module})}
      else
        {nil, nil, :undefined}
      end

    if url in [nil, :remove_link] and mode == :custom_link do
      maybe_warn(config, {:module, module}, visibility, %{
        mix_task: true,
        original_text: string
      })
    end

    url
  end

  defp module_url(module, anchor \\ nil, mode, config, string) do
    ref = {:module, module}

    case {mode, Refs.get_visibility(ref)} do
      {_link_type, visibility} when visibility in [:public, :limited] ->
        string_app_module_url(tool(module, config), module, anchor, config)

      {:regular_link, :undefined} ->
        nil

      {:custom_link, visibility} when visibility in [:hidden, :undefined] ->
        maybe_warn(config, ref, visibility, %{original_text: string})
        :remove_link

      {_link_type, visibility} ->
        maybe_warn(config, ref, visibility, %{original_text: string})
        nil
    end
  end

  defp extra_url(string, config) do
    case String.split(string, ":", parts: 2) do
      [app, extra] ->
        {extra, anchor} =
          case String.split(extra, "#", parts: 2) do
            [extra] ->
              {extra, ""}

            [extra, anchor] ->
              {extra, "#" <> anchor}
          end

        app = String.to_atom(app)

        config.deps
        |> Keyword.get_lazy(app, fn ->
          if Application.ensure_loaded(app) != :ok do
            maybe_warn(
              config,
              "documentation references \"e:#{string}\" but #{app} cannot be found.",
              nil,
              %{}
            )
          end

          prefix =
            cond do
              app in config.apps -> ""
              is_app_otp(app) -> @otpappdocs
              true -> @hexdocs
            end

          prefix <> "#{app}"
        end)
        |> String.trim_trailing("/")
        |> Kernel.<>("/" <> convert_extra_extension(extra, config) <> anchor)

      _ ->
        nil
    end
  end

  defp convert_extra_extension(extra, config) do
    if Path.extname(extra) in @builtin_ext do
      Path.rootname(extra) <> config.ext
    else
      extra
    end
  end

  defp parse_url(string, mode, config) do
    case Regex.run(~r{^(.+)/(\d+)(#.*)?$}, string) do
      [_, left, right | maybe_fragment] ->
        with {:ok, arity} <- parse_arity(right) do
          {kind, rest} = kind(left)

          case config.language.parse_module_function(rest) do
            {:local, function} ->
              kind
              |> local_url(function, arity, config, string, mode: mode)
              |> maybe_append_nested_fragment(maybe_fragment)
              |> maybe_remove_link(mode)

            {:remote, module, function} ->
              {kind, module, function, arity}
              |> remote_url(config, string, mode: mode)
              |> maybe_append_nested_fragment(maybe_fragment)
              |> maybe_remove_link(mode)

            :error ->
              nil
          end
        else
          _ ->
            nil
        end

      nil ->
        case string do
          "m:" <> rest ->
            parse_module_with_anchor(rest, config)

          "e:" <> rest ->
            extra_url(rest, config)

          string when mode == :custom_link ->
            parse_module_with_anchor(string, config)

          string when not config.force_module_prefix ->
            case config.language.parse_module(string, mode) do
              {:module, module} ->
                module_url(module, mode, config, string)

              :error ->
                nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp parse_module_with_anchor(string, config) do
    destructure [rest, fragment], String.split(string, "#", parts: 2)
    # TODO: rename :custom_link to :strict i.e. we expect ref to be valid
    # force custom_link mode because of m: prefix.
    case config.language.parse_module(rest, :custom_link) do
      {:module, module} ->
        module_url(module, fragment && "#" <> fragment, :custom_link, config, rest)

      :error ->
        nil
    end
  end

  defp parse_arity(string) do
    case Integer.parse(string) do
      {arity, ""} -> {:ok, arity}
      _ -> :error
    end
  end

  def kind("c:" <> rest), do: {:callback, rest}
  def kind("t:" <> rest), do: {:type, rest}
  ## \\ does not work for :custom_url as Earmark strips the \...
  def kind("\\" <> rest), do: {:function, rest}
  def kind(rest), do: {:function, rest}

  def local_url(kind, name, arity, config, original_text, options \\ [])

  def local_url(kind, name, arity, config, original_text, options) do
    module = config.current_module
    ref = {kind, module, name, arity}
    mode = Keyword.get(options, :mode, :regular_link)
    visibility = Refs.get_visibility(ref)

    case {kind, visibility} do
      {_kind, :public} ->
        fragment(kind, name, arity)

      {:function, _visibility} ->
        case config.language.try_autoimported_function(name, arity, mode, config, original_text) do
          nil ->
            if mode == :custom_link do
              maybe_warn(config, ref, visibility, %{original_text: original_text})
            end

            nil

          url ->
            url
        end

      {:type, _visibility} ->
        case config.language.try_builtin_type(name, arity, mode, config, original_text) do
          nil ->
            if mode == :custom_link or config.language == ExDoc.Language.Erlang do
              maybe_warn(config, ref, visibility, %{original_text: original_text})
            end

            nil

          url ->
            url
        end

      _ ->
        maybe_warn(config, ref, visibility, %{original_text: original_text})
        nil
    end
  end

  def fragment(kind, nil, arity) do
    fragment(kind, "nil", arity)
  end

  def fragment(kind, name, arity) do
    "#" <> prefix(kind) <> "#{encode_fragment_name(name)}/#{arity}"
  end

  defp encode_fragment_name(name) when is_atom(name) do
    encode_fragment_name(Atom.to_string(name))
  end

  defp encode_fragment_name(name) when is_binary(name) do
    URI.encode(name)
  end

  defp prefix(kind)
  defp prefix(:function), do: ""
  defp prefix(:callback), do: "c:"
  defp prefix(:type), do: "t:"

  def remote_url({kind, module, name, arity} = ref, config, original_text, opts \\ []) do
    warn? = Keyword.get(opts, :warn?, true)
    mode = Keyword.get(opts, :mode, :regular_link)
    same_module? = module == config.current_module

    case {mode, Refs.get_visibility({:module, module}), Refs.get_visibility(ref)} do
      {_mode, _module_visibility, :public} ->
        tool = tool(module, config)

        if same_module? do
          fragment(kind, name, arity)
        else
          url = string_app_module_url(tool, module, nil, config)
          url && url <> fragment(kind, name, arity)
        end

      {:regular_link, module_visibility, :undefined}
      when module_visibility == :public
      when module_visibility == :limited and kind != :type ->
        if warn? do
          maybe_warn(config, ref, :undefined, %{original_text: original_text})
        end

        nil

      {:regular_link, _module_visibility, :undefined}
      when not same_module? and
             (config.language != ExDoc.Language.Erlang or kind == :function) ->
        nil

      {:regular_link, :hidden, :hidden}
      when not same_module? ->
        if warn? do
          maybe_warn(config, ref, :hidden, %{
            original_text: original_text,
            module_visibility: :hidden,
            same_module?: false
          })
        end

        nil

      {_mode, _module_visibility, visibility} ->
        if warn? do
          maybe_warn(config, ref, visibility, %{original_text: original_text})
        end

        nil
    end
  end

  @doc false
  def warn(config, message) do
    f =
      case config.current_kfa do
        {:function, f, a} ->
          [function: {f, a}]

        _ ->
          []
      end

    stacktrace_info = [file: config.file, line: config.line, module: config.current_module] ++ f

    case config.warnings do
      :emit ->
        ExDoc.warn(message, stacktrace_info)

      :raise ->
        ExDoc.warn(message, stacktrace_info)
        raise "fail due to warnings"

      :send ->
        send(self(), {:warn, message, file: config.file, line: config.line})
    end
  end

  defp warn(config, ref, visibility, metadata)

  defp warn(
         config,
         {:module, _module},
         visibility,
         %{mix_task: true, original_text: original_text}
       ) do
    message =
      "documentation references \"#{original_text}\" but it is " <>
        format_visibility(visibility, :module)

    warn(config, message)
  end

  defp warn(
         config,
         {:module, _module},
         visibility,
         %{original_text: original_text}
       ) do
    message =
      "documentation references module \"#{original_text}\" but it is " <>
        format_visibility(visibility, :module)

    warn(config, message)
  end

  defp warn(
         config,
         nil,
         _visibility,
         %{file_path: _file_path, original_text: original_text}
       ) do
    message = "documentation references file \"#{original_text}\" but it does not exist"

    warn(config, message)
  end

  defp warn(
         config,
         {:type, module, _name, _arity},
         :hidden,
         %{original_text: original_text, module_visibility: :hidden, same_module?: false}
       ) do
    message =
      "documentation references type \"#{original_text}\" but the module " <>
        "#{inspect(module)} is #{format_visibility(:hidden, :module)}"

    warn(config, message)
  end

  defp warn(
         config,
         {kind, _module, _name, _arity},
         visibility,
         %{original_text: original_text}
       ) do
    message =
      "documentation references #{kind} \"#{original_text}\" but it is " <>
        format_visibility(visibility, kind)

    warn(config, message)
  end

  defp warn(config, message, _, _) when is_binary(message) do
    warn(config, message)
  end

  # there is not such a thing as private callback or private module
  def format_visibility(visibility, kind) when kind in [:module, :callback], do: "#{visibility}"

  # typep is defined as :hidden, since there is no :private visibility value
  # but type defined with @doc false also is the stored the same way.
  def format_visibility(:hidden, :type), do: "hidden or private"

  # for the rest, it can either be undefined or private
  def format_visibility(:undefined, _kind), do: "undefined or private"
  def format_visibility(visibility, _kind), do: "#{visibility}"

  defp maybe_append_nested_fragment(nil, _), do: nil
  defp maybe_append_nested_fragment(url, []), do: url
  defp maybe_append_nested_fragment(url, ["#" <> fragment]), do: url <> "-" <> fragment

  defp append_fragment(url, nil), do: url
  defp append_fragment(url, fragment), do: url <> "#" <> fragment
end
