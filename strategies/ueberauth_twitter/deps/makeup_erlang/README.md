# MakeupErlang

[![CI](https://github.com/elixir-makeup/makeup_erlang/actions/workflows/ci.yml/badge.svg)](https://github.com/elixir-makeup/makeup_erlang/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/makeup_erlang.svg)](https://hex.pm/packages/makeup_erlang)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/makeup_erlang)

A [Makeup](https://github.com/elixir-makeup/makeup/) lexer for the `Erlang` language.

## Installation

Add `makeup_erlang` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:makeup_erlang, "~> 1.0"}
  ]
end
```

The lexer will automatically register itself with `Makeup` for the languages `erlang` and `erl`
as well as the extensions `.erl`, `.hrl` and `.escript`.
