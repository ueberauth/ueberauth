%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% The manager used to drive request counters and a duration histogram
%%% via `hackney_metrics'. Those hooks are gone — metrics are now
%%% emitted by user middleware (see `hackney_middleware' and
%%% `guides/middleware.md'). What remains is a tiny gen_server kept for
%%% the backward-compatible `get_state/1' and `async_response_pid/1'
%%% accessors that older callers still rely on.

-module(hackney_manager).
-behaviour(gen_server).

%% Backward compatibility API
-export([get_state/1, async_response_pid/1]).

%% gen_server API
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

%% @doc Check the state of a connection (backward compatibility).
%% In the old architecture, this tracked request state.
%% In the new architecture, we simply check if the connection process is alive.
%% Returns `req_not_found' if the process is dead, or the connection state name.
-spec get_state(pid() | term()) -> req_not_found | atom().
get_state(ConnPid) when is_pid(ConnPid) ->
    case is_process_alive(ConnPid) of
        false -> req_not_found;
        true ->
            case hackney_conn:get_state(ConnPid) of
                {ok, State} -> State;
                _ -> req_not_found
            end
    end;
get_state(_) ->
    req_not_found.

%% @doc Get the async response pid (backward compatibility).
%% In the new architecture, all streaming connections are considered "async".
-spec async_response_pid(pid()) -> {ok, pid()} | {error, req_not_found | req_not_async}.
async_response_pid(Ref) when is_pid(Ref) ->
    case get_state(Ref) of
        req_not_found -> {error, req_not_found};
        streaming -> {ok, Ref};
        streaming_once -> {ok, Ref};
        _ -> {error, req_not_async}
    end;
async_response_pid(_) ->
    {error, req_not_async}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
