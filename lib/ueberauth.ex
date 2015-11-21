defmodule Ueberauth do
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
  or a form for collecting username and password. The request phase is concerned with
  only the collection of information. When a request comes in on the request phase url the relevant strategy will receive the `handle_request!` call.

  In some cases (default) the application using Ueberauth is responsible for implementing the request phase.
  That is, you should setup a route to receive the request phase and provide a form etc.
  In some cases, like OAuth, the request phase is used to redirect your user to
  a 3rd party site to fulfill the request.

  For example, an OAuth strategy for GitHub will receive the request phase url
  and stop the request, redirecting you to GitHub’s OAuth challenge url with some query parameters.
  Once you complete the GitHub OAuth flow, the user will be redirected back to the host site to the callback URL.

  Another example is simple email/password authentication.
  A request is made by the client to the request phase path and the host application displays a form.
  The strategy will likely not do anything with the incoming `handle_request!` request and simply pass through to the application.
  Once the form is completed, the POST should go to the callback url where it is handled (passwords checked, users created / authenticated).

  ### Callback Phase

  The callback phase is where the fun happens. Once a successful request phase has been completed, the request phase provider (OAuth provider or host site etc)
  should call the callback url. The strategy will intercept the request via the `handle_callback!`. If successful it should prepare the connection so the `Ueberauth.Auth` struct can be created, or set errors to indicate a failure.

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
        plug Ueberauth, base_path: "/auth"
      end

  Its url matching is done via pattern matching rather than explicit runtime checks so your strategies will only fire for relevant requests.

  Now that you have this, your strategies will intercept relevant requests for
  each strategy for both request and callback phases. The default urls are (for
  our Facebook & GitHub example)

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

  By default, all callback urls are only available via the GET method. You can override this via options to your strategy.

      providers: [
        identity: { Ueberauth.Strategies.Identity, [ callback_methods: ["POST"] ] }
      ]

  #### Strategy Options

  All options that are passed into your strategy are available at runtime to modify the behaviour of the strategy.
  """

  alias Ueberauth.Strategy

  @doc """
  Fetch a successful auth from the connection object after the callback phase has run
  """
  @spec auth(Plug.Conn.t) :: Ueberauth.Auth.t
  def auth(conn) do
    conn.assigns[:ueberauth_auth]
  end

  @doc """
  Adds Ueberauth to your plug pipeline. `Ueberauth.plug/1` will find your providers from the environments configuration

      config :ueberauth, Ueberauth,
        providers: [
          facebook: { Ueberauth.Strategy.Facebook, [ opt1: "value", opts2: "value" ] },
          github: { Ueberauth.Strategy.Github, [ opt1: "value", opts2: "value" ] }
        ]

  From this configuration it will insert a plug into your pipeline that decorates requests that match
  the `handle_request!` path or `handle_callback!` path. When one of these paths is found, the relevant strategy
  will be inserted into the plug pipeline and may take whatever action is appropriate.

  The `base_path` option provides a url prefix for your Ueberauth strategies.

  ### Example

      # In phoenix

      pipeline :ueberauth do
        Ueberauth.plug "/auth"
      end

  This will result in the following paths being decorated:

      # handle_request!
      "/auth/facebook"
      "/auth/github"

      # handle_callback!
      "/auth/facebook/callback"
      "/auth/github/callback"

  To customize these paths see `Ueberauth.Strategy`

  Note that in phoenix the 'scope' of the request path does not matter, the paths that Ueberauth matches against are absolute paths from the root.

  ### Example

      pipeline :ueberauth do
        Ueberauth.plug "/auth"
      end

      scope "/foo" do
        pipe_through [:browser, :ueberauth] do
          # …
        end
      end

  This is a useless case. Given that the router will always match on "/foo" the Ueberauth plugs that are matching at "/auth" will never fire.
  """
  def init(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:ueberauth, Ueberauth), opts)

    {base_path, opts}  = Keyword.pop(opts, :base_path)
    {providers, _opts} = Keyword.pop(opts, :providers)

    Enum.reduce providers, %{}, fn {name, {module, opts}} = strategy, acc ->
      request_path = request_path(base_path, strategy)
      callback_path = callback_path(base_path, strategy)
      callback_methods = callback_methods(opts)

      request_opts = strategy_opts(strategy, request_path, callback_path, callback_methods)
      callback_opts = strategy_opts(strategy, request_path, callback_path, callback_methods)

      acc
      |> Map.put(request_path, {module, :run_request, request_opts})
      |> Map.put(callback_path, {module, :run_callback, callback_opts})
    end
  end

  def call(%{request_path: request_path} = conn, opts) do
    if strategy = Map.get(opts, request_path) do
      run!(conn, strategy)
    else
      conn
    end
  end

  defp run!(conn, {module, :run_request, opts}) do
    conn
    |> Plug.Conn.put_private(:ueberauth_request_options, opts)
    |> Strategy.run_request(module)
  end

  defp run!(conn, {module, :run_callback, opts}) do
    if conn.method in opts[:callback_methods] do
      conn
      |> Plug.Conn.put_private(:ueberauth_request_options, opts)
      |> Strategy.run_callback(module)
    else
      conn
    end
  end

  defp strategy_opts({name, {module, opts}}, req_path, cb_path, cb_meths) do
    %{strategy_name: name,
      strategy: module,
      callback_path: cb_path,
      request_path: req_path,
      callback_methods: cb_meths,
      options: opts}
  end

  defp request_path(base_path, {name, {_, opts}}) do
    default_path = Path.join(["/", base_path, to_string(name)])
    Keyword.get(opts, :request_path, default_path)
  end

  defp callback_path(base_path, {name, {_, opts}}) do
    default_path = Path.join(["/", base_path, to_string(name), "callback"])
    Keyword.get(opts, :callback_path, default_path)
  end

  defp callback_methods(opts) do
    opts
    |> Keyword.get(:callback_methods, ["GET"])
    |> Enum.map(&(String.upcase(to_string(&1))))
  end
end
