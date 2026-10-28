-module(hackney_happy).

-export([connect/3, connect/4]).
-export([connect_udp/3, connect_udp/4]).

-include("hackney_internal.hrl").
-include_lib("kernel/include/inet.hrl").

-define(TIMEOUT, 250).
-define(CONNECT_TIMEOUT, 5000).

connect(Hostname, Port, Opts) ->
  connect(Hostname, Port, Opts, ?CONNECT_TIMEOUT).

connect(Hostname, Port, Opts, Timeout) ->
  do_connect(parse_address(Hostname), Port, Opts, Timeout).

do_connect(Hostname, Port, Opts, Timeout) when is_tuple(Hostname) ->
  case hackney_cidr:is_ipv6(Hostname) of
    true ->
      ?report_debug("connect using IPv6", [{hostname, Hostname}, {port, Port}]),
      gen_tcp:connect(Hostname, Port, [inet6 | Opts], Timeout);
    false ->
      case hackney_cidr:is_ipv4(Hostname) of
        true ->
          ?report_debug("connect using IPv4", [{hostname, Hostname}, {port, Port}]),
          gen_tcp:connect(Hostname, Port, [inet | Opts], Timeout);
        false ->
          {error, nxdomain}
      end
  end;
do_connect(Hostname, Port, Opts, Timeout) ->
  ?report_debug("happy eyeballs, try to connect using IPv6",  [{hostname, Hostname}, {port, Port}, {timeout, Timeout}]),
  Self = self(),
  case getaddrs(Hostname) of
    {[], []} -> {error, nxdomain};
    {[], IPv4Addrs} ->
      ?report_trace("happy connect: try IPv4 only", []),
      {Pid4, MRef4} = spawn_monitor(fun() -> try_connect(IPv4Addrs, Port, Opts, Timeout, Self) end),
      do_connect_2(Pid4, MRef4, Timeout);
    {Ipv6Addrs, []} ->
      ?report_trace("happy connect: try IPv6 only", []),
      {Pid6, MRef6} = spawn_monitor(fun() -> try_connect(Ipv6Addrs, Port, Opts, Timeout, Self) end),
      do_connect_2(Pid6, MRef6, Timeout);
    {Ipv6Addrs, IPv4Addrs} ->
      {Pid6, MRef6} = spawn_monitor(fun() -> try_connect(Ipv6Addrs, Port, Opts, Timeout, Self) end),
      TRef = erlang:start_timer(?TIMEOUT, self(), try_ipv4),
      receive
        {'DOWN', MRef6, _Type, _Pid, {happy_connect, OK}} ->
          _ = erlang:cancel_timer(TRef, []),
          OK;
        {'DOWN', MRef6, _Type, _Pid, _Info} ->
          _ = erlang:cancel_timer(TRef, []),
          {Pid4, MRef4} = spawn_monitor(fun() -> try_connect(IPv4Addrs, Port, Opts, Timeout, Self) end),
          do_connect_2(Pid4, MRef4, Timeout);
        {timeout, TRef, try_ipv4} ->
          ?report_trace("happy connect: try IPv4", []),
          PidRef4 = spawn_monitor(fun() -> try_connect(IPv4Addrs, Port, Opts, Timeout, Self) end),
          do_connect_1(PidRef4, {Pid6, MRef6}, Timeout)
      after Timeout ->
              ?report_trace("happy, connect timeout", []),
              _ = erlang:cancel_timer(TRef, []),
              erlang:demonitor(MRef6, [flush]),
              {error, connect_timeout}
      end
  end.


do_connect_1({Pid4, MRef4}, {Pid6, MRef6}, Timeout) ->
  receive
    {'DOWN', MRef4, _Type, _Pid, {happy_connect, OK}} ->
      ?report_trace("happy_connect: ~p", [OK]),
      connect_gc(Pid6, MRef6),
      OK;
     {'DOWN', MRef6, _Type, _Pid, {happy_connect, OK}} ->
      ?report_trace("happy_connect ~p", [OK]),
      connect_gc(Pid4, MRef4),
      OK;
    {'DOWN', MRef4, _Type, _Pid, _Info} ->
      do_connect_2(Pid6, MRef6, Timeout);
    {'DOWN', MRef6, _Type, _Pid, _Info} ->
      do_connect_2(Pid4, MRef4, Timeout)
  after Timeout ->
          connect_gc(Pid4, MRef4),
          connect_gc(Pid6, MRef6),
          {error, connect_timeout}
  end.

do_connect_2(Pid, MRef, Timeout) ->
  receive
    {'DOWN', MRef, _Type, _Pid, {happy_connect, OK}} ->
      ?report_trace("happy_connect ~p", [OK]),
      OK;
    {'DOWN', MRef, _Type, _Pid, {error, _} = Error} ->
      Error;
    {'DOWN', MRef, _Type, _Pid, Info} ->
      %% Wrap unexpected exit reasons in error tuple
      {error, Info}
  after Timeout ->
          connect_gc(Pid, MRef),
          {error, connect_timeout}
  end.

connect_gc(Pid, MRef) ->
  (try exit(Pid, normal) catch _:_ -> ok end),
  erlang:demonitor(MRef, [flush]).


-spec parse_address(inet:ip_address() | binary() | string()) -> inet:ip_address() | string().
parse_address(IPTuple) when is_tuple(IPTuple) -> IPTuple;
parse_address(IPBin) when is_binary(IPBin) ->
  parse_address(binary_to_list(IPBin));
%% IPv6 string with brackets
parse_address("[" ++ IPString) ->
  parse_address(lists:sublist(IPString, length(IPString) - 1));
parse_address(IPString) ->
  case inet:parse_address(IPString) of
    {ok, IP} -> IP;
    {error, _} -> IPString
  end.

-spec getaddrs(string()) -> {[{inet:ip_address(), 'inet6' | 'inet'}], [{inet:ip_address(), 'inet6' | 'inet'}]}.
getaddrs("localhost") ->
  {[{{0,0,0,0,0,0,0,1}, 'inet6'}], [{{127,0,0,1}, 'inet'}]};
getaddrs(Name) ->
  IP6Addrs = [{Addr, 'inet6'} || Addr <- getbyname(Name, 'aaaa')],
  IP4Addrs = [{Addr, 'inet'} || Addr <- getbyname(Name, 'a')],
  {IP6Addrs, IP4Addrs}.

getbyname(Hostname, Type) ->
  %% First try DNS resolution using inet_res:getbyname
  try inet_res:getbyname(Hostname, Type) of
    {'ok', #hostent{h_addr_list=AddrList}} ->
      AddrList;
    {error, _Reason} ->
      %% DNS failed, try fallback to /etc/hosts using inet:gethostbyname
      %% This fixes NXDOMAIN errors in Docker Compose environments where
      %% hostnames are resolved via /etc/hosts entries
      fallback_hosts_lookup(Hostname, Type)
  catch
    Class:Reason ->
      ?report_debug("DNS error", [{hostname, Hostname}
                                 ,{type, Type}
                                 ,{error, {Class, Reason}}]),
      %% Try fallback on resolver crashes too
      fallback_hosts_lookup(Hostname, Type)
  end.

%% Fallback to check /etc/hosts when DNS resolution fails
fallback_hosts_lookup(Hostname, Type) ->
  InetType = case Type of
    a -> inet;
    aaaa -> inet6
  end,
  try inet:gethostbyname(Hostname, InetType) of
    {'ok', #hostent{h_addr_list=AddrList}} ->
      AddrList;
    _ ->
      []
  catch
    _:_ ->
      []
  end.

try_connect(Ipv6Addrs, Port, Opts, Timeout, Self) ->
  try_connect(Ipv6Addrs, Port, Opts, Timeout, Self, {error, nxdomain}).

try_connect([], _Port, _Opts, _Timeout, _ServerPid, LastError) ->
  ?report_trace("happy eyeball: failed to connect", [{error, LastError}]),
  exit(LastError);
try_connect([{IP, Type} | Rest], Port, Opts, Timeout, ServerPid, _LastError) ->
  ?report_trace("try to connect", [{ip, IP}, {type, Type}]),
  case gen_tcp:connect(IP, Port, [Type | Opts], Timeout) of
    {ok, Socket} = OK ->
      ?report_trace("success to connect", [{ip, IP}, {type, Type}]),
      case gen_tcp:controlling_process(Socket, ServerPid) of
        ok ->
          exit({happy_connect, OK});
        {error, Reason} ->
          ?report_trace("controlling_process failed", [{error, Reason}]),
          _ = gen_tcp:close(Socket),
          try_connect(Rest, Port, Opts, Timeout, ServerPid, {error, Reason})
      end;
    Error ->
      try_connect(Rest, Port, Opts, Timeout, ServerPid, Error)
  end.

%%====================================================================
%% UDP Happy Eyeballs (for QUIC/HTTP3)
%%====================================================================

%% @doc Connect via UDP using happy eyeballs algorithm.
%% Returns {ok, Socket, RemoteAddr} where RemoteAddr is {IP, Port}.
connect_udp(Hostname, Port, Opts) ->
  connect_udp(Hostname, Port, Opts, ?CONNECT_TIMEOUT).

connect_udp(Hostname, Port, Opts, Timeout) ->
  do_connect_udp(parse_address(Hostname), Port, Opts, Timeout).

do_connect_udp(Hostname, Port, Opts, _Timeout) when is_tuple(Hostname) ->
  case hackney_cidr:is_ipv6(Hostname) of
    true ->
      try_udp_connect(Hostname, Port, inet6, Opts);
    false ->
      case hackney_cidr:is_ipv4(Hostname) of
        true ->
          try_udp_connect(Hostname, Port, inet, Opts);
        false ->
          {error, nxdomain}
      end
  end;
do_connect_udp(Hostname, Port, Opts, Timeout) ->
  Self = self(),
  case getaddrs(Hostname) of
    {[], []} -> {error, nxdomain};
    {[], IPv4Addrs} ->
      {Pid4, MRef4} = spawn_monitor(fun() -> try_udp_list(IPv4Addrs, Port, Opts, Self) end),
      do_udp_wait(Pid4, MRef4, Timeout);
    {Ipv6Addrs, []} ->
      {Pid6, MRef6} = spawn_monitor(fun() -> try_udp_list(Ipv6Addrs, Port, Opts, Self) end),
      do_udp_wait(Pid6, MRef6, Timeout);
    {Ipv6Addrs, IPv4Addrs} ->
      {Pid6, MRef6} = spawn_monitor(fun() -> try_udp_list(Ipv6Addrs, Port, Opts, Self) end),
      TRef = erlang:start_timer(?TIMEOUT, self(), try_ipv4),
      receive
        {'DOWN', MRef6, _, _, {happy_connect, OK}} ->
          _ = erlang:cancel_timer(TRef, []),
          OK;
        {'DOWN', MRef6, _, _, _} ->
          _ = erlang:cancel_timer(TRef, []),
          {Pid4, MRef4} = spawn_monitor(fun() -> try_udp_list(IPv4Addrs, Port, Opts, Self) end),
          do_udp_wait(Pid4, MRef4, Timeout);
        {timeout, TRef, try_ipv4} ->
          PidRef4 = spawn_monitor(fun() -> try_udp_list(IPv4Addrs, Port, Opts, Self) end),
          do_udp_race(PidRef4, {Pid6, MRef6}, Timeout)
      after Timeout ->
        _ = erlang:cancel_timer(TRef, []),
        erlang:demonitor(MRef6, [flush]),
        {error, connect_timeout}
      end
  end.

do_udp_wait(Pid, MRef, Timeout) ->
  receive
    {'DOWN', MRef, _, _, {happy_connect, OK}} -> OK;
    {'DOWN', MRef, _, _, {error, _} = E} -> E;
    {'DOWN', MRef, _, _, Info} -> {error, Info}
  after Timeout ->
    connect_gc(Pid, MRef),
    {error, connect_timeout}
  end.

do_udp_race({Pid4, MRef4}, {Pid6, MRef6}, Timeout) ->
  receive
    {'DOWN', MRef4, _, _, {happy_connect, OK}} ->
      connect_gc(Pid6, MRef6), OK;
    {'DOWN', MRef6, _, _, {happy_connect, OK}} ->
      connect_gc(Pid4, MRef4), OK;
    {'DOWN', MRef4, _, _, _} ->
      do_udp_wait(Pid6, MRef6, Timeout);
    {'DOWN', MRef6, _, _, _} ->
      do_udp_wait(Pid4, MRef4, Timeout)
  after Timeout ->
    connect_gc(Pid4, MRef4),
    connect_gc(Pid6, MRef6),
    {error, connect_timeout}
  end.

try_udp_list(Addrs, Port, Opts, ServerPid) ->
  try_udp_list_1(Addrs, Port, Opts, ServerPid, {error, nxdomain}).

try_udp_list_1([], _Port, _Opts, _ServerPid, LastError) ->
  exit(LastError);
try_udp_list_1([{IP, Type} | Rest], Port, Opts, ServerPid, _LastError) ->
  case try_udp_connect(IP, Port, Type, Opts) of
    {ok, Socket, RemoteAddr} ->
      %% Transfer socket ownership to parent process before exiting
      case gen_udp:controlling_process(Socket, ServerPid) of
        ok ->
          exit({happy_connect, {ok, Socket, RemoteAddr}});
        {error, Reason} ->
          gen_udp:close(Socket),
          try_udp_list_1(Rest, Port, Opts, ServerPid, {error, Reason})
      end;
    Error ->
      try_udp_list_1(Rest, Port, Opts, ServerPid, Error)
  end.

try_udp_connect(IP, Port, Type, Opts) ->
  UdpOpts = [binary, {active, false}, Type | proplists:delete(inet, proplists:delete(inet6, Opts))],
  case gen_udp:open(0, UdpOpts) of
    {ok, Socket} ->
      case gen_udp:connect(Socket, IP, Port) of
        ok -> {ok, Socket, {IP, Port}};
        {error, Reason} ->
          gen_udp:close(Socket),
          {error, Reason}
      end;
    {error, _} = Error -> Error
  end.
