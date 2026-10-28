

# hackney - HTTP client library in Erlang #

Copyright (c) 2012-2025 Benoît Chesneau.

__Version:__ 1.24.1

# hackney

**hackney** is an HTTP client library for Erlang.

[![Build Status](https://github.com/benoitc/hackney/workflows/build/badge.svg)](https://github.com/benoitc/hackney/actions?query=workflow%3Abuild)
[![Hex pm](http://img.shields.io/hexpm/v/hackney.svg?style=flat)](https://hex.pm/packages/hackney)

## Main features:

- no message passing (except for asynchronous responses): response is
  directly streamed to the current process and state is kept in a `#client{}` record.
- binary streams
- SSL support
- Keepalive handling
- basic authentication
- stream the response and the requests
- fetch a response asynchronously
- multipart support (streamed or not)
- chunked encoding support
- Can send files using the sendfile API
- Optional socket pool
- REST syntax: `hackney:Method(URL)` (where a method can be get, post, put, delete, ...)

**Supported versions** of Erlang are 25.3 and above. 

> Note: This is a work in progress, see the
[TODO](http://github.com/benoitc/hackney/blob/master/TODO.md) for more
information on what still needs to be done.

#### Useful modules are:

- [`hackney`](https://hexdocs.pm/hackney/hackney.html): main module. It contains all HTTP client functions.
- [`hackney_http`](https://hexdocs.pm/hackney/hackney_http.html): HTTP parser in pure Erlang. This parser is able
to parse HTTP responses and requests in a streaming fashion. If not set
it will be autodetected if it's a request or a response that's needed.

- [`hackney_headers`](https://hexdocs.pm/hackney/hackney_headers.html) Module to manipulate HTTP headers.
- [`hackney_cookie`](https://hexdocs.pm/hackney/hackney_cookie.html): Module to manipulate cookies.
- [`hackney_multipart`](https://hexdocs.pm/hackney/hackney_multipart.html): Module to encode/decode multipart.
- [`hackney_url`](https://hexdocs.pm/hackney/hackney_url.html): Module to parse and create URIs.
- [`hackney_date`](https://hexdocs.pm/hackney/hackney_date.html): Module to parse HTTP dates.

Read the [NEWS](https://hexdocs.pm/hackney/news.html) file
to get the last changelog.

## Installation

Download the sources from our [Github
repository](http://github.com/benoitc/hackney)

To build the application simply run 'rebar3 compile'.

To run tests run 'rebar3 eunit'.
To generate doc, run 'rebar3 edoc'.

Or add it to your rebar config

```erlang

{deps, [
    ....
    {hackney, ".*", {git, "git://github.com/benoitc/hackney.git", {branch, "master"}}}
]}.
```

## Basic usage

The basic usage of hackney is:

### Start hackney

hackney is an
[OTP](http://www.erlang.org/doc/design_principles/users_guide.html)
application. You have to start it first before using any of the functions.
The hackney application will start the default socket pool for you.

To start in the console run:

```erlang-repl

$ ./rebar3 shell

```

It is suggested that you install rebar3 user-wide as described [here](http://blog.erlware.org/rebar3-features-part-1-local-install-and-upgrade/).
This fixes zsh (and maybe other shells) escript-related bugs. Also this should speed things up.

```erlang

> application:ensure_all_started(hackney).
ok
```

It will start hackney and all of the application it depends on:

```erlang

application:start(crypto),
application:start(public_key),
application:start(ssl),
application:start(hackney).
```

Or add hackney to the applications property of your .app in a release

### Simple request

Do a simple request that will return a client state:

```erlang

Method = get,
URL = <<"https://friendpaste.com">>,
Headers = [],
Payload = <<>>,
Options = [],
{ok, StatusCode, RespHeaders, ClientRef} = hackney:request(Method, URL,
                                                        Headers, Payload,
                                                        Options).
```

The request method returns the tuple `{ok, StatusCode, Headers, ClientRef}`
or `{error, Reason}`. A `ClientRef` is simply a reference to the current
request that you can reuse.

If you prefer the REST syntax, you can also do:

```erlang
hackney:Method(URL, Headers, Payload, Options)
```

where `Method`, can be any HTTP method in lowercase.

### Read the body

```erlang
{ok, Body} = hackney:body(ClientRef).
```

`hackney:body/1` fetch the body. To fetch it by chunk you can use the
`hackney:stream_body/1` function:

```erlang

read_body(MaxLength, Ref, Acc) when MaxLength > byte_size(Acc) ->
	case hackney:stream_body(Ref) of
		{ok, Data} ->
			read_body(MaxLength, Ref, << Acc/binary, Data/binary >>);
		done ->
			{ok, Acc};
		{error, Reason} ->
			{error, Reason}
	end.
```

> Note: you can also fetch a multipart response using the functions
> `hackney:stream_multipart/1` and  `hackney:skip_multipart/1`.

> Note 2: using the `with_body` option will return the body directly instead of a reference.

### Reuse a connection

By default all connections are created and closed dynamically by
hackney but sometimes you may want to reuse the same reference for your
connections. It's especially useful if you just want to handle serially a
couple of requests.

> A closed connection will automatically be reconnected.

#### To create a connection:

```erlang

Transport = hackney_ssl,
Host = << "friendpaste.com" >>,
Port = 443,
Options = [],
{ok, ConnRef} = hackney:connect(Transport, Host, Port, Options).
```

> To create a connection that will use an HTTP proxy use
> `hackney_http_proxy:connect_proxy/5` instead.

#### To get local and remote ip and port information of a connection:

```erlang

> hackney:peername(ConnRef).
> hackney:sockname(ConnRef).
```

#### Make a request

Once you created a connection use the `hackney:send_request/2` function
to make a request:

```erlang

ReqBody = << "{	\"snippet\": \"some snippet\" }" >>,
ReqHeaders = [{<<"Content-Type">>, <<"application/json">>}],
NextPath = <<"/">>,
NextMethod = post,
NextReq = {NextMethod, NextPath, ReqHeaders, ReqBody},
{ok, _, _, ConnRef} = hackney:send_request(ConnRef, NextReq),
{ok, Body1} = hackney:body(ConnRef).
```

Here we are posting a JSON payload to '/' on the friendpaste service to
create a paste. Then we close the client connection.

> If your connection supports keepalive the connection will be kept open until you close it exclusively.

### Send a body

hackney helps you send different payloads by passing different terms as
the request body:

- `{form, PropList}` : To send a form
- `{multipart, Parts}` : to send your body using the multipart API. Parts
  follow this format:
  - `eof`: end the multipart request
  - `{file, Path}`: to stream a file
  - `{file, Path, ExtraHeaders}`: to stream a file
  - `{file, Path, Name, ExtraHeaders}` : to send a file with DOM element name and extra headers
  - `{Name, Content}`: to send a full part
  - `{Name, Content, ExtraHeaders}`: to send a full part
  - `{mp_mixed, Name, MixedBoundary}`: To notify we start a part with 
    a mixed multipart content
  - `{mp_mixed_eof, MixedBoundary}`: To notify we end a part with a
    mixed multipart content
- `{file, File}` : To send a file
- Bin: To send a binary or an iolist

> Note: to send a chunked request, just add the `Transfer-Encoding: chunked`
> header to your headers. Binary and Iolist bodies will be then sent using
> the chunked encoding.

#### Send the body by yourself

While the default is to directly send the request and fetch the status
and headers, if the body is set as the atom `stream` the request and
send_request function will return {ok, Client}. Then you can use the
function `hackney:send_body/2` to stream the request body and
`hackney:start_response/1` to initialize the response.

> Note: The function `hackney:start_response/1` will only accept
> a Client that is waiting for a response (with a response state
> equal to the atom `waiting`).

Ex:

```erlang

ReqBody = << "{
      \"id\": \"some_paste_id2\",
      \"rev\": \"some_revision_id\",
      \"changeset\": \"changeset in unidiff format\"
}" >>,
ReqHeaders = [{<<"Content-Type">>, <<"application/json">>}],
Path = <<"https://friendpaste.com/">>,
Method = post,
{ok, ClientRef} = hackney:request(Method, Path, ReqHeaders, stream, []),
ok  = hackney:send_body(ClientRef, ReqBody),
{ok, _Status, _Headers, ClientRef} = hackney:start_response(ClientRef),
{ok, Body} = hackney:body(ClientRef),
```

> Note: to send a **multipart** body  in a streaming fashion use the
> `hackney:send_multipart_body/2` function.

### Get a response asynchronously

Since the 0.6 version, hackney is able to fetch the response
asynchronously using the `async` option:

```erlang

Url = <<"https://friendpaste.com/_all_languages">>,
Opts = [async],
LoopFun = fun(Loop, Ref) ->
        receive
            {hackney_response, Ref, {status, StatusInt, Reason}} ->
                io:format("got status: ~p with reason ~p~n", [StatusInt,
                                                              Reason]),
                Loop(Loop, Ref);
            {hackney_response, Ref, {headers, Headers}} ->
                io:format("got headers: ~p~n", [Headers]),
                Loop(Loop, Ref);
            {hackney_response, Ref, done} ->
                ok;
            {hackney_response, Ref, Bin} ->
                io:format("got chunk: ~p~n", [Bin]),
                Loop(Loop, Ref);

            Else ->
                io:format("else ~p~n", [Else]),
                ok
        end
    end.

{ok, ClientRef} = hackney:get(Url, [], <<>>, Opts),
LoopFun(LoopFun, ClientRef).
```

> **Note 1**: When `{async, once}` is used the socket will receive only once.
> To receive the other messages use the function `hackney:stream_next/1`.

> **Note 2**:  Asynchronous responses automatically checkout the socket at the end.

> **Note 3**:  At any time you can go back and receive your response
> synchronously using the function `hackney:stop_async/1` See the
> example [test_async_once2](https://github.com/benoitc/hackney/blob/master/examples/test_async_once2.erl) for the usage.

> **Note 4**:  When the option `{follow_redirect, true}` is passed to
> the request, you will receive the following messages on valid
> redirection:
> - `{redirect, To, Headers}`
> - `{see_other, To, Headers}` for status 303 and POST requests.

> **Note 5**: You can send the messages to another process by using the
> option `{stream_to, Pid}` .

### Use the default pool

Hackney uses socket pools to reuse connections globally. By default,
hackney uses a pool named `default`. You may want to use different
pools in your application which allows you to maintain a group of
connections. To use a different pool, do the following:

```erlang

Method = get,
URL = <<"https://friendpaste.com">>,
Headers = [],
Payload = <<>>,
Options = [{pool, mypool}],
{ok, StatusCode, RespHeaders, ClientRef} = hackney:request(Method, URL, Headers,
                                                        Payload, Options).
```

By adding the tuple `{pool, mypool}` to the options, hackney will use
the connections stored in that pool. The pool gets started automatically
the first time it is used. You can also explicitly configure and start
the pool like this:

```erlang

PoolName = mypool,
Options = [{timeout, 150000}, {max_connections, 100}],
ok = hackney_pool:start_pool(PoolName, Options),
```

`timeout` is the time we keep the connection alive in the pool,
`max_connections` is the number of connections maintained in the pool. Each
connection in a pool is monitored and closed connections are removed
automatically.

To close a pool do:

```erlang
hackney_pool:stop_pool(PoolName).
```

> Note: Sometimes you want to disable the default pool in your app
> without having to set the client option each time. You can now do this
> by setting the hackney application environment key `use_default_pool`
> to false. This means that hackney will not use socket pools unless
> specifically requested using the `pool` option as described above.
>
> To disable socket pools for a single request, specify the option
> `{pool, false}`.

### Use a custom pool handler.

Since the version 0.8 it is now possible to use your own Pool to
maintain the connections in hackney.

A pool handler is a module that handles the `hackney_pool_handler`
behaviour.

See for example the
[hackney_disp](https://github.com/benoitc/hackney_disp) a load-balanced
Pool dispatcher based on dispcount.

> Note: for now you can't force the pool handler / client.

### Automatically follow a redirection

If the option `{follow_redirect, true}` is given to the request, the
client will be able to automatically follow the redirection and
retrieve the body. The maximum number of connections can be set using the
`{max_redirect, Max}` option. Default is 5.

The client will follow redirects on 301, 302 & 307 if the method is
get or head. If another method is used the tuple
`{ok, maybe_redirect, Status, Headers, Client}` will be returned. It will
only follow 303 redirects (see other) if the method is a POST.

Last Location is stored in the `location` property of the client state.

ex:

```erlang

Method = get,
URL = "http://friendpaste.com/",
ReqHeaders = [{<<"accept-encoding">>, <<"identity">>}],
ReqBody = <<>>,
Options = [{follow_redirect, true}, {max_redirect, 5}],
{ok, S, H, Ref} = hackney:request(Method, URL, ReqHeaders,
                                     ReqBody, Options),
{ok, Body1} = hackney:body(Ref).
```

### Use SSL/TLS with self signed certificates

Hackney uses CA bundles adapted from Mozilla by
[certifi](https://hex.pm/packages/certifi).
Recognising an organisation specific (self signed) certificates is possible
by providing the necessary `ssl_options`. Note that `ssl_options` overrides all
options passed to the ssl module.

ex (>= Erlang 21):

```erlang

CACertFile = <path_to_self_signed_ca_bundle>,
CrlCheckTimeout = 5000,
SSLOptions = [
{verify, verify_peer},
{versions, ['tlsv1.2']},
{cacertfile, CACertFile},
{crl_check, peer},
{crl_cache, {ssl_crl_cache, {internal, [{http, CrlCheckTimeout}]}}},
{customize_hostname_check,
  [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],

Method = get,
URL = "http://my-organisation/",
ReqHeaders = [],
ReqBody = <<>>,
Options = [{ssl_options, SSLoptions}],
{ok, S, H, Ref} = hackney:request(Method, URL, ReqHeaders,
                                  ReqBody, Options),

%% To provide client certificate:

CertFile = <path_to_client_certificate>,
KeyFile = <path_to_client_private_key>,
SSLOptions1 = SSLoptions ++ [
{certfile, CertFile},
{keyfile, KeyFile}
],
Options1 = [{ssl_options, SSLoptions1}],
{ok, S1, H1, Ref1} = hackney:request(Method, URL, ReqHeaders,
                                     ReqBody, Options1).

```

### Proxy a connection

#### HTTP Proxy

To use an HTTP tunnel add the option `{proxy, ProxyUrl}` where
`ProxyUrl` can be a simple url or an `{Host, Port}` tuple. If you need
to authenticate set the option `{proxy_auth, {User, Password}}`.

#### SOCKS5 proxy

Hackney supports the connection via a socks5 proxy. To set a socks5
proxy, use the following settings:

- `{proxy, {socks5, ProxyHost, ProxyPort}}`: to set the host and port of
  the proxy to connect.
- `{socks5_user, Username}`: to set the user used to connect to the proxy
- `{socks5_pass, Password}`: to set the password used to connect to the proxy

SSL and TCP connections can be forwarded via a socks5 proxy. hackney is
automatically upgrading to an SSL connection if needed.

### Metrics

Hackney offers the following metrics

You can enable metrics collection by adding a `mod_metrics` entry to hackney's
app config. Metrics are disabled by default. The module specified must have an
API matching that of the hackney metrics module.

To  use [folsom](https://github.com/boundary/folsom), specify `{mod_metrics,
folsom}`, or if you want to use
[exometer](https://github.com/feuerlabs/exometer), specify`{mod_metrics,
exometer}` and ensure that folsom or exometer is in your code path and has
been started.

#### Generic Hackney metrics

|Name                     |Type   | Description                        |
|-------------------------|-------|------------------------------------|
|hackney.nb_requests      |counter| Number of running requests         |
|hackney.total_requests   |counter| Total number of requests           |
|hackney.finished_requests|counter| Total number of requests finished  |

#### Metrics per Hosts

|Name                              |Type     | Description                               |
|----------------------------------|---------|-------------------------------------------|
|hackney.HOST.nb_requests          |counter  | Number of running requests                |
|hackney.HOST.request_time         |histogram| Request time                              |
|hackney.HOST.connect_time         |histogram| Connect time                              |
|hackney.HOST.response_time        |histogram| Response time                             |
|hackney.HOST.connect_timeout      |counter  | Number of connect timeout                 |
|hackney.HOST.connect_error        |counter  | Number of timeout errors                  |
|hackney_pool.HOST.new_connection  |counter  | Number of new pool connections per host   |
|hackney_pool.HOST.reuse_connection|counter  | Number of reused pool connections per host|

#### Metrics per Pool

|Name                              |Type     | Description                                                          |
|----------------------------------|---------|----------------------------------------------------------------------|
|hackney_pool.POOLNAME.take_rate   |meter    | meter recording rate at which a connection is retrieved from the pool|
|hackney_pool.POOLNAME.no_socket   |counter  | Count of new connections                                             |
|hackney_pool.POOLNAME.in_use_count|histogram| How many connections from the pool are used                          |
|hackney_pool.POOLNAME.free_count  |histogram| Number of free sockets in the pool                                   |
|hackney_pool.POOLNAME.queue_count |histogram| queued clients                                                       |

## Contribute

For issues, comments or feedback please [create an
issue](http://github.com/benoitc/hackney/issues).

### Notes for developers

If you want to contribute patches or improve the docs, you will need to
build hackney using the `rebar_dev.config`  file. It can also be built
using the **Makefile**:

```sh

$ rebar3 update
$ rebar3 compile

```

For successfully running the hackney test suite locally it is necessary to
install [httpbin](https://pypi.python.org/pypi/httpbin/0.2.0).

An example installation using virtualenv::

```sh

$ mkvirtualenv hackney
$ pip install gunicorn httpbin

```

Running the tests:

```
$ gunicorn --daemon --pid httpbin.pid httpbin:app
$ rebar3 eunit
$ kill `cat httpbin.pid`
```
