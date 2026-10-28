defmodule Mock do
  @moduledoc """
  Mock modules for testing purposes. Usually inside a unit test.

  Please see the README file on github for a tutorial

  ## Example

      defmodule MyTest do
        use ExUnit.Case
        import Mock

        test "get" do
          with_mock HTTPotion,
              [get: fn("http://example.com", _headers) ->
                      HTTPotion.Response.new(status_code: 200,
                          body: "hello") end] do
            # Code which calls HTTPotion.get
            # Check that the call was made as we expected
            assert called HTTPotion.get("http://example.com", :_)
          end
        end
      end
  """

  @doc """
  Mock up `mock_module` with functions specified as a keyword
  list of function_name:implementation `mocks` for the duration
  of `test`.

  `opts` List of optional arguments passed to meck. `:passthrough` will
   passthrough arguments to the original module.

  ## Example

      with_mock HTTPotion, [get: fn("http://example.com") ->
           "<html></html>" end] do
         # Tests that make the expected call
         assert called HTTPotion.get("http://example.com")
      end
  """
  defmacro with_mock(mock_module, opts \\ [], mocks, do: test) do
    quote do
      unquote(__MODULE__).with_mocks(
        [{unquote(mock_module), unquote(opts), unquote(mocks)}],
        do: unquote(test)
      )
    end
  end

  @doc """
  Mock up multiple modules for the duration of `test`.

  ## Example
      with_mocks([{HTTPotion, opts, [get: fn("http://example.com") -> "<html></html>" end]}]) do
        # Tests that make the expected call
        assert called HTTPotion.get("http://example.com")
      end
  """
  defmacro with_mocks(mocks, do: test) do
    quote do
      mock_modules = mock_modules(unquote(mocks))

      try do
        unquote(test)
      after
        for m <- mock_modules, do: :meck.unload(m)
      end
    end
  end

  @doc """
  Shortcut to avoid multiple blocks when a test requires a single
  mock.

  For full description see `with_mock`.

  ## Example

      test_with_mock "test_name", HTTPotion,
        [get: fn(_url) -> "<html></html>" end] do
        HTTPotion.get("http://example.com")
        assert called HTTPotion.get("http://example.com")
      end
  """
  defmacro test_with_mock(test_name, mock_module, opts \\ [], mocks, test_block) do
    quote do
      test unquote(test_name) do
        unquote(__MODULE__).with_mock(
          unquote(mock_module),
          unquote(opts),
          unquote(mocks),
          unquote(test_block)
        )
      end
    end
  end

  @doc """
  Shortcut to avoid multiple blocks when a test requires a single
  mock. Accepts a context argument enabling information to be shared
  between callbacks and the test.

  For full description see `with_mock`.

  ## Example
      setup do
        doc = "<html></html>"
        {:ok, doc: doc}
      end

      test_with_mock "test_with_mock with context", %{doc: doc}, HTTPotion, [],
        [get: fn(_url) -> doc end] do

        HTTPotion.get("http://example.com")
        assert called HTTPotion.get("http://example.com")
      end
  """
  defmacro test_with_mock(test_name, context, mock_module, opts, mocks, test_block) do
    quote do
      test unquote(test_name), unquote(context) do
        unquote(__MODULE__).with_mock(
          unquote(mock_module),
          unquote(opts),
          unquote(mocks),
          unquote(test_block)
        )
      end
    end
  end

  @doc """
  Call original function inside mock anonymous function.
  Allows overriding only a certain behavior of a function.
  Compatible with passthrough option.

  ## Example

      with_mock String, [:passthrough], [reverse: fn(str) ->
           passthrough([str]) <> "!" end] do
         assert String.reverse("xyz") == "zyx!"
      end
  """
  defmacro passthrough(args) do
    quote do
      :meck.passthrough(unquote(args))
    end
  end

  @doc """
  Use inside a `with_mock` block to determine whether
  a mocked function was called as expected.

  Pass `:_` as a function argument for wildcard matches.

  ## Example

      assert called HTTPotion.get("http://example.com")

      # Matches any invocation
      assert called HTTPotion.get(:_)
  """
  defmacro called({{:., _, [module, f]}, _, args}) do
    quote do
      :meck.called(unquote(module), unquote(f), unquote(args))
    end
  end

  @doc """
  Use inside a `with_mock` block to determine whether
  a mocked function was called as expected. If the assertion fails,
  the calls that were received are displayed in the assertion message.

  Pass `:_` as a function argument for wildcard matches.

  ## Example

      assert_called HTTPotion.get("http://example.com")

      # Matches any invocation
      assert_called HTTPotion.get(:_)
  """
  defmacro assert_called({{:., _, [module, f]}, _, args}) do
    quote do
      unquoted_module = unquote(module)
      value = :meck.called(unquoted_module, unquote(f), unquote(args))

      unless value do
        calls =
          unquoted_module
          |> :meck.history()
          |> Enum.with_index()
          |> Enum.map(fn {{_, {m, f, a}, ret}, i} ->
            "#{i}. #{m}.#{f}(#{a |> Enum.map(&Kernel.inspect/1) |> Enum.join(",")}) (returned #{inspect(ret)})"
          end)
          |> Enum.join("\n")

        raise ExUnit.AssertionError,
          message: "Expected call but did not receive it. Calls which were received:\n\n#{calls}"
      end
    end
  end

  @doc """
    Use inside a `with_mock` block to determine whether a mocked function was called
    as expected exactly x times. If the assertion fails, the number of calls that
    were received is displayed in the assertion message.

    Pass `:_` as a function argument for wildcard matches.

    ## Example

        assert_called_exactly HTTPotion.get("http://example.com"), 2

        # Matches any invocation
        assert_called_exactly HTTPotion.get(:_), 2
  """
  defmacro assert_called_exactly({{:., _, [module, f]}, _, args}, call_times) do
    quote do
      unquoted_module = unquote(module)
      unquoted_f = unquote(f)
      unquoted_args = unquote(args)
      unquoted_call_times = unquote(call_times)
      num_calls = :meck.num_calls(unquoted_module, unquoted_f, unquoted_args)

      if num_calls != unquoted_call_times do
        mfa_str =
          "#{unquoted_module}.#{unquoted_f}(#{unquoted_args |> Enum.map(&Kernel.inspect/1) |> Enum.join(", ")})"

        raise ExUnit.AssertionError,
          message:
            "Expected #{mfa_str} to be called exactly #{unquoted_call_times} time(s), but it was called (number of calls: #{num_calls})"
      end
    end
  end

  @doc """
    Use inside a `with_mock` block to determine whether a mocked function was called
    as expected at least x times. If the assertion fails, the number of calls that
    were received is displayed in the assertion message.

    Pass `:_` as a function argument for wildcard matches.

    ## Example

        assert_called_at_least HTTPotion.get("http://example.com"), 2

        # Matches any invocation
        assert_called_at_leaset HTTPotion.get(:_), 2
  """
  defmacro assert_called_at_least({{:., _, [module, f]}, _, args}, expected_times) do
    quote do
      unquoted_module = unquote(module)
      unquoted_f = unquote(f)
      unquoted_args = unquote(args)
      unquoted_expected_times = unquote(expected_times)
      actual_called_count = :meck.num_calls(unquoted_module, unquoted_f, unquoted_args)

      if actual_called_count < unquoted_expected_times do
        mfa_str =
          "#{unquoted_module}.#{unquoted_f}(#{unquoted_args |> Enum.map(&Kernel.inspect/1) |> Enum.join(", ")})"

        raise ExUnit.AssertionError,
          message:
            "Expected #{mfa_str} to be called at least #{unquoted_expected_times} time(s), but it was called (number of calls: #{actual_called_count})"
      end
    end
  end

  @doc """
  Use inside a `with_mock` block to check if
  a mocked function was NOT called. If the assertion fails,
  the number of calls is displayed in the assertion message.

  Pass `:_` as a function argument for wildcard matches.

  ## Example

      assert_not_called HTTPotion.get("http://example.com")

      # Matches any invocation
      assert_not_called HTTPotion.get(:_)
  """
  defmacro assert_not_called({{:., _, [module, f]}, _, args}) do
    quote do
      unquoted_module = unquote(module)
      unquoted_f = unquote(f)
      unquoted_args = unquote(args)
      num_calls = :meck.num_calls(unquoted_module, unquoted_f, unquoted_args)

      if num_calls > 0 do
        mfa_str =
          "#{unquoted_module}.#{unquoted_f}(#{unquoted_args |> Enum.map(&Kernel.inspect/1) |> Enum.join(", ")})"

        raise ExUnit.AssertionError,
          message:
            "Expected #{mfa_str} not to be called, but it was called (number of calls: #{num_calls})"
      end
    end
  end

  @doc """
  Helper function to get the history of mock functions executed.

  ## Example

      iex> assert call_history(HTTPotion) == [
          {pid, {HTTPotion, :get, ["http://example.com"]}, some_return_value}
        ]

  """
  defmacro call_history(module) do
    quote do
      unquoted_module = unquote(module)

      unquoted_module
      |> :meck.history()
    end
  end

  @doc """
  Mocks up multiple modules prior to the execution of each test in a case and
  execute the callback specified.

  For full description of mocking, see `with_mocks`.

  For a full description of ExUnit setup, see
  https://hexdocs.pm/ex_unit/ExUnit.Callbacks.html

  ## Example
      setup_with_mocks([
        {Map, [], [get: fn(%{}, "http://example.com") -> "<html></html>" end]}
      ]) do
        foo = "bar"
        {:ok, foo: foo}
      end

      test "setup_all_with_mocks base case" do
        assert Map.get(%{}, "http://example.com") == "<html></html>"
      end
  """
  defmacro setup_with_mocks(mocks, do: setup_block) do
    quote do
      setup do
        mock_modules(unquote(mocks))

        on_exit(fn ->
          :meck.unload()
        end)

        unquote(setup_block)
      end
    end
  end

  @doc """
  Mocks up multiple modules prior to the execution of each test in a case and
  execute the callback specified with a context specified

  See `setup_with_mocks` for more details

  ## Example
      setup_with_mocks([
        {Map, [], [get: fn(%{}, "http://example.com") -> "<html></html>" end]}
      ], context) do
        {:ok, test_string: Atom.to_string(context.test)}
      end

      test "setup_all_with_mocks with context", %{test_string: test_string} do
        assert Map.get(%{}, "http://example.com") == "<html></html>"
        assert test_string == "test setup_all_with_mocks with context"
      end
  """
  defmacro setup_with_mocks(mocks, context, do: setup_block) do
    quote do
      setup unquote(context) do
        mock_modules(unquote(mocks))

        on_exit(fn ->
          :meck.unload()
        end)

        unquote(setup_block)
      end
    end
  end

  @doc """
  Shortcut to avoid multiple blocks when a test requires multiple
  mocks.

  For full description see `test_with_mocks`.

  ## Example

      test_with_mocks "test_name", [{HTTPotion,[],
        [get: fn(_url) -> "<html></html>" end]}] do
        HTTPotion.get("http://example.com")
        assert called HTTPotion.get("http://example.com")
      end
  """
  defmacro test_with_mocks(test_name, mocks, test_block) do
    quote do
      test unquote(test_name) do
        unquote(__MODULE__).with_mocks(
          unquote(mocks),
          unquote(test_block)
        )
      end
    end
  end

  @doc """
  Shortcut to avoid multiple blocks when a test requires multiple
  mocks. Accepts a context argument enabling information to be shared
  between callbacks and the test.

  For full description see `test_with_mocks`.

  ## Example

      test_with_mocks "test_name", %{foo: foo} [{HTTPotion,[],
        [get: fn(_url) -> "<html></html>" end]}] do
        HTTPotion.get("http://example.com")
        assert called HTTPotion.get("http://example.com")
        assert foo == "bar"
      end
  """
  defmacro test_with_mocks(test_name, context, mocks, test_block) do
    quote do
      test unquote(test_name), unquote(context) do
        unquote(__MODULE__).with_mocks(
          unquote(mocks),
          unquote(test_block)
        )
      end
    end
  end

  ######################################################

  # Helper macro to mock modules. Intended to be called only within this module
  # but not defined as `defmacrop` due to the scope within which it's used.
  defmacro mock_modules(mocks) do
    quote do
      Enum.reduce(unquote(mocks), [], fn {m, opts, mock_fns}, ms ->
        unless m in ms do
          # :meck.validate will throw an error if trying to validate
          # a module that was not mocked
          try do
            if :meck.validate(m), do: :meck.unload(m)
          rescue
            e in ErlangError -> :ok
          end

          :meck.new(m, opts)
        end

        unquote(__MODULE__)._install_mock(m, mock_fns)
        true = :meck.validate(m)

        [m | ms] |> Enum.uniq()
      end)
    end
  end

  @doc false
  def _install_mock(_, []), do: :ok

  def _install_mock(mock_module, [{fn_name, value} | tail]) do
    :meck.expect(mock_module, fn_name, value)
    _install_mock(mock_module, tail)
  end

  def in_series(signature, results) do
    {signature, :meck.seq(results)}
  end
end
