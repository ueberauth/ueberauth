%%% -*- erlang -*-
%%%
%%% QUIC Interop Runner Client
%%% https://github.com/quic-interop/quic-interop-runner
%%%
%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Interop runner client for QUIC compliance testing.
%%%
%%% Environment variables:
%%%   REQUESTS - Space-separated URLs to download
%%%   TESTCASE - Test case name (handshake, transfer, retry, etc.)
%%%   DOWNLOADS - Directory to save downloaded files
%%%   SSLKEYLOGFILE - Optional file for TLS key logging

-module(quic_interop_client).

-export([main/1]).

%% Suppress dialyzer warnings for escript functions that call halt()
-dialyzer({no_return, [main/1, run_test/3]}).
-dialyzer({nowarn_function, [run_http3_test/2]}).
-dialyzer({nowarn_function, [run_resumption_test/2, run_zerortt_test/2, run_migration_test/2]}).

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

%% Include for session_ticket record
-include("quic.hrl").

%% Ticket file location (for resumption/0-RTT tests)
%% NOT under /downloads: the runner diffs that directory against the
%% requested files and fails the test on anything unexpected in it.
-define(TICKET_FILE, "/tmp/session_ticket.dat").

main(_Args) ->
    %% Start required applications. The h3 path needs the quic app's
    %% supervision (connection registry etc.); the hq path merely
    %% tolerates its absence.
    application:ensure_all_started(crypto),
    application:ensure_all_started(ssl),
    application:ensure_all_started(quic),

    %% Get environment variables
    TestCase = os:getenv("TESTCASE", "handshake"),
    RequestsStr = os:getenv("REQUESTS", ""),
    DownloadsDir = os:getenv("DOWNLOADS", "/downloads"),

    io:format("QUIC Interop Client~n"),
    io:format("  Test case: ~s~n", [TestCase]),
    io:format("  Requests: ~s~n", [RequestsStr]),
    io:format("  Downloads: ~s~n", [DownloadsDir]),

    %% Check if test case is supported
    case lists:member(TestCase, ?SUPPORTED_TESTS) of
        false ->
            io:format("Test case ~s not supported~n", [TestCase]),
            halt(?EXIT_UNSUPPORTED);
        true ->
            run_test(TestCase, RequestsStr, DownloadsDir)
    end.

run_test("http3", RequestsStr, DownloadsDir) ->
    run_http3_test(RequestsStr, DownloadsDir);
run_test("resumption", RequestsStr, DownloadsDir) ->
    %% Resumption test: two connections, second uses session ticket
    run_resumption_test(RequestsStr, DownloadsDir);
run_test("zerortt", RequestsStr, DownloadsDir) ->
    %% 0-RTT test: send early data using stored ticket
    run_zerortt_test(RequestsStr, DownloadsDir);
run_test("connectionmigration", RequestsStr, DownloadsDir) ->
    %% Connection migration: simulate path change during transfer
    run_migration_test(RequestsStr, DownloadsDir);
run_test("multiconnect", RequestsStr, DownloadsDir) ->
    %% One connection per file, sequentially: the runner maps the
    %% handshakeloss and handshakecorruption cases to this testcase
    %% name and counts one handshake per requested file.
    Requests = string:tokens(RequestsStr, " "),
    Results = lists:append([
        download_all("multiconnect", [R], DownloadsDir)
     || R <- Requests
    ]),
    case lists:all(fun(R) -> R =:= ok end, Results) of
        true ->
            io:format("All downloads successful~n"),
            halt(?EXIT_SUCCESS);
        false ->
            io:format("Some downloads failed~n"),
            halt(?EXIT_FAILURE)
    end;
run_test(TestCase, RequestsStr, DownloadsDir) ->
    %% Standard test case
    Requests = string:tokens(RequestsStr, " "),

    case Requests of
        [] ->
            io:format("No requests specified~n"),
            halt(?EXIT_FAILURE);
        _ ->
            %% The runner asks for several files and requires them on ONE
            %% connection: the transfer test counts handshakes and fails on
            %% more than one, and multiplexing expects concurrent streams.
            %% Connect once per host and reuse it for every path.
            Results = download_all(TestCase, Requests, DownloadsDir),

            case lists:all(fun(R) -> R =:= ok end, Results) of
                true ->
                    io:format("All downloads successful~n"),
                    halt(?EXIT_SUCCESS);
                false ->
                    io:format("Some downloads failed~n"),
                    halt(?EXIT_FAILURE)
            end
    end.

download_all(TestCase, Requests, DownloadsDir) ->
    ByHost = lists:foldl(
        fun(Url, Acc) ->
            case parse_url(Url) of
                {ok, Host, Port, Path} ->
                    maps:update_with(
                        {Host, Port}, fun(Ps) -> Ps ++ [Path] end, [Path], Acc
                    );
                error ->
                    io:format("Invalid URL: ~s~n", [Url]),
                    Acc
            end
        end,
        #{},
        Requests
    ),
    lists:append(
        maps:fold(
            fun({Host, Port}, Paths, Acc) ->
                [download_from(TestCase, Host, Port, Paths, DownloadsDir) | Acc]
            end,
            [],
            ByHost
        )
    ).

download_from(TestCase, Host, Port, Paths, DownloadsDir) ->
    Opts = build_opts(TestCase),
    case quic:connect(Host, Port, Opts, self()) of
        {ok, Conn} ->
            case wait_connected(Conn, TestCase) of
                ok ->
                    %% Open every stream and send every request before
                    %% collecting any of them. The multiplexing test wants the
                    %% streams in flight at the same time; issuing them one
                    %% after another looks like a series of single-stream
                    %% transfers no matter how many files are requested.
                    io:format("Requesting ~p file(s)~n", [length(Paths)]),
                    Results = collect_streams(Conn, Paths, DownloadsDir),
                    quic:close(Conn, normal),
                    Results;
                error ->
                    quic:close(Conn, normal),
                    [error || _ <- Paths]
            end;
        {error, Reason} ->
            io:format("Connection failed: ~p~n", [Reason]),
            [error || _ <- Paths]
    end.

wait_connected(Conn, TestCase) ->
    receive
        {quic, Conn, {connected, _Info}} ->
            io:format("Connected~n"),
            case TestCase of
                "keyupdate" -> quic_connection:key_update(Conn);
                _ -> ok
            end,
            ok;
        {quic, Conn, {closed, Reason}} ->
            io:format("Connection closed: ~p~n", [Reason]),
            error;
        {quic, Conn, {transport_error, Code, Msg}} ->
            io:format("Transport error: ~p ~p~n", [Code, Msg]),
            error
    after 60000 ->
        io:format("Connection timeout~n"),
        error
    end.

%% Kept for the resumption/zerortt paths, which connect per attempt by
%% design: one connection, one request.
wait_for_connection_and_download(Conn, Path, DownloadsDir, TestCase) ->
    case wait_connected(Conn, TestCase) of
        ok -> request_path(Conn, Path, DownloadsDir);
        error -> error
    end.

request_path(Conn, Path, DownloadsDir) ->
    case quic:open_stream(Conn) of
        {ok, StreamId} ->
            Request = <<"GET ", (list_to_binary(Path))/binary, "\r\n">>,
            ok = quic:send_data(Conn, StreamId, Request, true),
            receive_and_save(Conn, StreamId, Path, DownloadsDir);
        {error, StreamErr} ->
            io:format("Failed to open stream: ~p~n", [StreamErr]),
            error
    end.

build_opts("chacha20") ->
    %% Force ChaCha20-Poly1305 cipher
    #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>],
        ciphers => [chacha20_poly1305]
    };
build_opts("keyupdate") ->
    %% Request key update after initial data
    #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>],
        force_key_update => true
    };
build_opts("v2") ->
    %% RFC 9368 compatible version negotiation: start in v1 and offer
    %% v2, so the server switches. Starting directly in v2 fails the
    %% grader, which requires the client's Initial to be v1.
    #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>],
        %% Preference order: v2 first. Some servers (picoquic) honour
        %% the client's order rather than their own.
        versions => [16#6b3343cf, 16#00000001]
    };
build_opts(_) ->
    %% Default options. disconnect_timeout is off: the blackhole case
    %% blacks the network out on purpose and expects the transfer to
    %% outlast it.
    #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>],
        disconnect_timeout => infinity
    }.

%% Keep as many streams in flight as the peer's stream credit allows and
%% refill as they finish. The multiplexing test asks for close to 2000
%% files while the default bidi stream limit is 100, so opening them all
%% up front fails all but the first hundred; the peer extends credit with
%% MAX_STREAMS only as earlier streams close.
collect_streams(Conn, Paths, DownloadsDir) ->
    {Open, Pending} = fill_streams(Conn, Paths, #{}, DownloadsDir),
    Deadline = erlang:monotonic_time(millisecond) + 180000,
    {Done, PendingLeft} = collect_loop(Conn, Open, Pending, DownloadsDir, #{}, Deadline),
    case PendingLeft of
        [] -> ok;
        _ -> io:format("~p request(s) never got a stream~n", [length(PendingLeft)])
    end,
    [Result || {_StreamId, Result} <- maps:to_list(Done)] ++
        [error || _ <- PendingLeft].

fill_streams(_Conn, [], Open, _DownloadsDir) ->
    {Open, []};
fill_streams(Conn, [Path | Rest] = Pending, Open, DownloadsDir) ->
    case quic:open_stream(Conn) of
        {ok, StreamId} ->
            Request = <<"GET ", (list_to_binary(Path))/binary, "\r\n">>,
            case quic:send_data(Conn, StreamId, Request, true) of
                ok ->
                    fill_streams(
                        Conn,
                        Rest,
                        Open#{StreamId => open_target(Path, DownloadsDir)},
                        DownloadsDir
                    );
                _Err ->
                    {Open, Pending}
            end;
        {error, _} ->
            %% Out of stream credit for now; the rest wait for MAX_STREAMS.
            {Open, Pending}
    end.

open_target(Path, DownloadsDir) ->
    FilePath = filename:join(DownloadsDir, filename:basename(Path)),
    case file:open(FilePath, [write, binary, raw]) of
        {ok, Handle} -> {Handle, FilePath, 0};
        {error, Err} -> {error, FilePath, Err}
    end.

collect_loop(_Conn, Open, [], _DownloadsDir, Done, _Deadline) when map_size(Open) =:= 0 ->
    {Done, []};
collect_loop(Conn, Open, Pending, DownloadsDir, Done, Deadline) ->
    TimeLeft = max(0, Deadline - erlang:monotonic_time(millisecond)),
    %% With requests waiting for stream credit, poll: MAX_STREAMS
    %% arriving at the connection process produces no message here, so
    %% waiting only for stream events deadlocks when the last grant
    %% lands after the last completion event has been handled.
    Timeout =
        case Pending of
            [] -> TimeLeft;
            _ -> min(200, TimeLeft)
        end,
    receive
        {quic, Conn, {stream_data, Sid, Data, Fin}} ->
            case maps:find(Sid, Open) of
                {ok, {Handle, FilePath, Written}} ->
                    ok = file:write(Handle, Data),
                    NewWritten = Written + byte_size(Data),
                    case Fin of
                        true ->
                            file:close(Handle),
                            io:format("Saved: ~s (~p bytes)~n", [FilePath, NewWritten]),
                            {Open2, Pending2} = fill_streams(
                                Conn, Pending, maps:remove(Sid, Open), DownloadsDir
                            ),
                            collect_loop(
                                Conn, Open2, Pending2, DownloadsDir, Done#{Sid => ok}, Deadline
                            );
                        false ->
                            collect_loop(
                                Conn,
                                Open#{Sid => {Handle, FilePath, NewWritten}},
                                Pending,
                                DownloadsDir,
                                Done,
                                Deadline
                            )
                    end;
                error ->
                    collect_loop(Conn, Open, Pending, DownloadsDir, Done, Deadline)
            end;
        {quic, Conn, {stream_reset, Sid, _Code}} ->
            {Open2, Pending2} = fill_streams(Conn, Pending, maps:remove(Sid, Open), DownloadsDir),
            collect_loop(Conn, Open2, Pending2, DownloadsDir, Done#{Sid => error}, Deadline);
        {quic, Conn, {closed, _Reason}} ->
            {close_remaining(Open, Done), Pending}
    after Timeout ->
        case TimeLeft > 0 andalso Pending =/= [] of
            true ->
                {Open2, Pending2} = fill_streams(Conn, Pending, Open, DownloadsDir),
                collect_loop(Conn, Open2, Pending2, DownloadsDir, Done, Deadline);
            false ->
                io:format("Stream timeout with ~p stream(s) outstanding~n", [map_size(Open)]),
                {close_remaining(Open, Done), Pending}
        end
    end.

close_remaining(Open, Done) ->
    maps:fold(
        fun
            (Sid, {Handle, FilePath, _}, Acc) when is_pid(Handle) orelse is_tuple(Handle) ->
                file:close(Handle),
                file:delete(FilePath),
                Acc#{Sid => error};
            (Sid, _, Acc) ->
                Acc#{Sid => error}
        end,
        Done,
        Open
    ).

receive_and_save(Conn, StreamId, Path, DownloadsDir) ->
    %% Extract filename and open file for streaming writes
    Filename = filename:basename(Path),
    FilePath = filename:join(DownloadsDir, Filename),

    case file:open(FilePath, [write, binary, raw]) of
        {ok, FileHandle} ->
            Result = receive_stream_data_streaming(Conn, StreamId, FileHandle, 0, 60000),
            file:close(FileHandle),
            case Result of
                {ok, BytesWritten} ->
                    io:format("Saved: ~s (~p bytes)~n", [FilePath, BytesWritten]),
                    ok;
                error ->
                    %% Clean up partial file on error
                    file:delete(FilePath),
                    error
            end;
        {error, OpenErr} ->
            io:format("Failed to open file for writing: ~p~n", [OpenErr]),
            error
    end.

%% Streaming version: write chunks to disk as they arrive (memory efficient for large files)
receive_stream_data_streaming(Conn, StreamId, FileHandle, BytesWritten, Timeout) ->
    receive
        {quic, Conn, {stream_data, StreamId, Data, Fin}} ->
            case file:write(FileHandle, Data) of
                ok ->
                    NewBytesWritten = BytesWritten + byte_size(Data),
                    case Fin of
                        true ->
                            {ok, NewBytesWritten};
                        false ->
                            receive_stream_data_streaming(
                                Conn, StreamId, FileHandle, NewBytesWritten, Timeout
                            )
                    end;
                {error, WriteErr} ->
                    io:format("Write error: ~p~n", [WriteErr]),
                    error
            end;
        {quic, Conn, {stream_reset, StreamId, _Code}} ->
            io:format("Stream reset~n"),
            error;
        {quic, Conn, {closed, _Reason}} ->
            %% Connection closed, return what we have
            case BytesWritten of
                0 -> error;
                _ -> {ok, BytesWritten}
            end
    after Timeout ->
        io:format("Stream timeout~n"),
        case BytesWritten of
            0 -> error;
            _ -> {ok, BytesWritten}
        end
    end.

parse_url(Url) ->
    %% Simple URL parser for https://host:port/path
    case string:prefix(Url, "https://") of
        nomatch ->
            error;
        HostPortPath ->
            %% string:split always returns at least one element
            [HostPort | PathParts] = string:split(HostPortPath, "/"),
            Path = "/" ++ string:join(PathParts, "/"),
            case string:split(HostPort, ":") of
                [Host, PortStr] ->
                    Port = list_to_integer(PortStr),
                    {ok, Host, Port, Path};
                [Host] ->
                    {ok, Host, 443, Path}
            end
    end.

%%====================================================================
%% Session Resumption Test
%%====================================================================

%% Two-phase resumption test:
%% Phase 1: Connect, download, receive session ticket
%% Phase 2: Reconnect with ticket, verify resumption works
run_resumption_test(RequestsStr, DownloadsDir) ->
    Requests = string:tokens(RequestsStr, " "),
    case Requests of
        [] ->
            io:format("No requests specified~n"),
            halt(?EXIT_FAILURE);
        [Url | Rest] ->
            case parse_url(Url) of
                {ok, Host, Port, Path} ->
                    %% The runner hands us two files: the first is fetched on
                    %% the fresh connection, the second on the resumed one.
                    %% Fetching the same file twice leaves the second file
                    %% missing and fails the test even when resumption works.
                    Path2 =
                        case [P || U <- Rest, {ok, _, _, P} <- [parse_url(U)]] of
                            [Second | _] -> Second;
                            [] -> Path
                        end,
                    %% Phase 1: Initial connection to get ticket
                    io:format("~n=== Phase 1: Initial connection to get ticket ===~n"),
                    case resumption_phase1(Host, Port, Path, DownloadsDir) of
                        {ok, Ticket} ->
                            %% Save ticket to file
                            save_ticket(Ticket),
                            io:format("Ticket saved~n"),

                            %% Phase 2: Resumption with ticket
                            io:format("~n=== Phase 2: Resumption with ticket ===~n"),
                            case resumption_phase2(Host, Port, Path2, DownloadsDir, Ticket) of
                                ok ->
                                    io:format("Resumption test successful~n"),
                                    halt(?EXIT_SUCCESS);
                                error ->
                                    io:format("Resumption phase 2 failed~n"),
                                    halt(?EXIT_FAILURE)
                            end;
                        error ->
                            io:format("Resumption phase 1 failed~n"),
                            halt(?EXIT_FAILURE)
                    end;
                error ->
                    io:format("Invalid URL~n"),
                    halt(?EXIT_FAILURE)
            end
    end.

%% Phase 1: Connect, download, and wait for session ticket
resumption_phase1(Host, Port, Path, DownloadsDir) ->
    Opts = #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>]
    },
    case quic:connect(Host, Port, Opts, self()) of
        {ok, Conn} ->
            Result = wait_for_ticket_and_download(Conn, Path, DownloadsDir),
            quic:close(Conn, normal),
            Result;
        {error, Reason} ->
            io:format("Phase 1 connection failed: ~p~n", [Reason]),
            error
    end.

%% Wait for connection, download, and capture session ticket
wait_for_ticket_and_download(Conn, Path, DownloadsDir) ->
    receive
        {quic, Conn, {connected, _Info}} ->
            io:format("Phase 1: Connected~n"),
            case quic:open_stream(Conn) of
                {ok, StreamId} ->
                    Request = <<"GET ", (list_to_binary(Path))/binary, "\r\n">>,
                    ok = quic:send_data(Conn, StreamId, Request, true),
                    %% Download and wait for ticket
                    download_and_wait_for_ticket(
                        Conn, StreamId, Path, DownloadsDir, undefined, []
                    );
                {error, Err} ->
                    io:format("Failed to open stream: ~p~n", [Err]),
                    error
            end;
        {quic, Conn, {closed, Reason}} ->
            io:format("Phase 1: Connection closed: ~p~n", [Reason]),
            error
    after 30000 ->
        io:format("Phase 1: Connection timeout~n"),
        error
    end.

%% Download file and wait for session ticket
download_and_wait_for_ticket(Conn, StreamId, Path, DownloadsDir, Ticket, Acc) ->
    receive
        {quic, Conn, {stream_data, StreamId, Data, Fin}} ->
            %% Every chunk counts: writing only the final one truncated the
            %% file to the last STREAM frame and failed the size check.
            Acc1 = [Acc | Data],
            case Fin of
                true ->
                    %% Save the file
                    Filename = filename:basename(Path),
                    FilePath = filename:join(DownloadsDir, Filename),
                    file:write_file(FilePath, Acc1),
                    io:format("Phase 1: Downloaded ~s~n", [FilePath]),
                    %% Continue waiting for ticket if we don't have one yet
                    case Ticket of
                        undefined -> wait_for_ticket_only(Conn, 5000);
                        _ -> {ok, Ticket}
                    end;
                false ->
                    download_and_wait_for_ticket(Conn, StreamId, Path, DownloadsDir, Ticket, Acc1)
            end;
        {quic, Conn, {session_ticket, NewTicket}} ->
            io:format("Phase 1: Received session ticket~n"),
            download_and_wait_for_ticket(Conn, StreamId, Path, DownloadsDir, NewTicket, Acc);
        {quic, Conn, {closed, _Reason}} ->
            case Ticket of
                undefined -> error;
                _ -> {ok, Ticket}
            end
    after 60000 ->
        io:format("Phase 1: Stream/ticket timeout~n"),
        case Ticket of
            undefined -> error;
            _ -> {ok, Ticket}
        end
    end.

%% Wait only for a session ticket (after download is complete)
wait_for_ticket_only(Conn, Timeout) ->
    receive
        {quic, Conn, {session_ticket, Ticket}} ->
            io:format("Received session ticket~n"),
            {ok, Ticket};
        {quic, Conn, {closed, _Reason}} ->
            io:format("Connection closed before ticket received~n"),
            error
    after Timeout ->
        io:format("Ticket timeout~n"),
        error
    end.

%% Phase 2: Reconnect using session ticket
resumption_phase2(Host, Port, Path, DownloadsDir, Ticket) ->
    Opts = #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>],
        session_ticket => Ticket
    },
    case quic:connect(Host, Port, Opts, self()) of
        {ok, Conn} ->
            Result = wait_for_connection_and_download(Conn, Path, DownloadsDir, "resumption"),
            quic:close(Conn, normal),
            Result;
        {error, Reason} ->
            io:format("Phase 2 connection failed: ~p~n", [Reason]),
            error
    end.

%% Save ticket to file for debugging/inspection
save_ticket(Ticket) ->
    file:write_file(?TICKET_FILE, term_to_binary(Ticket)).

%% Load ticket from file
load_ticket() ->
    case file:read_file(?TICKET_FILE) of
        {ok, Data} ->
            try binary_to_term(Data) of
                Ticket -> {ok, Ticket}
            catch
                _:_ -> error
            end;
        {error, _} ->
            error
    end.

%%====================================================================
%% 0-RTT Test
%%====================================================================

%% 0-RTT test requires a stored ticket from a previous connection
run_zerortt_test(RequestsStr, DownloadsDir) ->
    Requests = string:tokens(RequestsStr, " "),
    case Requests of
        [] ->
            io:format("No requests specified~n"),
            halt(?EXIT_FAILURE);
        [Url | _] ->
            case parse_url(Url) of
                {ok, Host, Port, _} ->
                    %% The runner expects every requested file to be
                    %% downloaded, with the requests sent as early data. The
                    %% first connection only fetches a ticket; downloading
                    %% there would also count the files against the wrong
                    %% handshake.
                    AllPaths = [P || U <- Requests, {ok, _, _, P} <- [parse_url(U)]],
                    TicketResult =
                        case load_ticket() of
                            {ok, T} ->
                                io:format("Using stored ticket for 0-RTT~n"),
                                {ok, T};
                            error ->
                                io:format("No stored ticket, fetching one~n"),
                                ticket_only_connection(Host, Port)
                        end,
                    case TicketResult of
                        {ok, Ticket} ->
                            save_ticket(Ticket),
                            case zerortt_download_all(Host, Port, AllPaths, DownloadsDir, Ticket) of
                                ok ->
                                    io:format("0-RTT test successful~n"),
                                    halt(?EXIT_SUCCESS);
                                error ->
                                    io:format("0-RTT test failed~n"),
                                    halt(?EXIT_FAILURE)
                            end;
                        error ->
                            io:format("Failed to get ticket for 0-RTT~n"),
                            halt(?EXIT_FAILURE)
                    end;
                error ->
                    io:format("Invalid URL~n"),
                    halt(?EXIT_FAILURE)
            end
    end.

%% Fetch every file over one HTTP/3 connection (RFC 9114); the runner
%% requires exactly one handshake, so all requests share the connection.
run_http3_test(RequestsStr, DownloadsDir) ->
    Requests = string:tokens(RequestsStr, " "),
    case [{H, Po, Pa} || U <- Requests, {ok, H, Po, Pa} <- [parse_url(U)]] of
        [] ->
            io:format("No valid requests~n"),
            halt(?EXIT_FAILURE);
        [{Host, Port, _} | _] = Parsed ->
            case quic_h3:connect(Host, Port, #{quic_opts => #{verify => false}}) of
                {ok, Conn} ->
                    ok = quic_h3:wait_connected(Conn, 30000),
                    Results = [
                        h3_fetch(Conn, Host, Path, DownloadsDir)
                     || {_, _, Path} <- Parsed
                    ],
                    quic_h3:close(Conn),
                    case lists:all(fun(R) -> R =:= ok end, Results) of
                        true ->
                            io:format("All H3 downloads successful~n"),
                            halt(?EXIT_SUCCESS);
                        false ->
                            io:format("Some H3 downloads failed~n"),
                            halt(?EXIT_FAILURE)
                    end;
                {error, Reason} ->
                    io:format("H3 connect failed: ~p~n", [Reason]),
                    halt(?EXIT_FAILURE)
            end
    end.

h3_fetch(Conn, Host, Path, DownloadsDir) ->
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>,
            case list_to_binary(Path) of
                <<"/", _/binary>> = P -> P;
                P -> <<"/", P/binary>>
            end},
        {<<":authority">>, list_to_binary(Host)}
    ],
    case quic_h3:request(Conn, Headers) of
        {ok, StreamId} ->
            h3_collect(Conn, StreamId, Path, DownloadsDir, undefined, <<>>);
        {error, Reason} ->
            io:format("H3 request failed: ~p~n", [Reason]),
            error
    end.

h3_collect(Conn, StreamId, Path, DownloadsDir, Status, Acc) ->
    receive
        {quic_h3, Conn, {response, StreamId, RespStatus, _Headers}} ->
            h3_collect(Conn, StreamId, Path, DownloadsDir, RespStatus, Acc);
        {quic_h3, Conn, {data, StreamId, Data, Fin}} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            case Fin of
                true when Status =:= 200 ->
                    FilePath = filename:join(DownloadsDir, filename:basename(Path)),
                    ok = file:write_file(FilePath, Acc1),
                    io:format("H3 saved: ~s (~p bytes)~n", [FilePath, byte_size(Acc1)]),
                    ok;
                true ->
                    io:format("H3 status ~p for ~s~n", [Status, Path]),
                    error;
                false ->
                    h3_collect(Conn, StreamId, Path, DownloadsDir, Status, Acc1)
            end;
        {quic_h3, Conn, {error, StreamId, Reason}} ->
            io:format("H3 stream error: ~p~n", [Reason]),
            error;
        {quic_h3, Conn, {closed, Reason}} ->
            io:format("H3 connection closed: ~p~n", [Reason]),
            error
    after 60000 ->
        io:format("H3 timeout for ~s~n", [Path]),
        error
    end.

%% First connection: handshake, wait for a session ticket, download nothing.
ticket_only_connection(Host, Port) ->
    %% pmtu_enabled: the zerortt grader counts every 1-RTT byte the client
    %% sends across the whole capture, and padded PMTU probes alone blow
    %% the budget.
    Opts = #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>],
        pmtu_enabled => false
    },
    case quic:connect(Host, Port, Opts, self()) of
        {ok, Conn} ->
            Result =
                receive
                    {quic, Conn, {connected, _Info}} ->
                        io:format("Ticket connection established~n"),
                        wait_for_ticket_only(Conn, 10000);
                    {quic, Conn, {closed, Reason}} ->
                        io:format("Ticket connection closed: ~p~n", [Reason]),
                        error
                after 30000 ->
                    io:format("Ticket connection timeout~n"),
                    error
                end,
            quic:close(Conn, normal),
            Result;
        {error, Reason} ->
            io:format("Ticket connection failed: ~p~n", [Reason]),
            error
    end.

%% Second connection: requests go out as early data (collect_streams opens
%% streams and sends immediately; before the handshake completes that is
%% the client 0-RTT path), responses arrive once the handshake is done.
zerortt_download_all(Host, Port, Paths, DownloadsDir, Ticket) ->
    Opts = #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>],
        session_ticket => Ticket,
        enable_early_data => true,
        pmtu_enabled => false
    },
    case quic:connect(Host, Port, Opts, self()) of
        {ok, Conn} ->
            io:format("Sending ~p request(s) as early data~n", [length(Paths)]),
            Results = collect_streams(Conn, Paths, DownloadsDir),
            quic:close(Conn, normal),
            case
                length(Results) =:= length(Paths) andalso
                    lists:all(fun(R) -> R =:= ok end, Results)
            of
                true -> ok;
                false -> error
            end;
        {error, Reason} ->
            io:format("0-RTT connection failed: ~p~n", [Reason]),
            error
    end.

%%====================================================================
%% Connection Migration Test
%%====================================================================

%% Connection migration test: change local address mid-transfer
run_migration_test(RequestsStr, DownloadsDir) ->
    Requests = string:tokens(RequestsStr, " "),
    case Requests of
        [] ->
            io:format("No requests specified~n"),
            halt(?EXIT_FAILURE);
        [Url | _Rest] ->
            case parse_url(Url) of
                {ok, Host, Port, Path} ->
                    case run_migration_download(Host, Port, Path, DownloadsDir) of
                        ok ->
                            io:format("Connection migration test successful~n"),
                            halt(?EXIT_SUCCESS);
                        error ->
                            io:format("Connection migration test failed~n"),
                            halt(?EXIT_FAILURE)
                    end;
                error ->
                    io:format("Invalid URL~n"),
                    halt(?EXIT_FAILURE)
            end
    end.

%% Connect, start download, trigger migration, complete download
run_migration_download(Host, Port, Path, DownloadsDir) ->
    Opts = #{
        verify => false,
        alpn => [<<"hq-interop">>, <<"h3">>]
    },
    case quic:connect(Host, Port, Opts, self()) of
        {ok, Conn} ->
            Result = wait_and_migrate_download(Conn, Path, DownloadsDir),
            quic:close(Conn, normal),
            Result;
        {error, Reason} ->
            io:format("Migration test connection failed: ~p~n", [Reason]),
            error
    end.

%% Wait for connection, start download, trigger migration mid-transfer
wait_and_migrate_download(Conn, Path, DownloadsDir) ->
    receive
        {quic, Conn, {connected, _Info}} ->
            io:format("Migration test: Connected~n"),
            case quic:open_stream(Conn) of
                {ok, StreamId} ->
                    Request = <<"GET ", (list_to_binary(Path))/binary, "\r\n">>,
                    ok = quic:send_data(Conn, StreamId, Request, true),
                    receive_with_migration(Conn, StreamId, Path, DownloadsDir, false, <<>>);
                {error, Err} ->
                    io:format("Failed to open stream: ~p~n", [Err]),
                    error
            end;
        {quic, Conn, {closed, Reason}} ->
            io:format("Migration test: Connection closed: ~p~n", [Reason]),
            error
    after 30000 ->
        io:format("Migration test: Connection timeout~n"),
        error
    end.

%% Receive data and trigger migration after first chunk
receive_with_migration(Conn, StreamId, Path, DownloadsDir, Migrated, Acc) ->
    receive
        {quic, Conn, {stream_data, StreamId, Data, Fin}} ->
            NewAcc = <<Acc/binary, Data/binary>>,

            %% Trigger migration after receiving some data (but before FIN)
            Migrated1 =
                case Migrated orelse Fin of
                    true ->
                        Migrated;
                    false when byte_size(NewAcc) > 0 ->
                        io:format("Migration test: Triggering path migration~n"),
                        %% The migrate call initiates path validation
                        case quic:migrate(Conn) of
                            ok ->
                                io:format("Migration test: Migration initiated~n"),
                                true;
                            {error, MigErr} ->
                                io:format("Migration test: Migration failed: ~p~n", [MigErr]),
                                % Continue anyway
                                true
                        end;
                    false ->
                        false
                end,

            case Fin of
                true ->
                    Filename = filename:basename(Path),
                    FilePath = filename:join(DownloadsDir, Filename),
                    file:write_file(FilePath, NewAcc),
                    io:format("Migration test: Downloaded ~s (~p bytes)~n", [
                        FilePath, byte_size(NewAcc)
                    ]),
                    ok;
                false ->
                    receive_with_migration(Conn, StreamId, Path, DownloadsDir, Migrated1, NewAcc)
            end;
        {quic, Conn, {path_validated, _PathInfo}} ->
            io:format("Migration test: New path validated~n"),
            receive_with_migration(Conn, StreamId, Path, DownloadsDir, Migrated, Acc);
        {quic, Conn, {closed, Reason}} ->
            io:format("Migration test: Connection closed: ~p~n", [Reason]),
            case Acc of
                <<>> ->
                    error;
                _ ->
                    Filename = filename:basename(Path),
                    FilePath = filename:join(DownloadsDir, Filename),
                    file:write_file(FilePath, Acc),
                    ok
            end
    after 60000 ->
        io:format("Migration test: Timeout~n"),
        error
    end.
