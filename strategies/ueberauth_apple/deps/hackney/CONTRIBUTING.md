# Contributing to hackney

Thank you for your interest in contributing to hackney!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/hackney.git`
3. Create a branch: `git checkout -b my-feature`
4. Make your changes
5. Run tests: `rebar3 eunit`
6. Push and open a pull request

## Pull Request Guidelines

### Title Format

We use [Conventional Commits](https://www.conventionalcommits.org/) for PR titles:

```
<type>: <description>
```

**Types:**

| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or updating tests |
| `chore` | Maintenance tasks, dependencies |
| `security` | Security fix |

**Examples:**

- `feat: add HTTP/3 connection pooling`
- `fix: handle timeout in async responses`
- `docs: update WebSocket guide`
- `refactor: simplify connection state machine`
- `perf: reduce memory allocation in header parsing`
- `security: update SSL certificate bundle`

### Description

Include in your PR description:

- **What** the change does
- **Why** the change is needed
- **How** to test it (if applicable)

## Development Setup

### Requirements

- Erlang/OTP 27+
- rebar3

### Building

```sh
rebar3 compile
```

### Building with QUIC support

QUIC/HTTP3 support is included automatically via the pure Erlang `quic` dependency - no additional build steps required.

### Running Tests

```sh
# All tests
rebar3 eunit

# Specific test module
rebar3 eunit --module=hackney_conn_tests

# With verbose output
rebar3 eunit --verbose
```

### Running Dialyzer

```sh
rebar3 dialyzer
```

## Code Style

- Follow existing code conventions
- Keep functions short and focused
- Add specs for exported functions
- Update documentation for API changes

## Reporting Issues

When reporting bugs, include:

- Erlang/OTP version (`erl -version`)
- hackney version
- Minimal reproduction case
- Expected vs actual behavior

## Questions?

Open an issue or reach out to the maintainers.
