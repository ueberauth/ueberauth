%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% @doc RoundTripper-style middleware for hackney:request/1..5.
%%%
%%% A middleware is a fun `fun((Request, Next) -> Response)'. `Next' is
%%% itself a fun that takes a (possibly rewritten) request and returns
%%% the response. Middleware can observe, rewrite, short-circuit, or
%%% wrap the downstream call.
%%%
%%% Chains are outermost-first: `[A, B, C]' means A wraps B wraps C, so
%%% the request flows `A -> B -> C -> transport' and the response
%%% unwinds the same way. This matches Go's `http.RoundTripper', Plug,
%%% Rack and Tower-rs.
%%%
%%% Middleware wraps the user-facing `hackney:request/1..5' only. The
%%% low-level `hackney:connect/*' + `hackney:send_request/2' path is
%%% intentionally unchanged.
%%%
%%% Example — a minimal duration logger:
%%% ```
%%% Log = fun(Req, Next) ->
%%%     T0 = erlang:monotonic_time(millisecond),
%%%     Resp = Next(Req),
%%%     logger:info("~p ~s -> ~pms",
%%%                 [maps:get(method, Req),
%%%                  hackney_url:unparse_url(maps:get(url, Req)),
%%%                  erlang:monotonic_time(millisecond) - T0]),
%%%     Resp
%%% end,
%%% hackney:get(URL, [], <<>>, [{middleware, [Log]}]).
%%% '''
-module(hackney_middleware).

-export([apply_chain/3,
         resolve_chain/1]).

-export_type([request/0, response/0, next/0, middleware/0]).

-include("hackney_lib.hrl").

-type request() :: #{method  := atom() | binary(),
                     url     := #hackney_url{},
                     headers := [{binary(), binary()}],
                     body    := term(),
                     options := [term()]}.

-type response() :: {ok, integer(), list(), binary()}
                  | {ok, integer(), list()}
                  | {ok, pid()}
                  | {error, term()}.

-type next()       :: fun((request()) -> response()).
-type middleware() :: fun((request(), next()) -> response()).

%% @doc Apply `Chain' (outermost-first) around `Terminal'.
%%
%% The returned response is whatever the outermost middleware produces;
%% crashes propagate to the caller.
-spec apply_chain([middleware()], request(), next()) -> response().
apply_chain([], Req, Terminal) ->
    Terminal(Req);
apply_chain(Chain, Req, Terminal) when is_list(Chain) ->
    Next = build(Chain, Terminal),
    Next(Req).

%% @doc Pick the middleware chain for a request.
%%
%% Per-request `{middleware, List}' in `Options' replaces the global
%% `application:get_env(hackney, middleware)' value. No implicit merge.
-spec resolve_chain([term()]) -> [middleware()].
resolve_chain(Options) ->
    case lists:keyfind(middleware, 1, Options) of
        {middleware, List} when is_list(List) ->
            List;
        false ->
            case application:get_env(hackney, middleware) of
                {ok, List} when is_list(List) -> List;
                _ -> []
            end
    end.

%% ============================================================================
%% Internal
%% ============================================================================

%% Fold from the right so the head of Chain becomes the outermost call.
build(Chain, Terminal) ->
    lists:foldr(
      fun(M, Next) when is_function(M, 2) ->
              fun(R) -> M(R, Next) end
      end,
      Terminal,
      Chain).
