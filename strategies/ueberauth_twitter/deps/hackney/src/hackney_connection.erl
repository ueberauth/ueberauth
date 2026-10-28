%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information

-module(hackney_connection).


-export([new/1,
         get_property/2,
         is_ssl/1]).


%% helpers
-export([controlling_process/3]).
-export([setopts/3]).
-export([sync_socket/2]).
-export([connect/3]).
-export([close/2]).

-export([connect_options/3]).
-export([ssl_opts/2]).
-export([merge_ssl_opts/2]).

-include("hackney.hrl").


new(#client{transport=Transport,
            host=Host0,
            port=Port,
            options=ClientOptions}) ->
  Host1 = string_compat:to_lower(Host0),
  ConnectOptions = connect_options(Transport, Host1, ClientOptions),
  Tunnel = maybe_tunnel(Transport),
  Id = new_connection_id(Transport, Host1, Port, ConnectOptions),
  Connection = new_connection_r(Transport, Host1, Port, Id, Tunnel),
  {Connection, ConnectOptions}.

get_property(transport, #connection{transport=Transport}) -> Transport;
get_property(host, #connection{host=Host}) -> Host;
get_property(port, #connection{port=Port}) -> Port;
get_property(id, #connection{id=Id}) -> Id;
get_property(_, _) -> erlang:error(badarg).


is_ssl(#connection{transport=hackney_ssl}) -> true;
is_ssl(#connection{}) -> false;
is_ssl(_) -> erlang:error(badarg).

controlling_process(#connection{transport=Transport}, Socket, Owner) ->
  Transport:controlling_process(Socket, Owner).


setopts(#connection{transport=Transport}, Socket, Opts) ->
  Transport:setopts(Socket, Opts).


%% check that no events from the sockets is received after setting it to
%% passive.
sync_socket(#connection{transport=Transport}, Socket) ->
  {Msg, MsgClosed, MsgError} = Transport:messages(Socket),
  receive
    {Msg, Socket, _} -> false;
    {MsgClosed, Socket} -> false;
    {MsgError, Socket, _} -> false
  after 0 ->
          true
  end.


connect(#connection{transport=Transport,
                    host=Host,
                    port=Port}, ConnectOptions, Timeout) ->
  Transport:connect(Host, Port, ConnectOptions, Timeout).


close(#connection{transport=Transport}, Socket) ->
  Transport:close(Socket).


new_connection_id(Transport, Host, Port, ConnectionOptions) ->
  Key = {Transport, Host, Port, ConnectionOptions},
  case hackney_connections:lookup(Key) of
    {ok, Id} ->
      Id;
    error ->
      Id = erlang:phash2(Key),
      hackney_connections:insert(Key, Id),
      Id
  end.


new_connection_r(Transport, Host, Port, Id, Tunnel) ->
  #connection{transport=Transport,
              host=Host,
              port=Port,
              id=Id,
              tunnel=Tunnel}.


connect_options(hackney_local_tcp, _Host, ClientOptions) ->
  proplists:get_value(connect_options, ClientOptions, []);

connect_options(Transport, Host, ClientOptions) ->
  ConnectOpts = proplists:get_value(connect_options, ClientOptions, []),

  case Transport of
    hackney_ssl ->
      [{ssl_options, ssl_opts(Host, ClientOptions)} | ConnectOpts];
    _ ->
      ConnectOpts
  end.


ssl_opts(Host, Options) ->
  case proplists:get_value(ssl_options, Options) of
    undefined ->
      ssl_opts_1(Host, Options);
    [] ->
      ssl_opts_1(Host, Options);
    SSLOpts ->
      merge_ssl_opts(Host, SSLOpts)
  end.

ssl_opts_1(Host, Options) ->
  Insecure =  proplists:get_value(insecure, Options, false),
  case Insecure of
    true ->
      [{verify, verify_none} | ssl_opts_2()];
    false ->
      hackney_ssl:check_hostname_opts(Host) ++ ssl_opts_2()
  end.

ssl_opts_2() ->
  hackney_ssl:cipher_opts().

merge_ssl_opts(Host, OverrideOpts) ->
  DefaultOpts = ssl_opts_1(Host, OverrideOpts),
  MergedOpts = orddict:merge(fun(_K, _V1, V) -> V end,
                             orddict:from_list(DefaultOpts),
                             orddict:from_list(OverrideOpts)),
  %% If cacertfile was provided in override opts remove cacerts
  case lists:keymember(cacertfile, 1, MergedOpts) of
    true ->
      lists:keydelete(cacerts, 1, MergedOpts);
    false ->
      MergedOpts
  end.

maybe_tunnel(hackney_http_connect) ->
  true;
maybe_tunnel(_) ->
  false.
