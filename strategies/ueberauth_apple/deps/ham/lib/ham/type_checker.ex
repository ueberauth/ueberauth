defmodule Ham.TypeChecker do
  @moduledoc false
  alias Ham.{Cache, TypeEngine, TypeMatchError, Utils}

  @doc "Validate a function call against its typespecs."
  @spec validate(module, atom, [any], any, list(module)) :: :ok | {:error, TypeMatchError.t()}
  def validate(module, function_name, args, return_value, behaviours \\ []) do
    case fetch_typespecs(module, function_name, length(args), behaviours) do
      {:ok, typespecs} -> check_call(args, return_value, typespecs)
      {:error, reason} -> {:error, %TypeMatchError{reasons: [reason]}}
    end
  end

  defp check_call(args, return_value, typespecs) when is_list(typespecs) do
    typespecs
    |> Enum.reduce_while({:error, []}, fn typespec, {:error, reasons} = result ->
      case match_call(args, return_value, typespec) do
        :ok ->
          {:halt, :ok}

        {:error, new_reasons} = new_result ->
          {:cont,
           if(length(reasons) >= length(new_reasons),
             do: result,
             else: new_result
           )}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, []} -> :ok
      {:error, reasons} -> {:error, %TypeMatchError{reasons: reasons}}
    end
  end

  defp match_call(args, return_value, typespec) do
    args_result = match_args(args, typespec)
    return_value_result = match_return_value(return_value, typespec)

    [return_value_result, args_result]
    |> Enum.reduce([], fn result, acc ->
      case result do
        :ok -> acc
        {:error, reasons} -> reasons ++ acc
      end
    end)
    |> case do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  defp match_args([], _typespec), do: :ok

  # credo:disable-for-lines:24 Credo.Check.Refactor.Nesting
  defp match_args(args, typespec) do
    args
    |> Enum.zip(0..(length(args) - 1))
    |> Enum.map(fn {arg, index} ->
      arg_type = arg_typespec(typespec, index)

      case TypeEngine.match_type(arg, arg_type) do
        {:error, reasons} ->
          {:error, [{:arg_type_mismatch, index, arg, arg_type} | reasons]}

        :ok ->
          :ok
      end
    end)
    |> Enum.max_by(fn
      {:error, reasons} -> length(reasons)
      :ok -> 0
    end)
  end

  defp match_return_value(return_value, typespec) do
    {:type, _, :fun, [_, return_type]} = typespec

    case TypeEngine.match_type(return_value, return_type) do
      {:error, reasons} ->
        {:error, [{:return_type_mismatch, return_value, return_type} | reasons]}

      :ok ->
        :ok
    end
  end

  defp fetch_typespecs(module, function_name, arity) do
    with {:ok, specs} <- fetch_specs(module, :specs, &Code.Typespec.fetch_specs/1) do
      {:ok, Map.get(specs, {function_name, arity}, [])}
    end
  end

  defp fetch_callback_typespecs(module, function_name, arity) do
    with {:ok, specs} <- fetch_specs(module, :callbacks, &Code.Typespec.fetch_callbacks/1) do
      {:ok, Map.get(specs, {function_name, arity}, [])}
    end
  end

  defp fetch_specs(module, key, fetcher) do
    Cache.fetch({key, module}, fn ->
      case fetcher.(module) do
        {:ok, specs} ->
          {:ok, build_typespecs_map(specs, module)}

        :error ->
          {:error, {:module_fetch_failure, module}}
      end
    end)
  end

  defp build_typespecs_map(specs, module) do
    specs
    |> Map.new(fn {{function_name, arity}, typespecs} ->
      typespecs =
        typespecs
        |> Enum.map(&guards_to_annotated_types(&1))
        |> Enum.map(&Utils.replace_user_types(&1, module))

      {{function_name, arity}, typespecs}
    end)
  end

  defp guards_to_annotated_types({:type, _, :fun, _} = typespec), do: typespec

  defp guards_to_annotated_types(
         {:type, _, :bounded_fun,
          [{:type, _, :fun, [{:type, _, :product, args}, return_value]}, constraints]}
       ) do
    type_lookup_map =
      constraints
      |> Enum.map(fn {:type, _, :constraint,
                      [{:atom, _, :is_subtype}, [{:var, _, var_name}, type]]} ->
        {var_name, type}
      end)
      |> Enum.into(%{})

    new_args =
      Enum.map(
        args,
        &annotate_vars(&1, type_lookup_map)
      )

    new_return_value = annotate_vars(return_value, type_lookup_map)

    {:type, 0, :fun, [{:type, 0, :product, new_args}, new_return_value]}
  end

  defp annotate_vars(type, type_lookup_map) do
    Utils.type_map(type, fn
      {:var, _, var_name} ->
        type_for_var = Map.fetch!(type_lookup_map, var_name)
        {:ann_type, 0, [{:var, 0, var_name}, type_for_var]}

      other ->
        other
    end)
  end

  defp fetch_behaviours_typespecs(behaviours, function_name, arity) do
    Enum.reduce_while(behaviours, {:ok, []}, fn behaviour, {:ok, acc} ->
      case fetch_callback_typespecs(behaviour, function_name, arity) do
        {:ok, callback_specs} -> {:cont, {:ok, [callback_specs | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_typespecs(module, function_name, arity, behaviours)
       when is_atom(module) and is_atom(function_name) and is_integer(arity) do
    with {:ok, specs} <- fetch_typespecs(module, function_name, arity),
         {:ok, callback_specs} <- fetch_behaviours_typespecs(behaviours, function_name, arity) do
      {:ok, List.flatten([callback_specs | specs])}
    end
  end

  defp arg_typespec(function_typespec, arg_index) do
    {:type, _, :fun, [{:type, _, :product, arg_typespecs}, _]} = function_typespec
    Enum.at(arg_typespecs, arg_index)
  end
end
