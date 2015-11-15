# Überauth Facebook

> Facebook OAuth2 strategy for Überauth.

### Setup

Include the provider in your configuration for Überauth

```elixir
config :ueberauth, Ueberauth,
  providers: [
    facebook: [ { Ueberauth.Strategy.Facebook, [] } ]
  ]
```

Then include the configuration for github.

```elixir
config :ueberauth, Ueberauth.Strategy.Facebook.OAuth,
  client_id: System.get_env("FACEBOOK_APP_ID"),
  client_secret: System.get_env("FACEBOOK_APP_SECRET")

```

If you haven't already, create a pipeline and setup routes for your callback handler

```elixir
pipeline :auth do
  Ueberauth.plug "/auth"
end

scope "/auth" do
  pipe_through [:browser, :auth]

  get "/:provider/callback", AuthController, :callback
end
```

Create an endpoint for the callback where you will handle the `Ueberauth.Auth` struct

```elixir
defmodule MyApp.AuthController do
  use MyApp.Web, :controller

  def callback_phase(%{ assigns: %{ ueberauth_failure: fails } } = conn, _params) do
    # do things with the failure
  end

  def callback_phase(%{ assigns: %{ ueberauth_auth: auth } } = conn, params) do
    # do things with the auth
  end
end
```

For more details on configuring Überauth and strategies see the official documentation: [scrogson/ueberauth](https://github.com/scrogson/ueberauth).

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

1. Add ueberauth_facebook to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_facebook, "~> 0.0.1"}]
    end
    ```
