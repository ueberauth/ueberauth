# Überauth Twitter

> Twitter strategy for Überauth.

_Note_: Sessions are required for this strategy.

## Installation

1. Setup your application at [Twitter Developers](https://dev.twitter.com/).

1. Add `:ueberauth_twitter` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_twitter, "~> 0.2"},
       {:oauth, github: "tim/erlang-oauth"}]
    end
    ```

1. Add the strategy to your applications:

    ```elixir
    def application do
      [applications: [:ueberauth_twitter]]
    end
    ```

1. Add Twitter to your Überauth configuration:

    ```elixir
    config :ueberauth, Ueberauth,
      providers: [
        twitter: {Ueberauth.Strategy.Twitter, []}
      ]
    ```

1.  Update your provider configuration:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Twitter.OAuth,
      consumer_key: System.get_env("TWITTER_CONSUMER_KEY"),
      consumer_secret: System.get_env("TWITTER_CONSUMER_SECRET")
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

1. You controller needs to implement callbacks to deal with `Ueberauth.Auth` and `Ueberauth.Failure` responses.

For an example implementation see the [Überauth Example](https://github.com/ueberauth/ueberauth_example) application.

## Calling

Depending on the configured url you can initial the request through:

    /auth/twitter

## License

Please see [LICENSE](https://github.com/ueberauth/ueberauth_twitter/blob/master/LICENSE) for licensing details.

