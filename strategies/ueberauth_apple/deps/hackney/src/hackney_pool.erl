%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2009, Erlang Training and Consulting Ltd.
%%% Copyright (c) 2012-2024, Benoît Chesneau <benoitc@e-engura.org>

%% @doc Pool of connection processes.
%%
%% This module manages hackney_conn processes in a pool. Instead of storing
%% raw sockets, it tracks connection process pids. Idle timeout is handled
%% by the connection processes themselves (gen_statem state_timeout).
%%
-module(hackney_pool).
-behaviour(gen_server).

%% PUBLIC API
-export([start/0,
         checkout/4,
         checkout_ssl/4,
         checkin/2,
         discard/2]).

%% HTTP/2 connection pooling
-export([checkout_h2/4,
         register_h2/5,
         unregister_h2/2,
         unregister_h2_all/0]).

%% HTTP/3 connection pooling
-export([checkout_h3/4,
         register_h3/5,
         unregister_h3/2,
         get_h3_session/4,
         store_h3_session/5,
         delete_h3_session/4]).

-export([
         get_stats/1,
         start_pool/2,
         stop_pool/1,
         find_pool/1,
         notify/2
        ]).

-export([count/1, count/2,
         max_connections/1,
         set_max_connections/2,
         timeout/1,
         set_timeout/2,
         prewarm/3,
         prewarm/4,
         host_stats/3,
         child_spec/2]).

-export([start_link/2]).

%% For internal use
-export([to_pool_name/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-include("hackney.hrl").
-include_lib("hackney_internal.hrl").

-record(state, {
    name,
    max_connections,
    keepalive_timeout,
    prewarm_count,
    %% Available connection processes: #{Key => [Pid]}
    available = #{},
    %% In-use connections: #{Pid => Key}
    in_use = #{},
    %% Connections handed out undialed, while their requester dials them:
    %% #{Pid => {Key, RequesterMonitorRef}}. They move to in_use on dial_ok.
    dialing = #{},
    %% Pid to monitor ref mapping: #{Pid => MonitorRef}
    pid_monitors = #{},
    %% Hosts that have been activated (prewarm triggered): sets:set(Key)
    activated_hosts = sets:new(),
    %% HTTP/2 connections: #{Key => Pid} - one multiplexed connection per host
    %% These connections are shared across callers (not checked out exclusively)
    h2_connections = #{},
    %% HTTP/3 connections: #{Key => Pid} - one multiplexed QUIC connection per host
    %% These connections are shared across callers (not checked out exclusively)
    h3_connections = #{},
    %% HTTP/3 0-RTT/resumption session tickets: #{Key => Ticket} keyed by
    %% h3_connection_key/4. Replayed on the next connect to resume.
    h3_sessions = #{}
}).

-define(DEFAULT_MAX_CONNECTIONS, 50).
-define(DEFAULT_KEEPALIVE_TIMEOUT, 2000).  % 2 seconds max idle
-define(DEFAULT_PREWARM_COUNT, 4).         % Connections to maintain per host
-define(STOP_CONN_TIMEOUT, 100).           % Max wait for a conn to stop
-define(PREWARM_CONNECT_TIMEOUT, 5000).    % Dial budget for a prewarm conn
%% Every question the pool asks a conn about its own health is answered from
%% the conn's state, so a healthy conn answers at once. A conn that does not
%% is wedged, and waiting on it from inside the pool gen_server blocks every
%% caller of the pool, not just the one that asked: treat slow as unusable.
-define(PROBE_TIMEOUT, 250).

start() ->
    %% Create ETS table to store pool pid by name
    _ = ets:new(?MODULE, [set, public, named_table, {read_concurrency, true}]),
    ok.

%% @doc Checkout a connection process from the pool.
%% Returns {ok, PoolInfo, Pid} where Pid is a hackney_conn process.
-spec checkout(Host :: string(), Port :: non_neg_integer(),
               Transport :: module(), Options :: list()) ->
    {ok, term(), pid()} | {error, term()}.
checkout(Host, Port, Transport, Options) ->
    Requester = self(),
    try
        do_checkout(Requester, Host, Port, Transport, Options)
    catch
        exit:{timeout, _} ->
            ?report_trace("pool: checkout timeout", []),
            {error, checkout_timeout};
        _:Error ->
            ?report_trace("pool: checkout failure", [{error, Error}]),
            {error, checkout_failure}
    end.

do_checkout(Requester, Host, Port, Transport, Opts) ->
    ConnectTimeout = proplists:get_value(connect_timeout, Opts, 8000),
    CheckoutTimeout = proplists:get_value(checkout_timeout, Opts, ConnectTimeout),
    PoolName = proplists:get_value(pool, Opts, default),
    Pool = find_pool(PoolName, Opts),
    Key = connection_key(Host, Port, Transport),

    PoolInfo = {PoolName, Key, Pool, Transport},
    case gen_server:call(Pool, {checkout, Key, Requester, Opts}, CheckoutTimeout) of
        {ok, Pid} ->
            {ok, PoolInfo, Pid};
        {new, Pid} ->
            case dial(Pool, Pid, ConnectTimeout) of
                ok -> {ok, PoolInfo, Pid};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error;
        {'EXIT', {timeout, _}} ->
            {error, checkout_timeout}
    end.

%% @doc Checkout a connection for an HTTPS request with SSL pooling enabled.
%% Reuses a pooled upgraded HTTPS/1.1 connection when the hash of its TLS
%% options (`tls_key' in Options) matches exactly, returning `ready'.
%% Otherwise a TCP connection is handed out as `needs_upgrade' and the
%% caller performs the TLS upgrade.
-spec checkout_ssl(Host :: string(), Port :: non_neg_integer(),
                   Transport :: module(), Options :: list()) ->
    {ok, term(), pid(), ready | needs_upgrade} | {error, term()}.
checkout_ssl(Host, Port, Transport, Options) ->
    Requester = self(),
    try
        do_checkout_ssl(Requester, Host, Port, Transport, Options)
    catch
        exit:{timeout, _} ->
            ?report_trace("pool: checkout_ssl timeout", []),
            {error, checkout_timeout};
        _:Error ->
            ?report_trace("pool: checkout_ssl failure", [{error, Error}]),
            {error, checkout_failure}
    end.

do_checkout_ssl(Requester, Host, Port, Transport, Opts) ->
    ConnectTimeout = proplists:get_value(connect_timeout, Opts, 8000),
    CheckoutTimeout = proplists:get_value(checkout_timeout, Opts, ConnectTimeout),
    PoolName = proplists:get_value(pool, Opts, default),
    Pool = find_pool(PoolName, Opts),
    TlsKey = proplists:get_value(tls_key, Opts, default),
    SslKey = connection_key(Host, Port, Transport, TlsKey),

    PoolInfo = {PoolName, SslKey, Pool, Transport},
    case gen_server:call(Pool, {checkout_ssl, SslKey, Requester, Opts}, CheckoutTimeout) of
        {ok, Pid, ConnState} ->
            {ok, PoolInfo, Pid, ConnState};
        {new, Pid, needs_upgrade} ->
            case dial(Pool, Pid, ConnectTimeout) of
                ok -> {ok, PoolInfo, Pid, needs_upgrade};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error;
        {'EXIT', {timeout, _}} ->
            {error, checkout_timeout}
    end.

%% @doc Return a connection process to the pool.
-spec checkin(PoolInfo :: term(), Pid :: pid()) -> ok.
checkin({_PoolName, _Key, Pool, _Transport}, Pid) ->
    gen_server:cast(Pool, {checkin, nil, Pid}),
    ok.

%% @doc Stop tracking a checked-out connection the caller is about to stop,
%% without releasing its load-regulation slot: the caller releases it. Used
%% when the TLS upgrade of a checked-out connection fails; otherwise the
%% pool would release the slot a second time when the connection dies.
-spec discard(PoolInfo :: term(), Pid :: pid()) -> ok.
discard({_PoolName, _Key, Pool, _Transport}, Pid) ->
    _ = pool_call(Pool, {discard, Pid}),
    ok.

%%====================================================================
%% HTTP/2 Connection Pooling
%%====================================================================

%% @doc Get an existing HTTP/2 connection for a host/port, or 'none' if not available.
%% HTTP/2 connections are shared (multiplexed) across callers.
-spec checkout_h2(Host :: string(), Port :: non_neg_integer(),
                  Transport :: module(), Options :: list()) ->
    {ok, pid()} | none.
checkout_h2(Host, Port, Transport, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    ConnectTimeout = proplists:get_value(connect_timeout, Options, 8000),
    Pool = find_pool(PoolName, Options),
    Key = h2_connection_key(Host, Port, Transport, Options),
    try
        gen_server:call(Pool, {checkout_h2, Key}, ConnectTimeout)
    catch
        exit:{timeout, _} -> none;
        _:_ -> none
    end.

%% @doc Register an HTTP/2 connection in the pool for sharing.
%% Called after ALPN negotiation confirms HTTP/2.
-spec register_h2(Host :: string(), Port :: non_neg_integer(),
                  Transport :: module(), Pid :: pid(), Options :: list()) -> ok.
register_h2(Host, Port, Transport, Pid, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    Pool = find_pool(PoolName, Options),
    Key = h2_connection_key(Host, Port, Transport, Options),
    gen_server:cast(Pool, {register_h2, Key, Pid}),
    ok.

%% @doc Remove an HTTP/2 connection from the pool (e.g., on GOAWAY).
-spec unregister_h2(Pid :: pid(), Options :: list()) -> ok.
unregister_h2(Pid, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    Pool = find_pool(PoolName, Options),
    gen_server:cast(Pool, {unregister_h2, Pid}),
    ok.

%% @doc Remove all HTTP/2 connections from the default pool.
%% Used for testing to ensure clean state between tests.
-spec unregister_h2_all() -> ok.
unregister_h2_all() ->
    Pool = find_pool(default, []),
    gen_server:call(Pool, unregister_h2_all).

%%====================================================================
%% HTTP/3 Connection Pooling
%%====================================================================

%% @doc Get an existing HTTP/3 connection for a host/port, or 'none' if not available.
%% HTTP/3 connections are shared (multiplexed) across callers via QUIC streams.
-spec checkout_h3(Host :: string(), Port :: non_neg_integer(),
                  Transport :: module(), Options :: list()) ->
    {ok, pid()} | none.
checkout_h3(Host, Port, Transport, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    ConnectTimeout = proplists:get_value(connect_timeout, Options, 8000),
    Pool = find_pool(PoolName, Options),
    Key = h3_connection_key(Host, Port, Transport, Options),
    try
        gen_server:call(Pool, {checkout_h3, Key}, ConnectTimeout)
    catch
        exit:{timeout, _} -> none;
        _:_ -> none
    end.

%% @doc Register an HTTP/3 connection in the pool for sharing.
%% Called after QUIC connection is established with HTTP/3.
-spec register_h3(Host :: string(), Port :: non_neg_integer(),
                  Transport :: module(), Pid :: pid(), Options :: list()) -> ok.
register_h3(Host, Port, Transport, Pid, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    Pool = find_pool(PoolName, Options),
    Key = h3_connection_key(Host, Port, Transport, Options),
    gen_server:cast(Pool, {register_h3, Key, Pid}),
    ok.

%% @doc Remove an HTTP/3 connection from the pool (e.g., on connection close).
-spec unregister_h3(Pid :: pid(), Options :: list()) -> ok.
unregister_h3(Pid, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    Pool = find_pool(PoolName, Options),
    gen_server:cast(Pool, {unregister_h3, Pid}),
    ok.

%% @doc Look up a cached HTTP/3 0-RTT/resumption session ticket for a host/port.
-spec get_h3_session(Host :: string(), Port :: non_neg_integer(),
                     Transport :: module(), Options :: list()) ->
    {ok, term()} | none.
get_h3_session(Host, Port, Transport, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    Pool = find_pool(PoolName, Options),
    Key = h3_connection_key(Host, Port, Transport, Options),
    try
        gen_server:call(Pool, {get_h3_session, Key})
    catch
        _:_ -> none
    end.

%% @doc Cache an HTTP/3 session ticket for a host/port for later resumption.
-spec store_h3_session(Host :: string(), Port :: non_neg_integer(),
                       Transport :: module(), Ticket :: term(),
                       Options :: list()) -> ok.
store_h3_session(Host, Port, Transport, Ticket, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    Pool = find_pool(PoolName, Options),
    Key = h3_connection_key(Host, Port, Transport, Options),
    gen_server:cast(Pool, {store_h3_session, Key, Ticket}),
    ok.

%% @doc Invalidate a cached HTTP/3 session ticket (e.g. after 0-RTT rejection).
-spec delete_h3_session(Host :: string(), Port :: non_neg_integer(),
                        Transport :: module(), Options :: list()) -> ok.
delete_h3_session(Host, Port, Transport, Options) ->
    PoolName = proplists:get_value(pool, Options, default),
    Pool = find_pool(PoolName, Options),
    Key = h3_connection_key(Host, Port, Transport, Options),
    gen_server:cast(Pool, {delete_h3_session, Key}),
    ok.

get_stats(Pool) ->
    gen_server:call(find_pool(Pool), stats).

%% @doc start a pool
start_pool(Name, Options) ->
    case find_pool(Name, Options) of
        Pid when is_pid(Pid) ->
            ok;
        Error ->
            Error
    end.

%% @doc stop a pool
stop_pool(Name) ->
    case find_pool(Name) of
        undefined ->
            ok;
        _Pid ->
            case supervisor:terminate_child(hackney_sup, Name) of
                ok ->
                    _ = supervisor:delete_child(hackney_sup, Name),
                    ets:delete(hackney_pool, Name),
                    ok;
                Error ->
                    Error
            end
    end.

notify(Pool, Msg) ->
    case find_pool(Pool) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.

%% @doc return a child spec suitable for embedding your pool in the supervisor
child_spec(Name, Options0) ->
    Options = [{name, Name} | Options0],
    {Name, {hackney_pool, start_link, [Name, Options]},
     permanent, 10000, worker, [hackney_pool]}.

%% @doc get the number of connections in the pool
count(Name) ->
    case find_pool(Name) of
        undefined -> 0;
        Pid -> gen_server:call(Pid, count)
    end.

%% @doc get the number of connections in the pool for a key. A legacy
%% `{Host, Port, Transport}' tuple aggregates over all TLS buckets of the
%% triple; a `{Host, Port, Transport, TlsKey}' tuple counts one bucket.
count(Name, Key) ->
    case find_pool(Name) of
        undefined -> 0;
        Pid -> gen_server:call(Pid, {count, Key})
    end.

%% @doc get max pool size
max_connections(Name) ->
    case find_pool(Name) of
        undefined -> 0;
        Pid -> gen_server:call(Pid, max_connections)
    end.

%% @doc change the pool size
set_max_connections(Name, NewSize) ->
    gen_server:cast(find_pool(Name), {set_maxconn, NewSize}).

%% @doc get timeout
timeout(Name) ->
    case find_pool(Name) of
        undefined -> 0;
        Pid -> gen_server:call(Pid, timeout)
    end.

%% @doc change the connection timeout
set_timeout(Name, NewTimeout) ->
    gen_server:cast(find_pool(Name), {set_timeout, NewTimeout}).

%% @doc Prewarm connections to a host (default count from pool settings)
%% Starts the pool if it doesn't exist.
-spec prewarm(atom(), string() | binary(), inet:port_number()) -> ok.
prewarm(PoolName, Host, Port) ->
    Pool = find_pool(PoolName, []),
    gen_server:cast(Pool, {prewarm, Host, Port}).

%% @doc Prewarm a specific number of connections to a host
%% Starts the pool if it doesn't exist.
-spec prewarm(atom(), string() | binary(), inet:port_number(), non_neg_integer()) -> ok.
prewarm(PoolName, Host, Port, Count) ->
    Pool = find_pool(PoolName, []),
    gen_server:cast(Pool, {prewarm, Host, Port, Count}).

%% @doc Get per-host connection statistics.
%% Returns a proplist with:
%% - active: number of active requests (from load_regulation)
%% - in_use: connections checked out from pool
%% - free: connections available in pool
-spec host_stats(atom(), string() | binary(), inet:port_number()) ->
    [{atom(), non_neg_integer()}].
host_stats(PoolName, Host, Port) ->
    Active = hackney_load_regulation:current(Host, Port),
    case find_pool(PoolName) of
        undefined ->
            [{active, Active}, {in_use, 0}, {free, 0}];
        Pool ->
            {InUse, Free} = gen_server:call(Pool, {host_stats, Host, Port}),
            [{active, Active}, {in_use, InUse}, {free, Free}]
    end.

to_pool_name(Name) when is_atom(Name) ->
    list_to_atom("hackney_pool_" ++ atom_to_list(Name));
to_pool_name(Name) when is_list(Name) ->
    list_to_atom("hackney_pool_" ++ Name);
to_pool_name(Name) when is_binary(Name) ->
    to_pool_name(binary_to_list(Name)).

%% @private
do_start_pool(Name, Options) ->
    Spec = child_spec(Name, Options),
    case supervisor:start_child(hackney_sup, Spec) of
        {ok, Pid} ->
            Pid;
        {error, {already_started, _}} ->
            find_pool(Name, Options)
    end.

find_pool(Name) ->
    case ets:lookup(?MODULE, Name) of
        [] ->
            undefined;
        [{_, Pid}] ->
            Pid
    end.

find_pool(Name, Options) ->
    case ets:lookup(?MODULE, Name) of
        [] ->
            do_start_pool(Name, Options);
        [{_, Pid}] ->
            Pid
    end.

start_link(Name, Options0) ->
    Options = hackney_util:maybe_apply_defaults([max_connections, timeout],
                                                Options0),
    gen_server:start_link(?MODULE, [Name, Options], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Name, Options]) ->
    %% Trap exits so a supervisor shutdown (stop_pool -> terminate_child) runs
    %% terminate/2 instead of killing the pool outright. terminate/2 releases the
    %% load_regulation slots of in_use connections; without trapping exits it
    %% would be skipped and those per-host slots would leak.
    process_flag(trap_exit, true),
    MaxConn = case proplists:get_value(pool_size, Options) of
                  undefined ->
                      proplists:get_value(max_connections, Options, ?DEFAULT_MAX_CONNECTIONS);
                  Size ->
                      Size
              end,
    %% keepalive_timeout: max idle time for pooled connections (capped at 2s)
    %% Also accept 'timeout' for backward compatibility
    RawTimeout = case proplists:get_value(keepalive_timeout, Options) of
                     undefined ->
                         proplists:get_value(timeout, Options, ?DEFAULT_KEEPALIVE_TIMEOUT);
                     KT ->
                         KT
                 end,
    KeepaliveTimeout = min(RawTimeout, ?DEFAULT_KEEPALIVE_TIMEOUT),

    %% prewarm_count: number of TCP connections to maintain per host
    %% Check pool options first, then app env, then default
    PrewarmCount = case proplists:get_value(prewarm_count, Options) of
                       undefined ->
                           hackney_app:get_app_env(prewarm_count, ?DEFAULT_PREWARM_COUNT);
                       PC ->
                           PC
                   end,

    %% register the module
    ets:insert(?MODULE, {Name, self()}),

    {ok, #state{name=Name, max_connections=MaxConn,
                keepalive_timeout=KeepaliveTimeout, prewarm_count=PrewarmCount}}.

handle_call(stats, _From, State) ->
    {reply, handle_stats(State), State};

handle_call(count, _From, #state{available=Available, in_use=InUse}=State) ->
    AvailCount = maps:fold(fun(_, Pids, Acc) -> Acc + length(Pids) end, 0, Available),
    {reply, AvailCount + maps:size(InUse), State};

handle_call(timeout, _From, #state{keepalive_timeout=Timeout}=State) ->
    {reply, Timeout, State};

handle_call(max_connections, _From, #state{max_connections=MaxConn}=State) ->
    {reply, MaxConn, State};

handle_call({count, {Host, Port, Transport}}, _From, #state{available=Available}=State) ->
    %% Legacy 3-tuple key: aggregate over all TLS buckets for the triple
    Count = maps:fold(
        fun({H, P, T, _K}, Pids, Acc) when H =:= Host, P =:= Port, T =:= Transport ->
                Acc + length(Pids);
           (_, _, Acc) -> Acc
        end, 0, Available),
    {reply, Count, State};

handle_call({count, Key}, _From, #state{available=Available}=State) ->
    Count = case maps:find(Key, Available) of
                {ok, Pids} -> length(Pids);
                error -> 0
            end,
    {reply, Count, State};

handle_call({host_stats, Host, Port}, _From, #state{available=Available, in_use=InUse}=State) ->
    %% Count in_use and free for this host (any transport)
    HostLower = string:lowercase(Host),
    InUseCount = maps:fold(
        fun(_Pid, {H, P, _T, _K}, Acc) when H =:= HostLower, P =:= Port -> Acc + 1;
           (_, _, Acc) -> Acc
        end, 0, InUse),
    FreeCount = maps:fold(
        fun({H, P, _T, _K}, Pids, Acc) when H =:= HostLower, P =:= Port -> Acc + length(Pids);
           (_, _, Acc) -> Acc
        end, 0, Available),
    {reply, {InUseCount, FreeCount}, State};

handle_call({checkout, Key, Requester, Opts}, _From, State) ->
    #state{name=PoolName, max_connections=MaxConn,
           available=Available, in_use=InUse} = State,

    TotalInUse = maps:size(InUse),

    ?report_trace("pool: checkout request", [{pool, PoolName}, {key, Key},
        {total_in_use, TotalInUse}, {max_conn, MaxConn}]),

    case find_available(Key, Available) of
        {ok, Pid, Available2} ->
            %% Found an available connection - update owner to new requester
            ?report_debug("pool: reusing connection", [{pool, PoolName}, {pid, Pid}]),
            case set_owner(Pid, Requester) of
                ok ->
                    InUse2 = maps:put(Pid, Key, InUse),
                    {reply, {ok, Pid}, State#state{available=Available2, in_use=InUse2}};
                {error, _} ->
                    %% #850: the connection closed between is_ready and
                    %% set_owner (server-side close race). It is already out of
                    %% Available2; drop it and start a fresh connection rather
                    %% than crashing the pool on a bad match.
                    case spawn_connection(Key, Requester, Opts, State#state{available=Available2}) of
                        {ok, Pid2, State2} ->
                            {reply, {new, Pid2}, State2};
                        {error, Reason} ->
                            {reply, {error, Reason}, State#state{available=Available2}}
                    end
            end;
        none ->
            %% No pooled connection available. Per-host concurrency is already
            %% capped by hackney_load_regulation, so start a connection even
            %% when in_use has reached max_connections: it is an overflow
            %% connection, closed at checkin rather than pooled (see do_checkin).
            %% max_connections bounds the warm/idle pool, not the number of
            %% concurrent connections.
            ?report_trace("pool: starting new connection",
                          [{pool, PoolName}, {overflow, TotalInUse >= MaxConn}]),
            case spawn_connection(Key, Requester, Opts, State) of
                {ok, Pid, State2} ->
                    {reply, {new, Pid}, State2};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;

handle_call({checkout_ssl, SslKey, Requester, Opts}, _From, State) ->
    #state{name=PoolName, available=Available, in_use=InUse} = State,

    ?report_trace("pool: checkout_ssl request", [{pool, PoolName}, {key, SslKey},
        {total_in_use, maps:size(InUse)}]),

    case find_available_ssl(SslKey, Available) of
        {ok, Pid, Available2} ->
            %% Found a pooled SSL connection with the same TLS options hash
            ?report_debug("pool: reusing ssl connection", [{pool, PoolName}, {pid, Pid}]),
            case set_owner(Pid, Requester) of
                ok ->
                    InUse2 = maps:put(Pid, SslKey, InUse),
                    {reply, {ok, Pid, ready},
                     State#state{available=Available2, in_use=InUse2}};
                {error, _} ->
                    %% #850: the connection closed between is_ready and
                    %% set_owner. It is already out of Available2; fall back
                    %% to the TCP bucket with the dead conn dropped.
                    checkout_ssl_fallback(SslKey, Requester, Opts,
                                          State#state{available=Available2})
            end;
        none ->
            checkout_ssl_fallback(SslKey, Requester, Opts, State)
    end;

%% The requester finished dialing a conn handed out by a checkout miss. A conn
%% that died in between is no longer in dialing: the caller gets an error and
%% releases its slot itself.
handle_call({dial_ok, Pid}, _From, #state{dialing=Dialing, in_use=InUse}=State) ->
    case maps:take(Pid, Dialing) of
        {{Key, ReqMon}, Dialing2} ->
            erlang:demonitor(ReqMon, [flush]),
            {reply, ok, State#state{dialing=Dialing2,
                                    in_use=maps:put(Pid, Key, InUse)}};
        error ->
            {reply, {error, closed}, State}
    end;

%% The requester's dial failed. Forget the conn without releasing its slot:
%% the caller releases it on the checkout error, as for any failed checkout.
handle_call({dial_failed, Pid}, _From, #state{dialing=Dialing}=State) ->
    case maps:take(Pid, Dialing) of
        {{_Key, ReqMon}, Dialing2} ->
            erlang:demonitor(ReqMon, [flush]),
            {reply, ok, forget_monitor(Pid, State#state{dialing=Dialing2})};
        error ->
            {reply, ok, State}
    end;

handle_call({discard, Pid}, _From, #state{in_use=InUse}=State) ->
    {reply, ok, forget_monitor(Pid, State#state{in_use=maps:remove(Pid, InUse)})};

handle_call({checkin_sync, Pid}, _From, State) ->
    %% Synchronous checkin - caller waits for acknowledgement
    %% Legacy format without SSL flag - need to query connection (may deadlock if called from connection)
    State2 = do_checkin(Pid, State),
    {reply, ok, State2};

handle_call({checkin_sync, Pid, ShouldClose}, _From, State) ->
    %% Synchronous checkin with "should close" flag - avoids deadlock
    %% ShouldClose is true if connection was SSL upgraded or is a proxy tunnel
    State2 = do_checkin_with_close_flag(Pid, ShouldClose, State),
    {reply, ok, State2};

handle_call({checkout_h2, Key}, _From, #state{h2_connections = H2Conns} = State) ->
    %% HTTP/2 checkout - return existing connection if available.
    %% Liveness check includes both process_alive and gen_statem state, so a
    %% hackney_conn that already transitioned to `closed` (e.g. after an h2
    %% GOAWAY) but has not yet been removed via 'DOWN' is not handed out.
    case maps:get(Key, H2Conns, undefined) of
        undefined ->
            {reply, none, State};
        Pid ->
            case h2_conn_usable(Pid) of
                true ->
                    {reply, {ok, Pid}, State};
                false ->
                    H2Conns2 = maps:remove(Key, H2Conns),
                    {reply, none, State#state{h2_connections = H2Conns2}}
            end
    end;

handle_call({checkout_h3, Key}, _From, #state{h3_connections = H3Conns} = State) ->
    %% HTTP/3 checkout - return existing connection if available
    case maps:get(Key, H3Conns, undefined) of
        undefined ->
            {reply, none, State};
        Pid ->
            %% Verify connection is still alive
            case erlang:is_process_alive(Pid) of
                true ->
                    {reply, {ok, Pid}, State};
                false ->
                    %% Connection died, remove from pool
                    H3Conns2 = maps:remove(Key, H3Conns),
                    {reply, none, State#state{h3_connections = H3Conns2}}
            end
    end;

handle_call({get_h3_session, Key}, _From, #state{h3_sessions = Sessions} = State) ->
    case maps:get(Key, Sessions, undefined) of
        undefined -> {reply, none, State};
        Ticket -> {reply, {ok, Ticket}, State}
    end;

handle_call(unregister_h2_all, _From, State) ->
    %% Clear all HTTP/2 connections (for testing)
    {reply, ok, State#state{h2_connections = #{}}}.

handle_cast({checkin, _PoolInfo, Pid}, State) ->
    State2 = do_checkin(Pid, State),
    {noreply, State2};

handle_cast({set_maxconn, MaxConn}, State) ->
    {noreply, State#state{max_connections=MaxConn}};

handle_cast({set_timeout, NewTimeout}, State) ->
    %% Cap at 2 seconds
    Capped = min(NewTimeout, ?DEFAULT_KEEPALIVE_TIMEOUT),
    {noreply, State#state{keepalive_timeout=Capped}};

handle_cast({prewarm, Host, Port}, #state{prewarm_count=Count}=State) ->
    State2 = do_prewarm(Host, Port, Count, State),
    {noreply, State2};

handle_cast({prewarm, Host, Port, Count}, State) ->
    State2 = do_prewarm(Host, Port, Count, State),
    {noreply, State2};

handle_cast({prewarm_checkin, Pid, Key}, State) ->
    %% Add a prewarmed connection to the pool
    #state{available=Available, pid_monitors=PidMonitors} = State,
    %% Set owner to pool
    hackney_conn:set_owner_async(Pid, self()),
    %% Monitor the connection
    MonRef = erlang:monitor(process, Pid),
    PidMonitors2 = maps:put(Pid, MonRef, PidMonitors),
    %% Add to available
    Available2 = maps:update_with(Key, fun(Pids) -> [Pid | Pids] end, [Pid], Available),
    {noreply, State#state{available=Available2, pid_monitors=PidMonitors2}};

handle_cast({register_h2, Key, Pid}, State) ->
    %% Register an HTTP/2 connection for sharing
    #state{h2_connections = H2Conns, pid_monitors = PidMonitors} = State,
    %% Monitor the connection if not already monitored
    PidMonitors2 = case maps:is_key(Pid, PidMonitors) of
        true -> PidMonitors;
        false ->
            MonRef = erlang:monitor(process, Pid),
            maps:put(Pid, MonRef, PidMonitors)
    end,
    %% Store HTTP/2 connection
    H2Conns2 = maps:put(Key, Pid, H2Conns),
    {noreply, State#state{h2_connections = H2Conns2, pid_monitors = PidMonitors2}};

handle_cast({unregister_h2, Pid}, State) ->
    %% Remove an HTTP/2 connection from the pool
    State2 = do_unregister_h2(Pid, State),
    {noreply, State2};

handle_cast({register_h3, Key, Pid}, State) ->
    %% Register an HTTP/3 connection for sharing
    #state{h3_connections = H3Conns, pid_monitors = PidMonitors} = State,
    %% Monitor the connection if not already monitored
    PidMonitors2 = case maps:is_key(Pid, PidMonitors) of
        true -> PidMonitors;
        false ->
            MonRef = erlang:monitor(process, Pid),
            maps:put(Pid, MonRef, PidMonitors)
    end,
    %% Store HTTP/3 connection
    H3Conns2 = maps:put(Key, Pid, H3Conns),
    {noreply, State#state{h3_connections = H3Conns2, pid_monitors = PidMonitors2}};

handle_cast({unregister_h3, Pid}, State) ->
    %% Remove an HTTP/3 connection from the pool
    State2 = do_unregister_h3(Pid, State),
    {noreply, State2};

handle_cast({store_h3_session, Key, Ticket}, #state{h3_sessions = Sessions} = State) ->
    {noreply, State#state{h3_sessions = maps:put(Key, Ticket, Sessions)}};

handle_cast({delete_h3_session, Key}, #state{h3_sessions = Sessions} = State) ->
    {noreply, State#state{h3_sessions = maps:remove(Key, Sessions)}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, Reason}, #state{dialing=Dialing}=State) ->
    case take_dialing_requester(MonRef, Dialing) of
        {ConnPid, Key, Dialing2} ->
            %% The requester died while dialing: nobody is left to release its
            %% slot. The conn stops on its own when it sees its owner go.
            ?report_trace("pool: requester DOWN while dialing",
                          [{pid, Pid}, {conn, ConnPid}]),
            {Host, Port} = key_host_port(Key),
            hackney_load_regulation:release(Host, Port),
            {noreply, State#state{dialing=Dialing2}};
        none ->
            conn_down(Pid, Reason, State)
    end;

handle_info(_Info, State) ->
    {noreply, State}.

%% @private A connection process died: remove it from every map that holds
%% it. The pool monitors every conn from spawn_connection on, so this runs
%% whatever stage the conn died in. Only the slot depends on the stage: an
%% in_use conn releases it here; a dialing conn does not, its requester sees
%% the dial fail and releases it. A conn whose requester died mid-dial has
%% already left dialing (its slot released then) and stops on its own once
%% it sees its owner gone; that DOWN only clears pid_monitors.
conn_down(Pid, Reason, State) ->
    #state{name=PoolName, available=Available, in_use=InUse, pid_monitors=PidMonitors,
           h2_connections=H2Conns, h3_connections=H3Conns, dialing=Dialing} = State,
    Dialing2 = case maps:take(Pid, Dialing) of
        {{_Key, ReqMon}, D} ->
            erlang:demonitor(ReqMon, [flush]),
            D;
        error ->
            Dialing
    end,
    ?report_trace("pool: connection DOWN", [{pool, PoolName}, {pid, Pid}, {reason, Reason},
        {was_in_use, maps:is_key(Pid, InUse)}]),

    %% Remove from available pools
    Available2 = maps:fold(
        fun(Key, Pids, Acc) ->
            case lists:delete(Pid, Pids) of
                [] -> maps:remove(Key, Acc);
                Pids2 -> maps:put(Key, Pids2, Acc)
            end
        end,
        Available,
        Available
    ),

    %% Remove from in_use and release load_regulation slot if it was checked out
    InUse2 = case maps:take(Pid, InUse) of
        {Key, NewInUse} ->
            %% Connection died while in use - release the load_regulation slot
            {Host, Port} = key_host_port(Key),
            hackney_load_regulation:release(Host, Port),
            NewInUse;
        error ->
            InUse
    end,

    %% Remove from HTTP/2 connections if present
    H2Conns2 = maps:fold(
        fun(Key, ConnPid, Acc) ->
            case ConnPid of
                Pid -> maps:remove(Key, Acc);
                _ -> Acc
            end
        end,
        H2Conns,
        H2Conns
    ),

    %% Remove from HTTP/3 connections if present
    H3Conns2 = maps:fold(
        fun(Key, ConnPid, Acc) when is_pid(ConnPid) ->
            case ConnPid of
                Pid -> maps:remove(Key, Acc);
                _ -> Acc
            end;
           (_Key, _Val, Acc) -> Acc
        end,
        H3Conns,
        H3Conns
    ),

    PidMonitors2 = maps:remove(Pid, PidMonitors),
    {noreply, State#state{available=Available2, in_use=InUse2, pid_monitors=PidMonitors2,
                          h2_connections=H2Conns2, h3_connections=H3Conns2,
                          dialing=Dialing2}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{available=Available, in_use=InUse,
                         h2_connections=H2Conns, h3_connections=H3Conns,
                         pid_monitors=PidMonitors, dialing=Dialing}) ->
    %% Stop conns still being dialed. Their requesters see the dial fail and
    %% release their own slots.
    maps:foreach(fun(Pid, _) -> stop_conn(Pid) end, Dialing),

    %% Stop all available connections
    maps:foreach(
        fun(_Key, Pids) ->
            lists:foreach(fun(Pid) ->
                stop_conn(Pid)
            end, Pids)
        end,
        Available
    ),

    %% Release the load_regulation slot of every checked-out connection and stop
    %% it. Without this, stopping a pool while requests are in flight orphans the
    %% in_use conns: the pool's DOWN handler (which would release) is gone, so the
    %% global per-host slots leak and that host's concurrency cap is starved
    %% node-wide. Each Key carries the conn's host/port.
    maps:foreach(
        fun(Pid, Key) ->
            {Host, Port} = key_host_port(Key),
            hackney_load_regulation:release(Host, Port),
            stop_conn(Pid)
        end,
        InUse
    ),

    %% Stop all HTTP/2 connections
    maps:foreach(
        fun(_Key, Pid) ->
            stop_conn(Pid)
        end,
        H2Conns
    ),

    %% Stop all HTTP/3 connections
    maps:foreach(
        fun(_Key, Pid) ->
            stop_conn(Pid)
        end,
        H3Conns
    ),

    %% Demonitor all
    maps:foreach(fun(_Pid, MonRef) -> erlang:demonitor(MonRef, [flush]) end, PidMonitors),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private Key for pooled connections. The 4th element buckets pooled SSL
%% connections by the hash of their effective TLS options (ssl_pooling);
%% plain TCP connections all use the `default' bucket.
connection_key(Host, Port, Transport) ->
    connection_key(Host, Port, Transport, default).

connection_key(Host0, Port, Transport, TlsKey) ->
    Host = string:lowercase(Host0),
    {Host, Port, Transport, TlsKey}.

%% @private Host and port of a pool connection key.
key_host_port({Host, Port, _Transport, _TlsKey}) ->
    {Host, Port}.

%% @private Key for shared HTTP/2 connections. Includes the hash of the
%% effective TLS options (tls_key) so requests with different ssl_options
%% never share a connection. Callers that pass no tls_key all land in the
%% `default' bucket, preserving the previous behavior.
h2_connection_key(Host0, Port, Transport, Options) ->
    Host = string:lowercase(Host0),
    {Host, Port, Transport, proplists:get_value(tls_key, Options, default)}.

%% @private Key for shared HTTP/3 connections and cached 0-RTT session
%% tickets. Includes the hash of the QUIC trust projection (h3_tls_key) so
%% requests with differing trust configs never share a connection, and a
%% ticket obtained under one trust config is never resumed under another.
%% Callers that pass no h3_tls_key all land in the `default' bucket,
%% preserving the previous behavior.
h3_connection_key(Host0, Port, Transport, Options) ->
    Host = string:lowercase(Host0),
    {Host, Port, Transport, proplists:get_value(h3_tls_key, Options, default)}.

%% @private Stop a connection, tolerating an already-dead process. Bounded on
%% purpose: this runs inside the pool gen_server, and a conn wedged in a
%% transport call would otherwise hold every caller of the pool for as long
%% as the transport takes to return. A requester whose dial just outlived its
%% timeout uses it too. Past the deadline the conn is killed.
stop_conn(Pid) ->
    try hackney_conn:stop(Pid, ?STOP_CONN_TIMEOUT) catch _:_ -> ok end.

%% @private Find a reusable idle connection for `Key', discarding any that are
%% no longer keepalive-ready. Only a conn that is_ready reports `{ok, connected}'
%% is handed out; a closed conn is stopped and dropped (never reanimated). Fresh
%% dialing for an empty bucket is the caller's `none' branch, off the pool's hot
%% path. The SSL alias exists only to mark intent at the SSL checkout site.
find_available(Key, Available) ->
    case maps:find(Key, Available) of
        {ok, [Pid | Rest]} ->
            Available2 = case Rest of
                [] -> maps:remove(Key, Available);
                _ -> maps:put(Key, Rest, Available)
            end,
            %% Verify connection is still alive and usable
            case is_process_alive(Pid) of
                true ->
                    %% is_ready checks both state and socket health in one call.
                    %% The connection can die between is_process_alive/1 above
                    %% and this gen_statem call (flaky network); the resulting
                    %% noproc exit must not crash the pool, so skip and move on.
                    try hackney_conn:is_ready(Pid, ?PROBE_TIMEOUT) of
                        {ok, connected} ->
                            {ok, Pid, Available2};
                        _ ->
                            %% Closed or unusable: discard it rather than redial
                            %% from inside the pool. Reanimating a closed pid would
                            %% break the "only keepalive conns are reused" invariant
                            %% and a redial here would block the pool on connect.
                            stop_conn(Pid),
                            find_available(Key, Available2)
                    catch
                        _:_ -> find_available(Key, Available2)
                    end;
                false ->
                    find_available(Key, Available2)
            end;
        {ok, []} ->
            none;
        error ->
            none
    end.

%% @private SSL-bucket variant. Now identical to find_available/2 (closed conns
%% are always dropped, never redialed); kept as a named alias to mark intent at
%% the SSL checkout site.
find_available_ssl(Key, Available) ->
    find_available(Key, Available).

%% @private SSL checkout miss: reuse or dial a TCP connection for the caller
%% to upgrade. It is recorded in in_use under the SSL key so the checkin
%% decision can tell it apart from plain TCP checkouts.
checkout_ssl_fallback(SslKey, Requester, Opts, State) ->
    #state{name=PoolName, max_connections=MaxConn,
           available=Available, in_use=InUse} = State,
    {Host, Port} = key_host_port(SslKey),
    TcpKey = connection_key(Host, Port, hackney_tcp),
    TotalInUse = maps:size(InUse),

    case find_available(TcpKey, Available) of
        {ok, Pid, Available2} ->
            case set_owner(Pid, Requester) of
                ok ->
                    InUse2 = maps:put(Pid, SslKey, InUse),
                    {reply, {ok, Pid, needs_upgrade},
                     State#state{available=Available2, in_use=InUse2}};
                {error, _} ->
                    %% #850 race again: drop the dead conn and dial fresh
                    start_ssl_checkout_conn(SslKey, Requester, Opts,
                                            State#state{available=Available2})
            end;
        none ->
            %% No pooled TCP connection. Per-host concurrency is already capped
            %% by hackney_load_regulation, so start one even at max_connections:
            %% it is an overflow connection, closed at checkin (see do_checkin)
            %% rather than pooled. Mirrors the plain checkout path.
            ?report_trace("pool: starting new connection",
                          [{pool, PoolName}, {overflow, TotalInUse >= MaxConn}]),
            start_ssl_checkout_conn(SslKey, Requester, Opts, State)
    end.

%% @private Start a fresh TCP connection for an SSL checkout. The caller
%% dials and upgrades it, so the transport is TCP even though the in_use key
%% carries hackney_ssl.
start_ssl_checkout_conn(SslKey, Requester, Opts, State) ->
    {Host, Port} = key_host_port(SslKey),
    case spawn_connection(Host, Port, hackney_tcp, SslKey, Requester, Opts, State) of
        {ok, Pid, State2} ->
            {reply, {new, Pid, needs_upgrade}, State2};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

spawn_connection(Key, Owner, Opts, State) ->
    %% Plain checkouts dial the key's transport; SSL-bucket checkouts dial
    %% TCP explicitly via spawn_connection/7.
    {Host, Port, Transport, _TlsKey} = Key,
    spawn_connection(Host, Port, Transport, Key, Owner, Opts, State).

%% @private Start an undialed connection for `Owner' and record it in dialing
%% under `Key'. The owner dials it in its own process (dial/4): dialing here
%% would hold every caller of the pool for as long as one host takes to
%% answer (#973). The owner is monitored so its slot is released if it dies
%% before reporting the dial.
spawn_connection(Host, Port, Transport, Key, Owner, Opts, State) ->
    ConnectTimeout = proplists:get_value(connect_timeout, Opts, 8000),
    RecvTimeout = proplists:get_value(recv_timeout, Opts, infinity),
    IdleTimeout = State#state.keepalive_timeout,
    SslOpts = proplists:get_value(ssl_options, Opts, []),
    ConnectOpts = proplists:get_value(connect_options, Opts, []),

    ConnOpts = #{
        host => Host,
        port => Port,
        transport => Transport,
        connect_timeout => ConnectTimeout,
        recv_timeout => RecvTimeout,
        idle_timeout => IdleTimeout,
        ssl_options => SslOpts,
        connect_options => ConnectOpts,
        pool_pid => self(),
        owner => Owner
    },

    case hackney_conn_sup:start_conn(ConnOpts) of
        {ok, Pid} ->
            MonRef = erlang:monitor(process, Pid),
            ReqMon = erlang:monitor(process, Owner),
            PidMonitors = maps:put(Pid, MonRef, State#state.pid_monitors),
            Dialing = maps:put(Pid, {Key, ReqMon}, State#state.dialing),
            {ok, Pid, State#state{pid_monitors=PidMonitors, dialing=Dialing}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Dial a conn the pool handed out undialed, in the requester's
%% process, then report the outcome to the pool. A pool that went away in
%% between is a checkout error like any other.
dial(Pool, Pid, Timeout) ->
    case connect_connection(Pid, Timeout) of
        ok ->
            case pool_call(Pool, {dial_ok, Pid}) of
                ok ->
                    ok;
                {error, _} = Error ->
                    stop_conn(Pid),
                    Error
            end;
        {error, _} = Error ->
            _ = pool_call(Pool, {dial_failed, Pid}),
            stop_conn(Pid),
            Error
    end.

pool_call(Pool, Msg) ->
    try
        gen_server:call(Pool, Msg)
    catch
        exit:_ -> {error, checkout_failure}
    end.

%% @private Forget the monitor the pool holds on a conn.
forget_monitor(Pid, #state{pid_monitors=PidMonitors}=State) ->
    case maps:take(Pid, PidMonitors) of
        {MonRef, PidMonitors2} ->
            erlang:demonitor(MonRef, [flush]),
            State#state{pid_monitors=PidMonitors2};
        error ->
            State
    end.

%% @private Find the dialing entry whose requester monitor is `MonRef'.
take_dialing_requester(MonRef, Dialing) ->
    Found = maps:fold(fun(Pid, {Key, Ref}, none) when Ref =:= MonRef -> {Pid, Key};
                         (_, _, Acc) -> Acc
                      end, none, Dialing),
    case Found of
        {Pid, Key} -> {Pid, Key, maps:remove(Pid, Dialing)};
        none -> none
    end.

%% @private Convert a failed connection call into a checkout error. Nothing
%% may crash because a DNS/TCP/TLS attempt outlives its timeout, nor because
%% the connection process dies while dialing (a transport raising, or the
%% conn being killed). The caller stops the conn on any error return.
connect_connection(Pid, Timeout) ->
    try hackney_conn:connect(Pid, Timeout) of
        Result ->
            Result
    catch
        exit:{timeout, _} ->
            {error, connect_timeout};
        exit:{Reason, {gen_statem, call, _}} ->
            {error, Reason};
        exit:Reason ->
            {error, Reason}
    end.

%% @private Process a checkin - return connection to pool.
%% Plain TCP connections are stored under their TCP key. An SSL upgraded
%% connection is stored only when it was checked out through checkout_ssl
%% (its in_use key carries hackney_ssl plus the TLS options hash) and still
%% speaks HTTP/1.1; any other SSL conn is closed as before.
%% Always releases the load_regulation slot since connection is no longer in use.
do_checkin(Pid, State) ->
    #state{in_use=InUse} = State,

    %% Get the key from in_use and remove
    case maps:take(Pid, InUse) of
        {Key, InUse2} ->
            %% Release load_regulation slot - connection is no longer in active use
            {Host, Port} = key_host_port(Key),
            hackney_load_regulation:release(Host, Port),

            %% Check if connection is still alive
            case is_process_alive(Pid) of
                true ->
                    %% One call fetches every flag the decision needs. A failed
                    %% checkin_info means we cannot prove the conn keepalive/ready,
                    %% so treat it as not poolable (close) rather than pooling blind.
                    Poolable = case checkin_info(Pid) of
                        {ok, Info} -> checkin_poolable(Key, Info);
                        error -> false
                    end,
                    case Poolable andalso pool_has_idle_room(State) of
                        true ->
                            checkin_pool(Pid, Key, InUse2, State);
                        false ->
                            %% Not poolable, or the warm pool is already full
                            %% (overflow connection): close rather than pool.
                            stop_conn(Pid),
                            checkin_close(Pid, Key, InUse2, State)
                    end;
                false ->
                    State#state{in_use=InUse2}
            end;
        error ->
            State
    end.

%% @private Decide at checkin whether a conn can go back to the pool.
%% The key shape records the checkout decision: an SSL-bucket key means the
%% caller opted into ssl_pooling, so the conn is poolable only as an
%% upgraded HTTPS/1.1 conn (HTTP/2 conns multiplex via h2_connections and
%% must never enter `available'). A TCP key keeps the previous rule: never
%% pool a conn that was SSL upgraded or marked no_reuse (proxy tunnels,
%% issue #283). A failed checkin_info call defaults to the safe side of
%% each rule: close for SSL keys, pool for TCP keys as before.
checkin_poolable({_Host, _Port, hackney_ssl, _TlsKey}, Info) ->
    maps:get(no_reuse, Info, true) =:= false andalso
        maps:get(upgraded_ssl, Info, false) =:= true andalso
        maps:get(protocol, Info, undefined) =:= http1 andalso
        keepalive_ready(Info);
checkin_poolable(_TcpKey, Info) ->
    maps:get(no_reuse, Info, false) =:= false andalso
        maps:get(upgraded_ssl, Info, false) =:= false andalso
        keepalive_ready(Info).

%% @private Hand a pooled conn to its new owner. Called from inside the pool
%% gen_server, so it must not raise: the conn answered `is_ready' a moment ago
%% but can be gone or wedged by now, and either would take the pool down. Any
%% failure means the conn is unusable; every caller already dials a fresh one
%% on `{error, _}'.
set_owner(Pid, Owner) ->
    try hackney_conn:set_owner(Pid, Owner, ?PROBE_TIMEOUT)
    catch _:_ -> {error, set_owner_failed}
    end.

%% @private Fetch the conn's checkin flags, or `error' if the call fails (the
%% conn died between is_process_alive/1 and here). Caller treats `error' as
%% not poolable.
checkin_info(Pid) ->
    try {ok, hackney_conn:checkin_info(Pid, ?PROBE_TIMEOUT)}
    catch _:_ -> error
    end.

%% @private Shared keepalive/readiness gate for checkin: only pool a conn whose
%% response left it reusable and whose socket is proven ready. Defaults are the
%% safe side so an unknown flag closes rather than pools.
keepalive_ready(Info) ->
    maps:get(should_close, Info, true) =:= false andalso
        maps:get(ready, Info, false) =:= true.

%% @private Close branch of a checkin: drop the monitor and keep the host's
%% TCP prewarm warm (the replacement for a closed conn is a TCP conn that
%% gets upgraded on its next SSL checkout). The conn itself is stopped by
%% the caller: stop_conn for async checkin, a stop cast for sync checkin
%% where the conn is blocked waiting on the pool's reply.
checkin_close(Pid, Key, InUse2, State) ->
    #state{pid_monitors=PidMonitors} = State,
    PidMonitors2 = case maps:take(Pid, PidMonitors) of
        {MonRef, PM} ->
            erlang:demonitor(MonRef, [flush]),
            PM;
        error -> PidMonitors
    end,
    State2 = State#state{in_use=InUse2, pid_monitors=PidMonitors2},
    {Host, Port} = key_host_port(Key),
    TcpKey = connection_key(Host, Port, hackney_tcp),
    maybe_maintain_prewarm(TcpKey, activate_host(TcpKey, State2)).

%% @private Pool branch of a checkin: hand ownership to the pool and store
%% the conn under its checkout key (TCP or SSL bucket).
%% set_owner is async so the sync checkin path never calls back into a conn
%% that is blocked waiting on our reply.
checkin_pool(Pid, Key, InUse2, State) ->
    #state{available=Available, pid_monitors=PidMonitors} = State,
    hackney_conn:set_owner_async(Pid, self()),
    Available2 = maps:update_with(Key, fun(Pids) -> [Pid | Pids] end, [Pid], Available),

    %% Ensure we're monitoring this pid
    PidMonitors2 = case maps:is_key(Pid, PidMonitors) of
        true -> PidMonitors;
        false ->
            MonRef = erlang:monitor(process, Pid),
            maps:put(Pid, MonRef, PidMonitors)
    end,

    State2 = State#state{in_use=InUse2, available=Available2, pid_monitors=PidMonitors2},
    %% Maintain prewarm for activated hosts. No-op for SSL keys: only TCP
    %% keys are ever activated for prewarm.
    maybe_maintain_prewarm(Key, State2).

%% @private Process a checkin with known "should close" flag - avoids calling back to connection
%% Used for sync checkin to prevent deadlock when connection calls pool.
%% The conn computes the flag itself: true for proxy tunnels (no_reuse), SSL
%% upgrades without ssl_pooling, and non HTTP/1.1 conns. A conn reaching the
%% pool branch with an SSL key is therefore an upgraded HTTPS/1.1 conn that
%% opted into ssl_pooling.
do_checkin_with_close_flag(Pid, ShouldClose, State) ->
    #state{in_use=InUse} = State,

    %% Get the key from in_use and remove
    case maps:take(Pid, InUse) of
        {Key, InUse2} ->
            %% Release load_regulation slot - connection is no longer in active use
            {Host, Port} = key_host_port(Key),
            hackney_load_regulation:release(Host, Port),

            %% Check if connection is still alive
            case is_process_alive(Pid) of
                true ->
                    %% Use the provided flag instead of querying connection
                    case ShouldClose of
                        true ->
                            %% Connection should not be reused - close it
                            %% Use cast to avoid deadlock (connection is waiting for our reply)
                            gen_statem:cast(Pid, stop),
                            checkin_close(Pid, Key, InUse2, State);
                        _ ->
                            %% Pool only if the warm pool has room; otherwise
                            %% close this overflow connection. Use cast - the
                            %% connection is blocked waiting for our reply.
                            case pool_has_idle_room(State) of
                                true ->
                                    checkin_pool(Pid, Key, InUse2, State);
                                false ->
                                    gen_statem:cast(Pid, stop),
                                    checkin_close(Pid, Key, InUse2, State)
                            end
                    end;
                false ->
                    State#state{in_use=InUse2}
            end;
        error ->
            State
    end.

%% @private Is there room in the warm/idle pool for one more connection?
%% `available' holds idle pooled connections; their count is capped at
%% max_connections. Concurrency above that is served by overflow connections
%% at checkout, which are closed here instead of pooled.
pool_has_idle_room(#state{available=Available, max_connections=MaxConn}) ->
    idle_count(Available) < MaxConn.

%% @private Number of idle (pooled) connections across all host buckets.
idle_count(Available) ->
    maps:fold(fun(_, Pids, Acc) -> Acc + length(Pids) end, 0, Available).

%% @private Check that a pooled HTTP/2 conn is alive and in `connected` state.
%% Short timeout so a stuck conn doesn't wedge the pool; any failure → unusable.
h2_conn_usable(Pid) ->
    case erlang:is_process_alive(Pid) of
        false -> false;
        true ->
            try hackney_conn:get_state(Pid, ?PROBE_TIMEOUT) of
                {ok, connected} -> true;
                _ -> false
            catch
                _:_ -> false
            end
    end.

%% @private Remove an HTTP/2 connection from the pool
do_unregister_h2(Pid, State) ->
    #state{h2_connections = H2Conns, in_use = InUse,
           pid_monitors = PidMonitors} = State,
    %% Find and remove the connection
    H2Conns2 = maps:fold(
        fun(Key, ConnPid, Acc) ->
            case ConnPid of
                Pid -> maps:remove(Key, Acc);
                _ -> Acc
            end
        end,
        H2Conns,
        H2Conns
    ),
    %% Demonitor if no longer tracked. A checked-out conn keeps its monitor:
    %% it holds a per-host slot until it stops, and only the DOWN releases it.
    PidMonitors2 = case maps:is_key(Pid, InUse) of
        true ->
            PidMonitors;
        false ->
            case maps:take(Pid, PidMonitors) of
                {MonRef, PM} ->
                    erlang:demonitor(MonRef, [flush]),
                    PM;
                error -> PidMonitors
            end
    end,
    State#state{h2_connections = H2Conns2, pid_monitors = PidMonitors2}.

%% @private Remove an HTTP/3 connection from the pool
do_unregister_h3(Pid, State) ->
    #state{h3_connections = H3Conns, pid_monitors = PidMonitors} = State,
    %% Find and remove the connection
    H3Conns2 = maps:fold(
        fun(Key, ConnPid, Acc) when is_pid(ConnPid) ->
            case ConnPid of
                Pid -> maps:remove(Key, Acc);
                _ -> Acc
            end;
           (_Key, _Val, Acc) -> Acc
        end,
        H3Conns,
        H3Conns
    ),
    %% Demonitor if no longer tracked
    PidMonitors2 = case maps:take(Pid, PidMonitors) of
        {MonRef, PM} ->
            erlang:demonitor(MonRef, [flush]),
            PM;
        error -> PidMonitors
    end,
    State#state{h3_connections = H3Conns2, pid_monitors = PidMonitors2}.

%% @private Prewarm connections to a host
%% Creates connections up to Count if there are fewer available.
%% Only creates TCP connections (prewarm doesn't apply to SSL).
do_prewarm(Host, Port, Count, State) ->
    #state{name=PoolName, available=Available, keepalive_timeout=IdleTimeout} = State,
    Key = connection_key(Host, Port, hackney_tcp),
    CurrentCount = case maps:find(Key, Available) of
        {ok, Pids} -> length(Pids);
        error -> 0
    end,
    Needed = max(0, Count - CurrentCount),
    ?report_trace("pool: prewarm", [{pool, PoolName}, {host, Host}, {port, Port},
                                    {current, CurrentCount}, {needed, Needed}]),
    case Needed > 0 of
        true ->
            %% Mark host as activated
            State2 = activate_host(Key, State),
            %% Create connections in background to not block the pool
            PoolPid = self(),
            spawn(fun() ->
                prewarm_connections(PoolPid, Host, Port, Needed, IdleTimeout)
            end),
            State2;
        false ->
            State
    end.

%% @private Mark a host as activated for prewarm
activate_host(Key, #state{activated_hosts=Activated}=State) ->
    State#state{activated_hosts=sets:add_element(Key, Activated)}.

%% @private Check if a host has been activated
is_host_activated(Key, #state{activated_hosts=Activated}) ->
    sets:is_element(Key, Activated).

%% @private Maintain prewarm count for activated hosts
maybe_maintain_prewarm(Key, State) ->
    case is_host_activated(Key, State) of
        true ->
            #state{prewarm_count=PrewarmCount, available=Available} = State,
            CurrentCount = case maps:find(Key, Available) of
                {ok, Pids} -> length(Pids);
                error -> 0
            end,
            case CurrentCount < PrewarmCount of
                true ->
                    {Host, Port} = key_host_port(Key),
                    do_prewarm(Host, Port, PrewarmCount, State);
                false ->
                    State
            end;
        false ->
            State
    end.

%% @private Create prewarm connections (runs in separate process)
prewarm_connections(_PoolPid, _Host, _Port, 0, _IdleTimeout) ->
    ok;
prewarm_connections(PoolPid, Host, Port, Count, IdleTimeout) ->
    ConnOpts = #{
        host => Host,
        port => Port,
        transport => hackney_tcp,
        connect_timeout => 5000,
        recv_timeout => 5000,
        idle_timeout => IdleTimeout,
        ssl_options => [],
        connect_options => [],
        pool_pid => PoolPid,
        owner => PoolPid
    },
    case hackney_conn_sup:start_conn(ConnOpts) of
        {ok, Pid} ->
            case connect_connection(Pid, ?PREWARM_CONNECT_TIMEOUT) of
                ok ->
                    %% Checkin the new connection to the pool
                    gen_server:cast(PoolPid, {prewarm_checkin, Pid,
                                              connection_key(Host, Port, hackney_tcp)});
                {error, _Reason} ->
                    stop_conn(Pid)
            end;
        {error, _Reason} ->
            ok
    end,
    prewarm_connections(PoolPid, Host, Port, Count - 1, IdleTimeout).

handle_stats(State) ->
    #state{name=PoolName, max_connections=Max, available=Available,
           in_use=InUse} = State,
    AvailCount = maps:fold(fun(_, Pids, Acc) -> Acc + length(Pids) end, 0, Available),
    [{name, PoolName},
     {max, Max},
     {in_use_count, maps:size(InUse)},
     {free_count, AvailCount},
     {queue_count, 0}].  % No more queue
