%%% -*- erlang -*-
%%%
%%% QUIC Flow Control
%%% RFC 9000 Section 4 - Flow Control
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Connection-level flow control accounting.
%%%
%%% Standalone helper: `quic_connection' does not use it. The flow
%%% control that runs on the wire is inline in `quic_connection', which
%%% auto-tunes the window from the RTT, keeps per-stream limits, sends
%%% the frames and closes the connection on a violation. Read that for
%%% the library's behaviour; use this module when you want the
%%% accounting on its own.
%%%
%%% What it does:
%%% - Tracking bytes sent against peer's MAX_DATA limit
%%% - Tracking bytes received against our MAX_DATA limit
%%% - Telling you when a MAX_DATA update is due, and what value to grant
%%% - Detecting when we're blocked by flow control
%%%
%%% What it does not do: stream-level accounting, and sending anything.
%%% It emits no frames, so you send MAX_DATA and DATA_BLOCKED yourself
%%% and you decide what a violation does.
%%%
%%% == Flow Control Concepts ==
%%%
%%% - MAX_DATA: Maximum total bytes the peer can send
%%% - DATA_BLOCKED: Indicates sender is blocked by receiver's limit
%%% - Window: The difference between max_data and bytes received
%%%

-module(quic_flow).

-include("quic.hrl").

-export([
    %% State management
    new/0,
    new/1,

    %% Send side
    can_send/2,
    on_data_sent/2,
    on_max_data_received/2,
    send_blocked/1,

    %% Receive side
    on_data_received/2,
    should_send_max_data/1,
    generate_max_data/1,

    %% Queries
    bytes_sent/1,
    bytes_received/1,
    send_limit/1,
    recv_limit/1,
    send_window/1,
    recv_window/1
]).

%% Default values

%% Threshold encodes "fraction of window REMAINING when MAX_DATA fires":
%% fires when bytes_received > recv_max_data_sent - (Initial * THRESHOLD).
%% So 0.5 fires after 50% consumed, 0.75 fires after 25% consumed.
%%
%% Bumped from 0.5 to 0.75 so MAX_DATA updates arrive twice as often
%% under sustained high-throughput. The previous 0.5 threshold stalled
%% sustained single-stream transfers because the sender would deplete
%% the remaining half of the window before the next MAX_DATA frame
%% arrived.
-define(WINDOW_UPDATE_THRESHOLD, 0.75).

%% Flow control state
-record(flow_state, {
    %% Send side (our sending, limited by peer's MAX_DATA)
    bytes_sent = 0 :: non_neg_integer(),
    % Peer's limit on what we can send
    send_max_data :: non_neg_integer(),
    send_blocked = false :: boolean(),

    %% Receive side (peer's sending, limited by our MAX_DATA)
    bytes_received = 0 :: non_neg_integer(),
    % Our limit on what peer can send
    recv_max_data :: non_neg_integer(),
    % Last MAX_DATA we sent
    recv_max_data_sent :: non_neg_integer(),

    %% Configuration
    initial_max_data :: non_neg_integer()
}).

-opaque flow_state() :: #flow_state{}.
-export_type([flow_state/0]).

%%====================================================================
%% State Management
%%====================================================================

%% @doc Create a new flow control state.
-spec new() -> flow_state().
new() ->
    new(#{}).

%% @doc Create a new flow control state with options.
-spec new(map()) -> flow_state().
new(Opts) ->
    InitialMaxData = maps:get(initial_max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA),
    PeerMaxData = maps:get(peer_initial_max_data, Opts, ?DEFAULT_INITIAL_MAX_DATA),
    #flow_state{
        send_max_data = PeerMaxData,
        recv_max_data = InitialMaxData,
        recv_max_data_sent = InitialMaxData,
        initial_max_data = InitialMaxData
    }.

%%====================================================================
%% Send Side
%%====================================================================

%% @doc Check if we can send the specified number of bytes.
-spec can_send(flow_state(), non_neg_integer()) -> boolean().
can_send(#flow_state{bytes_sent = Sent, send_max_data = Max}, Size) ->
    Sent + Size =< Max.

%% @doc Record that we sent data.
%% Returns {ok, NewState} or {blocked, NewState} if we hit the limit.
-spec on_data_sent(flow_state(), non_neg_integer()) ->
    {ok | blocked, flow_state()}.
on_data_sent(#flow_state{bytes_sent = Sent, send_max_data = Max} = State, Size) ->
    NewSent = Sent + Size,
    NewState = State#flow_state{bytes_sent = NewSent},
    case NewSent >= Max of
        true ->
            {blocked, NewState#flow_state{send_blocked = true}};
        false ->
            {ok, NewState#flow_state{send_blocked = false}}
    end.

%% @doc Process a MAX_DATA frame from peer.
%% Updates our send limit.
-spec on_max_data_received(flow_state(), non_neg_integer()) -> flow_state().
on_max_data_received(#flow_state{send_max_data = OldMax} = State, NewMax) ->
    %% MAX_DATA only increases, never decreases
    ActualMax = max(OldMax, NewMax),
    State#flow_state{
        send_max_data = ActualMax,
        send_blocked = false
    }.

%% @doc Check if we're currently blocked on send flow control.
-spec send_blocked(flow_state()) -> boolean().
send_blocked(#flow_state{send_blocked = B}) -> B.

%%====================================================================
%% Receive Side
%%====================================================================

%% @doc Record that we received data.
-spec on_data_received(flow_state(), non_neg_integer()) ->
    {ok, flow_state()} | {error, flow_control_error}.
on_data_received(
    #flow_state{bytes_received = Received, recv_max_data = Max} = State,
    Size
) ->
    NewReceived = Received + Size,
    case NewReceived > Max of
        true ->
            {error, flow_control_error};
        false ->
            {ok, State#flow_state{bytes_received = NewReceived}}
    end.

%% @doc Check if we should send a MAX_DATA update.
%% True once the granted window is down to its last
%% `?WINDOW_UPDATE_THRESHOLD' fraction. That constant is the fraction
%% remaining, not the fraction consumed, so 0.75 fires after 25% of the
%% window has been used.
-spec should_send_max_data(flow_state()) -> boolean().
should_send_max_data(#flow_state{
    bytes_received = Received,
    recv_max_data_sent = SentMax,
    initial_max_data = Initial
}) ->
    %% Send update when we've consumed > threshold of the window
    WindowConsumed = Received,
    WindowGranted = SentMax,
    Threshold = trunc(Initial * ?WINDOW_UPDATE_THRESHOLD),
    (WindowConsumed > WindowGranted - Threshold).

%% @doc Generate a new MAX_DATA value to send.
%% Returns {NewMaxData, UpdatedState}.
-spec generate_max_data(flow_state()) ->
    {non_neg_integer(), flow_state()}.
generate_max_data(
    #flow_state{
        bytes_received = Received,
        initial_max_data = Initial
    } = State
) ->
    %% Grant a new window based on bytes consumed
    NewMax = Received + Initial,
    NewState = State#flow_state{
        recv_max_data = NewMax,
        recv_max_data_sent = NewMax
    },
    {NewMax, NewState}.

%%====================================================================
%% Queries
%%====================================================================

%% @doc Get total bytes we've sent.
-spec bytes_sent(flow_state()) -> non_neg_integer().
bytes_sent(#flow_state{bytes_sent = B}) -> B.

%% @doc Get total bytes we've received.
-spec bytes_received(flow_state()) -> non_neg_integer().
bytes_received(#flow_state{bytes_received = B}) -> B.

%% @doc Get our current send limit (peer's MAX_DATA).
-spec send_limit(flow_state()) -> non_neg_integer().
send_limit(#flow_state{send_max_data = M}) -> M.

%% @doc Get our current receive limit (our MAX_DATA).
-spec recv_limit(flow_state()) -> non_neg_integer().
recv_limit(#flow_state{recv_max_data = M}) -> M.

%% @doc Get available send window.
-spec send_window(flow_state()) -> non_neg_integer().
send_window(#flow_state{bytes_sent = Sent, send_max_data = Max}) ->
    max(0, Max - Sent).

%% @doc Get available receive window.
-spec recv_window(flow_state()) -> non_neg_integer().
recv_window(#flow_state{bytes_received = Received, recv_max_data = Max}) ->
    max(0, Max - Received).
