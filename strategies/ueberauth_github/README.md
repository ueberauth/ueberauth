# Überauth GitHub

Provides an Üeberauth strategy for authenticating with Github.

### Setup

Create an application in Github for you to use.

Register a new application at: [your github developer page](https://github.com/settings/developers) and get the `client_id` and `client_secret`.

Include the provider in your configuration for Üeberauth

````elixir
config :ueberauth, Ueberauth,
  providers: [
    github: [ { Ueberauth.Strategy.Github, [] } ]
  ]
````

Then include the configuration for github.

````elixir
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET")
````

If you haven't already, create a pipeline and setup routes for your callback handler

````elixir
pipeline :auth do
  Ueberauth.plug "/auth"
end

scope "/auth" do
  pipe_through [:browser, :auth]

  get "/:provider/callback", AuthController, :callback
end
````


Create an endpoint for the callback where you will handle the `Ueberauth.Auth` struct

````elixir
defmodule MyApp.AuthController do
  use MyApp.Web, :controller

  def callback_phase(%{ assigns: %{ ueberauth_failure: fails } } = conn, _params) do
    # do things with the failure
  end

  def callback_phase(%{ assigns: %{ ueberauth_auth: auth } } = conn, params) do
    # do things with the auth
  end
end
````

You can edit the behaviour of the Strategy by including some options when you register your provider.

To set the `uid_field`

````elixir
config :ueberauth, Ueberauth,
  providers: [
    github: [ { Ueberauth.Strategy.Github, [uid_field: :email] } ]
  ]
````

Default is `:login`

To set the default 'scopes' (permissions):

````elixir
config :ueberauth, Ueberauth,
  providers: [
    github: [ { Ueberauth.Strategy.Github, [default_scope: "user,public_repo"] } ]
  ]
````

Deafult is "user,public_repo"

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add ueber_github to your list of dependencies in `mix.exs`:

````elixir
def deps do
  [{:ueberauth_github, "~> 0.1.0"}]
end
````

# License

The MIT License (MIT)

Copyright (c) 2015 Daniel Neighman

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
