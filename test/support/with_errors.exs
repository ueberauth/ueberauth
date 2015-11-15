defmodule Support.WithErrors do
  use Ueberauth.Strategy, the_uid: "default uid"
  use Support.Mixins

  def handle_callback!(conn) do
    set_errors!(conn, [error("one", "error one"), error("two", "error two")])
  end
end
