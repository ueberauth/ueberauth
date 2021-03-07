defmodule Support.WithErrors do
  @moduledoc false

  use Ueberauth.Strategy, the_uid: "default uid", ignores_csrf_attack: true
  use Support.Mixins

  def handle_callback!(conn) do
    set_errors!(conn, [error("one", "error one"), error("two", "error two")])
  end
end
