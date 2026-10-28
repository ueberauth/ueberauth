defmodule Ham.Utils do
  @moduledoc false

  def module_to_string(module_name) do
    module_name
    |> Atom.to_string()
    |> String.split(".")
    |> Enum.drop(1)
    |> Enum.join(".")
  end

  def replace_user_types(type, module_name) do
    type_map(type, fn
      {:user_type, _, name, args} ->
        {:remote_type, 0, [{:atom, 0, module_name}, {:atom, 0, name}, args]}

      other ->
        other
    end)
  end

  def type_map(type, map_fun) do
    case map_fun.(type) do
      {:type, position, name, params} when is_list(params) ->
        {:type, position, name, Enum.map(params, fn param -> type_map(param, map_fun) end)}

      {:user_type, position, name, params} when is_list(params) ->
        {:user_type, position, name, Enum.map(params, fn param -> type_map(param, map_fun) end)}

      {:ann_type, position, [var, ann_type]} ->
        {:ann_type, position, [var, type_map(ann_type, map_fun)]}

      {:remote_type, position, [module_name, name, params]} ->
        {:remote_type, position,
         [module_name, name, Enum.map(params, fn param -> type_map(param, map_fun) end)]}

      other ->
        other
    end
  end

  def check_module_exists(module) do
    Code.ensure_compiled!(module)
  end

  # ordinalize is originally from the Ordinal package
  # https://github.com/andrewhao/ordinal
  # Copyright (c) 2018 Andrew Hao
  @spec ordinalize(integer()) :: String.t()
  def ordinalize(number) when is_integer(number) and number >= 0 do
    [to_string(number), suffix(number)]
    |> IO.iodata_to_binary()
  end

  def ordinalize(number), do: number

  defp suffix(num) when is_integer(num) and num > 100,
    do: rem(num, 100) |> suffix()

  defp suffix(num) when num in 11..13, do: "th"
  defp suffix(num) when num > 10, do: rem(num, 10) |> suffix()
  defp suffix(1), do: "st"
  defp suffix(2), do: "nd"
  defp suffix(3), do: "rd"
  defp suffix(_), do: "th"

  def type_to_string({:type, _, :map_field_exact, [type1, type2]}) do
    "required(#{type_to_string(type1)}) => #{type_to_string(type2)}"
  end

  def type_to_string({:type, _, :map_field_assoc, [type1, type2]}) do
    "optional(#{type_to_string(type1)}) => #{type_to_string(type2)}"
  end

  def type_to_string(type) do
    # We really want to access Code.Typespec.typespec_to_quoted/1 here but it's
    # private... this hack needs to suffice.
    macro =
      {:foo, type, []}
      |> Code.Typespec.type_to_quoted()

    macro
    |> Macro.to_string()
    |> String.split("\n")
    |> Enum.map_join(&String.replace(&1, ~r/ +/, " "))
    |> String.split(" :: ", parts: type_parts(macro))
    |> case do
      [_foo, type_string] -> type_string
      [_foo, type_name, type_string] -> "#{type_string} (\"#{type_name}\")"
    end
  end

  defp type_parts(macro) do
    case macro do
      # The type has a name
      {:"::", [], [{:foo, [], []}, {:"::", _, _}]} -> 3
      _ -> 2
    end
  end
end
