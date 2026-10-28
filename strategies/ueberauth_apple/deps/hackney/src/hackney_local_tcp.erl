%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>
%%%
-module(hackney_local_tcp).
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

%% @doc Atoms used to identify messages in {active, once | true} mode.
messages(_) -> {tcp, tcp_closed, tcp_error}.

connect(Host, Port, Opts) ->
  connect(Host, Port, Opts, infinity).

connect(Host, Port, Opts, Timeout) when is_list(Host), is_integer(Port),
                                        (Timeout =:= infinity orelse is_integer(Timeout)) ->
  BaseOpts = [binary, {active, false}, {packet, raw}],
  Opts1 = hackney_util:merge_opts(BaseOpts, Opts),
  %% connect
  gen_tcp:connect({local, Host}, Port, Opts1, Timeout).

recv(Socket, Length) ->
  recv(Socket, Length, infinity).

%% @doc Receive a packet from a socket in passive mode.
%% @see gen_tcp:recv/3
-spec recv(inet:socket(), non_neg_integer(), timeout())
    -> {ok, any()} | {error, closed | atom()}.
recv(Socket, Length, Timeout) ->
  gen_tcp:recv(Socket, Length, Timeout).


%% @doc Send a packet on a socket.
%% @see gen_tcp:send/2
-spec send(inet:socket(), iolist()) -> ok | {error, atom()}.
send(Socket, Packet) ->
  gen_tcp:send(Socket, Packet).

%% @doc Set one or more options for a socket.
%% @see inet:setopts/2
-spec setopts(inet:socket(), list()) -> ok | {error, atom()}.
setopts(Socket, Opts) ->
  inet:setopts(Socket, Opts).

%% @doc Assign a new controlling process <em>Pid</em> to <em>Socket</em>.
%% @see gen_tcp:controlling_process/2
-spec controlling_process(inet:socket(), pid())
    -> ok | {error, closed | not_owner | atom()}.
controlling_process(Socket, Pid) ->
  gen_tcp:controlling_process(Socket, Pid).

%% @doc Return the address and port for the other end of a connection.
%% @see inet:peername/1
-spec peername(inet:socket())
    -> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
peername(Socket) ->
  inet:peername(Socket).

%% @doc Close a TCP socket.
%% @see gen_tcp:close/1
-spec close(inet:socket()) -> ok.
close(Socket) ->
  gen_tcp:close(Socket).

%% @doc Immediately close a socket in one or two directions.
%% @see gen_tcp:shutdown/2
-spec shutdown(inet:socket(), read | write | read_write) -> ok.
shutdown(Socket, How) ->
  gen_tcp:shutdown(Socket, How).

%% @doc Get the local address and port of a socket
%% @see inet:sockname/1
-spec sockname(inet:socket())
    -> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
sockname(Socket) ->
  inet:sockname(Socket).
