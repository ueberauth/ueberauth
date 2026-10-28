%%% -*- erlang -*-
%%%
%%% QUIC Discovery Behaviour
%%% Pluggable discovery for QUIC distribution
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Behaviour definition for node discovery backends.
%%%
%%% Discovery modules are used to locate nodes in a QUIC cluster
%%% without requiring EPMD. Implementations can use:
%%%
%%% - Static configuration
%%% - DNS SRV records
%%% - Consul/etcd/Kubernetes service discovery
%%% - Custom protocols
%%%
%%% == Implementing a Backend ==
%%%
%%% ```
%%% -module(my_discovery).
%%% -behaviour(quic_discovery).
%%%
%%% -export([init/1, register/3, lookup/2, list_nodes/1]).
%%%
%%% init(Opts) ->
%%%     %% Initialize backend state
%%%     {ok, State}.
%%%
%%% register(NodeName, Port, State) ->
%%%     %% Register this node
%%%     {ok, State}.
%%%
%%% lookup(NodeName, Host) ->
%%%     %% Find a node's address
%%%     {ok, {IP, Port}} | {error, not_found}.
%%%
%%% list_nodes(Host) ->
%%%     %% List all known nodes
%%%     {ok, [{NodeName, Port}]}.
%%% '''
%%%
%%% @end

-module(quic_discovery).

%% Behaviour callbacks
-callback init(Opts :: proplists:proplist() | map()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

-callback register(
    NodeName :: atom(),
    Port :: inet:port_number(),
    State :: term()
) ->
    {ok, State :: term()} | {error, Reason :: term()}.

-callback lookup(NodeName :: atom(), Host :: string()) ->
    {ok, {inet:ip_address() | string(), inet:port_number()}}
    | {error, Reason :: term()}.

-callback list_nodes(Host :: string()) ->
    {ok, [{NodeName :: atom(), inet:port_number()}]}
    | {error, Reason :: term()}.

%% Optional callbacks
-optional_callbacks([init/1, register/3, list_nodes/1]).

%% API for discovery operations
-export([
    lookup/2,
    register_node/3,
    list_nodes/1
]).

%%====================================================================
%% API
%%====================================================================

%% @doc Look up a node's address using the configured discovery module.
-spec lookup(Node :: node(), Host :: string()) ->
    {ok, {inet:ip_address() | string(), inet:port_number()}}
    | {error, term()}.
lookup(Node, Host) ->
    Module = get_discovery_module(),
    Module:lookup(Node, Host).

%% @doc Register this node with the discovery backend.
-spec register_node(
    NodeName :: atom(),
    Port :: inet:port_number(),
    Opts :: proplists:proplist()
) ->
    ok | {error, term()}.
register_node(NodeName, Port, Opts) ->
    Module = get_discovery_module(),
    case erlang:function_exported(Module, register, 3) of
        true ->
            State = get_discovery_state(Module, Opts),
            case Module:register(NodeName, Port, State) of
                {ok, _NewState} -> ok;
                Error -> Error
            end;
        false ->
            % Registration not supported by backend
            ok
    end.

%% @doc List all known nodes.
-spec list_nodes(Host :: string()) ->
    {ok, [{atom(), inet:port_number()}]} | {error, term()}.
list_nodes(Host) ->
    Module = get_discovery_module(),
    case erlang:function_exported(Module, list_nodes, 1) of
        true -> Module:list_nodes(Host);
        false -> {error, not_supported}
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private
get_discovery_module() ->
    DistOpts = application:get_env(quic, dist, []),
    proplists:get_value(discovery_module, DistOpts, quic_discovery_static).

%% @private
get_discovery_state(Module, Opts) ->
    case erlang:function_exported(Module, init, 1) of
        true ->
            case Module:init(Opts) of
                {ok, State} -> State;
                _ -> #{}
            end;
        false ->
            #{}
    end.
