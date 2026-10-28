%%% -*- erlang -*-
%%%
%%% DNS SRV Discovery Backend
%%% DNS-based service discovery for QUIC distribution
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc DNS SRV record discovery backend.
%%%
%%% This backend uses DNS SRV records to discover nodes in a cluster.
%%% It queries `_erlang-dist._quic.{domain}` for SRV records.
%%%
%%% == Configuration ==
%%%
%%% In sys.config:
%%% ```
%%% {quic, [
%%%   {dist, [
%%%     {discovery_module, quic_discovery_dns},
%%%     {dns_domain, "cluster.example.com"},
%%%     {dns_ttl, 30}  % Cache TTL in seconds
%%%   ]}
%%% ]}
%%% '''
%%%
%%% == DNS Records ==
%%%
%%% ```
%%% _erlang-dist._quic.cluster.example.com. SRV 0 0 4433 node1.cluster.example.com.
%%% _erlang-dist._quic.cluster.example.com. SRV 0 0 4433 node2.cluster.example.com.
%%% '''
%%%
%%% @end

-module(quic_discovery_dns).
-behaviour(quic_discovery).

%% quic_discovery callbacks
-export([
    init/1,
    lookup/2,
    list_nodes/1
]).

%% Default service name
-define(SERVICE_NAME, "_erlang-dist._quic").
% seconds
-define(DEFAULT_TTL, 30).

%% ETS table for caching
-define(CACHE_TABLE, quic_discovery_dns_cache).

%%====================================================================
%% quic_discovery callbacks
%%====================================================================

%% @doc Initialize DNS discovery backend.
-spec init(Opts :: proplists:proplist() | map()) -> {ok, map()}.
init(Opts) ->
    %% Create cache table
    case ets:info(?CACHE_TABLE) of
        undefined ->
            ets:new(?CACHE_TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ok
    end,

    Domain = get_opt(dns_domain, Opts),
    TTL = get_opt(dns_ttl, Opts, ?DEFAULT_TTL),

    {ok, #{domain => Domain, ttl => TTL}}.

%% @doc Look up a node's address via DNS.
-spec lookup(NodeName :: atom(), Host :: string()) ->
    {ok, {inet:ip_address() | string(), inet:port_number()}}
    | {error, term()}.
lookup(NodeName, Host) ->
    %% Check cache first
    case lookup_cache(NodeName) of
        {ok, Address} ->
            {ok, Address};
        miss ->
            %% Query DNS
            lookup_dns(NodeName, Host)
    end.

%% @doc List all nodes via DNS SRV query.
-spec list_nodes(Host :: string()) ->
    {ok, [{atom(), inet:port_number()}]}
    | {error, term()}.
list_nodes(_Host) ->
    Domain = get_domain(),
    case query_srv(Domain) of
        {ok, Records} ->
            Nodes = lists:map(
                fun({_Priority, _Weight, Port, Target}) ->
                    %% Extract node name from target
                    NodeName = target_to_node(Target),
                    {NodeName, Port}
                end,
                Records
            ),
            {ok, Nodes};
        Error ->
            Error
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private
get_opt(Key, Opts) when is_map(Opts) ->
    maps:get(Key, Opts, undefined);
get_opt(Key, Opts) when is_list(Opts) ->
    proplists:get_value(Key, Opts, undefined).

get_opt(Key, Opts, Default) when is_map(Opts) ->
    maps:get(Key, Opts, Default);
get_opt(Key, Opts, Default) when is_list(Opts) ->
    proplists:get_value(Key, Opts, Default).

%% @private
get_domain() ->
    DistOpts = application:get_env(quic, dist, []),
    proplists:get_value(dns_domain, DistOpts, "local").

%% @private
get_ttl() ->
    DistOpts = application:get_env(quic, dist, []),
    proplists:get_value(dns_ttl, DistOpts, ?DEFAULT_TTL).

%% @private
lookup_cache(NodeName) ->
    case ets:lookup(?CACHE_TABLE, NodeName) of
        [{NodeName, Address, Expires}] ->
            Now = erlang:system_time(second),
            if
                Now < Expires -> {ok, Address};
                true -> miss
            end;
        [] ->
            miss
    end.

%% @private
cache_result(NodeName, Address) ->
    TTL = get_ttl(),
    Expires = erlang:system_time(second) + TTL,
    ets:insert(?CACHE_TABLE, {NodeName, Address, Expires}).

%% @private
lookup_dns(NodeName, Host) ->
    Domain = get_domain(),

    %% First try SRV record for the specific node
    SrvName = node_srv_name(NodeName, Domain),
    case query_srv(SrvName) of
        {ok, [{_Priority, _Weight, Port, Target} | _]} ->
            %% Resolve target to IP
            case resolve_target(Target) of
                {ok, IP} ->
                    Address = {IP, Port},
                    cache_result(NodeName, Address),
                    {ok, Address};
                Error ->
                    Error
            end;
        _ ->
            %% Fall back to A/AAAA record
            lookup_a_record(NodeName, Host)
    end.

%% @private
node_srv_name(NodeName, Domain) ->
    %% Format: _erlang-dist._quic.{nodename}.{domain}
    Name = atom_to_list(NodeName),
    case string:tokens(Name, "@") of
        [_Node, NodeHost] ->
            ?SERVICE_NAME ++ "." ++ NodeHost ++ "." ++ Domain;
        _ ->
            ?SERVICE_NAME ++ "." ++ Domain
    end.

%% @private
query_srv(Name) ->
    case inet_res:lookup(Name, in, srv) of
        [] ->
            {error, nxdomain};
        Records ->
            %% Sort by priority then weight
            Sorted = lists:sort(
                fun({P1, W1, _, _}, {P2, W2, _, _}) ->
                    {P1, -W1} =< {P2, -W2}
                end,
                Records
            ),
            {ok, Sorted}
    end.

%% @private
resolve_target(Target) ->
    %% Remove trailing dot if present
    Host =
        case lists:reverse(Target) of
            [$. | Rest] -> lists:reverse(Rest);
            _ -> Target
        end,

    case inet:getaddr(Host, inet) of
        {ok, IP} ->
            {ok, IP};
        {error, _} ->
            %% Try IPv6
            case inet:getaddr(Host, inet6) of
                {ok, IP} -> {ok, IP};
                Error -> Error
            end
    end.

%% @private
lookup_a_record(NodeName, Host) ->
    %% Try to resolve the host directly
    case inet:getaddr(Host, inet) of
        {ok, IP} ->
            %% Use default port
            Port = application:get_env(quic, dist_port, 4433),
            Address = {IP, Port},
            cache_result(NodeName, Address),
            {ok, Address};
        {error, _} ->
            %% Try IPv6
            case inet:getaddr(Host, inet6) of
                {ok, IP} ->
                    Port = application:get_env(quic, dist_port, 4433),
                    Address = {IP, Port},
                    cache_result(NodeName, Address),
                    {ok, Address};
                Error ->
                    Error
            end
    end.

%% @private
target_to_node(Target) ->
    %% Convert DNS target to node name
    %% Assumes format: nodename.domain.
    Host =
        case lists:reverse(Target) of
            [$. | Rest] -> lists:reverse(Rest);
            _ -> Target
        end,

    %% Extract first part as node name, rest as host
    case string:tokens(Host, ".") of
        [Name | HostParts] ->
            list_to_atom(Name ++ "@" ++ string:join(HostParts, "."));
        _ ->
            list_to_atom(Host)
    end.
