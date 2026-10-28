defmodule Makeup.Lexers.HTMLLexer.Application do
  @moduledoc false
  use Application

  alias Makeup.Registry
  alias Makeup.Lexers.HTMLLexer

  def start(_type, _args) do
    Registry.register_lexer(HTMLLexer,
      options: [],
      names: ["html"],
      extensions: ["html"]
    )

    Supervisor.start_link([], strategy: :one_for_one)
  end
end
