%%% -*- erlang -*-
%%%
%%% HTTP/3 Test Client
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc HTTP/3 test client escript.
%%%
%%% Usage:
%%%   quic_h3_client https://host:port/path [options]
%%%
%%% Options:
%%%   -v, --verbose     Show detailed output
%%%   --cert FILE       Client certificate (PEM)
%%%   --key FILE        Client private key (PEM)
%%%   --cacerts FILE    CA certificates (PEM)
%%%   --insecure        Skip certificate verification
%%%   -H, --header      Add request header (can be repeated)
%%%   -d, --data        Request body (for POST)
%%%   -X, --method      HTTP method (default: GET)
%%%   -o, --output      Write response body to file
%%%   --timeout         Connection timeout in seconds (default: 30)

-module(quic_h3_client).

-export([main/1]).

%% Suppress dialyzer warnings for escript functions that call halt()
-dialyzer({no_return, [main/1, run_request/2, usage/0]}).
-dialyzer(
    {nowarn_function, [
        usage/0,
        parse_args/2,
        parse_header/3,
        run_request/2,
        parse_url/1,
        build_connect_opts/1,
        read_cert/1,
        read_key/1,
        decode_key_entry/1,
        read_cacerts/1,
        build_request_headers/3,
        receive_response/4,
        receive_loop/6,
        output_response/3,
        verbose/3
    ]}
).

-define(EXIT_SUCCESS, 0).
-define(EXIT_FAILURE, 1).

-record(opts, {
    url = undefined :: string() | undefined,
    method = <<"GET">> :: binary(),
    headers = [] :: [{binary(), binary()}],
    body = <<>> :: binary(),
    output = undefined :: string() | undefined,
    verbose = false :: boolean(),
    insecure = false :: boolean(),
    cert = undefined :: string() | undefined,
    key = undefined :: string() | undefined,
    cacerts = undefined :: string() | undefined,
    timeout = 30 :: pos_integer()
}).

main([]) ->
    usage();
main(Args) ->
    application:ensure_all_started(crypto),
    application:ensure_all_started(ssl),

    case parse_args(Args, #opts{}) of
        {ok, Opts} ->
            run_request(Opts, self());
        {error, Msg} ->
            io:format(standard_error, "Error: ~s~n", [Msg]),
            halt(?EXIT_FAILURE)
    end.

usage() ->
    io:format("Usage: quic_h3_client URL [options]~n~n"),
    io:format("Options:~n"),
    io:format("  -v, --verbose      Show detailed output~n"),
    io:format("  --cert FILE        Client certificate (PEM)~n"),
    io:format("  --key FILE         Client private key (PEM)~n"),
    io:format("  --cacerts FILE     CA certificates (PEM)~n"),
    io:format("  --insecure         Skip certificate verification~n"),
    io:format("  -H, --header K:V   Add request header~n"),
    io:format("  -d, --data DATA    Request body~n"),
    io:format("  -X, --method M     HTTP method (default: GET)~n"),
    io:format("  -o, --output FILE  Write response body to file~n"),
    io:format("  --timeout SEC      Connection timeout (default: 30)~n"),
    halt(?EXIT_FAILURE).

parse_args([], #opts{url = undefined}) ->
    {error, "URL is required"};
parse_args([], Opts) ->
    {ok, Opts};
parse_args(["-v" | Rest], Opts) ->
    parse_args(Rest, Opts#opts{verbose = true});
parse_args(["--verbose" | Rest], Opts) ->
    parse_args(Rest, Opts#opts{verbose = true});
parse_args(["--insecure" | Rest], Opts) ->
    parse_args(Rest, Opts#opts{insecure = true});
parse_args(["--cert", File | Rest], Opts) ->
    parse_args(Rest, Opts#opts{cert = File});
parse_args(["--key", File | Rest], Opts) ->
    parse_args(Rest, Opts#opts{key = File});
parse_args(["--cacerts", File | Rest], Opts) ->
    parse_args(Rest, Opts#opts{cacerts = File});
parse_args(["-H", Header | Rest], Opts) ->
    parse_header(Header, Rest, Opts);
parse_args(["--header", Header | Rest], Opts) ->
    parse_header(Header, Rest, Opts);
parse_args(["-d", Data | Rest], Opts) ->
    parse_args(Rest, Opts#opts{body = list_to_binary(Data)});
parse_args(["--data", Data | Rest], Opts) ->
    parse_args(Rest, Opts#opts{body = list_to_binary(Data)});
parse_args(["-X", Method | Rest], Opts) ->
    parse_args(Rest, Opts#opts{method = list_to_binary(string:uppercase(Method))});
parse_args(["--method", Method | Rest], Opts) ->
    parse_args(Rest, Opts#opts{method = list_to_binary(string:uppercase(Method))});
parse_args(["-o", File | Rest], Opts) ->
    parse_args(Rest, Opts#opts{output = File});
parse_args(["--output", File | Rest], Opts) ->
    parse_args(Rest, Opts#opts{output = File});
parse_args(["--timeout", Secs | Rest], Opts) ->
    parse_args(Rest, Opts#opts{timeout = list_to_integer(Secs)});
parse_args(["-h" | _], _Opts) ->
    usage();
parse_args(["--help" | _], _Opts) ->
    usage();
parse_args([[$- | _] = Opt | _], _Opts) ->
    {error, io_lib:format("Unknown option: ~s", [Opt])};
parse_args([Url | Rest], #opts{url = undefined} = Opts) ->
    parse_args(Rest, Opts#opts{url = Url});
parse_args([Arg | _], _Opts) ->
    {error, io_lib:format("Unexpected argument: ~s", [Arg])}.

parse_header(Header, Rest, Opts) ->
    case string:split(Header, ":") of
        [Name, Value] ->
            H = {list_to_binary(string:trim(Name)), list_to_binary(string:trim(Value))},
            parse_args(Rest, Opts#opts{headers = Opts#opts.headers ++ [H]});
        _ ->
            {error, io_lib:format("Invalid header format: ~s (use Name:Value)", [Header])}
    end.

run_request(#opts{url = Url} = Opts, Owner) ->
    case parse_url(Url) of
        {ok, Host, Port, Path} ->
            verbose(Opts, "Connecting to ~s:~p~n", [Host, Port]),
            ConnOpts = build_connect_opts(Opts),
            case quic_h3:connect(Host, Port, ConnOpts) of
                {ok, Conn} ->
                    verbose(Opts, "Connected, sending request~n", []),
                    Headers = build_request_headers(Opts, Host, Path),
                    case quic_h3:request(Conn, Headers) of
                        {ok, StreamId} ->
                            verbose(Opts, "Request sent on stream ~p~n", [StreamId]),
                            %% Send body if present
                            case Opts#opts.body of
                                <<>> -> ok;
                                Body -> quic_h3:send_data(Conn, StreamId, Body, true)
                            end,
                            %% Wait for response
                            Result = receive_response(Conn, StreamId, Opts, Owner),
                            quic_h3:close(Conn),
                            Result;
                        {error, ReqErr} ->
                            io:format(standard_error, "Request failed: ~p~n", [ReqErr]),
                            quic_h3:close(Conn),
                            halt(?EXIT_FAILURE)
                    end;
                {error, ConnErr} ->
                    io:format(standard_error, "Connection failed: ~p~n", [ConnErr]),
                    halt(?EXIT_FAILURE)
            end;
        error ->
            io:format(standard_error, "Invalid URL: ~s~n", [Url]),
            halt(?EXIT_FAILURE)
    end.

parse_url(Url) ->
    case string:prefix(Url, "https://") of
        nomatch ->
            error;
        HostPortPath ->
            [HostPort | PathParts] = string:split(HostPortPath, "/"),
            Path =
                case PathParts of
                    [] -> "/";
                    _ -> "/" ++ string:join(PathParts, "/")
                end,
            case string:split(HostPort, ":") of
                [Host, PortStr] ->
                    Port = list_to_integer(PortStr),
                    {ok, Host, Port, Path};
                [Host] ->
                    {ok, Host, 443, Path}
            end
    end.

build_connect_opts(Opts) ->
    Base = #{},
    O1 =
        case Opts#opts.insecure of
            true -> Base#{verify => verify_none};
            false -> Base#{verify => verify_peer}
        end,
    O2 =
        case Opts#opts.cert of
            undefined -> O1;
            CertFile -> O1#{cert => read_cert(CertFile)}
        end,
    O3 =
        case Opts#opts.key of
            undefined -> O2;
            KeyFile -> O2#{key => read_key(KeyFile)}
        end,
    case Opts#opts.cacerts of
        undefined -> O3;
        CaFile -> O3#{cacerts => read_cacerts(CaFile)}
    end.

read_cert(File) ->
    {ok, Pem} = file:read_file(File),
    [{_, Der, _}] = public_key:pem_decode(Pem),
    Der.

read_key(File) ->
    {ok, Pem} = file:read_file(File),
    [Entry] = public_key:pem_decode(Pem),
    decode_key_entry(Entry).

decode_key_entry({Type, Der, not_encrypted}) ->
    public_key:der_decode(Type, Der);
decode_key_entry({'PrivateKeyInfo', Der, not_encrypted}) ->
    public_key:der_decode('PrivateKeyInfo', Der).

read_cacerts(File) ->
    {ok, Ders} = quic_cert:cacerts_from_file(File),
    Ders.

build_request_headers(Opts, Host, Path) ->
    Method = Opts#opts.method,
    PseudoHeaders = [
        {<<":method">>, Method},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, list_to_binary(Path)},
        {<<":authority">>, list_to_binary(Host)}
    ],
    PseudoHeaders ++ Opts#opts.headers.

receive_response(Conn, StreamId, Opts, _Owner) ->
    TimeoutMs = Opts#opts.timeout * 1000,
    receive_loop(Conn, StreamId, Opts, TimeoutMs, undefined, <<>>).

receive_loop(Conn, StreamId, Opts, Timeout, Status, Body) ->
    receive
        {quic_h3, Conn, {response, StreamId, RespStatus, RespHeaders}} ->
            verbose(Opts, "Response: ~p~n", [RespStatus]),
            case Opts#opts.verbose of
                true ->
                    lists:foreach(
                        fun({K, V}) ->
                            io:format("< ~s: ~s~n", [K, V])
                        end,
                        RespHeaders
                    );
                false ->
                    ok
            end,
            receive_loop(Conn, StreamId, Opts, Timeout, RespStatus, Body);
        {quic_h3, Conn, {data, StreamId, Data, false}} ->
            receive_loop(Conn, StreamId, Opts, Timeout, Status, <<Body/binary, Data/binary>>);
        {quic_h3, Conn, {data, StreamId, Data, true}} ->
            FinalBody = <<Body/binary, Data/binary>>,
            output_response(Opts, Status, FinalBody);
        {quic_h3, Conn, {trailers, StreamId, Trailers}} ->
            verbose(Opts, "Trailers: ~p~n", [Trailers]),
            output_response(Opts, Status, Body);
        {quic_h3, Conn, {stream_reset, StreamId, ErrorCode}} ->
            io:format(standard_error, "Stream reset: ~p~n", [ErrorCode]),
            halt(?EXIT_FAILURE);
        {quic_h3, Conn, {goaway, _LastId}} ->
            verbose(Opts, "Server sent GOAWAY~n", []),
            output_response(Opts, Status, Body);
        {quic_h3, Conn, {closed, CloseReason}} ->
            verbose(Opts, "Connection closed: ~p~n", [CloseReason]),
            case Status of
                undefined ->
                    io:format(standard_error, "Connection closed before response~n", []),
                    halt(?EXIT_FAILURE);
                _ ->
                    output_response(Opts, Status, Body)
            end
    after Timeout ->
        io:format(standard_error, "Request timeout~n", []),
        halt(?EXIT_FAILURE)
    end.

output_response(Opts, Status, Body) ->
    case Opts#opts.output of
        undefined ->
            io:format("~s", [Body]);
        File ->
            case file:write_file(File, Body) of
                ok ->
                    verbose(Opts, "Response written to ~s~n", [File]);
                {error, Reason} ->
                    io:format(standard_error, "Failed to write output: ~p~n", [Reason]),
                    halt(?EXIT_FAILURE)
            end
    end,
    case Status of
        S when S >= 200, S < 300 -> halt(?EXIT_SUCCESS);
        S when S >= 400 -> halt(?EXIT_FAILURE);
        _ -> halt(?EXIT_SUCCESS)
    end.

verbose(#opts{verbose = true}, Fmt, Args) ->
    io:format(standard_error, Fmt, Args);
verbose(_, _, _) ->
    ok.
