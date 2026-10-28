# Changelog

## Unreleased

### Breaking changes (0.13.0)

These changes ship in the release after the one that adds the `trust_forwarded_headers` warning below.

- Ignore the `X-Forwarded-Host` and `X-Forwarded-Proto` headers when building request and callback URLs, unless `trust_forwarded_headers: true` is set. The option is deprecated.
- Store the OAuth state in a cookie per provider, named `ueberauth.state_param.<provider>`, so login flows for different providers no longer overwrite each other. The cookie's path is the provider's request path when the callback is below it, and `/` otherwise. Strategies that read the cookie should use `Ueberauth.Strategy.Helpers.state_cookie_name/1`.
- Read provider configuration on each request instead of in `Ueberauth.init/1`, so values from `config/runtime.exs` apply when Phoenix initializes plugs at compile time. `init/1` now returns only the `:otp_app`, `:providers` and `:base_path` options, and a missing `:providers` config raises on the first request. Use the new `Ueberauth.routes/1` where tests changed the result of `init/1`.

#### Upgrading

1. **Behind a proxy:** add `plug Plug.RewriteOn, [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]` before Ueberauth runs (for Phoenix, in the endpoint), or set `:callback_scheme`, `:callback_port` or `:callback_url` on each provider. Setting `trust_forwarded_headers: true` keeps the old behavior for now.
2. **In-flight logins:** users who started a login before the deploy must start it again, because the state cookie name changed.
3. **Sign in with Apple:** upgrade `ueberauth_apple` at the same time. Older versions look for the old cookie name and raise in `form_post` mode.
4. **Tests:** replace `Ueberauth.init()` with `Ueberauth.routes()` where a test edits the route list before calling `Ueberauth.call/2`, and replace the `"ueberauth.state_param"` cookie name with `"ueberauth.state_param.<provider>"`.

### Fixes and warnings

- Mark the OAuth state cookie `Secure` when the request is HTTPS or `state_param_cookie_same_site` is `"None"`. Browsers drop `SameSite=None` cookies without `Secure`, so strategies using that option previously failed every callback with `csrf_attack`.
- Expire the OAuth state cookie after 10 minutes by default. Configure with the `state_param_cookie_max_age` strategy option (seconds).
- Delete the state cookie when the CSRF check fails, and compare the state param in constant time.
- Stop raising on malformed or IPv6 `Host` / `X-Forwarded-Host` values when building request and callback URLs. Invalid values fall back to the connection's host and port.
- Add the `trust_forwarded_headers` option (global or per provider). When it is not set, Ueberauth still reads `X-Forwarded-Host` and `X-Forwarded-Proto`, and logs a warning once if they change a URL. **Ueberauth 0.13.0 will ignore these headers unless `trust_forwarded_headers: true` is set.** Set it to `false` and use `Plug.RewriteOn`, or set it to `true` only if a proxy you control sets these headers.
- Raise a descriptive `ArgumentError` when no providers are configured.
- Fix the `set_errors!` example in the `Ueberauth.Strategy` docs, typos, and the Guardian link.
- Update the locked `plug_crypto` to 2.2.1, which fixes EEF-CVE-2026-105963 / GHSA-ffw9-w85g-f2vh. Ueberauth signs the state cookie with `secret_key_base`, so applications should update `plug_crypto` as well (`mix deps.update plug_crypto`). [#220](https://github.com/ueberauth/ueberauth/pull/220)

## 0.11.0 - 2026-10-11

- Sign and verify the OAuth state cookie, rejecting unsigned or tampered cookies before the provider callback. Protected strategies now require a stable host-provided `conn.secret_key_base` (a strong binary secret) across both phases and all application instances. Restart in-flight OAuth flows after upgrading. [#217](https://github.com/ueberauth/ueberauth/pull/217)
- Require Plug 1.10 or later for signed-cookie support. [#217](https://github.com/ueberauth/ueberauth/pull/217)
- Exclude the `provider` param from `callback_url` params [#216](https://github.com/ueberauth/ueberauth/pull/216)
- Fix `@spec` for `Ueberauth.Strategy.Helpers.options/1` to include `nil` [#199](https://github.com/ueberauth/ueberauth/pull/199)

## 0.10.8 - 2024-02-27

- Use `conn.port` by default in `callback_url/1` [#187](https://github.com/ueberauth/ueberauth/pull/187)

## 0.10.7 - 2024-01-04

- Revert the change from 0.10.6 [#195](https://github.com/ueberauth/ueberauth/pull/195)

## 0.10.6 - 2023-12-01

- Attempt to fix [#173](https://github.com/ueberauth/ueberauth/issues/173) [#193](https://github.com/ueberauth/ueberauth/pull/193)

## 0.10.5 - 2023-03-09

- Fix default port selection when none is specified on the host header [#181](https://github.com/ueberauth/ueberauth/pull/181)

## 0.10.4 - 2023-01-19

- Fix `port` being duplicate when behind reverse proxy and non-standard port [#103](https://github.com/ueberauth/ueberauth/pull/175)

## 0.10.3 - 2022-09-13

- Fix `@spec` for `Ueberauth.Strategy.Helpers.set_errors!/2`

## 0.10.2 - 2022-08-11

- Replace `:csrf_attack` with `"csrf_attack"` so it matches the type specs in `Ueberauth.Failure.Error` [#169](https://github.com/ueberauth/ueberauth/pull/169)

## 0.10.1 - 2022-07-05

- Fix callback URL not mounted right when router has nested paths [#166](https://github.com/ueberauth/ueberauth/pull/166)

## 0.10.0 - 2022-06-16

- Add `state_param_cookie_same_site` to strategy options to support different SameSite values [#148](https://github.com/ueberauth/ueberauth/pull/164#issuecomment-1155406862)

## v0.9.0 - 2022-04-27

- Prefer `x-forwarded-host` to construct callback_url [#161](https://github.com/ueberauth/ueberauth/pull/161)

## v0.8.0 - 2021-08-19

- Add support for custom URL schemes [#144](https://github.com/ueberauth/ueberauth/pull/144)

## v0.7.0 - 2020-04-17

- Add support for CSRF [#136](https://github.com/ueberauth/ueberauth/pull/136)
- Improve documentation [#137](https://github.com/ueberauth/ueberauth/pull/137)

## v0.6.3 - 2020-03-05

- Dynamic providers
- Birthday part of info struct

## v0.6.2 - 2019-09-11

- Fixed Ueberauth request not respecting Script Name [#97](https://github.com/ueberauth/ueberauth/pull/97)

## v0.6.1 - 2019-03-14

- Fix versioning for `plug` dependency

## v0.4.0 - 2016-09-21

- Target Elixir 1.3 and above
- Fix Elixir 1.4 warnings
- Fix bug preventing multiple providers

## v0.3.0 - 2016-07-19

- Allow `:redirect_url` to be configured
- Handle requests with or without trailing slash

## v0.2.1 - 2015-12-23

- Add the ability to select which providers to use on a per-plug basis

## v0.2.0 - 2015-11-28

- Remove the Ueberauth.plug function in favour of making Ueberauth a plug

## v0.1.0 - 2015-11-15

- Initial release
