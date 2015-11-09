defmodule Support.DefaultOptions do
  use Ueberauth.Strategy, the_uid: "default uid"
  use Support.Mixins

  def uid(conn), do: options(conn)[:the_uid] || default_options[:the_uid]
end
