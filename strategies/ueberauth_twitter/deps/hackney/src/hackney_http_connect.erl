%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2012-2014 Benoît Chesneau <benoitc@e-engura.org>
%%%
%%%
-module(hackney_http_connect).

-export([messages/1,
  connect/3, connect/4,
  recv/2, recv/3,
  send/2,
  setopts/2,
  controlling_process/2,
  peername/1,
  close/1,
  shutdown/2,
  sockname/1]).

-define(TIMEOUT, infinity).

-type http_socket() :: {atom(), inet:socket()}.
-export_type([http_socket/0]).

-ifdef(no_proxy_sni_support).

ssl_opts(Host, Opts) ->
  hackney_connection:ssl_opts(Host, Opts).

-else.

ssl_opts(Host, Opts) ->
  [{server_name_indication, Host} | hackney_connection:ssl_opts(Host,Opts)].

-endif.

%% @doc Atoms used to identify messages in {active, once | true} mode.
messages({hackney_ssl, _}) ->
  {ssl, ssl_closed, ssl_error};
messages({_, _}) ->
  {tcp, tcp_closed, tcp_error}.


connect(ProxyHost, ProxyPort, Opts) ->
  connect(ProxyHost, ProxyPort, Opts, infinity).

connect(ProxyHost, ProxyPort, Opts, Timeout)
  when is_list(ProxyHost), is_integer(ProxyPort),
       (Timeout =:= infinity orelse is_integer(Timeout)) ->

  %% get the  host and port to connect from the options
  Host = proplists:get_value(connect_host, Opts),
  Port = proplists:get_value(connect_port, Opts),
  Transport = proplists:get_value(connect_transport, Opts),

  %% filter connection options
  AcceptedOpts =  [linger, nodelay, send_timeout,
    send_timeout_close, raw, inet6],
  BaseOpts = [binary, {active, false}, {packet, 0}, {keepalive,  true},
    {nodelay, true}],
  ConnectOpts = hackney_util:filter_options(Opts, AcceptedOpts, BaseOpts),

  %% connect to the proxy, and upgrade the socket if needed.
  case hackney_happy:connect(ProxyHost, ProxyPort, ConnectOpts) of
    {ok, Socket} ->
      case do_handshake(Socket, Host, Port, Opts) of
        ok ->
          %% if we are connecting to a remote https source, we
          %% upgrade the connection socket to handle SSL.
          case Transport of
            hackney_ssl ->
              SSLOpts = ssl_opts(Host, Opts),
              %% upgrade the tcp connection
              case ssl:connect(Socket, SSLOpts) of
                {ok, SslSocket} ->
                  {ok, {Transport, SslSocket}};
                Error ->
                  gen_tcp:close(Socket),
                  Error
              end;
            _ ->
              {ok, {Transport, Socket}}
          end;
        Error ->
          gen_tcp:close(Socket),
          Error
      end;
    Error ->
      Error
  end.

recv(Socket, Length) ->
  recv(Socket, Length, infinity).

%% @doc Receive a packet from a socket in passive mode.
%% @see gen_tcp:recv/3
-spec recv(http_socket(), non_neg_integer(), timeout())
    -> {ok, any()} | {error, closed | atom()}.
recv({Transport, Socket}, Length, Timeout) ->
  Transport:recv(Socket, Length, Timeout).


%% @doc Send a packet on a socket.
%% @see gen_tcp:send/2
-spec send(http_socket(), iolist()) -> ok | {error, atom()}.
send({Transport, Socket}, Packet) ->
  Transport:send(Socket, Packet).

%% @doc Set one or more options for a socket.
%% @see inet:setopts/2
-spec setopts(http_socket(), list()) -> ok | {error, atom()}.
setopts({Transport, Socket}, Opts) ->
  Transport:setopts(Socket, Opts).

%% @doc Assign a new controlling process <em>Pid</em> to <em>Socket</em>.
%% @see gen_tcp:controlling_process/2
-spec controlling_process(http_socket(), pid())
    -> ok | {error, closed | not_owner | atom()}.
controlling_process({Transport, Socket}, Pid) ->
  Transport:controlling_process(Socket, Pid).

%% @doc Return the address and port for the other end of a connection.
%% @see inet:peername/1
-spec peername(http_socket())
    -> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
peername({Transport, Socket}) ->
  Transport:peername(Socket).

%% @doc Close a socks5 socket.
%% @see gen_tcp:close/1
-spec close(http_socket()) -> ok.
close({Transport, Socket}) ->
  Transport:close(Socket).

%% @doc Immediately close a socket in one or two directions.
%% @see gen_tcp:shutdown/2
-spec shutdown(http_socket(), read | write | read_write) -> ok.
shutdown({Transport, Socket}, How) ->
  Transport:shutdown(Socket, How).


%% @doc Get the local address and port of a socket
%% @see inet:sockname/1
-spec sockname(http_socket())
    -> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
sockname({Transport, Socket}) ->
  Transport:sockname(Socket).

%% private functions
do_handshake(Socket, Host, Port, Options) ->
  ProxyUser = proplists:get_value(connect_user, Options),
  ProxyPass = proplists:get_value(connect_pass, Options, <<>>),
  ProxyPort = proplists:get_value(connect_port, Options),

  %% set defaults headers
  HostHdr = case ProxyPort of
              80 ->
                list_to_binary(Host);
              _ ->
                iolist_to_binary([Host, ":", integer_to_list(Port)])
            end,
  UA =  hackney_request:default_ua(),
  Headers0 = [<<"Host: ", HostHdr/binary>>,
    <<"User-Agent: ", UA/binary >>],

  Headers = case ProxyUser of
              undefined ->
                Headers0;
              _ ->
                Credentials = base64:encode(<<ProxyUser/binary, ":",
                  ProxyPass/binary>>),
                Headers0 ++ [<< "Proxy-Authorization: Basic ", Credentials/binary >>]
            end,
  Path = iolist_to_binary([Host, ":", integer_to_list(Port)]),

  Payload = [<< "CONNECT ", Path/binary, " HTTP/1.1", "\r\n" >>,
    hackney_bstr:join(lists:reverse(Headers), <<"\r\n">>),
    <<"\r\n\r\n">>],
  case gen_tcp:send(Socket, Payload) of
    ok ->
      check_response(Socket);
    Error ->
      Error
  end.

check_response(Socket) ->
  case gen_tcp:recv(Socket, 0, ?TIMEOUT) of
    {ok, Data} ->
      check_status(Data);
    Error ->
      Error
  end.

check_status(<< "HTTP/1.1 200", _/bits >>) ->
  ok;
check_status(<< "HTTP/1.1 201", _/bits >>) ->
  ok;
check_status(<< "HTTP/1.0 200", _/bits >>) ->
  ok;
check_status(<< "HTTP/1.0 201", _/bits >>) ->
  ok;
check_status(Else) ->
  error_logger:error_msg("proxy error: ~w~n", [Else]),
  {error, proxy_error}.
