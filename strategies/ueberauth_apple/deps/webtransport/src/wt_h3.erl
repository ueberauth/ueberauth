%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc HTTP/3 WebTransport protocol helpers.
%%
%% This module bridges the generic HTTP/3 connection layer from quic_h3
%% with WebTransport-specific session negotiation and capsule handling.
%%
-module(wt_h3).

-export([default_settings/0, default_settings/1]).
-export([request_headers/2, request_headers/3, request_headers/4]).
-export([request_session/4, request_session/5]).
-export([response_status/1, is_success_response/1]).
-export([validate_wt_support/2, validate_wt_support/3]).
-export([detect_compat_mode/1]).
-export([send_capsule/3, close_session/4, drain_session/2]).

-include("webtransport.hrl").

-type headers() :: [{binary(), binary()}].
-type compat_mode() :: latest | legacy_browser_compat.

-export_type([headers/0, compat_mode/0]).

%% ============================================================================
%% Settings
%% ============================================================================

%% @deprecated Use `default_settings/1' with an explicit `compat_mode'.
%% Retained for the eunit suite and external callers that haven't migrated.
%% Returns the latest-spec settings.
-spec default_settings() -> map().
default_settings() ->
    default_settings(latest).

%% @doc Return default H3 settings for the given compatibility mode.
-spec default_settings(compat_mode()) -> map().
default_settings(latest) ->
    %% draft-15 §3.1: servers advertise wt_enabled plus initial
    %% flow-control windows. h3_datagram (0x33) is emitted by quic_h3
    %% when `h3_datagram_enabled => true' -- don't duplicate it here
    %% (duplicate setting ids are an H3_SETTINGS_ERROR per
    %% RFC 9114 §7.2.4.1).
    #{
        enable_connect_protocol      => 1,
        wt_enabled                   => 1,
        wt_initial_max_data          => ?DEFAULT_MAX_DATA,
        wt_initial_max_streams_bidi  => ?DEFAULT_MAX_STREAMS_BIDI,
        wt_initial_max_streams_uni   => ?DEFAULT_MAX_STREAMS_UNI
    };
default_settings(legacy_browser_compat) ->
    %% draft-02 (Chrome / Firefox / quic-go v0.9). Never mix these
    %% with the latest-spec settings in one handshake.
    #{
        enable_connect_protocol              => 1,
        ?SETTINGS_ENABLE_WEBTRANSPORT_DRAFT02 => 1
    }.

%% ============================================================================
%% Session Establishment
%% ============================================================================

%% @doc Build WebTransport CONNECT request headers for the latest draft.
-spec request_headers(binary(), binary()) -> headers().
request_headers(Authority, Path) ->
    request_headers(Authority, Path, [], latest).

%% @doc Build WebTransport CONNECT request headers with additional custom headers.
-spec request_headers(binary(), binary(), headers()) -> headers().
request_headers(Authority, Path, ExtraHeaders) ->
    request_headers(Authority, Path, ExtraHeaders, latest).

%% @doc Build WebTransport CONNECT request headers for the specified compat mode.
-spec request_headers(binary(), binary(), headers(), compat_mode()) -> headers().
request_headers(Authority, Path, ExtraHeaders, latest) ->
    %% draft-15 §3.2: `:protocol' MUST be `webtransport-h3'. No draft-02
    %% Sec- header on this path.
    BaseHeaders = [
        {<<":method">>, <<"CONNECT">>},
        {<<":protocol">>, <<"webtransport-h3">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, Authority},
        {<<":path">>, Path}
    ],
    BaseHeaders ++ strip_reserved_headers(ExtraHeaders);
request_headers(Authority, Path, ExtraHeaders, legacy_browser_compat) ->
    %% draft-02: `:protocol' = webtransport + the draft-02 marker header.
    %% Chrome / Firefox / quic-go v0.9 expect this exact shape.
    BaseHeaders = [
        {<<":method">>, <<"CONNECT">>},
        {<<":protocol">>, <<"webtransport">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, Authority},
        {<<":path">>, Path},
        {<<"sec-webtransport-http3-draft02">>, <<"1">>}
    ],
    BaseHeaders ++ strip_reserved_headers(ExtraHeaders).

%% @doc Send a WebTransport CONNECT request on the H3 connection, returning the stream ID.
-spec request_session(pid(), binary(), binary(), headers()) ->
    {ok, non_neg_integer()} | {error, term()}.
request_session(H3Conn, Authority, Path, ExtraHeaders) ->
    request_session(H3Conn, Authority, Path, ExtraHeaders, latest).

%% @doc Send a WebTransport CONNECT request using the given compat mode.
-spec request_session(pid(), binary(), binary(), headers(), compat_mode()) ->
    {ok, non_neg_integer()} | {error, term()}.
request_session(H3Conn, Authority, Path, ExtraHeaders, CompatMode) ->
    Headers = request_headers(Authority, Path, ExtraHeaders, CompatMode),
    quic_h3:request(H3Conn, Headers, #{end_stream => false}).

%% @doc Extract the numeric HTTP status code from response headers.
-spec response_status(headers()) -> {ok, non_neg_integer()} | {error, term()}.
response_status(Headers) ->
    case lists:keyfind(<<":status">>, 1, Headers) of
        {_, StatusBin} when is_binary(StatusBin) ->
            try
                {ok, binary_to_integer(StatusBin)}
            catch
                error:badarg -> {error, {invalid_status, StatusBin}}
            end;
        false ->
            {error, missing_status}
    end.

%% @doc Return true if the response headers contain a 2xx status code.
-spec is_success_response(headers()) -> boolean().
is_success_response(Headers) ->
    case response_status(Headers) of
        {ok, Status} when Status >= 200, Status < 300 -> true;
        _ -> false
    end.

%% ============================================================================
%% Peer Validation
%% ============================================================================

%% @doc Check that the peer advertises WebTransport support (latest draft).
-spec validate_wt_support(pid(), pid()) -> ok | {error, term()}.
validate_wt_support(H3Conn, QuicConn) ->
    validate_wt_support(H3Conn, QuicConn, latest).

%% @doc Check that the peer advertises WebTransport support for the given compat mode.
-spec validate_wt_support(pid(), pid(), compat_mode()) -> ok | {error, term()}.
validate_wt_support(H3Conn, QuicConn, CompatMode) ->
    case quic_h3:get_peer_settings(H3Conn) of
        undefined ->
            {error, settings_not_received};
        PeerSettings ->
            case validate_required_settings(PeerSettings, CompatMode) of
                ok -> validate_transport_params(QuicConn);
                Err -> Err
            end
    end.

validate_transport_params(QuicConn) ->
    case quic:get_peer_transport_params(QuicConn) of
        {ok, TP} ->
            case maps:get(max_datagram_frame_size, TP, 0) of
                0 -> {error, datagrams_not_enabled};
                _ ->
                    %% reset_stream_at is required by draft-15 §3.1.
                    %% If the peer does not advertise it, warn but allow
                    %% (many implementations have not adopted it yet).
                    case maps:get(reset_stream_at, TP, false) of
                        true -> ok;
                        false ->
                            logger:debug("peer does not advertise reset_stream_at"),
                            ok
                    end
            end;
        {error, _} ->
            %% Transport params not yet available (rare race).
            ok
    end.

validate_required_settings(PeerSettings, CompatMode) ->
    case setting_enabled(PeerSettings, enable_connect_protocol) of
        false -> {error, connect_protocol_not_enabled};
        true -> check_wt_setting(PeerSettings, CompatMode)
    end.

check_wt_setting(PeerSettings, latest) ->
    %% draft-15 §3.1: peer MUST advertise wt_enabled = 1.
    case setting_enabled(PeerSettings, wt_enabled) of
        true -> ok;
        false -> {error, wt_not_enabled}
    end;
check_wt_setting(PeerSettings, legacy_browser_compat) ->
    case maps:find(?SETTINGS_ENABLE_WEBTRANSPORT_DRAFT02, PeerSettings) of
        {ok, V} when V =/= 0 -> ok;
        _ -> {error, wt_not_enabled}
    end.

setting_enabled(Settings, Key) ->
    Value = maps:get(Key, Settings, 0),
    Value =:= 1 orelse Value =:= true.

%% Server-side helper: read the incoming CONNECT request and decide which
%% compat mode it is asking for. Returns `{ok, latest | legacy_browser_compat}'
%% on a well-formed request or `{error, Reason}' if the three signals
%% disagree.
%% @doc Determine the compat mode (latest or legacy) from incoming CONNECT headers.
-spec detect_compat_mode(headers()) ->
    {ok, compat_mode()} | {error, term()}.
detect_compat_mode(Headers) ->
    Protocol = header_value(<<":protocol">>, Headers),
    Draft02Marker = header_value(<<"sec-webtransport-http3-draft02">>, Headers),
    case {Protocol, Draft02Marker} of
        {<<"webtransport-h3">>, undefined} ->
            {ok, latest};
        {<<"webtransport-h3">>, _} ->
            %% Sending the draft-02 marker alongside the draft-15 :protocol
            %% is not a valid handshake.
            {error, mixed_draft_signals};
        {<<"webtransport">>, _} ->
            %% draft-02. Some implementations (webtransport-go) do not send
            %% the `Sec-Webtransport-Http3-Draft02' header; treat the
            %% :protocol alone as sufficient evidence of draft-02 intent.
            {ok, legacy_browser_compat};
        {undefined, _} ->
            {error, missing_protocol};
        {_, _} ->
            {error, unknown_protocol}
    end.

header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.

%% ============================================================================
%% CONNECT Stream Capsules
%% ============================================================================

%% @doc Encode and send a capsule on the CONNECT stream for the given session.
-spec send_capsule(pid(), non_neg_integer(), wt_h3_capsule:capsule()) -> ok | {error, term()}.
send_capsule(H3Conn, SessionId, Capsule) ->
    quic_h3:send_data(H3Conn, SessionId, wt_h3_capsule:encode(Capsule), false).

%% @doc Send a CLOSE_WEBTRANSPORT_SESSION capsule on the CONNECT stream.
-spec close_session(pid(), non_neg_integer(), non_neg_integer(), binary()) -> ok | {error, term()}.
close_session(H3Conn, SessionId, ErrorCode, Reason) ->
    send_capsule(H3Conn, SessionId, wt_h3_capsule:close_session(ErrorCode, Reason)).

%% @doc Send a DRAIN_WEBTRANSPORT_SESSION capsule to signal graceful shutdown.
-spec drain_session(pid(), non_neg_integer()) -> ok | {error, term()}.
drain_session(H3Conn, SessionId) ->
    send_capsule(H3Conn, SessionId, wt_h3_capsule:drain_session()).

strip_reserved_headers(Headers) ->
    Reserved = #{
        <<":method">> => true,
        <<":protocol">> => true,
        <<":scheme">> => true,
        <<":authority">> => true,
        <<":path">> => true
    },
    [
        {Name, Value}
     || {Name, Value} <- Headers,
        not maps:is_key(Name, Reserved)
    ].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

request_headers_latest_test() ->
    Headers = request_headers(<<"example.com">>, <<"/wt">>,
                              [{<<"origin">>, <<"https://example.com">>}], latest),
    ?assertEqual({<<":method">>, <<"CONNECT">>}, lists:nth(1, Headers)),
    ?assert(lists:member({<<":protocol">>, <<"webtransport-h3">>}, Headers)),
    ?assertNot(lists:keymember(<<"sec-webtransport-http3-draft02">>, 1, Headers)),
    ?assert(lists:member({<<"origin">>, <<"https://example.com">>}, Headers)).

request_headers_legacy_test() ->
    Headers = request_headers(<<"example.com">>, <<"/wt">>, [], legacy_browser_compat),
    ?assert(lists:member({<<":protocol">>, <<"webtransport">>}, Headers)),
    ?assert(lists:member({<<"sec-webtransport-http3-draft02">>, <<"1">>}, Headers)).

default_settings_latest_disjoint_from_legacy_test() ->
    Latest = default_settings(latest),
    Legacy = default_settings(legacy_browser_compat),
    ?assert(maps:is_key(wt_enabled, Latest)),
    ?assertNot(maps:is_key(?SETTINGS_ENABLE_WEBTRANSPORT_DRAFT02, Latest)),
    ?assert(maps:is_key(?SETTINGS_ENABLE_WEBTRANSPORT_DRAFT02, Legacy)),
    ?assertNot(maps:is_key(wt_enabled, Legacy)).

detect_compat_mode_latest_test() ->
    ?assertEqual({ok, latest},
                 detect_compat_mode([{<<":protocol">>, <<"webtransport-h3">>}])).

detect_compat_mode_legacy_test() ->
    ?assertEqual({ok, legacy_browser_compat},
                 detect_compat_mode([{<<":protocol">>, <<"webtransport">>},
                                     {<<"sec-webtransport-http3-draft02">>, <<"1">>}])).

detect_compat_mode_bare_legacy_test() ->
    %% webtransport-go v0.9 sends `:protocol = webtransport' without the
    %% draft-02 Sec- header; we still recognize it as legacy.
    ?assertEqual({ok, legacy_browser_compat},
                 detect_compat_mode([{<<":protocol">>, <<"webtransport">>}])).

detect_compat_mode_rejects_mixed_test() ->
    ?assertEqual({error, mixed_draft_signals},
                 detect_compat_mode([{<<":protocol">>, <<"webtransport-h3">>},
                                     {<<"sec-webtransport-http3-draft02">>, <<"1">>}])).

response_status_test_() ->
    [
        ?_assertEqual({ok, 200}, response_status([{<<":status">>, <<"200">>}])),
        ?_assert(is_success_response([{<<":status">>, <<"204">>}])),
        ?_assertNot(is_success_response([{<<":status">>, <<"404">>}]))
    ].

-endif.
