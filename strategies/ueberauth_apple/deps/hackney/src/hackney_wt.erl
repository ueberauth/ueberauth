%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2026 Benoît Chesneau <benoitc@pm.me>
%%%
%%% @doc gen_statem process for WebTransport client connections.
%%%
%%% This module mirrors {@link hackney_ws} so an application can move from
%%% WebSocket to WebTransport by swapping the `ws_' API prefix for `wt_'.
%%% It wraps an `erlang-webtransport' client session (HTTP/3 by default,
%%% HTTP/2 optional) and owns that session process.
%%%
%%% == Connection reuse and multiplexing ==
%%%
%%% A WebTransport session is the analog of an HTTP/2 connection: one
%%% `hackney_wt' process owns a single session and many streams are
%%% multiplexed over it. `open_stream/2' opens as many bidirectional or
%%% unidirectional streams as the peer's flow control allows; each stream
%%% has its own send (`stream_send/3,4') and receive (`stream_recv/2,3')
%%% channel, keyed by stream id, exactly like the `h2_streams' map in
%%% `hackney_conn'.
%%%
%%% == Default message channel ==
%%%
%%% WebTransport has no message framing of its own, so to stay
%%% interoperable with any server we do NOT invent a wire format. The
%%% `send/2' / `recv/1' convenience channel maps onto a single persistent
%%% bidirectional stream opened at connect time: `send/2' writes bytes to
%%% it and `recv/1' returns the next chunk received on it as
%%% `{binary, Data}'. Datagrams and data from server-opened streams are
%%% also surfaced on this channel as `{datagram, Data}' and
%%% `{stream, Id, Data}'. Because there is no framing, chunks are not
%%% guaranteed to align with send boundaries; an application that needs
%%% message boundaries must self-delimit.
%%%
%%% == Delivery modes ==
%%%
%%% In passive mode (the default) data is buffered per channel and read
%%% with `recv'/`stream_recv'. In active mode every event is forwarded to
%%% the owner uniformly tagged with its stream id:
%%% `{hackney_wt, Conn, {binary, Data}}', `{hackney_wt, Conn, {datagram,
%%% Data}}', `{hackney_wt, Conn, {stream, Id, Data}}', `{hackney_wt, Conn,
%%% {stream_fin, Id, Data}}', `{hackney_wt, Conn, {stream_closed, Id,
%%% Reason}}' and `{hackney_wt, Conn, closed}'.
%%%
%%% States:
%%% <ul>
%%%   <li>idle: process started, session not yet established</li>
%%%   <li>connected: session established, ready for I/O</li>
%%%   <li>closed: session terminated (buffered data still drainable)</li>
%%% </ul>
-module(hackney_wt).
-behaviour(gen_statem).

%% API
-export([
    start_link/1,
    connect/1, connect/2,
    send/2,
    recv/1, recv/2,
    setopts/2,
    close/1, close/2,
    controlling_process/2,
    open_stream/2,
    stream_send/3, stream_send/4,
    stream_recv/2, stream_recv/3,
    close_stream/2,
    reset_stream/3,
    stop_sending/3,
    send_datagram/2,
    session_info/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    terminate/3,
    code_change/4
]).

%% State functions
-export([
    idle/3,
    connected/3,
    closed/3
]).

-define(CONNECT_TIMEOUT, 8000).
-define(RECV_TIMEOUT, infinity).

%% Bound the bytes buffered across all passive receive queues so a hostile
%% server cannot drive the client to OOM by flooding stream/datagram data
%% that is never consumed. `infinity' disables the cap. This complements
%% WebTransport flow control (which bounds in-flight bytes per stream) by
%% bounding the already-decoded queues; same intent as the WebSocket
%% client's GHSA-q8jg caps.
-define(DEFAULT_MAX_RECV_BUFFER, 16#4000000). %% 64 MiB

%% A normalized message on the primary channel, handed to recv/2 or, in
%% active mode, to the owner.
-type wt_msg() :: {binary, binary()}
                | {datagram, binary()}
                | {stream, non_neg_integer(), binary()}
                | {stream_fin, non_neg_integer(), binary()}
                | {stream_closed, non_neg_integer(), term()}.

%% Accepted by send/2.
-type wt_frame() :: {text, iodata()}
                  | {binary, iodata()}
                  | iodata()
                  | {datagram, iodata()}
                  | {stream, non_neg_integer(), iodata()}
                  | {stream, non_neg_integer(), iodata(), fin | nofin}.

%% Returned by stream_recv/2,3.
-type stream_msg() :: {ok, binary()}
                    | {ok, {fin, binary()}}
                    | {error, term()}.

-export_type([wt_msg/0, wt_frame/0, stream_msg/0]).

%% Per-stream receive state for a client-opened stream (mirrors the role
%% of an HTTP/2 stream's pending caller in hackney_conn).
-record(stream, {
    q = queue:new() :: queue:queue(),
    from :: {pid(), reference()} | undefined,
    %% undefined while open; set when the peer ends the stream
    closed :: undefined | term()
}).

-record(wt_data, {
    %% Connection owner (linked via start_link, trap_exit handles death)
    owner :: pid(),

    %% Connection identity
    host :: string() | binary(),
    port :: inet:port_number(),
    transport = h3 :: h2 | h3,
    path :: binary(),

    %% webtransport:connect/4 options map (TLS, headers, compat_mode, ...)
    connect_opts = #{} :: map(),
    connect_timeout = ?CONNECT_TIMEOUT :: timeout(),
    recv_timeout = ?RECV_TIMEOUT :: timeout(),

    %% Delivery mode
    active = false :: false | true | once,

    %% Underlying webtransport session and the persistent default stream
    session :: pid() | undefined,
    default_stream :: non_neg_integer() | undefined,

    %% Per-stream state for client-opened streams: StreamId => #stream{}
    streams = #{} :: #{non_neg_integer() => #stream{}},

    %% Primary channel buffering (default stream + datagrams + server streams)
    recv_q = queue:new() :: queue:queue(),
    recv_from :: {pid(), reference()} | undefined,

    %% Total buffered bytes across every queue, for the OOM cap
    recv_bytes = 0 :: non_neg_integer(),
    max_recv_buffer = ?DEFAULT_MAX_RECV_BUFFER :: non_neg_integer() | infinity,

    %% Reason recorded once the session ends
    closed_reason :: term()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a WebTransport connection process.
%% Options:
%% <ul>
%%   <li>host: Target host (string or binary)</li>
%%   <li>port: Target port (integer)</li>
%%   <li>transport: h3 (default) or h2</li>
%%   <li>path: WebTransport path (binary, default "/")</li>
%%   <li>connect_opts: webtransport:connect/4 options map</li>
%%   <li>connect_timeout: Connection timeout (default 8000ms)</li>
%%   <li>recv_timeout: Default receive timeout (default infinity)</li>
%%   <li>active: false | true | once (default false)</li>
%%   <li>max_recv_buffer: passive buffer cap in bytes (default 64 MiB)</li>
%% </ul>
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, [self(), Opts], []).

%% @doc Establish the WebTransport session. Blocks until the CONNECT
%% completes or fails.
-spec connect(pid()) -> ok | {error, term()}.
connect(Pid) ->
    connect(Pid, ?CONNECT_TIMEOUT).

-spec connect(pid(), timeout()) -> ok | {error, term()}.
connect(Pid, Timeout) ->
    %% The handshake is driven inside the process; the internal timeout
    %% below bounds it, so the call itself waits indefinitely.
    gen_statem:call(Pid, {connect, Timeout}, infinity).

%% @doc Send on the connection.
%% Frame forms:
%% <ul>
%%   <li>`{text, Data}' | `{binary, Data}' | `Data' (binary/iodata):
%%       write to the persistent default stream</li>
%%   <li>`{datagram, Data}': send an unreliable datagram</li>
%%   <li>`{stream, StreamId, Data}' | `{stream, StreamId, Data, fin|nofin}':
%%       write to a specific stream</li>
%% </ul>
-spec send(pid(), wt_frame()) -> ok | {error, term()}.
send(Pid, Frame) ->
    gen_statem:call(Pid, {send, Frame}).

%% @doc Receive the next message on the primary channel (passive mode only).
-spec recv(pid()) -> {ok, wt_msg()} | {error, term()}.
recv(Pid) ->
    gen_statem:call(Pid, {recv, default}, infinity).

-spec recv(pid(), timeout()) -> {ok, wt_msg()} | {error, term()}.
recv(Pid, Timeout) ->
    gen_statem:call(Pid, {recv, Timeout}, infinity).

%% @doc Set options. Supported: [{active, true|false|once}]
-spec setopts(pid(), list()) -> ok | {error, term()}.
setopts(Pid, Opts) ->
    gen_statem:call(Pid, {setopts, Opts}).

%% @doc Close the session gracefully (error code 0, no reason).
-spec close(pid()) -> ok.
close(Pid) ->
    close(Pid, {0, <<>>}).

-spec close(pid(), {non_neg_integer(), binary()}) -> ok.
close(Pid, {Code, Reason}) ->
    gen_statem:cast(Pid, {close, Code, Reason}).

%% @doc Assign a new controlling process.
-spec controlling_process(pid(), pid()) -> ok | {error, term()}.
controlling_process(Pid, NewOwner) ->
    gen_statem:call(Pid, {controlling_process, NewOwner}).

%% @doc Open a new stream multiplexed over the session. Returns its id.
-spec open_stream(pid(), bidi | uni) -> {ok, non_neg_integer()} | {error, term()}.
open_stream(Pid, Type) when Type =:= bidi; Type =:= uni ->
    gen_statem:call(Pid, {open_stream, Type}).

%% @doc Write to a stream (no FIN).
-spec stream_send(pid(), non_neg_integer(), iodata()) -> ok | {error, term()}.
stream_send(Pid, StreamId, Data) ->
    gen_statem:call(Pid, {stream_send, StreamId, Data, nofin}).

%% @doc Write to a stream, optionally closing the write side (FIN).
-spec stream_send(pid(), non_neg_integer(), iodata(), fin | nofin) -> ok | {error, term()}.
stream_send(Pid, StreamId, Data, Fin) when Fin =:= fin; Fin =:= nofin ->
    gen_statem:call(Pid, {stream_send, StreamId, Data, Fin}).

%% @doc Receive the next chunk on a client-opened stream (passive mode).
%% Returns `{ok, Data}', `{ok, {fin, Data}}' when the peer ends the
%% stream, or `{error, Reason}'.
-spec stream_recv(pid(), non_neg_integer()) -> stream_msg().
stream_recv(Pid, StreamId) ->
    gen_statem:call(Pid, {stream_recv, StreamId, default}, infinity).

-spec stream_recv(pid(), non_neg_integer(), timeout()) -> stream_msg().
stream_recv(Pid, StreamId, Timeout) ->
    gen_statem:call(Pid, {stream_recv, StreamId, Timeout}, infinity).

%% @doc Close a stream gracefully (send FIN).
-spec close_stream(pid(), non_neg_integer()) -> ok | {error, term()}.
close_stream(Pid, StreamId) ->
    gen_statem:call(Pid, {close_stream, StreamId}).

%% @doc Abruptly terminate a stream with an error code.
-spec reset_stream(pid(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
reset_stream(Pid, StreamId, ErrorCode) ->
    gen_statem:call(Pid, {reset_stream, StreamId, ErrorCode}).

%% @doc Ask the peer to stop sending on a stream.
-spec stop_sending(pid(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
stop_sending(Pid, StreamId, ErrorCode) ->
    gen_statem:call(Pid, {stop_sending, StreamId, ErrorCode}).

%% @doc Send an unreliable datagram.
-spec send_datagram(pid(), iodata()) -> ok | {error, term()}.
send_datagram(Pid, Data) ->
    gen_statem:call(Pid, {send_datagram, Data}).

%% @doc Return session information (transport, stream count, flow control).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

%% @private
callback_mode() ->
    [state_functions, state_enter].

%% @private
init([Owner, Opts]) ->
    process_flag(trap_exit, true),
    Data = #wt_data{
        owner = Owner,
        host = maps:get(host, Opts),
        port = maps:get(port, Opts),
        transport = maps:get(transport, Opts, h3),
        path = maps:get(path, Opts, <<"/">>),
        connect_opts = maps:get(connect_opts, Opts, #{}),
        connect_timeout = maps:get(connect_timeout, Opts, ?CONNECT_TIMEOUT),
        recv_timeout = maps:get(recv_timeout, Opts, ?RECV_TIMEOUT),
        active = maps:get(active, Opts, false),
        max_recv_buffer = maps:get(max_recv_buffer, Opts, ?DEFAULT_MAX_RECV_BUFFER)
    },
    {ok, idle, Data}.

%% @private
terminate(_Reason, _State, #wt_data{session = undefined}) ->
    ok;
terminate(_Reason, _State, #wt_data{} = Data) ->
    close_session_safe(Data),
    ok.

%% @private
code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%====================================================================
%% State: idle
%%====================================================================

idle(enter, _OldState, _Data) ->
    keep_state_and_data;

idle({call, From}, {connect, Timeout}, Data) ->
    #wt_data{host = Host, port = Port, path = Path,
             transport = Transport, connect_opts = COpts0} = Data,
    COpts = COpts0#{transport => Transport, timeout => Timeout},
    case webtransport:connect(Host, Port, Path, COpts) of
        {ok, Session} ->
            %% Open the persistent default bidi stream eagerly; if the
            %% server has not granted bidi credit yet, fall back to opening
            %% it lazily on the first send.
            DefaultStream = case webtransport:open_stream(Session, bidi) of
                {ok, Sid} -> Sid;
                {error, _} -> undefined
            end,
            Data1 = Data#wt_data{session = Session, default_stream = DefaultStream},
            {next_state, connected, Data1, [{reply, From, ok}]};
        {error, Reason} ->
            {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
    end;

idle({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

idle(info, {'EXIT', Owner, _Reason}, #wt_data{owner = Owner}) ->
    {stop, normal};

idle(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: connected
%%====================================================================

connected(enter, _OldState, _Data) ->
    keep_state_and_data;

%% --- send -------------------------------------------------------------
connected({call, From}, {send, Frame}, Data) ->
    {Reply, Data1} = do_send(Frame, Data),
    {keep_state, Data1, [{reply, From, Reply}]};

%% --- primary channel recv --------------------------------------------
connected({call, From}, {recv, _Timeout}, #wt_data{active = Active})
  when Active =/= false ->
    {keep_state_and_data, [{reply, From, {error, {active_mode, Active}}}]};

connected({call, From}, {recv, _Timeout}, #wt_data{recv_from = RF})
  when RF =/= undefined ->
    {keep_state_and_data, [{reply, From, {error, recv_busy}}]};

connected({call, From}, {recv, Timeout0}, Data) ->
    Timeout = recv_timeout(Timeout0, Data),
    case dequeue(Data#wt_data.recv_q, Data) of
        {value, Msg, Q1, Data1} ->
            {keep_state, Data1#wt_data{recv_q = Q1}, [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            case Data#wt_data.closed_reason of
                undefined ->
                    {keep_state, Data#wt_data{recv_from = From}, recv_timer(recv, Timeout)};
                Reason ->
                    {keep_state_and_data, [{reply, From, {error, Reason}}]}
            end
    end;

%% --- per-stream recv --------------------------------------------------
connected({call, From}, {stream_recv, _Sid, _Timeout}, #wt_data{active = Active})
  when Active =/= false ->
    {keep_state_and_data, [{reply, From, {error, {active_mode, Active}}}]};

connected({call, From}, {stream_recv, Sid, Timeout0}, Data) ->
    case maps:find(Sid, Data#wt_data.streams) of
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]};
        {ok, #stream{from = F}} when F =/= undefined ->
            {keep_state_and_data, [{reply, From, {error, recv_busy}}]};
        {ok, S} ->
            do_stream_recv(From, Sid, S, recv_timeout(Timeout0, Data), Data)
    end;

%% --- options ----------------------------------------------------------
connected({call, From}, {setopts, Opts}, Data) ->
    case proplists:get_value(active, Opts) of
        undefined ->
            {keep_state_and_data, [{reply, From, ok}]};
        NewActive when NewActive =:= true; NewActive =:= false; NewActive =:= once ->
            Data1 = apply_active(NewActive, Data),
            {keep_state, Data1, [{reply, From, ok}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, badarg}}]}
    end;

connected({call, From}, {controlling_process, NewOwner}, #wt_data{owner = OldOwner} = Data) ->
    unlink(OldOwner),
    link(NewOwner),
    {keep_state, Data#wt_data{owner = NewOwner}, [{reply, From, ok}]};

%% --- native stream / datagram API ------------------------------------
connected({call, From}, {open_stream, Type}, #wt_data{session = S} = Data) ->
    case webtransport:open_stream(S, Type) of
        {ok, Sid} = Ok ->
            Streams = maps:put(Sid, #stream{}, Data#wt_data.streams),
            {keep_state, Data#wt_data{streams = Streams}, [{reply, From, Ok}]};
        {error, _} = Err ->
            {keep_state_and_data, [{reply, From, Err}]}
    end;

connected({call, From}, {stream_send, StreamId, SData, Fin}, #wt_data{session = S}) ->
    {keep_state_and_data, [{reply, From, webtransport:send(S, StreamId, SData, Fin)}]};

connected({call, From}, {close_stream, StreamId}, #wt_data{session = S}) ->
    {keep_state_and_data, [{reply, From, webtransport:close_stream(S, StreamId)}]};

connected({call, From}, {reset_stream, StreamId, Code}, #wt_data{session = S}) ->
    {keep_state_and_data, [{reply, From, webtransport:reset_stream(S, StreamId, Code)}]};

connected({call, From}, {stop_sending, StreamId, Code}, #wt_data{session = S}) ->
    {keep_state_and_data, [{reply, From, webtransport:stop_sending(S, StreamId, Code)}]};

connected({call, From}, {send_datagram, SData}, #wt_data{session = S}) ->
    {keep_state_and_data, [{reply, From, webtransport:send_datagram(S, SData)}]};

connected({call, From}, session_info, #wt_data{session = S}) ->
    {keep_state_and_data, [{reply, From, webtransport:session_info(S)}]};

connected({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, badrequest}}]};

%% --- close ------------------------------------------------------------
connected(cast, {close, Code, Reason}, #wt_data{session = S} = Data) ->
    _ = webtransport:close_session(S, Code, Reason),
    {next_state, closed, Data#wt_data{closed_reason = closed}};

%% --- recv timeouts ----------------------------------------------------
connected({timeout, recv}, recv, #wt_data{recv_from = From} = Data)
  when From =/= undefined ->
    {keep_state, Data#wt_data{recv_from = undefined}, [{reply, From, {error, timeout}}]};
connected({timeout, recv}, recv, _Data) ->
    keep_state_and_data;

connected({timeout, {srecv, Sid}}, {srecv, Sid}, Data) ->
    case maps:find(Sid, Data#wt_data.streams) of
        {ok, #stream{from = From} = S} when From =/= undefined ->
            Streams = maps:put(Sid, S#stream{from = undefined}, Data#wt_data.streams),
            {keep_state, Data#wt_data{streams = Streams}, [{reply, From, {error, timeout}}]};
        _ ->
            keep_state_and_data
    end;

%% --- session events ---------------------------------------------------
connected(info, {webtransport, Session, Event}, #wt_data{session = Session} = Data) ->
    handle_wt_event(Event, Data);

connected(info, {'EXIT', Session, Reason}, #wt_data{session = Session} = Data) ->
    R = case Reason of normal -> closed; _ -> {session_down, Reason} end,
    session_ended(R, Data);

connected(info, {'EXIT', Owner, _Reason}, #wt_data{owner = Owner} = Data) ->
    close_session_safe(Data),
    {stop, normal};

connected(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: closed
%%====================================================================

closed(enter, _OldState, _Data) ->
    keep_state_and_data;

%% Allow draining whatever was buffered before the session ended.
closed({call, From}, {recv, _Timeout}, Data) ->
    case dequeue(Data#wt_data.recv_q, Data) of
        {value, Msg, Q1, Data1} ->
            {keep_state, Data1#wt_data{recv_q = Q1}, [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state_and_data, [{reply, From, {error, closed_reason(Data)}}]}
    end;

closed({call, From}, {stream_recv, Sid, _Timeout}, Data) ->
    case maps:find(Sid, Data#wt_data.streams) of
        {ok, S} ->
            case queue:out(S#stream.q) of
                {{value, Item}, Q1} ->
                    Data1 = sub_bytes(item_size(Item), Data),
                    Streams = maps:put(Sid, S#stream{q = Q1}, Data1#wt_data.streams),
                    {keep_state, Data1#wt_data{streams = Streams},
                     [{reply, From, stream_item_result(Item)}]};
                {empty, _} ->
                    {keep_state_and_data, [{reply, From, {error, closed_reason(Data)}}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, closed}}]}
    end;

closed({call, From}, {controlling_process, NewOwner}, #wt_data{owner = OldOwner} = Data) ->
    unlink(OldOwner),
    link(NewOwner),
    {keep_state, Data#wt_data{owner = NewOwner}, [{reply, From, ok}]};

closed({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closed}}]};

closed(cast, {close, _Code, _Reason}, _Data) ->
    keep_state_and_data;

closed(info, {'EXIT', Owner, _Reason}, #wt_data{owner = Owner}) ->
    {stop, normal};

closed(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% Internal: send
%%====================================================================

%% @private Map a send frame onto the webtransport session.
do_send({text, D}, Data) ->
    send_default(D, Data);
do_send({binary, D}, Data) ->
    send_default(D, Data);
do_send({datagram, D}, #wt_data{session = S} = Data) ->
    {webtransport:send_datagram(S, D), Data};
do_send({stream, StreamId, D}, #wt_data{session = S} = Data) ->
    {webtransport:send(S, StreamId, D, nofin), Data};
do_send({stream, StreamId, D, Fin}, #wt_data{session = S} = Data)
  when Fin =:= fin; Fin =:= nofin ->
    {webtransport:send(S, StreamId, D, Fin), Data};
do_send(Ping, Data) when Ping =:= ping; Ping =:= pong ->
    {{error, {unsupported_frame, Ping}}, Data};
do_send({ping, _}, Data) ->
    {{error, {unsupported_frame, ping}}, Data};
do_send({pong, _}, Data) ->
    {{error, {unsupported_frame, pong}}, Data};
do_send(D, Data) when is_binary(D); is_list(D) ->
    send_default(D, Data);
do_send(_Other, Data) ->
    {{error, badarg}, Data}.

%% @private Write to the persistent default stream, opening it lazily if it
%% was not granted at connect time.
send_default(D, #wt_data{session = S, default_stream = undefined} = Data) ->
    case webtransport:open_stream(S, bidi) of
        {ok, StreamId} ->
            {webtransport:send(S, StreamId, D, nofin), Data#wt_data{default_stream = StreamId}};
        {error, _} = Err ->
            {Err, Data}
    end;
send_default(D, #wt_data{session = S, default_stream = StreamId} = Data) ->
    {webtransport:send(S, StreamId, D, nofin), Data}.

%%====================================================================
%% Internal: inbound events
%%====================================================================

%% @private Classify a webtransport handler event and route it. Data on
%% the default stream becomes the ws-shaped `{binary, Data}'; data on a
%% client-opened stream goes to that stream's per-stream channel;
%% everything else (datagrams, server-opened streams) stays on the primary
%% channel with its native shape.
handle_wt_event(closed, Data) ->
    session_ended(closed, Data);
handle_wt_event(Event, #wt_data{active = Active} = Data) when Active =/= false ->
    %% Active mode: forward everything to the owner, uniformly tagged.
    Data1 = clear_default_on_fin(Event, Data),
    case active_msg(Event, Data) of
        ignore ->
            {keep_state, Data1};
        Msg ->
            (Data1#wt_data.owner) ! {hackney_wt, self(), Msg},
            case Active of
                once -> {keep_state, Data1#wt_data{active = false}};
                true -> {keep_state, Data1}
            end
    end;
handle_wt_event(Event, Data) ->
    %% Passive mode: buffer per channel.
    route_passive(Event, Data).

%% @private Owner-facing message for active mode (ignore = drop).
active_msg({stream, Sid, _Type, D}, #wt_data{default_stream = Sid}) ->
    nonempty_binary(D);
active_msg({stream_fin, Sid, _Type, D}, #wt_data{default_stream = Sid}) ->
    nonempty_binary(D);
active_msg({stream, Sid, _Type, D}, _Data) ->
    {stream, Sid, D};
active_msg({stream_fin, Sid, _Type, D}, _Data) ->
    {stream_fin, Sid, D};
active_msg({datagram, D}, _Data) ->
    {datagram, D};
active_msg({stream_closed, Sid, Reason}, _Data) ->
    {stream_closed, Sid, Reason};
active_msg(_Other, _Data) ->
    ignore.

nonempty_binary(<<>>) -> ignore;
nonempty_binary(D) -> {binary, D}.

%% @private Route an inbound event into the right passive queue.
route_passive({stream, Sid, _Type, D}, #wt_data{default_stream = Sid} = Data) ->
    deliver_primary_nonempty({binary, D}, Data);
route_passive({stream_fin, Sid, _Type, D}, #wt_data{default_stream = Sid} = Data) ->
    %% Server closed the default stream; drop our id so the next send opens
    %% a fresh one.
    deliver_primary_nonempty({binary, D}, Data#wt_data{default_stream = undefined});
route_passive({stream, Sid, _Type, D}, Data) ->
    case maps:is_key(Sid, Data#wt_data.streams) of
        true -> deliver_stream(Sid, {data, D}, Data);
        false -> deliver_primary({stream, Sid, D}, Data)
    end;
route_passive({stream_fin, Sid, _Type, D}, Data) ->
    case maps:is_key(Sid, Data#wt_data.streams) of
        true -> deliver_stream(Sid, {fin, D}, Data);
        false -> deliver_primary({stream_fin, Sid, D}, Data)
    end;
route_passive({datagram, D}, Data) ->
    deliver_primary({datagram, D}, Data);
route_passive({stream_closed, Sid, Reason}, Data) ->
    case maps:is_key(Sid, Data#wt_data.streams) of
        true -> deliver_stream(Sid, {closed, Reason}, Data);
        false -> deliver_primary({stream_closed, Sid, Reason}, Data)
    end;
route_passive(_Other, _Data) ->
    keep_state_and_data.

%% @private In active mode the default stream still has to be forgotten on
%% FIN so a later send reopens it.
clear_default_on_fin({stream_fin, Sid, _Type, _D}, #wt_data{default_stream = Sid} = Data) ->
    Data#wt_data{default_stream = undefined};
clear_default_on_fin(_Event, Data) ->
    Data.

%%====================================================================
%% Internal: primary channel buffering
%%====================================================================

deliver_primary_nonempty({binary, <<>>}, _Data) ->
    keep_state_and_data;
deliver_primary_nonempty(Msg, Data) ->
    deliver_primary(Msg, Data).

%% @private Hand a primary-channel message to a waiting reader or buffer it.
deliver_primary(Msg, #wt_data{recv_from = undefined} = Data) ->
    enqueue_primary(Msg, Data);
deliver_primary(Msg, #wt_data{recv_from = From} = Data) ->
    {keep_state, Data#wt_data{recv_from = undefined},
     [{reply, From, {ok, Msg}}, {{timeout, recv}, cancel}]}.

enqueue_primary(Msg, #wt_data{recv_q = Q} = Data) ->
    case add_bytes(msg_size(Msg), Data) of
        {ok, Data1} ->
            {keep_state, Data1#wt_data{recv_q = queue:in(Msg, Q)}};
        overflow ->
            overflow(Data)
    end.

%%====================================================================
%% Internal: per-stream buffering
%%====================================================================

%% @private Serve a per-stream recv from the buffer or wait for data.
do_stream_recv(From, Sid, #stream{q = Q} = S, Timeout, Data) ->
    case queue:out(Q) of
        {{value, Item}, Q1} ->
            Data1 = sub_bytes(item_size(Item), Data),
            Streams = maps:put(Sid, S#stream{q = Q1}, Data1#wt_data.streams),
            {keep_state, Data1#wt_data{streams = Streams},
             [{reply, From, stream_item_result(Item)}]};
        {empty, _} ->
            case S#stream.closed of
                undefined ->
                    Streams = maps:put(Sid, S#stream{from = From}, Data#wt_data.streams),
                    {keep_state, Data#wt_data{streams = Streams},
                     recv_timer({srecv, Sid}, Timeout)};
                Reason ->
                    {keep_state_and_data, [{reply, From, {error, map_stream_reason(Reason)}}]}
            end
    end.

%% @private Hand a per-stream terminal event to a waiting reader or record it.
deliver_stream(Sid, {closed, Reason}, Data) ->
    S = maps:get(Sid, Data#wt_data.streams),
    case S#stream.from of
        undefined ->
            buffer_stream(Sid, S, {closed, Reason}, Data);
        From ->
            S1 = S#stream{from = undefined, closed = Reason},
            Streams = maps:put(Sid, S1, Data#wt_data.streams),
            {keep_state, Data#wt_data{streams = Streams},
             [{reply, From, {error, map_stream_reason(Reason)}},
              {{timeout, {srecv, Sid}}, cancel}]}
    end;
%% @private Hand a per-stream data/fin item to a waiting reader or buffer it.
deliver_stream(Sid, Item, Data) ->
    S = maps:get(Sid, Data#wt_data.streams),
    case S#stream.from of
        undefined ->
            buffer_stream(Sid, S, Item, Data);
        From ->
            S1 = S#stream{from = undefined, closed = closed_after(Item, S#stream.closed)},
            Streams = maps:put(Sid, S1, Data#wt_data.streams),
            {keep_state, Data#wt_data{streams = Streams},
             [{reply, From, stream_item_result(Item)}, {{timeout, {srecv, Sid}}, cancel}]}
    end.

buffer_stream(Sid, S, {closed, Reason}, Data) ->
    %% No bytes to buffer; just record the terminal state.
    Streams = maps:put(Sid, S#stream{closed = Reason}, Data#wt_data.streams),
    {keep_state, Data#wt_data{streams = Streams}};
buffer_stream(Sid, S, Item, Data) ->
    case add_bytes(item_size(Item), Data) of
        {ok, Data1} ->
            S1 = S#stream{q = queue:in(Item, S#stream.q),
                          closed = closed_after(Item, S#stream.closed)},
            Streams = maps:put(Sid, S1, Data1#wt_data.streams),
            {keep_state, Data1#wt_data{streams = Streams}};
        overflow ->
            overflow(Data)
    end.

%% @private A delivered FIN means the stream is half-closed for reading
%% once the queue drains.
closed_after({fin, _}, undefined) -> normal;
closed_after(_Item, Closed) -> Closed.

stream_item_result({data, D}) -> {ok, D};
stream_item_result({fin, D}) -> {ok, {fin, D}}.

map_stream_reason(normal) -> closed;
map_stream_reason(Reason) -> Reason.

item_size({data, D}) -> byte_size(D);
item_size({fin, D}) -> byte_size(D);
item_size({closed, _}) -> 0.

%%====================================================================
%% Internal: buffer accounting and lifecycle
%%====================================================================

%% @private Pop a primary-channel message, adjusting the byte counter.
dequeue(Q, Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {value, Msg, Q1, sub_bytes(msg_size(Msg), Data)};
        {empty, _} = E ->
            E
    end.

add_bytes(_Size, #wt_data{max_recv_buffer = infinity} = Data) ->
    {ok, Data};
add_bytes(Size, #wt_data{recv_bytes = B, max_recv_buffer = Max} = Data) ->
    NewBytes = B + Size,
    case NewBytes > Max of
        true -> overflow;
        false -> {ok, Data#wt_data{recv_bytes = NewBytes}}
    end.

sub_bytes(Size, #wt_data{recv_bytes = B} = Data) ->
    Data#wt_data{recv_bytes = max(0, B - Size)}.

%% @private Receive buffer cap exceeded: tear the session down.
overflow(Data) ->
    close_session_safe(Data),
    _ = maybe_notify_error(recv_buffer_overflow, Data),
    {next_state, closed, Data#wt_data{closed_reason = recv_buffer_overflow}}.

msg_size({binary, B}) -> byte_size(B);
msg_size({datagram, B}) -> byte_size(B);
msg_size({stream, _, B}) -> byte_size(B);
msg_size({stream_fin, _, B}) -> byte_size(B);
msg_size({stream_closed, _, _}) -> 0.

%% @private Apply a new active mode, flushing buffered messages into active
%% delivery as we switch.
apply_active(false, Data) ->
    Data#wt_data{active = false};
apply_active(true, Data) ->
    flush_all(Data#wt_data{active = true});
apply_active(once, #wt_data{owner = Owner} = Data) ->
    case dequeue(Data#wt_data.recv_q, Data) of
        {value, Msg, Q1, Data1} ->
            Owner ! {hackney_wt, self(), Msg},
            %% A single buffered message satisfies `once'; stay passive.
            Data1#wt_data{recv_q = Q1, active = false};
        {empty, _} ->
            Data#wt_data{active = once}
    end.

%% @private Forward every buffered message (primary + per-stream) to the
%% owner, then run with empty queues.
flush_all(#wt_data{owner = Owner, recv_q = Q, streams = Streams} = Data) ->
    lists:foreach(fun(Msg) -> Owner ! {hackney_wt, self(), Msg} end, queue:to_list(Q)),
    Streams1 = maps:map(
        fun(Sid, #stream{q = SQ} = S) ->
            lists:foreach(
                fun(Item) -> Owner ! {hackney_wt, self(), stream_active_msg(Sid, Item)} end,
                queue:to_list(SQ)),
            S#stream{q = queue:new()}
        end, Streams),
    Data#wt_data{recv_q = queue:new(), recv_bytes = 0, streams = Streams1}.

stream_active_msg(Sid, {data, D}) -> {stream, Sid, D};
stream_active_msg(Sid, {fin, D}) -> {stream_fin, Sid, D};
stream_active_msg(Sid, {closed, R}) -> {stream_closed, Sid, R}.

%% @private Handle the session ending (graceful close or crash). Reply to
%% any waiting reader, notify the owner in active mode, and move to closed
%% while keeping buffered data drainable.
session_ended(Reason, Data0) ->
    {Data1, Actions1} = fail_primary_reader(Reason, Data0),
    {Data2, Actions2} = fail_stream_readers(Reason, Data1),
    _ = case Data2#wt_data.active of
        false -> ok;
        _ -> maybe_notify_error(Reason, Data2)
    end,
    {next_state, closed, Data2#wt_data{closed_reason = Reason}, Actions1 ++ Actions2}.

fail_primary_reader(_Reason, #wt_data{recv_from = undefined} = Data) ->
    {Data, []};
fail_primary_reader(Reason, #wt_data{recv_from = From} = Data) ->
    {Data#wt_data{recv_from = undefined},
     [{reply, From, {error, Reason}}, {{timeout, recv}, cancel}]}.

fail_stream_readers(Reason, #wt_data{streams = Streams} = Data) ->
    maps:fold(
        fun(Sid, #stream{from = From} = S, {DAcc, AAcc}) when From =/= undefined ->
                Streams1 = maps:put(Sid, S#stream{from = undefined}, DAcc#wt_data.streams),
                {DAcc#wt_data{streams = Streams1},
                 [{reply, From, {error, Reason}}, {{timeout, {srecv, Sid}}, cancel} | AAcc]};
           (_Sid, _S, Acc) ->
                Acc
        end, {Data, []}, Streams).

%% @private In active mode, surface a graceful close as `closed' and any
%% other reason as an error.
maybe_notify_error(closed, #wt_data{owner = Owner}) ->
    Owner ! {hackney_wt, self(), closed};
maybe_notify_error(Reason, #wt_data{owner = Owner}) ->
    Owner ! {hackney_wt_error, self(), Reason}.

closed_reason(#wt_data{closed_reason = undefined}) -> closed;
closed_reason(#wt_data{closed_reason = R}) -> R.

%% @private gen_statem timeout action for a recv, or none for infinity.
recv_timer(_Name, infinity) -> [];
recv_timer(Name, Timeout) -> [{{timeout, Name}, Timeout, Name}].

%% @private Resolve the effective recv timeout (`default' uses the option).
recv_timeout(default, #wt_data{recv_timeout = T}) -> T;
recv_timeout(T, _Data) -> T.

%% @private Best-effort session close.
close_session_safe(#wt_data{session = undefined}) ->
    ok;
close_session_safe(#wt_data{session = Session}) ->
    try webtransport:close_session(Session) catch _:_ -> ok end,
    ok.
