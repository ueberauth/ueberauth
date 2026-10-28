# MIME

[![CI](https://github.com/elixir-plug/mime/actions/workflows/ci.yml/badge.svg)](https://github.com/elixir-plug/mime/actions/workflows/ci.yml)

A read-only and immutable MIME type module for Elixir.

This library embeds a database of MIME types so we can map MIME types
to extensions and vice-versa. The library was designed to be read-only
for performance. This library is used by projects like Plug and Phoenix.

Master currently points to a redesign of this library with a minimal copy
of the MIME database. To add any [media type specified by
IANA](https://www.iana.org/assignments/media-types/media-types.xhtml),
please submit a pull request. You can also add specific types to your
application via a compile-time configuration, see [the documentation for
more information](http://hexdocs.pm/mime/).

## Installation

The package can be installed as:

```elixir
def deps do
  [{:mime, "~> 2.0"}]
end
```

## License

MIME source code is released under Apache License 2.0.

Check LICENSE file for more information.
