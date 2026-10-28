# Changelog

## v1.1.0 (2026-05-08)

### Added

  * Support for OTP 27+ triple-, quadruple-, and quintuple-quoted strings,
    including the matching sigil delimiters.
  * Support for OTP 27 underscore separators in numeric literals
    (`1_000_000`, `16#FF_FF`, `0.1_5e1_0`).
  * Support for OTP 25/27 `?=` maybe-match operator as a single token.
  * Support for OTP 29 native records, including the external
    `#Module:Name{...}` / `#Module:Name.field` forms and variable-shape /
    keyword record names (`#State{}`, `#case{}`, `#fun{}`).
  * Distinct token for parameterised macro calls (`?FOO(args)` →
    `:name_function`) versus parameterless macro references (`?FOO` →
    `:name_constant`).
  * `:string_escape` sub-tokens emitted inside plain double-quoted strings
    (previously only emitted inside triple-quoted strings).
  * Multi-character escape sequences (`$\xFF`, `$\x{1F600}`, `$\077`,
    `$\^A`) in `$\...` character literals tokenised as a single escape.
  * Underscore-prefixed identifiers (`_5`, `_X`, `_unused`) lex as a single
    `:name` variable rather than `_` + integer/name.

### Changed

  * BIF list is now generated at compile time from `erl_internal:bif/2`,
    keeping the recognised builtins in sync with the OTP version
    `makeup_erlang` is compiled against. Adds 30+ post-OTP-19 BIFs and
    fixes one stale typo. Closes #13.
  * Reserved words written adjacent to `(` (e.g. `fun(X)`) are recovered
    as `:keyword` instead of misclassified `:name_function`.
  * Erlang shell prompts (`1> ...`) are detected after multi-line
    whitespace blocks, not only after a single immediate `\n`.

## v1.0.3

  * Do not tag newlines before prompts as unselectable.
  * LICENSE and CI housekeeping.

## v1.0.2

### Added

  * Support for strict generators in comprehensions.
  * Support for parallel comprehensions.
  * Group handling for binaries.
  * Elixir 1.18 and Erlang 27 in the CI matrix.
  * Tests for list and binary comprehensions.

## v1.0.1

  * Parse tabs correctly (#29).

## v1.0.0

  * Properly deal with unicode characters in `$` character literals.
  * Fix publishing and generation of docs.

## v0.1.5

  * Highlight errors in shell examples correctly.

## v0.1.4

  * Support for `maybe ... end` expressions.
  * Support for triple-quoted strings and sigils.
  * CI updates.

## v0.1.3

  * Support for the Erlang shell prompt (`1> ...`) (#24).
  * Use the SPDX-conformant license name.
  * Run `mix format` over the codebase.

## v0.1.2

  * Require Elixir 1.6 or newer (#17).
  * Drop unused `assert_value` dependency (#18).
  * Remove `@inline` annotations (#22).
  * CI configuration cleanup.

## v0.1.1

Initial public release.

  * Tokenisation of module attributes (with optional parentheses), atoms,
    binary syntax, charlists, escaped characters, operators and
    punctuation.
  * Tokenisation of records: creation, access, and update.
  * Tokenisation of qualified function calls — module name tagged as
    `:name_class`.
  * Combinator for function/arity syntax (`fun/N`).
  * Registers itself as a Makeup lexer on application boot.
