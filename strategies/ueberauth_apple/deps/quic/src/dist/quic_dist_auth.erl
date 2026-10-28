%%% -*- erlang -*-
%%%
%%% QUIC Distribution Authentication Behaviour
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Optional authentication callback invoked between the QUIC
%%% handshake and the Erlang distribution handshake.
%%%
%%% Configure via the `auth_callback' option (sys.config or
%%% `-quic_dist auth_callback Mod:Fun'):
%%%
%%% ```
%%% {quic, [{dist, [
%%%   {auth_callback, {my_app_auth, authenticate}},
%%%   {auth_handshake_timeout, 10000}
%%% ]}]}.
%%% '''
%%%
%%% The callback runs on both sides. It can refuse the connection by
%%% returning `{error, Reason}'; the connection is then closed and the
%%% dist controller is never started.
%%%
%%% @end

-module(quic_dist_auth).

%% Implementations validate the freshly-established QUIC connection
%% (peer certificate, ALPN, transport parameters, PSK identity) and
%% return `{ok, Info}' on success or `{error, Reason}' to refuse it.
%% Do not open a stream: stream ids are assigned in open order and both
%% sides assume the control stream is stream 0, so an extra stream
%% opened here shifts every stream after it. `Timeout' is the value
%% configured via `auth_handshake_timeout'; it bounds the wait for the
%% QUIC handshake, not this callback.
-callback authenticate(
    Conn :: pid(),
    Side :: client | server,
    Timeout :: timeout()
) ->
    {ok, Info :: term()} | {error, Reason :: term()}.

-export([run/4]).

%% @doc Invoke a configured callback, turning a crash or a bad return
%% into `{error, _}' so a buggy implementation cannot take down the
%% process running it. Callers must filter out `undefined' first.
-spec run(
    Callback :: quic_dist:auth_callback(),
    Conn :: pid(),
    Side :: client | server,
    Timeout :: timeout()
) ->
    {ok, term()} | {error, term()}.
run({Mod, Fun}, Conn, Side, Timeout) when is_atom(Mod), is_atom(Fun) ->
    safe_call(fun() -> Mod:Fun(Conn, Side, Timeout) end);
run(F, Conn, Side, Timeout) when is_function(F, 3) ->
    safe_call(fun() -> F(Conn, Side, Timeout) end).

%% @private
safe_call(Thunk) ->
    try Thunk() of
        {ok, _} = Ok -> Ok;
        {error, _} = Err -> Err;
        Other -> {error, {auth_callback_bad_return, Other}}
    catch
        Class:Reason:Stack ->
            {error, {auth_callback_crash, Class, Reason, Stack}}
    end.
