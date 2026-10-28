# Changelog

## v2.1.0 (2022-11-29)

### Improvements

- Now you can have a lot more control over your http client, including
  selecting what client you are using from the adapters available for
  [Tesla](https://github.com/elixir-tesla/tesla).
  You can also easily add logging and tracing with middleware.

### Backward Incompatible Changes

- No longer directly using hackney it's still possible to use it through a
  Tesla adapter. To keep all your tweaks working correctly you'll need to
  add these settings:

  In mix.exs
    ```elixir
    # mix.exs
    defp deps do
      # Add the dependency
      [
        {:oauth2, "~> 2.0"},
        {:hackney, "~> 1.18"} # This is the new line you need to add
      ]
    end
    ```

  In config:
    ```elixir
    config :oauth2, adapter: Tesla.Adapter.Hackney
    ```

## v2.0.1 (2022-06-20)

### Bug fixes

- Fix incorrect Accept header when requesting token

## v2.0.0 (2019-07-15)

### Bug fixes (possibly backwards incompatible)

- Ensure that the OAuth client is authenticated via Authorization header as
  described in the spec (#131).

## v1.0.1 (2019-04-12)

### Bug fixes

- Always use the provided serializer if one is registered (#132)

## v1.0.0 (2019-03-13)

### Backward Incompatible Changes

- There is no longer a default serializer for `application/json`. Please make
  sure to register a serializer with `OAuth2.Client.put_serializer/3`.
- Serializers are now registered via `OAuth2.Client.put_serializer/3`.
  This change allows applications wrapping `oauth2` a way to provide default
  serializers without requiring the user to manually configure a serializer.

## v0.9.4 (2018-10-18)

### Improvements

- Relaxed `hackney` version requirements

## v0.9.3 (2018-08-13)

### Bug fixes

- Various type specs fixed

## v0.9.2 (2017-11-17)

### Bug fixes

- Updates the `OAuth2.Client.get_token!` function to handle error `OAuth2.Response` structs.

## v0.9.1 (2017-03-10)

### Improvements

- Fix dialyzer warnings.
- Update `hackney` to `1.7`

### Bug fixes

- De-dupe headers.

## v0.9.0 (2017-02-02)

### Improvements

- Remove deprecated usage of `Behaviour` and `defcallback`
- Provides better support for configuring `request_opts` that will be used on
  every request. This is useful for configuring SSL options, etc.
- Provides support for `hackney`s streaming of responses.
- Better warnings when a serializer isn't properly configured.

### Backward Incompatible Changes

- Responses with status codes between `400..599` will now return `{:error, %OAuth2.Response{}}` instead of `{:ok, %OAuth2.Response{}}`
- When using the `!` versions of functions, `{:error, %OAuth2.Response{}}` will
  be converted to an `%OAuth2.Error{}` and raised.

## v0.8.3 (2017-01-26)

- Fix compile-time warnings for Elixir 1.4
- Fix dialyzer warnings on `@type params`
- Fix `content-type` resolving when there are multiple params
- Return the same refresh token unless a new one is provided
- Raise an exception when missing serializer configuration

## v0.8.2 (2016-11-22)

### Bug Fixes

- Fixed an issue in handling non-standard `expires` key in access token
  requests.

## v0.8.1 (2016-11-18)

### Improvements

- Added the ability to debug responses from the provider.

### Bug Fixes

- Fixed regression in handling `text/plain` content-type for tokens in #74

## v0.8.0 (2016-10-05)

### Improvements

- Added `OAuth2.Client.basic_auth/1` convenience function.

### Bug Fixes

- Fixed broken `RefreshToken` strategy reported in #66
- Fixed an issue where checking the `content-type` was defaulting to
  `application/json` causing Poison to explode.

## v0.7.0 (2016-08-16)

### Improvements

- Add support for custom serializers based on MIME types.
- Remove dependency on `HTTPoison` in favor of using `hackney` directly.
- Remove dependency on `mimetype_parser`.
- `Poison` is now only a `test` dependency.

### Bug Fixes

- `expires_in` values that are returned as strings are now properly parsed into integers for `expires_at`.

### Backward Incompatible Changes

Prior to version `v0.7.0` `OAuth2.Client` was primarily used for the purpose
of interfacing with the OAuth server to retrieve a token. `OAuth2.Token` was
then responsible for using that token to make authenticated requests.

In `v0.7.0` this interface has been refactored so that an `OAuth2.Client` struct
now references an `OAuth2.Token` directly and many of the action methods have
been moved so that they are called on `OAuth2.Client`, with an instance of the
client struct as their first argument.

Please consult the [README](https://github.com/scrogson/oauth2/blob/v0.7.0/README.md) for an example of general usage to retrieve a token and make a request.

The following methods have been moved and adjusted so that they take a `OAuth2.Client.t` which contains a token, rather than a token directly:

- `OAuth2.AccessToken.get` -> `OAuth2.Client.get`
- `OAuth2.AccessToken.get!` -> `OAuth2.Client.get!`
- `OAuth2.AccessToken.put` -> `OAuth2.Client.put`
- `OAuth2.AccessToken.put!` -> `OAuth2.Client.put!`
- `OAuth2.AccessToken.patch` -> `OAuth2.Client.patch`
- `OAuth2.AccessToken.patch!` -> `OAuth2.Client.patch!`
- `OAuth2.AccessToken.post` -> `OAuth2.Client.post`
- `OAuth2.AccessToken.post!` -> `OAuth2.Client.post!`
- `OAuth2.AccessToken.delete` -> `OAuth2.Client.delete`
- `OAuth2.AccessToken.delete!` -> `OAuth2.Client.delete!`
- `OAuth2.AccessToken.refresh` -> `OAuth2.Client.refresh_token`
- `OAuth2.AccessToken.refresh!` -> `OAuth2.Client.refresh_token!`

Additionally, the following methods have been moved to `OAuth2.Request`

- `OAuth2.AccessToken.request` -> `OAuth2.Request.request`
- `OAuth2.AccessToken.request!` -> `OAuth2.Request.request!`

Diff: https://github.com/scrogson/oauth2/compare/v0.6.0...v0.7.0

## v0.6.0 (2016-06-24)

### Improvements

- Use Poison ~> 2.0
- Reset client headers after fetching the token

### Bug Fixes

- Fix up auth code flow to match the RFC

Diff: https://github.com/scrogson/oauth2/compare/v0.5.0...v0.6.0

## v0.5.0 (2015-11-03)

### Improvements

- You can now request a refresh token with `OAuth2.AccessToken.refresh`. The `!` alternative is also available.
- Added `Bypass` for improved testability.
- `Plug` is no longer a direct dependency. It is only included as a test dependency through the `Bypass` library.
- `OAuth2.AccessToken` now supports `DELETE` requests with `delete` and `delete!`
- More tests!

### Bug Fixes

- Params are no longer sent in both the body and as a query string for `POST` requests with `OAuth2.Client.get_token`
- Responses will no longer be parsed automatically if the `content-type` is not supported by this lib. Registering custom parsers is a future goal for this library.
- Errors are now properly raised when they occur.

### Backwards Incompatible Changes

- `OAuth2.new/1` has been removed. Use `OAuth2.Client.new/1` instead.

Diff: https://github.com/scrogson/oauth2/compare/v0.4.0...v0.5.0

## v0.4.0 (2015-10-27)

### Additions/Improvements

- `OAuth2.AccessToken` now supports: `post`, `post!`, `put`, `put!`, `patch`, and `patch!`.
- Better documentation
- Test coverage improved

### Bug fixes

- Empty response bodies are no longer decoded

### Breaking changes

- `OAuth2.AccessToken.get!/4` now returns `OAuth2.Response{}` instead of just the parsed body.

### Acknowledgments

Thanks to @meatherly, @dejanstrbac, and @optikfluffel for their contributions!

Diff: https://github.com/scrogson/oauth2/compare/v0.3.0...v0.4.0

## v0.3.0 (2015-08-19)

Bump `Plug` dependency to `1.0`.

Diff: https://github.com/scrogson/oauth2/compare/v0.2.0...v0.3.0

## v0.2.0 (2015-07-13)

- `:erlang.now` was replaced with `:os.timestamp` for compatibility with Erlang 18
- You can now pass options to the `HTTPoison` library with `OAuth2.Client.get_token/4` and `OAuth2.Client.get_token!/4`

Diff: https://github.com/scrogson/oauth2/compare/v0.1.1...v0.2.0

## v0.1.1 (2015-04-18)

- Remove compilation warnings.
- Fix `request_body` function for `ClientCredentials`

Diff: https://github.com/scrogson/oauth2/compare/v0.1.0...v0.1.1

## v0.1.0 (2015-04-14)

This release bring breaking changes and more documentation.

Please see the [README](https://github.com/scrogson/oauth2/blob/v0.1.0/README.md) or [Hex Docs](http://hexdocs.pm/oauth2/0.1.0) for more details.

Diff: https://github.com/scrogson/oauth2/compare/v0.0.5...v0.1.0

## v0.0.5 (2015-04-11)

- Handles Facebook `expires` key for Access Tokens.
- Ensure the token type defaults to 'Bearer' when it is not present.

Diff: https://github.com/scrogson/oauth2/compare/0.0.3...v0.0.5

## v0.0.3 (2015-01-12)

- Relax version requirements for Poison.

## v0.0.2 (2015-01-10)

This release brings Password and Client Credentials strategies.

http://tools.ietf.org/html/draft-ietf-oauth-v2-15#section-4.3
http://tools.ietf.org/html/draft-ietf-oauth-v2-15#section-4.4

## v0.0.1 (2014-12-07)

Initial release.

This initial release includes a functional authorization code strategy: http://tools.ietf.org/html/draft-ietf-oauth-v2-15#section-4.1
