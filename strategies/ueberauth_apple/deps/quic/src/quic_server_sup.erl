%%% -*- erlang -*-
%%%
%%% QUIC Server Pool Dynamic Supervisor
%%% RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Dynamic supervisor for QUIC server pools.
%%%
%%% This module provides a dynamic supervisor that allows starting and
%%% stopping named QUIC server pools at runtime. Each server pool is
%%% supervised by a quic_listener_sup process.
%%%
%%% == Usage ==
%%%
%%% ```
%%% %% Start a named server
%%% {ok, Pid} = quic_server_sup:start_server(my_server, 4433, Opts).
%%%
%%% %% Stop the server
%%% ok = quic_server_sup:stop_server(my_server).
%%% '''

-module(quic_server_sup).
-behaviour(supervisor).

-export([
    start_link/0,
    start_server/3,
    stop_server/1,
    server_spec/3
]).

%% supervisor callbacks
-export([init/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the dynamic server supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a named QUIC server pool.
%% The server will be registered with the given Name in the server registry.
%% Registration is handled by quic_listener_sup:init/1 to support supervisor restarts.
-spec start_server(atom(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
start_server(Name, Port, Opts) when is_atom(Name), is_integer(Port), is_map(Opts) ->
    %% Check if server already exists
    case quic_server_registry:lookup(Name) of
        {ok, _} ->
            {error, {already_started, Name}};
        {error, not_found} ->
            %% Add name to options for registry registration in listener_sup
            ServerOpts = Opts#{name => Name},
            ChildSpec = #{
                id => Name,
                start => {quic_listener_sup, start_link, [Port, ServerOpts]},
                restart => permanent,
                shutdown => infinity,
                type => supervisor,
                modules => [quic_listener_sup]
            },
            supervisor:start_child(?MODULE, ChildSpec)
    end.

%% @doc Stop a named QUIC server pool.
-spec stop_server(atom()) -> ok | {error, term()}.
stop_server(Name) when is_atom(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok ->
            _ = supervisor:delete_child(?MODULE, Name),
            %% Unregister is handled by registry monitor
            ok;
        {error, not_found} ->
            {error, {not_found, Name}}
    end.

%% @doc Return a child spec for embedding a QUIC server in your own supervisor.
%%
%% This allows you to supervise QUIC servers within your application's
%% supervision tree instead of using the built-in `quic_server_sup'.
%%
%% Example:
%% ```
%% init([]) ->
%%     Spec = quic_server_sup:server_spec(my_quic, 4433, #{
%%         cert => CertDer,
%%         key => KeyTerm,
%%         alpn => [<<"h3">>]
%%     }),
%%     {ok, {#{strategy => one_for_one}, [Spec]}}.
%% '''
%%
%% Note: When using your own supervisor, the server will not be registered
%% in the quic_server_registry. Use `quic_listener_sup:get_listeners/1' to
%% get listener PIDs directly from the supervisor pid.
-spec server_spec(atom(), inet:port_number(), map()) -> supervisor:child_spec().
server_spec(Name, Port, Opts) when is_atom(Name), is_integer(Port), is_map(Opts) ->
    #{
        id => Name,
        start => {quic_listener_sup, start_link, [Port, Opts]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [quic_listener_sup]
    }.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    %% No static children - servers are started dynamically
    {ok, {SupFlags, []}}.
