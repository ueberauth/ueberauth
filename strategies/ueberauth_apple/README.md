# Ueberauth Apple

[![Hex.pm](https://img.shields.io/hexpm/v/ueberauth_apple)](https://hex.pm/packages/ueberauth_apple)
[![Documentation](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/ueberauth_apple)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)

Ueberauth plugin for Apple OAuth / _Sign In with Apple_

## What is this?

[Ueberauth](https://github.com/ueberauth/ueberauth) is an authentication framework for Elixir applications that specializes in [OAuth](https://oauth.net/).
This library is one of many [plugins](https://github.com/ueberauth/ueberauth/wiki/List-of-Strategies) (called Strategies) that allow Ueberauth to integrate with different identity providers.
Specifically, this one implements an OAuth integration with Apple, for their _Sign In with Apple_ service.

## Important Notes

Apple's OAuth implementation is different than you may expect.
Please keep the following in mind:

* There are only two scopes available, `name` and `email`, for retrieving personal information about the user signing in.
  Neither scope provides access to any API endpoints; instead they change the data returned during the sign-in process.

* If any scopes are requested during sign-in, the response from Apple **must** be in the form of a form POST request to your application.
  Otherwise, a GET request with query parameters will occur.
  Accepting POST callbacks require additional setup with Ueberauth that may not be necessary for other providers.

* Because scoped requests must use a form POST request, any cookies that will be read during the callback phase **must** have `SameSite=None` (and, therefore, `Secure`).
  Otherwise the browser will block them from being sent along with the POST because it is not a top-level navigation.

* Apple requires a **Primary App ID** (with the _Sign In with Apple_ capability enabled), **Services ID**, and **Private Key** to be set up in their [Apple Developer Console](https://developer.apple.com/account) before integration can occur.

* Apple OAuth Client Secrets are generated from a Private Key and have a maximum lifetime of six months.

* Users may choose not to share their information with your application, in which case an anonymized private relay email address will be supplied during the callback phase.

* Apple does not supply the user's name in callback responses after the first time.

## Quick Start

For detailed instructions, see [Getting Started](guides/getting-started.md).

1. Set up a Services ID and download a Private Key in the [Apple Developer Console](https://developer.apple.com/account).
  See [Getting Started](guides/getting-started.md) or the [official documentation](https://developer.apple.com/sign-in-with-apple/get-started/) for more information

2. Add `:ueberauth_apple` to your list of dependencies in `mix.exs` and run `mix deps.get`:

  ```elixir
  def deps do
    [
      # ...
      {:ueberauth, "~> 0.10"},
      {:ueberauth_apple, "~> 0.6.0"}
    ]
  end
  ```

3. Add this library as a new provider for Ueberauth (see [Getting Started](guides/getting-started.md#provider-configuration) for more information on the available options):

  ```elixir
  config :ueberauth, Ueberauth,
    providers: [
      # Default configuration: does not retrieve name or email address during sign-in.
      apple: {Ueberauth.Strategy.Apple, []}

      # Alternative configuration: retrieve name and email during sign-in.
      apple: {Ueberauth.Strategy.Apple, callback_methods: ["POST"], default_scope: "name email"}
    ]
  ```

4. Configure the provider (see [Getting Started](guides/getting-started.md#oauth-configuration) for more information on generating client secrets):

  ```elixir
  config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
    client_id: System.get_env("APPLE_CLIENT_ID"),
    client_secret: {MyApp.Apple, :client_secret}
  ```

5. Create a Client Secret generator function.
  (Apple's Client Secrets are generated from a Private Key and have a maximum life of six months.)

6. Integrate Ueberauth with the rest of your application (usually: router and controller).
  See [Getting Started](guides/getting-started.md#plug-integration) or the [Ueberauth Example](https://github.com/ueberauth/ueberauth_example) application.

## Usage

Making a request to `/auth/apple` will redirect to the Apple sign-in page with the relevant query parameters.
You can include a `scope` query param to configure the scopes at runtime: `/auth/apple?scope=name%20email`.
The default scopes can also be configured in the provider definition.

To guard against client-side request modification, it's important to still check the domain in `info.urls[:website]` within the `Ueberauth.Auth` struct if you want to limit sign-in to a specific domain.

## Acknowledgments

Thank you to [Loop Social](https://github.com/loopsocial/) for the original implementation of this library.

## License

Please see [LICENSE](LICENSE) for licensing details.
