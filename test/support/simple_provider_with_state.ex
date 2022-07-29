defmodule Support.SimpleProviderWithState do
  @moduledoc false

  use Ueberauth.Strategy, ignores_csrf_attack: true

  def uid(%{params: %{"id" => id}} = _conn), do: id

  def credentials(%{params: %{"code" => code}} = conn) do
    prefix = options(conn)[:token_prefix]

    %Ueberauth.Auth.Credentials{
      token: "#{prefix}#{code}"
    }
  end

  def handle_request!(conn) do
    callback = options(conn)[:callback_path]

    encoded_params =
      [code: uid(conn)]
      |> with_state_param(conn)
      |> Enum.into(%{})
      |> URI.encode_query()

    conn
    |> redirect!("#{callback}?#{encoded_params}")
  end
end
