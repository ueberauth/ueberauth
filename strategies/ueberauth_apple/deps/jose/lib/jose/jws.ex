require Record

defmodule JOSE.JWS do
  @moduledoc ~S"""
  JWS stands for JSON Web Signature which is defined in [RFC 7515](https://tools.ietf.org/html/rfc7515).

  ## Unsecured Signing Vulnerability

  The [`"none"`](https://tools.ietf.org/html/rfc7515#appendix-A.5) signing
  algorithm is disabled by default to prevent accidental verification of empty
  signatures (read about the vulnerability [here](https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/)).

  You may also enable the `"none"` algorithm as an application environment
  variable for `:jose` or by using `JOSE.unsecured_signing/1`.

  ## Strict Verification Recommended

  `JOSE.JWS.verify_strict/3` is recommended over `JOSE.JWS.verify/2` so that
  signing algorithms may be whitelisted during verification of signed input.

  ## Algorithms

  The following algorithms are currently supported by `JOSE.JWS` (some may need the `JOSE.crypto_fallback/1` option to be enabled):

    * `"Ed25519"`
    * `"Ed25519ph"`
    * `"Ed448"`
    * `"Ed448ph"`
    * `"EdDSA"`
    * `"ES256"`
    * `"ES384"`
    * `"ES512"`
    * `"HS256"`
    * `"HS384"`
    * `"HS512"`
    * `"Poly1305"`
    * `"PS256"`
    * `"PS384"`
    * `"PS512"`
    * `"RS256"`
    * `"RS384"`
    * `"RS512"`
    * `"none"` (disabled by default, enable with `JOSE.unsecured_signing/1`)

  ## Examples

  All of the example keys generated below can be found here: [https://gist.github.com/potatosalad/925a8b74d85835e285b9](https://gist.github.com/potatosalad/925a8b74d85835e285b9)

  ### Ed25519 and Ed25519ph

      # let's generate the 2 keys we'll use below
      jwk_ed25519   = JOSE.JWK.generate_key({:okp, :Ed25519})
      jwk_ed25519ph = JOSE.JWK.generate_key({:okp, :Ed25519ph})

      # Ed25519
      iex> signed_ed25519 = JOSE.JWS.sign(jwk_ed25519, "{}", %{ "alg" => "Ed25519" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFZDI1NTE5In0.e30.xyg2LTblm75KbLFJtROZRhEgAFJdlqH9bhx8a9LO1yvLxNLhO9fLqnFuU3ojOdbObr8bsubPkPqUfZlPkGHXCQ"
      iex> JOSE.JWS.verify(jwk_ed25519, signed_ed25519) |> elem(0)
      true

      # Ed25519ph
      iex> signed_ed25519ph = JOSE.JWS.sign(jwk_ed25519ph, "{}", %{ "alg" => "Ed25519ph" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFZDI1NTE5cGgifQ.e30.R3je4TTxQvoBOupIKkel_b8eW-G8KaWmXuC14NMGSCcHCTalURtMmVqX2KbcIpFBeI-OKP3BLHNIpt1keKveDg"
      iex> JOSE.JWS.verify(jwk_ed25519ph, signed_ed25519ph) |> elem(0)
      true

  ### Ed448 and Ed448ph

      # let's generate the 2 keys we'll use below
      jwk_ed448   = JOSE.JWK.generate_key({:okp, :Ed448})
      jwk_ed448ph = JOSE.JWK.generate_key({:okp, :Ed448ph})

      # Ed448
      iex> signed_ed448 = JOSE.JWS.sign(jwk_ed448, "{}", %{ "alg" => "Ed448" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFZDQ0OCJ9.e30.UlqTx962FvZP1G5pZOrScRXlAB0DJI5dtZkknNTm1E70AapkONi8vzpvKd355czflQdc7uyOzTeAz0-eLvffCKgWm_zebLly7L3DLBliynQk14qgJgz0si-60mBFYOIxRghk95kk5hCsFpxpVE45jRIA"
      iex> JOSE.JWS.verify(jwk_ed448, signed_ed448) |> elem(0)
      true

      # Ed448ph
      iex> signed_ed448ph = JOSE.JWS.sign(jwk_ed448ph, "{}", %{ "alg" => "Ed448ph" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFZDQ0OHBoIn0.e30._7wxQF8Am-Fg3E-KgREXBv3Gr2vqLM6ja_7hs6kA5EakCrJVQ2QiAHrr4NriLABmiPbVd7F7IiaAApyR3Ud4ak3lGcHVxSyksjJjvBUbKnSB_xkT6v_QMmx27hV08JlxskUkfvjAG0-yKGC8BXoT9R0A"
      iex> JOSE.JWS.verify(jwk_ed448ph, signed_ed448ph) |> elem(0)
      true

  ### EdDSA

      # EdDSA works with Ed25519, Ed25519ph, Ed448, and Ed448ph keys.
      # However, it defaults to Ed25519 for key generation.
      jwk_eddsa = JOSE.JWS.generate_key(%{ "alg" => "EdDSA" })

      # EdDSA
      iex> signed_eddsa = JOSE.JWS.sign(jwk_eddsa, "{}", %{ "alg" => "EdDSA" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFZERTQSJ9.e30.rhb5ZY7MllNbW9q-SCn_NglhYtaRGMXEUDj6BvJjltOt19tEI_1wFrVK__jL91i9hO7WtVqRH_OfHiilnO1CAQ"
      iex> JOSE.JWS.verify(jwk_eddsa, signed_eddsa) |> elem(0)
      true

  ### ES256, ES384, and ES512

      # let's generate the 3 keys we'll use below
      jwk_es256 = JOSE.JWK.generate_key({:ec, :secp256r1})
      jwk_es384 = JOSE.JWK.generate_key({:ec, :secp384r1})
      jwk_es512 = JOSE.JWK.generate_key({:ec, :secp521r1})

      # ES256
      iex> signed_es256 = JOSE.JWS.sign(jwk_es256, "{}", %{ "alg" => "ES256" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFUzI1NiJ9.e30.nb7cEQQuIi2NgcP5A468FHGG8UZg8gWZjloISyVIwNh3X6FiTTFZsvc0mL3RnulWoNJzKF6xwhae3botI1LbRg"
      iex> JOSE.JWS.verify(jwk_es256, signed_es256) |> elem(0)
      true

      # ES384
      iex> signed_es384 = JOSE.JWS.sign(jwk_es384, "{}", %{ "alg" => "ES384" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFUzM4NCJ9.e30.-2kZkNe66y2SprhgvvtMa0qBrSb2imPhMYkbi_a7vx-vpEHuVKsxCpUyNVLe5_CXaHWhHyc2rNi4uEfU73c8XQB3e03rg_JOj0H5XGIGS5G9f4RmNMSCiYGwqshLSDFI"
      iex> JOSE.JWS.verify(jwk_es384, signed_es384) |> elem(0)
      true

      # ES512
      iex> signed_es512 = JOSE.JWS.sign(jwk_es512, "{}", %{ "alg" => "ES512" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJFUzUxMiJ9.e30.AOIw4KTq5YDu6QNrAYKtFP8R5IljAbhqXuPK1dUARPqlfc5F3mM0kmSh5KOVNHDmdCdapBv0F3b6Hl6glFDPlxpiASuSWtvvs9K8_CRfSkEzvToj8wf3WLGOarQHDwYXtlZoki1zMPGeWABwafTZNQaItNSpqYd_P9GtN0XM3AALdua0"
      iex> JOSE.JWS.verify(jwk_es512, signed_es512) |> elem(0)
      true

  ### HS256, HS384, and HS512

      # let's generate the 3 keys we'll use below
      jwk_hs256 = JOSE.JWK.generate_key({:oct, 16})
      jwk_hs384 = JOSE.JWK.generate_key({:oct, 24})
      jwk_hs512 = JOSE.JWK.generate_key({:oct, 32})

      # HS256
      iex> signed_hs256 = JOSE.JWS.sign(jwk_hs256, "{}", %{ "alg" => "HS256" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJIUzI1NiJ9.e30.r2JwwMFHECoDZlrETLT-sgFT4qN3w0MLee9MrgkDwXs"
      iex> JOSE.JWS.verify(jwk_hs256, signed_hs256) |> elem(0)
      true

      # HS384
      iex> signed_hs384 = JOSE.JWS.sign(jwk_hs384, "{}", %{ "alg" => "HS384" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJIUzM4NCJ9.e30.brqQFXXM0XtMWDdKf0foEQcvK18swcoDkxBqCPeed_IO317_tisr60H2mz79SlNR"
      iex> JOSE.JWS.verify(jwk_hs384, signed_hs384) |> elem(0)
      true

      # HS512
      iex> signed_hs512 = JOSE.JWS.sign(jwk_hs512, "{}", %{ "alg" => "HS512" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJIUzUxMiJ9.e30.ge1JYomO8Fyl6sgxLbc4g3AMPbaMHLmeTl0jrUYAJZSloN9j4VyhjucX8d-RWIlMjzdG0xyklw53k1-kaTlRVQ"
      iex> JOSE.JWS.verify(jwk_hs512, signed_hs512) |> elem(0)
      true

  ### Poly1305

  This is highly experimental and based on [RFC 7539](https://tools.ietf.org/html/rfc7539).

  Every signed message has a new 96-bit nonce generated which is used to generate a one-time key from the secret.

      # let's generate the key we'll use below
      jwk_poly1305 = JOSE.JWK.generate_key({:oct, 32})

      # Poly1305
      iex> signed_poly1305 = JOSE.JWS.sign(jwk_poly1305, "{}", %{ "alg" => "Poly1305" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJQb2x5MTMwNSIsIm5vbmNlIjoiTjhiR3A1QXdob0Y3Yk1YUiJ9.e30.XWcCkV1WU72cTO-XuiNRAQ"
      iex> JOSE.JWS.verify(jwk_poly1305, signed_poly1305) |> elem(0)
      true

      # let's inspect the protected header to see the generated nonce
      iex> JOSE.JWS.peek_protected(signed_poly1305)
      "{\"alg\":\"Poly1305\",\"nonce\":\"N8bGp5AwhoF7bMXR\"}"

  ### PS256, PS384, and PS512

      # let's generate the 3 keys we'll use below (cutkey must be installed as a dependency)
      jwk_ps256 = JOSE.JWK.generate_key({:rsa, 2048})
      jwk_ps384 = JOSE.JWK.generate_key({:rsa, 4096})
      jwk_ps512 = JOSE.JWK.generate_key({:rsa, 8192}) # this may take a few seconds

      # PS256
      iex> signed_ps256 = JOSE.JWS.sign(jwk_ps256, "{}", %{ "alg" => "PS256" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJQUzI1NiJ9.e30.RY5A3rG2TjmdlARE57eSSSFE6plkuQPKLKsyqz3WrqKRWZgSrvROACRTzoGyrx1sNvQEZJLZ-xVhrFvP-80Q14XzQbPfYLubvn-2wcMNCmih3OVQNVtFdFjA5U2NG-sF-SWAUmm9V_DvMShFGG0qHxLX7LqT83lAIgEulgsytb0xgOjtJObBru5jLjN_uEnc7fCfnxi3my1GAtnrs9NiKvMfuIVlttvOORDFBTO2aFiCv1F-S6Xgj16rc0FGImG0x3amQcmFAD9g41KY0_KsCXgUfoiVpC6CqO6saRC4UDykks91B7Nuoxjsm3nKWa_4vKh9QJy-V8Sf0gHxK58j8Q"
      iex> JOSE.JWS.verify(jwk_ps256, signed_ps256) |> elem(0)
      true

      # PS384
      iex> signed_ps384 = JOSE.JWS.sign(jwk_ps384, "{}", %{ "alg" => "PS384" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJQUzM4NCJ9.e30.xmYVenIhi75hDMy3bnL6WVpVlTzYmO1ejOZeq9AkSjkp_STrdIp6uUEs9H_y7CLD9LrGYYHDNDl9WmoH6cn95WZT9KJgAVNFFYd8owY6JUHGKU1jUbLkptAgvdphVpWZ1C5fVCRt4vmp8K9f6jy3er9jCBNjl9gSBdmToFwYdXI26ZKSBjfoVm2tFFQIOThye4YQWCWHbzSho6J7d5ATje72L30zDvWXavJ-XNvof5Tkju4WQQB-ukFoqTw4yV8RVwCa-DX61I1hNrq-Zr75_iWmHak3GqNkg5ACBEjDtvtyxJizqy9KINKSlbB9jGztiWoEiXZ6wJ5sSJ6ZrSFJuQVEmns_dLqzpSHEFkWfczEV_gj9Eu_EXwMp9YQlQ3GktfXaz-mzH_jUaLmudEUskQGCiR92gK9KR6_ROQPJfD54Tkqdh6snwg6y17k8GdlTc5qMM3V84q3R6zllmhrRhV1Dlduc0MEqKcsQSX_IX21-sfiVMIcUsW73dIPXVZI2jsNlEHKqwMjWdSfjYUf3YApxSGERU3u4lRS3F0yRrZur8KWS3ToilApjg0cNg9jKas8g8C8ZPgGFYM6StVxUnXRmsJILDnsZMIPjbUDAPHhB0DwLwOB7OqGUBcItX-zwur1OVnHR7aIh1DbfWfyTIml8VIhYfGfazgXfgQVcGEM"
      iex> JOSE.JWS.verify(jwk_ps384, signed_ps384) |> elem(0)
      true

      # PS512
      iex> signed_ps512 = JOSE.JWS.sign(jwk_ps512, "{}", %{ "alg" => "PS512" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJQUzUxMiJ9.e30.fJe52-PF3I7UrpQamLCnmVAGkBhP0HVeJi48qZqaFc1-_tQEiYTfxuwQBDlt01GQWpjTZRb097bZF6RcrKWwRHyAo3otOZdR32emWfOHddWLL3qotj_fTaDR2-OhLixwce6mFjnHqppHH1zjCmgbKPG8S2cAadNd5w10VR-IS6LdnFRhNZOahuuB7dzCEJaSjkGfm3_9xdj3I0ZRl4fauR_LO9NQIyvMMeCFevowz1sVGG1G-I2njPrEXvxhAMp7y2mao5Yik8UUORXRjcn2Wai3umy8Yh4nHYU5qqruHjLjDwudCPNDjxjg294z1uAUpt7S0v7VbrkgUvgutTFAT-bcHywFODiycajQuqIpFp1TCUAq3Xe2yk4DTRduvPIKcPkJQnFrVkClJAU9A4D4602xpdK-z2uCgWsBVHVokf5-9ba5EqVb8BJx2xYZUIA5CdrIiTBfoe_cI5Jh92uprcWC_llio2ZJvGdQpPgwCgca7-RQ94LAmIA4u3mAndrZj_z48T2GjHbaKzl18FOPQH0XEvK_W5oypUe5NOGlz9mMGZigbFqBY2lM-7oVVYc4ZA3VFy8Dv1nWhU6DGb2NnDnQUyChllyBREuZbwrkOTQEvqqdV-6lM6VwXNu1gqc3YHly9W6u5CmsnxtvlIxsUVg679HiqdtdWxLSaIJObd9Xji56-eEkWMEA08SNy9p-F9AgHOxzoZqgrAQDEwqyEwqoAW681xLc5Vck580AQDxO9Ha4IqLIPirpO5EODQjOd8-S_SlAP5o_wz1Oh38MC5T5V13PqPuZ70dbggB4bUgVaHYC4FE4XHCqP7W3xethaPc68cY9-g9f1RUvthmnEYXSRpvyaMY3iX0txZazWIS_Jg7pNTCEaWr9JCLTZd1MiLbFowPvKYGM-z-39K31OUbq5PIScy0I9OOz9joecm8KsCesA2ysPph1E7cL7Etiw5tGhCFzcdQwm8Gm6SDwj8vCEcZUkXeZJfhlS1cJtZk1sNu3KZNndevtZjRWaXi2m4WNKVxVE-nuaF7V3GWfDemh9RXxyFK8OC8aYLIqcc2pAKJM47ANVty2ll1xaCIB3q3CKdnk5fmsnzKkQI9SjKy70p9TWT-NNoYU682KG_mZo-ByEs5CvJ8w7qysmX8Xpb2I6oSJf7S3qjbqkqtXQcV5MuQ232vk7-g42CcQGL82xvRc09TuvwnmykpKHmjUaJ4U9k9zTN3g2iTdpkvl6vbnND9uG1SBaieVeFYWCT-6VdhovEiD9bvIdA7D_R7NZO8YHBt_lfBQRle_jDyLzHSlkP6kt9dYRhrc2SNMzF_4i3iEUAihbaQYvbNsGwWrHqyGofnva20pRXwc4GxOlw"
      iex> JOSE.JWS.verify(jwk_ps512, signed_ps512) |> elem(0)
      true

  ### RS256, RS384, and RS512

      # let's generate the 3 keys we'll use below
      jwk_rs256 = JOSE.JWK.generate_key({:rsa, 1024})
      jwk_rs384 = JOSE.JWK.generate_key({:rsa, 2048})
      jwk_rs512 = JOSE.JWK.generate_key({:rsa, 4096})

      # RS256
      iex> signed_rs256 = JOSE.JWS.sign(jwk_rs256, "{}", %{ "alg" => "RS256" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJSUzI1NiJ9.e30.C0J8v5R-sEe9-g_s0SMgPorCh8VDdaZ9gLpWNm1Tn1Cv2xRph1Xn9Rzm10ZCEs84sj7kxA4v28fVShQ_P1AHN83yQ2mvstkKwsuwXxr-cludx_NLQL5CKKQtTR0ITD_pxUowjfAkBYuJv0677jUj-8lGKs1P5e2dbwW9IqFe4uE"
      iex> JOSE.JWS.verify(jwk_rs256, signed_rs256) |> elem(0)
      true

      # RS384
      iex> signed_rs384 = JOSE.JWS.sign(jwk_rs384, "{}", %{ "alg" => "RS384" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJSUzM4NCJ9.e30.fvPxeNhO0oitOsdqFmrBgpGE7Gn_NdJ1J8F5ArKon54pdHB2v30hua9wbG4V2Hr-hNAyflaBJtoGAwIpKVkfHn-IW7d06hKw_Hv0ecG-VvZr60cK2IJnHS149Htz_652egThZh1GIKRZN1IrRVlraLMozFcWP0Ojc-L-g5XjcTFafesmV0GFGfFubAiQWEiWIgNV3822L-wPe7ZGeFe5yYsZ70WMHQQ1tSuNsm5QUOUVInOThAhJ30FRTCNFgv46l4TEF9aaI9443cKAbwzd_EavD0FpvgpwEhGyNTVx0sxiCZIYUE_jN53aSaHXB82d0xwIr2-GXlr3Y-dLwERIMw"
      iex> JOSE.JWS.verify(jwk_rs384, signed_rs384) |> elem(0)
      true

      # RS512
      iex> signed_rs512 = JOSE.JWS.sign(jwk_rs512, "{}", %{ "alg" => "RS512" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJSUzUxMiJ9.e30.le2_kCnmj6Y02bl16Hh5EPqmLsFkB3YZpiEfvmA6xfdg9I3QJ5uSgOejs_HpuIbItuMFUdcqtkfW45_6YKlI7plB49iWiNnWY0PLxsvbiZaSmT4R4dOUWx9KlO_Ui5SE94XkigUoFanDTHTr9bh4NpvoIaNdi_xLdC7FYA-AqZspegRcgY-QZQv4kbD3NQJtxsEiAXk8-C8CX3lF6haRlh7s4pyAmgj7SJeElsPjhPNVZ7EduhTLZfVwiLrRmzLKQ6dJ_PrZDig1lgl9jf2NjzcsFpt6lvfrMsDdIQEGyJoh53-zXiD_ltyAZGS3pX-_tHRxoAZ1SyAPkkC4cCra6wc-03sBQPoUa26xyyhrgf4h7E2l-JqhKPXT7pJv6AbRPgKUH4prEH636gpoWQrRc-JxbDIJHR0ShdL8ssf5e-rKpcVVAZKnRI64NbSKXTg-JtDxhU9QG8JVEkHqOxSeo-VSXOoExdmm8lCfqylrw7qmDxjEwOq7TGjhINyjVaK1Op_64BWVuCzgooea6G2ZvCTIEl0-k8wY8s9VC7hxSrsgCAnpWeKpIcbLQoDIoyasG-6Qb5OuSLR367eg9NAQ8WMTbrrQkm-KLNCYvMFaxmlWzBFST2JDmIr0VH9BzXRAdfG81SymuyFA7_FdpiVYwAwEGR4Q5HYEpequ38tHu3Y"
      iex> JOSE.JWS.verify(jwk_rs512, signed_rs512) |> elem(0)
      true

  """

  record = Record.extract(:jose_jws, from_lib: "jose/include/jose_jws.hrl")
  keys = :lists.map(&elem(&1, 0), record)
  vals = :lists.map(&{&1, [], nil}, keys)
  pairs = :lists.zip(keys, vals)

  defstruct keys
  @type t :: %__MODULE__{}

  @doc """
  Converts a `JOSE.JWS` struct to a `:jose_jws` record.
  """
  def to_record(%JOSE.JWS{unquote_splicing(pairs)}) do
    {:jose_jws, unquote_splicing(vals)}
  end

  def to_record(list) when is_list(list), do: for(element <- list, into: [], do: to_record(element))

  @doc """
  Converts a `:jose_jws` record into a `JOSE.JWS`.
  """
  def from_record(jose_jws)

  def from_record({:jose_jws, unquote_splicing(vals)}) do
    %JOSE.JWS{unquote_splicing(pairs)}
  end

  def from_record(list) when is_list(list), do: for(element <- list, into: [], do: from_record(element))

  ## Decode API

  @doc """
  Converts a binary or map into a `JOSE.JWS`.

      iex> JOSE.JWS.from(%{ "alg" => "HS256" })
      %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined, fields: %{}}
      iex> JOSE.JWS.from("{\"alg\":\"HS256\"}")
      %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined, fields: %{}}

  Support for custom algorithms may be added by specifying a map tuple:

      iex> JOSE.JWS.from({%{ alg: MyCustomAlgorithm }, %{ "alg" => "custom" }})
      %JOSE.JWS{alg: {MyCustomAlgorithm, :state}, b64: :undefined, fields: %{}}

  *Note:* `MyCustomAlgorithm` must implement the `:jose_jws` and `:jose_jws_alg` behaviours.
  """
  def from(list) when is_list(list), do: for(element <- list, into: [], do: from(element))
  def from(jws = %JOSE.JWS{}), do: from(to_record(jws))
  def from(any), do: :jose_jws.from(any) |> from_record()

  @doc """
  Converts a binary into a `JOSE.JWS`.
  """
  def from_binary(list) when is_list(list), do: for(element <- list, into: [], do: from_binary(element))
  def from_binary(binary), do: :jose_jws.from_binary(binary) |> from_record()

  @doc """
  Reads file and calls `from_binary/1` to convert into a `JOSE.JWS`.
  """
  def from_file(file), do: :jose_jws.from_file(file) |> from_record()

  @doc """
  Converts a map into a `JOSE.JWS`.
  """
  def from_map(list) when is_list(list), do: for(element <- list, into: [], do: from_map(element))
  def from_map(map), do: :jose_jws.from_map(map) |> from_record()

  ## Encode API

  @doc """
  Converts a `JOSE.JWS` into a binary.
  """
  def to_binary(list) when is_list(list), do: for(element <- list, into: [], do: to_binary(element))
  def to_binary(jws = %JOSE.JWS{}), do: to_binary(to_record(jws))
  def to_binary(any), do: :jose_jws.to_binary(any)

  @doc """
  Calls `to_binary/1` on a `JOSE.JWS` and then writes the binary to file.
  """
  def to_file(file, jws = %JOSE.JWS{}), do: to_file(file, to_record(jws))
  def to_file(file, any), do: :jose_jws.to_file(file, any)

  @doc """
  Converts a `JOSE.JWS` into a map.
  """
  def to_map(list) when is_list(list), do: for(element <- list, into: [], do: to_map(element))
  def to_map(jws = %JOSE.JWS{}), do: to_map(to_record(jws))
  def to_map(any), do: :jose_jws.to_map(any)

  ## API

  @doc """
  Compacts an expanded signed map or signed list into a binary.

      iex> JOSE.JWS.compact(%{"payload" => "e30",
       "protected" => "eyJhbGciOiJIUzI1NiJ9",
       "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"})
      {%{},
       "eyJhbGciOiJIUzI1NiJ9.e30.5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"}
      iex> JOSE.JWS.compact(%{"payload" => "e30",
       "signatures" => [
        %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
          "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"},
        %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
          "signature" => "himAUXqVJnW2ZWOD8zaOZr0YzsA61lo48wu6-WP-Ks0"}]})
      {%{},
       ["eyJhbGciOiJIUzI1NiJ9.e30.5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU",
        "eyJhbGciOiJIUzI1NiJ9.e30.himAUXqVJnW2ZWOD8zaOZr0YzsA61lo48wu6-WP-Ks0"]}}

  See `expand/1`.
  """
  defdelegate compact(signed), to: :jose_jws

  @doc """
  Expands a compacted signed binary or list of signed binaries into a map.

      iex> JOSE.JWS.expand("eyJhbGciOiJIUzI1NiJ9.e30.5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU")
      {%{},
       %{"payload" => "e30", "protected" => "eyJhbGciOiJIUzI1NiJ9",
         "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"}}
      iex> JOSE.JWS.expand([
       "eyJhbGciOiJIUzI1NiJ9.e30.5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU",
       "eyJhbGciOiJIUzI1NiJ9.e30.himAUXqVJnW2ZWOD8zaOZr0YzsA61lo48wu6-WP-Ks0"])
      {%{},
       %{"payload" => "e30",
         "signatures" => [
          %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
            "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"},
          %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
            "signature" => "himAUXqVJnW2ZWOD8zaOZr0YzsA61lo48wu6-WP-Ks0"}]}}

  See `compact/1`.
  """
  defdelegate expand(signed), to: :jose_jws

  @doc """
  Generates a new `JOSE.JWK` based on the algorithms of the specified `JOSE.JWS`.

      iex> JOSE.JWS.generate_key(%{"alg" => "HS256"})
      %JOSE.JWK{fields: %{"alg" => "HS256", "use" => "sig"},
       keys: :undefined,
       kty: {:jose_jwk_kty_oct,
        <<150, 71, 29, 79, 228, 32, 218, 4, 111, 250, 212, 129, 226, 173, 86, 205, 72, 48, 98, 100, 66, 68, 113, 13, 43, 60, 122, 248, 179, 44, 140, 24>>}}

  """
  def generate_key(list) when is_list(list), do: for(element <- list, into: [], do: generate_key(element))
  def generate_key(jws = %JOSE.JWS{}), do: generate_key(to_record(jws))
  def generate_key(any), do: JOSE.JWK.from_record(:jose_jws.generate_key(any))

  @doc """
  Merges map on right into map on left.
  """
  def merge(left = %JOSE.JWS{}, right), do: merge(left |> to_record(), right)
  def merge(left, right = %JOSE.JWS{}), do: merge(left, right |> to_record())
  def merge(left, right), do: :jose_jws.merge(left, right) |> from_record()

  @doc """
  See `peek_payload/1`.
  """
  defdelegate peek(signed), to: :jose_jws

  @doc """
  Returns the decoded payload portion of a signed binary or map without verifying the signature.

      iex> JOSE.JWS.peek_payload("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.dMAojPMVbFvvkouYUSI9AxIRBxgqretQMCvNF7KmTHU")
      "{}"

  """
  defdelegate peek_payload(signed), to: :jose_jws

  @doc """
  Returns the decoded protected portion of a signed binary or map without verifying the signature.

      iex> JOSE.JWS.peek_protected("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.dMAojPMVbFvvkouYUSI9AxIRBxgqretQMCvNF7KmTHU")
      "{\"alg\":\"HS256\",\"typ\":\"JWT\"}"

  """
  defdelegate peek_protected(signed), to: :jose_jws

  @doc """
  Returns the decoded signature portion of a signed binary or map without verifying the signature.

      iex> JOSE.JWS.peek_signature("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.dMAojPMVbFvvkouYUSI9AxIRBxgqretQMCvNF7KmTHU")
      <<116, 192, 40, 140, 243, 21, 108, 91, 239, 146, 139, 152, 81, 34, 61, 3, 18, 17, 7, 24, 42, 173, 235, 80, 48, 43, 205, 23, 178, 166, 76, 117>>

  """
  defdelegate peek_signature(signed), to: :jose_jws

  @doc """
  Signs the `plain_text` using the `jwk` and algorithm specified by the `jws`.

      iex> jwk = JOSE.JWK.from(%{"k" => "qUg4Yw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}}
      iex> JOSE.JWS.sign(jwk, "{}", %{ "alg" => "HS256" })
      {%{alg: :jose_jws_alg_hmac},
       %{"payload" => "e30", "protected" => "eyJhbGciOiJIUzI1NiJ9",
         "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"}}

  If the `jwk` has a `"kid"` assigned, it will be added to the `"header"` on the signed map:

      iex> jwk = JOSE.JWK.from(%{"k" => "qUg4Yw", "kid" => "eyHC48MN26DvoBpkaudvOVXuI5Sy8fKMxQMYiRWmjFw", "kty" => "oct"})
      %JOSE.JWK{fields: %{"kid" => "eyHC48MN26DvoBpkaudvOVXuI5Sy8fKMxQMYiRWmjFw"},
       keys: :undefined, kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}}
      iex> JOSE.JWS.sign(jwk, "test", %{ "alg" => "HS256" })
      {%{alg: :jose_jws_alg_hmac},
       %{"header" => %{"kid" => "eyHC48MN26DvoBpkaudvOVXuI5Sy8fKMxQMYiRWmjFw"},
         "payload" => "e30", "protected" => "eyJhbGciOiJIUzI1NiJ9",
         "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"}}

  A list of `jwk` keys can also be specified to produce a signed list:

      iex> jwk1 = JOSE.JWK.from(%{"k" => "qUg4Yw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}}
      iex> jwk2 = JOSE.JWK.from_map(%{"k" => "H-v_Nw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<31, 235, 255, 55>>}}
      iex> JOSE.JWS.sign([jwk1, jwk2], "{}", %{ "alg" => "HS256" })
      {%{alg: :jose_jws_alg_hmac},
       %{"payload" => "e30",
         "signatures" => [
          %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
            "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"},
          %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
            "signature" => "himAUXqVJnW2ZWOD8zaOZr0YzsA61lo48wu6-WP-Ks0"}]}}

  *Note:* Signed maps with a `"header"` or other fields will have data loss when used with `compact/1`.
  """
  def sign(jwk = %JOSE.JWK{}, plain_text, jws), do: sign(JOSE.JWK.to_record(jwk), plain_text, jws)
  def sign(jwk, plain_text, jws = %JOSE.JWS{}), do: sign(jwk, plain_text, to_record(jws))

  def sign(key_list, plain_text, signer_list)
      when is_list(key_list) and is_list(signer_list) and length(key_list) === length(signer_list) do
    keys =
      for key <- key_list, into: [] do
        case key do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(key)

          _ ->
            key
        end
      end

    signers =
      for signer <- signer_list, into: [] do
        case signer do
          %JOSE.JWS{} ->
            JOSE.JWS.to_record(signer)

          _ ->
            signer
        end
      end

    :jose_jws.sign(keys, plain_text, signers)
  end

  def sign(key_list, plain_text, jws) when is_list(key_list) and not is_list(jws) do
    keys =
      for key <- key_list, into: [] do
        case key do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(key)

          _ ->
            key
        end
      end

    :jose_jws.sign(keys, plain_text, jws)
  end

  def sign(jwk, plain_text, signer_list) when is_list(signer_list) and not is_list(jwk) do
    signers =
      for signer <- signer_list, into: [] do
        case signer do
          %JOSE.JWS{} ->
            JOSE.JWS.to_record(signer)

          _ ->
            signer
        end
      end

    :jose_jws.sign(jwk, plain_text, signers)
  end

  def sign(jwk, plain_text, jws), do: :jose_jws.sign(jwk, plain_text, jws)

  @doc """
  Signs the `plain_text` using the `jwk` and algorithm specified by the `jws` and adds the `header` to the signed map.

      iex> jwk = JOSE.JWK.from(%{"k" => "qUg4Yw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}}
      iex> JOSE.JWS.sign(jwk, "{}", %{ "test" => true }, %{ "alg" => "HS256" })
      {%{alg: :jose_jws_alg_hmac},
       %{"header" => %{"test" => true}, "payload" => "e30",
         "protected" => "eyJhbGciOiJIUzI1NiJ9",
         "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"}}

  If the `jwk` has a `"kid"` assigned, it will be added to the `"header"` on the signed map.  See `sign/3`.
  """
  def sign(jwk = %JOSE.JWK{}, plain_text, header, jws), do: sign(JOSE.JWK.to_record(jwk), plain_text, header, jws)
  def sign(jwk, plain_text, header, jws = %JOSE.JWS{}), do: sign(jwk, plain_text, header, to_record(jws))

  def sign(key_list, plain_text, header, signer)
      when is_list(key_list) and is_map(header) and not is_list(signer) do
    headers = for _ <- key_list, into: [], do: header
    signers = for _ <- key_list, into: [], do: signer
    sign(key_list, plain_text, headers, signers)
  end

  def sign(key_list, plain_text, header, signer_list)
      when is_list(key_list) and is_map(header) and is_list(signer_list) and length(key_list) === length(signer_list) do
    headers = for _ <- key_list, into: [], do: header
    sign(key_list, plain_text, headers, signer_list)
  end

  def sign(key_list, plain_text, header_list, signer)
      when is_list(key_list) and is_list(header_list) and not is_list(signer) and length(key_list) === length(header_list) do
    signers = for _ <- key_list, into: [], do: signer
    sign(key_list, plain_text, header_list, signers)
  end

  def sign(key_list, plain_text, header_list, signer_list)
      when is_list(key_list) and is_list(header_list) and is_list(signer_list) and length(key_list) === length(signer_list) and
             length(key_list) === length(header_list) do
    keys =
      for key <- key_list, into: [] do
        case key do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(key)

          _ ->
            key
        end
      end

    signers =
      for signer <- signer_list, into: [] do
        case signer do
          %JOSE.JWS{} ->
            JOSE.JWS.to_record(signer)

          _ ->
            signer
        end
      end

    :jose_jws.sign(keys, plain_text, header_list, signers)
  end

  def sign(jwk = [%JOSE.JWK{} | _], plain_text, header, jws) do
    sign(
      for k <- jwk do
        case k do
          %JOSE.JWK{} ->
            JOSE.JWK.to_record(k)

          _ ->
            k
        end
      end,
      plain_text,
      header,
      jws
    )
  end

  def sign(jwk, plain_text, header, jws), do: :jose_jws.sign(jwk, plain_text, header, jws)

  @doc """
  Converts the `jws` to the `protected` argument used by `signing_input/3`.
  """
  def signing_input(payload, jws = %JOSE.JWS{}), do: signing_input(payload, to_record(jws))
  def signing_input(payload, jws), do: :jose_jws.signing_input(payload, jws)

  @doc """
  Combines `payload` and `protected` based on the `"b64"` setting on the `jws` for the signing input used by `sign/3` and `sign/4`.

  If `"b64"` is set to `false` on the `jws`, the raw `payload` will be used:

      iex> JOSE.JWS.signing_input("{}", %{ "alg" => "HS256" })
      "eyJhbGciOiJIUzI1NiJ9.e30"
      iex> JOSE.JWS.signing_input("{}", %{ "alg" => "HS256", "b64" => false })
      "eyJhbGciOiJIUzI1NiIsImI2NCI6ZmFsc2V9.{}"

  See [JWS Unencoded Payload Option](https://tools.ietf.org/html/draft-ietf-jose-jws-signing-input-options-04) for more information.
  """
  def signing_input(payload, protected, jws = %JOSE.JWS{}), do: signing_input(payload, protected, to_record(jws))
  def signing_input(payload, protected, jws), do: :jose_jws.signing_input(payload, protected, jws)

  @doc """
  Verifies the `signed` using the `jwk`.

      iex> jwk = JOSE.JWK.from(%{"k" => "qUg4Yw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}}
      iex> JOSE.JWS.verify(jwk, "eyJhbGciOiJIUzI1NiJ9.e30.5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU")
      {true, "{}",
       %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined, fields: %{}}}

  A list of `jwk` keys can also be specified where each key will be used to verify every entry in a signed list:

      iex> jwk1 = JOSE.JWK.from(%{"k" => "qUg4Yw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}}
      iex> jwk2 = JOSE.JWK.from_map(%{"k" => "H-v_Nw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<31, 235, 255, 55>>}}
      iex> JOSE.JWS.verify([jwk1, jwk2], %{"payload" => "e30",
       "signatures" => [
        %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
          "signature" => "5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"},
        %{"protected" => "eyJhbGciOiJIUzI1NiJ9",
          "signature" => "himAUXqVJnW2ZWOD8zaOZr0YzsA61lo48wu6-WP-Ks0"}]})
      [{%JOSE.JWK{fields: %{}, keys: :undefined,
         kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}},
        [{true, "{}",
          %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined, fields: %{}}},
         {false, "{}",
          %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined,
           fields: %{}}}]},
       {%JOSE.JWK{fields: %{}, keys: :undefined,
         kty: {:jose_jwk_kty_oct, <<31, 235, 255, 55>>}},
        [{false, "{}",
          %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined, fields: %{}}},
         {true, "{}",
          %JOSE.JWS{alg: {:jose_jws_alg_hmac, :HS256}, b64: :undefined,
           fields: %{}}}]}]

  """
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
      case :jose_jws.verify(key, signed) do
        {verified, payload, jws} when is_tuple(jws) ->
          {verified, payload, from_record(jws)}

        list when is_list(list) ->
          for {jwk, verifications} <- list do
            {JOSE.JWK.from_record(jwk),
             for {verified, payload, jws} <- verifications do
               {verified, payload, from_record(jws)}
             end}
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
  Same as `verify/2`, but uses `allow` as a whitelist for `"alg"` which are allowed to verify against.

  If the detected algorithm is not present in `allow`, then `false` is returned.

      iex> jwk = JOSE.JWK.from(%{"k" => "qUg4Yw", "kty" => "oct"})
      %JOSE.JWK{fields: %{}, keys: :undefined,
       kty: {:jose_jwk_kty_oct, <<169, 72, 56, 99>>}}
      iex> signed_hs256 = JOSE.JWS.sign(jwk, "{}", %{ "alg" => "HS256" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJIUzI1NiJ9.e30.5paAJxaOXSqRUIXrP_vJXUZu2SCBH-ojgP4D6Xr6GPU"
      iex> signed_hs512 = JOSE.JWS.sign(jwk, "{}", %{ "alg" => "HS512" }) |> JOSE.JWS.compact |> elem(1)
      "eyJhbGciOiJIUzUxMiJ9.e30.DN_JCks5rzQiDJJ15E6uJFskAMw-KcasGINKK_4S8xKo7W6tZ-a00ZL8UWOWgE7oHpcFrYnvSpNRldAMp19iyw"
      iex> JOSE.JWS.verify_strict(jwk, ["HS256"], signed_hs256) |> elem(0)
      true
      iex> JOSE.JWS.verify_strict(jwk, ["HS256"], signed_hs512) |> elem(0)
      false
      iex> JOSE.JWS.verify_strict(jwk, ["HS256", "HS512"], signed_hs512) |> elem(0)
      true

  """
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
      case :jose_jws.verify_strict(key, allow, signed) do
        {verified, payload, jws} when is_tuple(jws) ->
          {verified, payload, from_record(jws)}

        list when is_list(list) ->
          for {jwk, verifications} <- list do
            {JOSE.JWK.from_record(jwk),
             for {verified, payload, jws} <- verifications do
               {verified, payload, from_record(jws)}
             end}
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
