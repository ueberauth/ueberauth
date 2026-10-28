%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2026 Benoît Chesneau <benoitc@pm.me>
%%%
%%% @doc gen_statem process for a single full-duplex HTTP/2 stream
%%% (gRPC-style bidirectional streaming).
%%%
%%% This module mirrors {@link hackney_wt} / {@link hackney_ws}: an
%%% application gets a pid and uses `send'/`recv' (passive) or active-mode
%%% messages. It owns one dedicated HTTP/2 connection (negotiated via ALPN)
%%% and opens one stream on it whose events are routed here directly by the
%%% `h2' library's per-stream handler mechanism, so the request body and the
%%% response can be sent and read interleaved on the same stream.
%%%
%%% == Send / receive ==
%%%
%%% `send/2,3' writes a DATA frame (optionally with END_STREAM via `fin').
%%% `send_trailers/2' closes the send side with trailing HEADERS (gRPC
%%% carries grpc-status there). `recv/1,2' returns the next inbound message:
%%% `{response, Status, Headers}', `{data, Data}', `{trailers, Trailers}' or
%%% `done' (the peer ended the stream). After `done', recv returns
%%% `{error, closed}'.
%%%
%%% == Delivery modes ==
%%%
%%% Passive (default): messages are buffered and read with `recv'. Active
%%% (`{active, true|once}'): every message is forwarded to the owner as
%%% `{hackney_h2, Pid, Msg}', and errors as `{hackney_h2_error, Pid, Reason}'.
%%%
%%% == Flow control ==
%%%
%%% With `{flow_control, manual}' the receive window is only replenished by
%%% `consume/2', so a slow reader applies backpressure to the peer. The
%%% default `auto' replenishes automatically.
%%%
%%% States: idle (not yet connected), connected (ready), closed (stream/conn
%%% ended, buffered data still drainable).
-module(hackney_h2_stream).
-behaviour(gen_statem).

%% API
-export([
    start_link/1,
    connect/1, connect/2,
    send/2, send/3,
    send_trailers/2,
    recv/1, recv/2,
    consume/2,
    setopts/2,
    controlling_process/2,
    close/1
]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).

%% State functions
-export([idle/3, connected/3, closed/3]).

-define(CONNECT_TIMEOUT, 8000).
-define(RECV_TIMEOUT, infinity).
%% Bound the decoded bytes buffered in the passive recv queue so a hostile
%% peer cannot drive the client to OOM; complements HTTP/2 flow control.
-define(DEFAULT_MAX_RECV_BUFFER, 16#4000000). %% 64 MiB

%% A normalized inbound message handed to recv/2 or, in active mode, the owner.
-type h2_msg() :: {response, non_neg_integer(), list()}
                | {data, binary()}
                | {trailers, list()}
                | done.

-export_type([h2_msg/0]).

-record(h2s_data, {
    %% Stream owner (linked via start_link, trap_exit handles death)
    owner :: pid(),

    %% Request identity used to open the stream
    method :: binary(),
    host :: string() | binary(),
    port :: inet:port_number(),
    transport :: module(),
    path :: binary(),
    headers = [] :: list(),

    %% Connection setup
    connect_options = [] :: list(),
    ssl_options = [] :: list(),
    connect_timeout = ?CONNECT_TIMEOUT :: timeout(),
    recv_timeout = ?RECV_TIMEOUT :: timeout(),
    flow_control = auto :: auto | manual,
    active = false :: false | true | once,

    %% Underlying hackney_conn (dedicated, owned here) and the h2 stream
    conn_pid :: pid() | undefined,
    conn_mon :: reference() | undefined,
    h2_conn :: pid() | undefined,
    stream_id :: pos_integer() | undefined,

    %% Passive recv buffering
    recv_q = queue:new() :: queue:queue(),
    recv_from :: gen_statem:from() | undefined,
    recv_bytes = 0 :: non_neg_integer(),
    max_recv_buffer = ?DEFAULT_MAX_RECV_BUFFER :: non_neg_integer() | infinity,

    %% Peer END_STREAM seen (no more inbound after the queue drains)
    ended = false :: boolean(),
    closed_reason :: term()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a stream process. See hackney:h2_open/3,4 for option docs.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, [self(), Opts], []).

%% @doc Establish the connection and open the stream. Blocks until ready.
-spec connect(pid()) -> ok | {error, term()}.
connect(Pid) ->
    connect(Pid, ?CONNECT_TIMEOUT).

-spec connect(pid(), timeout()) -> ok | {error, term()}.
connect(Pid, Timeout) ->
    gen_statem:call(Pid, {connect, Timeout}, infinity).

%% @doc Send a DATA frame on the stream (no END_STREAM).
-spec send(pid(), iodata()) -> ok | {error, term()}.
send(Pid, Data) ->
    send(Pid, Data, nofin).

%% @doc Send a DATA frame, optionally half-closing the send side (`fin').
-spec send(pid(), iodata(), fin | nofin) -> ok | {error, term()}.
send(Pid, Data, Fin) when Fin =:= fin; Fin =:= nofin ->
    gen_statem:call(Pid, {send, Data, Fin}).

%% @doc Send trailing HEADERS, half-closing the send side (gRPC trailers).
-spec send_trailers(pid(), list()) -> ok | {error, term()}.
send_trailers(Pid, Trailers) ->
    gen_statem:call(Pid, {send_trailers, Trailers}).

%% @doc Receive the next inbound message (passive mode only).
-spec recv(pid()) -> {ok, h2_msg()} | {error, term()}.
recv(Pid) ->
    gen_statem:call(Pid, {recv, default}, infinity).

-spec recv(pid(), timeout()) -> {ok, h2_msg()} | {error, term()}.
recv(Pid, Timeout) ->
    gen_statem:call(Pid, {recv, Timeout}, infinity).

%% @doc Acknowledge N consumed bytes (manual flow control only).
-spec consume(pid(), non_neg_integer()) -> ok | {error, term()}.
consume(Pid, NBytes) when is_integer(NBytes), NBytes >= 0 ->
    gen_statem:call(Pid, {consume, NBytes}).

%% @doc Set options. Supported: [{active, true|false|once}].
-spec setopts(pid(), list()) -> ok | {error, term()}.
setopts(Pid, Opts) ->
    gen_statem:call(Pid, {setopts, Opts}).

%% @doc Assign a new controlling process.
-spec controlling_process(pid(), pid()) -> ok | {error, term()}.
controlling_process(Pid, NewOwner) ->
    gen_statem:call(Pid, {controlling_process, NewOwner}).

%% @doc Cancel the stream and tear down the connection.
-spec close(pid()) -> ok.
close(Pid) ->
    gen_statem:cast(Pid, close).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

%% @private
callback_mode() ->
    [state_functions, state_enter].

%% @private
init([Owner, Opts]) ->
    process_flag(trap_exit, true),
    Data = #h2s_data{
        owner = Owner,
        method = maps:get(method, Opts, <<"POST">>),
        host = maps:get(host, Opts),
        port = maps:get(port, Opts),
        transport = maps:get(transport, Opts),
        path = maps:get(path, Opts, <<"/">>),
        headers = maps:get(headers, Opts, []),
        connect_options = maps:get(connect_options, Opts, []),
        ssl_options = maps:get(ssl_options, Opts, []),
        connect_timeout = maps:get(connect_timeout, Opts, ?CONNECT_TIMEOUT),
        recv_timeout = maps:get(recv_timeout, Opts, ?RECV_TIMEOUT),
        flow_control = maps:get(flow_control, Opts, auto),
        active = maps:get(active, Opts, false),
        max_recv_buffer = maps:get(max_recv_buffer, Opts, ?DEFAULT_MAX_RECV_BUFFER)
    },
    {ok, idle, Data}.

%% @private
terminate(_Reason, _State, #h2s_data{conn_pid = undefined}) ->
    ok;
terminate(_Reason, _State, #h2s_data{conn_pid = ConnPid}) ->
    stop_conn(ConnPid),
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
    case establish(Timeout, Data) of
        {ok, Data1} ->
            {next_state, connected, Data1, [{reply, From, ok}]};
        {error, Reason} ->
            {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
    end;

idle({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

idle(info, {'EXIT', Owner, _Reason}, #h2s_data{owner = Owner}) ->
    {stop, normal};

idle(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: connected
%%====================================================================

connected(enter, _OldState, _Data) ->
    keep_state_and_data;

%% --- send ------------------------------------------------------------
connected({call, From}, {send, SData, Fin},
          #h2s_data{h2_conn = H2Conn, stream_id = Sid}) ->
    EndStream = (Fin =:= fin),
    Reply = h2_call(fun() ->
        h2_connection:send_data(H2Conn, Sid, iolist_to_binary(SData), EndStream)
    end),
    {keep_state_and_data, [{reply, From, Reply}]};

connected({call, From}, {send_trailers, Trailers},
          #h2s_data{h2_conn = H2Conn, stream_id = Sid}) ->
    Reply = h2_call(fun() -> h2_connection:send_trailers(H2Conn, Sid, Trailers) end),
    {keep_state_and_data, [{reply, From, Reply}]};

connected({call, From}, {consume, NBytes},
          #h2s_data{h2_conn = H2Conn, stream_id = Sid}) ->
    Reply = h2_call(fun() -> h2_connection:consume(H2Conn, Sid, NBytes) end),
    {keep_state_and_data, [{reply, From, Reply}]};

%% --- recv ------------------------------------------------------------
connected({call, From}, {recv, _Timeout}, #h2s_data{active = Active})
  when Active =/= false ->
    {keep_state_and_data, [{reply, From, {error, {active_mode, Active}}}]};

connected({call, From}, {recv, _Timeout}, #h2s_data{recv_from = RF})
  when RF =/= undefined ->
    {keep_state_and_data, [{reply, From, {error, recv_busy}}]};

connected({call, From}, {recv, Timeout0}, Data) ->
    Timeout = recv_timeout(Timeout0, Data),
    case dequeue(Data) of
        {value, Msg, Data1} ->
            {keep_state, Data1, [{reply, From, {ok, Msg}}]};
        empty ->
            case Data#h2s_data.ended of
                true ->
                    {keep_state_and_data, [{reply, From, {error, closed}}]};
                false ->
                    {keep_state, Data#h2s_data{recv_from = From}, recv_timer(Timeout)}
            end
    end;

%% --- options ---------------------------------------------------------
connected({call, From}, {setopts, Opts}, Data) ->
    case proplists:get_value(active, Opts) of
        undefined ->
            {keep_state_and_data, [{reply, From, ok}]};
        NewActive when NewActive =:= true; NewActive =:= false; NewActive =:= once ->
            {keep_state, apply_active(NewActive, Data), [{reply, From, ok}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, badarg}}]}
    end;

connected({call, From}, {controlling_process, NewOwner}, #h2s_data{owner = OldOwner} = Data) ->
    unlink(OldOwner),
    link(NewOwner),
    {keep_state, Data#h2s_data{owner = NewOwner}, [{reply, From, ok}]};

connected({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, badrequest}}]};

%% --- close -----------------------------------------------------------
connected(cast, close, Data) ->
    cancel_stream_safe(Data),
    stop_conn(Data#h2s_data.conn_pid),
    {next_state, closed, Data#h2s_data{closed_reason = closed}};

%% --- recv timeout ----------------------------------------------------
connected({timeout, recv}, recv, #h2s_data{recv_from = From} = Data)
  when From =/= undefined ->
    {keep_state, Data#h2s_data{recv_from = undefined}, [{reply, From, {error, timeout}}]};
connected({timeout, recv}, recv, _Data) ->
    keep_state_and_data;

%% --- stream events from the h2 connection ----------------------------
connected(info, {h2, H2Conn, Event}, #h2s_data{h2_conn = H2Conn} = Data) ->
    handle_h2_event(Event, Data);

%% The hackney_conn owning the h2 connection died.
connected(info, {'DOWN', Mon, process, _Pid, Reason}, #h2s_data{conn_mon = Mon} = Data) ->
    stream_ended(down_reason(Reason), Data#h2s_data{conn_pid = undefined, conn_mon = undefined});

connected(info, {'EXIT', Owner, _Reason}, #h2s_data{owner = Owner} = Data) ->
    cancel_stream_safe(Data),
    stop_conn(Data#h2s_data.conn_pid),
    {stop, normal};

connected(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: closed
%%====================================================================

closed(enter, _OldState, _Data) ->
    keep_state_and_data;

%% Drain whatever was buffered before the stream/connection ended.
closed({call, From}, {recv, _Timeout}, Data) ->
    case dequeue(Data) of
        {value, Msg, Data1} ->
            {keep_state, Data1, [{reply, From, {ok, Msg}}]};
        empty ->
            {keep_state_and_data, [{reply, From, {error, closed_reason(Data)}}]}
    end;

%% Once the stream has ended there is no receive window left to manage, so
%% consume is a harmless no-op (a slow reader may still be draining + acking
%% buffered chunks after the peer's END_STREAM arrived).
closed({call, From}, {consume, _NBytes}, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

closed({call, From}, {controlling_process, NewOwner}, #h2s_data{owner = OldOwner} = Data) ->
    unlink(OldOwner),
    link(NewOwner),
    {keep_state, Data#h2s_data{owner = NewOwner}, [{reply, From, ok}]};

closed({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closed}}]};

closed(cast, close, _Data) ->
    keep_state_and_data;

closed(info, {'EXIT', Owner, _Reason}, #h2s_data{owner = Owner}) ->
    {stop, normal};

closed(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% Internal: connection + stream setup
%%====================================================================

%% @private Open a dedicated HTTP/2 connection and one handler-routed stream.
establish(Timeout, Data) ->
    #h2s_data{host = Host, port = Port, transport = Transport,
              connect_options = COpts, ssl_options = SslOpts,
              recv_timeout = RT, method = Method, path = Path,
              headers = Headers, flow_control = FC} = Data,
    ConnOpts = #{
        %% This stream process owns the dedicated connection, so the
        %% connection closes even if the stream is killed before terminate/3.
        owner => self(),
        host => Host,
        port => Port,
        transport => Transport,
        connect_timeout => Timeout,
        recv_timeout => RT,
        connect_options => [{protocols, [http2]} | COpts],
        ssl_options => SslOpts
    },
    case hackney_conn_sup:start_conn(ConnOpts) of
        {ok, ConnPid} ->
            case hackney_conn:connect(ConnPid, Timeout) of
                ok ->
                    case hackney_conn:get_protocol(ConnPid) of
                        http2 ->
                            open_stream(ConnPid, Method, Path, Headers, FC, Data);
                        Other ->
                            stop_conn(ConnPid),
                            {error, {protocol_not_negotiated, Other}}
                    end;
                {error, Reason} ->
                    stop_conn(ConnPid),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

open_stream(ConnPid, Method, Path, Headers, FC, Data) ->
    case hackney_conn:open_h2_stream(ConnPid, Method, Path, Headers, self(),
                                     #{flow_control => FC}) of
        {ok, H2Conn, StreamId} ->
            Mon = erlang:monitor(process, ConnPid),
            {ok, Data#h2s_data{conn_pid = ConnPid, conn_mon = Mon,
                               h2_conn = H2Conn, stream_id = StreamId}};
        {error, Reason} ->
            stop_conn(ConnPid),
            {error, Reason}
    end.

%%====================================================================
%% Internal: inbound stream events
%%====================================================================

%% @private Map an {h2, Conn, Event} stream event onto recv messages.
handle_h2_event({response, _Sid, Status, Headers}, Data) ->
    deliver({response, Status, Headers}, Data);
handle_h2_event({informational, _Sid, _Status, _Headers}, Data) ->
    {keep_state, Data};
handle_h2_event({data, _Sid, Body, false}, Data) ->
    case Body of
        <<>> -> {keep_state, Data};
        _ -> deliver({data, Body}, Data)
    end;
handle_h2_event({data, _Sid, Body, true}, Data) ->
    Data1 = case Body of
        <<>> -> Data;
        _ -> deliver_acc({data, Body}, Data)
    end,
    finish(Data1);
handle_h2_event({trailers, _Sid, Trailers}, Data) ->
    Data1 = deliver_acc({trailers, Trailers}, Data),
    finish(Data1);
handle_h2_event({stream_reset, _Sid, ErrorCode}, Data) ->
    stream_ended({stream_error, ErrorCode}, Data);
handle_h2_event({goaway, _LastSid, _ErrorCode}, #h2s_data{ended = true}) ->
    keep_state_and_data;
handle_h2_event({goaway, _LastSid, ErrorCode}, Data) ->
    stream_ended({goaway, ErrorCode}, Data);
handle_h2_event({closed, Reason}, Data) ->
    stream_ended(down_reason(Reason), Data);
handle_h2_event(_Other, Data) ->
    {keep_state, Data}.

%% @private Deliver a message, returning the gen_statem transition.
deliver(Msg, Data) ->
    {keep_state, deliver_acc(Msg, Data)}.

%% @private Deliver/buffer a message and return the updated #h2s_data only,
%% so callers can chain (e.g. data then done).
deliver_acc(Msg, #h2s_data{active = Active} = Data) when Active =/= false ->
    _ = (Data#h2s_data.owner) ! {hackney_h2, self(), Msg},
    case Active of
        once -> Data#h2s_data{active = false};
        true -> Data
    end;
deliver_acc(Msg, #h2s_data{recv_from = From} = Data) when From =/= undefined ->
    gen_statem:reply(From, {ok, Msg}),
    %% A pending {timeout, recv} may still fire; it is a no-op once recv_from
    %% is cleared (see the connected/closed {timeout, recv} clauses).
    Data#h2s_data{recv_from = undefined};
deliver_acc(Msg, Data) ->
    enqueue(Msg, Data).

%% @private Mark the stream ended and surface a terminal `done', then move to
%% closed (buffered data stays drainable).
finish(Data0) ->
    Data1 = deliver_acc(done, Data0#h2s_data{ended = true}),
    {next_state, closed, Data1#h2s_data{closed_reason = closed}}.

%% @private The stream/connection ended abnormally: fail a waiting reader,
%% notify the owner in active mode, move to closed.
stream_ended(Reason, #h2s_data{recv_from = From} = Data) when From =/= undefined ->
    _ = maybe_notify_error(Reason, Data),
    {next_state, closed,
     Data#h2s_data{recv_from = undefined, ended = true, closed_reason = Reason},
     [{reply, From, {error, Reason}}]};
stream_ended(Reason, Data) ->
    _ = maybe_notify_error(Reason, Data),
    {next_state, closed, Data#h2s_data{ended = true, closed_reason = Reason}}.

maybe_notify_error(_Reason, #h2s_data{active = false}) ->
    ok;
maybe_notify_error(closed, #h2s_data{owner = Owner}) ->
    Owner ! {hackney_h2, self(), {closed, closed}};
maybe_notify_error(Reason, #h2s_data{owner = Owner}) ->
    Owner ! {hackney_h2_error, self(), Reason}.

%%====================================================================
%% Internal: passive buffering
%%====================================================================

enqueue(Msg, #h2s_data{recv_q = Q} = Data) ->
    case add_bytes(msg_size(Msg), Data) of
        {ok, Data1} ->
            Data1#h2s_data{recv_q = queue:in(Msg, Q)};
        overflow ->
            %% Tear the connection down; recv surfaces the overflow reason.
            cancel_stream_safe(Data),
            stop_conn(Data#h2s_data.conn_pid),
            Data#h2s_data{ended = true, closed_reason = recv_buffer_overflow}
    end.

dequeue(#h2s_data{recv_q = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {value, Msg, sub_bytes(msg_size(Msg), Data#h2s_data{recv_q = Q1})};
        {empty, _} ->
            empty
    end.

add_bytes(_Size, #h2s_data{max_recv_buffer = infinity} = Data) ->
    {ok, Data};
add_bytes(Size, #h2s_data{recv_bytes = B, max_recv_buffer = Max} = Data) ->
    case B + Size > Max of
        true -> overflow;
        false -> {ok, Data#h2s_data{recv_bytes = B + Size}}
    end.

sub_bytes(Size, #h2s_data{recv_bytes = B} = Data) ->
    Data#h2s_data{recv_bytes = max(0, B - Size)}.

msg_size({data, B}) -> byte_size(B);
msg_size(_) -> 0.

%% @private Apply a new active mode, flushing buffered messages on the way.
apply_active(false, Data) ->
    Data#h2s_data{active = false};
apply_active(true, #h2s_data{owner = Owner, recv_q = Q} = Data) ->
    lists:foreach(fun(Msg) -> Owner ! {hackney_h2, self(), Msg} end, queue:to_list(Q)),
    Data#h2s_data{active = true, recv_q = queue:new(), recv_bytes = 0};
apply_active(once, #h2s_data{owner = Owner} = Data) ->
    case dequeue(Data) of
        {value, Msg, Data1} ->
            Owner ! {hackney_h2, self(), Msg},
            Data1#h2s_data{active = false};
        empty ->
            Data#h2s_data{active = once}
    end.

%%====================================================================
%% Internal: helpers
%%====================================================================

recv_timer(infinity) -> [];
recv_timer(Timeout) -> [{{timeout, recv}, Timeout, recv}].

recv_timeout(default, #h2s_data{recv_timeout = T}) -> T;
recv_timeout(T, _Data) -> T.

closed_reason(#h2s_data{closed_reason = undefined}) -> closed;
closed_reason(#h2s_data{closed_reason = R}) -> R.

down_reason(normal) -> closed;
down_reason(shutdown) -> closed;
down_reason({shutdown, _}) -> closed;
down_reason(Reason) -> {closed, Reason}.

%% @private Run an h2_connection call, normalising a dead-connection exit.
h2_call(Fun) ->
    try Fun()
    catch
        exit:{ExitReason, _} -> {error, {closed, ExitReason}};
        exit:ExitReason      -> {error, {closed, ExitReason}}
    end.

cancel_stream_safe(#h2s_data{h2_conn = undefined}) ->
    ok;
cancel_stream_safe(#h2s_data{h2_conn = H2Conn, stream_id = Sid}) ->
    _ = try h2_connection:cancel_stream(H2Conn, Sid) catch _:_ -> ok end,
    ok.

stop_conn(undefined) ->
    ok;
stop_conn(ConnPid) ->
    try hackney_conn:stop(ConnPid) catch _:_ -> ok end,
    ok.
