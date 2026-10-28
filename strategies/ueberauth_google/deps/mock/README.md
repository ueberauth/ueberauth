[![Build Status](https://travis-ci.org/jjh42/mock.svg?branch=master)](https://travis-ci.org/jjh42/mock)

# Mock
A mocking library for the Elixir language.

We use the Erlang [meck library](https://github.com/eproxus/meck) to provide
module mocking functionality for Elixir. It uses macros in Elixir to expose the
functionality in a convenient manner for integrating in Elixir tests.

See the full [reference documentation](https://hexdocs.pm/mock/Mock.html).

# Table of Contents
* [Mock](#Mock)
	* [Installation](#Installation)
	* [*with_mock* - Mocking a single module](#with_mock---Mocking-a-single-module)
	* [*with_mocks* - Mocking multiple modules](#with_mocks---Mocking-multiple-modules)
	* [*test_with_mock* - with_mock helper](#test_with_mock---with_mock-helper)
	* [*setup_with_mocks* - Configure all tests to have the same mocks](#setup_with_mocks---Configure-all-tests-to-have-the-same-mocks)
	* [Mocking input dependent output](#Mocking-input-dependent-output)
	* [Mocking functions with different arities](#Mocking-functions-with-different-arities)
	* [Mocking repeated calls to the same function with different results](#mock-repeated-calls)
	* [*passthrough* - partial mocking of a module](#passthrough---partial-mocking-of-a-module)
	* [Assert called - assert a specific function was called](#Assert-called---assert-a-specific-function-was-called)
		* [Assert called - specific value](#Assert-called---specific-value)
		* [Assert called - wildcard](#Assert-called---wildcard)
		* [Assert called - pattern matching](#Assert-called---pattern-matching)
		* [Assert call order](#Assert-call-order)
	* [Assert not called - assert a specific function was not called](#Assert-not-called---assert-a-specific-function-was-not-called)
	* [Assert called exactly - assert a specific function was called exactly x times](#Assert-called-exactly---assert-a-specific-function-was-called-exactly-x-times)
	* [Assert called at least - assert a specific function was called at least x times](#Assert-called-at-least---assert-a-specific-function-was-called-at-least-x-times)
	* [NOT SUPPORTED - Mocking internal function calls](#NOT-SUPPORTED---Mocking-internal-function-calls)
	* [Tips](#Tips)
	* [Help](#Help)
	* [Suggestions](#Suggestions)

## Installation
First, add mock to your `mix.exs` dependencies:

```elixir
def deps do
  [{:mock, "~> 0.3.0", only: :test}]
end
```

and run `$ mix deps.get`.

## *with_mock* - Mocking a single module
The Mock library provides the `with_mock` macro for running tests with
mocks.

For a simple example, if you wanted to test some code which calls
`HTTPotion.get` to get a webpage but without actually fetching the
webpage you could do something like this:

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock HTTPotion, [get: fn(_url) -> "<html></html>" end] do
      assert "<html></html>" == HTTPotion.get("http://example.com")
    end
  end
end
````

The `with_mock` macro creates a mock module. The keyword list provides a set
of mock implementation for functions we want to provide in the mock (in
this case just `get`). Inside `with_mock` we exercise the test code
and we can check that the call was made as we expected using `called` and
providing the example of the call we expected.

## *with_mocks* - Mocking multiple modules

You can mock up multiple modules with `with_mocks`.

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "multiple mocks" do
    with_mocks([
      {Map,
       [],
       [get: fn(%{}, "http://example.com") -> "<html></html>" end]},
      {String,
       [],
       [reverse: fn(x) -> 2*x end,
        length: fn(_x) -> :ok end]}
    ]) do
      assert Map.get(%{}, "http://example.com") == "<html></html>"
      assert String.reverse(3) == 6
      assert String.length(3) == :ok
    end
  end
end
````

The second parameter of each tuple is `opts` - a list of optional arguments
passed to meck.

## *test_with_mock* - with_mock helper

An additional convenience macro `test_with_mock` is supplied which internally
delegates to `with_mock`. Allowing the above test to be written as follows:

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test_with_mock "test_name", HTTPotion,
    [get: fn(_url) -> "<html></html>" end] do
    HTTPotion.get("http://example.com")
    assert_called HTTPotion.get("http://example.com")
  end
end
````

The `test_with_mock` macro can also be passed a context argument
allowing the sharing of information between callbacks and the test

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  setup do
    doc = "<html></html>"
    {:ok, doc: doc}
  end

  test_with_mock "test_with_mock with context", %{doc: doc}, HTTPotion, [],
    [get: fn(_url, _headers) -> doc end] do

    HTTPotion.get("http://example.com", [foo: :bar])
    assert_called HTTPotion.get("http://example.com", :_)
  end
end
````

## *setup_with_mocks* - Configure all tests to have the same mocks

The `setup_with_mocks` mocks up multiple modules prior to every single test
along while calling the provided setup block. It is simply an integration of the
`with_mocks` macro available in this module along with the [`setup`](https://hexdocs.pm/ex_unit/ExUnit.Callbacks.html#setup/1)
macro defined in elixir's `ExUnit`.

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false
  import Mock

  setup_with_mocks([
    {Map, [], [get: fn(%{}, "http://example.com") -> "<html></html>" end]}
  ]) do
    foo = "bar"
    {:ok, foo: foo}
  end

  test "setup_with_mocks" do
    assert Map.get(%{}, "http://example.com") == "<html></html>"
  end
end
````

The behaviour of a mocked module within the setup call can be overridden using any
of the methods above in the scope of a specific test. Providing this functionality
by `setup_all` is more difficult, and as such, `setup_all_with_mocks` is not currently
supported.

Currently, mocking modules cannot be done asynchronously, so make sure that you
are not using `async: true` in any module where you are testing.

Also, because of the way mock overrides the module, it must be defined in a
separate file from the test file.

## Mocking input dependent output

If you have a function that should return different values depending on what the
input is, you can do as follows:

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "mock functions with multiple returns" do
    with_mock(Map, [
      get: fn
        (%{}, "http://example.com") -> "<html>Hello from example.com</html>"
        (%{}, "http://example.org") -> "<html>example.org says hi</html>"
        (%{}, url) -> conditionally_mocked(url)
      end
    ]) do
      assert Map.get(%{}, "http://example.com") == "<html>Hello from example.com</html>"
      assert Map.get(%{}, "http://example.org") == "<html>example.org says hi</html>"
      assert Map.get(%{}, "http://example.xyz") == "<html>Hello from example.xyz</html>"
      assert Map.get(%{}, "http://example.tech") == "<html>example.tech says hi</html>"
    end
  end

  def conditionally_mocked(url) do
    cond do
      String.contains?(url, ".xyz") -> "<html>Hello from example.xyz</html>"
      String.contains?(url, ".tech") -> "<html>example.tech says hi</html>"
    end
  end
end
````

## Mocking functions with different arities

You can mock functions in the same module with different arity:

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "mock functions with different arity" do
    with_mock String,
      [slice: fn(string, range)      -> string end,
       slice: fn(string, range, len) -> string end]
    do
      assert String.slice("test", 1..3) == "test"
      assert String.slice("test", 1, 3) == "test"
    end
  end
end

````

## Mock repeated calls

You can mock repeated calls to the same function _and_ arguments to return
different results in a series using the `in_series` call with static values.
This does not currently support _functions_.

**Caution**: This is only useful in rare instances where the underlying business
logic is likely to be stateful. If you can avoid it by using different function
arguments, or refactor the function to be stateful, consider that approach first.

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "mock repeated calls with in_series" do
    with_mock String,
      [slice: [in_series(["test", 1..3], ["string1", "string2", "string3"])]]
    do
      assert String.slice("test", 1..3) == "string1"
      assert String.slice("test", 1..3) == "string2"
      assert String.slice("test", 1..3) == "string3"
    end
  end
end

````

## *passthrough* - partial mocking of a module

By default, only the functions being mocked can be accessed from within the test.
Trying to call a non-mocked function from a mocked Module will result in an error.
This can be circumvented by passing the `:passthrough` option like so:

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false
  import Mock

  test_with_mock "test_name", IO, [:passthrough], [] do
    IO.puts "hello"
    assert_called IO.puts "hello"
  end
end
````

## Assert called - assert a specific function was called

You can check whether or not your mocked module was called.

### Assert called - specific value

It is possible to assert that the mocked module was called with a specific input.

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock HTTPotion, [get: fn(_url) -> "<html></html>" end] do
      HTTPotion.get("http://example.com")
      assert_called HTTPotion.get("http://example.com")
    end
  end
end
````

### Assert called - wildcard

It is also possible to assert that the mocked module was called with any value
by passing the `:_` wildcard.

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock HTTPotion, [get: fn(_url) -> "<html></html>" end] do
      HTTPotion.get("http://example.com")
      assert_called HTTPotion.get(:_)
    end
  end
end
````

### Assert called - pattern matching

`assert_called` will check argument equality using `==` semantics, not pattern matching.
For structs, you must provide every property present on the argument as it was called or
it will fail. To use pattern matching (useful when you only care about a few properties on
the argument or need to perform advanced matching like regex matching), provide custom
argument matcher(s) using [`:meck.is/1`](https://hexdocs.pm/meck/meck.html#is-1).

```` elixir
defmodule User do
  defstruct [:id, :name, :email]
end

defmodule Network do
  def update(%User{} = user), do: # ...
end

defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock Network, [update: fn(_user) -> :ok end] do
      user = %User{id: 1, name: "Jane Doe", email: "jane.doe@gmail.com"}
      Network.update(user)

      assert_called Network.update(
        :meck.is(fn user ->
          assert user.__struct__ == User
          assert user.id == 1

          # matcher must return true when the match succeeds
          true
        end)
      )
    end
  end
end
````

## Assert not called - assert a specific function was not called

`assert_not_called` will assert that a mocked function was not called.

```elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock HTTPotion, [get: fn(_url) -> "<html></html>" end] do
      # Using Wildcard
      assert_not_called HTTPotion.get(:_)

      HTTPotion.get("http://example.com")

      # Using Specific Value
      assert_not_called HTTPotion.get("http://another-example.com")
    end
  end
end
```

## Assert called exactly - assert a specific function was called exactly x times

`assert_called_exactly` will assert that a mocked function was called exactly the expected number of times.

```elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock HTTPotion, [get: fn(_url) -> "<html></html>" end] do
      HTTPotion.get("http://example.com")
      HTTPotion.get("http://example.com")

      # Using Wildcard
      assert_called_exactly HTTPotion.get(:_), 2

      # Using Specific Value
      assert_called_exactly HTTPotion.get("http://example.com"), 2
    end
  end
end
```

## Assert called at least - assert a specific function was called at least x times

`assert_called_at_least` will assert that a mocked function was called at least the expected number of times.

```elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock HTTPotion, [get: fn(_url) -> "<html></html>" end] do
      HTTPotion.get("http://example.com")
      HTTPotion.get("http://example.com")
      HTTPotion.get("http://example.com")

      # Using Wildcard
      assert_called_at_least HTTPotion.get(:_), 2

      # Using Specific Value
      assert_called_at_least HTTPotion.get("http://example.com"), 2
    end
  end
end
```



### Assert call order

`call_history` will return the `meck.history(Module)` allowing you assert on the order of the function invocation:

```elixir
defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock HTTPotion, [get: fn(_url) -> "<html></html>" end] do
      HTTPotion.get("http://example.com")

      assert call_history(HTTPotion) ==
        [
          {pid, {HTTPotion, :get, ["http://example.com"]}, "<html></html>"}
        ]
    end
  end
end
```


You can use any valid Elixir pattern matching/multiple function heads to accomplish
this more succinctly, but remember that the matcher will be executed for _all_ function
calls, so be sure to include a fallback case that returns `false`. For mocked functions
with multiple arguments, you must include a matcher/pattern for each argument.

```` elixir
defmodule Network.V2 do
  def update(%User{} = user, changes), do: # ...

  def update(id, changes) when is_integer(id), do: # ...

  def update(_, _), do: # ...
end

defmodule MyTest do
  use ExUnit.Case, async: false

  import Mock

  test "test_name" do
    with_mock Network.V2, [update: fn(_user, _changes) -> :ok end] do
      Network.V2.update(%User{id: 456, name: "Jane Doe"}, %{name: "John Doe"})
      Network.V2.update(123, %{name: "John Doe", email: "john.doe@gmail.com"})
      Network.V2.update(nil, %{})

      # assert that `update` was called with user id 456
      assert_called Network.V2.update(
        :meck.is(fn
          %User{id: 456} -> true
          _ -> false
        end),
        :_
      )

      # assert that `update` was called with an email change
      assert_called Network.V2.update(
        :_,
        :meck.is(fn
          %{email: "john.doe@gmail.com"} -> true
          _ -> false
        end)
      )
    end
  end
end
````

## NOT SUPPORTED

### Mocking internal function calls

A common issue a lot of developers run into is Mock's lack of support for mocking
internal functions. Mock will behave as follows:

```` elixir
defmodule MyApp.IndirectMod do

  def value do
    1
  end

  def indirect_value do
    value()
  end

  def indirect_value_2 do
    MyApp.IndirectMod.value()
  end

end
````

```` elixir
defmodule MyTest do
  use ExUnit.Case, async: false
  import Mock

  test "indirect mock" do
    with_mocks([
      { MyApp.IndirectMod, [:passthrough], [value: fn -> 2 end] },
    ]) do
      # The following assert succeeds
      assert MyApp.IndirectMod.indirect_value_2() == 2
      # The following assert also succeeds
      assert MyApp.IndirectMod.indirect_value() == 1
    end
  end
end
````

It is important to understand that only fully qualified function calls get mocked.
The reason for this is because of the way Meck is structured. Meck creates a thin wrapper module with the name of the mocked module (and passes through any calls to the original
Module in case passthrough is used). The original module is renamed, but otherwise unmodified. Once the call enters the original module, the local function call jumps stay in the module.

Big thanks to @eproxus (author of Meck) who helped explain this to me. We're looking
into some alternatives to help solve this, but it is something to be aware of in the meantime. The issue is being tracked in [Issue 71](https://github.com/jjh42/mock/issues/71).

In order to workaround this issue, the `indirect_value` can be rewritten like so:
```` elixir
  def indirect_value do
    __MODULE__.value()
  end
````

Or, like so:

```` elixir
  def indirect_value do
    MyApp.IndirectMod.value()
  end
````

### Mocking macros

Currently mocking macros is not supported. For example this will not work because `Logger.error/1` is a macro:

```elixir
with_mock Logger, [error: fn(_) -> 42 end] do
   assert Logger.error("msg") == 42
end
```

This code will give you this error: `Erlang error: {:undefined_function, {Logger, :error, 1}}`

As a workaround, you may define a wrapper function for the macro you need to invoke:

```elixir
defmodule MyModule do
  def log_error(arg) do
    Logger.error(arg)
  end
end
```

Then in your test you can mock that wrapper function:

```elixir
with_mock MyModule, [log_error: fn(_) -> 42 end] do
   assert MyModule.log_error("msg") == 42
end
```

## Tips
The use of mocking can be somewhat controversial. I personally think that it
works well for certain types of tests. Certainly, you should not overuse it. It
is best to write as much as possible of your code as pure functions which don't
require mocking to test. However, when interacting with the real world (or web
services, users etc.) sometimes side-effects are necessary. In these cases,
mocking is one useful approach for testing this functionality.

Also, note that Mock has a global effect so if you are using Mocks in multiple
tests set `async: false` so that only one test runs at a time.

## Help
Open an issue.

## Publishing New Package Versions
For library maintainers, the following is an example of how to publish new versions of the package. Run the following commands assuming you incremented the version in the `mix.exs` file from 0.3.4 to 0.3.5:

```
git commit -am "Increase version from 0.3.4 to 0.3.5"
git tag -a v0.3.5 -m "Git tag 0.3.5"
git push origin --tags
mix hex.publish
```

## Suggestions
I'd welcome suggestions for improvements or bugfixes. Just open an issue.
