defmodule Ueberauth do
  require IEx
  @moduledoc """
  Ueberauth is an authentication framework that is heavily inspired by [Omniauth](https://github.com/intridea/omniauth)

  It is a two-phase authentication framework that provides a clear API - allowing for many strategies to be created for the system
  and shared in the community.

  Ueberauth consists of two phases, the request phase and the callback phase.

  The request phase is where you request information about the user. This could be an OAuth2 authorization url
  or a form for collecting username and password. Once the request phase is completed, the callback phase is begun
  and hands over to your code with all the required information to deal with the request.

  In your config file

      config :ueberauth, Ueberauth,
        providers: [
          facebook: { Ueberauth.Strategy.Facebook, [ opt1: "value", opts2: "value" ] },
          github: { Ueberauth.Strategy.Github, [ opt1: "value", opts2: "value" ] }
        ]

  This will setup two providers for you. The facebook and twitter. To use them, we need to integrate with the router

  In your router

      Ueberauth.plug "/auth"

  This will make your strategies avaialble at:

      /auth/facebook
      /auth/github

  Send your users to these urls to begin the authentication process. After this your app will receive a callback at

      /auth/facebook/callback
      /auth/github/callback

  Your code should implement code at these endpoints to handle the response.
  """

  alias Ueberauth.Strategy

  def auth(conn) do
    conn.assigns[:ueberauth_auth]
  end

  defmacro plug(base_path) do
    opts = Application.get_env(:ueberauth, Ueberauth)

    parts = Enum.map(opts[:providers], fn({ name, { strategy, options } }) ->

      request_path = Dict.get(options, :request_path, Path.join(["/", base_path, to_string(name)]))
      callback_path = Dict.get(options, :callback_path, Path.join(["/", base_path, to_string(name), "calback"]))
      failure_path = Dict.get(options, :failure_path) || Dict.get(opts, :failure_path) || Path.join(["/", base_path, to_string(name), "failure"])
      methods = Dict.get(options, :methods, ["GET"]) |> Enum.map(&(String.upcase(to_string(&1))))

      quoted_method_opts = quote do
        %{
          strategy_name: unquote(name),
          strategy: unquote(strategy),
          callback_path: unquote(callback_path),
          request_path: unquote(request_path),
          failure_path: unquote(failure_path),
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

    module_contents = quote do
      def init(opts \\ []), do: []
      def call(conn, _), do: run!(conn, conn.request_path)
      # unquote(parts)
      def run!(conn, _), do: conn # if we don't match anything just call through
    end

    mod = Module.create(Ueberauth.Strategies.Builder, module_contents, Macro.Env.location(__ENV__))

    quote do
      plug unquote(mod)
    end
  end
end
