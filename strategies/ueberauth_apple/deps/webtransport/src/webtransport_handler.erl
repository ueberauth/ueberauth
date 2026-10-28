%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc WebTransport handler behaviour.
%%
%% Applications implement this behaviour to handle WebTransport sessions.
%% The callbacks are invoked by the session process when events occur.
%%
%% == Example Handler ==
%% Prefer `init/3' — it receives the `handler_opts' map from the connection
%% / listener options, which is the only way to plumb things like an owner
%% pid, a request-id, or application configuration into the handler. The
%% 2-arity `init/2' is kept only as a back-compat shim and is called when
%% the handler does not export `init/3'.
%% ```
%% -module(my_wt_handler).
%% -behaviour(webtransport_handler).
%%
%% -export([init/3, handle_stream/4, handle_datagram/2,
%%          handle_stream_closed/3, terminate/2]).
%%
%% init(Session, _Req, Opts) ->
%%     Owner = maps:get(owner, Opts, undefined),
%%     {ok, #{session => Session, owner => Owner}}.
%%
%% handle_stream(Stream, Type, Data, State) ->
%%     {ok, State, [{send, Stream, <<"echo: ", Data/binary>>}]}.
%%
%% handle_datagram(Data, State) ->
%%     {ok, State}.
%%
%% handle_stream_closed(_Stream, _Reason, State) ->
%%     {ok, State}.
%%
%% terminate(_Reason, _State) ->
%%     ok.
%% '''
-module(webtransport_handler).

%% Callback declarations
-callback init(Session, Req) -> {ok, State} | {ok, State, Actions} | {error, Reason} when
    Session :: webtransport:session(),
    Req :: webtransport:request(),
    State :: term(),
    Actions :: [action()],
    Reason :: term().

-callback init(Session, Req, Opts) -> {ok, State} | {ok, State, Actions} | {error, Reason} when
    Session :: webtransport:session(),
    Req :: webtransport:request(),
    Opts :: map(),
    State :: term(),
    Actions :: [action()],
    Reason :: term().

-callback handle_stream(Stream, Type, Data, State) -> Result when
    Stream :: webtransport:stream(),
    Type :: bidi | uni,
    Data :: binary(),
    State :: term(),
    Result :: {ok, NewState} | {ok, NewState, Actions} | {stop, Reason, NewState},
    NewState :: term(),
    Actions :: [action()],
    Reason :: term().

-callback handle_stream_fin(Stream, Type, Data, State) -> Result when
    Stream :: webtransport:stream(),
    Type :: bidi | uni,
    Data :: binary(),
    State :: term(),
    Result :: {ok, NewState} | {ok, NewState, Actions} | {stop, Reason, NewState},
    NewState :: term(),
    Actions :: [action()],
    Reason :: term().

-callback handle_datagram(Data, State) -> Result when
    Data :: binary(),
    State :: term(),
    Result :: {ok, NewState} | {ok, NewState, Actions} | {stop, Reason, NewState},
    NewState :: term(),
    Actions :: [action()],
    Reason :: term().

-callback handle_stream_closed(Stream, Reason, State) -> Result when
    Stream :: webtransport:stream(),
    Reason :: normal | {reset, non_neg_integer()} | {error, term()},
    State :: term(),
    Result :: {ok, NewState} | {stop, Reason, NewState},
    NewState :: term().

-callback handle_info(Info, State) -> Result when
    Info :: term(),
    State :: term(),
    Result :: {ok, NewState} | {ok, NewState, Actions} | {stop, Reason, NewState},
    NewState :: term(),
    Actions :: [action()],
    Reason :: term().

%% Invoked when a handler-returned action fails at dispatch time
%% (e.g. `{send, UnknownStream, _}' returns `{error, unknown_stream}').
%% The default behaviour — when this callback is not exported — is to
%% log the failure via `logger:warning/2' and continue. Implement this
%% callback to observe failures, emit metrics, or stop the session.
-callback handle_action_failed(Action, Reason, State) -> Result when
    Action :: action(),
    Reason :: term(),
    State :: term(),
    Result :: {ok, NewState} | {stop, StopReason, NewState},
    NewState :: term(),
    StopReason :: term().

-callback terminate(Reason, State) -> term() when
    Reason :: normal | {error, term()} | term(),
    State :: term().

%% Optional pre-session origin / request filter. Invoked before
%% `init/3' is called on the accepted CONNECT request; returning
%% `{reject, Status, Reason}' causes the server to respond with the
%% given HTTP status (403, 404, or similar) instead of accepting the
%% session. Defaults to accept when not exported.
-callback origin_check(Headers, Opts) -> Result when
    Headers :: [{binary(), binary()}],
    Opts :: map(),
    Result :: accept | {reject, Status :: 400..599, Reason :: binary()}.

%% Optional callbacks. `init/3' is preferred; `init/2' is a back-compat
%% shim that only gets called when the handler module does not export
%% `init/3'.
-optional_callbacks([init/2, init/3, handle_stream_fin/4, handle_info/2,
                     handle_action_failed/3, origin_check/2]).

%% Types
-type action() ::
    {send, webtransport:stream(), iodata()} |
    {send, webtransport:stream(), iodata(), fin} |
    {send_datagram, iodata()} |
    {open_stream, bidi | uni} |
    {close_stream, webtransport:stream()} |
    {reset_stream, webtransport:stream(), non_neg_integer()} |
    {stop_sending, webtransport:stream(), non_neg_integer()} |
    drain_session |
    {close_session, non_neg_integer(), binary()}.

-export_type([action/0]).
