# Changelog

## (Unreleased)

## v0.10.1

* Misc doc changes [81](https://github.com/ueberauth/ueberauth_google/pull/81)
* Upgrade Ueberauth and Refactor CSRF State Logic [82](https://github.com/ueberauth/ueberauth_google/pull/82)

## v0.10.0 - 2020-10-20

### Enhancement

* Updated docs [#69](https://github.com/ueberauth/ueberauth_google/pull/69) [#70](https://github.com/ueberauth/ueberauth_google/pull/70)
* Support for birthday [#73](https://github.com/ueberauth/ueberauth_google/pull/73)
* Allow for userinfo endpoint to be configured [#75](https://github.com/ueberauth/ueberauth_google/pull/75)
* Updated plug and ueberauth packages [#76](https://github.com/ueberauth/ueberauth_google/pull/76)

Thanks goes to all the contributes

## v0.9.0 - 2019-08-21

### Enhancement

* Add support for optional login_hint param [#61](https://github.com/ueberauth/ueberauth_google/pull/61)
* Use `json_library` method from Ueberauth config [#58](https://github.com/ueberauth/ueberauth_google/pull/58)
* Allows specifying `{m, f, a}` tuples for things such as Client ID
  and Client Secret [#60](https://github.com/ueberauth/ueberauth_google/pull/60)
* Allows the newest oauth2 package versions with potential security fixes [#68](https://github.com/ueberauth/ueberauth_google/pull/68)

## v0.6.0 - 2017-07-18

* Add support for `access_type` per request using `url` parameter.

## v0.5.0 - 2016-12-27

* Add support for new params: `access_type`, `approval_prompt`, `state`.
* Fix Elixir warnings.

## v0.4.0 - 2016-09-21

* Target Elixir 1.3 and greater.
* Fix OAuth bug with 0.6.0 pin.

## v0.3.0 - 2016-08-15

* Use OpenID endpoint for profile information.
* Update authorize and token URLs.

## v0.2.0 - 2016-12-10

* Release 0.2.0 to follow Ueberauth.
