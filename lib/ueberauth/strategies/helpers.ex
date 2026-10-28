defmodule Ueberauth.Strategy.Helpers do
  @moduledoc """
  Provides helper methods for use within your strategy.

  These helpers are provided as a convenience for accessing the options passed
  to the specific pipelined strategy, considering the pipelined options and
  falling back to defaults.
  """
  import Plug.Conn, except: [request_url: 1]
  require Logger
  alias Ueberauth.Failure
  alias Ueberauth.Failure.Error

  @doc """
  Provides the name of the strategy or provider name.

  This is defined in your configuration as the provider name.
  """
  @spec strategy_name(Plug.Conn.t()) :: String.t() | nil
  def strategy_name(conn), do: from_private(conn, :strategy_name)

  @doc """
  The strategy module that is being used for the request.
  """
  @spec strategy(Plug.Conn.t()) :: module
  def strategy(conn), do: from_private(conn, :strategy)

  @doc """
  The request path for the strategy to hit.

  Requests to this path will trigger the `request_phase` of the strategy.
  """
  @spec request_path(Plug.Conn.t()) :: String.t() | nil
  def request_path(conn), do: from_private(conn, :request_path)

  @doc """
  The callback path for the requests strategy.

  When a client hits this path, the callback phase will be triggered for the strategy.
  """
  @spec callback_path(Plug.Conn.t()) :: String.t() | nil
  def callback_path(conn), do: from_private(conn, :callback_path)

  @doc """
  The full url for the request phase for the requests strategy.

  The URL is based on the current requests host and scheme.
  """
  @spec request_url(Plug.Conn.t()) :: String.t()
  def request_url(conn, query_params \\ []) do
    opts = [
      scheme: from_private(conn, :request_scheme),
      port: from_private(conn, :request_port),
      path: request_path(conn),
      query_params: query_params
    ]

    full_url(conn, opts)
  end

  @doc """
  The full URL for the callback phase for the requests strategy.

  The URL is based on the current requests host and scheme.
  """

  @spec callback_url(Plug.Conn.t()) :: String.t()
  def callback_url(conn, query_params \\ []) do
    if url = from_private(conn, :callback_url) do
      url
    else
      opts = [
        scheme: from_private(conn, :callback_scheme),
        port: from_private(conn, :callback_port),
        path: callback_path(conn),
        query_params: callback_params(conn, query_params)
      ]

      full_url(conn, opts)
    end
  end

  @doc """
  Build params for callback

  This method will filter conn.params with whitelisted params from :callback_params settings
  """
  @spec callback_params(Plug.Conn.t()) :: keyword()
  def callback_params(conn, query_params \\ []) do
    callback_params = from_private(conn, :callback_params) || []

    callback_params =
      callback_params
      |> Enum.map(fn k -> {String.to_atom(k), conn.params[k]} end)
      |> Enum.reject(fn {k, v} -> k == :provider or v == nil end)

    Keyword.merge(query_params, callback_params)
  end

  @doc """
  The configured allowed callback http methods.

  This will use any supplied options from the configuration, but fallback to the
  default options
  """
  @spec allowed_callback_methods(Plug.Conn.t()) :: list(String.t()) | nil
  def allowed_callback_methods(conn), do: from_private(conn, :callback_methods)

  @doc """
  Is the current request http method one of the allowed callback methods?
  """
  @spec allowed_callback_method?(Plug.Conn.t()) :: boolean
  def allowed_callback_method?(%{method: method} = conn) do
    callback_method =
      method
      |> to_string
      |> String.upcase()

    conn
    |> allowed_callback_methods
    |> Enum.member?(callback_method)
  end

  @doc """
  The full list of options passed to the strategy in the configuration.
  """
  @spec options(Plug.Conn.t()) :: Keyword.t() | nil
  def options(conn), do: from_private(conn, :options)

  @doc """
  A helper for constructing error entries on failure.

  The `message_key` is intended for use by machines for translations etc.
  The message is a human readable error message.

  #### Example

      error("something_bad", "Something really bad happened")
  """
  @spec error(String.t(), String.t()) :: Error.t()
  def error(key, message), do: struct(Error, message_key: key, message: message)

  @doc """
  Sets a failure onto the connection containing a List of errors.

  During your callback phase, this should be called to 'fail' the authentication
  request and include a collection of errors outlining what the problem is.

  Note this changes the conn object and should be part of your returned
  connection of the `callback_phase!`.
  """
  @spec set_errors!(Plug.Conn.t(), list(Error.t())) :: Plug.Conn.t()
  def set_errors!(conn, errors) do
    failure =
      struct(
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
  @spec redirect!(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def redirect!(conn, url) do
    html = Plug.HTML.html_escape(url)
    body = "<html><body>You are being <a href=\"#{html}\">redirected</a>.</body></html>"

    conn
    |> put_resp_header("location", url)
    |> send_resp(conn.status || 302, body)
    |> halt
  end

  @doc """
  Add state parameter to the `%Plug.Conn{}`.
  """
  @spec add_state_param(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def add_state_param(conn, value) do
    Plug.Conn.put_private(conn, :ueberauth_state_param, value)
  end

  @doc """
  Add state parameter to the options.
  """
  @spec with_state_param(
          keyword(),
          Plug.Conn.t()
        ) :: keyword()
  def with_state_param(opts, conn) do
    state = conn.private[:ueberauth_state_param]

    if is_nil(state) do
      opts
    else
      Keyword.put(opts, :state, state)
    end
  end

  defp from_private(conn, key) do
    opts = conn.private[:ueberauth_request_options]
    if opts, do: opts[key], else: nil
  end

  defp full_url(conn, opts) do
    case from_private(conn, :trust_forwarded_headers) do
      nil ->
        url = build_url(conn, opts, true)
        unless url == build_url(conn, opts, false), do: warn_untrusted_forwarded_headers()
        url

      trust_forwarded_headers ->
        build_url(conn, opts, trust_forwarded_headers)
    end
  end

  defp build_url(conn, opts, trust_forwarded_headers) do
    scheme =
      Keyword.get(opts, :scheme) ||
        (trust_forwarded_headers && get_forwarded_proto_header(conn)) ||
        to_string(conn.scheme)

    {host, port} = get_host_and_port(conn, trust_forwarded_headers)

    port = Keyword.get(opts, :port) || normalize_port(scheme, port)

    path = Keyword.fetch!(opts, :path)

    query =
      opts
      |> Keyword.get(:query_params, [])
      |> encode_query()

    %URI{
      host: host,
      port: port,
      path: path,
      query: query,
      scheme: scheme
    }
    |> to_string()
  end

  defp get_forwarded_proto_header(conn) do
    conn
    |> get_req_header("x-forwarded-proto")
    |> List.first()
  end

  defp get_forwarded_host_header(conn) do
    conn
    |> get_req_header("x-forwarded-host")
    |> List.first()
  end

  defp get_host_header(conn) do
    conn
    |> get_req_header("host")
    |> List.first()
  end

  # Header values are client-controlled, so anything that is not a plain
  # `host[:port]` authority falls through to the next candidate instead of
  # raising.
  defp get_host_and_port(conn, trust_forwarded_headers) do
    [
      trust_forwarded_headers && get_forwarded_host_header(conn),
      get_host_header(conn),
      conn.host
    ]
    |> Enum.find_value({conn.host, conn.port}, &parse_authority(&1, conn.port))
  end

  defp parse_authority(authority, default_port) when is_binary(authority) do
    case URI.new("//" <> authority) do
      {:ok, %URI{host: host, port: port, userinfo: nil, path: nil, query: nil, fragment: nil}}
      when host != "" and (is_nil(port) or port in 0..65_535) ->
        {host, port || default_port}

      _ ->
        nil
    end
  end

  defp parse_authority(_authority, _default_port), do: nil

  defp warn_untrusted_forwarded_headers do
    key = {__MODULE__, :warned_untrusted_forwarded_headers}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning("""
      Ueberauth built a request or callback URL from the X-Forwarded-Host or \
      X-Forwarded-Proto header. Any client can send these headers, so they can \
      change the redirect_uri sent to your OAuth provider.

      If a proxy you control sets these headers, set `trust_forwarded_headers: true` \
      in your provider options or in `config :ueberauth, Ueberauth`. Otherwise set \
      it to `false`, or use Plug.RewriteOn to apply proxy headers before Ueberauth runs.

      Ueberauth 0.12.0 will ignore these headers unless `trust_forwarded_headers: true` is set.
      """)
    end
  end

  defp normalize_port(scheme, 80), do: URI.default_port(scheme)
  defp normalize_port(_, port), do: port

  defp encode_query([]), do: nil
  defp encode_query(query_params), do: URI.encode_query(query_params)

  defp map_errors(nil), do: []
  defp map_errors([]), do: []
  defp map_errors(%Error{} = error), do: [error]
  defp map_errors(errors), do: Enum.map(errors, &p_error/1)

  defp p_error(%Error{} = error), do: error
  defp p_error(%{} = error), do: struct(Error, error)
  defp p_error(error) when is_list(error), do: struct(Error, error)
end
