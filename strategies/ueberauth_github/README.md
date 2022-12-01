# Überauth GitHub

[![Build Status](https://travis-ci.org/ueberauth/ueberauth_github.svg?branch=master)](https://travis-ci.org/ueberauth/ueberauth_github)
[![Module Version](https://img.shields.io/hexpm/v/ueberauth_github.svg)](https://hex.pm/packages/ueberauth_github)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ueberauth_github/)
[![Total Download](https://img.shields.io/hexpm/dt/ueberauth_github.svg)](https://hex.pm/packages/ueberauth_github)
[![License](https://img.shields.io/hexpm/l/ueberauth_github.svg)](https://github.com/ueberauth/ueberauth_github/blob/master/LICENSE.md)
[![Last Updated](https://img.shields.io/github/last-commit/ueberauth/ueberauth_github.svg)](https://github.com/ueberauth/ueberauth_github/commits/master)

> GitHub OAuth2 strategy for Überauth.

## Installation

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

    Or, to read the client credentials at runtime:

    ```elixir
    config :ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: {:system, "GITHUB_CLIENT_ID"},
      client_secret: {:system, "GITHUB_CLIENT_SECRET"}
    ```

5.  Include the Überauth plug in your router:

    ```elixir
    defmodule MyApp.Router do
      use MyApp.Web, :router

      pipeline :browser do
        plug Ueberauth
        ...
       end
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

7.  Your controller needs to implement callbacks to deal with `Ueberauth.Auth`
    and `Ueberauth.Failure` responses.

For an example implementation see the [Überauth Example](https://github.com/ueberauth/ueberauth_example) application.

## Calling

Depending on the configured url you can initiate the request through:

    /auth/github

Or with options:

    /auth/github?scope=user,public_repo

By default the requested scope is "user,public\_repo". This provides both read
and write access to the GitHub user profile details and public repos. For a
read-only scope, either use "user:email" or an empty scope "". See more at
[GitHub's OAuth Documentation](https://developer.github.com/apps/building-integrations/setting-up-and-registering-oauth-apps/about-scopes-for-oauth-apps/).

Scope can be configured either explicitly as a `scope` query value on the
request path or in your configuration:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user,public_repo,notifications"]}
  ]
```

It is also possible to disable the sending of the `redirect_uri` to GitHub.
This is particularly useful when your production application sits behind a
proxy that handles SSL connections. In this case, the `redirect_uri` sent by
`Ueberauth` will start with `http` instead of `https`, and if you configured
your GitHub OAuth application's callback URL to use HTTPS, GitHub will throw an
`uri_mismatch` error.

To prevent `Ueberauth` from sending the `redirect_uri`, you should add the
following to your configuration:

```elixir
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [send_redirect_uri: false]}
  ]
```

## Private Emails

GitHub now allows you to keep your email address private. If you don't mind
that you won't know a users email address you can specify
`allow_private_emails`. This will set the users email as
`id+username@users.noreply.github.com`.

```elixir
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [allow_private_emails: true]}
  ]
```

## Copyright and License

Copyright (c) 2015 Daniel Neighman

This library is released under the MIT License. See the [LICENSE.md](./LICENSE.md) file
