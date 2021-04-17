defmodule Support.ProviderWithCsrfAttackEnabled do
  @moduledoc false
  use Ueberauth.Strategy
  use Support.Mixins
end
