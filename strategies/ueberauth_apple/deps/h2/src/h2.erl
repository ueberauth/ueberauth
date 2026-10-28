%% @doc HTTP/2 Public API
%%
%% This module provides the public API for HTTP/2 client and server operations.
%% It wraps the h2_connection state machine with a clean interface.
%%
%% == Client Usage ==
%%
%% ```
%% %% Connect to a server
%% {ok, Conn} = h2:connect("example.com", 443, #{}).
%%
%% %% Send a request
%% {ok, StreamId} = h2:request(Conn, <<"GET">>, <<"/">>, [
%%     {<<"host">>, <<"example.com">>}
%% ]).
%%
%% %% Receive response (messages sent to caller)
%% receive
%%     {h2, Conn, {response, StreamId, Status, Headers}} ->
%%         io:format("Status: ~p~n", [Status]);
%%     {h2, Conn, {data, StreamId, Data, IsFin}} ->
%%         io:format("Data: ~p~n", [Data])
%% end.
%%
%% %% Close connection
%% ok = h2:close(Conn).
%% '''
%%
%% == Server Usage ==
%%
%% ```
%% %% Start server
%% {ok, Server} = h2:start_server(8443, #{
%%     cert => "server.pem",
%%     key => "server-key.pem",
%%     handler => fun(Conn, StreamId, Method, Path, Headers) ->
%%         h2:send_response(Conn, StreamId, 200, [{<<"content-type">>, <<"text/plain">>}]),
%%         h2:send_data(Conn, StreamId, <<"Hello World!">>, true)
%%     end
%% }).
%%
%% %% Stop server
%% ok = h2:stop_server(Server).
%% '''
%%
%% == Event Messages ==
%%
%% The owner process receives the following messages:
%%
%% Client:
%% - `{h2, Conn, {response, StreamId, Status, Headers}}'
%% - `{h2, Conn, {data, StreamId, Data, IsFin}}'
%% - `{h2, Conn, {trailers, StreamId, Trailers}}'
%% - `{h2, Conn, {stream_reset, StreamId, ErrorCode}}'
%% - `{h2, Conn, {goaway, LastStreamId, ErrorCode}}'
%% - `{h2, Conn, {closed, Reason}}'
%%
%% Server handler receives direct calls.
%%
%% == Bidirectional streaming (gRPC) ==
%%
%% A per-call process can own a single stream's events without owning the
%% connection, so many calls multiplex one connection. Pass `#{handler => Pid}'
%% to request/3 (or call set_stream_handler/3,4) to route every event for that
%% stream to Pid; events that arrive before registration are buffered and
%% replayed in order. send_data/4 can be called repeatedly and half-closes with
%% `send_data(Conn, Sid, <<>>, true)' while the receive side stays open. For
%% backpressure use `#{flow_control => manual}' plus consume/3 on receive, and
%% send_data/5 with `#{block => Timeout}' on send. See the README for an example.
%%
-module(h2).

-include("h2.hrl").

%% Client API
-export([connect/2, connect/3]).
-export([wait_connected/1, wait_connected/2]).
-export([request/2, request/3, request/4, request/5]).

%% Server API
-export([start_server/2, start_server/3, stop_server/1, server_port/1]).
-export([serve_socket/2]).
-export([send_response/4]).
-export([respond/5]).

%% Common API
-export([send_data/3, send_data/4, send_data/5]).
-export([consume/3]).
-export([send_trailers/3]).
-export([cancel/2, cancel/3]).
-export([cancel_stream/2, cancel_stream/3]).
-deprecated([{cancel_stream, 2, "use h2:cancel/2 instead"},
             {cancel_stream, 3, "use h2:cancel/3 instead"}]).
-export([set_stream_handler/3, set_stream_handler/4, unset_stream_handler/2]).
-export([goaway/1, goaway/2]).
-export([close/1]).
-export([get_settings/1, get_peer_settings/1, peername/1]).
-export([controlling_process/2]).

%% Types
-type connection() :: pid().
-type stream_id() :: non_neg_integer().
-type headers() :: [{binary(), binary()}].
-type status() :: 100..599.
-type error_code() :: h2_error:error_code().
-type server_ref() :: {pid(), reference(), inet:port_number()}.

-type connect_opts() :: #{
    transport => tcp | ssl,
    ssl_opts => [ssl:tls_client_option()],
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    verify => verify_none | verify_peer,
    settings => h2_settings:settings(),
    %% Connection-level receive window shared by all streams. Raise it with
    %% settings.initial_window_size for large downloads. Default 65535.
    connection_window_size => 65535..2147483647,
    timeout => timeout(),
    connect_timeout => timeout(),
    sync => boolean()
}.

-type server_opts() :: #{
    transport => ssl | tcp,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    %% TLS peer-cert verification policy. Defaults to verify_none. When
    %% verify_peer is requested, `cacerts' must be supplied; otherwise the
    %% listener start fails with {error, verify_peer_requires_cacerts}.
    verify => verify_none | verify_peer,
    %% Raw ssl:tls_option() overrides; merged on top of our defaults. Useful
    %% for pinning a cipher list, disabling renegotiation, etc.
    ssl_opts => [ssl:tls_option()],
    ip => inet:ip_address(),
    inet6 => boolean(),
    handler := fun((connection(), stream_id(), binary(), binary(), headers()) -> any()),
    settings => h2_settings:settings(),
    %% Connection-level receive window shared by all streams. Default 65535.
    connection_window_size => 65535..2147483647,
    acceptors => pos_integer(),
    %% RFC 8441: when true, advertise SETTINGS_ENABLE_CONNECT_PROTOCOL=1 and
    %% accept Extended CONNECT requests carrying the `:protocol` pseudo-header.
    enable_connect_protocol => boolean()
}.

-export_type([connection/0, stream_id/0, headers/0, status/0, error_code/0]).
-export_type([connect_opts/0, server_opts/0, server_ref/0]).

%% ============================================================================
%% Client API
%% ============================================================================

%% @doc Connect to an HTTP/2 server.
%% Uses TLS by default on port 443.
-spec connect(string() | binary(), inet:port_number()) ->
    {ok, connection()} | {error, term()}.
connect(Host, Port) ->
    connect(Host, Port, #{}).

%% @doc Connect to an HTTP/2 server with options.
-spec connect(string() | binary(), inet:port_number(), connect_opts()) ->
    {ok, connection()} | {error, term()}.
connect(Host, Port, Opts) when is_binary(Host) ->
    connect(binary_to_list(Host), Port, Opts);
connect(Host, Port, Opts) ->
    Transport = maps:get(transport, Opts, ssl),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT_MS),

    case Transport of
        ssl ->
            connect_ssl(Host, Port, Opts, Timeout);
        tcp ->
            connect_tcp(Host, Port, Opts, Timeout)
    end.

connect_ssl(Host, Port, Opts, Timeout) ->
    DefaultSSLOpts = [
        {active, false},
        {mode, binary},
        {alpn_advertised_protocols, [<<"h2">>]},
        {versions, ['tlsv1.2', 'tlsv1.3']}
    ],
    %% Honor top-level verify and cacerts from connect_opts(), merged with
    %% any explicit ssl_opts (ssl_opts takes precedence).
    TopLevel = [{verify, V} || V <- [maps:get(verify, Opts, undefined)], V =/= undefined]
               ++ [{cacerts, C} || C <- [maps:get(cacerts, Opts, undefined)], C =/= undefined],
    SSLOpts0 = maps:get(ssl_opts, Opts, []),
    SSLOpts = merge_opts(merge_opts(DefaultSSLOpts, TopLevel), SSLOpts0),

    case ssl:connect(Host, Port, SSLOpts, Timeout) of
        {ok, Socket} ->
            %% Verify ALPN negotiated h2
            case ssl:negotiated_protocol(Socket) of
                {ok, <<"h2">>} ->
                    start_connection(client, Socket, Opts);
                {ok, Other} ->
                    _ = ssl:close(Socket),
                    {error, {alpn_mismatch, Other}};
                {error, protocol_not_negotiated} ->
                    %% RFC 9113 §3.3: TLS endpoints MUST use ALPN to
                    %% negotiate "h2". Don't fall back to assuming HTTP/2.
                    _ = ssl:close(Socket),
                    {error, alpn_not_negotiated};
                {error, Reason} ->
                    _ = ssl:close(Socket),
                    {error, {alpn_error, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

connect_tcp(Host, Port, Opts, Timeout) ->
    TCPOpts = [
        {active, false},
        {mode, binary},
        {packet, raw}
    ],
    case gen_tcp:connect(Host, Port, TCPOpts, Timeout) of
        {ok, Socket} ->
            start_connection(client, Socket, Opts);
        {error, Reason} ->
            {error, Reason}
    end.

start_connection(Mode, Socket, Opts) ->
    ConnOpts = maps:with([settings, connection_window_size], Opts),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT_MS),
    case h2_connection:start_link(Mode, Socket, ConnOpts) of
        {ok, Pid} ->
            %% Transfer socket ownership to connection process
            Transport = case is_ssl_socket(Socket) of
                true -> ssl;
                false -> gen_tcp
            end,
            TransferResult = case Transport of
                ssl -> ssl:controlling_process(Socket, Pid);
                gen_tcp -> gen_tcp:controlling_process(Socket, Pid)
            end,
            case TransferResult of
                ok ->
                    _ = h2_connection:activate(Pid),
                    case h2_connection:wait_connected(Pid, Timeout) of
                        ok ->
                            {ok, Pid};
                        {error, Reason} ->
                            ignore_errors(fun() -> h2_connection:close(Pid) end),
                            {error, Reason}
                    end;
                {error, TransferReason} ->
                    ignore_errors(fun() -> h2_connection:close(Pid) end),
                    ignore_errors(fun() -> close_socket(Transport, Socket) end),
                    {error, {controlling_process_failed, TransferReason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

close_socket(ssl, Socket) -> ssl:close(Socket);
close_socket(gen_tcp, Socket) -> gen_tcp:close(Socket).

-spec ignore_errors(fun(() -> any())) -> ok.
ignore_errors(Fun) ->
    try Fun() of
        _ -> ok
    catch
        _:_ -> ok
    end.

is_ssl_socket(Socket) when is_tuple(Socket) ->
    element(1, Socket) =:= sslsocket;
is_ssl_socket(_) ->
    false.

%% @doc Wait for a client connection to reach the connected state.
-spec wait_connected(connection()) -> ok | {error, term()}.
wait_connected(Conn) ->
    h2_connection:wait_connected(Conn).

-spec wait_connected(connection(), timeout()) -> ok | {error, term()}.
wait_connected(Conn, Timeout) ->
    h2_connection:wait_connected(Conn, Timeout).

%% @doc Send an HTTP/2 request with pre-built headers (matches quic_h3:request/2).
%% Headers should include pseudo-headers (:method, :path, :scheme, :authority).
-spec request(connection(), headers()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, Headers) ->
    request(Conn, Headers, #{}).

%% Opts may carry per-stream routing/backpressure options for gRPC-style use:
%%   handler      => pid()           route this stream's events to pid from
%%                                   creation (race-free; recommended for bidi)
%%   defer        => true            buffer events until a later
%%                                   set_stream_handler/3 replays them
%%   flow_control => manual | auto   manual = receive-side backpressure (consume/3)
%%   end_stream   => boolean()       half-close the send side immediately
%%   protocol     => binary()        RFC 8441 Extended CONNECT
-spec request(connection(), headers(), map()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, Headers, Opts) ->
    StreamOpts = stream_opts(Opts),
    %% RFC 8441 Extended CONNECT: when `protocol` is supplied, inject the
    %% `:protocol` pseudo-header (unless caller already included it) and
    %% default end_stream to false (the stream stays open as a tunnel).
    case maps:get(protocol, Opts, undefined) of
        undefined ->
            EndStream = maps:get(end_stream, Opts, true),
            h2_connection:send_request_headers(Conn, Headers, EndStream, StreamOpts);
        Protocol when is_binary(Protocol) ->
            Headers1 = case proplists:is_defined(<<":protocol">>, Headers) of
                true  -> Headers;
                false -> inject_protocol_pseudo(Headers, Protocol)
            end,
            EndStream = maps:get(end_stream, Opts, false),
            h2_connection:send_request_headers(Conn, Headers1, EndStream, StreamOpts)
    end.

%% Project the per-stream creation options out of the user opts map.
stream_opts(Opts) ->
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Opts) of
            {ok, Value} -> Acc#{Key => Value};
            error       -> Acc
        end
    end, #{}, [handler, defer, flow_control]).

%% Insert `:protocol` after the trailing pseudo-header so the block stays
%% well-ordered (RFC 9113 §8.3: pseudo-headers must precede regular ones).
inject_protocol_pseudo(Headers, Protocol) ->
    {Pseudos, Regular} = lists:splitwith(
        fun({<<$:, _/binary>>, _}) -> true; (_) -> false end, Headers),
    Pseudos ++ [{<<":protocol">>, Protocol} | Regular].

%% @doc Send an HTTP/2 request.
%% For body-less requests (GET, HEAD, etc.), sends HEADERS with END_STREAM.
%% For CONNECT (RFC 7540 §8.3) leaves the stream open so the caller can
%% send tunnel bytes via send_data.
-spec request(connection(), binary(), binary(), headers()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, <<"CONNECT">> = Method, Path, Headers) ->
    h2_connection:send_request(Conn, Method, Path, Headers, false);
request(Conn, Method, Path, Headers) ->
    h2_connection:send_request(Conn, Method, Path, Headers, true).

%% @doc Send an HTTP/2 request with body.
%% Sends HEADERS without END_STREAM, then sends DATA with END_STREAM.
-spec request(connection(), binary(), binary(), headers(), binary()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, Method, Path, Headers, Body) ->
    case h2_connection:send_request(Conn, Method, Path, Headers, false) of
        {ok, StreamId} ->
            case h2_connection:send_data(Conn, StreamId, Body, true) of
                ok -> {ok, StreamId};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% ============================================================================
%% Server API
%% ============================================================================

%% @doc Start a named HTTP/2 server (matches quic_h3:start_server/3).
-spec start_server(atom(), inet:port_number(), server_opts()) ->
    {ok, server_ref()} | {error, term()}.
start_server(Name, Port, Opts) when is_atom(Name) ->
    case start_server(Port, Opts) of
        {ok, Ref} ->
            persistent_term:put({?MODULE, server, Name}, Ref),
            {ok, Ref};
        Other ->
            Other
    end.

%% @doc Start an HTTP/2 server.
-spec start_server(inet:port_number(), server_opts()) ->
    {ok, server_ref()} | {error, term()}.
start_server(Port, Opts) ->
    Transport = maps:get(transport, Opts, ssl),
    case Transport of
        ssl -> start_server_ssl(Port, Opts);
        tcp -> start_server_tcp(Port, Opts)
    end.

start_server_ssl(Port, Opts) ->
    case {maps:find(cert, Opts), maps:find(key, Opts), maps:find(handler, Opts)} of
        {{ok, Cert}, {ok, Key}, {ok, Handler}} ->
            case build_server_ssl_opts(Cert, Key, Opts) of
                {error, _} = OptsErr -> OptsErr;
                {ok, SSLOpts} ->
            NumAcceptors = maps:get(acceptors, Opts, erlang:system_info(schedulers)),
            case ssl:listen(Port, SSLOpts) of
                {ok, ListenSocket} ->
                    {ok, {_, BoundPort}} = ssl:sockname(ListenSocket),
                    Ref = make_ref(),
                    ServerState = #{
                        listen_socket => ListenSocket,
                        handler => Handler,
                        conn_opts => conn_opts(Opts),
                        ref => Ref
                    },
                    case h2_sup:start_listener(#{
                        transport => ssl,
                        listen_socket => ListenSocket,
                        acceptor_count => NumAcceptors,
                        ref => Ref,
                        acceptor_fun => fun(S) -> acceptor_loop(S) end,
                        server_state => ServerState
                    }) of
                        {ok, ListenerPid} ->
                            {ok, {ListenerPid, Ref, BoundPort}};
                        {error, StartReason} ->
                            _ = ssl:close(ListenSocket),
                            {error, StartReason}
                    end;
                {error, Reason} ->
                    {error, {listen_failed, Reason}}
            end
            end;
        _ ->
            {error, {missing_required_option, [cert, key, handler]}}
    end.

%% Build the final ssl:listen/2 option list from the user-supplied map.
%% Honors `verify' (default verify_none), `cacerts', and `ssl_opts' as a
%% raw override. Rejects verify_peer without cacerts so a misconfigured
%% server fails closed instead of silently accepting unauthenticated peers.
build_server_ssl_opts(Cert, Key, Opts) ->
    CertFile = load_file(Cert),
    KeyFile  = load_file(Key),
    Verify   = maps:get(verify, Opts, verify_none),
    CACerts  = maps:get(cacerts, Opts, []),
    UserOpts = maps:get(ssl_opts, Opts, []),
    case Verify of
        verify_peer when CACerts =:= [] ->
            {error, verify_peer_requires_cacerts};
        _ ->
            Base = [
                {certfile, CertFile},
                {keyfile, KeyFile},
                {alpn_preferred_protocols, [<<"h2">>]},
                {versions, ['tlsv1.2', 'tlsv1.3']},
                {honor_cipher_order, true},
                {reuseaddr, true},
                {active, false},
                {mode, binary},
                {backlog, maps:get(backlog, Opts, 1024)},
                {verify, Verify}
            ],
            Auth = case CACerts of
                []  -> [];
                _   -> [{cacerts, CACerts}]
            end,
            Addr = socket_addr_opts(Opts),
            {ok, Addr ++ merge_opts(merge_opts(Base, Auth), UserOpts)}
    end.

%% Cleartext (h2c over TCP, prior-knowledge) server listener.
start_server_tcp(Port, Opts) ->
    case maps:find(handler, Opts) of
        {ok, Handler} ->
            NumAcceptors = maps:get(acceptors, Opts, erlang:system_info(schedulers)),
            TCPOpts = [
                {reuseaddr, true},
                {active, false},
                {mode, binary},
                {packet, raw},
                {backlog, maps:get(backlog, Opts, 1024)}
            ] ++ socket_addr_opts(Opts),
            case gen_tcp:listen(Port, TCPOpts) of
                {ok, ListenSocket} ->
                    {ok, {_, BoundPort}} = inet:sockname(ListenSocket),
                    Ref = make_ref(),
                    ServerState = #{
                        listen_socket => ListenSocket,
                        handler => Handler,
                        conn_opts => conn_opts(Opts),
                        ref => Ref
                    },
                    case h2_sup:start_listener(#{
                        transport => tcp,
                        listen_socket => ListenSocket,
                        acceptor_count => NumAcceptors,
                        ref => Ref,
                        acceptor_fun => fun(S) -> tcp_acceptor_loop(S) end,
                        server_state => ServerState
                    }) of
                        {ok, ListenerPid} ->
                            {ok, {ListenerPid, Ref, BoundPort}};
                        {error, StartReason} ->
                            _ = gen_tcp:close(ListenSocket),
                            {error, StartReason}
                    end;
                {error, Reason} ->
                    {error, {listen_failed, Reason}}
            end;
        _ ->
            {error, {missing_required_option, [handler]}}
    end.

%% @doc Stop an HTTP/2 server.
-spec stop_server(server_ref()) -> ok.
stop_server({ListenerPid, Ref, _Port}) ->
    h2_listener:stop(ListenerPid, Ref).

%% @doc Return the TCP port the server is actually listening on.
-spec server_port(server_ref()) -> inet:port_number().
server_port({_, _, Port}) -> Port.

%% @doc Serve HTTP/2 over a socket the caller already accepted and handshook.
%%
%% This is the entry point for embedders that own their own listener: accept a
%% TLS connection yourself, complete the handshake, resolve ALPN, and hand the
%% `h2' connections here while dispatching `http/1.1' to your own stack. One
%% port, one certificate, one acceptor pool, both protocols. `Opts' is the same
%% `server_opts()' map `start_server/2' takes; only `handler', `settings' and
%% `enable_connect_protocol' are read (the listener keys are the caller's
%% business), and the connection options are derived through the same code the
%% built-in acceptor uses.
%%
%% ```
%% {ok, Sock}   = ssl:transport_accept(Listen),
%% {ok, TLS}    = ssl:handshake(Sock, 30000),
%% case ssl:negotiated_protocol(TLS) of
%%     {ok, <<"h2">>}       -> h2:serve_socket(TLS, #{handler => Handler});
%%     {ok, <<"http/1.1">>} -> my_http1:serve(TLS);
%%     _                    -> ssl:close(TLS)
%% end.
%% '''
%%
%% Accepts a TLS socket or a plain `gen_tcp' socket; the transport is inferred
%% from the socket, and with it the request scheme (`https' vs `http'). A
%% cleartext socket is served as prior-knowledge h2c.
%%
%% == Socket ownership ==
%%
%% The caller must be the socket's current controlling process, the socket must
%% be in binary mode, and nothing may have been read from it beyond the TLS
%% handshake. The socket is forced to `{active, false}' before it is handed on.
%%
%% On `{ok, Pid}' ownership has transferred: the caller must not read from,
%% write to, or close the socket afterwards. On `{error, _}' the socket is
%% untouched and still belongs to the caller, who decides whether to close it.
%%
%% == Linking and connection death ==
%%
%% `Pid' is spawned linked to the caller. A clean peer disconnect or GOAWAY
%% exits it with `normal', which a caller that does not trap exits can ignore;
%% an abnormal connection failure propagates to the caller unless it traps
%% exits. If the caller dies, the connection is torn down with it. Call
%% `serve_socket/2' from the per-connection process you are happy to tie the
%% connection's lifetime to, not from a long-lived accept loop.
%%
%% `Pid' is the connection loop process, not the `h2_connection' pid. The
%% handler is passed the connection pid as its first argument, exactly as under
%% `start_server/2'.
%%
%% ALPN is not re-validated: the caller has already resolved it.
-spec serve_socket(ssl:sslsocket() | gen_tcp:socket(), server_opts()) ->
    {ok, pid()} | {error, term()}.
serve_socket(Socket, Opts) ->
    case maps:find(handler, Opts) of
        {ok, Handler} ->
            Transport = case is_ssl_socket(Socket) of
                true -> ssl;
                false -> gen_tcp
            end,
            ConnOpts = conn_opts(Opts),
            _ = set_passive(Transport, Socket),
            Pid = spawn_link(fun() ->
                receive
                    {socket_ready, Sock} ->
                        handle_server_connection(Sock, Handler, ConnOpts, Transport);
                    {socket_transfer_failed, _} ->
                        ok
                end
            end),
            TransferResult = case Transport of
                ssl -> ssl:controlling_process(Socket, Pid);
                gen_tcp -> gen_tcp:controlling_process(Socket, Pid)
            end,
            case TransferResult of
                ok ->
                    Pid ! {socket_ready, Socket},
                    {ok, Pid};
                {error, TransferReason} ->
                    %% The wrapper exits `normal'; the socket stays the
                    %% caller's, so we deliberately don't close it here.
                    Pid ! {socket_transfer_failed, TransferReason},
                    {error, {controlling_process_failed, TransferReason}}
            end;
        error ->
            {error, {missing_required_option, [handler]}}
    end.

set_passive(ssl, Socket)     -> ssl:setopts(Socket, [{active, false}]);
set_passive(gen_tcp, Socket) -> inet:setopts(Socket, [{active, false}]).

acceptor_loop(State) ->
    process_flag(trap_exit, true),
    acceptor_loop_inner(State).

%% Each accepted connection spawns a linked wrapper; when the wrapper
%% exits the acceptor (trap_exit) receives `{'EXIT', _, _}'. The accept
%% loop never reads its mailbox, so without a drain these queue up until
%% the node runs out of memory.
drain_child_exits() ->
    receive
        {'EXIT', _Pid, _Reason} -> drain_child_exits()
    after 0 -> ok
    end.

acceptor_loop_inner(#{listen_socket := ListenSocket, handler := Handler,
                      conn_opts := ConnOpts} = State) ->
    drain_child_exits(),
    case ssl:transport_accept(ListenSocket, infinity) of
        {ok, Socket} ->
            %% The TLS handshake runs in the spawned connection process, not
            %% here: a slow or stalled peer would otherwise hold up this
            %% acceptor's whole accept queue for up to ?DEFAULT_TIMEOUT_MS.
            Pid = spawn_link(fun() ->
                receive
                    {socket_ready, Sock} ->
                        accept_handshake(Sock, Handler, ConnOpts);
                    {socket_transfer_failed, _} ->
                        ok
                end
            end),
            case ssl:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! {socket_ready, Socket},
                    ok;
                {error, TransferReason} ->
                    Pid ! {socket_transfer_failed, TransferReason},
                    _ = ssl:close(Socket),
                    ok
            end,
            acceptor_loop_inner(State);
        {error, closed} ->
            %% Listen socket closed (server shutdown). Exit with `shutdown`
            %% so any wrapper/connection processes still spawn_link'd to us
            %% (in-flight connections) tear down too.
            exit(shutdown);
        {error, _Reason} ->
            acceptor_loop_inner(State)
    end.

%% TLS handshake + ALPN gate for a socket handed over by the acceptor. Runs in
%% the connection process. Anything the peer did not negotiate as `h2' is
%% closed here; callers who want to dispatch non-h2 themselves own the
%% handshake and use serve_socket/2 instead.
accept_handshake(Socket, Handler, ConnOpts) ->
    case ssl:handshake(Socket, ?DEFAULT_TIMEOUT_MS) of
        {ok, SSLSocket} ->
            case ssl:negotiated_protocol(SSLSocket) of
                {ok, <<"h2">>} ->
                    %% Ensure socket is in passive mode before transfer
                    _ = ssl:setopts(SSLSocket, [{active, false}]),
                    handle_server_connection(SSLSocket, Handler, ConnOpts, ssl);
                _ ->
                    _ = ssl:close(SSLSocket),
                    ok
            end;
        {error, _} ->
            ignore_errors(fun() -> ssl:close(Socket) end)
    end.

%% Derive the h2_connection options from a server_opts() map. Single source of
%% truth for both the built-in acceptor path and serve_socket/2, so the two
%% cannot drift.
conn_opts(Opts) ->
    maps:merge(maps:with([connection_window_size], Opts),
               #{settings => maps:get(settings, Opts, #{}),
                 enable_connect_protocol => maps:get(enable_connect_protocol, Opts, false)}).

handle_server_connection(Socket, Handler, ConnOpts, Transport) ->
    TransferFn = case Transport of
        ssl -> fun ssl:controlling_process/2;
        gen_tcp -> fun gen_tcp:controlling_process/2
    end,
    case h2_connection:start_link(server, Socket, self(), ConnOpts) of
        {ok, Conn} ->
            case TransferFn(Socket, Conn) of
                ok ->
                    _ = h2_connection:activate(Conn),
                    server_connection_loop(Conn, Handler);
                {error, _} ->
                    ignore_errors(fun() -> h2_connection:close(Conn) end),
                    ignore_errors(fun() -> close_socket(Transport, Socket) end)
            end;
        {error, _Reason} ->
            ignore_errors(fun() -> close_socket(Transport, Socket) end)
    end.

tcp_acceptor_loop(State) ->
    process_flag(trap_exit, true),
    tcp_acceptor_loop_inner(State).

tcp_acceptor_loop_inner(#{listen_socket := ListenSocket, handler := Handler,
                          conn_opts := ConnOpts} = State) ->
    drain_child_exits(),
    case gen_tcp:accept(ListenSocket, infinity) of
        {ok, Socket} ->
            _ = inet:setopts(Socket, [{active, false}]),
            Pid = spawn_link(fun() ->
                receive
                    {socket_ready, Sock} ->
                        handle_server_connection(Sock, Handler, ConnOpts, gen_tcp);
                    {socket_transfer_failed, _} ->
                        ok
                end
            end),
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    Pid ! {socket_ready, Socket},
                    ok;
                {error, TransferReason} ->
                    Pid ! {socket_transfer_failed, TransferReason},
                    _ = gen_tcp:close(Socket),
                    ok
            end,
            tcp_acceptor_loop_inner(State);
        {error, closed} ->
            exit(shutdown);
        {error, _Reason} ->
            tcp_acceptor_loop_inner(State)
    end.

server_connection_loop(Conn, Handler) ->
    receive
        {h2, Conn, {request, StreamId, Method, Path, Headers}} ->
            spawn(fun() ->
                try
                    invoke_handler(Handler, Conn, StreamId, Method, Path, Headers)
                catch
                    Class:Reason:Stack ->
                        logger:error("h2 handler crash: ~ts:~tp~n~tp",
                                     [Class, Reason, Stack]),
                        ignore_errors(fun() -> h2:send_response(Conn, StreamId, 500, []) end),
                        ignore_errors(fun() -> h2:send_data(Conn, StreamId,
                                                            <<"Internal Server Error">>, true) end)
                end
            end),
            server_connection_loop(Conn, Handler);
        {h2, Conn, {data, _StreamId, _Data, _IsFin}} ->
            %% Data received (for POST/PUT bodies)
            server_connection_loop(Conn, Handler);
        {h2, Conn, {closed, _Reason}} ->
            ok;
        {h2, Conn, {goaway, _LastStreamId, _ErrorCode}} ->
            ok;
        Other ->
            logger:debug("h2 server_connection_loop: unexpected message ~tp",
                         [Other]),
            server_connection_loop(Conn, Handler)
    end.

invoke_handler(Handler, Conn, StreamId, Method, Path, Headers) when is_function(Handler, 5) ->
    Handler(Conn, StreamId, Method, Path, Headers);
invoke_handler(Module, Conn, StreamId, Method, Path, Headers) when is_atom(Module) ->
    Module:handle_request(Conn, StreamId, Method, Path, Headers).

%% @doc Send an HTTP/2 response (server mode).
-spec send_response(connection(), stream_id(), status(), headers()) ->
    ok | {error, term()}.
send_response(Conn, StreamId, Status, Headers) ->
    h2_connection:send_response(Conn, StreamId, Status, Headers).

%% @doc Send a complete response (headers + full body) in a single call. This is
%% the fast path for the common request/response case: one message to the
%% connection and one socket write (HEADERS coalesced with DATA), versus the two
%% round-trips of send_response/4 followed by send_data/4. Falls back to the
%% granular path transparently when the response cannot be coalesced (oversized
%% headers/body, CONNECT tunnels).
-spec respond(connection(), stream_id(), status(), headers(), binary()) ->
    ok | {error, term()}.
respond(Conn, StreamId, Status, Headers, Body) ->
    case h2_connection:respond(Conn, StreamId, Status, Headers, Body) of
        need_fallback ->
            case h2_connection:send_response(Conn, StreamId, Status, Headers) of
                ok  -> h2_connection:send_data(Conn, StreamId, Body, true);
                Err -> Err
            end;
        Result ->
            Result
    end.

%% ============================================================================
%% Common API
%% ============================================================================

%% @doc Send data on a stream.
-spec send_data(connection(), stream_id(), binary()) -> ok | {error, term()}.
send_data(Conn, StreamId, Data) ->
    h2_connection:send_data(Conn, StreamId, Data).

%% @doc Send data on a stream with end_stream flag.
%%
%% Non-blocking backpressure: when the peer's send window is exhausted the data
%% is buffered, and `{error, send_buffer_full}' is returned once the buffer would
%% exceed the per-stream cap, so the caller backs off instead of growing memory
%% without bound. For a blocking variant see send_data/5.
-spec send_data(connection(), stream_id(), binary(), boolean()) -> ok | {error, term()}.
send_data(Conn, StreamId, Data, EndStream) ->
    h2_connection:send_data(Conn, StreamId, Data, EndStream).

%% @doc Send data with per-call options. Pass `#{block => Timeout}' (ms or
%% `infinity') to block until the peer's window accepts the data, returning `ok',
%% or `{error, timeout}' if the window does not open in time (the data may still
%% be queued; the caller should slow down or cancel the stream).
-spec send_data(connection(), stream_id(), binary(), boolean(), map()) ->
    ok | {error, term()}.
send_data(Conn, StreamId, Data, EndStream, Opts) ->
    h2_connection:send_data(Conn, StreamId, Data, EndStream, Opts).

%% @doc Acknowledge consumption of ByteCount received bytes on a manual
%% flow-control stream, replenishing its receive window. Receive-side
%% backpressure: a handler calls this only after processing data, gating the
%% peer's WINDOW_UPDATE on consumer progress. No-op on auto-mode streams.
-spec consume(connection(), stream_id(), non_neg_integer()) -> ok | {error, term()}.
consume(Conn, StreamId, ByteCount) ->
    h2_connection:consume(Conn, StreamId, ByteCount).

%% @doc Send trailers on a stream.
-spec send_trailers(connection(), stream_id(), headers()) -> ok | {error, term()}.
send_trailers(Conn, StreamId, Trailers) ->
    h2_connection:send_trailers(Conn, StreamId, Trailers).

%% @doc Cancel a stream.
-spec cancel(connection(), stream_id()) -> ok | {error, term()}.
cancel(Conn, StreamId) ->
    h2_connection:cancel_stream(Conn, StreamId).

%% @doc Cancel a stream with a specific error code.
-spec cancel(connection(), stream_id(), error_code()) -> ok | {error, term()}.
cancel(Conn, StreamId, ErrorCode) ->
    h2_connection:cancel_stream(Conn, StreamId, ErrorCode).

%% @deprecated Use {@link cancel/2} instead.
-spec cancel_stream(connection(), stream_id()) -> ok | {error, term()}.
cancel_stream(Conn, StreamId) ->
    cancel(Conn, StreamId).

%% @deprecated Use {@link cancel/3} instead.
-spec cancel_stream(connection(), stream_id(), error_code()) -> ok | {error, term()}.
cancel_stream(Conn, StreamId, ErrorCode) ->
    cancel(Conn, StreamId, ErrorCode).

%% @doc Register a pid to receive a stream's events.
%% Routes every event for the stream — `{response,...}', `{data,...}',
%% `{trailers,...}', `{informational,...}', `{stream_reset,...}' — to the
%% handler pid as `{h2, Conn, Event}'. By default the connection replays any
%% events buffered before the handler was registered, in arrival order, so a
%% response/trailers that raced ahead of registration is never dropped to the
%% owner. The call returns `ok'. Pass `#{drain_buffer => true}' to instead get
%% the buffered DATA back in the reply (`{ok, [{Data, Fin}, ...]}') and forward
%% it yourself (kept for the WebSocket/MASQUE tunnel callers).
%%
%% To avoid the registration race entirely, set the handler at stream creation
%% with `h2:request(Conn, Headers, #{handler => Pid})'.
%%
%% Backpressure: by default incoming DATA replenishes the receive window on
%% dispatch, so a slow handler's mailbox can grow unbounded. Pass
%% `#{flow_control => manual}' (here or at request time) to gate window
%% replenishment on consume/3 — the handler calls `h2:consume(Conn, StreamId, N)'
%% after processing N bytes, bounding in-flight data to one window.
-spec set_stream_handler(connection(), stream_id(), pid()) ->
    ok | {ok, [{binary(), boolean()}]} | {error, term()}.
set_stream_handler(Conn, StreamId, Pid) ->
    h2_connection:set_stream_handler(Conn, StreamId, Pid).

-spec set_stream_handler(connection(), stream_id(), pid(), map()) ->
    ok | {ok, [{binary(), boolean()}]} | {error, term()}.
set_stream_handler(Conn, StreamId, Pid, Opts) ->
    h2_connection:set_stream_handler(Conn, StreamId, Pid, Opts).

-spec unset_stream_handler(connection(), stream_id()) -> ok.
unset_stream_handler(Conn, StreamId) ->
    h2_connection:unset_stream_handler(Conn, StreamId).

%% @doc Initiate graceful connection shutdown.
-spec goaway(connection()) -> ok | {error, term()}.
goaway(Conn) ->
    h2_connection:send_goaway(Conn).

%% @doc Initiate connection shutdown with error code.
-spec goaway(connection(), error_code()) -> ok | {error, term()}.
goaway(Conn, ErrorCode) ->
    h2_connection:send_goaway(Conn, ErrorCode).

%% @doc Close the connection immediately.
-spec close(connection()) -> ok.
close(Conn) ->
    h2_connection:close(Conn).

%% @doc Get local settings.
-spec get_settings(connection()) -> h2_settings:settings().
get_settings(Conn) ->
    h2_connection:get_settings(Conn).

%% @doc Get peer settings.
-spec get_peer_settings(connection()) -> h2_settings:settings().
get_peer_settings(Conn) ->
    h2_connection:get_peer_settings(Conn).

%% @doc Return the address of the connection's peer.
-spec peername(connection()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(Conn) ->
    h2_connection:peername(Conn).

%% @doc Transfer connection ownership.
-spec controlling_process(connection(), pid()) -> ok | {error, term()}.
controlling_process(Conn, NewOwner) ->
    h2_connection:controlling_process(Conn, NewOwner).

%% ============================================================================
%% Internal Functions
%% ============================================================================

merge_opts(Default, Override) ->
    lists:ukeymerge(1,
        lists:ukeysort(1, Override),
        lists:ukeysort(1, Default)).

%% Build inet listen options from the `ip'/`inet6' server opts. An IPv6
%% `ip' tuple (or `inet6 => true') selects the inet6 family; `ip' sets the
%% bind address. Returned as a list for the gen_tcp/ssl listen opts.
socket_addr_opts(Opts) ->
    IP = maps:get(ip, Opts, undefined),
    Family = case {IP, maps:get(inet6, Opts, false)} of
        {{_, _, _, _, _, _, _, _}, _} -> [inet6];
        {_, true} -> [inet6];
        _ -> []
    end,
    Addr = case IP of
        undefined -> [];
        _ -> [{ip, IP}]
    end,
    Family ++ Addr.

load_file(Path) when is_list(Path) -> Path;
load_file(Path) when is_binary(Path) -> binary_to_list(Path).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

merge_opts_test() ->
    Default = [{a, 1}, {b, 2}],
    Override = [{b, 3}, {c, 4}],
    Merged = merge_opts(Default, Override),
    ?assertEqual(1, proplists:get_value(a, Merged)),
    ?assertEqual(3, proplists:get_value(b, Merged)),
    ?assertEqual(4, proplists:get_value(c, Merged)).

-endif.
