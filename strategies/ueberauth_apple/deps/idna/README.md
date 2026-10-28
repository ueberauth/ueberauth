# erlang-idna

[![Hex.pm](https://img.shields.io/hexpm/v/idna.svg)](https://hex.pm/packages/idna)
[![Hex.pm](https://img.shields.io/hexpm/dt/idna.svg)](https://hex.pm/packages/idna)
[![CI](https://github.com/benoitc/erlang-idna/actions/workflows/ci.yml/badge.svg)](https://github.com/benoitc/erlang-idna/actions/workflows/ci.yml)

A pure Erlang IDNA implementation following [RFC 5891](https://tools.ietf.org/html/rfc5891).

**Current Unicode version: 17.0.0**

## Features

- **IDNA 2008** compliance with [RFC 5891](https://tools.ietf.org/html/rfc5891)
- **IDNA 2003** backward compatibility
- **UTS #46** compatibility processing ([Unicode Technical Standard #46](https://unicode.org/reports/tr46/))
- Full label validation:
  - NFC normalization check
  - Hyphen placement rules
  - Leading combining marks check
  - Contextual rules (CONTEXTJ/CONTEXTO)
  - Bidirectional text rules ([RFC 5893](https://tools.ietf.org/html/rfc5893))

## Installation

### Rebar3

Add to your `rebar.config`:

```erlang
{deps, [
    {idna, "7.1.0"}
]}.
```

### Mix (Elixir)

Add to your `mix.exs`:

```elixir
defp deps do
  [
    {:idna, "~> 7.1"}
  ]
end
```

## Quick Start

### Encoding (Unicode → ASCII/Punycode)

```erlang
%% Basic encoding
1> idna:encode("münchen.de").
"xn--mnchen-3ya.de"

2> idna:encode("βόλος.com").
"xn--nxasmq5b.com"

%% Japanese domain with UTS #46 processing
3> idna:encode("日本語.JP", [uts46]).
"xn--wgv71a119e.jp"
```

### Decoding (ASCII/Punycode → Unicode)

```erlang
1> idna:decode("xn--mnchen-3ya.de").
"münchen.de"

2> idna:decode("xn--nxasmq5b.com").
"βόλος.com"
```

## Options

The `encode/2` and `decode/2` functions accept an options list:

| Option | Default | Description |
|--------|---------|-------------|
| `uts46` | `false` | Enable [UTS #46](https://unicode.org/reports/tr46/) compatibility processing |
| `std3_rules` | `false` | Enforce STD3 ASCII rules |
| `transitional` | `false` | Use transitional processing (IDNA 2003 compatibility) |
| `strict` | `false` | Only use ASCII period (`.`) as label separator |

### Examples with Options

```erlang
%% UTS #46 processing normalizes and maps characters
1> idna:encode("Ⅷ.com", [uts46]).
"viii.com"

%% Transitional processing (ß → ss)
2> idna:encode("faß.de", [uts46, transitional]).
"fass.de"

%% Non-transitional (default) preserves ß
3> idna:encode("faß.de", [uts46]).
"xn--fa-hia.de"

%% STD3 rules reject certain characters
4> idna:encode("_example.com", [uts46, std3_rules]).
** exception exit: {invalid_codepoint,95}
```

## API Reference

### Main Functions

| Function | Description |
|----------|-------------|
| `encode/1,2` | Encode a Unicode domain name to ASCII (Punycode) |
| `decode/1,2` | Decode an ASCII domain name to Unicode |
| `alabel/1` | Convert a single label to ASCII form (A-label) |
| `ulabel/1` | Convert a single label to Unicode form (U-label) |

### Validation Functions

| Function | Description |
|----------|-------------|
| `check_label/1,4` | Validate a domain label |
| `check_nfc/1` | Check NFC normalization |
| `check_hyphen/1` | Check hyphen placement rules |
| `check_context/1` | Check contextual rules |
| `check_initial_combiner/1` | Check for leading combining marks |
| `check_label_length/1` | Check label length (max 63 octets) |

### Compatibility Functions (Deprecated)

| Function | Replacement |
|----------|-------------|
| `to_ascii/1` | Use `encode/1` |
| `to_unicode/1` | Use `decode/1` |
| `from_ascii/1` | Use `decode/1` |
| `utf8_to_ascii/1` | Use `encode/1` |

## Documentation

Full API documentation is available on [HexDocs](https://hexdocs.pm/idna/).

Generate documentation locally:

```bash
rebar3 ex_doc
```

## Updating Unicode Data

This library currently supports **Unicode 17.0.0**. To update to a new Unicode version:

### 1. Download Unicode Data Files

Replace `VERSION` with the target version (e.g., `17.0.0`):

```bash
# Core Unicode data files
wget -O uc_spec/UnicodeData.txt https://www.unicode.org/Public/VERSION/ucd/UnicodeData.txt
wget -O uc_spec/ArabicShaping.txt https://www.unicode.org/Public/VERSION/ucd/ArabicShaping.txt
wget -O uc_spec/Scripts.txt https://www.unicode.org/Public/VERSION/ucd/Scripts.txt

# IDNA-specific files (path structure as of Unicode 17.0.0)
wget -O uc_spec/IdnaMappingTable.txt https://www.unicode.org/Public/VERSION/idna/IdnaMappingTable.txt
wget -O test/IdnaTestV2.txt https://www.unicode.org/Public/VERSION/idna/IdnaTestV2.txt
```

### 2. Generate IDNA Table

Use the [kjd/idna](https://github.com/kjd/idna) Python tool:

```bash
git clone --depth 1 https://github.com/kjd/idna.git /tmp/kjd-idna
python3 /tmp/kjd-idna/tools/idna-data make-table --version VERSION > uc_spec/idna-table.txt
rm -rf /tmp/kjd-idna
```

If the tool needs additional files, use the `--source` option:

```bash
python3 /tmp/kjd-idna/tools/idna-data make-table --version VERSION --source uc_spec > uc_spec/idna-table.txt
```

### 3. Regenerate Erlang Modules

```bash
cd uc_spec
./gen_idnadata_mod.escript
./gen_idna_table_mod.escript
./gen_idna_mapping_mod.escript
cd ..
```

### 4. Run Tests

```bash
rebar3 eunit
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
