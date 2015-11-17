# Überauth Google

> Google OAuth2 strategy for Überauth.

### Setup

Include the provider in your configuration for Überauth:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    google: [ { Ueberauth.Strategy.Google, [] } ]
  ]
```

Then configure your provider:

```elixir
config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
```

For an example implementation see the [Überauth Example](https://github.com/doomspork/ueberauth_example) application.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

1. Add `:ueberauth_google` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_google, "~> 0.1.0"}]
    end
    ```
