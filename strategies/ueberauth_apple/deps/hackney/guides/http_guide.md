# HTTP Guide

This guide covers hackney's HTTP features in depth.

## Request Anatomy

```erlang
hackney:request(Method, URL, Headers, Body, Options) ->
    {ok, StatusCode, RespHeaders, Body} | {error, Reason}
```

Body is always returned directly in the response for consistent behavior across HTTP/1.1, HTTP/2, and HTTP/3.

## Request Bodies

### Binary Body

```erlang
hackney:post(URL,
    [{<<"content-type">>, <<"application/json">>}],
    <<"{\"key\": \"value\"}">>
).
```

### Form-Encoded Body

```erlang
hackney:post(URL, [], {form, [{<<"key">>, <<"value">>}]}).
```

### Multipart Body

Multipart requests are used to upload files and send form data together.

#### Basic File Upload

```erlang
hackney:post(URL, [], {multipart, [
    {<<"field">>, <<"value">>},
    {file, <<"/path/to/file.txt">>}
]}).
```

#### File Upload with Custom Field Name

Use `{file, Path, FieldName, ExtraHeaders}` to specify the form field name:

```erlang
%% Upload file to "attachment" field instead of default "file"
hackney:post(URL, [], {multipart, [
    {file, <<"/path/to/document.pdf">>, <<"attachment">>, []}
]}).
```

#### File Upload with Full Control

For complete control over the Content-Disposition header:

```erlang
Path = <<"/path/to/photo.jpg">>,
FName = hackney_bstr:to_binary(filename:basename(Path)),
Disposition = {<<"form-data">>,
               [{<<"name">>, <<"photo">>},
                {<<"filename">>, FName}]},
hackney:post(URL, [], {multipart, [
    {file, Path, Disposition, []}
]}).
```

#### Mixed File and Text Fields

Combine file uploads with text fields:

```erlang
hackney:post(URL, [], {multipart, [
    {file, <<"/path/to/image.jpg">>, <<"image">>, []},
    {<<"title">>, <<"My Photo">>},
    {<<"description">>, <<"A nice picture">>}
]}).
```

#### Text Fields with Explicit Content-Type

Some servers require explicit content-type for text fields:

```erlang
hackney:post(URL, [], {multipart, [
    {file, <<"/path/to/doc.pdf">>, <<"document">>, []},
    {<<"name">>, <<"Report">>, [{<<"content-type">>, <<"text/plain">>}]}
]}).
```

#### Supported Part Formats

| Format | Description |
|--------|-------------|
| `{file, Path}` | File with auto-generated field name |
| `{file, Path, ExtraHeaders}` | File with extra headers |
| `{file, Path, FieldName, ExtraHeaders}` | File with custom field name |
| `{file, Path, {Disposition, Params}, ExtraHeaders}` | Full control |
| `{Name, Data}` | Text field (Data must be binary) |
| `{Name, Data, ExtraHeaders}` | Text field with headers |
| `{Name, Data, Disposition, ExtraHeaders}` | Text field with full control |

### Streaming Body

```erlang
{ok, Ref} = hackney:post(URL, Headers, stream),
ok = hackney:send_body(Ref, <<"chunk1">>),
ok = hackney:send_body(Ref, <<"chunk2">>),
ok = hackney:finish_send_body(Ref),
{ok, Status, RespHeaders, Ref} = hackney:start_response(Ref).
```

## QUERY Requests

QUERY (RFC 10008) is a safe, idempotent method for read-only operations that
need a request body, for example a structured query too large or too
sensitive for the URL. Use it like a POST: the body travels the same way
over HTTP/1.1, HTTP/2, and HTTP/3.

```erlang
hackney:query(
    URL,
    [{<<"content-type">>, <<"application/json">>}],
    Json,
    Options
).
```

The generic form works too:

```erlang
hackney:request(query, URL, Headers, Body, Options).
```

Every request body format above (binary, form, multipart, streaming) works
with QUERY.

## Response Handling

### Read Full Body

```erlang
%% Body is returned directly
{ok, 200, Headers, Body} = hackney:get(URL).
```

### Automatic Decompression

Hackney can automatically decompress gzip and deflate encoded responses:

```erlang
{ok, 200, Headers, Body} = hackney:get(URL, [], <<>>, [
    {auto_decompress, true}
]).
```

When `auto_decompress` is enabled:
- Adds `Accept-Encoding: gzip, deflate` header to requests
- Automatically decompresses the response body based on `Content-Encoding`
- Supports gzip, deflate, and x-gzip encodings
- Non-compressed responses are returned unchanged
- The decompressed body counts against `max_body_size` (see below)

### Response Body Size Limit

A response body returned whole (`hackney:request/5`, `hackney:body/1`) is
capped at 512 MiB, measured after decompression. Past the cap the request
fails with `{error, body_too_large}` instead of buffering the body in memory.
Set `max_body_size` to change the cap, or `infinity` to disable it; for very
large downloads use the streaming API instead.

```erlang
hackney:get(URL, [], <<>>, [{max_body_size, 10 * 1024 * 1024}]).
```

### Stream Response Body (Async Mode)

For incremental body streaming, use async mode:

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [async]),
stream_loop(Ref).

stream_loop(Ref) ->
    receive
        {hackney_response, Ref, {status, Status, _}} ->
            io:format("Status: ~p~n", [Status]),
            stream_loop(Ref);
        {hackney_response, Ref, {headers, Headers}} ->
            io:format("Headers: ~p~n", [Headers]),
            stream_loop(Ref);
        {hackney_response, Ref, done} ->
            ok;
        {hackney_response, Ref, Chunk} when is_binary(Chunk) ->
            process_chunk(Chunk),
            stream_loop(Ref)
    end.
```

## HTTP/2 Support

Hackney automatically negotiates HTTP/2 for HTTPS connections via ALPN.

Response format is consistent across all protocols - body is always returned directly.

### Automatic HTTP/2

```erlang
%% HTTP/2 used automatically when server supports it
{ok, 200, Headers, Body} = hackney:get(<<"https://nghttp2.org/">>).
```

### Force Protocol

```erlang
%% HTTP/2 only
hackney:get(URL, [], <<>>, [{protocols, [http2]}]).

%% HTTP/1.1 only
hackney:get(URL, [], <<>>, [{protocols, [http1]}]).
```

### Detect Protocol

HTTP/2 responses have lowercase header names:

```erlang
case hd(Headers) of
    {<<"date">>, _} -> http2;
    {<<"Date">>, _} -> http1
end.
```

For details on multiplexing, server push, and architecture, see the [HTTP/2 Guide](http2_guide.md).

## Async Responses

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [async]),
receive
    {hackney_response, Ref, {status, Status, _}} -> ok
end,
receive
    {hackney_response, Ref, {headers, Headers}} -> ok
end,
receive
    {hackney_response, Ref, done} -> ok;
    {hackney_response, Ref, Bin} -> ok
end.
```

### Async Once

```erlang
{ok, Ref} = hackney:get(URL, [], <<>>, [{async, once}]),
receive {hackney_response, Ref, Msg} -> ok end,
hackney:stream_next(Ref).  %% Request next message
```

### Stream to Another Process

Use `stream_to` to send async messages to a different process:

```erlang
Receiver = spawn(fun() -> receive_loop() end),
{ok, Ref} = hackney:get(URL, [], <<>>, [
    async,
    {stream_to, Receiver}
]).
```

When `stream_to` is specified:
- The connection is owned by the `stream_to` process, not the caller
- If `stream_to` dies, the connection terminates
- If the original caller dies, the connection continues as long as `stream_to` is alive
- This ensures proper cleanup when the message recipient terminates

## Connection Pooling

### Default Pool

```erlang
hackney:get(URL).  %% Uses default pool
```

### Named Pools

```erlang
hackney_pool:start_pool(my_api, [
    {max_connections, 100},
    {timeout, 150000}
]),
hackney:get(URL, [], <<>>, [{pool, my_api}]).
```

### Pooling HTTPS Connections

Only plain TCP connections are pooled by default: an HTTPS request upgrades a
pooled TCP connection and closes the SSL connection after use. Set
`{ssl_pooling, true}` (per request or via the `ssl_pooling` application env)
to also pool HTTPS/1.1 connections, keyed by their TLS options so only
requests with identical `ssl_options` reuse them:

```erlang
hackney:get(URL, [], <<>>, [{ssl_pooling, true}]).
```

Requests on hackney's default TLS config (no `ssl_options`) also use TLS 1.3
session resumption, so a fresh connection to a recently contacted server
skips the full handshake. Set the `tls_session_resumption` application env to
`false` to disable it. Requests with custom `ssl_options` never resume: the
OTP ticket store is node-wide and a resumed session skips certificate
validation, so it is reserved for the shared default trust config.

## Manual Connection Management

For fine-grained control, you can create a connection and reuse it for multiple requests. This works for both HTTP/1.1 and HTTP/2.

### Get a Connection

```erlang
%% Connect to a host (returns a connection PID)
{ok, ConnPid} = hackney:connect(hackney_ssl, "example.com", 443, []).

%% Or from a URL
{ok, ConnPid} = hackney:connect(<<"https://example.com">>).
```

### Check the Protocol

```erlang
%% See which protocol was negotiated
Protocol = hackney_conn:get_protocol(ConnPid).  %% http1 | http2 | http3
```

### Send Requests on the Connection

```erlang
%% Send multiple requests on the same connection. send_request returns the
%% connection; read each response before sending the next one.
{ok, 200, Headers1, ConnPid} = hackney:send_request(ConnPid, {get, <<"/api/users">>, [], <<>>}).
{ok, Body1} = hackney:body(ConnPid).

{ok, 201, Headers2, ConnPid} = hackney:send_request(ConnPid, {post, <<"/api/users">>,
    [{<<"content-type">>, <<"application/json">>}],
    <<"{\"name\": \"Alice\"}">>}).
{ok, Body2} = hackney:body(ConnPid).
```

Pull a response in chunks instead of reading it whole:

```erlang
{ok, 200, _Headers, ConnPid} = hackney:send_request(ConnPid, {get, <<"/big">>, [], <<>>}).
stream_loop(ConnPid) ->
    case hackney:stream_body(ConnPid) of
        {ok, Chunk} -> handle(Chunk), stream_loop(ConnPid);
        done        -> ok;
        {error, R}  -> {error, R}
    end.
```

### Close the Connection

```erlang
hackney:close(ConnPid).
```

A connection from a pool stays yours between requests; it does not go back to the pool after each response. `hackney:close/1` returns it to the pool when it can be reused, and closes it otherwise. A pooled HTTP/2 connection is shared with other callers: `hackney:close/1` only resets your own streams on it.

### Hand the Connection to Another Process

A connection opened without a pool belongs to the process that opened it and closes when that process exits. To keep it open after that, give it to the process that will use it:

```erlang
ok = hackney_conn:set_owner(ConnPid, NewOwner).
```

### Complete Example

```erlang
%% Reuse a connection for multiple API calls
{ok, Conn} = hackney:connect(hackney_ssl, "api.example.com", 443, []),

%% Check protocol (optional)
case hackney_conn:get_protocol(Conn) of
    http2 -> io:format("Using HTTP/2 multiplexing~n");
    http1 -> io:format("Using HTTP/1.1 keep-alive~n")
end,

%% Make requests, reading each body before the next request
{ok, 200, _, Conn} = hackney:send_request(Conn, {post, <<"/auth">>, [], Credentials}),
{ok, Token} = hackney:body(Conn),
{ok, 200, _, Conn} = hackney:send_request(Conn, {get, <<"/users">>, AuthHeaders, <<>>}),
{ok, Users} = hackney:body(Conn),

%% Clean up
hackney:close(Conn).
```

### HTTP/1.1 vs HTTP/2 Behavior

| Aspect | HTTP/1.1 | HTTP/2 |
|--------|----------|--------|
| Requests | Sequential (one at a time) | Multiplexed (concurrent) |
| Connection | Keep-alive between requests | Single connection, multiple streams |
| Use case | Simple sequential calls | High-throughput parallel calls |

For HTTP/2 multiplexing (parallel requests on one connection), see the [HTTP/2 Guide](http2_guide.md).

## Redirects

```erlang
{ok, 200, Headers, Body} = hackney:get(URL, [], <<>>, [
    {follow_redirect, true},
    {max_redirect, 5}
]).
```

## Proxies

### HTTP Proxy

```erlang
hackney:get(URL, [], <<>>, [
    {proxy, <<"http://proxy:8080">>}
]).
```

### Environment Variables

hackney reads `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` automatically.

## SSL/TLS

### Custom CA Certificate

```erlang
hackney:get(URL, [], <<>>, [
    {ssl_options, [{cacertfile, "/path/to/ca.crt"}]}
]).
```

### Skip Verification

```erlang
hackney:get(URL, [], <<>>, [
    {ssl_options, [{verify, verify_none}]}
]).
```

### SNI

The TLS `server_name_indication` defaults to the request host and is omitted
for IP-literal hosts (RFC 6066). Set it explicitly to present a different
name; the value drives both the wire SNI and the certificate
hostname-verification target. Use `disable` to suppress SNI without weakening
verification. This applies to HTTP/1.1, HTTP/2 and HTTP/3.

```erlang
hackney:get("https://93.184.216.34", [], <<>>, [
    {ssl_options, [{server_name_indication, "example.com"}]}
]).
```

## Timeouts

```erlang
hackney:get(URL, [], <<>>, [
    {connect_timeout, 5000},
    {recv_timeout, 30000}
]).
```

## Cookies

```erlang
hackney:get(URL, [], <<>>, [{cookie, <<"session=abc">>}]).

%% Parse response cookies
{ok, 200, Headers, _} = hackney:get(URL),
Cookies = hackney:cookies(Headers).
```

## Basic Authentication

```erlang
hackney:get(URL, [], <<>>, [
    {basic_auth, {<<"user">>, <<"pass">>}}
]).
```

## Next Steps

- [HTTP/2 Guide](http2_guide.md) - Multiplexing, server push, architecture
- [WebSocket Guide](websocket_guide.md)
- [Migration Guide](MIGRATION.md)
