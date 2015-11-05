defmodule Ueberauth do
  require IEx
  @moduledoc """
  Ueberauth is an authentication framework that is heavily inspired by [Omniauth](https://github.com/intridea/omniauth)
  I would call it a port but it is significantly different in operation - but almost the same by concept. Huge hat tip to omniauth.

  It is a two-phase authentication framework that provides a clear API - allowing for many strategies to be created and shared within the community.

  Ueberauth provides only the initial authentication challenge. The initial OAuth flow, collecting the information from a login form etc. It does not authenticate each request, that's up to your application. You could issue a token or put the result into a session for your applications needs. Libraries like (Guardian)[https://github.com/hassox/guardian] can help you with that aspect of authentication. Ueberauth manages the initial challenge only.

  The two phases are `request` and `callback`. These phases are implemented by Strategies.

  ### Strategies

  Strategies are plugs that decorate or intercept requests (or both).
  Strategies implement the two phases and then may allow the request to flow through to your downstream plugs.
  Implementing the request and callback phases is optional, and if not implemented the request will be decorated Ueberauth information
  and allowed to carry on through the pipeline.

  ### Request Phase

  The request phase is where you request information about the user. This could be a redirect to an OAuth2 authorization url
  or a form for collecting username and password. The request phase may be very asynchronous and should be concered with
  only the collection of information. When a request comes in on the request phase url the relevant strategy will receive the `request_phase!` call.

  In some cases (default) the application using Ueberauth is responsible for implementing the request phase.
  That is, you should setup a route to receive the request phase and provide a form etc.
  In some cases, like OAuth, the request phase is used to redirect your user to a 3rd party site to fullfil the request.

  For example, an OAuth strategy for Github will receive the request phase url and stop the request, redirecting you to Githubs OAuth challenge url with some query parameters.
  Once you complete the Github OAuth flow, the user will be redirected back to the host site to the callback URL.

  Another example is simple email/password authentication.
  A request is made by the client to the request phase path and the host application displays a form.
  The strategy will likely not do anything with the incomming request_phase request and simply pass through to the application.
  Once the form is completed, the POST should go to the callback url where it is handled (passwords checked, users created / authenticated).

  ### Callback Phase

  The callback phase is where the fun happens. Once a successful request phase has been completed, the request phase provider (OAuth provider or host site etc)
  should call the callback url. The strategy will intercept the request via the `callback_phase!`. If successful it should prepare the connection so the `Ueberauth.Auth` struct can be created, or set errors to indicate a failure.

  See `Ueberauth.Strategy` for more information on constructing the Ueberauth.Auth struct.

  ### Setup

  In your configuration file provide a list of the providers you intend to use. For example:

      config :ueberauth, Ueberauth,
        providers: [
          facebook: { Ueberauth.Strategy.Facebook, [ opt1: "value", opts2: "value" ] },
          github: { Ueberauth.Strategy.Github, [ opt1: "value", opts2: "value" ] }
        ]

  This will define two providers for you. The general structure of the providers value is:

      config :ueberauth, Ueberauth,
        providers: [
          <provider name>: { <Strategy Module>, [ <strategy options> ] }
        ]

  We use the configuration options for defining these to allow for dependency injection in different environments.
  The provider name will be used to construct request and response paths (by default) but will also be returned in the
  `Ueberauth.Auth` struct as the `provider` field.

  Once you've setup your providers, in your router you need to configure the plug to run. The plug should run before you application routes.

  In phoenix setup a pipeline:

      pipeline :ueberauth do
        Ueberauth.plug "/auth"
      end

  Its url matching is done via pattern matching rather than explicit runtime checks so your strategies will only fire for relevant requests.

  Now that you have this, your strategies will intercept relevant requests for each strategy for both request and callback phases. The default urls are (for our facebook and github example)

      # Request phase paths
      /auth/facebook
      /auth/github

      # Callback phase paths
      /auth/facebook/callback
      /auth/github/callback

  #### Customizing Paths

  These paths can be configured on a per strategy basis by setting options on the provider.
  Note: These paths are absolute

  Example:

      providers: [
        identity: { Ueberauth.Strategies.Identity, [ request_path: "/absolute/path", callback_path: "/absolute_path" ] }
      ]


  #### Http Methods

  By default, all callback urls are only avaialble via the GET method. You can override this via options to your strategy.

      providers: [
        identity: { Ueberauth.Strategies.Identity, [ methods: ["POST"] ] }
      ]

  #### Strategy Options

  All options that are passed into your strategy are available at runtime to modify the behaviour of the strategy.
  """

  alias Ueberauth.Strategy

  @doc """
  Fetch a successful auth from the connection object after the callback phase has run
  """
  def auth(conn) do
    conn.assigns[:ueberauth_auth]
  end

  defmacro plug(base_path) do
    opts = Application.get_env(:ueberauth, Ueberauth)

    parts = Enum.map(opts[:providers], fn({ name, { strategy, options } }) ->

      request_path = Dict.get(options, :request_path, Path.join(["/", base_path, to_string(name)]))
      callback_path = Dict.get(options, :callback_path, Path.join(["/", base_path, to_string(name), "callback"]))
      methods = Dict.get(options, :methods, ["GET"]) |> Enum.map(&(String.upcase(to_string(&1))))

      quoted_method_opts = quote do
        %{
          strategy_name: unquote(name),
          strategy: unquote(strategy),
          callback_path: unquote(callback_path),
          request_path: unquote(request_path),
          request_methods: unquote(methods),
          options: unquote(options)
        }
      end

      quote do
        def run!(conn, unquote(request_path)) do
          conn
          |> Plug.Conn.put_private(:ueberauth_request_options, unquote(quoted_method_opts))
          |> Strategy.run_request_phase(unquote(strategy))
        end

        def run!(%Plug.Conn{ method: method } = conn, unquote(callback_path)) when method in unquote(methods) do
          conn
          |> Plug.Conn.put_private(:ueberauth_request_options, unquote(quoted_method_opts))
          |> Strategy.run_callback_phase(unquote(strategy))
        end
      end
    end)

    quoted_parts = quote do
      unquote(parts)
    end

    module_contents = quote do
      def init(opts \\ []), do: []
      def call(conn, _), do: run!(conn, conn.request_path)
      unquote(quoted_parts)
      def run!(conn, _), do: conn # if we don't match anything just call through
    end

    module_name = Module.concat([Ueberauth, "Strategies", "Builder#{String.replace(base_path, ~r/[^a-zA-Z0-9]/, "")}"])

    Module.create(module_name, module_contents, Macro.Env.location(__ENV__))

    quote do
      plug unquote(module_name)
    end
  end
end
