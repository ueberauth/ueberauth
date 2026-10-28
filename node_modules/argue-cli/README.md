# argue-cli

[![ESM-only package][package]][package-url]
[![NPM version][npm]][npm-url]
[![Node version][node]][node-url]
[![Dependencies status][deps]][deps-url]
[![Install size][size]][size-url]
[![Build status][build]][build-url]
[![Coverage status][coverage]][coverage-url]

[package]: https://img.shields.io/badge/package-ESM--only-ffe536.svg
[package-url]: https://nodejs.org/api/esm.html

[npm]: https://img.shields.io/npm/v/argue-cli.svg
[npm-url]: https://www.npmjs.com/package/argue-cli

[node]: https://img.shields.io/node/v/argue-cli.svg
[node-url]: https://nodejs.org

[deps]: https://img.shields.io/librariesio/release/npm/argue-cli
[deps-url]: https://libraries.io/npm/argue-cli

[size]: https://packagephobia.com/badge?p=argue-cli
[size-url]: https://packagephobia.com/result?p=argue-cli

[build]: https://img.shields.io/github/actions/workflow/status/TrigenSoftware/Argue/tests.yml?branch=master
[build-url]: https://github.com/TrigenSoftware/Argue/actions

[coverage]: https://img.shields.io/codecov/c/github/TrigenSoftware/Argue.svg
[coverage-url]: https://app.codecov.io/gh/TrigenSoftware/Argue

A thin and strongly typed CLI arguments parser for Node.js.

## Usage

1. Install

```bash
# pnpm
pnpm add argue-cli
# yarn
yarn add argue-cli
# npm
npm i argue-cli
```

2. Import in your code and use it!

```ts
import { read, end, expect, alias, option, readOptions } from 'argue-cli'

/**
 * Expect and read one of the commands
 */
const command = expect(
  alias('install', 'i'),
  'remove'
)
let options = {}

if (command === 'install') {
  /**
   * Read passed options
   */
  options = readOptions(
    option(alias('save', 'S'), Boolean),
    option(alias('saveDev', 'save-dev', 'D'), Boolean),
    option('workspace', String)
  )
}

/**
 * Read next argument
 */
const packageName = read()

/**
 * Expect end of the arguments
 */
end()

/* ... */
```

## API

Argue reads arguments sequentially from an internal state, which is initialized with `process.argv`. Every call consumes the arguments it reads, so you describe your CLI step by step: expect a command, read its options, read positional arguments, and finally assert the end.

> [!TIP]
> The internal state can be controlled manually with `setArgs(...args)` and `resetArgs()` — handy in tests.

### read

```ts
function read(): string
```

Reads the next argument and returns it. Throws an error if there are no arguments left.

```ts
// my-cli sort-imports
const fileName = read() // 'sort-imports'
```

### rest

```ts
function rest(): string[]
```

Reads all remaining arguments and returns them. Returns an empty array if there are none — unlike [`read`](#read), it never throws.

```ts
// my-cli format a.js b.js c.js
expect('format')

const files = rest() // ['a.js', 'b.js', 'c.js']

end() // always passes after rest()
```

### end

```ts
function end(): void
```

Asserts that all arguments were consumed. Throws an error if there are any arguments left — useful to catch typos and unexpected input.

```ts
// my-cli install --sav
expect('install')
readOptions(
  option(alias('save', 'S'), Boolean)
)
end() // throws: Unexpected argument "--sav"
```

### expect

```ts
function expect(...argRefs: ArgRef[]): string
```

Expects the next argument to be one of the given ones and returns the matched name. If an [alias](#alias) matches, the main name is returned. Throws an error on any other input.

The return type is inferred as a union of the given names:

```ts
// my-cli i
const command = expect(alias('install', 'i'), 'remove')
// typeof command: 'install' | 'remove'
// command === 'install'
```

### alias

```ts
function alias(name: string, ...aliases: string[]): AliasArgRef
```

Describes an argument that has alternative names. Use it anywhere an argument name is expected — in [`expect`](#expect) and [`option`](#option).

```ts
alias('install', 'i')
alias('saveDev', 'save-dev', 'D')
```

### autocase

```ts
function autocase(argRef: ArgRef): ArgRef
```

Describes an argument that matches both camelCase and kebab-case forms. The name can be given in either form — the twin form is added as an alias. Aliases longer than one character are autocased too. Use it anywhere an argument name is expected.

```ts
autocase('firstRelease')
// --firstRelease and --first-release are both accepted

autocase(alias('save-dev', 'D'))
// --save-dev, --saveDev and -D
```

### option

```ts
function option(argRef: ArgRef, type: OptionConstructor): OptionReader
```

Describes an option with a value of the given type, to be read by [`readOptions`](#readoptions):

- `String` — takes the next argument as a value: `--workspace packages/app`
- `Number` — parses the next argument as a number: `--port 8080`
- `Boolean` — a flag without a value, `true` when present: `--verbose`
- `Array` — splits the next argument by commas; repeated options are merged: `--plugins eslint,swc --plugins tsc` → `['eslint', 'swc', 'tsc']`
- `[String]` or `[Number]` — takes the next argument as a whole; repeated options are collected: `--match '*.{js,ts}' --match '*.css'` → `['*.{js,ts}', '*.css']`. Use it instead of `Array` for values that may contain commas of their own

### flag

```ts
function flag(argRef: ArgRef): OptionReader
```

Describes a boolean flag with `--no-*` negation support, to be read by [`readOptions`](#readoptions): `--verbose` sets `true`, `--no-verbose` sets `false`. Use `option(argRef, Boolean)` when negation is not wanted.

```ts
const options = readOptions(
  flag(autocase('firstRelease'))
)
// --first-release → { firstRelease: true }
// --no-first-release, --no-firstRelease → { firstRelease: false }
```

### readOptions

```ts
function readOptions(...optionReaders: OptionReader[]): OptionResult
```

Scans the arguments and reads all described options. Both `--option` and `-o` prefixes are accepted, and a value can be passed either as the next argument or inline: `--workspace packages/app` and `--workspace=packages/app` are equivalent. Arguments that don't match any described option are left untouched, so you can continue reading them afterwards.

The result is a strongly typed object, where every property is optional — an option simply may not be passed:

```ts
// my-cli --save-dev --workspace packages/app my-package
const options = readOptions(
  option(alias('saveDev', 'save-dev', 'D'), Boolean),
  option('workspace', String)
)
// typeof options: { saveDev?: boolean, workspace?: string }
// options: { saveDev: true, workspace: 'packages/app' }

const packageName = read() // 'my-package'
```

## TypeScript

In the [API section](#api) types are described in a simplified way. A detailed example of the inferred types you can see in [type tests](src/types.spec.ts).
