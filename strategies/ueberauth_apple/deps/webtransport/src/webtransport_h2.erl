%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc HTTP/2 WebTransport runtime wrapper.
%%
%% WebTransport over HTTP/2 uses a single CONNECT stream to multiplex all
%% WebTransport data through capsules. This module manages the CONNECT stream
%% and handles capsule encoding/decoding.
%%
%% Key differences from HTTP/3 transport:
%% <ul>
%% <li>All streams are multiplexed over one HTTP/2 stream using capsules</li>
%% <li>Flow control is managed via capsules, not native QUIC flow control</li>
%% <li>Datagrams use the DATAGRAM capsule type</li>
%% </ul>
%%
%% @see wt_h2_capsule
%%
-module(webtransport_h2).

-export([new/2, with_peer_settings/2]).
-export([h2_conn/1, connect_stream_id/1, peer_settings/1]).
-export([open_stream/3]).
-export([send/4, send_datagram/2]).
-export([close_session/3, drain_session/1]).
-export([send_capsule/2]).
-export([reset_stream/3, stop_sending/3]).
-export([decode_capsule/1, decode_capsules/1]).

%% Client connection helpers
-export([connect/4, request_headers/2, request_headers/3]).
-export([is_success_response/1]).

-include("webtransport.hrl").

-record(state, {
    h2_conn :: pid(),
    connect_stream_id :: non_neg_integer(),
    peer_settings = #{} :: map(),
    recv_buffer = <<>> :: binary()
}).

-opaque state() :: #state{}.

-export_type([state/0]).

%% ============================================================================
%% Lifecycle
%% ============================================================================

%% @doc Create a new H2 transport state for the given CONNECT stream.
-spec new(pid(), non_neg_integer()) -> state().
new(H2Conn, ConnectStreamId) ->
    #state{
        h2_conn = H2Conn,
        connect_stream_id = ConnectStreamId
    }.

%% @doc Return a new state with updated peer settings.
-spec with_peer_settings(state(), map()) -> state().
with_peer_settings(State, PeerSettings) ->
    State#state{peer_settings = PeerSettings}.

%% @doc Return the HTTP/2 connection pid.
-spec h2_conn(state()) -> pid().
h2_conn(#state{h2_conn = H2Conn}) ->
    H2Conn.

%% @doc Return the HTTP/2 CONNECT stream ID used for this session.
-spec connect_stream_id(state()) -> non_neg_integer().
connect_stream_id(#state{connect_stream_id = StreamId}) ->
    StreamId.

%% @doc Return the peer's advertised WebTransport settings.
-spec peer_settings(state()) -> map().
peer_settings(#state{peer_settings = PeerSettings}) ->
    PeerSettings.

%% ============================================================================
%% Client Connection
%% ============================================================================

%% @doc Establish an HTTP/2 WebTransport session to the given host, port, and path.
-spec connect(string() | binary() | inet:ip_address(), inet:port_number(), binary(), map()) ->
    {ok, state()} | {error, term()}.
connect(Host, Port, Path, Opts) ->
    %% h2:connect hands the host to ssl:connect, which accepts an
    %% inet:ip_address() tuple directly and infers the family from it. h2's
    %% client opts have no family control and its ssl-opt merge rejects bare
    %% socket atoms, so for IPv6 we resolve to an address tuple here.
    H2Host = h2_host(Host),
    SSLOpts = maps:get(ssl_opts, Opts, []),
    H2Opts = #{
        ssl_opts => [{alpn_advertised_protocols, [<<"h2">>]} | SSLOpts]
    },
    case h2:connect(H2Host, Port, H2Opts) of
        {ok, H2Conn} ->
            Authority = authority(Host, Port),
            Headers = request_headers(Authority, Path, maps:get(headers, Opts, [])),
            case h2:request(H2Conn, <<"CONNECT">>, Path, Headers) of
                {ok, StreamId} ->
                    %% Wait for response
                    receive
                        {h2, H2Conn, {response, StreamId, Status, RespHeaders}} when Status >= 200, Status < 300 ->
                            State = new(H2Conn, StreamId),
                            {ok, extract_peer_settings(State, RespHeaders)};
                        {h2, H2Conn, {response, StreamId, Status, _RespHeaders}} ->
                            h2:close(H2Conn),
                            {error, {http_error, Status}};
                        {h2, H2Conn, {stream_reset, StreamId, ErrorCode}} ->
                            h2:close(H2Conn),
                            {error, {stream_reset, ErrorCode}};
                        {h2, H2Conn, {closed, _Reason}} ->
                            {error, connection_closed};
                        {h2, H2Conn, closed} ->
                            {error, connection_closed}
                    after
                        maps:get(timeout, Opts, 30000) ->
                            h2:close(H2Conn),
                            {error, timeout}
                    end;
                {error, Reason} ->
                    h2:close(H2Conn),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Format an HTTP `:authority' from a host (string/binary/IP tuple) and port.
%% IPv6 literals and 8-tuple addresses are bracketed per RFC 3986.
authority(Host, Port) when is_tuple(Host) ->
    authority(inet:ntoa(Host), Port);
authority(Host, Port) when is_list(Host) ->
    authority(list_to_binary(Host), Port);
authority(Host, Port) when is_binary(Host) ->
    PortBin = integer_to_binary(Port),
    case is_ipv6_literal(Host) of
        true -> <<"[", Host/binary, "]:", PortBin/binary>>;
        false -> <<Host/binary, ":", PortBin/binary>>
    end.

is_ipv6_literal(<<"[", _/binary>>) -> false;
is_ipv6_literal(Host) -> binary:match(Host, <<":">>) =/= nomatch.

%% Resolve the host into a form ssl:connect can reach. An IP tuple passes
%% through; an IPv6 literal string/binary is parsed to a tuple so ssl picks
%% the v6 family (a bare literal string would otherwise resolve as a v4
%% hostname and fail). Plain hostnames and IPv4 literals are returned as-is.
h2_host(Host) when is_tuple(Host) ->
    Host;
h2_host(Host) ->
    HostBin = if is_list(Host) -> list_to_binary(Host); true -> Host end,
    case is_ipv6_literal(HostBin) of
        true ->
            case inet:parse_address(binary_to_list(HostBin)) of
                {ok, Addr} -> Addr;
                {error, _} -> Host
            end;
        false ->
            Host
    end.

%% @doc Build CONNECT request headers for an H2 WebTransport session.
-spec request_headers(binary(), binary()) -> [{binary(), binary()}].
request_headers(Authority, Path) ->
    request_headers(Authority, Path, []).

%% @doc Build CONNECT request headers with additional custom headers.
-spec request_headers(binary(), binary(), [{binary(), binary()}]) -> [{binary(), binary()}].
request_headers(Authority, Path, ExtraHeaders) ->
    request_headers(Authority, Path, ExtraHeaders, #{}).

%% @doc Build CONNECT request headers with custom headers and initial flow-control options.
-spec request_headers(binary(), binary(), [{binary(), binary()}], map()) ->
    [{binary(), binary()}].
request_headers(Authority, Path, ExtraHeaders, ConnectOpts) ->
    %% h2_connection derives :authority from the "host" header and rejects
    %% duplicate :authority pseudo-headers, so we only send "host" here.
    BaseHeaders = [
        {<<":protocol">>, <<"webtransport">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, Path},
        {<<"host">>, Authority}
    ],
    %% Emit WebTransport-Init if the caller provided initial windows.
    InitParams = maps:fold(fun
        (max_streams_uni, V, Acc) -> Acc#{u => V};
        (max_streams_bidi, V, Acc) -> Acc#{bl => V};
        (max_data, V, Acc) -> Acc#{br => V};
        (_, _, Acc) -> Acc
    end, #{}, ConnectOpts),
    InitHeader = case map_size(InitParams) of
        0 -> [];
        _ -> [{<<"webtransport-init">>, wt_h2_init:encode(InitParams)}]
    end,
    BaseHeaders ++ InitHeader ++ strip_reserved_headers(ExtraHeaders).

%% @doc Return true if the response headers contain a 2xx status code.
-spec is_success_response([{binary(), binary()}]) -> boolean().
is_success_response(Headers) ->
    case lists:keyfind(<<":status">>, 1, Headers) of
        {_, Status} ->
            try binary_to_integer(Status) of
                N when N >= 200, N < 300 -> true;
                _ -> false
            catch
                _:_ -> false
            end;
        false ->
            false
    end.

%% ============================================================================
%% WebTransport Streams (multiplexed over capsules)
%% ============================================================================

%% @doc No-op: H2 streams are implicitly opened when first used via capsules.
-spec open_stream(state(), non_neg_integer(), bidi | uni) -> ok | {error, term()}.
open_stream(_State, _StreamId, _Type) ->
    %% In HTTP/2, streams are implicitly opened when first used
    %% No explicit open operation needed
    ok.

%% @doc Send data on a multiplexed stream via a WT_STREAM capsule.
-spec send(state(), non_neg_integer(), iodata(), boolean()) -> ok | {error, term()}.
send(#state{h2_conn = H2Conn, connect_stream_id = ConnectStreamId}, StreamId, Data, Fin) ->
    DataBin = iolist_to_binary(Data),
    Capsule = case Fin of
        true -> wt_h2_capsule:wt_stream_fin(StreamId, DataBin);
        false -> wt_h2_capsule:wt_stream(StreamId, DataBin)
    end,
    h2:send_data(H2Conn, ConnectStreamId, wt_h2_capsule:encode(Capsule), false).

%% @doc Send an unreliable datagram via the DATAGRAM capsule type.
-spec send_datagram(state(), binary()) -> ok | {error, term()}.
send_datagram(_State, Data) when byte_size(Data) > ?WT_H2_DATAGRAM_MAX ->
    {error, datagram_too_large};
send_datagram(#state{h2_conn = H2Conn, connect_stream_id = ConnectStreamId}, Data) ->
    Capsule = wt_h2_capsule:datagram(Data),
    h2:send_data(H2Conn, ConnectStreamId, wt_h2_capsule:encode(Capsule), false).

%% ============================================================================
%% Session Control
%% ============================================================================

%% @doc Send a CLOSE_WEBTRANSPORT_SESSION capsule and FIN the CONNECT stream.
-spec close_session(state(), non_neg_integer(), binary()) -> ok | {error, term()}.
close_session(#state{h2_conn = H2Conn, connect_stream_id = ConnectStreamId}, ErrorCode, Reason) ->
    Capsule = wt_h2_capsule:close_session(ErrorCode, Reason),
    h2:send_data(H2Conn, ConnectStreamId, wt_h2_capsule:encode(Capsule), true).

%% @doc Send a DRAIN_WEBTRANSPORT_SESSION capsule to signal graceful shutdown.
-spec drain_session(state()) -> ok | {error, term()}.
drain_session(#state{h2_conn = H2Conn, connect_stream_id = ConnectStreamId}) ->
    Capsule = wt_h2_capsule:drain_session(),
    h2:send_data(H2Conn, ConnectStreamId, wt_h2_capsule:encode(Capsule), false).

%% ============================================================================
%% Stream Control (via capsules)
%% ============================================================================

%% @doc Reset a multiplexed stream by sending a WT_RESET_STREAM capsule.
-spec reset_stream(state(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
reset_stream(#state{h2_conn = H2Conn, connect_stream_id = ConnectStreamId}, StreamId, ErrorCode) ->
    Capsule = wt_h2_capsule:reset_stream(StreamId, ErrorCode),
    h2:send_data(H2Conn, ConnectStreamId, wt_h2_capsule:encode(Capsule), false).

%% @doc Request the peer stop sending on a stream via a WT_STOP_SENDING capsule.
-spec stop_sending(state(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
stop_sending(#state{h2_conn = H2Conn, connect_stream_id = ConnectStreamId}, StreamId, ErrorCode) ->
    Capsule = wt_h2_capsule:stop_sending(StreamId, ErrorCode),
    h2:send_data(H2Conn, ConnectStreamId, wt_h2_capsule:encode(Capsule), false).

%% @doc Write a pre-built capsule on the CONNECT stream (e.g. for flow-control signalling).
-spec send_capsule(state(), wt_h2_capsule:capsule()) -> ok | {error, term()}.
send_capsule(#state{h2_conn = H2Conn, connect_stream_id = ConnectStreamId}, Capsule) ->
    h2:send_data(H2Conn, ConnectStreamId, wt_h2_capsule:encode(Capsule), false).

%% ============================================================================
%% Capsule Decoding
%% ============================================================================

%% @doc Decode a single capsule from the binary buffer, returning any remainder.
-spec decode_capsule(binary()) ->
    {ok, wt_h2_capsule:capsule(), binary()} | {more, pos_integer()} | {error, term()}.
decode_capsule(Bin) ->
    wt_h2_capsule:decode(Bin).

%% @doc Decode all complete capsules from the binary buffer, returning the unparsed tail.
-spec decode_capsules(binary()) ->
    {ok, [wt_h2_capsule:capsule()], binary()} | {error, term()}.
decode_capsules(Bin) ->
    wt_h2_capsule:decode_all(Bin).

%% ============================================================================
%% Internal Functions
%% ============================================================================

strip_reserved_headers(Headers) ->
    Reserved = #{
        <<":method">> => true,
        <<":protocol">> => true,
        <<":scheme">> => true,
        <<":authority">> => true,
        <<":path">> => true
    },
    [{Name, Value} || {Name, Value} <- Headers, not maps:is_key(Name, Reserved)].

extract_peer_settings(State, Headers) ->
    %% Parse WebTransport-Init structured-field header (draft-14 §4.3.2).
    Settings = case lists:keyfind(<<"webtransport-init">>, 1, Headers) of
        {_, InitBin} ->
            case wt_h2_init:parse(InitBin) of
                {ok, Init} -> Init;
                {error, _} -> #{}
            end;
        false ->
            #{}
    end,
    State#state{peer_settings = Settings}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

request_headers_test() ->
    Headers = request_headers(<<"example.com:443">>, <<"/wt">>),
    ?assertEqual({<<":protocol">>, <<"webtransport">>}, lists:nth(1, Headers)),
    ?assertEqual({<<"host">>, <<"example.com:443">>},
                 lists:keyfind(<<"host">>, 1, Headers)).

request_headers_with_init_test() ->
    Headers = request_headers(<<"example.com:443">>, <<"/wt">>, [],
                              #{max_streams_uni => 50, max_streams_bidi => 100}),
    ?assert(lists:keymember(<<"webtransport-init">>, 1, Headers)),
    {_, InitBin} = lists:keyfind(<<"webtransport-init">>, 1, Headers),
    {ok, Parsed} = wt_h2_init:parse(InitBin),
    ?assertEqual(50, maps:get(u, Parsed)),
    ?assertEqual(100, maps:get(bl, Parsed)).

strip_reserved_headers_test() ->
    Input = [
        {<<":method">>, <<"CONNECT">>},
        {<<"origin">>, <<"https://example.com">>},
        {<<":path">>, <<"/wt">>},
        {<<"x-custom">>, <<"value">>}
    ],
    Output = strip_reserved_headers(Input),
    ?assertEqual(2, length(Output)),
    ?assert(lists:member({<<"origin">>, <<"https://example.com">>}, Output)),
    ?assert(lists:member({<<"x-custom">>, <<"value">>}, Output)).

-endif.
