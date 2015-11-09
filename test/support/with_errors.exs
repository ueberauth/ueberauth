defmodule Support.WithErrors do
  use Ueberauth.Strategy, the_uid: "default uid"
  use Support.Mixins

  def callback_phase!(conn) do
    set_errors!(conn, [error("one", "error one"), error("two", "error two")])
  end
end
