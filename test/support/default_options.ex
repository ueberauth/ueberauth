defmodule Support.DefaultOptions do
  @moduledoc false

  use Ueberauth.Strategy, the_uid: "default uid", ignores_csrf_attack: true
  use Support.Mixins

  def uid(conn), do: options(conn)[:the_uid] || default_options()[:the_uid]
end
