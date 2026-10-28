%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2012-2024, Benoît Chesneau <benoitc@e-engura.org>

%% @doc HTTP/1.x keepalive semantics.
%%
%% Single source of truth for deciding whether an HTTP/1.x connection must be
%% closed (not reused) after a response, per RFC 7230. The `Connection' header
%% is a list-valued, hop-by-hop field (RFC 7230 3.2.2, 6.1): a recipient may get
%% it as several header lines or as one comma-joined value, and both are
%% equivalent. It is forbidden in HTTP/2 and HTTP/3, so these rules apply only to
%% HTTP/1.x; multiplexed conns are never pooled in `available'.
%%
%% Every function tolerates undefined or malformed header objects so a bad header
%% can never crash the keepalive decision.
-module(hackney_keepalive).

-export([should_close/3,
         request_closes/1,
         connection_tokens/1]).

%% @doc Whether a parsed HTTP/1.x response means the connection must close.
%%
%% The caller (hackney_conn:should_close_connection/1) guards the "no response
%% observed yet" case; here `Version'/`RespHeaders' describe a response that was
%% actually parsed. Order matters: an explicit `close' wins over version default.
-spec should_close(Version, RespHeaders, RequestClose) -> boolean() when
      Version :: {integer(), integer()} | undefined,
      RespHeaders :: term(),
      RequestClose :: boolean().
should_close(_Version, _RespHeaders, true) ->
    %% We asked the server to close (request carried Connection: close).
    true;
should_close(Version, RespHeaders, false) ->
    Tokens = connection_tokens(RespHeaders),
    case lists:member(<<"close">>, Tokens) of
        true ->
            true;
        false ->
            case Version of
                {1, 1} ->
                    %% HTTP/1.1 default is keep-alive; an absent Connection header
                    %% stays persistent and poolable.
                    false;
                {1, 0} ->
                    %% HTTP/1.0 default is close unless it opts into keep-alive.
                    not lists:member(<<"keep-alive">>, Tokens);
                _ ->
                    %% Unknown version on a parsed response: close on the safe side.
                    true
            end
    end.

%% @doc Whether request headers carry `Connection: close'.
-spec request_closes(term()) -> boolean().
request_closes(ReqHeaders) ->
    lists:member(<<"close">>, connection_tokens(ReqHeaders)).

%% @doc Lower-cased, trimmed tokens from every `Connection' header.
%%
%% Defensive at each layer: an undefined or malformed header object yields `[]',
%% and a value that does not convert to a binary is skipped rather than crashing.
-spec connection_tokens(term()) -> [binary()].
connection_tokens(undefined) ->
    [];
connection_tokens(Headers) ->
    Values = try hackney_headers:lookup(<<"connection">>, Headers)
             catch _:_ -> []
             end,
    lists:flatmap(fun({_Key, Value}) -> value_tokens(Value) end, Values).

%% @private
value_tokens(Value) ->
    case (try hackney_bstr:to_binary(Value) catch _:_ -> error end) of
        error ->
            [];
        Bin ->
            Lower = hackney_bstr:to_lower(Bin),
            Parts = binary:split(Lower, <<",">>, [global]),
            Trimmed = [hackney_bstr:trim(P) || P <- Parts],
            [T || T <- Trimmed, T =/= <<>>]
    end.
