%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024-2025 Benoît Chesneau <benoitc@pm.me>
%%%
%%% @doc gen_statem process for WebSocket connections.
%%%
%%% This module implements a state machine for WebSocket connections,
%%% handling HTTP upgrade handshake and WebSocket frame exchange.
%%%
%%% States:
%%% - idle: Process started, not connected
%%% - upgrading: HTTP upgrade in progress
%%% - connected: WebSocket ready for messages
%%% - closing: Close handshake in progress
%%% - closed: Connection terminated

-module(hackney_ws).
-behaviour(gen_statem).

%% API
-export([
    start_link/1,
    connect/1,
    connect/2,
    send/2,
    recv/1,
    recv/2,
    setopts/2,
    close/1,
    close/2,
    controlling_process/2,
    peername/1,
    sockname/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    terminate/3,
    code_change/4
]).

%% State functions
-export([
    idle/3,
    upgrading/3,
    connected/3,
    closing/3,
    closed/3
]).

-define(CONNECT_TIMEOUT, 8000).
-define(RECV_TIMEOUT, infinity).
-define(CLOSE_TIMEOUT, 5000).

%% GHSA-q8jg: bound attacker-controlled buffers. A single frame's declared
%% length, the cumulative size of a fragmented message, and the handshake
%% response are all capped so a hostile server cannot drive the client to OOM.
-define(DEFAULT_MAX_FRAME_SIZE, 16#1000000).      %% 16 MiB per frame
-define(DEFAULT_MAX_MESSAGE_SIZE, 16#4000000).    %% 64 MiB per fragmented message
-define(MAX_HANDSHAKE_RESPONSE_SIZE, 65536).      %% 64 KiB of upgrade headers

%% WebSocket frame types (for documentation)
-type ws_frame() :: {text, binary()}
                  | {binary, binary()}
                  | ping
                  | {ping, binary()}
                  | pong
                  | {pong, binary()}
                  | close
                  | {close, integer(), binary()}.

-export_type([ws_frame/0]).

%% State data record
-record(ws_data, {
    %% Connection owner (linked via start_link, trap_exit handles owner death)
    owner :: pid(),

    %% Connection identity
    host :: string() | binary(),
    port :: inet:port_number(),
    transport :: hackney_tcp | hackney_ssl,
    path :: binary(),

    %% Socket state
    socket :: inet:socket() | ssl:sslsocket() | undefined,
    buffer = <<>> :: binary(),

    %% Options
    connect_timeout = ?CONNECT_TIMEOUT :: timeout(),
    recv_timeout = ?RECV_TIMEOUT :: timeout(),
    connect_options = [] :: list(),
    ssl_options = [] :: list(),
    proxy = false :: false | {connect | socks5, string(), inet:port_number(),
                              undefined | {binary(), binary()}, tcp | ssl},

    %% WebSocket options
    active = false :: false | true | once,
    headers = [] :: [{binary(), binary()}],
    protocols = [] :: [binary()],

    %% WebSocket handshake state
    ws_key :: binary() | undefined,
    ws_accept :: binary() | undefined,
    ws_protocol :: binary() | undefined,

    %% Frame parsing state (for hackney_ws_proto)
    frag_state = undefined :: term(),
    frag_buffer = [] :: list(),  %% Accumulated fragment payloads
    frag_size = 0 :: non_neg_integer(),  %% Bytes buffered in frag_buffer
    utf8_state = 0 :: integer(),
    extensions = #{} :: map(),

    %% GHSA-q8jg: buffer caps (bytes), infinity disables the cap
    max_frame_size = ?DEFAULT_MAX_FRAME_SIZE :: non_neg_integer() | infinity,
    max_message_size = ?DEFAULT_MAX_MESSAGE_SIZE :: non_neg_integer() | infinity,

    %% Pending requests
    connect_from :: {pid(), reference()} | undefined,
    recv_from :: {pid(), reference()} | undefined
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a WebSocket connection process.
%% Options:
%% <ul>
%%   <li>host: Target host (string or binary)</li>
%%   <li>port: Target port (integer)</li>
%%   <li>transport: hackney_tcp or hackney_ssl</li>
%%   <li>path: WebSocket path (binary, default "/")</li>
%%   <li>connect_timeout: Connection timeout (default 8000ms)</li>
%%   <li>recv_timeout: Receive timeout (default infinity)</li>
%%   <li>connect_options: Options passed to transport connect</li>
%%   <li>ssl_options: Additional SSL options</li>
%%   <li>active: false | true | once (default false)</li>
%%   <li>headers: Extra headers for upgrade request</li>
%%   <li>protocols: Sec-WebSocket-Protocol values</li>
%% </ul>
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, [self(), Opts], []).

%% @doc Initiate WebSocket connection. Blocks until upgrade completes.
-spec connect(pid()) -> ok | {error, term()}.
connect(Pid) ->
    connect(Pid, ?CONNECT_TIMEOUT).

-spec connect(pid(), timeout()) -> ok | {error, term()}.
connect(Pid, Timeout) ->
    gen_statem:call(Pid, connect, Timeout).

%% @doc Send a WebSocket frame.
%% Frame types: {text, Data}, {binary, Data}, ping, {ping, Data},
%%              pong, {pong, Data}, close, {close, Code, Reason}
-spec send(pid(), ws_frame()) -> ok | {error, term()}.
send(Pid, Frame) ->
    gen_statem:call(Pid, {send, Frame}).

%% @doc Receive a WebSocket frame (passive mode only).
-spec recv(pid()) -> {ok, ws_frame()} | {error, term()}.
recv(Pid) ->
    recv(Pid, ?RECV_TIMEOUT).

-spec recv(pid(), timeout()) -> {ok, ws_frame()} | {error, term()}.
recv(Pid, Timeout) ->
    gen_statem:call(Pid, recv, Timeout).

%% @doc Set socket options. Supported: [{active, true|false|once}]
-spec setopts(pid(), list()) -> ok | {error, term()}.
setopts(Pid, Opts) ->
    gen_statem:call(Pid, {setopts, Opts}).

%% @doc Close the WebSocket connection gracefully.
-spec close(pid()) -> ok.
close(Pid) ->
    close(Pid, {1000, <<>>}).

-spec close(pid(), {integer(), binary()}) -> ok.
close(Pid, {Code, Reason}) ->
    gen_statem:cast(Pid, {close, Code, Reason}).

%% @doc Assign a new controlling process.
-spec controlling_process(pid(), pid()) -> ok | {error, term()}.
controlling_process(Pid, NewOwner) ->
    gen_statem:call(Pid, {controlling_process, NewOwner}).

%% @doc Return the address and port for the other end of connection.
-spec peername(pid()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(Pid) ->
    gen_statem:call(Pid, peername).

%% @doc Get the local address and port of the socket.
-spec sockname(pid()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(Pid) ->
    gen_statem:call(Pid, sockname).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

%% @private
callback_mode() ->
    [state_functions, state_enter].

%% @private
init([Owner, Opts]) ->
    process_flag(trap_exit, true),

    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    Transport = maps:get(transport, Opts, hackney_tcp),
    Path = maps:get(path, Opts, <<"/">>),

    Data = #ws_data{
        owner = Owner,
        host = Host,
        port = Port,
        transport = Transport,
        path = Path,
        connect_timeout = maps:get(connect_timeout, Opts, ?CONNECT_TIMEOUT),
        recv_timeout = maps:get(recv_timeout, Opts, ?RECV_TIMEOUT),
        connect_options = maps:get(connect_options, Opts, []),
        ssl_options = maps:get(ssl_options, Opts, []),
        proxy = maps:get(proxy, Opts, false),
        active = maps:get(active, Opts, false),
        headers = maps:get(headers, Opts, []),
        protocols = maps:get(protocols, Opts, []),
        max_frame_size = maps:get(max_frame_size, Opts, ?DEFAULT_MAX_FRAME_SIZE),
        max_message_size = maps:get(max_message_size, Opts, ?DEFAULT_MAX_MESSAGE_SIZE)
    },
    {ok, idle, Data}.

%% @private
terminate(_Reason, _State, #ws_data{socket = undefined}) ->
    ok;
terminate(_Reason, _State, #ws_data{} = WsData) ->
    close_socket(WsData),
    ok.

%% @private
code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%====================================================================
%% State: idle
%%====================================================================

idle(enter, _OldState, _Data) ->
    keep_state_and_data;

idle({call, From}, connect, Data) ->
    #ws_data{
        host = Host,
        port = Port,
        transport = Transport,
        connect_timeout = ConnectTimeout,
        connect_options = ConnectOpts0,
        ssl_options = SSLOpts,
        proxy = Proxy
    } = Data,

    %% Build connection options
    BaseOpts = [binary, {active, false}, {packet, 0}, {keepalive, true}, {nodelay, true}],
    AcceptedOpts = [linger, nodelay, send_timeout, send_timeout_close, raw, inet6],
    ConnectOpts = hackney_util:filter_options(ConnectOpts0, AcceptedOpts, BaseOpts),

    %% Convert host to list if binary
    Host1 = case is_binary(Host) of
        true -> binary_to_list(Host);
        false -> Host
    end,

    %% Connect to the server (directly or through proxy)
    ConnectResult = case Proxy of
        false ->
            do_connect(Transport, Host1, Port, ConnectOpts, SSLOpts, ConnectTimeout);
        {connect, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport} ->
            do_connect_via_http_proxy(Transport, Host1, Port, ProxyHost, ProxyPort,
                                       ProxyAuth, ProxyTransport, ConnectOpts, SSLOpts, ConnectTimeout);
        {socks5, ProxyHost, ProxyPort, ProxyAuth, ProxyTransport} ->
            do_connect_via_socks5(Transport, Host1, Port, ProxyHost, ProxyPort,
                                   ProxyAuth, ProxyTransport, ConnectOpts, SSLOpts, ConnectTimeout)
    end,

    case ConnectResult of
        {ok, Socket} ->
            Data1 = Data#ws_data{socket = Socket},
            %% Perform WebSocket handshake
            case do_handshake(Data1) of
                {ok, Data2} ->
                    {next_state, connected, Data2, [{reply, From, ok}]};
                {error, Reason} ->
                    close_socket(Data1),
                    {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
            end;
        {error, Reason} ->
            {stop_and_reply, normal, [{reply, From, {error, Reason}}]}
    end;

idle({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_connected}}]};

idle(info, {'EXIT', Owner, _Reason}, #ws_data{owner = Owner}) ->
    {stop, normal};

idle(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: upgrading (reserved for async handshake, not currently used)
%%====================================================================

upgrading(enter, _OldState, _Data) ->
    keep_state_and_data;

upgrading({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, upgrading}}]};

upgrading(info, {'EXIT', Owner, _Reason}, #ws_data{owner = Owner}) ->
    {stop, normal};

upgrading(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: connected
%%====================================================================

connected(enter, OldState, #ws_data{active = Active} = Data) when OldState =:= idle; OldState =:= upgrading ->
    %% Set socket active mode if configured
    case Active of
        false ->
            keep_state_and_data;
        _ ->
            _ = set_socket_active(Data, Active),
            keep_state_and_data
    end;

connected(enter, _OldState, _Data) ->
    keep_state_and_data;

connected({call, From}, {send, Frame}, Data) ->
    case do_send_frame(Frame, Data) of
        ok ->
            {keep_state_and_data, [{reply, From, ok}]};
        {error, Reason} ->
            close_socket(Data),
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

connected({call, From}, recv, #ws_data{active = Active}) when Active =/= false ->
    {keep_state_and_data, [{reply, From, {error, {active_mode, Active}}}]};

connected({call, From}, recv, #ws_data{recv_timeout = Timeout} = Data) ->
    case do_recv_frame(Data, Timeout) of
        {ok, Frame, Data1} ->
            {keep_state, Data1, [{reply, From, {ok, Frame}}]};
        {close, Code, Reason, Data1} ->
            %% Server initiated close - send close response
            do_send_frame({close, Code, Reason}, Data1),
            close_socket(Data1),
            {next_state, closed, Data1, [{reply, From, {error, {closed, Code, Reason}}}]};
        {error, Reason} ->
            close_socket(Data),
            {next_state, closed, Data, [{reply, From, {error, Reason}}]}
    end;

connected({call, From}, {setopts, Opts}, Data) ->
    case proplists:get_value(active, Opts) of
        undefined ->
            {keep_state_and_data, [{reply, From, ok}]};
        NewActive when NewActive =:= true; NewActive =:= false; NewActive =:= once ->
            _ = set_socket_active(Data, NewActive),
            {keep_state, Data#ws_data{active = NewActive}, [{reply, From, ok}]};
        _ ->
            {keep_state_and_data, [{reply, From, {error, badarg}}]}
    end;

connected({call, From}, {controlling_process, NewOwner}, #ws_data{owner = OldOwner} = Data) ->
    unlink(OldOwner),
    link(NewOwner),
    Data1 = Data#ws_data{owner = NewOwner},
    {keep_state, Data1, [{reply, From, ok}]};

connected({call, From}, peername, #ws_data{socket = Socket, transport = Transport}) ->
    Result = Transport:peername(Socket),
    {keep_state_and_data, [{reply, From, Result}]};

connected({call, From}, sockname, #ws_data{socket = Socket, transport = Transport}) ->
    Result = Transport:sockname(Socket),
    {keep_state_and_data, [{reply, From, Result}]};

connected({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, badrequest}}]};

connected(cast, {close, Code, Reason}, Data) ->
    %% Client-initiated close
    do_send_frame({close, Code, Reason}, Data),
    {next_state, closing, Data, [{state_timeout, ?CLOSE_TIMEOUT, close_timeout}]};

connected(info, {Msg, Socket, SocketData}, #ws_data{socket = Socket} = Data)
  when Msg =:= tcp; Msg =:= ssl ->
    %% Active mode data
    handle_active_data(SocketData, Data);

connected(info, {Closed, Socket}, #ws_data{socket = Socket, owner = Owner} = Data)
  when Closed =:= tcp_closed; Closed =:= ssl_closed ->
    Owner ! {hackney_ws, self(), closed},
    close_socket(Data),
    {next_state, closed, Data};

connected(info, {Error, Socket, Reason}, #ws_data{socket = Socket, owner = Owner} = Data)
  when Error =:= tcp_error; Error =:= ssl_error ->
    Owner ! {hackney_ws_error, self(), Reason},
    close_socket(Data),
    {next_state, closed, Data};

connected(info, {'EXIT', Owner, _Reason}, #ws_data{owner = Owner} = Data) ->
    %% Owner died, close gracefully
    do_send_frame(close, Data),
    close_socket(Data),
    {stop, normal};

connected(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: closing
%%====================================================================

closing(enter, _OldState, _Data) ->
    keep_state_and_data;

closing({call, From}, {send, _Frame}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closing}}]};

closing({call, From}, recv, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closing}}]};

closing({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closing}}]};

closing(cast, {close, _Code, _Reason}, _Data) ->
    %% Already closing
    keep_state_and_data;

closing(info, {Msg, Socket, SocketData}, #ws_data{socket = Socket} = Data)
  when Msg =:= tcp; Msg =:= ssl ->
    %% Look for close response
    case parse_close_response(SocketData, Data) of
        {ok, _Code, _Reason} ->
            close_socket(Data),
            {next_state, closed, Data};
        more ->
            %% Keep waiting
            keep_state_and_data
    end;

closing(info, {Closed, Socket}, #ws_data{socket = Socket} = Data)
  when Closed =:= tcp_closed; Closed =:= ssl_closed ->
    {next_state, closed, Data};

closing(state_timeout, close_timeout, Data) ->
    close_socket(Data),
    {next_state, closed, Data};

closing(info, {'EXIT', Owner, _Reason}, #ws_data{owner = Owner}) ->
    {stop, normal};

closing(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% State: closed
%%====================================================================

closed(enter, _OldState, _Data) ->
    keep_state_and_data;

closed({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closed}}]};

closed(cast, {close, _Code, _Reason}, _Data) ->
    keep_state_and_data;

closed(info, {'EXIT', Owner, _Reason}, #ws_data{owner = Owner}) ->
    {stop, normal};

closed(_, _, _) ->
    keep_state_and_data.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private Connect to server
do_connect(hackney_tcp, Host, Port, Opts, _SSLOpts, Timeout) ->
    hackney_happy:connect(Host, Port, Opts, Timeout);
do_connect(hackney_ssl, Host, Port, Opts, SSLOpts, Timeout) ->
    case hackney_happy:connect(Host, Port, Opts, Timeout) of
        {ok, TcpSocket} ->
            AllSSLOpts = hackney_ssl:ssl_opts(Host, SSLOpts),
            case ssl:connect(TcpSocket, AllSSLOpts, Timeout) of
                {ok, SSLSocket} ->
                    {ok, SSLSocket};
                {error, Reason} ->
                    gen_tcp:close(TcpSocket),
                    {error, Reason}
            end;
        Error ->
            Error
    end.

%% @private Connect through HTTP CONNECT proxy
%% ProxyTransport: tcp for HTTP proxy, ssl for HTTPS proxy
do_connect_via_http_proxy(Transport, Host, Port, ProxyHost, ProxyPort,
                          ProxyAuth, ProxyTransport, _ConnectOpts, SSLOpts, Timeout) ->
    %% Build options for hackney_http_connect
    ConnectOpts0 = [
        {connect_host, Host},
        {connect_port, Port},
        {connect_transport, Transport},
        {proxy_transport, ProxyTransport}
    ],
    ConnectOpts1 = case ProxyAuth of
        undefined -> ConnectOpts0;
        {User, Pass} -> [{connect_user, User}, {connect_pass, Pass} | ConnectOpts0]
    end,
    %% Add SSL options if connecting to wss:// target
    ConnectOpts = case Transport of
        hackney_ssl ->
            [{ssl_options, SSLOpts} | ConnectOpts1];
        _ ->
            ConnectOpts1
    end,
    case hackney_http_connect:connect(ProxyHost, ProxyPort, ConnectOpts, Timeout) of
        {ok, {_ReturnedTransport, Socket}} ->
            {ok, Socket};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Connect through SOCKS5 proxy
%% ProxyTransport: tcp for plain SOCKS5, ssl for SOCKS5 over TLS
do_connect_via_socks5(Transport, Host, Port, ProxyHost, ProxyPort,
                      ProxyAuth, ProxyTransport, _ConnectOpts, SSLOpts, Timeout) ->
    %% Build options for hackney_socks5
    Socks5Opts0 = [
        {socks5_host, ProxyHost},
        {socks5_port, ProxyPort},
        {socks5_transport, Transport},
        {proxy_transport, ProxyTransport}
    ],
    %% Add authentication if provided
    Socks5Opts = case ProxyAuth of
        undefined -> Socks5Opts0;
        {User, Pass} -> [{socks5_user, User}, {socks5_pass, Pass} | Socks5Opts0]
    end,
    %% Add SSL options
    AllOpts = case Transport of
        hackney_ssl ->
            [{ssl_options, SSLOpts} | Socks5Opts];
        _ ->
            Socks5Opts
    end,
    case hackney_socks5:connect(Host, Port, AllOpts, Timeout) of
        {ok, {_ReturnedTransport, Socket}} ->
            {ok, Socket};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Perform WebSocket handshake
do_handshake(#ws_data{transport = Transport, host = Host,
                      port = Port, path = Path, headers = ExtraHeaders,
                      protocols = Protocols} = Data) ->
    %% Generate random key
    Key = hackney_ws_proto:key(),

    %% Build Host header
    Host1 = case is_binary(Host) of
        true -> Host;
        false -> list_to_binary(Host)
    end,
    DefaultPort = case Transport of
        hackney_ssl -> 443;
        _ -> 80
    end,
    HostHdr = case Port of
        DefaultPort -> Host1;
        _ -> <<Host1/binary, ":", (integer_to_binary(Port))/binary>>
    end,

    %% Build headers
    Headers0 = [
        {<<"Host">>, HostHdr},
        {<<"Upgrade">>, <<"websocket">>},
        {<<"Connection">>, <<"Upgrade">>},
        {<<"Sec-WebSocket-Key">>, Key},
        {<<"Sec-WebSocket-Version">>, <<"13">>}
    ],

    %% Add protocols if specified
    Headers1 = case Protocols of
        [] -> Headers0;
        _ ->
            ProtocolValue = hackney_bstr:join(Protocols, <<", ">>),
            Headers0 ++ [{<<"Sec-WebSocket-Protocol">>, ProtocolValue}]
    end,

    %% Add extra headers
    Headers2 = Headers1 ++ ExtraHeaders,

    %% GHSA-f9vr: the upgrade request is assembled by raw concatenation, so
    %% a caller-supplied host, path, sub-protocol or extra header carrying
    %% CR/LF/NUL would splice in extra header lines or rewrite the request
    %% line. Reject those bytes before anything reaches the socket.
    case valid_handshake_fields(Path, Headers2) of
        ok ->
            %% Build request
            HeaderLines = [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers2],
            Request = [
                <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
                HeaderLines,
                <<"\r\n">>
            ],
            do_send_handshake(Data, Key, Request);
        {error, _} = Err ->
            Err
    end.

%% @private GHSA-f9vr: reject CR/LF/NUL in the request line path and in any
%% header name/value used to build the WebSocket upgrade request.
valid_handshake_fields(Path, Headers) ->
    Fields = [Path | lists:flatmap(fun({N, V}) -> [N, V] end, Headers)],
    case lists:any(fun has_ctl_bytes/1, Fields) of
        true -> {error, invalid_handshake_header};
        false -> ok
    end.

has_ctl_bytes(Bin) when is_binary(Bin) ->
    binary:match(Bin, [<<"\r">>, <<"\n">>, <<0>>]) =/= nomatch;
has_ctl_bytes(L) when is_list(L) ->
    has_ctl_bytes(iolist_to_binary(L));
has_ctl_bytes(_) ->
    false.

%% @private Send the assembled upgrade request and process the response.
do_send_handshake(#ws_data{socket = Socket, transport = Transport} = Data, Key, Request) ->
    case Transport:send(Socket, Request) of
        ok ->
            %% Read response
            case read_handshake_response(Socket, Transport, <<>>) of
                {ok, Status, ResponseHeaders, Rest} when Status =:= 101 ->
                    %% Validate response
                    ExpectedAccept = hackney_ws_proto:encode_key(Key),
                    case validate_handshake(ResponseHeaders, ExpectedAccept) of
                        ok ->
                            Protocol = get_header_value(<<"sec-websocket-protocol">>, ResponseHeaders),
                            Data1 = Data#ws_data{
                                ws_key = Key,
                                ws_accept = ExpectedAccept,
                                ws_protocol = Protocol,
                                buffer = Rest
                            },
                            {ok, Data1};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {ok, Status, _ResponseHeaders, _Rest} ->
                    {error, {http_error, Status}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Read HTTP response until \r\n\r\n
read_handshake_response(Socket, Transport, Buffer) ->
    case Transport:recv(Socket, 0, 10000) of
        {ok, Data} ->
            Buffer1 = <<Buffer/binary, Data/binary>>,
            case binary:match(Buffer1, <<"\r\n\r\n">>) of
                {Pos, 4} ->
                    HeaderPart = binary:part(Buffer1, 0, Pos),
                    Rest = binary:part(Buffer1, Pos + 4, byte_size(Buffer1) - Pos - 4),
                    parse_handshake_response(HeaderPart, Rest);
                nomatch when byte_size(Buffer1) > ?MAX_HANDSHAKE_RESPONSE_SIZE ->
                    %% GHSA-q8jg: a server that streams bytes without ever
                    %% sending the CRLFCRLF terminator would otherwise grow
                    %% this buffer without bound.
                    {error, handshake_response_too_large};
                nomatch ->
                    read_handshake_response(Socket, Transport, Buffer1)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Parse HTTP response headers
parse_handshake_response(HeaderPart, Rest) ->
    Lines = binary:split(HeaderPart, <<"\r\n">>, [global]),
    case Lines of
        [StatusLine | HeaderLines] ->
            case parse_status_line(StatusLine) of
                {ok, Status} ->
                    Headers = parse_headers(HeaderLines),
                    {ok, Status, Headers, Rest};
                {error, Reason} ->
                    {error, Reason}
            end;
        _ ->
            {error, invalid_response}
    end.

%% @private Parse status line
parse_status_line(<<"HTTP/1.1 ", Rest/binary>>) ->
    parse_status_code(Rest);
parse_status_line(<<"HTTP/1.0 ", Rest/binary>>) ->
    parse_status_code(Rest);
parse_status_line(_) ->
    {error, invalid_status_line}.

parse_status_code(<<D1, D2, D3, _/binary>>) when D1 >= $0, D1 =< $9,
                                                  D2 >= $0, D2 =< $9,
                                                  D3 >= $0, D3 =< $9 ->
    Status = (D1 - $0) * 100 + (D2 - $0) * 10 + (D3 - $0),
    {ok, Status};
parse_status_code(_) ->
    {error, invalid_status_code}.

%% @private Parse headers
parse_headers(Lines) ->
    parse_headers(Lines, []).

parse_headers([], Acc) ->
    lists:reverse(Acc);
parse_headers([Line | Rest], Acc) ->
    case binary:split(Line, <<": ">>) of
        [Name, Value] ->
            %% Lowercase header name for case-insensitive matching
            LowerName = hackney_bstr:to_lower(Name),
            parse_headers(Rest, [{LowerName, Value} | Acc]);
        _ ->
            parse_headers(Rest, Acc)
    end.

%% @private Get header value
get_header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.

%% @private Validate handshake response
validate_handshake(Headers, ExpectedAccept) ->
    %% Check Upgrade header
    case get_header_value(<<"upgrade">>, Headers) of
        Upgrade when is_binary(Upgrade) ->
            case hackney_bstr:to_lower(Upgrade) of
                <<"websocket">> ->
                    %% Check Sec-WebSocket-Accept
                    case get_header_value(<<"sec-websocket-accept">>, Headers) of
                        ExpectedAccept ->
                            ok;
                        Other ->
                            {error, {invalid_accept, Other, ExpectedAccept}}
                    end;
                _ ->
                    {error, {invalid_upgrade, Upgrade}}
            end;
        undefined ->
            {error, missing_upgrade}
    end.

%% @private Send a WebSocket frame
do_send_frame(Frame, #ws_data{socket = Socket, transport = Transport, extensions = Exts}) ->
    %% Client frames must be masked
    EncodedFrame = hackney_ws_proto:masked_frame(Frame, Exts),
    Transport:send(Socket, EncodedFrame).

%% @private Receive a WebSocket frame (passive mode)
do_recv_frame(#ws_data{buffer = Buffer} = Data, Timeout) ->
    do_recv_frame(Buffer, Data, Timeout).

do_recv_frame(Buffer, #ws_data{socket = Socket, transport = Transport,
                                frag_state = FragState, extensions = Exts,
                                utf8_state = Utf8State} = Data, Timeout) ->
    case hackney_ws_proto:parse_header(Buffer, Exts, FragState) of
        more ->
            %% Need more data
            case Transport:recv(Socket, 0, Timeout) of
                {ok, MoreData} ->
                    do_recv_frame(<<Buffer/binary, MoreData/binary>>, Data, Timeout);
                {error, Reason} ->
                    {error, Reason}
            end;
        error ->
            {error, invalid_frame};
        {_Type, _FragState1, _Rsv, Len, _MaskKey, _Rest} when is_integer(Len),
                                                              is_integer(Data#ws_data.max_frame_size),
                                                              Len > Data#ws_data.max_frame_size ->
            %% GHSA-q8jg: refuse an oversized declared frame length before
            %% buffering its payload (a peer may announce up to 2^63-1).
            {error, {frame_too_big, Len}};
        {Type, FragState1, Rsv, Len, MaskKey, Rest} ->
            %% Parse payload
            parse_payload(Type, FragState1, Rsv, Len, MaskKey, Rest, Data, Timeout, Utf8State)
    end.

%% @private Parse frame payload
%% hackney_ws_proto:parse_payload/9 signature:
%%   parse_payload(Data, MaskKey, Utf8State, ParsedLen, Type, Len, FragState, Extensions, Rsv)
%% Returns:
%%   {ok, Payload, Utf8State, Rest} - non-close frame completed
%%   {ok, CloseCode, Payload, Utf8State, Rest} - close frame completed
%%   {more, Payload, Utf8State} - need more data
%%   {more, CloseCode, Payload, Utf8State} - need more data for close
%%   {error, Reason}
parse_payload(Type, FragState1, Rsv, Len, MaskKey, Buffer,
              #ws_data{socket = Socket, transport = Transport,
                       extensions = Exts, frag_buffer = FragBuffer,
                       frag_size = FragSize} = Data,
              Timeout, Utf8State) ->
    %% ParsedLen = 0 for new frames
    case hackney_ws_proto:parse_payload(Buffer, MaskKey, Utf8State, 0, Type, Len, FragState1, Exts, Rsv) of
        {ok, CloseCode, Payload, Utf8State1, Rest} when Type =:= close ->
            %% Close frame with code
            Data1 = Data#ws_data{buffer = Rest, frag_state = undefined,
                                 frag_buffer = [], frag_size = 0,
                                 utf8_state = Utf8State1},
            {close, CloseCode, Payload, Data1};
        {ok, Payload, Utf8State1, Rest} ->
            %% Non-close frame completed
            case FragState1 of
                {nofin, _FragType, _Rsv} ->
                    %% This is a fragment, accumulate
                    NewFragSize = FragSize + byte_size(Payload),
                    case message_within_limit(NewFragSize, Data) of
                        ok ->
                            Data1 = Data#ws_data{buffer = Rest, frag_state = FragState1,
                                                 frag_buffer = [Payload | FragBuffer],
                                                 frag_size = NewFragSize,
                                                 utf8_state = Utf8State1},
                            do_recv_frame(Rest, Data1, Timeout);
                        Err ->
                            Err
                    end;
                {fin, FragType, _Rsv} ->
                    %% Final fragment - assemble full message
                    AllPayloads = lists:reverse([Payload | FragBuffer]),
                    FullPayload = iolist_to_binary(AllPayloads),
                    Frame = hackney_ws_proto:make_frame(FragType, FullPayload, undefined, undefined),
                    Data1 = Data#ws_data{buffer = Rest, frag_state = undefined,
                                         frag_buffer = [], frag_size = 0,
                                         utf8_state = Utf8State1},
                    handle_received_frame(Frame, Data1, Timeout);
                undefined ->
                    %% Complete non-fragmented frame
                    Frame = hackney_ws_proto:make_frame(Type, Payload, undefined, undefined),
                    Data1 = Data#ws_data{buffer = Rest, frag_state = undefined,
                                         frag_buffer = [], frag_size = 0,
                                         utf8_state = Utf8State1},
                    handle_received_frame(Frame, Data1, Timeout)
            end;
        {more, _PartialPayload, Utf8State1} ->
            %% Need more data for payload
            case Transport:recv(Socket, 0, Timeout) of
                {ok, MoreData} ->
                    parse_payload(Type, FragState1, Rsv, Len, MaskKey, <<Buffer/binary, MoreData/binary>>,
                                  Data#ws_data{utf8_state = Utf8State1}, Timeout, Utf8State1);
                {error, Reason} ->
                    {error, Reason}
            end;
        {more, _CloseCode, _PartialPayload, Utf8State1} ->
            %% Need more data for close frame payload
            case Transport:recv(Socket, 0, Timeout) of
                {ok, MoreData} ->
                    parse_payload(Type, FragState1, Rsv, Len, MaskKey, <<Buffer/binary, MoreData/binary>>,
                                  Data#ws_data{utf8_state = Utf8State1}, Timeout, Utf8State1);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private Handle a received frame (ping/pong auto-response, etc.)
handle_received_frame(Frame, Data, Timeout) ->
    case Frame of
        ping ->
            do_send_frame(pong, Data),
            do_recv_frame(Data#ws_data.buffer, Data, Timeout);
        {ping, PingData} ->
            do_send_frame({pong, PingData}, Data),
            do_recv_frame(Data#ws_data.buffer, Data, Timeout);
        close ->
            {close, 1000, <<>>, Data};
        {close, Code, Reason} ->
            {close, Code, Reason, Data};
        _ ->
            {ok, Frame, Data}
    end.

%% @private Handle active mode data
handle_active_data(SocketData, #ws_data{buffer = Buffer, owner = Owner, active = Active} = Data) ->
    Data1 = Data#ws_data{buffer = <<Buffer/binary, SocketData/binary>>},
    case parse_active_frames(Data1) of
        {ok, Frames, Data2} ->
            %% Deliver frames to owner
            lists:foreach(fun(Frame) ->
                Owner ! {hackney_ws, self(), Frame}
            end, Frames),
            %% Handle active mode
            case Active of
                once ->
                    _ = set_socket_active(Data2, false),
                    {keep_state, Data2#ws_data{active = false}};
                true ->
                    {keep_state, Data2};
                false ->
                    {keep_state, Data2}
            end;
        {close, Code, Reason, Data2} ->
            Owner ! {hackney_ws, self(), {close, Code, Reason}},
            do_send_frame({close, Code, Reason}, Data2),
            close_socket(Data2),
            {next_state, closed, Data2};
        {error, Reason} ->
            Owner ! {hackney_ws_error, self(), Reason},
            close_socket(Data),
            {next_state, closed, Data}
    end.

%% @private Parse all available frames from buffer
parse_active_frames(Data) ->
    parse_active_frames(Data, []).

parse_active_frames(#ws_data{buffer = Buffer, frag_state = FragState,
                              extensions = Exts, utf8_state = Utf8State} = Data, Acc) ->
    case hackney_ws_proto:parse_header(Buffer, Exts, FragState) of
        more ->
            {ok, lists:reverse(Acc), Data};
        error ->
            {error, invalid_frame};
        {_Type, _FragState1, _Rsv, Len, _MaskKey, _Rest} when is_integer(Len),
                                                              is_integer(Data#ws_data.max_frame_size),
                                                              Len > Data#ws_data.max_frame_size ->
            %% GHSA-q8jg: refuse an oversized declared frame length.
            {error, {frame_too_big, Len}};
        {Type, FragState1, Rsv, Len, MaskKey, Rest} ->
            case parse_active_payload(Type, FragState1, Rsv, Len, MaskKey, Rest, Data, Utf8State) of
                {ok, Frame, Data1} ->
                    case Frame of
                        ping ->
                            do_send_frame(pong, Data1),
                            parse_active_frames(Data1, [ping | Acc]);
                        {ping, PingData} ->
                            do_send_frame({pong, PingData}, Data1),
                            parse_active_frames(Data1, [{ping, PingData} | Acc]);
                        close ->
                            {close, 1000, <<>>, Data1};
                        {close, Code, Reason} ->
                            {close, Code, Reason, Data1};
                        _ ->
                            parse_active_frames(Data1, [Frame | Acc])
                    end;
                {fragment, Data1} ->
                    parse_active_frames(Data1, Acc);
                more ->
                    {ok, lists:reverse(Acc), Data};
                {error, Reason} ->
                    {error, Reason};
                error ->
                    {error, invalid_payload}
            end
    end.

%% @private GHSA-q8jg: bound the cumulative size of a fragmented message so a
%% peer cannot stream unbounded non-final continuation frames.
message_within_limit(_Size, #ws_data{max_message_size = infinity}) ->
    ok;
message_within_limit(Size, #ws_data{max_message_size = Max}) when Size > Max ->
    {error, {message_too_big, Size}};
message_within_limit(_Size, _Data) ->
    ok.

%% @private Parse payload in active mode (non-blocking)
parse_active_payload(Type, FragState1, Rsv, Len, MaskKey, Buffer,
                     #ws_data{extensions = Exts, frag_buffer = FragBuffer,
                              frag_size = FragSize} = Data,
                     Utf8State) ->
    case hackney_ws_proto:parse_payload(Buffer, MaskKey, Utf8State, 0, Type, Len, FragState1, Exts, Rsv) of
        {ok, CloseCode, Payload, Utf8State1, Rest} when Type =:= close ->
            %% Close frame with code
            Data1 = Data#ws_data{buffer = Rest, frag_state = undefined,
                                 frag_buffer = [], frag_size = 0,
                                 utf8_state = Utf8State1},
            {ok, {close, CloseCode, Payload}, Data1};
        {ok, Payload, Utf8State1, Rest} ->
            %% Non-close frame completed
            case FragState1 of
                {nofin, _FragType, _Rsv} ->
                    %% This is a fragment, accumulate
                    NewFragSize = FragSize + byte_size(Payload),
                    case message_within_limit(NewFragSize, Data) of
                        ok ->
                            Data1 = Data#ws_data{buffer = Rest, frag_state = FragState1,
                                                 frag_buffer = [Payload | FragBuffer],
                                                 frag_size = NewFragSize,
                                                 utf8_state = Utf8State1},
                            {fragment, Data1};
                        Err ->
                            Err
                    end;
                {fin, FragType, _Rsv} ->
                    %% Final fragment
                    AllPayloads = lists:reverse([Payload | FragBuffer]),
                    FullPayload = iolist_to_binary(AllPayloads),
                    Frame = hackney_ws_proto:make_frame(FragType, FullPayload, undefined, undefined),
                    Data1 = Data#ws_data{buffer = Rest, frag_state = undefined,
                                         frag_buffer = [], frag_size = 0,
                                         utf8_state = Utf8State1},
                    {ok, Frame, Data1};
                undefined ->
                    %% Complete non-fragmented frame
                    Frame = hackney_ws_proto:make_frame(Type, Payload, undefined, undefined),
                    Data1 = Data#ws_data{buffer = Rest, frag_state = undefined,
                                         frag_buffer = [], frag_size = 0,
                                         utf8_state = Utf8State1},
                    {ok, Frame, Data1}
            end;
        {more, _PartialPayload, _Utf8State1} ->
            more;
        {more, _CloseCode, _PartialPayload, _Utf8State1} ->
            more;
        {error, _Reason} ->
            error
    end.

%% @private Parse close frame response
%% parse_payload(Data, MaskKey, Utf8State, ParsedLen, Type, Len, FragState, Exts, Rsv)
parse_close_response(SocketData, #ws_data{buffer = Buffer, extensions = Exts}) ->
    FullBuffer = <<Buffer/binary, SocketData/binary>>,
    case hackney_ws_proto:parse_header(FullBuffer, Exts, undefined) of
        {close, FragState, Rsv, Len, MaskKey, Rest} ->
            case hackney_ws_proto:parse_payload(Rest, MaskKey, 0, 0, close, Len, FragState, Exts, Rsv) of
                {ok, Code, Reason, _, _} ->
                    {ok, Code, Reason};
                _ ->
                    {ok, 1000, <<>>}
            end;
        _ ->
            more
    end.

%% @private Set socket active mode
set_socket_active(#ws_data{socket = Socket, transport = hackney_ssl}, Mode) ->
    ssl:setopts(Socket, [{active, Mode}]);
set_socket_active(#ws_data{socket = Socket}, Mode) ->
    inet:setopts(Socket, [{active, Mode}]).

%% @private Close socket
close_socket(#ws_data{socket = undefined}) ->
    ok;
close_socket(#ws_data{socket = Socket, transport = Transport}) ->
    try Transport:close(Socket) catch _:_ -> ok end,
    ok.
