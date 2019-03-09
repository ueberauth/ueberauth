# Überauth Facebook
[![Build Status][travis-img]][travis] [![Hex Version][hex-img]][hex] [![License][license-img]][license]

[travis-img]: https://travis-ci.org/ueberauth/ueberauth_facebook.svg?branch=master
[travis]: https://travis-ci.org/ueberauth/ueberauth_facebook
[hex-img]: https://img.shields.io/hexpm/v/ueberauth_facebook.svg
[hex]: https://hex.pm/packages/ueberauth_facebook
[license-img]: http://img.shields.io/badge/license-MIT-brightgreen.svg
[license]: http://opensource.org/licenses/MIT

> Facebook OAuth2 strategy for Überauth.

## Installation

1. Setup your application at [Facebook Developers](https://developers.facebook.com).

1. Add `:ueberauth_facebook` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_facebook, "~> 0.8"}]
    end
    ```

1. Add the strategy to your applications:

    ```elixir
    def application do
      [applications: [:ueberauth_facebook]]
    end
    ```

1. Add Facebook to your Überauth configuration:

    ```elixir
    config :ueberauth, Ueberauth,
      providers: [
        facebook: {Ueberauth.Strategy.Facebook, []}
      ]
    ```

1.  Update your provider configuration:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Facebook.OAuth,
      client_id: System.get_env("FACEBOOK_CLIENT_ID"),
      client_secret: System.get_env("FACEBOOK_CLIENT_SECRET")
    ```

1.  Include the Überauth plug in your controller:

    ```elixir
    defmodule MyApp.AuthController do
      use MyApp.Web, :controller
      plug Ueberauth
      ...
    end
    ```

1.  Create the request and callback routes if you haven't already:

    ```elixir
    scope "/auth", MyApp do
      pipe_through :browser

      get "/:provider", AuthController, :request
      get "/:provider/callback", AuthController, :callback
    end
    ```

1. Your controller needs to implement callbacks to deal with `Ueberauth.Auth` and `Ueberauth.Failure` responses.

For an example implementation see the [Überauth Example](https://github.com/ueberauth/ueberauth_example) application.

## Calling

Depending on the configured URL you can initialize the request through:

    /auth/facebook

Or with options:

    /auth/facebook?scope=email,public_profile

By default the requested scope is "public_profile". Scope can be configured either explicitly as a `scope` query value on the request path or in your configuration:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    facebook: {Ueberauth.Strategy.Facebook, [default_scope: "email,public_profile,user_friends"]}
  ]
```

Additionally you can now specify the `display` param to pass to Facebook:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    facebook: {Ueberauth.Strategy.Facebook, [
      default_scope: "email,public_profile,user_friends",
      display: "popup"
    ]}
  ]
```

`display` can be the following values: `page` (default), `async`, `iframe`, `popup`, `touch`, `wap`

Starting with Graph API version 2.4, Facebook has limited the default fields returned when fetching the user profile.
Fields can be explicitly requested using the `profile_fields` option:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    facebook: {Ueberauth.Strategy.Facebook, [profile_fields: "name,email,first_name,last_name"]}
  ]
```

See [Graph API Reference > User](https://developers.facebook.com/docs/graph-api/reference/user) for full list of fields.


## License

Please see [LICENSE](https://github.com/ueberauth/ueberauth_facebook/blob/master/LICENSE) for licensing details.

