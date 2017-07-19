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
  like (Guardian)[https://github.com/hassox/guardian] can help you with that
  aspect of authentication.

  The two phases are `request` and `callback`. These phases are implemented by
  Strategies.

  ### Strategies

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
  implementing the request phase. That is, you should setup a route to receive
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
  has been completed, the request phase provider (OAuth provider or host site etc)
  should call the callback url. The strategy will intercept the request via the
  `handle_callback!`. If successful it should prepare the connection so the
  `Ueberauth.Auth` struct can be created, or set errors to indicate a failure.

  See `Ueberauth.Strategy` for more information on constructing the
  `Ueberauth.Auth` struct.

  ### Setup

  In your configuration file provide a list of the providers you intend to use.

  #### Example

      config :ueberauth, Ueberauth,
        providers: [
          facebook: {Ueberauth.Strategy.Facebook, [opt1: "value", opts2: "value"]},
          github: {Ueberauth.Strategy.Github, [opt1: "value", opts2: "value"]}
        ]

  This will define two providers for you. The general structure of the providers
  value is:

      config :ueberauth, Ueberauth,
        providers: [
          <provider name>: {<Strategy Module>, [<strategy options>]}
        ]

  We use the configuration options for defining these to allow for dependency
  injection in different environments. The provider name will be used to construct
  request and response paths (by default) but will also be returned in the
  `Ueberauth.Auth` struct as the `provider` field.

  Once you've setup your providers, in your router you need to configure the plug
  to run. The plug should run before you application routes.

  In phoenix, plug this module in your controller:

      defmodule MyApp.AuthController do
        use MyApp.Web, :controller
        plug Ueberauth

        ...
      end

  Its URL matching is done via pattern matching rather than explicit runtime
  checks so your strategies will only fire for relevant requests.

  Now that you have this, your strategies will intercept relevant requests for
  each strategy for both request and callback phases. The default urls are (for
  our Facebook & GitHub example)

      # Request phase paths
      /auth/facebook
      /auth/github

      # Callback phase paths
      /auth/facebook/callback
      /auth/github/callback

  If you want to include only some of the providers with your plug
  you can specify a list of configured providers

      def module MyApp.Admin.AuthController do
        user MyApp.Web :controller
        plug Ueberauth, providers: [:identity], base_path: "/admin/auth"
      end

  This will allow you to have different login points in your
  application selectively using some or all of the providers.

  #### Customizing Paths

  These paths can be configured on a per strategy basis by setting options on
  the provider.

  Note: These paths are absolute

  #### Example

      config :ueberauth, Ueberauth,
        base_path: "/login" # default is "/auth"
        providers: [
          identity: {Ueberauth.Strategies.Identity, [request_path: "/login/identity",
                                                     callback_path: "/login/identity/callback"]}
        ]

  #### Http Methods

  By default, all callback urls are only available via the `"GET"` method. You
  can override this via options to your strategy.

      providers: [
        identity: {Ueberauth.Strategies.Identity, [callback_methods: ["POST"]]}
      ]

  #### Strategy Options

  All options that are passed into your strategy are available at runtime to
  modify the behaviour of the strategy.
  """

  alias Ueberauth.Strategy

  @doc """
  Fetch a successful auth from the `Plug.Conn`.

  This should only be called after the callback phase has run.
  """
  @spec auth(Plug.Conn.t) :: Ueberauth.Auth.t
  def auth(conn) do
    conn.assigns[:ueberauth_auth]
  end

  @doc false
  def init(opts \\ []) do
    {provider_list, opts} = Keyword.pop(opts, :providers, :all)
    opts = Keyword.merge(Application.get_env(:ueberauth, Ueberauth), opts)

    {base_path, opts}  = Keyword.pop(opts, :base_path, "/auth")
    {all_providers, _opts} = Keyword.pop(opts, :providers)

    providers = if provider_list == :all do
      all_providers
    else
      all_providers
      |> Keyword.split(provider_list)
      |> elem(0)
    end

    Enum.reduce providers, %{}, fn {_name, {module, _}} = strategy, acc ->
      %{callback_methods: methods} = opts = strategy_opts(strategy, base_path)

      acc = Map.put(acc, {opts.request_path, "GET"}, {module, :run_request, opts})

      Enum.reduce(methods, acc, fn method, acc ->
        Map.put(acc, {opts.callback_path, method}, {module, :run_callback, opts})
      end)
    end
  end

  @doc false
  def call(%{request_path: request_path, method: method} = conn, opts) do
    if strategy = Map.get(opts, {String.replace_trailing(request_path, "/", ""), method}) do
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

  defp strategy_opts({name, {module, opts}} = strategy, base_path) do
    %{strategy_name: name,
      strategy: module,
      callback_path: callback_path(base_path, strategy),
      request_path: request_path(base_path, strategy),
      callback_methods: callback_methods(opts),
      options: opts,
      callback_url: Keyword.get(opts, :callback_url),
      callback_params: Keyword.get(opts, :callback_params)}
  end

  defp request_path(base_path, {name, {_, opts}}) do
    default_path = Path.join(["/", base_path, to_string(name)])
    String.replace_trailing(Keyword.get(opts, :request_path, default_path), "/", "")
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
