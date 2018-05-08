defmodule Ueberauth.Strategy.Base do
  @moduledoc false
  import Ueberauth.Strategy.Helpers

  def redirect_to_callback(conn) do
    redirect!(conn, callback_url(conn))
  end

  def assign_auth(conn, auth) do
    Plug.Conn.assign(conn, :ueberauth_auth, auth)
  end
end
