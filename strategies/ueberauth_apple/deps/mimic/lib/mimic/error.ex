defmodule Mimic.Error do
  defexception ~w(module fn_name arity)a
  @moduledoc false

  def message(e) do
    mfa = Exception.format_mfa(e.module, e.fn_name, e.arity)
    "#{mfa} cannot be stubbed as original module does not export such function"
  end
end
