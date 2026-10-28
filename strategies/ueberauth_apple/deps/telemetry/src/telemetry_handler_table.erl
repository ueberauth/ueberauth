%%%-------------------------------------------------------------------
%% @private ETS table for handlers.
%%
%% Each handler is stored in the table. A key is an event name the
%% handler is attached to. All writes to a table go through a single
%% Agent process to make sure that we don't get duplicate handler IDs.
%%
%% Reads (`list_handlers_...') are executed by the calling process.
%% @end
%%%-------------------------------------------------------------------
-module(telemetry_handler_table).

-behaviour(gen_server).

-export([start_link/0,
         persist/0,
         insert/4,
         delete/1,
         list_for_event/1,
         list_by_prefix/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-compile({inline, [impl_get/0]}).

-include("telemetry.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec insert(HandlerId, EventNames, Function, Config) -> ok | {error, already_exists} when
      HandlerId :: telemetry:handler_id(),
      EventNames :: [telemetry:event_name()],
      Function :: telemetry:handler_function(),
      Config :: telemetry:handler_config().
insert(HandlerId, EventNames, Function, Config) ->
    gen_server:call(?MODULE, {insert, HandlerId, EventNames, Function, Config}).

-spec delete(telemetry:handler_id()) -> ok | {error, not_found}.
delete(HandlerId) ->
    gen_server:call(?MODULE, {delete, HandlerId}).

persist() ->
    {Mod, _, State} = impl_get(),
    case Mod:persist(State) of
        {ok, NewState} ->
            ListForEventFun = fun telemetry_pt:list_for_event/2,
            persistent_term:put(telemetry, {telemetry_pt, ListForEventFun, NewState});
        _ ->
            ok
    end.

impl_get() ->
    persistent_term:get(telemetry, default_impl()).

-spec list_for_event(telemetry:event_name()) -> [#handler{}].
list_for_event(EventName) ->
    {_Mod, ListForEventFun, State} = impl_get(),
    ListForEventFun(State, EventName).

-spec list_by_prefix(telemetry:event_prefix()) -> [#handler{}].
list_by_prefix(EventPrefix) ->
    {Mod, _ListForEventFun, State} = impl_get(),
    Mod:list_by_prefix(State, EventPrefix).

init([]) ->
    process_flag(trap_exit, true),
    TID = create_table(),
    ListForEventFun = fun telemetry_ets:list_for_event/2,
    persistent_term:put(telemetry, {telemetry_ets, ListForEventFun, TID}),
    {ok, []}.

handle_call({insert, HandlerId, EventNames, Function, Config}, _From, State) ->
    {Mod, ListForEventFun, MState} = impl_get(),
    case Mod:insert(MState, HandlerId, EventNames, Function, Config) of
        {ok, NewState} ->
            persistent_term:put(telemetry, {Mod, ListForEventFun, NewState}),
            {reply, ok, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({delete, HandlerId}, _From, State) ->
    {Mod, ListForEventFun, MState} = impl_get(),
    case Mod:delete(MState, HandlerId) of
        {ok, NewState} ->
            persistent_term:put(telemetry, {Mod, ListForEventFun, NewState}),
            {reply, ok, State};
        {error, _} = Error ->
            {reply, Error, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_Reason, _State) ->
    persistent_term:erase(telemetry),
    ok.

%%

default_impl() ->
    ListForEventFun = fun(_, _) -> [] end,
    {telemetry_ets, ListForEventFun, #{}}.

create_table() ->
    ets:new(?MODULE, [duplicate_bag, protected,
                      {keypos, #handler.event_name}, {read_concurrency, true}]).
