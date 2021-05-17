defmodule Support.ProviderWithCsrfAttackEnabled do
  @moduledoc false
  use Ueberauth.Strategy
  use Support.Mixins

  def handle_callback!(%Plug.Conn{params: %{"code" => code, "next_url" => url}} = conn) do
    uri = URI.parse(url)
    uri_query = uri.query || ""
    query = URI.decode_query(uri_query) |> Map.put("code", code) |> URI.encode_query()
    uri = %{uri | query: query} |> URI.to_string()
    redirect!(conn, uri)
  end

  def handle_callback!(%Plug.Conn{params: %{"code" => _code}} = conn) do
    conn
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

end
