# Changelog

## v2.2.1 (2026-10-23)

  * Avoid secret key base from being written to logs in case of bad args (CVE-2026-105963) (GHSA-ffw9-w85g-f2vh)

## v2.2.0 (2026-07-24)

  * Support :compressed and :local options on encrypt/sign

## v2.1.1 (2025-04-03)

  * Fall back `hash_equals` when missing OpenSSL support

## v2.1.0 (2024-05-02)

  * Use `System.os_time/1` as the token signing date, since tokens are meant to be shared across machines

## v2.0.0 (2023-10-06)

  * Update Elixir requirement to v1.11+ and require Erlang/OTP 23.
  * Encryption now uses XChaCha20-Poly1305, which is safer, faster, and generates smaller payloads. This means data encrypted with Plug.Crypto v2.0 cannot be decrypted on Plug.Crypto v1.x. However, Plug.Crypto v2.0 can still decrypt data from Plug.Crypto v1.0.
  * XChaCha20-Poly1305 requires that the underlying Erlang/OTP is compiled with OpenSSL 1.1.0 or newer.
  * Optimize `secure_compare`, `masked_compare`, and key generator algorithms by relying on `:crypto` code when using more recent Erlang/OTP versions.

## v1.2.5 (2023-03-10)

  * Allow AAD to be given as iolist

## v1.2.4 (2023-03-10)

  * Allow AAD to be given as argument on message encryptor

## v1.2.3 (2022-08-19)

  * Remove warnings on Elixir v1.14

## v1.2.2 (2021-03-25)

  * Remove warnings on Elixir v1.12

## v1.2.1 (2021-02-17)

  * Add support for Erlang/OTP 24

## v1.2.0 (2020-10-07)

  * Update Elixir requirement to Elixir 1.7+.
  * Fixed a bug that allowed to sign and encrypt stuff with `nil` secret key base and salt.

## v1.1.2 (2020-02-16)

  * Do not key derive empty salts (default to no salt instead).

## v1.1.1 (2020-02-14)

  * Do not expose encryption with salt API.
  * Allow default `:max_age` to be set when signing/encrypting.

## v1.1.0 (2020-02-11)

  * Add high-level `Plug.Crypto.sign/verify` and `Plug.Crypto.encrypt/decrypt`.

## v1.0.0 (2018-10-03)

  * Split up the `plug_crypto` project from Plug as per [elixir-lang/plug#766](https://github.com/elixir-plug/plug/issues/766).
