%%% -*- erlang -*-
%%%
%%% Static Discovery Backend
%%% Static node configuration for QUIC distribution
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Static node discovery backend.
%%%
%%% This backend uses a static list of nodes configured in
%%% the application environment or vm.args.
%%%
%%% == Configuration ==
%%%
%%% In sys.config:
%%% ```
%%% {quic, [
%%%   {dist, [
%%%     {discovery_module, quic_discovery_static},
%%%     {nodes, [
%%%       {'node1@host1', {"192.168.1.1", 4433}},
%%%       {'node2@host2', {"192.168.1.2", 4433}}
%%%     ]}
%%%   ]}
%%% ]}
%%% '''
%%%
%%% In vm.args:
%%% ```
%%% -quic_dist nodes [{'node1@host1',{"192.168.1.1",4433}}]
%%% '''
%%%
%%% @end

-module(quic_discovery_static).
-behaviour(quic_discovery).

%% quic_discovery callbacks
-export([
    init/1,
    register/3,
    lookup/2,
    list_nodes/1
]).

%% Direct registration API (for manual/testing use)
-export([
    register/2,
    unregister/1
]).

%% ETS table for runtime updates
-define(TABLE, quic_discovery_static_nodes).

%%====================================================================
%% quic_discovery callbacks
%%====================================================================

%% @doc Initialize the static discovery backend.
-spec init(Opts :: proplists:proplist() | map()) -> {ok, map()}.
init(Opts) ->
    %% Create ETS table if not exists
    ensure_table(),

    %% Load initial nodes from config
    Nodes = get_configured_nodes(Opts),
    lists:foreach(
        fun({Node, Address}) ->
            ets:insert(?TABLE, {Node, Address})
        end,
        Nodes
    ),

    {ok, #{nodes => Nodes}}.

%% @doc Register a node in the static table.
%% This allows runtime updates to the node list.
-spec register(NodeName :: atom(), Port :: inet:port_number(), State :: map()) ->
    {ok, map()}.
register(NodeName, Port, State) ->
    %% Ensure table exists
    ensure_table(),
    %% Get local address (or use 0.0.0.0)
    Address =
        case inet:getif() of
            {ok, [{IP, _, _} | _]} -> {IP, Port};
            _ -> {{0, 0, 0, 0}, Port}
        end,
    ets:insert(?TABLE, {NodeName, Address}),
    {ok, State}.

%% @private
%% Ensure the ETS table exists.
ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ok
    end.

%%====================================================================
%% Direct Registration API
%%====================================================================

%% @doc Register a node with its address directly.
%% This is a simplified API for manual registration during testing
%% or when you need to add a node outside of the behaviour callback.
%% Address can be {IP, Port} where IP is a tuple or string.
-spec register(NodeName :: atom(), Address :: {inet:ip_address() | string(), inet:port_number()}) ->
    ok.
register(NodeName, Address) ->
    ensure_table(),
    ets:insert(?TABLE, {NodeName, Address}),
    ok.

%% @doc Unregister a node.
-spec unregister(NodeName :: atom()) -> ok.
unregister(NodeName) ->
    case ets:info(?TABLE) of
        undefined ->
            ok;
        _ ->
            ets:delete(?TABLE, NodeName),
            ok
    end.

%% @doc Look up a node's address.
-spec lookup(NodeName :: atom(), Host :: string()) ->
    {ok, {inet:ip_address() | string(), inet:port_number()}}
    | {error, not_found}.
lookup(NodeName, Host) ->
    %% First check ETS table (may not exist during early startup)
    case ets:info(?TABLE) of
        undefined ->
            %% Table not created yet, check config directly
            lookup_in_config(NodeName, Host);
        _ ->
            case ets:lookup(?TABLE, NodeName) of
                [{NodeName, Address}] ->
                    {ok, Address};
                [] ->
                    %% Check application config
                    lookup_in_config(NodeName, Host)
            end
    end.

%% @doc List all known nodes.
-spec list_nodes(Host :: string()) ->
    {ok, [{atom(), inet:port_number()}]}.
list_nodes(_Host) ->
    case ets:info(?TABLE) of
        undefined ->
            %% Table not created yet, return empty list
            {ok, []};
        _ ->
            Nodes = ets:tab2list(?TABLE),
            {ok, [{Node, Port} || {Node, {_IP, Port}} <- Nodes]}
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private
%% Get nodes from configuration.
get_configured_nodes(Opts) when is_map(Opts) ->
    maps:get(nodes, Opts, get_app_env_nodes());
get_configured_nodes(Opts) when is_list(Opts) ->
    proplists:get_value(nodes, Opts, get_app_env_nodes()).

%% @private
get_app_env_nodes() ->
    DistOpts = application:get_env(quic, dist, []),
    proplists:get_value(nodes, DistOpts, get_init_arg_nodes()).

%% @private
get_init_arg_nodes() ->
    case init:get_argument(quic_dist) of
        {ok, Args} ->
            parse_init_nodes(Args);
        error ->
            []
    end.

%% @private
parse_init_nodes(Args) ->
    lists:flatmap(
        fun
            (["nodes", NodesStr]) ->
                case erl_scan:string(NodesStr ++ ".") of
                    {ok, Tokens, _} ->
                        case erl_parse:parse_term(Tokens) of
                            {ok, Nodes} when is_list(Nodes) -> Nodes;
                            _ -> []
                        end;
                    _ ->
                        []
                end;
            (_) ->
                []
        end,
        Args
    ).

%% @private
lookup_in_config(NodeName, Host) ->
    Nodes = get_app_env_nodes(),
    case lists:keyfind(NodeName, 1, Nodes) of
        {NodeName, Address} ->
            {ok, Address};
        false ->
            %% Try with just the host part
            lookup_by_host(Host, Nodes)
    end.

%% @private
lookup_by_host(_Host, []) ->
    {error, not_found};
lookup_by_host(Host, [{Node, {IP, Port}} | Rest]) ->
    Name = atom_to_list(Node),
    case string:tokens(Name, "@") of
        [_, NodeHost] when NodeHost =:= Host ->
            {ok, {IP, Port}};
        _ ->
            lookup_by_host(Host, Rest)
    end.
