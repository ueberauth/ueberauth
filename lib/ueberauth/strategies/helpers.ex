defmodule Ueberauth.Strategy.Helpers do
  @moduledoc """
  Provides helper methods for use within your strategy.

  These helpers are provided as a convenience for accessing the options passed
  to the specific pipelined strategy, considering the pipelined options and
  falling back to defaults.
  """
  import Plug.Conn
  alias Ueberauth.Failure
  alias Ueberauth.Failure.Error

  @doc """
  Provides the name of the strategy or provider name.

  This is defined in your configuration as the provider name.
  """
  @spec strategy_name(Plug.Conn.t) :: String.t
  def strategy_name(conn), do: from_private(conn, :strategy_name)

  @doc """
  The strategy module that is being used for the request.
  """
  @spec strategy(Plug.Conn.t) :: module
  def strategy(conn), do: from_private(conn, :strategy)

  @doc """
  The request path for the strategy to hit.

  Requests to this path will trigger the `request_phase` of the strategy.
  """
  @spec request_path(Plug.Conn.t) :: String.t
  def request_path(conn), do: from_private(conn, :request_path)

  @doc """
  The callback path for the requests strategy.

  When a client hits this path, the callback phase will be triggered for the strategy.
  """
  @spec callback_path(Plug.Conn.t) :: String.t
  def callback_path(conn), do: from_private(conn, :callback_path)

  @doc """
  The full url for the request phase for the requests strategy.

  The URL is based on the current requests host and scheme. The options will be
  encoded as query params.
  """
  @spec request_url(Plug.Conn.t) :: String.t
  def request_url(conn, opts \\ []), do: full_url(conn, request_path(conn), opts)

  @doc """
  The full URL for the callback phase for the requests strategy.

  The URL is based on the current requests host and scheme. The options will be
  encoded as query params.
  """

  @spec callback_url(Plug.Conn.t) :: String.t
  def callback_url(conn, opts \\ []) do
    from_private(conn, :callback_url) ||
    full_url(conn, callback_path(conn),  callback_params(conn, opts))
  end

  @doc """
  Build params for callback

  This method will filter conn.params with whitelisted params from :callback_params settings
  """
  @spec callback_params(Plug.Conn.t) :: list(String.t)
  def callback_params(conn, opts \\ []) do
    callback_params = from_private(conn, :callback_params) || []
    callback_params = callback_params
      |> Enum.map(fn(k) -> {String.to_atom(k), conn.params[k]} end)
      |> Enum.filter(fn {_, v} -> v != nil end)
      |> Enum.filter(fn {k, _} -> k != "provider" end)
    Keyword.merge(opts, callback_params)
  end

  @doc """
  The configured allowed callback http methods.

  This will use any supplied options from the configuration, but fallback to the
  default options
  """
  @spec allowed_callback_methods(Plug.Conn.t) :: list(String.t)
  def allowed_callback_methods(conn), do: from_private(conn, :callback_methods)

  @doc """
  Is the current request http method one of the allowed callback methods?
  """
  @spec allowed_callback_method?(Plug.Conn.t) :: boolean
  def allowed_callback_method?(%{method: method} = conn) do
    callback_method =
      method
      |> to_string
      |> String.upcase

    conn
    |> allowed_callback_methods
    |> Enum.member?(callback_method)
  end

  @doc """
  The full list of options passed to the strategy in the configuration.
  """
  @spec options(Plug.Conn.t) :: Keyword.t
  def options(conn), do: from_private(conn, :options)

  @doc """
  A helper for constructing error entries on failure.

  The `message_key` is intended for use by machines for translations etc.
  The message is a human readable error message.

  #### Example

      error("something_bad", "Something really bad happened")
  """
  @spec error(String.t, String.t) :: Error.t
  def error(key, message), do: struct(Error, message_key: key, message: message)

  @doc """
  Sets a failure onto the connection containing a List of errors.

  During your callback phase, this should be called to 'fail' the authentication
  request and include a collection of errors outlining what the problem is.

  Note this changes the conn object and should be part of your returned
  connection of the `callback_phase!`.
  """
  @spec error(Plug.Conn.t, list(Error.t)) :: Plug.Conn.t
  def set_errors!(conn, errors) do
    failure = struct(
      Failure,
      provider: strategy_name(conn),
      strategy: strategy(conn),
      errors: map_errors(errors)
    )

    Plug.Conn.assign(conn, :ueberauth_failure, failure)
  end

  @doc """
  Redirects to a url and halts the plug pipeline.
  """
  @spec redirect!(Plug.Conn.t, String.t) :: Plug.Conn.t
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

  defp full_url(conn, path, opts) do
    scheme = conn
    |> forwarded_proto
    |> coalesce(conn.scheme)
    |> normalize_scheme

    %URI{
      host: conn.host,
      port: normalize_port(scheme, conn.port),
      path: path,
      query: encode_query(opts),
      scheme: to_string(scheme),
    }
    |> to_string
  end

  defp forwarded_proto(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-proto")
    |> List.first
  end

  defp normalize_scheme("https"), do: :https
  defp normalize_scheme("http"), do: :http
  defp normalize_scheme(scheme), do: scheme

  defp coalesce(nil, second), do: second
  defp coalesce(first, _), do: first

  defp normalize_port(:https, 80), do: 443
  defp normalize_port(_, port), do: port

  defp encode_query([]), do: nil
  defp encode_query(opts), do: URI.encode_query(opts)

  defp map_errors(nil), do: []
  defp map_errors([]), do: []
  defp map_errors(%Error{} = error), do: [error]
  defp map_errors(errors), do: Enum.map(errors, &p_error/1)

  defp p_error(%Error{} = error), do: error
  defp p_error(%{} = error), do: struct(Error, error)
  defp p_error(error) when is_list(error), do: struct(Error, error)
end
