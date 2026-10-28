require Record

defmodule JOSE.JWE do
  @moduledoc ~S"""
  JWE stands for JSON Web Encryption which is defined in [RFC 7516](https://tools.ietf.org/html/rfc7516).

  ## Key Derivation Algorithms

  The following key derivation algorithms for the `"alg"` field are currently supported by `JOSE.JWE` (some may need the `JOSE.crypto_fallback/1` option to be enabled):

    * `"A128GCMKW"`
    * `"A192GCMKW"`
    * `"A256GCMKW"`
    * `"A128KW"`
    * `"A192KW"`
    * `"A256KW"`
    * `"dir"`
    * `"ECDH-1PU"`
    * `"ECDH-1PU+A128GCMKW"`
    * `"ECDH-1PU+A192GCMKW"`
    * `"ECDH-1PU+A256GCMKW"`
    * `"ECDH-1PU+A128KW"`
    * `"ECDH-1PU+A192KW"`
    * `"ECDH-1PU+A256KW"`
    * `"ECDH-1PU+C20PKW"`
    * `"ECDH-1PU+XC20PKW"`
    * `"ECDH-ES"`
    * `"ECDH-ES+A128GCMKW"`
    * `"ECDH-ES+A192GCMKW"`
    * `"ECDH-ES+A256GCMKW"`
    * `"ECDH-ES+A128KW"`
    * `"ECDH-ES+A192KW"`
    * `"ECDH-ES+A256KW"`
    * `"ECDH-ES+C20PKW"`
    * `"ECDH-ES+XC20PKW"`
    * `"ECDH-SS"`
    * `"ECDH-SS+A128GCMKW"`
    * `"ECDH-SS+A192GCMKW"`
    * `"ECDH-SS+A256GCMKW"`
    * `"ECDH-SS+A128KW"`
    * `"ECDH-SS+A192KW"`
    * `"ECDH-SS+A256KW"`
    * `"ECDH-SS+C20PKW"`
    * `"ECDH-SS+XC20PKW"`
    * `"PBES2-HS256+A128GCMKW"`
    * `"PBES2-HS384+A192GCMKW"`
    * `"PBES2-HS512+A256GCMKW"`
    * `"PBES2-HS256+A128KW"`
    * `"PBES2-HS384+A192KW"`
    * `"PBES2-HS512+A256KW"`
    * `"PBES2-HS512+C20PKW"`
    * `"PBES2-HS512+XC20PKW"`
    * `"RSA1_5"`
    * `"RSA-OAEP"`
    * `"RSA-OAEP-256"`

  ## Encryption Algorithms

  The following encryption algorithms for the `"enc"` field are currently supported by `JOSE.JWE` (some may need the `JOSE.crypto_fallback/1` option to be enabled):

    * `"A128CBC-HS256"`
    * `"A192CBC-HS384"`
    * `"A256CBC-HS512"`
    * `"A128GCM"`
    * `"A192GCM"`
    * `"A256GCM"`
    * `"C20P"`
    * `"XC20P"`

  ## Compression Algorithms

  The following compression algorithms for the `"zip"` field are currently supported by `JOSE.JWE`:

    * `"DEF"`

  ## Key Derivation Examples

  All of the examples below will use `"enc"` set to `"A128GCM"`, `"A192GCM"`, or `"A256GCM"` depending on the derived key size.

  The octet key used will typically be all zeroes of the required size in the form of `<<0::128>>` (for a 128-bit key).

  All of the example keys generated below can be found here: [https://gist.github.com/potatosalad/dd140560b2bdbdab886d](https://gist.github.com/potatosalad/dd140560b2bdbdab886d)

      # octet keys we'll use below
      jwk_oct128 = JOSE.JWK.from_oct(<<0::128>>)
      jwk_oct192 = JOSE.JWK.from_oct(<<0::192>>)
      jwk_oct256 = JOSE.JWK.from_oct(<<0::256>>)
      jwk_secret = JOSE.JWK.from_oct("secret")

      # EC keypairs we'll use below
      jwk_ec256_alice_sk = JOSE.JWK.generate_key({:ec, :secp256r1})
      jwk_ec256_alice_pk = JOSE.JWK.to_public(jwk_ec256_alice_sk)
      jwk_ec256_bob_sk   = JOSE.JWK.generate_key({:ec, :secp256r1})
      jwk_ec256_bob_pk   = JOSE.JWK.to_public(jwk_ec256_bob_sk)

      # X25519 keypairs we'll use below
      jwk_x25519_alice_sk = JOSE.JWK.generate_key({:okp, :X25519})
      jwk_x25519_alice_pk = JOSE.JWK.to_public(jwk_x25519_alice_sk)
      jwk_x25519_bob_sk   = JOSE.JWK.generate_key({:okp, :X25519})
      jwk_x25519_bob_pk   = JOSE.JWK.to_public(jwk_x25519_bob_sk)

      # X448 keypairs we'll use below
      jwk_x448_alice_sk = JOSE.JWK.generate_key({:okp, :X448})
      jwk_x448_alice_pk = JOSE.JWK.to_public(jwk_x448_alice_sk)
      jwk_x448_bob_sk   = JOSE.JWK.generate_key({:okp, :X448})
      jwk_x448_bob_pk   = JOSE.JWK.to_public(jwk_x448_bob_sk)

      # RSA keypairs we'll use below
      jwk_rsa_sk = JOSE.JWK.generate_key({:rsa, 4096})
      jwk_rsa_pk = JOSE.JWK.to_public(jwk_rsa_sk)

  ### A128GCMKW, A192GCMKW, and A256GCMKW

      # A128GCMKW
      iex> encrypted_a128gcmkw = JOSE.JWE.block_encrypt(jwk_oct128, "{}", %{ "alg" => "A128GCMKW", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJBMTI4R0NNS1ciLCJlbmMiOiJBMTI4R0NNIiwiaXYiOiJzODNFNjhPNjhsWlM5ZVprIiwidGFnIjoieF9Ea2M5dm1LMk5RQV8tU2hvTkFRdyJ9.8B2qX8fVEa-s61RsZXqkCg.J7yJ8sKLbUlzyor6.FRs.BhBwImTv9B14NwVuxmfU6A"
      iex> JOSE.JWE.block_decrypt(jwk_oct128, encrypted_a128gcmkw) |> elem(0)
      "{}"

      # A192GCMKW
      iex> encrypted_a192gcmkw = JOSE.JWE.block_encrypt(jwk_oct192, "{}", %{ "alg" => "A192GCMKW", "enc" => "A192GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJBMTkyR0NNS1ciLCJlbmMiOiJBMTkyR0NNIiwiaXYiOiIxMkduZWQyTDB6NE5LZG83IiwidGFnIjoiM0thbG9iaER1Wmx5dE1YSjhjcXhZZyJ9.jJC4E1c6augIhvGDp3fquRfO-mnnud4F.S2NkKNGxBKTsCnKo.gZA.MvfhqSTeEN75H8HDyvfzRQ"
      iex> JOSE.JWE.block_decrypt(jwk_oct192, encrypted_a192gcmkw) |> elem(0)
      "{}"

      # A256GCMKW
      iex> encrypted_a256gcmkw = JOSE.JWE.block_encrypt(jwk_oct256, "{}", %{ "alg" => "A256GCMKW", "enc" => "A256GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJBMjU2R0NNS1ciLCJlbmMiOiJBMjU2R0NNIiwiaXYiOiJHU3lFMTBLQURxZTczNUMzIiwidGFnIjoiR3dVbDJCbXRNWlVseDlXNEMtY0tQZyJ9.sSsbFw9z8WTkzBLvPMywSedTXXygFxfP9g5U2qpzUX8.eiVFfe7iojfK0AXb._v8.YVfk9dNrtS7wxbGqCVge-g"
      iex> JOSE.JWE.block_decrypt(jwk_oct256, encrypted_a256gcmkw) |> elem(0)
      "{}"

  ### A128KW, A192KW, and A256KW

      # A128KW
      iex> encrypted_a128kw = JOSE.JWE.block_encrypt(jwk_oct128, "{}", %{ "alg" => "A128KW", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJBMTI4S1ciLCJlbmMiOiJBMTI4R0NNIn0.t4_Fb4kCl6BcS1cXnR4P4Xgm-jwVNsFl.RerKfWjzqqtLIUrz.JmE.ZDpVlWo-aQYM5la9eshwWw"
      iex> JOSE.JWE.block_decrypt(jwk_oct128, encrypted_a128kw) |> elem(0)
      "{}"

      # A192KW
      iex> encrypted_a192kw = JOSE.JWE.block_encrypt(jwk_oct192, "{}", %{ "alg" => "A192KW", "enc" => "A192GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJBMTkyS1ciLCJlbmMiOiJBMTkyR0NNIn0.edpvNrztlNADbkwfq5YBJgqFBSH_Znv1Y1uXKNQ_13w.yCkEYTCPOKH6CoxZ.siw.zP_ZM9OEeX1FIdFjqNawtQ"
      iex> JOSE.JWE.block_decrypt(jwk_oct192, encrypted_a192kw) |> elem(0)
      "{}"

      # A256KW
      iex> encrypted_a256kw = JOSE.JWE.block_encrypt(jwk_oct256, "{}", %{ "alg" => "A256KW", "enc" => "A256GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJBMjU2S1ciLCJlbmMiOiJBMjU2R0NNIn0.OvAhC1a2BoP_2SMIiZXwIHWPoIkD-Cosgp3nlpiTs8ySUBPfPzwG1g.4GeackYJbuBksAWA.HPE.vG0sGC2kuklH5xk8KXhyNA"
      iex> JOSE.JWE.block_decrypt(jwk_oct256, encrypted_a256kw) |> elem(0)
      "{}"

  ### dir

  The `"dir"` key derivation algorithm is essentially just a pass-through to the underlying `"enc"` algorithm.

  The `"encrypted_key"` is not included in the protected header, so the key must be fully known by both parties.

      # dir
      iex> encrypted_dir = JOSE.JWE.block_encrypt(jwk_oct128, "{}", %{ "alg" => "dir", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4R0NNIn0..HdRR8O0kk_SvOjAS.rxo.JTMPGPKZZKVNlWV0RexsmQ"
      iex> JOSE.JWE.block_decrypt(jwk_oct128, encrypted_dir) |> elem(0)
      "{}"

  ### ECDH-ES, ECDH-ES+A128KW, ECDH-ES+A192KW, and ECDH-ES+A256KW

  The `"ECDH-ES"` key derivation algorithm does not include the `"encrypted_key"` field in the protected header, similar to how `"dir"` functions.

  The size of the generated key is dependent on the `"enc"` setting (for example, `"A128GCM"` will generate a 128-bit key, `"A256GCM"` a 256-bit key, etc).

      # ECDH-ES with EC keypairs
      iex> encrypted_ecdhes_ec256_alice2bob = JOSE.JWE.block_encrypt({jwk_ec256_bob_pk, jwk_ec256_alice_sk}, "{}", %{ "alg" => "ECDH-ES", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJFQ0RILUVTIiwiZW5jIjoiQTEyOEdDTSIsImVwayI6eyJjcnYiOiJQLTI1NiIsImt0eSI6IkVDIiwieCI6IjQ4UVUzUTBDeVN4d0piRXdXckpyWVhscDg4X2RWcEhUeHE0YXZjNjZoNVEiLCJ5IjoiWnpxcklOdE1NeEh4US1RQjcyUk1jZGxtRHNPSXdsS2hNcVZtX2dZV0MxNCJ9fQ..UssNrY5qEeFdluZY.R6g.32nlr0wHF2TwfL1UnBtIow"
      iex> JOSE.JWE.block_decrypt({jwk_ec256_alice_pk, jwk_ec256_bob_sk}, encrypted_ecdhes_ec256_alice2bob) |> elem(0)
      "{}"

      # ECDH-ES with X25519 keypairs
      iex> encrypted_ecdhes_x25519_alice2bob = JOSE.JWE.block_encrypt({jwk_x25519_bob_pk, jwk_x25519_alice_sk}, "{}", %{ "alg" => "ECDH-ES", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJFQ0RILUVTIiwiZW5jIjoiQTEyOEdDTSIsImVwayI6eyJjcnYiOiJYMjU1MTkiLCJrdHkiOiJPS1AiLCJ4IjoiZ0g3TjJwT0duenZfd0tBLUhqREZKTlVSZVhfdG05XzdiMkZSUjI3cXFYcyJ9fQ..T-0q42FPCUy3hlla.MHU.9TNP2jG5bN1vSvaesijdww"
      iex> JOSE.JWE.block_decrypt({jwk_x25519_alice_pk, jwk_x25519_bob_sk}, encrypted_ecdhes_x25519_alice2bob) |> elem(0)
      "{}"

      # ECDH-ES with X448 keypairs
      iex> encrypted_ecdhes_x448_alice2bob = JOSE.JWE.block_encrypt({jwk_x448_bob_pk, jwk_x448_alice_sk}, "{}", %{ "alg" => "ECDH-ES", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJFQ0RILUVTIiwiZW5jIjoiQTEyOEdDTSIsImVwayI6eyJjcnYiOiJYNDQ4Iiwia3R5IjoiT0tQIiwieCI6ImFFaHZISGxFM2V1Y3lsY0RNNzBMd1paY2dDRk9acXExNWM3YXZNMjJkcWZIUEtja1FZNmo3LXFfM19kMGI1cGVWZEFoNVoyQWZIWSJ9fQ..T-UNE-wOApuRH71r.Uj8.l8bIfhC1UPAPVWBV3wkc6A"
      iex> JOSE.JWE.block_decrypt({jwk_x448_alice_pk, jwk_x448_bob_sk}, encrypted_ecdhes_x448_alice2bob) |> elem(0)
      "{}"

  When decrypting with any of the `"ECDH-ES"` related algorithms, the other party's public key is recommended, but not required for decryption (the embedded Ephemeral Public Key will be used instead):

      # decrypting the X448 example with and without the public key specified
      iex> JOSE.JWE.block_decrypt({jwk_x448_alice_pk, jwk_x448_bob_sk}, encrypted_ecdhes_x448_alice2bob) |> elem(0)
      "{}"
      iex> JOSE.JWE.block_decrypt(jwk_x448_bob_sk, encrypted_ecdhes_x448_alice2bob) |> elem(0)
      "{}"

  The `"ECDH-ES+A128KW"`, `"ECDH-ES+A192KW"`, and `"ECDH-ES+A256KW"` key derivation algorithms do include the `"encrypted_key"` and the suffix after `"ECDH-ES+"` determines the key size (so `"ECDH-ES+A128KW"` computes a 128-bit key).

      # ECDH-ES+A128KW with EC keypairs
      iex> encrypted_ecdhesa128kw_alice2bob = JOSE.JWE.block_encrypt({jwk_ec256_bob_pk, jwk_ec256_alice_sk}, "{}", %{ "alg" => "ECDH-ES+A128KW", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJFQ0RILUVTK0ExMjhLVyIsImVuYyI6IkExMjhHQ00iLCJlcGsiOnsiY3J2IjoiUC0yNTYiLCJrdHkiOiJFQyIsIngiOiI0OFFVM1EwQ3lTeHdKYkV3V3JKcllYbHA4OF9kVnBIVHhxNGF2YzY2aDVRIiwieSI6Ilp6cXJJTnRNTXhIeFEtUUI3MlJNY2RsbURzT0l3bEtoTXFWbV9nWVdDMTQifX0.ZwuqXf7svd3SH0M-XYLjWz5JsN6xX03C.l8tt83EJjy86IovL.i5A.nw05dPUA0a18xdtvmHbhHA"
      iex> JOSE.JWE.block_decrypt({jwk_ec256_alice_pk, jwk_ec256_bob_sk}, encrypted_ecdhesa128kw_alice2bob) |> elem(0)
      "{}"

      # ECDH-ES+A192KW with EC keypairs
      iex> encrypted_ecdhesa192kw_alice2bob = JOSE.JWE.block_encrypt({jwk_ec256_bob_pk, jwk_ec256_alice_sk}, "{}", %{ "alg" => "ECDH-ES+A192KW", "enc" => "A192GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJFQ0RILUVTK0ExOTJLVyIsImVuYyI6IkExOTJHQ00iLCJlcGsiOnsiY3J2IjoiUC0yNTYiLCJrdHkiOiJFQyIsIngiOiI0OFFVM1EwQ3lTeHdKYkV3V3JKcllYbHA4OF9kVnBIVHhxNGF2YzY2aDVRIiwieSI6Ilp6cXJJTnRNTXhIeFEtUUI3MlJNY2RsbURzT0l3bEtoTXFWbV9nWVdDMTQifX0.S9LZ1i_Lua_if4I83WcaCQ9yT5qqPI_NhCFR7tMiZDQ.kG3taKEjGeKDRTzs.H1s.oVGBFP63z4gd3e-R2d1cmA"
      iex> JOSE.JWE.block_decrypt({jwk_ec256_alice_pk, jwk_ec256_bob_sk}, encrypted_ecdhesa192kw_alice2bob) |> elem(0)
      "{}"

      # ECDH-ES+A256KW with EC keypairs
      iex> encrypted_ecdhesa256kw_alice2bob = JOSE.JWE.block_encrypt({jwk_ec256_bob_pk, jwk_ec256_alice_sk}, "{}", %{ "alg" => "ECDH-ES+A256KW", "enc" => "A256GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJFQ0RILUVTK0EyNTZLVyIsImVuYyI6IkEyNTZHQ00iLCJlcGsiOnsiY3J2IjoiUC0yNTYiLCJrdHkiOiJFQyIsIngiOiI0OFFVM1EwQ3lTeHdKYkV3V3JKcllYbHA4OF9kVnBIVHhxNGF2YzY2aDVRIiwieSI6Ilp6cXJJTnRNTXhIeFEtUUI3MlJNY2RsbURzT0l3bEtoTXFWbV9nWVdDMTQifX0.4KWy1-vRiJyNINF6mWYbUPPTVNG9ADfvvfpSDbddPTftz7GmUHUsuQ.IkRhtGH23R-9dFF3.9yk.RnALhnqWMHWCZFxqc-DU4A"
      iex> JOSE.JWE.block_decrypt({jwk_ec256_alice_pk, jwk_ec256_bob_sk}, encrypted_ecdhesa256kw_alice2bob) |> elem(0)
      "{}"

  See `JOSE.JWK.box_encrypt/2` for generating an Ephemeral Public Key based on the same curve as the supplied other party key in the same step.

  ### PBES2-HS256+A128KW, PBES2-HS384+A192KW, and PBES2-HS512+A256KW

      # PBES2-HS256+A128KW
      iex> encrypted_pbes2hs256a128kw = JOSE.JWE.block_encrypt(jwk_secret, "{}", %{ "alg" => "PBES2-HS256+A128KW", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJQQkVTMi1IUzI1NitBMTI4S1ciLCJlbmMiOiJBMTI4R0NNIiwicDJjIjo0MDk2LCJwMnMiOiJRR0laNTlzbjRnQThySHBWYjFrSkd3In0.8WMQ0fysLiHU8AjpjkcqJGpYe53VRf2s.vVEb2ZtKmtPIw8M-.Cmg.GCjDtdKV6khqEuyZy2gUxw"
      iex> JOSE.JWE.block_decrypt(jwk_secret, encrypted_pbes2hs256a128kw) |> elem(0)
      "{}"

      # PBES2-HS384+A192KW
      iex> encrypted_pbes2hs384a192kw = JOSE.JWE.block_encrypt(jwk_secret, "{}", %{ "alg" => "PBES2-HS384+A192KW", "enc" => "A192GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJQQkVTMi1IUzM4NCtBMTkyS1ciLCJlbmMiOiJBMTkyR0NNIiwicDJjIjo2MTQ0LCJwMnMiOiJKSDRjZ0hlNTZiU0prZ1d6VktpWWJCb0FzWEJBY1A1NiJ9.Ck5GvgXxmyac3jzs0lRavoRh6tI9nEs3lYkx8sdDzGw.IdxaPATMkQ8FYiYQ.uHk.rDU6ltWsTsw9vuvA73bgJQ"
      iex> JOSE.JWE.block_decrypt(jwk_secret, encrypted_pbes2hs384a192kw) |> elem(0)
      "{}"

      # PBES2-HS512+A256KW
      iex> encrypted_pbes2hs512a256kw = JOSE.JWE.block_encrypt(jwk_secret, "{}", %{ "alg" => "PBES2-HS512+A256KW", "enc" => "A256GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJQQkVTMi1IUzUxMitBMjU2S1ciLCJlbmMiOiJBMjU2R0NNIiwicDJjIjo4MTkyLCJwMnMiOiJ6YWRiMVNmT1F4V1gyTHJrSVgwWDFGM2QzNlBIdUdxRVFzUDVhbWVnTk00In0.6SUVO9sSevqZrZ5yPX-JvJNJrzfIQeTTzrkWBHEqHra1_AITtwEe0A.0AaF_3ZlJOkRlqgb.W8I.jFWob73QTn52IFSIPEWHFA"
      iex> JOSE.JWE.block_decrypt(jwk_secret, encrypted_pbes2hs512a256kw) |> elem(0)
      "{}"

  The `"p2s"` and `"p2i"` fields may also be specified to control the Salt and Iterations of the PBES2 Key Derivation Function, respectively.

  The default Salt is a randomly generated binary the same length of bytes as the key wrap (for example, `"PBES2-HS256+A128KW"` will generate a 16-byte Salt).

  The default Iterations is 32 times the number of bits specified by the key wrap (for example, `"PBES2-HS256+A128KW"` will have 4096 Iterations).

      # let's setup the JWE header
      iterations = 8192
      salt = <<0::256>> # all zero salt, for example usage only
      jwe = %{
        "alg" => "PBES2-HS256+A128KW",
        "enc" => "A128GCM",
        "p2i" => iterations,
        "p2s" => :jose_base64url.encode(salt)
      }
      # PBES2-HS256+A128KW
      iex> encrypted_pbes2 = JOSE.JWE.block_encrypt(jwk_secret, "{}", jwe) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJQQkVTMi1IUzI1NitBMTI4S1ciLCJlbmMiOiJBMTI4R0NNIiwicDJjIjo0MDk2LCJwMmkiOjgxOTIsInAycyI6IkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEifQ.I7wcBmg7O_rOWpg1aak7wQWX84YtED6k.Rgh3f6Kzl5SZ1z7x.FNo.eyK1ySx4SGR-xC2EYNySQA"
      iex> JOSE.JWE.block_decrypt(jwk_secret, encrypted_pbes2) |> elem(0)
      "{}"

  ### RSA1_5, RSA-OAEP, and RSA-OAEP-256

      # RSA1_5
      iex> encrypted_rsa1_5 = JOSE.JWE.block_encrypt(jwk_rsa_pk, "{}", %{ "alg" => "RSA1_5", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJSU0ExXzUiLCJlbmMiOiJBMTI4R0NNIn0.NlndPTqULN1vArshEzfEXY0nHCf4ubsTK9iHAeIxL85fReYrYG8EDB2_IirUneavvHSa-hsVLXNzBu0F9OY3TRFAIuJ8Jt1tqZZEhHZ97vzTEIjdlPNctGNI11-mhNCJ0doSvx9T4ByngaAFtJnRoR2cqbJkJFGja60fHtO0CfKLW5XzPf0NAhr8Tof-5IJfbNpMcC_LdCItJ6i8cuj4i5pG_CikOKDrNzbaBP72200_kl_-YaLDMA4tVb2YjWksY5Vau0Hz16QvI9QwDIcIDLYPAlTlDrU7s_FfmO_89S9Z69-lc_OBG7x2CYzIhB-0wzx753nZRl_WNJKi1Ya_AV552FEqVUhR-SuKcyrTA9OwkKC2JoL3lFqsCL9jkZkBrVREQlT0cxNI_AInyx5FHNLBbdtkz0JQbvzMJ854RP0V_eTlI5u8DZ42aOTRMBLHPi-4gP0J_CGWyKDQreXEEF6LSuLJb1cGk-NX1Vd85aARstQPuOoy7pWJjPvBEKEib70fjkUuMA0Atid-5BusQLKc1H-D6c5HIFH0DgYtXhN6AtQ_fmqw1F_X1JrGnYiYGzJCD2hh0Yt2UJZoCuHlPKk8aM5L3lNU3AISb1soSQl3hfX8Skb817ffC7jYezdhZc12cRNzOPAYqJYjN2eDlQhx-gpFjVzc-W1bFG8Yijo.grliT3M1iZ48aSY9.F4Y.pBRqIGZ4Q_fI1kmeAggvRg"
      iex> JOSE.JWE.block_decrypt(jwk_rsa_sk, encrypted_rsa1_5) |> elem(0)
      "{}"

      # RSA-OAEP
      iex> encrypted_rsaoaep = JOSE.JWE.block_encrypt(jwk_rsa_pk, "{}", %{ "alg" => "RSA-OAEP", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJSU0EtT0FFUCIsImVuYyI6IkExMjhHQ00ifQ.YZfGKTTU2KuvwIMpSYadbNmGzWIbLrwRYD8JvZAWkvcnFeky09S04VadRNPXmCBSl4EF1K7oBm0fiYXuvNbLFNKYT_Jo_y6Lb-XsP--BZKaEcq6wIdZ4-xTJ7YYX5dfco_cMknZLG8W2sQRwtWopisn9NyzSpfGNlYqeJqjpoJy0qnO8yZeEYeadwoVF9-XZfYwvMjEt7HORqBIPF1JIaOYTQ-LQBvya6XYhOR7dkSnuCZ_ITGW5ZbPvzOILSMW_3Ixe78ncfO2gxF6AiLh02oTLsOSrF9xDlJvuU0k1TdkNWtGroeP_WVbXEO7O_GI5LVW-cDzoVm5ZCQs2Df0018-qDxFyY9xhKS9aNDi_btiarstXMSz3EkOfPhWR_IzlVyUkYnzs3GS993gKLQ0Tk-ipvOT9Bcw9VTLLK3-f5YSkf51IA---hPFlxVlboH9bmTXlT4JzSbErQEYp3JuXjOP7FQn0OPko5Utqbbm41XBEJhUpBNhjrBGDspsMxML_eJdyzBgA5UyNfdCEQ2vM1pCegxG_hSKAhCKVNn71wW4O_y_eqUcoyhjB7HtVxiF29jzNUKF-y14171L4-mxsIpixaM1ofnayWMiherVP0Wz2MXkzWB0AUv8c3kNEJIh3oeyrczWwzpmeCh1Bq7-J4D6aaFjyGFcm-03_QZmfwho.ymxveKBeRuaZ8HzD.3H4.6oKLh2NouhPGpO1dmA-tTg"
      iex> JOSE.JWE.block_decrypt(jwk_rsa_sk, encrypted_rsaoaep) |> elem(0)
      "{}"

      # RSA-OAEP-256
      iex> encrypted_rsaoaep256 = JOSE.JWE.block_encrypt(jwk_rsa_pk, "{}", %{ "alg" => "RSA-OAEP-256", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJSU0EtT0FFUC0yNTYiLCJlbmMiOiJBMTI4R0NNIn0.OW9Hy9qpOIgVueODQXcWIUw_-Sm3UFGtxosyOAaI6JUQFt8q-iEtKkUp4NHrOlczO6tP5t8zRKdNXFfCm9QZk6F9PsSO-NzE2-DV1ANAMck-CDfGTK0mwG5U_KZwlObSgU0gxf87K49Wuno1rWlHWzJb__C_hCJXi_aQW17tLmbuTpJMkB0NTCKX3y6QaxvynP98jqwMJT6uGmE3AeuZYhPGzAOWbltbWyw-TqWqyLJirAUY_fvDNsKt1TDrTd9216TK5y7RQeUtdGfbuYK9lt2TIwfh9ycAHd7SANH_YJc2cKYa3e6CgqnQAjVpbhpogBz5sz5HaK95XYbXOdnYyHQ00gS44YquiQCvX331UgEWnthtmYwDZfnCxTkPydafGOBsjaagGvV2tQtxUKW3JmVChF97bNj5lQZ7rAkyooxx-k3IMT0005x6_74O5tXGN5fb7oyT3Mx_NZ5dKzlYAA_V8oOpNslaFhV5K5Q_-hRkUsEPWdaD5s2uS9Z7l7ot39CzzTKDj65f2eCTWFReFKOjhabCL4ZiFXbElB3dA3y5FdxXPAfe6N31G9ynalx1JIcrEaRb8sdqk6U6uC3s3DpkoRSnp3osBJOxxuk_Lgb-ZM9d8UuRVj4W78-qjfX_lcG1RlRmlYoDIU03ly0UfRWi-7HmpPECrGTsGZEfULg.J-txckmMXEi-bZVh.Rbw.D7UpSkticmDCGiNyLVggLg"
      iex> JOSE.JWE.block_decrypt(jwk_rsa_sk, encrypted_rsaoaep256) |> elem(0)
      "{}"

  ## Encryption Examples

  All of the examples below will use `"alg"` set to `"dir"` passing the key directly to the Encryption Algorithm.

  The octet key used will typically be all zeroes of the required size in the form of `<<0::128>>` (for a 128-bit key).

  All of the example keys generated below can be found here: [https://gist.github.com/potatosalad/dd140560b2bdbdab886d](https://gist.github.com/potatosalad/dd140560b2bdbdab886d)

      # octet keys we'll use below
      jwk_oct128 = JOSE.JWK.from_oct(<<0::128>>)
      jwk_oct192 = JOSE.JWK.from_oct(<<0::192>>)
      jwk_oct256 = JOSE.JWK.from_oct(<<0::256>>)
      jwk_oct384 = JOSE.JWK.from_oct(<<0::384>>)
      jwk_oct512 = JOSE.JWK.from_oct(<<0::512>>)

  ### A128CBC-HS256, A192CBC-HS384, and A256CBC-HS512

      # A128CBC-HS256
      iex> encrypted_a128cbchs256 = JOSE.JWE.block_encrypt(jwk_oct256, "{}", %{ "alg" => "dir", "enc" => "A128CBC-HS256" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0..bxps64-UIQoFvhkjr05e9A.HrtJ3AqrqJ4f5PHjGseHYw.kopJoTDxk34IVhheoToLSA"
      iex> JOSE.JWE.block_decrypt(jwk_oct256, encrypted_a128cbchs256) |> elem(0)
      "{}"

      # A192CBC-HS384
      iex> encrypted_a192cbchs384 = JOSE.JWE.block_encrypt(jwk_oct384, "{}", %{ "alg" => "dir", "enc" => "A192CBC-HS384" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTkyQ0JDLUhTMzg0In0..3zSCHwvHrcxsNyssIgEBRA.XB70tUoQZlnOgY5ygMxfKA.Avl7Z8jCpShh3_iTcPcU3Woh6E9ykNyB"
      iex> JOSE.JWE.block_decrypt(jwk_oct384, encrypted_a192cbchs384) |> elem(0)
      "{}"

      # A256CBC-HS512
      iex> encrypted_a256cbchs512 = JOSE.JWE.block_encrypt(jwk_oct512, "{}", %{ "alg" => "dir", "enc" => "A256CBC-HS512" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2Q0JDLUhTNTEyIn0..mqMhkWAMF7HmW_Nu1ERUzQ.bzd-tmykuru0Lu_rsNZ2ow.mlOFO8JcC_UJ35TsZgiUeEwAjRDs6cwfN7Umyzm7mmY"
      iex> JOSE.JWE.block_decrypt(jwk_oct512, encrypted_a256cbchs512) |> elem(0)
      "{}"

  ### A128GCM, A192GCM, and A256GCM

      # A128GCM
      iex> encrypted_a128gcm = JOSE.JWE.block_encrypt(jwk_oct128, "{}", %{ "alg" => "dir", "enc" => "A128GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4R0NNIn0..pPF4SbzGZwxS1J-M.Ic0.qkHuC-hOO44HPlykBJLSsA"
      iex> JOSE.JWE.block_decrypt(jwk_oct128, encrypted_a128gcm) |> elem(0)
      "{}"

      # A192GCM
      iex> encrypted_a192gcm = JOSE.JWE.block_encrypt(jwk_oct192, "{}", %{ "alg" => "dir", "enc" => "A192GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTkyR0NNIn0..muNgk2GFW9ATwqqZ.bvE.gYvC0G6DAodJdyrUqLw7Iw"
      iex> JOSE.JWE.block_decrypt(jwk_oct192, encrypted_a192gcm) |> elem(0)
      "{}"

      # A256GCM
      iex> encrypted_a256gcm = JOSE.JWE.block_encrypt(jwk_oct256, "{}", %{ "alg" => "dir", "enc" => "A256GCM" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..rDTJhd5ja5pDAYtn.PrM.MQdLgiVXQsG_cLas93ZEHw"
      iex> JOSE.JWE.block_decrypt(jwk_oct256, encrypted_a256gcm) |> elem(0)
      "{}"

  ### ChaCha20/Poly1305 and XChaCha20/Poly1305

  This is experimental and based on [RFC 7539](https://tools.ietf.org/html/rfc7539) and [draft-amringer-jose-chacha](https://tools.ietf.org/html/draft-amringer-jose-chacha-01).

      # C20P
      iex> encrypted_c20p = JOSE.JWE.block_encrypt(jwk_oct256, "{}", %{ "alg" => "dir", "enc" => "C20P" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJDMjBQIn0..W3qFkCKCEJz5H5jt.Hag.2TUFobBK_TYdtC2auoiiKA"
      iex> JOSE.JWE.block_decrypt(jwk_oct256, encrypted_c20p) |> elem(0)
      "{}"
      # XC20P
      iex> encrypted_xc20p = JOSE.JWE.block_encrypt(jwk_oct256, "{}", %{ "alg" => "dir", "enc" => "XC20P" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJYQzIwUCJ9..aMrioLxn-KO8Dyy8LcYD2mSNY7yPE_yf.Wxg.PJgIuI0ZADBE6Gi5-f7Tfg"
      iex> JOSE.JWE.block_decrypt(jwk_oct256, encrypted_xc20p) |> elem(0)
      "{}"

  ## Compression Examples

  All of the examples below will use `"alg"` set to `"dir"` passing the key directly to the Encryption Algorithm (`"enc"` is set to `"A128GCM"`).

  The octet key used will typically be all zeroes of the required size in the form of `<<0::128>>` (for a 128-bit key).

  All of the example keys generated below can be found here: [https://gist.github.com/potatosalad/dd140560b2bdbdab886d](https://gist.github.com/potatosalad/dd140560b2bdbdab886d)

      # octet keys we'll use below
      jwk_oct128 = JOSE.JWK.from_oct(<<0::128>>)

  ### DEF

      # DEF
      iex> encrypted_def = JOSE.JWE.block_encrypt(jwk_oct128, "{}", %{ "alg" => "dir", "enc" => "A128GCM", "zip" => "DEF" }) |> JOSE.JWE.compact |> elem(1)
      "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4R0NNIiwiemlwIjoiREVGIn0..Vvr0vlKWE9rAJ8CR.UpOz7w10Uc9pMg.Pctxzz0ijPSOY8zyRcbjww"
      iex> JOSE.JWE.block_decrypt(jwk_oct128, encrypted_def) |> elem(0)
      "{}"

  """

  record = Record.extract(:jose_jwe, from_lib: "jose/include/jose_jwe.hrl")
  keys = :lists.map(&elem(&1, 0), record)
  vals = :lists.map(&{&1, [], nil}, keys)
  pairs = :lists.zip(keys, vals)

  defstruct keys
  @type t :: %__MODULE__{}

  @doc """
  Converts a `JOSE.JWE` struct to a `:jose_jwe` record.
  """
  @spec to_record(t()) :: tuple()
  @spec to_record([t()]) :: [tuple()]
  def to_record(%JOSE.JWE{unquote_splicing(pairs)}) do
    {:jose_jwe, unquote_splicing(vals)}
  end

  def to_record(list) when is_list(list), do: for(element <- list, into: [], do: to_record(element))

  @doc """
  Converts a `:jose_jwe` record into a `JOSE.JWE`.
  """
  @spec from_record(tuple()) :: t()
  @spec from_record([tuple()]) :: [t()]
  def from_record(jose_jwe)

  def from_record({:jose_jwe, unquote_splicing(vals)}) do
    %JOSE.JWE{unquote_splicing(pairs)}
  end

  def from_record(list) when is_list(list), do: for(element <- list, into: [], do: from_record(element))

  ## Decode API

  @doc """
  Converts a binary or map into a `JOSE.JWE`.

      iex> JOSE.JWE.from(%{ "alg" => "dir" })
      %JOSE.JWE{alg: {:jose_jwe_alg_dir, :dir}, enc: :undefined, fields: %{},
       zip: :undefined}
      iex> JOSE.JWE.from("{\"alg\":\"dir\"}")
      %JOSE.JWE{alg: {:jose_jwe_alg_dir, :dir}, enc: :undefined, fields: %{},
       zip: :undefined}

  There are 3 keys which can have custom modules defined for them:

    * `"alg"` - must implement `:jose_jwe` and `:jose_jwe_alg` behaviours
    * `"enc"` - must implement `:jose_jwe` and `:jose_jwe_enc` behaviours
    * `"zip"` - must implement `:jose_jwe` and `:jose_jwe_zip` behaviours

  For example:

      iex> JOSE.JWE.from({%{ zip: MyCustomCompress }, %{ "alg" => "dir", "zip" => "custom" }})
      %JOSE.JWE{alg: {:jose_jwe_alg_dir, :dir}, enc: :undefined, fields: %{},
       zip: {MyCustomCompress, :state}}

  """
  @spec from(t() | map() | binary()) :: t()
  @spec from([t() | map() | binary()]) :: [t()]
  def from(list) when is_list(list), do: for(element <- list, into: [], do: from(element))
  def from(jwe = %JOSE.JWE{}), do: from(to_record(jwe))
  def from(any), do: :jose_jwe.from(any) |> from_record()

  @doc """
  Converts a binary into a `JOSE.JWE`.
  """
  @spec from_binary(binary()) :: t()
  @spec from_binary([binary()]) :: [t()]
  def from_binary(list) when is_list(list), do: for(element <- list, into: [], do: from_binary(element))
  def from_binary(binary), do: :jose_jwe.from_binary(binary) |> from_record()

  @doc """
  Reads file and calls `from_binary/1` to convert into a `JOSE.JWE`.
  """
  @spec from_file(String.t()) :: t()
  def from_file(file), do: :jose_jwe.from_file(file) |> from_record()

  @doc """
  Converts a map into a `JOSE.JWE`.
  """
  @spec from_map(map()) :: t()
  @spec from_map([map()]) :: [t()]
  def from_map(list) when is_list(list), do: for(element <- list, into: [], do: from_map(element))
  def from_map(map), do: :jose_jwe.from_map(map) |> from_record()

  ## Encode API

  @doc """
  Converts a `JOSE.JWE` into a binary.
  """
  @spec to_binary(t() | map() | binary()) :: binary()
  @spec to_binary([t() | map() | binary()]) :: [binary()]
  def to_binary(list) when is_list(list), do: for(element <- list, into: [], do: to_binary(element))
  def to_binary(jwe = %JOSE.JWE{}), do: to_binary(to_record(jwe))
  def to_binary(any), do: :jose_jwe.to_binary(any)

  @doc """
  Calls `to_binary/1` on a `JOSE.JWE` and then writes the binary to file.
  """
  @spec to_file(String.t(), t() | map() | binary()) :: :ok | {:error, reason :: term()}
  def to_file(file, jwe = %JOSE.JWE{}), do: to_file(file, to_record(jwe))
  def to_file(file, any), do: :jose_jwe.to_file(file, any)

  @doc """
  Converts a `JOSE.JWE` into a map.
  """
  @spec to_map(t() | map() | binary()) :: map()
  @spec to_map([t() | map() | binary()]) :: [map()]
  def to_map(list) when is_list(list), do: for(element <- list, into: [], do: to_map(element))
  def to_map(jwe = %JOSE.JWE{}), do: to_map(to_record(jwe))
  def to_map(any), do: :jose_jwe.to_map(any)

  ## API

  @doc """
  Decrypts the `encrypted` binary or map using the `jwk`.

      iex> jwk = JOSE.JWK.from(%{"k" => "STlqtIOhWJjoVnYjUjxFLZ6oN1oB70QARGSTWQ_5XgM", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct,
        <<73, 57, 106, 180, 131, 161, 88, 152, 232, 86, 118, 35, 82, 60, 69, 45, 158, 168, 55, 90, 1, 239, 68, 0, 68, 100, 147, 89, 15, 249, 94, 3>>}}
      iex> JOSE.JWE.block_decrypt(jwk, "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0..jBt5tTa1Q0N3uFPEkf30MQ.Ei49MvTLLje7bsZ5EZCZMA.gMWOAmhZSq9ksHCZm6VSoA")
      {"{}",
       %JOSE.JWE{alg: {:jose_jwe_alg_dir, :dir},
        enc: {:jose_jwe_enc_aes,
         {:jose_jwe_enc_aes, {:aes_cbc, 128}, 256, 32, 16, 16, 16, 16, :sha256}},
        fields: %{}, zip: :undefined}}

  See `block_encrypt/2`.
  """
  @spec block_decrypt(JOSE.JWK.t(), binary()) :: {plaintext :: binary(), t()} | {:error, t()}
  def block_decrypt(jwk = %JOSE.JWK{}, encrypted), do: block_decrypt(JOSE.JWK.to_record(jwk), encrypted)

  def block_decrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, encrypted),
    do: block_decrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, encrypted)

  def block_decrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, encrypted),
    do: block_decrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, encrypted)

  def block_decrypt(jwk, encrypted) do
    case :jose_jwe.block_decrypt(jwk, encrypted) do
      {plain_text, jwe} when is_tuple(jwe) ->
        {plain_text, from_record(jwe)}

      error ->
        error
    end
  end

  @doc """
  Encrypts `plain_text` using the `jwk` and algorithm specified by the `jwe` by getting the `cek` for `block_encrypt/4`.
  """
  @spec block_encrypt(JOSE.JWK.t(), binary(), t()) :: binary()
  def block_encrypt(jwk = %JOSE.JWK{}, plain_text, jwe), do: block_encrypt(JOSE.JWK.to_record(jwk), plain_text, jwe)

  def block_encrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, plain_text, jwe),
    do: block_encrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, plain_text, jwe)

  def block_encrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, plain_text, jwe),
    do: block_encrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, plain_text, jwe)

  def block_encrypt(jwk, plain_text, jwe = %JOSE.JWE{}), do: block_encrypt(jwk, plain_text, to_record(jwe))
  def block_encrypt(jwk, plain_text, jwe), do: :jose_jwe.block_encrypt(jwk, plain_text, jwe)

  @doc """
  Encrypts `plain_text` using the `jwk`, `cek`, and algorithm specified by the `jwe` by getting the `iv` for `block_encrypt/5`.
  """
  @spec block_encrypt(JOSE.JWK.t(), binary(), map(), t()) :: binary()
  def block_encrypt(jwk = %JOSE.JWK{}, plain_text, cek, jwe), do: block_encrypt(JOSE.JWK.to_record(jwk), plain_text, cek, jwe)

  def block_encrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, plain_text, cek, jwe),
    do: block_encrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, plain_text, cek, jwe)

  def block_encrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, plain_text, cek, jwe),
    do: block_encrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, plain_text, cek, jwe)

  def block_encrypt(jwk, plain_text, cek, jwe = %JOSE.JWE{}), do: block_encrypt(jwk, plain_text, cek, to_record(jwe))
  def block_encrypt(jwk, plain_text, cek, jwe), do: :jose_jwe.block_encrypt(jwk, plain_text, cek, jwe)

  @doc """
  Encrypts the `plain_text` using the `jwk`, `cek`, `iv`, and algorithm specified by the `jwe`.

      iex> jwk = JOSE.JWK.from(%{"k" => "STlqtIOhWJjoVnYjUjxFLZ6oN1oB70QARGSTWQ_5XgM", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct,
        <<73, 57, 106, 180, 131, 161, 88, 152, 232, 86, 118, 35, 82, 60, 69, 45, 158, 168, 55, 90, 1, 239, 68, 0, 68, 100, 147, 89, 15, 249, 94, 3>>}}
      iex> JOSE.JWE.block_encrypt(jwk, "{}", %{ "alg" => "dir", "enc" => "A128CBC-HS256" })
      {%{alg: :jose_jwe_alg_dir, enc: :jose_jwe_enc_aes},
       %{"ciphertext" => "Ei49MvTLLje7bsZ5EZCZMA", "encrypted_key" => "",
         "iv" => "jBt5tTa1Q0N3uFPEkf30MQ",
         "protected" => "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0",
         "tag" => "gMWOAmhZSq9ksHCZm6VSoA"}}

  See `block_decrypt/2`.
  """
  @spec block_encrypt(JOSE.JWK.t(), binary(), map(), binary(), t()) :: {binary(), t()}
  def block_encrypt(jwk = %JOSE.JWK{}, plain_text, cek, iv, jwe),
    do: block_encrypt(JOSE.JWK.to_record(jwk), plain_text, cek, iv, jwe)

  def block_encrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, plain_text, cek, iv, jwe),
    do: block_encrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, plain_text, cek, iv, jwe)

  def block_encrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, plain_text, cek, iv, jwe),
    do: block_encrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, plain_text, cek, iv, jwe)

  def block_encrypt(jwk, plain_text, cek, iv, jwe = %JOSE.JWE{}), do: block_encrypt(jwk, plain_text, cek, iv, to_record(jwe))
  def block_encrypt(jwk, plain_text, cek, iv, jwe), do: :jose_jwe.block_encrypt(jwk, plain_text, cek, iv, jwe)

  @doc """
  Compacts an expanded encrypted map into a binary.

      iex> JOSE.JWE.compact(%{"ciphertext" => "Ei49MvTLLje7bsZ5EZCZMA", "encrypted_key" => "",
       "iv" => "jBt5tTa1Q0N3uFPEkf30MQ",
       "protected" => "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0",
       "tag" => "gMWOAmhZSq9ksHCZm6VSoA"})
      {%{},
       "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0..jBt5tTa1Q0N3uFPEkf30MQ.Ei49MvTLLje7bsZ5EZCZMA.gMWOAmhZSq9ksHCZm6VSoA"}

  See `expand/1`.
  """
  @spec compact(map() | {map(), map()}) :: {map(), binary()}
  defdelegate compact(encrypted), to: :jose_jwe

  @doc """
  Compresses the `plain_text` using the `"zip"` algorithm specified by the `jwe`.

      iex> JOSE.JWE.compress("{}", %{ "alg" => "dir", "zip" => "DEF" })
      <<120, 156, 171, 174, 5, 0, 1, 117, 0, 249>>

  See `uncompress/2`.
  """
  @spec compress(binary(), t() | tuple()) :: binary()
  def compress(plain_text, jwe = %JOSE.JWE{}), do: compress(plain_text, to_record(jwe))
  def compress(plain_text, jwe), do: :jose_jwe.compress(plain_text, jwe)

  @doc """
  Expands a compacted encrypted binary into a map.

      iex> JOSE.JWE.expand("eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0..jBt5tTa1Q0N3uFPEkf30MQ.Ei49MvTLLje7bsZ5EZCZMA.gMWOAmhZSq9ksHCZm6VSoA")
      {%{},
       %{"ciphertext" => "Ei49MvTLLje7bsZ5EZCZMA", "encrypted_key" => "",
         "iv" => "jBt5tTa1Q0N3uFPEkf30MQ",
         "protected" => "eyJhbGciOiJkaXIiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0",
         "tag" => "gMWOAmhZSq9ksHCZm6VSoA"}}

  See `compact/1`.
  """
  @spec expand(binary()) :: {map(), map()}
  defdelegate expand(encrypted), to: :jose_jwe

  @doc """
  Generates a new `JOSE.JWK` based on the algorithms of the specified `JOSE.JWE`.

      iex> JOSE.JWE.generate_key(%{"alg" => "dir", "enc" => "A128GCM"})
      %JOSE.JWK{fields: %{"alg" => "dir", "enc" => "A128GCM", "use" => "enc"},
       keys: :undefined,
       kty: {:jose_jwk_kty_oct,
        <<188, 156, 171, 224, 232, 231, 41, 250, 210, 117, 112, 219, 134, 218, 94, 50>>}}

  """
  @spec generate_key(t() | binary() | map()) :: JOSE.JWK.t()
  @spec generate_key([t() | binary() | map()]) :: [JOSE.JWK.t()]
  def generate_key(list) when is_list(list), do: for(element <- list, into: [], do: generate_key(element))
  def generate_key(jwe = %JOSE.JWE{}), do: generate_key(to_record(jwe))
  def generate_key(any), do: JOSE.JWK.from_record(:jose_jwe.generate_key(any))

  @doc """
  Decrypts the `encrypted_key` using the `jwk` and the `"alg"` and `"enc"` specified by the `jwe`.

      # let's define our jwk and encrypted_key
      jwk = JOSE.JWK.from(%{"k" => "idN_YyeYZqEE7BkpexhA2Q", "kty" => "oct"})
      enc = <<27, 123, 126, 121, 56, 105, 105, 81, 140, 76, 30, 2, 14, 92, 231, 174, 203, 196, 110, 204, 57, 238, 248, 73>>

      iex> JOSE.JWE.key_decrypt(jwk, enc, %{ "alg" => "A128KW", "enc" => "A128CBC-HS256" })
      <<134, 82, 15, 176, 181, 115, 173, 19, 13, 44, 189, 185, 187, 125, 28, 240>>

  See `key_encrypt/3`.
  """
  @spec key_decrypt(JOSE.JWK.t(), binary(), t()) :: {binary(), t()} | {:error, term()}
  def key_decrypt(jwk = %JOSE.JWK{}, encrypted_key, jwe), do: key_decrypt(JOSE.JWK.to_record(jwk), encrypted_key, jwe)

  def key_decrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, encrypted_key, jwe),
    do: key_decrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, encrypted_key, jwe)

  def key_decrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, encrypted_key, jwe),
    do: key_decrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, encrypted_key, jwe)

  def key_decrypt(jwk, encrypted_key, jwe = %JOSE.JWE{}), do: key_decrypt(jwk, encrypted_key, to_record(jwe))
  def key_decrypt(jwk, encrypted_key, jwe), do: :jose_jwe.key_decrypt(jwk, encrypted_key, jwe)

  @doc """
  Encrypts the `decrypted_key` using the `jwk` and the `"alg"` and `"enc"` specified by the `jwe`.

      # let's define our jwk and cek (or decrypted_key)
      jwk = JOSE.JWK.from(%{"k" => "idN_YyeYZqEE7BkpexhA2Q", "kty" => "oct"})            # JOSE.JWK.generate_key({:oct, 16})
      cek = <<134, 82, 15, 176, 181, 115, 173, 19, 13, 44, 189, 185, 187, 125, 28, 240>> # :crypto.rand_bytes(16)

      iex> JOSE.JWE.key_encrypt(jwk, cek, %{ "alg" => "A128KW", "enc" => "A128CBC-HS256" })
      {<<27, 123, 126, 121, 56, 105, 105, 81, 140, 76, 30, 2, 14, 92, 231, 174, 203, 196, 110, 204, 57, 238, 248, 73>>,
       %JOSE.JWE{alg: {:jose_jwe_alg_aes_kw,
         {:jose_jwe_alg_aes_kw, 128, false, :undefined, :undefined}},
        enc: {:jose_jwe_enc_aes,
         {:jose_jwe_enc_aes, {:aes_cbc, 128}, 256, 32, 16, 16, 16, 16, :sha256}},
        fields: %{}, zip: :undefined}}

  See `key_decrypt/3`.
  """
  @spec key_encrypt(JOSE.JWK.t(), binary(), t()) :: {binary(), t()} | {:error, term()}
  def key_encrypt(jwk = %JOSE.JWK{}, decrypted_key, jwe), do: key_encrypt(JOSE.JWK.to_record(jwk), decrypted_key, jwe)

  def key_encrypt({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, decrypted_key, jwe),
    do: key_encrypt({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, decrypted_key, jwe)

  def key_encrypt({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, decrypted_key, jwe),
    do: key_encrypt({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, decrypted_key, jwe)

  def key_encrypt(jwk, decrypted_key, jwe = %JOSE.JWE{}), do: key_encrypt(jwk, decrypted_key, to_record(jwe))

  def key_encrypt(jwk, decrypted_key, jwe) do
    case :jose_jwe.key_encrypt(jwk, decrypted_key, jwe) do
      {encrypted_key, jwe} when is_tuple(jwe) ->
        {encrypted_key, from_record(jwe)}

      error ->
        error
    end
  end

  @doc """
  Merges map on right into map on left.
  """
  @spec merge(t() | tuple(), t() | tuple()) :: t()
  def merge(left = %JOSE.JWE{}, right), do: merge(left |> to_record, right)
  def merge(left, right = %JOSE.JWE{}), do: merge(left, right |> to_record)
  def merge(left, right), do: :jose_jwe.merge(left, right) |> from_record

  @doc """
  Returns the next `cek` using the `jwk` and the `"alg"` and `"enc"` specified by the `jwe`.

      # let's define our jwk
      jwk = JOSE.JWK.from(%{"k" => "idN_YyeYZqEE7BkpexhA2Q", "kty" => "oct"}) # JOSE.JWK.generate_key({:oct, 16})

      iex> JOSE.JWE.next_cek(jwk, %{ "alg" => "A128KW", "enc" => "A128CBC-HS256" })
      <<37, 83, 139, 165, 44, 23, 163, 186, 255, 155, 183, 17, 220, 211, 80, 247, 239, 149, 194, 53, 134, 41, 254, 176, 0, 247, 66, 38, 217, 252, 82, 233>>

      # when using the "dir" algorithm, the jwk itself will be used
      iex> JOSE.JWE.next_cek(jwk, %{ "alg" => "dir", "enc" => "A128GCM" })
      <<137, 211, 127, 99, 39, 152, 102, 161, 4, 236, 25, 41, 123, 24, 64, 217>>

  """
  @spec next_cek(JOSE.JWK.t(), t() | tuple() | map() | binary()) :: binary()
  def next_cek(jwk = %JOSE.JWK{}, jwe), do: next_cek(JOSE.JWK.to_record(jwk), jwe)

  def next_cek({your_public_jwk = %JOSE.JWK{}, my_private_jwk}, jwe),
    do: next_cek({JOSE.JWK.to_record(your_public_jwk), my_private_jwk}, jwe)

  def next_cek({your_public_jwk, my_private_jwk = %JOSE.JWK{}}, jwe),
    do: next_cek({your_public_jwk, JOSE.JWK.to_record(my_private_jwk)}, jwe)

  def next_cek(jwk, jwe = %JOSE.JWE{}), do: next_cek(jwk, to_record(jwe))
  def next_cek(jwk, jwe), do: :jose_jwe.next_cek(jwk, jwe)

  @doc """
  Returns the next `iv` the `"alg"` and `"enc"` specified by the `jwe`.

      # typically just returns random bytes for the specified "enc" algorithm
      iex> bit_size(JOSE.JWE.next_iv(%{ "alg" => "dir", "enc" => "A128CBC-HS256" }))
      128
      iex> bit_size(JOSE.JWE.next_iv(%{ "alg" => "dir", "enc" => "A128GCM" }))
      96

  """
  @spec next_iv(t() | tuple()) :: binary()
  def next_iv(jwe = %JOSE.JWE{}), do: next_iv(to_record(jwe))
  def next_iv(jwe), do: :jose_jwe.next_iv(jwe)

  @doc """
  Uncompresses the `cipher_text` using the `"zip"` algorithm specified by the `jwe`.

      iex> JOSE.JWE.uncompress(<<120, 156, 171, 174, 5, 0, 1, 117, 0, 249>>, %{ "alg" => "dir", "zip" => "DEF" })
      "{}"

  See `compress/2`.
  """
  @spec uncompress(binary(), t() | tuple()) :: binary()
  def uncompress(cipher_text, jwe = %JOSE.JWE{}), do: uncompress(cipher_text, to_record(jwe))
  def uncompress(cipher_text, jwe), do: :jose_jwe.uncompress(cipher_text, jwe)
end
