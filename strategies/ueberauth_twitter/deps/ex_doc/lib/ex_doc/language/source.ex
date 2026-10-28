defmodule ExDoc.Language.Source do
  # Shared helpers used by both Erlang and Elixir.
  @moduledoc false

  def anno_line(line) when is_integer(line), do: abs(line)
  def anno_line(anno), do: anno |> :erl_anno.line() |> abs()

  def anno_file(anno) do
    case :erl_anno.file(anno) do
      :undefined ->
        nil

      file ->
        String.Chars.to_string(file)
    end
  end

  @doc """
  Get abstract code and basedir for a module

  The abstract code has been traversed so that all records in types
  have had their fields in-lined.
  """
  def get_abstract_code(module) do
    with {^module, binary, _file} <- :code.get_object_code(module),
         {:ok, {_, [{:abstract_code, {_vsn, abst_code}}]}} <-
           :beam_lib.chunks(binary, [:abstract_code]) do
      expand_records_in_types(abst_code)
    else
      _ -> nil
    end
  end

  defp expand_records_in_types(abst_code) do
    # Find all records in ast and collect any fields with type declarations
    records =
      filtermap_ast(abst_code, nil, fn
        {:attribute, anno, :record, {name, fields}} ->
          {name,
           fields
           |> Enum.flat_map(fn
             {:typed_record_field, record_field, type} ->
               [{:type, anno, :field_type, [elem(record_field, 2), type]}]

             record_field when elem(record_field, 0) == :record_field ->
               [{:type, anno, :field_type, [elem(record_field, 2), {:type, anno, :term, []}]}]

             _ ->
               []
           end)}

        _ ->
          nil
      end)
      |> Map.new()

    # Expand records in all specs, callbacks, types, opaques and nominals
    filtermap_ast(abst_code, nil, fn
      {:attribute, anno, kind, {mfa, ast}} when kind in [:spec, :callback] ->
        ast = Enum.map(ast, &expand_records(&1, records))
        {:attribute, anno, kind, {mfa, ast}}

      {:attribute, anno, type, {name, ast, args}} when type in [:opaque, :nominal, :type] ->
        {:attribute, anno, type, {name, expand_records(ast, records), args}}

      otherwise ->
        otherwise
    end)
  end

  defp expand_records(types, records) when is_list(types) do
    Enum.map(types, &expand_records(&1, records))
  end

  defp expand_records({:ann_type, anno, [name, type]}, records) do
    {:ann_type, anno, [name, expand_records(type, records)]}
  end

  # When we encounter a record, we fetch the type definitions in the record and
  # merge then with the type. If there are duplicates we take the one in the type
  # declaration
  defp expand_records({:type, anno, :record, [{:atom, _, record} = name | args]}, records) do
    args =
      (args ++ Map.get(records, record, []))
      |> Enum.uniq_by(fn {:type, _, :field_type, [{:atom, _, name} | _]} -> name end)

    # We delete the record from the map so that recursive
    # record definitions are not expanded.
    records = Map.delete(records, record)

    {:type, anno, :record, expand_records([name | args], records)}
  end

  defp expand_records({type, anno, what, args}, records) when type in [:type, :user_type] do
    {type, anno, what, expand_records(args, records)}
  end

  defp expand_records({:remote_type, anno, [m, t, args]}, records) do
    {:remote_type, anno, [m, t, expand_records(args, records)]}
  end

  defp expand_records(otherwise, _records) do
    otherwise
  end

  @doc """
  Fetches the basedir of a module.

  The basedir is the cwd of the Elixir/Erlang compiler when compiling the module.
  All `-file` attributes in the module is relative to this directory.
  """
  def fetch_basedir!(abst_code, module) do
    # We look for the first -file attribute to see what the source file that
    # was compiled is called. Both Erlang and Elixir places one at the top.
    filename =
      Enum.find_value(abst_code, fn
        {:attribute, _anno, :file, {filename, _line}} ->
          filename

        _ ->
          nil
      end) || raise "could not find base directory for #{inspect(module)}"

    # The first -file attribute will be either relative or absolute
    # depending on whether the compiler was called with an absolute
    # or relative path.
    if Path.type(filename) == :relative do
      # If the compiler was called with a relative path, then any other
      # relative -file attribute will be relative to the same directory.
      # We use `module_info(:compile)[:source]` to get an absolute path
      # to the source file and calculate the basedir from that
      compile_source =
        cond do
          source = module.module_info(:compile)[:source] ->
            source

          module in :erlang.pre_loaded() ->
            {:ok, {_, [compile_info: compile_info]}} =
              :beam_lib.chunks(
                Application.app_dir(:erts, "ebin/#{module}.beam")
                |> String.to_charlist(),
                [:compile_info]
              )

            compile_info[:source]

          true ->
            # This happens only when building docs for Makeup itself,
            # as some of its modules may have been loaded from the escript.
            filename
        end

      compile_source
      |> String.Chars.to_string()
      |> Path.absname()
      |> Path.split()
      |> Enum.drop(Path.split(filename) |> Enum.count() |> Kernel.*(-1))
      |> Path.join()
    else
      # If an absolute path was used, then any relative -file attribute
      # is relative to the directory of the source file
      Path.dirname(filename)
    end
  end

  def fetch_module_location!(abst_code, source_basedir, module) do
    find_ast(abst_code, source_basedir, fn
      {:attribute, anno, :module, ^module} ->
        {anno_file(anno), anno_line(anno)}

      _ ->
        nil
    end) || raise "could not find module definition for #{inspect(module)}"
  end

  def fetch_function_location!(module_data, {name, arity}) do
    find_ast(module_data.private.abst_code, module_data.source_basedir, fn
      {:function, anno, ^name, ^arity, _} -> {anno_file(anno), anno_line(anno)}
      _ -> nil
    end) || raise "could not find function definition for #{name}/#{arity}"
  end

  # Returns a map of {name, arity} => spec.
  def get_specs(abst_code, source_basedir) do
    filtermap_ast(abst_code, source_basedir, fn
      {:attribute, _anno, :spec, {name, _types}} = spec ->
        {name, spec}

      _ ->
        nil
    end)
    |> Map.new()
  end

  def fetch_type!(module_data, name, arity) do
    find_ast(module_data.private.abst_code, module_data.source_basedir, fn
      {:attribute, anno, type, {^name, _, args} = spec} = attr ->
        if type in [:nominal, :opaque, :type] and length(args) == arity do
          %{
            type: type,
            spec: spec,
            attr: attr,
            source_file: anno_file(anno),
            source_line: anno_line(anno)
          }
        end

      _ ->
        nil
    end) || raise "could not find type definition for #{name}/#{arity}"
  end

  def get_callbacks(abst_code, source_basedir) do
    filtermap_ast(abst_code, source_basedir, fn
      {:attribute, _anno, :callback, {name, _types}} = callback ->
        {name, callback}

      _ ->
        nil
    end)
    |> Map.new()
  end

  def get_optional_callbacks(module, :behaviour) do
    module.behaviour_info(:optional_callbacks)
  rescue
    FunctionClauseError -> []
  end

  def get_optional_callbacks(_module, _type), do: []

  defp find_ast(ast, source_basedir, fun) do
    filtermap_ast(ast, source_basedir, fun) |> List.first()
  end

  # The file which a form belongs to is decided by the previous :file
  # attribute in the AST. The :file can be either relative, or absolute
  # depending on how the file was included. So when traversing the AST
  # we need to keep track of the :file attributes and update the anno
  # with the correct file.
  defp filtermap_ast(ast, source_basedir, fun) do
    Enum.reduce(ast, {nil, []}, fn
      {:attribute, _anno, :file, {filename, _line}} = entry, {_file, acc} ->
        {if Path.type(filename) == :relative && source_basedir do
           Path.join(source_basedir, filename)
         else
           filename
         end,
         if entry = fun.(entry) do
           [entry | acc]
         else
           acc
         end}

      entry, {file, acc} ->
        anno =
          if file && source_basedir do
            :erl_anno.set_file(file, elem(entry, 1))
          else
            elem(entry, 1)
          end

        if entry = fun.(put_elem(entry, 1, anno)) do
          {file, [entry | acc]}
        else
          {file, acc}
        end

      _, file_acc ->
        file_acc
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
