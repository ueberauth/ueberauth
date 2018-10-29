defmodule Ueberauth do
  @moduledoc """
  Ueberauth is two-phase authentication framework that provides a clear API -
  allowing for many strategies to be created and shared within the community. It
  is heavily inspired by [Omniauth](https://github.com/intridea/omniauth). You
  could call it a port but it is significantly different in operation - but
  almost the same by concept. Huge hat tip to [Intridea](https://github.com/intridea).

  Ueberauth provides only the initial authentication challenge, (initial OAuth
  flow, collecting the information from a login form, etc). It does not
  authenticate each request, that's up to your application. You could issue a
  token or put the result into a session for your applications needs. Libraries
  like (Guardian)[https://github.com/ueberauth/guardian] can help you with that
  aspect of authentication.

  ### Strategies

  Strategies are the work-horse of Ueberauth.
  Every implementation of a strategy can provide authentication capabilities against a different provider.

  Identity, Google, Facebook, Slack etc.

  Strategies have two simple callbacks.

  1. request_url
  2. authenticate

  The request_url is used to provide clients with the url to use to access the providers challenge page.

  The authenticate function is used to deal with the response. Using the `code`, `token` or other information passed from the provider
  the authenticate function should call out to the provider to gather the information sufficient to complete the `Ueberauth.Auth` struct.

  This may be done from anywhere in your application including sockets, channels, controller or as implemented by `Ueberauth.Plug`


  ### Using with Ueberauth.Plug

  You can of course call the strategies authenticate or request_url functions at any time in your application. However when you use the `Ueberauth.Plug`

  The two phases are `request` and `callback`. These phases are implemented by `Ueberauth.Plug` and your configured Strategies.

  ### Request Phase

  The request phase is where you request information about the user. This could
  be a redirect to an OAuth2 authorization url or a form for collecting username
  and password. The request phase is concerned with only the collection of
  information. When a request comes in on the request phase url the relevant
  strategy will receive the `redirect_url` call and when using the `Ueberauth.Plug` plug will redirect the client.

  In some cases (default) the application using Ueberauth is responsible for
  implementing the request phase. That is, you should setup a route to receive
  the request phase and provide a form etc. In some cases, like OAuth, the
  request phase is used to redirect your user to a 3rd party site to fulfill
  the request.

  For example, an OAuth strategy for GitHub will receive the request phase url
  and stop the request, redirecting you to GitHub’s OAuth challenge url with
  some query parameters. Once you complete the GitHub OAuth flow, the user will
  be redirected back to the host site to the callback URL.

  Another example is simple email/password authentication. A request is made by
  the client to the request phase path and the host application redirects to a login form.

  ### Callback Phase

  The callback phase is where the fun happens. Once a successful request phase
  has been completed, the request phase provider (OAuth provider or host site etc)
  should call the callback url. The `Ueberauth.Plug` will intercept the request and call the `authenticate` function
  on the matching strategy. When successful, the strategy will return an `Ueberauth.Auth` struct and make that available
  in the `assigns` map under the `:ueberauth_auth` key.

  ### Setup

  Configuration is done when you use the `Ueberauth.Plug`. This can be specified in your mix configs, or via a function that dynamically calculates the configuration.

  All strategies will take a list of options. For example:

      plug Ueberauth.Plug, providers: [
        github: {Ueberauth.Strategy.Github, [opt1: "value", opt2: "value"]},
        facebook: {Ueberauth.Strategy.Facebook, [opt1: "value", opt2: "value"]},
      ]

  By default, the callback url will be calculated the be at `"/the/path/to/your/auth/:provider/callback"` where `callback` is the `:callback_suffix`.

  You can specify the callback suffix in your configuration nex to your providers.

      plug Ueberauth.Plug,
        providers: [
          github: {Ueberauth.Strategy.Github, [opt1: "value", opt2: "value"]},
          facebook: {Ueberauth.Strategy.Facebook, [opt1: "value", opt2: "value"]},
        ],
        callback_suffix: "phone_home"

  The other way you can configure `Ueberauth.Plug` is to provide a function.

  The function can be zero or one arity. If one arity, it will receive the Plug.Conn struct. The return value is the configuration Keyword list.

  The general structure of the providers
  value is:

        providers: [
          <provider name>: {<Strategy Module>, [<strategy options>]}
        ]

  We use the configuration options for defining these to allow for dependency
  injection in different environments. The provider name will be used to construct
  request and response paths (by default) but will also be returned in the
  `Ueberauth.Auth` struct as the `provider` field.

  Its URL matching is done via pattern matching rather than explicit runtime
  checks so your strategies will only fire for relevant requests.

  Now that you have this, your strategies will intercept relevant requests for
  each strategy for both request and callback phases. The default urls are (for
  our Facebook & GitHub example)

      # Request phase paths
      /facebook
      /github

      # Callback phase paths
      /facebook/callback
      /github/callback

  To setup a prefix, configure the prefix in your router.

  #### Strategy Options

  All options that are passed into your strategy are available at runtime to
  modify the behaviour of the strategy.

  Where appropriate, all strategies _should_ handle a `:credentials` value in their options that
  allows overwriting of the providers credentials (id, secret etc)
  """
end
