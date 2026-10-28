require Record

defmodule JOSE.JWK do
  @moduledoc ~S"""
  JWK stands for JSON Web Key which is defined in [RFC 7517](https://tools.ietf.org/html/rfc7517).
  """

  record = Record.extract(:jose_jwk, from_lib: "jose/include/jose_jwk.hrl")
  keys = :lists.map(&elem(&1, 0), record)
  vals = :lists.map(&{&1, [], nil}, keys)
  pairs = :lists.zip(keys, vals)

  @derive {Inspect, except: [:kty]}
  defstruct keys
  @type t :: %__MODULE__{}

  @doc """
  Converts a `JOSE.JWK` struct to a `:jose_jwk` record.
  """
  def to_record(%JOSE.JWK{unquote_splicing(pairs)}) do
    {:jose_jwk, unquote_splicing(vals)}
  end

  def to_record(list) when is_list(list), do: for(element <- list, into: [], do: to_record(element))

  @doc false
  defp maybe_to_record(struct = %JOSE.JWK{}), do: to_record(struct)
  defp maybe_to_record(other), do: other

  @doc """
  Converts a `:jose_jwk` record into a `JOSE.JWK`.
  """
  def from_record(jose_jwk)

  def from_record({:jose_jwk, unquote_splicing(vals)}) do
    %JOSE.JWK{unquote_splicing(pairs)}
  end

  def from_record(list) when is_list(list), do: for(element <- list, into: [], do: from_record(element))

  ## Decode API

  @doc """
  Converts a binary or map into a `JOSE.JWK`.

      iex> JOSE.JWK.from(%{"k" => "", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined, kty: {:jose_jwk_kty_oct, ""}}
      iex> JOSE.JWK.from("{\"k\":\"\",\"kty\":\"oct\"}")
      %JOSE.JWK{fields: %{}, keys: :undefined, kty: {:jose_jwk_kty_oct, ""}}

  The `"kty"` field may be overridden with a custom module that implements the `:jose_jwk` and `:jose_jwk_kty` behaviours.

  For example:

      iex> JOSE.JWK.from({%{ kty: MyCustomKey }, %{ "kty" => "custom" }})
      %JOSE.JWK{fields: %{}, keys: :undefined, kty: {MyCustomKey, :state}}

  """
  def from(list) when is_list(list), do: for(element <- list, into: [], do: from(element))
  def from(jwk = %JOSE.JWK{}), do: from(to_record(jwk))
  def from(any), do: :jose_jwk.from(any) |> from_record()

  @doc """
  Decrypts an encrypted binary or map into a `JOSE.JWK` using the specified `password`.

      iex> JOSE.JWK.from("password", "eyJhbGciOiJQQkVTMi1IUzI1NitBMTI4S1ciLCJjdHkiOiJqd2sranNvbiIsImVuYyI6IkExMjhHQ00iLCJwMmMiOjQwOTYsInAycyI6Im5OQ1ZNQUktNTU5UVFtbWRFcnBsZFEifQ.Ucye69ii4dxd1ykNFlJyBVeA6xeNu4aV.2pZ4nBoxBjmdrneS.boqwdFZVNAFHk1M5P6kPYgBUgGwW32QuKzHuFA.wL9Hy6dcE_DPkUW9s5iwKA")
      {%JOSE.JWE{alg: {:jose_jwe_alg_pbes2,
         {:jose_jwe_alg_pbes2, :sha256, 128,
          <<80, 66, 69, 83, 50, 45, 72, 83, 50, 53, 54, 43, 65, 49, 50, 56, 75, 87, 0, 156, 208, 149, 48, 2, 62, 231, 159, 80, 66, 105, 157, 18, 186, 101, 117>>,
          4096}},
        enc: {:jose_jwe_enc_aes,
         {:jose_jwe_enc_aes, {:aes_gcm, 128}, 128, 16, 12, :undefined, :undefined,
          :undefined, :undefined}}, fields: %{"cty" => "jwk+json"}, zip: :undefined},
       %JOSE.JWK{fields: %{}, keys: :undefined, kty: {:jose_jwk_kty_oct, "secret"}}}

  """
  def from(password, list) when is_list(list), do: for(element <- list, into: [], do: from(password, element))
  def from(password, jwk = %JOSE.JWK{}), do: from(password, to_record(jwk))
  def from(password, any), do: :jose_jwk.from(password, any) |> from_encrypted_record()

  @doc """
  Converts a binary into a `JOSE.JWK`.
  """
  def from_binary(list) when is_list(list), do: for(element <- list, into: [], do: from_binary(element))
  def from_binary(binary), do: :jose_jwk.from_binary(binary) |> from_record()

  @doc """
  Decrypts an encrypted binary into a `JOSE.JWK` using `password`.  See `from/2`.
  """
  def from_binary(password, list) when is_list(list), do: for(element <- list, into: [], do: from_binary(password, element))
  def from_binary(password, binary), do: :jose_jwk.from_binary(password, binary) |> from_encrypted_record()

  @doc """
  Converts a DER (Distinguished Encoding Rules)  binary into a `JOSE.JWK`.
  """
  def from_der(list) when is_list(list), do: for(element <- list, into: [], do: from_der(element))
  def from_der(pem), do: :jose_jwk.from_der(pem) |> from_record()

  @doc """
  Decrypts an encrypted DER (Distinguished Encoding Rules)  binary into a `JOSE.JWK` using `password`.
  """
  def from_der(password, list) when is_list(list), do: for(element <- list, into: [], do: from_der(password, element))
  def from_der(password, pem), do: :jose_jwk.from_der(password, pem) |> from_record()

  @doc """
  Reads file and calls `from_der/1` to convert into a `JOSE.JWK`.
  """
  def from_der_file(file), do: :jose_jwk.from_der_file(file) |> from_record()

  @doc """
  Reads encrypted file and calls `from_der/2` to convert into a `JOSE.JWK` using `password`.
  """
  def from_der_file(password, file), do: :jose_jwk.from_der_file(password, file) |> from_record()

  @doc """
  Reads file and calls `from_binary/1` to convert into a `JOSE.JWK`.
  """
  def from_file(file), do: :jose_jwk.from_file(file) |> from_record()

  @doc """
  Reads encrypted file and calls `from_binary/2` to convert into a `JOSE.JWK` using `password`.  See `from/2`.
  """
  def from_file(password, file), do: :jose_jwk.from_file(password, file) |> from_encrypted_record()

  @doc """
  Converts Firebase certificate public keys into a map of `JOSE.JWK`.
  """
  def from_firebase(any), do: :maps.fold(fn k, v, a -> :maps.put(k, from_record(v), a) end, %{}, :jose_jwk.from_firebase(any))

  @doc """
  Converts Erlang records for `:ECPrivateKey`, `:ECPublicKey`, `:RSAPrivateKey`, and `:RSAPublicKey` into a `JOSE.JWK`.
  """
  def from_key(list) when is_list(list), do: for(element <- list, into: [], do: from_key(element))
  def from_key(key), do: :jose_jwk.from_key(key) |> from_record()

  @doc """
  Converts a map into a `JOSE.JWK`.
  """
  def from_map(list) when is_list(list), do: for(element <- list, into: [], do: from_map(element))
  def from_map(map), do: :jose_jwk.from_map(map) |> from_record()

  @doc """
  Decrypts an encrypted map into a `JOSE.JWK` using `password`.  See `from/2`.
  """
  def from_map(password, list) when is_list(list), do: for(element <- list, into: [], do: from_map(password, element))
  def from_map(password, map), do: :jose_jwk.from_map(password, map) |> from_encrypted_record()

  @doc """
  Converts an arbitrary binary into a `JOSE.JWK` with `"kty"` of `"oct"`.
  """
  def from_oct(list) when is_list(list), do: for(element <- list, into: [], do: from_oct(element))
  def from_oct(oct), do: :jose_jwk.from_oct(oct) |> from_record()

  @doc """
  Decrypts an encrypted arbitrary binary into a `JOSE.JWK` with `"kty"` of `"oct"` using `password`.  See `from/2`.
  """
  def from_oct(password, list) when is_list(list), do: for(element <- list, into: [], do: from_oct(password, element))
  def from_oct(password, oct), do: :jose_jwk.from_oct(password, oct) |> from_encrypted_record()

  @doc """
  Reads file and calls `from_oct/1` to convert into a `JOSE.JWK`.
  """
  def from_oct_file(file), do: :jose_jwk.from_oct_file(file) |> from_record()

  @doc """
  Reads encrypted file and calls `from_oct/2` to convert into a `JOSE.JWK` using `password`.  See `from/2`.
  """
  def from_oct_file(password, file), do: :jose_jwk.from_oct_file(password, file) |> from_encrypted_record()

  @doc """
  Converts an octet key pair into a `JOSE.JWK` with `"kty"` of `"OKP"`.
  """
  def from_okp(list) when is_list(list), do: for(element <- list, into: [], do: from_okp(element))
  def from_okp(okp), do: :jose_jwk.from_okp(okp) |> from_record()

  @doc """
  Converts an openssh key into a `JOSE.JWK` with `"kty"` of `"OKP"`.
  """
  def from_openssh_key(list) when is_list(list), do: for(element <- list, into: [], do: from_openssh_key(element))
  def from_openssh_key(openssh_key), do: :jose_jwk.from_openssh_key(openssh_key) |> from_record()

  @doc """
  Reads file and calls `from_openssh_key/1` to convert into a `JOSE.JWK`.
  """
  def from_openssh_key_file(file), do: :jose_jwk.from_openssh_key_file(file) |> from_record()

  @doc """
  Converts a PEM (Privacy Enhanced Email) binary into a `JOSE.JWK`.
  """
  def from_pem(list) when is_list(list), do: for(element <- list, into: [], do: from_pem(element))
  def from_pem(pem), do: :jose_jwk.from_pem(pem) |> from_record()

  @doc """
  Decrypts an encrypted PEM (Privacy Enhanced Email) binary into a `JOSE.JWK` using `password`.
  """
  def from_pem(password, list) when is_list(list), do: for(element <- list, into: [], do: from_pem(password, element))
  def from_pem(password, pem), do: :jose_jwk.from_pem(password, pem) |> from_record()

  @doc """
  Reads file and calls `from_pem/1` to convert into a `JOSE.JWK`.
  """
  def from_pem_file(file), do: :jose_jwk.from_pem_file(file) |> from_record()

  @doc """
  Reads encrypted file and calls `from_pem/2` to convert into a `JOSE.JWK` using `password`.
  """
  def from_pem_file(password, file), do: :jose_jwk.from_pem_file(password, file) |> from_record()

  defp from_encrypted_record({jwe, jwk}) when is_tuple(jwe) and is_tuple(jwk),
    do: {JOSE.JWE.from_record(jwe), from_record(jwk)}

  defp from_encrypted_record(any), do: any

  ## Encode API

  @doc """
  Converts a `JOSE.JWK` into a binary.
  """
  def to_binary(list) when is_list(list), do: for(element <- list, into: [], do: to_binary(element))
  def to_binary(jwk = %JOSE.JWK{}), do: to_binary(to_record(jwk))
  def to_binary(jwk), do: :jose_jwk.to_binary(jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a binary using `password` and the default `jwe` for the key type.  See `to_binary/3`.
  """
  def to_binary(password, list) when is_list(list), do: for(element <- list, into: [], do: to_binary(password, element))
  def to_binary(password, jwk = %JOSE.JWK{}), do: to_binary(password, to_record(jwk))
  def to_binary(password, jwk), do: :jose_jwk.to_binary(password, jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a binary using `password` and `jwe`.
  """
  def to_binary(password, jwe = %JOSE.JWE{}, jwk), do: to_binary(password, JOSE.JWE.to_record(jwe), jwk)
  def to_binary(password, jwe, jwk = %JOSE.JWK{}), do: to_binary(password, jwe, to_record(jwk))
  def to_binary(password, jwe, jwk), do: :jose_jwk.to_binary(password, jwe, jwk)

  @doc """
  Converts a `JOSE.JWK` into a DER (Distinguished Encoding Rules)  binary.
  """
  def to_der(list) when is_list(list), do: for(element <- list, into: [], do: to_der(element))
  def to_der(jwk = %JOSE.JWK{}), do: to_der(to_record(jwk))
  def to_der(jwk), do: :jose_jwk.to_der(jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a DER (Distinguished Encoding Rules)  encrypted binary using `password`.
  """
  def to_der(password, list) when is_list(list), do: for(element <- list, into: [], do: to_der(password, element))
  def to_der(password, jwk = %JOSE.JWK{}), do: to_der(password, to_record(jwk))
  def to_der(password, jwk), do: :jose_jwk.to_der(password, jwk)

  @doc """
  Calls `to_der/1` on a `JOSE.JWK` and then writes the binary to file.
  """
  def to_der_file(file, jwk = %JOSE.JWK{}), do: to_der_file(file, to_record(jwk))
  def to_der_file(file, jwk), do: :jose_jwk.to_der_file(file, jwk)

  @doc """
  Calls `to_der/2` on a `JOSE.JWK` and then writes the encrypted binary to file.
  """
  def to_der_file(password, file, jwk = %JOSE.JWK{}), do: to_der_file(password, file, to_record(jwk))
  def to_der_file(password, file, jwk), do: :jose_jwk.to_der_file(password, file, jwk)

  @doc """
  Calls `to_binary/1` on a `JOSE.JWK` and then writes the binary to file.
  """
  def to_file(file, jwk = %JOSE.JWK{}), do: to_file(file, to_record(jwk))
  def to_file(file, jwk), do: :jose_jwk.to_file(file, jwk)

  @doc """
  Calls `to_binary/2` on a `JOSE.JWK` and then writes the encrypted binary to file.
  """
  def to_file(password, file, jwk = %JOSE.JWK{}), do: to_file(password, file, to_record(jwk))
  def to_file(password, file, jwk), do: :jose_jwk.to_file(password, file, jwk)

  @doc """
  Calls `to_binary/3` on a `JOSE.JWK` and then writes the encrypted binary to file.
  """
  def to_file(password, file, jwe = %JOSE.JWE{}, jwk), do: to_file(password, file, JOSE.JWE.to_record(jwe), jwk)
  def to_file(password, file, jwe, jwk = %JOSE.JWK{}), do: to_file(password, file, jwe, to_record(jwk))
  def to_file(password, file, jwe, jwk), do: :jose_jwk.to_file(password, file, jwe, jwk)

  @doc """
  Converts a `JOSE.JWK` into the raw key format.
  """
  def to_key(list) when is_list(list), do: for(element <- list, into: [], do: to_key(element))
  def to_key(jwk = %JOSE.JWK{}), do: to_key(to_record(jwk))
  def to_key(jwk), do: :jose_jwk.to_key(jwk)

  @doc """
  Converts a `JOSE.JWK` into a map.
  """
  def to_map(list) when is_list(list), do: for(element <- list, into: [], do: to_map(element))
  def to_map(jwk = %JOSE.JWK{}), do: to_map(to_record(jwk))
  def to_map(jwk), do: :jose_jwk.to_map(jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a map using `password` and the default `jwe` for the key type.  See `to_map/3`.
  """
  def to_map(password, list) when is_list(list), do: for(element <- list, into: [], do: to_map(password, element))
  def to_map(password, jwk = %JOSE.JWK{}), do: to_map(password, to_record(jwk))
  def to_map(password, jwk), do: :jose_jwk.to_map(password, jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a map using `password` and `jwe`.
  """
  def to_map(password, jwe = %JOSE.JWE{}, jwk), do: to_map(password, JOSE.JWE.to_record(jwe), jwk)
  def to_map(password, jwe, jwk = %JOSE.JWK{}), do: to_map(password, jwe, to_record(jwk))
  def to_map(password, jwe, jwk), do: :jose_jwk.to_map(password, jwe, jwk)

  @doc """
  Converts a `JOSE.JWK` into a raw binary octet.
  """
  def to_oct(list) when is_list(list), do: for(element <- list, into: [], do: to_oct(element))
  def to_oct(jwk = %JOSE.JWK{}), do: to_oct(to_record(jwk))
  def to_oct(jwk), do: :jose_jwk.to_oct(jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a raw binary octet using `password` and the default `jwe` for the key type.  See `to_oct/3`.
  """
  def to_oct(password, list) when is_list(list), do: for(element <- list, into: [], do: to_oct(password, element))
  def to_oct(password, jwk = %JOSE.JWK{}), do: to_oct(password, to_record(jwk))
  def to_oct(password, jwk), do: :jose_jwk.to_oct(password, jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a raw binary octet using `password` and `jwe`.
  """
  def to_oct(password, jwe = %JOSE.JWE{}, jwk), do: to_oct(password, JOSE.JWE.to_record(jwe), jwk)
  def to_oct(password, jwe, jwk = %JOSE.JWK{}), do: to_oct(password, jwe, to_record(jwk))
  def to_oct(password, jwe, jwk), do: :jose_jwk.to_oct(password, jwe, jwk)

  @doc """
  Calls `to_oct/1` on a `JOSE.JWK` and then writes the binary to file.
  """
  def to_oct_file(file, jwk = %JOSE.JWK{}), do: to_oct_file(file, to_record(jwk))
  def to_oct_file(file, jwk), do: :jose_jwk.to_oct_file(file, jwk)

  @doc """
  Calls `to_oct/2` on a `JOSE.JWK` and then writes the encrypted binary to file.
  """
  def to_oct_file(password, file, jwk = %JOSE.JWK{}), do: to_oct_file(password, file, to_record(jwk))
  def to_oct_file(password, file, jwk), do: :jose_jwk.to_oct_file(password, file, jwk)

  @doc """
  Calls `to_oct/3` on a `JOSE.JWK` and then writes the encrypted binary to file.
  """
  def to_oct_file(password, file, jwe = %JOSE.JWE{}, jwk), do: to_oct_file(password, file, JOSE.JWE.to_record(jwe), jwk)
  def to_oct_file(password, file, jwe, jwk = %JOSE.JWK{}), do: to_oct_file(password, file, jwe, to_record(jwk))
  def to_oct_file(password, file, jwe, jwk), do: :jose_jwk.to_oct_file(password, file, jwe, jwk)

  @doc """
  Converts a `JOSE.JWK` into an octet key pair.
  """
  def to_okp(list) when is_list(list), do: for(element <- list, into: [], do: to_okp(element))
  def to_okp(jwk = %JOSE.JWK{}), do: to_okp(to_record(jwk))
  def to_okp(jwk), do: :jose_jwk.to_okp(jwk)

  @doc """
  Converts a `JOSE.JWK` into an OpenSSH key binary.
  """
  def to_openssh_key(list) when is_list(list), do: for(element <- list, into: [], do: to_openssh_key(element))
  def to_openssh_key(jwk = %JOSE.JWK{}), do: to_openssh_key(to_record(jwk))
  def to_openssh_key(jwk), do: :jose_jwk.to_openssh_key(jwk)

  @doc """
  Calls `to_openssh_key/1` on a `JOSE.JWK` and then writes the binary to file.
  """
  def to_openssh_key_file(file, jwk = %JOSE.JWK{}), do: to_openssh_key_file(file, to_record(jwk))
  def to_openssh_key_file(file, jwk), do: :jose_jwk.to_openssh_key_file(file, jwk)

  @doc """
  Converts a `JOSE.JWK` into a PEM (Privacy Enhanced Email) binary.
  """
  def to_pem(list) when is_list(list), do: for(element <- list, into: [], do: to_pem(element))
  def to_pem(jwk = %JOSE.JWK{}), do: to_pem(to_record(jwk))
  def to_pem(jwk), do: :jose_jwk.to_pem(jwk)

  @doc """
  Encrypts a `JOSE.JWK` into a PEM (Privacy Enhanced Email) encrypted binary using `password`.
  """
  def to_pem(password, list) when is_list(list), do: for(element <- list, into: [], do: to_pem(password, element))
  def to_pem(password, jwk = %JOSE.JWK{}), do: to_pem(password, to_record(jwk))
  def to_pem(password, jwk), do: :jose_jwk.to_pem(password, jwk)

  @doc """
  Calls `to_pem/1` on a `JOSE.JWK` and then writes the binary to file.
  """
  def to_pem_file(file, jwk = %JOSE.JWK{}), do: to_pem_file(file, to_record(jwk))
  def to_pem_file(file, jwk), do: :jose_jwk.to_pem_file(file, jwk)

  @doc """
  Calls `to_pem/2` on a `JOSE.JWK` and then writes the encrypted binary to file.
  """
  def to_pem_file(password, file, jwk = %JOSE.JWK{}), do: to_pem_file(password, file, to_record(jwk))
  def to_pem_file(password, file, jwk), do: :jose_jwk.to_pem_file(password, file, jwk)

  @doc """
  Converts a private `JOSE.JWK` into a public `JOSE.JWK`.

      iex> jwk_rsa = JOSE.JWK.generate_key({:rsa, 256})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_rsa,
        {:RSAPrivateKey, :"two-prime",
         89657271283923333213688956979801646886488725937927826421780028977595670900943,
         65537,
         49624301670095289515744590467755999498582844809776145284365095264133428741569,
         336111124810514302695156165996294214367,
         266748895426976520545002702829665062929,
         329628611699439793965634256329704106687,
         266443630200356088742496100410997365601,
         145084675516165292189647528713269147163, :asn1_NOVALUE}}}
      iex> JOSE.JWK.to_public(jwk_rsa)
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_rsa,
        {:RSAPublicKey,
         89657271283923333213688956979801646886488725937927826421780028977595670900943,
         65537}}}

  """
  def to_public(list) when is_list(list), do: for(element <- list, into: [], do: to_public(element))
  def to_public(jwk = %JOSE.JWK{}), do: to_public(to_record(jwk))
  def to_public(jwk), do: :jose_jwk.to_public(jwk) |> from_record()

  @doc """
  Calls `to_public/1` and then `to_file/2` on a `JOSE.JWK`.
  """
  def to_public_file(file, jwk = %JOSE.JWK{}), do: to_public_file(file, to_record(jwk))
  def to_public_file(file, jwk), do: :jose_jwk.to_public_file(file, jwk)

  @doc """
  Calls `to_public/1` and then `to_key/1` on a `JOSE.JWK`.
  """
  def to_public_key(list) when is_list(list), do: for(element <- list, into: [], do: to_public_key(element))
  def to_public_key(jwk = %JOSE.JWK{}), do: to_public_key(to_record(jwk))
  def to_public_key(jwk), do: :jose_jwk.to_public_key(jwk)

  @doc """
  Calls `to_public/1` and then `to_map/1` on a `JOSE.JWK`.
  """
  def to_public_map(list) when is_list(list), do: for(element <- list, into: [], do: to_public_map(element))
  def to_public_map(jwk = %JOSE.JWK{}), do: to_public_map(to_record(jwk))
  def to_public_map(jwk), do: :jose_jwk.to_public_map(jwk)

  @doc """
  Converts a `JOSE.JWK` into a map that can be used by `thumbprint/1` and `thumbprint/2`.
  """
  def to_thumbprint_map(list) when is_list(list), do: for(element <- list, into: [], do: to_thumbprint_map(element))
  def to_thumbprint_map(jwk = %JOSE.JWK{}), do: to_thumbprint_map(to_record(jwk))
  def to_thumbprint_map(jwk), do: :jose_jwk.to_thumbprint_map(jwk)

  ## API

  @doc """
  Decrypts the `encrypted` binary or map using the `jwk`.  See `JOSE.JWE.block_decrypt/2`.
  """
  def block_decrypt(encrypted, jwk = %JOSE.JWK{}), do: block_decrypt(encrypted, to_record(jwk))

  def block_decrypt(encrypted, {your_public_jwk = %JOSE.JWK{}, my_private_jwk}),
    do: block_decrypt(encrypted, {to_record(your_public_jwk), my_private_jwk})

  def block_decrypt(encrypted, {your_public_jwk, my_private_jwk = %JOSE.JWK{}}),
    do: block_decrypt(encrypted, {your_public_jwk, to_record(my_private_jwk)})

  def block_decrypt(encrypted, jwk) do
    case :jose_jwk.block_decrypt(encrypted, jwk) do
      {plain_text, jwe} when is_tuple(jwe) ->
        {plain_text, JOSE.JWE.from_record(jwe)}

      error ->
        error
    end
  end

  @doc """
  Encrypts the `plain_text` using the `jwk` and the default `jwe` based on the key type.  See `block_encrypt/3`.
  """
  def block_encrypt(plain_text, jwk = %JOSE.JWK{}), do: block_encrypt(plain_text, to_record(jwk))

  def block_encrypt(plain_text, {your_public_jwk = %JOSE.JWK{}, my_private_jwk}),
    do: block_encrypt(plain_text, {to_record(your_public_jwk), my_private_jwk})

  def block_encrypt(plain_text, {your_public_jwk, my_private_jwk = %JOSE.JWK{}}),
    do: block_encrypt(plain_text, {your_public_jwk, to_record(my_private_jwk)})

  def block_encrypt(plain_text, jwk), do: :jose_jwk.block_encrypt(plain_text, jwk)

  @doc """
  Encrypts the `plain_text` using the `jwk` and algorithms specified by the `jwe`.  See `JOSE.JWE.block_encrypt/3`.
  """
  def block_encrypt(plain_text, jwe = %JOSE.JWE{}, jwk), do: block_encrypt(plain_text, JOSE.JWE.to_record(jwe), jwk)
  def block_encrypt(plain_text, jwe, jwk = %JOSE.JWK{}), do: block_encrypt(plain_text, jwe, to_record(jwk))

  def block_encrypt(plain_text, jwe, {your_public_jwk = %JOSE.JWK{}, my_private_jwk}),
    do: block_encrypt(plain_text, jwe, {to_record(your_public_jwk), my_private_jwk})

  def block_encrypt(plain_text, jwe, {your_public_jwk, my_private_jwk = %JOSE.JWK{}}),
    do: block_encrypt(plain_text, jwe, {your_public_jwk, to_record(my_private_jwk)})

  def block_encrypt(plain_text, jwe, jwk), do: :jose_jwk.block_encrypt(plain_text, jwe, jwk)

  @doc """
  Returns a block encryptor map for the key type.
  """
  def block_encryptor(list) when is_list(list), do: for(element <- list, into: [], do: block_encryptor(element))
  def block_encryptor(jwk = %JOSE.JWK{}), do: block_encryptor(to_record(jwk))
  def block_encryptor(jwk), do: :jose_jwk.block_encryptor(jwk)

  @deprecated "Use JOSE.JWK.box_decrypt_ecdh_es/2 or JOSE.JWK.box_decrypt_ecdh_1pu/3 instead"
  def box_decrypt(encrypted, my_private_jwk = %JOSE.JWK{}), do: box_decrypt(encrypted, to_record(my_private_jwk))

  def box_decrypt(encrypted, {your_public_jwk = %JOSE.JWK{}, my_private_jwk}),
    do: box_decrypt(encrypted, {to_record(your_public_jwk), my_private_jwk})

  def box_decrypt(encrypted, {your_public_jwk, my_private_jwk = %JOSE.JWK{}}),
    do: box_decrypt(encrypted, {your_public_jwk, to_record(my_private_jwk)})

  def box_decrypt(encrypted, my_private_jwk) do
    case :jose_jwk.box_decrypt(encrypted, my_private_jwk) do
      {plain_text, jwe} when is_tuple(jwe) ->
        {plain_text, JOSE.JWE.from_record(jwe)}

      error ->
        error
    end
  end

  @deprecated "Use JOSE.JWK.box_decrypt_ecdh_es/2 or JOSE.JWK.box_encrypt_ecdh_1pu/3 instead"
  def box_encrypt(plain_text, other_public_jwk = %JOSE.JWK{}), do: box_encrypt(plain_text, to_record(other_public_jwk))

  def box_encrypt(plain_text, other_public_jwk) do
    case :jose_jwk.box_encrypt(plain_text, other_public_jwk) do
      {encrypted, my_private_jwk} when is_tuple(my_private_jwk) ->
        {encrypted, from_record(my_private_jwk)}

      error ->
        error
    end
  end

  @deprecated "Use JOSE.JWK.box_decrypt_ecdh_es/3 or JOSE.JWK.box_encrypt_ecdh_1pu/4 instead"
  def box_encrypt(plain_text, other_public_jwk = %JOSE.JWK{}, my_private_jwk),
    do: box_encrypt(plain_text, to_record(other_public_jwk), my_private_jwk)

  def box_encrypt(plain_text, other_public_jwk, my_private_jwk = %JOSE.JWK{}),
    do: box_encrypt(plain_text, other_public_jwk, to_record(my_private_jwk))

  def box_encrypt(plain_text, other_public_jwk, my_private_jwk),
    do: :jose_jwk.box_encrypt(plain_text, other_public_jwk, my_private_jwk)

  @deprecated "Use JOSE.JWK.box_decrypt_ecdh_es/4 or JOSE.JWK.box_encrypt_ecdh_1pu/5 instead"
  def box_encrypt(plain_text, jwe = %JOSE.JWE{}, other_public_jwk, my_private_jwk),
    do: box_encrypt(plain_text, JOSE.JWE.to_record(jwe), other_public_jwk, my_private_jwk)

  def box_encrypt(plain_text, jwe, other_public_jwk = %JOSE.JWK{}, my_private_jwk),
    do: box_encrypt(plain_text, jwe, to_record(other_public_jwk), my_private_jwk)

  def box_encrypt(plain_text, jwe, other_public_jwk, my_private_jwk = %JOSE.JWK{}),
    do: box_encrypt(plain_text, jwe, other_public_jwk, to_record(my_private_jwk))

  def box_encrypt(plain_text, jwe, other_public_jwk, my_private_jwk),
    do: :jose_jwk.box_encrypt(plain_text, jwe, other_public_jwk, my_private_jwk)

  @doc """
  ECDH-1PU Key Agreement decryption of the `encrypted` binary or map using `u_static_public_key` and `v_static_secret_key`.  See `box_encrypt_ecdh_1pu/3` and `JOSE.JWE.block_decrypt/2`.
  """
  def box_decrypt_ecdh_1pu(encrypted, u_static_public_key, v_static_secret_key) do
    u_static_public_key = maybe_to_record(u_static_public_key)
    v_static_secret_key = maybe_to_record(v_static_secret_key)

    case :jose_jwk.box_decrypt_ecdh_1pu(encrypted, u_static_public_key, v_static_secret_key) do
      {plain_text, jwe} when is_tuple(jwe) ->
        {plain_text, JOSE.JWE.from_record(jwe)}

      error ->
        error
    end
  end

  @doc """
  ECDH-1PU Key Agreement encryption of `plain_text` by generating an ephemeral secret key based on `v_static_public_key` and `u_static_secret_key` curve.  See `box_encrypt_ecdh_1pu/4`.

      # Alice (U) wants to send Bob (V) a secret message.
      # They have already shared their static public keys with one another through an unspecified channel:
      u_static_public_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "kty" => "OKP",
        "x" => "sz1JMMasNRLQfXIkvLTRaOu978QQu1roFKxBPKZdsC8"
      })
      v_static_public_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "kty" => "OKP",
        "x" => "EFvrJluQClNDvbIjcie4UADLfirR9Fk53rcSM5gibx4"
      })

      # WARNING: Do not share secret keys.  For reference purposes only, here is Alice's (U) static secret key that is used below:
      u_static_secret_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "d" => "SfYmE8aLpvX6Z0rZQVa5eBjLKeINUfSlu-_AcYJXCqQ",
        "kty" => "OKP",
        "x" => "sz1JMMasNRLQfXIkvLTRaOu978QQu1roFKxBPKZdsC8"
      })
      # WARNING: Do not share secret keys.  For reference purposes only, here is Bob's (V) static secret key that is used below:
      v_static_secret_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "d" => "8-SdA6TQ1mdFRC06U-R4-ah6YkeVcodtGuMNVngwlto",
        "kty" => "OKP",
        "x" => "EFvrJluQClNDvbIjcie4UADLfirR9Fk53rcSM5gibx4"
      })

      # Alice (U) uses Bob's (V) static public key along with Alice's (U) static secret key to generate an ephemeral secret key used to encrypt the message:
      iex> {enc_alice2bob_tuple, u_ephemeral_secret_key} = JOSE.JWK.box_encrypt_ecdh_1pu("secret message", v_static_public_key, u_static_secret_key)
      {{%{alg: :jose_jwe_alg_ecdh_1pu, enc: :jose_jwe_enc_aes},
        %{
          "ciphertext" => "Ry0I26YMnaHSmNQ86EY",
          "encrypted_key" => "",
          "iv" => "swK08mi6cjJ1aUQF",
          "protected" => "eyJhbGciOiJFQ0RILTFQVSIsImFwdSI6IjAybXM0OF90ZmpqQXk4TXJMeDV1LW1yaVZwT24tOFpNVmtDTXlIbEtBTjAiLCJhcHYiOiJrNDR0QzE4U2tYTUVXektFQ0JSZ3VhMHpaX01MRHY1VTQ2TWNueVl6ajBBIiwiZW5jIjoiQTEyOEdDTSIsImVwayI6eyJjcnYiOiJYMjU1MTkiLCJrdHkiOiJPS1AiLCJ4IjoiX3JBS1l6WThJczFSRXJQTTVod29OSEZjdWZQOHpiYXpVaTN5QXJ3WnVDVSJ9LCJza2lkIjoieXNZVzZiUmRpVW1ST0NWa09oSmtWMV9JX0VEM1dESzBIN2tkbU5GelNYSSJ9",
          "tag" => "-6PitRlVuXk5HT3g_y6Uxw"
        }},
       %JOSE.JWK{
         keys: :undefined,
         kty: {:jose_jwk_kty_okp_x25519,
          <<30, 250, 220, 248, 158, 207, 86, 211, 254, 196, 78, 125, 132, 228, 186, 20, 253, 56, 226, 29, 191, 220, 131, 114, 44, 253, 72, 117, 25, 112, 209, 175, 254, 176, 10, 99, 54, 60, 34, 205, 81, 18, 179, 204, 230, 28, 40, 52, 113, 92, 185, 243, 252, 205, 182, 179, 82, 45, 242, 2, 188, 25, 184, 37>>},
         fields: %{}
       }}

      # Alice (U) compacts the encrypted message and sends it to Bob (V), which contains Alice's (U) ephemeral public key:
      iex> enc_alice2bob_binary = JOSE.JWE.compact(enc_alice2bob_tuple) |> elem(1)
      "eyJhbGciOiJFQ0RILTFQVSIsImFwdSI6IjAybXM0OF90ZmpqQXk4TXJMeDV1LW1yaVZwT24tOFpNVmtDTXlIbEtBTjAiLCJhcHYiOiJrNDR0QzE4U2tYTUVXektFQ0JSZ3VhMHpaX01MRHY1VTQ2TWNueVl6ajBBIiwiZW5jIjoiQTEyOEdDTSIsImVwayI6eyJjcnYiOiJYMjU1MTkiLCJrdHkiOiJPS1AiLCJ4IjoiX3JBS1l6WThJczFSRXJQTTVod29OSEZjdWZQOHpiYXpVaTN5QXJ3WnVDVSJ9LCJza2lkIjoieXNZVzZiUmRpVW1ST0NWa09oSmtWMV9JX0VEM1dESzBIN2tkbU5GelNYSSJ9..swK08mi6cjJ1aUQF.Ry0I26YMnaHSmNQ86EY.-6PitRlVuXk5HT3g_y6Uxw"

      # Bob (V) can then decrypt the encrypted message using Alice's (U) static public key along with Bob's (V) static secret key:
      iex> JOSE.JWK.box_decrypt_ecdh_1pu(enc_alice2bob_binary, u_static_public_key, v_static_secret_key)
      {"secret message",
       %JOSE.JWE{
         alg: {:jose_jwe_alg_ecdh_1pu,
          {:jose_jwe_alg_ecdh_1pu,
           {:jose_jwk, :undefined,
            {:jose_jwk_kty_okp_x25519,
             <<254, 176, 10, 99, 54, 60, 34, 205, 81, 18, 179, 204, 230, 28, 40, 52, 113, 92, 185, 243, 252, 205, 182, 179, 82, 45, 242, 2, 188, 25, 184, 37>>}, %{}},
           <<211, 105, 172, 227, 207, 237, 126, 56, 192, 203, 195, 43, 47, 30, 110, 250, 106, 226, 86, 147, 167, 251, 198, 76, 86, 64, 140, 200, 121, 74, 0, 221>>,
           <<147, 142, 45, 11, 95, 18, 145, 115, 4, 91, 50, 132, 8, 20, 96, 185, 173, 51, 103, 243, 11, 14, 254, 84, 227, 163, 28, 159, 38, 51, 143, 64>>, :undefined, :undefined, :undefined, :undefined}},
         enc: {:jose_jwe_enc_aes,
          {:jose_jwe_enc_aes, {:aes_gcm, 128}, 128, 16, 12, :undefined, :undefined, :undefined, :undefined}},
         zip: :undefined,
         fields: %{"skid" => "ysYW6bRdiUmROCVkOhJkV1_I_ED3WDK0H7kdmNFzSXI"}
       }}

  """
  def box_encrypt_ecdh_1pu(plain_text, v_static_public_key, u_static_secret_key) do
    v_static_public_key = maybe_to_record(v_static_public_key)
    u_static_secret_key = maybe_to_record(u_static_secret_key)
    {encrypted, u_ephemeral_secret_key} = :jose_jwk.box_encrypt_ecdh_1pu(plain_text, v_static_public_key, u_static_secret_key)
    {encrypted, from_record(u_ephemeral_secret_key)}
  end

  @doc """
  ECDH-1PU Key Agreement encryption of `plain_text` using `v_static_public_key`, `u_static_secret_key`, `u_ephemeral_secret_key`, and a derived `jwe` based on the input key types.  See `box_encrypt_ecdh_1pu/5`.
  """
  def box_encrypt_ecdh_1pu(plain_text, v_static_public_key, u_static_secret_key, u_ephemeral_secret_key) do
    v_static_public_key = maybe_to_record(v_static_public_key)
    u_static_secret_key = maybe_to_record(u_static_secret_key)
    u_ephemeral_secret_key = maybe_to_record(u_ephemeral_secret_key)
    :jose_jwk.box_encrypt_ecdh_1pu(plain_text, v_static_public_key, u_static_secret_key, u_ephemeral_secret_key)
  end

  @doc """
  ECDH-1PU Key Agreement encryption of `plain_text` using `v_static_public_key`, `u_static_secret_key`, `u_ephemeral_secret_key`, and the algorithms specified by the `jwe`.
  """
  def box_encrypt_ecdh_1pu(plain_text, jwe, v_static_public_key, u_static_secret_key, u_ephemeral_secret_key) do
    jwe =
      case jwe do
        %JOSE.JWE{} -> JOSE.JWE.to_record(jwe)
        {metadata, jwe = %JOSE.JWE{}} -> {metadata, JOSE.JWE.to_record(jwe)}
        _ -> jwe
      end

    v_static_public_key = maybe_to_record(v_static_public_key)
    u_static_secret_key = maybe_to_record(u_static_secret_key)
    u_ephemeral_secret_key = maybe_to_record(u_ephemeral_secret_key)
    :jose_jwk.box_encrypt_ecdh_1pu(plain_text, jwe, v_static_public_key, u_static_secret_key, u_ephemeral_secret_key)
  end

  @doc """
  ECDH-ES Key Agreement decryption of the `encrypted` binary or map using `v_static_secret_key`.  See `box_encrypt_ecdh_es/2` and `JOSE.JWE.block_decrypt/2`.
  """
  def box_decrypt_ecdh_es(encrypted, v_static_secret_key) do
    v_static_secret_key = maybe_to_record(v_static_secret_key)

    case :jose_jwk.box_decrypt_ecdh_es(encrypted, v_static_secret_key) do
      {plain_text, jwe} when is_tuple(jwe) ->
        {plain_text, JOSE.JWE.from_record(jwe)}

      error ->
        error
    end
  end

  @doc """
  ECDH-ES Key Agreement encryption of `plain_text` by generating an ephemeral secret key based on `v_static_public_key` curve.  See `box_encrypt_ecdh_es/3`.

      # Alice (U) wants to send Bob (V) a secret message.
      # Bob (V) has already shared their static public key with Alice (U) through an unspecified channel:
      v_static_public_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "kty" => "OKP",
        "x" => "EFvrJluQClNDvbIjcie4UADLfirR9Fk53rcSM5gibx4"
      })

      # WARNING: Do not share secret keys.  For reference purposes only, here is Bob's (V) static secret key that is used below:
      v_static_secret_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "d" => "8-SdA6TQ1mdFRC06U-R4-ah6YkeVcodtGuMNVngwlto",
        "kty" => "OKP",
        "x" => "EFvrJluQClNDvbIjcie4UADLfirR9Fk53rcSM5gibx4"
      })

      # Alice (U) uses Bob's (V) static public key to generate an ephemeral secret key used to encrypt the message:
      iex> {enc_alice2bob_tuple, u_ephemeral_secret_key} = JOSE.JWK.box_encrypt_ecdh_es("secret message", v_static_public_key)
      {{%{alg: :jose_jwe_alg_ecdh_es, enc: :jose_jwe_enc_aes},
        %{
          "ciphertext" => "AhQ3W31vvypJNubhD2U",
          "encrypted_key" => "",
          "iv" => "YjojFg2wPnk5JmMG",
          "protected" => "eyJhbGciOiJFQ0RILUVTIiwiYXB1IjoiRHNVZlFNdUEybnZqMnRzTVp1N0o5YUFEekw3akUyRFUzRWFvVTh3YmJlVSIsImFwdiI6Ims0NHRDMThTa1hNRVd6S0VDQlJndWEwelpfTUxEdjVVNDZNY255WXpqMEEiLCJlbmMiOiJBMTI4R0NNIiwiZXBrIjp7ImNydiI6IlgyNTUxOSIsImt0eSI6Ik9LUCIsIngiOiJwRkg3YXZYQlFvUjBoZnNsUm1HaVJxREpxdUVjS0w0eTU4TEZocnc1S3dFIn19",
          "tag" => "pwRKlhhXEPjwZg13455U5Q"
        }},
       %JOSE.JWK{
         keys: :undefined,
         kty: {:jose_jwk_kty_okp_x25519,
          <<68, 178, 96, 158, 87, 182, 26, 216, 211, 230, 115, 239, 145, 244, 93, 4, 79, 231, 189, 5, 96, 164, 241, 132, 123, 151, 253, 19, 109, 246, 211, 86, 164, 81, 251, 106, 245, 193, 66, 132, 116, 133, 251, 37, 70, 97, 162, 70, 160, 201, 170, 225, 28, 40, 190, 50, 231, 194, 197, 134, 188, 57, 43, 1>>},
         fields: %{}
       }}

      # Alice (U) compacts the encrypted message and sends it to Bob (V), which contains Alice's (U) ephemeral public key:
      iex> enc_alice2bob_binary = JOSE.JWE.compact(enc_alice2bob_tuple) |> elem(1)
      "eyJhbGciOiJFQ0RILUVTIiwiYXB1IjoiRHNVZlFNdUEybnZqMnRzTVp1N0o5YUFEekw3akUyRFUzRWFvVTh3YmJlVSIsImFwdiI6Ims0NHRDMThTa1hNRVd6S0VDQlJndWEwelpfTUxEdjVVNDZNY255WXpqMEEiLCJlbmMiOiJBMTI4R0NNIiwiZXBrIjp7ImNydiI6IlgyNTUxOSIsImt0eSI6Ik9LUCIsIngiOiJwRkg3YXZYQlFvUjBoZnNsUm1HaVJxREpxdUVjS0w0eTU4TEZocnc1S3dFIn19..YjojFg2wPnk5JmMG.AhQ3W31vvypJNubhD2U.pwRKlhhXEPjwZg13455U5Q"

      # Bob (V) can then decrypt the encrypted message with Bob's (V) static secret key:
      iex> JOSE.JWK.box_decrypt_ecdh_es(enc_alice2bob_binary, v_static_secret_key)
      {"secret message",
       %JOSE.JWE{
         alg: {:jose_jwe_alg_ecdh_es,
          {:jose_jwe_alg_ecdh_es,
           {:jose_jwk, :undefined,
            {:jose_jwk_kty_okp_x25519,
             <<164, 81, 251, 106, 245, 193, 66, 132, 116, 133, 251, 37, 70, 97, 162, 70, 160, 201, 170, 225, 28, 40, 190, 50, 231, 194, 197, 134, 188, 57, 43, 1>>}, %{}},
           <<14, 197, 31, 64, 203, 128, 218, 123, 227, 218, 219, 12, 102, 238, 201, 245, 160, 3, 204, 190, 227, 19, 96, 212, 220, 70, 168, 83, 204, 27, 109, 229>>,
           <<147, 142, 45, 11, 95, 18, 145, 115, 4, 91, 50, 132, 8, 20, 96, 185, 173, 51, 103, 243, 11, 14, 254, 84, 227, 163, 28, 159, 38, 51, 143, 64>>, :undefined, :undefined, :undefined, :undefined}},
         enc: {:jose_jwe_enc_aes,
          {:jose_jwe_enc_aes, {:aes_gcm, 128}, 128, 16, 12, :undefined, :undefined, :undefined, :undefined}},
         zip: :undefined,
         fields: %{}
       }}

  """
  def box_encrypt_ecdh_es(plain_text, v_static_public_key) do
    v_static_public_key = maybe_to_record(v_static_public_key)
    {encrypted, u_ephemeral_secret_key} = :jose_jwk.box_encrypt_ecdh_es(plain_text, v_static_public_key)
    {encrypted, from_record(u_ephemeral_secret_key)}
  end

  @doc """
  ECDH-ES Key Agreement encryption of `plain_text` using `v_static_public_key`, `u_ephemeral_secret_key`, and a derived `jwe` based on the input key types.  See `box_encrypt_ecdh_es/4`.
  """
  def box_encrypt_ecdh_es(plain_text, v_static_public_key, u_ephemeral_secret_key) do
    v_static_public_key = maybe_to_record(v_static_public_key)
    u_ephemeral_secret_key = maybe_to_record(u_ephemeral_secret_key)
    :jose_jwk.box_encrypt_ecdh_es(plain_text, v_static_public_key, u_ephemeral_secret_key)
  end

  @doc """
  ECDH-ES Key Agreement encryption of `plain_text` using `v_static_public_key`, `u_ephemeral_secret_key`, and the algorithms specified by the `jwe`.
  """
  def box_encrypt_ecdh_es(plain_text, jwe, v_static_public_key, u_ephemeral_secret_key) do
    jwe =
      case jwe do
        %JOSE.JWE{} -> JOSE.JWE.to_record(jwe)
        {metadata, jwe = %JOSE.JWE{}} -> {metadata, JOSE.JWE.to_record(jwe)}
        _ -> jwe
      end

    v_static_public_key = maybe_to_record(v_static_public_key)
    u_ephemeral_secret_key = maybe_to_record(u_ephemeral_secret_key)
    :jose_jwk.box_encrypt_ecdh_es(plain_text, jwe, v_static_public_key, u_ephemeral_secret_key)
  end

  @doc """
  ECDH-SS Key Agreement decryption of the `encrypted` binary or map using `v_static_secret_key`.  See `box_encrypt_ecdh_ss/2` and `JOSE.JWE.block_decrypt/2`.
  """
  def box_decrypt_ecdh_ss(encrypted, v_static_secret_key) do
    v_static_secret_key = maybe_to_record(v_static_secret_key)

    case :jose_jwk.box_decrypt_ecdh_ss(encrypted, v_static_secret_key) do
      {plain_text, jwe} when is_tuple(jwe) ->
        {plain_text, JOSE.JWE.from_record(jwe)}

      error ->
        error
    end
  end

  @doc """
  ECDH-SS Key Agreement encryption of `plain_text` by generating a static secret key based on `v_static_public_key` curve.  See `box_encrypt_ecdh_ss/3`.

      # Alice (U) wants to send Bob (V) a secret message.
      # Bob (V) has already shared their static public key with Alice (U) through an unspecified channel:
      v_static_public_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "kty" => "OKP",
        "x" => "EFvrJluQClNDvbIjcie4UADLfirR9Fk53rcSM5gibx4"
      })

      # WARNING: Do not share secret keys.  For reference purposes only, here is Alice's (U) static secret key that is used below:
      u_static_secret_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "d" => "SfYmE8aLpvX6Z0rZQVa5eBjLKeINUfSlu-_AcYJXCqQ",
        "kty" => "OKP",
        "x" => "sz1JMMasNRLQfXIkvLTRaOu978QQu1roFKxBPKZdsC8"
      })
      # WARNING: Do not share secret keys.  For reference purposes only, here is Bob's (V) static secret key that is used below:
      v_static_secret_key = JOSE.JWK.from(%{
        "crv" => "X25519",
        "d" => "8-SdA6TQ1mdFRC06U-R4-ah6YkeVcodtGuMNVngwlto",
        "kty" => "OKP",
        "x" => "EFvrJluQClNDvbIjcie4UADLfirR9Fk53rcSM5gibx4"
      })

      # Alice (U) uses Bob's (V) static public key and Alice's (U) static secret key to encrypt the message:
      iex> enc_alice2bob_tuple = JOSE.JWK.box_encrypt_ecdh_ss("secret message", v_static_public_key, u_static_secret_key)
      {%{alg: :jose_jwe_alg_ecdh_ss, enc: :jose_jwe_enc_aes}, %{
         "ciphertext" => "yug6TzZUgAEt0DAPNnw",
         "encrypted_key" => "",
         "iv" => "f3rEdLgkLLXqDjno",
         "protected" => "eyJhbGciOiJFQ0RILVNTIiwiYXB1IjoieG1RUUNGbzk5OF9TVzhkMy1vQnRMX0ZfbGtBd1E0Y1J0VHZSRWtlUjBaVTdNR2Q0SkZqSHczR2t1dVdXNFI5YzJDSWkzQzQtQW84NFRzR2x5c0JOMVEiLCJhcHYiOiJrNDR0QzE4U2tYTUVXektFQ0JSZ3VhMHpaX01MRHY1VTQ2TWNueVl6ajBBIiwiZW5jIjoiQTEyOEdDTSIsInNwayI6eyJjcnYiOiJYMjU1MTkiLCJrdHkiOiJPS1AiLCJ4Ijoic3oxSk1NYXNOUkxRZlhJa3ZMVFJhT3U5NzhRUXUxcm9GS3hCUEtaZHNDOCJ9fQ",
         "tag" => "gAszp6UPSNozXeoqk428Og"
       }}

      # Alice (U) compacts the encrypted message and sends it to Bob (V), which contains Alice's (U) static public key:
      iex> enc_alice2bob_binary = JOSE.JWE.compact(enc_alice2bob_tuple) |> elem(1)
      "eyJhbGciOiJFQ0RILVNTIiwiYXB1IjoieG1RUUNGbzk5OF9TVzhkMy1vQnRMX0ZfbGtBd1E0Y1J0VHZSRWtlUjBaVTdNR2Q0SkZqSHczR2t1dVdXNFI5YzJDSWkzQzQtQW84NFRzR2x5c0JOMVEiLCJhcHYiOiJrNDR0QzE4U2tYTUVXektFQ0JSZ3VhMHpaX01MRHY1VTQ2TWNueVl6ajBBIiwiZW5jIjoiQTEyOEdDTSIsInNwayI6eyJjcnYiOiJYMjU1MTkiLCJrdHkiOiJPS1AiLCJ4Ijoic3oxSk1NYXNOUkxRZlhJa3ZMVFJhT3U5NzhRUXUxcm9GS3hCUEtaZHNDOCJ9fQ..f3rEdLgkLLXqDjno.yug6TzZUgAEt0DAPNnw.gAszp6UPSNozXeoqk428Og"

      # Bob (V) can then decrypt the encrypted message with Bob's (V) static secret key:
      iex> JOSE.JWK.box_decrypt_ecdh_ss(enc_alice2bob_binary, v_static_secret_key)
      {"secret message",
       %JOSE.JWE{
         alg: {:jose_jwe_alg_ecdh_ss,
          {:jose_jwe_alg_ecdh_ss,
           {:jose_jwk, :undefined,
            {:jose_jwk_kty_okp_x25519,
             <<179, 61, 73, 48, 198, 172, 53, 18, 208, 125, 114, 36, 188, 180, 209, 104, 235, 189, 239, 196, 16, 187, 90, 232, 20, 172, 65, 60, 166, 93, 176, 47>>}, %{}},
           <<198, 100, 16, 8, 90, 61, 247, 207, 210, 91, 199, 119, 250, 128, 109, 47, 241, 127, 150, 64, 48, 67, 135, 17, 181, 59, 209, 18, 71, 145, 209, 149, 59, 48, 103, 120, 36, 88, 199, 195, 113, 164, 186, 229, 150, 225, 31, 92, 216, 34, 34, 220, 46, 62, 2, 143, 56, 78, 193, 165, 202, 192, 77, 213>>,
           <<147, 142, 45, 11, 95, 18, 145, 115, 4, 91, 50, 132, 8, 20, 96, 185, 173, 51, 103, 243, 11, 14, 254, 84, 227, 163, 28, 159, 38, 51, 143, 64>>,
           :undefined, :undefined, :undefined, :undefined}},
         enc: {:jose_jwe_enc_aes,
          {:jose_jwe_enc_aes, {:aes_gcm, 128}, 128, 16, 12, :undefined, :undefined,
           :undefined, :undefined}},
         zip: :undefined,
         fields: %{}
       }}

  """
  def box_encrypt_ecdh_ss(plain_text, v_static_public_key) do
    v_static_public_key = maybe_to_record(v_static_public_key)
    {encrypted, u_static_secret_key} = :jose_jwk.box_encrypt_ecdh_ss(plain_text, v_static_public_key)
    {encrypted, from_record(u_static_secret_key)}
  end

  @doc """
  ECDH-SS Key Agreement encryption of `plain_text` using `v_static_public_key`, `u_static_secret_key`, and a derived `jwe` based on the input key types.  See `box_encrypt_ecdh_ss/4`.
  """
  def box_encrypt_ecdh_ss(plain_text, v_static_public_key, u_static_secret_key) do
    v_static_public_key = maybe_to_record(v_static_public_key)
    u_static_secret_key = maybe_to_record(u_static_secret_key)
    :jose_jwk.box_encrypt_ecdh_ss(plain_text, v_static_public_key, u_static_secret_key)
  end

  @doc """
  ECDH-SS Key Agreement encryption of `plain_text` using `v_static_public_key`, `u_static_secret_key`, and the algorithms specified by the `jwe`.
  """
  def box_encrypt_ecdh_ss(plain_text, jwe, v_static_public_key, u_static_secret_key) do
    jwe =
      case jwe do
        %JOSE.JWE{} -> JOSE.JWE.to_record(jwe)
        {metadata, jwe = %JOSE.JWE{}} -> {metadata, JOSE.JWE.to_record(jwe)}
        _ -> jwe
      end

    v_static_public_key = maybe_to_record(v_static_public_key)
    u_static_secret_key = maybe_to_record(u_static_secret_key)
    :jose_jwk.box_encrypt_ecdh_ss(plain_text, jwe, v_static_public_key, u_static_secret_key)
  end

  @doc """
  Generates a new `JOSE.JWK` based on another `JOSE.JWK` or from initialization params provided.

  Passing another `JOSE.JWK` results in different behavior depending on the `"kty"`:

    * `"EC"` - uses the same named curve to generate a new key
    * `"oct"` - uses the byte size to generate a new key
    * `"OKP"` - uses the same named curve to generate a new key
    * `"RSA"` - uses the same modulus and exponent sizes to generate a new key

  The following initialization params may also be used:

    * `{:ec, "secp256k1", "P-256" | "P-384" | "P-521"}` - generates an `"EC"` key using the `"secp256k1"`, `"P-256"`, `"P-384"`, or `"P-521"` curves
    * `{:oct, bytes}` - generates an `"oct"` key made of a random `bytes` number of bytes
    * `{:okp, :Ed25519 | :Ed25519ph | :Ed448 | :Ed448ph | :X25519 | :X448}` - generates an `"OKP"` key using the specified EdDSA or ECDH edwards curve
    * `{:rsa, modulus_size} | {:rsa, modulus_size, exponent_size}` - generates an `"RSA"` key using the `modulus_size` and `exponent_size`

  """
  def generate_key(jwk = %JOSE.JWK{}), do: jwk |> to_record() |> generate_key()
  def generate_key(parameters), do: :jose_jwk.generate_key(parameters) |> from_record()

  @doc """
  Merges map on right into map on left.
  """
  def merge(left = %JOSE.JWK{}, right), do: merge(left |> to_record(), right)
  def merge(left, right = %JOSE.JWK{}), do: merge(left, right |> to_record())
  def merge(left, right), do: :jose_jwk.merge(left, right) |> from_record()

  @doc """
  Computes the shared secret between two keys.  Currently only works for `"EC"` keys and `"OKP"` keys with `"crv"` set to `"X25519"` or `"X448"`.
  """
  def shared_secret(your_jwk = %JOSE.JWK{}, my_jwk), do: shared_secret(to_record(your_jwk), my_jwk)
  def shared_secret(your_jwk, my_jwk = %JOSE.JWK{}), do: shared_secret(your_jwk, to_record(my_jwk))
  def shared_secret(your_jwk, my_jwk), do: :jose_jwk.shared_secret(your_jwk, my_jwk)

  @doc """
  Signs the `plain_text` using the `jwk` and the default signer algorithm `jws` for the key type.  See `sign/3`.
  """
  def sign(plain_text, jwk = %JOSE.JWK{}), do: sign(plain_text, to_record(jwk))

  def sign(plain_text, key_list) when is_list(key_list) do
    keys =
      for key <- key_list, into: [] do
        case key do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(key)

          _ ->
            key
        end
      end

    :jose_jwk.sign(plain_text, keys)
  end

  def sign(plain_text, jwk), do: :jose_jwk.sign(plain_text, jwk)

  @doc """
  Signs the `plain_text` using the `jwk` and the algorithm specified by the `jws`.  See `JOSE.JWS.sign/3`.
  """
  def sign(plain_text, jws = %JOSE.JWS{}, jwk), do: sign(plain_text, JOSE.JWS.to_record(jws), jwk)
  def sign(plain_text, jws, jwk = %JOSE.JWK{}), do: sign(plain_text, jws, to_record(jwk))

  def sign(plain_text, signer_list, key_list)
      when is_list(signer_list) and is_list(key_list) and length(signer_list) === length(key_list) do
    signers =
      for signer <- signer_list, into: [] do
        case signer do
          %JOSE.JWS{} ->
            JOSE.JWS.to_record(signer)

          _ ->
            signer
        end
      end

    keys =
      for key <- key_list, into: [] do
        case key do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(key)

          _ ->
            key
        end
      end

    :jose_jwk.sign(plain_text, signers, keys)
  end

  def sign(plain_text, jws, key_list) when is_list(key_list) and not is_list(jws) do
    keys =
      for key <- key_list, into: [] do
        case key do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(key)

          _ ->
            key
        end
      end

    :jose_jwk.sign(plain_text, jws, keys)
  end

  def sign(plain_text, jws, jwk), do: :jose_jwk.sign(plain_text, jws, jwk)

  @doc """
  Returns a signer map for the key type.
  """
  def signer(list) when is_list(list), do: for(element <- list, into: [], do: signer(element))
  def signer(jwk = %JOSE.JWK{}), do: signer(to_record(jwk))
  def signer(jwk), do: :jose_jwk.signer(jwk)

  @doc """
  Returns the unique thumbprint for a `JOSE.JWK` using the `:sha256` digest type.  See `thumbprint/2`.
  """
  def thumbprint(list) when is_list(list), do: for(element <- list, into: [], do: thumbprint(element))
  def thumbprint(jwk = %JOSE.JWK{}), do: thumbprint(to_record(jwk))
  def thumbprint(jwk), do: :jose_jwk.thumbprint(jwk)

  @doc """
  Returns the unique thumbprint for a `JOSE.JWK` using the `digest_type`.

      # let's define two different keys that will have the same thumbprint
      jwk1 = JOSE.JWK.from_oct("secret")
      jwk2 = JOSE.JWK.from(%{ "use" => "sig", "k" => "c2VjcmV0", "kty" => "oct" })

      iex> JOSE.JWK.thumbprint(jwk1)
      "DWBh0SEIAPYh1x5uvot4z3AhaikHkxNJa3Ada2fT-Cg"
      iex> JOSE.JWK.thumbprint(jwk2)
      "DWBh0SEIAPYh1x5uvot4z3AhaikHkxNJa3Ada2fT-Cg"
      iex> JOSE.JWK.thumbprint(:md5, jwk1)
      "Kldz8k5PQm7y1E3aNBlMiA"
      iex> JOSE.JWK.thumbprint(:md5, jwk2)
      "Kldz8k5PQm7y1E3aNBlMiA"

  See JSON Web Key (JWK) Thumbprint [RFC 7638](https://tools.ietf.org/html/rfc7638) for more information.
  """
  def thumbprint(digest_type, list) when is_list(list), do: for(element <- list, into: [], do: thumbprint(digest_type, element))
  def thumbprint(digest_type, jwk = %JOSE.JWK{}), do: thumbprint(digest_type, to_record(jwk))
  def thumbprint(digest_type, jwk), do: :jose_jwk.thumbprint(digest_type, jwk)

  @doc """
  Returns a verifier algorithm list for the key type.
  """
  def verifier(list) when is_list(list), do: for(element <- list, into: [], do: verifier(element))
  def verifier(jwk = %JOSE.JWK{}), do: verifier(to_record(jwk))
  def verifier(jwk), do: :jose_jwk.verifier(jwk)

  @doc """
  Verifies the `signed` using the `jwk`.  See `JOSE.JWS.verify_strict/3`.
  """
  def verify(signed, jwk = %JOSE.JWK{}), do: verify(signed, to_record(jwk))

  def verify(signed, jwk = [%JOSE.JWK{} | _]) do
    verify(
      signed,
      for k <- jwk do
        case k do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(k)

          _ ->
            k
        end
      end
    )
  end

  def verify(signed, jwk) do
    try do
      case :jose_jwk.verify(signed, jwk) do
        {verified, payload, jws} when is_tuple(jws) ->
          {verified, payload, JOSE.JWS.from_record(jws)}

        list when is_list(list) ->
          for {jwk, verifications} <- list do
            {JOSE.JWK.from_record(jwk),
             Enum.map(verifications, fn
               {verified, jwt, jws} when is_tuple(jwt) and is_tuple(jws) ->
                 {verified, from_record(jwt), JOSE.JWS.from_record(jws)}

               other ->
                 other
             end)}
          end

        error ->
          error
      end
    catch
      class, reason ->
        {class, reason}
    end
  end

  @doc """
  Verifies the `signed` using the `jwk` and whitelists the `"alg"` using `allow`.  See `JOSE.JWS.verify/2`.
  """
  def verify_strict(signed, allow, jwk = %JOSE.JWK{}), do: verify_strict(signed, allow, to_record(jwk))

  def verify_strict(signed, allow, jwk = [%JOSE.JWK{} | _]) do
    verify_strict(
      signed,
      allow,
      for k <- jwk do
        case k do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(k)

          _ ->
            k
        end
      end
    )
  end

  def verify_strict(signed, allow, jwk) do
    try do
      case :jose_jwk.verify_strict(signed, allow, jwk) do
        {verified, payload, jws} when is_tuple(jws) ->
          {verified, payload, JOSE.JWS.from_record(jws)}

        list when is_list(list) ->
          for {jwk, verifications} <- list do
            {JOSE.JWK.from_record(jwk),
             Enum.map(verifications, fn
               {verified, jwt, jws} when is_tuple(jwt) and is_tuple(jws) ->
                 {verified, from_record(jwt), JOSE.JWS.from_record(jws)}

               other ->
                 other
             end)}
          end

        error ->
          error
      end
    catch
      class, reason ->
        {class, reason}
    end
  end
end
