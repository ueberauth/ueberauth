%%% -*- erlang -*-
%%%
%%% QUIC Distribution Controller
%%% Per-connection controller for Erlang distribution over QUIC
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Per-connection distribution controller.
%%%
%%% This module manages a single distribution connection over QUIC,
%%% handling:
%%%
%%% - Control stream (stream 0) for handshake and tick messages
%%% - Data stream pool for distribution messages
%%% - Message framing with length prefixes
%%% - Tick handling for connection liveness
%%% - Stream prioritization
%%%
%%% == Stream Layout ==
%%%
%%% Stream 0: Control (urgency 0)
%%%   - Distribution handshake messages
%%%   - Tick messages
%%%   - Link/monitor signals
%%%
%%% Streams 4,8,12...: Data (urgency 4-6)
%%%   - Regular distribution messages
%%%   - Round-robin scheduling
%%%
%%% @end

-module(quic_dist_controller).
-behaviour(gen_statem).

-include("quic_dist.hrl").
-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/logger.hrl").

-define(QUIC_LOG_META, #{
    domain => [erlang_quic, dist_controller], report_cb => fun quic_log:format_report/2
}).

%% Maximum messages to deliver per batch in input handler before yielding.
%% Prevents blocking on dist_ctrl_put_data during heavy incoming traffic.
-define(INPUT_HANDLER_BATCH_SIZE, 32).

%% Pending tick retry interval in milliseconds.
%% When a tick send fails due to flow control or queue full, retry aggressively.
%% Use short interval (10ms) to ensure tick gets through during brief congestion windows.
-define(PENDING_TICK_RETRY_MS, 10).

%% API
-export([
    start_link/2,
    start_link/3,
    adopt_owner_events/2,
    send/2,
    recv/3,
    tick/1,
    getstat/1,
    get_address/2,
    set_supervisor/2,
    set_handshake_owner/2,
    set_node/2,
    get_node/1,
    getll/1,
    pre_nodeup/1
]).

%% User stream API
-export([
    open_user_stream/2,
    open_user_stream/3,
    send_user_data/4,
    close_user_stream/2,
    reset_user_stream/2,
    reset_user_stream/3,
    accept_user_streams/2,
    stop_accepting_streams/1,
    controlling_process/3,
    list_user_streams/1
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
    init_state/3,
    handshaking/3,
    connected/3
]).

-ifdef(TEST).
-export([deliver_complete_messages/3, deliver_complete_messages/4, input_handler_loop/6]).
-endif.

%% Internal state
-record(state, {
    %% Connection (pid, receives {quic, Conn, Event} messages)
    conn :: pid(),
    role :: client | server,

    %% Streams
    control_stream :: non_neg_integer() | undefined,
    data_streams = [] :: [non_neg_integer()],

    %% Receive buffer for control stream (handshake only)
    recv_buffer = <<>> :: binary(),
    recv_queue = queue:new() :: queue:queue(),
    recv_waiters = [] :: [{pid(), reference(), non_neg_integer()}],

    %% Pending data stream buffer (for data arriving before connected state)
    %% Per-stream: framing must NOT interleave bytes from different streams.
    pending_data_buffers = #{} ::
        #{StreamId :: non_neg_integer() => binary()},

    %% Send queues for pending messages — per-stream so a backpressure
    %% stall on one stream cannot let later sends to that stream
    %% overtake older queued ones.
    send_queues = #{} ::
        #{StreamId :: non_neg_integer() => queue:queue(iodata())},

    %% In-flight fragmented messages: maps the SeqId from the FRAGMENT
    %% header (tag 69 = 'E') to the stream id chosen for the first
    %% fragment, so every continuation (tag 70 = 'F') of the same
    %% logical message routes to the same stream.
    in_flight_fragments = #{} ::
        #{SeqId :: non_neg_integer() => StreamId :: non_neg_integer()},

    %% Supervision
    supervisor :: pid() | undefined,
    kernel :: pid() | undefined,

    %% The dist_util process this controller serves. dist_util expects
    %% the transport to go with it, so its exit closes the connection.
    handshake_owner_mon :: reference() | undefined,

    %% Remote node info
    node :: node() | undefined,

    %% Tick handling
    tick_time :: non_neg_integer() | undefined,
    tick_ref :: reference() | undefined,

    %% Distribution handle (from erlang:setnode)
    dhandle :: term() | undefined,
    input_handler :: pid() | undefined,

    %% Statistics
    recv_cnt = 0 :: non_neg_integer(),
    send_cnt = 0 :: non_neg_integer(),
    recv_oct = 0 :: non_neg_integer(),
    send_oct = 0 :: non_neg_integer(),

    %% Session ticket for 0-RTT
    session_ticket :: term() | undefined,

    %% Backpressure tuning (from quic_dist_config or defaults)
    max_pull = ?DEFAULT_MAX_PULL_PER_NOTIFICATION :: pos_integer(),
    backpressure_retry = ?DEFAULT_BACKPRESSURE_RETRY_MS :: pos_integer(),

    %% Pending tick flag - set when tick send fails due to backpressure
    pending_tick = false :: boolean(),
    %% Timer for retrying pending tick sends
    pending_tick_timer :: reference() | undefined,
    %% Last time we sent data (for tick response rate limiting)
    last_send_time = 0 :: integer(),
    %% Last time we sent a tick response (to prevent feedback loops)
    last_tick_response = 0 :: integer(),

    %% User stream support
    %% Map of StreamId -> #user_stream{} for user-accessible streams
    user_streams = #{} :: #{non_neg_integer() => #user_stream{}},
    %% Acceptor pool: list of {Pid, MonitorRef} for processes accepting incoming streams
    acceptor_pool = [] :: [{pid(), reference()}],
    %% Round-robin index for acceptor selection
    acceptor_idx = 0 :: non_neg_integer(),

    %% Pending auth handshake (server role). `undefined' means the
    %% connection is admitted as soon as it is set up.
    auth = undefined :: undefined | {quic_dist:auth_callback(), timeout()}
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a controller for a QUIC distribution connection.
-spec start_link(Conn :: pid(), Role :: client | server) ->
    {ok, pid()} | {error, term()}.
start_link(Conn, Role) ->
    start_link(Conn, Role, undefined).

%% @doc Start a controller, optionally gating it behind an auth handshake.
%%
%% With an auth spec the server-role controller stays in `init_state'
%% until the QUIC handshake completes, runs the callback, and only then
%% admits the connection to `dist_util'.
-spec start_link(
    Conn :: pid(),
    Role :: client | server,
    Auth :: undefined | {quic_dist:auth_callback(), timeout()}
) ->
    {ok, pid()} | {error, term()}.
start_link(Conn, Role, Auth) when Role =:= client; Role =:= server ->
    gen_statem:start_link(?MODULE, {Conn, Role, Auth}, []).

%% @doc Hand QUIC events buffered by a previous owner to a controller.
%%
%% The connecting setup process owns the connection until the controller
%% starts, and the controller takes ownership in its `init/1', so by the
%% time this runs the caller's mailbox holds exactly what arrived before
%% the swap and can receive nothing further.
%%
%% Only events the controller understands cross over. A setup process may
%% also have run an auth callback on a stream of its own; those bytes are
%% not distribution traffic, and `forward_pending_data/1' would feed them
%% to the VM's dist input. Anything not matched here stays in the caller's
%% mailbox, which is what `{'EXIT', _, remarked}' and the setup timer
%% depend on.
-spec adopt_owner_events(Conn :: pid(), Controller :: pid()) -> non_neg_integer().
adopt_owner_events(Conn, Controller) ->
    adopt_owner_events(Conn, Controller, 0).

adopt_owner_events(Conn, Controller, N) ->
    receive
        {quic, C, {stream_data, ?QUIC_DIST_CONTROL_STREAM, _, _}} = Msg when C =:= Conn ->
            Controller ! Msg,
            adopt_owner_events(Conn, Controller, N + 1);
        {quic, C, {connected, _}} = Msg when C =:= Conn ->
            Controller ! Msg,
            adopt_owner_events(Conn, Controller, N + 1);
        {quic, C, {stream_opened, _}} = Msg when C =:= Conn ->
            Controller ! Msg,
            adopt_owner_events(Conn, Controller, N + 1);
        {quic, C, {session_ticket, _}} = Msg when C =:= Conn ->
            Controller ! Msg,
            adopt_owner_events(Conn, Controller, N + 1);
        {quic, C, {closed, _}} = Msg when C =:= Conn ->
            Controller ! Msg,
            adopt_owner_events(Conn, Controller, N + 1);
        {quic, C, {transport_error, _, _}} = Msg when C =:= Conn ->
            Controller ! Msg,
            adopt_owner_events(Conn, Controller, N + 1)
    after 0 ->
        N
    end.

%% @doc Send data on the control stream.
-spec send(Controller :: pid(), Data :: iodata()) -> ok | {error, term()}.
send(Controller, Data) ->
    gen_statem:call(Controller, {send, Data}).

%% @doc Receive data from the control stream.
-spec recv(
    Controller :: pid(),
    Length :: non_neg_integer(),
    Timeout :: timeout()
) ->
    {ok, [byte()]} | {error, term()}.
recv(Controller, Length, Timeout) ->
    gen_statem:call(Controller, {recv, Length}, Timeout).

%% @doc Send a tick message.
-spec tick(Controller :: pid()) -> ok.
tick(Controller) ->
    gen_statem:cast(Controller, tick).

%% @doc Get connection statistics.
-spec getstat(Controller :: pid()) ->
    {ok, RecvCnt :: non_neg_integer(), SendCnt :: non_neg_integer(), SendPend :: non_neg_integer()}.
getstat(Controller) ->
    gen_statem:call(Controller, getstat).

%% @doc Get address information for the connection.
-spec get_address(Controller :: pid(), Node :: node()) ->
    {ok, #net_address{}}.
get_address(Controller, Node) ->
    gen_statem:call(Controller, {get_address, Node}).

%% @doc Set the supervisor process (kernel).
-spec set_supervisor(Controller :: pid(), Supervisor :: pid()) -> ok.
set_supervisor(Controller, Supervisor) ->
    gen_statem:cast(Controller, {set_supervisor, Supervisor}).

%% @doc Name the dist_util process this controller serves.
%%
%% `dist_util' owns the transport in stock distribution, so net_kernel
%% resolves a simultaneous connect by killing the losing handshake
%% process and lets the peer discover the dropped socket. Here the
%% connection belongs to the controller, so it has to follow that
%% process down itself. Synchronous: the caller hands control to
%% dist_util straight after, and by then the connection must already be
%% tied to it.
-spec set_handshake_owner(Controller :: pid(), Owner :: pid()) -> ok.
set_handshake_owner(Controller, Owner) when is_pid(Owner) ->
    gen_statem:call(Controller, {set_handshake_owner, Owner}).

%% @doc Set the other node name.
-spec set_node(Controller :: pid(), Node :: node()) -> ok.
set_node(Controller, Node) ->
    gen_statem:cast(Controller, {set_node, Node}).

%% @doc Get the other node name.
-spec get_node(Controller :: pid()) -> {ok, node()} | undefined.
get_node(Controller) ->
    gen_statem:call(Controller, get_node).

%% @doc Get low-level controller (self).
-spec getll(Controller :: pid()) -> {ok, pid()}.
getll(Controller) ->
    gen_statem:call(Controller, getll).

%% @doc Pre-nodeup callback - sends dist_ctrlr message to kernel.
%% Called by f_setopts_pre_nodeup. SetupPid is the calling process.
-spec pre_nodeup(Controller :: pid()) -> ok.
pre_nodeup(Controller) ->
    gen_statem:call(Controller, {pre_nodeup, self()}).

%%====================================================================
%% User Stream API
%%====================================================================

%% @doc Open a user stream for application use.
%% Returns {ok, StreamId} on success.
-spec open_user_stream(Controller :: pid(), Owner :: pid()) ->
    {ok, non_neg_integer()} | {error, term()}.
open_user_stream(Controller, Owner) ->
    open_user_stream(Controller, Owner, []).

%% @doc Open a user stream with options.
%% Options:
%%   {priority, 16..255} - Stream priority (default: 128, lower = higher priority)
-spec open_user_stream(Controller :: pid(), Owner :: pid(), Opts :: list()) ->
    {ok, non_neg_integer()} | {error, term()}.
open_user_stream(Controller, Owner, Opts) ->
    gen_statem:call(Controller, {open_user_stream, Owner, Opts}).

%% @doc Send data on a user stream.
%% Fin=true marks the end of data on this stream.
-spec send_user_data(
    Controller :: pid(),
    StreamId :: non_neg_integer(),
    Data :: iodata(),
    Fin :: boolean()
) -> ok | {error, term()}.
send_user_data(Controller, StreamId, Data, Fin) ->
    gen_statem:call(Controller, {send_user_data, StreamId, Data, Fin}).

%% @doc Close a user stream.
-spec close_user_stream(Controller :: pid(), StreamId :: non_neg_integer()) ->
    ok | {error, term()}.
close_user_stream(Controller, StreamId) ->
    gen_statem:call(Controller, {close_user_stream, StreamId}).

%% @doc Reset/cancel a user stream (notifies peer immediately).
%% Uses default error code 0.
-spec reset_user_stream(Controller :: pid(), StreamId :: non_neg_integer()) ->
    ok | {error, term()}.
reset_user_stream(Controller, StreamId) ->
    reset_user_stream(Controller, StreamId, 0).

%% @doc Reset/cancel a user stream with a specific error code.
-spec reset_user_stream(
    Controller :: pid(), StreamId :: non_neg_integer(), ErrorCode :: non_neg_integer()
) ->
    ok | {error, term()}.
reset_user_stream(Controller, StreamId, ErrorCode) ->
    gen_statem:call(Controller, {reset_user_stream, StreamId, ErrorCode}).

%% @doc Register to accept incoming user streams.
%% The controller auto-assigns ownership of each new incoming stream
%% to the registered acceptor and delivers data directly as
%% `{quic_dist_stream, StreamRef, {data, Data, Fin}}' messages. No
%% prior `{incoming, StreamId}' handshake.
-spec accept_user_streams(Controller :: pid(), Acceptor :: pid()) ->
    ok | {error, term()}.
accept_user_streams(Controller, Acceptor) ->
    gen_statem:call(Controller, {accept_user_streams, Acceptor}).

%% @doc Stop accepting incoming user streams.
-spec stop_accepting_streams(Controller :: pid()) -> ok.
stop_accepting_streams(Controller) ->
    gen_statem:call(Controller, stop_accepting_streams).

%% @doc Transfer stream ownership to another process.
-spec controlling_process(Controller :: pid(), StreamId :: non_neg_integer(), NewOwner :: pid()) ->
    ok | {error, term()}.
controlling_process(Controller, StreamId, NewOwner) ->
    gen_statem:call(Controller, {controlling_process, StreamId, NewOwner}).

%% @doc List all user streams.
%% Returns a list of stream info maps.
-spec list_user_streams(Controller :: pid()) -> [map()].
list_user_streams(Controller) ->
    gen_statem:call(Controller, list_user_streams).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

callback_mode() ->
    [state_functions, state_enter].

%% Initialize for client role.
%%
%% The setup process owns the connection until this call, and it forwards
%% whatever it buffered once we return. Take ownership here rather than in
%% the `init_state' enter callback: gen_statem answers `start_link' before
%% running a state-enter callback, so a swap made there leaves a window in
%% which the connection still delivers to a process that has stopped
%% reading. Swapping in `init/1' makes the setup process's drain final.
init({Conn, client, _Auth}) ->
    case quic:set_owner_sync(Conn, self()) of
        ok ->
            State = init_backpressure_config(#state{
                conn = Conn,
                role = client
            }),
            {ok, init_state, State};
        {error, Reason} ->
            %% The peer can close during a slow auth callback, and a
            %% draining connection refuses the swap. `{error, _}' is
            %% gen_statem's silent termination: no crash report for a
            %% connection that simply went away.
            {error, {set_owner_failed, Reason}}
    end;
%% Initialize for server role. The listener installs us as the connection
%% owner before it hands the connection its first packet, so there is
%% nothing to take over here.
init({Conn, server, Auth}) ->
    State = init_backpressure_config(#state{
        conn = Conn,
        role = server,
        auth = Auth
    }),
    {ok, init_state, State}.

%% @private
%% Initialize backpressure configuration from application environment.
%% Reads max_pull_per_notification and backpressure_retry_ms from quic dist config.
init_backpressure_config(State) ->
    DistOpts = application:get_env(quic, dist, []),
    MaxPull = get_dist_opt(max_pull_per_notification, DistOpts, ?DEFAULT_MAX_PULL_PER_NOTIFICATION),
    RetryMs = get_dist_opt(backpressure_retry_ms, DistOpts, ?DEFAULT_BACKPRESSURE_RETRY_MS),
    State#state{
        max_pull = MaxPull,
        backpressure_retry = RetryMs
    }.

%% @private
%% Get option from dist config (supports both proplist and map).
get_dist_opt(Key, Opts, Default) when is_list(Opts) ->
    proplists:get_value(Key, Opts, Default);
get_dist_opt(Key, Opts, Default) when is_map(Opts) ->
    maps:get(Key, Opts, Default).

terminate(_Reason, _StateName, #state{
    conn = Conn, pending_tick_timer = Timer, user_streams = Streams, acceptor_pool = Pool
}) ->
    %% Cancel pending tick retry timer if running
    case Timer of
        undefined -> ok;
        TimerRef -> erlang:cancel_timer(TimerRef)
    end,
    %% Demonitor all user stream owners
    maps:foreach(
        fun(_StreamId, #user_stream{monitor = MonRef}) ->
            erlang:demonitor(MonRef, [flush])
        end,
        Streams
    ),
    %% Demonitor all acceptors in pool
    lists:foreach(
        fun({_Pid, MonRef}) ->
            erlang:demonitor(MonRef, [flush])
        end,
        Pool
    ),
    try
        quic:close(Conn, normal)
    catch
        _:_ -> ok
    end,
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%====================================================================
%% State: init_state
%%====================================================================

init_state(enter, _OldState, #state{role = client} = State) ->
    %% Client: ownership was taken in init/1; the connection is already
    %% established, so we can open our streams immediately.
    case setup_streams(State) of
        {ok, State1} ->
            {keep_state, State1, [{state_timeout, 0, start_handshake}]};
        {error, Reason} ->
            {stop, {stream_setup_failed, Reason}}
    end;
init_state(enter, _OldState, #state{role = server, conn = Conn} = State) ->
    %% Server: the listener made us the owner before the connection saw
    %% its first packet. This call is redundant, and is kept only so a
    %% controller started any other way still ends up owning its
    %% connection; nothing depends on its timing any more.
    ok = quic:set_owner_sync(Conn, self()),
    %% Setup streams - transition via timeout since enter can't change state
    case setup_streams(State) of
        {ok, State1} ->
            {keep_state, State1, [{state_timeout, 0, proceed_to_handshaking}]};
        {error, Reason} ->
            {stop, {stream_setup_failed, Reason}}
    end;
%% Without an auth callback the connection is admitted straight away. We
%% do not wait for `{connected, _}': the control stream is stream 0,
%% opened by the client.
init_state(state_timeout, proceed_to_handshaking, #state{auth = undefined} = State) ->
    {next_state, handshaking, State};
%% With one, hold here until the QUIC handshake completes and the
%% callback admits the peer. The deadline guards that wait, exactly as
%% the gatekeeper process it replaces did; it does not bound a callback
%% that has already started.
init_state(state_timeout, proceed_to_handshaking, #state{auth = {_, Timeout}} = State) ->
    {keep_state, State, [{state_timeout, Timeout, auth_timeout}]};
init_state(state_timeout, auth_timeout, #state{conn = Conn} = State) ->
    ?LOG_WARNING(
        #{what => dist_auth_handshake_timeout, conn => Conn},
        ?QUIC_LOG_META
    ),
    {stop, normal, State};
%% Handshake complete. With auth pending this is the gate; otherwise we
%% have already moved on and this is a late duplicate.
init_state(
    info,
    {quic, Conn, {connected, _Info}},
    #state{conn = Conn, auth = {Callback, Timeout}} = State
) ->
    case quic_dist_auth:run(Callback, Conn, server, Timeout) of
        {ok, _} ->
            %% Only now: notify_acceptor/1 starts the dist_util worker,
            %% whose f_send/f_recv are calls into this process. Notifying
            %% before the callback returns would deadlock them against it.
            quic_dist:notify_acceptor(self()),
            {next_state, handshaking, State#state{auth = undefined}};
        {error, Reason} ->
            ?LOG_WARNING(
                #{what => dist_auth_refused, conn => Conn, reason => Reason},
                ?QUIC_LOG_META
            ),
            %% terminate/3 closes the connection. Stop normal: a refused
            %% peer is an outcome, not a crash.
            {stop, normal, State}
    end;
init_state(info, {quic, Conn, {connected, _Info}}, #state{conn = Conn} = State) ->
    {keep_state, State};
init_state(state_timeout, start_handshake, State) ->
    {next_state, handshaking, State};
%% Dist handshake calls can arrive before we finish transitioning to
%% handshaking (accept_connection spawns the dist worker which calls
%% f_send/f_recv immediately). Defer them until the state transition.
init_state({call, _From}, {send, _Data}, State) ->
    {keep_state, State, [postpone]};
init_state({call, _From}, {recv, _Length}, State) ->
    {keep_state, State, [postpone]};
%% Handle QUIC errors during init
init_state(info, {quic, Conn, {closed, Reason}}, #state{conn = Conn}) ->
    {stop, close_reason(Reason)};
init_state(info, {quic, Conn, {transport_error, Code, Reason}}, #state{conn = Conn}) ->
    {stop, {transport_error, Code, Reason}};
init_state(EventType, Event, State) ->
    handle_common_event(EventType, Event, init_state, State).

%% @private
%% Set up control and data streams once connection is ready.
setup_streams(#state{role = client} = State) ->
    %% Client opens streams and sets priorities
    case open_control_stream(State) of
        {ok, StreamId, State1} ->
            %% Set stream priority (highest for control)
            case set_stream_priority(State1, StreamId, ?QUIC_DIST_URGENCY_CONTROL) of
                ok ->
                    State2 = State1#state{control_stream = StreamId},
                    %% Open data streams
                    open_data_streams(State2, ?QUIC_DIST_DATA_STREAMS);
                {error, Reason} ->
                    {error, {priority_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {control_stream_failed, Reason}}
    end;
setup_streams(#state{role = server} = State) ->
    %% Server uses stream 0 (opened by client) for control.
    %% Priority is set in connected/enter once stream 0 exists in streams map.
    {ok, State#state{control_stream = 0}}.

%%====================================================================
%% State: handshaking
%%====================================================================

handshaking(enter, _OldState, _State) ->
    keep_state_and_data;
%% Handle tick during handshake - send empty frame to keep connection alive
handshaking(cast, tick, State) ->
    State1 = do_send_tick_frame(State),
    {keep_state, State1};
%% Handle send during handshake
handshaking({call, From}, {send, Data}, State) ->
    case do_send_control(Data, State) of
        {ok, State1} ->
            {keep_state, State1, [{reply, From, ok}]};
        {error, Reason} ->
            ?LOG_WARNING(#{what => handshake_send_failed, reason => Reason}, ?QUIC_LOG_META),
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;
%% Handle recv during handshake
handshaking({call, From}, {recv, Length}, State) ->
    case try_recv(Length, State) of
        {ok, Data, State1} ->
            %% dist_util expects data as a list (charlist), not binary
            DataList = binary_to_list(Data),
            {keep_state, State1, [{reply, From, {ok, DataList}}]};
        {need_more, State1} ->
            %% Queue the waiter
            Ref = make_ref(),
            Waiters = [{From, Ref, Length} | State1#state.recv_waiters],
            {keep_state, State1#state{recv_waiters = Waiters}}
    end;
%% Handshake complete notification with DHandle
handshaking(info, {handshake_complete, Node, DHandle}, State) ->
    ?LOG_INFO(#{what => handshake_complete, node => Node}, ?QUIC_LOG_META),

    %% Set up distribution control machinery
    %% This is required for process-based distribution to work properly
    %% Note: Server opens data streams in connected/enter handler, not here,
    %% so we can set control stream priority first (which requires data_streams = [])

    %% Spawn input handler to receive QUIC data and deliver to VM
    Self = self(),
    Conn = State#state.conn,
    ControlStream = State#state.control_stream,
    InputHandler = spawn_link(
        fun() ->
            input_handler_loop(DHandle, Self, Conn, ControlStream)
        end
    ),

    %% Register input handler with VM
    ok = erlang:dist_ctrl_input_handler(DHandle, InputHandler),

    %% DON'T notify here - wait until we're in connected state
    %% The notification happens in the connected state's enter callback

    State1 = State#state{
        node = Node,
        dhandle = DHandle,
        input_handler = InputHandler
    },
    {next_state, connected, State1};
%% Legacy handshake complete notification (for backward compatibility)
handshaking(info, {handshake_complete, Node}, State) ->
    ?LOG_WARNING(#{what => handshake_complete_no_dhandle, node => Node}, ?QUIC_LOG_META),
    State1 = State#state{node = Node},
    {next_state, connected, State1};
handshaking(EventType, Event, State) ->
    handle_common_event(EventType, Event, handshaking, State).

%%====================================================================
%% State: connected
%%====================================================================

connected(
    enter, _OldState, #state{role = server, data_streams = [], dhandle = DHandle} = State
) when
    DHandle =/= undefined
->
    %% Set control stream (stream 0) priority now that stream exists in connection.
    %% This must happen AFTER handshake (stream creation) but BEFORE we start sending.
    %% Urgency 0 allows ticks to use control_allowance, bypassing congestion control.
    _ = set_stream_priority(State, 0, ?QUIC_DIST_URGENCY_CONTROL),
    %% Server needs to open data streams for sending distribution data
    case open_server_data_streams(State) of
        {ok, NewState} ->
            %% Forward any pending data stream content to input handler
            NewState2 = forward_pending_data(NewState),
            %% Notify VM we're ready for data
            erlang:dist_ctrl_get_data_notification(DHandle),
            {keep_state, NewState2};
        {error, Reason} ->
            ?LOG_ERROR(
                #{what => server_open_data_streams_failed, reason => Reason},
                ?QUIC_LOG_META
            ),
            {stop, {stream_setup_failed, Reason}, State}
    end;
connected(enter, _OldState, #state{dhandle = DHandle} = State) when DHandle =/= undefined ->
    %% Client already has data streams, just notify VM we're ready
    %% Forward any pending data stream content to input handler
    NewState = forward_pending_data(State),
    erlang:dist_ctrl_get_data_notification(DHandle),
    {keep_state, NewState};
connected(enter, _OldState, _State) ->
    %% No DHandle (shouldn't happen in normal flow)
    keep_state_and_data;
%% Handle send in connected state (direct send, not from VM).
%% `send/2' is bound to f_send in #hs_data{} and only used by dist_util
%% during the handshake — under normal post-handshake operation this
%% handler is unreachable. The function is exported, so route any caller
%% through the same picker + framing + per-stream queue as the VM path.
connected({call, From}, {send, DataIO}, State) ->
    #state{
        conn = Conn,
        data_streams = DataStreams,
        control_stream = Ctrl,
        in_flight_fragments = Frags
    } = State,
    Data = iolist_to_binary(DataIO),
    case quic_dist_dispatch:pick_stream(Data, DataStreams, Ctrl, Frags) of
        {{ok, Sid}, Frags1} ->
            State1 = State#state{in_flight_fragments = Frags1},
            case try_send(Conn, Sid, Data, State1) of
                {ok, State2} ->
                    {keep_state, State2, [{reply, From, ok}]};
                {queued, State2} ->
                    {keep_state, State2, [{reply, From, ok}]}
            end;
        {{fatal, Why}, _} ->
            log_routing_fatal(Why, Data),
            exit({dist_routing_fatal, Why})
    end;
%% Handle recv in connected state (for backward compatibility)
connected({call, From}, {recv, Length}, State) ->
    case try_recv(Length, State) of
        {ok, Data, State1} ->
            DataList = binary_to_list(Data),
            {keep_state, State1, [{reply, From, {ok, DataList}}]};
        {need_more, State1} ->
            Ref = make_ref(),
            Waiters = [{From, Ref, Length} | State1#state.recv_waiters],
            {keep_state, State1#state{recv_waiters = Waiters}}
    end;
%% Handle tick (from mf_tick callback)
%% CRITICAL: Always send tick frame FIRST as the liveness signal.
%% The tick frame uses the control stream (urgency 0, separate flow control)
%% to ensure it gets through even when data streams are congested.
%% Then optionally flush limited data (best effort, not blocking).
connected(cast, tick, #state{dhandle = DHandle, conn = Conn} = State) when
    DHandle =/= undefined
->
    %% Try to drain any pending send queue first
    State1 = drain_send_queues(State),
    %% Send tick frame - track if it fails
    State2 = do_send_tick_frame(State1),
    %% Then try to flush some data if not congested (best effort)
    State3 =
        case quic:get_send_queue_info(Conn) of
            {ok, #{congested := false}} ->
                send_dist_data_with_tick(State2);
            _ ->
                State2
        end,
    {keep_state, State3};
connected(cast, tick, State) ->
    %% No DHandle yet, send empty frame to keep QUIC connection alive
    State1 = do_send_tick_frame(State),
    {keep_state, State1};
%% Handle dist_data notification from VM
%% This means the VM has data ready for us to send
%% Uses backpressure to avoid overwhelming the QUIC send queue
connected(
    info,
    dist_data,
    #state{dhandle = DHandle, conn = Conn, backpressure_retry = RetryMs} = State
) when
    DHandle =/= undefined
->
    %% First drain any pending send queue
    State1 = drain_send_queues(State),
    %% Also retry pending tick if any
    State2 = maybe_retry_pending_tick(State1),
    case quic:get_send_queue_info(Conn) of
        {ok, #{congested := true}} ->
            %% Queue is congested - don't pull more data
            %% Re-check after a delay
            erlang:send_after(RetryMs, self(), check_queue),
            {keep_state, State2};
        {ok, #{congested := false}} ->
            %% Queue has room - pull and send limited amount of data
            State3 = send_dist_data_limited(State2),
            %% Re-register for next notification
            erlang:dist_ctrl_get_data_notification(DHandle),
            {keep_state, State3};
        {error, _} ->
            %% Error getting info - try sending anyway to avoid deadlock
            State3 = send_dist_data_limited(State2),
            erlang:dist_ctrl_get_data_notification(DHandle),
            {keep_state, State3}
    end;
%% Handle check_queue - retry sending after backpressure delay
connected(
    info,
    check_queue,
    #state{dhandle = DHandle, conn = Conn, backpressure_retry = RetryMs} = State
) when
    DHandle =/= undefined
->
    %% First drain any pending send queue
    State1 = drain_send_queues(State),
    %% Also retry pending tick if any
    State2 = maybe_retry_pending_tick(State1),
    case quic:get_send_queue_info(Conn) of
        {ok, #{congested := false}} ->
            %% Queue has room - pull and send data
            State3 = send_dist_data_limited(State2),
            erlang:dist_ctrl_get_data_notification(DHandle),
            {keep_state, State3};
        _ ->
            %% Still congested or error - retry later
            erlang:send_after(RetryMs, self(), check_queue),
            {keep_state, State2}
    end;
%% Handle connection migration notification
connected(info, {quic, _Conn, {path_changed, OldPath, NewPath}}, State) ->
    ?LOG_INFO(
        #{
            what => connection_migrated,
            node => State#state.node,
            old_path => OldPath,
            new_path => NewPath
        },
        ?QUIC_LOG_META
    ),
    {keep_state, State};
%% Handle user stream operations
connected({call, From}, {open_user_stream, Owner}, State) ->
    handle_open_user_stream(From, Owner, [], State);
connected({call, From}, {open_user_stream, Owner, Opts}, State) ->
    handle_open_user_stream(From, Owner, Opts, State);
connected({call, From}, {send_user_data, StreamId, Data, Fin}, State) ->
    handle_send_user_data(From, StreamId, Data, Fin, State);
connected({call, From}, {close_user_stream, StreamId}, State) ->
    handle_close_user_stream(From, StreamId, State);
connected({call, From}, {reset_user_stream, StreamId, ErrorCode}, State) ->
    handle_reset_user_stream(From, StreamId, ErrorCode, State);
connected({call, From}, {accept_user_streams, Acceptor}, State) ->
    handle_accept_user_streams(From, Acceptor, State);
connected({call, From}, stop_accepting_streams, State) ->
    handle_stop_accepting_streams(From, State);
connected({call, From}, {controlling_process, StreamId, NewOwner}, State) ->
    handle_controlling_process(From, StreamId, NewOwner, State);
connected({call, From}, list_user_streams, State) ->
    handle_list_user_streams(From, State);
connected(
    info,
    {'DOWN', MonRef, process, _Pid, _Reason},
    #state{handshake_owner_mon = MonRef} = State
) when MonRef =/= undefined ->
    stop_and_fail_reads({shutdown, handshake_owner_down}, State);
%% Handle user stream owner DOWN
connected(info, {'DOWN', MonRef, process, Pid, _Reason}, State) ->
    handle_user_stream_owner_down(MonRef, Pid, State);
connected(EventType, Event, State) ->
    handle_common_event(EventType, Event, connected, State).

%%====================================================================
%% Common Event Handling
%%====================================================================

handle_common_event({call, From}, getstat, _StateName, #state{conn = Conn} = State) ->
    %% Use QUIC-level packet counts for liveness detection
    %% This ensures any QUIC activity (ACKs, PINGs) counts as proof of liveness,
    %% even when application-level data is blocked by flow control.
    {RecvCnt, SendCnt} =
        case quic:get_stats(Conn) of
            {ok, #{packets_received := PR, packets_sent := PS}} ->
                {PR, PS};
            _ ->
                %% Fallback to application-level counts if get_stats fails
                {State#state.recv_cnt, State#state.send_cnt}
        end,
    SendPend = pending_total(State#state.send_queues),
    {keep_state, State, [{reply, From, {ok, RecvCnt, SendCnt, SendPend}}]};
handle_common_event(
    {call, From},
    {get_address, Node},
    _StateName,
    #state{conn = Conn} = State
) ->
    Address =
        case quic:peername(Conn) of
            {ok, {IP, Port}} ->
                #net_address{
                    address = {IP, Port},
                    host = atom_to_list(Node),
                    protocol = quic,
                    family = inet
                };
            _Error ->
                #net_address{
                    address = undefined,
                    host = atom_to_list(Node),
                    protocol = quic,
                    family = inet
                }
        end,
    {keep_state, State, [{reply, From, {ok, Address}}]};
handle_common_event(cast, {set_supervisor, Pid}, _StateName, State) ->
    {keep_state, State#state{supervisor = Pid, kernel = Pid}};
handle_common_event(
    {call, From},
    {set_handshake_owner, Owner},
    _StateName,
    #state{handshake_owner_mon = Old} = State
) ->
    _ =
        case Old of
            undefined -> ok;
            _ -> erlang:demonitor(Old, [flush])
        end,
    MonRef = erlang:monitor(process, Owner),
    {keep_state, State#state{handshake_owner_mon = MonRef}, [{reply, From, ok}]};
handle_common_event(
    info,
    {'DOWN', MonRef, process, _Pid, _Reason},
    _StateName,
    #state{handshake_owner_mon = MonRef} = State
) when MonRef =/= undefined ->
    stop_and_fail_reads({shutdown, handshake_owner_down}, State);
handle_common_event(cast, {set_node, Node}, _StateName, State) ->
    {keep_state, State#state{node = Node}};
handle_common_event({call, From}, get_node, _StateName, #state{node = Node} = State) ->
    Reply =
        case Node of
            undefined -> undefined;
            _ -> {ok, Node}
        end,
    {keep_state, State, [{reply, From, Reply}]};
handle_common_event({call, From}, getll, _StateName, State) ->
    {keep_state, State, [{reply, From, {ok, self()}}]};
handle_common_event(
    {call, From},
    {pre_nodeup, SetupPid},
    _StateName,
    #state{kernel = Kernel, node = Node} = State
) ->
    %% Send dist_ctrlr message to kernel to register this controller
    %% This is required before mark_nodeup can succeed
    case {Kernel, Node} of
        {undefined, _} ->
            ?LOG_WARNING(#{what => pre_nodeup_no_kernel}, ?QUIC_LOG_META),
            {keep_state, State, [{reply, From, ok}]};
        {_, undefined} ->
            ?LOG_WARNING(#{what => pre_nodeup_no_node}, ?QUIC_LOG_META),
            {keep_state, State, [{reply, From, ok}]};
        {K, N} when is_pid(K), is_atom(N) ->
            K ! {dist_ctrlr, self(), N, SetupPid},
            {keep_state, State, [{reply, From, ok}]}
    end;
%% Handle incoming QUIC messages
handle_common_event(
    info,
    {quic, Conn, {stream_data, StreamId, Data, Fin}},
    StateName,
    #state{
        conn = Conn,
        control_stream = CtrlStream
    } = State
) ->
    case StreamId of
        CtrlStream ->
            %% Data on control stream
            handle_control_data(Data, StateName, State);
        _ ->
            %% Data on data stream - check if user stream and pass Fin
            case StateName of
                connected ->
                    case is_user_stream(StreamId, State) of
                        true ->
                            handle_user_stream_data(StreamId, Data, Fin, State);
                        false ->
                            handle_stream_data(StreamId, Data, StateName, State)
                    end;
                _ ->
                    handle_stream_data(StreamId, Data, StateName, State)
            end
    end;
%% Handle stream reset for user streams
handle_common_event(
    info,
    {quic, Conn, {stream_reset, StreamId, ErrorCode}},
    _StateName,
    #state{conn = Conn, node = Node, user_streams = Streams} = State
) ->
    case maps:find(StreamId, Streams) of
        {ok, #user_stream{owner = Owner, monitor = MonRef}} ->
            %% Notify owner of reset
            StreamRef = {quic_dist_stream, Node, StreamId},
            Owner ! {quic_dist_stream, StreamRef, {reset, ErrorCode}},
            %% Demonitor and remove from map
            erlang:demonitor(MonRef, [flush]),
            NewStreams = maps:remove(StreamId, Streams),
            {keep_state, State#state{user_streams = NewStreams}};
        error ->
            %% Not a user stream or not known - ignore
            {keep_state, State}
    end;
handle_common_event(
    info,
    {quic, Conn, {session_ticket, Ticket}},
    _StateName,
    #state{conn = Conn} = State
) ->
    %% Store session ticket for 0-RTT
    {keep_state, State#state{session_ticket = Ticket}};
handle_common_event(
    info,
    {quic, Conn, {connected, _Info}},
    _StateName,
    #state{conn = Conn} = State
) ->
    %% Connection fully established - we may receive this after transitioning
    %% to handshaking state, just acknowledge and continue
    {keep_state, State};
handle_common_event(
    info,
    {quic, Conn, {stream_opened, _StreamId}},
    _StateName,
    #state{conn = Conn} = State
) ->
    %% New stream opened by peer - for distribution, we primarily use stream 0
    {keep_state, State};
handle_common_event(
    info,
    {quic, Conn, {closed, Reason}},
    _StateName,
    #state{conn = Conn} = State
) ->
    %% Connection closed
    stop_and_fail_reads(close_reason(Reason), State);
handle_common_event(
    info,
    {quic, Conn, {transport_error, Code, Reason}},
    _StateName,
    #state{conn = Conn} = State
) ->
    stop_and_fail_reads({transport_error, Code, Reason}, State);
handle_common_event(
    info,
    {quic, _OtherRef, {stream_data, StreamId, Data, _Fin}},
    _StateName,
    State
) ->
    %% Stream data with non-matching Conn (should not happen)
    ?LOG_WARNING(
        #{
            what => stream_data_conn_mismatch,
            stream_id => StreamId,
            data_size => byte_size(Data)
        },
        ?QUIC_LOG_META
    ),
    {keep_state, State};
%% Handle tick in any state (fallback)
handle_common_event(cast, tick, _StateName, State) ->
    State1 = do_send_tick_frame(State),
    {keep_state, State1};
%% Handle pending tick retry timer
handle_common_event(info, pending_tick_retry, _StateName, State) ->
    State1 = State#state{pending_tick_timer = undefined},
    State2 = maybe_retry_pending_tick(State1),
    {keep_state, State2};
handle_common_event(_EventType, _Event, _StateName, State) ->
    {keep_state, State}.

%% A read blocked on a connection that has gone answers like a closed
%% socket, which dist_util reports as a failed handshake step. Left
%% unanswered the caller dies out of the gen_statem call instead.
stop_and_fail_reads(Reason, #state{recv_waiters = Waiters} = State) ->
    Replies = [{reply, From, {error, closed}} || {From, _Ref, _Len} <- Waiters],
    {stop_and_reply, Reason, Replies, State#state{recv_waiters = []}}.

%% A node leaving is not a fault. A peer that closed the connection
%% cleanly, which for distribution means an application close with error
%% code 0, stops as a shutdown so no crash report is logged; anything
%% else keeps a reason that is reported, because it is a real failure.
close_reason({peer_closed, application, 0, _Phrase} = Reason) ->
    {shutdown, {connection_closed, Reason}};
close_reason(normal = Reason) ->
    {shutdown, {connection_closed, Reason}};
close_reason(Reason) ->
    {connection_closed, Reason}.

%%====================================================================
%% Internal Functions - Streams
%%====================================================================

%% @private
%% Open the control stream (client only - server uses stream 0 from client).
open_control_stream(#state{conn = Conn} = State) ->
    case quic:open_stream(Conn) of
        {ok, StreamId} ->
            {ok, StreamId, State};
        Error ->
            Error
    end.

%% @private
%% Open data streams for message passing.
%%
%% Partial reservation is fatal: the user-stream threshold macros assume
%% exactly N reserved IDs. If fewer open, subsequent user-stream opens
%% get IDs below the threshold and are rejected for the connection's
%% lifetime. Same goes for priority-set failure.
open_data_streams(State, 0) ->
    {ok, State};
open_data_streams(#state{conn = Conn, data_streams = Streams} = State, N) ->
    case quic:open_stream(Conn) of
        {ok, StreamId} ->
            case set_stream_priority(State, StreamId, ?QUIC_DIST_URGENCY_DATA_NORMAL) of
                ok ->
                    open_data_streams(
                        State#state{data_streams = [StreamId | Streams]},
                        N - 1
                    );
                {error, PrioReason} ->
                    {error,
                        {set_stream_priority_failed, StreamId, PrioReason, opened, length(Streams)}}
            end;
        {error, Reason} ->
            {error, {open_data_stream_failed, Reason, opened, length(Streams)}}
    end.

%% @private
set_stream_priority(#state{conn = Conn}, StreamId, Urgency) ->
    quic:set_stream_priority(Conn, StreamId, Urgency, false).

%% @private
%% Open server-initiated data streams after handshake.
%% Server-initiated bidirectional streams have IDs 1, 5, 9, ...
%% Returns {ok, NewState} | {error, Reason}; the server-enter clause
%% in connected/3 stops the controller on error.
open_server_data_streams(State) ->
    case open_data_streams(State, ?QUIC_DIST_DATA_STREAMS) of
        {ok, NewState} -> {ok, NewState};
        {error, _} = Err -> Err
    end.

%% @private
%% Forward any pending data stream content to the input handler.
%% This handles the race condition where the peer starts sending distribution
%% data before we've finished processing our handshake_complete message and
%% transitioning to connected state.
forward_pending_data(
    #state{pending_data_buffers = Buffers, input_handler = InputHandler} = State
) when is_pid(InputHandler), map_size(Buffers) > 0 ->
    ?LOG_INFO(
        #{
            what => forwarding_pending_data,
            slots => map_size(Buffers),
            total_size => maps:fold(
                fun(_, B, A) -> A + byte_size(B) end, 0, Buffers
            )
        },
        ?QUIC_LOG_META
    ),
    maps:foreach(
        fun
            (Sid, B) when byte_size(B) > 0 ->
                InputHandler ! {dist_data, Sid, B};
            (_, _) ->
                ok
        end,
        Buffers
    ),
    State#state{pending_data_buffers = #{}};
forward_pending_data(#state{pending_data_buffers = Buffers} = State) when
    map_size(Buffers) > 0
->
    %% No input handler yet — this shouldn't happen but warn.
    ?LOG_WARNING(
        #{
            what => pending_data_no_handler,
            slots => map_size(Buffers)
        },
        ?QUIC_LOG_META
    ),
    State;
forward_pending_data(State) ->
    %% No pending data.
    State.

%%====================================================================
%% Internal Functions - Send
%%====================================================================

%% @private
%% Send data on control stream (handshake messages).
%% Note: No framing needed - dist_util handles its own protocol framing.
do_send_control(
    Data,
    #state{
        conn = Conn,
        control_stream = StreamId,
        send_cnt = SendCnt,
        send_oct = SendOct
    } = State
) ->
    DataBin = iolist_to_binary(Data),
    Len = byte_size(DataBin),

    case quic:send_data(Conn, StreamId, DataBin, false) of
        ok ->
            Now = erlang:monotonic_time(millisecond),
            {ok, State#state{
                send_cnt = SendCnt + 1,
                last_send_time = Now,
                send_oct = SendOct + Len
            }};
        Error ->
            Error
    end.

%% @private
%% Send tick frame on control stream with QUIC PING for reliability.
%% We send both:
%% 1. QUIC PING - bypasses congestion, keeps transport alive
%% 2. Stream tick - needed for Erlang distribution response mechanism
%% Returns updated state with pending_tick flag set if stream send failed.
%% Starts a retry timer when tick is blocked to ensure retry during idle periods.
do_send_tick_frame(#state{conn = Conn, control_stream = CtrlStream} = State) when
    CtrlStream =/= undefined
->
    %% Send QUIC PING to keep transport alive (bypasses congestion)
    _ = quic:send_ping(Conn),
    %% Also send stream-based tick for Erlang distribution protocol
    case quic:send_data(Conn, CtrlStream, <<0:32/big-unsigned>>, false) of
        ok ->
            Now = erlang:monotonic_time(millisecond),
            cancel_pending_tick_timer(State#state{pending_tick = false, last_send_time = Now});
        {error, send_queue_full} ->
            %% Stream blocked - mark pending, retry aggressively
            start_pending_tick_timer(State#state{pending_tick = true});
        {error, {flow_control_blocked, _}} ->
            %% Flow control blocked - mark pending, retry aggressively
            start_pending_tick_timer(State#state{pending_tick = true});
        {error, _} ->
            %% Other error - clear pending
            cancel_pending_tick_timer(State#state{pending_tick = false})
    end;
do_send_tick_frame(#state{conn = Conn, data_streams = [FirstStream | _]} = State) ->
    %% Fallback to data stream if no control stream
    _ = quic:send_ping(Conn),
    case quic:send_data(Conn, FirstStream, <<0:32/big-unsigned>>, false) of
        ok ->
            Now = erlang:monotonic_time(millisecond),
            cancel_pending_tick_timer(State#state{pending_tick = false, last_send_time = Now});
        {error, send_queue_full} ->
            start_pending_tick_timer(State#state{pending_tick = true});
        {error, {flow_control_blocked, _}} ->
            start_pending_tick_timer(State#state{pending_tick = true});
        {error, _} ->
            cancel_pending_tick_timer(State#state{pending_tick = false})
    end;
do_send_tick_frame(State) ->
    State.

%% @private
%% Start the pending tick retry timer if not already running.
start_pending_tick_timer(#state{pending_tick_timer = undefined} = State) ->
    TimerRef = erlang:send_after(?PENDING_TICK_RETRY_MS, self(), pending_tick_retry),
    State#state{pending_tick_timer = TimerRef};
start_pending_tick_timer(State) ->
    %% Timer already running
    State.

%% @private
%% Cancel the pending tick retry timer if running.
cancel_pending_tick_timer(#state{pending_tick_timer = undefined} = State) ->
    State;
cancel_pending_tick_timer(#state{pending_tick_timer = TimerRef} = State) ->
    erlang:cancel_timer(TimerRef),
    State#state{pending_tick_timer = undefined}.

%% @private
%% Retry sending a pending tick if one is queued.
maybe_retry_pending_tick(#state{pending_tick = false} = State) ->
    State;
maybe_retry_pending_tick(#state{pending_tick = true} = State) ->
    State1 = do_send_tick_frame(State),
    case State1#state.pending_tick of
        false ->
            ?LOG_WARNING(#{what => pending_tick_retry_success}, ?QUIC_LOG_META);
        true ->
            ok
    end,
    State1.

%% @private
%% Send distribution data from VM via QUIC with backpressure.
%% Called when dist_data notification is received.
%% Each message returned by dist_ctrl_get_data/1 is routed to a stream
%% by quic_dist_dispatch:pick_stream/4 — fragments of the same logical
%% message stay on the same stream via the in_flight_fragments map.
send_dist_data_limited(
    #state{
        dhandle = DHandle,
        conn = Conn,
        data_streams = DataStreams,
        max_pull = MaxPull
    } = State
) when DataStreams =/= [] ->
    send_dist_data_limited_loop(DHandle, Conn, DataStreams, MaxPull, State);
send_dist_data_limited(_State) ->
    %% Setup guarantees N data streams (see open_data_streams/2). A
    %% post-setup empty pool is an invariant violation — fail loud.
    exit({dist_routing_fatal, no_data_streams}).

%% @private
%% Send up to Remaining messages from the VM, routing each to its
%% target stream. Buffers unsent data in send_queues on backpressure.
send_dist_data_limited_loop(_DHandle, _Conn, _Streams, Remaining, State) when
    Remaining =< 0
->
    State;
send_dist_data_limited_loop(DHandle, Conn, Streams, Remaining, State) ->
    case erlang:dist_ctrl_get_data(DHandle) of
        none ->
            State;
        DataIO ->
            %% dist_ctrl_get_data/1 returns iovec form (or {Size, Iovec});
            %% flatten so the dispatcher can pattern-match on the leading
            %% bytes.
            Data = iolist_to_binary(payload_bytes(DataIO)),
            #state{control_stream = Ctrl, in_flight_fragments = Frags} = State,
            case quic_dist_dispatch:pick_stream(Data, Streams, Ctrl, Frags) of
                {{ok, Sid}, Frags1} ->
                    State1 = State#state{in_flight_fragments = Frags1},
                    case try_send(Conn, Sid, Data, State1) of
                        {ok, State2} ->
                            send_dist_data_limited_loop(
                                DHandle, Conn, Streams, Remaining - 1, State2
                            );
                        {queued, State2} ->
                            send_dist_data_limited_loop(
                                DHandle, Conn, Streams, Remaining - 1, State2
                            )
                    end;
                {{fatal, Why}, _} ->
                    log_routing_fatal(Why, Data),
                    exit({dist_routing_fatal, Why})
            end
    end.

%% @private
%% dist_ctrl_get_data/1 may return `Data' (iovec) or `{Size, Data}'
%% (iovec with precomputed size); peel the size off.
payload_bytes({_Size, Data}) -> Data;
payload_bytes(Data) -> Data.

%% @private
%% Send distribution data during tick callback. Same routing as
%% send_dist_data_limited but with a tighter pull budget so the tick
%% doesn't block.
send_dist_data_with_tick(
    #state{
        dhandle = DHandle,
        conn = Conn,
        data_streams = DataStreams,
        max_pull = MaxPull
    } = State
) when DataStreams =/= [] ->
    send_dist_data_loop_tick(DHandle, Conn, DataStreams, MaxPull, State);
send_dist_data_with_tick(State) ->
    %% No data streams reserved yet — skip (tick is best-effort).
    State.

send_dist_data_loop_tick(_DHandle, _Conn, _Streams, Remaining, State) when
    Remaining =< 0
->
    State;
send_dist_data_loop_tick(DHandle, Conn, Streams, Remaining, State) ->
    case erlang:dist_ctrl_get_data(DHandle) of
        none ->
            State;
        DataIO ->
            Data = iolist_to_binary(payload_bytes(DataIO)),
            #state{control_stream = Ctrl, in_flight_fragments = Frags} = State,
            case quic_dist_dispatch:pick_stream(Data, Streams, Ctrl, Frags) of
                {{ok, Sid}, Frags1} ->
                    State1 = State#state{in_flight_fragments = Frags1},
                    case try_send(Conn, Sid, Data, State1) of
                        {ok, State2} ->
                            send_dist_data_loop_tick(
                                DHandle, Conn, Streams, Remaining - 1, State2
                            );
                        {queued, State2} ->
                            send_dist_data_loop_tick(
                                DHandle, Conn, Streams, Remaining - 1, State2
                            )
                    end;
                {{fatal, Why}, _} ->
                    log_routing_fatal(Why, Data),
                    exit({dist_routing_fatal, Why})
            end
    end.

%% @private
%% Try to send Data on StreamId. Returns {ok, State} on success or
%% {queued, State} if backpressure made us buffer. Fatal send errors
%% (closed stream, transport error, invalid id) exit the controller —
%% we must not silently drop dist bytes.
try_send(Conn, StreamId, Data, State) ->
    case has_pending(StreamId, State) of
        true ->
            {queued, enqueue(StreamId, Data, State)};
        false ->
            case send_one_frame(Conn, StreamId, Data) of
                ok ->
                    {ok, State};
                {error, send_queue_full} ->
                    {queued, enqueue(StreamId, Data, State)};
                {error, {flow_control_blocked, _}} ->
                    {queued, enqueue(StreamId, Data, State)};
                {error, Reason} ->
                    exit({dist_send_failed, StreamId, Reason})
            end
    end.

%% @private
has_pending(StreamId, #state{send_queues = Qs}) ->
    case maps:get(StreamId, Qs, undefined) of
        undefined -> false;
        Q -> not queue:is_empty(Q)
    end.

%% @private
enqueue(StreamId, Data, #state{send_queues = Qs} = State) ->
    Q = maps:get(StreamId, Qs, queue:new()),
    State#state{send_queues = maps:put(StreamId, queue:in(Data, Q), Qs)}.

%% @private
%% Drain every per-stream queue, head-first. A blocked head leaves
%% the whole queue intact so per-pair ordering is preserved.
drain_send_queues(#state{conn = Conn, send_queues = Qs} = State) ->
    maps:fold(
        fun(Sid, Q, S0) -> drain_one(Conn, Sid, Q, S0) end,
        State,
        Qs
    ).

drain_one(Conn, Sid, Q, #state{send_queues = Qs} = State) ->
    case queue:out(Q) of
        {empty, _} ->
            %% Fully drained — remove the entry.
            State#state{send_queues = maps:remove(Sid, Qs)};
        {{value, Data}, Rest} ->
            case send_one_frame(Conn, Sid, Data) of
                ok ->
                    drain_one(Conn, Sid, Rest, State);
                {error, send_queue_full} ->
                    %% Backpressure: leave full queue in place so later
                    %% sends to Sid keep enqueueing behind it.
                    State#state{send_queues = maps:put(Sid, Q, Qs)};
                {error, {flow_control_blocked, _}} ->
                    State#state{send_queues = maps:put(Sid, Q, Qs)};
                {error, Reason} ->
                    %% Fatal: closed stream, transport error, invalid id.
                    exit({dist_drain_failed, Sid, Reason})
            end
    end.

%% @private
pending_total(SendQueues) ->
    maps:fold(fun(_, Q, Acc) -> Acc + queue:len(Q) end, 0, SendQueues).

%% @private
log_routing_fatal(Reason, Data) ->
    Head = binary:part(Data, 0, min(32, byte_size(Data))),
    ?LOG_WARNING(
        #{
            what => dist_routing_fatal,
            reason => Reason,
            first_bytes => Head
        },
        ?QUIC_LOG_META
    ).

%% @private
%% Send a single framed message.
%% Adds 4-byte big-endian length prefix for message framing over QUIC.
%% Returns ok on success or {error, Reason} on failure.
send_one_frame(Conn, StreamId, Data) ->
    %% dist_ctrl_get_data returns raw message data (no length prefix)
    %% We add 4-byte length prefix for framing over QUIC
    DataBin = iolist_to_binary(Data),
    Length = byte_size(DataBin),
    FramedData = <<Length:32/big-unsigned, DataBin/binary>>,
    case quic:send_data(Conn, StreamId, FramedData, false) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

%%====================================================================
%% Input Handler - receives QUIC data and delivers to VM
%%====================================================================

%% @private
%% Input handler loop - receives QUIC data from controller and delivers to VM.
%% This runs in a separate process registered with erlang:dist_ctrl_input_handler.
%%
%% IMPORTANT: The distribution protocol uses 4-byte length-prefixed messages:
%%   <<Length:32/big-unsigned, Payload:Length/binary>>
%%
%% QUIC delivers data in arbitrary chunks (typically ~1100 bytes due to MTU).
%% We MUST buffer incoming data and only pass complete messages to the VM.
%% Passing partial messages causes "corrupted distribution header" errors.
input_handler_loop(DHandle, Controller, Conn, ControlStream) ->
    input_handler_loop(
        DHandle, Controller, Conn, ControlStream, #{}, fun erlang:dist_ctrl_put_data/2
    ).

%% Buffers :: #{StreamId :: non_neg_integer() => binary()}
%% Each dist stream has its own framing buffer; inter-stream delivery
%% order is free under the atom-cache-off handshake (each message is
%% self-contained).
input_handler_loop(DHandle, Controller, Conn, ControlStream, Buffers, Deliver) ->
    receive
        {continue_delivery, Sid} ->
            B0 = maps:get(Sid, Buffers, <<>>),
            case deliver_complete_messages(DHandle, B0, ?INPUT_HANDLER_BATCH_SIZE, Deliver, Sid) of
                {ok, Remaining} ->
                    Buffers1 = update_buffer(Sid, Remaining, Buffers),
                    input_handler_loop(
                        DHandle, Controller, Conn, ControlStream, Buffers1, Deliver
                    );
                {error, _Reason} ->
                    exit(normal)
            end;
        {dist_data, Sid, Data} ->
            input_handle_chunk(
                DHandle, Controller, Conn, ControlStream, Buffers, Deliver, Sid, Data
            );
        {'EXIT', Controller, Reason} ->
            exit(Reason);
        {quic, Conn, {stream_data, Sid, Data, _Fin}} ->
            input_handle_chunk(
                DHandle, Controller, Conn, ControlStream, Buffers, Deliver, Sid, Data
            );
        {quic, Conn, {closed, _Reason}} ->
            exit(normal);
        Other ->
            logger:warning(
                #{what => input_handler_unexpected_msg, msg => Other},
                ?QUIC_LOG_META
            ),
            input_handler_loop(DHandle, Controller, Conn, ControlStream, Buffers, Deliver)
    end.

%% @private
input_handle_chunk(DHandle, Controller, Conn, ControlStream, Buffers, Deliver, Sid, Data) ->
    B0 = maps:get(Sid, Buffers, <<>>),
    B1 = <<B0/binary, Data/binary>>,
    case deliver_complete_messages(DHandle, B1, ?INPUT_HANDLER_BATCH_SIZE, Deliver, Sid) of
        {ok, Remaining} ->
            Buffers1 = update_buffer(Sid, Remaining, Buffers),
            input_handler_loop(
                DHandle, Controller, Conn, ControlStream, Buffers1, Deliver
            );
        {error, _Reason} ->
            exit(normal)
    end.

%% @private
update_buffer(Sid, <<>>, Buffers) -> maps:remove(Sid, Buffers);
update_buffer(Sid, Bin, Buffers) -> maps:put(Sid, Bin, Buffers).

%% @private
%% Deliver complete messages to the VM with batch limiting.
%% 4-byte length-prefixed framing: <<Length:32/big, Payload:Length/binary>>.
%% The payload (without the length header) is passed to the Deliver fn.
%% Empty frames (Length=0) are tick signals - no payload to deliver.
%% The unprocessed remnant comes back via `{ok, RemainingBuffer}'; the
%% yield signal is a tag-only `continue_delivery' atom so the buffer
%% cannot race against an incoming `{dist_data, _}' message.
-ifdef(TEST).
%% Test-only /3 convenience, exercised by
%% `quic_dist_controller_tests:deliver_yield_returns_remainder_test/0'.
%% Production code calls the /5 arity (which threads StreamId for the
%% continue_delivery yield).
deliver_complete_messages(DHandle, Buffer, Remaining) ->
    deliver_complete_messages(DHandle, Buffer, Remaining, fun erlang:dist_ctrl_put_data/2).
-endif.

%% Backwards-compatible /4 entry (test only): uses a sentinel stream
%% id for the yield message. Production code calls the /5 arity.
-ifdef(TEST).
deliver_complete_messages(DHandle, Buffer, Remaining, Deliver) ->
    deliver_complete_messages(DHandle, Buffer, Remaining, Deliver, no_stream).
-endif.

deliver_complete_messages(_DHandle, Buffer, 0, _Deliver, Sid) ->
    self() ! {continue_delivery, Sid},
    {ok, Buffer};
deliver_complete_messages(DHandle, Buffer, Remaining, Deliver, Sid) ->
    case Buffer of
        <<0:32/big-unsigned, Rest/binary>> ->
            %% Empty frame = tick signal - just continue (ticks don't count against batch limit)
            logger:debug(#{what => tick_frame_received}, ?QUIC_LOG_META),
            deliver_complete_messages(DHandle, Rest, Remaining, Deliver, Sid);
        <<Length:32/big-unsigned, Rest/binary>> when byte_size(Rest) >= Length ->
            %% We have a complete message - extract payload only
            <<Payload:Length/binary, Tail/binary>> = Rest,
            logger:debug(
                #{
                    what => complete_message,
                    length => Length,
                    payload_first_bytes => binary:part(Payload, 0, min(16, byte_size(Payload)))
                },
                ?QUIC_LOG_META
            ),
            try
                %% Pass ONLY the payload (no length header) to the
                %% delivery fn. Production default is
                %% `erlang:dist_ctrl_put_data/2'; tests inject a fn
                %% that records payloads for assertion.
                Deliver(DHandle, Payload),
                deliver_complete_messages(DHandle, Tail, Remaining - 1, Deliver, Sid)
            catch
                Class:Reason ->
                    logger:error(
                        #{
                            what => dist_ctrl_put_data_failed,
                            class => Class,
                            reason => Reason,
                            payload_size => Length
                        },
                        ?QUIC_LOG_META
                    ),
                    {error, {put_data_failed, Reason}}
            end;
        <<Length:32/big-unsigned, _Rest/binary>> ->
            %% Have header but incomplete payload - need more data
            logger:debug(
                #{
                    what => need_more_data,
                    expected_length => Length,
                    have_bytes => byte_size(_Rest)
                },
                ?QUIC_LOG_META
            ),
            {ok, Buffer};
        _ when byte_size(Buffer) < 4 ->
            %% Don't even have the header yet
            {ok, Buffer};
        _ ->
            %% This shouldn't happen - log and keep the buffer
            %% Check if this looks like unframed ETF data
            logger:warning(
                #{
                    what => unexpected_buffer_state,
                    buffer_size => byte_size(Buffer),
                    first_bytes => binary:part(Buffer, 0, min(20, byte_size(Buffer))),
                    looks_like_etf => (byte_size(Buffer) >= 1 andalso binary:first(Buffer) =:= 131)
                },
                ?QUIC_LOG_META
            ),
            {ok, Buffer}
    end.

%%====================================================================
%% Internal Functions - Receive
%%====================================================================

%% @private
%% Try to receive data from buffer.
%% When Length = 0, return all available data (like gen_tcp:recv/3).
try_recv(0, #state{recv_buffer = <<>>} = State) ->
    %% No data available, need more
    {need_more, State};
try_recv(0, #state{recv_buffer = Buffer} = State) ->
    %% Return all available data
    {ok, Buffer, State#state{recv_buffer = <<>>}};
try_recv(Length, #state{recv_buffer = Buffer} = State) when byte_size(Buffer) >= Length ->
    <<Data:Length/binary, Rest/binary>> = Buffer,
    {ok, Data, State#state{recv_buffer = Rest}};
try_recv(_Length, State) ->
    {need_more, State}.

%% @private
%% Handle data received on control stream.
%% During handshake: buffer data for f_recv (distribution handshake)
%% After handshake: control stream only receives tick frames (<<0:32>>)
%%                  Send tick response to ensure bidirectional liveness.
handle_control_data(<<>>, _StateName, State) ->
    %% Empty data - signals liveness, nothing to process
    {keep_state, State};
handle_control_data(
    <<0:32/big-unsigned, Rest/binary>>,
    connected,
    #state{last_send_time = LastSend, last_tick_response = LastResp} = State
) ->
    %% Tick frame received in connected state.
    %% Send tick response only if:
    %% 1. We've been idle (haven't sent data recently) - need to prove liveness
    %% 2. We haven't sent a tick response recently - prevents feedback loops
    Now = erlang:monotonic_time(millisecond),
    IdleThreshold = 1000,
    TickResponseCooldown = 5000,
    IsIdle = (Now - LastSend) > IdleThreshold,
    CanRespond = (Now - LastResp) > TickResponseCooldown,
    State1 =
        case IsIdle andalso CanRespond of
            true ->
                %% We're idle and cooldown passed - send tick response
                State2 = do_send_tick_frame(State),
                State2#state{last_tick_response = Now};
            false ->
                %% Either actively sending data or already responded recently
                State
        end,
    handle_control_data(Rest, connected, State1);
handle_control_data(<<0:32/big-unsigned, Rest/binary>>, StateName, State) ->
    %% Tick frame during handshake - just consume, don't respond
    handle_control_data(Rest, StateName, State);
handle_control_data(
    Data,
    StateName,
    #state{
        recv_buffer = Buffer,
        recv_waiters = Waiters,
        recv_cnt = RecvCnt,
        recv_oct = RecvOct
    } = State
) ->
    case StateName of
        connected ->
            %% In connected state, control stream should only have tick frames
            %% Any other data is unexpected - log and ignore to avoid corruption
            ?LOG_WARNING(
                #{
                    what => unexpected_control_data,
                    size => byte_size(Data),
                    first_bytes => binary:part(Data, 0, min(20, byte_size(Data)))
                },
                ?QUIC_LOG_META
            ),
            {keep_state, State};
        _ ->
            %% During handshake, buffer data for f_recv
            NewBuffer = <<Buffer/binary, Data/binary>>,
            State1 = State#state{
                recv_buffer = NewBuffer,
                recv_cnt = RecvCnt + 1,
                recv_oct = RecvOct + byte_size(Data),
                recv_waiters = []
            },
            {State2, Actions} = satisfy_waiters(Waiters, State1, []),
            {keep_state, State2, Actions}
    end.

%% @private
%% Handle data received on data streams.
%% In connected state, forward to input handler for VM delivery or user stream owner.
%% During handshake, buffer data (shouldn't happen for data streams).
handle_stream_data(
    StreamId,
    Data,
    connected,
    #state{
        input_handler = InputHandler,
        recv_cnt = RecvCnt,
        recv_oct = RecvOct
    } = State
) when is_pid(InputHandler) ->
    %% Check if this is a user stream
    case is_user_stream(StreamId, State) of
        true ->
            %% User stream - route to owner or acceptor
            handle_user_stream_data(StreamId, Data, false, State);
        false ->
            %% Distribution data stream — forward to input handler
            %% tagged with the stream id so per-stream framing is
            %% maintained.
            InputHandler ! {dist_data, StreamId, Data},
            {keep_state, State#state{
                recv_cnt = RecvCnt + 1,
                recv_oct = RecvOct + byte_size(Data)
            }}
    end;
handle_stream_data(
    StreamId,
    Data,
    _StateName,
    #state{
        pending_data_buffers = Buffers,
        recv_cnt = RecvCnt,
        recv_oct = RecvOct
    } = State
) ->
    %% Data stream content arrived before we transitioned to connected.
    %% Buffer per-stream so multi-stream framing isn't corrupted when
    %% forward_pending_data flushes on transition.
    ?LOG_DEBUG(
        #{
            what => buffering_early_data_stream,
            stream_id => StreamId,
            size => byte_size(Data)
        },
        ?QUIC_LOG_META
    ),
    NewBuffers = maps:update_with(
        StreamId,
        fun(B) -> <<B/binary, Data/binary>> end,
        Data,
        Buffers
    ),
    {keep_state, State#state{
        pending_data_buffers = NewBuffers,
        recv_cnt = RecvCnt + 1,
        recv_oct = RecvOct + byte_size(Data)
    }}.

%% @private
%% Try to satisfy waiting recv requests.
satisfy_waiters([], State, Actions) ->
    {State, lists:reverse(Actions)};
satisfy_waiters([{From, _Ref, Length} | Rest], State, Actions) ->
    case try_recv(Length, State) of
        {ok, Data, State1} ->
            %% dist_util expects data as a list (charlist), not binary
            DataList = binary_to_list(Data),
            satisfy_waiters(Rest, State1, [{reply, From, {ok, DataList}} | Actions]);
        {need_more, State1} ->
            %% Put waiter back
            {State1#state{recv_waiters = [{From, _Ref, Length} | Rest]}, lists:reverse(Actions)}
    end.

%%====================================================================
%% User Stream Support
%%====================================================================

%% @private
%% Check if a stream ID is a user stream (above distribution reserved streams).
%% IMPORTANT: Check based on stream ID's initiator bit, NOT connection role.
%% QUIC stream IDs encode the initiator: even=client-initiated, odd=server-initiated.
is_user_stream(StreamId, _State) ->
    case StreamId band 1 of
        0 ->
            %% Client-initiated stream (even IDs: 0, 4, 8, 12, 16, 20...)
            StreamId >= ?USER_STREAM_THRESHOLD_CLIENT;
        1 ->
            %% Server-initiated stream (odd IDs: 1, 5, 9, 13, 17...)
            StreamId >= ?USER_STREAM_THRESHOLD_SERVER
    end.

%% @private
%% Handle open_user_stream call with options.
handle_open_user_stream(From, Owner, Opts, #state{conn = Conn, user_streams = Streams} = State) ->
    case quic:open_stream(Conn) of
        {ok, StreamId} ->
            %% Verify it's above the threshold
            case is_user_stream(StreamId, State) of
                true ->
                    %% Extract and validate priority
                    Priority = validate_priority(
                        proplists:get_value(priority, Opts, ?USER_STREAM_DEFAULT_PRIORITY)
                    ),
                    %% Set stream priority (user streams always lower than distribution)
                    _ = quic:set_stream_priority(Conn, StreamId, Priority, false),
                    %% Monitor the owner
                    MonRef = erlang:monitor(process, Owner),
                    UserStream = #user_stream{
                        id = StreamId,
                        owner = Owner,
                        monitor = MonRef,
                        priority = Priority
                    },
                    NewStreams = maps:put(StreamId, UserStream, Streams),
                    {keep_state, State#state{user_streams = NewStreams}, [
                        {reply, From, {ok, StreamId}}
                    ]};
                false ->
                    %% Shouldn't happen but handle gracefully
                    ?LOG_WARNING(
                        #{what => user_stream_below_threshold, stream_id => StreamId},
                        ?QUIC_LOG_META
                    ),
                    quic:reset_stream(Conn, StreamId, 0),
                    {keep_state, State, [{reply, From, {error, stream_below_threshold}}]}
            end;
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end.

%% @private
%% Validate and clamp user priority to allowed range.
validate_priority(P) when P < ?USER_STREAM_MIN_PRIORITY -> ?USER_STREAM_MIN_PRIORITY;
validate_priority(P) when P > 255 -> 255;
validate_priority(P) -> P.

%% @private
%% Handle send_user_data call.
handle_send_user_data(
    From, StreamId, Data, Fin, #state{conn = Conn, user_streams = Streams} = State
) ->
    case maps:find(StreamId, Streams) of
        {ok, #user_stream{owner = Owner} = US} ->
            %% Verify caller is the owner
            {CallerPid, _} = From,
            case CallerPid =:= Owner of
                true ->
                    DataBin = iolist_to_binary(Data),
                    case quic:send_data(Conn, StreamId, DataBin, Fin) of
                        ok ->
                            NewUS = US#user_stream{send_fin = Fin},
                            NewStreams = maps:put(StreamId, NewUS, Streams),
                            {keep_state, State#state{user_streams = NewStreams}, [
                                {reply, From, ok}
                            ]};
                        {error, Reason} ->
                            {keep_state, State, [{reply, From, {error, Reason}}]}
                    end;
                false ->
                    {keep_state, State, [{reply, From, {error, not_owner}}]}
            end;
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

%% @private
%% Handle close_user_stream call.
handle_close_user_stream(
    From, StreamId, #state{conn = Conn, node = Node, user_streams = Streams} = State
) ->
    case maps:find(StreamId, Streams) of
        {ok, #user_stream{owner = Owner, monitor = MonRef, recv_fin = RecvFin} = US} ->
            %% Verify caller is the owner
            {CallerPid, _} = From,
            case CallerPid =:= Owner of
                true ->
                    %% Send FIN on the stream
                    _ = quic:send_data(Conn, StreamId, <<>>, true),
                    %% Check if stream is now fully closed
                    case RecvFin of
                        true ->
                            %% Both sides closed - cleanup
                            erlang:demonitor(MonRef, [flush]),
                            StreamRef = {quic_dist_stream, Node, StreamId},
                            Owner ! {quic_dist_stream, StreamRef, closed},
                            NewStreams = maps:remove(StreamId, Streams),
                            {keep_state, State#state{user_streams = NewStreams}, [
                                {reply, From, ok}
                            ]};
                        false ->
                            %% Only send side closed - update state
                            NewUS = US#user_stream{send_fin = true},
                            NewStreams = maps:put(StreamId, NewUS, Streams),
                            {keep_state, State#state{user_streams = NewStreams}, [
                                {reply, From, ok}
                            ]}
                    end;
                false ->
                    {keep_state, State, [{reply, From, {error, not_owner}}]}
            end;
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

%% @private
%% Handle reset_user_stream call.
handle_reset_user_stream(
    From, StreamId, ErrorCode, #state{conn = Conn, node = Node, user_streams = Streams} = State
) ->
    case maps:find(StreamId, Streams) of
        {ok, #user_stream{owner = Owner, monitor = MonRef}} ->
            %% Verify caller is the owner
            {CallerPid, _} = From,
            case CallerPid =:= Owner of
                true ->
                    %% Reset the stream
                    _ = quic:reset_stream(Conn, StreamId, ErrorCode),
                    %% Notify owner and cleanup
                    erlang:demonitor(MonRef, [flush]),
                    StreamRef = {quic_dist_stream, Node, StreamId},
                    Owner ! {quic_dist_stream, StreamRef, {reset, ErrorCode}},
                    NewStreams = maps:remove(StreamId, Streams),
                    {keep_state, State#state{user_streams = NewStreams}, [
                        {reply, From, ok}
                    ]};
                false ->
                    {keep_state, State, [{reply, From, {error, not_owner}}]}
            end;
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

%% @private
%% Handle accept_user_streams call.
%% Adds the caller to the acceptor pool (multiple processes can accept streams).
handle_accept_user_streams(From, Acceptor, #state{acceptor_pool = Pool} = State) ->
    %% Check if already in pool
    case lists:keyfind(Acceptor, 1, Pool) of
        {Acceptor, _} ->
            %% Already registered
            {keep_state, State, [{reply, From, ok}]};
        false ->
            %% Add to pool with monitor
            MonRef = erlang:monitor(process, Acceptor),
            NewPool = [{Acceptor, MonRef} | Pool],
            {keep_state, State#state{acceptor_pool = NewPool}, [{reply, From, ok}]}
    end.

%% @private
%% Handle stop_accepting_streams call.
%% Removes the caller from the acceptor pool.
handle_stop_accepting_streams(From, #state{acceptor_pool = Pool} = State) ->
    {CallerPid, _} = From,
    case lists:keyfind(CallerPid, 1, Pool) of
        {CallerPid, MonRef} ->
            erlang:demonitor(MonRef, [flush]),
            NewPool = lists:keydelete(CallerPid, 1, Pool),
            {keep_state, State#state{acceptor_pool = NewPool}, [{reply, From, ok}]};
        false ->
            %% Not in pool - ok
            {keep_state, State, [{reply, From, ok}]}
    end.

%% @private
%% Handle controlling_process call - transfer stream ownership to another process.
handle_controlling_process(From, StreamId, NewOwner, #state{user_streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #user_stream{owner = Owner, monitor = MonRef} = US} ->
            %% Verify caller is the current owner
            {CallerPid, _} = From,
            case CallerPid =:= Owner of
                true ->
                    %% Transfer ownership
                    erlang:demonitor(MonRef, [flush]),
                    NewMonRef = erlang:monitor(process, NewOwner),
                    NewUS = US#user_stream{owner = NewOwner, monitor = NewMonRef},
                    NewStreams = maps:put(StreamId, NewUS, Streams),
                    {keep_state, State#state{user_streams = NewStreams}, [
                        {reply, From, ok}
                    ]};
                false ->
                    {keep_state, State, [{reply, From, {error, not_owner}}]}
            end;
        error ->
            {keep_state, State, [{reply, From, {error, unknown_stream}}]}
    end.

%% @private
%% Handle list_user_streams call.
handle_list_user_streams(From, #state{node = Node, user_streams = Streams} = State) ->
    StreamList = maps:fold(
        fun(
            StreamId,
            #user_stream{
                owner = Owner, priority = Priority, recv_fin = RecvFin, send_fin = SendFin
            },
            Acc
        ) ->
            [
                #{
                    ref => {quic_dist_stream, Node, StreamId},
                    node => Node,
                    stream_id => StreamId,
                    owner => Owner,
                    priority => Priority,
                    recv_fin => RecvFin,
                    send_fin => SendFin
                }
                | Acc
            ]
        end,
        [],
        Streams
    ),
    {keep_state, State, [{reply, From, StreamList}]}.

%% @private
%% Handle user stream owner process going down.
handle_user_stream_owner_down(
    MonRef, Pid, #state{conn = Conn, user_streams = Streams, acceptor_pool = Pool} = State
) ->
    %% Check if this is an acceptor from the pool
    case lists:keyfind(Pid, 1, Pool) of
        {Pid, MonRef} ->
            %% Acceptor died - remove from pool
            %% Also reset any streams owned by this acceptor
            {StreamsToReset, RemainingStreams} = maps:fold(
                fun(StreamId, #user_stream{owner = O, monitor = M} = US, {ToReset, Keep}) ->
                    case O =:= Pid of
                        true ->
                            erlang:demonitor(M, [flush]),
                            {[StreamId | ToReset], Keep};
                        false ->
                            {ToReset, maps:put(StreamId, US, Keep)}
                    end
                end,
                {[], #{}},
                Streams
            ),
            %% Reset streams owned by dead acceptor
            lists:foreach(
                fun(StreamId) -> _ = quic:reset_stream(Conn, StreamId, 0) end,
                StreamsToReset
            ),
            NewPool = lists:keydelete(Pid, 1, Pool),
            {keep_state, State#state{acceptor_pool = NewPool, user_streams = RemainingStreams}};
        false ->
            %% Check if this is a stream owner
            case find_stream_by_monitor(MonRef, Streams) of
                {ok, StreamId, _UserStream} ->
                    %% Reset the stream since owner died
                    _ = quic:reset_stream(Conn, StreamId, 0),
                    NewStreams = maps:remove(StreamId, Streams),
                    {keep_state, State#state{user_streams = NewStreams}};
                error ->
                    %% Unknown monitor - ignore
                    {keep_state, State}
            end
    end.

%% @private
%% Find a stream by its monitor reference.
find_stream_by_monitor(MonRef, Streams) ->
    maps:fold(
        fun(StreamId, #user_stream{monitor = MRef} = US, Acc) ->
            case MRef =:= MonRef of
                true -> {ok, StreamId, US};
                false -> Acc
            end
        end,
        error,
        Streams
    ).

%% @private
%% Handle data received on a user stream.
%% For existing streams: forward data to owner.
%% For new streams: select acceptor from pool (round-robin), auto-assign ownership, deliver data.
%% If no acceptor available: RESET stream immediately.
handle_user_stream_data(
    StreamId,
    Data,
    Fin,
    #state{
        conn = Conn,
        node = Node,
        user_streams = Streams,
        acceptor_pool = Pool,
        acceptor_idx = Idx,
        recv_cnt = RecvCnt,
        recv_oct = RecvOct
    } = State
) ->
    StreamRef = {quic_dist_stream, Node, StreamId},
    case maps:find(StreamId, Streams) of
        {ok, #user_stream{owner = Owner, monitor = MonRef, send_fin = SendFin} = US} ->
            %% Known stream - forward data to owner
            Owner ! {quic_dist_stream, StreamRef, {data, Data, Fin}},
            %% Update recv_fin if FIN received
            case Fin of
                true ->
                    %% Check if stream is now fully closed
                    case SendFin of
                        true ->
                            %% Both sides closed - send closed notification and cleanup
                            Owner ! {quic_dist_stream, StreamRef, closed},
                            erlang:demonitor(MonRef, [flush]),
                            NewStreams = maps:remove(StreamId, Streams),
                            {keep_state, State#state{
                                user_streams = NewStreams,
                                recv_cnt = RecvCnt + 1,
                                recv_oct = RecvOct + byte_size(Data)
                            }};
                        false ->
                            %% Only recv side closed
                            NewUS = US#user_stream{recv_fin = true},
                            NewStreams = maps:put(StreamId, NewUS, Streams),
                            {keep_state, State#state{
                                user_streams = NewStreams,
                                recv_cnt = RecvCnt + 1,
                                recv_oct = RecvOct + byte_size(Data)
                            }}
                    end;
                false ->
                    {keep_state, State#state{
                        recv_cnt = RecvCnt + 1,
                        recv_oct = RecvOct + byte_size(Data)
                    }}
            end;
        error ->
            %% New incoming stream - select acceptor from pool (round-robin)
            case select_acceptor(Pool, Idx) of
                {ok, AcceptorPid, NewIdx} ->
                    %% Auto-assign ownership to selected acceptor
                    OwnerMonRef = erlang:monitor(process, AcceptorPid),
                    UserStream = #user_stream{
                        id = StreamId,
                        owner = AcceptorPid,
                        monitor = OwnerMonRef,
                        recv_fin = Fin
                    },
                    NewStreams = maps:put(StreamId, UserStream, Streams),
                    %% Deliver data directly to acceptor (implicit ownership)
                    AcceptorPid ! {quic_dist_stream, StreamRef, {data, Data, Fin}},
                    {keep_state, State#state{
                        user_streams = NewStreams,
                        acceptor_idx = NewIdx,
                        recv_cnt = RecvCnt + 1,
                        recv_oct = RecvOct + byte_size(Data)
                    }};
                {error, no_acceptor} ->
                    %% No acceptor available - RESET stream immediately
                    ?LOG_WARNING(
                        #{what => user_stream_no_acceptor, stream_id => StreamId, action => reset},
                        ?QUIC_LOG_META
                    ),
                    _ = quic:reset_stream(Conn, StreamId, ?STREAM_REFUSED),
                    {keep_state, State#state{
                        recv_cnt = RecvCnt + 1,
                        recv_oct = RecvOct + byte_size(Data)
                    }}
            end
    end.

%% @private
%% Select an acceptor from the pool using round-robin.
select_acceptor([], _Idx) ->
    {error, no_acceptor};
select_acceptor(Pool, Idx) ->
    Len = length(Pool),
    {Acceptor, _MonRef} = lists:nth((Idx rem Len) + 1, Pool),
    {ok, Acceptor, Idx + 1}.
