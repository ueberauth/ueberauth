%% @doc HTTP/2 Standalone Client Escript
%%
%% A standalone HTTP/2 client that can be run from the command line.
%%
%% Usage:
%% ```
%% h2_client URL [options]
%%
%% Options:
%%   -X, --method METHOD   HTTP method (default: GET)
%%   -H, --header K:V      Add request header (repeatable)
%%   -d, --data DATA       Request body
%%   --cert FILE           Client certificate (PEM)
%%   --key FILE            Client private key (PEM)
%%   --cacerts FILE        CA certificates (PEM)
%%   --insecure            Skip certificate verification
%%   -o, --output FILE     Write response to file
%%   --timeout SEC         Connection timeout (default: 30)
%%   -v, --verbose         Show detailed output
%%   -h, --help            Show this help
%% '''
%%
-module(h2_client).

-export([main/1]).

-define(DEFAULT_TIMEOUT, 30).

%% ============================================================================
%% Escript Entry Point
%% ============================================================================

-spec main([string()]) -> no_return().
main(Args) ->
    case parse_args(Args) of
        {ok, Opts} ->
            run_client(Opts);
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
        method => <<"GET">>,
        headers => [],
        timeout => ?DEFAULT_TIMEOUT,
        verbose => false,
        insecure => false
    }).

parse_args([], #{url := _} = Opts) ->
    %% Reverse headers to maintain order
    {ok, Opts#{headers => lists:reverse(maps:get(headers, Opts))}};
parse_args([], _Opts) ->
    {error, "Missing URL argument"};

parse_args(["-h"|_], _Opts) -> help;
parse_args(["--help"|_], _Opts) -> help;

parse_args(["-X", Method|Rest], Opts) ->
    parse_args(Rest, Opts#{method => list_to_binary(string:uppercase(Method))});
parse_args(["--method", Method|Rest], Opts) ->
    parse_args(Rest, Opts#{method => list_to_binary(string:uppercase(Method))});

parse_args(["-H", Header|Rest], Opts) ->
    parse_args(["--header", Header|Rest], Opts);
parse_args(["--header", Header|Rest], #{headers := Headers} = Opts) ->
    case string:split(Header, ":") of
        [Name, Value] ->
            H = {list_to_binary(string:trim(Name)), list_to_binary(string:trim(Value))},
            parse_args(Rest, Opts#{headers => [H|Headers]});
        _ ->
            {error, io_lib:format("Invalid header format: ~s (expected Name:Value)", [Header])}
    end;

parse_args(["-d", Data|Rest], Opts) ->
    parse_args(Rest, Opts#{data => list_to_binary(Data)});
parse_args(["--data", Data|Rest], Opts) ->
    parse_args(Rest, Opts#{data => list_to_binary(Data)});

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

parse_args(["--cacerts", File|Rest], Opts) ->
    case filelib:is_regular(File) of
        true -> parse_args(Rest, Opts#{cacerts => File});
        false -> {error, io_lib:format("CA certificates file not found: ~s", [File])}
    end;

parse_args(["--insecure"|Rest], Opts) ->
    parse_args(Rest, Opts#{insecure => true});

parse_args(["-o", File|Rest], Opts) ->
    parse_args(Rest, Opts#{output => File});
parse_args(["--output", File|Rest], Opts) ->
    parse_args(Rest, Opts#{output => File});

parse_args(["--timeout", Timeout|Rest], Opts) ->
    try list_to_integer(Timeout) of
        N when is_integer(N), N > 0 ->
            parse_args(Rest, Opts#{timeout => N});
        _ ->
            {error, io_lib:format("Invalid timeout: ~s", [Timeout])}
    catch _:_ ->
        {error, io_lib:format("Invalid timeout: ~s", [Timeout])}
    end;

parse_args(["-v"|Rest], Opts) ->
    parse_args(Rest, Opts#{verbose => true});
parse_args(["--verbose"|Rest], Opts) ->
    parse_args(Rest, Opts#{verbose => true});

parse_args([[$-|_] = Unknown|_], _Opts) ->
    {error, io_lib:format("Unknown option: ~s", [Unknown])};

parse_args([URL|Rest], Opts) ->
    {ok, ParsedURL} = parse_url(URL),
    parse_args(Rest, maps:merge(Opts, ParsedURL)).

parse_url(URL) ->
    %% Simple URL parser for https://host:port/path
    case URL of
        "https://" ++ Rest ->
            parse_url_parts(Rest, https);
        "http://" ++ Rest ->
            parse_url_parts(Rest, http);
        _ ->
            %% Assume https
            parse_url_parts(URL, https)
    end.

parse_url_parts(Rest, Scheme) ->
    %% Split host:port/path
    {HostPort, Path} = case string:split(Rest, "/") of
        [HP] -> {HP, "/"};
        [HP, PathPart] -> {HP, "/" ++ PathPart}
    end,

    %% Split host:port
    {Host, Port} = case string:split(HostPort, ":") of
        [H] ->
            DefaultPort = case Scheme of https -> 443; http -> 80 end,
            {H, DefaultPort};
        [H, PortStr] ->
            try list_to_integer(PortStr) of
                N when is_integer(N) -> {H, N}
            catch _:_ -> {H, 443}
            end
    end,

    {ok, #{
        url => Rest,
        scheme => Scheme,
        host => Host,
        port => Port,
        path => Path
    }}.

usage() ->
    io:format(
        "Usage: h2_client URL [OPTIONS]~n"
        "~n"
        "HTTP/2 reference client~n"
        "~n"
        "Arguments:~n"
        "  URL                   Target URL (https://host:port/path)~n"
        "~n"
        "Options:~n"
        "  -X, --method METHOD   HTTP method (default: GET)~n"
        "  -H, --header K:V      Add request header (can be repeated)~n"
        "  -d, --data DATA       Request body~n"
        "  --cert FILE           Client certificate (PEM)~n"
        "  --key FILE            Client private key (PEM)~n"
        "  --cacerts FILE        CA certificates (PEM)~n"
        "  --insecure            Skip certificate verification~n"
        "  -o, --output FILE     Write response body to file~n"
        "  --timeout SEC         Connection timeout (default: ~p)~n"
        "  -v, --verbose         Show detailed output~n"
        "  -h, --help            Show this help~n"
        "~n"
        "Examples:~n"
        "  h2_client https://localhost:8443/~n"
        "  h2_client https://example.com/ -v~n"
        "  h2_client https://example.com/api -X POST -d '{\"key\":\"value\"}'~n"
        "  h2_client https://localhost:8443/ --insecure~n"
        "~n",
        [?DEFAULT_TIMEOUT]).

%% ============================================================================
%% Client Implementation
%% ============================================================================

-spec run_client(map()) -> no_return().
run_client(Opts) ->
    %% Start required applications
    ok = application:ensure_started(crypto),
    ok = application:ensure_started(asn1),
    ok = application:ensure_started(public_key),
    ok = application:ensure_started(ssl),

    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    Path = maps:get(path, Opts),
    Method = maps:get(method, Opts),
    Headers = maps:get(headers, Opts),
    Timeout = maps:get(timeout, Opts) * 1000,
    Verbose = maps:get(verbose, Opts),

    log(Verbose, "Connecting to ~s:~p~n", [Host, Port]),

    %% Build SSL options
    SSLOpts = build_ssl_opts(Opts),

    %% Connect
    ConnectOpts = #{
        transport => ssl,
        ssl_opts => SSLOpts,
        timeout => Timeout
    },

    case h2:connect(Host, Port, ConnectOpts) of
        {ok, Conn} ->
            log(Verbose, "Connected, sending request~n", []),

            %% Add host header if not present
            Headers1 = case proplists:is_defined(<<"host">>, Headers) of
                true -> Headers;
                false -> [{<<"host">>, list_to_binary(Host)} | Headers]
            end,

            %% Send request
            Result = case maps:find(data, Opts) of
                {ok, Data} ->
                    h2:request(Conn, Method, list_to_binary(Path), Headers1, Data);
                error ->
                    h2:request(Conn, Method, list_to_binary(Path), Headers1)
            end,

            case Result of
                {ok, StreamId} ->
                    log(Verbose, "Request sent on stream ~p~n", [StreamId]),
                    receive_response(Conn, StreamId, Opts);
                {error, Reason} ->
                    io:format(standard_error, "Request failed: ~p~n", [Reason]),
                    h2:close(Conn),
                    halt(1)
            end;
        {error, Reason} ->
            io:format(standard_error, "Connection failed: ~p~n", [Reason]),
            halt(1)
    end.

build_ssl_opts(Opts) ->
    BaseOpts = case maps:get(insecure, Opts) of
        true ->
            [{verify, verify_none}];
        false ->
            [{verify, verify_peer},
             {depth, 10},
             {cacerts, public_key:cacerts_get()}]
    end,

    %% Add client certificate if provided
    CertOpts = case maps:find(cert, Opts) of
        {ok, CertFile} -> [{certfile, CertFile}];
        error -> []
    end,

    KeyOpts = case maps:find(key, Opts) of
        {ok, KeyFile} -> [{keyfile, KeyFile}];
        error -> []
    end,

    %% Add custom CA certificates if provided
    CAOpts = case maps:find(cacerts, Opts) of
        {ok, CAFile} -> [{cacertfile, CAFile}];
        error -> []
    end,

    %% Server name indication
    Host = maps:get(host, Opts),
    SNIOpts = [{server_name_indication, Host}],

    BaseOpts ++ CertOpts ++ KeyOpts ++ CAOpts ++ SNIOpts.

-spec receive_response(pid(), non_neg_integer(), map()) -> no_return().
receive_response(Conn, StreamId, Opts) ->
    Verbose = maps:get(verbose, Opts),
    halt(receive_response_loop(Conn, StreamId, Opts, Verbose, <<>>, undefined)).

receive_response_loop(Conn, StreamId, Opts, Verbose, BodyAcc, Status) ->
    Timeout = maps:get(timeout, Opts) * 1000,
    receive
        {h2, Conn, {response, StreamId, ResponseStatus, Headers}} ->
            log(Verbose, "~n< HTTP/2 ~p~n", [ResponseStatus]),
            print_headers(Verbose, Headers),
            receive_response_loop(Conn, StreamId, Opts, Verbose, BodyAcc, ResponseStatus);

        {h2, Conn, {data, StreamId, Data, true}} ->
            %% Final data
            FullBody = <<BodyAcc/binary, Data/binary>>,
            handle_response_body(FullBody, Status, Opts, Verbose),
            h2:close(Conn),
            case Status of
                S when S >= 200, S < 400 -> 0;
                _ -> 1
            end;

        {h2, Conn, {data, StreamId, Data, false}} ->
            %% More data coming
            NewAcc = <<BodyAcc/binary, Data/binary>>,
            receive_response_loop(Conn, StreamId, Opts, Verbose, NewAcc, Status);

        {h2, Conn, {trailers, StreamId, Trailers}} ->
            log(Verbose, "~n< Trailers:~n", []),
            print_headers(Verbose, Trailers),
            receive_response_loop(Conn, StreamId, Opts, Verbose, BodyAcc, Status);

        {h2, Conn, {stream_reset, StreamId, ErrorCode}} ->
            io:format(standard_error, "~nStream reset: ~p~n", [ErrorCode]),
            h2:close(Conn),
            1;

        {h2, Conn, {goaway, _LastStreamId, ErrorCode}} ->
            io:format(standard_error, "~nConnection closed: ~p~n", [ErrorCode]),
            h2:close(Conn),
            1;

        {h2, Conn, {closed, Reason}} ->
            io:format(standard_error, "~nConnection closed: ~p~n", [Reason]),
            1

    after Timeout ->
        io:format(standard_error, "~nTimeout waiting for response~n", []),
        h2:close(Conn),
        1
    end.

handle_response_body(Body, Status, Opts, Verbose) ->
    case maps:find(output, Opts) of
        {ok, OutputFile} ->
            case file:write_file(OutputFile, Body) of
                ok ->
                    log(Verbose, "~nWrote ~p bytes to ~s~n", [byte_size(Body), OutputFile]);
                {error, Reason} ->
                    io:format(standard_error, "Failed to write output: ~p~n", [Reason])
            end;
        error ->
            %% Print to stdout
            case Verbose of
                true -> io:format("~n~s~n", [Body]);
                false ->
                    case Status of
                        S when S >= 200, S < 400 ->
                            io:format("~s", [Body]);
                        _ ->
                            io:format(standard_error, "~s", [Body])
                    end
            end
    end.

print_headers(true, Headers) ->
    lists:foreach(fun({Name, Value}) ->
        io:format("< ~s: ~s~n", [Name, Value])
    end, Headers);
print_headers(false, _) ->
    ok.

log(true, Format, Args) ->
    io:format(standard_error, "* " ++ Format, Args);
log(false, _Format, _Args) ->
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_url_test_() ->
    [
        ?_assertMatch({ok, #{host := "example.com", port := 443, path := "/"}},
                      parse_url("https://example.com/")),
        ?_assertMatch({ok, #{host := "example.com", port := 8443, path := "/api"}},
                      parse_url("https://example.com:8443/api")),
        ?_assertMatch({ok, #{host := "localhost", port := 443, path := "/"}},
                      parse_url("localhost"))
    ].

parse_args_test_() ->
    [
        ?_assertMatch({ok, #{method := <<"GET">>, host := "example.com"}},
                      parse_args(["https://example.com/"], #{method => <<"GET">>, headers => [], timeout => 30, verbose => false, insecure => false})),
        ?_assertMatch({ok, #{method := <<"POST">>}},
                      parse_args(["-X", "post", "https://example.com/"], #{method => <<"GET">>, headers => [], timeout => 30, verbose => false, insecure => false}))
    ].

%% A close while waiting for the response must end the wait right away
%% instead of running out the timeout.
receive_response_closed_test() ->
    Conn = self(),
    self() ! {h2, Conn, {closed, {shutdown, tcp_closed}}},
    {Elapsed, Code} = timer:tc(fun() ->
        receive_response_loop(Conn, 1, #{timeout => 2}, false, <<>>, undefined)
    end),
    ?assertEqual(1, Code),
    ?assert(Elapsed < 1000000).

-endif.
