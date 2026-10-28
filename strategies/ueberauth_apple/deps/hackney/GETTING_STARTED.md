# Getting Started with hackney

This guide walks you through installing hackney and making your first HTTP requests.

## Installation

### Rebar3 (Erlang)

Add hackney to your `rebar.config`:

```erlang
{deps, [hackney]}.
```

### Mix (Elixir)

Add to your `mix.exs`:

```elixir
{:hackney, "~> 4.0"}
```

## Starting hackney

hackney is an OTP application. Start it before making requests:

```erlang
application:ensure_all_started(hackney).
```

## Your First Request

### Simple GET

The response body is returned directly in the response tuple:

```erlang
{ok, 200, Headers, Body} = hackney:get(<<"https://httpbin.org/get">>).
```

### Reading the Body of a Streamed Request

When you stream the request body, `start_response/1` returns a connection
PID. Read the full response body with `hackney:body/1` (or `stream_body/1`
for chunk-by-chunk):

```erlang
{ok, Status, RespHeaders, ConnPid} = hackney:start_response(ConnPid),
{ok, Body} = hackney:body(ConnPid).
```

## POST Requests

### Simple POST

```erlang
URL = <<"https://httpbin.org/post">>,
Headers = [{<<"content-type">>, <<"application/json">>}],
Body = <<"{\"name\": \"hackney\"}">>,
{ok, 200, _, Ref} = hackney:post(URL, Headers, Body).
```

### Form Data

```erlang
hackney:post(URL, [], {form, [{<<"key">>, <<"value">>}]}).
```

### Multipart / File Upload

```erlang
hackney:post(URL, [], {multipart, [
    {<<"field">>, <<"value">>},
    {file, <<"/path/to/file.txt">>}
]}).
```

## Request Options

| Option | Description |
|--------|-------------|
| `with_body` | Return body in response tuple |
| `{pool, Name}` | Use named connection pool |
| `{pool, false}` | Don't use pooling |
| `{connect_timeout, Ms}` | Connection timeout (default: 8000) |
| `{recv_timeout, Ms}` | Response timeout (default: 5000) |
| `async` | Receive response as messages |
| `{follow_redirect, true}` | Follow redirects |
| `insecure` | Skip SSL verification |

## Connection Pooling

hackney pools connections by default:

```erlang
%% Create a pool
hackney_pool:start_pool(api_pool, [{max_connections, 50}]).

%% Use the pool
hackney:get(URL, [], <<>>, [{pool, api_pool}]).

%% Disable pooling
hackney:get(URL, [], <<>>, [{pool, false}]).
```

## Error Handling

```erlang
case hackney:get(URL) of
    {ok, Status, Headers, Body} ->
        handle_response(Status, Headers, Body);
    {error, timeout} ->
        handle_timeout();
    {error, Reason} ->
        handle_error(Reason)
end.
```

## Next Steps

- [HTTP Guide](guides/http_guide.md) - Streaming, async responses, advanced features
- [WebSocket Guide](guides/websocket_guide.md) - Real-time bidirectional communication
- [Migration Guide](guides/MIGRATION.md) - Upgrading from hackney 1.x
