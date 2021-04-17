defmodule Support.SimpleCallback do
  @moduledoc false

  use Ueberauth.Strategy, ignores_csrf_attack: true
  use Support.Mixins
end
