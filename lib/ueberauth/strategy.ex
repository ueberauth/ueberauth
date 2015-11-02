defmodule Ueberauth.Strategy do
  alias Ueberauth.Auth
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Extra

  @callback request_phase(Plug.Conn.t) :: Plug.Conn.t
  @callback callback_phase(Plug.Conn.t) :: Plug.Conn.t

  @callback uid(Plug.Conn.t) :: binary
  @callback info(Plug.Conn.t) :: Info.t
  @callback extra(Plug.Conn.t) :: Extra.t
  @callback credentials(Plug.Conn.t) :: Credentials.t

  defmacro __using__(opts \\ []) do
    quote do
      @behaviour Ueberauth.Strategy
      import Ueberauth.Strategy.Helpers

      def default_options, do: unquote(opts)

      def info(conn), do: %Info{}
      def extra(conn), do: %Extra{}
      def credentials(conn), do: %Credentials{}

      def request_phase(conn), do: conn
      def callback_phase(conn), do: conn

      def auth(conn) do
        struct(
          Auth,
          provider: strategy_name(conn),
          strategy: strategy(conn),
          uid: uid(conn),
          info: info(conn),
          extra: extra(conn),
          credentials: credentials(conn)
        )
      end

      defoverridable [info: 1, extra: 1, credentials: 1, request_phase: 1, callback_phase: 1]
    end
  end

  def run_request_phase(conn, strategy, opts) do
    apply(strategy, :request_phase, [conn])
  end

  def run_callback_phase(conn, strategy) do
    new_conn = apply(strategy, :callback_phase, [conn])
    if new_conn.halted do
      new_conn
    else
      auth = apply(strategy, :auth, [new_conn])
      Plug.Conn.assign(new_conn, :ueberauth_auth, auth)
    end
  end
end
