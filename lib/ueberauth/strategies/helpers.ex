defmodule Ueberauth.Strategy.Helpers do
  import Plug.Conn

  def strategy_name(conn), do: from_private(conn, :strategy_name)
  def strategy(conn), do: from_private(conn, :strategy)

  def request_path(conn), do: from_private(conn, :request_path_path)
  def callback_path(conn), do: from_private(conn, :callback_path)
  def failure_path(conn), do: from_private(conn, :failure_path)

  def request_url(conn), do: full_url(conn, request_path(conn))
  def callback_url(conn), do: full_url(conn, callback_path(conn))
  def failure_url(conn), do: full_url(conn, failure_path(conn))

  def allowed_request_methods(conn), do: from_private(conn, :request_methods)
  def allowed_request_method?(%{method: method} = conn) do
    conn
    |> allowed_request_methods
    |> Enum.member?(method)
  end

  def options(conn), do: from_private(conn, :options)

  def redirect!(conn, url) do
    html = Plug.HTML.html_escape(url)
    body = "<html><body>You are being <a href=\"#{html}\">redirected</a>.</body></html>"

    conn
    |> put_resp_header("location", url)
    |> send_resp(conn.status || 302, body)
  end

  defp from_private(conn, key) do
    opts = conn.private[:ueberauth_request_options]
    if opts, do: opts[key], else: nil
  end

  def full_url(conn, path, options \\ []) do
    %URI{
      host: conn.host,
      scheme: conn.scheme,
      port: conn.port,
      path: path,
      query: URI.encode_query(options)
    }
    |> to_string
  end
end
