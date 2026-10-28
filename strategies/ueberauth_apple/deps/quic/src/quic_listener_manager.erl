%%% -*- erlang -*-
%%%
%%% QUIC Listener Pool Supervisor
%%% RFC 9000 Section 5 - Connections
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @private

-module(quic_listener_manager).

-behaviour(gen_server).

-export([get_tables/1]).

-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

-type state() :: {ets:table(), ets:table()}.

-spec get_tables(pid()) -> {ok, state()}.
get_tables(Pid) ->
    gen_server:call(Pid, get_tables).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link(?MODULE, noargs, [{hibernate_after, 50}]).

-spec init(noargs) -> {ok, state()}.
init(noargs) ->
    Opts = [set, public, {read_concurrency, true}, {write_concurrency, auto}],
    ConnTab = ets:new(quic_pool_connections, Opts),
    TicketTab = ets:new(quic_server_tickets, Opts),
    {ok, {ConnTab, TicketTab}}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, {ok, state()} | not_implemented, state()}.
handle_call(get_tables, _From, Tabs) ->
    {reply, {ok, Tabs}, Tabs};
handle_call(_Request, _From, Tabs) ->
    {reply, not_implemented, Tabs}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, Tabs) ->
    {noreply, Tabs}.
