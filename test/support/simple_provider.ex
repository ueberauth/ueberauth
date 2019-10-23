defmodule Support.SimpleProvider do
  @moduledoc false

  use Ueberauth.Strategy

  def uid(%{body_params: %{"id" => id}} = _conn), do: id

  def credentials(%{body_params: %{"code" => code}} = conn) do
    prefix = options(conn)[:token_prefix]

    %Ueberauth.Auth.Credentials{
      token: "#{prefix}#{code}"
    }
  end

  def handle_request!(conn) do
    callback = options(conn)[:callback_path]

    conn
    |> redirect!("#{callback}?code=#{uid(conn)}")
  end

  def handle_callback!(conn) do
    conn
    |> Plug.Conn.assign(:ueberauth_auth, auth(conn))
  end
end
