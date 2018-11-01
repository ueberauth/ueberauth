defmodule Ueberauth.Strategy.Helpers do
  @moduledoc """
  Provides helper methods for use within your strategy.

  These helpers are provided as a convenience for accessing the options passed
  to the specific pipelined strategy, considering the pipelined options and
  falling back to defaults.
  """

  require Logger

  alias Ueberauth.Failure
  alias Ueberauth.Failure.Error

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
  Creates a failure containing a list of error

  During your callback phase, this should be called to 'fail' the authentication
  request and include a collection of errors outlining what the problem is.

  Note this changes the conn object and should be part of your returned
  connection of the `callback_phase!`.
  """
  def create_failure(provider, strategy, errors) do
    struct(
      Failure,
      provider: provider,
      strategy: strategy,
      errors: map_errors(errors)
    )
  end

  @doc """
  Redirects to a url and halts the plug pipeline.
  """
  @spec redirect!(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def redirect!(conn, url) do
    html = Plug.HTML.html_escape(url)
    body = "<html><body>You are being <a href=\"#{html}\">redirected</a>.</body></html>"

    conn
    |> Plug.Conn.put_resp_header("location", url)
    |> Plug.Conn.send_resp(conn.status || 302, body)
    |> Plug.Conn.halt()
  end

  def request_uri(conn) do
    scheme =
      conn
      |> forwarded_proto
      |> coalesce(conn.scheme)
      |> normalize_scheme

    %URI{
      host: conn.host,
      port: normalize_port(scheme, conn.port),
      path: conn.request_path,
      query: conn.query_string(),
      scheme: to_string(scheme),
    }
  end

  def validate_options({:error, _} = err, _), do: err
  def validate_options({:ok, options}, []), do: {:ok, options}
  def validate_options({:ok, options}, [key | rest]) do
    if Keyword.has_key?(options, key) do
      validate_options({:ok, options}, rest)
    else
      Logger.warn(fn -> "[Ueberauth] Missing required key #{inspect(key)}" end)
      {:error, :missing_key}
    end
  end

  def validate_options(options, required_keys),
    do: validate_options({:ok, options}, required_keys)

  def map_string_to_atom(map, key),
    do: map_string_to_atom(map, List.wrap(key))

  def map_string_to_atom(map, []),
    do: map

  def map_string_to_atom(map, [key | rest]) do
    result =
      if Map.get(map, key) do
        map
      else
        if value = Map.get(map, to_string(key)) do
          map
          |> Map.put(key, value)
          |> Map.drop([to_string(key)])
        else
          map
        end
      end
    map_string_to_atom(result, rest)
  end

  def put_non_nil(collection, _key, nil), do: collection
  def put_non_nil(collection, key, value) when is_list(collection) and is_atom(key) do
    [{key, value} | collection]
  end
  defp put_non_nil(collection, key, value) when is_map(collection) and is_atom(key) do
    Map.put(collection, key, value)
  end

  defp forwarded_proto(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-proto")
    |> List.first()
  end

  defp normalize_scheme("https"), do: :https
  defp normalize_scheme("http"), do: :http
  defp normalize_scheme(scheme), do: scheme

  defp coalesce(nil, second), do: second
  defp coalesce(first, _), do: first

  defp normalize_port(:https, 80), do: 443
  defp normalize_port(_, port), do: port

  defp map_errors(nil), do: []
  defp map_errors([]), do: []
  defp map_errors(%Error{} = error), do: [error]
  defp map_errors(errors), do: Enum.map(errors, &p_error/1)

  defp p_error(%Error{} = error), do: error
  defp p_error(%{} = error), do: struct(Error, error)
  defp p_error(error) when is_list(error), do: struct(Error, error)
end
