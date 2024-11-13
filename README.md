# Überauth

[![Continuous Integration](https://github.com/ueberauth/ueberauth/actions/workflows/ci.yml/badge.svg)](https://github.com/ueberauth/ueberauth/actions/workflows/ci.yml)
[![Codecov](https://codecov.io/gh/ueberauth/ueberauth/branch/master/graph/badge.svg)](https://codecov.io/gh/ueberauth/ueberauth)
[![Inline docs](http://inch-ci.org/github/ueberauth/ueberauth.svg)](http://inch-ci.org/github/ueberauth/ueberauth)
[![Hex Version](http://img.shields.io/hexpm/v/ueberauth.svg)](https://hex.pm/packages/ueberauth)
[![Hex docs](http://img.shields.io/badge/hex.pm-docs-green.svg)](https://hexdocs.pm/ueberauth)
[![Total Download](https://img.shields.io/hexpm/dt/ueberauth.svg)](https://hex.pm/packages/ueberauth)
[![License](https://img.shields.io/hexpm/l/ueberauth.svg)](https://github.com/ueberauth/ueberauth/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/ueberauth/ueberauth.svg)](https://github.com/ueberauth/ueberauth/commits/master)

> An Elixir Authentication System for Plug-based Web Applications

Ueberauth is a two-phase authentication framework that provides a clear API -
allowing for many strategies to be created and shared within the community. It
is most often used with third-party providers. It is heavily inspired by
[Omniauth](https://github.com/intridea/omniauth). You could call it a port but
it is significantly different in operation - but almost the same concept.
Huge hat tip to [Intridea](https://github.com/intridea).

Ueberauth provides only the initial authentication challenge, (initial OAuth
flow, collecting the information from a login form, etc). It does not
authenticate each request, that's up to your application, but it integrates
nicely with `mix phx.gen.auth` generators. You may also use libraries
like [Guardian](https://github.com/ueberauth/guardian) for authentication.

## Integration with Phoenix

To integrate `Ueberauth` with your Phoenix application, the first step
is to choose your strategy. There are several under [our organization on
GitHub](https://github.com/ueberauth) and more on [Hex.pm](https://hex.pm).
See the [Wiki](https://github.com/ueberauth/ueberauth/wiki/List-of-Strategies)
for a complete list.

For this example, we will use [the GitHub strategy](https://github.com/ueberauth/ueberauth_github).
You just need to follow a series of steps:

1.  Setup your application at [GitHub Developer](https://developer.github.com).

2.  Add `:ueberauth_github` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [
        {:ueberauth_github, "~> 0.8"}
      ]
    end
    ```

3.  Add GitHub to your Überauth configuration:

    ```elixir
    config :ueberauth, Ueberauth,
      providers: [
        github: {Ueberauth.Strategy.Github, []}
      ]
    ```

4.  Update your provider configuration:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET")
    ```

5.  Create the request and callback routes in your `Phoenix.Router`:

    ```elixir
    scope "/auth", MyAppWeb do
      pipe_through :browser

      get "/:provider", AuthController, :request
      get "/:provider/callback", AuthController, :callback
    end
    ```

6.  Implement the routes in a controller to deal with `Ueberauth.Auth`
    and `Ueberauth.Failure` responses.

    ```elixir
    defmodule MyAppWeb.AuthController do
      use MyAppWeb, :controller
      plug Ueberauth
    
      def callback(%{assigns: %{ueberauth_failure: %Ueberauth.Failure{}}} = conn, _params) do
        conn
        |> put_flash(:error, "Failed to authenticate")
        |> redirect(to: ~p"/")
      end
    
      def callback(%{assigns: %{ueberauth_auth: %UeberAuth{} = auth}} = conn, _params) do
        # You will have to implement this function that inserts into the database
        user = MyApp.Accounts.create_user_from_ueberauth!(auth)

        # If you are using mix phx.gen.auth, you can use it to login
        MyAppWeb.UserAuth.log_in_user(conn, user)

        # If you are not using mix phx.gen.auth, store the user in the session
        conn
        |> renew_session()
        |> put_session(:user_id, user.id)
        |> redirect(to: ~p"/")
      end
    end
    ```

You will have to implement the function that receives the authentication info
and creates a new user in the database, such as `create_user_from_ueberauth!`
above, and you are good to go!

If you want to look at an example, check out
[ueberauth/ueberauth_example](https://github.com/ueberauth/ueberauth_example).

## Strategies

Strategies are plugs that decorate or intercept requests (or both).

Strategies implement the two phases and then may allow the request to flow
through to your downstream plugs. Implementing the request and callback phases
is optional depending on the strategies requirements. If a strategy does not
redirect, the request will be decorated with Ueberauth information and
allowed to carry on through the pipeline.

### Request Phase

The request phase is where you request information about the user. This could
be a redirect to an OAuth2 authorization url or a form for collecting username
and password. The request phase is concerned with only the collection of
information. When a request comes in on the request phase url the relevant
strategy will receive the `handle_request!` call.

In some cases (default) the application using Ueberauth is responsible for
implementing the request phase. That is, you should set up a route to receive
the request phase and provide a form etc. In some cases, like OAuth, the
request phase is used to redirect your user to a 3rd party site to fulfill
the request.

For example, an OAuth strategy for GitHub will receive the request phase url
and stop the request, redirecting you to GitHub’s OAuth challenge url with
some query parameters. Once you complete the GitHub OAuth flow, the user will
be redirected back to the host site to the callback URL.

Another example is simple email/password authentication. A request is made by
the client to the request phase path and the host application displays a form.
The strategy will likely not do anything with the incoming `handle_request!`
request and simply pass through to the application. Once the form is completed,
the POST should go to the callback url where it is handled (passwords checked,
users created / authenticated).

### Callback Phase

The callback phase is where the fun happens. Once a successful request phase
has been completed, the request phase provider (OAuth provider or host site,
etc) should call the callback URL. The strategy will intercept the request via
the `handle_callback!`. If successful, it should prepare the connection so the
`Ueberauth.Auth` struct can be created, or set errors to indicate a failure.

See `Ueberauth.Strategy` for more information on constructing the `Ueberauth.Auth`
struct.

## Customization

### Configuring providers

Your configuration file (`config/config.exs`) lists the providers you intend to use. For example:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    facebook: {Ueberauth.Strategy.Facebook, [opt1: "value", opts2: "value"]},
    github: {Ueberauth.Strategy.Github, [opt1: "value", opts2: "value"]}
  ]
```

This will define two providers for you. The general structure of the providers value is:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    <provider name>: {<Strategy Module>, [<strategy options>]}
  ]
```

We use the configuration options for defining these to allow for dependency
injection in different environments. The provider name will be used to construct
request and response paths (by default) but will also be returned in the
`Ueberauth.Auth` struct as the `provider` field.

Once you've setup your providers, you need to configure the `Ueberauth` plug to
run. It generally runs before your application routes but in Phoenix applications
it can also be done in a controller:

```elixir
defmodule MyAppWeb.AuthController do
  use MyAppWeb, :controller
  plug Ueberauth
  ...
end
```

Now that you have this, your strategies will intercept relevant requests for
each strategy for both request and callback phases. The default urls are (for
our Facebook & GitHub example)

```
# Request phase paths
/auth/facebook
/auth/github

# Callback phase paths
/auth/facebook/callback
/auth/github/callback
```

### Customizing Paths

These paths can be configured on a per strategy basis by setting options on
the provider.

```elixir
config :ueberauth, Ueberauth,
  base_path: "/login", # default is "/auth"
  providers: [
    identity: {Ueberauth.Strategies.Identity, [request_path: "/login/identity",
                                               callback_path: "/login/identity/callback"]}
  ]
```

### Customizing JSON Serializer

Your JSON serializer can be configured depending on what you have installed in
your application. Defaults to [Jason](https://github.com/michalmuskala/jason).

```elixir
config :ueberauth, Ueberauth,
  json_library: Poison # default is Jason
```

### Customizing HTTP Methods

By default, all callback URLs are only available via the `"GET"` method. You
can override this via options to your strategy.

```elixir
providers: [
  identity: {Ueberauth.Strategies.Identity, [callback_methods: ["POST"]]}
]
```

### Strategy Options

All options that are passed into your strategy are available at runtime to
modify the behaviour of the strategy.

## Copyright and License

Copyright (c) 2015 Sonny Scroggin

Released under the MIT License, which can be found in the repository in [`LICENSE`](https://raw.githubusercontent.com/ueberauth/ueberauth/master/LICENSE).
