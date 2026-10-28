require Record

defmodule JOSE.JWT do
  @moduledoc ~S"""
  JWT stands for JSON Web Token which is defined in [RFC 7519](https://tools.ietf.org/html/rfc7519).

  ## Encryption Examples

  ## Signature Examples

  All of the example keys generated below can be found here: [https://gist.github.com/potatosalad/925a8b74d85835e285b9](https://gist.github.com/potatosalad/925a8b74d85835e285b9)

  See `JOSE.JWS` for more Signature examples.  For security purposes, `verify_strict/3` is recommended over `verify/2`.

  ### HS256

      # let's generate the key we'll use below and define our jwt
      jwk_hs256 = JOSE.JWK.generate_key({:oct, 16})
      jwt       = %{ "test" => true }

      # HS256
      iex> signed_hs256 = JOSE.JWT.sign(jwk_hs256, %{ "alg" => "HS256" }, jwt) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0ZXN0Ijp0cnVlfQ.XYsFJDhfBZCAKnEZjR0WWd1l1ZPDD4bYpZYMHizexfQ"
      # verify_strict/3 is recommended over verify/2
      iex> JOSE.JWT.verify_strict(jwk_hs256, ["HS256"], signed_hs256)
      {true, %JOSE.JWT{fields: %{"test" => true}},
       %JOSE.JWS{alg: {:jose_jws_alg_hmac, {:jose_jws_alg_hmac, :sha256}},
        b64: :undefined, fields: %{"typ" => "JWT"}}}
      # verify/2 returns the same thing without "alg" whitelisting
      iex> JOSE.JWT.verify(jwk_hs256, signed_hs256)
      {true, %JOSE.JWT{fields: %{"test" => true}},
       %JOSE.JWS{alg: {:jose_jws_alg_hmac, {:jose_jws_alg_hmac, :sha256}},
        b64: :undefined, fields: %{"typ" => "JWT"}}}

      # the default signing algorithm is also "HS256" based on the type of jwk used
      iex> signed_hs256 == JOSE.JWT.sign(jwk_hs256, jwt) |> JOSE.JWS.compact |> elem(1)
      true

  """

  record = Record.extract(:jose_jwt, from_lib: "jose/include/jose_jwt.hrl")
  keys = :lists.map(&elem(&1, 0), record)
  vals = :lists.map(&{&1, [], nil}, keys)
  pairs = :lists.zip(keys, vals)

  defstruct keys
  @type t :: %__MODULE__{}

  @doc """
  Converts a `JOSE.JWT` struct to a `:jose_jwt` record.

  This also works for converting a list of `JOSE.JWT` structs to a list of `:jose_jwt` records.
  """
  @spec to_record(t()) :: tuple()
  @spec to_record([t()]) :: [tuple()]
  def to_record(jose_jwt)

  def to_record(%JOSE.JWT{unquote_splicing(pairs)}) do
    {:jose_jwt, unquote_splicing(vals)}
  end

  def to_record(list) when is_list(list), do: for(element <- list, into: [], do: to_record(element))

  @doc """
  Converts a `:jose_jwt` record into a `JOSE.JWT`.

  This also works for converting a list of `:jose_jwt` records into a list of `JOSE.JWT` structs.
  """
  @spec from_record(tuple()) :: t()
  @spec from_record([tuple()]) :: [t()]
  def from_record(jose_jwt)

  def from_record({:jose_jwt, unquote_splicing(vals)}) do
    %JOSE.JWT{unquote_splicing(pairs)}
  end

  def from_record(list) when is_list(list), do: for(element <- list, into: [], do: from_record(element))

  ## Decode API

  @doc """
  Converts a binary or map into a `JOSE.JWT`.

      iex> JOSE.JWT.from(%{ "test" => true })
      %JOSE.JWT{fields: %{"test" => true}}
      iex> JOSE.JWT.from("{\"test\":true}")
      %JOSE.JWT{fields: %{"test" => true}}

  """
  def from(list) when is_list(list), do: for(element <- list, into: [], do: from(element))
  def from(jwt = %JOSE.JWT{}), do: from(to_record(jwt))
  def from(any), do: :jose_jwt.from(any) |> from_record()

  @doc """
  Converts a binary into a `JOSE.JWT`.
  """
  def from_binary(list) when is_list(list), do: for(element <- list, into: [], do: from_binary(element))
  def from_binary(binary), do: :jose_jwt.from_binary(binary) |> from_record()

  @doc """
  Reads file and calls `from_binary/1` to convert into a `JOSE.JWT`.
  """
  @spec from_file(String.t() | charlist()) :: t()
  def from_file(file), do: :jose_jwt.from_file(file) |> from_record()

  @doc """
  Converts a map into a `JOSE.JWT`.
  """
  def from_map(list) when is_list(list), do: for(element <- list, into: [], do: from_map(element))
  def from_map(map), do: :jose_jwt.from_map(map) |> from_record()

  ## Encode API

  @doc """
  Converts a `JOSE.JWT` into a binary.
  """
  def to_binary(list) when is_list(list), do: for(element <- list, into: [], do: to_binary(element))
  def to_binary(jwt = %JOSE.JWT{}), do: to_binary(to_record(jwt))
  def to_binary(any), do: :jose_jwt.to_binary(any)

  @doc """
  Calls `to_binary/1` on a `JOSE.JWT` and then writes the binary to file.
  """
  def to_file(file, jwt = %JOSE.JWT{}), do: to_file(file, to_record(jwt))
  def to_file(file, any), do: :jose_jwt.to_file(file, any)

  @doc """
  Converts a `JOSE.JWT` into a map.
  """
  def to_map(list) when is_list(list), do: for(element <- list, into: [], do: to_map(element))
  def to_map(jwt = %JOSE.JWT{}), do: to_map(to_record(jwt))
  def to_map(any), do: :jose_jwt.to_map(any)

  ## API

  @doc """
  Decrypts an encrypted `JOSE.JWT` using the `jwk`.  See `JOSE.JWE.block_decrypt/2`.
  """
  def decrypt(jwk = %JOSE.JWK{}, encrypted), do: decrypt(JOSE.JWK.to_record(jwk), encrypted)

  def decrypt(key, encrypted) do
    case :jose_jwt.decrypt(key, encrypted) do
      {jwe, jwt} when is_tuple(jwe) and is_tuple(jwt) ->
        {JOSE.JWE.from_record(jwe), from_record(jwt)}

      error ->
        error
    end
  end

  @doc """
  Encrypts a `JOSE.JWT` using the `jwk` and the default block encryptor algorithm `jwe` for the key type.  See `encrypt/3`.
  """
  def encrypt(jwk = %JOSE.JWK{}, jwt), do: encrypt(JOSE.JWK.to_record(jwk), jwt)

  def encrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, jwt),
    do: encrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, jwt)

  def encrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, jwt),
    do: encrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, jwt)

  def encrypt(jwk, jwt = %JOSE.JWT{}), do: encrypt(jwk, to_record(jwt))
  def encrypt(jwk, jwt), do: :jose_jwt.encrypt(jwk, jwt)

  @doc """
  Encrypts a `JOSE.JWT` using the `jwk` and the `jwe` algorithm.  See `JOSE.JWK.block_encrypt/3`.

  If `"typ"` is not specified in the `jwe`, `%{ "typ" => "JWT" }` will be added.
  """
  def encrypt(jwk = %JOSE.JWK{}, jwe, jwt), do: encrypt(JOSE.JWK.to_record(jwk), jwe, jwt)

  def encrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, jwe, jwt),
    do: encrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, jwe, jwt)

  def encrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, jwe, jwt),
    do: encrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, jwe, jwt)

  def encrypt(jwk, jwe = %JOSE.JWE{}, jwt), do: encrypt(jwk, JOSE.JWE.to_record(jwe), jwt)
  def encrypt(jwk, jwe, jwt = %JOSE.JWT{}), do: encrypt(jwk, jwe, to_record(jwt))
  def encrypt(jwk, jwe, jwt), do: :jose_jwt.encrypt(jwk, jwe, jwt)

  @doc """
  Merges map on right into map on left.
  """
  def merge(left = %JOSE.JWT{}, right), do: merge(left |> to_record(), right)
  def merge(left, right = %JOSE.JWT{}), do: merge(left, right |> to_record())
  def merge(left, right), do: :jose_jwt.merge(left, right) |> from_record()

  @doc """
  Same as `peek_payload/1`.
  """
  @spec peek(binary()) :: t()
  def peek(signed), do: from_record(:jose_jwt.peek(signed))

  @doc """
  Returns the decoded payload as a `JOSE.JWT` of a signed binary or map without verifying the signature.

  See `JOSE.JWS.peek_payload/1`.
  """
  @spec peek_payload(binary()) :: t()
  def peek_payload(signed), do: from_record(:jose_jwt.peek_payload(signed))

  @doc """
  Returns the decoded protected as a `JOSE.JWS` of a signed binary or map without verifying the signature.

  See `JOSE.JWS.peek_protected/1`.
  """
  @spec peek_protected(binary()) :: JOSE.JWS.t()
  def peek_protected(signed), do: JOSE.JWS.from_record(:jose_jwt.peek_protected(signed))

  @doc """
  Signs a `JOSE.JWT` using the `jwk` and the default signer algorithm `jws` for the key type.  See `sign/3`.
  """
  def sign(jwk = %JOSE.JWK{}, jwt), do: sign(JOSE.JWK.to_record(jwk), jwt)
  def sign(jwk, jwt = %JOSE.JWT{}), do: sign(jwk, to_record(jwt))

  def sign(jwk = [%JOSE.JWK{} | _], jwt) do
    sign(
      for k <- jwk do
        case k do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(k)

          _ ->
            k
        end
      end,
      jwt
    )
  end

  def sign(jwk, jwt), do: :jose_jwt.sign(jwk, jwt)

  @doc """
  Signs a `JOSE.JWT` using the `jwk` and the `jws` algorithm.  See `JOSE.JWK.sign/3`.

  If `"typ"` is not specified in the `jws`, `%{ "typ" => "JWT" }` will be added.
  """
  def sign(jwk = %JOSE.JWK{}, jws, jwt), do: sign(JOSE.JWK.to_record(jwk), jws, jwt)
  def sign(jwk, jws = %JOSE.JWS{}, jwt), do: sign(jwk, JOSE.JWS.to_record(jws), jwt)
  def sign(jwk, jws, jwt = %JOSE.JWT{}), do: sign(jwk, jws, to_record(jwt))

  def sign(jwk = [%JOSE.JWK{} | _], jws, jwt) do
    sign(
      for k <- jwk do
        case k do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(k)

          _ ->
            k
        end
      end,
      jws,
      jwt
    )
  end

  def sign(jwk, jws, jwt), do: :jose_jwt.sign(jwk, jws, jwt)

  @doc """
  Verifies the `signed` using the `jwk` and calls `from/1` on the payload.  See `JOSE.JWS.verify/2`.
  """
  @spec verify(JOSE.JWK.t(), binary()) :: {valid? :: boolean(), jwt :: t(), jws :: JOSE.JWS.t()}
  def verify(jwk = %JOSE.JWK{}, signed), do: verify(JOSE.JWK.to_record(jwk), signed)

  def verify(jwk = [%JOSE.JWK{} | _], signed) do
    verify(
      for k <- jwk do
        case k do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(k)

          _ ->
            k
        end
      end,
      signed
    )
  end

  def verify(key, signed) do
    try do
      case :jose_jwt.verify(key, signed) do
        {verified, jwt, jws} when is_tuple(jwt) and is_tuple(jws) ->
          {verified, from_record(jwt), JOSE.JWS.from_record(jws)}

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
  Verifies the `signed` using the `jwk`, whitelists the `"alg"` using `allow`, and calls `from/1` on the payload.  See `JOSE.JWS.verify_strict/3`.
  """
  @spec verify_strict(JOSE.JWK.t(), [String.t()], binary()) :: {valid? :: boolean(), jwt :: t(), jws :: JOSE.JWS.t()}
  def verify_strict(jwk = %JOSE.JWK{}, allow, signed), do: verify_strict(JOSE.JWK.to_record(jwk), allow, signed)

  def verify_strict(jwk = [%JOSE.JWK{} | _], allow, signed) do
    verify_strict(
      for k <- jwk do
        case k do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(k)

          _ ->
            k
        end
      end,
      allow,
      signed
    )
  end

  def verify_strict(key, allow, signed) do
    try do
      case :jose_jwt.verify_strict(key, allow, signed) do
        {verified, jwt, jws} when is_tuple(jwt) and is_tuple(jws) ->
          {verified, from_record(jwt), JOSE.JWS.from_record(jws)}

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
