%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%%
%%% @doc Alt-Svc header parsing and caching for HTTP/3 discovery.
%%%
%%% This module parses Alt-Svc response headers to discover HTTP/3 endpoints
%%% and caches them for future requests.
%%%
%%% == Alt-Svc Header Format ==
%%% ```
%%% Alt-Svc: h3=":443"; ma=86400, h3-29=":443"
%%% Alt-Svc: clear
%%% '''
%%%
%%% == Usage ==
%%% After receiving an HTTP/1.1 or HTTP/2 response, check for Alt-Svc:
%%% ```
%%% case hackney_altsvc:parse_and_cache(Host, Headers) of
%%%     {ok, h3, Port} -> %% HTTP/3 available on Port
%%%     none -> %% No HTTP/3 advertised
%%% end
%%% '''
%%%
%%% Before connecting, check the cache:
%%% ```
%%% case hackney_altsvc:lookup(Host, Port) of
%%%     {ok, h3, H3Port} -> %% Try HTTP/3 on H3Port
%%%     none -> %% No cached Alt-Svc
%%% end
%%% '''

-module(hackney_altsvc).

-export([
    init/0,
    parse/1,
    parse_and_cache/3,
    lookup/2,
    cache/4,
    clear/2,
    clear_all/0,
    is_h3_blocked/2,
    mark_h3_blocked/2
]).

-define(ALTSVC_TABLE, hackney_altsvc_cache).
-define(DEFAULT_MAX_AGE, 86400).  %% 24 hours
-define(BLOCKED_TTL, 300).        %% 5 minutes for negative cache

%%====================================================================
%% API
%%====================================================================

%% @doc Initialize the Alt-Svc cache. Called at application start.
-spec init() -> ok.
init() ->
    case ets:info(?ALTSVC_TABLE) of
        undefined ->
            _ = ets:new(?ALTSVC_TABLE, [set, public, named_table,
                                        {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

%% @doc Parse an Alt-Svc header value.
%% Returns list of {Protocol, Host, Port, MaxAge} tuples.
%% Protocol is h3 atom for HTTP/3 variants, or binary for other protocols.
%% Host is 'same' if not specified (use origin host).
-spec parse(binary() | string()) -> [{h3 | binary(), same | binary(), inet:port_number(), non_neg_integer()}].
parse(<<"clear">>) -> [];
parse("clear") -> [];
parse(Header) when is_list(Header) ->
    parse(list_to_binary(Header));
parse(Header) when is_binary(Header) ->
    parse_entries(Header, []).

%% @doc Parse Alt-Svc header from response headers and cache if h3 found.
%%
%% Honors RFC 7838: a `clear' value invalidates any cached entry for the
%% origin. Multiple `Alt-Svc' headers are merged before parsing as if
%% they had been comma-concatenated (RFC 7230 §3.2.2).
%%
%% Returns `{ok, h3, Port}' if HTTP/3 is now cached for the origin,
%% `cleared' if the cache was invalidated, or `none' otherwise.
-spec parse_and_cache(Host :: binary() | string(), Port :: inet:port_number(),
                      Headers :: [{binary(), binary()}]) ->
    {ok, h3, inet:port_number()} | cleared | none.
parse_and_cache(Host, OrigPort, Headers) ->
    case collect_altsvc_headers(Headers) of
        <<>> ->
            none;
        Combined ->
            case is_clear_directive(Combined) of
                true ->
                    clear(Host, OrigPort),
                    cleared;
                false ->
                    Entries = parse(Combined),
                    case find_h3_entry(Entries) of
                        {ok, H3Port, MaxAge} ->
                            cache(Host, OrigPort, H3Port, MaxAge),
                            {ok, h3, H3Port};
                        none ->
                            none
                    end
            end
    end.

%% @doc Lookup cached Alt-Svc for a host/port.
%% Returns {ok, h3, H3Port} if HTTP/3 is available and not expired.
-spec lookup(Host :: binary() | string(), Port :: inet:port_number()) ->
    {ok, h3, inet:port_number()} | none.
lookup(Host, Port) ->
    Key = make_key(Host, Port),
    case ets:lookup(?ALTSVC_TABLE, Key) of
        [{Key, {h3, H3Port, Expiry}}] ->
            Now = erlang:system_time(second),
            case Now < Expiry of
                true -> {ok, h3, H3Port};
                false ->
                    ets:delete(?ALTSVC_TABLE, Key),
                    none
            end;
        _ ->
            none
    end.

%% @doc Cache an Alt-Svc entry.
-spec cache(Host :: binary() | string(), OrigPort :: inet:port_number(),
            H3Port :: inet:port_number(), MaxAge :: non_neg_integer()) -> ok.
cache(Host, OrigPort, H3Port, MaxAge) ->
    Key = make_key(Host, OrigPort),
    Expiry = erlang:system_time(second) + MaxAge,
    ets:insert(?ALTSVC_TABLE, {Key, {h3, H3Port, Expiry}}),
    ok.

%% @doc Clear cached Alt-Svc for a host/port.
-spec clear(Host :: binary() | string(), Port :: inet:port_number()) -> ok.
clear(Host, Port) ->
    Key = make_key(Host, Port),
    ets:delete(?ALTSVC_TABLE, Key),
    ok.

%% @doc Clear all cached Alt-Svc entries.
-spec clear_all() -> ok.
clear_all() ->
    ets:delete_all_objects(?ALTSVC_TABLE),
    ok.

%% @doc Check if HTTP/3 is blocked for a host (negative cache).
-spec is_h3_blocked(Host :: binary() | string(), Port :: inet:port_number()) -> boolean().
is_h3_blocked(Host, Port) ->
    Key = {blocked, make_key(Host, Port)},
    case ets:lookup(?ALTSVC_TABLE, Key) of
        [{Key, Expiry}] ->
            Now = erlang:system_time(second),
            case Now < Expiry of
                true -> true;
                false ->
                    ets:delete(?ALTSVC_TABLE, Key),
                    false
            end;
        _ ->
            false
    end.

%% @doc Mark HTTP/3 as blocked for a host (negative cache for 5 min).
-spec mark_h3_blocked(Host :: binary() | string(), Port :: inet:port_number()) -> ok.
mark_h3_blocked(Host, Port) ->
    Key = {blocked, make_key(Host, Port)},
    Expiry = erlang:system_time(second) + ?BLOCKED_TTL,
    ets:insert(?ALTSVC_TABLE, {Key, Expiry}),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

make_key(Host, Port) when is_list(Host) ->
    make_key(list_to_binary(Host), Port);
make_key(Host, Port) when is_binary(Host) ->
    {string:lowercase(Host), Port}.

%% Collect every alt-svc header value and join with ", " so multiple
%% header lines are parsed as a single combined entry list per RFC 7230.
collect_altsvc_headers(Headers) ->
    Values = [to_binary(V) || {K, V} <- Headers,
                              string:lowercase(to_binary(K)) =:= <<"alt-svc">>],
    join_with_comma(Values).

join_with_comma([]) -> <<>>;
join_with_comma([V]) -> V;
join_with_comma([V | Rest]) ->
    iolist_to_binary([V, ", ", join_with_comma(Rest)]).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> iolist_to_binary(L).

%% RFC 7838 §3: a value of "clear" (case-insensitive) invalidates the
%% origin's cached alternatives. Surrounding whitespace is allowed.
is_clear_directive(Value) ->
    case string:lowercase(string:trim(Value)) of
        <<"clear">> -> true;
        _ -> false
    end.

find_h3_entry([]) ->
    none;
find_h3_entry([{Protocol, _Host, Port, MaxAge} | Rest]) ->
    case is_h3_protocol(Protocol) of
        true -> {ok, Port, MaxAge};
        false -> find_h3_entry(Rest)
    end.

%% Protocol is already normalized to h3 atom by normalize_protocol/1
is_h3_protocol(h3) -> true;
is_h3_protocol(_) -> false.

%% Parse comma-separated Alt-Svc entries
parse_entries(<<>>, Acc) ->
    lists:reverse(Acc);
parse_entries(Data, Acc) ->
    Stripped = skip_ws(Data),
    {Entry, Rest} = parse_entry(Stripped),
    %% GHSA-6cp8: ensure forward progress. A leading non-token byte
    %% (`!`, `@`, `=`, `;`, `.`, ...) makes parse_entry return
    %% {undefined, Rest=Stripped}, which would otherwise loop forever.
    %% Skip to the next ',' so at most one malformed entry is dropped.
    Rest1 = case Entry of
                undefined when Rest =:= Stripped -> seek_next_entry(Stripped);
                _ -> Rest
            end,
    case Entry of
        undefined -> parse_entries(skip_comma(Rest1), Acc);
        _ -> parse_entries(skip_comma(Rest1), [Entry | Acc])
    end.

seek_next_entry(<<>>) -> <<>>;
seek_next_entry(<<$,, _/binary>> = Data) -> Data;
seek_next_entry(<<_, Rest/binary>>) -> seek_next_entry(Rest).

%% Parse a single Alt-Svc entry: protocol="host:port"; ma=N
parse_entry(<<>>) ->
    {undefined, <<>>};
parse_entry(Data) ->
    case parse_protocol(Data) of
        {undefined, Rest} ->
            {undefined, Rest};
        {Protocol, Rest1} ->
            case skip_ws(Rest1) of
                <<"=", Rest2/binary>> ->
                    {HostPort, Rest3} = parse_quoted_or_token(skip_ws(Rest2)),
                    {Host, Port} = parse_host_port(HostPort),
                    {MaxAge, Rest4} = parse_params(Rest3),
                    {{Protocol, Host, Port, MaxAge}, Rest4};
                Rest2 ->
                    {undefined, Rest2}
            end
    end.

parse_protocol(Data) ->
    parse_token(Data, <<>>).

parse_token(<<C, Rest/binary>>, Acc) when C >= $a, C =< $z;
                                           C >= $A, C =< $Z;
                                           C >= $0, C =< $9;
                                           C =:= $-; C =:= $_ ->
    parse_token(Rest, <<Acc/binary, C>>);
parse_token(Rest, <<>>) ->
    {undefined, Rest};
parse_token(Rest, Acc) ->
    {normalize_protocol(Acc), Rest}.

normalize_protocol(<<"h3">>) -> h3;
normalize_protocol(<<"h3-", _/binary>>) -> h3;  % h3-29, h3-34, etc.
normalize_protocol(Other) -> Other.

parse_quoted_or_token(<<$", Rest/binary>>) ->
    parse_quoted(Rest, <<>>);
parse_quoted_or_token(Data) ->
    parse_token_value(Data, <<>>).

parse_quoted(<<$", Rest/binary>>, Acc) ->
    {Acc, Rest};
parse_quoted(<<$\\, C, Rest/binary>>, Acc) ->
    parse_quoted(Rest, <<Acc/binary, C>>);
parse_quoted(<<C, Rest/binary>>, Acc) ->
    parse_quoted(Rest, <<Acc/binary, C>>);
parse_quoted(<<>>, Acc) ->
    {Acc, <<>>}.

parse_token_value(<<C, Rest/binary>>, Acc) when C =/= $;, C =/= $,, C =/= $  ->
    parse_token_value(Rest, <<Acc/binary, C>>);
parse_token_value(Rest, Acc) ->
    {Acc, Rest}.

parse_host_port(<<$:, PortBin/binary>>) ->
    %% No host, just ":port"
    Port = binary_to_integer(PortBin),
    {same, Port};
parse_host_port(HostPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host, PortBin] ->
            Port = binary_to_integer(PortBin),
            {Host, Port};
        [PortBin] ->
            %% Just port number
            Port = binary_to_integer(PortBin),
            {same, Port}
    end.

parse_params(Data) ->
    parse_params(skip_ws(Data), ?DEFAULT_MAX_AGE).

parse_params(<<$;, Rest/binary>>, MaxAge) ->
    {Key, Rest2} = parse_token(skip_ws(Rest), <<>>),
    case skip_ws(Rest2) of
        <<"=", Rest3/binary>> ->
            {Value, Rest4} = parse_token_value(skip_ws(Rest3), <<>>),
            case Key of
                <<"ma">> ->
                    NewMaxAge = try binary_to_integer(Value)
                                catch error:badarg -> MaxAge end,
                    parse_params(Rest4, NewMaxAge);
                _ ->
                    parse_params(Rest4, MaxAge)
            end;
        Rest3 ->
            parse_params(Rest3, MaxAge)
    end;
parse_params(Rest, MaxAge) ->
    {MaxAge, Rest}.

skip_ws(<<$\s, Rest/binary>>) -> skip_ws(Rest);
skip_ws(<<$\t, Rest/binary>>) -> skip_ws(Rest);
skip_ws(Data) -> Data.

skip_comma(<<$,, Rest/binary>>) -> skip_ws(Rest);
skip_comma(Data) -> Data.
