# Contribution Guidelines

Hello there.
Thank you for your interest in contributing to this project.
Although the goals of this project are very simple, maintenance of any project takes effort.

Reading and following the guidelines in this document is an act of kindness and respect for other contributors.
With your help, we can address issues, make changes, and work together efficiently.

## Ways to Contribute

There are many ways to contribute to this project:

* Users of the project can report issues and share new use-cases.
* Everyone can help improve documentation and support others in Discussions.
* Anyone can assist in the triage of bugs, identifying root causes, and proposing solutions.

Please keep in mind the intended scope of this package: an Ueberauth strategy for integrating with _Sign In with Apple_.

## Ground Rules

All contributions to this project must align with the [code of conduct](CODE_OF_CONDUCT.md).
Beyond that, we ask:

* Please be kind. Maintaining this project is not paid work.
* Please create an issue before embarking on major refactors or new features.
* Let's make a reasonable effort to support older versions of Elixir and OTP.

## Workflows

If you're interested in doing something specific, here are some guidelines:

### Security Issues

If you find a security-related issue with this project, please refrain from opening a public issue and instead [create a private security report](https://github.com/ueberauth/ueberauth_apple/security).

### Bugs and Blockers

Please use [GitHub Issues](https://github.com/ueberauth/ueberauth_apple/issues) to report reproducible bugs.

### Feature Requests and Ideas

Please use [GitHub Discussions](https://github.com/ueberauth/ueberauth_apple/discussions) to share requests and ideas for improvements to the library.

### Implementing Changes

If you've decided to take on the implementation of a new feature or fix, please open an issue or create a discussion post first to get feedback.

## Releases

For maintainers, the process of releasing this package to [Hex.pm](https://hex.pm/packages/ueberauth_apple) centers around git tags.
To make a new release:

1. Update the Changelog with a new header that has today's date and the new version.
  Include any missing notes from changes since the last release, and any additional upgrade instructions users may need.
2. Update the `@version` number in `mix.exs`.
  The form should be `X.Y.Z`, with optional suffixes, but no leading `v`.
3. Update the **Quick Start** installation instructions in `README.md` to have the newest non-suffixed version number.
4. Update the **Installation** instructions in `guides/getting-started.md` to have the newest non-suffixed version number.
5. Commit the above changes with a generic commit message, such as `Release X.Y.Z`.
6. Tag the commit as `X.Y.Z`, with optional suffixes, but no leading `v`.
7. Push the commits and tag (for example, `git push origin main --tags`).
8. Observe the GitHub Action titled **Release**.
  This action automatically publishes the package to Hex.pm.
