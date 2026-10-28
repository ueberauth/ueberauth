![Mimic logo](logo.png)
# Mimic

[![CI](https://github.com/edgurgel/mimic/actions/workflows/main.yml/badge.svg)](https://github.com/edgurgel/mimic/actions/workflows/main.yml)
[![Module Version](https://img.shields.io/hexpm/v/mimic.svg)](https://hex.pm/packages/mimic)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/mimic/)
[![Total Download](https://img.shields.io/hexpm/dt/mimic.svg)](https://hex.pm/packages/mimic)
[![License](https://img.shields.io/hexpm/l/mimic.svg)](https://github.com/edgurgel/mimic/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/edgurgel/mimic.svg)](https://github.com/edgurgel/mimic/commits/master)

A sane way of using mocks in Elixir. It borrows a lot from both Meck & Mox! Thanks [@eproxus](https://twitter.com/eproxus) & [@josevalim](https://twitter.com/josevalim).

## Installation

Just add `:mimic` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mimic, "~> 2.0", only: :test}
  ]
end
```

If `:applications` key is defined inside your `mix.exs` or you run `mix test --no-start`, you probably want to add `Application.ensure_all_started(:mimic)` in your `test_helper.exs`

## Using

Modules need to be prepared so that they can be used.

You must first call `copy` in your `test_helper.exs` for
each module that may have the behaviour changed.

```elixir
Mimic.copy(Calculator)

ExUnit.start()
```

Calling `copy` will not change the behaviour of the module.

The user must call `stub/1`, `stub/3`, `expect/4` or `reject/1` so that the functions can
behave differently.

Then for the actual tests one could use it like this:

```elixir
use ExUnit.Case, async: true
use Mimic

test "invokes mult once and add twice" do
  Calculator
  |> stub(:add, fn x, y -> :stub end)
  |> expect(:add, fn x, y -> x + y end)
  |> expect(:mult, 2, fn x, y -> x * y end)

  assert Calculator.add(2, 3) == 5
  assert Calculator.mult(2, 3) == 6

  assert Calculator.add(2, 3) == :stub
end
```

## Stub, Expect and Reject

### Stub

`stub/1` will change every module function to throw an exception if called.

```elixir
stub(Calculator)

** (Mimic.UnexpectedCallError) Stub! Unexpected call to Calculator.add(3, 7) from #PID<0.187.0>
     code: assert Calculator.add(3, 7) == 10
```

`stub/3` changes a specific function to behave differently. If the function is not called no verification error will happen.

### Expect

`expect/4` changes a specific function and it works like a queue of operations. It has precedence over stubs and if not called a verification error will be thrown.

If the same function is called with `expect/4` the order will be respected:

```elixir
Calculator
|> stub(:add, fn _x, _y -> :stub end)
|> expect(:add, fn _, _ -> :expected_1 end)
|> expect(:add, fn _, _ -> :expected_2 end)

assert Calculator.add(1, 1) == :expected_1
assert Calculator.add(1, 1) == :expected_2
assert Calculator.add(1, 1) == :stub
```

`expect/4` has an optional parameter which is the amount of calls expected:

```elixir
Calculator
|> expect(:add, 2, fn x, y -> {:add, x, y} end)

assert Calculator.add(1, 3) == {:add, 1, 3}
assert Calculator.add(4, 5) == {:add, 4, 5}
Calculator.add(1, 4)

# Will raise error because more than 2 calls to Calculator.add were made and there is no stub
# ** (Mimic.UnexpectedCallError) Calculator.add/2 called in process #PID<.*> but expectations are already fulfilled
```

With `use Mimic`, verification `expect/4` function call of is done automatically on test case end. `verify!/1` can be used in case custom verification timing required:

```elixir
Calculator
|> expect(:add, 2, fn x, y -> {:add, x, y} end)

# Will raise error because Calculator.add is not called
# ** (Mimic.VerificationError) error while verifying mocks for #PID<0.3182.0>:
#   * expected Calculator.add/2 to be invoked 1 time(s) but it has been called 0 time(s)
verify!()
```

Using `expect/4` on intra-module functions will not work, unless the function is referenced by it's fully qualified name.

```elixir
defmodule Calculator do
  def mult(x, y) do
    x * y
  end

  def negation(x) do
    mult(x, -1)
  end
end

Calculator
|> expect(:mult, fn x, y -> x + y end)

assert Calculator.negation(5) == -5

# Will raise error because because BEAM optimises this case and jumps directly to the appropriate bytecode.
# ** (Mimic.VerificationError) error while verifying mocks for #PID<0.207.0>:
#   * expected Calculator.mult/2 to be invoked 1 time(s) but it has been called 0 time(s)
verify!()
```

To ensure that the stubbed Mimic function is called, it can be referenced by `Calculator.mult/2` instead of `mult/2`.

### Reject

One may want to reject calls to a specific function. `reject/1` can be used to achieved this behaviour.

```elixir
reject(&Calculator.add/2)
assert_raise Mimic.UnexpectedCallError, fn -> Calculator.add(4, 2) end
```

### Calls

`calls/3` returns a list of args for each call to a stubbed Mimic function.

```elixir
defmodule Calculator do
  def mult(x, y) do
    x * y
  end
end

Calculator
|> expect(:mult, fn x, y -> x + y end)

[] = calls(Calculator, :mult, 2)

9 = Calculator.mult(3, 3)

[[3, 3]] = calls(Calculator, :mult, 2)
```

`calls/1` works the same way, but with a capture of the function:

```elixir
defmodule Calculator do
  def mult(x, y) do
    x * y
  end
end

Calculator
|> expect(:mult, fn x, y -> x + y end)

[] = calls(&Calculator.mult/2)

9 = Calculator.mult(3, 3)

[[3, 3]] = calls(&Calculator.mult/2)
```

When `calls` is called they are popped out of the list of calls. Next time `calls` is used it will only
return new calls since the last time that `calls` was used.

## Private and Global mode

The default mode is private which means that only the process
and explicitly allowed process will see the different behaviour.

Calling `allow/2` will permit a different pid to call the stubs and expects from the original process.

If you are using `Task` there is no need to use global mode as Tasks can see the same expectations and stubs from the calling process.

Global mode can be used with `set_mimic_global` like this:

```elixir
setup :set_mimic_global

test "invokes add and mult" do
  Calculator
  |> expect(:add, fn x, y -> x + y end)
  |> expect(:mult, fn x, y -> x * y end)

  parent_pid = self()

  spawn_link(fn ->
    assert Calculator.add(2, 3) == 5
    assert Calculator.mult(2, 3) == 6

    send parent_pid, :ok
  end)

  assert_receive :ok
end
```

This means that all processes will get the same behaviour
defined with expect & stub. This option is simpler but tests running
concurrently will have undefined behaviour. It is important to run with `async: false`.
One could use `:set_mimic_from_context` instead of using `:set_mimic_global` or `:set_mimic_private`. It will be private if `async: true`, global otherwise.

## DSL Mode
To use DSL Mode `use Mimic.DSL` rather than `use Mimic` in your test.  DSL Mode enables a more expressive api to the Mimic functionality.

```elixir
  use Mimic.DSL

  test "basic example" do
    stub Calculator.add(_x, _y), do: :stub
    expect Calculator.add(x, y), do: x + y
    expect Calculator.mult(x, y), do: x * y

    assert Calculator.add(2, 3) == 5
    assert Calculator.mult(2, 3) == 6

    assert Calculator.add(2, 3) == :stub
  end
```

## Stubs with fake module
`stub_with/2` enable substitute function call of a module with another similar module.

```elixir
  defmodule BadCalculator do
    def add(x, y), do: x*y
    def mult(x, y), do: x+y
  end

  test "basic example" do
    stub_with(Calculator, BadCalculator)

    assert Calculator.add(2, 3) == 6
    assert Calculator.mult(2, 3) == 5
  end
```

## Calling the original
`call_original/3` allows to call original unmocked version of the function.

```elixir
setup :set_mimic_private

test "calls original function even if it has been is stubbed" do
  stub_with(Calculator, InverseCalculator)

  assert call_original(Calculator, :add, [1, 2]) == 3
end
```

## Experimental type checking for copied modules

One can pass `type_check: true` when a module is copied to also get the function expected/stubbed to
validate the arguments and return value using [Ham](https://github.com/edgurgel/ham) which is essentially
what [Hammox](https://github.com/msz/hammox) improved on Mox.

```elixir
Mimic.copy(:cowboy_req, type_check: true)
```

If there is any problem with the arguments or return values of the stubbed functions on your tests you might see
an error like this one:

```elixir
     ** (Mimic.TypeCheckError) :cowboy_req.parse_qs/1: 1st argument value %{} does not match 1st parameter's type :cowboy_req.req().
       Could not find a map entry matching required(:method) => binary().
```

This feature is experimental at the moment which means that it might change a little bit how this
is configured and used. Feedback is welcome!

## Implementation Details & Performance

After calling `Mimic.copy(MyModule)`, calls to functions belonging to this module will first go through an ETS table to check which pid sees what (stubs, expects or call original).

It is really fast but it won't be as fast as calling a no-op function. Here's a very simple benchmark:

```elixir
defmodule Enumerator do
 def to_list(x, y), do: Enum.to_list(x..y)
end
```

Benchmarking `Enumerator.to_list(1, 100)` :

```
Name               ips        average  deviation         median         99th %
mimic         116.00 K        8.62 μs   ±729.13%           5 μs          29 μs
original       19.55 K       51.15 μs   ±302.46%          34 μs         264 μs

Comparison:
mimic         116.00 K
original       19.55 K - 5.93x slower
```

Benchmarking `Enumerator.to_list(1, 250)` :

```
Name               ips        average  deviation         median         99th %
original      131.49 K        7.61 μs   ±167.90%           7 μs          16 μs
mimic         105.47 K        9.48 μs   ±145.21%           9 μs          27 μs

Comparison:
original      131.49 K
mimic         105.47 K - 1.25x slower
```

There's a small fixed price to pay when mimic is used but it is unnoticeable for tests purposes.

## Acknowledgements

Thanks to [@jimsynz](https://github.com/jimsynz)  and [@alissonsales](http://github.com/alissonsales) for all the help! :tada:

Thanks to [@mendokusai](https://github.com/mendokusai) for the nice logo!

## Copyright and License

Copyright (c) 2016 Eduardo Gurgel

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
