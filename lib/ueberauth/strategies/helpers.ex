defmodule Ueberauth.Strategy.Helpers do
  import Plug.Conn
  alias Ueberauth.Strategy.Failure
  alias Ueberauth.Strategy.Failure.Error

  def strategy_name(conn), do: from_private(conn, :strategy_name)
  def strategy(conn), do: from_private(conn, :strategy)

  def request_path(conn), do: from_private(conn, :request_path_path)
  def callback_path(conn), do: from_private(conn, :callback_path)
  def failure_path(conn), do: from_private(conn, :failure_path)

  def request_url(conn, opts \\ []), do: full_url(conn, request_path(conn), opts)
  def callback_url(conn, opts \\ []), do: full_url(conn, callback_path(conn), opts)
  def failure_url(conn, opts \\ []), do: full_url(conn, failure_path(conn), opts)

  def allowed_request_methods(conn), do: from_private(conn, :request_methods)
  def allowed_request_method?(%{method: method} = conn) do
    conn
    |> allowed_request_methods
    |> Enum.member?(method)
  end

  def options(conn), do: from_private(conn, :options)

  def error(key, message), do: struct(Error, message_key: key, message: message)

  def set_errors!(conn, errors) do
    failure = struct(
      Failure,
      provider: strategy_name(conn),
      strategy: strategy(conn),
      errors: map_errors(errors)
    )

    Plug.assign(conn, :ueberauth_failure, failure)
  end

  def redirect!(conn, url) do
    html = Plug.HTML.html_escape(url)
    body = "<html><body>You are being <a href=\"#{html}\">redirected</a>.</body></html>"

    conn
    |> put_resp_header("location", url)
    |> send_resp(conn.status || 302, body)
    |> halt
  end

  defp from_private(conn, key) do
    opts = conn.private[:ueberauth_request_options]
    if opts, do: opts[key], else: nil
  end

  def full_url(conn, path, options \\ []) do
    %URI{
      host: conn.host,
      scheme: to_string(conn.scheme),
      port: conn.port,
      path: path,
      query: URI.encode_query(options)
    }
    |> to_string
  end

  defp map_errors(nil), do: []
  defp map_errors([]), do: []
  defp map_errors(errors), do: Enum.map(errors, &p_error/1)

  defp p_error(%Error{} = error), do: error
  defp p_error(%{} = error), do: struct(Error, error)
  defp p_error(error) when is_list(error), do: struct(Error, error)
end
