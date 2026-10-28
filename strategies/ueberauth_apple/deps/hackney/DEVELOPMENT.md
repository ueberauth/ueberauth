# Hackney Development Guide

This guide covers development setup, testing, and contributing to hackney.

## Prerequisites

- Erlang/OTP 27 or later
- rebar3 3.24.0 or later

### Platform-specific requirements

**macOS:**
```bash
brew install erlang
```

**Ubuntu/Debian:**
```bash
sudo apt-get install erlang build-essential
```

**FreeBSD:**
```bash
pkg install erlang-runtime28 rebar3
```

## Building

Clone the repository:

```bash
git clone https://github.com/benoitc/hackney.git
cd hackney
```

Build the project:

```bash
rebar3 compile
```

This will compile all Erlang source files and fetch dependencies (including the pure Erlang QUIC library for HTTP/3 support).

## Running Tests

Run all tests:

```bash
rebar3 eunit
```

Run specific test modules:

```bash
rebar3 eunit --module=hackney_h3_low_level_tests
rebar3 eunit --module=hackney_http3_tests
```

### Running tests with httpbin

Some tests require the httpbin server. Start it before running tests:

```bash
pip3 install httpbin gunicorn
gunicorn -b 127.0.0.1:8000 httpbin:app &
rebar3 eunit
```

### Fault injection and chaos tests

Use these when you change the pool or the connection state machine. Ordinary
integration tests only exercise servers that answer, so they never see a
connection that stalls, crashes, or dies at the wrong moment, which is where
pool failures come from: the pool dials and stops connections from inside its
own gen_server, and an unguarded call that exits takes the pool down along with
every caller using it.

Three pieces make up the harness:

| Module | What it does |
| --- | --- |
| `hackney_fault_transport` | A transport that behaves like `hackney_tcp` until you arm a fault on one of its callbacks |
| `hackney_crash_sentinel` | Captures crash reports so a test can assert a process survived, even with `error_logger:tty(false)` |
| `hackney_pool_safety_tests` | Walks the compiled abstract code and fails on any call into `hackney_conn` that is not inside a `try` |

Arm a fault, drive the code path, assert the pool is untouched:

```erlang
ok = hackney_crash_sentinel:start(),
hackney_fault_transport:set(connect, {slow_error, 300}),
Opts = [{pool, my_pool}, {connect_timeout, 30}],
{error, connect_timeout} =
    hackney_pool:checkout("127.0.0.1", 8080, hackney_fault_transport, Opts),
hackney_crash_sentinel:assert_no_crash_from(hackney_pool:find_pool(my_pool)),
ok = hackney_fault_transport:clear().
```

Available faults: `{sleep, Ms}`, `{slow_error, Ms}`, `{hang, Ms}`, `{error, Reason}`,
`crash`. Any callback can be armed: `connect`, `send`, `recv`, `setopts`,
`close`, `controlling_process`.

Run the fault matrix, the multiplexed (HTTP/2, HTTP/3) checkout faults, and the
randomized chaos run:

```bash
rebar3 eunit --module=hackney_pool_fault_tests
rebar3 eunit --module=hackney_pool_h2h3_fault_tests
rebar3 eunit --module=hackney_pool_chaos_tests
```

The HTTP/2 and HTTP/3 connections are shared rather than checked out, so one
bad connection is felt by every caller for that host. Those scenarios wedge a
registered connection with `sys:suspend/1` and require the pool to answer
`none` within the probe budget instead of waiting on it.

Soak the chaos run harder, for example before a release:

```bash
HACKNEY_CHAOS_WORKERS=64 HACKNEY_CHAOS_ROUNDS=2000 \
    rebar3 eunit --module=hackney_pool_chaos_tests
```

If `hackney_pool_safety_tests` fails, route the new call through a guarded
helper in `hackney_pool` (`connect_connection/2`, `set_owner/2`, `stop_conn/1`,
`checkin_info/1`) rather than relaxing the check.

## Local Docker Testing

A Dockerfile is provided for testing on Linux locally, which mirrors the GitHub CI environment.

### Building the Docker image

```bash
docker build -f Dockerfile.test -t hackney-test .
```

### Running tests in Docker

Run all tests:

```bash
docker run --rm hackney-test
```

Run specific test modules:

```bash
docker run --rm hackney-test bash -c "rebar3 eunit --module=hackney_h3_low_level_tests"
```

### Interactive debugging in Docker

Start an interactive shell:

```bash
docker run --rm -it hackney-test bash
```

Then you can:
- Run tests manually: `rebar3 eunit`
- Start an Erlang shell: `rebar3 shell`

## QUIC/HTTP3 Development

HTTP/3 support uses a pure Erlang QUIC implementation from the `quic` dependency.

### Source Files

- `src/hackney_h3.erl` - HTTP/3 high-level + low-level adapter over `quic_h3`

The underlying QUIC implementation is in the `quic` dependency which provides:
- TLS 1.3 handshake
- QUIC packet encoding/decoding
- Congestion control
- Loss recovery

## Code Style

### Erlang

- Follow standard Erlang conventions
- Use edoc for function documentation
- Keep lines under 100 characters

## Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Run tests locally and in Docker
5. Commit with clear messages
6. Push and create a pull request

### Commit Message Format

```
type: short description

Longer description if needed.
```

Types: `fix`, `feat`, `docs`, `test`, `refactor`, `ci`, `chore`

## Continuous Integration

CI runs on:
- Linux x86_64 (OTP 27.2, 28.0)
- Linux ARM64 (OTP 27.2)
- macOS ARM64 (OTP 27)
- FreeBSD 14.2 (OTP 28)

All CI jobs must pass before merging.
