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

Do not bump the version in `mix.exs` or edit `CHANGELOG.md`. [Release Please](https://github.com/googleapis/release-please)
opens a release pull request that updates both from the commit history, and merging it publishes the release to Hex.

## Issues

If you believe there to be a bug, please provide the maintainers with enough
detail to reproduce or a link to an app exhibiting unexpected behavior. For
help, please start with Stack Overflow.
