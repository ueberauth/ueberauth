defmodule OAuther do
  defmodule Credentials do
    defstruct [
      :consumer_key,
      :consumer_secret,
      :token,
      :token_secret,
      method: :hmac_sha1
    ]

    @type t :: %__MODULE__{
            consumer_key: String.t(),
            consumer_secret: String.t(),
            token: nil | String.t(),
            token_secret: nil | String.t(),
            method: :hmac_sha1 | :hmac_sha256 | :rsa_sha1 | :plaintext
          }
  end

  @type params :: [{String.t(), String.Chars.t()}]
  @type header :: {String.t(), String.t()}

  @spec credentials(Enumerable.t()) :: Credentials.t() | no_return
  def credentials(args) do
    Enum.reduce(args, %Credentials{}, fn {key, val}, acc ->
      :maps.update(key, val, acc)
    end)
  end

  @spec sign(String.t(), URI.t() | String.t(), params, Credentials.t()) :: params
  def sign(verb, url, params, %Credentials{} = creds) do
    params = protocol_params(params, creds)
    signature = signature(verb, url, params, creds)

    [{"oauth_signature", signature} | params]
  end

  @spec header(params) :: {header, params}
  def header(params) do
    {oauth_params, req_params} = split_with(params, &protocol_param?/1)

    {{"Authorization", "OAuth " <> compose_header(oauth_params)}, req_params}
  end

  @spec protocol_params(params, Credentials.t()) :: params
  def protocol_params(params, %Credentials{} = creds) do
    [
      {"oauth_consumer_key", creds.consumer_key},
      {"oauth_nonce", nonce()},
      {"oauth_signature_method", signature_method(creds.method)},
      {"oauth_timestamp", timestamp()},
      {"oauth_version", "1.0"}
      | maybe_put_token(params, creds.token)
    ]
  end

  @spec signature(String.t(), URI.t() | String.t(), params, Credentials.t()) :: binary
  def signature(_, _, _, %Credentials{method: :plaintext} = creds) do
    compose_key(creds)
  end

  def signature(verb, url, params, %Credentials{method: :hmac_sha1} = creds) do
    creds
    |> compose_key()
    |> hmac_sha(base_string(verb, url, params), :sha)
    |> Base.encode64()
  end

  def signature(verb, url, params, %Credentials{method: :hmac_sha256} = creds) do
    creds
    |> compose_key()
    |> hmac_sha(base_string(verb, url, params), :sha256)
    |> Base.encode64()
  end

  def signature(verb, url, params, %Credentials{method: :rsa_sha1} = creds) do
    base_string(verb, url, params)
    |> :public_key.sign(:sha, decode_private_key(creds.consumer_secret))
    |> Base.encode64()
  end

  # TODO: Remove this once we require at minimum OTP 22.
  if Code.ensure_loaded?(:crypto) and function_exported?(:crypto, :mac, 4) do
    defp hmac_sha(key, data, hash_function) do
      :crypto.mac(:hmac, hash_function, key, data)
    end
  else
    defp hmac_sha(key, data, hash_function) do
      :crypto.hmac(hash_function, key, data)
    end
  end

  defp protocol_param?({key, _value}) do
    String.starts_with?(key, "oauth_")
  end

  defp compose_header([_ | _] = params) do
    params
    |> Stream.map(&percent_encode/1)
    |> Enum.map_join(", ", &compose_header/1)
  end

  defp compose_header({key, value}) do
    key <> "=\"" <> value <> "\""
  end

  defp compose_key(creds) do
    [creds.consumer_secret, creds.token_secret]
    |> Enum.map_join("&", &percent_encode/1)
  end

  defp read_private_key("-----BEGIN RSA PRIVATE KEY-----" <> _ = private_key) do
    private_key
  end

  defp read_private_key(path) do
    File.read!(path)
  end

  defp decode_private_key(private_key_or_path) do
    [entry] =
      private_key_or_path
      |> read_private_key()
      |> :public_key.pem_decode()

    :public_key.pem_entry_decode(entry)
  end

  defp base_string(verb, url, params) do
    {uri, query_params} = parse_url(url)

    [verb, uri, params ++ query_params]
    |> Stream.map(&normalize/1)
    |> Enum.map_join("&", &percent_encode/1)
  end

  defp normalize(verb) when is_binary(verb) do
    String.upcase(verb)
  end

  defp normalize(%URI{host: host} = uri) do
    %{uri | host: String.downcase(host)}
  end

  defp normalize([_ | _] = params) do
    Enum.map(params, &percent_encode/1)
    |> Enum.sort()
    |> Enum.map_join("&", &normalize_pair/1)
  end

  defp normalize_pair({key, value}) do
    key <> "=" <> value
  end

  defp parse_url(url) do
    uri = URI.parse(url)
    {%{uri | query: nil}, parse_query_params(uri.query)}
  end

  defp parse_query_params(params) do
    if is_nil(params) do
      []
    else
      URI.query_decoder(params)
      |> Enum.to_list()
    end
  end

  defp nonce() do
    :crypto.strong_rand_bytes(24)
    |> Base.encode64()
  end

  defp timestamp() do
    {megasec, sec, _microsec} = :os.timestamp()
    megasec * 1_000_000 + sec
  end

  defp maybe_put_token(params, value) do
    if is_nil(value) do
      params
    else
      [{"oauth_token", value} | params]
    end
  end

  defp signature_method(:plaintext), do: "PLAINTEXT"
  defp signature_method(:hmac_sha1), do: "HMAC-SHA1"
  defp signature_method(:hmac_sha256), do: "HMAC-SHA256"
  defp signature_method(:rsa_sha1), do: "RSA-SHA1"

  defp percent_encode({key, value}) do
    {percent_encode(key), percent_encode(value)}
  end

  defp percent_encode(other) do
    other
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  # TODO: Remove once we depend on Elixir 1.4 and higher.
  Code.ensure_loaded(Enum)
  split_with = if function_exported?(Enum, :split_with, 2), do: :split_with, else: :partition
  defp split_with(enum, fun), do: Enum.unquote(split_with)(enum, fun)
end
