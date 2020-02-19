# Überauth Apple

> Apple OAuth2 strategy for Überauth.

## Installation

1. Setup your application at [Apple Developer Console](https://developer.apple.com).

1. Add `:ueberauth_apple` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_apple, "~> 0.2"}]
    end
    ```

1. Add the strategy to your applications:

    ```elixir
    def application do
      [applications: [:ueberauth_apple]]
    end
    ```

1. Add Apple to your Überauth configuration:

    ```elixir
    config :ueberauth, Ueberauth,
      providers: [
        apple: {Ueberauth.Strategy.Apple, []}
      ]
    ```

1.  Update your provider configuration:

    If you don't have the client secret, generate the client secret:

    ```elixir
    UeberauthApple.generate_client_secret(%{
      client_id: "com.example.service",
      key_id: "10digitkey",
      team_id: "teamid",
      private_key: "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
      })
    ```

    Use that if you want to read client ID/secret from the environment
    variables in the compile time:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
      client_id: System.get_env("APPLE_CLIENT_ID"),
      client_secret: System.get_env("APPLE_CLIENT_SECRET")
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

Depending on the configured url you can initiate the request through:

    /auth/apple

Or with options:

    /auth/apple?scope=email%20name

By default the requested scope is "name". Scope can be configured either explicitly as a `scope` query value on the request path or in your configuration:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Apple, [default_scope: "name email"]}
  ]
```

To guard against client-side request modification, it's important to still check the domain in `info.urls[:website]` within the `Ueberauth.Auth` struct if you want to limit sign-in to a specific domain.

## License

Please see [LICENSE](https://github.com/loopsocial/ueberauth_apple/blob/master/LICENSE) for licensing details.
