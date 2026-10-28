defmodule Ueberauth.Strategy.Test do
  @moduledoc """
  A strategy for testing your application's authentication flow without
  talking to a real provider.

  Swap it in for your real strategies in `config/test.exs`, keeping the
  provider names so your routes stay the same:

      config :ueberauth, Ueberauth,
        providers: [
          github: {Ueberauth.Strategy.Test, []},
          google: {Ueberauth.Strategy.Test, []}
        ]

  The request phase redirects straight to the callback URL, as if the user
  approved the login at the provider. The callback phase assigns an
  `Ueberauth.Auth` built from the data you give it, with `provider` set to the
  configured provider name (e.g. `:github`).

  ## Setting the authenticated user

  Use `put_auth/2` on the conn before calling the callback route. The data is
  stored on the conn, so it is safe in `async: true` tests:

      test "signs in a new user", %{conn: conn} do
        conn =
          conn
          |> Ueberauth.Strategy.Test.put_auth(
            uid: "12345",
            info: %{email: "jane@example.com", name: "Jane Doe"},
            credentials: %{token: "token"}
          )
          |> get(~p"/auth/github/callback")

        assert redirected_to(conn) == ~p"/dashboard"
      end

  Defaults for every request can be set as provider options. Values given to
  `put_auth/2` take precedence:

      github: {Ueberauth.Strategy.Test, [uid: "12345", info: %{email: "jane@example.com"}]}

  When neither is set, the callback uses `"test-uid"` as the uid
  and empty `info`, `credentials` and `extra`.

  ## Simulating a failure

  Use `put_failure/3` to make the callback assign an `Ueberauth.Failure`
  instead:

      conn =
        conn
        |> Ueberauth.Strategy.Test.put_failure("access_denied", "The user denied access")
        |> get(~p"/auth/github/callback")

  ## CSRF protection

  This strategy sets `ignores_csrf_attack: true` so callback routes can be
  called directly, without a prior request phase. The state parameter is not
  checked.
  """

  use Ueberauth.Strategy, ignores_csrf_attack: true

  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra
  alias Ueberauth.Auth.Info

  @private_key :ueberauth_test
  @default_uid "test-uid"

  @typedoc """
  Data used to build the `Ueberauth.Auth` in the callback phase.

  `info`, `credentials` and `extra` may be given as structs or as maps (or
  keyword lists) of their fields.
  """
  @type auth_data :: [
          uid: String.t(),
          info: Info.t() | map() | keyword(),
          credentials: Credentials.t() | map() | keyword(),
          extra: Extra.t() | map() | keyword()
        ]

  @doc """
  Sets the data the callback phase uses to build `Ueberauth.Auth`.

  Accepts `:uid`, `:info`, `:credentials` and `:extra`. Keys that are not
  given fall back to the provider options, then to the defaults.
  """
  @spec put_auth(Plug.Conn.t(), auth_data() | map()) :: Plug.Conn.t()
  def put_auth(conn, data) do
    put_private(conn, @private_key, {:auth, Map.new(data)})
  end

  @doc """
  Makes the callback phase fail with the given error.
  """
  @spec put_failure(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def put_failure(conn, message_key \\ "access_denied", message \\ "Access denied") do
    put_private(conn, @private_key, {:failure, message_key, message})
  end

  @impl Ueberauth.Strategy
  def handle_request!(conn) do
    redirect!(conn, callback_url(conn))
  end

  @impl Ueberauth.Strategy
  def handle_callback!(conn) do
    case conn.private[@private_key] do
      {:failure, message_key, message} -> set_errors!(conn, [error(message_key, message)])
      _ -> conn
    end
  end

  @impl Ueberauth.Strategy
  def uid(conn), do: fetch(conn, :uid) || @default_uid

  @impl Ueberauth.Strategy
  def info(conn), do: to_struct(Info, fetch(conn, :info))

  @impl Ueberauth.Strategy
  def credentials(conn), do: to_struct(Credentials, fetch(conn, :credentials))

  @impl Ueberauth.Strategy
  def extra(conn), do: to_struct(Extra, fetch(conn, :extra))

  defp fetch(conn, key) do
    case conn.private[@private_key] do
      {:auth, %{^key => value}} -> value
      _ -> Keyword.get(options(conn) || [], key)
    end
  end

  defp to_struct(module, nil), do: struct!(module)
  defp to_struct(module, %module{} = value), do: value
  defp to_struct(module, fields), do: struct!(module, fields)
end
