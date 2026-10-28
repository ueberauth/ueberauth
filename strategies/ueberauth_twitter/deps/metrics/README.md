

# metrics: A generic interface to different metrics systems in Erlang. #

Copyright (c) 2016 Benoît Chesneau.

__Version:__ 1.0.0

# metrics

A generic interface to folsom or exometer or any compliant interface. This
application have been extracted from
[hackney](https://github.com/benoitc/hackney).

Currently support [Folsom](https://github.com/folsom-project/folsom) and [Exometer](https://github.com/Feuerlabs/exometer)

[![Hex pm](http://img.shields.io/hexpm/v/metrics.svg?style=flat)](https://hex.pm/packages/metrics)

Example:
--------

```erlang


%% initialize an engine
Engine = metrics:init(metrics_exometer),

%% create a counter named TestCounter
ok = metrics:new(Engine, counter, TestCounter),

%% Increment the counter

metrics:increment_counter(Engine, TestCounter).
```

## Documentation

Full doc is available in the [`metrics`](http://github.com/benoitc/erlang-metrics/blob/master/doc/metrics.md) module.

## Build

```
$ rebar3 compile
```



## Modules ##


<table width="100%" border="0" summary="list of modules">
<tr><td><a href="http://github.com/benoitc/erlang-metrics/blob/master/doc/metrics.md" class="module">metrics</a></td></tr>
<tr><td><a href="http://github.com/benoitc/erlang-metrics/blob/master/doc/metrics_dummy.md" class="module">metrics_dummy</a></td></tr>
<tr><td><a href="http://github.com/benoitc/erlang-metrics/blob/master/doc/metrics_exometer.md" class="module">metrics_exometer</a></td></tr>
<tr><td><a href="http://github.com/benoitc/erlang-metrics/blob/master/doc/metrics_folsom.md" class="module">metrics_folsom</a></td></tr></table>

