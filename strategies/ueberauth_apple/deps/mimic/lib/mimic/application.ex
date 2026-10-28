defmodule Mimic.Application do
  use Application
  alias Mimic.Server
  @moduledoc false

  def start(_, _) do
    children = [Server]
    Supervisor.start_link(children, name: Mimic.Supervisor, strategy: :one_for_one)
  end
end
