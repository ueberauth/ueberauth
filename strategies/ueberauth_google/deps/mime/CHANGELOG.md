# Changelog

## v2.0.7

  * Correct support for JP2000

## v2.0.6

  * Add mimes for ZSTD, APNG, JP2000
  * Add `known_types/0` to list all known types

## v2.0.5

  * Allow conflicting extension to be overridden

## v2.0.4

  * Only returns extensions from known suffixes
  * Allow mime types to be fully overridden

## v2.0.3

  * Support Markdown, JPEG XL, and PSD formats

## v2.0.2

  * Support Associated Signature Containers (ASiC) files
  * Support `.atom` and `.rss` files

## v2.0.1

  * Add `.text` extension to text/plain

## v2.0.0

Upgrade note: mime v2 no longer ships with a complete database of mime.types,
instead it lists the most common mime types used by web applications. When
upgrading, check carefully if all mime types used by your app are supported.

  * Ship with our own minimal types database

## v1.6.0

  * Deprecate MIME.valid?
  * Ignore media type params
  * Detect subtype suffix according to the spec

## v1.5.0

  * Compare extensions in a case-insensitive way (see
    [elixir-plug/mime#38](https://github.com/elixir-plug/mime/issues/38)).
