# Contributing to Ueberauth

## Pull Requests Welcome

1. fork ueberauth
2. create a topic branch
3. make logically-grouped commits with clear commit messages
4. push commits to your fork
5. open a pull request against `ueberauth/main`
6. title the pull request using [Conventional Commits](https://www.conventionalcommits.org/)
   (for example `fix: handle missing state cookie` or `feat: add trust_forwarded_headers option`).
   Pull requests are squash merged, so the title becomes the commit message on `main`.

   When a change only touches one strategy, scope it to that package, e.g. `fix(ueberauth_google): ...`.

Do not bump the version in `mix.exs` or edit `CHANGELOG.md`. [Release Please](https://github.com/googleapis/release-please)
opens a release pull request per package that updates both from the commit history, and merging it publishes that
release to Hex.

## Repository Layout

This repository holds `ueberauth` itself (at the root) and the strategies maintained by the Überauth team
(under `strategies/`). Each strategy is its own Mix project and Hex package, versioned and released independently.

Strategies depend on `ueberauth` from this checkout (`path: "../.."`), so their tests always run against the core
library on `main`. To work on a strategy:

```sh
cd strategies/ueberauth_google
mix deps.get
mix test
```

Release Please assigns a commit to a package by the files it changes, so keep changes to core and to a strategy in
separate pull requests where you can.

## Issues

If you believe there to be a bug, please provide the maintainers with enough
detail to reproduce or a link to an app exhibiting unexpected behavior. For
help, please start with Stack Overflow.
