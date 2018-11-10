defmodule Ueberauth.Plug do
  @moduledoc """

  Provides a convenient way to configure and run multiple strategies or providers
  in you plug pipeline. Often used with a controller in Phoneix.

  This plug is configured in your controller and acts as a decorator.

  It operates with the concept of phases. There are two.

  1. Challenge phase
  2. Callback phase

  ## Challenge phase
  The challenge phase follows normal plug pipeline behaviour.

  When a request comes into your controller with `/some/path/:provider`

  Where `:provider` is a configured provider, This plug will request the redirect url from
  from the strategy. It will then redirect to that url.

  The call to `challenge` will be:

  `%{callback_url: url, conn: conn}`

  Your strategy must be able to deal with this.

  The result of redirecting to that URL should eventually be a callback to:
  `/some/path/:provider/callback`. The callback suffix is configurable.

  ## Callback phase

  When a request comes into the controller that matches the path: `/some/path/:provider/callback`
  the plug will use the `authenticate` function of your strategy passing the following:

  `strategy.authenticate(provider_name, %{query: query_params, body: body_params, conn: conn}, strategy_options)`

  Your strategy must implement a function that handles these specific parameters although you should also provide a more direct version.

  The result of the call to authenticate will either be:

  `{:ok, %Ueberauth.Auth{}}` or `{:error, %Ueberauth.Failure{}}`

  The callback phase is essentially a decorator and does not usually redirect or
  halt the request. Its result is that one of two cases will end up in your
  connections assigns when it reaches your controller.

  * On Failure - An `Ueberauth.Failure` struct is available at `:ueberauth_failure`
  * On Success - An `Ueberauth.Auth` struct is available at `:ueberauth_auth`

  ### An Example

  When using this plug, you must pass in your configuration.

  This can be done in one of two ways.

  1. Literal config Keyword list
  2. Function (0 or 1 arity receiving Plug.Conn) that returns the config Keyword list

    defmodule MyApp.MyController do
      use MyApp, :controller

      # in-place configuration
      plug Ueberauth.Plug, providers: [
        slack: {Ueberauth.Slack.Strategy, [xxxx]},
        github: {Ueberauth.Github.Strategy, [xxxx]},
        facebook: {Ueberauth.Facebook.Strategy, [xxxx]}
      ]

      # OR

      # configuration from a function
      plug Ueberauth.Plug, &ueberauth_config/1

      # OR to use configuration coming from mix
      plug Ueberauth.Plug, Uebeauth.Plug.lookup_config_func([:ueberauth, Ueberauth])


      # should never be called but should be routed to as `/path/for/auth/:provider`
      def request(conn, _) do
        raise "should not be called"
      end

      # routed as `/path/for/auth/:provider/callback`
      def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _) do
        handle_auth_successful(conn, auth) # write the handle_successful_auth function
      end

      def callback(%{assigns: %{ueberauth_failure: failz}} = conn, _) do
        handle_auth_failure(conn, failz) # write then handle_auth_failure
      end
    end
  """

  @behaviour Plug

  @type provider :: {atom, {module, Keyword.t()}}
  @type config :: [
          providers: [provider],
          # default /callback
          callback_suffix: String.t()
        ]

  @type config_func ::
          (Plug.Conn.t() -> config)
          | (() -> config)
          | mfa

  require Logger

  alias Ueberauth.{Auth, Failure, Strategy.Helpers}

  @doc """
  Provides a lookup from mix config  and returns a config function

  # Example

      Ueberauth.Plug.lookup_config_func([:ueberauth, Ueberauth])
  """
  @spec lookup_config_func([atom]) :: config_func
  def lookup_config_func(args) do
    fn -> apply(Application, :get_env, args) end
  end

  @spec init(config | config_func) :: config
  @impl true
  def init(config) when is_list(config) do
    validate_config!(config)
    config
  end

  def init(config) when is_function(config), do: config

  def init({_m, _f, _a} = config), do: config

  @impl true
  def call(conn, config) when is_function(config) do
    config =
      case Function.info(config)[:arity] do
        0 -> call(conn, config.())
        1 -> call(conn, config.(conn))
      end

    validate_config!(config)
    call(conn, config)
  end

  def call(conn, {m, f, a}) do
    config = apply(m, f, [conn | a])
    validate_config!(config)
    call(conn, config)
  end

  @impl true
  def call(conn, config) when is_list(config) do
    case provider_and_phase_for_request(conn, config) do
      {_, nil} -> conn
      {:callback, provider} -> handle_callback_phase(conn, provider, config)
      {_, provider} -> handle_challenge_phase(conn, provider, config)
    end
  end

  @impl true
  def call(_, _), do: raise_invalid_config!()

  defp handle_challenge_phase(conn, {name, {strategy, opts}}, config) do
    Logger.debug(fn -> "[#{__MODULE__}] Handling challenge phase #{name}" end)
    suffix = callback_suffix(config)

    request_uri = Helpers.request_uri(conn)
    callback_uri = %{request_uri | path: Path.join(request_uri.path, suffix), query: nil}

    challenge = strategy.challenge(%{callback_url: to_string(callback_uri), conn: conn}, opts)

    case challenge do
      {:ok, %URI{} = url} ->
        Helpers.redirect!(conn, to_string(url))

      {:error, reason} ->
        # what to do here?
        Logger.error("[#{__MODULE__}] Error fetching redirect url: #{inspect(reason)}")

        conn
        |> Plug.Conn.send_resp(500, "Error")
        |> Plug.Conn.halt()
    end
  end

  defp handle_callback_phase(conn, {name, {strategy, opts}}, config) do
    Logger.debug(fn -> "[#{__MODULE__}] Handling callback phase #{name}" end)
    {conn, params} = params_from_conn(conn, opts, config)

    case strategy.authenticate(name, params, opts) do
      {:ok, auth} ->
        IO.puts("Valid auth response #{inspect(auth)}")

        if Auth.valid?(auth) do
          Plug.Conn.assign(conn, :ueberauth_auth, auth)
        else
          Logger.error("[#{__MODULE__} Invalid auth struct #{inspect(auth)}")

          failure = %Failure{
            provider: name,
            strategy: strategy,
            errors: [
              %Failure.Error{
                message_key: "invalid_auth_struct",
                message: "Invalid auth struct"
              }
            ]
          }

          Plug.Conn.assign(conn, :ueberauth_failure, failure)
        end

      {:error, failure} ->
        IO.puts("Auth failure #{inspect(failure)}")
        Plug.Conn.assign(conn, :ueberauth_failure, failure)
    end
  end

  defp validate_config!(nil), do: raise_invalid_config!()
  defp validate_config!([]), do: raise_invalid_config!()

  defp validate_config!(config) do
    case Keyword.get(config, :providers) do
      [] -> raise_invalid_config!()
      providers when is_list(providers) -> providers
      _ -> raise_invalid_config!()
    end
  end

  defp raise_invalid_config! do
    raise "invalid configuration for Ueberauth.Plug"
  end

  defp provider_and_phase_for_request(conn, config) do
    suffix = callback_suffix(config)
    providers = Keyword.get(config, :providers)

    provider_keys =
      providers
      |> Keyword.keys()
      |> Enum.join("|")

    reg = Regex.compile!("\\b(#{provider_keys})(/#{suffix}|/)?$")

    case Regex.run(reg, conn.request_path) do
      # not a match
      nil ->
        {nil, nil}

      # request
      [_, name_as_string] ->
        provider_name = String.to_existing_atom(name_as_string)
        {:request, {provider_name, Keyword.get(providers, provider_name)}}

      # callback
      [_, name_as_string, _] ->
        provider_name = String.to_existing_atom(name_as_string)
        {:callback, {provider_name, Keyword.get(providers, provider_name)}}
    end
  end

  defp callback_suffix(config) do
    config
    |> Keyword.get(:callback_suffix, "callback")
    |> String.trim_leading("/")
  end

  defp params_from_conn(conn, _opts, _config) do
    {conn, %{}}
    |> apply_query_params()
    |> apply_body_params()
    |> apply_conn_to_params()
  end

  defp apply_query_params({conn, params}) do
    case conn.query_params do
      %Plug.Conn.Unfetched{} ->
        conn = Plug.Conn.fetch_query_params(conn)
        apply_query_params({conn, params})

      query_params ->
        {conn, Map.put(params, :query, query_params)}
    end
  end

  defp apply_body_params({conn, params}) do
    if conn.method != "GET" do
      {conn, Map.put(params, :body, conn.body_params)}
    else
      {conn, params}
    end
  end

  defp apply_conn_to_params({conn, params}) do
    {conn, Map.put(params, :conn, conn)}
  end
end
