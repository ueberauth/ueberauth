%%% -*- erlang -*-
%%%
%%% QUIC EPMD Module
%%% EPMD replacement for QUIC distribution
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc EPMD replacement module for QUIC distribution.
%%%
%%% This module implements the erl_epmd behaviour to provide
%%% node discovery without requiring the traditional EPMD daemon.
%%% It delegates to the configured discovery backend.
%%%
%%% == Usage ==
%%%
%%% ```
%%% erl -proto_dist quic -epmd_module quic_epmd -start_epmd false
%%% '''
%%%
%%% @end

-module(quic_epmd).

%% erl_epmd behaviour callbacks
-export([
    start_link/0,
    register_node/2,
    register_node/3,
    port_please/2,
    port_please/3,
    names/1,
    address_please/3
]).

%% Default QUIC distribution port
-define(DEFAULT_PORT, 4433).

%%====================================================================
%% erl_epmd Behaviour Callbacks
%%====================================================================

%% @doc Start the EPMD replacement.
%% This is a no-op since we don't need a separate process.
-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    %% We could start a gen_server here if needed for state,
    %% but for now discovery is stateless
    ignore.

%% @doc Register this node with the name server.
-spec register_node(Name :: atom(), Port :: inet:port_number()) ->
    {ok, Creation :: non_neg_integer()} | {error, term()}.
register_node(Name, Port) ->
    register_node(Name, Port, inet).

%% @doc Register this node with address family.
-spec register_node(
    Name :: atom(),
    Port :: inet:port_number(),
    Family :: inet | inet6
) ->
    {ok, Creation :: non_neg_integer()} | {error, term()}.
register_node(Name, Port, _Family) ->
    %% Register with discovery backend
    DistOpts = application:get_env(quic, dist, []),
    ok = quic_discovery:register_node(Name, Port, DistOpts),

    %% Return a creation number
    %% Use timestamp-based creation for uniqueness
    Creation = erlang:system_time(second) band 16#FFFFFFFF,
    {ok, Creation}.

%% @doc Look up a node's port.
-spec port_please(Name :: string(), Host :: string()) ->
    {port, Port :: inet:port_number(), Version :: non_neg_integer()}
    | noport.
port_please(Name, Host) ->
    port_please(Name, Host, infinity).

%% @doc Look up a node's port with timeout.
-spec port_please(
    Name :: string(),
    Host :: string(),
    Timeout :: timeout()
) ->
    {port, Port :: inet:port_number(), Version :: non_neg_integer()}
    | noport.
port_please(Name, Host, _Timeout) ->
    %% Convert name string to node atom
    NodeName = list_to_atom(Name ++ "@" ++ Host),

    case quic_discovery:lookup(NodeName, Host) of
        {ok, {_IP, Port}} ->
            %% Version 5 is for OTP R6 and later
            {port, Port, 5};
        {error, _} ->
            noport
    end.

%% @doc List all registered nodes on a host.
-spec names(Host :: string()) ->
    {ok, [{Name :: string(), Port :: inet:port_number()}]}
    | {error, term()}.
names(Host) ->
    case quic_discovery:list_nodes(Host) of
        {ok, Nodes} ->
            %% Convert to expected format
            Names = lists:map(
                fun({NodeAtom, Port}) ->
                    NodeStr = atom_to_list(NodeAtom),
                    Name =
                        case string:tokens(NodeStr, "@") of
                            [N, _] -> N;
                            _ -> NodeStr
                        end,
                    {Name, Port}
                end,
                Nodes
            ),
            {ok, Names};
        Error ->
            Error
    end.

%% @doc Get the address for a node.
%% This is called when we need to connect to another node.
-spec address_please(
    Name :: string(),
    Host :: string(),
    AddressFamily :: inet | inet6
) ->
    {ok, inet:ip_address()}
    | {ok, inet:ip_address(), Port :: inet:port_number(), Version :: non_neg_integer()}
    | {error, term()}.
address_please(Name, Host, AddressFamily) ->
    NodeName = list_to_atom(Name ++ "@" ++ Host),

    case quic_discovery:lookup(NodeName, Host) of
        {ok, {IP, Port}} when is_tuple(IP) ->
            %% IP address already resolved
            {ok, IP, Port, 5};
        {ok, {IPStr, Port}} when is_list(IPStr) ->
            %% Need to parse IP string
            case inet:parse_address(IPStr) of
                {ok, IP} ->
                    {ok, IP, Port, 5};
                {error, _} ->
                    %% Try DNS resolution
                    resolve_address(IPStr, Port, AddressFamily)
            end;
        {error, not_found} ->
            %% Fall back to DNS resolution of the host
            resolve_host(Host, AddressFamily);
        Error ->
            Error
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private
resolve_address(Host, Port, AddressFamily) ->
    case inet:getaddr(Host, AddressFamily) of
        {ok, IP} ->
            {ok, IP, Port, 5};
        {error, _} = Error ->
            Error
    end.

%% @private
resolve_host(Host, AddressFamily) ->
    case inet:getaddr(Host, AddressFamily) of
        {ok, IP} ->
            %% Use default port
            Port = application:get_env(quic, dist_port, ?DEFAULT_PORT),
            {ok, IP, Port, 5};
        Error ->
            Error
    end.
