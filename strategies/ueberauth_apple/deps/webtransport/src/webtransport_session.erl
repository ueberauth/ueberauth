%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc WebTransport session state machine.
%%
%% This module implements a gen_statem that manages a WebTransport session's
%% lifecycle, including stream management, flow control, and handler callbacks.
%%
%% The session supports both HTTP/2 and HTTP/3 transports, using the
%% appropriate transport module for capsule/stream handling.
%%
-module(webtransport_session).
-behaviour(gen_statem).

-include("webtransport.hrl").

%% API
-export([start_link/4, start_link/5]).
-export([send/4, send_datagram/2]).
-export([open_stream/2, close_stream/2]).
-export([reset_stream/3, stop_sending/3]).
-export([drain/1, close/3]).
-export([get_info/1]).
-export([early_data_accepted/1]).

%% Internal API (called by transport layers)
-export([handle_capsule/2, handle_stream_data/4, handle_datagram_data/2]).
-export([handle_stream_opened/3, handle_stream_closed/3]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3]).
-export([connecting/3, open/3, draining/3]).

-record(data, {
    transport :: h2 | h3,
    transport_state :: term(),
    handler :: module(),
    handler_state :: term(),
    request :: map(),
    %% Stream management
    streams = #{} :: #{non_neg_integer() => webtransport_stream:stream()},
    next_bidi_id :: non_neg_integer(),
    next_uni_id :: non_neg_integer(),
    %% Flow control
    local_max_data :: non_neg_integer(),
    remote_max_data :: non_neg_integer(),
    local_max_streams_bidi :: non_neg_integer(),
    local_max_streams_uni :: non_neg_integer(),
    remote_max_streams_bidi :: non_neg_integer(),
    remote_max_streams_uni :: non_neg_integer(),
    bytes_sent = 0 :: non_neg_integer(),
    bytes_received = 0 :: non_neg_integer(),
    %% Size of the session receive window we advertise and replenish (h2).
    session_window :: non_neg_integer(),
    %% Flags
    is_server :: boolean(),
    close_info :: undefined | {non_neg_integer(), binary()}
}).

-type session() :: pid().
-type stream_ref() :: non_neg_integer().
-type request() :: #{
    path := binary(),
    authority := binary(),
    headers => [{binary(), binary()}]
}.

-export_type([session/0, stream_ref/0, request/0]).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Start a session with default gen_statem options.
-spec start_link(h2 | h3, term(), module(), map()) -> {ok, pid()} | {error, term()}.
start_link(Transport, TransportState, Handler, Opts) ->
    start_link(Transport, TransportState, Handler, Opts, []).

%% @doc Start a session linked to the caller, with explicit gen_statem start options.
-spec start_link(h2 | h3, term(), module(), map(), list()) -> {ok, pid()} | {error, term()}.
start_link(Transport, TransportState, Handler, Opts, StartOpts) ->
    gen_statem:start_link(?MODULE, {Transport, TransportState, Handler, Opts}, StartOpts).

%% @doc Send data on a stream. Set Fin to true to half-close the local side.
-spec send(session(), stream_ref(), iodata(), boolean()) -> ok | {error, term()}.
send(Session, StreamId, Data, Fin) ->
    gen_statem:call(Session, {send, StreamId, iolist_to_binary(Data), Fin}).

%% @doc Send an unreliable datagram on the session.
-spec send_datagram(session(), iodata()) -> ok | {error, term()}.
send_datagram(Session, Data) ->
    gen_statem:call(Session, {send_datagram, iolist_to_binary(Data)}).

%% @doc Open a new locally-initiated stream of the given type.
-spec open_stream(session(), bidi | uni) -> {ok, stream_ref()} | {error, term()}.
open_stream(Session, Type) ->
    gen_statem:call(Session, {open_stream, Type}).

%% @doc Gracefully close a stream by sending FIN.
-spec close_stream(session(), stream_ref()) -> ok | {error, term()}.
close_stream(Session, StreamId) ->
    gen_statem:call(Session, {close_stream, StreamId}).

%% @doc Abruptly reset a stream with the given application error code.
-spec reset_stream(session(), stream_ref(), non_neg_integer()) -> ok | {error, term()}.
reset_stream(Session, StreamId, ErrorCode) ->
    gen_statem:call(Session, {reset_stream, StreamId, ErrorCode}).

%% @doc Ask the peer to stop sending on a stream with the given error code.
-spec stop_sending(session(), stream_ref(), non_neg_integer()) -> ok | {error, term()}.
stop_sending(Session, StreamId, ErrorCode) ->
    gen_statem:call(Session, {stop_sending, StreamId, ErrorCode}).

%% @doc Initiate a graceful drain: no new streams, existing ones finish.
-spec drain(session()) -> ok.
drain(Session) ->
    gen_statem:cast(Session, drain).

%% @doc Close the session immediately with the given error code and reason.
-spec close(session(), non_neg_integer(), binary()) -> ok.
close(Session, ErrorCode, Reason) ->
    gen_statem:cast(Session, {close, ErrorCode, Reason}).

%% @doc Return a map of session metrics: stream count, flow control limits, bytes sent/received.
-spec get_info(session()) -> {ok, map()} | {error, term()}.
get_info(Session) ->
    gen_statem:call(Session, get_info).

%% @doc Report whether the underlying connection negotiated 0-RTT early data.
%% Returns `true'/`false'/`unknown' for h3 (per RFC 9001 §4.6), or
%% `not_supported' for h2 which has no QUIC 0-RTT.
-spec early_data_accepted(session()) -> boolean() | unknown | not_supported.
early_data_accepted(Session) ->
    gen_statem:call(Session, early_data_accepted).

%% Internal API

%% @doc Deliver a decoded capsule to the session (called by transport layers).
-spec handle_capsule(session(), term()) -> ok.
handle_capsule(Session, Capsule) ->
    gen_statem:cast(Session, {capsule, Capsule}).

%% @doc Deliver inbound stream data to the session (called by transport layers).
-spec handle_stream_data(session(), stream_ref(), binary(), boolean()) -> ok.
handle_stream_data(Session, StreamId, Data, Fin) ->
    gen_statem:cast(Session, {stream_data, StreamId, Data, Fin}).

%% @doc Deliver an inbound datagram payload to the session.
-spec handle_datagram_data(session(), binary()) -> ok.
handle_datagram_data(Session, Data) ->
    gen_statem:cast(Session, {datagram_data, Data}).

%% @doc Notify the session that a peer-initiated stream was opened.
-spec handle_stream_opened(session(), stream_ref(), bidi | uni) -> ok.
handle_stream_opened(Session, StreamId, Type) ->
    gen_statem:cast(Session, {stream_opened, StreamId, Type}).

%% @doc Notify the session that a stream was closed or reset by the peer.
-spec handle_stream_closed(session(), stream_ref(), term()) -> ok.
handle_stream_closed(Session, StreamId, Reason) ->
    gen_statem:cast(Session, {stream_closed, StreamId, Reason}).

%% ============================================================================
%% gen_statem callbacks
%% ============================================================================

callback_mode() -> state_functions.

init({Transport, TransportState, Handler, Opts}) ->
    IsServer = maps:get(is_server, Opts, true),
    Request = maps:get(request, Opts, #{}),
    HandlerOpts = maps:get(handler_opts, Opts, #{}),

    %% Stream ID assignment depends on role
    {NextBidi, NextUni} = case IsServer of
        true -> {1, 3};   %% Server: odd IDs
        false -> {0, 2}   %% Client: even IDs
    end,

    Data = #data{
        transport = Transport,
        transport_state = TransportState,
        handler = Handler,
        request = Request,
        is_server = IsServer,
        next_bidi_id = NextBidi,
        next_uni_id = NextUni,
        local_max_data = maps:get(max_data, Opts, ?DEFAULT_MAX_DATA),
        remote_max_data = maps:get(max_data, Opts, ?DEFAULT_MAX_DATA),
        session_window = maps:get(max_data, Opts, ?DEFAULT_MAX_DATA),
        local_max_streams_bidi = maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        local_max_streams_uni = maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI),
        remote_max_streams_bidi = maps:get(max_streams_bidi, Opts, ?DEFAULT_MAX_STREAMS_BIDI),
        remote_max_streams_uni = maps:get(max_streams_uni, Opts, ?DEFAULT_MAX_STREAMS_UNI)
    },

    %% Initialize handler. `code:ensure_loaded/1' is required because
    %% `erlang:function_exported/3' returns false for modules that haven't
    %% been loaded yet — which would silently demote init/3 callers to
    %% init/2 and throw handler_opts away.
    %%
    %% Preference order: `init/3' > `init/2'. Handlers that export neither
    %% are a configuration error and we stop immediately with a clear
    %% reason so the user sees it in the crash log.
    InitResult =
        case code:ensure_loaded(Handler) of
            {error, LoadReason} ->
                {error, {handler_not_loaded, Handler, LoadReason}};
            {module, Handler} ->
                case erlang:function_exported(Handler, init, 3) of
                    true ->
                        Handler:init(self(), Request, HandlerOpts);
                    false ->
                        case erlang:function_exported(Handler, init, 2) of
                            true -> Handler:init(self(), Request);
                            false -> {error, {no_init_callback, Handler}}
                        end
                end
        end,
    case InitResult of
        {ok, HandlerState} ->
            {ok, open, Data#data{handler_state = HandlerState}};
        {ok, HandlerState, Actions} ->
            {Data1, Transition} = handle_actions(Actions, Data#data{handler_state = HandlerState}),
            init_apply_transition(Transition, Data1);
        {error, Reason} ->
            {stop, Reason}
    end.

init_apply_transition(continue, Data) ->
    {ok, open, Data};
init_apply_transition(drain, Data) ->
    {ok, draining, Data};
init_apply_transition({stop, Reason}, _Data) ->
    {stop, Reason}.

%% Open state - normal operation
open({call, From}, {send, StreamId, Data, Fin}, #data{} = StateData) ->
    case do_send(StreamId, Data, Fin, StateData) of
        {ok, StateData1} ->
            {keep_state, StateData1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, StateData, [{reply, From, {error, Reason}}]}
    end;

open({call, From}, {send_datagram, Data}, #data{} = StateData) ->
    case do_send_datagram(Data, StateData) of
        {ok, StateData1} ->
            {keep_state, StateData1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, StateData, [{reply, From, {error, Reason}}]}
    end;

open({call, From}, {open_stream, Type}, #data{} = StateData) ->
    case do_open_stream(Type, StateData) of
        {ok, StreamId, StateData1} ->
            {keep_state, StateData1, [{reply, From, {ok, StreamId}}]};
        {error, Reason} ->
            {keep_state, StateData, [{reply, From, {error, Reason}}]}
    end;

open({call, From}, {close_stream, StreamId}, #data{} = StateData) ->
    case do_close_stream(StreamId, StateData) of
        {ok, StateData1} ->
            {keep_state, StateData1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, StateData, [{reply, From, {error, Reason}}]}
    end;

open({call, From}, {reset_stream, StreamId, ErrorCode}, #data{} = StateData) ->
    case do_reset_stream(StreamId, ErrorCode, StateData) of
        {ok, StateData1} ->
            {keep_state, StateData1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, StateData, [{reply, From, {error, Reason}}]}
    end;

open({call, From}, {stop_sending, StreamId, ErrorCode}, #data{} = StateData) ->
    case do_stop_sending(StreamId, ErrorCode, StateData) of
        {ok, StateData1} ->
            {keep_state, StateData1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, StateData, [{reply, From, {error, Reason}}]}
    end;

open({call, From}, get_info, StateData) ->
    Info = build_info(StateData),
    {keep_state, StateData, [{reply, From, {ok, Info}}]};

open({call, From}, early_data_accepted, StateData) ->
    {keep_state, StateData, [{reply, From, do_early_data_accepted(StateData)}]};

open(cast, {capsule, Capsule}, StateData) ->
    case handle_incoming_capsule(Capsule, StateData) of
        {session_error, Code, Reason} ->
            do_close(Code, Reason, StateData),
            {stop, {shutdown, {session_error, Code}},
             StateData#data{close_info = {Code, Reason}}};
        StateData1 ->
            apply_capsule_transition(Capsule, StateData1)
    end;

open(cast, {stream_data, StreamId, Data, Fin}, StateData) ->
    {StateData1, Transition} = handle_incoming_stream_data(StreamId, Data, Fin, StateData),
    open_apply_transition(Transition, StateData1);

open(cast, {datagram_data, Data}, StateData) ->
    {StateData1, Transition} = handle_incoming_datagram(Data, StateData),
    open_apply_transition(Transition, StateData1);

open(cast, {stream_opened, StreamId, Type}, StateData) ->
    StateData1 = handle_remote_stream_opened(StreamId, Type, StateData),
    {keep_state, StateData1};

open(cast, {stream_closed, StreamId, Reason}, StateData) ->
    {StateData1, Transition} = handle_remote_stream_closed(StreamId, Reason, StateData),
    open_apply_transition(Transition, StateData1);

open(cast, drain, StateData) ->
    do_drain(StateData),
    {next_state, draining, StateData};

open(cast, {close, ErrorCode, Reason}, StateData) ->
    do_close(ErrorCode, Reason, StateData),
    {stop, normal, StateData#data{close_info = {ErrorCode, Reason}}};

%% On h3 the CONNECT stream is registered with quic_h3:set_stream_handler,
%% so session-management capsules (CLOSE_SESSION, DRAIN_SESSION) arrive as
%% raw bytes in `{quic_h3, _, {data, StreamId, Data, Fin}}'. Decode and
%% dispatch them through the same handle_incoming_capsule path as h2.
open(info, {quic_h3, _Conn, {data, StreamId, Data, Fin}},
     #data{transport = h3, transport_state = H3State} = StateData) ->
    %% draft-15 §5: session-management capsules ride the CONNECT stream.
    %% Decode and dispatch like the h2 capsule path; non-CONNECT streams
    %% are handled by the h3 router and never reach us here.
    case webtransport_h3:session_id(H3State) of
        StreamId ->
            case wt_h3_capsule:decode_all(Data) of
                {ok, Capsules, _} ->
                    Result = apply_capsule_list(Capsules, StateData),
                    %% draft-14 §3.4: "A WebTransport session is terminated
                    %% when either endpoint closes the stream". If the peer
                    %% FINs the CONNECT stream without sending CLOSE_SESSION,
                    %% treat as session close.
                    case {Fin, Result} of
                        {true, {keep_state, SD}} ->
                            reset_all_streams(?WT_SESSION_GONE, SD),
                            {stop, normal, SD#data{close_info = {0, <<"peer closed CONNECT">>}}};
                        _ ->
                            Result
                    end;
                {error, Reason} ->
                    %% Malformed capsule framing is a protocol error.
                    logger:warning("h3 CONNECT capsule decode error: ~p", [Reason]),
                    do_close(?WT_REQUIREMENTS_NOT_MET, <<"malformed capsule">>, StateData),
                    {stop, {shutdown, {session_error, ?WT_REQUIREMENTS_NOT_MET}},
                     StateData#data{close_info = {?WT_REQUIREMENTS_NOT_MET,
                                                  <<"malformed capsule">>}}}
            end;
        _ ->
            {keep_state, StateData}
    end;

open(info, Msg, #data{handler = Handler, handler_state = HState} = StateData) ->
    case erlang:function_exported(Handler, handle_info, 2) of
        true ->
            case Handler:handle_info(Msg, HState) of
                {ok, HState1} ->
                    {keep_state, StateData#data{handler_state = HState1}};
                {ok, HState1, Actions} ->
                    {StateData1, Transition} = handle_actions(Actions, StateData#data{handler_state = HState1}),
                    open_apply_transition(Transition, StateData1);
                {stop, Reason, HState1} ->
                    {stop, Reason, StateData#data{handler_state = HState1}}
            end;
        false ->
            {keep_state, StateData}
    end.

apply_capsule_list([], StateData) ->
    {keep_state, StateData};
apply_capsule_list([Capsule | Rest], StateData) ->
    case handle_incoming_capsule(Capsule, StateData) of
        {session_error, Code, Reason} ->
            do_close(Code, Reason, StateData),
            {stop, {shutdown, {session_error, Code}},
             StateData#data{close_info = {Code, Reason}}};
        StateData1 ->
            case apply_capsule_transition(Capsule, StateData1) of
                {keep_state, StateData2} ->
                    apply_capsule_list(Rest, StateData2);
                Stop ->
                    Stop
            end
    end.

%% Translate a `handle_actions' transition into a gen_statem return while
%% in the `open' state.
open_apply_transition(continue, StateData) ->
    {keep_state, StateData};
open_apply_transition(drain, StateData) ->
    {next_state, draining, StateData};
open_apply_transition({stop, Reason}, StateData) ->
    {stop, Reason, StateData}.

%% Peer-sent control capsules influence the state machine.
%% draft-14 §4.6 / draft-15 §5: CLOSE_SESSION is terminal.
%% draft-14 §4.7 / draft-15 §5.1: DRAIN_SESSION moves us to draining.
apply_capsule_transition({close_session, _Code, _Reason}, StateData) ->
    %% Reset all live streams with WT_SESSION_GONE before stopping.
    reset_all_streams(?WT_SESSION_GONE, StateData),
    {stop, normal, StateData};
apply_capsule_transition({drain_session}, StateData) ->
    {next_state, draining, StateData};
apply_capsule_transition(_Capsule, StateData) ->
    {keep_state, StateData}.

%% Connecting state (for client sessions)
connecting({call, From}, _, StateData) ->
    {keep_state, StateData, [{reply, From, {error, not_connected}}]};

connecting(cast, connected, StateData) ->
    {next_state, open, StateData};

connecting(cast, {connection_error, Reason}, StateData) ->
    {stop, {connection_error, Reason}, StateData}.

%% Draining state - no new streams, waiting for existing to finish
draining({call, From}, {send, StreamId, Data, Fin}, StateData) ->
    %% Allow sending on existing streams during drain
    case do_send(StreamId, Data, Fin, StateData) of
        {ok, StateData1} ->
            maybe_stop_if_drained(StateData1, [{reply, From, ok}]);
        {error, Reason} ->
            {keep_state, StateData, [{reply, From, {error, Reason}}]}
    end;

draining({call, From}, {open_stream, _Type}, StateData) ->
    {keep_state, StateData, [{reply, From, {error, session_draining}}]};

draining({call, From}, get_info, StateData) ->
    Info = build_info(StateData),
    {keep_state, StateData, [{reply, From, {ok, Info}}]};

draining({call, From}, early_data_accepted, StateData) ->
    {keep_state, StateData, [{reply, From, do_early_data_accepted(StateData)}]};

draining({call, From}, _, StateData) ->
    {keep_state, StateData, [{reply, From, {error, session_draining}}]};

draining(cast, {stream_data, StreamId, Data, Fin}, StateData) ->
    {StateData1, Transition} = handle_incoming_stream_data(StreamId, Data, Fin, StateData),
    draining_apply_transition(Transition, StateData1);

draining(cast, {stream_closed, StreamId, Reason}, StateData) ->
    {StateData1, Transition} = handle_remote_stream_closed(StreamId, Reason, StateData),
    draining_apply_transition(Transition, StateData1);

draining(cast, _, StateData) ->
    maybe_stop_if_drained(StateData, []).

%% In the draining state we never go backwards: drain stays drain,
%% a `stop' transition takes immediate effect, and a `continue' just
%% re-evaluates whether all streams are closed.
draining_apply_transition({stop, Reason}, StateData) ->
    {stop, Reason, StateData};
draining_apply_transition(_Transition, StateData) ->
    maybe_stop_if_drained(StateData, []).

terminate(Reason, _State, #data{handler = Handler, handler_state = HState,
                                close_info = CloseInfo,
                                transport = Transport,
                                transport_state = TransportState}) ->
    %% Close the underlying connection gracefully so quic_h3_connection
    %% enters its `closing' state and exits with `normal' instead of
    %% `quic_closed'. Without this, the QUIC connection drop races with
    %% our process exit and produces noisy crash reports.
    close_transport(Transport, TransportState),
    %% Surface close_info to the handler so it can distinguish a clean
    %% local/remote close (with error code + reason) from an abnormal exit.
    Handler:terminate(augment_reason(Reason, CloseInfo), HState),
    ok.

close_transport(h3, H3State) ->
    %% Tell the h3_connection to enter its `closing' state (which exits
    %% with `normal'). Without this the QUIC connection drop can race
    %% our exit. On the server side the peer may have already closed
    %% the QUIC connection before this cast arrives; the upstream fix
    %% (quic_h3_connection using `{shutdown, quic_closed}' instead of
    %% bare `quic_closed') eliminates the remaining noise.
    try quic_h3:close(webtransport_h3:h3_conn(H3State)) catch _:_ -> ok end;
close_transport(h2, _H2State) ->
    ok.

augment_reason(Reason, undefined) -> Reason;
augment_reason(normal, {Code, Msg}) -> {closed, Code, Msg};
augment_reason(Reason, {Code, Msg}) -> {Reason, {closed, Code, Msg}}.

%% ============================================================================
%% Internal functions
%% ============================================================================

%% Per-stream WebTransport windows only exist on h2 (draft-14 §6). On h3 the
%% QUIC transport does flow control, so the WT-level window is unbounded
%% there; applying the h2 default on h3 used to cut every payload at 256 KiB.
-define(H3_STREAM_WINDOW, 1 bsl 62).

-spec initial_stream_window(#data{}) -> non_neg_integer().
initial_stream_window(#data{transport = h3}) -> ?H3_STREAM_WINDOW;
initial_stream_window(#data{transport = h2}) -> ?DEFAULT_MAX_STREAM_DATA.

do_send(StreamId, Data, Fin, #data{streams = Streams, transport = Transport} = StateData) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            case Transport of
                h3 -> send_h3(StreamId, Data, Fin, Stream, StateData);
                h2 -> send_h2(StreamId, Data, Fin, Stream, StateData)
            end;
        error ->
            {error, unknown_stream}
    end.

%% h3: hand the whole payload to QUIC; it blocks or buffers as its own
%% flow control dictates.
send_h3(StreamId, Data, Fin, Stream,
        #data{streams = Streams, bytes_sent = SessSent} = StateData) ->
    case webtransport_stream:send(Stream, Data) of
        {ok, ToSend, Stream1} ->
            case transport_send(StreamId, ToSend, Fin, StateData) of
                ok ->
                    Stream2 = maybe_close_local(Fin, Stream1),
                    {ok, StateData#data{streams = Streams#{StreamId => Stream2},
                                        bytes_sent = SessSent + byte_size(ToSend)}};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% h2: honour the session and per-stream windows. Bytes that do not fit are
%% queued on the stream, in order, and go out from flush_h2_streams/1 when
%% the peer raises a window. A FIN is held back until the queue drains, so
%% the peer never sees FIN before the last byte.
send_h2(StreamId, Data, Fin, Stream, #data{streams = Streams} = StateData) ->
    case webtransport_stream:send_buffer(Stream) of
        <<>> ->
            push_h2(StreamId, Data, Fin, Stream, StateData);
        _ ->
            %% Earlier bytes are still waiting for credit: queue behind them.
            case webtransport_stream:is_writable(Stream) andalso
                 not webtransport_stream:fin_pending(Stream) of
                true ->
                    Stream1 = webtransport_stream:buffer_send(Stream, Data),
                    Stream2 = maybe_set_fin_pending(Fin, Stream1),
                    {ok, StateData#data{streams = Streams#{StreamId => Stream2}}};
                false ->
                    {error, stream_fin_sent}
            end
    end.

push_h2(StreamId, Data, Fin, Stream,
        #data{streams = Streams, bytes_sent = SessSent,
              remote_max_data = SessMax} = StateData) ->
    SessAvail = max(SessMax - SessSent, 0),
    {Now, Later} = split_binary_at(Data, SessAvail),
    case webtransport_stream:send(Stream, Now) of
        {ok, ToSend, Stream1} ->
            Stream2 = webtransport_stream:buffer_send(Stream1, Later),
            Drained = webtransport_stream:send_buffer(Stream2) =:= <<>>,
            FinNow = Fin andalso Drained,
            Stream3 = maybe_set_fin_pending(Fin andalso not Drained, Stream2),
            case ToSend =:= <<>> andalso not FinNow of
                true ->
                    %% Nothing fits right now; tell the peer we are blocked.
                    StateData1 = StateData#data{streams = Streams#{StreamId => Stream3}},
                    emit_blocked(StreamId, Stream3, SessAvail, StateData1),
                    {ok, StateData1};
                false ->
                    case transport_send(StreamId, ToSend, FinNow, StateData) of
                        ok ->
                            Stream4 = maybe_close_local(FinNow, Stream3),
                            StateData1 = StateData#data{
                                streams = Streams#{StreamId => Stream4},
                                bytes_sent = SessSent + byte_size(ToSend)},
                            case Drained of
                                true -> ok;
                                false -> emit_blocked(StreamId, Stream4,
                                                      SessAvail - byte_size(ToSend),
                                                      StateData1)
                            end,
                            {ok, StateData1};
                        {error, _} = Err ->
                            Err
                    end
            end;
        {error, _} = Err ->
            Err
    end.

%% Retry queued bytes on every h2 stream after the peer raised a window.
-spec flush_h2_streams(#data{}) -> #data{}.
flush_h2_streams(#data{transport = h2, streams = Streams} = StateData) ->
    maps:fold(fun flush_h2_stream/3, StateData, Streams);
flush_h2_streams(StateData) ->
    StateData.

flush_h2_stream(StreamId, Stream, #data{streams = Streams} = StateData) ->
    case webtransport_stream:send_buffer(Stream) of
        <<>> ->
            StateData;
        Buf ->
            {_, Stream0} = webtransport_stream:flush_send_buffer(Stream),
            Fin = webtransport_stream:fin_pending(Stream0),
            Stream1 = webtransport_stream:clear_fin_pending(Stream0),
            StateData1 = StateData#data{streams = Streams#{StreamId => Stream1}},
            case push_h2(StreamId, Buf, Fin, Stream1, StateData1) of
                {ok, StateData2} ->
                    StateData2;
                {error, Reason} ->
                    logger:warning("webtransport: flush of stream ~p failed: ~p",
                                   [StreamId, Reason]),
                    StateData
            end
    end.

maybe_close_local(true, Stream) ->
    {ok, S} = webtransport_stream:close_local(Stream),
    S;
maybe_close_local(false, Stream) ->
    Stream.

maybe_set_fin_pending(true, Stream) -> webtransport_stream:set_fin_pending(Stream);
maybe_set_fin_pending(false, Stream) -> Stream.

split_binary_at(Bin, At) when At >= byte_size(Bin) ->
    {Bin, <<>>};
split_binary_at(Bin, At) ->
    <<Now:At/binary, Later/binary>> = Bin,
    {Now, Later}.

emit_blocked(StreamId, Stream, SessAvail, StateData) ->
    case SessAvail =< 0 of
        true -> _ = emit_data_blocked(StateData, StateData#data.remote_max_data);
        false -> ok
    end,
    maybe_emit_stream_data_blocked(h2, StreamId, Stream, StateData).

%% h2 peers learn about local backpressure via DATA_BLOCKED / STREAM_DATA_BLOCKED
%% capsules. h3 uses native QUIC flow control; the drafts don't define these
%% capsules for h3, so we only emit on h2.
emit_data_blocked(#data{transport = h2, transport_state = H2State}, Limit) ->
    webtransport_h2:send_capsule(H2State, wt_h2_capsule:data_blocked(Limit));
emit_data_blocked(_StateData, _Limit) ->
    ok.

maybe_emit_stream_data_blocked(h2, StreamId, Stream, #data{transport_state = H2State}) ->
    Window = webtransport_stream:send_window(Stream),
    Sent = webtransport_stream:bytes_sent(Stream),
    case Window - Sent of
        0 ->
            webtransport_h2:send_capsule(H2State,
                                         wt_h2_capsule:stream_data_blocked(StreamId, Window));
        _ ->
            ok
    end.

do_send_datagram(Data, StateData) ->
    case transport_send_datagram(Data, StateData) of
        ok -> {ok, StateData};
        {error, _} = Err -> Err
    end.

do_open_stream(bidi, #data{streams = Streams, next_bidi_id = NextId,
                           remote_max_streams_bidi = MaxStreams} = StateData) ->
    CurrentCount = count_streams(bidi, Streams),
    case CurrentCount < MaxStreams of
        true ->
            case transport_open_stream(NextId, bidi, StateData) of
                {ok, StreamId} ->
                    Stream = webtransport_stream:new(StreamId, bidi, initial_stream_window(StateData)),
                    Streams1 = Streams#{StreamId => Stream},
                    {ok, StreamId, StateData#data{
                        streams = Streams1,
                        next_bidi_id = NextId + 4
                    }};
                {error, _} = Err ->
                    Err
            end;
        false ->
            {error, stream_limit_reached}
    end;

do_open_stream(uni, #data{streams = Streams, next_uni_id = NextId,
                          remote_max_streams_uni = MaxStreams} = StateData) ->
    CurrentCount = count_streams(uni, Streams),
    case CurrentCount < MaxStreams of
        true ->
            case transport_open_stream(NextId, uni, StateData) of
                {ok, StreamId} ->
                    Stream = webtransport_stream:new(StreamId, uni, initial_stream_window(StateData)),
                    Streams1 = Streams#{StreamId => Stream},
                    {ok, StreamId, StateData#data{
                        streams = Streams1,
                        next_uni_id = NextId + 4
                    }};
                {error, _} = Err ->
                    Err
            end;
        false ->
            {error, stream_limit_reached}
    end.

do_close_stream(StreamId, #data{streams = Streams} = StateData) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            case webtransport_stream:close_local(Stream) of
                {ok, Stream1} ->
                    transport_send(StreamId, <<>>, true, StateData),
                    {ok, StateData#data{streams = Streams#{StreamId => Stream1}}};
                {error, _} = Err ->
                    Err
            end;
        error ->
            {error, unknown_stream}
    end.

do_reset_stream(StreamId, ErrorCode, #data{streams = Streams} = StateData) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Stream1 = webtransport_stream:reset(Stream, ErrorCode),
            transport_reset_stream(StreamId, ErrorCode, StateData),
            {ok, StateData#data{streams = Streams#{StreamId => Stream1}}};
        error ->
            {error, unknown_stream}
    end.

do_stop_sending(StreamId, ErrorCode, #data{streams = Streams} = StateData) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Stream1 = webtransport_stream:stop_sending(Stream, ErrorCode),
            transport_stop_sending(StreamId, ErrorCode, StateData),
            {ok, StateData#data{streams = Streams#{StreamId => Stream1}}};
        error ->
            {error, unknown_stream}
    end.

do_drain(#data{transport = h2, transport_state = H2State}) ->
    webtransport_h2:drain_session(H2State);
do_drain(#data{transport = h3, transport_state = H3State}) ->
    webtransport_h3:drain_session(H3State).

do_close(ErrorCode, Reason, StateData) ->
    %% Reset all live streams with WT_SESSION_GONE, then send CLOSE_SESSION.
    %% The transport may already be gone (connection lost, peer closed
    %% first); closing is then a no-op, not a crash of the session.
    reset_all_streams(?WT_SESSION_GONE, StateData),
    transport_call(fun() ->
        case StateData of
            #data{transport = h2, transport_state = H2State} ->
                webtransport_h2:close_session(H2State, ErrorCode, Reason);
            #data{transport = h3, transport_state = H3State} ->
                webtransport_h3:close_session(H3State, ErrorCode, Reason)
        end
    end).

reset_all_streams(ErrorCode, #data{streams = Streams} = StateData) ->
    maps:foreach(fun(StreamId, Stream) ->
        case webtransport_stream:is_open(Stream) of
            true ->
                transport_call(fun() ->
                    transport_reset_stream(StreamId, ErrorCode, StateData)
                end);
            false ->
                ok
        end
    end, Streams).

%% A call into a transport process that has already exited.
transport_call(Fun) ->
    try
        Fun()
    catch
        exit:{noproc, _} -> {error, closed};
        exit:{normal, _} -> {error, closed};
        exit:{shutdown, _} -> {error, closed};
        exit:{{shutdown, _}, _} -> {error, closed}
    end.

handle_incoming_capsule({max_data, Limit}, #data{remote_max_data = Prev} = StateData) ->
    %% Drafts: MUST close session with WT_FLOW_CONTROL_ERROR on decrease.
    case Limit < Prev of
        true ->
            {session_error, ?WT_FLOW_CONTROL_ERROR, <<"max_data decreased">>};
        false ->
            flush_h2_streams(StateData#data{remote_max_data = Limit})
    end;
handle_incoming_capsule({max_stream_data, _StreamId, _Limit},
                        #data{transport = h3} = _StateData) ->
    %% draft-15 §5.4: WT_MAX_STREAM_DATA is prohibited on h3.
    {session_error, ?WT_FLOW_CONTROL_ERROR,
     <<"h3 prohibits per-stream flow control capsules">>};
handle_incoming_capsule({max_stream_data, StreamId, Limit},
                        #data{streams = Streams} = StateData) ->
    %% h2 only: peer raises the per-stream send window.
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Current = webtransport_stream:send_window(Stream),
            case Limit < Current of
                true ->
                    {session_error, ?WT_FLOW_CONTROL_ERROR,
                     <<"max_stream_data decreased">>};
                false ->
                    Stream1 = webtransport_stream:update_send_window(Stream, Limit),
                    flush_h2_streams(StateData#data{streams = Streams#{StreamId => Stream1}})
            end;
        error ->
            StateData
    end;
handle_incoming_capsule({max_streams_bidi, Limit}, #data{remote_max_streams_bidi = Prev} = StateData) ->
    case Limit < Prev of
        true ->
            {session_error, ?WT_FLOW_CONTROL_ERROR, <<"max_streams_bidi decreased">>};
        false ->
            StateData#data{remote_max_streams_bidi = Limit}
    end;
handle_incoming_capsule({max_streams_uni, Limit}, #data{remote_max_streams_uni = Prev} = StateData) ->
    case Limit < Prev of
        true ->
            {session_error, ?WT_FLOW_CONTROL_ERROR, <<"max_streams_uni decreased">>};
        false ->
            StateData#data{remote_max_streams_uni = Limit}
    end;
handle_incoming_capsule({data_blocked, Limit}, StateData) ->
    logger:debug("peer data_blocked at ~p", [Limit]),
    StateData;
handle_incoming_capsule({stream_data_blocked, _StreamId, _Limit},
                        #data{transport = h3} = _StateData) ->
    %% draft-15 §5.4: WT_STREAM_DATA_BLOCKED is prohibited on h3.
    {session_error, ?WT_FLOW_CONTROL_ERROR,
     <<"h3 prohibits per-stream flow control capsules">>};
handle_incoming_capsule({stream_data_blocked, StreamId, Limit}, StateData) ->
    logger:debug("peer stream_data_blocked stream=~p limit=~p", [StreamId, Limit]),
    StateData;
handle_incoming_capsule({streams_blocked_bidi, Limit}, StateData) ->
    logger:debug("peer streams_blocked_bidi at ~p", [Limit]),
    StateData;
handle_incoming_capsule({streams_blocked_uni, Limit}, StateData) ->
    logger:debug("peer streams_blocked_uni at ~p", [Limit]),
    StateData;
handle_incoming_capsule({stop_sending, StreamId, ErrorCode},
                        #data{streams = Streams} = StateData) ->
    %% Peer asked us to stop sending on this stream: block our write side.
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            case webtransport_stream:peer_stop_sending(Stream, ErrorCode) of
                {ok, Stream1} ->
                    StateData#data{streams = Streams#{StreamId => Stream1}};
                {error, duplicate} ->
                    %% draft-14 §6.3: duplicate STOP_SENDING is a stream
                    %% state error. Log and continue (h2 could emit
                    %% WEBTRANSPORT_STREAM_STATE_ERROR, but we don't have
                    %% a separate stream-error return path yet).
                    logger:warning("duplicate stop_sending on stream ~p", [StreamId]),
                    StateData
            end;
        error ->
            StateData
    end;
handle_incoming_capsule({reset_stream, StreamId, ErrorCode},
                        #data{streams = Streams} = StateData) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Stream1 = webtransport_stream:reset(Stream, ErrorCode),
            StateData#data{streams = Streams#{StreamId => Stream1}};
        error ->
            StateData
    end;
handle_incoming_capsule({padding, _}, StateData) ->
    StateData;
handle_incoming_capsule({close_session, ErrorCode, Reason}, #data{} = StateData) ->
    StateData#data{close_info = {ErrorCode, Reason}};
handle_incoming_capsule({drain_session}, #data{} = StateData) ->
    StateData;
handle_incoming_capsule(Unknown, _StateData) ->
    %% Unknown capsule on the CONNECT stream. The drafts don't define a
    %% "forward-compatible ignore" rule for WT capsules; treat it as a
    %% session error so protocol mismatches surface immediately.
    logger:warning("webtransport: unknown capsule ~p, closing session", [Unknown]),
    {session_error, ?WT_REQUIREMENTS_NOT_MET,
     iolist_to_binary(io_lib:format("unknown capsule: ~p", [Unknown]))}.

handle_incoming_stream_data(StreamId, Data, Fin,
                             #data{streams = Streams, handler = Handler,
                                   handler_state = HState,
                                   bytes_received = SessRecv} = StateData) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Type = webtransport_stream:type(Stream),
            case webtransport_stream:receive_data(Stream, Data) of
                {ok, Stream1} ->
                    Stream2 = case Fin of
                        true ->
                            {ok, S} = webtransport_stream:receive_fin(Stream1),
                            S;
                        false ->
                            Stream1
                    end,
                    Callback = case Fin andalso erlang:function_exported(Handler, handle_stream_fin, 4) of
                        true -> fun() -> Handler:handle_stream_fin(StreamId, Type, Data, HState) end;
                        false -> fun() -> Handler:handle_stream(StreamId, Type, Data, HState) end
                    end,
                    StateData1 = StateData#data{bytes_received = SessRecv + byte_size(Data)},
                    %% The handler consumes the bytes synchronously, so credit
                    %% can be returned to the peer right away.
                    {Stream3, StateData2} = grant_credit(StreamId, Stream2, StateData1),
                    apply_stream_callback(Callback(), StreamId, Stream3, Streams, StateData2);
                {error, Reason} ->
                    logger:warning("webtransport: dropping ~p bytes on stream ~p: ~p",
                                   [byte_size(Data), StreamId, Reason]),
                    {StateData, continue}
            end;
        error ->
            {StateData, continue}
    end.

%% h2 receive-side flow control (draft-14 §6): once half of a window has
%% been consumed, advertise a new limit so the peer can keep sending. h3
%% leaves this to QUIC.
-spec grant_credit(non_neg_integer(), webtransport_stream:stream(), #data{}) ->
    {webtransport_stream:stream(), #data{}}.
grant_credit(StreamId, Stream,
             #data{transport = h2, transport_state = H2State,
                   bytes_received = SessRecv, local_max_data = LocalMax,
                   session_window = SessWindow} = StateData) ->
    Window = webtransport_stream:recv_window(Stream),
    Received = webtransport_stream:bytes_received(Stream),
    Stream1 =
        case webtransport_stream:is_readable(Stream) andalso
             Received >= Window - (?DEFAULT_MAX_STREAM_DATA div 2) of
            true ->
                NewWindow = Received + ?DEFAULT_MAX_STREAM_DATA,
                _ = webtransport_h2:send_capsule(
                      H2State, wt_h2_capsule:max_stream_data(StreamId, NewWindow)),
                webtransport_stream:update_recv_window(Stream, NewWindow);
            false ->
                Stream
        end,
    StateData1 =
        case SessRecv >= LocalMax - (SessWindow div 2) of
            true ->
                NewMax = SessRecv + SessWindow,
                _ = webtransport_h2:send_capsule(H2State, wt_h2_capsule:max_data(NewMax)),
                StateData#data{local_max_data = NewMax};
            false ->
                StateData
        end,
    {Stream1, StateData1};
grant_credit(_StreamId, Stream, StateData) ->
    {Stream, StateData}.

apply_stream_callback({ok, HState1}, StreamId, Stream2, Streams, StateData) ->
    {StateData#data{streams = Streams#{StreamId => Stream2},
                    handler_state = HState1},
     continue};
apply_stream_callback({ok, HState1, Actions}, StreamId, Stream2, Streams, StateData) ->
    StateData1 = StateData#data{streams = Streams#{StreamId => Stream2},
                                handler_state = HState1},
    handle_actions(Actions, StateData1);
apply_stream_callback({stop, Reason, HState1}, StreamId, Stream2, Streams, StateData) ->
    {StateData#data{streams = Streams#{StreamId => Stream2},
                    handler_state = HState1},
     {stop, Reason}}.

handle_incoming_datagram(Data, #data{handler = Handler, handler_state = HState} = StateData) ->
    case Handler:handle_datagram(Data, HState) of
        {ok, HState1} ->
            {StateData#data{handler_state = HState1}, continue};
        {ok, HState1, Actions} ->
            handle_actions(Actions, StateData#data{handler_state = HState1});
        {stop, Reason, HState1} ->
            {StateData#data{handler_state = HState1}, {stop, Reason}}
    end.

handle_remote_stream_opened(StreamId, Type, #data{streams = Streams} = StateData) ->
    case maps:is_key(StreamId, Streams) of
        true ->
            StateData;
        false ->
            Limit = case Type of
                bidi -> StateData#data.local_max_streams_bidi;
                uni  -> StateData#data.local_max_streams_uni
            end,
            Count = count_peer_streams(Type, Streams, StateData#data.is_server),
            case Count < Limit of
                true ->
                    Stream = webtransport_stream:new(StreamId, Type, initial_stream_window(StateData)),
                    StateData#data{streams = Streams#{StreamId => Stream}};
                false ->
                    %% Peer exceeded our advertised stream limit.
                    %% Reset the stream with WT_BUFFERED_STREAM_REJECTED.
                    reject_excess_stream(StreamId, StateData),
                    StateData
            end
    end.

count_peer_streams(Type, Streams, IsServer) ->
    maps:fold(fun(Sid, S, Acc) ->
        StreamType = webtransport_stream:type(S),
        Initiator = webtransport_stream:initiator(Sid),
        IsPeer = case IsServer of
            true  -> Initiator =:= client;
            false -> Initiator =:= server
        end,
        case IsPeer andalso StreamType =:= Type of
            true -> Acc + 1;
            false -> Acc
        end
    end, 0, Streams).

reject_excess_stream(StreamId, #data{transport = h3, transport_state = H3State}) ->
    QuicConn = webtransport_h3:quic_conn(H3State),
    QuicCode = wt_error:to_quic(?WT_BUFFERED_STREAM_REJECTED),
    _ = quic:reset_stream(QuicConn, StreamId, QuicCode),
    ok;
reject_excess_stream(StreamId, #data{transport = h2, transport_state = H2State}) ->
    _ = webtransport_h2:send_capsule(H2State,
            wt_h2_capsule:reset_stream(StreamId, ?WT_BUFFERED_STREAM_REJECTED)),
    ok.

handle_remote_stream_closed(StreamId, Reason,
                             #data{streams = Streams, handler = Handler,
                                   handler_state = HState} = StateData) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} ->
            Stream1 = webtransport_stream:close(Stream),
            case Handler:handle_stream_closed(StreamId, Reason, HState) of
                {ok, HState1} ->
                    {StateData#data{streams = Streams#{StreamId => Stream1},
                                    handler_state = HState1},
                     continue};
                {stop, StopReason, HState1} ->
                    {StateData#data{streams = Streams#{StreamId => Stream1},
                                    handler_state = HState1},
                     {stop, StopReason}}
            end;
        error ->
            {StateData, continue}
    end.

%% Execute handler-returned actions inline on the session's own state.
%% Runs inside the gen_statem callback so we cannot round-trip through the
%% public API — that would self-call and crash with `calling_self`.
%%
%% Returns `{NewStateData, Transition}' where Transition is:
%%   `continue'          — stay in current state
%%   `drain'             — caller must enter the `draining' state
%%   `{stop, Reason}'    — caller must stop the gen_statem
%% The strongest transition wins (stop > drain > continue) so an action list
%% like `[drain_session, {close_session, 0, <<>>}]' produces `{stop, normal}'.
-spec handle_actions([webtransport_handler:action()], #data{}) ->
    {#data{}, continue | drain | {stop, term()}}.
handle_actions(Actions, StateData) ->
    handle_actions(Actions, StateData, continue).

handle_actions([], StateData, Transition) ->
    {StateData, Transition};
handle_actions([Action | Rest], StateData, Transition) ->
    {StateData1, NewTrans} = dispatch_action(Action, StateData),
    handle_actions(Rest, StateData1, strongest_transition(Transition, NewTrans)).

strongest_transition(continue, New) -> New;
strongest_transition(Old, continue) -> Old;
strongest_transition({stop, _} = Stop, _) -> Stop;
strongest_transition(_, {stop, _} = Stop) -> Stop;
strongest_transition(drain, drain) -> drain.

dispatch_action({send, Stream, Data} = Action, StateData) ->
    apply_do_result(do_send(Stream, iolist_to_binary(Data), false, StateData), StateData, Action);
dispatch_action({send, Stream, Data, fin} = Action, StateData) ->
    apply_do_result(do_send(Stream, iolist_to_binary(Data), true, StateData), StateData, Action);
dispatch_action({send_datagram, Data} = Action, StateData) ->
    apply_do_result(do_send_datagram(iolist_to_binary(Data), StateData), StateData, Action);
dispatch_action({open_stream, Type} = Action, StateData) ->
    case do_open_stream(Type, StateData) of
        {ok, _StreamId, StateData1} ->
            {StateData1, continue};
        {error, Reason} ->
            handle_action_failure(Action, Reason, StateData)
    end;
dispatch_action({close_stream, _Stream} = Action, StateData) ->
    apply_do_result(do_close_stream(element(2, Action), StateData), StateData, Action);
dispatch_action({reset_stream, Stream, Code} = Action, StateData) ->
    apply_do_result(do_reset_stream(Stream, Code, StateData), StateData, Action);
dispatch_action({stop_sending, Stream, Code} = Action, StateData) ->
    apply_do_result(do_stop_sending(Stream, Code, StateData), StateData, Action);
dispatch_action(drain_session, StateData) ->
    do_drain(StateData),
    {StateData, drain};
dispatch_action({close_session, ErrorCode, Reason}, StateData) ->
    do_close(ErrorCode, Reason, StateData),
    {StateData#data{close_info = {ErrorCode, Reason}}, {stop, normal}}.

apply_do_result({ok, StateData1}, _OldState, _Action) ->
    {StateData1, continue};
apply_do_result({error, Reason}, OldState, Action) ->
    handle_action_failure(Action, Reason, OldState).

%% Invoke the handler's optional `handle_action_failed/3' callback with the
%% action and the underlying error reason. If the callback is not exported,
%% log a warning and keep the session running (pre-callback behaviour).
handle_action_failure(Action, Reason,
                      #data{handler = Handler, handler_state = HState} = StateData) ->
    case erlang:function_exported(Handler, handle_action_failed, 3) of
        true ->
            case Handler:handle_action_failed(Action, Reason, HState) of
                {ok, HState1} ->
                    {StateData#data{handler_state = HState1}, continue};
                {stop, StopReason, HState1} ->
                    {StateData#data{handler_state = HState1}, {stop, StopReason}}
            end;
        false ->
            logger:warning("webtransport action ~p failed: ~p", [Action, Reason]),
            {StateData, continue}
    end.

%% Transport abstraction
transport_send(StreamId, Data, Fin, #data{transport = h2, transport_state = H2State}) ->
    webtransport_h2:send(H2State, StreamId, Data, Fin);
transport_send(StreamId, Data, Fin, #data{transport = h3, transport_state = H3State}) ->
    webtransport_h3:send(H3State, StreamId, Data, Fin).

transport_send_datagram(Data, #data{transport = h2, transport_state = H2State}) ->
    webtransport_h2:send_datagram(H2State, Data);
transport_send_datagram(Data, #data{transport = h3, transport_state = H3State}) ->
    webtransport_h3:send_datagram(H3State, Data).

transport_open_stream(StreamId, Type, #data{transport = h2, transport_state = H2State}) ->
    ok = webtransport_h2:open_stream(H2State, StreamId, Type),
    {ok, StreamId};
transport_open_stream(_StreamId, bidi, #data{transport = h3, transport_state = H3State}) ->
    case webtransport_h3:open_bidi_stream(H3State) of
        {ok, RealId, _} -> {ok, RealId};
        {error, _} = Err -> Err
    end;
transport_open_stream(_StreamId, uni, #data{transport = h3, transport_state = H3State}) ->
    case webtransport_h3:open_uni_stream(H3State) of
        {ok, RealId, _} -> {ok, RealId};
        {error, _} = Err -> Err
    end.

transport_reset_stream(StreamId, ErrorCode, #data{transport = h2, transport_state = H2State}) ->
    webtransport_h2:reset_stream(H2State, StreamId, ErrorCode);
transport_reset_stream(StreamId, ErrorCode, #data{transport = h3, transport_state = H3State}) ->
    webtransport_h3:reset_stream(H3State, StreamId, ErrorCode, 0).

transport_stop_sending(StreamId, ErrorCode, #data{transport = h2, transport_state = H2State}) ->
    webtransport_h2:stop_sending(H2State, StreamId, ErrorCode);
transport_stop_sending(StreamId, ErrorCode, #data{transport = h3, transport_state = H3State}) ->
    webtransport_h3:stop_sending(H3State, StreamId, ErrorCode).

count_streams(Type, Streams) ->
    maps:fold(fun(_Id, Stream, Acc) ->
        case webtransport_stream:type(Stream) of
            Type -> Acc + 1;
            _ -> Acc
        end
    end, 0, Streams).

maybe_stop_if_drained(#data{streams = Streams} = StateData, Actions) ->
    OpenCount = maps:fold(fun(_Id, Stream, Acc) ->
        case webtransport_stream:is_open(Stream) of
            true -> Acc + 1;
            false -> Acc
        end
    end, 0, Streams),
    case OpenCount of
        0 -> {stop, normal, StateData};
        _ -> {keep_state, StateData, Actions}
    end.

do_early_data_accepted(#data{transport = h3, transport_state = H3State}) ->
    quic_h3:early_data_accepted(webtransport_h3:h3_conn(H3State));
do_early_data_accepted(#data{transport = h2}) ->
    not_supported.

build_info(#data{transport = Transport, streams = Streams,
                  local_max_data = LocalMaxData, remote_max_data = RemoteMaxData,
                  local_max_streams_bidi = LocalMaxBidi, local_max_streams_uni = LocalMaxUni,
                  remote_max_streams_bidi = RemoteMaxBidi, remote_max_streams_uni = RemoteMaxUni,
                  bytes_sent = Sent, bytes_received = Received, close_info = Close}) ->
    Base = #{
        transport => Transport,
        stream_count => maps:size(Streams),
        local_max_data => LocalMaxData,
        remote_max_data => RemoteMaxData,
        local_max_streams_bidi => LocalMaxBidi,
        local_max_streams_uni => LocalMaxUni,
        remote_max_streams_bidi => RemoteMaxBidi,
        remote_max_streams_uni => RemoteMaxUni,
        bytes_sent => Sent,
        bytes_received => Received
    },
    case Close of
        undefined -> Base;
        _ -> Base#{close_info => Close}
    end.

%% ============================================================================
%% Eunit (internal helpers)
%% ============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

handle_incoming_capsule_max_stream_data_test() ->
    Stream = webtransport_stream:new(4, bidi, 1024),
    Data = #data{streams = #{4 => Stream}, transport = h2,
                 remote_max_data = 0, remote_max_streams_bidi = 0,
                 remote_max_streams_uni = 0,
                 local_max_data = 0, local_max_streams_bidi = 0,
                 local_max_streams_uni = 0, is_server = false,
                 next_bidi_id = 0, next_uni_id = 2,
                 request = #{}, handler = undefined,
                 handler_state = undefined},
    Data1 = handle_incoming_capsule({max_stream_data, 4, 65536}, Data),
    #{4 := Stream1} = Data1#data.streams,
    ?assertEqual(65536, webtransport_stream:send_window(Stream1)),
    %% Lower value triggers session error (monotonicity enforcement).
    ?assertMatch({session_error, ?WT_FLOW_CONTROL_ERROR, _},
                 handle_incoming_capsule({max_stream_data, 4, 100}, Data1)),
    ok.

handle_incoming_capsule_max_stream_data_h3_rejected_test() ->
    Stream = webtransport_stream:new(4, bidi, 1024),
    Data = #data{streams = #{4 => Stream}, transport = h3,
                 remote_max_data = 0, remote_max_streams_bidi = 0,
                 remote_max_streams_uni = 0,
                 local_max_data = 0, local_max_streams_bidi = 0,
                 local_max_streams_uni = 0, is_server = false,
                 next_bidi_id = 0, next_uni_id = 2,
                 request = #{}, handler = undefined,
                 handler_state = undefined},
    ?assertMatch({session_error, ?WT_FLOW_CONTROL_ERROR, _},
                 handle_incoming_capsule({max_stream_data, 4, 65536}, Data)),
    ok.

handle_incoming_capsule_max_data_monotonic_test() ->
    Data = #data{streams = #{}, transport = h2,
                 remote_max_data = 1000, remote_max_streams_bidi = 0,
                 remote_max_streams_uni = 0, local_max_data = 0,
                 local_max_streams_bidi = 0, local_max_streams_uni = 0,
                 is_server = false, next_bidi_id = 0, next_uni_id = 2,
                 request = #{}, handler = undefined, handler_state = undefined},
    %% Decrease triggers session error.
    ?assertMatch({session_error, ?WT_FLOW_CONTROL_ERROR, _},
                 handle_incoming_capsule({max_data, 500}, Data)),
    %% Increase is accepted.
    ?assertEqual(2000, (handle_incoming_capsule({max_data, 2000}, Data))#data.remote_max_data),
    %% Equal is accepted (not a decrease).
    ?assertEqual(1000, (handle_incoming_capsule({max_data, 1000}, Data))#data.remote_max_data),
    ok.

handle_incoming_capsule_stop_sending_test() ->
    Stream = webtransport_stream:new(4, bidi, 1024),
    Data = #data{streams = #{4 => Stream}, transport = h2,
                 remote_max_data = 0, remote_max_streams_bidi = 0,
                 remote_max_streams_uni = 0, local_max_data = 0,
                 local_max_streams_bidi = 0, local_max_streams_uni = 0,
                 is_server = false, next_bidi_id = 0, next_uni_id = 2,
                 request = #{}, handler = undefined, handler_state = undefined},
    Data1 = handle_incoming_capsule({stop_sending, 4, 42}, Data),
    #{4 := Stream1} = Data1#data.streams,
    ?assertNot(webtransport_stream:is_writable(Stream1)),
    ok.

augment_reason_test_() ->
    [
        ?_assertEqual(normal, augment_reason(normal, undefined)),
        ?_assertEqual(shutdown, augment_reason(shutdown, undefined)),
        ?_assertEqual({closed, 7, <<"bye">>},
                      augment_reason(normal, {7, <<"bye">>})),
        ?_assertEqual({{shutdown, x}, {closed, 0, <<>>}},
                      augment_reason({shutdown, x}, {0, <<>>}))
    ].

apply_capsule_transition_test_() ->
    Data = #data{streams = #{}, transport = h2,
                 remote_max_data = 0, remote_max_streams_bidi = 0,
                 remote_max_streams_uni = 0, local_max_data = 0,
                 local_max_streams_bidi = 0, local_max_streams_uni = 0,
                 is_server = false, next_bidi_id = 0, next_uni_id = 2,
                 request = #{}, handler = undefined, handler_state = undefined},
    [
        ?_assertMatch({stop, normal, _},
                      apply_capsule_transition({close_session, 1, <<>>}, Data)),
        ?_assertMatch({next_state, draining, _},
                      apply_capsule_transition({drain_session}, Data)),
        ?_assertMatch({keep_state, _},
                      apply_capsule_transition({max_data, 1000}, Data))
    ].

-endif.
