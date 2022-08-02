defmodule Support.SimpleProviderWithState do
  @moduledoc false

  use Ueberauth.Strategy, ignores_csrf_attack: true

  def uid(%{params: %{"id" => id}} = _conn), do: id

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
