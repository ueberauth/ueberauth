defmodule Support.Redirector do
  use Ueberauth.Strategy
  use Support.Mixins

  def handle_request!(conn) do
    redirect!(conn, "https://redirectme.example.com/foo")
  end
end
