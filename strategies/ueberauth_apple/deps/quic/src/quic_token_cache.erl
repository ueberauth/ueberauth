%%% -*- erlang -*-
%%%
%%% Client-side cache for RFC 9000 §8.1.3 NEW_TOKEN frames.
%%%
%%% Servers send NEW_TOKEN to signal that a given client address has
%%% already completed address validation. A subsequent connect by the
%%% same client can include that opaque token in the Initial packet's
%%% Token field and skip the retry round-trip.
%%%
%%% This cache is in-memory only; tokens do not survive VM restart.
%%% The table is bounded to avoid unbounded growth from talking to
%%% many distinct servers — on overflow the oldest entry is dropped.

-module(quic_token_cache).
-behaviour(gen_server).

-export([start_link/0, put/2, take/1, clear/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TABLE, ?MODULE).
-define(MAX_ENTRIES, 256).

-type endpoint() :: {binary() | inet:ip_address(), inet:port_number()}.

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Store a token for the given endpoint. Overwrites any previous
%% entry for the same endpoint; when the cache is at its size limit,
%% the oldest entry is dropped.
-spec put(endpoint(), binary()) -> ok.
put(Endpoint, Token) when is_binary(Token) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _ ->
            Ts = erlang:monotonic_time(millisecond),
            true = ets:insert(?TABLE, {Endpoint, Token, Ts}),
            gen_server:cast(?MODULE, maybe_evict),
            ok
    end.

%% @doc Atomically return and remove a cached token for the endpoint,
%% or `empty' if none is cached. Returning the token consumes it —
%% per RFC 9000 §8.1.3 each NEW_TOKEN is meant to be used at most once.
-spec take(endpoint()) -> {ok, binary()} | empty.
take(Endpoint) ->
    case whereis(?MODULE) of
        undefined ->
            empty;
        _ ->
            case ets:lookup(?TABLE, Endpoint) of
                [] ->
                    empty;
                [{_, Token, _Ts}] ->
                    ets:delete(?TABLE, Endpoint),
                    {ok, Token}
            end
    end.

%% @doc Drop all cached tokens. Useful for tests.
-spec clear() -> ok.
clear() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:call(?MODULE, clear)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    Tab = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    {ok, Tab}.

handle_call(clear, _From, Tab) ->
    ets:delete_all_objects(Tab),
    {reply, ok, Tab}.

handle_cast(maybe_evict, Tab) ->
    maybe_evict_oldest(Tab),
    {noreply, Tab}.

%%====================================================================
%% Internal
%%====================================================================

maybe_evict_oldest(Tab) ->
    case ets:info(Tab, size) > ?MAX_ENTRIES of
        false ->
            ok;
        true ->
            %% Linear scan for the oldest entry; acceptable at the
            %% default cap (256 entries).
            Oldest = ets:foldl(
                fun
                    ({Key, _, Ts}, undefined) ->
                        {Key, Ts};
                    ({Key, _, Ts}, {_, OldestTs}) when Ts < OldestTs ->
                        {Key, Ts};
                    (_, Acc) ->
                        Acc
                end,
                undefined,
                Tab
            ),
            case Oldest of
                undefined -> ok;
                {Key, _} -> ets:delete(Tab, Key)
            end
    end.
