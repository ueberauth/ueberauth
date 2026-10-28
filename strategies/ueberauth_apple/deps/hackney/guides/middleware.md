# Middleware Guide

Hackney supports a RoundTripper-style middleware layer around
`hackney:request/1..5`. A middleware can observe, rewrite, short-circuit
or wrap a request/response pair. The API is a plain fun — no behaviour,
no registry, no deps.

```erlang
-type request() :: #{method  := atom() | binary(),
                     url     := #hackney_url{},
                     headers := [{binary(), binary()}],
                     body    := term(),
                     options := [term()]}.

-type response() :: {ok, integer(), list(), binary()}
                  | {ok, integer(), list()}         %% HEAD
                  | {ok, pid()}                     %% async or streaming upload
                  | {error, term()}.

-type next()       :: fun((request()) -> response()).
-type middleware() :: fun((request(), next()) -> response()).
```

## Chain order

Outermost first. `[A, B, C]` means A wraps B wraps C: the request flows
`A → B → C → transport` and the response unwinds `transport → C → B → A`.
First in the list sees the request first and the response last — same
convention as Go's `http.RoundTripper`, Elixir Plug, Ruby Rack and
Tower-rs.

## Installing a chain

Per-request — overrides the global chain:

```erlang
hackney:request(get, URL, [], <<>>,
                [{middleware, [Mw1, Mw2]}]).
```

Global fallback — applied to every request that doesn't set `middleware`:

```erlang
application:set_env(hackney, middleware, [Mw1, Mw2]).
```

Per-request **replaces** the global list. If you want to compose, merge
explicitly in your own code.

## Scope

Middleware runs around `hackney:request/1..5` only. The low-level
`hackney:connect/*` + `hackney:send_request/2` path bypasses middleware
— it's the raw transport, equivalent to Go's `http.Transport`.

Middleware sees whatever `Next` returns. For async and streaming bodies
that's a bare `{ok, Ref}` or `{ok, ConnPid}`; later message delivery is
the caller's problem. If you want to observe completion in async mode
you'll need to proxy `stream_to`.

If a middleware crashes, the exception propagates to the caller.
Hackney does not wrap user code in `try/catch`.

## Recipes

### Log every call

```erlang
Log = fun(Req, Next) ->
    T0 = erlang:monotonic_time(millisecond),
    Resp = Next(Req),
    Status = case Resp of
                 {ok, S, _, _} -> S;
                 {ok, S, _}    -> S;
                 _             -> error
             end,
    logger:info("~p ~s -> ~p (~pms)",
                [maps:get(method, Req),
                 hackney_url:unparse_url(maps:get(url, Req)),
                 Status,
                 erlang:monotonic_time(millisecond) - T0]),
    Resp
end,
hackney:get(URL, [], <<>>, [{middleware, [Log]}]).
```

### Add a header to every request

```erlang
AddHeader = fun(Req, Next) ->
    H = maps:get(headers, Req),
    Next(Req#{headers := [{<<"x-trace-id">>, trace_id()} | H]})
end.
```

### Retry on transient errors

```erlang
Retry = fun Self(Req, Next) ->
    case Next(Req) of
        {error, timeout} -> Self(Req, Next);
        Other -> Other
    end
end.
```

(For real retries add a counter and a backoff; kept minimal here.)

### Short-circuit / cache

A middleware that doesn't call `Next` returns its own response and the
request never leaves the process:

```erlang
Cache = fun(Req, Next) ->
    Key = cache_key(Req),
    case cache_get(Key) of
        {ok, Resp} -> Resp;
        miss -> cache_put(Key, Next(Req))
    end
end.
```

## Migrating from `hackney_metrics`

The `hackney_metrics` module and its prometheus/dummy backends have been
removed. Hackney no longer emits any metrics itself. Port your metrics
into a middleware:

### Prometheus

```erlang
PromMetrics = fun(Req, Next) ->
    T0 = erlang:monotonic_time(millisecond),
    #hackney_url{host = Host} = maps:get(url, Req),
    HostBin = iolist_to_binary(Host),
    prometheus_counter:inc(hackney_requests_total, [HostBin]),
    prometheus_gauge:inc(hackney_requests_active, [HostBin]),
    Resp = Next(Req),
    prometheus_gauge:dec(hackney_requests_active, [HostBin]),
    prometheus_counter:inc(hackney_requests_finished_total, [HostBin]),
    Dt = (erlang:monotonic_time(millisecond) - T0) / 1000,
    prometheus_histogram:observe(hackney_request_duration_seconds,
                                 [HostBin], Dt),
    Resp
end,
application:set_env(hackney, middleware, [PromMetrics]).
```

Declare the same counter/gauge/histogram at startup as before — the
middleware just emits the numbers, it does not own the registry.

### Telemetry

```erlang
Telemetry = fun(Req, Next) ->
    T0 = erlang:monotonic_time(),
    telemetry:execute([hackney, request, start],
                      #{system_time => erlang:system_time()},
                      #{method => maps:get(method, Req)}),
    try
        Resp = Next(Req),
        telemetry:execute([hackney, request, stop],
                          #{duration => erlang:monotonic_time() - T0},
                          #{result => Resp}),
        Resp
    catch Class:Reason:Stack ->
        telemetry:execute([hackney, request, exception],
                          #{duration => erlang:monotonic_time() - T0},
                          #{kind => Class, reason => Reason,
                            stacktrace => Stack}),
        erlang:raise(Class, Reason, Stack)
    end
end.
```

### Pool observability

`hackney_pool_free_count`, `hackney_pool_in_use_count` and
`hackney_pool_checkouts_total` are gone with the metrics module — they
reflect pool state, not per-request events, and can't be expressed as
middleware. Use `hackney_pool:get_stats/1` from your own metrics
collector to sample pool state at whatever cadence you want:

```erlang
Stats = hackney_pool:get_stats(default),
%% #{name, max, in_use_count, free_count, queue_count}
```
