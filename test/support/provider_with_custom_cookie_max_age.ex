defmodule Support.ProviderWithCustomCookieMaxAge do
  @moduledoc false
  use Ueberauth.Strategy,
    state_param_cookie_max_age: 1800

  use Support.Mixins
end
