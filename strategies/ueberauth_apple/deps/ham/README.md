# Ham

[![CI](https://github.com/edgurgel/ham/actions/workflows/ci.yml/badge.svg)](https://github.com/edgurgel/ham/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/ham.svg)](https://hex.pm/packages/ham)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ham)
[![Total Download](https://img.shields.io/hexpm/dt/ham.svg)](https://hex.pm/packages/ham)
[![License](https://img.shields.io/hexpm/l/ham.svg)](https://github.com/edgurgel/ham/blob/main/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/edgurgel/ham.svg)](https://github.com/edgurgel/ham/commits/main)

Ham is a library to validate function arguments and return values against their typespecs.
It was originally extracted out from [Ham](https://github.com/msz/hammox/) but
without the Mox integration. Hammox - Mox = Ham!
Thanks [@msz](https://github.com/msz) for creating Hammox!

The main reason why I wanted to extract it out is so that it can be used as part of Mimic or other testing libraries.

## Installation

Add `:ham`:

```elixir
def deps do
  [
    {:ham, "~> 0.1", only: :test}
  ]
end
```

## Using Ham

One can simply let Ham apply a module function using `Ham.apply/2` (function or macro) and it will validate argument and return value:

```elixir
iex> Ham.apply(URI, :decode, ["https%3A%2F%2Felixir-lang.org"])
"https://elixir-lang.org"
iex> Ham.apply(URI, :char_reserved?, ["a"])
** (Ham.TypeMatchError) 1st argument value "a" does not match 1st parameter's type byte().
  Value "a" does not match type 0..255.
```

```elixir
iex> Ham.apply(URI.decode("https%3A%2F%2Felixir-lang.org"))
"https://elixir-lang.org"
iex> Ham.apply(URI.char_reserved?("a"))
** (Ham.TypeMatchError) 1st argument value "a" does not match 1st parameter's type byte().
  Value "a" does not match type 0..255.
```

Another way is to pass the args and return value without Ham executing anything:

```elixir
iex> Ham.validate(URI, :char_reserved?, ["a"], true)
{:error,
 %Ham.TypeMatchError{
   reasons: [
     {:arg_type_mismatch, 0, "a", {:type, {324, 24}, :byte, []}},
     {:type_mismatch, "a", {:type, 0, :range, [{:integer, 0, 0}, {:integer, 0, 255}]}}
   ]
 }}

iex> Ham.validate!(URI, :char_reserved?, ["a"], true)
** (Ham.TypeMatchError) 1st argument value "a" does not match 1st parameter's type byte().
  Value "a" does not match type 0..255.
```

Both `apply` and `validate` accept `behaviours` as an option to declare that the module
implements certain behaviours.

For example let's implement a module that does a poor job of implementing `Access`

```elixir
defmodule CustomAccess do
  @behaviour Access

  def fetch(_data, _key), do: :poor
  def get_and_update(_data, _key, _function), do: :poor
  def pop(data, key), do: :poor
end

Ham.apply(CustomAccess.fetch([], "key"), behaviours: [Access])
** (Ham.TypeMatchError) Returned value :poor does not match type {:ok, Access.value()} | :error.
  Value :wrong does not match type {:ok, Access.value()} | :error.
```

## Why use Ham for my application code when I have Dialyzer?

Dialyzer is a powerful static analysis tool that can uncover serious problems.
But during tests dialyzer is not as useful. Ham can be used to validate function arguments
and return values during tests even if they are randomly generated or loaded from files.

## Protocol types

A `t()` type defined on a protocol is taken by Ham to mean "a struct
implementing the given protocol". Therefore, trying to pass `:atom` for an
`Enumerable.t()` will produce an error, even though the type is defined as
`term()`:

```none
** (Ham.TypeMatchError)
Returned value :atom does not match type Enumerable.t().
  Value :atom does not implement the Enumerable protocol.
```

## Limitations
- For anonymous function types in typespecs, only the arity is checked.
Parameter types and return types are not checked.

- For records we are only checking if it's a tuple and that the first value is the name of the record.

## License

Copyright 2019 Michał Szewczak

Copyright 2024 Eduardo Gurgel

Licensed under the Apache License, Version 2.0 (the "License"); you may not
use this file except in compliance with the License. You may obtain a copy of
the License at

http://www.apache.org/licenses/LICENSE-2.0 Unless required by applicable law
or agreed to in writing, software distributed under the License is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied. See the License for the specific language
governing permissions and limitations under the License.
