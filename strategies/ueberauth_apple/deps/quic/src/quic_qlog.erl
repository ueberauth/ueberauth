%%%-------------------------------------------------------------------
%%% @doc QLOG Tracing for QUIC (draft-ietf-quic-qlog-quic-events)
%%%
%%% Provides JSON-SEQ format trace files for debug visibility with
%%% Wireshark/qvis compatibility.
%%%
%%% Usage: pass `qlog' option to `quic:connect/4':
%%% `#{qlog => #{enabled => true, dir => "/tmp/qlog"}}'
%%% @end
%%%-------------------------------------------------------------------
-module(quic_qlog).

-include("quic_qlog.hrl").

%% API
-export([
    new/3,
    close/1,
    is_enabled/1
]).

%% Event emission
-export([
    packet_sent/2,
    packet_received/2,
    frames_processed/2,
    connection_started/1,
    connection_state_updated/3,
    connection_closed/3,
    packets_acked/3,
    packet_lost/2,
    metrics_updated/2
]).

%% Writer process
-export([
    start_writer/2,
    writer_loop/1
]).

%%====================================================================
%% Types
%%====================================================================

-type qlog_opts() :: #{
    enabled => boolean(),
    dir => file:filename(),
    events => all | [atom()]
}.

-export_type([qlog_opts/0]).

%%====================================================================
%% Writer State Record
%%====================================================================

-record(writer_state, {
    fd :: file:io_device(),
    buffer = [] :: [iodata()],
    buffer_size = 0 :: non_neg_integer(),
    flush_timer :: reference() | undefined
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new QLOG context from connection options.
%% Returns undefined if qlog is disabled.
-spec new(Opts :: map(), ODCID :: binary(), VantagePoint :: client | server) ->
    #qlog_ctx{} | undefined.
new(Opts, ODCID, VantagePoint) ->
    %% Check connection options first, then application env
    QlogOpts = get_qlog_opts(Opts),
    case maps:get(enabled, QlogOpts, false) of
        false ->
            undefined;
        true ->
            Dir = maps:get(dir, QlogOpts, "/tmp/qlog"),
            Events = maps:get(events, QlogOpts, all),
            RefTime = erlang:system_time(millisecond),

            %% Create directory if it doesn't exist
            ok = filelib:ensure_dir(filename:join(Dir, "dummy")),

            %% Generate filename: {odcid_hex}_{vantage}_{timestamp}.qlog
            Filename = generate_filename(Dir, ODCID, VantagePoint, RefTime),

            %% Create JSON-SEQ header
            Header = encode_header(ODCID, VantagePoint, RefTime),

            %% Start writer process
            {ok, WriterPid} = start_writer(Filename, Header),

            #qlog_ctx{
                enabled = true,
                writer = WriterPid,
                odcid = ODCID,
                reference_time = RefTime,
                vantage_point = VantagePoint,
                events = Events,
                dir = Dir
            }
    end.

%% @doc Close the QLOG context and flush remaining data.
-spec close(#qlog_ctx{} | undefined) -> ok.
close(undefined) ->
    ok;
close(#qlog_ctx{enabled = false}) ->
    ok;
close(#qlog_ctx{writer = WriterPid}) when is_pid(WriterPid) ->
    WriterPid ! {close, self()},
    receive
        {closed, WriterPid} -> ok
    after 5000 ->
        %% Force kill if writer doesn't respond
        exit(WriterPid, kill),
        ok
    end;
close(_) ->
    ok.

%% @doc Check if QLOG is enabled for this context.
-spec is_enabled(#qlog_ctx{} | undefined) -> boolean().
is_enabled(undefined) -> false;
is_enabled(#qlog_ctx{enabled = Enabled}) -> Enabled.

%%====================================================================
%% Event Emission
%%====================================================================

%% @doc Log a packet_sent event.
-spec packet_sent(#qlog_ctx{} | undefined, map()) -> ok.
packet_sent(undefined, _) ->
    ok;
packet_sent(#qlog_ctx{enabled = false}, _) ->
    ok;
packet_sent(Ctx, Info) ->
    case event_enabled(Ctx, ?QLOG_PACKET_SENT) of
        false ->
            ok;
        true ->
            Event = #{
                name => <<"quic:packet_sent">>,
                data => encode_packet_info(Info)
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log a packet_received event.
-spec packet_received(#qlog_ctx{} | undefined, map()) -> ok.
packet_received(undefined, _) ->
    ok;
packet_received(#qlog_ctx{enabled = false}, _) ->
    ok;
packet_received(Ctx, Info) ->
    case event_enabled(Ctx, ?QLOG_PACKET_RECEIVED) of
        false ->
            ok;
        true ->
            Event = #{
                name => <<"quic:packet_received">>,
                data => encode_packet_info(Info)
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log frames_processed event.
-spec frames_processed(#qlog_ctx{} | undefined, [term()]) -> ok.
frames_processed(undefined, _) ->
    ok;
frames_processed(#qlog_ctx{enabled = false}, _) ->
    ok;
frames_processed(Ctx, Frames) ->
    case event_enabled(Ctx, ?QLOG_FRAMES_PROCESSED) of
        false ->
            ok;
        true ->
            Event = #{
                name => <<"quic:frames_processed">>,
                data => #{frames => encode_frames(Frames)}
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log connection_started event.
-spec connection_started(#qlog_ctx{} | undefined) -> ok.
connection_started(undefined) ->
    ok;
connection_started(#qlog_ctx{enabled = false}) ->
    ok;
connection_started(#qlog_ctx{odcid = ODCID, vantage_point = VP} = Ctx) ->
    case event_enabled(Ctx, ?QLOG_CONNECTION_STARTED) of
        false ->
            ok;
        true ->
            Event = #{
                name => <<"quic:connection_started">>,
                data => #{
                    odcid => hex_encode(ODCID),
                    vantage_point => VP
                }
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log connection_state_updated event.
-spec connection_state_updated(#qlog_ctx{} | undefined, atom(), atom()) -> ok.
connection_state_updated(undefined, _, _) ->
    ok;
connection_state_updated(#qlog_ctx{enabled = false}, _, _) ->
    ok;
connection_state_updated(Ctx, OldState, NewState) ->
    case event_enabled(Ctx, ?QLOG_CONNECTION_STATE_UPDATED) of
        false ->
            ok;
        true ->
            Event = #{
                name => <<"quic:connection_state_updated">>,
                data => #{
                    old => OldState,
                    new => NewState
                }
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log connection_closed event.
-spec connection_closed(#qlog_ctx{} | undefined, integer() | atom(), binary() | undefined) -> ok.
connection_closed(undefined, _, _) ->
    ok;
connection_closed(#qlog_ctx{enabled = false}, _, _) ->
    ok;
connection_closed(Ctx, ErrorCode, Reason) ->
    case event_enabled(Ctx, ?QLOG_CONNECTION_CLOSED) of
        false ->
            ok;
        true ->
            Data = #{error_code => ErrorCode},
            Data1 =
                case Reason of
                    undefined -> Data;
                    <<>> -> Data;
                    _ -> Data#{reason => Reason}
                end,
            Event = #{
                name => <<"quic:connection_closed">>,
                data => Data1
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log packets_acked event.
-spec packets_acked(#qlog_ctx{} | undefined, [non_neg_integer()], map()) -> ok.
packets_acked(undefined, _, _) ->
    ok;
packets_acked(#qlog_ctx{enabled = false}, _, _) ->
    ok;
packets_acked(Ctx, PacketNumbers, Info) ->
    case event_enabled(Ctx, ?QLOG_PACKETS_ACKED) of
        false ->
            ok;
        true ->
            Data = #{
                packet_numbers => PacketNumbers
            },
            Data1 =
                case maps:get(rtt_sample, Info, undefined) of
                    undefined -> Data;
                    RTT -> Data#{rtt_sample => RTT}
                end,
            Event = #{
                name => <<"quic:packets_acked">>,
                data => Data1
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log packet_lost event.
-spec packet_lost(#qlog_ctx{} | undefined, map()) -> ok.
packet_lost(undefined, _) ->
    ok;
packet_lost(#qlog_ctx{enabled = false}, _) ->
    ok;
packet_lost(Ctx, Info) ->
    case event_enabled(Ctx, ?QLOG_PACKET_LOST) of
        false ->
            ok;
        true ->
            Event = #{
                name => <<"quic:packet_lost">>,
                data => #{
                    packet_number => maps:get(packet_number, Info),
                    reason => maps:get(reason, Info, unknown)
                }
            },
            emit_event(Ctx, Event)
    end.

%% @doc Log metrics_updated event.
-spec metrics_updated(#qlog_ctx{} | undefined, map()) -> ok.
metrics_updated(undefined, _) ->
    ok;
metrics_updated(#qlog_ctx{enabled = false}, _) ->
    ok;
metrics_updated(Ctx, Metrics) ->
    case event_enabled(Ctx, ?QLOG_METRICS_UPDATED) of
        false ->
            ok;
        true ->
            Event = #{
                name => <<"quic:metrics_updated">>,
                data => Metrics
            },
            emit_event(Ctx, Event)
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Get qlog options from connection opts or application env.
get_qlog_opts(Opts) ->
    case maps:get(qlog, Opts, undefined) of
        undefined ->
            %% Check application environment
            application:get_env(quic, qlog, #{enabled => false});
        QlogOpts when is_map(QlogOpts) ->
            QlogOpts
    end.

%% @private Check if an event type should be logged.
event_enabled(#qlog_ctx{events = all}, _Event) -> true;
event_enabled(#qlog_ctx{events = Events}, Event) -> lists:member(Event, Events).

%% @private Generate the qlog filename.
generate_filename(Dir, ODCID, VantagePoint, Timestamp) ->
    ODCIDHex = hex_encode(ODCID),
    VP = atom_to_binary(VantagePoint),
    Filename =
        <<ODCIDHex/binary, "_", VP/binary, "_", (integer_to_binary(Timestamp))/binary, ".qlog">>,
    filename:join(Dir, binary_to_list(Filename)).

%% @private Encode the JSON-SEQ header.
encode_header(ODCID, VantagePoint, RefTime) ->
    Header = #{
        qlog_format => ?QLOG_FORMAT,
        qlog_version => ?QLOG_VERSION,
        title => <<"erlang_quic">>,
        trace => #{
            vantage_point => #{type => VantagePoint},
            common_fields => #{
                protocol_type => [<<"QUIC">>],
                group_id => hex_encode(ODCID),
                reference_time => RefTime
            }
        }
    },
    encode_json(Header).

%% @private Emit an event to the writer process.
emit_event(#qlog_ctx{writer = WriterPid, reference_time = RefTime}, Event) ->
    Now = erlang:system_time(millisecond),
    RelTime = Now - RefTime,
    EventWithTime = Event#{time => RelTime},
    Json = encode_json(EventWithTime),
    WriterPid ! {event, Json},
    ok.

%% @private Encode a packet info map for qlog.
encode_packet_info(Info) ->
    Base = #{},
    Base1 =
        case maps:get(packet_type, Info, undefined) of
            undefined -> Base;
            Type -> Base#{packet_type => Type}
        end,
    Base2 =
        case maps:get(packet_number, Info, undefined) of
            undefined -> Base1;
            PN -> Base1#{packet_number => PN}
        end,
    Base3 =
        case maps:get(length, Info, undefined) of
            undefined -> Base2;
            Len -> Base2#{length => Len}
        end,
    case maps:get(frames, Info, undefined) of
        undefined -> Base3;
        Frames -> Base3#{frames => encode_frames(Frames)}
    end.

%% @private Encode a list of frames for qlog. The decoder yields one
%% padding atom per byte; a run of them is one padding frame.
encode_frames([padding | Rest]) ->
    {Run, Rest1} = lists:splitwith(fun(F) -> F =:= padding end, Rest),
    [#{frame_type => <<"padding">>, length => length(Run) + 1} | encode_frames(Rest1)];
encode_frames([Frame | Rest]) ->
    [encode_frame(Frame) | encode_frames(Rest)];
encode_frames([]) ->
    [].

%% @private Encode a single frame for qlog.
encode_frame(ping) ->
    #{frame_type => <<"ping">>};
encode_frame({crypto, Offset, Data}) ->
    #{frame_type => <<"crypto">>, offset => Offset, length => byte_size(Data)};
encode_frame({ack, Ranges, AckDelay, _ECN}) ->
    #{frame_type => <<"ack">>, ack_ranges => encode_ack_ranges(Ranges), ack_delay => AckDelay};
encode_frame({stream, StreamId, Offset, Data, Fin}) ->
    #{
        frame_type => <<"stream">>,
        stream_id => StreamId,
        offset => Offset,
        length => iolist_size(Data),
        fin => Fin
    };
encode_frame({max_data, MaxData}) ->
    #{frame_type => <<"max_data">>, maximum => MaxData};
encode_frame({max_stream_data, StreamId, MaxData}) ->
    #{frame_type => <<"max_stream_data">>, stream_id => StreamId, maximum => MaxData};
encode_frame({max_streams, bidi, Max}) ->
    #{frame_type => <<"max_streams">>, stream_type => <<"bidirectional">>, maximum => Max};
encode_frame({max_streams, uni, Max}) ->
    #{frame_type => <<"max_streams">>, stream_type => <<"unidirectional">>, maximum => Max};
encode_frame({reset_stream, StreamId, ErrorCode, FinalSize}) ->
    #{
        frame_type => <<"reset_stream">>,
        stream_id => StreamId,
        error_code => ErrorCode,
        final_size => FinalSize
    };
encode_frame({stop_sending, StreamId, ErrorCode}) ->
    #{frame_type => <<"stop_sending">>, stream_id => StreamId, error_code => ErrorCode};
encode_frame({connection_close, ErrorCode, FrameType, Reason}) ->
    #{
        frame_type => <<"connection_close">>,
        error_code => ErrorCode,
        trigger_frame_type => FrameType,
        reason_phrase => Reason
    };
encode_frame({new_connection_id, SeqNum, RetirePrior, CID, _Token}) ->
    #{
        frame_type => <<"new_connection_id">>,
        sequence_number => SeqNum,
        retire_prior_to => RetirePrior,
        connection_id => hex_encode(CID)
    };
encode_frame({retire_connection_id, SeqNum}) ->
    #{frame_type => <<"retire_connection_id">>, sequence_number => SeqNum};
encode_frame({path_challenge, Data}) ->
    #{frame_type => <<"path_challenge">>, data => hex_encode(Data)};
encode_frame({path_response, Data}) ->
    #{frame_type => <<"path_response">>, data => hex_encode(Data)};
encode_frame(handshake_done) ->
    #{frame_type => <<"handshake_done">>};
encode_frame({new_token, Token}) ->
    #{frame_type => <<"new_token">>, length => byte_size(Token)};
encode_frame({datagram, Data}) ->
    #{frame_type => <<"datagram">>, length => iolist_size(Data)};
encode_frame(Frame) when is_tuple(Frame) ->
    #{frame_type => <<"unknown">>, raw => element(1, Frame)};
encode_frame(_) ->
    #{frame_type => <<"unknown">>}.

%% @private Encode ACK ranges for qlog.
encode_ack_ranges(Ranges) ->
    [[Start, End] || {Start, End} <- Ranges].

%% @private Hex encode a binary.
hex_encode(Bin) when is_binary(Bin) ->
    <<<<(hex_digit(N div 16)), (hex_digit(N rem 16))>> || <<N>> <= Bin>>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

%% @private Simple JSON encoder (no external dependencies).
encode_json(Map) when is_map(Map) ->
    Pairs = maps:to_list(Map),
    ["{", lists:join(",", [encode_json_pair(K, V) || {K, V} <- Pairs]), "}"];
encode_json(List) when is_list(List) ->
    ["[", lists:join(",", [encode_json(E) || E <- List]), "]"];
encode_json(Bin) when is_binary(Bin) ->
    ["\"", escape_json_string(Bin), "\""];
encode_json(Atom) when is_atom(Atom) ->
    ["\"", atom_to_binary(Atom), "\""];
encode_json(Int) when is_integer(Int) ->
    integer_to_binary(Int);
encode_json(Float) when is_float(Float) ->
    float_to_binary(Float, [{decimals, 3}, compact]);
encode_json(true) ->
    <<"true">>;
encode_json(false) ->
    <<"false">>;
encode_json(null) ->
    <<"null">>.

encode_json_pair(Key, Value) ->
    [encode_json(Key), ":", encode_json(Value)].

%% @private Escape special JSON characters in a string.
escape_json_string(Bin) ->
    escape_json_string(Bin, <<>>).

escape_json_string(<<>>, Acc) ->
    Acc;
escape_json_string(<<$", Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, "\\\"">>);
escape_json_string(<<$\\, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, "\\\\">>);
escape_json_string(<<$\n, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, "\\n">>);
escape_json_string(<<$\r, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, "\\r">>);
escape_json_string(<<$\t, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, "\\t">>);
escape_json_string(<<C, Rest/binary>>, Acc) when C < 32 ->
    %% Control characters as \uXXXX
    Hex = io_lib:format("\\u~4.16.0B", [C]),
    escape_json_string(Rest, <<Acc/binary, (iolist_to_binary(Hex))/binary>>);
escape_json_string(<<C, Rest/binary>>, Acc) ->
    escape_json_string(Rest, <<Acc/binary, C>>).

%%====================================================================
%% Writer Process
%%====================================================================

%% @doc Start the async writer process.
-spec start_writer(file:filename(), iodata()) -> {ok, pid()}.
start_writer(Filename, Header) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        %% No delayed_write: the loop already batches, and the driver's
        %% own buffer would hold events back until 64 KB or close.
        case file:open(Filename, [write, raw]) of
            {ok, Fd} ->
                %% Write header as first line
                ok = file:write(Fd, [Header, "\n"]),
                Parent ! {writer_ready, self()},
                writer_loop(#writer_state{fd = Fd});
            {error, Reason} ->
                Parent ! {writer_error, self(), Reason},
                exit(Reason)
        end
    end),
    receive
        {writer_ready, Pid} -> {ok, Pid};
        {writer_error, Pid, Reason} -> {error, Reason}
    after 5000 ->
        exit(Pid, kill),
        {error, timeout}
    end.

%% @doc Writer process main loop.
writer_loop(#writer_state{fd = Fd, buffer = Buffer, buffer_size = Size} = State) ->
    receive
        {event, Json} ->
            NewBuffer = [Buffer, Json, "\n"],
            NewSize = Size + iolist_size(Json) + 1,
            NewState = State#writer_state{buffer = NewBuffer, buffer_size = NewSize},
            %% Check if we should flush
            case NewSize >= ?QLOG_MAX_BUFFER_SIZE of
                true ->
                    flush_buffer(NewState);
                false ->
                    %% Start flush timer if not already running
                    NewState2 = maybe_start_flush_timer(NewState),
                    writer_loop(NewState2)
            end;
        flush ->
            flush_buffer(State);
        {close, From} ->
            %% Flush remaining data and close
            case Buffer of
                [] -> ok;
                _ -> file:write(Fd, Buffer)
            end,
            file:close(Fd),
            From ! {closed, self()},
            ok
    after ?QLOG_FLUSH_INTERVAL_MS ->
        %% Periodic flush
        flush_buffer(State)
    end.

%% @private Flush the buffer to disk.
flush_buffer(#writer_state{buffer = [], flush_timer = TimerRef} = State) ->
    cancel_timer(TimerRef),
    writer_loop(State#writer_state{flush_timer = undefined});
flush_buffer(#writer_state{fd = Fd, buffer = Buffer, flush_timer = TimerRef} = State) ->
    cancel_timer(TimerRef),
    file:write(Fd, Buffer),
    writer_loop(State#writer_state{buffer = [], buffer_size = 0, flush_timer = undefined}).

%% @private Start flush timer if not already running.
maybe_start_flush_timer(#writer_state{flush_timer = undefined} = State) ->
    TimerRef = erlang:send_after(?QLOG_FLUSH_INTERVAL_MS, self(), flush),
    State#writer_state{flush_timer = TimerRef};
maybe_start_flush_timer(State) ->
    State.

%% @private Cancel a timer if set.
cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).
