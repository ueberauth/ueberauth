%%% -*- erlang -*-
%%%
%%% QUIC Socket Abstraction with UDP Packet Batching
%%% Supports GSO/GRO on Linux (OTP 27+), gen_udp fallback elsewhere
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc UDP socket abstraction with packet batching support.
%%%
%%% This module provides a unified socket interface that:
%%% - Uses the OTP 27+ `socket' module with GSO/GRO on Linux
%%% - Falls back to gen_udp on macOS/Windows/other platforms
%%% - Batches outgoing packets for improved throughput
%%% - Handles coalesced packets on receive (GRO)
%%%
%%% == Architecture ==
%%% ```
%%% quic_connection/quic_listener
%%%         |
%%%    quic_socket (this module)
%%%         |
%%%   socket module (OTP 27+) with GSO/GRO on Linux
%%%         or
%%%   gen_udp fallback on macOS/Windows
%%% '''
%%%
%%% == Configuration ==
%%% ```
%%% quic:start_server(Name, Port, #{
%%%     batching => #{
%%%         enabled => true,
%%%         max_packets => 64
%%%     }
%%% }).
%%% '''

-module(quic_socket).

-export([
    sender_down/2,
    open/2,
    open_for_send/2,
    open_adapter/1,
    wrap/2,
    new_sender/2,
    start_shared_sender/1,
    close/1,
    send/4,
    send_immediate/4,
    flush/1,
    recv/2,
    sockname/1,
    controlling_process/2,
    setopts/2,
    detect_capabilities/0,
    get_fd/1,
    get_socket/1,
    reuseaddr_for_port/1,
    gso_supported/1,
    info/1,
    recv_queue_max/1,
    start_client_receiver/3,
    stop_client_receiver/1,
    set_socket/2,
    client_recv_drops/0
]).

-include("quic.hrl").

%% Idle tick of the shared sender loop; also keeps its receive bounded.
-define(SHARED_SENDER_IDLE_MS, 30000).
-include_lib("kernel/include/logger.hrl").

%% GSO/GRO socket option constants for Linux
%% UDP_SEGMENT = 103 (for GSO)
%% UDP_GRO = 104 (for GRO)
-define(UDP_SEGMENT, 103).
-define(UDP_GRO, 104).

-record(socket_state, {
    %% The underlying socket. For the `adapter' backend this is an
    %% opaque reference() used only for pattern matching against the
    %% owning connection's #state.socket field.
    socket :: socket:socket() | gen_udp:socket() | reference(),
    %% Which backend we're using
    backend :: socket | gen_udp | adapter,
    %% Adapter backend: caller-supplied datagram send and close callbacks.
    %% Inbound packets must be delivered as
    %%   `{udp, Socket, IP, Port, Data}' to the connection owner pid,
    %% same shape as the gen_udp backend.
    adapter_send_fun ::
        undefined
        | fun((inet:ip_address(), inet:port_number(), iodata()) -> ok | {error, term()}),
    adapter_close_fun :: undefined | fun(() -> ok),
    %% Adapter-only: cached local address (sockname has no real socket).
    adapter_local :: undefined | {inet:ip_address(), inet:port_number()},
    %% Whether this socket_state owns the socket (true = close on cleanup)
    %% When wrapping an existing socket, this is false to avoid closing caller's socket
    owns_socket = true :: boolean(),
    %% GSO support detected and enabled
    gso_supported = false :: boolean(),
    %% Segment size of the most recent GSO flush, 0 before the first one.
    %% Derived per run from the batch: packet sizes follow the current max
    %% datagram size, so there is no fixed value to configure.
    gso_size = 0 :: non_neg_integer(),
    %% GRO enabled for receive
    gro_enabled = false :: boolean(),
    %% Batching enabled
    batching_enabled = true :: boolean(),
    %% Batched packets waiting to be sent (stored as packet_view())
    batch_buffer = [] :: [packet_view()],
    %% Number of packets in batch (avoids O(n) length/1)
    batch_count = 0 :: non_neg_integer(),
    %% Current batch destination address
    batch_addr :: {inet:ip_address(), inet:port_number()} | undefined,
    %% Maximum packets per batch
    max_batch_packets = ?DEFAULT_MAX_BATCH_PACKETS :: pos_integer(),
    %% Observability counters: bumped on successful flush only. Skip
    %% immediate (unbatched) sends so packets_coalesced strictly measures
    %% the batching win. batch_flushes counts each flush that actually
    %% transmitted something.
    batch_flushes = 0 :: non_neg_integer(),
    packets_coalesced = 0 :: non_neg_integer(),
    %% Batches the kernel segmented, as opposed to sent packet by packet.
    gso_flushes = 0 :: non_neg_integer(),
    %% Shared sender process: when set, flush/1 hands the batch to this
    %% process instead of calling sendmsg from the connection process.
    %% Concurrent sendmsg on one socket handle burns ~20x the CPU in
    %% NIF-level contention (measured 98.6 vs 4.7 us per send with 50
    %% concurrent senders), so server connections serialize the actual
    %% syscalls through the listener's sender while keeping their own
    %% batch buffers and GSO grouping.
    sender_pid = undefined :: undefined | pid(),
    %% Monitor on sender_pid, owned by the process that built this state.
    sender_mon = undefined :: undefined | reference(),
    %% GSO flushes performed by the shared sender on behalf of every
    %% connection of the listener, so a connection's gso_flushes stays
    %% meaningful (listener-wide) once the syscall has moved out of it.
    gso_counter = undefined :: undefined | atomics:atomics_ref()
}).

%% Packet can be:
%%   - binary() - already flat
%%   - {iov, [binary()]} - explicit iov parts (preferred for zero-copy)
%%   - iodata() - any iolist (for backwards compatibility)
-type packet_view() :: binary() | {iov, [binary()]} | iodata().

-opaque socket_state() :: #socket_state{}.
-export_type([socket_state/0, packet_view/0]).

-ifdef(TEST).
-compile([export_all, nowarn_export_all]).
-endif.

%%====================================================================
%% API
%%====================================================================

%% @doc Open a UDP socket with batching support.
%% Options:
%%   - All standard gen_udp options
%%   - batching => #{enabled => true, max_packets => 64, flush_timeout_ms => 1}
-spec open(inet:port_number(), map()) ->
    {ok, socket_state()} | {error, term()}.
open(Port, Opts) ->
    Family = extra_socket_family(maps:get(extra_socket_opts, Opts, [])),
    Capabilities = detect_capabilities(Family),
    Backend = maps:get(backend, Capabilities, gen_udp),
    GSOSupported = maps:get(gso, Capabilities, false),
    GROSupported = maps:get(gro, Capabilities, false),

    BatchOpts = maps:get(batching, Opts, #{}),
    BatchingEnabled = maps:get(enabled, BatchOpts, true),
    MaxBatch = maps:get(max_packets, BatchOpts, ?DEFAULT_MAX_BATCH_PACKETS),

    case Backend of
        socket ->
            open_socket_backend(Port, Family, Opts, #{
                gso_supported => GSOSupported,
                gro_supported => GROSupported,
                batching_enabled => BatchingEnabled,
                max_batch => MaxBatch
            });
        gen_udp ->
            open_genudp_backend(Port, Opts, #{
                batching_enabled => BatchingEnabled,
                max_batch => MaxBatch
            })
    end.

%% @doc Open a UDP socket optimized for sending (client connections).
%% Detects platform capabilities and enables GSO if available.
%% Unlike open/2, this is optimized for a single destination.
-spec open_for_send(inet:ip_address(), map()) ->
    {ok, socket_state()} | {error, term()}.
open_for_send(RemoteIP, Opts) ->
    Family = family(RemoteIP),
    Capabilities = detect_capabilities(Family),
    %% Allow the caller to force a backend (via `backend => socket'
    %% in Opts) so the opt-in client path can request the OTP socket
    %% NIF even on platforms where capability detection would pick
    %% `gen_udp' by default. Similarly `gso => false' lets the caller
    %% opt out of GSO even when the platform supports it — the opt-in
    %% client path uses that to avoid UDP_SEGMENT until the batched
    %% send path is validated against gen_udp servers.
    DetectedBackend = maps:get(backend, Capabilities, gen_udp),
    Backend = maps:get(backend, Opts, DetectedBackend),
    DetectedGSO = maps:get(gso, Capabilities, false),
    GSOSupported = maps:get(gso, Opts, DetectedGSO),
    DetectedGRO = maps:get(gro, Capabilities, false),
    GROSupported = maps:get(gro, Opts, DetectedGRO),

    BatchOpts = maps:get(batching, Opts, #{}),
    BatchingEnabled = maps:get(enabled, BatchOpts, true),
    MaxBatch = maps:get(max_packets, BatchOpts, ?DEFAULT_MAX_BATCH_PACKETS),

    case Backend of
        socket ->
            open_send_socket_backend(Family, Opts, #{
                gso_supported => GSOSupported,
                gro_supported => GROSupported,
                batching_enabled => BatchingEnabled,
                max_batch => MaxBatch
            });
        gen_udp ->
            open_send_genudp_backend(Family, Opts, #{
                batching_enabled => BatchingEnabled,
                max_batch => MaxBatch
            })
    end.

%% @doc Get the underlying socket from a socket_state.
-spec get_socket(socket_state()) -> socket:socket() | gen_udp:socket().
get_socket(#socket_state{socket = Socket}) ->
    Socket.

%% @doc Swap the underlying socket handle without rebuilding the
%% `#socket_state{}'. Used by client-migration rebind so batching
%% configuration is preserved while the handle points at a fresh
%% ephemeral port. Callers must flush any pending batch before
%% swapping; packets buffered under the old handle cannot migrate to
%% the new one.
-spec set_socket(socket_state(), gen_udp:socket() | socket:socket()) -> socket_state().
set_socket(#socket_state{} = State, NewSocket) ->
    State#socket_state{socket = NewSocket}.

%% @doc Check if GSO is supported for this socket_state.
-spec gso_supported(socket_state()) -> boolean().
gso_supported(#socket_state{gso_supported = Supported}) ->
    Supported.

%% @doc Return a map describing the socket_state's configuration and
%% observability counters. Intended for debugging, benchmarking, and
%% test assertions.
-spec info(socket_state()) ->
    #{
        backend := gen_udp | socket,
        gso_supported := boolean(),
        gso_size := non_neg_integer(),
        gro_enabled := boolean(),
        batching_enabled := boolean(),
        max_batch_packets := pos_integer(),
        batch_pending := non_neg_integer(),
        batch_flushes := non_neg_integer(),
        packets_coalesced := non_neg_integer(),
        gso_flushes := non_neg_integer()
    }.
info(#socket_state{
    backend = Backend,
    gso_supported = GSO,
    gso_size = GSOSize,
    gro_enabled = GRO,
    batching_enabled = Batching,
    max_batch_packets = MaxBatch,
    batch_flushes = Flushes,
    packets_coalesced = Coalesced,
    gso_flushes = OwnGSOFlushes,
    batch_count = Pending,
    sender_pid = Sender,
    gso_counter = Counter
}) ->
    %% With a shared sender the segmented flushes happen there; report
    %% the listener-wide count in that case.
    GSOFlushes =
        case {Sender, Counter} of
            {P, C} when is_pid(P), C =/= undefined -> atomics:get(C, 1);
            _ -> OwnGSOFlushes
        end,
    #{
        backend => Backend,
        batch_pending => Pending,
        gso_supported => GSO,
        gso_size => GSOSize,
        gro_enabled => GRO,
        batching_enabled => Batching,
        max_batch_packets => MaxBatch,
        batch_flushes => Flushes,
        packets_coalesced => Coalesced,
        gso_flushes => GSOFlushes
    }.

%% @doc Build a socket_state backed by caller-supplied callbacks instead
%% of a real UDP socket. Useful for tunnelling QUIC packets over an
%% alternate transport (for example a MASQUE CONNECT-UDP session).
%%
%% Required options:
%% <ul>
%%   <li>`send_fun' - `fun((IP, Port, Packet) -> ok | {error, _})'.
%%       Called for every outbound packet. The caller is responsible
%%       for delivering inbound packets to the connection owner as
%%       `{udp, Socket, IP, Port, Data}' messages, where `Socket' is
%%       the reference returned in the `socket_state'.</li>
%% </ul>
%% Optional options:
%% <ul>
%%   <li>`close_fun' - `fun(() -> ok)' invoked on socket close.</li>
%%   <li>`local' - `{IP, Port}' returned by `sockname/1'.</li>
%%   <li>`socket_ref' - `reference()' to use as the opaque socket
%%       handle. Defaults to a fresh `make_ref/0'. Callers that need
%%       to forward inbound packets as `{udp, Ref, IP, Port, Data}'
%%       should supply their own ref so they know which value to use
%%       before the connection starts.</li>
%% </ul>
%% Batching, GSO and GRO are unconditionally disabled for this backend
%% because the underlying transport handles its own framing.
-spec open_adapter(map()) -> {ok, socket_state()} | {error, term()}.
open_adapter(#{send_fun := SendFun} = Opts) when is_function(SendFun, 3) ->
    State = #socket_state{
        socket = maps:get(socket_ref, Opts, make_ref()),
        backend = adapter,
        owns_socket = true,
        gso_supported = false,
        gro_enabled = false,
        batching_enabled = false,
        adapter_send_fun = SendFun,
        adapter_close_fun = maps:get(close_fun, Opts, undefined),
        adapter_local = maps:get(local, Opts, undefined)
    },
    {ok, State};
open_adapter(_) ->
    {error, {missing, send_fun}}.

%% @doc Wrap an existing gen_udp socket with batching support.
%% This allows adding batching to connections that already have a socket.
%% Note: GSO/GRO are not available when wrapping existing gen_udp sockets.
%% The wrapped socket is NOT owned by this state - close/1 will not close it.
-spec wrap(gen_udp:socket(), map()) -> {ok, socket_state()}.
wrap(Socket, Opts) ->
    BatchOpts = maps:get(batching, Opts, #{}),
    BatchingEnabled = maps:get(enabled, BatchOpts, true),
    MaxBatch = maps:get(max_packets, BatchOpts, ?DEFAULT_MAX_BATCH_PACKETS),

    State = #socket_state{
        socket = Socket,
        backend = gen_udp,
        owns_socket = false,
        gso_supported = false,
        gro_enabled = false,
        batching_enabled = BatchingEnabled,
        max_batch_packets = MaxBatch
    },
    {ok, State}.

%% @doc Create a fresh per-connection sender that reuses an existing
%% socket (e.g. the listener's shared UDP socket on the server side).
%% Each caller gets its own batch buffer so multiple connections can
%% accumulate packets independently before flush. GSO is inherited from
%% the underlying backend when requested.
%% The socket is NOT owned by the returned state - close/1 will not close it.
-spec new_sender(gen_udp:socket() | socket:socket(), map()) ->
    {ok, socket_state()}.
new_sender(Socket, Opts) ->
    Backend = maps:get(backend, Opts, gen_udp),
    GSOSupported = maps:get(gso_supported, Opts, false),
    BatchOpts = maps:get(batching, Opts, #{}),
    BatchingEnabled = maps:get(enabled, BatchOpts, true),
    MaxBatch = maps:get(max_packets, BatchOpts, ?DEFAULT_MAX_BATCH_PACKETS),

    State = #socket_state{
        socket = Socket,
        backend = Backend,
        owns_socket = false,
        gso_supported = GSOSupported andalso (Backend =:= socket),
        gro_enabled = false,
        batching_enabled = BatchingEnabled,
        max_batch_packets = MaxBatch,
        sender_pid = maps:get(sender_pid, Opts, undefined),
        sender_mon = monitor_sender(maps:get(sender_pid, Opts, undefined)),
        gso_counter = maps:get(gso_counter, Opts, undefined)
    },
    {ok, State}.

monitor_sender(Pid) when is_pid(Pid) -> erlang:monitor(process, Pid);
monitor_sender(_) -> undefined.

%% @doc The shared sender went down (its monitor fired in the owning
%% process): flushes go direct from here on.
-spec sender_down(socket_state() | undefined, reference()) -> {ok, socket_state()} | false.
sender_down(#socket_state{sender_mon = Mon} = State, Mon) when Mon =/= undefined ->
    {ok, State#socket_state{sender_pid = undefined, sender_mon = undefined}};
sender_down(_, _) ->
    false.

%% @doc Spawn the shared sender for a listener socket: a process that
%% performs the actual sendmsg calls for every server connection's
%% batches, serially. GSO state (including the partial-send disable)
%% lives in the sender's own socket_state copy. Linked to the caller.
%% Returns the sender and the counter connections read gso_flushes
%% from; both go into new_sender/2 options (`sender_pid',
%% `gso_counter').
-spec start_shared_sender(socket_state()) -> {pid(), atomics:atomics_ref()}.
start_shared_sender(#socket_state{} = SS) ->
    Counter = atomics:new(1, []),
    Template = SS#socket_state{
        sender_pid = undefined,
        gso_counter = Counter,
        owns_socket = false,
        batch_buffer = [],
        batch_count = 0,
        batch_addr = undefined
    },
    {spawn_link(fun() -> shared_sender_loop(Template) end), Counter}.

shared_sender_loop(SS) ->
    receive
        {send_batch, Addr, Buffer, Count} ->
            Loaded = SS#socket_state{
                batch_buffer = Buffer,
                batch_count = Count,
                batch_addr = Addr
            },
            SS2 =
                case flush(Loaded) of
                    {ok, S} ->
                        S;
                    {error, Reason, S} ->
                        ?LOG_WARNING(#{what => shared_sender_flush_failed, reason => Reason}),
                        S
                end,
            %% Carry forward only the socket-global bits (a partial GSO
            %% send disables GSO for the socket).
            shared_sender_loop(SS#socket_state{
                gso_supported = SS2#socket_state.gso_supported,
                gso_size = SS2#socket_state.gso_size
            });
        stop ->
            ok
    after ?SHARED_SENDER_IDLE_MS ->
        %% Nothing to send for a while: shed the heap the batches left.
        erlang:garbage_collect(),
        shared_sender_loop(SS)
    end.

bump_batch_counters(#socket_state{} = State, Count) ->
    State#socket_state{
        batch_flushes = State#socket_state.batch_flushes + 1,
        packets_coalesced = State#socket_state.packets_coalesced + Count
    }.

%% @doc Close the socket and flush any pending packets.
%% Only closes the socket if owns_socket is true (i.e., socket was created by us).
-spec close(socket_state()) -> ok.
close(#socket_state{backend = adapter, adapter_close_fun = Fun}) ->
    case Fun of
        undefined ->
            ok;
        F when is_function(F, 0) ->
            _ =
                try
                    F()
                catch
                    _:_ -> ok
                end,
            ok
    end;
close(#socket_state{owns_socket = false}) ->
    %% Don't close wrapped sockets - caller owns them
    ok;
close(#socket_state{socket = Socket, backend = socket}) ->
    _ = socket:close(Socket),
    ok;
close(#socket_state{socket = Socket, backend = gen_udp}) ->
    _ = gen_udp:close(Socket),
    ok.

%% @doc Send a packet immediately, bypassing the batch buffer.
%% Intended for one-shot control-plane sends (version negotiation,
%% retry, stateless reset) where batching adds no value and persisting
%% the returned state is awkward.
-spec send_immediate(socket_state(), inet:ip_address(), inet:port_number(), packet_view()) ->
    {ok, socket_state()} | {error, term()}.
send_immediate(State, IP, Port, Packet) ->
    do_send_immediate(State, IP, Port, Packet).

%% @doc Send a packet, buffering for batch send if enabled.
%% Packet can be:
%%   - binary() - already flat packet
%%   - {iov, [binary()]} - packet parts for scatter/gather (avoids copy)
%%
%% Returns updated state. Auto-flushes when:
%% - Batch is full (max_batch_packets reached)
%% - Destination address changes
-spec send(socket_state(), inet:ip_address(), inet:port_number(), packet_view()) ->
    {ok, socket_state()} | {error, term()} | {error, term(), socket_state()}.
send(#socket_state{batching_enabled = false} = State, IP, Port, Packet) ->
    %% Batching disabled - send immediately
    do_send_immediate(State, IP, Port, Packet);
send(#socket_state{batch_addr = undefined} = State, IP, Port, Packet) ->
    %% First packet in batch
    add_to_batch(State#socket_state{batch_addr = {IP, Port}}, Packet);
send(#socket_state{batch_addr = {IP, Port}} = State, IP, Port, Packet) ->
    %% Same destination - add to batch
    add_to_batch(State, Packet);
send(#socket_state{} = State, IP, Port, Packet) ->
    %% Different destination - flush current batch first
    case flush(State) of
        {ok, State1} ->
            add_to_batch(State1#socket_state{batch_addr = {IP, Port}}, Packet);
        {error, _, _} = Error ->
            Error
    end.

%% @doc Flush all buffered packets. On hard send error the batch is
%% cleared in the returned state so callers thread a clean buffer;
%% PTO-driven retransmission owns recovery of any packets the CC has
%% already tracked.
-spec flush(socket_state()) ->
    {ok, socket_state()} | {error, term(), socket_state()}.
flush(#socket_state{batch_count = 0} = State) ->
    %% Nothing to flush
    {ok, State};
flush(#socket_state{batch_count = Count, batch_addr = undefined} = State) ->
    %% No address set but have data - shouldn't happen, but clear buffer
    ?LOG_WARNING(#{what => flush_no_addr, buffer_size => Count}),
    {ok, clear_batch(State)};
flush(
    #socket_state{
        sender_pid = Sender,
        batch_count = Count,
        batch_addr = Addr,
        batch_buffer = Buffer
    } = State
) when is_pid(Sender) ->
    %% Hand the whole batch to the shared sender (see the sender_pid
    %% field). Fire-and-forget: send errors are logged by the sender
    %% and covered by loss recovery, the same contract as the direct
    %% path. A dead sender is noticed through its monitor (sender_down/2);
    %% a batch sent in the window before that is covered by loss recovery
    %% too, which is cheaper than an is_process_alive per flush.
    Sender ! {send_batch, Addr, Buffer, Count},
    {ok, bump_batch_counters(clear_batch(State), Count)};
flush(#socket_state{gso_supported = true, batch_count = 1} = State) ->
    %% Single-packet batch has no segmentation work; direct send.
    flush_individual(State);
flush(#socket_state{gso_supported = true} = State) ->
    %% UDP_SEGMENT requires every segment except the last to be exactly
    %% the segment size, so the batch goes out as runs of equal-sized
    %% packets, one sendmsg each. The size comes from the run itself:
    %% 1-RTT packets follow the current max datagram size, so comparing
    %% against a configured constant never matched and the GSO path
    %% never ran (issue #196). Handshake flights, which coalesce an
    %% Initial padded to 1200 with a ~400 byte Handshake packet, split
    %% into their own runs instead of being mis-segmented.
    flush_gso_runs(State);
flush(#socket_state{} = State) ->
    %% Fallback path - send packets individually
    flush_individual(State).

%% @doc Receive packets from the socket.
%% On Linux with GRO, may return multiple coalesced packets.
-spec recv(socket_state(), timeout()) ->
    {ok, {inet:ip_address(), inet:port_number()}, [binary()]} | {error, term()}.
recv(#socket_state{socket = Socket, backend = socket, gro_enabled = true}, Timeout) ->
    %% GRO path - receive potentially coalesced packets
    recv_gro(Socket, Timeout);
recv(#socket_state{socket = Socket, backend = socket}, Timeout) ->
    %% Socket backend without GRO
    case socket:recvfrom(Socket, 0, [], Timeout) of
        {ok, {#{addr := IP, port := Port}, Data}} ->
            {ok, {IP, Port}, [Data]};
        {error, _} = Error ->
            Error
    end;
recv(#socket_state{socket = Socket, backend = gen_udp}, Timeout) ->
    %% gen_udp backend
    receive
        {udp, Socket, IP, Port, Data} ->
            {ok, {IP, Port}, [Data]}
    after Timeout ->
        {error, timeout}
    end;
recv(#socket_state{socket = Socket, backend = adapter}, Timeout) ->
    %% Adapter backend: caller delivers gen_udp-shaped messages.
    receive
        {udp, Socket, IP, Port, Data} ->
            {ok, {IP, Port}, [Data]}
    after Timeout ->
        {error, timeout}
    end.

%% @doc Get the local address and port.
-spec sockname(socket_state()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(#socket_state{socket = Socket, backend = socket}) ->
    case socket:sockname(Socket) of
        {ok, #{addr := IP, port := Port}} ->
            {ok, {IP, Port}};
        {error, _} = Error ->
            Error
    end;
sockname(#socket_state{socket = Socket, backend = gen_udp}) ->
    inet:sockname(Socket);
sockname(#socket_state{backend = adapter, adapter_local = Local}) ->
    case Local of
        undefined -> {ok, {{0, 0, 0, 0}, 0}};
        {_, _} -> {ok, Local}
    end.

%% @doc Set the controlling process.
-spec controlling_process(socket_state(), pid()) -> ok | {error, term()}.
controlling_process(#socket_state{socket = Socket, backend = gen_udp}, Pid) ->
    gen_udp:controlling_process(Socket, Pid);
controlling_process(#socket_state{backend = socket}, _Pid) ->
    %% socket module doesn't have controlling_process concept
    ok;
controlling_process(#socket_state{backend = adapter}, _Pid) ->
    %% Caller manages its own delivery pid.
    ok.

%% @doc Set socket options.
-spec setopts(socket_state(), list()) -> ok | {error, term()}.
setopts(#socket_state{socket = Socket, backend = gen_udp}, Opts) ->
    inet:setopts(Socket, Opts);
setopts(#socket_state{socket = Socket, backend = socket}, Opts) ->
    %% Convert gen_udp style opts to socket module
    set_socket_opts(Socket, Opts);
setopts(#socket_state{backend = adapter}, _Opts) ->
    %% No socket options to configure on a callback-based adapter.
    ok.

%% @doc Get the underlying file descriptor.
-spec get_fd(socket_state()) -> {ok, integer()} | {error, term()}.
get_fd(#socket_state{socket = Socket, backend = gen_udp}) ->
    case inet:getfd(Socket) of
        {ok, Fd} -> {ok, Fd};
        Error -> Error
    end;
get_fd(#socket_state{socket = Socket, backend = socket}) ->
    %% socket module - get native fd
    try
        Fd = socket:info(Socket),
        case maps:get(fd, Fd, undefined) of
            undefined -> {error, no_fd};
            FdVal -> {ok, FdVal}
        end
    catch
        _:_ -> {error, not_supported}
    end;
get_fd(#socket_state{backend = adapter}) ->
    {error, not_supported}.

%% @doc Spawn a client-side receiver process for the `socket' backend.
%%
%% The OTP `socket' module does not support `{active, N}' semantics,
%% so instead we spawn a dedicated process that loops on
%% `socket:recvfrom/4' and forwards each datagram as
%% `{udp, Owner, IP, Port, Data}' to the owning connection process.
%% This lets the existing `quic_connection' receive path keep
%% pattern-matching on the gen_udp-style message shape without
%% any branching.
%%
%% Returns the receiver pid, linked to the caller so it terminates
%% when the connection process exits.
%% QueueMax is the owner's mailbox bound, see recv_queue_max/1.
-spec start_client_receiver(socket_state(), pid(), pos_integer()) ->
    {ok, pid()} | {error, term()}.
start_client_receiver(#socket_state{backend = socket} = SocketState, Owner, QueueMax) when
    is_pid(Owner)
->
    Pid = spawn_link(fun() -> client_recv_loop(SocketState, Owner, QueueMax) end),
    {ok, Pid};
start_client_receiver(#socket_state{backend = gen_udp}, _Owner, _QueueMax) ->
    {error, not_supported_on_gen_udp};
start_client_receiver(#socket_state{backend = adapter}, _Owner, _QueueMax) ->
    %% Adapter callers deliver `{udp, ...}' messages themselves.
    {error, not_supported_on_adapter}.

%% Mailbox bound for a receiver that advertised MaxData bytes of
%% connection flow-control window: the window in full-size packets,
%% never below ?MAX_CONN_RECV_QUEUE_MSGS.
-spec recv_queue_max(non_neg_integer()) -> pos_integer().
recv_queue_max(MaxData) ->
    max(?MAX_CONN_RECV_QUEUE_MSGS, MaxData div ?RECV_QUEUE_PACKET_BYTES).

%% @doc Stop a client receiver process previously returned by
%% `start_client_receiver/3'. Safe to call with `undefined'.
-spec stop_client_receiver(pid() | undefined) -> ok.
stop_client_receiver(undefined) ->
    ok;
stop_client_receiver(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true ->
            unlink(Pid),
            exit(Pid, shutdown),
            ok;
        false ->
            ok
    end.

%% Blocking recvfrom loop. Forwards each datagram as a gen_udp-shaped
%% `{udp, Socket, IP, Port, Data}' tuple so the owner's existing
%% receive handlers work unchanged — `Socket' here matches the OTP
%% socket handle stored in `#state.socket'. Uses a 100ms timeout so
%% exit signals from the linked owner are processed promptly rather
%% than blocking forever in the NIF.
client_recv_loop(#socket_state{socket = Socket} = SocketState, Owner, QueueMax) ->
    %% recv_gro splits GRO-coalesced trains and sizes the read buffer
    %% for a maximal train; a plain recvfrom with the default 8 KiB
    %% buffer would silently truncate coalesced input. A multi-packet
    %% train goes to the owner as ONE message so the mailbox holds
    %% trains, not packets, and the whole train is processed in one
    %% receive pass.
    case recv_gro(Socket, 100) of
        {ok, {IP, Port}, Packets} ->
            forward_to_owner(Owner, Socket, IP, Port, Packets, QueueMax),
            client_recv_loop(SocketState, Owner, QueueMax);
        {error, timeout} ->
            client_recv_loop(SocketState, Owner, QueueMax);
        {error, closed} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING(#{what => client_recv_loop_exit, reason => Reason}),
            ok
    end.

%% Bench diagnostic: client-receiver tail-drop counter.
%% Tail-drop over QueueMax, see recv_queue_max/1.
forward_to_owner(Owner, Socket, IP, Port, Packets, QueueMax) ->
    case erlang:process_info(Owner, message_queue_len) of
        {message_queue_len, QLen} when QLen > QueueMax ->
            count_client_recv_drop(length(Packets));
        _ ->
            case Packets of
                [Single] -> Owner ! {udp, Socket, IP, Port, Single};
                _ -> Owner ! {udp_batch, Socket, IP, Port, Packets}
            end,
            ok
    end.

count_client_recv_drop(N) ->
    Ref =
        case persistent_term:get({?MODULE, recv_drops}, undefined) of
            undefined ->
                R = atomics:new(1, []),
                persistent_term:put({?MODULE, recv_drops}, R),
                R;
            R ->
                R
        end,
    atomics:add(Ref, 1, N).

-spec client_recv_drops() -> non_neg_integer().
client_recv_drops() ->
    case persistent_term:get({?MODULE, recv_drops}, undefined) of
        undefined -> 0;
        Ref -> atomics:get(Ref, 1)
    end.

%% @doc Detect platform capabilities for GSO/GRO. Context-free wrapper that
%% probes the IPv4 family; callers that know their target family should use
%% detect_capabilities/1 so an IPv6-only host is not wrongly downgraded.
-spec detect_capabilities() -> map().
detect_capabilities() ->
    detect_capabilities(inet).

-spec detect_capabilities(inet | inet6) -> map().
detect_capabilities(Family) ->
    case os:type() of
        {unix, linux} ->
            detect_linux_capabilities(Family);
        _ ->
            #{gso => false, gro => false, backend => gen_udp}
    end.

%%====================================================================
%% Internal Functions - Socket Backend
%%====================================================================

open_socket_backend(Port, Family, Opts, BatchConfig) ->
    case socket:open(Family, dgram, udp) of
        {ok, Socket} ->
            configure_and_bind_socket(Socket, Port, Family, Opts, BatchConfig);
        {error, _} = Error ->
            Error
    end.

configure_and_bind_socket(Socket, Port, Family, Opts, BatchConfig) ->
    maybe_set_reuseaddr(Socket, Port),
    set_socket_buffer_sizes(Socket, Opts),
    maybe_set_reuseport(Socket, Opts),
    %% Honor a specific bind address from extra_socket_opts {ip, Addr};
    %% fall back to the family wildcard.
    BindAddr = proplists:get_value(ip, maps:get(extra_socket_opts, Opts, []), any),
    bind_and_finalize_socket(Socket, Port, Family, BindAddr, BatchConfig).

set_socket_buffer_sizes(Socket, Opts) ->
    RecBuf = maps:get(recbuf, Opts, ?DEFAULT_UDP_RECBUF),
    SndBuf = maps:get(sndbuf, Opts, ?DEFAULT_UDP_SNDBUF),
    _ = socket:setopt(Socket, {socket, rcvbuf}, RecBuf),
    _ = socket:setopt(Socket, {socket, sndbuf}, SndBuf),
    ok.

%% @doc Whether a UDP socket bound to `Port' should set SO_REUSEADDR.
%% Only a listener on a fixed port needs it, to rebind after a restart.
%% On an ephemeral port it buys nothing, and it makes the kernel treat a
%% port held by another SO_REUSEADDR socket as free when it autobinds, so
%% two sockets land on one port and only one of them sees its datagrams.
%% A gen_udp caller that wants it anyway can pass it in `extra_socket_opts',
%% which is appended last; the socket backend reads only `{ip, _}' there.
-spec reuseaddr_for_port(inet:port_number()) -> boolean().
reuseaddr_for_port(0) -> false;
reuseaddr_for_port(_Port) -> true.

maybe_set_reuseaddr(Socket, Port) ->
    case reuseaddr_for_port(Port) of
        true -> ok = socket:setopt(Socket, {socket, reuseaddr}, true);
        false -> ok
    end.

maybe_set_reuseport(Socket, Opts) ->
    case maps:get(reuseport, Opts, false) of
        true -> _ = socket:setopt(Socket, {socket, reuseport}, true);
        false -> ok
    end.

bind_and_finalize_socket(Socket, Port, Family, BindAddr, BatchConfig) ->
    Addr = #{family => Family, addr => BindAddr, port => Port},
    case socket:bind(Socket, Addr) of
        ok ->
            build_socket_state(Socket, BatchConfig);
        {error, _} = Error ->
            socket:close(Socket),
            Error
    end.

build_socket_state(Socket, BatchConfig) ->
    %% GSO is applied per-message via the UDP_SEGMENT cmsg in
    %% flush_gso/1, never as a socket-level setsockopt. A socket-level
    %% UDP_SEGMENT would force GSO segmentation on every outbound
    %% datagram including the short handshake packets and fallback
    %% sends, which stalled the handshake on ubuntu-24.04.
    GSOEnabled = maps:get(gso_supported, BatchConfig, false),
    GROEnabled = maybe_enable_gro(Socket, BatchConfig),
    State = #socket_state{
        socket = Socket,
        backend = socket,
        gso_supported = GSOEnabled,
        gro_enabled = GROEnabled,
        batching_enabled = maps:get(batching_enabled, BatchConfig),
        max_batch_packets = maps:get(max_batch, BatchConfig)
    },
    {ok, State}.

maybe_enable_gro(Socket, #{gro_supported := true}) ->
    %% Try to enable GRO
    %% UDP_GRO = 104
    case socket:setopt_native(Socket, {udp, ?UDP_GRO}, <<1:32/native>>) of
        ok -> true;
        {error, _} -> false
    end;
maybe_enable_gro(_, _) ->
    false.

%%====================================================================
%% Internal Functions - Send-optimized Socket (for client connections)
%%====================================================================

%% Open socket backend optimized for sending (no binding to specific port)
open_send_socket_backend(Family, Opts, BatchConfig) ->
    case socket:open(Family, dgram, udp) of
        {ok, Socket} ->
            configure_send_socket(Socket, Opts, BatchConfig);
        {error, _} = Error ->
            Error
    end.

configure_send_socket(Socket, Opts, BatchConfig) ->
    set_socket_buffer_sizes(Socket, Opts),
    maybe_bind_source(Socket, Opts),
    %% GSO is applied per-message via the UDP_SEGMENT cmsg in
    %% flush_gso/1, never as a socket-level setsockopt. A socket-level
    %% UDP_SEGMENT would force GSO segmentation on every outbound
    %% datagram, including short handshake packets and non-uniform
    %% fallback sends, which stalled handshakes and mis-segmented
    %% coalesced Initial+Handshake flights against gen_udp servers.
    GSOEnabled = maps:get(gso_supported, BatchConfig, false),
    %% Enable GRO so a GSO-batching peer's trains arrive as one
    %% recvmsg with a UDP_GRO cmsg instead of one syscall per segment;
    %% recv_gro/2 already handles both shapes.
    GROEnabled = maybe_enable_gro(Socket, #{
        gro_supported => maps:get(gro_supported, BatchConfig, false)
    }),
    State = #socket_state{
        socket = Socket,
        backend = socket,
        owns_socket = true,
        gso_supported = GSOEnabled,
        gro_enabled = GROEnabled,
        batching_enabled = maps:get(batching_enabled, BatchConfig),
        max_batch_packets = maps:get(max_batch, BatchConfig)
    },
    {ok, State}.

%% Honor a specific source address from extra_socket_opts {ip, Addr},
%% as the gen_udp client path does. Without the bind the kernel
%% picks the source per route (127.0.0.1 for loopback), which
%% misidentifies the sender on multi-address hosts.
maybe_bind_source(Socket, Opts) ->
    case proplists:get_value(ip, maps:get(extra_socket_opts, Opts, []), undefined) of
        undefined ->
            ok;
        BindAddr ->
            case
                socket:bind(Socket, #{
                    family => family(BindAddr), addr => BindAddr, port => 0
                })
            of
                ok ->
                    ok;
                {error, BindErr} ->
                    ?LOG_WARNING(#{
                        what => client_source_bind_failed,
                        addr => BindAddr,
                        reason => BindErr
                    }),
                    ok
            end
    end.

%% Open gen_udp backend optimized for sending (ephemeral port)
open_send_genudp_backend(Family, Opts, BatchConfig) ->
    SocketOpts = build_send_genudp_opts(Family, Opts),
    case gen_udp:open(0, SocketOpts) of
        {ok, Socket} ->
            {ok, build_genudp_state(Socket, BatchConfig)};
        {error, _} = Error ->
            Error
    end.

build_send_genudp_opts(Family, Opts) ->
    ActiveN = maps:get(active_n, Opts, 100),
    ExtraFlags = maps:get(extra_socket_opts, Opts, []),
    RecBuf = maps:get(recbuf, Opts, ?DEFAULT_UDP_RECBUF),
    SndBuf = maps:get(sndbuf, Opts, ?DEFAULT_UDP_SNDBUF),
    [
        binary,
        Family,
        {active, ActiveN},
        {recbuf, RecBuf},
        {sndbuf, SndBuf}
    ] ++ ExtraFlags.

%%====================================================================
%% Internal Functions - gen_udp Backend
%%====================================================================

open_genudp_backend(Port, Opts, BatchConfig) ->
    SocketOpts = build_genudp_opts(Port, Opts),
    case gen_udp:open(Port, SocketOpts) of
        {ok, Socket} ->
            {ok, build_genudp_state(Socket, BatchConfig)};
        {error, _} = Error ->
            Error
    end.

build_genudp_opts(Port, Opts) ->
    ActiveN = maps:get(active_n, Opts, 100),
    ReusePort = maps:get(reuseport, Opts, false),
    ExtraFlags = maps:get(extra_socket_opts, Opts, []),
    RecBuf = maps:get(recbuf, Opts, ?DEFAULT_UDP_RECBUF),
    SndBuf = maps:get(sndbuf, Opts, ?DEFAULT_UDP_SNDBUF),
    BaseOpts = [
        binary,
        extra_socket_family(ExtraFlags),
        {active, ActiveN},
        {reuseaddr, reuseaddr_for_port(Port)},
        {recbuf, RecBuf},
        {sndbuf, SndBuf}
    ],
    ReuseOpts =
        case ReusePort of
            true -> [{reuseport, true}, {reuseport_lb, true}];
            false -> []
        end,
    BaseOpts ++ ReuseOpts ++ ExtraFlags.

build_genudp_state(Socket, BatchConfig) ->
    #socket_state{
        socket = Socket,
        backend = gen_udp,
        gso_supported = false,
        gro_enabled = false,
        batching_enabled = maps:get(batching_enabled, BatchConfig),
        max_batch_packets = maps:get(max_batch, BatchConfig)
    }.

%%====================================================================
%% Internal Functions - Batching
%%====================================================================

add_to_batch(
    #socket_state{batch_buffer = Buffer, batch_count = Count, max_batch_packets = Max} = State,
    Packet
) ->
    %% Store packet as-is (binary or {iov, Parts}) - no flattening yet
    NewBuffer = [Packet | Buffer],
    NewCount = Count + 1,
    State1 = State#socket_state{batch_buffer = NewBuffer, batch_count = NewCount},

    case NewCount >= Max of
        true ->
            %% Batch full - flush now
            flush(State1);
        false ->
            %% Just accumulate - caller flushes at send cycle boundaries
            {ok, State1}
    end.

flush_individual(#socket_state{backend = socket} = State) ->
    flush_individual_socket(State);
flush_individual(#socket_state{backend = gen_udp} = State) ->
    flush_individual_genudp(State).

%% Mixed-size batch on a GSO socket: send it as runs of equal-sized
%% packets, each run in one UDP_SEGMENT sendmsg, odd-sized packets
%% individually, preserving wire order. A run may absorb one shorter
%% trailing packet (the kernel allows a short final segment).
flush_gso_runs(
    #socket_state{
        socket = Socket,
        batch_buffer = Buffer,
        batch_addr = {IP, Port}
    } = State
) ->
    Packets = lists:reverse(Buffer),
    Dest = #{family => family(IP), addr => IP, port => Port},
    Runs = split_uniform_runs(Packets),
    case send_runs(Socket, Dest, Runs) of
        ok ->
            {ok, record_run_flush(State, Runs)};
        {error, Reason} ->
            ?LOG_WARNING(#{what => gso_run_send_error, reason => Reason}),
            {error, Reason, clear_batch(State)}
    end.

%% Group an oldest-first packet list into {gso, SegmentSize, Packets}
%% runs (>= 2 packets, all SegmentSize except possibly a shorter last)
%% and {single, Packet} entries, preserving order.
split_uniform_runs([]) ->
    [];
split_uniform_runs([P | Rest]) ->
    split_uniform_runs(Rest, iolist_size(P), [P]).

split_uniform_runs([], _Size, [Single]) ->
    [{single, Single}];
split_uniform_runs([], Size, RunAcc) ->
    cap_run(Size, lists:reverse(RunAcc));
split_uniform_runs([P | Rest], Size, RunAcc) ->
    case iolist_size(P) of
        Size ->
            split_uniform_runs(Rest, Size, [P | RunAcc]);
        PSize when PSize < Size ->
            %% Shorter packet closes this run as its final segment
            %% (the kernel permits a short last segment).
            cap_run(Size, lists:reverse([P | RunAcc])) ++ split_uniform_runs(Rest);
        PSize ->
            Head =
                case RunAcc of
                    [Single] -> [{single, Single}];
                    _ -> cap_run(Size, lists:reverse(RunAcc))
                end,
            Head ++ split_uniform_runs(Rest, PSize, [P])
    end.

%% One UDP_SEGMENT write carries at most UDP_MAX_SEGMENTS segments and a
%% payload that still fits a 16-bit UDP length, so a long run is split
%% across writes: 64 packets of 1398 bytes is 89 KB, well over the cap.
%% Only the final packet of the batch may be short, and it stays in the
%% final chunk, so every chunk remains a legal segmented write.
cap_run(SegmentSize, Packets) ->
    PerWrite = max(1, min(?MAX_GSO_SEGMENTS, ?MAX_GSO_PAYLOAD div SegmentSize)),
    [{gso, SegmentSize, Chunk} || Chunk <- chunk_list(Packets, PerWrite)].

chunk_list(Packets, Size) when length(Packets) =< Size ->
    [Packets];
chunk_list(Packets, Size) ->
    {Head, Tail} = lists:split(Size, Packets),
    [Head | chunk_list(Tail, Size)].

send_runs(_Socket, _Dest, []) ->
    ok;
send_runs(Socket, Dest, [{single, Packet} | Rest]) ->
    Msg = #{addr => Dest, iov => [normalize_packet(Packet)]},
    case socket:sendmsg(Socket, Msg) of
        ok -> send_runs(Socket, Dest, Rest);
        {ok, _RestData} -> send_runs(Socket, Dest, Rest);
        {error, _} = Error -> Error
    end;
send_runs(Socket, Dest, [{gso, SegmentSize, Packets} | Rest]) ->
    PacketIov = [normalize_packet(P) || P <- Packets],
    Msg = #{
        addr => Dest,
        iov => PacketIov,
        ctrl => [#{level => udp, type => ?UDP_SEGMENT, data => <<SegmentSize:16/native>>}]
    },
    case socket:sendmsg(Socket, Msg) of
        ok ->
            send_runs(Socket, Dest, Rest);
        {ok, RestData} ->
            %% Kernel refused part of the segmented write: send the
            %% remainder segment-by-segment, then continue with the
            %% remaining runs (mirrors flush_gso_partial).
            Data = iolist_to_binary(RestData),
            case send_run_segments(Socket, Dest, split_into_segments(Data, SegmentSize)) of
                ok -> send_runs(Socket, Dest, Rest);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

send_run_segments(_Socket, _Dest, []) ->
    ok;
send_run_segments(Socket, Dest, [Packet | Rest]) ->
    case socket:sendto(Socket, Packet, Dest) of
        ok -> send_run_segments(Socket, Dest, Rest);
        {error, _} = Error -> Error
    end.

flush_individual_socket(
    #socket_state{
        socket = Socket,
        batch_buffer = Buffer,
        batch_addr = {IP, Port}
    } = State
) ->
    %% Send each packet using sendmsg with iov (no flattening)
    Packets = lists:reverse(Buffer),
    Dest = #{family => family(IP), addr => IP, port => Port},
    case send_packets_socket(Socket, Dest, Packets, 0) of
        {ok, _Sent} ->
            {ok, record_flush(State)};
        {error, Reason, _Sent} ->
            {error, Reason, clear_batch(State)}
    end.

flush_individual_genudp(
    #socket_state{
        socket = Socket,
        batch_buffer = Buffer,
        batch_addr = {IP, Port}
    } = State
) ->
    %% Send each packet using gen_udp (must flatten)
    Packets = lists:reverse(Buffer),
    case send_packets_genudp(Socket, IP, Port, Packets, 0) of
        {ok, _Sent} ->
            {ok, record_flush(State)};
        {error, Reason, _Sent} ->
            {error, Reason, clear_batch(State)}
    end.

%% Send packets using socket:sendmsg with iov (no flattening for socket backend)
send_packets_socket(_Socket, _Dest, [], Sent) ->
    {ok, Sent};
send_packets_socket(Socket, Dest, [Packet | Rest], Sent) ->
    Msg = #{
        addr => Dest,
        iov => packet_iov(Packet)
    },
    case socket:sendmsg(Socket, Msg) of
        ok ->
            send_packets_socket(Socket, Dest, Rest, Sent + 1);
        {ok, _Remaining} ->
            {error, partial_send, Sent};
        {error, Reason} ->
            {error, Reason, Sent}
    end.

%% Send packets using gen_udp (must flatten to binary)
send_packets_genudp(_Socket, _IP, _Port, [], Sent) ->
    {ok, Sent};
send_packets_genudp(Socket, IP, Port, [Packet | Rest], Sent) ->
    Bin = normalize_packet(Packet),
    case gen_udp:send(Socket, IP, Port, Bin) of
        ok ->
            send_packets_genudp(Socket, IP, Port, Rest, Sent + 1);
        {error, Reason} ->
            {error, Reason, Sent}
    end.

%% Split binary data into segment-sized chunks
split_into_segments(Data, SegmentSize) ->
    split_into_segments(Data, SegmentSize, []).

split_into_segments(<<>>, _SegmentSize, Acc) ->
    lists:reverse(Acc);
split_into_segments(Data, SegmentSize, Acc) when byte_size(Data) =< SegmentSize ->
    lists:reverse([Data | Acc]);
split_into_segments(Data, SegmentSize, Acc) ->
    <<Segment:SegmentSize/binary, Rest/binary>> = Data,
    split_into_segments(Rest, SegmentSize, [Segment | Acc]).

do_send_immediate(
    #socket_state{backend = adapter, adapter_send_fun = Fun} = State, IP, Port, Packet
) ->
    Bin = normalize_packet(Packet),
    case Fun(IP, Port, Bin) of
        ok -> {ok, State};
        {error, _} = Error -> Error
    end;
do_send_immediate(#socket_state{socket = Socket, backend = socket} = State, IP, Port, Packet) ->
    %% Use sendmsg with iov - no flattening needed
    Msg = #{
        addr => #{family => family(IP), addr => IP, port => Port},
        iov => packet_iov(Packet)
    },
    case socket:sendmsg(Socket, Msg) of
        ok -> {ok, State};
        {ok, _Remaining} -> {error, partial_send};
        {error, Reason} -> {error, Reason}
    end;
do_send_immediate(#socket_state{socket = Socket, backend = gen_udp} = State, IP, Port, Packet) ->
    %% gen_udp needs flat binary
    Bin = normalize_packet(Packet),
    case gen_udp:send(Socket, IP, Port, Bin) of
        ok -> {ok, State};
        {error, _} = Error -> Error
    end.

%%====================================================================
%% Internal Functions - Packet View Helpers
%%====================================================================

%% Convert packet_view to iov list for sendmsg
%% {iov, Parts} uses parts directly (zero-copy path)
%% binary is wrapped in list
%% iodata is flattened to list of binaries (preserves binary boundaries)
packet_iov(Bin) when is_binary(Bin) ->
    [Bin];
packet_iov({iov, Parts}) ->
    Parts;
packet_iov(IoData) when is_list(IoData) ->
    %% Flatten iolist to list of binaries (preserves binary boundaries)
    flatten_iodata(IoData, []).

%% Flatten iodata to list of binaries (for iov)
%% Preserves binary boundaries, concatenates byte sequences
flatten_iodata([], Acc) ->
    lists:reverse(Acc);
flatten_iodata([H | T], Acc) when is_binary(H) ->
    flatten_iodata(T, [H | Acc]);
flatten_iodata([H | T], Acc) when is_list(H) ->
    %% Nested list - recurse
    flatten_iodata(T, flatten_iodata(H, Acc));
flatten_iodata([H | T], Acc) when is_integer(H), H >= 0, H =< 255 ->
    %% Byte value - collect consecutive bytes into a binary
    {Bytes, Rest} = collect_bytes([H | T], []),
    flatten_iodata(Rest, [list_to_binary(Bytes) | Acc]).

%% Collect consecutive byte integers
collect_bytes([H | T], Acc) when is_integer(H), H >= 0, H =< 255 ->
    collect_bytes(T, [H | Acc]);
collect_bytes(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

%% Flatten packet_view to binary (for GSO and gen_udp)
normalize_packet(Bin) when is_binary(Bin) ->
    Bin;
normalize_packet({iov, Parts}) ->
    iolist_to_binary(Parts);
normalize_packet(IoData) when is_list(IoData) ->
    iolist_to_binary(IoData).

%% Clear batch state without bumping observability counters. Used by
%% error / partial-send paths where we do not want to count as a
%% successful flush.
clear_batch(State) ->
    State#socket_state{
        batch_buffer = [],
        batch_count = 0,
        batch_addr = undefined
    }.

%% Record a successful flush and clear the batch state. Increments
%% batch_flushes by one and packets_coalesced by the number of packets
%% that were coalesced before the send. Use this only when the send
%% actually transmitted the full batch.
record_flush(
    #socket_state{
        batch_count = Count,
        batch_flushes = Flushes,
        packets_coalesced = Coalesced
    } = State
) ->
    State#socket_state{
        batch_buffer = [],
        batch_count = 0,
        batch_addr = undefined,
        batch_flushes = Flushes + 1,
        packets_coalesced = Coalesced + Count
    }.

%% As record_flush/1, for a batch the kernel segmented. gso_flushes
%% counts only those: batch_flushes and packets_coalesced advance on the
%% individual path too, so a ratio over them proves batching, not
%% offload, and stayed green while the GSO path was dead (issue #196).
%% gso_size records the segment size that actually went on the wire.
record_run_flush(State, Runs) ->
    State1 = record_flush(State),
    case [Size || {gso, Size, _} <- Runs] of
        [] ->
            State1;
        [Size | _] = Sizes ->
            case State#socket_state.gso_counter of
                undefined -> ok;
                Counter -> atomics:add(Counter, 1, length(Sizes))
            end,
            State1#socket_state{
                gso_flushes = State#socket_state.gso_flushes + length(Sizes),
                gso_size = Size
            }
    end.

%% Get address family
family({_, _, _, _}) -> inet;
family({_, _, _, _, _, _, _, _}) -> inet6.

%% Infer the UDP address family from caller socket options: inet6 when an
%% `inet6' atom or an 8-tuple `{ip, _}' is present, inet otherwise.
extra_socket_family(Extra) ->
    case lists:member(inet6, Extra) of
        true ->
            inet6;
        false ->
            case proplists:get_value(ip, Extra) of
                {_, _, _, _, _, _, _, _} -> inet6;
                _ -> inet
            end
    end.

%%====================================================================
%% Internal Functions - GRO Receive
%%====================================================================

recv_gro(Socket, Timeout) ->
    %% Receive with GRO - may get coalesced packets. The buffer must
    %% hold a maximally coalesced train (64 KiB): passing 0 uses the
    %% OTP default read buffer (8 KiB) and recvmsg silently truncates
    %% any larger train, discarding every segment past the first few.
    case socket:recvmsg(Socket, 65535, 128, [], Timeout) of
        {ok, #{addr := #{addr := IP, port := Port}, iov := [Data], ctrl := Ctrl}} ->
            %% Check for GRO segment size in control messages
            case extract_gro_segment_size(Ctrl) of
                undefined ->
                    %% No GRO - single packet
                    {ok, {IP, Port}, [Data]};
                SegmentSize ->
                    %% Split coalesced data into individual packets
                    Packets = split_gro_packets(Data, SegmentSize),
                    {ok, {IP, Port}, Packets}
            end;
        {ok, #{addr := #{addr := IP, port := Port}, iov := [Data]}} ->
            %% No control messages
            {ok, {IP, Port}, [Data]};
        {error, _} = Error ->
            Error
    end.

extract_gro_segment_size([]) ->
    undefined;
extract_gro_segment_size([
    #{level := udp, type := ?UDP_GRO, data := <<Size:16/native, _/binary>>} | _
]) ->
    %% The kernel's UDP_GRO cmsg payload is an int (4 bytes); matching
    %% exactly 2 bytes made every lookup fail, so a GRO-coalesced buffer
    %% was passed up unsplit as one giant datagram and dropped by the
    %% QUIC layer (short-header packets cannot be re-split). Accept the
    %% int and read the low 16 bits.
    Size;
extract_gro_segment_size([_ | Rest]) ->
    extract_gro_segment_size(Rest).

split_gro_packets(Data, SegmentSize) ->
    split_gro_packets(Data, SegmentSize, []).

split_gro_packets(<<>>, _SegmentSize, Acc) ->
    lists:reverse(Acc);
split_gro_packets(Data, SegmentSize, Acc) when byte_size(Data) =< SegmentSize ->
    lists:reverse([Data | Acc]);
split_gro_packets(Data, SegmentSize, Acc) ->
    <<Packet:SegmentSize/binary, Rest/binary>> = Data,
    split_gro_packets(Rest, SegmentSize, [Packet | Acc]).

%%====================================================================
%% Internal Functions - Linux Capability Detection
%%====================================================================

detect_linux_capabilities(Family) ->
    %% Check OTP version - need 27+ for socket module features
    case otp_version_check() of
        false ->
            #{gso => false, gro => false, backend => gen_udp};
        true ->
            %% Try to create a test socket and check GSO/GRO
            test_linux_socket_capabilities(Family)
    end.

otp_version_check() ->
    %% Check if OTP version is 27 or higher
    try
        OtpRelease = erlang:system_info(otp_release),
        Version = list_to_integer(OtpRelease),
        Version >= 27
    catch
        _:_ -> false
    end.

test_linux_socket_capabilities(Family) ->
    case socket:open(Family, dgram, udp) of
        {ok, Socket} ->
            %% Test GSO
            GSOSupported = test_gso(Socket),
            %% Test GRO
            GROSupported = test_gro(Socket),

            socket:close(Socket),

            #{
                gso => GSOSupported,
                gro => GROSupported,
                backend => socket
            };
        {error, _} ->
            #{gso => false, gro => false, backend => gen_udp}
    end.

test_gso(Socket) ->
    %% UDP_SEGMENT setsockopt expects sizeof(int) on Linux; passing 2
    %% bytes makes the kernel reject with EINVAL and GSO is reported as
    %% unsupported even on kernels that have it.
    case socket:setopt_native(Socket, {udp, ?UDP_SEGMENT}, <<1200:32/native>>) of
        ok -> true;
        {error, _} -> false
    end.

test_gro(Socket) ->
    %% Try to set UDP_GRO option
    case socket:setopt_native(Socket, {udp, ?UDP_GRO}, <<1:32/native>>) of
        ok -> true;
        {error, _} -> false
    end.

%%====================================================================
%% Internal Functions - Socket Option Conversion
%%====================================================================

set_socket_opts(_Socket, []) ->
    ok;
set_socket_opts(Socket, [{active, N} | Rest]) when is_integer(N) ->
    %% socket module doesn't have active mode - skip
    set_socket_opts(Socket, Rest);
set_socket_opts(Socket, [{active, _} | Rest]) ->
    %% Skip active mode
    set_socket_opts(Socket, Rest);
set_socket_opts(Socket, [{recbuf, Size} | Rest]) ->
    _ = socket:setopt(Socket, {socket, rcvbuf}, Size),
    set_socket_opts(Socket, Rest);
set_socket_opts(Socket, [{sndbuf, Size} | Rest]) ->
    _ = socket:setopt(Socket, {socket, sndbuf}, Size),
    set_socket_opts(Socket, Rest);
set_socket_opts(Socket, [_ | Rest]) ->
    %% Skip unknown options
    set_socket_opts(Socket, Rest).
