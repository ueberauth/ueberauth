# Überauth GitHub

> GitHub OAuth2 strategy for Überauth.

## Installation

1. Setup your application at [GitHub Developer](https://developer.github.com).

1. Add `:ueberauth_github` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_github, "~> 0.4"}]
    end
    ```

1. Add the strategy to your applications:

    ```elixir
    def application do
      [applications: [:ueberauth_github]]
    end
    ```

1. Add GitHub to your Überauth configuration:

    ```elixir
    config :ueberauth, Ueberauth,
      providers: [
        github: {Ueberauth.Strategy.Github, []}
      ]
    ```

1.  Update your provider configuration:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET")
    ```

1.  Include the Überauth plug in your controller:

    ```elixir
    defmodule MyApp.AuthController do
      use MyApp.Web, :controller

      pipeline :browser do
        plug Ueberauth
        ...
       end
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

1. You controller needs to implement callbacks to deal with `Ueberauth.Auth` and `Ueberauth.Failure` responses.

For an example implementation see the [Überauth Example](https://github.com/ueberauth/ueberauth_example) application.

## Calling

Depending on the configured url you can initial the request through:

    /auth/github

Or with options:

    /auth/github?scope=user,public_repo

By default the requested scope is "user,public\_repo". Scope can be configured either explicitly as a `scope` query value on the request path or in your configuration:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user,public_repo,notifications"]}
  ]
```

## License

Please see [LICENSE](https://github.com/ueberauth/ueberauth_github/blob/master/LICENSE) for licensing details.
