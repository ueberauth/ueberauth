defmodule Ueberauth.Strategy do
  @moduledoc """
  The Strategy is the work-horse of the system.

  Strategies are implemented outside this library to meet your needs, the
  strategy provides a consistent API and behaviour.

  Each strategy operates through two phases.

  1. `request phase`
  2. `callback phase`

  These phases can be understood with the following psuedocode.

  ### Request Phase

      request (for the request phase - default /auth/:provider)
      |> relevant_strategy.handle_request!(conn)
      |> continue with request plug pipeline

  The request phase follows normal plug pipeline behaviour. The request will not
  continue if the strategy halted the connection.

  ### Callback Phase

      request (for a callback phase - default /auth/:provider/callback)
      |> relevant_strategy.handle_auth!(conn)
      if connection does not have ueberauth failure
        |> set ueberauth auth with relevant_strategy.auth
      |> cleanup from the strategy with relevant_strategy.handle_cleanup!
      |> continue with plug pipeline

  The callback phase is essentially a decorator and does not usually redirect or
  halt the request. Its result is that one of two cases will end up in your
  connections assigns when it reaches your controller.

  * On Failure - An `Ueberauth.Failure` struct is available at `:ueberauth_failure`
  * On Success - An `Ueberauth.Auth` struct is available at `:ueberauth_auth`

  ### An example

  The simplest example is an email/password strategy. This does not intercept
  the request and just decorates it with the `Ueberauth.Auth` struct. (it is
  always successful)

      defmodule Ueberauth.Strategies.Identity do
        use Ueberauth.Strategy

        alias Ueberauth.Auth.Credentials
        alias Ueberauth.Auth.Extra

        def uid(conn), do: conn.params["email"]

        def extra(conn), do: struct(Extra, raw_info: conn.params)

        def credentials(conn) do
          %Credentials{
            other: %{
              password: conn.params["password"],
              password_confirmation: conn.params["password_confirmation"]
            }
          }
        end
      end

  After the strategy has run through the `handle_callback!` function, since
  there are no errors added, Ueberauth will add the constructed auth struct to
  the connection.

  The Auth struct is constructed like:

      def auth(conn) do
        %Auth{
          provider: strategy_name(conn),
          strategy: strategy(conn),
          uid: uid(conn),
          info: info(conn),
          extra: extra(conn),
          credentials: credentials(conn)
        }
      end

  Each component of the struct is a separate function and receives the connection
  object. From this Ueberauth will construct and assign the struct for processing
  in your own controller.

  ### Redirecting during the request phase

  Many strategies may require a redirect (looking at you OAuth). To do this,
  implement the `handle_request!` function.

      def handle_request!(conn)
        callback_url = callback_url(conn)
        redirect!(conn, callback_url)
      end

  ### Callback phase

  The callback phase may not do anything other than instruct the strategy where
  to get the information to construct the auth struct. In that case define the
  functions for the components of the struct and fetch the information from the
  connection struct.

  In the case where you do need to take some other step, the `handle_callback!`
  function is where its at.

      def handle_callback!(conn) do
        conn
        |> call_external_service_and_assign_result_to_private
      end

      def uid(conn) do
        fetch_from_my_private_area(conn, :username)
      end

      def handle_cleanup!(conn) do
        remove_my_private_area(conn)
      end

  This provides a simplistic psuedocode look at what a callback + cleanup phase
  might look like. By setting the result of your call to the external service in
  the connections private assigns, you can use that to construct the auth struct
  in the auth component functions. Of course, as a good citizen you also cleanup
  the connection before the request continues.

  ### Cleanup phase

  The cleanup phase is provided for you to be a good citizen and clean up after
  your strategy. During the callback phase, you may need to temporarily store
  information in the private section of the conn struct. Once this is done,
  the cleanup phase exists to cleanup that temporary storage after the strategy
  has everything it needs.

  Implement the `handle_cleanup!` function and return the cleaned conn struct.

  ### Adding errors during callback

  You have two options when you're in the callback phase. Either you can let the
  connection go through and Ueberauth will construct the auth hash for you, or
  you can add errors.

  You should add errors before you leave your `handle_callback!` function.

      def handle_callback!(conn) do
        errors = []
        if (something_bad), do: errors = [error("error_key", "Some message") | errors]

        if (length(errors) > 0) do
          set_errors!(errors)
        else
          conn
        end
      end

  Once you've set errors, Ueberauth will not set the auth struct in the connections
  assigns at `:ueberauth_auth`, instead it will set a `Ueberauth.Failure` struct at
  `:ueberauth_failure` with the information provided detailing the failure.
  """

  alias Ueberauth.Auth
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Extra

  @doc """
  The request phase implementation for your strategy.

  Setup, redirect or otherwise in here. This is an information gathering phase
  and should provide the end user with a way to provide the information
  required for your application to authenticate them.
  """
  @callback handle_request!(Plug.Conn.t) :: Plug.Conn.t

  @doc """
  The callback phase implementation for your strategy.

  In this function you should make any external calls you need, check for
  errors etc. The result of this phase is that either a failure
  (`Ueberauth.Failure`) will be assigned to the connections assigns at
  `ueberauth_failure` or an `Ueberauth.Auth` struct will be constrcted and
  added to the assigns at `:ueberauth_auth`.
  """
  @callback handle_callback!(Plug.Conn.t) :: Plug.Conn.t

  @doc """
  The cleanup phase implementation for your strategy.

  The cleanup phase runs after the callback phase and is present to provide a
  mechanism to cleanup any temporary data your strategy may have placed in the
  connection.
  """
  @callback handle_cleanup!(Plug.Conn.t) :: Plug.Conn.t

  @doc """
  Provides the uid for the user.

  This is one of the component functions that is used to construct the auth
  struct. What you return here will be in the auth struct at the `uid` key.
  """
  @callback uid(Plug.Conn.t) :: binary | nil

  @doc """
  Provides the info for the user.

  This is one of the component functions that is used to construct the auth
  struct. What you return here will be in the auth struct at the `info` key.
  """
  @callback info(Plug.Conn.t) :: Info.t

  @doc """
  Provides the extra params for the user.

  This is one of the component functions that is used to construct the auth
  struct. What you return here will be in the auth struct at the `extra` key.

  You would include any additional information within extra that does not fit
  in either `info` or `credentials`
  """
  @callback extra(Plug.Conn.t) :: Extra.t

  @doc """
  Provides the credentials for the user.

  This is one of the component functions that is used to construct the auth
  struct. What you return here will be in the auth struct at the `credentials`
  key.
  """
  @callback credentials(Plug.Conn.t) :: Credentials.t

  @doc """
  When defining your own strategy you should use Ueberauth.Strategy.

  This provides default callbacks for all required callbacks to meet the
  Ueberauth.Strategy behaviour and imports some helper functions found in
  `Ueberauth.Strategy.Helpers`

  ### Imports

  * Ueberauth.Stratgey.Helpers
  * Plug.Conn

  ## Default Options

  When using the strategy you can pass a keyword list for default options:

      defmodule MyStrategy do
        use Ueberauth.Strategy, some: "options"

        # …
      end

      MyStrategy.default_options # [ some: "options" ]

  These options are made available to your strategy at `YourStrategy.default_options`.
  On a per usage level, other options can also be passed to the strategy to provide
  customization.
  """
  defmacro __using__(opts \\ []) do
    quote do
      @behaviour Ueberauth.Strategy
      import Ueberauth.Strategy.Helpers
      import Plug.Conn

      def default_options, do: unquote(opts)

      def uid(conn), do: nil

      def info(conn), do: %Info{}
      def extra(conn), do: %Extra{}
      def credentials(conn), do: %Credentials{}

      def handle_request!(conn), do: conn
      def handle_callback!(conn), do: conn
      def handle_cleanup!(conn), do: conn

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

      defoverridable [uid: 1, info: 1, extra: 1, credentials: 1, handle_request!: 1, handle_callback!: 1, handle_cleanup!: 1]
    end
  end

  @doc false
  def run_request(conn, strategy) do
    apply(strategy, :handle_request!, [conn])
  end

  @doc false
  def run_callback(conn, strategy) do
    handled_conn =
      strategy
      |> apply(:handle_callback!, [conn])
      |> handle_callback_result(strategy)
      |> handle_callback_result(strategy)
    apply(strategy, :handle_cleanup!, [handled_conn])
  end

  defp handle_callback_result(%{halted: true} = conn, _), do: conn
  defp handle_callback_result(%{assigns: %{ueberauth_failure: _}} = conn, _), do: conn
  defp handle_callback_result(%{assigns: %{ueberauth_auth: %{}}} = conn, _), do: conn
  defp handle_callback_result(conn, strategy) do
    auth = apply(strategy, :auth, [conn])
    Plug.Conn.assign(conn, :ueberauth_auth, auth)
  end
end
