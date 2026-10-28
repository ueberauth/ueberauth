%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2009, Erlang Training and Consulting Ltd.
%%% Copyright (c) 2012-2021, Benoît Chesneau <benoitc@e-engura.org>

%% @doc pool of sockets connections
%%
-module(hackney_pool).
-behaviour(gen_server).

%% PUBLIC API
-export([start/0,
         checkout/4,
         checkin/2]).

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
         child_spec/2]).

-export([start_link/2]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-include("hackney.hrl").
-include_lib("hackney_internal.hrl").

-record(state, {name,
                metrics,
                max_connections,
                timeout,
                clients = dict:new(),
                queues = dict:new(),      % Dest => queue of {From, Ref, Requester}
                pending = dict:new(),     % Ref  => {From, Dest, Requester}
                connections = dict:new(),
                sockets = dict:new()}).


start() ->
  %% NB this is first called from hackney_sup:start_link
  %%    BEFORE the hackney_pool ETS table exists
  ok.

%% @doc fetch a socket from the pool
checkout(Host, Port, Transport, Client) ->
  Requester = self(),
  try
    do_checkout(Requester, Host, Port, Transport, Client)
  catch _:Error ->
    ?report_trace("pool: checkout failure", [{error, Error}]),
    {error, checkout_failure}
  end.

do_checkout(Requester, Host, _Port, Transport, #client{options=Opts,
                                                       mod_metrics=Metrics}=Client) ->
  ConnectTimeout = proplists:get_value(connect_timeout, Opts, 8000),
  %% Fall back to using connect_timeout if checkout_timeout is not set
  CheckoutTimeout = proplists:get_value(checkout_timeout, Opts, ConnectTimeout),
  {Connection, ConnectOptions} = hackney_connection:new(Client),
  RequestRef = Client#client.request_ref,
  PoolName = proplists:get_value(pool, Opts, default),
  Pool = find_pool(PoolName, Opts),
  case catch gen_server:call(Pool, {checkout, Connection, Requester, RequestRef}, CheckoutTimeout) of
    {ok, Socket, Owner} ->
      %% stats
      ?report_debug("reuse a connection", [{pool, PoolName}]),
      _ = metrics:update_meter(Metrics, [hackney_pool, PoolName, take_rate], 1),
      _ = metrics:increment_counter(Metrics, [hackney_pool, Host, reuse_connection]),
      {ok, {PoolName, RequestRef, Connection, Owner, Transport}, Socket};
    {error, no_socket, Owner} ->
      ?report_trace("no socket in the pool", [{pool, PoolName}]),
      Begin = os:timestamp(),
      case hackney_connection:connect(Connection, ConnectOptions, ConnectTimeout) of
        {ok, Socket} ->
          case hackney_connection:controlling_process(Connection, Socket, Requester) of
            ok ->
              ?report_trace("new connection", []),
              ConnectTime = timer:now_diff(os:timestamp(), Begin)/1000,
              _ = metrics:update_histogram(Metrics, [hackney, Host, connect_time], ConnectTime),
              _ = metrics:increment_counter(Metrics, [hackney_pool, Host, new_connection]),
              {ok, {PoolName, RequestRef, Connection, Owner, Transport}, Socket};
            Error ->
              %% Ensure socket is properly closed on controlling_process error
              _ = catch hackney_connection:close(Connection, Socket),
              _ = metrics:increment_counter(Metrics, [hackney, Host, connect_error]),
              Error
           end;
        {error, timeout} ->
          _ = metrics:increment_counter(Metrics, [hackney, Host, connect_timeout]),
          {error, timeout};
        Error ->
          ?report_trace("connect error", [{pool, PoolName}, {error, Error}]),
          _ = metrics:increment_counter(Metrics, [hackney, Host, connect_error]),
          Error
      end;
    {error, Reason} ->
      {error, Reason};
    {'EXIT', {timeout, _}} ->
      %% checkout should be canceled by the caller via hackney_manager
      {error, checkout_timeout}
  end.

%% @doc release a socket in the pool
checkin({_Name, Ref, Connection, Owner, Transport}, Socket) ->
  hackney_connection:setopts(Connection, Socket, [{active, false}]),
  case hackney_connection:sync_socket(Connection, Socket) of
    true ->
      case hackney_connection:controlling_process(Connection, Socket, Owner) of
        ok ->
          gen_server:call(Owner, {checkin, Ref, Connection, Socket, Transport}, infinity);
        _Error ->
          %% Ensure socket is properly closed on controlling_process error
          _ = catch hackney_connection:close(Connection, Socket),
          ok
      end;
    false ->
      catch hackney_connection:close(Connection, Socket),
      ok
  end.

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
          _= supervisor:delete_child(hackney_sup, Name),
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



%%
%%  util functions for this pool
%%

%% @doc return a child spec suitable for embeding your pool in the
%% supervisor
child_spec(Name, Options0) ->
  Options = [{name, Name} | Options0],
  {Name, {hackney_pool, start_link, [Name, Options]},
   permanent, 10000, worker, [hackney_pool]}.


%% @doc get the number of connections in the pool
count(Name) ->
  gen_server:call(find_pool(Name), count).

%% @doc get the number of connections in the pool for `{Host0, Port, Transport}'
count(Name, {Host0, Port, Transport}) ->
  Host = string:to_lower(Host0),
  gen_server:call(find_pool(Name), {count, {Host, Port, Transport}}).

%% @doc get max pool size
max_connections(Name) ->
  gen_server:call(find_pool(Name), max_connections).

%% @doc change the pool size
set_max_connections(Name, NewSize) ->
  gen_server:cast(find_pool(Name), {set_maxconn, NewSize}).

%% @doc get timeout
timeout(Name) ->
  gen_server:call(find_pool(Name), timeout).

%% @doc change the connection timeout
%%
set_timeout(Name, NewTimeout) ->
  gen_server:cast(find_pool(Name), {set_timeout, NewTimeout}).

%% @private
%%
%%
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

init([Name, Options]) ->
  MaxConn = case proplists:get_value(pool_size, Options) of
              undefined ->
                proplists:get_value(max_connections, Options);
              Size ->
                Size
            end,
  Timeout = proplists:get_value(timeout, Options),

  %% register the module
  ets:insert(?MODULE, {Name, self()}),

  %% initialize metrics
  Engine = init_metrics(Name),

  {ok, #state{name=Name, metrics=Engine, max_connections=MaxConn,
              timeout=Timeout}}.

handle_call(stats, _From, State) ->
  {reply, handle_stats(State), State};
handle_call(count, _From, #state{sockets=Sockets}=State) ->
  {reply, dict:size(Sockets), State};
handle_call(timeout, _From, #state{timeout=Timeout}=State) ->
  {reply, Timeout, State};
handle_call(max_connections, _From, #state{max_connections=MaxConn}=State) ->
  {reply, MaxConn, State};
handle_call({checkout, Dest, Requester, RequestRef}, From, State) ->
  #state{name=PoolName,
         metrics = Engine,
         max_connections=MaxConn,
         clients=Clients,
         queues = Queues,
         pending = Pending} = State,

  {Reply, State2} = find_connection(Dest, Requester, State),
  case Reply of
    {ok, _Socket, _Owner} ->
      State3 = monitor_client(Dest, RequestRef, State2),
      ok = update_usage(State3),
      {reply, Reply, State3};
    no_socket ->
      case dict:size(Clients) >= MaxConn of
        true ->
          Queues2 = add_to_queue(Dest, From, RequestRef, Requester, Queues),
          Pending2 = add_pending(RequestRef, From, Dest, Requester, Pending),
          _ = metrics:update_histogram(
                Engine, [hackney_pool, PoolName, queue_count], dict:size(Pending2)
               ),
          {noreply, State2#state{queues = Queues2, pending = Pending2}};
        false ->
          State3 = monitor_client(Dest, RequestRef, State2),
          ok = update_usage(State3),
          {reply, {error, no_socket, self()}, State3}
      end
  end;
handle_call({checkin, Ref, Dest, Socket, Transport}, From, State) ->
  reply_if_alive(From, ok),
  Clients2 = case dict:find(Ref, State#state.clients) of
               {ok, Dest} ->
                 dict:erase(Ref, State#state.clients);
               error ->
                 State#state.clients
             end,
  State2 = case Transport:peername(Socket) of
             {ok, {_Adress, _Port}} ->
               %% socket is not closed, try to deliver it or store it
               deliver_socket(Socket, Dest, State#state{clients=Clients2});
             Error ->
               %% socket may be half-closed, close it and return
               catch Transport:close(Socket),
               ?report_trace("checkin: socket is not ok~n", [{socket, Socket}, {peername, Error}]),
               State#state{clients=Clients2}
           end,
  ok = update_usage(State2),
  {noreply, State2};

handle_call({count, Key}, _From, #state{connections=Conns}=State) ->
  Size = case dict:find(Key, Conns) of
           {ok, Sockets} ->
             length(Sockets);
           error ->
             0
         end,
  {reply, Size, State}.

handle_cast({set_maxconn, MaxConn}, State) ->
  {noreply, State#state{max_connections=MaxConn}};
handle_cast({set_timeout, NewTimeout}, State) ->
  {noreply, State#state{timeout=NewTimeout}};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({timeout, Socket}, State) ->
  {noreply, remove_socket(Socket, State)};
handle_info({tcp, Socket, _}, State) ->
  {noreply, remove_socket(Socket, State)};
handle_info({tcp_closed, Socket}, State) ->
  {noreply, remove_socket(Socket, State)};
handle_info({ssl, Socket, _}, State) ->
  {noreply, remove_socket(Socket, State)};
handle_info({ssl_closed, Socket}, State) ->
  {noreply, remove_socket(Socket, State)};
handle_info({tcp_error, Socket, _}, State) ->
  {noreply, remove_socket(Socket, State)};
handle_info({ssl_error, Socket, _}, State) ->
  {noreply, remove_socket(Socket, State)};
handle_info({'DOWN', Ref, request, _Pid, _Reason}, State) ->
  case dict:find(Ref, State#state.clients) of
    {ok, Dest} ->
      {noreply, dequeue(Dest, Ref, State)};
    error ->
      NewState = remove_pending(Ref, State),
      {noreply, NewState}
  end;
handle_info(_, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

terminate(_Reason, #state{name=PoolName, metrics=Engine, sockets=Sockets}) ->
  %% close any sockets in the pool
  lists:foreach(fun({Socket, {{_, _, Transport}, Timer}}) ->
                    cancel_timer(Socket, Timer),
                    Transport:close(Socket)
                end, dict:to_list(Sockets)),

  %% delete pool metrics
  ok = delete_metrics(Engine, PoolName),
  ok.

%% internals

dequeue(Dest, Ref, State) ->
  #state{clients=Clients, queues=Queues, pending=Pending} = State,
  Clients2 = dict:erase(Ref, Clients),
  case queue_out(Dest, Queues) of
    empty ->
      State#state{clients = Clients2};
    {ok, {From, Ref2, _Requester}, Queues2} ->
      Pending2 = del_pending(Ref2, Pending),
      _ = metrics:update_histogram(
            State#state.metrics, [hackney_pool, State#state.name, queue_count], dict:size(Pending2)
           ),
      reply_if_alive(From, {error, no_socket, self()}),
      State2 = State#state{queues = Queues2, clients = Clients2, pending=Pending2},
      monitor_client(Dest, Ref2, State2)
  end.

find_connection(Connection, Pid, #state{connections=Conns, sockets=Sockets}=State) ->
  case dict:find(Connection, Conns) of
    {ok, [S | Rest]} ->
      hackney_connection:setopts(Connection, S, [{active, false}]),
      case hackney_connection:sync_socket(Connection, S) of
        true ->
          case hackney_connection:controlling_process(Connection, S, Pid) of
            ok ->
              {_, Timer} = dict:fetch(S, Sockets),
              cancel_timer(S, Timer),
              NewConns = update_connections(Rest, Connection, Conns),
              NewSockets = dict:erase(S, Sockets),
              NewState = State#state{connections=NewConns, sockets=NewSockets},
              {{ok, S, self()}, NewState};
            {error, badarg} ->
              %% something happened here normally the PID died,
              %% but make sure we still have the control of the
              %% process
              case catch hackney_connection:controlling_process(Connection, S, self()) of
                ok ->
                  %% Successfully regained control, now remove the socket
                  find_connection(Connection, Pid, remove_socket(S, State));
                _ ->
                  %% Failed to regain control, force close and remove
                  _ = catch hackney_connection:close(Connection, S),
                  find_connection(Connection, Pid, remove_socket(S, State))
              end;
            _Else ->
              find_connection(Connection, Pid, remove_socket(S, State))
          end;
        false ->
          ?report_trace("checkout: socket unsynced~n", []),
          find_connection(Connection, Pid, remove_socket(S, State))
      end;
    _Else ->
      {no_socket, State}
  end.

remove_socket(Socket, #state{connections=Conns, sockets=Sockets}=State) ->
  _ = metrics:update_histogram(State#state.metrics,
                               [hackney, State#state.name, free_count],
                               dict:size(Sockets)),
  case dict:find(Socket, Sockets) of
    {ok, {Connection, Timer}} ->
      cancel_timer(Socket, Timer),
      catch hackney_connection:close(Connection, Socket),
      ConnSockets = lists:delete(Socket, dict:fetch(Connection, Conns)),
      NewConns = update_connections(ConnSockets, Connection, Conns),
      NewSockets = dict:erase(Socket, Sockets),
      State#state{connections=NewConns, sockets=NewSockets};
    error ->
      State
  end.


store_socket(Connection, Socket, #state{timeout=Timeout, connections=Conns,
                                        sockets=Sockets}=State) ->
  Timer = erlang:send_after(Timeout, self(), {timeout, Socket}),
  %% make sure to close the socket if anything is received while we are in
  %% the pool.
  hackney_connection:setopts(Connection, Socket, [{active, once}, {packet, 0}]),
  ConnSockets = case dict:find(Connection, Conns) of
                  {ok, OldSockets} ->
                    [Socket | OldSockets];
                  error -> [Socket]
                end,
  State#state{connections = dict:store(Connection, ConnSockets, Conns),
              sockets = dict:store(Socket, {Connection, Timer}, Sockets)}.

update_connections([], Key, Connections) ->
  dict:erase(Key, Connections);
update_connections(Sockets, Key, Connections) ->
  dict:store(Key, Sockets, Connections).

cancel_timer(Socket, Timer) ->
  case erlang:cancel_timer(Timer) of
    false ->
      %% Timer already fired, must drain the timeout message
      receive
        {timeout, Socket} -> ok
      after
        100 -> 
          %% Safety timeout - if message doesn't arrive, continue anyway
          ok
      end;
    _ -> 
      %% Timer was successfully cancelled, no message should exist
      %% Don't drain messages to avoid consuming legitimate timeout messages
      ok
  end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
add_to_queue(Connection, From, Ref, Requester, Queues) ->
  case dict:find(Connection, Queues) of
    error ->
      dict:store(Connection, queue:in({From, Ref, Requester}, queue:new()), Queues);
    {ok, Q} ->
      dict:store(Connection, queue:in({From, Ref, Requester}, Q), Queues)
  end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
queue_out(Connection, Queues) ->
  case dict:find(Connection, Queues) of
    error ->
      empty;
    {ok, Q} ->
      case queue:out(Q) of
        {{value, {From, Ref, Requester}}, Q2} ->
          Queues2 = case queue:is_empty(Q2) of
                      true ->
                        dict:erase(Connection, Queues);
                      false ->
                        dict:store(Connection, Q2, Queues)
                    end,
          {ok, {From, Ref, Requester}, Queues2};
        {empty, _} ->
          %% fix race condition
          empty
      end
  end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
deliver_socket(Socket, Connection, State) ->
  #state{queues = Queues, pending=Pending} = State,
  case queue_out(Connection, Queues) of
    empty ->
      store_socket(Connection, Socket, State);
    {ok, {FromWaiter, Ref, PidWaiter}, Queues2} ->
      Pending2 = del_pending(Ref, Pending),
      _ = metrics:update_histogram(
            State#state.metrics, [hackney_pool, State#state.name, queue_count], dict:size(Pending2)
           ),
      case hackney_connection:controlling_process(Connection, Socket, PidWaiter) of
        ok ->
          reply_if_alive(FromWaiter, {ok, Socket, self()}),
          monitor_client(Connection, Ref, State#state{queues = Queues2, pending=Pending2});
        _Error ->
          % Something wrong, close the socket
          _ = (catch hackney_connection:close(Connection, Socket)),
          %% and let the waiter connect to a new one
          reply_if_alive(FromWaiter, {error, no_socket, self()}),
          State#state{queues = Queues2, pending = Pending2}
      end
  end.

add_pending(Ref, From, Connection, Requester, Pending) ->
  dict:store(Ref, {From, Connection, Requester}, Pending).


del_pending(Ref, Pending) ->
  dict:erase(Ref, Pending).


remove_pending(Ref, #state{queues=Queues0, pending=Pending0} = State) ->
  case dict:find(Ref, Pending0) of
    {ok, {From, Connection, Requester}} ->
      Pending1 = dict:erase(Ref, Pending0),
      Queues1 = case dict:find(Connection, Queues0) of
                  {ok, Q0} ->
                    Q1 = queue:filter(
                           fun
                             (PendingReq) when PendingReq =:= {From, Ref, Requester} -> false;
                        (_) -> true
                           end,
                           Q0
                          ),
                    dict:store(Connection, Q1, Queues0);
                  error ->
                    Queues0
                end,
      State#state{queues=Queues1, pending=Pending1};
    error ->
      State
  end.



%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
monitor_client(Connection, Ref, State) ->
  Clients2 = dict:store(Ref, Connection, State#state.clients),
  State#state{clients = Clients2}.


init_metrics(PoolName) ->
  %% get metrics module
  Engine = hackney_metrics:get_engine(),

  %% initialise metrics
  _ = metrics:new(Engine, histogram, [hackney_pool, PoolName, take_rate]),
  _ = metrics:new(Engine, counter, [hackney_pool, PoolName, no_socket]),
  _ = metrics:new(Engine, histogram, [hackney_pool, PoolName, in_use_count]),
  _ = metrics:new(Engine, histogram, [hackney_pool, PoolName, free_count]),
  _ = metrics:new(Engine, histogram, [hackney_pool, PoolName, queue_count]),
  Engine.

delete_metrics(Engine, PoolName) ->
  _ = metrics:delete(Engine, [hackney_pool, PoolName, take_rate]),
  _ = metrics:delete(Engine, [hackney_pool, PoolName, no_socket]),
  _ = metrics:delete(Engine, [hackney_pool, PoolName, in_use_count]),
  _ = metrics:delete(Engine, [hackney_pool, PoolName, free_count]),
  _ = metrics:delete(Engine, [hackney_pool, PoolName, queue_count]),
  ok.


update_usage(
  #state{name=PoolName, metrics=Engine, sockets=Sockets, clients=Clients}
 ) ->
  _ = metrics:update_histogram(Engine, [hackney_pool, PoolName,in_use_count],
                               dict:size(Clients) - 1),
  _ = metrics:update_histogram(Engine, [hackney_pool, PoolName, free_count],
                               dict:size(Sockets) - 1),
  ok.


handle_stats(State) ->
  #state{name=PoolName, max_connections=Max, sockets=Sockets, clients=Clients, pending=Pending} = State,
  [{name, PoolName},
   {max, Max},
   {in_use_count,  dict:size(Clients)},
   {free_count, dict:size(Sockets)},
   {queue_count, dict:size(Pending)}].

reply_if_alive({Pid, _Tag}=To, Msg) ->
  case is_process_alive(Pid) of
    true ->
      gen_server:reply(To, Msg);
    false ->
      ok
  end.
