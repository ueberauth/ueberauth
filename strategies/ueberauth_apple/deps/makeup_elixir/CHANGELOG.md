# Changelog

## 1.0.1 (2024-12-10)

* Support multi-letter sigils
* Allow options to be registered with custom lexers

## 1.0.0 (2024-11-06)

* Allow registering custom sigils
* Allow node names in prompts
* Allow \t and \f as whitespace

## 0.16.2 (2024-03-01)

* Fix warnings on Elixir v1.16+

## 0.16.1 (2023-04-03)

* Relax NimbleParsec dependency

## 0.16.0 (2022-03-07)

Export the `root` and `root_parsec` parsecs as combinators so that they can
be used from other modules. This is backward-compatible with the previous version
(it only adds some new exports to the module).

This way, the `root` and `root_parsec` combinators can be used from other lexers
(such as the `EExLexer` for examples).

## 0.15.2 (2021-10-13)

* Highlight Erlang calls as modules.
* Support digits as modifiers in sigils.
* Support stepped ranges operators `..//`.

## 0.15.1 (2021-01-29)

* Multiple bug fixes and update list of tokens.

## 0.15.0 (2020-10-02)

* Added support for Unicode characters in identifiers (atoms and variables).
* Improved handling of sigils.
