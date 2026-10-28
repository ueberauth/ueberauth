%%% -*- erlang -*-
%%%
%%% Dynamic supervisor for client connection attempts started by the
%%% Happy Eyeballs coordinator (quic_happy). Children are temporary
%%% quic_connection workers identified by a unique reference so several
%%% concurrent attempts can run under one supervisor.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-module(quic_conn_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/4, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a supervised client connection attempt. The connection is
%% linked to this supervisor (not the caller), so the Happy Eyeballs
%% coordinator can race several attempts and keep the winner after it
%% exits. Returns the connection pid.
-spec start_child(
    inet:ip_address() | binary() | string(),
    inet:port_number(),
    map(),
    pid()
) -> {ok, pid()} | {error, term()}.
start_child(Host, Port, Opts, Owner) ->
    %% Supervised attempts are linked to this supervisor, not the caller, so
    %% they monitor their owner to close when it dies (see quic_connection).
    Spec = #{
        id => {quic_connection, make_ref()},
        start => {quic_connection, start_link, [Host, Port, Opts#{monitor_owner => true}, Owner]},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [quic_connection]
    },
    supervisor:start_child(?MODULE, Spec).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.
