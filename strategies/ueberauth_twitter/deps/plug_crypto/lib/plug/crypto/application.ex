defmodule Plug.Crypto.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    children = [
      {Agent, &start_crypto_keys/0}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  defp start_crypto_keys do
    Plug.Crypto.Keys = :ets.new(Plug.Crypto.Keys, [:named_table, :public, read_concurrency: true])
  end
end
