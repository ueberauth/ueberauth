%% @doc HTTP/2 Error Codes (RFC 7540 Section 7)
%%
%% Error codes are 32-bit integers used in RST_STREAM and GOAWAY frames.
%%
-module(h2_error).

-export([code/1, name/1, format/1]).

-include("h2.hrl").

%% Error code types
-type error_code() :: no_error | protocol_error | internal_error |
                      flow_control_error | settings_timeout | stream_closed |
                      frame_size_error | refused_stream | cancel |
                      compression_error | connect_error | enhance_your_calm |
                      inadequate_security | http_1_1_required |
                      {unknown, non_neg_integer()}.

-export_type([error_code/0]).

%% @doc Get the numeric code for an error name.
-spec code(error_code()) -> non_neg_integer().
code(no_error) -> ?NO_ERROR;
code(protocol_error) -> ?PROTOCOL_ERROR;
code(internal_error) -> ?INTERNAL_ERROR;
code(flow_control_error) -> ?FLOW_CONTROL_ERROR;
code(settings_timeout) -> ?SETTINGS_TIMEOUT;
code(stream_closed) -> ?STREAM_CLOSED;
code(frame_size_error) -> ?FRAME_SIZE_ERROR;
code(refused_stream) -> ?REFUSED_STREAM;
code(cancel) -> ?CANCEL;
code(compression_error) -> ?COMPRESSION_ERROR;
code(connect_error) -> ?CONNECT_ERROR;
code(enhance_your_calm) -> ?ENHANCE_YOUR_CALM;
code(inadequate_security) -> ?INADEQUATE_SECURITY;
code(http_1_1_required) -> ?HTTP_1_1_REQUIRED;
code({unknown, Code}) when is_integer(Code), Code >= 0 -> Code.

%% @doc Get the error name for a numeric code.
-spec name(non_neg_integer()) -> error_code().
name(?NO_ERROR) -> no_error;
name(?PROTOCOL_ERROR) -> protocol_error;
name(?INTERNAL_ERROR) -> internal_error;
name(?FLOW_CONTROL_ERROR) -> flow_control_error;
name(?SETTINGS_TIMEOUT) -> settings_timeout;
name(?STREAM_CLOSED) -> stream_closed;
name(?FRAME_SIZE_ERROR) -> frame_size_error;
name(?REFUSED_STREAM) -> refused_stream;
name(?CANCEL) -> cancel;
name(?COMPRESSION_ERROR) -> compression_error;
name(?CONNECT_ERROR) -> connect_error;
name(?ENHANCE_YOUR_CALM) -> enhance_your_calm;
name(?INADEQUATE_SECURITY) -> inadequate_security;
name(?HTTP_1_1_REQUIRED) -> http_1_1_required;
name(Code) when is_integer(Code), Code >= 0 -> {unknown, Code}.

%% @doc Format an error for display.
-spec format(error_code() | non_neg_integer()) -> string().
format(Code) when is_integer(Code) ->
    format(name(Code));
format(no_error) ->
    "NO_ERROR (0x0): Graceful shutdown";
format(protocol_error) ->
    "PROTOCOL_ERROR (0x1): Protocol error detected";
format(internal_error) ->
    "INTERNAL_ERROR (0x2): Implementation fault";
format(flow_control_error) ->
    "FLOW_CONTROL_ERROR (0x3): Flow-control limits exceeded";
format(settings_timeout) ->
    "SETTINGS_TIMEOUT (0x4): Settings not acknowledged";
format(stream_closed) ->
    "STREAM_CLOSED (0x5): Frame received for closed stream";
format(frame_size_error) ->
    "FRAME_SIZE_ERROR (0x6): Frame size incorrect";
format(refused_stream) ->
    "REFUSED_STREAM (0x7): Stream not processed";
format(cancel) ->
    "CANCEL (0x8): Stream cancelled";
format(compression_error) ->
    "COMPRESSION_ERROR (0x9): Compression state not updated";
format(connect_error) ->
    "CONNECT_ERROR (0xa): TCP connection error";
format(enhance_your_calm) ->
    "ENHANCE_YOUR_CALM (0xb): Processing capacity exceeded";
format(inadequate_security) ->
    "INADEQUATE_SECURITY (0xc): Negotiated TLS parameters not acceptable";
format(http_1_1_required) ->
    "HTTP_1_1_REQUIRED (0xd): Use HTTP/1.1 for the request";
format({unknown, Code}) ->
    io_lib:format("UNKNOWN (0x~.16b): Unknown error code", [Code]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

roundtrip_test_() ->
    Errors = [no_error, protocol_error, internal_error, flow_control_error,
              settings_timeout, stream_closed, frame_size_error, refused_stream,
              cancel, compression_error, connect_error, enhance_your_calm,
              inadequate_security, http_1_1_required],
    [?_assertEqual(E, name(code(E))) || E <- Errors].

known_codes_test_() ->
    [
        ?_assertEqual(0, code(no_error)),
        ?_assertEqual(1, code(protocol_error)),
        ?_assertEqual(13, code(http_1_1_required))
    ].

unknown_code_test_() ->
    [
        ?_assertEqual({unknown, 100}, name(100)),
        ?_assertEqual(100, code({unknown, 100}))
    ].

format_test_() ->
    [
        ?_assertMatch("NO_ERROR" ++ _, format(no_error)),
        ?_assertMatch("PROTOCOL_ERROR" ++ _, format(1)),
        ?_assertMatch("UNKNOWN" ++ _, format(999))
    ].

-endif.
