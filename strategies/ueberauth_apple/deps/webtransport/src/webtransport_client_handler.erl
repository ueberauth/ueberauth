%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc Default WebTransport client handler.
%%
%% This handler forwards all events to the controlling process as messages:
%%
%% - `{webtransport, Session, {stream, StreamId, Type, Data}}'
%% - `{webtransport, Session, {stream_fin, StreamId, Type, Data}}'
%% - `{webtransport, Session, {datagram, Data}}'
%% - `{webtransport, Session, {stream_closed, StreamId, Reason}}'
%%
-module(webtransport_client_handler).
-behaviour(webtransport_handler).

-export([init/2, init/3, handle_stream/4, handle_stream_fin/4]).
-export([handle_datagram/2, handle_stream_closed/3, terminate/2]).

-record(state, {
    owner :: pid(),
    session :: webtransport:session()
}).

init(Session, Req) ->
    init(Session, Req, #{}).

init(Session, _Req, Opts) ->
    Owner = maps:get(owner, Opts, self()),
    {ok, #state{owner = Owner, session = Session}}.

handle_stream(StreamId, Type, Data, #state{owner = Owner, session = Session} = State) ->
    Owner ! {webtransport, Session, {stream, StreamId, Type, Data}},
    {ok, State}.

handle_stream_fin(StreamId, Type, Data, #state{owner = Owner, session = Session} = State) ->
    Owner ! {webtransport, Session, {stream_fin, StreamId, Type, Data}},
    {ok, State}.

handle_datagram(Data, #state{owner = Owner, session = Session} = State) ->
    Owner ! {webtransport, Session, {datagram, Data}},
    {ok, State}.

handle_stream_closed(StreamId, Reason, #state{owner = Owner, session = Session} = State) ->
    Owner ! {webtransport, Session, {stream_closed, StreamId, Reason}},
    {ok, State}.

terminate(_Reason, #state{owner = Owner, session = Session}) ->
    Owner ! {webtransport, Session, closed},
    ok.
