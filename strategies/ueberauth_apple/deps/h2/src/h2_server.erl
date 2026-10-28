%% @doc HTTP/2 Standalone Server Escript
%%
%% A standalone HTTP/2 server that can be run from the command line.
%%
%% Usage:
%% ```
%% h2_server --cert cert.pem --key key.pem [options]
%%
%% Options:
%%   -p, --port PORT       Listen port (default: 8443)
%%   --cert FILE           Server certificate (PEM) - required
%%   --key FILE            Server private key (PEM) - required
%%   --docroot DIR         Document root (default: .)
%%   --echo                Echo mode (return request info)
%%   -v, --verbose         Show detailed output
%%   -h, --help            Show this help
%% '''
%%
-module(h2_server).

-include_lib("kernel/include/file.hrl").

-export([main/1]).

-define(DEFAULT_PORT, 8443).
-define(DEFAULT_DOCROOT, ".").

%% ============================================================================
%% Escript Entry Point
%% ============================================================================

-spec main([string()]) -> no_return().
main(Args) ->
    case parse_args(Args) of
        {ok, Opts} ->
            run_server(Opts);
        {error, Reason} ->
            io:format(standard_error, "Error: ~s~n~n", [Reason]),
            usage(),
            halt(1);
        help ->
            usage(),
            halt(0)
    end.

%% ============================================================================
%% Argument Parsing
%% ============================================================================

parse_args(Args) ->
    parse_args(Args, #{
        port => ?DEFAULT_PORT,
        docroot => ?DEFAULT_DOCROOT,
        echo => false,
        verbose => false
    }).

parse_args([], Opts) ->
    %% Validate required options
    case {maps:find(cert, Opts), maps:find(key, Opts)} of
        {{ok, _}, {ok, _}} ->
            {ok, Opts};
        _ ->
            {error, "Missing required options: --cert and --key"}
    end;

parse_args(["-h"|_], _Opts) -> help;
parse_args(["--help"|_], _Opts) -> help;

parse_args(["-p", Port|Rest], Opts) ->
    parse_args(["--port", Port|Rest], Opts);
parse_args(["--port", Port|Rest], Opts) ->
    try list_to_integer(Port) of
        N when is_integer(N), N > 0, N < 65536 ->
            parse_args(Rest, Opts#{port => N});
        _ ->
            {error, io_lib:format("Invalid port: ~s", [Port])}
    catch _:_ ->
        {error, io_lib:format("Invalid port: ~s", [Port])}
    end;

parse_args(["--cert", File|Rest], Opts) ->
    case filelib:is_regular(File) of
        true -> parse_args(Rest, Opts#{cert => File});
        false -> {error, io_lib:format("Certificate file not found: ~s", [File])}
    end;

parse_args(["--key", File|Rest], Opts) ->
    case filelib:is_regular(File) of
        true -> parse_args(Rest, Opts#{key => File});
        false -> {error, io_lib:format("Key file not found: ~s", [File])}
    end;

parse_args(["--docroot", Dir|Rest], Opts) ->
    case filelib:is_dir(Dir) of
        true -> parse_args(Rest, Opts#{docroot => Dir});
        false -> {error, io_lib:format("Document root not found: ~s", [Dir])}
    end;

parse_args(["--echo"|Rest], Opts) ->
    parse_args(Rest, Opts#{echo => true});

parse_args(["-v"|Rest], Opts) ->
    parse_args(Rest, Opts#{verbose => true});
parse_args(["--verbose"|Rest], Opts) ->
    parse_args(Rest, Opts#{verbose => true});

parse_args([Unknown|_], _Opts) ->
    {error, io_lib:format("Unknown option: ~s", [Unknown])}.

usage() ->
    io:format(
        "Usage: h2_server --cert FILE --key FILE [OPTIONS]~n"
        "~n"
        "HTTP/2 reference server~n"
        "~n"
        "Required:~n"
        "  --cert FILE           Server certificate (PEM)~n"
        "  --key FILE            Server private key (PEM)~n"
        "~n"
        "Options:~n"
        "  -p, --port PORT       Listen port (default: ~p)~n"
        "  --docroot DIR         Document root (default: .)~n"
        "  --echo                Echo mode - return request info as response~n"
        "  -v, --verbose         Show detailed output~n"
        "  -h, --help            Show this help~n"
        "~n"
        "Examples:~n"
        "  h2_server --cert server.pem --key server-key.pem~n"
        "  h2_server --cert server.pem --key server-key.pem --port 443 --echo~n"
        "~n",
        [?DEFAULT_PORT]).

%% ============================================================================
%% Server Implementation
%% ============================================================================

run_server(Opts) ->
    %% Start required applications
    ok = application:ensure_started(crypto),
    ok = application:ensure_started(asn1),
    ok = application:ensure_started(public_key),
    ok = application:ensure_started(ssl),

    Port = maps:get(port, Opts),
    Cert = maps:get(cert, Opts),
    Key = maps:get(key, Opts),
    Verbose = maps:get(verbose, Opts),

    %% Create handler
    Handler = create_handler(Opts),

    %% Log startup
    log(Verbose, "Starting HTTP/2 server on port ~p~n", [Port]),
    log(Verbose, "Certificate: ~s~n", [Cert]),
    log(Verbose, "Key: ~s~n", [Key]),
    log(Verbose, "Mode: ~s~n", [handler_mode(Opts)]),

    %% Start server
    ServerOpts = #{
        cert => Cert,
        key => Key,
        handler => Handler,
        settings => #{}
    },

    case h2:start_server(Port, ServerOpts) of
        {ok, ServerRef} ->
            io:format("HTTP/2 server listening on https://localhost:~p/~n", [Port]),
            io:format("Press Ctrl+C to stop~n"),
            wait_forever(ServerRef, Verbose);
        {error, Reason} ->
            io:format(standard_error, "Failed to start server: ~p~n", [Reason]),
            halt(1)
    end.

handler_mode(#{echo := true}) -> "echo";
handler_mode(_) -> "file server".

create_handler(#{echo := true, verbose := Verbose}) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        echo_handler(Conn, StreamId, Method, Path, Headers, Verbose)
    end;
create_handler(#{docroot := Docroot, verbose := Verbose}) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        file_handler(Conn, StreamId, Method, Path, Headers, Docroot, Verbose)
    end.

%% Echo handler - returns request information
echo_handler(Conn, StreamId, Method, Path, Headers, Verbose) ->
    log(Verbose, "[~p] ~s ~s~n", [StreamId, Method, Path]),

    %% Build response body
    Body = io_lib:format(
        "Method: ~s~n"
        "Path: ~s~n"
        "Headers:~n~s",
        [Method, Path, format_headers(Headers)]),
    BodyBin = iolist_to_binary(Body),

    %% Send response
    ResponseHeaders = [
        {<<"content-type">>, <<"text/plain; charset=utf-8">>},
        {<<"content-length">>, integer_to_binary(byte_size(BodyBin))}
    ],

    ok = h2:send_response(Conn, StreamId, 200, ResponseHeaders),
    ok = h2:send_data(Conn, StreamId, BodyBin, true),

    log(Verbose, "[~p] 200 ~p bytes~n", [StreamId, byte_size(BodyBin)]).

%% File handler - serves files from document root
file_handler(Conn, StreamId, Method, Path, _Headers, Docroot, Verbose) ->
    log(Verbose, "[~p] ~s ~s~n", [StreamId, Method, Path]),

    case Method of
        <<"GET">> ->
            serve_file(Conn, StreamId, Path, Docroot, Verbose);
        <<"HEAD">> ->
            serve_file_head(Conn, StreamId, Path, Docroot, Verbose);
        _ ->
            send_error(Conn, StreamId, 405, <<"Method Not Allowed">>, Verbose)
    end.

serve_file(Conn, StreamId, Path, Docroot, Verbose) ->
    FilePath = safe_path(Path, Docroot),
    case FilePath of
        {error, unsafe} ->
            send_error(Conn, StreamId, 400, <<"Bad Request">>, Verbose);
        SafePath ->
            case file:read_file(SafePath) of
                {ok, Content} ->
                    ContentType = guess_content_type(SafePath),
                    ResponseHeaders = [
                        {<<"content-type">>, ContentType},
                        {<<"content-length">>, integer_to_binary(byte_size(Content))}
                    ],
                    ok = h2:send_response(Conn, StreamId, 200, ResponseHeaders),
                    ok = h2:send_data(Conn, StreamId, Content, true),
                    log(Verbose, "[~p] 200 ~p bytes~n", [StreamId, byte_size(Content)]);
                {error, enoent} ->
                    send_error(Conn, StreamId, 404, <<"Not Found">>, Verbose);
                {error, eisdir} ->
                    %% Try index.html
                    IndexPath = filename:join(SafePath, "index.html"),
                    case file:read_file(IndexPath) of
                        {ok, Content} ->
                            ResponseHeaders = [
                                {<<"content-type">>, <<"text/html; charset=utf-8">>},
                                {<<"content-length">>, integer_to_binary(byte_size(Content))}
                            ],
                            ok = h2:send_response(Conn, StreamId, 200, ResponseHeaders),
                            ok = h2:send_data(Conn, StreamId, Content, true),
                            log(Verbose, "[~p] 200 ~p bytes~n", [StreamId, byte_size(Content)]);
                        {error, _} ->
                            send_error(Conn, StreamId, 403, <<"Forbidden">>, Verbose)
                    end;
                {error, _Reason} ->
                    send_error(Conn, StreamId, 500, <<"Internal Server Error">>, Verbose)
            end
    end.

serve_file_head(Conn, StreamId, Path, Docroot, Verbose) ->
    FilePath = safe_path(Path, Docroot),
    case FilePath of
        {error, unsafe} ->
            send_error(Conn, StreamId, 400, <<"Bad Request">>, Verbose);
        SafePath ->
            case file:read_file_info(SafePath) of
                {ok, #file_info{size = Size}} ->
                    ContentType = guess_content_type(SafePath),
                    ResponseHeaders = [
                        {<<"content-type">>, ContentType},
                        {<<"content-length">>, integer_to_binary(Size)}
                    ],
                    ok = h2:send_response(Conn, StreamId, 200, ResponseHeaders),
                    ok = h2:send_data(Conn, StreamId, <<>>, true),
                    log(Verbose, "[~p] 200 (HEAD)~n", [StreamId]);
                {error, enoent} ->
                    send_error(Conn, StreamId, 404, <<"Not Found">>, Verbose);
                {error, _} ->
                    send_error(Conn, StreamId, 500, <<"Internal Server Error">>, Verbose)
            end
    end.

send_error(Conn, StreamId, Status, Message, Verbose) ->
    Body = io_lib:format("~p ~s~n", [Status, Message]),
    BodyBin = iolist_to_binary(Body),
    ResponseHeaders = [
        {<<"content-type">>, <<"text/plain; charset=utf-8">>},
        {<<"content-length">>, integer_to_binary(byte_size(BodyBin))}
    ],
    ok = h2:send_response(Conn, StreamId, Status, ResponseHeaders),
    ok = h2:send_data(Conn, StreamId, BodyBin, true),
    log(Verbose, "[~p] ~p~n", [StreamId, Status]).

%% ============================================================================
%% Utilities
%% ============================================================================

safe_path(Path, Docroot) ->
    PathStr = case Path of
        <<"/">> -> "index.html";
        <<"/", Rest/binary>> -> binary_to_list(Rest);
        _ -> binary_to_list(Path)
    end,
    DecodedPath = uri_string:unquote(PathStr),
    %% filelib:safe_relative_path/2 normalizes the path (resolving `.' and
    %% `..' components) and refuses anything that escapes Docroot. Beats
    %% the previous string-based `..' check, which missed URL-encoded
    %% (`%2e%2e') and overlong (`./foo/../../etc') variants.
    case filelib:safe_relative_path(DecodedPath, Docroot) of
        unsafe -> {error, unsafe};
        SafeRel -> filename:join(Docroot, SafeRel)
    end.

guess_content_type(Path) ->
    case filename:extension(Path) of
        ".html" -> <<"text/html; charset=utf-8">>;
        ".htm" -> <<"text/html; charset=utf-8">>;
        ".css" -> <<"text/css; charset=utf-8">>;
        ".js" -> <<"application/javascript; charset=utf-8">>;
        ".json" -> <<"application/json; charset=utf-8">>;
        ".xml" -> <<"application/xml; charset=utf-8">>;
        ".txt" -> <<"text/plain; charset=utf-8">>;
        ".png" -> <<"image/png">>;
        ".jpg" -> <<"image/jpeg">>;
        ".jpeg" -> <<"image/jpeg">>;
        ".gif" -> <<"image/gif">>;
        ".svg" -> <<"image/svg+xml">>;
        ".ico" -> <<"image/x-icon">>;
        ".pdf" -> <<"application/pdf">>;
        ".woff" -> <<"font/woff">>;
        ".woff2" -> <<"font/woff2">>;
        ".ttf" -> <<"font/ttf">>;
        ".eot" -> <<"application/vnd.ms-fontobject">>;
        _ -> <<"application/octet-stream">>
    end.

format_headers(Headers) ->
    lists:map(fun({Name, Value}) ->
        io_lib:format("  ~s: ~s~n", [Name, Value])
    end, Headers).

log(true, Format, Args) ->
    Timestamp = format_timestamp(),
    io:format("[~s] " ++ Format, [Timestamp | Args]);
log(false, _Format, _Args) ->
    ok.

format_timestamp() ->
    {{Y, M, D}, {H, Mi, S}} = calendar:local_time(),
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
                  [Y, M, D, H, Mi, S]).

wait_forever(ServerRef, Verbose) ->
    receive
        {'EXIT', _, Reason} ->
            log(Verbose, "Server stopped: ~p~n", [Reason]),
            h2:stop_server(ServerRef),
            halt(0);
        _ ->
            wait_forever(ServerRef, Verbose)
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

safe_path_test_() ->
    [
        ?_assertEqual("./index.html", safe_path(<<"/">>, ".")),
        ?_assertEqual("./test.html", safe_path(<<"/test.html">>, ".")),
        ?_assertEqual({error, unsafe}, safe_path(<<"/../etc/passwd">>, ".")),
        %% URL-encoded `..' — previously slipped past the component check.
        ?_assertEqual({error, unsafe}, safe_path(<<"/%2e%2e/etc/passwd">>, ".")),
        %% Normalized escape through a fake subdir.
        ?_assertEqual({error, unsafe}, safe_path(<<"/a/../../etc/passwd">>, "."))
    ].

content_type_test_() ->
    [
        ?_assertEqual(<<"text/html; charset=utf-8">>, guess_content_type("index.html")),
        ?_assertEqual(<<"image/png">>, guess_content_type("image.png")),
        ?_assertEqual(<<"application/octet-stream">>, guess_content_type("file.xyz"))
    ].

-endif.
