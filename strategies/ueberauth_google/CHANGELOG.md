# Changelog

## (Unreleased)

## [0.13.0](https://github.com/ueberauth/ueberauth/compare/ueberauth_google-v0.12.1...ueberauth_google-v0.13.0) (2026-10-28)


### ⚠ BREAKING CHANGES

* forwarded headers are ignored unless `trust_forwarded_headers: true` is set; use Plug.RewriteOn behind a proxy. The state cookie is renamed, so in-flight logins must restart. `init/1` no longer returns the route list; tests that edit it should use `Ueberauth.routes/1`.

### Features

* ignore forwarded headers, per-provider state cookies, runtime config ([#248](https://github.com/ueberauth/ueberauth/issues/248)) ([89e9017](https://github.com/ueberauth/ueberauth/commit/89e9017a0d56721cac34b5c868acf9f4eb583ea4))


### Bug Fixes

* Log the error body (ueberauth/ueberauth_google[#106](https://github.com/ueberauth/ueberauth/issues/106)) ([fd485c9](https://github.com/ueberauth/ueberauth/commit/fd485c99cc4bd187b445c4f3bea2ba58bcbe0540))

## v0.12.1

- Fix scope splitting [104](https://github.com/ueberauth/ueberauth_google/pull/104)

## v0.12.0

- Add support to hl param in handle_request! [102](https://github.com/ueberauth/ueberauth_google/pull/102)

## v0.11.0

- Allow using a function to generate the client secret [101](https://github.com/ueberauth/ueberauth_google/pull/101)

## v0.10.3

- Handle `%OAuth2.Response{status_code: 503}` with no `error_description` in `get_access_token` [99](https://github.com/ueberauth/ueberauth_google/pull/99)

## v0.10.2

- Prefer Local Over Global Configuration [95](https://github.com/ueberauth/ueberauth_google/pull/95)

## v0.10.1

- Misc doc changes [81](https://github.com/ueberauth/ueberauth_google/pull/81)
- Upgrade Ueberauth and Refactor CSRF State Logic [82](https://github.com/ueberauth/ueberauth_google/pull/82)

## v0.10.0 - 2020-10-20

### Enhancement

- Updated docs [#69](https://github.com/ueberauth/ueberauth_google/pull/69) [#70](https://github.com/ueberauth/ueberauth_google/pull/70)
- Support for birthday [#73](https://github.com/ueberauth/ueberauth_google/pull/73)
- Allow for userinfo endpoint to be configured [#75](https://github.com/ueberauth/ueberauth_google/pull/75)
- Updated plug and ueberauth packages [#76](https://github.com/ueberauth/ueberauth_google/pull/76)

Thanks goes to all the contributes

## v0.9.0 - 2019-08-21

### Enhancement

- Add support for optional login_hint param [#61](https://github.com/ueberauth/ueberauth_google/pull/61)
- Use `json_library` method from Ueberauth config [#58](https://github.com/ueberauth/ueberauth_google/pull/58)
- Allows specifying `{m, f, a}` tuples for things such as Client ID
  and Client Secret [#60](https://github.com/ueberauth/ueberauth_google/pull/60)
- Allows the newest oauth2 package versions with potential security fixes [#68](https://github.com/ueberauth/ueberauth_google/pull/68)

## v0.6.0 - 2017-07-18

- Add support for `access_type` per request using `url` parameter.

## v0.5.0 - 2016-12-27

- Add support for new params: `access_type`, `approval_prompt`, `state`.
- Fix Elixir warnings.

## v0.4.0 - 2016-09-21

- Target Elixir 1.3 and greater.
- Fix OAuth bug with 0.6.0 pin.

## v0.3.0 - 2016-08-15

- Use OpenID endpoint for profile information.
- Update authorize and token URLs.

## v0.2.0 - 2016-12-10

- Release 0.2.0 to follow Ueberauth.
