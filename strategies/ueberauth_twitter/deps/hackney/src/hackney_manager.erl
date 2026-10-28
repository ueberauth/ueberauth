%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.


-module(hackney_manager).
-behaviour(gen_server).

-export([new_request/1,
  start_async_response/1,
  stop_async_response/1,
  cancel_request/1,
  close_request/1,
  controlling_process/2]).

-export([get_state/1, get_state/2,
  update_state/1, update_state/2,
  store_state/1, store_state/2,
  take_control/2,
  handle_error/1]).

-export([async_response_pid/1,
  with_async_response_pid/2]).

-export([start_link/0]).


%% private gen_server api
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-include("hackney.hrl").

-record(request, {ref,
  pid,
  async_pid=nil,
  state}).

-record(request_info, {pool,
  start_time,
  host}).


-define(REFS, hackney_manager_refs).

-record(mstate, {pids=dict:new(),
  metrics}).


new_request(#client{request_ref=Ref}=Client) when is_reference(Ref) ->
  {ok, StartTime} = take_control(Ref, Client),
  {Ref, Client#client{start_time=StartTime}};
new_request(Client) ->
  {Ref, StartTime} = init_request(Client),
  {Ref, Client#client{start_time=StartTime, request_ref=Ref}}.


init_request(InitialState) ->
  %% initialize the request
  Ref = make_ref(),
  %% store the current state in the process dictionary
  put(Ref, InitialState#client{request_ref=Ref}),
  %% supervise the process owner
  {ok, StartTime} = gen_server:call(?MODULE, {new_request, self(), Ref,
    InitialState}, infinity),
  {Ref, StartTime}.


cancel_request(#client{request_ref=Ref}) ->
  cancel_request(Ref);
cancel_request(Ref) when is_reference(Ref) ->
  case get_state(Ref) of
    req_not_found ->
      req_not_found;
    #client{socket=Skt}=Client when Skt /= nil ->
      #client{transport=Transport, socket=Socket, buffer=Buffer,
        response_state=RespState} = Client,

      %% only the owner can cancel the request
      case Transport:controlling_process(Socket, self()) of
        ok ->
          %% remove the request
          erase(Ref),

          %% stop to monitor the request
          ok = gen_server:cast(?MODULE, {cancel_request, Ref}),
          %% return the latest state
          {ok, {Transport, Socket, Buffer, RespState}};
        Error ->
          Error
      end;
    Client ->
      #client{transport=Transport, socket=Socket,
        buffer=Buffer, response_state=RespState} = Client,

      %% remove the request
      erase(Ref),

      %% stop to monitor the request
      ok = gen_server:cast(?MODULE, {cancel_request, Ref}),
      %% return the latest state
      {ok, {Transport, Socket, Buffer, RespState}}
  end.

close_request(#client{}=Client) ->
  #client{transport=Transport,
    socket=Socket,
    state=Status,
    request_ref=Ref} = Client,

  %% remove the request
  erase(Ref),
  catch ets:delete(?MODULE, Ref),

  %% stop to monitor the request
  ok = gen_server:cast(?MODULE, {cancel_request, Ref}),

  case Status of
    done when Socket /= nil ->
      %% Connection completed successfully, return to pool if using one
      case Client#client.socket_ref of
        nil ->
          %% Not using pool, close the socket
          catch Transport:close(Socket);
        SocketRef ->
          %% Return to pool
          Handler = Client#client.pool_handler,
          catch Handler:checkin(SocketRef, Socket)
      end,
      ok;
    _ when Socket /= nil ->
        catch Transport:controlling_process(Socket, self()),
        catch Transport:close(Socket),
      ok;
    _ -> ok
  end;
close_request(Ref) ->
  case get_state(Ref) of
    req_not_found ->
      req_not_found;
    Client ->
      close_request(Client)
  end.


controlling_process(Ref, Pid) ->
  case get(Ref) of
    undefined ->
      {error, not_owner};
    Client ->
      Reply = gen_server:call(?MODULE, {controlling_process, Ref, Pid}),
      case Reply of
        ok ->
          #client{transport=Transport, socket=Socket} = Client,
          Transport:controlling_process(Socket, Pid),
          ets:insert(?MODULE, {Ref, #request{ref=Ref, state=Client}}),
          ok;
        Error ->
          Error
      end
  end.

start_async_response(Ref) ->
  case get_state(Ref)of
    req_not_found ->
      req_not_found;
    Client ->
      #client{transport=Transport, socket=Socket,
        stream_to=StreamTo} = Client,
      case gen_server:call(?MODULE, {start_async_response, Ref,
        StreamTo, Client}) of
        {ok, Pid} ->
          %% store temporarily the socket in the the ets so it can
          %% be used by the other process later
          true = ets:insert(?MODULE, {Ref, #request{ref=Ref,
            state=Client}}),
          %% delete the current state from the process dictionary
          %% since it's not the owner
          erase(Ref),

          %% transfer the control of the socket
          case Transport:controlling_process(Socket, Pid) of
            ok -> Pid ! controlling_process_done, ok;
            Else -> Else
          end;
        Error ->
          Error
      end
  end.

stop_async_response(Ref) ->
  gen_server:call(?MODULE, {stop_async_response, Ref, self()}, 30000).

async_response_pid(Ref) ->
  case ets:lookup(?REFS, Ref) of
    [] ->
      {error, req_not_found};
    [{Ref, {_, nil, _}}] ->
      {error, req_not_async};
    [{Ref, {_, Pid, _}}] ->
      {ok, Pid}
  end.

with_async_response_pid(Ref, Fun) ->
  case async_response_pid(Ref) of
    {ok, Pid} ->
      Fun(Pid);
    Error ->
      Error
  end.

get_state(#client{request_ref=Ref}) ->
  get_state(Ref);

get_state(Ref) ->
  case get(Ref) of
    undefined ->
      case ets:lookup(?MODULE, Ref) of
        [] ->
          req_not_found;
        [{Ref, #request{state=State}}] ->
          %% store the state in the new context, only the current
          %% owner can handle it.
          put(Ref, State),
          %% delete the state, from ets
          catch ets:delete(?MODULE, Ref),
          State
      end;
    State ->
      State
  end.

get_state(Ref, Fun) ->
  case get_state(Ref) of
    req_not_found -> {error, req_not_found};
    State -> Fun(State)
  end.

update_state(#client{request_ref=Ref}=NState) ->
  update_state(Ref, NState).

update_state(Ref, NState) ->
  put(Ref, NState).

store_state(#client{request_ref=Ref}=NState) ->
  store_state(Ref, NState).

store_state(Ref, NState) ->
  true = ets:insert(?MODULE, {Ref, #request{ref=Ref, state=NState}}),
  ok.

take_control(Ref, NState) ->
  %% maybe delete the state from ets
  catch ets:delete(?MODULE, Ref),
  %% add the state to the current context
  put(Ref, NState),
  gen_server:call(?MODULE, {take_control, Ref, NState}, 30000).

handle_error(#client{request_ref=Ref, dynamic=true}) ->
  close_request(Ref);

handle_error(#client{request_ref=Ref, transport=Transport,
  socket=Socket}=Client) ->

  case get_state(Ref) of
    req_not_found -> ok;
    _ ->
        catch Transport:controlling_process(Socket, self()),
        catch Transport:close(Socket),
      NClient = Client#client{socket=nil, state=closed},
      update_state(NClient),
      ok
  end.


start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_) ->
  _ = ets:new(hackney_pool, [named_table,
                             set,
                             public]),

  _ = ets:new(?MODULE, [set,
                        {keypos, 1},
                        public,
                        named_table,
                        {read_concurrency, true},
                        {write_concurrency, true}]),

  _ = ets:new(?REFS, [named_table, set, protected]),

  %% initialize metrics
  Metrics = init_metrics(),

  process_flag(trap_exit, true),
  %% return {ok, {Pids, Refs}}
  %% Pids are the managed pids
  %% Refs are the managed requests
  {ok, #mstate{pids=dict:new(),
    metrics=Metrics}}.


handle_call({new_request, Pid, Ref, Client}, _From, #mstate{pids=Pids}=State) ->
  %% get pool name
  Pool = proplists:get_value(pool, Client#client.options, default),
  %% set requInfo
  StartTime = os:timestamp(),
  ReqInfo = #request_info{pool=Pool,
                          start_time=StartTime,
                          host=Client#client.host},
  %% start the request
  _ = start_request(ReqInfo, State),
  %% track the request owner
  Pids2 = track_owner(Pid, Ref, Pids),
  ets:insert(?REFS, {Ref, {Pid, nil, ReqInfo}}),
  {reply, {ok, StartTime}, State#mstate{pids=Pids2}};

handle_call({take_control, Ref, Client}, _From, State) ->
  StartTime = os:timestamp(),

  case ets:lookup(?REFS, Ref) of
    [] ->
      %% not supposed to happen but ignore it.
      {reply, {ok, StartTime}, State};
    [{Ref, {Owner, Stream, Info}}] ->
      NInfo = Info#request_info{start_time=StartTime,
                                host=Client#client.host},
      %% start the request
      _ = start_request(NInfo, State),
      ets:insert(?REFS, {Ref, {Owner, Stream, NInfo}}),
      {reply, {ok, StartTime}, State}
  end;

handle_call({start_async_response, Ref, StreamTo, Client}, _From, State) ->
  %% start the stream and eventually update the owner of the request
  case do_start_async_response(Ref, StreamTo, Client, State) of
    {ok, Pid, NState} ->
      {reply, {ok, Pid}, NState};
    Error ->
      {reply, Error, State}
  end;

handle_call({stop_async_response, Ref, To}, _From, State) ->
  case ets:lookup(?REFS, Ref) of
    [] -> {reply, {ok, Ref}, State};
    [{Ref, {_Owner, nil, _Info}}] ->
      %% there is no async request to handle, just return
      {reply, {ok, Ref}, State};
    [{Ref, {Owner, Stream, Info}}] ->
      %% Monitor the stream process to avoid race conditions
      MonitorRef = erlang:monitor(process, Stream),
      %% tell to the stream to stop
      Stream ! {Ref, stop_async, self()},
      receive
        {Ref, ok} ->
          %% Clean shutdown received
          erlang:demonitor(MonitorRef, [flush]),
          unlink(Stream),
          ets:insert(?REFS, {Ref, {To, nil, Info}}),
          Pids1 = dict:erase(Stream, State#mstate.pids),
          %% if the owner change we need to track the request for this new pid
          Pids2 = case To of
                    Owner -> Pids1;
                    _ ->
                      track_owner(To, Ref, untrack_owner(Owner, Ref, Pids1))
                  end,
          {reply, {ok, Ref}, State#mstate{pids=Pids2}};
        {'DOWN', MonitorRef, process, Stream, _Reason} ->
          %% Stream died before responding, clean up and continue
          ets:insert(?REFS, {Ref, {To, nil, Info}}),
          Pids1 = dict:erase(Stream, State#mstate.pids),
          Pids2 = case To of
                    Owner -> Pids1;
                    _ ->
                      track_owner(To, Ref, untrack_owner(Owner, Ref, Pids1))
                  end,
          {reply, {ok, Ref}, State#mstate{pids=Pids2}}
      after 5000 ->
        %% Timeout - force cleanup
        erlang:demonitor(MonitorRef, [flush]),
        catch unlink(Stream),
        ets:insert(?REFS, {Ref, {To, nil, Info}}),
        Pids1 = dict:erase(Stream, State#mstate.pids),
        Pids2 = case To of
                  Owner -> Pids1;
                  _ ->
                    track_owner(To, Ref, untrack_owner(Owner, Ref, Pids1))
                end,
        {reply, {error, timeout}, State#mstate{pids=Pids2}}
      end
  end;

handle_call({controlling_process, Ref, Pid}, _From, State) ->
  case ets:lookup(?REFS, Ref) of
    [] -> {reply, badarg, State};
    [{Ref, {Pid, _, _}}] ->
      %% the request is already controlled by this process just return
      {reply, ok, State};
    [{Ref, {Owner, Stream, Info}}] ->
      %% new owner, track it
      Pids2 = track_owner(Pid, Ref, untrack_owner(Owner, Ref, State#mstate.pids)),
      ets:insert(?REFS, {Ref, {Pid, Stream, Info}}),
      {reply, ok, State#mstate{pids=Pids2}}
  end.

handle_cast({cancel_request, Ref}, State) ->
  PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
  case ets:lookup(?REFS, Ref) of
    [] ->
      {noreply, State};
    [{Ref, {Owner, nil, #request_info{pool=Pool}=Info}}] ->
      %% no stream just cancel the request and untrack the owner.
      Pids2 = untrack_owner(Owner, Ref, State#mstate.pids),
      catch ets:delete(?REFS, Ref),
      %% notify the pool that the request have been canceled
      PoolHandler:notify(Pool, {'DOWN', Ref, request, Owner, cancel}),
      %% update metrics
      ok = finish_request(Info, State),
      {noreply, State#mstate{pids=Pids2}};
    [{Ref, {Owner, Stream, #request_info{pool=Pool}=Info}}] when is_pid(Stream) ->
      %% unlink the stream and untrack the owner
      unlink(Stream),
      Pids2 = dict:erase(Stream, untrack_owner(Owner, Ref, State#mstate.pids)),
      catch ets:delete(?REFS, Ref),
      %% notify the pool that the request have been canceled
      _ = PoolHandler:notify(Pool, {'DOWN', Ref, request, Owner, cancel}),
      %% update metrics
      ok = finish_request(Info, State),
      %% terminate the async response
      _ = terminate_async_response(Stream),
      {noreply, State#mstate{pids=Pids2}}
  end;

handle_cast(_Msg, Children) ->
  {noreply, Children}.

handle_info({'EXIT', Pid, Reason}, State) ->
  case dict:find(Pid, State#mstate.pids) of
    {ok, {stream, Ref}} ->
      handle_stream_exit(Pid, Ref, Reason, State);
    {ok, Refs} when is_list(Refs) ->
      handle_owner_exit(Pid, Refs, Reason, State);
    _Else ->
      {noreply, State}
  end;

handle_info(_Info, State) ->
  {noreply, State}.


code_change(_OldVsn, Ring, _Extra) ->
  {ok, Ring}.

terminate(_Reason, _State) ->
  ok.

do_start_async_response(Ref, StreamTo, Client, State) ->
  %% get current owner
  [{Ref, {Owner, _, Info}}] = ets:lookup(?REFS, Ref),

  %% if not stream target we use the owner
  StreamTo2 = case StreamTo of
                false -> Owner;
                _ -> StreamTo
              end,

  %% start the stream process
  case catch hackney_stream:start_link(StreamTo2, Ref, Client) of
    {ok, Pid} when is_pid(Pid) ->
      ets:insert(?REFS, {Ref, {Owner, Pid, Info}}),
      Pids2 = dict:store(Pid, {stream, Ref}, State#mstate.pids),
      {ok, Pid, State#mstate{pids=Pids2}};
    {error, What} ->
      {error, What};
    What ->
      {error, What}
  end.

%% cleanup socket
cleanup_socket(Ref) ->
   case ets:lookup(?MODULE, Ref) of
      [{Ref, #request{ref=Ref,
                      state=#client{transport=Transport,
                                    socket=Socket}}}] ->
         catch Transport:close(Socket),
         ok;
      [] ->
         ok
   end.

%% a stream exited
handle_stream_exit(Pid, Ref, Reason, State) ->
  %% delete the pid from our list
  Pids1 = dict:erase(Pid, State#mstate.pids),
  case ets:lookup(?REFS, Ref) of
    [] ->
      %% ref already removed just return
      {noreply, State#mstate{pids=Pids1}};
    [{Ref, {Owner, Pid, #request_info{pool=Pool}=Info}}] ->
      %% untrack the owner
      Pids2 = untrack_owner(Owner, Ref, Pids1),
      %% if abnormal reason let the owner knows
      _ = case Reason of
            normal ->  ok;
            {owner_down, Owner, _} -> ok; %% we were streaming to
            _ -> Owner ! {'DOWN', Ref, Reason}
          end,
      %% cleanup socket
      ok = cleanup_socket(Ref),
      %% remove the reference
      _ = ets:delete(?REFS, Ref),
      _ = ets:delete(?MODULE, Ref),
      %% notify the pool that the request have been canceled
      PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
      PoolHandler:notify(Pool, {'DOWN', Ref, request, Owner, Reason}),
      %% update metrics
      ok = finish_request(Info, State),
      %% reply
      {noreply, State#mstate{pids=Pids2}}
  end.


%% owner exited
handle_owner_exit(Pid, Refs, Reason, State) ->
  PoolHandler = hackney_app:get_app_env(pool_handler, hackney_pool),
  %% delete the pid from our list
  Pids1 = dict:erase(Pid, State#mstate.pids),
  NewState = clean_requests(Refs, Pid, Reason, PoolHandler, State#mstate{pids=Pids1}),
  {noreply, NewState}.

clean_requests([Ref | Rest], Pid, Reason, PoolHandler, State) ->
  case ets:lookup(?REFS, Ref) of
    [] ->
      %% ref already removed just return
      clean_requests(Rest, Pid, Reason, PoolHandler, State);
    [{Ref, {Pid, nil, #request_info{pool=Pool}=Info}}] ->
      %% no stream
      %% cleanup socket
      ok = cleanup_socket(Ref),
      %% remove the reference
      catch ets:delete(?REFS, Ref),
      catch ets:delete(?MODULE, Ref),
      %% notify the pool that the request have been canceled
      PoolHandler:notify(Pool, {'DOWN', Ref, request, Pid, Reason}),
      %% update metrics
      ok = finish_request(Info, State),
      %% continue
      clean_requests(Rest, Pid, Reason, PoolHandler, State);
    [{Ref, {Pid, Stream, #request_info{pool=Pool}=Info}}] ->
      %% erase the stream
      Pids2 = dict:erase(Stream, State#mstate.pids),
      %% terminate the async stream
      ok = terminate_async_response(Stream),
      %% cleanup socket
      ok = cleanup_socket(Ref),
      %% remove the reference
      catch ets:delete(?REFS, Ref),
      catch ets:delete(?MODULE, Ref),
      %% notify the pool that the request have been canceled
      PoolHandler:notify(Pool, {'DOWN', Ref, request, Pid, Reason}),
      %% update metrics
      ok = finish_request(Info, State),
      %% continue
      clean_requests(Rest, Pid, Reason, PoolHandler, State#mstate{pids=Pids2})
  end;
clean_requests([], _Pid, _Reason, _PoolHandler, State) ->
  State.

terminate_async_response(StreamPid) ->
  terminate_async_response(StreamPid, shutdown).

terminate_async_response(StreamPid, Reason) ->
  MonitorRef = erlang:monitor(process, StreamPid),
  unlink(StreamPid),
  exit(StreamPid, Reason),
  receive
    {'DOWN', MonitorRef, process, StreamPid, _} ->
      erlang:demonitor(MonitorRef, [flush]),
      ok
  after 5000 ->
      %% Force kill if not terminated
      exit(StreamPid, kill),
      receive
        {'DOWN', MonitorRef, process, StreamPid, _} ->
          erlang:demonitor(MonitorRef, [flush]),
          ok
      after 1000 ->
          %% Process should be dead now, clean up monitor
          erlang:demonitor(MonitorRef, [flush]),
          ok  %% Give up if still not dead
      end
  end.


track_owner(Pid, Ref, Pids) ->
  case dict:is_key(Pid, Pids) of
    true ->
      dict:append(Pid, Ref, Pids);
    false ->
      link(Pid),
      dict:append(Pid, Ref, Pids)
  end.


untrack_owner(Pid, Ref, Pids) ->
  case dict:find(Pid, Pids) of
    {ok, Refs} ->
      case lists:delete(Ref, Refs) of
        [] ->
          unlink(Pid),
          dict:erase(Pid, Pids);
        Refs2 ->
          dict:store(Pid, Refs2, Pids)
      end;
    error ->
      catch unlink(Pid),
      Pids
  end.


init_metrics() ->
  %% get metrics module
  Engine = hackney_metrics:get_engine(),
  %% initialise metrics
  _ = metrics:new(Engine, counter, [hackney, nb_requests]),
  _ = metrics:new(Engine, counter, [hackney, total_requests]),
  _ = metrics:new(Engine, counter, [hackney, finished_requests]),
  Engine.

start_request(#request_info{host=Host}, #mstate{metrics=Engine}) ->
  _ = metrics:increment_counter(Engine, [hackney, Host, nb_requests]),
  _ =  metrics:increment_counter(Engine, [hackney, nb_requests]),
  _ = metrics:increment_counter(Engine, [hackney, total_requests]),
  ok.


finish_request(#request_info{start_time=Begin, host=Host},
               #mstate{metrics=Engine}) ->
  RequestTime = timer:now_diff(os:timestamp(), Begin)/1000,
  _ = metrics:update_histogram(Engine, [hackney, Host, request_time], RequestTime),
  _ = metrics:decrement_counter(Engine, [hackney, Host, nb_requests]),
  _ = metrics:decrement_counter(Engine, [hackney, nb_requests]),
  _ = metrics:increment_counter(Engine, [hackney, finished_requests]),
  ok.
