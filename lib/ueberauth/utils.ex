defmodule Ueberauth.Utils do
  def struct_from_params(mod, params) do
    Enum.reduce(
      Map.keys(mod.__struct__),
      struct(mod),
      fn(key, acc) ->
        if key != :__struct__ do
          Map.put(acc, key, params[to_string(key)] || params[key])
        else
          acc
        end
      end
    )
  end

  def struct_from_params(mod, _), do: struct(mod)
end
