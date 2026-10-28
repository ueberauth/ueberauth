%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Simplified hackney API using process-per-connection architecture.
%%% Connection handles are now hackney_conn process PIDs.

-module(hackney).

-export([connect/1, connect/2, connect/3, connect/4,
         close/1,
         peername/1,
         peercert/1,
         sockname/1,
         request/1, request/2, request/3, request/4, request/5,
         send_request/2,
         cookies/1,
         send_body/2, finish_send_body/1, start_response/1,
         body/1, body/2, stream_body/1,
         setopts/2]).

%% WebSocket API
-export([ws_connect/1, ws_connect/2,
         ws_send/2,
         ws_recv/1, ws_recv/2,
         ws_setopts/2,
         ws_close/1, ws_close/2]).

%% WebTransport API
-export([wt_connect/1, wt_connect/2,
         wt_send/2,
         wt_recv/1, wt_recv/2,
         wt_setopts/2,
         wt_close/1, wt_close/2,
         wt_open_stream/2,
         wt_stream_send/3, wt_stream_send/4,
         wt_stream_recv/2, wt_stream_recv/3,
         wt_close_stream/2,
         wt_reset_stream/3,
         wt_stop_sending/3,
         wt_send_datagram/2,
         wt_session_info/1]).

%% HTTP/2 bidirectional (gRPC-style) stream API
-export([h2_open/2, h2_open/3, h2_open/4,
         h2_send/2, h2_send/3,
         h2_send_trailers/2,
         h2_recv/1, h2_recv/2,
         h2_consume/2,
         h2_setopts/2,
         h2_close/1]).

-export([redirect_location/1, location/1]).

-export([get_version/0]).
-export([default_ua/0]).

%% Async streaming
-export([stream_next/1,
         stop_async/1,
         pause_stream/1,
         resume_stream/1]).

-export([parse_proxy_url/1]).

-ifdef(TEST).
-export([get_proxy_env/1, do_get_proxy_env/1]).
-export([get_proxy_config/3]).
-export([check_no_proxy/2]).
-export([start_conn_with_socket/5]).
-endif.

-define(METHOD_TPL(Method),
  -export([Method/1, Method/2, Method/3, Method/4])).
-include("hackney_methods.hrl").

-include("hackney.hrl").
-include("hackney_lib.hrl").
-include_lib("hackney_internal.hrl").


-type url() :: #hackney_url{} | binary().
-type conn() :: pid().
-type request_ret() ::
    {ok, integer(), list(), binary()} | %% response with body
    {ok, integer(), list()} |           %% HEAD request
    {ok, conn()} |                      %% async mode or streaming body upload (body = stream)
    {error, term()}.
-export_type([url/0, conn/0, request_ret/0]).

%%====================================================================
%% Connection API
%%====================================================================

connect(URL) ->
  connect(URL, []).

connect(#hackney_url{}=URL, Options) ->
  #hackney_url{transport=Transport,
    host=Host,
    port=Port} = URL,
  connect(Transport, Host, Port, Options);
connect(URL, Options) when is_binary(URL) orelse is_list(URL) ->
  connect(hackney_url:parse_url(URL), Options).

%% @doc Connect to a host and return a connection handle (hackney_conn PID).
-spec connect(module(), string(), inet:port_number()) -> {ok, conn()} | {error, term()}.
connect(Transport, Host, Port) ->
  connect(Transport, Host, Port, []).

-spec connect(module(), string() | binary(), inet:port_number(), list()) ->
        {ok, conn()} | {error, term()}.
connect(Transport, Host, Port, Options) when is_binary(Host) ->
  connect(Transport, binary_to_list(Host), Port, Options);
connect(Transport, Host, Port, Options) ->
  %% The caller keeps the connection for its own requests, so a pooled one
  %% must not go back to the pool after each response: close/1 does that.
  case open_conn(Transport, Host, Port, Options) of
    {ok, ConnPid} ->
      _ = hackney_conn:hold(ConnPid),
      {ok, ConnPid};
    Error ->
      Error
  end.

%% @private Open a connection for one request (request/5 and the proxy
%% paths). A pooled one returns to the pool once its response is read.
open_conn(Transport, Host, Port, Options) ->
  %% Check if using a pool
  UsePool = use_pool(Options),
  case UsePool of
    false ->
      %% Direct connection - start a hackney_conn process
      connect_direct(Transport, Host, Port, Options);
    _PoolName ->
      %% Pool mode with per-host load regulation
      connect_pool(Transport, Host, Port, Options)
  end.

%% @private Direct connection without pool
connect_direct(Transport, Host, Port, Options) ->
  %% Build connect_options including protocols for ALPN
  BaseConnectOpts = proplists:get_value(connect_options, Options, []),
  Protocols = proplists:get_value(protocols, Options, undefined),
  ConnectOpts = case Protocols of
    undefined -> BaseConnectOpts;
    _ -> [{protocols, Protocols} | BaseConnectOpts]
  end,
  ConnectTimeout = proplists:get_value(connect_timeout, Options, 8000),
  ConnOpts = #{
    %% The caller owns the connection: it is started under hackney_conn_sup,
    %% so without this the supervisor is the owner and the connection
    %% outlives a caller that dies.
    owner => self(),
    host => Host,
    port => Port,
    transport => Transport,
    connect_timeout => ConnectTimeout,
    recv_timeout => proplists:get_value(recv_timeout, Options, 5000),
    %% Single-owner connection: seed the conn-level send_timeout so
    %% hackney:send_request/2 (which has no options channel) honors it.
    %% Pooled connections deliberately skip this (shared conns keep the
    %% constant default; per-request ReqOpts override there).
    send_timeout => proplists:get_value(send_timeout, Options, 30000),
    connect_options => ConnectOpts,
    ssl_options => proplists:get_value(ssl_options, Options, [])
  },
  case hackney_conn_sup:start_conn(ConnOpts) of
    {ok, ConnPid} ->
      case hackney_conn:connect(ConnPid, ConnectTimeout) of
        ok ->
          {ok, ConnPid};
        {error, Reason} ->
          stop_conn(ConnPid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @private Pool connection with load regulation
%% Flow:
%% 1. For SSL: Check if existing HTTP/3 or HTTP/2 connection can be reused (multiplexing)
%% 2. If HTTP/3 allowed and available (via Alt-Svc), try HTTP/3 first
%% 3. Acquire slot from load_regulation (blocks if at per-host limit)
%% 4. Get TCP connection from pool (always TCP, pool doesn't store SSL)
%% 5. Upgrade to SSL if needed (in-place upgrade)
%% 6. If HTTP/2 negotiated, register for multiplexing
%% Note: load_regulation slot is released when connection is checked in or dies
connect_pool(Transport, Host, Port, Options) ->
  PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),

  %% Check which protocols are allowed (default from application env)
  Protocols = proplists:get_value(protocols, Options, hackney_util:default_protocols()),
  H3Allowed = lists:member(http3, Protocols),
  H2Allowed = lists:member(http2, Protocols),

  %% For SSL connections, try multiplexed protocols (HTTP/3 first, then HTTP/2)
  case Transport of
    hackney_ssl ->
      %% Compute the exact TLS handshake options once; their hash keys the
      %% shared HTTP/2 connection so requests with different ssl_options
      %% never share a connection. FinalSslOpts is passed alongside Options
      %% (not inside it) to keep the large CA material out of the pool state.
      {FinalSslOpts, TlsKey} = effective_ssl_opts(Host, Options),
      Options2 = [{tls_key, TlsKey} | Options],
      %% Check HTTP/3 first if allowed
      case H3Allowed andalso try_h3_connection(Host, Port, Transport, Options, PoolHandler) of
        {ok, H3Pid} ->
          {ok, H3Pid};
        _ when H2Allowed ->
          %% Try HTTP/2 multiplexing
          case PoolHandler:checkout_h2(Host, Port, Transport, Options2) of
            {ok, H2Pid} ->
              %% Verify connection is actually in connected state
              %% (OTP 28 on FreeBSD may have timing issues with SSL connections).
              %% The probe is a gen_statem:call, which exits if the pooled
              %% connection is terminating (idle teardown, GOAWAY, keepalive
              %% close) at checkout time; treat that as unusable and fall
              %% through to a fresh connection instead of crashing the caller.
              %% Mirrors maybe_register_h2/maybe_upgrade_ssl.
              GetState = try hackney_conn:get_state(H2Pid)
                         catch exit:_ -> {error, terminated} end,
              case GetState of
                {ok, connected} ->
                          {ok, H2Pid};
                _ ->
                  %% Connection not ready, unregister and create new
                  PoolHandler:unregister_h2(H2Pid, Options2),
                  connect_pool_new(Transport, Host, Port, Options2, FinalSslOpts, PoolHandler)
              end;
            none ->
              connect_pool_new(Transport, Host, Port, Options2, FinalSslOpts, PoolHandler)
          end;
        _ ->
          %% No multiplexed protocols allowed or available
          connect_pool_new(Transport, Host, Port, Options2, FinalSslOpts, PoolHandler)
      end;
    _ ->
      %% Non-SSL, use normal pool
      connect_pool_new(Transport, Host, Port, Options, undefined, PoolHandler)
  end.

%% @private Build the exact TLS handshake options for a pooled SSL request,
%% plus their memoized pool key hash. Single source of truth: replicates
%% what maybe_upgrade_ssl used to build inline, including the optional
%% protocols entry for ALPN.
effective_ssl_opts(Host, Options) ->
  SslOpts = proplists:get_value(ssl_options, Options, []),
  SslOpts2 = case proplists:get_value(protocols, Options, undefined) of
    undefined -> SslOpts;
    Protocols -> [{protocols, Protocols} | SslOpts]
  end,
  ConnectOpts = proplists:get_value(connect_options, Options, []),
  hackney_ssl:effective_opts_and_key(Host, SslOpts2, ConnectOpts).

%% @private Try to get or establish an HTTP/3 connection
try_h3_connection(Host, Port, Transport, Options, PoolHandler) ->
  %% Hash the QUIC trust projection once; it keys both the shared H3
  %% connection and the 0-RTT ticket cache so requests with differing
  %% trust configs never share either.
  ConnectOpts = proplists:get_value(connect_options, Options, []),
  SslOpts = proplists:get_value(ssl_options, Options, []),
  K3 = hackney_ssl:h3_options_key(ConnectOpts, SslOpts),
  Options2 = [{h3_tls_key, K3} | Options],
  %% Check if HTTP/3 is blocked for this host (negative cache)
  case hackney_altsvc:is_h3_blocked(Host, Port) of
    true ->
      false;
    false ->
      %% Check if we have an existing HTTP/3 connection
      case PoolHandler:checkout_h3(Host, Port, Transport, Options2) of
        {ok, H3Pid} ->
          %% Verify connection is actually in connected state. The probe is a
          %% gen_statem:call, which exits if the pooled connection is
          %% terminating at checkout time; treat that as unusable and fall
          %% through to a fresh connection instead of crashing the caller.
          GetState = try hackney_conn:get_state(H3Pid)
                     catch exit:_ -> {error, terminated} end,
          case GetState of
            {ok, connected} ->
              {ok, H3Pid};
            _ ->
              %% Connection not ready, unregister and try new connection
              PoolHandler:unregister_h3(H3Pid, Options2),
              try_new_h3_connection(Host, Port, Transport, Options2, PoolHandler)
          end;
        none ->
          %% Check Alt-Svc cache for known HTTP/3 endpoint
          case hackney_altsvc:lookup(Host, Port) of
            {ok, h3, H3Port} ->
              %% Alt-Svc says HTTP/3 is available, try connecting
              try_new_h3_connection(Host, H3Port, Transport, Options2, PoolHandler);
            none ->
              %% No Alt-Svc cached, only try H3 if explicitly requested
              case lists:member(http3, proplists:get_value(protocols, Options, [])) of
                true ->
                  %% User explicitly wants HTTP/3, try it
                  try_new_h3_connection(Host, Port, Transport, Options2, PoolHandler);
                false ->
                  false
              end
          end
      end
  end.

%% @private Establish a new HTTP/3 connection
try_new_h3_connection(Host, Port, Transport, Options, PoolHandler) ->
  %% Start HTTP/3 connection via hackney_conn
  ConnectTimeout = proplists:get_value(connect_timeout, Options, 8000),
  BaseConnectOpts = proplists:get_value(connect_options, Options, []),
  SslOpts = proplists:get_value(ssl_options, Options, []),
  %% Forward the caller's connect_options (e.g. {family, inet6}) and resolve the
  %% 0-RTT session ticket (explicit option beats the pool cache).
  ConnectOpts0 = [{protocols, [http3]} | proplists:delete(protocols, BaseConnectOpts)],
  ConnectOpts = maybe_inject_h3_session(ConnectOpts0, SslOpts, Host, Port, Transport,
                                        Options, PoolHandler),
  PoolName = proplists:get_value(pool, Options, default),
  ConnOpts = #{
    host => Host,
    port => Port,
    transport => Transport,
    connect_timeout => ConnectTimeout,
    recv_timeout => proplists:get_value(recv_timeout, Options, 5000),
    connect_options => ConnectOpts,
    ssl_options => SslOpts,
    pool_name => PoolName,
    pool_handler => PoolHandler
  },
  case hackney_conn_sup:start_conn(ConnOpts) of
    {ok, ConnPid} ->
      case hackney_conn:connect(ConnPid, ConnectTimeout) of
        ok ->
          %% Verify it's HTTP/3
          try hackney_conn:get_protocol(ConnPid) of
            http3 ->
              %% Register for multiplexing
              PoolHandler:register_h3(Host, Port, Transport, ConnPid, Options),
              {ok, ConnPid};
            _ ->
              %% Not HTTP/3, close and fail
              stop_conn(ConnPid),
              hackney_altsvc:mark_h3_blocked(Host, Port),
              false
          catch
            _:_ ->
              %% Connection terminated before we could check
              hackney_altsvc:mark_h3_blocked(Host, Port),
              false
          end;
        {error, _Reason} ->
          stop_conn(ConnPid),
          hackney_altsvc:mark_h3_blocked(Host, Port),
          false
      end;
    {error, _Reason} ->
      hackney_altsvc:mark_h3_blocked(Host, Port),
      false
  end.

%% @private Resolve the 0-RTT session ticket for a new H3 connection.
%% Precedence: an explicit `session_ticket' in connect_options or ssl_options
%% wins; otherwise, unless `zero_rtt' is disabled, a pool-cached ticket for
%% {Host, Port, Transport} is injected. The pool lookup is guarded so a custom
%% pool handler without the callback degrades to no reuse rather than crashing.
maybe_inject_h3_session(ConnectOpts, SslOpts, Host, Port, Transport, Options, PoolHandler) ->
  ZeroRtt = proplists:get_value(zero_rtt, Options, true),
  Explicit = proplists:get_value(session_ticket, ConnectOpts,
               proplists:get_value(session_ticket, SslOpts, undefined)),
  case {ZeroRtt, Explicit} of
    {false, _} -> ConnectOpts;
    {_, T} when T =/= undefined -> ConnectOpts;
    _ ->
      case erlang:function_exported(PoolHandler, get_h3_session, 4) of
        false -> ConnectOpts;
        true ->
          case PoolHandler:get_h3_session(Host, Port, Transport, Options) of
            {ok, Cached} -> [{session_ticket, Cached} | ConnectOpts];
            _ -> ConnectOpts
          end
      end
  end.

connect_pool_new(Transport, Host, Port, Options, FinalSslOpts, PoolHandler) ->
  MaxPerHost = proplists:get_value(max_per_host, Options, 50),
  CheckoutTimeout = proplists:get_value(checkout_timeout, Options,
                      proplists:get_value(connect_timeout, Options, 8000)),

  %% 1. Acquire per-host slot (blocks with backoff until available)
  case hackney_load_regulation:acquire(Host, Port, MaxPerHost, CheckoutTimeout) of
    ok ->
      %% Slot acquired - now get connection from pool
      SslPooling = proplists:get_value(ssl_pooling, Options,
                     hackney_app:get_app_env(ssl_pooling, false)),
      case Transport =:= hackney_ssl andalso SslPooling =:= true
           andalso erlang:function_exported(PoolHandler, checkout_ssl, 4) of
        true ->
          %% Opt-in ssl_pooling: pooled HTTPS/1.1 connections are reused on
          %% an exact match of the TLS options hash (tls_key in Options)
          connect_pool_ssl(Transport, Host, Port, Options, FinalSslOpts, PoolHandler);
        false ->
          %% Always checkout as TCP - pool only stores TCP connections
          case PoolHandler:checkout(Host, Port, hackney_tcp, Options) of
            {ok, PoolRef, ConnPid} ->
              %% Got TCP connection - upgrade to SSL if needed
              case maybe_upgrade_ssl(Transport, ConnPid, FinalSslOpts) of
                ok ->
                  %% Check if HTTP/2 was negotiated, register for multiplexing
                  maybe_register_h2(ConnPid, Host, Port, Transport, Options, PoolHandler),
                  {ok, ConnPid};
                {error, Reason} ->
                  %% Upgrade failed - release slot and close connection
                  discard_conn(PoolHandler, PoolRef, ConnPid, Host, Port),
                  {error, Reason}
              end;
            {error, Reason} ->
              %% Checkout failed - release slot
              hackney_load_regulation:release(Host, Port),
              {error, Reason}
          end
      end;
    {error, timeout} ->
      {error, checkout_timeout}
  end.

%% @private SSL-pooling checkout. A `ready' conn is an already-upgraded
%% HTTPS/1.1 connection reused on an exact tls_key match; it was registered
%% for h2 at creation if applicable, so it is not re-registered here. A
%% `needs_upgrade' conn is a TCP connection upgraded with pool_ssl so it can
%% return to the pool at checkin.
connect_pool_ssl(Transport, Host, Port, Options, FinalSslOpts, PoolHandler) ->
  case PoolHandler:checkout_ssl(Host, Port, Transport, Options) of
    {ok, _PoolRef, ConnPid, ready} ->
      {ok, ConnPid};
    {ok, PoolRef, ConnPid, needs_upgrade} ->
      case hackney_conn:upgrade_to_ssl(ConnPid, FinalSslOpts,
                                       #{final => true, pool_ssl => true}) of
        ok ->
          maybe_register_h2(ConnPid, Host, Port, Transport, Options, PoolHandler),
          {ok, ConnPid};
        {error, Reason} ->
          discard_conn(PoolHandler, PoolRef, ConnPid, Host, Port),
          {error, Reason}
      end;
    {error, Reason} ->
      hackney_load_regulation:release(Host, Port),
      {error, Reason}
  end.

%% @private Register HTTP/2 connection for multiplexing if applicable
%% Wrapped in try to handle a race where the connection terminates before the call
maybe_register_h2(ConnPid, Host, Port, Transport, Options, PoolHandler) ->
  try hackney_conn:get_protocol(ConnPid) of
    http2 ->
      %% HTTP/2 negotiated - register for connection sharing. Share it first
      %% so it no longer dies with this caller while other callers use it.
      _ = hackney_conn:share_h2(ConnPid),
      PoolHandler:register_h2(Host, Port, Transport, ConnPid, Options);
    http1 ->
      ok;
    http3 ->
      ok
  catch
    _:_ ->
      %% Connection terminated before we could check - ignore
      ok
  end.

%% @private Upgrade TCP connection to SSL if needed.
%% FinalSslOpts is precomputed by effective_ssl_opts/2 so the handshake uses
%% exactly the options hashed into the pool tls_key.
maybe_upgrade_ssl(hackney_ssl, ConnPid, FinalSslOpts) ->
  %% Check if connection is already SSL (e.g., reused SSL connection)
  try hackney_conn:is_upgraded_ssl(ConnPid) of
    true ->
      %% Already SSL, no upgrade needed
      ok;
    _ ->
      %% Upgrade TCP to SSL with ALPN
      hackney_conn:upgrade_to_ssl(ConnPid, FinalSslOpts, #{final => true})
  catch
    _:_ ->
      %% Connection terminated, attempt upgrade anyway
      hackney_conn:upgrade_to_ssl(ConnPid, FinalSslOpts, #{final => true})
  end;
maybe_upgrade_ssl(_, _ConnPid, _FinalSslOpts) ->
  %% Not SSL, no upgrade needed
  ok.

%% @private Drop a checked-out conn whose TLS upgrade failed: the pool
%% forgets it first, so its DOWN does not release the slot released here a
%% second time. A pool handler without discard/2 keeps the old behaviour.
discard_conn(PoolHandler, PoolRef, ConnPid, Host, Port) ->
  _ = case erlang:function_exported(PoolHandler, discard, 2) of
        true -> PoolHandler:discard(PoolRef, ConnPid);
        false -> ok
      end,
  hackney_load_regulation:release(Host, Port),
  stop_conn(ConnPid).

%% @private Stop a connection, tolerating an already-dead process.
stop_conn(ConnPid) ->
  %% Bounded: a conn wedged in a dial past its deadline is killed rather
  %% than holding the caller.
  try hackney_conn:stop(ConnPid, 100) catch _:_ -> ok end.

%% @private Signal the websocket process to shut down, ignoring errors.
shutdown_ws(WsPid) ->
  try exit(WsPid, shutdown) catch _:_ -> ok end.

%% @doc Close a connection.
-spec close(conn()) -> ok.
close(ConnPid) when is_pid(ConnPid) ->
  %% A pooled connection held by a connect/* caller goes back to its pool,
  %% and a shared HTTP/2 one only drops this caller's streams; any other one
  %% is stopped.
  case hackney_conn:release_held(ConnPid) of
    ok -> ok;
    {error, _} -> hackney_conn:stop(ConnPid)
  end.

%% @doc Start a connection with a pre-established socket.
%% Used for proxy connections where the tunnel is established first.
%% Socket can be a raw socket or a {Transport, Socket} tuple from proxy modules.
-spec start_conn_with_socket(string(), inet:port_number(), module(),
                              inet:socket() | {module(), inet:socket()}, list()) ->
  {ok, conn()} | {error, term()}.
start_conn_with_socket(Host, Port, _Transport, {SocketTransport, Socket}, Options) ->
  %% Handle {Transport, Socket} tuple from proxy modules
  %% Use the socket's transport for operations
  ActualTransport = normalize_transport(SocketTransport),
  start_conn_with_socket_internal(Host, Port, ActualTransport, Socket, Options);
start_conn_with_socket(Host, Port, Transport, Socket, Options) ->
  %% Raw socket
  ActualTransport = normalize_transport(Transport),
  start_conn_with_socket_internal(Host, Port, ActualTransport, Socket, Options).

start_conn_with_socket_internal(Host, Port, Transport, Socket, Options) ->
  %% Build connect_options including protocols for ALPN
  BaseConnectOpts = proplists:get_value(connect_options, Options, []),
  Protocols = proplists:get_value(protocols, Options, undefined),
  ConnectOpts = case Protocols of
    undefined -> BaseConnectOpts;
    _ -> [{protocols, Protocols} | BaseConnectOpts]
  end,
  %% Check if this is a proxy tunnel connection (should not be reused)
  NoReuse = proplists:get_value(no_reuse, Options, false),
  ConnOpts = #{
    %% The caller owns the tunneled connection, as in connect_direct.
    owner => self(),
    host => Host,
    port => Port,
    transport => Transport,
    socket => Socket,
    connect_timeout => proplists:get_value(connect_timeout, Options, 8000),
    recv_timeout => proplists:get_value(recv_timeout, Options, 5000),
    %% Single-owner tunneled connection: same seeding as connect_direct.
    send_timeout => proplists:get_value(send_timeout, Options, 30000),
    connect_options => ConnectOpts,
    ssl_options => proplists:get_value(ssl_options, Options, []),
    no_reuse => NoReuse
  },
  case hackney_conn_sup:start_conn(ConnOpts) of
    {ok, ConnPid} ->
      %% The socket was opened in this process, so it closes with it unless
      %% the conn controls it. A caller that passes a socket it does not own
      %% keeps the old behaviour.
      case Transport:controlling_process(Socket, ConnPid) of
        ok ->
          {ok, ConnPid};
        {error, not_owner} ->
          {ok, ConnPid};
        {error, Reason} ->
          stop_conn(ConnPid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% Normalize transport atoms (e.g., ssl -> hackney_ssl, gen_tcp -> hackney_tcp)
normalize_transport(hackney_tcp) -> hackney_tcp;
normalize_transport(hackney_ssl) -> hackney_ssl;
normalize_transport(gen_tcp) -> hackney_tcp;
normalize_transport(ssl) -> hackney_ssl;
normalize_transport(Other) -> Other.

%% @doc Get the remote address and port.
-spec peername(conn()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:peername(ConnPid).

%% @doc Get the peer SSL certificate.
%% Returns the DER-encoded certificate of the peer, or an error if the connection
%% is not SSL or the certificate is unavailable.
-spec peercert(conn()) -> {ok, binary()} | {error, term()}.
peercert(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:peercert(ConnPid).

%% @doc Get the local address and port.
-spec sockname(conn()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:sockname(ConnPid).

%% @doc Set socket options.
-spec setopts(conn(), list()) -> ok | {error, term()}.
setopts(ConnPid, Options) when is_pid(ConnPid) ->
  hackney_conn:setopts(ConnPid, Options).

%%====================================================================
%% Request API
%%====================================================================

%% @doc Make a request.
-spec request(url()) -> request_ret().
request(URL) ->
  request(get, URL).

-spec request(atom() | binary(), url()) -> request_ret().
request(Method, URL) ->
  request(Method, URL, [], <<>>, []).

-spec request(atom() | binary(), url(), list()) -> request_ret().
request(Method, URL, Headers) ->
  request(Method, URL, Headers, <<>>, []).

-spec request(atom() | binary(), url(), list(), term()) -> request_ret().
request(Method, URL, Headers, Body) ->
  request(Method, URL, Headers, Body, []).

%% @doc Make a request.
%%
%% Args:
%% - Method: HTTP method (get, post, put, delete, query, etc.).
%%   `query' is the RFC 10008 QUERY method: safe and idempotent, with a
%%   request body allowed like post.
%% - URL: Full URL or parsed hackney_url record
%% - Headers: List of headers
%% - Body: Request body (binary, iolist, {form, KVs}, {file, Path}, etc.)
%% - Options: Request options
%%
%% Options:
%% - async: true | once - Receive response asynchronously
%% - stream_to: PID to receive async messages
%% - follow_redirect: Follow redirects automatically
%% - max_redirect: Maximum number of redirects (default 5)
%% - location_trusted: If true, forward auth credentials on cross-host redirects (default false)
%% - pool: Pool name or false for no pooling
%% - connect_timeout: Connection timeout in ms (default 8000)
%% - recv_timeout: Receive timeout in ms (default 5000)
%% - max_body_size: Cap in bytes on a response body returned whole, after
%%   decompression (default 512 MiB, `infinity' disables it). Past it the
%%   request fails with {error, body_too_large}; stream larger bodies.
%%
%% Returns:
%% - {ok, Status, Headers, Body}: Success with response body
%% - {ok, Status, Headers}: HEAD request
%% - {ok, Ref}: Async mode - use stream_next/1 to receive messages
%% - {ok, ConnPid}: Streaming body mode (body = stream) - use send_body/2, finish_send_body/1
%% - {error, Reason}: Error
%%
%% Note: The `with_body' option is deprecated and ignored. Body is always returned directly.
-spec request(atom() | binary(), url(), list(), term(), list()) -> request_ret().
request(Method, URL, Headers, Body, Options) when is_binary(URL) orelse is_list(URL) ->
  request(Method, hackney_url:parse_url(URL), Headers, Body, Options);
request(Method, #hackney_url{}=URL0, Headers0, Body, Options0) ->
  PathEncodeFun = proplists:get_value(path_encode_fun, Options0,
    fun hackney_url:pathencode/1),

  %% Normalize the URL
  URL = hackney_url:normalize(URL0, PathEncodeFun),

  ?report_trace("request", [{method, Method},
                            {url, URL},
                            {headers, Headers0},
                            {body, Body},
                            {options, Options0}]),

  Req = #{method  => Method,
          url     => URL,
          headers => Headers0,
          body    => Body,
          options => Options0},
  Chain = hackney_middleware:resolve_chain(Options0),
  hackney_middleware:apply_chain(Chain, Req, fun do_dispatch/1).

%% @private Terminal of the middleware chain: the actual request dispatch.
do_dispatch(#{method := Method, url := URL,
              headers := Headers0, body := Body, options := Options0}) ->
  #hackney_url{transport=Transport,
               scheme = Scheme,
               host = Host,
               port = Port,
               user = User,
               password = Password,
               path = Path,
               qs = Query} = URL,

  %% Check for unsupported URL schemes
  case Transport of
    undefined ->
      {error, {unsupported_scheme, Scheme}};
    _ ->
      request_with_transport(Method, URL, Headers0, Body, Options0,
                             Transport, Host, Port, User, Password, Path, Query)
  end.

%% @private Continue request processing after transport validation
request_with_transport(Method, URL, Headers0, Body, Options0,
                       Transport, Host, Port, User, Password, Path, Query) ->
  Options = case User of
              <<>> -> Options0;
              _ -> lists:keystore(basic_auth, 1, Options0, {basic_auth, {User, Password}})
            end,

  %% Build final path
  FinalPath = case Query of
                <<>> -> Path;
                _ -> <<Path/binary, "?", Query/binary>>
              end,

  %% Check for proxy
  case maybe_proxy(Transport, URL#hackney_url.scheme, Host, Port, Options) of
    {ok, ConnPid} ->
      do_request(ConnPid, Method, FinalPath, Headers0, Body, Options, URL, Host);
    {ok, ConnPid, {http_proxy, TargetScheme, TargetHost, TargetPort, ProxyAuth}} ->
      %% HTTP proxy mode - use absolute URLs
      AbsolutePath = build_absolute_url(TargetScheme, TargetHost, TargetPort, FinalPath),
      Headers1 = add_proxy_auth_header(Headers0, ProxyAuth),
      do_request(ConnPid, Method, AbsolutePath, Headers1, Body, Options, URL, Host);
    Error ->
      Error
  end.

%% @doc Send a request on an existing connection.
%% Returns the connection, so the body is read with body/1 or pulled with
%% stream_body/1. A HEAD response has no body and comes back as
%% {ok, Status, Headers}.
-spec send_request(conn(), {atom(), binary(), list(), term()}) ->
    {ok, integer(), list(), conn()} | {ok, integer(), list()} | {error, term()}.
send_request(ConnPid, {Method, Path, Headers, Body}) when is_pid(ConnPid) ->
  %% Convert method to binary
  MethodBin = hackney_bstr:to_upper(hackney_bstr:to_binary(Method)),
  %% request_streaming/5 answers with the status and headers on every
  %% protocol and leaves the body on the connection. The plain request/5
  %% would hand back the whole body on HTTP/2 and HTTP/3, which this API
  %% has no place to put.
  case hackney_conn:request_streaming(ConnPid, MethodBin, Path, Headers, Body) of
    {ok, Status, RespHeaders} ->
      send_request_reply(MethodBin, Status, RespHeaders, ConnPid);
    {ok, Status, RespHeaders, _Pid} ->
      send_request_reply(MethodBin, Status, RespHeaders, ConnPid);
    {error, Reason} ->
      {error, Reason}
  end.

send_request_reply(<<"HEAD">>, Status, RespHeaders, _ConnPid) ->
  {ok, Status, RespHeaders};
send_request_reply(_Method, Status, RespHeaders, ConnPid) ->
  {ok, Status, RespHeaders, ConnPid}.

%%====================================================================
%% Streaming Request Body API
%%====================================================================

%% @doc Send a chunk of the request body.
%% Used when request was initiated with body = stream.
-spec send_body(conn(), iodata()) -> ok | {error, term()}.
send_body(ConnPid, Data) when is_pid(ConnPid) ->
  hackney_conn:send_body_chunk(ConnPid, Data).

%% @doc Finish sending the streaming request body.
-spec finish_send_body(conn()) -> ok | {error, term()}.
finish_send_body(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:finish_send_body(ConnPid).

%% @doc Start receiving the response after sending the full body.
%% Returns {ok, Status, Headers, ConnPid}.
-spec start_response(conn()) -> {ok, integer(), list(), conn()} | {error, term()}.
start_response(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:start_response(ConnPid).

%% @doc Read the full response body after start_response/1.
%% Consumes the response stream and returns it as a single binary. If the
%% server closes before a chunked or Content-Length body is complete, it
%% returns `{error, {closed, Partial}}' with the bytes that did arrive.
-spec body(conn()) -> {ok, binary()} | {error, term()}.
body(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:body(ConnPid).

%% @doc Same as body/1 with a receive timeout.
-spec body(conn(), timeout()) -> {ok, binary()} | {error, term()}.
body(ConnPid, Timeout) when is_pid(ConnPid) ->
  hackney_conn:body(ConnPid, Timeout).

%% @doc Read the response body one chunk at a time after start_response/1.
%% Returns {ok, Chunk} per chunk and done when the body is fully consumed.
-spec stream_body(conn()) -> {ok, binary()} | done | {error, term()}.
stream_body(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:stream_body(ConnPid).

%%====================================================================
%% Async Streaming API
%%====================================================================

%% @doc Request next chunk in {async, once} mode.
-spec stream_next(conn()) -> ok.
stream_next(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:stream_next(ConnPid).

%% @doc Stop async mode and return to sync mode.
-spec stop_async(conn()) -> ok | {error, term()}.
stop_async(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:stop_async(ConnPid).

%% @doc Pause async streaming.
-spec pause_stream(conn()) -> ok.
pause_stream(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:pause_stream(ConnPid).

%% @doc Resume async streaming.
-spec resume_stream(conn()) -> ok.
resume_stream(ConnPid) when is_pid(ConnPid) ->
  hackney_conn:resume_stream(ConnPid).

%%====================================================================
%% WebSocket API
%%====================================================================

%% @doc Connect to a WebSocket server.
%% URL should use ws:// or wss:// scheme.
%%
%% Options:
%% <ul>
%%   <li>active: false | true | once (default false)</li>
%%   <li>headers: Extra headers for upgrade request</li>
%%   <li>protocols: Sec-WebSocket-Protocol values</li>
%%   <li>connect_timeout: Connection timeout in ms (default 8000)</li>
%%   <li>recv_timeout: Receive timeout in ms (default infinity)</li>
%%   <li>connect_options: Options passed to transport connect</li>
%%   <li>ssl_options: Additional SSL options</li>
%% </ul>
%%
%% Returns `{ok, WsPid}' on success, where WsPid is the hackney_ws process.
-spec ws_connect(binary() | string()) -> {ok, pid()} | {error, term()}.
ws_connect(URL) ->
  ws_connect(URL, []).

-spec ws_connect(binary() | string(), list()) -> {ok, pid()} | {error, term()}.
ws_connect(URL, Options) when is_binary(URL) orelse is_list(URL) ->
  #hackney_url{
    transport = Transport,
    scheme = Scheme,
    host = Host,
    port = Port,
    path = Path0,
    qs = Query
  } = hackney_url:parse_url(URL),

  %% Validate scheme
  case Scheme of
    ws -> ok;
    wss -> ok;
    _ -> error({invalid_websocket_scheme, Scheme})
  end,

  %% Build path with query string
  Path = case Query of
    <<>> -> Path0;
    _ -> <<Path0/binary, "?", Query/binary>>
  end,

  %% Get proxy configuration (WebSocket always uses tunnel mode)
  ProxyConfig = get_ws_proxy_config(Scheme, Host, Options),

  %% Build connection options
  WsOpts = #{
    host => Host,
    port => Port,
    transport => Transport,
    path => Path,
    connect_timeout => proplists:get_value(connect_timeout, Options, 8000),
    recv_timeout => proplists:get_value(recv_timeout, Options, infinity),
    connect_options => proplists:get_value(connect_options, Options, []),
    ssl_options => proplists:get_value(ssl_options, Options, []),
    active => proplists:get_value(active, Options, false),
    headers => normalize_ws_headers(proplists:get_value(headers, Options, [])),
    protocols => proplists:get_value(protocols, Options, []),
    proxy => ProxyConfig
  },

  %% Start WebSocket process and connect
  case hackney_ws:start_link(WsOpts) of
    {ok, WsPid} ->
      Timeout = maps:get(connect_timeout, WsOpts),
      try hackney_ws:connect(WsPid, Timeout) of
        ok ->
          {ok, WsPid};
        {error, Reason} ->
          shutdown_ws(WsPid),
          {error, Reason}
      catch
        exit:{timeout, _} ->
          shutdown_ws(WsPid),
          {error, connect_timeout};
        exit:{noproc, _} ->
          {error, {ws_process_died, noproc}}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Send a WebSocket frame.
%% Frame types:
%%   - {text, Data} - Text message
%%   - {binary, Data} - Binary message
%%   - ping | {ping, Data} - Ping frame
%%   - pong | {pong, Data} - Pong frame
%%   - close | {close, Code, Reason} - Close frame
-spec ws_send(pid(), hackney_ws:ws_frame()) -> ok | {error, term()}.
ws_send(WsPid, Frame) when is_pid(WsPid) ->
  hackney_ws:send(WsPid, Frame).

%% @doc Receive a WebSocket frame (passive mode only).
%% Blocks until a frame is received or timeout.
%% Returns {ok, Frame} or {error, Reason}.
-spec ws_recv(pid()) -> {ok, hackney_ws:ws_frame()} | {error, term()}.
ws_recv(WsPid) when is_pid(WsPid) ->
  hackney_ws:recv(WsPid).

-spec ws_recv(pid(), timeout()) -> {ok, hackney_ws:ws_frame()} | {error, term()}.
ws_recv(WsPid, Timeout) when is_pid(WsPid) ->
  hackney_ws:recv(WsPid, Timeout).

%% @doc Set WebSocket options.
%% Supported options: [{active, true | false | once}]
-spec ws_setopts(pid(), list()) -> ok | {error, term()}.
ws_setopts(WsPid, Opts) when is_pid(WsPid) ->
  hackney_ws:setopts(WsPid, Opts).

%% @doc Close WebSocket connection gracefully.
-spec ws_close(pid()) -> ok.
ws_close(WsPid) when is_pid(WsPid) ->
  hackney_ws:close(WsPid).

-spec ws_close(pid(), {integer(), binary()}) -> ok.
ws_close(WsPid, {Code, Reason}) when is_pid(WsPid) ->
  hackney_ws:close(WsPid, {Code, Reason}).

%%====================================================================
%% WebTransport API
%%====================================================================

%% @doc Connect to a WebTransport server.
%%
%% The URL must use the https:// scheme (wss:// is accepted as an alias so
%% existing ws_* code can switch over by changing only the function name).
%% WebTransport always runs over TLS.
%%
%% Options:
%% <ul>
%%   <li>transport: h3 (default) or h2</li>
%%   <li>active: false | true | once (default false)</li>
%%   <li>headers: extra headers for the CONNECT request</li>
%%   <li>connect_timeout: connection timeout in ms (default 8000)</li>
%%   <li>recv_timeout: default receive timeout in ms (default infinity)</li>
%%   <li>ssl_options: TLS options (verify, cacerts/cacertfile, cert/certfile,
%%       key/keyfile)</li>
%%   <li>verify: verify_peer (default) | verify_none</li>
%%   <li>compat_mode: latest (default) | legacy_browser_compat</li>
%%   <li>max_recv_buffer: passive buffer cap in bytes (default 64 MiB)</li>
%% </ul>
%%
%% Returns `{ok, WtPid}' on success, where WtPid is the hackney_wt process.
-spec wt_connect(binary() | string()) -> {ok, pid()} | {error, term()}.
wt_connect(URL) ->
  wt_connect(URL, []).

-spec wt_connect(binary() | string(), list()) -> {ok, pid()} | {error, term()}.
wt_connect(URL, Options) when is_binary(URL) orelse is_list(URL) ->
  #hackney_url{
    scheme = Scheme,
    host = Host,
    port = Port,
    path = Path0,
    qs = Query
  } = hackney_url:parse_url(URL),

  %% WebTransport runs over HTTP/3 or HTTP/2, both TLS-only.
  case Scheme of
    https -> ok;
    wss -> ok;
    _ -> error({invalid_webtransport_scheme, Scheme})
  end,

  Path = case Query of
    <<>> -> Path0;
    _ -> <<Path0/binary, "?", Query/binary>>
  end,

  Headers = normalize_ws_headers(proplists:get_value(headers, Options, [])),

  %% Mirror the WebSocket GHSA-f9vr guard: reject CR/LF/NUL in the request
  %% path or in any caller-supplied header before it reaches the wire.
  case valid_wt_fields(Host, Path, Headers) of
    ok ->
      Transport = proplists:get_value(transport, Options, h3),
      ConnectTimeout = proplists:get_value(connect_timeout, Options, 8000),
      WtOpts = #{
        host => Host,
        port => Port,
        path => Path,
        transport => Transport,
        connect_opts => build_wt_connect_opts(Options, Headers),
        connect_timeout => ConnectTimeout,
        recv_timeout => proplists:get_value(recv_timeout, Options, infinity),
        active => proplists:get_value(active, Options, false),
        max_recv_buffer => proplists:get_value(max_recv_buffer, Options, 16#4000000)
      },
      case hackney_wt:start_link(WtOpts) of
        {ok, WtPid} ->
          try hackney_wt:connect(WtPid, ConnectTimeout) of
            ok ->
              {ok, WtPid};
            {error, Reason} ->
              shutdown_wt(WtPid),
              {error, Reason}
          catch
            exit:{noproc, _} ->
              {error, {wt_process_died, noproc}}
          end;
        {error, Reason} ->
          {error, Reason}
      end;
    {error, _} = Err ->
      Err
  end.

%% @doc Send on a WebTransport connection.
%% Frame forms: `{text, Data}', `{binary, Data}', `Data' (write to the
%% default stream); `{datagram, Data}'; `{stream, StreamId, Data}' or
%% `{stream, StreamId, Data, fin|nofin}'.
-spec wt_send(pid(), hackney_wt:wt_frame()) -> ok | {error, term()}.
wt_send(WtPid, Frame) when is_pid(WtPid) ->
  hackney_wt:send(WtPid, Frame).

%% @doc Receive the next message on the default channel (passive mode).
-spec wt_recv(pid()) -> {ok, hackney_wt:wt_msg()} | {error, term()}.
wt_recv(WtPid) when is_pid(WtPid) ->
  hackney_wt:recv(WtPid).

-spec wt_recv(pid(), timeout()) -> {ok, hackney_wt:wt_msg()} | {error, term()}.
wt_recv(WtPid, Timeout) when is_pid(WtPid) ->
  hackney_wt:recv(WtPid, Timeout).

%% @doc Set WebTransport options. Supported: [{active, true | false | once}]
-spec wt_setopts(pid(), list()) -> ok | {error, term()}.
wt_setopts(WtPid, Opts) when is_pid(WtPid) ->
  hackney_wt:setopts(WtPid, Opts).

%% @doc Close a WebTransport session gracefully.
-spec wt_close(pid()) -> ok.
wt_close(WtPid) when is_pid(WtPid) ->
  hackney_wt:close(WtPid).

-spec wt_close(pid(), {non_neg_integer(), binary()}) -> ok.
wt_close(WtPid, {Code, Reason}) when is_pid(WtPid) ->
  hackney_wt:close(WtPid, {Code, Reason}).

%% @doc Open a new stream multiplexed over the session.
-spec wt_open_stream(pid(), bidi | uni) -> {ok, non_neg_integer()} | {error, term()}.
wt_open_stream(WtPid, Type) when is_pid(WtPid) ->
  hackney_wt:open_stream(WtPid, Type).

%% @doc Write to a stream (no FIN).
-spec wt_stream_send(pid(), non_neg_integer(), iodata()) -> ok | {error, term()}.
wt_stream_send(WtPid, StreamId, Data) when is_pid(WtPid) ->
  hackney_wt:stream_send(WtPid, StreamId, Data).

%% @doc Write to a stream, optionally closing the write side (FIN).
-spec wt_stream_send(pid(), non_neg_integer(), iodata(), fin | nofin) -> ok | {error, term()}.
wt_stream_send(WtPid, StreamId, Data, Fin) when is_pid(WtPid) ->
  hackney_wt:stream_send(WtPid, StreamId, Data, Fin).

%% @doc Receive the next chunk on a stream (passive mode).
-spec wt_stream_recv(pid(), non_neg_integer()) -> hackney_wt:stream_msg().
wt_stream_recv(WtPid, StreamId) when is_pid(WtPid) ->
  hackney_wt:stream_recv(WtPid, StreamId).

-spec wt_stream_recv(pid(), non_neg_integer(), timeout()) -> hackney_wt:stream_msg().
wt_stream_recv(WtPid, StreamId, Timeout) when is_pid(WtPid) ->
  hackney_wt:stream_recv(WtPid, StreamId, Timeout).

%% @doc Close a stream gracefully (send FIN).
-spec wt_close_stream(pid(), non_neg_integer()) -> ok | {error, term()}.
wt_close_stream(WtPid, StreamId) when is_pid(WtPid) ->
  hackney_wt:close_stream(WtPid, StreamId).

%% @doc Abruptly terminate a stream with an error code.
-spec wt_reset_stream(pid(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
wt_reset_stream(WtPid, StreamId, ErrorCode) when is_pid(WtPid) ->
  hackney_wt:reset_stream(WtPid, StreamId, ErrorCode).

%% @doc Ask the peer to stop sending on a stream.
-spec wt_stop_sending(pid(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
wt_stop_sending(WtPid, StreamId, ErrorCode) when is_pid(WtPid) ->
  hackney_wt:stop_sending(WtPid, StreamId, ErrorCode).

%% @doc Send an unreliable datagram.
-spec wt_send_datagram(pid(), iodata()) -> ok | {error, term()}.
wt_send_datagram(WtPid, Data) when is_pid(WtPid) ->
  hackney_wt:send_datagram(WtPid, Data).

%% @doc Return WebTransport session information.
-spec wt_session_info(pid()) -> {ok, map()} | {error, term()}.
wt_session_info(WtPid) when is_pid(WtPid) ->
  hackney_wt:session_info(WtPid).

%% @private Signal the WebTransport process to shut down, ignoring errors.
shutdown_wt(WtPid) ->
  try exit(WtPid, shutdown) catch _:_ -> ok end.

%%====================================================================
%% HTTP/2 bidirectional (gRPC-style) stream API
%%====================================================================

%% @doc Open a full-duplex HTTP/2 stream (gRPC-style bidirectional streaming).
%% Establishes a dedicated HTTP/2 connection (ALPN, so an https URL) and opens
%% one stream on it. Returns a pid driven with h2_send/h2_recv etc. The method
%% defaults to POST.
%%
%% Options: connect_timeout, recv_timeout, connect_options, ssl_options,
%% {flow_control, auto | manual}, {active, true | false | once},
%% {max_recv_buffer, bytes | infinity}.
-spec h2_open(binary() | string(), list()) -> {ok, pid()} | {error, term()}.
h2_open(URL, Opts) ->
  h2_open(post, URL, [], Opts).

-spec h2_open(binary() | string(), list(), list()) -> {ok, pid()} | {error, term()}.
h2_open(URL, Headers, Opts) ->
  h2_open(post, URL, Headers, Opts).

-spec h2_open(atom() | binary() | string(), binary() | string(), list(), list()) ->
  {ok, pid()} | {error, term()}.
h2_open(Method, URL, Headers, Opts) ->
  #hackney_url{
    transport = Transport,
    scheme = Scheme,
    host = Host,
    port = Port,
    path = Path0,
    qs = Query
  } = hackney_url:parse_url(URL),
  case Transport of
    hackney_ssl ->
      Path = case Query of
        <<>> -> Path0;
        _ -> <<Path0/binary, "?", Query/binary>>
      end,
      H2Opts = #{
        method => h2_method_bin(Method),
        host => Host,
        port => Port,
        transport => Transport,
        path => Path,
        headers => Headers,
        connect_timeout => proplists:get_value(connect_timeout, Opts, 8000),
        recv_timeout => proplists:get_value(recv_timeout, Opts, infinity),
        connect_options => proplists:get_value(connect_options, Opts, []),
        ssl_options => proplists:get_value(ssl_options, Opts, []),
        flow_control => proplists:get_value(flow_control, Opts, auto),
        active => proplists:get_value(active, Opts, false),
        max_recv_buffer => proplists:get_value(max_recv_buffer, Opts, 16#4000000)
      },
      case hackney_h2_stream:start_link(H2Opts) of
        {ok, Pid} ->
          Timeout = maps:get(connect_timeout, H2Opts),
          try hackney_h2_stream:connect(Pid, Timeout) of
            ok ->
              {ok, Pid};
            {error, Reason} ->
              shutdown_h2(Pid),
              {error, Reason}
          catch
            exit:{timeout, _} ->
              shutdown_h2(Pid),
              {error, connect_timeout};
            exit:{noproc, _} ->
              {error, {h2_process_died, noproc}}
          end;
        {error, Reason} ->
          {error, Reason}
      end;
    _ ->
      {error, {scheme_not_supported, Scheme}}
  end.

%% @doc Send a DATA frame on the stream (no END_STREAM).
-spec h2_send(pid(), iodata()) -> ok | {error, term()}.
h2_send(Pid, Data) when is_pid(Pid) ->
  hackney_h2_stream:send(Pid, Data).

%% @doc Send a DATA frame, optionally half-closing the send side (`fin').
-spec h2_send(pid(), iodata(), fin | nofin) -> ok | {error, term()}.
h2_send(Pid, Data, Fin) when is_pid(Pid) ->
  hackney_h2_stream:send(Pid, Data, Fin).

%% @doc Send trailing HEADERS, half-closing the send side (gRPC trailers).
-spec h2_send_trailers(pid(), list()) -> ok | {error, term()}.
h2_send_trailers(Pid, Trailers) when is_pid(Pid) ->
  hackney_h2_stream:send_trailers(Pid, Trailers).

%% @doc Receive the next inbound message: {response, Status, Headers} |
%% {data, Data} | {trailers, Trailers} | done. After done, returns
%% {error, closed}. Passive mode only.
-spec h2_recv(pid()) -> {ok, hackney_h2_stream:h2_msg()} | {error, term()}.
h2_recv(Pid) when is_pid(Pid) ->
  hackney_h2_stream:recv(Pid).

-spec h2_recv(pid(), timeout()) -> {ok, hackney_h2_stream:h2_msg()} | {error, term()}.
h2_recv(Pid, Timeout) when is_pid(Pid) ->
  hackney_h2_stream:recv(Pid, Timeout).

%% @doc Acknowledge N consumed bytes (manual flow control only).
-spec h2_consume(pid(), non_neg_integer()) -> ok | {error, term()}.
h2_consume(Pid, NBytes) when is_pid(Pid) ->
  hackney_h2_stream:consume(Pid, NBytes).

%% @doc Set options. Supported: [{active, true | false | once}].
-spec h2_setopts(pid(), list()) -> ok | {error, term()}.
h2_setopts(Pid, Opts) when is_pid(Pid) ->
  hackney_h2_stream:setopts(Pid, Opts).

%% @doc Cancel the stream and tear down its connection.
-spec h2_close(pid()) -> ok.
h2_close(Pid) when is_pid(Pid) ->
  hackney_h2_stream:close(Pid).

%% @private Normalize an HTTP method to an uppercase binary.
h2_method_bin(M) when is_binary(M) -> M;
h2_method_bin(M) when is_atom(M) -> list_to_binary(string:to_upper(atom_to_list(M)));
h2_method_bin(M) when is_list(M) -> list_to_binary(string:to_upper(M)).

%% @private Signal the HTTP/2 stream process to shut down, ignoring errors.
shutdown_h2(Pid) ->
  try exit(Pid, shutdown) catch _:_ -> ok end.

%% @private Reject CR/LF/NUL in the authority, request path, or any
%% caller-supplied header used in the WebTransport CONNECT request
%% (GHSA-f9vr analog).
valid_wt_fields(Host, Path, Headers) ->
  Fields = [Host, Path | lists:flatmap(fun({N, V}) -> [N, V] end, Headers)],
  case lists:any(fun has_ctl_bytes/1, Fields) of
    true -> {error, invalid_handshake_header};
    false -> ok
  end.

has_ctl_bytes(Bin) when is_binary(Bin) ->
  binary:match(Bin, [<<"\r">>, <<"\n">>, <<0>>]) =/= nomatch;
has_ctl_bytes(L) when is_list(L) ->
  has_ctl_bytes(iolist_to_binary(L));
has_ctl_bytes(_) ->
  false.

%% @private Translate hackney connect options into a webtransport:connect/4
%% options map. Honours a caller-supplied CA (cacerts/cacertfile); when
%% verifying with no CA given, fall back to the bundled certifi store.
build_wt_connect_opts(Options, Headers) ->
  SslOpts = proplists:get_value(ssl_options, Options, []),
  Verify = proplists:get_value(verify, Options,
                               proplists:get_value(verify, SslOpts, verify_peer)),
  Base = #{headers => Headers, verify => Verify},
  Base1 = case proplists:get_value(compat_mode, Options) of
    undefined -> Base;
    CompatMode -> Base#{compat_mode => CompatMode}
  end,
  Base2 = wt_ca_opts(Base1, SslOpts, Verify),
  wt_cert_opts(Base2, SslOpts).

%% @private CA trust store selection.
wt_ca_opts(Base, SslOpts, Verify) ->
  case {proplists:get_value(cacertfile, SslOpts),
        proplists:get_value(cacerts, SslOpts)} of
    {undefined, undefined} when Verify =:= verify_peer ->
      Base#{cacerts => certifi:cacerts()};
    {undefined, undefined} ->
      Base;
    {CAFile, _} when CAFile =/= undefined ->
      Base#{cacertfile => CAFile};
    {_, CACerts} ->
      Base#{cacerts => CACerts}
  end.

%% @private Optional client certificate / key.
wt_cert_opts(Base, SslOpts) ->
  Base1 = case {proplists:get_value(certfile, SslOpts),
                proplists:get_value(cert, SslOpts)} of
    {CertFile, _} when CertFile =/= undefined -> Base#{certfile => CertFile};
    {_, Cert} when Cert =/= undefined -> Base#{cert => Cert};
    _ -> Base
  end,
  case {proplists:get_value(keyfile, SslOpts),
        proplists:get_value(key, SslOpts)} of
    {KeyFile, _} when KeyFile =/= undefined -> Base1#{keyfile => KeyFile};
    {_, Key} when Key =/= undefined -> Base1#{key => Key};
    _ -> Base1
  end.

%% @private Normalize WebSocket headers to {binary(), binary()} format
normalize_ws_headers(Headers) ->
  [{hackney_bstr:to_binary(Name), hackney_bstr:to_binary(Value)}
   || {Name, Value} <- Headers].

%% @private Get proxy configuration for WebSocket.
%% WebSocket always uses tunnel mode (CONNECT or SOCKS5), never simple HTTP proxy.
get_ws_proxy_config(Scheme, Host, Options) ->
  %% Map ws/wss to http/https for proxy env var lookup
  HttpScheme = case Scheme of
    ws -> http;
    wss -> https
  end,
  case get_proxy_config(HttpScheme, Host, Options) of
    false ->
      false;
    {http, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport} ->
      %% Simple HTTP proxy - convert to CONNECT tunnel for WebSocket
      {connect, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport};
    {connect, _, _, _, _} = Config ->
      Config;
    {socks5, _, _, _, _} = Config ->
      Config
  end.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Parse cookies from response headers.
-spec cookies(list()) -> list().
cookies(Headers) ->
  lists:foldl(fun({K, V}, Acc) ->
                  case hackney_bstr:to_lower(K) of
                    <<"set-cookie">> ->
                      case hackney_cookie:parse_cookie(V) of
                        {error, _} -> Acc;
                        [{Name, _} | _]=Cookie ->
                          [{Name, Cookie} | Acc]
                      end;
                    _ ->
                      Acc
                  end
              end, [], Headers).

%% @doc Get redirect location from headers.
redirect_location(Headers) when is_list(Headers) ->
  redirect_location(hackney_headers:from_list(Headers));
redirect_location(Headers) ->
  hackney_headers:get_value(<<"location">>, Headers).

%% @doc Get the final URL after following redirects.
%% First checks the stored location (set after redirects),
%% then falls back to the Location header from the last response.
-spec location(conn()) -> binary() | undefined.
location(ConnPid) when is_pid(ConnPid) ->
  case hackney_conn:get_location(ConnPid) of
    undefined ->
      %% No stored location, check response headers
      case hackney_conn:response_headers(ConnPid) of
        undefined -> undefined;
        Headers -> redirect_location(Headers)
      end;
    Location ->
      Location
  end.

%%====================================================================
%% Internal functions
%%====================================================================

do_request(ConnPid, Method, Path, Headers0, Body, Options, URL, _Host) ->
  %% Build headers
  Headers1 = hackney_headers:new(Headers0),
  Headers2 = add_host_header(URL, Headers1),

  %% Add default headers (User-Agent, Authorization, Cookies)
  Headers3 = add_default_headers(Headers2, Options, URL),

  %% Check for async mode
  Async = proplists:get_value(async, Options, false),
  StreamTo = proplists:get_value(stream_to, Options, self()),
  %% DEPRECATED: The with_body option is now ignored.
  %% Body is always returned directly for consistent behavior between HTTP/1.1 and HTTP/2.
  %% For incremental body streaming, use async mode instead.
  _ = proplists:get_value(with_body, Options, true), %% Read but ignored
  WithBody = true, %% Always return body directly
  FollowRedirect = proplists:get_value(follow_redirect, Options, false),
  MaxRedirect = proplists:get_value(max_redirect, Options, 5),
  RedirectCount = proplists:get_value(redirect_count, Options, 0),

  %% Convert method to binary
  MethodBin = hackney_bstr:to_upper(hackney_bstr:to_binary(Method)),

  case Async of
    false ->
      %% Sync request with redirect handling
      sync_request_with_redirect(ConnPid, MethodBin, Path, Headers3, Body, WithBody,
                                 Options, URL, FollowRedirect, MaxRedirect, RedirectCount);
    _ ->
      %% Async request with optional redirect handling
      async_request(ConnPid, MethodBin, Path, Headers3, Body, Async, StreamTo, FollowRedirect, Options)
  end.

sync_request_with_redirect(ConnPid, Method, Path, Headers, Body, WithBody, Options, URL,
                           FollowRedirect, MaxRedirect, RedirectCount) ->
  %% Handle body encoding
  {FinalHeaders, FinalBody} = encode_body(Headers, Body, Options),
  HeadersList = hackney_headers:to_list(FinalHeaders),

  %% Check if this is a streaming body request
  case FinalBody of
    stream ->
      %% For streaming body, send headers and return immediately. Forward
      %% send_timeout so the body chunks use the caller's deadline even on a
      %% reused pooled connection, and max_body_size for the later body/1.
      ReqOpts0 = case proplists:get_value(send_timeout, Options) of
        undefined -> [];
        SendTimeout -> [{send_timeout, SendTimeout}]
      end,
      ReqOpts = case proplists:get_value(max_body_size, Options,
                                         proplists:get_value(max_body, Options)) of
        undefined -> ReqOpts0;
        MaxBodySize -> [{max_body_size, MaxBodySize} | ReqOpts0]
      end,
      case hackney_conn:send_request_headers(ConnPid, Method, Path, HeadersList, ReqOpts) of
        ok -> {ok, ConnPid};
        {error, Reason} -> {error, Reason}
      end;
    _ ->
      sync_request_with_redirect_body(ConnPid, Method, Path, HeadersList, FinalBody,
                                      WithBody, Options, URL, FollowRedirect, MaxRedirect, RedirectCount)
  end.

sync_request_with_redirect_body(ConnPid, Method, Path, HeadersList, FinalBody,
                                WithBody, Options, URL, FollowRedirect, MaxRedirect, RedirectCount) ->
  %% Extract request options for 1xx informational responses and auto_decompress
  ReqOpts0 = case proplists:get_value(inform_fun, Options) of
    undefined -> [];
    InformFun -> [{inform_fun, InformFun}]
  end,
  ReqOpts1 = case proplists:get_value(auto_decompress, Options, false) of
    true -> [{auto_decompress, true} | ReqOpts0];
    false -> ReqOpts0
  end,
  %% Pass recv_timeout through to the connection so it's applied per-request
  ReqOpts2 = case proplists:get_value(recv_timeout, Options) of
    undefined -> ReqOpts1;
    RecvTimeout -> [{recv_timeout, RecvTimeout} | ReqOpts1]
  end,
  %% Pass send_timeout through so HTTP/2 body sends blocked on flow control
  %% use the caller's deadline
  ReqOpts3 = case proplists:get_value(send_timeout, Options) of
    undefined -> ReqOpts2;
    SendTimeout -> [{send_timeout, SendTimeout} | ReqOpts2]
  end,
  %% Cap on the buffered response body (max_body_size, or the 1.x max_body)
  ReqOpts = case proplists:get_value(max_body_size, Options,
                                     proplists:get_value(max_body, Options)) of
    undefined -> ReqOpts3;
    MaxBodySize -> [{max_body_size, MaxBodySize} | ReqOpts3]
  end,
  case hackney_conn:request(ConnPid, Method, Path, HeadersList, FinalBody, infinity, ReqOpts) of
    %% HTTP/2 returns body directly - handle 4-tuple first
    {ok, Status, RespHeaders, RespBody} when Status >= 301, Status =< 303; Status =:= 307; Status =:= 308 ->
      %% HTTP/2 redirect status
      case FollowRedirect of
        true when RedirectCount < MaxRedirect ->
          follow_redirect(ConnPid, Method, FinalBody, WithBody, Options, URL,
                         RespHeaders, Status, MaxRedirect, RedirectCount);
        true ->
          {error, {max_redirect, RedirectCount}};
        false ->
          {ok, Status, RespHeaders, RespBody}
      end;
    {ok, Status, RespHeaders, RespBody} ->
      %% HTTP/2 response with body - already have body
      case Method of
        <<"HEAD">> ->
          {ok, Status, RespHeaders};
        _ ->
          {ok, Status, RespHeaders, RespBody}
      end;
    %% HTTP/1.1 returns 3-tuple, body fetched separately
    {ok, Status, RespHeaders} when Status >= 301, Status =< 303; Status =:= 307; Status =:= 308 ->
      %% Redirect status
      case FollowRedirect of
        true when RedirectCount < MaxRedirect ->
          %% Skip the body if any
          _ = hackney_conn:body(ConnPid),
          %% Follow redirect
          follow_redirect(ConnPid, Method, FinalBody, WithBody, Options, URL,
                         RespHeaders, Status, MaxRedirect, RedirectCount);
        true ->
          {error, {max_redirect, RedirectCount}};
        false ->
          %% Return the redirect response with body
          case hackney_conn:body(ConnPid) of
            {ok, RespBody} ->
              {ok, Status, RespHeaders, RespBody};
            {error, Reason} ->
              {error, Reason}
          end
      end;
    {ok, Status, RespHeaders} ->
      case Method of
        <<"HEAD">> ->
          %% HEAD responses have no body - call body() to trigger auto-release
          %% (body returns immediately for HEAD with empty response)
          _ = hackney_conn:body(ConnPid),
          {ok, Status, RespHeaders};
        _ ->
          %% Always fetch body for consistent response format
          case hackney_conn:body(ConnPid) of
            {ok, RespBody} ->
              %% Body read - connection auto-released to pool
              {ok, Status, RespHeaders, RespBody};
            {error, Reason} ->
              {error, Reason}
          end
      end;
    {error, Reason} ->
      {error, Reason}
  end.

follow_redirect(ConnPid, Method, Body, WithBody, Options, CurrentURL, RespHeaders, Status,
                MaxRedirect, RedirectCount) ->
  %% Get the Location header
  Location = redirect_location(RespHeaders),
  case Location of
    undefined ->
      {error, no_location_header};
    LocationBin ->
      %% Parse the new URL (could be relative or absolute)
      NewURL = resolve_redirect_url(CurrentURL, LocationBin),
      %% Get the full URL as a binary for storing
      FinalLocation = hackney_url:unparse_url(NewURL),
      %% Determine method for redirect (301, 302, 303 -> GET, 307, 308 -> same method)
      NewMethod = case Status of
        S when S =:= 301; S =:= 302; S =:= 303 ->
          <<"GET">>;
        _ ->
          Method
      end,
      NewBody = case NewMethod of
        <<"GET">> -> <<>>;
        _ -> Body
      end,
      %% Make new request to the redirect URL
      %% Remove old redirect_count and add incremented one
      Options1 = proplists:delete(redirect_count, Options),
      %% CVE-2018-1000007: Strip sensitive auth options when redirecting to a different origin
      %% unless location_trusted is set (similar to curl's --location-trusted)
      Options2 = maybe_strip_auth_on_redirect(CurrentURL, NewURL, Options1),
      case request(NewMethod, NewURL, [], NewBody,
                   [{follow_redirect, true}, {max_redirect, MaxRedirect},
                    {redirect_count, RedirectCount + 1}, {with_body, WithBody} | Options2]) of
        {ok, Status2, Headers2, Body2} ->
          %% Store the final location in the connection (the conn may already
          %% be gone, so set_location can return {error, closed}).
          _ = hackney_conn:set_location(ConnPid, FinalLocation),
          {ok, Status2, Headers2, Body2};
        {ok, Status2, Headers2} ->
          %% Store the final location in the connection
          _ = hackney_conn:set_location(ConnPid, FinalLocation),
          {ok, Status2, Headers2};
        Error ->
          Error
      end
  end.

resolve_redirect_url(CurrentURL, Location) when is_binary(Location) ->
  case Location of
    <<"http://", _/binary>> -> hackney_url:parse_url(Location);
    <<"https://", _/binary>> -> hackney_url:parse_url(Location);
    <<"ws://", _/binary>> -> hackney_url:parse_url(Location);
    <<"wss://", _/binary>> -> hackney_url:parse_url(Location);
    <<"//", _/binary>> ->
      %% Network-path reference (RFC 3986 Section 4.2)
      %% Use the current scheme with the new authority and path
      Scheme = CurrentURL#hackney_url.scheme,
      SchemePrefix = atom_to_binary(Scheme, utf8),
      hackney_url:parse_url(<<SchemePrefix/binary, ":", Location/binary>>);
    <<"/", _/binary>> ->
      %% Absolute-path reference - parse query string from Location
      {Path, Qs} = parse_path_qs(Location),
      CurrentURL#hackney_url{path = Path, qs = Qs};
    _ ->
      %% Relative-path reference (RFC 3986 Section 5.2.3)
      %% Parse query string from Location first
      {RelPath, Qs} = parse_path_qs(Location),
      CurrentPath = CurrentURL#hackney_url.path,
      NewPath = merge_paths(CurrentPath, RelPath),
      CurrentURL#hackney_url{path = NewPath, qs = Qs}
  end.

%% @private Parse path and query string from a path-like string
parse_path_qs(PathLike) ->
  case binary:split(PathLike, <<"?">>) of
    [Path] -> {Path, <<>>};
    [Path, Qs] -> {Path, Qs}
  end.

%% @private Merge a relative path with a base path per RFC 3986 Section 5.2.3
merge_paths(BasePath, RelPath) when is_binary(BasePath), is_binary(RelPath) ->
  case BasePath of
    <<>> ->
      %% Empty base path - prepend /
      <<"/", RelPath/binary>>;
    <<"/">> ->
      %% Root path - just prepend /
      <<"/", RelPath/binary>>;
    _ ->
      %% Get directory part of base path (everything up to and including last /)
      BaseDir = base_directory(BasePath),
      iolist_to_binary([BaseDir, RelPath])
  end.

%% @private Get the directory part of a path (up to and including last /)
%% Example: "/a/b/c" -> "/a/b/", "/a/b/" -> "/a/b/", "/" -> "/", "" -> ""
base_directory(Path) ->
  case find_last_slash(Path) of
    -1 -> <<>>;
    Pos -> binary:part(Path, 0, Pos + 1)
  end.

%% @private Find the position of the last "/" in a binary
find_last_slash(Bin) ->
  find_last_slash(Bin, byte_size(Bin) - 1).

find_last_slash(_Bin, Pos) when Pos < 0 -> -1;
find_last_slash(Bin, Pos) ->
  case binary:at(Bin, Pos) of
    $/ -> Pos;
    _ -> find_last_slash(Bin, Pos - 1)
  end.

%% @private Strip sensitive auth options when redirecting to a different origin.
%% This prevents credential leakage per CVE-2018-1000007. The origin is the
%% {scheme, host, port} triple (hackney_url:same_origin/2, GHSA-h73q):
%% comparing the host alone let an https -> http redirect resend basic_auth
%% and cookie in cleartext, and a redirect to another port hand them to a
%% different service on the same host.
%% Use location_trusted option to allow forwarding auth to different origins (like curl's --location-trusted).
maybe_strip_auth_on_redirect(CurrentURL, NewURL, Options) ->
  LocationTrusted = proplists:get_value(location_trusted, Options, false),
  case LocationTrusted of
    true ->
      %% User explicitly allows forwarding auth to different origins
      Options;
    false ->
      case hackney_url:same_origin(CurrentURL, NewURL) of
        true ->
          %% Same origin - keep auth options
          Options;
        false ->
          %% Different origin - strip sensitive options
          lists:filter(fun
            ({basic_auth, _}) -> false;
            ({cookie, _}) -> false;
            (_) -> true
          end, Options)
      end
  end.

async_request(ConnPid, Method, Path, Headers, Body, AsyncMode, StreamTo, FollowRedirect, Options) ->
  %% Handle body encoding
  {FinalHeaders, FinalBody} = encode_body(Headers, Body, []),
  HeadersList = hackney_headers:to_list(FinalHeaders),
  %% Build ReqOpts for recv_timeout (fix for issue #832)
  ReqOpts0 = case proplists:get_value(recv_timeout, Options) of
    undefined -> [];
    RecvTimeout -> [{recv_timeout, RecvTimeout}]
  end,
  ReqOpts = case proplists:get_value(send_timeout, Options) of
    undefined -> ReqOpts0;
    SendTimeout -> [{send_timeout, SendTimeout} | ReqOpts0]
  end,
  %% Note: Issue #646 - ownership transfer to StreamTo (when different from caller)
  %% is handled atomically inside hackney_conn:do_request_async
  case hackney_conn:request_async(ConnPid, Method, Path, HeadersList, FinalBody, AsyncMode, StreamTo, FollowRedirect, ReqOpts) of
    {ok, Ref} ->
      {ok, Ref};
    {error, Reason} ->
      {error, Reason}
  end.

encode_body(Headers, <<>>, _Options) ->
  {Headers, <<>>};
encode_body(Headers, [], _Options) ->
  {Headers, <<>>};
encode_body(Headers, {form, KVs}, _Options) ->
  {CLen, CType, EncodedBody} = encode_form(KVs),
  Headers1 = hackney_headers:store(<<"Content-Type">>, CType, Headers),
  Headers2 = hackney_headers:store(<<"Content-Length">>, integer_to_binary(CLen), Headers1),
  {Headers2, EncodedBody};
encode_body(Headers, {multipart, Parts}, _Options) ->
  %% Encode multipart body
  Boundary = hackney_multipart:boundary(),
  {MpBody, MpSize} = hackney_multipart:encode_form(Parts, Boundary),
  %% Add Content-Type with boundary
  ContentType = <<"multipart/form-data; boundary=", Boundary/binary>>,
  Headers1 = hackney_headers:store(<<"Content-Type">>, ContentType, Headers),
  Headers2 = hackney_headers:store(<<"Content-Length">>, integer_to_binary(MpSize), Headers1),
  {Headers2, MpBody};
encode_body(Headers, Body, _Options) when is_binary(Body) ->
  %% Add Content-Length if not present
  Headers1 = case hackney_headers:get_value(<<"content-length">>, Headers) of
    undefined ->
      hackney_headers:store(<<"Content-Length">>, integer_to_binary(byte_size(Body)), Headers);
    _ ->
      Headers
  end,
  %% Add default Content-Type if not present (RFC 7231 recommends application/octet-stream)
  {_, Headers2} = hackney_headers:store_new(<<"Content-Type">>, <<"application/octet-stream">>, Headers1),
  {Headers2, Body};
encode_body(Headers, Body, _Options) when is_list(Body) ->
  Bin = iolist_to_binary(Body),
  encode_body(Headers, Bin, _Options);
encode_body(Headers, Body, _Options) ->
  {Headers, Body}.

%% @doc Encode form data as application/x-www-form-urlencoded
encode_form(KVs) ->
  Lines = hackney_url:qs(KVs),
  CType = <<"application/x-www-form-urlencoded; charset=utf-8">>,
  {byte_size(Lines), CType, Lines}.

add_host_header(#hackney_url{transport=Transport, netloc=Netloc}, Headers) ->
  HostValue = case Transport of
                hackney_local_tcp -> hackney_url:urlencode(Netloc);
                _ -> Netloc
              end,
  {_, Headers1} = hackney_headers:store_new(<<"Host">>, HostValue, Headers),
  Headers1.

%% Add default headers: User-Agent, Authorization (basic auth), Cookies
add_default_headers(Headers, Options, URL) ->
  %% Add User-Agent
  {_, Headers1} = hackney_headers:store_new(<<"User-Agent">>, default_ua(), Headers),

  %% Add basic auth if present
  Headers2 = case proplists:get_value(basic_auth, Options) of
    undefined ->
      Headers1;
    {User, Pwd} ->
      %% Check if basic auth over HTTP is allowed
      Transport = URL#hackney_url.transport,
      AllowInsecureAuth = proplists:get_value(insecure_basic_auth, Options,
                            hackney_app:get_app_env(insecure_basic_auth, true)),
      case {Transport, AllowInsecureAuth} of
        {hackney_ssl, _} ->
          %% HTTPS - always safe
          add_basic_auth_header(User, Pwd, Headers1);
        {_, true} ->
          %% HTTP with explicit bypass
          add_basic_auth_header(User, Pwd, Headers1);
        {_, false} ->
          erlang:error({insecure_basic_auth,
                       "Basic authentication over HTTP is insecure. "
                       "Use HTTPS, add {insecure_basic_auth, true} option, or set "
                       "application:set_env(hackney, insecure_basic_auth, true) to bypass this check."})
      end
  end,

  %% Add Accept-Encoding if auto_decompress is enabled (issue #155)
  Headers3 = case proplists:get_value(auto_decompress, Options, false) of
    true ->
      {_, H} = hackney_headers:store_new(<<"Accept-Encoding">>, <<"gzip, deflate">>, Headers2),
      H;
    false ->
      Headers2
  end,

  %% Add cookies if present
  case proplists:get_value(cookie, Options, []) of
    [] -> Headers3;
    Cookies -> add_cookies_header(Cookies, Headers3)
  end.

add_basic_auth_header(User, Pwd, Headers) ->
  User1 = hackney_bstr:to_binary(User),
  Pwd1 = hackney_bstr:to_binary(Pwd),
  Credentials = base64:encode(<<User1/binary, ":", Pwd1/binary>>),
  hackney_headers:store(<<"Authorization">>, <<"Basic ", Credentials/binary>>, Headers).

add_cookies_header([], Headers) ->
  Headers;
add_cookies_header(Cookies, Headers) when is_list(Cookies) ->
  %% Format cookies as "name1=value1; name2=value2"
  CookieStr = format_cookies(Cookies),
  case CookieStr of
    <<>> -> Headers;
    _ -> hackney_headers:store(<<"Cookie">>, CookieStr, Headers)
  end;
add_cookies_header(Cookie, Headers) when is_binary(Cookie) ->
  hackney_headers:store(<<"Cookie">>, Cookie, Headers).

format_cookies([]) ->
  <<>>;
format_cookies([{Name, Value} | Rest]) ->
  First = iolist_to_binary([Name, <<"=">>, Value]),
  format_cookies(Rest, First);
format_cookies([Cookie | Rest]) when is_binary(Cookie) ->
  format_cookies(Rest, Cookie).

format_cookies([], Acc) ->
  Acc;
format_cookies([{Name, Value} | Rest], Acc) ->
  format_cookies(Rest, <<Acc/binary, "; ", (iolist_to_binary([Name, <<"=">>, Value]))/binary>>);
format_cookies([Cookie | Rest], Acc) when is_binary(Cookie) ->
  format_cookies(Rest, <<Acc/binary, "; ", Cookie/binary>>).

default_ua() ->
  <<"hackney/", (list_to_binary(get_version()))/binary>>.

get_version() ->
  case application:get_key(hackney, vsn) of
    {ok, Vsn} -> Vsn;
    undefined -> "1.0.0"
  end.

use_pool(Options) ->
  UseDefaultPool = case application:get_env(hackney, use_default_pool) of
                     {ok, Val} -> Val;
                     _ -> true
                   end,
  case proplists:get_value(pool, Options) of
    false -> false;
    undefined when UseDefaultPool =:= false -> false;
    undefined -> default;
    PoolName -> PoolName
  end.

maybe_proxy(Transport, Scheme, Host, Port, Options) ->
  case get_proxy_config(Scheme, Host, Options) of
    false ->
      %% No proxy configured, direct connection
      open_conn(Transport, Host, Port, Options);
    {connect, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport} ->
      %% HTTP CONNECT tunnel (for HTTPS through HTTP/HTTPS proxy)
      connect_via_connect_proxy(Transport, Host, Port, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport, Options);
    {socks5, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport} ->
      %% SOCKS5 proxy
      connect_via_socks5_proxy(Transport, Host, Port, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport, Options);
    {http, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport} ->
      %% Simple HTTP proxy - connect to proxy, use absolute URLs
      connect_via_http_proxy(Scheme, Host, Port, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport, Options)
  end.

%% @doc Connect through HTTP CONNECT proxy (tunnel).
%% Used for HTTPS requests through HTTP/HTTPS proxy.
%% ProxyTransport: tcp for HTTP proxy, ssl for HTTPS proxy
connect_via_connect_proxy(Transport, Host, Port, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport, Options) ->
  %% Build options for hackney_http_connect
  ConnectOpts0 = [
    {connect_host, Host},
    {connect_port, Port},
    {connect_transport, Transport},
    {proxy_transport, ProxyTransport}
  ],
  ConnectOpts1 = case ProxyAuth of
    undefined -> ConnectOpts0;
    {User, Pass} -> [{connect_user, User}, {connect_pass, Pass} | ConnectOpts0]
  end,
  %% Add SSL options if connecting to HTTPS target
  ConnectOpts2 = case Transport of
    hackney_ssl ->
      SslOpts = proplists:get_value(ssl_options, Options, []),
      [{ssl_options, SslOpts} | ConnectOpts1];
    _ ->
      ConnectOpts1
  end,
  %% Add proxy SSL options if connecting to HTTPS proxy
  ConnectOpts3 = case ProxyTransport of
    ssl ->
      ProxySslOpts = proplists:get_value(proxy_ssl_options, Options, []),
      [{proxy_ssl_options, ProxySslOpts} | ConnectOpts2];
    _ ->
      ConnectOpts2
  end,
  %% Add recv_timeout for proxy handshake (issue #569)
  RecvTimeout = proplists:get_value(recv_timeout, Options, infinity),
  ConnectOpts4 = [{recv_timeout, RecvTimeout} | ConnectOpts3],
  %% Add other connection options
  ConnectOpts = ConnectOpts4 ++ proplists:get_value(connect_options, Options, []),
  Timeout = proplists:get_value(connect_timeout, Options, 8000),

  case hackney_http_connect:connect(ProxyHost, ProxyPort, ConnectOpts, Timeout) of
    {ok, ProxySocket} ->
      %% Start hackney_conn with the pre-established socket
      %% HTTP CONNECT tunnels should not be reused/pooled (tunnel is destination-specific)
      start_conn_with_socket(Host, Port, Transport, ProxySocket, [{no_reuse, true} | Options]);
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Connect through SOCKS5 proxy.
%% ProxyTransport: tcp for plain SOCKS5, ssl for SOCKS5 over TLS
connect_via_socks5_proxy(Transport, Host, Port, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport, Options) ->
  %% Build options for hackney_socks5
  Socks5Opts0 = [
    {socks5_host, ProxyHost},
    {socks5_port, ProxyPort},
    {socks5_transport, Transport},
    {proxy_transport, ProxyTransport}
  ],
  Socks5Opts1 = case ProxyAuth of
    undefined -> Socks5Opts0;
    {User, Pass} -> [{socks5_user, User}, {socks5_pass, Pass} | Socks5Opts0]
  end,
  %% Add SSL options if connecting to HTTPS target
  Socks5Opts2 = case Transport of
    hackney_ssl ->
      SslOpts = proplists:get_value(ssl_options, Options, []),
      [{ssl_options, SslOpts} | Socks5Opts1];
    _ ->
      Socks5Opts1
  end,
  %% Add proxy SSL options if connecting to SOCKS5 over TLS
  Socks5Opts3 = case ProxyTransport of
    ssl ->
      ProxySslOpts = proplists:get_value(proxy_ssl_options, Options, []),
      [{proxy_ssl_options, ProxySslOpts} | Socks5Opts2];
    _ ->
      Socks5Opts2
  end,
  %% Add socks5_resolve option if specified
  Socks5Opts4 = case proplists:get_value(socks5_resolve, Options) of
    undefined -> Socks5Opts3;
    Resolve -> [{socks5_resolve, Resolve} | Socks5Opts3]
  end,
  %% Add other connection options
  Socks5Opts = Socks5Opts4 ++ proplists:get_value(connect_options, Options, []),
  Timeout = proplists:get_value(connect_timeout, Options, 8000),

  case hackney_socks5:connect(Host, Port, Socks5Opts, Timeout) of
    {ok, ProxySocket} ->
      %% Start hackney_conn with the pre-established socket
      %% SOCKS5 tunnels should not be reused/pooled (issue #283)
      start_conn_with_socket(Host, Port, Transport, ProxySocket, [{no_reuse, true} | Options]);
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Connect through simple HTTP proxy (no tunneling).
%% Used for HTTP requests through HTTP/HTTPS proxy. Requests use absolute URLs.
%% ProxyTransport: tcp for HTTP proxy, ssl for HTTPS proxy
connect_via_http_proxy(TargetScheme, TargetHost, TargetPort, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport, Options) ->
  %% Determine transport module and options based on proxy transport
  {ProxyTransportMod, ConnectOpts} = case ProxyTransport of
    ssl ->
      %% Use proxy_ssl_options for the proxy connection
      ProxySslOpts = proplists:get_value(proxy_ssl_options, Options, []),
      %% Replace ssl_options with proxy_ssl_options for the connection
      Opts1 = proplists:delete(ssl_options, Options),
      {hackney_ssl, [{ssl_options, ProxySslOpts} | Opts1]};
    _ ->
      {hackney_tcp, Options}
  end,
  %% Connect directly to the proxy server
  case open_conn(ProxyTransportMod, ProxyHost, ProxyPort, ConnectOpts) of
    {ok, ConnPid} ->
      %% Return connection with proxy info for absolute URL mode
      {ok, ConnPid, {http_proxy, TargetScheme, TargetHost, TargetPort, ProxyAuth}};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Build absolute URL for HTTP proxy requests.
build_absolute_url(Scheme, Host, Port, Path) ->
  SchemeBin = atom_to_binary(Scheme),
  HostBin = hackney_bstr:to_binary(Host),
  %% Include port only if non-default
  HostPort = case {Scheme, Port} of
    {http, 80} -> HostBin;
    {https, 443} -> HostBin;
    _ -> <<HostBin/binary, ":", (integer_to_binary(Port))/binary>>
  end,
  <<SchemeBin/binary, "://", HostPort/binary, Path/binary>>.

%% @doc Add Proxy-Authorization header if auth is configured.
add_proxy_auth_header(Headers, undefined) ->
  Headers;
add_proxy_auth_header(Headers, {User, Pass}) ->
  Credentials = base64:encode(<<User/binary, ":", Pass/binary>>),
  AuthHeader = {<<"Proxy-Authorization">>, <<"Basic ", Credentials/binary>>},
  [AuthHeader | Headers].

%% @doc Extract proxy configuration from options.
%% Returns: false | {Type, Host, Port, Auth}
%% Type: http | connect | socks5
%% Auth: undefined | {User, Pass}
%% TargetHost is used to check NO_PROXY for environment variable proxies.
-spec get_proxy_config(atom(), string() | binary(), list()) ->
  false | {http | connect | socks5, string(), inet:port_number(),
           undefined | {binary(), binary()}, tcp | ssl}.
get_proxy_config(Scheme, TargetHost, Options) ->
  case proplists:get_value(proxy, Options) of
    undefined ->
      %% No explicit proxy option, check environment variables
      get_proxy_from_env(Scheme, TargetHost, Options);
    false ->
      false;
    ProxyUrl when is_binary(ProxyUrl); is_list(ProxyUrl) ->
      parse_proxy_option(ProxyUrl, Scheme, Options);
    {ProxyHost, ProxyPort} when (is_list(ProxyHost) orelse is_atom(ProxyHost) orelse is_binary(ProxyHost)), is_integer(ProxyPort) ->
      %% Simple tuple: use HTTP proxy for http, CONNECT for https
      ProxyAuth = proplists:get_value(proxy_auth, Options),
      ProxyTransport = proplists:get_value(proxy_transport, Options, tcp),
      {proxy_type_for_scheme(Scheme), normalize_proxy_host(ProxyHost), ProxyPort, ProxyAuth, ProxyTransport};
    {connect, ProxyHost, ProxyPort} when (is_list(ProxyHost) orelse is_atom(ProxyHost) orelse is_binary(ProxyHost)), is_integer(ProxyPort) ->
      %% Explicit CONNECT tunnel
      ProxyAuth = proplists:get_value(proxy_auth, Options),
      ProxyTransport = proplists:get_value(proxy_transport, Options, tcp),
      {connect, normalize_proxy_host(ProxyHost), ProxyPort, ProxyAuth, ProxyTransport};
    {socks5, ProxyHost, ProxyPort} when (is_list(ProxyHost) orelse is_atom(ProxyHost) orelse is_binary(ProxyHost)), is_integer(ProxyPort) ->
      %% SOCKS5 proxy
      User = proplists:get_value(socks5_user, Options),
      Pass = proplists:get_value(socks5_pass, Options, <<>>),
      Auth = case User of
        undefined -> undefined;
        _ -> {User, Pass}
      end,
      ProxyTransport = proplists:get_value(proxy_transport, Options, tcp),
      {socks5, normalize_proxy_host(ProxyHost), ProxyPort, Auth, ProxyTransport};
    _ ->
      false
  end.

%% @private Accept a proxy host given as a string, a binary or an atom
%% (e.g. `localhost'), as hackney 1.x did, and normalise it to a string.
%% A new is_list/1 guard regressed atom hosts to a silent fall-through (#858).
normalize_proxy_host(H) when is_list(H) -> H;
normalize_proxy_host(H) when is_atom(H) -> atom_to_list(H);
normalize_proxy_host(H) when is_binary(H) -> binary_to_list(H).

%% Parse proxy URL and determine type based on target scheme
parse_proxy_option(ProxyUrl, Scheme, Options) ->
  case parse_proxy_url(ProxyUrl) of
    {ok, #{scheme := ProxyScheme, host := ProxyHost, port := ProxyPort,
           user := User, password := Pass}} ->
      Auth = case User of
        undefined -> proplists:get_value(proxy_auth, Options);
        _ -> {User, Pass}
      end,
      Type = case ProxyScheme of
        socks5 -> socks5;
        _ -> proxy_type_for_scheme(Scheme)
      end,
      %% Determine proxy transport based on proxy URL scheme
      ProxyTransport = case ProxyScheme of
        https -> ssl;
        _ -> tcp
      end,
      {Type, ProxyHost, ProxyPort, Auth, ProxyTransport};
    {error, _} ->
      false
  end.

%% @doc Get proxy configuration from environment variables.
%% Checks HTTP_PROXY, HTTPS_PROXY, ALL_PROXY based on scheme.
%% Returns false if NO_PROXY matches the target host.
get_proxy_from_env(Scheme, TargetHost, Options) ->
  case get_proxy_env(Scheme) of
    false ->
      false;
    {ok, ProxyUrl} ->
      %% Check if target host is in NO_PROXY list
      case check_no_proxy(TargetHost, get_no_proxy()) of
        true ->
          %% Host is in NO_PROXY, don't use proxy
          false;
        false ->
          parse_proxy_option(ProxyUrl, Scheme, Options)
      end
  end.

%% @doc Get proxy URL from environment variables.
get_proxy_env(Scheme) ->
  case Scheme of
    https -> get_proxy_env_https();
    _ -> get_proxy_env_http()
  end.

get_proxy_env_https() ->
  do_get_proxy_env(?HTTPS_PROXY_ENV_VARS).

get_proxy_env_http() ->
  do_get_proxy_env(?HTTP_PROXY_ENV_VARS).

do_get_proxy_env([Var | Rest]) when is_list(Var) ->
  case os:getenv(Var) of
    false -> do_get_proxy_env(Rest);
    Url ->
      %% Trim whitespace from the URL
      TrimmedUrl = string:trim(Url),
      case TrimmedUrl of
        "" -> do_get_proxy_env(Rest);
        _ -> {ok, TrimmedUrl}
      end
  end;
do_get_proxy_env([]) ->
  false.

%% @doc Get NO_PROXY list from environment variables.
%% Returns list of hosts/domains to bypass proxy.
get_no_proxy() ->
  case do_get_proxy_env(?HTTP_NO_PROXY_ENV_VARS) of
    false -> [];
    {ok, NoProxyStr} ->
      %% Split by comma and trim each entry
      Entries = string:split(NoProxyStr, ",", all),
      [string:trim(E) || E <- Entries, string:trim(E) =/= ""]
  end.

%% @doc Check if a host matches any NO_PROXY entry.
%% Supports exact match, suffix match (with leading dot), and wildcard (*).
%% Returns true if proxy should be bypassed for this host.
%% Note: binary clause is for API flexibility (used in tests).
-dialyzer({nowarn_function, check_no_proxy/2}).
check_no_proxy(_Host, []) ->
  false;
check_no_proxy(Host, NoProxyList) when is_binary(Host) ->
  check_no_proxy(binary_to_list(Host), NoProxyList);
check_no_proxy(Host, NoProxyList) ->
  LowerHost = string:lowercase(Host),
  lists:any(fun(Entry) -> matches_no_proxy(LowerHost, Entry) end, NoProxyList).

%% Check if host matches a single NO_PROXY entry
matches_no_proxy(_Host, "*") ->
  %% Wildcard matches everything
  true;
matches_no_proxy(Host, Entry) ->
  LowerEntry = string:lowercase(Entry),
  case LowerEntry of
    [$. | Domain] ->
      %% Leading dot: match any subdomain
      string:find(Host, Domain, trailing) =:= Domain;
    _ ->
      %% Exact match or suffix match
      Host =:= LowerEntry orelse
        lists:suffix("." ++ LowerEntry, Host)
  end.

%% Determine proxy type based on target scheme
proxy_type_for_scheme(https) -> connect;
proxy_type_for_scheme(_) -> http.

%% HTTP method helpers
-define(METHOD_TPL(Method),
  Method(URL) ->
  hackney:request(Method, URL)).
-include("hackney_methods.hrl").

-define(METHOD_TPL(Method),
  Method(URL, Headers) ->
  hackney:request(Method, URL, Headers)).
-include("hackney_methods.hrl").

-define(METHOD_TPL(Method),
  Method(URL, Headers, Body) ->
  hackney:request(Method, URL, Headers, Body)).
-include("hackney_methods.hrl").

-define(METHOD_TPL(Method),
  Method(URL, Headers, Body, Options) ->
  hackney:request(Method, URL, Headers, Body, Options)).
-include("hackney_methods.hrl").

%% @doc Parse a proxy URL and extract host, port, and optional credentials.
%% Supports URLs like:
%% - "http://proxy.example.com:8080"
%% - "http://user:pass@proxy.example.com:8080"
%% - "https://admin:secret@secure-proxy.example.com:443"
%% - "socks5://socks.example.com:1080"
%% - "socks5://user:pass@socks.example.com:1080"
%%
%% Returns a map with keys: scheme, host, port, user, password
%% Fixes issue #741: Extract proxy basic auth from URL
-spec parse_proxy_url(binary() | string()) ->
  {ok, #{scheme := atom(),
         host := string(),
         port := inet:port_number(),
         user := binary() | undefined,
         password := binary() | undefined}} |
  {error, invalid_proxy_url}.
parse_proxy_url(Url) when is_list(Url) ->
  parse_proxy_url(list_to_binary(Url));
parse_proxy_url(Url) when is_binary(Url) ->
  try
    #hackney_url{
      scheme = Scheme,
      host = Host,
      port = Port,
      user = User,
      password = Password
    } = hackney_url:parse_url(Url),
    {ok, #{
      scheme => Scheme,
      host => Host,
      port => Port,
      user => case User of <<>> -> undefined; _ -> User end,
      password => case Password of <<>> -> undefined; _ -> Password end
    }}
  catch
    _:_ -> {error, invalid_proxy_url}
  end.
