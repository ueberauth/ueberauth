# Überauth Twitter

> Twitter strategy for Überauth.

### Setup

Include the provider in your configuration for Überauth:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    twitter: [ { Ueberauth.Strategy.Twitter, [] } ]
  ]
```

Then configure your provider:

```elixir
config :ueberauth, Ueberauth.Strategy.Twitter.OAuth,
  client_id: System.get_env("TWITTER_API_KEY"),
  client_secret: System.get_env("TWITTER_API_SECRET")
```

For an example implementation see the [Überauth Example](https://github.com/doomspork/ueberauth_example) application.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

1. Add `:ueberauth_twitter` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_twitter, "~> 0.1.0"}]
    end
    ```
