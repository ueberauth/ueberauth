%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information

-module(hackney_connections).
-behaviour(gen_server).

%% API
-export([
  insert/2,
  lookup/1,
  delete/1,
  get_num_entries/0
]).


-export([start_link/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).


-include("hackney.hrl").

-define(SERVER, ?MODULE).

-record(state, {tab,lru}).
-define(MAX_ITEMS, 1000).


insert(Key, Id) ->
  gen_server:call(?SERVER, {insert, Key, Id}).

lookup(Key) ->
  gen_server:call(?SERVER, {lookup, Key}).

delete(Key) ->
  gen_server:call(?SERVER, {delete, Key}).

get_num_entries() ->
  gen_server:call(?SERVER, num_entries).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


init([]) ->
  Tab = ets:new(?SERVER, [set, {read_concurrency, true}]),
  {ok, #state{tab=Tab, lru=new_lrulist()}}.



handle_call({insert, Key, Id}, From, #state{tab=Tab, lru=Lru} = State) ->
  true = ets:insert(Tab, {Key, Id}),
  gen_server:reply(From, true),
  Lru2 = push(Key, Lru),
  NewState = case has_exceeded(State) of
               true ->
                 evict(State#state{lru=Lru2});
               false ->
                 State#state{lru=Lru2 }
             end,
  {noreply, NewState};


handle_call({lookup, Key}, From, State = #state{tab=Tab, lru=Lru}) ->
  case ets:lookup(Tab, Key) of
    [{Key, Id}] ->
      gen_server:reply(From, {ok, Id}),
      Lru2 = touch(Key, Lru),
      {noreply, State#state{lru=Lru2}};
    [] ->
      {reply, error, State}
  end;

handle_call({delete, Key}, From, State =  #state{tab=Tab, lru=Lru}) ->
  _ = ets:delete(Tab, Key),
  gen_server:reply(From, ok),
  Lru2 = drop(Key, Lru),
  {reply, true, State#state{lru=Lru2}};


handle_call(num_entries, _From, State = #state{tab=Tab}) ->
  {reply, ets:info(Tab, size) , State};


handle_call(_Msg, _From, State) ->
  {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.


handle_info(_Info, State) ->
  {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


terminate(_Reason, _State) ->
  ok.



has_exceeded(#state{ tab = Tab}) ->
  (ets:info(Tab, size) > ?MAX_ITEMS).

evict(State = #state{tab=Tab, lru=Lru}) ->
  case pop(Lru) of
    {ok, Key, Lru2} ->
      _ = ets:delete(Tab, Key),
      State#state{lru=Lru2};
    empty ->
      State
  end.


%% ========
%% LRU LIST


new_lrulist() -> [].

push(LruElement, LruList) ->
  case lists:member(LruElement, LruList) of
    true -> LruList;
    false -> LruList ++ [LruElement]
  end.

pop([]) -> empty;
pop([ El | Rest] ) -> {ok, El, Rest}.

touch(LruElement, [LruElement|Rest]) ->
  Rest ++ [LruElement];
touch(LruElement, [H|Rest]) ->
  [H|touch(LruElement, Rest)];
touch(LruElement, []) ->
  [LruElement].

drop(LruElement, LruList) ->
  lists:delete(LruElement, LruList).

