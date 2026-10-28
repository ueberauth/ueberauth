%%% -*- erlang -*-
%%%
%%% QUIC Interop Runner Server
%%% https://github.com/quic-interop/quic-interop-runner
%%%
%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Interop runner server for QUIC compliance testing.
%%%
%%% Environment variables:
%%%   TESTCASE - Test case name (handshake, transfer, retry, etc.)
%%%   SSLKEYLOGFILE - Optional file for TLS key logging
%%%
%%% The server serves files from /www directory and uses certificates
%%% from /certs directory (cert.pem, priv.key).

-module(quic_interop_server).

-export([main/1]).

%% Suppress dialyzer warnings for escript functions that call halt()
-dialyzer({nowarn_function, [main/1, run_server/4]}).
-dialyzer({nowarn_function, [run_h3_server/4, run_hq_server/5]}).

-define(EXIT_SUCCESS, 0).
-define(EXIT_FAILURE, 1).
-define(EXIT_UNSUPPORTED, 127).

%% Supported test cases
-define(SUPPORTED_TESTS, [
    "handshake",
    "transfer",
    "retry",
    "keyupdate",
    "chacha20",
    "multiconnect",
    "v2",
    "resumption",
    "zerortt",
    "connectionmigration",
    "http3",
    %% Passive robustness cases: the simulator induces the loss,
    %% corruption, latency or rebinding; the endpoint just transfers.
    "longrtt",
    "blackhole",
    "amplificationlimit",
    "handshakeloss",
    "transferloss",
    "handshakecorruption",
    "transfercorruption",
    "rebind-port",
    "rebind-addr"
]).

main(_Args) ->
    %% Start required applications. The quic app supervision matters:
    %% the resumption ticket table is owned by the server registry, and
    %% without it the table dies with the first connection that created
    %% it, so a client resuming after a pause never finds its ticket.
    application:ensure_all_started(crypto),
    application:ensure_all_started(ssl),
    application:ensure_all_started(quic),

    %% Get environment variables
    TestCase = os:getenv("TESTCASE", "handshake"),
    CertsDir = os:getenv("CERTS", "/certs"),
    WwwDir = os:getenv("WWW", "/www"),
    Port = list_to_integer(os:getenv("PORT", "443")),

    io:format("QUIC Interop Server~n"),
    io:format("  Test case: ~s~n", [TestCase]),
    io:format("  Port: ~p~n", [Port]),
    io:format("  Certs: ~s~n", [CertsDir]),
    io:format("  WWW: ~s~n", [WwwDir]),

    %% Check if test case is supported
    case lists:member(TestCase, ?SUPPORTED_TESTS) of
        false ->
            io:format("Test case ~s not supported~n", [TestCase]),
            halt(?EXIT_UNSUPPORTED);
        true ->
            run_server(TestCase, Port, CertsDir, WwwDir)
    end.

run_server(TestCase, Port, CertsDir, WwwDir) ->
    %% Load certificates
    CertFile = filename:join(CertsDir, "cert.pem"),
    KeyFile = filename:join(CertsDir, "priv.key"),

    case {file:read_file(CertFile), file:read_file(KeyFile)} of
        {{ok, CertPem}, {ok, KeyPem}} ->
            %% Decode PEM to DER. The amplificationlimit case hands the
            %% server a 9-deep chain in cert.pem; leaf first, then the
            %% intermediates in order.
            [CertDer | CertChain] = [
                D
             || {'Certificate', D, not_encrypted} <- public_key:pem_decode(CertPem)
            ],
            PrivateKey = decode_private_key(KeyPem),

            case TestCase of
                "http3" ->
                    run_h3_server(Port, {CertDer, CertChain}, PrivateKey, WwwDir);
                _ ->
                    run_hq_server(TestCase, Port, {CertDer, CertChain}, PrivateKey, WwwDir)
            end;
        _ ->
            io:format("Failed to read certificates~n"),
            halt(?EXIT_FAILURE)
    end.

%% The http3 case serves real HTTP/3 (RFC 9114) through quic_h3; every
%% other case speaks hq-interop over a bare listener.
run_h3_server(Port, {CertDer, CertChain}, PrivateKey, WwwDir) ->
    Handler = fun(Conn, StreamId, _Method, Path, _Headers) ->
        serve_h3_request(Conn, StreamId, Path, WwwDir)
    end,
    case
        quic_h3:start_server(interop_h3, Port, #{
            cert => CertDer,
            cert_chain => CertChain,
            key => PrivateKey,
            handler => Handler
        })
    of
        {ok, _} ->
            io:format("H3 server listening on port ~p~n", [Port]),
            receive
                stop -> halt(?EXIT_SUCCESS)
            end;
        {error, Reason} ->
            io:format("Failed to start H3 server: ~p~n", [Reason]),
            halt(?EXIT_FAILURE)
    end.

serve_h3_request(Conn, StreamId, Path, WwwDir) ->
    CleanPath =
        case Path of
            <<"/", Rest/binary>> -> Rest;
            _ -> Path
        end,
    FilePath = filename:join(WwwDir, binary_to_list(CleanPath)),
    case file:read_file(FilePath) of
        {ok, Content} ->
            io:format("h3: 200 ~s (~p bytes)~n", [Path, byte_size(Content)]),
            quic_h3:respond(Conn, StreamId, 200, [], Content);
        {error, _} ->
            io:format("h3: 404 ~s~n", [Path]),
            quic_h3:respond(Conn, StreamId, 404, [], <<"not found">>)
    end.

run_hq_server(TestCase, Port, CertDer, PrivateKey, WwwDir) ->
    %% Build server options
    Opts = build_server_opts(TestCase, CertDer, PrivateKey, WwwDir),

    %% Start listener
    case quic_listener:start_link(Port, Opts) of
        {ok, Listener} ->
            io:format("Server listening on port ~p~n", [Port]),

            %% Wait forever (or until killed)
            receive
                stop ->
                    quic_listener:stop(Listener),
                    halt(?EXIT_SUCCESS)
            end;
        {error, Reason} ->
            io:format("Failed to start listener: ~p~n", [Reason]),
            halt(?EXIT_FAILURE)
    end.

build_server_opts(TestCase, {Cert, CertChain}, Key, WwwDir) ->
    BaseOpts = #{
        cert => Cert,
        cert_chain => CertChain,
        key => Key,
        alpn => [<<"hq-interop">>, <<"h3">>],
        %% The blackhole case blacks the network out on purpose and
        %% expects the connection to outlast it.
        disconnect_timeout => infinity,
        connection_handler => fun(ConnPid, Conn) ->
            spawn_handler(ConnPid, Conn, WwwDir, TestCase)
        end
    },

    %% Test case specific options
    case TestCase of
        "retry" ->
            %% The listener reads address_validation; `retry' was set here
            %% but nothing ever looked at it, so no Retry was sent.
            BaseOpts#{address_validation => always};
        "chacha20" ->
            BaseOpts#{ciphers => [chacha20_poly1305]};
        "v2" ->
            BaseOpts#{versions => [16#6b3343cf, 16#00000001]};
        _ ->
            BaseOpts
    end.

%% Decode PEM-encoded private key to internal format
decode_private_key(PemData) ->
    %% A key file may carry more than the key: `openssl ecparam -genkey',
    %% which is how the interop runner generates its certificates, emits
    %% EC PARAMETERS ahead of EC PRIVATE KEY. Pick the key entry out of
    %% the list rather than insisting the file holds exactly one.
    case [E || {Type, _, _} = E <- public_key:pem_decode(PemData), is_key_entry(Type)] of
        [{Type, Der, _} | _] ->
            decode_key_entry(Type, Der);
        [] ->
            error(invalid_private_key)
    end.

is_key_entry('RSAPrivateKey') -> true;
is_key_entry('DSAPrivateKey') -> true;
is_key_entry('ECPrivateKey') -> true;
is_key_entry('PrivateKeyInfo') -> true;
is_key_entry(_) -> false.

decode_key_entry('RSAPrivateKey', Der) ->
    public_key:der_decode('RSAPrivateKey', Der);
decode_key_entry('ECPrivateKey', Der) ->
    public_key:der_decode('ECPrivateKey', Der);
decode_key_entry('PrivateKeyInfo', Der) ->
    %% PKCS#8 format - public_key:der_decode handles extraction automatically
    public_key:der_decode('PrivateKeyInfo', Der);
decode_key_entry(Type, _Der) ->
    error({unsupported_key_type, Type}).

spawn_handler(ConnPid, _DCID, WwwDir, TestCase) ->
    %% The arity-2 connection_handler is called as Fun(ConnPid, DCID); the
    %% connection handle in every quic message and API call is the pid.
    HandlerPid = spawn(fun() ->
        connection_handler(ConnPid, WwwDir, TestCase)
    end),
    {ok, HandlerPid}.

connection_handler(Conn, WwwDir, TestCase) ->
    io:format("Handler started, waiting for messages...~n"),
    connection_handler(Conn, WwwDir, TestCase, #{}).

%% A request may arrive split across several STREAM frames, so buffer per
%% stream until FIN before parsing. Serving each fragment as if it were a
%% whole request answered twice on one stream: two responses, two FINs at
%% different offsets, and a correct peer kills the connection with
%% FINAL_SIZE_ERROR.
connection_handler(Conn, WwwDir, TestCase, Bufs) ->
    receive
        {quic, Conn, {connected, Info}} ->
            io:format("Handler got connected: ~p~n", [Info]),
            connection_handler(Conn, WwwDir, TestCase, Bufs);
        {quic, Conn, {stream_opened, StreamId}} ->
            io:format("Handler got stream_opened: ~p~n", [StreamId]),
            connection_handler(Conn, WwwDir, TestCase, Bufs);
        {quic, Conn, {stream_data, StreamId, Data, Fin}} ->
            Bufs1 = buffer_stream_data(Conn, WwwDir, TestCase, Bufs, StreamId, Data, Fin),
            connection_handler(Conn, WwwDir, TestCase, Bufs1);
        {quic, Conn, {closed, Reason}} ->
            io:format("Handler got closed: ~p~n", [Reason]),
            ok;
        Other ->
            io:format("Handler got unexpected: ~p~n", [Other]),
            connection_handler(Conn, WwwDir, TestCase, Bufs)
    after 60000 ->
        io:format("Handler timeout~n"),
        ok
    end.

buffer_stream_data(Conn, WwwDir, TestCase, Bufs, StreamId, Data, Fin) ->
    Acc = [maps:get(StreamId, Bufs, []) | Data],
    case Fin of
        true ->
            Request = iolist_to_binary(Acc),
            _ = serve_request(Conn, StreamId, Request, WwwDir, TestCase),
            maps:remove(StreamId, Bufs);
        false ->
            Bufs#{StreamId => Acc}
    end.

serve_request(Conn, StreamId, Data, WwwDir, TestCase) ->
    io:format("handle_request: stream=~p data=~p~n", [StreamId, Data]),
    %% Parse simple HTTP/0.9 request: "GET /path\r\n"
    case parse_request(Data) of
        {ok, Path} ->
            io:format("Parsed request path: ~p~n", [Path]),
            %% Handle key update test
            case TestCase of
                "keyupdate" ->
                    quic_connection:key_update(Conn);
                _ ->
                    ok
            end,

            %% Serve file
            FilePath = filename:join(WwwDir, Path),
            io:format("Reading file: ~p~n", [FilePath]),
            case file:read_file(FilePath) of
                {ok, Content} ->
                    io:format("Sending ~p bytes on stream ~p~n", [byte_size(Content), StreamId]),
                    Result = quic:send_data(Conn, StreamId, Content, true),
                    io:format("send_data result: ~p~n", [Result]),
                    Result;
                {error, ReadErr} ->
                    io:format("File read error: ~p, sending 404~n", [ReadErr]),
                    quic:send_data(Conn, StreamId, <<"404 Not Found">>, true)
            end;
        error ->
            io:format("Parse error, sending 400~n"),
            quic:send_data(Conn, StreamId, <<"400 Bad Request">>, true)
    end.

parse_request(Data) ->
    case binary:split(Data, <<"\r\n">>) of
        [RequestLine | _] ->
            case binary:split(RequestLine, <<" ">>, [global]) of
                [<<"GET">>, Path | _] ->
                    %% Remove leading slash for file path
                    CleanPath =
                        case Path of
                            <<"/">> -> <<"index.html">>;
                            <<"/", Rest/binary>> -> Rest;
                            _ -> Path
                        end,
                    {ok, binary_to_list(CleanPath)};
                _ ->
                    error
            end;
        _ ->
            error
    end.
