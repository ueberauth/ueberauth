defmodule Support.Redirector do
  use Ueberauth.Strategy
  use Support.Mixins

  def request_phase!(conn) do
    redirect!(conn, "https://redirectme.example.com/foo")
  end
end
