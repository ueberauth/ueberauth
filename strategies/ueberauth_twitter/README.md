# Überauth Twitter

[![Module Version](https://img.shields.io/hexpm/v/ueberauth_twitter.svg)](https://hex.pm/packages/ueberauth_twitter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ueberauth_twitter/)
[![Total Download](https://img.shields.io/hexpm/dt/ueberauth_twitter.svg)](https://hex.pm/packages/ueberauth_twitter)
[![License](https://img.shields.io/hexpm/l/ueberauth_twitter.svg)](https://github.com/ueberauth/ueberauth_twitter/blob/master/LICENSE.md)
[![Last Updated](https://img.shields.io/github/last-commit/ueberauth/ueberauth_twitter.svg)](https://github.com/ueberauth/ueberauth_twitter/commits/master)

> Twitter strategy for Überauth.

_Note_: Sessions are required for this strategy.

## Installation

1. Setup your application at [Twitter Developers](https://dev.twitter.com/).

2.  Add `:ueberauth_twitter` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [
        {:ueberauth_twitter, "~> 0.3"}
      ]
    end
    ```

3.  Add Twitter to your Überauth configuration:

    ```elixir
    config :ueberauth, Ueberauth,
      providers: [
        twitter: {Ueberauth.Strategy.Twitter, []}
      ]
    ```

4.  Update your provider configuration:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Twitter.OAuth,
      consumer_key: System.get_env("TWITTER_CONSUMER_KEY"),
      consumer_secret: System.get_env("TWITTER_CONSUMER_SECRET")
    ```

5.  Include the Überauth plug in your controller:

    ```elixir
    defmodule MyApp.AuthController do
      use MyApp.Web, :controller
      plug Ueberauth
      ...
    end
    ```

6.  Create the request and callback routes if you haven't already:

    ```elixir
    scope "/auth", MyApp do
      pipe_through :browser

      get "/:provider", AuthController, :request
      get "/:provider/callback", AuthController, :callback
    end
    ```

7. Your controller needs to implement callbacks to deal with `Ueberauth.Auth`
   and `Ueberauth.Failure` responses.

For an example implementation see the [Überauth Example](https://github.com/ueberauth/ueberauth_example) application.

## Calling

Depending on the configured url you can initiate the request through:

    /auth/twitter

## Development mode

As noted when registering your application on the Twitter Developer site, you need to explicitly specify the `oauth_callback` url.  While in development, this is an example url you need to enter.

    Website - http://127.0.0.1
    Callback URL - http://127.0.0.1:4000/auth/twitter/callback

## Copyright and License

Copyright (c) 2015 Sean Callan

This library is released under the MIT License. See the [LICENSE.md](./LICENSE.md) file
for further details.
