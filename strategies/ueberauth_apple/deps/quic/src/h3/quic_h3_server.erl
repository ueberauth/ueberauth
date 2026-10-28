%%% -*- erlang -*-
%%%
%%% HTTP/3 Test Server
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc HTTP/3 test server escript.
%%%
%%% Usage:
%%%   quic_h3_server --cert cert.pem --key key.pem [options]
%%%
%%% Options:
%%%   -p, --port PORT    Listen port (default: 4433)
%%%   --cert FILE        Server certificate (PEM) - required
%%%   --key FILE         Server private key (PEM) - required
%%%   --docroot DIR      Document root for static files (default: .)
%%%   --echo             Echo mode: return request info as response
%%%   -v, --verbose      Show detailed output

-module(quic_h3_server).

-export([main/1]).

%% Suppress dialyzer warnings for escript functions that call halt()
-dialyzer({no_return, [main/1, run_server/1, usage/0]}).
-dialyzer(
    {nowarn_function, [
        usage/0,
        parse_args/2,
        run_server/1,
        decode_private_key/1,
        decode_key_entry/2,
        make_handler/1,
        echo_handler/6,
        format_echo_response/3,
        file_handler/7,
        serve_file/4,
        serve_file_head/4,
        resolve_path/2,
        guess_content_type/1,
        verbose/3
    ]}
).

-define(EXIT_SUCCESS, 0).
-define(EXIT_FAILURE, 1).

-record(opts, {
    port = 4433 :: pos_integer(),
    cert :: string() | undefined,
    key :: string() | undefined,
    docroot = "." :: string(),
    echo = false :: boolean(),
    verbose = false :: boolean()
}).

main([]) ->
    usage();
main(Args) ->
    application:ensure_all_started(crypto),
    application:ensure_all_started(ssl),

    case parse_args(Args, #opts{}) of
        {ok, Opts} ->
            run_server(Opts);
        {error, Msg} ->
            io:format(standard_error, "Error: ~s~n", [Msg]),
            halt(?EXIT_FAILURE)
    end.

usage() ->
    io:format("Usage: quic_h3_server --cert FILE --key FILE [options]~n~n"),
    io:format("Options:~n"),
    io:format("  -p, --port PORT    Listen port (default: 4433)~n"),
    io:format("  --cert FILE        Server certificate (PEM) - required~n"),
    io:format("  --key FILE         Server private key (PEM) - required~n"),
    io:format("  --docroot DIR      Document root (default: .)~n"),
    io:format("  --echo             Echo mode~n"),
    io:format("  -v, --verbose      Show detailed output~n"),
    halt(?EXIT_FAILURE).

parse_args([], #opts{cert = undefined}) ->
    {error, "--cert is required"};
parse_args([], #opts{key = undefined}) ->
    {error, "--key is required"};
parse_args([], Opts) ->
    {ok, Opts};
parse_args(["-p", Port | Rest], Opts) ->
    parse_args(Rest, Opts#opts{port = list_to_integer(Port)});
parse_args(["--port", Port | Rest], Opts) ->
    parse_args(Rest, Opts#opts{port = list_to_integer(Port)});
parse_args(["--cert", File | Rest], Opts) ->
    parse_args(Rest, Opts#opts{cert = File});
parse_args(["--key", File | Rest], Opts) ->
    parse_args(Rest, Opts#opts{key = File});
parse_args(["--docroot", Dir | Rest], Opts) ->
    parse_args(Rest, Opts#opts{docroot = Dir});
parse_args(["--echo" | Rest], Opts) ->
    parse_args(Rest, Opts#opts{echo = true});
parse_args(["-v" | Rest], Opts) ->
    parse_args(Rest, Opts#opts{verbose = true});
parse_args(["--verbose" | Rest], Opts) ->
    parse_args(Rest, Opts#opts{verbose = true});
parse_args(["-h" | _], _Opts) ->
    usage();
parse_args(["--help" | _], _Opts) ->
    usage();
parse_args([[$- | _] = Opt | _], _Opts) ->
    {error, io_lib:format("Unknown option: ~s", [Opt])};
parse_args([Arg | _], _Opts) ->
    {error, io_lib:format("Unexpected argument: ~s", [Arg])}.

run_server(#opts{port = Port, cert = CertFile, key = KeyFile} = Opts) ->
    %% Read certificates
    case {file:read_file(CertFile), file:read_file(KeyFile)} of
        {{ok, CertPem}, {ok, KeyPem}} ->
            [{_, CertDer, _}] = public_key:pem_decode(CertPem),
            PrivateKey = decode_private_key(KeyPem),

            %% Build handler
            Handler = make_handler(Opts),

            %% Start server
            ServerOpts = #{
                cert => CertDer,
                key => PrivateKey,
                handler => Handler
            },

            case quic_h3:start_server(quic_h3_test_server, Port, ServerOpts) of
                {ok, _Pid} ->
                    verbose(Opts, "HTTP/3 server listening on port ~p~n", [Port]),
                    verbose(Opts, "Document root: ~s~n", [Opts#opts.docroot]),
                    verbose(Opts, "Press Ctrl+C to stop~n", []),
                    %% Wait forever
                    receive
                        stop ->
                            quic_h3:stop_server(quic_h3_test_server),
                            halt(?EXIT_SUCCESS)
                    end;
                {error, Reason} ->
                    io:format(standard_error, "Failed to start server: ~p~n", [Reason]),
                    halt(?EXIT_FAILURE)
            end;
        {{error, CertErr}, _} ->
            io:format(standard_error, "Failed to read cert: ~p~n", [CertErr]),
            halt(?EXIT_FAILURE);
        {_, {error, KeyErr}} ->
            io:format(standard_error, "Failed to read key: ~p~n", [KeyErr]),
            halt(?EXIT_FAILURE)
    end.

decode_private_key(PemData) ->
    case public_key:pem_decode(PemData) of
        [{Type, Der, not_encrypted}] ->
            decode_key_entry(Type, Der);
        [{Type, Der, _Cipher}] ->
            decode_key_entry(Type, Der);
        _ ->
            error(invalid_private_key)
    end.

decode_key_entry('RSAPrivateKey', Der) ->
    public_key:der_decode('RSAPrivateKey', Der);
decode_key_entry('ECPrivateKey', Der) ->
    public_key:der_decode('ECPrivateKey', Der);
decode_key_entry('PrivateKeyInfo', Der) ->
    public_key:der_decode('PrivateKeyInfo', Der);
decode_key_entry(Type, _Der) ->
    error({unsupported_key_type, Type}).

make_handler(#opts{echo = true} = Opts) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        echo_handler(Conn, StreamId, Method, Path, Headers, Opts)
    end;
make_handler(Opts) ->
    Docroot = Opts#opts.docroot,
    fun(Conn, StreamId, Method, Path, Headers) ->
        file_handler(Conn, StreamId, Method, Path, Headers, Docroot, Opts)
    end.

echo_handler(Conn, StreamId, Method, Path, Headers, Opts) ->
    verbose(Opts, "~s ~s~n", [Method, Path]),
    Body = format_echo_response(Method, Path, Headers),
    quic_h3:send_response(Conn, StreamId, 200, [
        {<<"content-type">>, <<"text/plain">>}
    ]),
    quic_h3:send_data(Conn, StreamId, Body, true).

format_echo_response(Method, Path, Headers) ->
    HeaderLines = [
        io_lib:format("~s: ~s~n", [K, V])
     || {K, V} <- Headers
    ],
    iolist_to_binary([
        io_lib:format("Method: ~s~n", [Method]),
        io_lib:format("Path: ~s~n", [Path]),
        "Headers:\n",
        HeaderLines
    ]).

file_handler(Conn, StreamId, Method, Path, _Headers, Docroot, Opts) ->
    verbose(Opts, "~s ~s~n", [Method, Path]),
    case Method of
        <<"GET">> ->
            serve_file(Conn, StreamId, Path, Docroot);
        <<"HEAD">> ->
            serve_file_head(Conn, StreamId, Path, Docroot);
        _ ->
            quic_h3:send_response(Conn, StreamId, 405, [
                {<<"content-type">>, <<"text/plain">>}
            ]),
            quic_h3:send_data(Conn, StreamId, <<"Method Not Allowed">>, true)
    end.

serve_file(Conn, StreamId, Path, Docroot) ->
    FilePath = resolve_path(Path, Docroot),
    case file:read_file(FilePath) of
        {ok, Content} ->
            ContentType = guess_content_type(FilePath),
            quic_h3:send_response(Conn, StreamId, 200, [
                {<<"content-type">>, ContentType},
                {<<"content-length">>, integer_to_binary(byte_size(Content))}
            ]),
            quic_h3:send_data(Conn, StreamId, Content, true);
        {error, enoent} ->
            quic_h3:send_response(Conn, StreamId, 404, [
                {<<"content-type">>, <<"text/plain">>}
            ]),
            quic_h3:send_data(Conn, StreamId, <<"Not Found">>, true);
        {error, _Reason} ->
            quic_h3:send_response(Conn, StreamId, 500, [
                {<<"content-type">>, <<"text/plain">>}
            ]),
            quic_h3:send_data(Conn, StreamId, <<"Internal Server Error">>, true)
    end.

serve_file_head(Conn, StreamId, Path, Docroot) ->
    FilePath = resolve_path(Path, Docroot),
    case file:read_file_info(FilePath) of
        {ok, FileInfo} ->
            Size = element(2, FileInfo),
            ContentType = guess_content_type(FilePath),
            quic_h3:send_response(Conn, StreamId, 200, [
                {<<"content-type">>, ContentType},
                {<<"content-length">>, integer_to_binary(Size)}
            ]),
            quic_h3:send_data(Conn, StreamId, <<>>, true);
        {error, enoent} ->
            quic_h3:send_response(Conn, StreamId, 404, []),
            quic_h3:send_data(Conn, StreamId, <<>>, true);
        {error, _} ->
            quic_h3:send_response(Conn, StreamId, 500, []),
            quic_h3:send_data(Conn, StreamId, <<>>, true)
    end.

resolve_path(Path, Docroot) ->
    %% Remove leading slash and normalize
    CleanPath =
        case Path of
            <<"/">> -> "index.html";
            <<"/", Rest/binary>> -> binary_to_list(Rest);
            _ -> binary_to_list(Path)
        end,
    %% Security: prevent directory traversal
    SafePath = filename:join([Docroot | string:split(CleanPath, "/", all)]),
    %% Verify path is under docroot
    AbsDocroot = filename:absname(Docroot),
    AbsPath = filename:absname(SafePath),
    case string:prefix(AbsPath, AbsDocroot) of
        nomatch -> filename:join(Docroot, "index.html");
        _ -> SafePath
    end.

guess_content_type(Path) ->
    case filename:extension(Path) of
        ".html" -> <<"text/html">>;
        ".htm" -> <<"text/html">>;
        ".css" -> <<"text/css">>;
        ".js" -> <<"application/javascript">>;
        ".json" -> <<"application/json">>;
        ".txt" -> <<"text/plain">>;
        ".xml" -> <<"application/xml">>;
        ".png" -> <<"image/png">>;
        ".jpg" -> <<"image/jpeg">>;
        ".jpeg" -> <<"image/jpeg">>;
        ".gif" -> <<"image/gif">>;
        ".svg" -> <<"image/svg+xml">>;
        ".ico" -> <<"image/x-icon">>;
        ".pdf" -> <<"application/pdf">>;
        ".woff" -> <<"font/woff">>;
        ".woff2" -> <<"font/woff2">>;
        _ -> <<"application/octet-stream">>
    end.

verbose(#opts{verbose = true}, Fmt, Args) ->
    io:format(Fmt, Args);
verbose(_, _, _) ->
    ok.
