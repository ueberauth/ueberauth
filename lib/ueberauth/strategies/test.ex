defmodule Ueberauth.Strategy.Test do
  @moduledoc """
  This strategy allows testing your callback controller code.

  The of this strategy is to be placed in configuration in test.exs file:
  ```
  config :ueberauth, Ueberauth,
    providers: [{:test, {Ueberauth.Strategy.Test, []}}]
  ```

  Then in your test you need to set what user data should be set.
  Please refer to `Ueberauth.Auth.Info`, `Ueberauth.Auth.Credentials` and `Ueberauth.Auth.Extra`.
  ```
  test "GET /auth/google/callback", %{conn: conn} do
    user = %Strategy.Test.UserData{
      uid: UUID.generate()
    }
    conn = Strategy.Test.put_testing_user(conn, user)
    conn = get(conn, "/auth/google/callback")
    assert conn.status == 302
    assert get_flash(conn) == %{"info" => "Successfully authenticated."}
  end
  ```
  """
  use Ueberauth.Strategy,
    uid_field: :sub,
    default_scope: "email",
    hd: nil,
    ignores_csrf_attack: true

  defmodule UserData do
    @moduledoc false

    alias Ueberauth.Auth.Credentials
    alias Ueberauth.Auth.Extra
    alias Ueberauth.Auth.Info
    alias Ueberauth.Failure.Error

    @enforce_keys [:uid]
    defstruct @enforce_keys ++
                [extra: %Extra{}, info: %Info{}, credentials: %Credentials{}, errors: []]

    @type t :: %__MODULE__{
            uid: binary(),
            extra: Extra.t(),
            info: Info.t(),
            credentials: Credentials.t(),
            errors: [Error.t()]
          }
  end

  alias Ueberauth.Strategy.Helpers

  @testing_user :ueberauth_testing_user
  @testing_redirect :ueberauth_testing_redirect
  # Default to default testing phoenix endpoint
  @default_url "http://localhost:4002"

  @impl Ueberauth.Strategy
  def handle_request!(conn) do
    url = conn.private[@testing_redirect] || @default_url
    redirect!(conn, url)
  end

  @impl Ueberauth.Strategy
  def handle_cleanup!(conn) do
    conn
    |> put_private(@testing_user, nil)
    |> put_private(@testing_redirect, nil)
  end

  @impl Ueberauth.Strategy
  def handle_callback!(conn) do
    errors = fetch_suplement(conn, :errors)

    case errors do
      [] -> conn
      errors -> Helpers.set_errors!(conn, errors)
    end
  end

  @impl Ueberauth.Strategy
  def credentials(conn) do
    fetch_suplement(conn, :credentials)
  end

  @impl Ueberauth.Strategy
  def extra(conn) do
    fetch_suplement(conn, :extra)
  end

  @impl Ueberauth.Strategy
  def uid(conn) do
    fetch_suplement(conn, :uid)
  end

  @impl Ueberauth.Strategy
  def info(conn) do
    fetch_suplement(conn, :info)
  end

  @spec put_testing_user(Plug.Conn.t(), UserData.t()) :: Plug.Conn.t()
  def put_testing_user(conn, user) do
    put_private(conn, @testing_user, user)
  end

  @spec put_testing_url(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_testing_url(conn, url) do
    put_private(conn, @testing_redirect, url)
  end

  defp fetch_suplement(conn, suplement) do
    user = conn.private[@testing_user] || raise "Testing user was read but not set"
    Map.fetch!(user, suplement)
  end
end
