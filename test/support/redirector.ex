defmodule Support.Redirector do
  @moduledoc false

  use Ueberauth.Strategy, ignores_csrf_attack: true
  use Support.Mixins

  def handle_request!(conn) do
    redirect!(conn, "https://redirectme.example.com/foo")
  end
end
