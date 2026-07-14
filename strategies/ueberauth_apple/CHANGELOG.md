# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.7.0 (2026-07-14)

- **Breaking**: Require Elixir 1.17 and OTP 27.
  This change occurs due to requiring non-vulnerable versions of HTTPoison and its sub-dependency, Hackney.
- **Breaking**: Require `httpoison ~> 3.0`
- **Chore**: Exchange `mock` for `mimic` in tests.

### v0.6.2 (2026-07-13)

This release provides a minimal update path to address [an advisory](https://github.com/ueberauth/ueberauth_apple/security/advisories/GHSA-pxx8-68pc-p9mr).
Please see `v0.7.0` for additional updates related to vulnerable dependencies.

- **Security**: Validate `iss`, `aud`, `iat`, and `exp` claims on callback `id_token` after signature verification.
  Callback authentication now fails closed if the expected `client_id` audience cannot be determined.
  Client ID configuration was already required, so this should not break existing implementations.

### v0.6.1 (2023-06-21)

- **Fix**: Avoid errors when email key is not present in token payload.

## v0.6.0 (2023-02-28)

**Note**: This project has new maintainers.
`v0.6.0` is a significant release.
Please test thoroughly before deploying this upgrade.

- **Breaking**: Require Ueberauth `v0.10`.
- **Breaking**: Use Ueberauth for handling state parameters.
  This requires Ueberauth `v0.7`, even if overridden.
- **Breaking**: Enforce `SameSite=None` and `Secure` attributes on the state cookie.
  This is required for Apple's distinct `form_post` responses.
- **Add**: Allow setting the `response_mode` in the provider configuration.
  This may automatically be overridden depending on the `scopes` requested.
- **Add**: Add tests and GitHub Actions for CI.
- **Fix**: Extract the email address from non-initial callbacks.
  Before this change, it was only possible to view the email address during the very first callback from Apple.
  Now, it can be extracted on every login.
- **Fix**: Resolve warnings related to configuration and startup applications.
- **Fix**: Allow `httpoison ~> 2.0`.

---

The following releases were created by the project's [previous maintainers](https://github.com/loopsocial/ueberauth_apple).

## v0.5.0

Note: this version was not released to Hex.pm.

- **Add**: JSON serializer for compatibility with OAuth 2.0.
- **Add**: `response_mode` param, which is required to be `form_post` when requesting scopes.

## v0.4.0

- **Add**: Get user object from callback response.

## v0.3.0

- Allows using a function to generate the client secret

## v0.2.0

- Apple changed its public keys endpoint. It now returns multiple public keys

## v0.1.0

- Initial release
