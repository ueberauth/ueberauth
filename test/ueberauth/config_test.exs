defmodule Ueberauth.ConfigTest do
  # Not async: temporarily removes the global :ueberauth config.
  use ExUnit.Case, async: false

  test "init/1 raises a descriptive error when no providers are configured" do
    config = Application.fetch_env!(:ueberauth, Ueberauth)
    Application.put_env(:ueberauth, Ueberauth, Keyword.delete(config, :providers))
    on_exit(fn -> Application.put_env(:ueberauth, Ueberauth, config) end)

    assert_raise ArgumentError, ~r/no Ueberauth providers are configured/, fn ->
      Ueberauth.init()
    end
  end
end
