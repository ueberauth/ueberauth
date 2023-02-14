# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.6.0

**Note**: This project has new maintainers.
`v0.6.0` is a significant release.
Please test thoroughly before deploying this upgrade.

* **Breaking**: Require Ueberauth `v0.10`.
* **Breaking**: Use Ueberauth for handling state parameters.
  This requires Ueberauth `v0.7`, even if overridden.
* **Breaking**: Enforce `SameSite=None` and `Secure` attributes on the state cookie.
  This is required for Apple's distinct `form_post` responses.
* **Add**: Allow setting the `response_mode` in the provider configuration.
  This may automatically be overridden depending on the `scopes` requested.
* **Add**: Add tests and GitHub Actions for CI.
* **Fix**: Extract the email address from non-initial callbacks.
  Before this change, it was only possible to view the email address during the very first callback from Apple.
  Now, it can be extracted on every login.
* **Fix**: Resolve warnings related to configuration and startup applications.
* **Fix**: Allow `httpoison ~> 2.0`.

---

The following releases were created by the project's [previous maintainers](https://github.com/loopsocial/ueberauth_apple).

## v0.5.0

## v0.4.0

## v0.3.0

* Allows using a function to generate the client secret

## v0.2.0

* Apple changed its public keys endpoint. It now returns multiple public keys

## v0.1.0

* Initial release
