# verkit

[![Open on npmx][npmx-version-src]][npmx-href]
[![npm downloads][npmx-downloads-src]][npmx-href]
[![Unit Test][unit-test-src]][unit-test-href]
[![Codecov][codecov-src]][codecov-href]

Fast, zero-dependency SemVer for ESM and TypeScript, with functional,
tree-shakeable APIs.

## Features

- ✅ Complete SemVer version and range toolkit.
- 🚀 Faster than [node-semver] across tested operations.
- 📦 Pure ESM with zero runtime dependencies.
- 💙 First-class TypeScript declarations.
- 🌳 Functional, tree-shakeable named exports.
- 🔁 Mutable `SemVer` and `SemVerRange` records.
- ⚡ 26.0% smaller for full CDN imports.
- 🪶 61.4% smaller with common bundled imports.
- 🛡️ Immutable collection operations.

## Install

```bash
npm add verkit
```

## Versions

```ts
import {
  coerce,
  increment,
  normalize,
  normalizeFull,
  parse,
  truncate,
} from 'verkit'

const version = parse('1.2.3-rc.1+sha.abc')
const coerced = coerce('release 42.6.7.9', { rtl: true })
version.patch = 4

normalizeFull(version) // '1.2.4-rc.1+sha.abc'
normalize(version) // '1.2.4-rc.1'
increment(version, 'minor') // '1.3.0'
truncate(version, 'patch') // '1.2.4'
coerced?.major // 6
```

Version APIs accept strings or mutable `SemVer` objects returned by `parse` or
`coerce`.
`normalizeFull` keeps build metadata; normalized, incremented, and truncated
versions omit it.

## Comparison

```ts
import { compare, compareBuild, isGreaterThan, sortReversed } from 'verkit'

compare('1.0.0+one', '1.0.0+two') // 0
compareBuild('1.0.0+one', '1.0.0+two') // -1
isGreaterThan('2.0.0', '1.0.0') // true
sortReversed(['1.0.0', '2.0.0']) // ['2.0.0', '1.0.0']
```

`compare` ignores build metadata; `compareBuild` uses it as a tie-breaker.

## Ranges

```ts
import {
  findMaxSatisfying,
  normalizeRange,
  parseRange,
  satisfies,
} from 'verkit'

const range = parseRange('^1.2.3')

normalizeRange(range) // '>=1.2.3 <2.0.0-0'
satisfies('1.5.0', range) // true
findMaxSatisfying(['1.2.3', '1.5.0', '2.0.0'], range) // '1.5.0'
```

Range APIs accept strings or mutable `SemVerRange` objects. They support
comparators, unions, hyphens, wildcards, tilde, caret, loose parsing, and
prereleases.

Range options are fixed when a `SemVerRange` is created. APIs that receive a
parsed range use its stored options and do not accept another options argument:

```ts
const prereleases = parseRange('1.x', { includePrerelease: true })

satisfies('1.0.0-rc.1', prereleases) // true
```

To use different options, pass the original range string again or create
another parsed range.

## API

See the [API reference](https://npmx.dev/package-docs/verkit).

## Invalid input behavior

`parse`, `parseComparator`, and `parseRange` throw detailed `TypeError`s. Their
`tryParse*` wrappers return `null`; other safe transforms and predicates keep
their documented `null`/`false` behavior.

## Migrating from node-semver

Only renamed or reshaped [node-semver] APIs are listed; same-named functions
such as `clean`, `coerce`, `compare`, and `satisfies` are omitted.

| node-semver                                    | verkit                                                                                              |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `SemVer`                                       | `parse`                                                                                             |
| `parse`                                        | `tryParse`                                                                                          |
| `valid`                                        | `normalize`                                                                                         |
| `inc`, `diff`                                  | `increment`, `difference`                                                                           |
| `major`, `minor`, `patch`, `prerelease`        | `getMajor`, `getMinor`, `getPatch`, `getPrerelease`                                                 |
| `rcompare`, `compareLoose`, `cmp`              | `compareReversed`, `compare` with `{ loose: true }`, `compareWithOperator`                          |
| `eq`, `neq`, `gt`, `gte`, `lt`, `lte`          | `isEqual`, `isNotEqual`, `isGreaterThan`, `isGreaterThanOrEqual`, `isLessThan`, `isLessThanOrEqual` |
| `rsort`                                        | `sortReversed`                                                                                      |
| `rcompareIdentifiers`                          | `compareIdentifiersReversed`                                                                        |
| `Comparator`                                   | `SemVerComparator`, `parseComparator`, `tryParseComparator`                                         |
| Comparator formatting, test, and intersection  | `normalizeComparator`, `satisfiesComparator`, `comparatorsIntersect`                                |
| `Range`                                        | `parseRange`                                                                                        |
| `toComparators`, `validRange`                  | `rangeToComparators`, `normalizeRange`                                                              |
| `maxSatisfying`, `minSatisfying`, `minVersion` | `findMaxSatisfying`, `findMinSatisfying`, `findMinimumForRange`                                     |
| `outside`, `gtr`, `ltr`                        | `isOutsideRange`, `isGreaterThanRange`, `isLessThanRange`                                           |
| `intersects`, `subset`                         | `rangesIntersect`, `isRangeSubset`                                                                  |
| `RELEASE_TYPES`                                | `INCREMENT_TYPES` (also includes `release`)                                                         |

`valid` returns a normalized `string | null` in node-semver, so its equivalent
is `normalize`. Use `isValid` when you only need a boolean.

Use options objects such as `{ loose: true }` and `{ identifier, identifierBase }`.
Range options belong to the string-parsing step; parsed `SemVerRange` objects
already contain them.

## Differences from node-semver

verkit follows [node-semver] semantics with four user-visible differences:

- Array helpers never mutate their inputs.
- Parsed `SemVerRange` objects retain their parse-time options. node-semver
  helpers may reparse a `Range` from `raw` using call-site options.
- verkit is ESM-only, with no CommonJS, CLI, or `NODE_DEBUG=semver` output.
- Error text, stack traces, and supported runtimes may differ.

## Bundle size

Full package imports, minified with Rolldown:

| Package               | Minified |    gzip |  Brotli |
| --------------------- | -------: | ------: | ------: |
| verkit                | 18,820 B | 5,914 B | 5,375 B |
| [semver][node-semver] | 24,424 B | 7,427 B | 6,765 B |
| verkit reduction      |    26.0% |   20.4% |   20.5% |

Common validation, range, comparison, increment, and coercion imports,
tree-shaken and minified with Rolldown:

| Package               | Minified |    gzip |  Brotli |
| --------------------- | -------: | ------: | ------: |
| verkit                |  9,872 B | 3,401 B | 3,121 B |
| [semver][node-semver] | 25,577 B | 7,500 B | 6,835 B |
| verkit reduction      |    61.4% |   54.7% |   54.3% |

Run `pnpm test:size` to reproduce the comparison.

## Benchmarks

Measured on a MacBook Pro with an Apple M1 Max and 32 GB RAM. Higher is
better.

| Operation                 | verkit ops/s | semver ops/s | Faster       |
| ------------------------- | -----------: | -----------: | ------------ |
| Parse and normalize       |        3.67M |        3.26M | verkit 1.13× |
| Compare                   |        3.09M |        2.36M | verkit 1.31× |
| Compare parsed versions   |       40.59M |       28.62M | verkit 1.42× |
| Increment                 |        3.38M |        2.03M | verkit 1.66× |
| Coerce                    |        2.77M |        2.32M | verkit 1.19× |
| Satisfy uncached ranges   |       148.5K |       122.3K | verkit 1.21× |
| Satisfy pre-parsed inputs |       22.91M |        7.20M | verkit 3.18× |

Range benchmarks either cycle through 1,001 inputs to avoid cache hits or
parse once and reuse the resulting objects.

Run runtime benchmarks with `pnpm bench`.

## Sponsors

<p align="center">
  <a href="https://cdn.jsdelivr.net/gh/sxzz/sponsors/sponsors.svg">
    <img src="https://cdn.jsdelivr.net/gh/sxzz/sponsors/sponsors.svg" alt="Sponsors" />
  </a>
</p>

## License

[MIT](./LICENSE) © 2026-PRESENT [Kevin Deng](https://github.com/sxzz).

Parts of the implementation and test fixtures are derived from [node-semver]
under the ISC license; see [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).

<!-- Badges -->

[npmx-version-src]: https://npmx.dev/api/registry/badge/version/verkit
[npmx-downloads-src]: https://npmx.dev/api/registry/badge/downloads-month/verkit
[npmx-href]: https://npmx.dev/verkit
[node-semver]: https://github.com/npm/node-semver
[unit-test-src]: https://github.com/sxzz/verkit/actions/workflows/unit-test.yml/badge.svg
[unit-test-href]: https://github.com/sxzz/verkit/actions/workflows/unit-test.yml
[codecov-src]: https://codecov.io/gh/sxzz/verkit/graph/badge.svg?token=hBBtxizmt9
[codecov-href]: https://codecov.io/gh/sxzz/verkit
