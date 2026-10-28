# [certifi](https://github.com/certifi/erlang-certifi)

[![CI](https://github.com/certifi/erlang-certifi/actions/workflows/erlang.yml/badge.svg)](https://github.com/certifi/erlang-certifi/actions/workflows/erlang.yml)
[![Hex](https://img.shields.io/hexpm/v/certifi.svg)](https://hex.pm/packages/certifi)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/certifi)

This Erlang library contains a CA bundle that you can reference in your Erlang
application. This is useful for systems that do not have CA bundles that
Erlang can find itself, or where a uniform set of CAs is valuable.

This an Erlang specific port of [certifi](https://certifi.io/). The CA bundle
is derived from Mozilla's canonical set.

The bundled 118 certificates were verified on 2026-10-23 against the
[Mozilla CA bundle published by curl](https://curl.se/docs/caextract.html),
dated 2026-10-20. The distrusted emSign C1, C3, and G3 roots are excluded.

## Usage

```erlang
CaCerts = certifi:cacerts(),
SslOptions = [{verify, verify_peer},
              {depth, 99},
              {cacerts, CaCerts}],
ssl:connect( "example.com", 443, SslOptions ).
```


You can also retrieve the path to the file and load it by yourself if needed:

```erlang
Path = certifi:cacertfile().
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Development

Update the CA bundle from curl's Mozilla extraction (requires curl and OpenSSL):

```shell
make update
rebar3 clean
rebar3 eunit
```

The update verifies the published SHA-256 checksum and parses the certificates
before replacing `priv/cacerts.pem`. Review changes to the trust roots and update
the test expectations before committing. Clean before rebuilding because the
certificates are embedded into the module at compile time.

Testing:

```shell
rebar3 eunit
```

Documentation:

```shell
rebar3 ex_doc
```
