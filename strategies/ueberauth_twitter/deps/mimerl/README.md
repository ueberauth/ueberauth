# mimerl

An Erlang library for MIME type handling.

Maps file extensions to MIME types and vice versa, based on the
[IANA Media Types](https://www.iana.org/assignments/media-types/media-types.xhtml) registry.

## Build

```sh
rebar3 compile
```

## Usage

Get MIME type from extension:

```erlang
1> mimerl:extension(<<"json">>).
<<"application/json">>

2> mimerl:extension(<<"html">>).
<<"text/html">>
```

Get MIME type from filename:

```erlang
1> mimerl:filename(<<"index.html">>).
<<"text/html">>

2> mimerl:filename(<<"data.json">>).
<<"application/json">>
```

Get extensions for a MIME type:

```erlang
1> mimerl:mime_to_exts(<<"text/plain">>).
[<<"txt">>,<<"text">>,<<"conf">>,<<"def">>,<<"list">>,<<"log">>,<<"in">>]
```

## License

MIT
