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
  peercert/1,
  close/1,
  shutdown/2,
  sockname/1]).

-export([check_hostname_opts/1]).
-export([cipher_opts/0]).
-export([ssl_opts/2]).
-export([effective_opts/3]).
-export([effective_opts_and_key/3]).
-export([init_key_cache/0]).
-export([options_key/1]).
-export([h3_options_key/2]).

-define(TLS_KEY_CACHE, hackney_tls_keys).
-define(TLS_KEY_CACHE_MAX, 512).

%% Per {Host, advertised-ALPN} memo of the protocol learned on a full handshake,
%% so a resumed TLS session (where ssl:negotiated_protocol/1 reports nothing) is
%% labeled correctly. See resolve_alpn/5 and the resumption gate in hackney_conn.
-define(ALPN_CACHE, hackney_alpn_protocols).
-define(ALPN_CACHE_MAX, 4096).

%% ALPN (Application-Layer Protocol Negotiation) for HTTP/2
-export([alpn_opts/1]).
-export([get_negotiated_protocol/1]).
-export([negotiated_protocol/5, resolve_alpn/6, recall_alpn/2, auto_tickets/1]).

%% @doc Atoms used to identify messages in {active, once | true} mode.
messages(_) -> {ssl, ssl_closed, ssl_error}.

%% @doc Build SSL options for a connection.
%% Used by proxy modules for SSL upgrade after tunnel establishment.
ssl_opts(Host, Options) ->
  case proplists:get_value(ssl_options, Options) of
    undefined ->
      ssl_opts_1(Host, Options);
    [] ->
      ssl_opts_1(Host, Options);
    SSLOpts ->
      merge_ssl_opts(Host, SSLOpts, Options)
  end.

ssl_opts_1(Host, Options) ->
  Insecure = proplists:get_value(insecure, Options, false),
  case Insecure of
    true ->
      [{verify, verify_none} | cipher_opts()];
    false ->
      check_hostname_opts(Host) ++ cipher_opts()
  end.

merge_ssl_opts(Host, OverrideOpts, Options) ->
  %% Verify against the chosen SNI: a user hostname wins, `disable' and no
  %% SNI both verify against Host. effective_opts no longer prepends a
  %% duplicate SNI, so the wire SNI and the verify target now agree.
  VerifyHost = case proplists:get_value(server_name_indication, OverrideOpts) of
    undefined -> Host;
    disable -> Host;
    SNI -> SNI
  end,
  %% Check insecure from top-level Options first, then fall back to ssl_options (fixes #786)
  Insecure = proplists:get_value(insecure, Options,
               proplists:get_value(insecure, OverrideOpts, false)),
  DefaultOpts = case Insecure of
    true ->
      [{verify, verify_none} | cipher_opts()];
    false ->
      check_hostname_opts(VerifyHost) ++ cipher_opts()
  end,
  MergedOpts = orddict:merge(fun(_K, _V1, V) -> V end,
                             orddict:from_list(DefaultOpts),
                             orddict:from_list(OverrideOpts)),
  %% If cacertfile was provided in override opts remove cacerts
  MergedOpts1 = case lists:keymember(cacertfile, 1, MergedOpts) of
    true ->
      lists:keydelete(cacerts, 1, MergedOpts);
    false ->
      MergedOpts
  end,
  %% hackney's partial_chain accepts any cert in the peer chain whose key
  %% matches a certifi root as the trust anchor, and OTP honours that over
  %% the configured CA set. Keep it only for hackney's own trust store: a
  %% caller who pins cacerts/cacertfile must not keep trusting the bundled
  %% roots behind their back. A caller-supplied partial_chain is kept.
  CustomCA = lists:keymember(cacerts, 1, OverrideOpts)
    orelse lists:keymember(cacertfile, 1, OverrideOpts),
  case CustomCA andalso not lists:keymember(partial_chain, 1, OverrideOpts) of
    true ->
      lists:keydelete(partial_chain, 1, MergedOpts1);
    false ->
      MergedOpts1
  end.

%% @doc Build the exact options handed to `ssl:connect/2' for an SSL upgrade.
%% SslOpts is the caller's ssl_options, with an optional `{protocols, P}'
%% entry prepended when the request carries one. ConnectOpts is only used
%% as the ALPN fallback when SslOpts yields no ALPN protocols. Computing
%% the final list once, caller-side, lets `options_key/1' hash the same
%% term the handshake uses.
%%
%% Requests on hackney's default TLS config (no user ssl_options) also get
%% `{session_tickets, auto}' for TLS 1.3 session resumption, unless the
%% `tls_session_resumption' application env is set to false or the node
%% pins the ssl app to versions without 'tlsv1.3'. Custom ssl_options
%% deliberately never get resumption: OTP's automatic ticket store is
%% global per node and keyed by SNI, not by trust options, and a
%% PSK-resumed handshake skips certificate validation. Restricting it to
%% the default config means every participant in the store has identical
%% trust, so trust configs cannot cross by construction.
-spec effective_opts(string(), list(), list()) -> list().
effective_opts(Host, SslOpts, ConnectOpts) ->
  %% Resolve SNI once: a user-supplied server_name_indication (a hostname or
  %% `disable') wins; otherwise default to Host, unless Host is an IP literal
  %% (RFC 6066 forbids SNI for IP literals), in which case emit none.
  SslOpts1 = case lists:keymember(server_name_indication, 1, SslOpts) of
    true -> SslOpts;
    false ->
      case hackney_url:is_ip_literal(Host) of
        true -> SslOpts;
        false -> [{server_name_indication, Host} | SslOpts]
      end
  end,
  Merged = ssl_opts(Host, [{ssl_options, SslOpts1}]),
  Alpn = case alpn_opts(SslOpts1) of
    [] -> alpn_opts(ConnectOpts);
    AlpnOpts -> AlpnOpts
  end,
  Final0 = hackney_util:merge_opts(Merged, Alpn),
  %% `protocols' is a hackney option, not an ssl one; keep it out of the
  %% handshake options.
  Final = proplists:delete(protocols, Final0),
  case resumption_allowed(SslOpts) of
    true -> [{session_tickets, auto} | Final];
    false -> Final
  end.

%% @private Resumption only for the default TLS config: the caller injects
%% at most a `protocols' entry, so deleting it leaves [] exactly when the
%% user passed no ssl_options (hence no insecure, versions or
%% session_tickets overrides by construction).
resumption_allowed(SslOpts) ->
  proplists:delete(protocols, SslOpts) =:= []
    andalso hackney_app:get_app_env(tls_session_resumption, true) =:= true
    andalso tlsv13_allowed().

%% @private OTP rejects `session_tickets' when 'tlsv1.3' is not among the
%% effective versions (ssl_config asserts the version dependency), so honor
%% a node-wide ssl `protocol_version' pin that excludes TLS 1.3.
tlsv13_allowed() ->
  case application:get_env(ssl, protocol_version) of
    undefined -> true;
    {ok, 'tlsv1.3'} -> true;
    {ok, Versions} when is_list(Versions) -> lists:member('tlsv1.3', Versions);
    {ok, _} -> false
  end.

%% @doc Create the TLS key memo table used by `effective_opts_and_key/3' and the
%% per-host ALPN memo used by `resolve_alpn/5'. Idempotent; called from
%% hackney_sup:init/1.
-spec init_key_cache() -> ok.
init_key_cache() ->
  ok = ensure_table(?TLS_KEY_CACHE),
  ok = ensure_table(?ALPN_CACHE),
  ok.

ensure_table(Name) ->
  case ets:info(Name) of
    undefined ->
      Name = ets:new(Name, [set, public, named_table, {read_concurrency, true}]),
      ok;
    _ ->
      ok
  end.

%% @doc Like `effective_opts/3' but also return `options_key/1' of the
%% result, memoized in a bounded ETS cache. Building the options is cheap;
%% hashing them is not (sha256 over the full term, dominated by the certifi
%% CA bundle), so only the hash is cached. The memo key is the small
%% pre-merge inputs plus `env_fingerprint/0', so a runtime env flip yields
%% a fresh key instead of hashing connections into wrong pool buckets.
-spec effective_opts_and_key(string(), list(), list()) -> {list(), binary()}.
effective_opts_and_key(Host, SslOpts, ConnectOpts) ->
  Final = effective_opts(Host, SslOpts, ConnectOpts),
  MemoKey = {Host, SslOpts, ConnectOpts, env_fingerprint()},
  try
    case ets:lookup(?TLS_KEY_CACHE, MemoKey) of
      [{_, Key}] ->
        {Final, Key};
      [] ->
        Key = options_key(Final),
        %% The bound is soft under concurrency; the cache is best-effort.
        case ets:info(?TLS_KEY_CACHE, size) >= ?TLS_KEY_CACHE_MAX of
          true -> _ = ets:delete_all_objects(?TLS_KEY_CACHE);
          false -> ok
        end,
        _ = ets:insert(?TLS_KEY_CACHE, {MemoKey, Key}),
        {Final, Key}
    end
  catch
    %% Table absent: hackney used as a library without the app started.
    error:badarg ->
      {Final, options_key(Final)}
  end.

%% @private Invariant: this tuple must cover every mutable read inside
%% effective_opts/3 (default_protocols via alpn_opts, the
%% tls_session_resumption env via resumption_allowed, the ssl
%% protocol_version env via tlsv13_allowed). Extend it whenever
%% effective_opts/3 grows a new env read, or stale keys get served.
env_fingerprint() ->
  {hackney_util:default_protocols(),
   hackney_app:get_app_env(tls_session_resumption, true),
   application:get_env(ssl, protocol_version, undefined)}.

%% @doc Hash the effective TLS options into a pool key component.
%% 2-tuples are ukeysorted (first occurrence wins, preserving proplists
%% lookup semantics) so option order does not change the key, while
%% conflicting duplicates such as `[{verify,A},{verify,B}]' and its
%% reverse still hash differently.
%%
%% `session_tickets' is excluded (like the HTTP/3 key excludes `session_ticket'):
%% it is identity-neutral (does not affect trust) and the handshake now varies it
%% per the ALPN resumption gate, so it must not change the pool bucket.
-spec options_key(list()) -> binary().
options_key(FinalSslOpts0) ->
  FinalSslOpts = proplists:delete(session_tickets, FinalSslOpts0),
  {Tuples, Rest} = lists:partition(
    fun(T) -> is_tuple(T) andalso tuple_size(T) =:= 2 end,
    FinalSslOpts),
  crypto:hash(sha256, term_to_binary({lists:ukeysort(1, Tuples), lists:usort(Rest)})).

%% @doc Hash the QUIC trust projection of an HTTP/3 connection into a pool
%% key component. Includes exactly what decides server trust on the QUIC
%% handshake, mirroring hackney_conn's h3_tls_opts/2: the verify mode
%% derived from the `insecure' flag (read from ConnectOpts first, then
%% SslOpts) and the CA source from SslOpts (the `cacerts' list, else the
%% `cacertfile' path, else the default trust store). The cacertfile path is
%% hashed as given, without reading the file. Deliberately excluded:
%% `session_ticket' (injected per resumption, so the conn-side store key
%% must not depend on it), and `family' and `happy_eyeballs' (connectivity
%% options that do not affect trust). A user-supplied
%% `server_name_indication' is included so requests to one host:port with
%% different SNI do not share a QUIC connection; the default SNI is the host
%% itself, already part of the outer pool key.
-spec h3_options_key(list(), list()) -> binary().
h3_options_key(ConnectOpts, SslOpts) ->
  Insecure = proplists:get_value(insecure, ConnectOpts,
               proplists:get_value(insecure, SslOpts, false)),
  VerifyMode = case Insecure of
    true -> verify_none;
    false -> verify_peer
  end,
  CaSource = case proplists:get_value(cacerts, SslOpts) of
    undefined ->
      case proplists:get_value(cacertfile, SslOpts) of
        undefined -> default;
        File -> {cacertfile, File}
      end;
    CACerts ->
      {cacerts, CACerts}
  end,
  Sni = proplists:get_value(server_name_indication, SslOpts, default),
  crypto:hash(sha256, term_to_binary({VerifyMode, CaSource, Sni})).

check_hostname_opts(Host0) ->
  Host1 = string:trim(Host0, trailing, "."),
  %% Rewrite cert_expired -> root_cert_expired so OTP's cross-sign recovery
  %% (find_cross_sign_root_paths/4) triggers; ssl_verify_hostname returns
  %% cert_expired verbatim, which bypasses it entirely.
  VerifyFun = {
    fun(_Cert, {bad_cert, cert_expired}, _State) ->
            {fail, {bad_cert, root_cert_expired}};
       (Cert, Event, State) ->
            ssl_verify_hostname:verify_fun(Cert, Event, State)
    end,
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
  case hackney_url:is_ip_literal(Host) of
    true -> Opts;
    false -> [{server_name_indication, Host} | Opts]
  end.
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
  Now = erlang:monotonic_time(millisecond),
  case hackney_happy:connect(Host, Port, Opts1, Timeout) of
    {ok, Sock} ->
      case Timeout of
        infinity ->
          ssl:connect(Sock, SSLOpts);
        _ ->
          Elapsed = erlang:monotonic_time(millisecond) - Now,
          case Timeout - Elapsed of
            TimeoutLeft when TimeoutLeft > 0 ->
              ssl:connect(Sock, SSLOpts, TimeoutLeft);
            _ ->
              gen_tcp:close(Sock),
              {error, timeout}
          end
      end;
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

%% @doc Return the peer certificate of an SSL connection.
%% @see ssl:peercert/1
-spec peercert(ssl:sslsocket()) ->
  {ok, binary()} | {error, atom()}.
peercert(Socket) ->
  ssl:peercert(Socket).

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

%%====================================================================
%% ALPN (Application-Layer Protocol Negotiation) for HTTP/2
%%====================================================================

%% @doc Generate ALPN options for SSL connection.
%% Returns a list containing alpn_advertised_protocols option based on
%% the protocols specified in Options.
%%
%% Options:
%%   - protocols: list of atoms [http3, http2, http1] (default: [http2, http1])
%%     Order matters - first protocol is preferred
%%     Note: http3 is only used for informational purposes here - HTTP/3 uses
%%     QUIC which has its own ALPN negotiation handled by hackney_http3.
%%
%% Example:
%% ```
%% alpn_opts([{protocols, [http2, http1]}]) ->
%%     [{alpn_advertised_protocols, [<<"h2">>, <<"http/1.1">>]}]
%% '''
-spec alpn_opts(list()) -> list().
alpn_opts(Opts) ->
  case proplists:get_value(protocols, Opts, hackney_util:default_protocols()) of
    Protos when is_list(Protos), Protos =/= [] ->
      %% Filter out http3 - it doesn't use TLS ALPN
      TlsProtos = [P || P <- Protos, P =/= http3],
      case TlsProtos of
        [] -> [];
        _ ->
          AlpnProtos = [proto_to_alpn(P) || P <- TlsProtos],
          [{alpn_advertised_protocols, AlpnProtos}]
      end;
    _ ->
      []
  end.

%% @doc Get the negotiated protocol after SSL handshake.
%% Returns http2 if HTTP/2 was negotiated, http1 otherwise.
%% Note: HTTP/3 is not returned here as it uses QUIC, not TLS.
%% @see ssl:negotiated_protocol/1
-spec get_negotiated_protocol(ssl:sslsocket()) -> http2 | http1.
get_negotiated_protocol(SslSocket) ->
  case ssl:negotiated_protocol(SslSocket) of
    {ok, <<"h2">>} -> http2;
    {ok, <<"http/1.1">>} -> http1;
    {error, protocol_not_negotiated} -> http1;
    _ -> http1
  end.

%% @doc Resolve the negotiated protocol after a handshake, carrying the ALPN memo
%% across TLS resumption. On a resumed session ssl:negotiated_protocol/1 reports
%% nothing, so we fall back to `Cached' (snapshotted before the handshake), but
%% only when the session actually resumed - a full handshake that reports no ALPN
%% is a genuine HTTP/1 conn. `Cached' is `recall_alpn(Host, AlpnProtos)' read at
%% the resumption gate. `Resumable' is whether this conn is tied to the resumable
%% ticket source (hackney enabled session_tickets); only then is the memo written,
%% so a custom-ssl_options handshake that does not seed the ticket store cannot
%% poison the shared `{Host, AlpnProtos}' entry a later resumed session reads.
-spec negotiated_protocol(ssl:sslsocket(), string(), list(),
                          http2 | http1 | none, boolean()) -> http2 | http1.
negotiated_protocol(SslSocket, Host, AlpnProtos, Cached, Resumable) ->
  resolve_alpn(ssl:negotiated_protocol(SslSocket), resumed(SslSocket),
               Cached, Host, AlpnProtos, Resumable).

%% @doc Pure ALPN decision (exported for tests). See negotiated_protocol/5.
-spec resolve_alpn({ok, binary()} | {error, term()}, boolean(),
                   http2 | http1 | none, string(), list(), boolean()) ->
  http2 | http1.
resolve_alpn({ok, <<"h2">>}, _Resumed, _Cached, Host, AlpnProtos, Resumable) ->
  maybe_remember(Resumable, Host, AlpnProtos, http2),
  http2;
resolve_alpn({ok, <<"http/1.1">>}, _Resumed, _Cached, Host, AlpnProtos, Resumable) ->
  maybe_remember(Resumable, Host, AlpnProtos, http1),
  http1;
resolve_alpn({error, protocol_not_negotiated}, true, Cached, _Host, _AlpnProtos, _Resumable)
  when Cached =/= none ->
  %% Genuinely resumed: ALPN is not re-reported, use the gate-time snapshot.
  Cached;
resolve_alpn({error, protocol_not_negotiated}, false, _Cached, Host, AlpnProtos, Resumable) ->
  %% Full handshake with no ALPN: a real HTTP/1 conn. Refresh the memo (only for
  %% the resumable source) so a stale cached http2 cannot be recalled later.
  maybe_remember(Resumable, Host, AlpnProtos, http1),
  http1;
resolve_alpn(_Other, _Resumed, _Cached, _Host, _AlpnProtos, _Resumable) ->
  %% Defensive: resumed without a snapshot (gate should prevent this) or an
  %% unexpected ssl:negotiated_protocol/1 result.
  http1.

%% @private Write the ALPN memo only for handshakes tied to the resumable ticket
%% source (hackney's default-config resumption). A non-resumable handshake
%% (custom ssl_options) leaves the shared entry untouched.
maybe_remember(true, Host, AlpnProtos, Proto) -> remember_alpn(Host, AlpnProtos, Proto);
maybe_remember(false, _Host, _AlpnProtos, _Proto) -> ok.

%% @doc Whether the effective opts carry hackney's automatic TLS resumption
%% (`{session_tickets, auto}'), which `effective_opts/3' adds only for the
%% resumable default config. Only such connections are tied to that ticket source
%% and may update the ALPN memo; a caller-supplied `disabled' or `manual' tickets
%% entry is not memo-eligible and must not overwrite the shared entry.
-spec auto_tickets(list()) -> boolean().
auto_tickets(SslOpts) ->
  lists:member({session_tickets, auto}, SslOpts).

%% @doc Whether the TLS handshake resumed a session (PSK / abbreviated handshake).
-spec resumed(ssl:sslsocket()) -> boolean().
resumed(SslSocket) ->
  case ssl:connection_information(SslSocket, [session_resumption]) of
    {ok, [{session_resumption, R}]} -> R =:= true;
    _ -> false
  end.

%% @doc Recall the protocol learned for `{Host, AlpnProtos}' on a full handshake,
%% or `none' if not cached. `AlpnProtos' is the advertised ALPN list in offered
%% order (order is the client's preference and can change negotiation).
-spec recall_alpn(string(), list()) -> http2 | http1 | none.
recall_alpn(Host, AlpnProtos) ->
  try ets:lookup(?ALPN_CACHE, {Host, AlpnProtos}) of
    [{_, Proto}] -> Proto;
    [] -> none
  catch
    %% Table absent: hackney used as a library without the app started.
    error:badarg -> none
  end.

%% @private Cache the protocol for `{Host, AlpnProtos}'. Soft-capped: a generous
%% bound cleared wholesale on overflow. Eviction is not correctness-critical - a
%% cold memo just means the next handshake is full (the gate offers no resumption)
%% and re-learns the protocol.
-spec remember_alpn(string(), list(), http2 | http1) -> ok.
remember_alpn(Host, AlpnProtos, Proto) ->
  try
    case ets:info(?ALPN_CACHE, size) >= ?ALPN_CACHE_MAX of
      true -> _ = ets:delete_all_objects(?ALPN_CACHE);
      false -> ok
    end,
    _ = ets:insert(?ALPN_CACHE, {{Host, AlpnProtos}, Proto}),
    ok
  catch
    error:badarg -> ok
  end.

%% @private Convert protocol atom to ALPN protocol identifier
-spec proto_to_alpn(http2 | http1 | http11) -> binary().
proto_to_alpn(http2) -> <<"h2">>;
proto_to_alpn(http1) -> <<"http/1.1">>;
proto_to_alpn(http11) -> <<"http/1.1">>.
