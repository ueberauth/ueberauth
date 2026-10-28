defmodule OAuth2.Response do
  @moduledoc """
  Defines the `OAuth2.Response` struct which is created from the HTTP responses
  made by the `OAuth2.Client` module.

  ## Struct fields

  * `status_code` - HTTP response status code
  * `headers` - HTTP response headers
  * `body` - Parsed HTTP response body (based on "content-type" header)
  """

  require Logger
  import OAuth2.Util
  alias OAuth2.Client

  @type status_code :: integer
  @type headers :: [{binary, binary}]
  @type body :: binary | map | list

  @type t :: %__MODULE__{
          status_code: status_code,
          headers: headers,
          body: body
        }

  defstruct status_code: nil, headers: [], body: nil

  @doc false
  @spec new(Client.t(), integer, headers, body) :: t
  def new(client, code, headers, body) do
    headers = process_headers(headers)
    content_type = content_type(headers)
    serializer = Client.get_serializer(client, content_type)
    body = decode_response_body(body, content_type, serializer)
    resp = %__MODULE__{status_code: code, headers: headers, body: body}

    if Application.get_env(:oauth2, :debug) do
      Logger.debug("OAuth2 Provider Response #{inspect(resp)}")
    end

    resp
  end

  defp process_headers(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
  end

  defp decode_response_body("", _type, _), do: ""
  defp decode_response_body(" ", _type, _), do: ""

  defp decode_response_body(body, _type, serializer) when serializer != nil do
    serializer.decode!(body)
  end

  # Facebook sends text/plain tokens!?
  defp decode_response_body(body, "text/plain", _) do
    case URI.decode_query(body) do
      %{"access_token" => _} = token -> token
      _ -> body
    end
  end

  defp decode_response_body(body, "application/x-www-form-urlencoded", _) do
    URI.decode_query(body)
  end

  defp decode_response_body(body, _mime, nil) do
    body
  end
end
