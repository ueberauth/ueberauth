defmodule Ueberauth.Config do
  @moduledoc """
  A json library is required for Ueberauth to operate.
  In config.exs your implicit or expicit configuration is:
    config ueberauth,
      json_library: Jason # defaults to Jason but can be configured to Poison

  In mix.exs you will need something like:
    def deps() do
      [
        ...
        {:jason, :version} # or {:poison, :version}
      ]
    end

  This file will serve underlying Ueberauth libraries as a hook to grab the
  configured json library.
  """

  @doc """
  Return the configured json lib
  """
  def json_library do
    Application.get_env(:ueberauth, :json_library, Jason)
  end
end
