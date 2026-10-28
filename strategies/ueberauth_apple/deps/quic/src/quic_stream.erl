%%% -*- erlang -*-
%%%
%%% QUIC Stream Management
%%% RFC 9000 Section 2 - Streams
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC stream state management.
%%%
%%% Standalone helper: `quic_connection' does not use it. The connection
%%% keeps its own `#stream_state{}' inline, and that is the code that
%%% runs on the wire. This module models the same lifecycle on its own.
%%%
%%% It manages individual stream state, including:
%%% - Stream lifecycle (idle -> open -> half-closed -> closed)
%%% - Send and receive buffers
%%% - Per-stream flow control
%%% - Data ordering and reassembly
%%%
%%% == Stream Types ==
%%%
%%% Stream IDs encode the initiator and directionality:
%%% - Bit 0: 0 = client-initiated, 1 = server-initiated
%%% - Bit 1: 0 = bidirectional, 1 = unidirectional
%%%
%%% Client-initiated bidirectional: 0, 4, 8, ...
%%% Server-initiated bidirectional: 1, 5, 9, ...
%%% Client-initiated unidirectional: 2, 6, 10, ...
%%% Server-initiated unidirectional: 3, 7, 11, ...
%%%

-module(quic_stream).

-include("quic.hrl").

-export([
    %% Stream creation
    new/2,
    new/3,

    %% Stream properties
    id/1,
    state/1,
    is_local/2,
    is_bidi/1,
    initiator/1,
    direction/1,

    %% Send operations
    send/2,
    send_fin/1,
    can_send/1,
    bytes_to_send/1,
    get_send_data/2,
    ack_send/2,

    %% Receive operations
    receive_data/4,
    receive_fin/2,
    read/1,
    read/2,
    bytes_available/1,

    %% Flow control
    update_max_data/2,
    update_send_window/2,
    blocked/1,

    %% State transitions
    reset/2,
    stop_sending/2,
    close/1,
    is_closed/1,
    is_send_closed/1,
    is_recv_closed/1,

    %% Priority (RFC 9218)
    get_priority/1,
    set_priority/3
]).

%% Internal stream state record
-record(stream, {
    id :: non_neg_integer(),
    state :: idle | open | half_closed_local | half_closed_remote | closed,

    %% Send state
    send_offset = 0 :: non_neg_integer(),
    send_max_data :: non_neg_integer(),
    send_fin = false :: boolean(),
    send_fin_acked = false :: boolean(),
    send_buffer = queue:new() :: queue:queue({non_neg_integer(), binary()}),
    % Bytes waiting to be sent
    send_pending = 0 :: non_neg_integer(),

    %% Receive state
    recv_offset = 0 :: non_neg_integer(),
    recv_max_data :: non_neg_integer(),
    recv_fin = false :: boolean(),
    recv_buffer = gb_trees:empty() :: gb_trees:tree(non_neg_integer(), binary()),
    % Contiguous bytes available
    recv_contiguous = 0 :: non_neg_integer(),

    %% Final size (set when FIN received or sent)
    final_size :: non_neg_integer() | undefined,

    %% Error codes (set on RESET_STREAM or STOP_SENDING)
    reset_error :: non_neg_integer() | undefined,
    stop_error :: non_neg_integer() | undefined,

    %% Stream Priority (RFC 9218)
    %% Urgency: 0-7 (lower = more urgent, default 3)
    %% Incremental: boolean (data can be processed incrementally)
    urgency = 3 :: 0..7,
    incremental = false :: boolean()
}).

-opaque stream() :: #stream{}.
-export_type([stream/0]).

%%====================================================================
%% Stream Creation
%%====================================================================

%% @doc Create a new stream with default flow control limits.
-spec new(non_neg_integer(), client | server) -> stream().
new(StreamId, Role) ->
    new(StreamId, Role, #{}).

%% @doc Create a new stream with custom options.
-spec new(non_neg_integer(), client | server, map()) -> stream().
new(StreamId, Role, Opts) ->
    IsLocal = is_local_stream(StreamId, Role),
    InitialState =
        case IsLocal of
            % We initiated, so it's open
            true -> open;
            % Peer initiated, waiting for first frame
            false -> idle
        end,
    #stream{
        id = StreamId,
        state = InitialState,
        send_max_data = maps:get(send_max_data, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA),
        recv_max_data = maps:get(recv_max_data, Opts, ?DEFAULT_INITIAL_MAX_STREAM_DATA)
    }.

%%====================================================================
%% Stream Properties
%%====================================================================

%% @doc Get the stream ID.
-spec id(stream()) -> non_neg_integer().
id(#stream{id = Id}) -> Id.

%% @doc Get the current stream state.
-spec state(stream()) -> idle | open | half_closed_local | half_closed_remote | closed.
state(#stream{state = State}) -> State.

%% @doc Check if this stream was initiated by us.
-spec is_local(stream(), client | server) -> boolean().
is_local(#stream{id = Id}, Role) ->
    is_local_stream(Id, Role).

%% @doc Check if this is a bidirectional stream.
-spec is_bidi(stream()) -> boolean().
is_bidi(#stream{id = Id}) ->
    (Id band 16#02) =:= 0.

%% @doc Get the initiator of the stream.
-spec initiator(stream()) -> client | server.
initiator(#stream{id = Id}) ->
    case Id band 16#01 of
        0 -> client;
        1 -> server
    end.

%% @doc Get the direction of the stream.
-spec direction(stream()) -> bidirectional | unidirectional.
direction(Stream) ->
    case is_bidi(Stream) of
        true -> bidirectional;
        false -> unidirectional
    end.

%%====================================================================
%% Send Operations
%%====================================================================

%% @doc Queue data for sending on the stream.
-spec send(stream(), binary()) -> {ok, stream()} | {error, term()}.
send(#stream{state = State}, _Data) when
    State =:= half_closed_local; State =:= closed
->
    {error, stream_closed};
send(
    #stream{
        send_buffer = Buffer,
        send_offset = Offset,
        send_pending = Pending
    } = Stream,
    Data
) ->
    DataSize = byte_size(Data),
    NewBuffer = queue:in({Offset + Pending, Data}, Buffer),
    {ok, Stream#stream{
        send_buffer = NewBuffer,
        send_pending = Pending + DataSize
    }}.

%% @doc Mark the stream as finished for sending (FIN).
-spec send_fin(stream()) -> {ok, stream()} | {error, term()}.
send_fin(#stream{state = State}) when State =:= half_closed_local; State =:= closed ->
    {error, already_closed};
send_fin(#stream{state = open} = Stream) ->
    {ok, Stream#stream{send_fin = true, state = half_closed_local}};
send_fin(#stream{state = half_closed_remote} = Stream) ->
    {ok, Stream#stream{send_fin = true, state = closed}};
send_fin(Stream) ->
    {ok, Stream#stream{send_fin = true}}.

%% @doc Check if we can send data on this stream.
-spec can_send(stream()) -> boolean().
can_send(#stream{state = State, send_offset = Offset, send_max_data = Max}) ->
    (State =:= open orelse State =:= half_closed_remote) andalso Offset < Max.

%% @doc Get number of bytes waiting to be sent.
-spec bytes_to_send(stream()) -> non_neg_integer().
bytes_to_send(#stream{send_pending = Pending}) -> Pending.

%% @doc Get data to send, up to MaxBytes.
%% Returns {Data, Offset, Fin, UpdatedStream}
-spec get_send_data(stream(), non_neg_integer()) ->
    {binary(), non_neg_integer(), boolean(), stream()}.
get_send_data(
    #stream{
        send_buffer = Buffer,
        send_offset = Offset,
        send_max_data = MaxData,
        send_fin = Fin,
        send_pending = Pending
    } = Stream,
    MaxBytes
) ->
    %% Calculate how much we can actually send
    Available = min(Pending, min(MaxBytes, MaxData - Offset)),
    {Data, NewBuffer, Sent} = drain_buffer(Buffer, Available),
    NewOffset = Offset + Sent,
    %% FIN only if no more data and FIN requested
    SendFin = Fin andalso (Pending - Sent =:= 0),
    NewStream = Stream#stream{
        send_buffer = NewBuffer,
        send_offset = NewOffset,
        send_pending = Pending - Sent
    },
    {Data, Offset, SendFin, NewStream}.

%% @doc Acknowledge that sent data was received.
-spec ack_send(stream(), non_neg_integer()) -> stream().
ack_send(#stream{send_fin = true, send_pending = 0} = Stream, _AckedOffset) ->
    Stream#stream{send_fin_acked = true};
ack_send(Stream, _AckedOffset) ->
    Stream.

%%====================================================================
%% Receive Operations
%%====================================================================

%% @doc Receive data at a specific offset.
-spec receive_data(stream(), non_neg_integer(), binary(), boolean()) ->
    {ok, stream()} | {error, term()}.
receive_data(#stream{state = State}, _Offset, _Data, _Fin) when
    State =:= half_closed_remote; State =:= closed
->
    {error, stream_closed};
receive_data(#stream{final_size = FinalSize}, Offset, Data, _Fin) when
    FinalSize =/= undefined, Offset + byte_size(Data) > FinalSize
->
    {error, final_size_error};
receive_data(
    #stream{
        recv_buffer = Buffer,
        recv_contiguous = Contiguous,
        state = State
    } = Stream,
    Offset,
    Data,
    Fin
) ->
    %% Insert data into buffer
    NewBuffer = gb_trees:enter(Offset, Data, Buffer),

    %% Calculate new contiguous offset
    NewContiguous = calculate_contiguous(NewBuffer, Contiguous),

    %% Update state for FIN
    {NewState, NewFinalSize} =
        case Fin of
            true ->
                FS = Offset + byte_size(Data),
                NS =
                    case State of
                        % Received data with FIN before sending
                        idle -> half_closed_remote;
                        open -> half_closed_remote;
                        half_closed_local -> closed;
                        _ -> State
                    end,
                {NS, FS};
            false ->
                {
                    case State of
                        idle -> open;
                        _ -> State
                    end,
                    Stream#stream.final_size
                }
        end,

    {ok, Stream#stream{
        recv_buffer = NewBuffer,
        recv_contiguous = NewContiguous,
        recv_fin = Fin orelse Stream#stream.recv_fin,
        final_size = NewFinalSize,
        state = NewState
    }}.

%% @doc Mark that FIN was received at the given offset.
-spec receive_fin(stream(), non_neg_integer()) -> {ok, stream()} | {error, term()}.
receive_fin(Stream, FinalSize) ->
    receive_data(Stream, FinalSize, <<>>, true).

%% @doc Read all available contiguous data.
-spec read(stream()) -> {binary(), stream()}.
read(Stream) ->
    read(Stream, infinity).

%% @doc Read up to MaxBytes of contiguous data.
-spec read(stream(), non_neg_integer() | infinity) -> {binary(), stream()}.
read(
    #stream{
        recv_buffer = Buffer,
        recv_offset = Offset,
        recv_contiguous = Contiguous
    } = Stream,
    MaxBytes
) ->
    BytesToRead =
        case MaxBytes of
            infinity -> Contiguous - Offset;
            N -> min(N, Contiguous - Offset)
        end,

    {Data, NewBuffer} = read_from_buffer(Buffer, Offset, BytesToRead),
    NewOffset = Offset + byte_size(Data),

    {Data, Stream#stream{
        recv_buffer = NewBuffer,
        recv_offset = NewOffset
    }}.

%% @doc Get number of bytes available for reading.
-spec bytes_available(stream()) -> non_neg_integer().
bytes_available(#stream{recv_offset = Offset, recv_contiguous = Contiguous}) ->
    Contiguous - Offset.

%%====================================================================
%% Flow Control
%%====================================================================

%% @doc Update the maximum data we can receive.
-spec update_max_data(stream(), non_neg_integer()) -> stream().
update_max_data(Stream, NewMax) ->
    Stream#stream{recv_max_data = NewMax}.

%% @doc Update the send window (peer's MAX_STREAM_DATA).
-spec update_send_window(stream(), non_neg_integer()) -> stream().
update_send_window(#stream{send_max_data = OldMax} = Stream, NewMax) ->
    Stream#stream{send_max_data = max(OldMax, NewMax)}.

%% @doc Check if the stream is blocked on flow control.
-spec blocked(stream()) -> boolean().
blocked(#stream{send_offset = Offset, send_max_data = Max, send_pending = Pending}) ->
    Pending > 0 andalso Offset >= Max.

%%====================================================================
%% State Transitions
%%====================================================================

%% @doc Reset the stream (send RESET_STREAM).
-spec reset(stream(), non_neg_integer()) -> stream().
reset(#stream{send_offset = Offset} = Stream, ErrorCode) ->
    Stream#stream{
        state = closed,
        reset_error = ErrorCode,
        final_size = Offset,
        send_buffer = queue:new(),
        send_pending = 0
    }.

%% @doc Handle STOP_SENDING frame from peer.
-spec stop_sending(stream(), non_neg_integer()) -> stream().
stop_sending(Stream, ErrorCode) ->
    Stream#stream{
        stop_error = ErrorCode,
        send_buffer = queue:new(),
        send_pending = 0
    }.

%% @doc Close the stream gracefully.
-spec close(stream()) -> stream().
close(Stream) ->
    Stream#stream{state = closed}.

%% @doc Check if the stream is fully closed.
-spec is_closed(stream()) -> boolean().
is_closed(#stream{state = closed}) -> true;
is_closed(_) -> false.

%% @doc Check if the send side is closed.
-spec is_send_closed(stream()) -> boolean().
is_send_closed(#stream{state = half_closed_local}) -> true;
is_send_closed(#stream{state = closed}) -> true;
is_send_closed(_) -> false.

%% @doc Check if the receive side is closed.
-spec is_recv_closed(stream()) -> boolean().
is_recv_closed(#stream{state = half_closed_remote}) -> true;
is_recv_closed(#stream{state = closed}) -> true;
is_recv_closed(_) -> false.

%%====================================================================
%% Priority (RFC 9218)
%%====================================================================

%% @doc Get the stream priority.
%% Returns {Urgency, Incremental} where Urgency is 0-7 (lower = more urgent)
%% and Incremental indicates whether data can be processed incrementally.
-spec get_priority(stream()) -> {0..7, boolean()}.
get_priority(#stream{urgency = Urgency, incremental = Incremental}) ->
    {Urgency, Incremental}.

%% @doc Set the stream priority.
%% Urgency: 0-7 (lower = more urgent, default 3)
%% Incremental: boolean (data can be processed incrementally, default false)
%% Returns {ok, UpdatedStream} or {error, invalid_urgency}.
-spec set_priority(stream(), 0..7, boolean()) -> {ok, stream()} | {error, invalid_urgency}.
set_priority(Stream, Urgency, Incremental) when
    Urgency >= 0, Urgency =< 7, is_boolean(Incremental)
->
    {ok, Stream#stream{urgency = Urgency, incremental = Incremental}};
set_priority(_Stream, _Urgency, _Incremental) ->
    {error, invalid_urgency}.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Check if stream was initiated locally
is_local_stream(StreamId, client) ->
    % Even = client-initiated
    (StreamId band 16#01) =:= 0;
is_local_stream(StreamId, server) ->
    % Odd = server-initiated
    (StreamId band 16#01) =:= 1.

%% Drain data from send buffer
drain_buffer(Buffer, MaxBytes) ->
    drain_buffer(Buffer, MaxBytes, [], 0).

drain_buffer(Buffer, 0, Acc, Total) ->
    {iolist_to_binary(lists:reverse(Acc)), Buffer, Total};
drain_buffer(Buffer, Remaining, Acc, Total) ->
    case queue:out(Buffer) of
        {empty, _} ->
            {iolist_to_binary(lists:reverse(Acc)), Buffer, Total};
        {{value, {_Offset, Data}}, NewBuffer} ->
            Size = byte_size(Data),
            if
                Size =< Remaining ->
                    drain_buffer(NewBuffer, Remaining - Size, [Data | Acc], Total + Size);
                true ->
                    %% Split the chunk
                    <<Take:Remaining/binary, Rest/binary>> = Data,
                    %% Put the rest back
                    FinalBuffer = queue:in_r({_Offset + Remaining, Rest}, NewBuffer),
                    {iolist_to_binary(lists:reverse([Take | Acc])), FinalBuffer, Total + Remaining}
            end
    end.

%% Calculate contiguous offset from buffer
calculate_contiguous(Buffer, Current) ->
    case gb_trees:is_empty(Buffer) of
        true ->
            Current;
        false ->
            %% Use iteration limit to prevent stack overflow with highly fragmented buffers
            calculate_contiguous_loop(Buffer, Current, 10000)
    end.

%% Tail-recursive with iteration limit to prevent runaway loops
calculate_contiguous_loop(_Buffer, Current, 0) ->
    %% Hit iteration limit - return current position to prevent infinite loop
    Current;
calculate_contiguous_loop(Buffer, Current, Remaining) ->
    case gb_trees:lookup(Current, Buffer) of
        {value, Data} ->
            DataSize = byte_size(Data),
            case DataSize of
                % Empty data, stop here
                0 -> Current;
                _ -> calculate_contiguous_loop(Buffer, Current + DataSize, Remaining - 1)
            end;
        none ->
            %% No exact match, return current position
            %% (out of order data that doesn't start at Current)
            Current
    end.

%% Read contiguous data from buffer
read_from_buffer(Buffer, Offset, BytesToRead) ->
    read_from_buffer(Buffer, Offset, BytesToRead, []).

read_from_buffer(Buffer, _Offset, 0, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Buffer};
read_from_buffer(Buffer, Offset, Remaining, Acc) ->
    case gb_trees:lookup(Offset, Buffer) of
        {value, Data} ->
            Size = byte_size(Data),
            NewBuffer = gb_trees:delete(Offset, Buffer),
            if
                Size =< Remaining ->
                    read_from_buffer(NewBuffer, Offset + Size, Remaining - Size, [Data | Acc]);
                true ->
                    <<Take:Remaining/binary, Rest/binary>> = Data,
                    FinalBuffer = gb_trees:enter(Offset + Remaining, Rest, NewBuffer),
                    {iolist_to_binary(lists:reverse([Take | Acc])), FinalBuffer}
            end;
        none ->
            {iolist_to_binary(lists:reverse(Acc)), Buffer}
    end.
