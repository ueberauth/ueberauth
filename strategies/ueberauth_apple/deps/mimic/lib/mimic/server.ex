defmodule Mimic.Server do
  use GenServer
  alias Mimic.Cover
  @moduledoc false

  defmodule State do
    @moduledoc false
    defstruct verify_on_exit: MapSet.new(),
              mode: :private,
              global_pid: nil,
              stubs: %{},
              expectations: %{},
              modules_beam: %{},
              modules_to_be_copied: MapSet.new(),
              reset_tasks: %{},
              modules_opts: %{},
              call_history: %{}
  end

  defmodule Expectation do
    @moduledoc false
    defstruct func: nil, num_applied_calls: 0, num_calls: nil
  end

  @long_timeout Application.compile_env(:mimic, :server_timeout, 60_000)

  @spec allow(module, pid, pid) :: {:ok, module} | {:error, :global}
  def allow(module, owner_pid, allowed_pid) do
    GenServer.call(__MODULE__, {:allow, module, owner_pid, allowed_pid})
  end

  @spec verify(pid) :: non_neg_integer
  def verify(pid) do
    GenServer.call(__MODULE__, {:verify, pid}, @long_timeout)
  end

  @spec verify_on_exit(pid) :: :ok
  def verify_on_exit(pid) do
    GenServer.call(__MODULE__, {:verify_on_exit, pid}, @long_timeout)
  end

  @spec stub(module, atom, arity, function) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def stub(module, fn_name, arity, func) do
    GenServer.call(__MODULE__, {:stub, module, fn_name, func, arity, self()}, @long_timeout)
  end

  @spec stub(module) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def stub(module) do
    GenServer.call(__MODULE__, {:stub, module, self()}, @long_timeout)
  end

  @spec stub_with(module, module) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def stub_with(module, mocking_module) do
    GenServer.call(__MODULE__, {:stub_with, module, mocking_module, self()}, @long_timeout)
  end

  @spec expect(module, atom, arity, non_neg_integer, function) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def expect(module, fn_name, arity, num_calls, func) do
    GenServer.call(
      __MODULE__,
      {:expect, {module, fn_name, func, arity}, num_calls, self()},
      @long_timeout
    )
  end

  @spec set_global_mode(pid) :: :ok
  def set_global_mode(owner_pid) do
    GenServer.call(__MODULE__, {:set_global_mode, owner_pid}, @long_timeout)
  end

  @spec set_private_mode :: :ok
  def set_private_mode do
    GenServer.call(__MODULE__, :set_private_mode, @long_timeout)
  end

  @spec get_mode :: :private | :global
  def get_mode do
    GenServer.call(__MODULE__, :get_mode, @long_timeout)
  end

  @spec exit(pid) :: :ok
  def exit(pid) do
    GenServer.cast(__MODULE__, {:exit, pid})
  end

  @spec reset(module) :: :ok
  def reset(module) do
    GenServer.call(__MODULE__, {:reset, module}, @long_timeout)
  end

  @spec soft_reset(module) :: :ok
  def soft_reset(module) do
    GenServer.call(__MODULE__, {:soft_reset, module}, @long_timeout)
  end

  @spec mark_to_copy(module, keyword) :: :ok | {:error, {:module_already_copied, module}}
  def mark_to_copy(module, opts) do
    GenServer.call(__MODULE__, {:mark_to_copy, module, opts}, @long_timeout)
  end

  @spec marked_to_copy?(module) :: boolean
  def marked_to_copy?(module) do
    GenServer.call(__MODULE__, {:marked_to_copy?, module}, @long_timeout)
  end

  @spec get_calls(module, atom, arity) :: {:ok, list(list(term))} | {:error, :not_found}
  def get_calls(module, fn_name, arity) do
    GenServer.call(__MODULE__, {:get_calls, {module, fn_name, arity}, self()})
  end

  def apply(module, fn_name, args) do
    arity = Enum.count(args)
    original_module = Mimic.Module.original(module)

    if function_exported?(original_module, fn_name, arity) do
      caller_pids = [self() | Process.get(:"$callers", [])]

      case allowed_pid(caller_pids, module) do
        {:ok, owner_pid} ->
          do_apply(owner_pid, module, fn_name, arity, args)

        _ ->
          apply_original(module, fn_name, args)
      end
    else
      raise Mimic.Error, module: module, fn_name: fn_name, arity: arity
    end
  end

  defp do_apply(owner_pid, module, fn_name, arity, args) do
    case GenServer.call(__MODULE__, {:apply, owner_pid, module, fn_name, arity, args}, :infinity) do
      {:ok, func} ->
        Kernel.apply(func, args)

      :original ->
        apply_original(module, fn_name, args)

      {:unexpected, :fulfilled} ->
        mfa = Exception.format_mfa(module, fn_name, arity)

        raise Mimic.UnexpectedCallError,
              "#{mfa} called in process #{inspect(self())} but expectations are already fulfilled"

      {:unexpected, num_calls, num_applied_calls} ->
        mfa = Exception.format_mfa(module, fn_name, arity)

        raise Mimic.UnexpectedCallError,
              "expected #{mfa} to be called #{num_calls} time(s) " <>
                "but it has been called #{num_applied_calls} time(s) in process #{inspect(self())}"
    end
  end

  defp apply_original(module, fn_name, args),
    do: Kernel.apply(Mimic.Module.original(module), fn_name, args)

  defp allowed_pid(pids, module) do
    case :ets.lookup(__MODULE__, :mode) do
      [{:mode, :private}] ->
        match = match_spec(pids, module)

        case :ets.select(__MODULE__, match) do
          [] -> :none
          [owner_pid | _] -> {:ok, owner_pid}
        end

      [{:mode, :global, global_pid}] ->
        case :ets.lookup(__MODULE__, {global_pid, module}) do
          [] -> :none
          [{{^global_pid, ^module}, owner_pid}] -> {:ok, owner_pid}
        end
    end
  end

  defp match_spec(pids, module) do
    guards = Enum.map(pids, fn pid -> {:==, :"$1", pid} end)
    orelse = List.to_tuple([:orelse | guards])
    [{{{:"$1", module}, :"$2"}, [orelse], [:"$2"]}]
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    :ets.new(__MODULE__, [:named_table, :protected, :set])
    state = do_set_private_mode(%State{})
    {:ok, state}
  end

  def handle_cast({:exit, pid}, state) do
    {:noreply, clear_data_from_pid(pid, state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_state =
      if MapSet.member?(state.verify_on_exit, pid) do
        state
      else
        clear_data_from_pid(pid, state)
      end

    {:noreply, new_state}
  end

  # Reset task has successfully finished
  def handle_info({ref, :ok}, state) do
    reset_tasks = Map.delete(state.reset_tasks, ref)

    {:noreply, %{state | reset_tasks: reset_tasks}}
  end

  def handle_info(msg, state) do
    IO.puts("handle_info with #{inspect(msg)} not handled")
    {:noreply, state}
  end

  defp clear_data_from_pid(pid, state) do
    expectations = Map.delete(state.expectations, pid)
    stubs = Map.delete(state.stubs, pid)

    select = [{{{pid, :_}}, [], [true]}, {{{:_, :_}, pid}, [], [true]}]

    :ets.select_delete(__MODULE__, select)

    state =
      if pid == state.global_pid do
        do_set_private_mode(state)
      else
        state
      end

    call_history = Map.delete(state.call_history, pid)

    %{state | expectations: expectations, stubs: stubs, call_history: call_history}
  end

  defp find_stub(stubs, module, fn_name, arity, caller) do
    case get_in(stubs, [caller, {module, fn_name, arity}]) do
      func when is_function(func) -> {:ok, func}
      nil -> :unexpected
    end
  end

  defp get_call_history(state, caller, module, fn_name, arity) do
    get_in(state.call_history, [Access.key(caller, %{}), {module, fn_name, arity}])
  end

  defp put_call_history(state, caller, module, fn_name, arity, args) do
    call_history = get_call_history(state, caller, module, fn_name, arity) || []

    %{
      state
      | call_history:
          put_in(
            state.call_history,
            [Access.key(caller, %{}), {module, fn_name, arity}],
            [
              args | call_history
            ]
          )
    }
  end

  def handle_call({:apply, owner_pid, module, fn_name, arity, args}, _from, state) do
    caller =
      if state.mode == :private do
        owner_pid
      else
        state.global_pid
      end

    case get_in(state.expectations, [Access.key(caller, %{}), {module, fn_name, arity}]) do
      [expectation | _] = expectations ->
        case apply_call_to_expectations(expectations, expectation) do
          {:ok, func, new_expectations} ->
            expectations =
              put_in(state.expectations, [caller, {module, fn_name, arity}], new_expectations)

            # Track call history
            state = put_call_history(state, caller, module, fn_name, arity, args)

            {:reply, {:ok, func}, %{state | expectations: expectations}}

          {:unexpected, num_calls, num_applied_calls} ->
            {:reply, {:unexpected, num_calls, num_applied_calls}, state}
        end

      expectations ->
        case {find_stub(state.stubs, module, fn_name, arity, caller), expectations} do
          {{:ok, func}, _} ->
            # Track call history for stubs too
            state = put_call_history(state, caller, module, fn_name, arity, args)

            {:reply, {:ok, func}, state}

          {:unexpected, []} ->
            # expectations for this mfa existed but they have all been fulfilled
            {:reply, {:unexpected, :fulfilled}, state}

          {:unexpected, nil} ->
            # no expectations were ever defined for this mfa
            # This case happens when another mfa was set-up
            {:reply, :original, state}
        end
    end
  end

  def handle_call({:stub, module, fn_name, func, arity, owner}, _from, state) do
    with {:ok, state} <- ensure_module_copied(module, state),
         true <- valid_mode?(state, owner),
         func <- maybe_typecheck_func(module, fn_name, func) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)

      :ets.insert_new(__MODULE__, {{owner, module}, owner})

      {:reply, {:ok, module},
       %{
         state
         | stubs: put_in(state.stubs, [Access.key(owner, %{}), {module, fn_name, arity}], func)
       }}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      false ->
        {:reply, {:error, :not_global_owner}, state}
    end
  end

  def handle_call({:stub, module, owner}, _from, state) do
    with {:ok, state} <- ensure_module_copied(module, state),
         true <- valid_mode?(state, owner) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)

      :ets.insert_new(__MODULE__, {{owner, module}, owner})

      internal_functions = [__info__: 1, module_info: 0, module_info: 1]

      stubs =
        module.module_info(:exports)
        |> Enum.filter(&(&1 not in internal_functions))
        |> Enum.reduce(state.stubs, fn {fn_name, arity}, stubs ->
          func = stub_function(module, fn_name, arity)
          put_in(stubs, [Access.key(owner, %{}), {module, fn_name, arity}], func)
        end)

      {:reply, {:ok, module}, %{state | stubs: stubs}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      false ->
        {:reply, {:error, :not_global_owner}, state}
    end
  end

  def handle_call({:stub_with, mocked_module, mocking_module, owner}, _from, state) do
    with {:ok, state} <- ensure_module_copied(mocked_module, state),
         true <- valid_mode?(state, owner) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)

      :ets.insert_new(__MODULE__, {{owner, mocked_module}, owner})

      original_module = Mimic.Module.original(mocked_module)

      internal_functions = [__info__: 1, module_info: 0, module_info: 1]

      mocked_public_functions =
        original_module.module_info(:exports)
        |> Enum.filter(&(&1 not in internal_functions))
        |> MapSet.new()

      mocking_public_functions =
        mocking_module.module_info(:exports)
        |> Enum.filter(&(&1 not in internal_functions))
        |> MapSet.new()

      will_be_mocked_functions =
        MapSet.intersection(mocking_public_functions, mocked_public_functions)

      will_be_stubbed_functions =
        MapSet.difference(mocked_public_functions, mocking_public_functions)

      stubs =
        will_be_mocked_functions
        |> Enum.reduce(state.stubs, fn {fn_name, arity}, stubs ->
          func = anonymize_module_function(mocking_module, fn_name, arity)
          func = maybe_typecheck_func(mocked_module, fn_name, func)
          put_in(stubs, [Access.key(owner, %{}), {mocked_module, fn_name, arity}], func)
        end)

      stubs =
        will_be_stubbed_functions
        |> Enum.reduce(stubs, fn {fn_name, arity}, stubs ->
          func = stub_function(mocked_module, fn_name, arity)
          put_in(stubs, [Access.key(owner, %{}), {mocked_module, fn_name, arity}], func)
        end)

      {:reply, {:ok, mocked_module}, %{state | stubs: stubs}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      false ->
        {:reply, {:error, :not_global_owner}, state}
    end
  end

  def handle_call({:expect, {module, fn_name, func, arity}, num_calls, owner}, _from, state) do
    with {:ok, state} <- ensure_module_copied(module, state),
         true <- valid_mode?(state, owner),
         func <- maybe_typecheck_func(module, fn_name, func) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)

      :ets.insert_new(__MODULE__, {{owner, module}, owner})

      expectation = %Expectation{func: func, num_calls: num_calls}

      expectations =
        update_in(
          state.expectations,
          [Access.key(owner, %{}), {module, fn_name, arity}],
          &((&1 || []) ++ [expectation])
        )

      {:reply, {:ok, module}, %{state | expectations: expectations}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      false ->
        {:reply, {:error, :not_global_owner}, state}
    end
  end

  def handle_call({:set_global_mode, owner_pid}, _from, state) do
    {:reply, :ok, do_set_global_mode(owner_pid, state)}
  end

  def handle_call(:set_private_mode, _from, state) do
    {:reply, :ok, do_set_private_mode(state)}
  end

  def handle_call(:get_mode, _from, state) do
    {:reply, state.mode, state}
  end

  def handle_call({:allow, module, owner_pid, allowed_pid}, _from, state = %State{mode: :private}) do
    case :ets.lookup(__MODULE__, {owner_pid, module}) do
      [{{^owner_pid, ^module}, actual_owner_pid}] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, actual_owner_pid})

      [] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, owner_pid})
    end

    {:reply, {:ok, module}, state}
  end

  def handle_call(
        {:allow, _module, _owner_pid, _allowed_pid},
        _from,
        state = %State{mode: :global}
      ) do
    {:reply, {:error, :global}, state}
  end

  def handle_call({:verify, pid}, _from, state) do
    expectations = state.expectations[pid] || %{}

    pending =
      for {{module, fn_name, arity}, mfa_expectations} <- expectations,
          expectation = %Expectation{num_applied_calls: num_applied_calls, num_calls: num_calls} <-
            mfa_expectations,
          num_calls != num_applied_calls do
        {{module, fn_name, arity}, expectation.num_calls, expectation.num_applied_calls}
      end

    {:reply, pending, state}
  end

  def handle_call({:verify_on_exit, pid}, _from, state) do
    {:reply, :ok, %{state | verify_on_exit: MapSet.put(state.verify_on_exit, pid)}}
  end

  def handle_call({:soft_reset, _module}, _from, state) do
    state = %{state | expectations: %{}, stubs: %{}, mode: :private, global_pid: nil}
    {:reply, :ok, state}
  end

  def handle_call({:reset, module}, _from, state) do
    state = %{state | modules_to_be_copied: MapSet.delete(state.modules_to_be_copied, module)}

    tasks =
      if Mimic.Module.copied?(module) do
        task = Task.async(fn -> do_reset(module, state) end)

        Map.put(state.reset_tasks, task.ref, task)
      else
        state.reset_tasks
      end

    # Clear the beam modules after starting the tasks (they read the state)
    # This is important for umbrella apps since they'll run app after app
    # and the modules that need to be covered will change between apps
    state = %{state | modules_beam: Map.delete(state.modules_beam, module)}

    # All modules have been reset. We should await all tasks now
    if state.modules_to_be_copied == MapSet.new() do
      tasks
      |> Map.values()
      |> Task.await_many(@long_timeout)

      {:reply, :ok, %{state | reset_tasks: %{}}}
    else
      {:reply, :ok, %{state | reset_tasks: tasks}}
    end
  end

  def handle_call({:marked_to_copy?, module}, _from, state) do
    {:reply, marked_to_copy?(module, state), state}
  end

  def handle_call({:mark_to_copy, module, opts}, _from, state) do
    if marked_to_copy?(module, state) do
      {:reply, {:error, {:module_already_copied, module}}, state}
    else
      # If cover is enabled call ensure_module_copied now
      # Otherwise just store that the module that will be copied
      # and ensure_module_copied/2 will copy it when
      # expect, stub, reject is called
      state = %{
        state
        | modules_to_be_copied: MapSet.put(state.modules_to_be_copied, module),
          modules_opts: Map.put(state.modules_opts, module, opts)
      }

      state =
        if Cover.enabled_for?(module) do
          {:ok, state} = ensure_module_copied(module, state)
          state
        else
          state
        end

      {:reply, :ok, state}
    end
  end

  def handle_call({:get_calls, {module, fn_name, arity}, owner_pid}, _from, state) do
    caller_pids = [self() | Process.get(:"$callers", [])]

    caller_pid =
      case allowed_pid(caller_pids, module) do
        {:ok, owner_pid} -> owner_pid
        _ -> owner_pid
      end

    case ensure_module_copied(module, state) do
      {:ok, state} ->
        case pop_in(state.call_history, [Access.key(caller_pid, %{}), {module, fn_name, arity}]) do
          {calls, call_history} when is_list(calls) ->
            {:reply, {:ok, Enum.reverse(calls)}, %{state | call_history: call_history}}

          {nil, _} ->
            {:reply, {:ok, []}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp maybe_typecheck_func(module, fn_name, func) do
    case module.__mimic_info__() do
      {:ok, %{type_check: true}} ->
        Mimic.TypeCheck.wrap(module, fn_name, func)

      _ ->
        func
    end
  end

  defp marked_to_copy?(module, state) do
    MapSet.member?(state.modules_to_be_copied, module)
  end

  defp do_reset(module, state) do
    case state.modules_beam[module] do
      {beam, coverdata} -> Cover.clear_module_and_import_coverdata!(module, beam, coverdata)
      _ -> Mimic.Module.clear!(module)
    end
  end

  defp ensure_module_copied(module, state) do
    cond do
      Mimic.Module.copied?(module) ->
        {:ok, state}

      MapSet.member?(state.modules_to_be_copied, module) ->
        case Mimic.Module.replace!(module, state.modules_opts[module]) do
          {beam_file, coverdata_path} ->
            modules_beam = Map.put(state.modules_beam, module, {beam_file, coverdata_path})
            {:ok, %{state | modules_beam: modules_beam}}

          :ok ->
            {:ok, state}
        end

      true ->
        {:error, {:module_not_copied, module}}
    end
  end

  defp apply_call_to_expectations(
         expectations,
         expectation = %Expectation{num_applied_calls: num_applied_calls, num_calls: num_calls}
       ) do
    cond do
      num_applied_calls + 1 == num_calls ->
        {:ok, expectation.func, tl(expectations)}

      num_applied_calls + 1 < num_calls ->
        {:ok, expectation.func,
         [%{expectation | num_applied_calls: num_applied_calls + 1} | tl(expectations)]}

      true ->
        {:unexpected, expectation.num_calls, expectation.num_applied_calls + 1}
    end
  end

  defp valid_mode?(state, caller) do
    state.mode == :private or (state.mode == :global and state.global_pid == caller)
  end

  def monitor_if_not_verify_on_exit(pid, verify_on_exit) do
    unless MapSet.member?(verify_on_exit, pid) do
      Process.monitor(pid)
    end
  end

  defp stub_function(module, fn_name, arity) do
    args =
      0..arity
      |> Enum.to_list()
      |> tl
      |> Enum.map(fn i -> Macro.var(String.to_atom("arg_#{i}"), nil) end)

    clause =
      quote do
        unquote_splicing(args) ->
          mfa = Exception.format_mfa(unquote(module), unquote(fn_name), unquote(args))

          raise Mimic.UnexpectedCallError,
                "Stub! Unexpected call to #{mfa} from #{inspect(self())}"
      end

    {fun, _} = Code.eval_quoted({:fn, [], clause})
    fun
  end

  defp anonymize_module_function(module, fn_name, arity) do
    args =
      0..arity
      |> Enum.to_list()
      |> tl
      |> Enum.map(fn i -> Macro.var(String.to_atom("arg_#{i}"), nil) end)

    clause =
      quote do
        unquote_splicing(args) ->
          apply(unquote(module), unquote(fn_name), [unquote_splicing(args)])
      end

    {fun, _} = Code.eval_quoted({:fn, [], clause})
    fun
  end

  defp do_set_global_mode(owner_pid, state) do
    :ets.insert(__MODULE__, {:mode, :global, owner_pid})
    %{state | global_pid: owner_pid, mode: :global}
  end

  defp do_set_private_mode(state) do
    :ets.insert(__MODULE__, {:mode, :private})
    %{state | global_pid: nil, mode: :private}
  end
end
