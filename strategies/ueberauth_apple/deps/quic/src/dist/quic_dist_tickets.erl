%%% -*- erlang -*-
%%%
%%% QUIC Distribution Session Tickets
%%% Session ticket storage for 0-RTT reconnection
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Session ticket storage for 0-RTT fast reconnection.
%%%
%%% This module manages session tickets received from peer nodes,
%%% enabling 0-RTT reconnection which reduces connection latency
%%% significantly.
%%%
%%% == How It Works ==
%%%
%%% 1. After a successful TLS handshake, the server sends session tickets
%%% 2. The client stores these tickets associated with the node name
%%% 3. On reconnection, the client can use the ticket for 0-RTT
%%% 4. Tickets expire after their lifetime and are cleaned up
%%%
%%% @end

-module(quic_dist_tickets).
-behaviour(gen_server).

%% Dialyzer suppressions - ETS match specs use atoms as placeholders
-dialyzer({nowarn_function, [do_cleanup/0]}).

%% API
-export([
    start_link/0,
    store/2,
    lookup/1,
    delete/1,
    cleanup/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% ETS table name
-define(TABLE, quic_dist_tickets).

%% Cleanup interval (5 minutes)
-define(CLEANUP_INTERVAL, 300000).

%% Record for stored tickets
-record(ticket_entry, {
    node :: node(),
    ticket :: term(),
    stored_at :: non_neg_integer(),
    expires_at :: non_neg_integer()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the ticket storage server.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Store a session ticket for a node.
-spec store(Node :: node(), Ticket :: term()) -> ok.
store(Node, Ticket) ->
    gen_server:cast(?MODULE, {store, Node, Ticket}).

%% @doc Look up a session ticket for a node.
-spec lookup(Node :: node()) -> {ok, term()} | {error, not_found | expired}.
lookup(Node) ->
    Now = erlang:system_time(second),
    case ets:lookup(?TABLE, Node) of
        [#ticket_entry{ticket = Ticket, expires_at = Expires}] when Now < Expires ->
            {ok, Ticket};
        [#ticket_entry{}] ->
            %% Ticket expired, delete it
            ets:delete(?TABLE, Node),
            {error, expired};
        [] ->
            {error, not_found}
    end.

%% @doc Delete a session ticket for a node.
-spec delete(Node :: node()) -> ok.
delete(Node) ->
    ets:delete(?TABLE, Node),
    ok.

%% @doc Manually trigger cleanup of expired tickets.
-spec cleanup() -> ok.
cleanup() ->
    gen_server:cast(?MODULE, cleanup).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Create ETS table
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {keypos, #ticket_entry.node},
        {read_concurrency, true}
    ]),

    %% Schedule periodic cleanup
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),

    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({store, Node, Ticket}, State) ->
    %% Extract expiry from ticket if possible, otherwise use default
    ExpiresAt = get_ticket_expiry(Ticket),

    Entry = #ticket_entry{
        node = Node,
        ticket = Ticket,
        stored_at = erlang:system_time(second),
        expires_at = ExpiresAt
    },

    ets:insert(?TABLE, Entry),
    {noreply, State};
handle_cast(cleanup, State) ->
    do_cleanup(),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    do_cleanup(),
    %% Schedule next cleanup
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private
%% Remove expired tickets from the table.
do_cleanup() ->
    Now = erlang:system_time(second),
    %% Use match spec to find and delete expired entries
    MatchSpec = [
        {
            #ticket_entry{node = '$1', expires_at = '$2', _ = '_'},
            [{'<', '$2', Now}],
            ['$1']
        }
    ],
    ExpiredNodes = ets:select(?TABLE, MatchSpec),
    lists:foreach(fun(Node) -> ets:delete(?TABLE, Node) end, ExpiredNodes),
    ok.

%% @private
%% Extract expiry time from a session ticket.
%% The ticket format depends on the QUIC implementation.
get_ticket_expiry(Ticket) when is_map(Ticket) ->
    %% Try to extract lifetime from ticket map
    case maps:get(lifetime, Ticket, undefined) of
        undefined ->
            default_expiry();
        Lifetime when is_integer(Lifetime) ->
            erlang:system_time(second) + Lifetime
    end;
get_ticket_expiry({session_ticket, _, Lifetime, _, _, _, _, _, _, _}) when
    is_integer(Lifetime)
->
    %% Handle #session_ticket record format
    erlang:system_time(second) + Lifetime;
get_ticket_expiry(_Ticket) ->
    %% Unknown format, use default expiry
    default_expiry().

%% @private
%% Default ticket expiry (7 days).
default_expiry() ->
    erlang:system_time(second) + (7 * 24 * 60 * 60).
