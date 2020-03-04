# Überauth Apple

> Apple OAuth2 strategy for Überauth.

## Installation

1. Setup your application at [Apple Developer Console](https://developer.apple.com).

2. Add `:ueberauth_apple` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:ueberauth_apple, "~> 0.2"}]
    end
    ```

3. Add the strategy to your applications:

    ```elixir
    def application do
      [applications: [:ueberauth_apple]]
    end
    ```

4. Add Apple to your Überauth configuration:

    ```elixir
    config :ueberauth, Ueberauth,
      providers: [
        apple: {Ueberauth.Strategy.Apple, []}
      ]
    ```

5.  Update your provider configuration:

    Option 1 - Generate secret manually:

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

    Option 2 - Generate secret programmatically:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
      client_id: System.get_env("APPLE_CLIENT_ID"),
      client_secret: {YourApp.SomeModule, :secret_function}
    ```

    And implement the function to generate the secret, once you generate the secret, store it in Redis so the secret does not generate every time.

    ```elixir
    function secret_function(ueberauth_config) do
      secret = get_secret_from_redis()
      if secret do
        secret
      else
        secret = UeberauthApple.generate_client_secret(%{
          client_id: opts[:client_id],
          key_id: Application.get_env(:naboo, Naboo.Auth.Apple)[:key_id],
          team_id: Application.get_env(:naboo, Naboo.Auth.Apple)[:team_id],
          private_key: Application.get_env(:naboo, Naboo.Auth.Apple)[:private_key]
        })
        set_secret_to_redis(secret)
        secret
      end
    end
    ```

6.  Include the Überauth plug in your controller:

    ```elixir
    defmodule MyApp.AuthController do
      use MyApp.Web, :controller
      plug Ueberauth
      ...
    end
    ```

7.  Create the request and callback routes if you haven't already:

    ```elixir
    scope "/auth", MyApp do
      pipe_through :browser

      get "/:provider", AuthController, :request
      get "/:provider/callback", AuthController, :callback
    end
    ```

8. Your controller needs to implement callbacks to deal with `Ueberauth.Auth` and `Ueberauth.Failure` responses.

For an example implementation see the [Überauth Example](https://github.com/ueberauth/ueberauth_example) application.

## Calling

Since Apple only supports form post, you need to create a Sign-in button:

```html
<html>
    <head>
    </head>
    <body>
        <script type="text/javascript" src="https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js"></script>
        <div id="appleid-signin" data-color="black" data-border="true" data-type="sign in"></div>
        <script type="text/javascript">
            AppleID.auth.init({
                clientId : '<%= Application.get_env(:ueberauth, Ueberauth.Strategy.Apple.OAuth)[:client_id] %>',
                scope : 'email name',
                redirectURI : '<%= Routes.auth_url(@conn, :callback, "apple") %>',
                state : '[STATE]',
                usePopup : true //or false defaults to false
            });
        </script>
    </body>
</html>
```

Scope can be configured either explicitly as a `scope` query value on the request path or in your configuration:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    apple: {Ueberauth.Strategy.Apple, [default_scope: "name email", callback_methods: ["POST"]]}
  ]
```

To guard against client-side request modification, it's important to still check the domain in `info.urls[:website]` within the `Ueberauth.Auth` struct if you want to limit sign-in to a specific domain.

## License

Please see [LICENSE](https://github.com/loopsocial/ueberauth_apple/blob/master/LICENSE) for licensing details.
