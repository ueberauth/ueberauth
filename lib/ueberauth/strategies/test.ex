defmodule Ueberauth.Strategy.Test do
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

    @enforce_keys [ :uid]
    defstruct @enforce_keys ++ [extra: %Extra{}, info: %Info{}, credentials: %Credentials{}]
  end

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
    conn
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

  def put_testing_user(conn, user) do
    put_private(conn, @testing_user, user)
  end

  defp fetch_suplement(conn, suplement) do
    user = conn.private[@testing_user] || raise "Testing user was read but not set"
    Map.fetch!(user, suplement)
  end
end
