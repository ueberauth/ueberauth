defmodule Ham.TypeMatchError do
  @moduledoc """
  An error thrown when Ham detects that values in a function call don't
  match types defined in typespecs.
  """
  defexception [:reasons]

  @type t :: %__MODULE__{}

  alias Ham.Utils
  import Ham.Utils, only: [type_to_string: 1]

  @impl Exception
  def exception({:error, reasons}), do: %__MODULE__{reasons: reasons}

  @impl Exception
  def message(exception) do
    message_string(exception.reasons)
  end

  def translate(exception) when is_struct(exception, __MODULE__) do
    Enum.map(exception.reasons, &human_reason/1)
  end

  defp human_reason({:arg_type_mismatch, index, value, type}) do
    "#{Utils.ordinalize(index + 1)} argument value #{inspect(value)} does not match #{Utils.ordinalize(index + 1)} parameter's type #{type_to_string(type)}."
  end

  defp human_reason({:return_type_mismatch, value, type}) do
    "Returned value #{inspect(value)} does not match type #{type_to_string(type)}."
  end

  defp human_reason({:tuple_elem_type_mismatch, index, elem, elem_type}) do
    "#{Utils.ordinalize(index + 1)} tuple element #{inspect(elem)} does not match #{Utils.ordinalize(index + 1)} element type #{type_to_string(elem_type)}."
  end

  defp human_reason({:elem_type_mismatch, index, elem, elem_type}) do
    "Element #{inspect(elem)} at index #{index} does not match element type #{type_to_string(elem_type)}."
  end

  defp human_reason({:empty_list_type_mismatch, type}) do
    "Got an empty list but expected #{type_to_string(type)}."
  end

  defp human_reason({:proper_list_type_mismatch, type}) do
    "Got a proper list but expected #{type_to_string(type)}."
  end

  defp human_reason({:improper_list_type_mismatch, type}) do
    "Got an improper list but expected #{type_to_string(type)}."
  end

  defp human_reason({:improper_list_terminator_type_mismatch, terminator, terminator_type}) do
    "Improper list terminator #{inspect(terminator)} does not match terminator type #{type_to_string(terminator_type)}."
  end

  defp human_reason({:function_arity_type_mismatch, expected, actual}) do
    "Expected function to have arity #{expected} but got #{actual}."
  end

  defp human_reason({:type_mismatch, value, type}) do
    "Value #{inspect(value)} does not match type #{type_to_string(type)}."
  end

  defp human_reason({:map_key_type_mismatch, key, key_types}) when is_list(key_types) do
    "Map key #{inspect(key)} does not match any of the allowed map key types #{key_types |> Enum.map_join(", ", &type_to_string/1)}."
  end

  defp human_reason({:map_key_type_mismatch, key, key_type}) do
    "Map key #{inspect(key)} does not match map key type #{type_to_string(key_type)}."
  end

  defp human_reason({:map_value_type_mismatch, key, value, value_types})
       when is_list(value_types) do
    "Map value #{inspect(value)} for key #{inspect(key)} does not match any of the allowed map value types #{value_types |> Enum.map_join(", ", &type_to_string/1)}."
  end

  defp human_reason({:map_value_type_mismatch, key, value, value_type}) do
    "Map value #{inspect(value)} for key #{inspect(key)} does not match map value type #{type_to_string(value_type)}."
  end

  defp human_reason({:required_field_unfulfilled_map_type_mismatch, entry_type}) do
    "Could not find a map entry matching #{type_to_string(entry_type)}."
  end

  defp human_reason({:struct_name_type_mismatch, nil, expected_struct_name}) do
    "Expected the value to be #{Utils.module_to_string(expected_struct_name)}."
  end

  defp human_reason({:struct_name_type_mismatch, actual_struct_name, expected_struct_name}) do
    "Expected the value to be a #{Utils.module_to_string(expected_struct_name)}, got a #{Utils.module_to_string(actual_struct_name)}."
  end

  defp human_reason({:module_fetch_failure, module_name}) do
    "Could not load module #{Utils.module_to_string(module_name)}."
  end

  defp human_reason({:remote_type_fetch_failure, {module_name, type_name, arity}}) do
    "Could not find type #{type_name}/#{arity} in #{Utils.module_to_string(module_name)}."
  end

  defp human_reason({:protocol_type_mismatch, value, protocol_name}) do
    "Value #{inspect(value)} does not implement the #{protocol_name} protocol."
  end

  defp message_string(reasons) when is_list(reasons) do
    reasons
    |> Enum.zip(0..length(reasons))
    |> Enum.map_join("\n", fn {reason, index} ->
      reason
      |> human_reason()
      |> leftpad(index)
    end)
  end

  defp message_string(reason) when is_tuple(reason) do
    message_string([reason])
  end

  defp leftpad(string, level) do
    padding =
      for(_ <- 0..level, do: "  ")
      |> Enum.drop(1)
      |> Enum.join()

    padding <> string
  end
end
