defmodule Mimic.Module do
  alias Mimic.{Cover, Server}

  @elixir_version System.version() |> Float.parse() |> elem(0)
  @moduledoc false

  @spec original(module) :: module
  def original(module), do: "#{module}.Mimic.Original.Module" |> String.to_atom()

  @spec clear!(module) :: :ok
  def clear!(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(original(module))
    :code.delete(original(module))
    :cover.reset(original(module))
    :ok
  end

  @spec replace!(module, keyword) :: :ok | {:cover.file(), binary}
  def replace!(module, opts) do
    backup_module = original(module)

    result =
      case :cover.is_compiled(module) do
        {:file, beam_file} ->
          # We don't want to wipe the coverdata for this module in the process of
          # renaming it. Save it for later
          coverdata_path = Cover.export_coverdata!(module)

          {beam_file, coverdata_path}

        false ->
          :ok
      end

    rename_module(module, backup_module)
    Code.compiler_options(ignore_module_conflict: true)
    create_mock(module, Map.new(opts))
    Code.compiler_options(ignore_module_conflict: false)

    result
  end

  @spec copied?(module) :: boolean
  def copied?(module) do
    function_exported?(module, :__mimic_info__, 0)
  end

  defp rename_module(module, new_module) do
    beam_code = beam_code(module)

    {:ok, {_, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
      :beam_lib.chunks(beam_code, [:abstract_code])

    forms = rename_attribute(forms, new_module)

    case :compile.forms(forms, compiler_options(module)) do
      {:ok, module_name, binary} ->
        load_binary(module_name, binary, Cover.enabled_for?(module))
        binary

      {:ok, module_name, binary, _warnings} ->
        load_binary(module_name, binary, Cover.enabled_for?(module))
        binary
    end
  end

  defp beam_code(module) do
    # Note: If the module was compiled with :cover, this loads the version of the module pre
    # coverage
    case :code.get_object_code(module) do
      {_, binary, _filename} -> binary
      _error -> throw({:object_code_not_found, module})
    end
  end

  defp compiler_options(module) do
    options =
      module.module_info(:compile)
      |> Keyword.get(:options, [])
      |> Enum.filter(&(&1 != :from_core))

    [:return_errors | [:debug_info | options]]
  end

  defp load_binary(module, binary, enable_cover?) do
    case :code.load_binary(module, ~c"", binary) do
      {:module, ^module} -> :ok
      {:error, reason} -> exit({:error_loading_module, module, reason})
    end

    if enable_cover? do
      Cover.export_private_functions()
      # Call dynamically to avoid compiler warning about private function being called
      # (compile_beams) which the above function exported. See export_private_functions's comment
      # for more info.
      #
      # beam_code/1 loads the not-cover-compiled version of the module, so we compile the
      # renamed module using cover. This is so we can collect coverage data on the
      # original module (which is called by the mock)
      apply(:cover, :compile_beams, [[{module, binary}]])
    end
  end

  defp rename_attribute([{:attribute, line, :module, {_, vars}} | t], new_name) do
    [{:attribute, line, :module, {new_name, vars}} | t]
  end

  defp rename_attribute([{:attribute, line, :module, _} | t], new_name) do
    [{:attribute, line, :module, new_name} | t]
  end

  defp rename_attribute([h | t], new_name), do: [h | rename_attribute(t, new_name)]

  defp create_mock(module, opts) do
    mimic_info = module_mimic_info(opts)
    mimic_behaviours = generate_mimic_behaviours(module)
    mimic_functions = generate_mimic_functions(module)
    mimic_macros = generate_mimic_macros(module)
    mimic_struct = generate_mimic_struct(module)

    quoted = [mimic_info, mimic_struct | mimic_behaviours ++ mimic_functions ++ mimic_macros]

    Module.create(module, quoted, Macro.Env.location(__ENV__))
    module
  end

  if @elixir_version >= 1.18 do
    defp generate_mimic_struct(module) do
      if function_exported?(module, :__info__, 1) && module.__info__(:struct) != nil do
        struct_template = Map.from_struct(module.__struct__())

        struct_params =
          Enum.map(module.__info__(:struct), fn %{field: field} ->
            {field, Macro.escape(struct_template[field])}
          end)

        quote do
          defstruct unquote(struct_params)
        end
      end
    end
  else
    defp generate_mimic_struct(module) do
      if function_exported?(module, :__info__, 1) && module.__info__(:struct) != nil do
        struct_info =
          module.__info__(:struct)
          |> Enum.split_with(& &1.required)
          |> Tuple.to_list()
          |> List.flatten()

        required_fields = for %{field: field, required: true} <- struct_info, do: field
        struct_template = Map.from_struct(module.__struct__())

        struct_params =
          for %{field: field, required: required} <- struct_info do
            if required do
              field
            else
              {field, Macro.escape(struct_template[field])}
            end
          end

        quote do
          @enforce_keys unquote(required_fields)
          defstruct unquote(struct_params)
        end
      end
    end
  end

  defp module_mimic_info(opts) do
    quote do: def(__mimic_info__, do: {:ok, unquote(Macro.escape(opts))})
  end

  defp generate_mimic_functions(module) do
    internal_functions = [__info__: 1, module_info: 0, module_info: 1]
    macro_functions = macro_functions(module)
    functions = module.module_info(:exports)

    for {fn_name, arity} <- functions,
        {fn_name, arity} not in (internal_functions ++ macro_functions) do
      args = Macro.generate_arguments(arity, module)

      quote do
        def unquote(fn_name)(unquote_splicing(args)) do
          Server.apply(__MODULE__, unquote(fn_name), unquote(args))
        end
      end
    end
  end

  defp macro_functions(module) do
    if function_exported?(module, :__info__, 1) do
      :macros
      |> module.__info__()
      |> Enum.map(fn {name, arity} -> {String.to_atom("MACRO-#{name}"), arity + 1} end)
    else
      []
    end
  end

  defp generate_mimic_macros(module) do
    macros =
      if function_exported?(module, :__info__, 1) do
        module.__info__(:macros)
      else
        []
      end

    for {macro_name, arity} <- macros do
      args = Macro.generate_arguments(arity, module)
      macro_fun = String.to_existing_atom("MACRO-#{macro_name}")

      quote do
        defmacro unquote(macro_name)(unquote_splicing(args)) do
          Server.apply(__MODULE__, unquote(macro_fun), [__CALLER__ | unquote(args)])
        end
      end
    end
  end

  defp generate_mimic_behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.map(fn behaviour ->
      quote do
        @behaviour unquote(behaviour)
      end
    end)
  end
end
