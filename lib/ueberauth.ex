defmodule Ueberauth do
  @moduledoc """
  Ueberauth is a two-phase authentication framework that provides a clear API -
  allowing for many strategies to be created and shared within the community. It
  is heavily inspired by [Omniauth](https://github.com/intridea/omniauth). You
  could call it a port but it is significantly different in operation - but
  almost the same by concept. Huge hat tip to [Intridea](https://github.com/intridea).

  Ueberauth provides only the initial authentication challenge, (initial OAuth
  flow, collecting the information from a login form, etc). It does not
  authenticate each request, that's up to your application. You could issue a
  token or put the result into a session for your applications needs. Libraries
  like [Guardian](https://github.com/hassox/guardian) can help you with that
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
  strategy will receive the `c:Ueberauth.Strategy.handle_request!/1` call.

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
  The strategy will likely not do anything with the incoming `c:Ueberauth.Strategy.handle_request!/1`
  request and simply pass through to the application. Once the form is completed,
  the POST should go to the callback url where it is handled (passwords checked,
  users created / authenticated).

  ### Callback Phase

  The callback phase is where the fun happens. Once a successful request phase
  has been completed, the request phase provider (OAuth provider or host site etc)
  should call the callback url. The strategy will intercept the request via the
  `c:Ueberauth.Strategy.handle_callback!/1`. If successful it should prepare the connection so the
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
  to run. The plug should run before your application routes.

  In phoenix, plug this module in your controller:

      defmodule MyApp.AuthController do
        use MyApp.Web, :controller
        plug Ueberauth

        ...
      end

  Its URL matching is done via pattern matching rather than explicit runtime
  checks so your strategies will only fire for relevant requests.

  Now that you have this, your strategies will intercept relevant requests for
  each strategy for both request and callback phases. The default URLs are (for
  our Facebook & GitHub example)

      # Request phase paths
      /auth/facebook
      /auth/github

      # Callback phase paths
      /auth/facebook/callback
      /auth/github/callback

  If you want to include only some of the providers with your plug
  you can specify a list of configured providers

      defmodule MyApp.Admin.AuthController do
        use MyApp.Web, :controller
        plug Ueberauth, providers: [:identity], base_path: "/admin/auth"
      end

  This will allow you to have different login points in your
  application selectively using some or all of the providers.

  #### Configuration of different Providers per OTP app

  If you wish to use Ueberauth in multiple OTP apps, and configure each instance of
  Ueberauth with a different list of Providers, you will need to do some things
  differently. When providing configuration for Ueberauth, you should set anything that
  differs by OTP app under the name of your OTP app, for example:

      config :my_app, Ueberauth,
        providers: [
          …
        ]

  Further, when using the Ueberauth plug, you should pass the `:otp_app` option,
  for example:

      defmodule MyApp.Admin.AuthController do
        use MyApp.Web, :controller
        plug Ueberauth,
          otp_app: :my_app,
          providers: [:identity],
          base_path: "/admin/auth"
      end

  This ensures that in addition to globally configured values under `:ueberauth`,
  values set under your own namespace are used with priority.

  #### Customizing Paths

  These paths can be configured on a per strategy basis by setting options on
  the provider.

  Note: These paths are absolute

  #### Example

      config :ueberauth, Ueberauth,
        base_path: "/login", # default is "/auth"
        providers: [
          identity: {Ueberauth.Strategies.Identity, [request_path: "/login/identity",
                                                     callback_path: "/login/identity/callback"]}
        ],
        json_library: Poison # or Jason

  #### Customizing Schemes

  By default, Ueberauth uses your `Plug.Conn` scheme.

  A custom scheme can be provided through the request header `X-Forwarded-Proto`.

  For example, in Nginx you can set it.

      proxy_set_header X-Forwarded-Proto $scheme;

  Another option is to override this via options to your strategy.

      providers: [
        identity: {Ueberauth.Strategies.Identity, [callback_scheme: "https"]}
      ]

  #### Customizing Ports

  By default, Ueberauth uses your `Plug.Conn` port.

  To override this via options to your strategy.

      providers: [
        identity: {Ueberauth.Strategies.Identity, [callback_port: 4000]}
      ]

  #### Http Methods

  By default, all callback URLs are only available via the `"GET"` method. You
  can override this via options to your strategy.

      providers: [
        identity: {Ueberauth.Strategies.Identity, [callback_methods: ["POST"]]}
      ]

  #### Strategy Options

  All options that are passed into your strategy are available at runtime to
  modify the behaviour of the strategy.
  """

  @behaviour Plug

  alias Ueberauth.Strategy

  @doc """
  Fetch a successful auth from the `Plug.Conn`.

  This should only be called after the callback phase has run.
  """
  @spec auth(Plug.Conn.t()) :: Ueberauth.Auth.t()
  def auth(conn) do
    conn.assigns[:ueberauth_auth]
  end

  @doc """
  Fetch the configured JSON library.

  A JSON library is required for Ueberauth to operate.

  In config.exs your implicit or explicit configuration is:

      config :ueberauth, Ueberauth, json_library: Jason

  Or:

      config :ueberauth, json_library: Jason

  If you are using per-app configuration, you can also use:

      config :my_app, Ueberauth, json_library: Jason

  The JSON library defaults to Jason but can be configured to Poison.

  In mix.exs you will need something like:

      def deps() do
        [
          ...
          {:jason, "<version>"} # or {:poison, "<version>"}
        ]
      end

  This file will serve underlying Ueberauth libraries as a hook to grab the
  configured JSON library.
  """
  def json_library(otp_app \\ nil) do
    environment = get_env([:ueberauth, otp_app])
    Keyword.get(environment, :json_library, Application.get_env(:ueberauth, :json_library, Jason))
  end

  @type path :: String.t()
  @type method :: String.t()
  @type route :: {{path, method}, mfa()}
  @type routes :: [route]

  @doc """
  Implements `c:Plug.init/1`
  """
  @impl Plug
  def init(options \\ []) do
    environment = get_env([:ueberauth, Keyword.get(options, :otp_app)])
    providers = get_providers(environment, options)
    base_path = get_base_path(environment, options)
    Enum.flat_map(providers, &build_routes(base_path, &1))
  end

  @doc """
  Implements `c:Plug.call/2`
  """
  @impl Plug
  def call(conn, routes) do
    route_prefix = Path.join(["/" | conn.script_name])
    route_path = Path.relative_to(conn.request_path, route_prefix)
    route_key = {normalize_route_path(route_path), conn.method}

    case List.keyfind(routes, route_key, 0) do
      {_, route_mfa} -> run(conn, route_mfa)
      _ -> conn
    end
  end

  @doc """
  Request authentication against a provider.

  specified dynamically in arguments. For example, you can specify in a
  controller:

      def request(conn, %{"provider_name" => provider_name} = _params) do
        provider_config = case provider_name do
          "github" ->
            { Ueberauth.Strategy.Github, [
              default_scope: "user",
              request_path:  provider_auth_path(conn, :request, provider_name),
              callback_path: provider_auth_path(conn, :callback, provider_name),
            ]}
        end
        conn
        |> Ueberauth.run_request(provider_name, provider_config)
      end
  """
  def run_request(conn, provider_name, {provider, provider_options}, options \\ []) do
    environment = get_env([:ueberauth, Keyword.get(options, :otp_app)])
    base_path = get_base_path(environment, options)

    to_options = build_strategy_options(base_path, {provider_name, {provider, provider_options}})
    run(conn, {provider, :run_request, to_options})
  end

  @doc """
  Request authentication against a provider.

      def callback(conn, %{"provider_name" => provider_name} = _params) do
        provider_config = case provider_name do
          "github" ->
            { Ueberauth.Strategy.Github, [
              default_scope: "user",
              request_path:  provider_auth_path(conn, :request, provider_name),
              callback_path: provider_auth_path(conn, :callback, provider_name),
            ]}
        end
        conn
        |> Ueberauth.run_callback(provider_name, provider_config)
        |> handle_callback(params, provider)
      end
  """
  def run_callback(conn, provider_name, {provider, provider_options}, options \\ []) do
    environment = get_env([:ueberauth, Keyword.get(options, :otp_app)])
    base_path = get_base_path(environment, options)

    to_options = build_strategy_options(base_path, {provider_name, {provider, provider_options}})
    run(conn, {provider, :run_callback, to_options})
  end

  defp run(conn, {module, :run_request, options}) do
    route_base_path = Enum.map_join(conn.script_name, &"/#{&1}")

    to_request_path = Path.join(["/", route_base_path, options.request_path])
    to_callback_path = Path.join(["/", route_base_path, options.callback_path])
    to_options = %{options | request_path: to_request_path, callback_path: to_callback_path}

    conn
    |> Plug.Conn.put_private(:ueberauth_request_options, to_options)
    |> Strategy.run_request(module)
  end

  defp run(conn, {module, :run_callback, options}) do
    route_base_path = Enum.map_join(conn.script_name, &"/#{&1}")

    to_request_path = Path.join(["/", route_base_path, options.request_path])
    to_callback_path = Path.join(["/", route_base_path, options.callback_path])
    to_options = %{options | request_path: to_request_path, callback_path: to_callback_path}

    conn
    |> Plug.Conn.put_private(:ueberauth_request_options, to_options)
    |> Strategy.run_callback(module)
  end

  defp build_routes(base_path, strategy) do
    #
    # Given a Strategy (passed as providers in environment) and a base_path,
    # build a list of routes that can be used later on in `call/2`.
    # The request route must be GET, but there can be as many callback routes
    # as there are callback methods.

    {_, {module, _}} = strategy
    strategy_options = build_strategy_options(base_path, strategy)

    request_mfa = {module, :run_request, strategy_options}
    request_route = {{strategy_options.request_path, "GET"}, request_mfa}

    callback_mfa = {module, :run_callback, strategy_options}

    callback_routes =
      for callback_method <- strategy_options.callback_methods do
        {{strategy_options.callback_path, callback_method}, callback_mfa}
      end

    [request_route | callback_routes]
  end

  defp get_env(value) do
    #
    # Return the environment via `Application.get_env/3` with nil app names
    # yielding empty list, so the results can be used with `Keyword.merge/2`.

    case value do
      nil -> []
      name when is_atom(name) -> Application.get_env(name, __MODULE__, [])
      list when is_list(list) -> list |> Enum.map(&get_env/1) |> Enum.reduce(&Keyword.merge/2)
    end
  end

  # Used by `call/2`. Prefixes the route_path with a "/" only if there is not one already.
  defp normalize_route_path("/" <> _rest = route_path), do: route_path
  defp normalize_route_path(route_path), do: "/" <> route_path

  defp get_providers(environment, options) do
    #
    # Used within `init/1`. Return a filtered Keyword list of providers,
    # taking into account whether the providers have been filtered via options.

    {:ok, providers} = Keyword.fetch(environment, :providers)

    case Keyword.get(options, :providers, :all) do
      :all -> providers
      provider_names -> Keyword.take(providers, provider_names)
    end
  end

  defp get_base_path(environment, options) do
    #
    # Used within `init/1`. Form the base_path from configuration
    # in environment and options.

    Keyword.get(options, :base_path, Keyword.get(environment, :base_path, "/auth"))
  end

  defp build_strategy_options(base_path, strategy) do
    #
    # Used within `build_routes/2`. Form an internal struct which holds
    # specifics that are expected by downstream Strategies when they are run.

    {name, {module, options}} = strategy

    %{
      strategy: module,
      strategy_name: name,
      request_scheme: Keyword.get(options, :request_scheme),
      request_path: get_request_path(base_path, strategy),
      request_port: Keyword.get(options, :request_port),
      callback_scheme: Keyword.get(options, :callback_scheme),
      callback_path: get_callback_path(base_path, strategy),
      callback_port: Keyword.get(options, :callback_port),
      callback_methods: get_callback_methods(options),
      options: options,
      callback_url: Keyword.get(options, :callback_url),
      callback_params: Keyword.get(options, :callback_params)
    }
  end

  defp get_request_path(base_path, strategy) do
    #
    # Used within `build_strategy_options/2`. Form the Request Path
    # from the base path and name of the Strategy as specified in Providers.

    {name, {_, options}} = strategy
    default_path = Path.join(["/", base_path, to_string(name)])
    String.replace_trailing(Keyword.get(options, :request_path, default_path), "/", "")
  end

  defp get_callback_path(base_path, strategy) do
    #
    # Used within `build_strategy_options/2`. Form the Callback Path
    # from the base path and name of the Strategy as specified in Providers.

    {name, {_, options}} = strategy
    default_path = Path.join(["/", base_path, to_string(name), "callback"])
    Keyword.get(options, :callback_path, default_path)
  end

  defp get_callback_methods(options) do
    #
    # Used within `build_strategy_options/2`. Form the list of Callback Methods
    # from options provided.

    options
    |> Keyword.get(:callback_methods, ["GET"])
    |> Enum.map(&String.upcase(to_string(&1)))
  end
end
