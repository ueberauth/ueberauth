# Changelog

## v0.9.0

### Enhancement

* Add support for optional login_hint param [#61](https://github.com/ueberauth/ueberauth_google/pull/61)
* Use json_library method from Ueberauth config [#58](https://github.com/ueberauth/ueberauth_google/pull/58)
* Allows specifying `{m, f, a}` tuples for things such as Client ID
  and Client Secret [#60](https://github.com/ueberauth/ueberauth_google/pull/60)
* Allows the newest oauth2 package versions with potential security fixes [#68](https://github.com/ueberauth/ueberauth_google/pull/68)

## v0.6.0

* Add support for access_type per request using url parameter.

## v0.5.0

* Add support for new params: access_type, approval_prompt, state.
* Fix Elixir warnings.

## v0.4.0

* Target Elixir 1.3 and greater.
* Fix OAuth bug with 0.6.0 pin.

## v0.3.0

* Use OpenID endpoint for profile information.
* Update authorize and token URLs.

## v0.2.0

* Release 0.2.0 to follow Ueberauth.
