defmodule Ueberauth.Config do
  @moduledoc false

  Module.put_attribute(
    __MODULE__,
    :poison,
    if(Code.ensure_loaded?(Poison), do: Poison, else: nil)
  )

  Module.put_attribute(
    __MODULE__,
    :jason,
    if(Code.ensure_loaded?(Jason), do: Jason, else: nil)
  )

  @doc """
  Return the configured json lib
  """
  @json_lib Application.get_env(:ueberauth, :json_library) || @jason || @poison
  def json_library do
    @json_lib
  end
end
