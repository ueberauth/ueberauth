defmodule Support.ProviderWithCsrfAttackEnabled do
  @moduledoc false

  use Ueberauth.Strategy, ignores_csrf_attack: false
end
