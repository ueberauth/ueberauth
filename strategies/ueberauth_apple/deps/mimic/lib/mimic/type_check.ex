defmodule Mimic.TypeCheckError do
  @moduledoc false
  defexception [:mfa, :reasons]

  @doc false
  @impl Exception
  def exception([mfa, reasons]), do: %__MODULE__{mfa: mfa, reasons: reasons}

  @doc false
  @impl Exception
  def message(exception) do
    {module, name, arity} = exception.mfa
    mfa = Exception.format_mfa(module, name, arity)
    "#{mfa}: #{Ham.TypeMatchError.message(exception)}"
  end
end

defmodule Mimic.TypeCheck do
  @moduledoc false

  # Wrap an anoynomous function with type checking provided by Ham
  @doc false
  @spec wrap(module, atom, (... -> term)) :: (... -> term)
  def wrap(module, fn_name, func) do
    arity = :erlang.fun_info(func)[:arity]

    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    do_wrap(module, behaviours, fn_name, func, arity)
  end

  defp do_wrap(module, behaviours, fn_name, func, 0) do
    fn ->
      apply_and_check(module, behaviours, fn_name, func, [])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 1) do
    fn arg1 ->
      apply_and_check(module, behaviours, fn_name, func, [arg1])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 2) do
    fn arg1, arg2 ->
      apply_and_check(module, behaviours, fn_name, func, [arg1, arg2])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 3) do
    fn arg1, arg2, arg3 ->
      apply_and_check(module, behaviours, fn_name, func, [arg1, arg2, arg3])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 4) do
    fn arg1, arg2, arg3, arg4 ->
      apply_and_check(module, behaviours, fn_name, func, [arg1, arg2, arg3, arg4])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 5) do
    fn arg1, arg2, arg3, arg4, arg5 ->
      apply_and_check(module, behaviours, fn_name, func, [arg1, arg2, arg3, arg4, arg5])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 6) do
    fn arg1, arg2, arg3, arg4, arg5, arg6 ->
      apply_and_check(module, behaviours, fn_name, func, [arg1, arg2, arg3, arg4, arg5, arg6])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 7) do
    fn arg1, arg2, arg3, arg4, arg5, arg6, arg7 ->
      apply_and_check(module, behaviours, fn_name, func, [
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
        arg7
      ])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 8) do
    fn arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8 ->
      apply_and_check(module, behaviours, fn_name, func, [
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
        arg7,
        arg8
      ])
    end
  end

  defp do_wrap(module, behaviours, fn_name, func, 9) do
    fn arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9 ->
      apply_and_check(module, behaviours, fn_name, func, [
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
        arg7,
        arg8,
        arg9
      ])
    end
  end

  defp do_wrap(_module, _behaviours, _fn_name, _func, arity) when arity > 9 do
    raise "Too many arguments!"
  end

  defp apply_and_check(module, behaviours, fn_name, func, args) do
    return_value = Kernel.apply(func, args)

    case Ham.validate(module, fn_name, args, return_value, behaviours: behaviours) do
      :ok ->
        :ok

      {:error, error} ->
        mfa = {module, fn_name, length(args)}
        raise Mimic.TypeCheckError, [mfa, error.reasons]
    end

    return_value
  end
end
