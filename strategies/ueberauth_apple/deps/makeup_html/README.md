# MakeupHTML

![CI](https://github.com/elixir-makeup/makeup_html/actions/workflows/ci.yml/badge.svg)

A [Makeup](https://github.com/elixir-makeup/makeup/) lexer for the `HTML` language.

If you want to syntax highlight (H)EEx templates, see [`makeup_eex`](https://github.com/makeup/makeup_eex).

If you want to highlight HTML, including any CSS and JavaScript within, see [`makeup_syntect`](https://github.com/steffenDE/makeup_syntect).

## Installation

Add `makeup_html` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:makeup_html, "~> 0.1.0"}
  ]
end
```

The lexer will automatically register itself with `Makeup` for the HTML language as well as the `.html` extension.
