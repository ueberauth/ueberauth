%% @doc HTTP/2 Settings (RFC 7540 Section 6.5)
%%
%% Settings are used to communicate configuration parameters between
%% HTTP/2 endpoints. Each setting is identified by a 16-bit identifier
%% and has a 32-bit value.
%%
-module(h2_settings).

-export([default/0, encode/1, decode/1]).
-export([get/2, set/3, merge/2]).
-export([validate/1, validate/2]).
-export([setting_id/1, encode_value/1]).

-include("h2.hrl").

%% Settings map type. Extension settings whose identifier is not
%% recognised by name are preserved under their raw 16-bit integer
%% key (see decode/1).
-type settings() :: #{
    header_table_size => non_neg_integer(),
    enable_push => 0 | 1,
    max_concurrent_streams => non_neg_integer() | unlimited,
    initial_window_size => non_neg_integer(),
    max_frame_size => non_neg_integer(),
    max_header_list_size => non_neg_integer() | unlimited,
    enable_connect_protocol => 0 | 1,
    wt_initial_max_data => non_neg_integer(),
    wt_initial_max_stream_data_uni => non_neg_integer(),
    wt_initial_max_stream_data_bidi_local => non_neg_integer(),
    wt_initial_max_stream_data_bidi_remote => non_neg_integer(),
    wt_initial_max_streams_uni => non_neg_integer(),
    wt_initial_max_streams_bidi => non_neg_integer(),
    non_neg_integer() => non_neg_integer()
}.

-export_type([settings/0]).

%% @doc Return the default settings values.
-spec default() -> settings().
default() ->
    #{
        header_table_size => ?DEFAULT_HEADER_TABLE_SIZE,
        enable_push => ?DEFAULT_ENABLE_PUSH,
        max_concurrent_streams => ?DEFAULT_MAX_CONCURRENT_STREAMS,
        initial_window_size => ?DEFAULT_INITIAL_WINDOW_SIZE,
        max_frame_size => ?DEFAULT_MAX_FRAME_SIZE,
        max_header_list_size => ?DEFAULT_MAX_HEADER_LIST_SIZE,
        enable_connect_protocol => 0
    }.

%% @doc Get a setting value.
-spec get(atom(), settings()) -> term().
get(Key, Settings) ->
    maps:get(Key, Settings, maps:get(Key, default())).

%% @doc Set a setting value.
-spec set(atom(), term(), settings()) -> settings().
set(Key, Value, Settings) ->
    maps:put(Key, Value, Settings).

%% @doc Merge new settings into existing settings.
-spec merge(settings(), settings()) -> settings().
merge(Base, New) ->
    maps:merge(Base, New).

%% @doc Encode settings to binary for SETTINGS frame payload.
-spec encode(settings()) -> binary().
encode(Settings) ->
    encode_settings(maps:to_list(Settings), <<>>).

encode_settings([], Acc) ->
    Acc;
encode_settings([{Key, Value}|Rest], Acc)
  when is_integer(Key), Key >= 0, Key =< 16#ffff ->
    %% Passthrough for extension settings kept under their raw 16-bit ID.
    V = encode_value(Value),
    encode_settings(Rest, <<Acc/binary, Key:16, V:32>>);
encode_settings([{Key, Value}|Rest], Acc) ->
    case setting_id(Key) of
        undefined ->
            %% Skip unknown atom keys
            encode_settings(Rest, Acc);
        Id ->
            V = encode_value(Value),
            encode_settings(Rest, <<Acc/binary, Id:16, V:32>>)
    end.

setting_id(header_table_size) -> ?SETTINGS_HEADER_TABLE_SIZE;
setting_id(enable_push) -> ?SETTINGS_ENABLE_PUSH;
setting_id(max_concurrent_streams) -> ?SETTINGS_MAX_CONCURRENT_STREAMS;
setting_id(initial_window_size) -> ?SETTINGS_INITIAL_WINDOW_SIZE;
setting_id(max_frame_size) -> ?SETTINGS_MAX_FRAME_SIZE;
setting_id(max_header_list_size) -> ?SETTINGS_MAX_HEADER_LIST_SIZE;
setting_id(enable_connect_protocol) -> ?SETTINGS_ENABLE_CONNECT_PROTOCOL;
setting_id(wt_initial_max_data) -> ?SETTINGS_WT_INITIAL_MAX_DATA;
setting_id(wt_initial_max_stream_data_uni) -> ?SETTINGS_WT_INITIAL_MAX_STREAM_DATA_UNI;
setting_id(wt_initial_max_stream_data_bidi_local) -> ?SETTINGS_WT_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL;
setting_id(wt_initial_max_stream_data_bidi_remote) -> ?SETTINGS_WT_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE;
setting_id(wt_initial_max_streams_uni) -> ?SETTINGS_WT_INITIAL_MAX_STREAMS_UNI;
setting_id(wt_initial_max_streams_bidi) -> ?SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI;
setting_id(_) -> undefined.

encode_value(unlimited) -> 16#ffffffff;
encode_value(V) when is_integer(V) -> V.

%% @doc Decode binary SETTINGS frame payload to settings map.
-spec decode(binary()) -> {ok, settings()} | {error, term()}.
decode(Bin) ->
    decode_settings(Bin, #{}).

decode_settings(<<>>, Acc) ->
    {ok, Acc};
decode_settings(<<Id:16, Value:32, Rest/binary>>, Acc) ->
    case setting_name(Id) of
        {ok, Name} ->
            V = decode_value(Name, Value),
            decode_settings(Rest, maps:put(Name, V, Acc));
        unknown ->
            %% RFC 7540 Section 6.5.2: MUST ignore unknown settings.
            %% "Ignore" means do not act on them, not discard. Preserve
            %% the raw 16-bit ID so extensions (e.g. WebTransport) can
            %% inspect the map without this module being patched.
            decode_settings(Rest, maps:put(Id, Value, Acc))
    end;
decode_settings(Bin, _Acc) when byte_size(Bin) > 0, byte_size(Bin) < 6 ->
    {error, {incomplete_setting, Bin}}.

setting_name(?SETTINGS_HEADER_TABLE_SIZE) -> {ok, header_table_size};
setting_name(?SETTINGS_ENABLE_PUSH) -> {ok, enable_push};
setting_name(?SETTINGS_MAX_CONCURRENT_STREAMS) -> {ok, max_concurrent_streams};
setting_name(?SETTINGS_INITIAL_WINDOW_SIZE) -> {ok, initial_window_size};
setting_name(?SETTINGS_MAX_FRAME_SIZE) -> {ok, max_frame_size};
setting_name(?SETTINGS_MAX_HEADER_LIST_SIZE) -> {ok, max_header_list_size};
setting_name(?SETTINGS_ENABLE_CONNECT_PROTOCOL) -> {ok, enable_connect_protocol};
setting_name(?SETTINGS_WT_INITIAL_MAX_DATA) -> {ok, wt_initial_max_data};
setting_name(?SETTINGS_WT_INITIAL_MAX_STREAM_DATA_UNI) -> {ok, wt_initial_max_stream_data_uni};
setting_name(?SETTINGS_WT_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL) -> {ok, wt_initial_max_stream_data_bidi_local};
setting_name(?SETTINGS_WT_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE) -> {ok, wt_initial_max_stream_data_bidi_remote};
setting_name(?SETTINGS_WT_INITIAL_MAX_STREAMS_UNI) -> {ok, wt_initial_max_streams_uni};
setting_name(?SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI) -> {ok, wt_initial_max_streams_bidi};
setting_name(_) -> unknown.

decode_value(max_concurrent_streams, 16#ffffffff) -> unlimited;
decode_value(max_header_list_size, 16#ffffffff) -> unlimited;
decode_value(_, Value) -> Value.

%% @doc Validate settings values (mode-agnostic).
%% Returns ok if valid, or {error, {setting, Reason}} if invalid.
-spec validate(settings()) -> ok | {error, term()}.
validate(Settings) ->
    validate_settings(maps:to_list(Settings), any).

%% @doc Validate settings values from the perspective of the given mode.
%% Matters for RFC 9113 §6.5.2 -- a client that receives
%% SETTINGS_ENABLE_PUSH with any value other than 0 MUST treat this as a
%% connection PROTOCOL_ERROR. Servers enforce only the 0|1 range.
-spec validate(settings(), client | server | any) -> ok | {error, term()}.
validate(Settings, Mode) ->
    validate_settings(maps:to_list(Settings), Mode).

validate_settings([], _Mode) ->
    ok;
%% RFC 9113 §6.5.2: clients MUST reject enable_push != 0.
validate_settings([{enable_push, 0}|Rest], Mode) ->
    validate_settings(Rest, Mode);
validate_settings([{enable_push, 1}|_], client) ->
    {error, {enable_push, {forbidden_for_client, 1}}};
validate_settings([{enable_push, 1}|Rest], Mode) ->
    validate_settings(Rest, Mode);
validate_settings([{enable_push, V}|_], _Mode) ->
    {error, {enable_push, {invalid_value, V}}};
validate_settings([{enable_connect_protocol, V}|Rest], Mode) when V == 0; V == 1 ->
    validate_settings(Rest, Mode);
validate_settings([{enable_connect_protocol, V}|_], _Mode) ->
    {error, {enable_connect_protocol, {invalid_value, V}}};
validate_settings([{initial_window_size, V}|_], _Mode) when V > ?MAX_WINDOW_SIZE ->
    {error, {initial_window_size, {exceeds_max, V}}};
validate_settings([{initial_window_size, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{max_frame_size, V}|_], _Mode) when V < ?MIN_FRAME_SIZE ->
    {error, {max_frame_size, {below_min, V}}};
validate_settings([{max_frame_size, V}|_], _Mode) when V > ?MAX_FRAME_SIZE ->
    {error, {max_frame_size, {exceeds_max, V}}};
validate_settings([{max_frame_size, V}|Rest], Mode) when is_integer(V) ->
    validate_settings(Rest, Mode);
validate_settings([{header_table_size, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{max_concurrent_streams, unlimited}|Rest], Mode) ->
    validate_settings(Rest, Mode);
validate_settings([{max_concurrent_streams, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{max_header_list_size, unlimited}|Rest], Mode) ->
    validate_settings(Rest, Mode);
validate_settings([{max_header_list_size, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{wt_initial_max_data, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{wt_initial_max_data, V}|_], _Mode) ->
    {error, {wt_initial_max_data, {invalid_value, V}}};
validate_settings([{wt_initial_max_stream_data_uni, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{wt_initial_max_stream_data_uni, V}|_], _Mode) ->
    {error, {wt_initial_max_stream_data_uni, {invalid_value, V}}};
validate_settings([{wt_initial_max_stream_data_bidi_local, V}|Rest], Mode)
  when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{wt_initial_max_stream_data_bidi_local, V}|_], _Mode) ->
    {error, {wt_initial_max_stream_data_bidi_local, {invalid_value, V}}};
validate_settings([{wt_initial_max_stream_data_bidi_remote, V}|Rest], Mode)
  when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{wt_initial_max_stream_data_bidi_remote, V}|_], _Mode) ->
    {error, {wt_initial_max_stream_data_bidi_remote, {invalid_value, V}}};
validate_settings([{wt_initial_max_streams_uni, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{wt_initial_max_streams_uni, V}|_], _Mode) ->
    {error, {wt_initial_max_streams_uni, {invalid_value, V}}};
validate_settings([{wt_initial_max_streams_bidi, V}|Rest], Mode) when is_integer(V), V >= 0 ->
    validate_settings(Rest, Mode);
validate_settings([{wt_initial_max_streams_bidi, V}|_], _Mode) ->
    {error, {wt_initial_max_streams_bidi, {invalid_value, V}}};
validate_settings([{_, _}|Rest], Mode) ->
    %% Unknown settings (including raw integer IDs) are ignored
    validate_settings(Rest, Mode).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

default_test() ->
    D = default(),
    ?assertEqual(4096, maps:get(header_table_size, D)),
    ?assertEqual(0, maps:get(enable_push, D)),
    ?assertEqual(100, maps:get(max_concurrent_streams, D)),
    ?assertEqual(65535, maps:get(initial_window_size, D)),
    ?assertEqual(16384, maps:get(max_frame_size, D)),
    ?assertEqual(unlimited, maps:get(max_header_list_size, D)),
    ?assertEqual(0, maps:get(enable_connect_protocol, D)).

encode_decode_test() ->
    Settings = #{
        header_table_size => 8192,
        enable_push => 0,
        max_concurrent_streams => 100,
        initial_window_size => 32768,
        enable_connect_protocol => 1
    },
    Encoded = encode(Settings),
    {ok, Decoded} = decode(Encoded),
    ?assertEqual(8192, maps:get(header_table_size, Decoded)),
    ?assertEqual(0, maps:get(enable_push, Decoded)),
    ?assertEqual(100, maps:get(max_concurrent_streams, Decoded)),
    ?assertEqual(32768, maps:get(initial_window_size, Decoded)),
    ?assertEqual(1, maps:get(enable_connect_protocol, Decoded)).

decode_unknown_setting_test() ->
    %% RFC 7540 6.5.2: unknown IDs must not drive behavior, but we
    %% preserve them under the raw integer key so extensions can peek.
    Bin = <<16#7ff0:16, 12345:32, ?SETTINGS_ENABLE_PUSH:16, 0:32>>,
    {ok, Decoded} = decode(Bin),
    ?assertEqual(0, maps:get(enable_push, Decoded)),
    ?assertEqual(12345, maps:get(16#7ff0, Decoded)).

unknown_setting_roundtrip_test() ->
    %% Encoding a map with a raw integer key must emit the setting
    %% verbatim, and decoding must restore it.
    Encoded = encode(#{16#7ff0 => 12345}),
    ?assertEqual(<<16#7ff0:16, 12345:32>>, Encoded),
    {ok, Decoded} = decode(Encoded),
    ?assertEqual(12345, maps:get(16#7ff0, Decoded)).

wt_settings_roundtrip_test() ->
    Settings = #{
        wt_initial_max_data => 1048576,
        wt_initial_max_stream_data_uni => 65536,
        wt_initial_max_stream_data_bidi_local => 131072,
        wt_initial_max_stream_data_bidi_remote => 262144,
        wt_initial_max_streams_uni => 10,
        wt_initial_max_streams_bidi => 20
    },
    {ok, Decoded} = decode(encode(Settings)),
    ?assertEqual(1048576, maps:get(wt_initial_max_data, Decoded)),
    ?assertEqual(65536, maps:get(wt_initial_max_stream_data_uni, Decoded)),
    ?assertEqual(131072, maps:get(wt_initial_max_stream_data_bidi_local, Decoded)),
    ?assertEqual(262144, maps:get(wt_initial_max_stream_data_bidi_remote, Decoded)),
    ?assertEqual(10, maps:get(wt_initial_max_streams_uni, Decoded)),
    ?assertEqual(20, maps:get(wt_initial_max_streams_bidi, Decoded)).

wt_settings_wire_ids_test() ->
    Encoded = encode(#{wt_initial_max_data => 1}),
    ?assertEqual(<<16#2b61:16, 1:32>>, Encoded).

wt_settings_validate_test_() ->
    [
        ?_assertEqual(ok, validate(#{wt_initial_max_data => 0})),
        ?_assertEqual(ok, validate(#{wt_initial_max_streams_bidi => 1000})),
        ?_assertMatch({error, {wt_initial_max_data, _}},
                      validate(#{wt_initial_max_data => -1})),
        ?_assertMatch({error, {wt_initial_max_streams_uni, _}},
                      validate(#{wt_initial_max_streams_uni => not_an_int}))
    ].

validate_test_() ->
    [
        ?_assertEqual(ok, validate(default())),
        ?_assertEqual(ok, validate(#{enable_push => 0})),
        ?_assertEqual(ok, validate(#{enable_connect_protocol => 1})),
        ?_assertEqual(ok, validate(#{max_frame_size => 16384})),
        ?_assertEqual(ok, validate(#{max_frame_size => ?MAX_FRAME_SIZE})),
        ?_assertMatch({error, {enable_push, _}}, validate(#{enable_push => 2})),
        ?_assertMatch({error, {max_frame_size, _}}, validate(#{max_frame_size => 100})),
        ?_assertMatch({error, {max_frame_size, _}}, validate(#{max_frame_size => 17000000})),
        ?_assertMatch({error, {initial_window_size, _}}, validate(#{initial_window_size => 16#80000000}))
    ].

merge_test() ->
    Base = #{header_table_size => 4096, enable_push => 1},
    New = #{enable_push => 0, max_concurrent_streams => 50},
    Merged = merge(Base, New),
    ?assertEqual(4096, maps:get(header_table_size, Merged)),
    ?assertEqual(0, maps:get(enable_push, Merged)),
    ?assertEqual(50, maps:get(max_concurrent_streams, Merged)).

-endif.
