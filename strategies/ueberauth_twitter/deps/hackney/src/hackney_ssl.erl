%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>

-module(hackney_ssl).
-compile({parse_transform, ct_expand}).

-export([messages/1,
  connect/3, connect/4,
  recv/3, recv/2,
  send/2,
  setopts/2,
  controlling_process/2,
  peername/1,
  close/1,
  shutdown/2,
  sockname/1]).

-export([check_hostname_opts/1]).
-export([cipher_opts/0]).

%% @doc Atoms used to identify messages in {active, once | true} mode.
messages(_) -> {ssl, ssl_closed, ssl_error}.




check_hostname_opts(Host0) ->
  Host1 = string_compat:strip(Host0, right, $.),
  VerifyFun = {
    fun ssl_verify_hostname:verify_fun/3,
    [{check_hostname, Host1}]
   },
  SslOpts = [{verify, verify_peer},
             {depth, 100},
             {cacerts, certifi:cacerts()},
             {partial_chain, fun partial_chain/1},
             {verify_fun, VerifyFun}],

  check_hostname_opt(Host1, server_name_indication_opt(Host1, SslOpts)).

-ifdef(buggy_chacha_ciphers).
cipher_opts() ->
    % Workaround for buggy ChaCha cipher in OTP 20, which breaks connectivity sometimes.
    % See: https://bugs.erlang.org/browse/ERL-538
    ct_expand:term(
      (fun () ->
               % This will be evaluated at compile time
               TLSVersionsInfo = ssl:versions(),
               {_, SupportedTLSVersions} = lists:keyfind(supported, 1, TLSVersionsInfo),
               DefaultCipherSuitesPerTLSVersion = [ssl:cipher_suites(default, TLSVersion)
                                                   || TLSVersion <- SupportedTLSVersions],
               DefaultCipherSuites = lists:flatten(DefaultCipherSuitesPerTLSVersion),
               CipherFilter = fun (Cipher) -> Cipher =/= chacha20_poly1305 end,
               Ciphers = ssl:filter_cipher_suites(DefaultCipherSuites, [{cipher, CipherFilter}]),
               [{ciphers, Ciphers}]
       end)()
     ).
-else.
cipher_opts() ->
    [].
-endif.

-ifdef(no_customize_hostname_check).
check_hostname_opt(_Host, Opts) ->
  Opts.
-else.
check_hostname_opt(_Host, Opts) ->
  MatchFun = public_key:pkix_verify_hostname_match_fun(https),
  [{customize_hostname_check, [{match_fun, MatchFun}]} | Opts].
-endif.


-ifdef(no_proxy_sni_support).
server_name_indication_opt(_Host, Opts) -> Opts.
-else.
server_name_indication_opt(Host, Opts) ->
  [{server_name_indication, Host} | Opts].
-endif.

%% code from rebar3 undert BSD license
partial_chain(Certs) ->
  Certs1 = lists:reverse([{Cert, public_key:pkix_decode_cert(Cert, otp)} ||
                          Cert <- Certs]),
  case find(fun({_, Cert}) ->
                check_cert(decoded_cacerts(), Cert)
            end, Certs1) of
    {ok, Trusted} ->
      {trusted_ca, element(1, Trusted)};
    _ ->
      unknown_ca
  end.


%% instead of parsing every time, compile this list at runtime
decoded_cacerts() ->
  ct_expand:term(
    lists:foldl(fun(Cert, Acc) ->
                    Dec = public_key:pkix_decode_cert(Cert, otp),
                    [hackney_ssl_certificate:public_key_info(Dec) | Acc]
                end, [], certifi:cacerts())
   ).


check_cert(CACerts, Cert) ->
  PublicKeyInfo = hackney_ssl_certificate:public_key_info(Cert),
  lists:member(PublicKeyInfo, CACerts).


-spec find(fun(), list()) -> {ok, term()} | error.
find(Fun, [Head|Tail]) when is_function(Fun) ->
  case Fun(Head) of
    true ->
      {ok, Head};
    false ->
      find(Fun, Tail)
  end;
find(_Fun, []) ->
  error.


connect(Host, Port, Opts) ->
  connect(Host, Port, Opts, 30000).

connect(Host, Port, Opts0, Timeout) when is_list(Host), is_integer(Port),
                                        (Timeout =:= infinity orelse is_integer(Timeout)) ->
  SSLOpts = proplists:get_value(ssl_options, Opts0),
  BaseOpts = [binary, {active, false}, {packet, raw}],
  Opts1 = hackney_util:merge_opts(BaseOpts, proplists:delete(ssl_options, Opts0)),
  case hackney_happy:connect(Host, Port, Opts1, Timeout) of
    {ok, Sock} ->
      ssl:connect(Sock, SSLOpts);
    Error ->
      Error
  end.

recv(Socket, Length) ->
  recv(Socket, Length, infinity).

%% @doc Receive a packet from a socket in passive mode.
%% @see ssl:recv/3
-spec recv(ssl:sslsocket(), non_neg_integer(), timeout())
    -> {ok, any()} | {error, closed | atom()}.
recv(Socket, Length, Timeout) ->
  ssl:recv(Socket, Length, Timeout).

%% @doc Send a packet on a socket.
%% @see ssl:send/2
-spec send(ssl:sslsocket(), iolist()) -> ok | {error, atom()}.
send(Socket, Packet) ->
  ssl:send(Socket, Packet).

%% @doc Set one or more options for a socket.
%% @see ssl:setopts/2
-spec setopts(ssl:sslsocket(), list()) -> ok | {error, atom()}.
setopts(Socket, Opts) ->
  ssl:setopts(Socket, Opts).

%% @doc Assign a new controlling process <em>Pid</em> to <em>Socket</em>.
%% @see ssl:controlling_process/2
-spec controlling_process(ssl:sslsocket(), pid())
    -> ok | {error, closed | not_owner | atom()}.
controlling_process(Socket, Pid) ->
  ssl:controlling_process(Socket, Pid).

%% @doc Return the address and port for the other end of a connection.
%% @see ssl:peername/1
-spec peername(ssl:sslsocket()) ->
  {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
peername(Socket) ->
  ssl:peername(Socket).

%% @doc Close a TCP socket.
%% @see ssl:close/1
-spec close(ssl:sslsocket()) -> ok.
close(Socket) ->
  ssl:close(Socket).

%% @doc Immediately close a socket in one or two directions.
%% @see ssl:shutdown/2
-spec shutdown(ssl:sslsocket(), read | write | read_write) -> ok | {error, any()}.
shutdown(Socket, How) ->
  ssl:shutdown(Socket, How).

%% @doc Get the local address and port of a socket
%% @see ssl:sockname/1
-spec sockname(ssl:sslsocket())
    -> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
sockname(Socket) ->
  ssl:sockname(Socket).
