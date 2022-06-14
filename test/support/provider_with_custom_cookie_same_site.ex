defmodule Support.ProviderWithCustomCookieSameSite do
  @moduledoc false
  use Ueberauth.Strategy,
  state_param_cookie_same_site: "None"
  use Support.Mixins

  def handle_callback!(%Plug.Conn{params: %{"code" => code, "next_url" => url}} = conn) do
    uri = URI.parse(url)
    uri_query = uri.query || ""
    query = uri_query |> URI.decode_query() |> Map.put("code", code) |> URI.encode_query()
    uri = URI.to_string(%{uri | query: query})
    redirect!(conn, uri)
  end

  def handle_callback!(%Plug.Conn{params: %{"code" => _code}} = conn) do
    conn
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end
end
