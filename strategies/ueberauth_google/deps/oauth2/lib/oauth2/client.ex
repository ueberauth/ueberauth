defmodule OAuth2.Client do
  @moduledoc ~S"""
  This module defines the `OAuth2.Client` struct and is responsible for building
  and establishing a request for an access token.

  ### Notes

  * If a full url is given (e.g. "http://www.example.com/api/resource") then it
  will use that otherwise you can specify an endpoint (e.g. "/api/resource") and
  it will append it to the `Client.site`.

  * The headers from the `Client.headers` are appended to the request headers.

  ### Examples

      client = OAuth2.Client.new(token: "abc123")

      case OAuth2.Client.get(client, "/some/resource") do
        {:ok, %OAuth2.Response{body: body}} ->
          "Yay!!"
        {:error, %OAuth2.Response{body: body}} ->
          "Something bad happen: #{inspect body}"
        {:error, %OAuth2.Error{reason: reason}} ->
          reason
      end

      response = OAuth2.Client.get!(client, "/some/resource")

      response = OAuth2.Client.post!(client, "/some/other/resources", %{foo: "bar"})
  """

  alias OAuth2.{AccessToken, Client, Error, Request, Response}

  @type authorize_url :: binary
  @type body :: any
  @type client_id :: binary
  @type client_secret :: binary
  @type headers :: [{binary, binary}]
  @type param :: binary | %{binary => param} | [param]
  @type params :: %{binary => param} | Keyword.t() | %{}
  @type redirect_uri :: binary
  @type ref :: reference | nil
  @type request_opts :: Keyword.t()
  @type serializers :: %{binary => module}
  @type site :: binary
  @type strategy :: module
  @type token :: AccessToken.t() | nil
  @type token_method :: :post | :get | atom
  @type token_url :: binary

  @type t :: %Client{
          authorize_url: authorize_url,
          client_id: client_id,
          client_secret: client_secret,
          headers: headers,
          params: params,
          redirect_uri: redirect_uri,
          ref: ref,
          request_opts: request_opts,
          serializers: serializers,
          site: site,
          strategy: strategy,
          token: token,
          token_method: token_method,
          token_url: token_url
        }

  defstruct authorize_url: "/oauth/authorize",
            client_id: "",
            client_secret: "",
            headers: [],
            params: %{},
            redirect_uri: "",
            ref: nil,
            request_opts: [],
            serializers: %{},
            site: "",
            strategy: OAuth2.Strategy.AuthCode,
            token: nil,
            token_method: :post,
            token_url: "/oauth/token"

  @doc """
  Builds a new `OAuth2.Client` struct using the `opts` provided.

  ## Client struct fields

  * `authorize_url` - absolute or relative URL path to the authorization
    endpoint. Defaults to `"/oauth/authorize"`
  * `client_id` - the client_id for the OAuth2 provider
  * `client_secret` - the client_secret for the OAuth2 provider
  * `headers` - a list of request headers
  * `params` - a map of request parameters
  * `redirect_uri` - the URI the provider should redirect to after authorization
     or token requests
  * `request_opts` - a keyword list of request options that will be sent to the
    `hackney` client. See the [hackney documentation] for a list of available
    options.
  * `site` - the OAuth2 provider site host
  * `strategy` - a module that implements the appropriate OAuth2 strategy,
    default `OAuth2.Strategy.AuthCode`
  * `token` - `%OAuth2.AccessToken{}` struct holding the token for requests.
  * `token_method` - HTTP method to use to request token (`:get` or `:post`).
    Defaults to `:post`
  * `token_url` - absolute or relative URL path to the token endpoint.
    Defaults to `"/oauth/token"`

  ## Example

      iex> OAuth2.Client.new(token: "123")
      %OAuth2.Client{authorize_url: "/oauth/authorize", client_id: "",
      client_secret: "", headers: [], params: %{}, redirect_uri: "", site: "",
      strategy: OAuth2.Strategy.AuthCode,
      token: %OAuth2.AccessToken{access_token: "123", expires_at: nil,
      other_params: %{}, refresh_token: nil, token_type: "Bearer"},
      token_method: :post, token_url: "/oauth/token"}

      iex> token = OAuth2.AccessToken.new("123")
      iex> OAuth2.Client.new(token: token)
      %OAuth2.Client{authorize_url: "/oauth/authorize", client_id: "",
      client_secret: "", headers: [], params: %{}, redirect_uri: "", site: "",
      strategy: OAuth2.Strategy.AuthCode,
      token: %OAuth2.AccessToken{access_token: "123", expires_at: nil,
      other_params: %{}, refresh_token: nil, token_type: "Bearer"},
      token_method: :post, token_url: "/oauth/token"}

  [hackney documentation]: https://github.com/benoitc/hackney/blob/master/doc/hackney.md#request5
  """
  @spec new(t, Keyword.t()) :: t
  def new(client \\ %Client{}, opts) do
    {token, opts} = Keyword.pop(opts, :token)
    {req_opts, opts} = Keyword.pop(opts, :request_opts, [])

    opts =
      opts
      |> Keyword.put(:token, process_token(token))
      |> Keyword.put(:request_opts, Keyword.merge(client.request_opts, req_opts))

    struct(client, opts)
  end

  defp process_token(nil), do: nil
  defp process_token(val) when is_binary(val), do: AccessToken.new(val)
  defp process_token(%AccessToken{} = token), do: token

  @doc """
  Puts the specified `value` in the params for the given `key`.

  The key can be a `string` or an `atom`. Atoms are automatically
  convert to strings.
  """
  @spec put_param(t, String.t() | atom, any) :: t
  def put_param(%Client{params: params} = client, key, value) do
    %{client | params: Map.put(params, "#{key}", value)}
  end

  @doc """
  Set multiple params in the client in one call.
  """
  @spec merge_params(t, params) :: t
  def merge_params(client, params) do
    params =
      Enum.reduce(params, %{}, fn {k, v}, acc ->
        Map.put(acc, "#{k}", v)
      end)

    %{client | params: Map.merge(client.params, params)}
  end

  @doc """
  Adds a new header `key` if not present, otherwise replaces the
  previous value of that header with `value`.
  """
  @spec put_header(t, binary, binary) :: t
  def put_header(%Client{headers: headers} = client, key, value)
      when is_binary(key) and is_binary(value) do
    key = String.downcase(key)
    %{client | headers: List.keystore(headers, key, 0, {key, value})}
  end

  @doc """
  Set multiple headers in the client in one call.
  """
  @spec put_headers(t, list) :: t
  def put_headers(%Client{} = client, []), do: client

  def put_headers(%Client{} = client, [{k, v} | rest]) do
    client
    |> put_header(k, v)
    |> put_headers(rest)
  end

  @doc false
  @spec authorize_url(t, list) :: {t, binary}
  def authorize_url(%Client{} = client, params \\ []) do
    client.strategy.authorize_url(client, params) |> to_url(:authorize_url)
  end

  @doc """
  Returns the authorize url based on the client configuration.

  ## Example

      iex> OAuth2.Client.authorize_url!(%OAuth2.Client{})
      "/oauth/authorize?client_id=&redirect_uri=&response_type=code"
  """
  @spec authorize_url!(t, list) :: binary
  def authorize_url!(%Client{} = client, params \\ []) do
    {_, url} = authorize_url(client, params)
    url
  end

  @doc """
  Register a serialization module for a given mime type.

  ## Example

      iex> client = OAuth2.Client.put_serializer(%OAuth2.Client{}, "application/json", Jason)
      %OAuth2.Client{serializers: %{"application/json" => Jason}}
      iex> OAuth2.Client.get_serializer(client, "application/json")
      Jason
  """
  @spec put_serializer(t, binary, atom) :: t
  def put_serializer(%Client{serializers: serializers} = client, mime, module)
      when is_binary(mime) and is_atom(module) do
    %Client{client | serializers: Map.put(serializers, mime, module)}
  end

  @doc """
  Un-register a serialization module for a given mime type.

  ## Example

      iex> client = OAuth2.Client.delete_serializer(%OAuth2.Client{}, "application/json")
      %OAuth2.Client{}
      iex> OAuth2.Client.get_serializer(client, "application/json")
      nil
  """
  @spec delete_serializer(t, binary) :: t
  def delete_serializer(%Client{serializers: serializers} = client, mime) do
    %Client{client | serializers: Map.delete(serializers, mime)}
  end

  @doc false
  @spec get_serializer(t, binary) :: atom
  def get_serializer(%Client{serializers: serializers}, mime) do
    Map.get(serializers, mime)
  end

  @doc """
  Fetches an `OAuth2.AccessToken` struct by making a request to the token endpoint.

  Returns the `OAuth2.Client` struct loaded with the access token which can then
  be used to make authenticated requests to an OAuth2 provider's API.

  ## Arguments

  * `client` - a `OAuth2.Client` struct with the strategy to use, defaults to
    `OAuth2.Strategy.AuthCode`
  * `params` - a keyword list of request parameters which will be encoded into
    a query string or request body depending on the selected strategy
  * `headers` - a list of request headers
  * `opts` - a Keyword list of request options which will be merged with
    `OAuth2.Client.request_opts`

  ## Options

  * `:recv_timeout` - the timeout (in milliseconds) of the request
  * `:proxy` - a proxy to be used for the request; it can be a regular url or a
    `{host, proxy}` tuple
  """
  @spec get_token(t, params, headers, Keyword.t()) ::
          {:ok, Client.t()} | {:error, Response.t()} | {:error, Error.t()}
  def get_token(%{token_method: method} = client, params \\ [], headers \\ [], opts \\ []) do
    {client, url} = token_url(client, params, headers)

    case Request.request(method, client, url, client.params, client.headers, opts) do
      {:ok, response} ->
        token = AccessToken.new(response.body)
        {:ok, %{client | headers: [], params: %{}, token: token}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Same as `get_token/4` but raises `OAuth2.Error` if an error occurs during the
  request.
  """
  @spec get_token!(t, params, headers, Keyword.t()) :: Client.t() | Error.t()
  def get_token!(client, params \\ [], headers \\ [], opts \\ []) do
    case get_token(client, params, headers, opts) do
      {:ok, client} ->
        client

      {:error, %Response{status_code: code, headers: headers, body: body}} ->
        raise %Error{
          reason: """
          Server responded with status: #{code}

          Headers:

          #{Enum.reduce(headers, "", fn {k, v}, acc -> acc <> "#{k}: #{v}\n" end)}
          Body:

          #{inspect(body)}
          """
        }

      {:error, error} ->
        raise error
    end
  end

  @doc """
  Refreshes an existing access token using a refresh token.
  """
  @spec refresh_token(t, params, headers, Keyword.t()) ::
          {:ok, Client.t()} | {:error, Response.t()} | {:error, Error.t()}
  def refresh_token(client, params \\ [], headers \\ [], opts \\ [])

  def refresh_token(%Client{token: %{refresh_token: nil}}, _params, _headers, _opts) do
    {:error, %Error{reason: "Refresh token not available."}}
  end

  def refresh_token(
        %Client{token: %{refresh_token: refresh_token}} = client,
        params,
        headers,
        opts
      ) do
    refresh_client =
      %{client | strategy: OAuth2.Strategy.Refresh, token: nil}
      |> Client.put_param(:refresh_token, refresh_token)

    case Client.get_token(refresh_client, params, headers, opts) do
      {:ok, %Client{} = client} ->
        if client.token.refresh_token do
          {:ok, client}
        else
          {:ok, put_in(client.token.refresh_token, refresh_token)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Calls `refresh_token/4` but raises `Error` if there an error occurs.
  """
  @spec refresh_token!(t, params, headers, Keyword.t()) :: Client.t() | Error.t()
  def refresh_token!(%Client{} = client, params \\ [], headers \\ [], opts \\ []) do
    case refresh_token(client, params, headers, opts) do
      {:ok, %Client{} = client} -> client
      {:error, error} -> raise error
    end
  end

  @doc """
  Adds `authorization` header for basic auth.
  """
  @spec basic_auth(t) :: t
  def basic_auth(%OAuth2.Client{client_id: id, client_secret: secret} = client) do
    put_header(client, "authorization", "Basic " <> Base.encode64(id <> ":" <> secret))
  end

  @doc """
  Makes a `GET` request to the given `url` using the `OAuth2.AccessToken`
  struct.
  """
  @spec get(t, binary, headers, Keyword.t()) ::
          {:ok, Response.t()} | {:error, Response.t()} | {:error, Error.t()}
  def get(%Client{} = client, url, headers \\ [], opts \\ []),
    do: Request.request(:get, client, url, "", headers, opts)

  @doc """
  Same as `get/4` but returns a `OAuth2.Response` or `OAuth2.Error` exception if
  the request results in an error.
  """
  @spec get!(t, binary, headers, Keyword.t()) :: Response.t() | Error.t()
  def get!(%Client{} = client, url, headers \\ [], opts \\ []),
    do: Request.request!(:get, client, url, "", headers, opts)

  @doc """
  Makes a `PUT` request to the given `url` using the `OAuth2.AccessToken`
  struct.
  """
  @spec put(t, binary, body, headers, Keyword.t()) ::
          {:ok, Response.t()} | {:error, Response.t()} | {:error, Error.t()}
  def put(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request(:put, client, url, body, headers, opts)

  @doc """
  Same as `put/5` but returns a `OAuth2.Response` or `OAuth2.Error` exception if
  the request results in an error.

  An `OAuth2.Error` exception is raised if the request results in an
  error tuple (`{:error, reason}`).
  """
  @spec put!(t, binary, body, headers, Keyword.t()) :: Response.t() | Error.t()
  def put!(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request!(:put, client, url, body, headers, opts)

  @doc """
  Makes a `PATCH` request to the given `url` using the `OAuth2.AccessToken`
  struct.
  """
  @spec patch(t, binary, body, headers, Keyword.t()) ::
          {:ok, Response.t()} | {:error, Response.t()} | {:error, Error.t()}
  def patch(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request(:patch, client, url, body, headers, opts)

  @doc """
  Same as `patch/5` but returns a `OAuth2.Response` or `OAuth2.Error` exception if
  the request results in an error.

  An `OAuth2.Error` exception is raised if the request results in an
  error tuple (`{:error, reason}`).
  """
  @spec patch!(t, binary, body, headers, Keyword.t()) :: Response.t() | Error.t()
  def patch!(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request!(:patch, client, url, body, headers, opts)

  @doc """
  Makes a `POST` request to the given URL using the `OAuth2.AccessToken`.
  """
  @spec post(t, binary, body, headers, Keyword.t()) ::
          {:ok, Response.t()} | {:error, Response.t()} | {:error, Error.t()}
  def post(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request(:post, client, url, body, headers, opts)

  @doc """
  Same as `post/5` but returns a `OAuth2.Response` or `OAuth2.Error` exception
  if the request results in an error.

  An `OAuth2.Error` exception is raised if the request results in an
  error tuple (`{:error, reason}`).
  """
  @spec post!(t, binary, body, headers, Keyword.t()) :: Response.t() | Error.t()
  def post!(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request!(:post, client, url, body, headers, opts)

  @doc """
  Makes a `DELETE` request to the given URL using the `OAuth2.AccessToken`.
  """
  @spec delete(t, binary, body, headers, Keyword.t()) ::
          {:ok, Response.t()} | {:error, Response.t()} | {:error, Error.t()}
  def delete(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request(:delete, client, url, body, headers, opts)

  @doc """
  Same as `delete/5` but returns a `OAuth2.Response` or `OAuth2.Error` exception
  if the request results in an error.

  An `OAuth2.Error` exception is raised if the request results in an
  error tuple (`{:error, reason}`).
  """
  @spec delete!(t, binary, body, headers, Keyword.t()) :: Response.t() | Error.t()
  def delete!(%Client{} = client, url, body \\ "", headers \\ [], opts \\ []),
    do: Request.request!(:delete, client, url, body, headers, opts)

  defp to_url(%Client{token_method: :post} = client, :token_url) do
    {client, endpoint(client, client.token_url)}
  end

  defp to_url(client, endpoint) do
    endpoint = Map.get(client, endpoint)
    url = endpoint(client, endpoint) <> "?" <> URI.encode_query(client.params)
    {client, url}
  end

  defp token_url(client, params, headers) do
    client
    |> token_post_header()
    |> client.strategy.get_token(params, headers)
    |> to_url(:token_url)
  end

  defp token_post_header(%Client{token_method: :post} = client) do
    client
    |> put_header("content-type", "application/x-www-form-urlencoded")
    |> put_header("accept", "application/json")
  end

  defp token_post_header(%Client{} = client), do: client

  defp endpoint(client, <<"/"::utf8, _::binary>> = endpoint),
    do: client.site <> endpoint

  defp endpoint(_client, endpoint), do: endpoint
end
