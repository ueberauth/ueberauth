%%% -*- erlang -*-
%%%
%%% QUIC Distribution Module
%%% Erlang Distribution over QUIC (RFC 9000)
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Erlang distribution protocol implementation over QUIC.
%%%
%%% This module implements the Erlang distribution protocol callbacks
%%% using QUIC as the transport layer. It provides:
%%%
%%% - Connection establishment via TLS 1.3 (built into QUIC)
%%% - Multiple streams for parallel message delivery
%%% - Head-of-line blocking avoidance
%%% - Connection migration for NAT traversal
%%% - 0-RTT reconnection for fast session resumption
%%%
%%% == Configuration ==
%%%
%%% Enable QUIC distribution in vm.args:
%%% ```
%%% -proto_dist quic
%%% -epmd_module quic_epmd
%%% -start_epmd false
%%% '''
%%%
%%% Configure in sys.config:
%%% ```
%%% {quic, [
%%%   {dist, [
%%%     {cert_file, "/path/to/cert.pem"},
%%%     {key_file, "/path/to/key.pem"},
%%%     {cacert_file, "/path/to/ca.pem"},
%%%     {verify, verify_peer}
%%%   ]}
%%% ]}
%%% '''
%%%
%%% @end

-module(quic_dist).

-include("quic.hrl").
-include("quic_dist.hrl").
-include_lib("kernel/include/dist_util.hrl").
-include_lib("kernel/include/net_address.hrl").

%% Dialyzer suppressions:
%% - accept_connection: handshake functions have complex control flow
-dialyzer({nowarn_function, [accept_connection/5]}).

%% Distribution module callbacks
-export([
    listen/1,
    listen/2,
    accept/1,
    accept_connection/5,
    setup/5,
    close/1,
    select/1,
    address/0,
    is_node_name/1
]).

%% User stream API
-export([
    open_stream/1,
    open_stream/2,
    send/2,
    send/3,
    close_stream/1,
    reset_stream/1,
    reset_stream/2,
    accept_streams/1,
    stop_accepting/1,
    controlling_process/2,
    list_streams/0,
    list_streams/1,
    get_controller/1
]).

%% Keep-alive cadence derivation (exported for testing the net_ticktime logic)
-export([keep_alive_interval/0, keep_alive_interval_for/1]).

%% Types
-export_type([stream_ref/0, stream_info/0, stream_opt/0]).

-type stream_ref() :: {quic_dist_stream, node(), non_neg_integer()}.
-type stream_opt() :: {priority, 16..255}.
-type stream_info() :: #{
    ref => stream_ref(),
    node => node(),
    stream_id => non_neg_integer(),
    owner => pid(),
    priority => 16..255,
    recv_fin => boolean(),
    send_fin => boolean()
}.

%% Internal exports
-export([
    acceptor_loop/2,
    do_setup/6,
    notify_acceptor/1
]).

-type auth_callback() ::
    {module(), atom()}
    | fun((pid(), client | server, timeout()) -> {ok, term()} | {error, term()}).

-export_type([auth_callback/0]).

%% Per-node connect-time option overrides
-export([
    set_connect_options/2,
    get_connect_options/1,
    clear_connect_options/1
]).

%%====================================================================
%% Distribution Module Callbacks
%%====================================================================

%% @doc Check if this distribution module should be used for the given node.
%% Returns true if the node name is valid and we can potentially connect.
-spec select(node()) -> boolean().
select(Node) ->
    case dist_util:split_node(Node) of
        {node, Name, Host} ->
            %% Try to resolve address via EPMD module
            EpmdMod = net_kernel:epmd_module(),
            try EpmdMod:address_please(Name, Host, inet) of
                {ok, _Addr} ->
                    true;
                {ok, _Addr, _Port, _Version} ->
                    true;
                _ ->
                    true
            catch
                %% Even if address lookup fails, allow local connections.
                %% This is needed during initial node startup.
                _:_ ->
                    true
            end;
        _ ->
            false
    end.

%% @doc Check if a node name is valid.
-spec is_node_name(atom()) -> boolean().
is_node_name(Node) when is_atom(Node) ->
    case split_node(atom_to_list(Node), $@, []) of
        [_, _Host] -> true;
        _ -> false
    end;
is_node_name(_) ->
    false.

%% @private
%% Split node name on separator character.
split_node([Sep | Rest], Sep, Acc) ->
    [lists:reverse(Acc) | split_node(Rest, Sep, [])];
split_node([C | Rest], Sep, Acc) ->
    split_node(Rest, Sep, [C | Acc]);
split_node([], _Sep, Acc) ->
    [lists:reverse(Acc)].

%% @doc Return the address family to use.
-spec address() -> #net_address{}.
address() ->
    {ok, Host} = inet:gethostname(),
    #net_address{
        host = Host,
        protocol = quic,
        family = inet
    }.

%% @doc Start listening for incoming distribution connections.
-spec listen(Name :: atom()) ->
    {ok, {LSocket :: term(), TcpAddress :: term(), Creation :: non_neg_integer()}}
    | {error, Reason :: term()}.
listen(Name) ->
    listen(Name, #{}).

%% @doc Start listening with options.
-spec listen(Name :: atom(), Opts :: map()) ->
    {ok, {LSocket :: term(), TcpAddress :: term(), Creation :: non_neg_integer()}}
    | {error, Reason :: term()}.
listen(Name, ExtraOpts) ->
    %% Ensure quic application is started - distribution callbacks run
    %% very early, before -eval or application start
    case ensure_quic_started() of
        ok ->
            Config = load_config(),
            Port = get_listen_port(),
            case start_quic_server(Name, Port, Config, ExtraOpts) of
                {ok, ServerName, ActualPort} ->
                    Listener = #quic_dist_listener{
                        server_name = ServerName,
                        port = ActualPort,
                        config = Config
                    },
                    Address = #net_address{
                        address = {{0, 0, 0, 0}, ActualPort},
                        host = localhost,
                        family = inet,
                        protocol = quic
                    },
                    case resolve_creation(Name, ActualPort, Config) of
                        {ok, Creation} ->
                            {ok, {Listener, Address, Creation}};
                        {error, EpmdReason} ->
                            close(Listener),
                            {error, EpmdReason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% Resolve the creation number. Either a synthetic one (default), or the
%% one returned by registering with the configured epmd_module so that
%% external tooling (e.g. `epmd -names') can find this node.
resolve_creation(Name, _Port, #quic_dist_config{register_with_epmd = false}) ->
    {ok, get_creation(Name)};
resolve_creation(Name, Port, #quic_dist_config{
    register_with_epmd = true,
    discovery_module = DiscoveryModule
}) ->
    %% quic_discovery dispatches via erlang:function_exported/3, which
    %% only sees exports of *loaded* modules. listen/1 runs before the
    %% normal application boot, so force the discovery backend in now.
    _ = code:ensure_loaded(DiscoveryModule),
    NameStr =
        case Name of
            N when is_atom(N) -> atom_to_list(N);
            N when is_list(N) -> N
        end,
    EpmdMod = net_kernel:epmd_module(),
    case EpmdMod:register_node(NameStr, Port, inet) of
        {ok, Creation} -> {ok, Creation};
        {error, _} = Err -> Err
    end.

%% @doc Accept a connection from the distribution listener.
-spec accept(Listen :: term()) -> AcceptPid :: pid().
accept(#quic_dist_listener{server_name = ServerName} = Listener) ->
    %% Spawn acceptor process that will handle incoming connections
    AcceptorPid = spawn_link(?MODULE, acceptor_loop, [self(), Listener]),
    %% Register acceptor so handle_new_connection can notify it
    persistent_term:put({quic_dist_acceptor, ServerName}, AcceptorPid),
    AcceptorPid.

%% @doc Handle an accepted connection.
%% Called by net_kernel when a new connection is accepted.
-spec accept_connection(
    AcceptPid :: pid(),
    Socket :: term(),
    MyNode :: node(),
    Allowed :: term(),
    SetupTime :: non_neg_integer()
) -> pid().
accept_connection(_AcceptPid, DistCtrl, MyNode, Allowed, SetupTime) ->
    %% self() is net_kernel here - capture before spawning.
    Kernel = self(),
    spawn_opt(
        fun() ->
            %% The controller already owns the QUIC connection (listener
            %% transferred ownership in handle_new_connection), so there
            %% is no socket-handoff rendezvous to wait for. Proceed
            %% straight to the dist handshake - reaching mark_pending
            %% fast is what lets dist_util resolve simultaneous connects.
            %%
            %% Do NOT trap exits: dist_util:start_timer/1 spawns a linked
            %% timer whose exit must kill this process on timeout.
            ok = quic_dist_controller:set_supervisor(DistCtrl, Kernel),
            %% net_kernel resolves a simultaneous connect by killing a
            %% handshake process; the connection has to go with it, or
            %% the peer waits on a read that will never be answered.
            ok = quic_dist_controller:set_handshake_owner(DistCtrl, self()),
            Timer = dist_util:start_timer(SetupTime),
            HSData = create_hs_data(DistCtrl, MyNode, Timer, Allowed, Kernel),
            dist_util:handshake_other_started(HSData)
        end,
        [link, {priority, max}]
    ).

%% @doc Set up an outgoing distribution connection.
%% Called by net_kernel to establish a connection to another node.
-spec setup(
    Node :: node(),
    Type :: atom(),
    MyNode :: node(),
    LongOrShortNames :: shortnames | longnames,
    SetupTime :: non_neg_integer()
) -> pid().
setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    spawn_opt(
        ?MODULE,
        do_setup,
        [self(), Node, Type, MyNode, LongOrShortNames, SetupTime],
        [link, {priority, max}]
    ).

%% @doc Close the distribution listener.
-spec close(Listen :: term()) -> ok.
close(#quic_dist_listener{server_name = ServerName}) ->
    %% First try to stop via supervised server
    try
        quic:stop_server(ServerName)
    catch
        _:_ -> ok
    end,
    %% Also check for early boot standalone listener
    Key = {quic_dist_early_listener, ServerName},
    case persistent_term:get(Key, undefined) of
        undefined ->
            ok;
        #{pid := Pid} ->
            try
                quic_listener:stop(Pid)
            catch
                _:_ -> ok
            end,
            try
                persistent_term:erase(Key)
            catch
                _:_ -> ok
            end,
            ok
    end;
close(_) ->
    ok.

%%====================================================================
%% Internal Functions - Server Setup
%%====================================================================

%% @private
%% Ensure minimal QUIC resources are available for distribution.
%%
%% This function handles the tricky boot sequence:
%% - When using -proto_dist quic, listen/1 is called BEFORE applications start
%% - Calling application:ensure_all_started(quic) would deadlock
%% - Instead, we initialize only the minimal required resources:
%%   1. Ensure crypto is loaded (for TLS operations)
%%   2. Create discovery ETS table (for node lookup)
%%   3. Set early boot flag so start_quic_server uses standalone listener
%%
%% Once boot completes and the quic application starts normally, it will
%% detect and adopt these early boot resources.
ensure_quic_started() ->
    case whereis(quic_sup) of
        Pid when is_pid(Pid) ->
            %% quic application is already running, nothing to do
            ok;
        undefined ->
            %% Early boot - initialize minimal resources without starting app
            ensure_quic_minimal()
    end.

%% @private
%% Minimal initialization for early boot (before quic application starts).
ensure_quic_minimal() ->
    %% Ensure crypto is available - needed for TLS
    case code:ensure_loaded(crypto) of
        {module, crypto} ->
            %% Create discovery ETS table if it doesn't exist
            ensure_discovery_table(),
            %% Mark that we're in early boot mode
            put(quic_dist_early_boot, true),
            ok;
        {error, Reason} ->
            {error, {crypto_not_available, Reason}}
    end.

%% @private
%% Create the discovery ETS table used by quic_discovery_static.
%% This is normally created by quic_sup:init/1.
ensure_discovery_table() ->
    ensure_named_set(quic_discovery_static_nodes).

%% @private
%% Idempotently create a named, public ETS set with read_concurrency.
%% Returns ok regardless of whether the table already existed or was
%% created by a racing process.
ensure_named_set(Name) ->
    case ets:info(Name) of
        undefined ->
            try
                _ = ets:new(
                    Name,
                    [named_table, public, set, {read_concurrency, true}]
                ),
                ok
            catch
                error:badarg ->
                    %% Lost the create race; fine.
                    ok
            end;
        _ ->
            ok
    end.

%% @private
%% Load distribution configuration from command-line args and application environment.
%% Command-line arguments take precedence (using -quic_dist key value format).
load_config() ->
    %% First check init arguments (command line), then fall back to app env
    DistOpts = application:get_env(quic, dist, []),

    #quic_dist_config{
        cert_file = get_init_arg(cert, get_opt(cert_file, DistOpts)),
        key_file = get_init_arg(key, get_opt(key_file, DistOpts)),
        cacert_file = get_init_arg(cacert, get_opt(cacert_file, DistOpts)),
        cert = get_opt(cert, DistOpts),
        key = get_opt(key, DistOpts),
        cacert = get_opt(cacert, DistOpts),
        verify = get_verify_opt(get_opt(verify, DistOpts, verify_none)),
        discovery_module = get_opt(discovery_module, DistOpts, quic_discovery_static),
        nodes = get_opt(nodes, DistOpts, []),
        dns_domain = get_opt(dns_domain, DistOpts),
        lb_enabled = get_opt(lb_enabled, DistOpts, false),
        lb_server_id = get_opt(lb_server_id, DistOpts, auto),
        lb_key = get_opt(lb_key, DistOpts),
        %% Backpressure tuning
        congestion_threshold = get_opt(
            congestion_threshold, DistOpts, ?DEFAULT_QUEUE_CONGESTION_THRESHOLD
        ),
        max_pull_per_notification = get_opt(
            max_pull_per_notification, DistOpts, ?DEFAULT_MAX_PULL_PER_NOTIFICATION
        ),
        backpressure_retry_ms = get_opt(
            backpressure_retry_ms, DistOpts, ?DEFAULT_BACKPRESSURE_RETRY_MS
        ),
        %% Pacing
        pacing_enabled = get_opt(pacing_enabled, DistOpts, true),
        %% Optional post-QUIC, pre-dist auth handshake
        auth_callback = parse_auth_callback(
            get_init_arg(auth_callback, get_opt(auth_callback, DistOpts))
        ),
        auth_handshake_timeout = parse_timeout(
            get_init_arg(auth_handshake_timeout, get_opt(auth_handshake_timeout, DistOpts)),
            10000
        ),
        %% Stock-EPMD registration of the listener port
        register_with_epmd = parse_bool(
            get_init_arg(register_with_epmd, get_opt(register_with_epmd, DistOpts)),
            false
        ),
        %% TLS 1.3 external PSK config (see docs/PSK.md)
        psks = validate_psks(get_opt(psks, DistOpts)),
        psk_callback = parse_psk_callback(
            get_init_arg(psk_callback, get_opt(psk_callback, DistOpts))
        ),
        external_psk = validate_external_psk(get_opt(external_psk, DistOpts))
    }.

%% @private
validate_psks(undefined) ->
    undefined;
validate_psks(Map) when is_map(Map) ->
    %% Require all keys/values to be binaries; reject loudly so
    %% dist startup fails rather than silently dropping the list.
    case
        lists:all(
            fun({K, V}) -> is_binary(K) andalso is_binary(V) end, maps:to_list(Map)
        )
    of
        true -> Map;
        false -> error({bad_config, {psks, malformed_entries}})
    end;
validate_psks(Other) ->
    error({bad_config, {psks, Other}}).

%% @private
validate_external_psk(undefined) ->
    undefined;
validate_external_psk({Id, Secret}) when is_binary(Id), is_binary(Secret) ->
    {Id, Secret};
validate_external_psk({Id, Secret, Modes}) when
    is_binary(Id), is_binary(Secret), is_list(Modes), Modes =/= []
->
    {Id, Secret, Modes};
validate_external_psk(Other) ->
    error({bad_config, {external_psk, Other}}).

%% @private
%% Parse psk_callback config. Accepts literal anonymous funs,
%% {Module, Function} tuples, and "Module:Function" strings from
%% vm.args. Mirrors parse_auth_callback/1 but for arity-1 funs.
parse_psk_callback(undefined) ->
    undefined;
parse_psk_callback({M, F}) when is_atom(M), is_atom(F) ->
    {M, F};
parse_psk_callback(F) when is_function(F, 1) ->
    F;
parse_psk_callback(Str) when is_list(Str) ->
    case string:split(Str, ":") of
        [M, F] when M =/= "", F =/= "" ->
            {list_to_atom(M), list_to_atom(F)};
        _ ->
            undefined
    end;
parse_psk_callback(_) ->
    undefined.

%% @private
parse_auth_callback(undefined) ->
    undefined;
parse_auth_callback({M, F}) when is_atom(M), is_atom(F) ->
    {M, F};
parse_auth_callback(F) when is_function(F, 3) ->
    F;
parse_auth_callback(Str) when is_list(Str) ->
    case string:split(Str, ":") of
        [M, F] when M =/= "", F =/= "" ->
            {list_to_atom(M), list_to_atom(F)};
        _ ->
            undefined
    end;
parse_auth_callback(_) ->
    undefined.

%% @private
parse_timeout(undefined, Default) ->
    Default;
parse_timeout(N, _Default) when is_integer(N), N > 0 ->
    N;
parse_timeout(infinity, _Default) ->
    infinity;
parse_timeout("infinity", _Default) ->
    infinity;
parse_timeout(Str, Default) when is_list(Str) ->
    try list_to_integer(Str) of
        N when N > 0 -> N;
        _ -> Default
    catch
        _:_ -> Default
    end;
parse_timeout(_, Default) ->
    Default.

%% @private
parse_bool(undefined, Default) -> Default;
parse_bool(true, _) -> true;
parse_bool(false, _) -> false;
parse_bool("true", _) -> true;
parse_bool("false", _) -> false;
parse_bool(_, Default) -> Default.

%% @private
%% Get value from init argument -quic_dist_Key Value
get_init_arg(Key, Default) ->
    ArgName = list_to_atom("quic_dist_" ++ atom_to_list(Key)),
    case init:get_argument(ArgName) of
        {ok, [[Value]]} ->
            Value;
        _ ->
            %% Also try plain -quic_dist with key value pairs
            case init:get_argument(quic_dist) of
                {ok, Args} ->
                    find_in_args(atom_to_list(Key), Args, Default);
                _ ->
                    Default
            end
    end.

%% @private
find_in_args(_Key, [], Default) -> Default;
find_in_args(Key, [[Key, Value] | _], _Default) -> Value;
find_in_args(Key, [_ | Rest], Default) -> find_in_args(Key, Rest, Default).

%% @private
get_verify_opt(verify_peer) -> verify_peer;
get_verify_opt(verify_none) -> verify_none;
get_verify_opt("verify_peer") -> verify_peer;
get_verify_opt("verify_none") -> verify_none;
get_verify_opt(_) -> verify_none.

%% @private
get_opt(Key, Opts) ->
    get_opt(Key, Opts, undefined).

get_opt(Key, Opts, Default) when is_list(Opts) ->
    proplists:get_value(Key, Opts, Default);
get_opt(Key, Opts, Default) when is_map(Opts) ->
    maps:get(Key, Opts, Default).

%% @private
%% Get the port to listen on from init arguments or config.
get_listen_port() ->
    case init:get_argument(quic_dist_port) of
        {ok, [[PortStr]]} ->
            list_to_integer(PortStr);
        _ ->
            application:get_env(quic, dist_port, ?QUIC_DIST_DEFAULT_PORT)
    end.

%% @private
%% @doc QUIC keep-alive interval for distribution connections, in milliseconds.
%%
%% net_kernel declares a peer down after net_ticktime with no received QUIC
%% packets (the transport's getstat reports packets_received), so the PING
%% keep-alive — which bypasses stream flow control — must fire well within that
%% window even when a post-burst flow-control stall delays the dist tick. We pace
%% it at net_ticktime/4, matching net_kernel's own tick cadence (~4 chances per
%% window), so a healthy link (latency well under net_ticktime) never trips a
%% false timeout.
%%
%% net_ticktime is read from the kernel application env, NOT via
%% net_kernel:get_net_ticktime/0: this runs inside the dist listen/connect
%% callback, which executes in the net_kernel process, so calling net_kernel
%% would deadlock ({calling_self,...}). The env holds the configured value
%% net_kernel itself uses at startup (a runtime set_net_ticktime/1 is not
%% reflected, which is acceptable for picking a keep-alive cadence).
-spec keep_alive_interval() -> pos_integer().
keep_alive_interval() ->
    keep_alive_interval_for(application:get_env(kernel, net_ticktime, 60)).

%% @private Pure derivation, split out so the net_ticktime cases are testable.
-spec keep_alive_interval_for(term()) -> pos_integer().
keep_alive_interval_for(Ticktime) when is_integer(Ticktime), Ticktime > 0 ->
    max(?QUIC_DIST_KEEP_ALIVE_MIN, (Ticktime * 1000) div 4);
keep_alive_interval_for(_Other) ->
    %% net_ticktime unset or invalid - use the configured fallback.
    ?QUIC_DIST_KEEP_ALIVE_INTERVAL.

%% Start QUIC server for distribution.
%%
%% Two modes of operation:
%% 1. Early boot mode: Start standalone quic_listener directly (no supervision)
%% 2. Normal mode: Use quic:start_server through the supervisor tree
start_quic_server(Name, Port, Config, _ExtraOpts) ->
    %% Load certificate and key (or fall through to PSK-only auth)
    case load_credentials(Config) of
        {ok, Cert, Key, _CACert} ->
            CongestionThreshold = Config#quic_dist_config.congestion_threshold,
            BaseOpts0 = #{
                alpn => [?QUIC_DIST_ALPN],
                idle_timeout => ?QUIC_DIST_IDLE_TIMEOUT,
                %% QUIC-level keep-alive via PING frames (bypasses flow control).
                %% Paced off net_ticktime so net_kernel never sees a stale
                %% connection under load.
                keep_alive_interval => keep_alive_interval(),
                %% Use aggressive initial cwnd for distribution bulk transfers
                initial_window => ?INITIAL_WINDOW_AGGRESSIVE,
                %% Keep a higher congestion floor to avoid liveness stalls
                %% on bursty virtual networks (e.g., Docker bridge).
                minimum_window => ?MINIMUM_WINDOW_DISTRIBUTION,
                %% Higher flow control limits for distribution to avoid blocking
                %% during large message transfers (code loading, large terms)
                max_data => ?DIST_INITIAL_MAX_DATA,
                max_stream_data_bidi_local => ?DIST_INITIAL_MAX_STREAM_DATA,
                max_stream_data_bidi_remote => ?DIST_INITIAL_MAX_STREAM_DATA,
                max_stream_data_uni => ?DIST_INITIAL_MAX_STREAM_DATA,
                %% Backpressure threshold for congestion detection
                congestion_threshold => CongestionThreshold,
                %% Pacing spreads packet sends to avoid bursts
                pacing_enabled => Config#quic_dist_config.pacing_enabled,
                %% Longer recovery duration for virtual network packet reordering
                min_recovery_duration => ?MIN_RECOVERY_DURATION_DISTRIBUTION,
                %% Use known-safe MTU for LAN (1452 bytes, IPv4/IPv6 compatible)
                %% instead of PMTU probing which adds overhead
                max_udp_payload_size => ?DIST_MAX_UDP_PAYLOAD_SIZE,
                pmtu_enabled => false,
                connection_handler => fun(Conn) ->
                    handle_new_connection(Conn)
                end
            },
            %% Add cert/key when present (PSK-only listeners omit them).
            BaseOpts1 =
                case {Cert, Key} of
                    {undefined, undefined} -> BaseOpts0;
                    {_, _} -> BaseOpts0#{cert => Cert, key => Key}
                end,
            %% Add PSK auth when configured.
            Opts = add_psk_listener_opts(BaseOpts1, Config),

            case whereis(quic_sup) of
                Pid when is_pid(Pid) ->
                    %% Normal mode - use supervised server
                    start_supervised_server(Name, Port, Opts);
                undefined ->
                    %% Early boot mode - start standalone listener
                    start_standalone_listener(Name, Port, Opts)
            end;
        {error, Reason} ->
            {error, {credentials, Reason}}
    end.

%% @private
%% Start QUIC server through the normal supervisor tree.
start_supervised_server(Name, Port, Opts) ->
    ServerName = dist_server_name(Name),
    case quic:start_server(ServerName, Port, Opts) of
        {ok, _Pid} ->
            %% Get actual port (may differ if Port was 0)
            case quic:get_server_port(ServerName) of
                {ok, ActualPort} ->
                    {ok, ServerName, ActualPort};
                Error ->
                    quic:stop_server(ServerName),
                    Error
            end;
        Error ->
            Error
    end.

%% @private
%% Start a standalone QUIC listener during early boot.
%% This bypasses the supervisor tree since quic_sup isn't running yet.
%% The listener is NOT linked to the distribution process to avoid
%% crashing if distribution restarts.
start_standalone_listener(Name, Port, Opts) ->
    ServerName = dist_server_name(Name),
    case quic_listener:start(Port, Opts) of
        {ok, ListenerPid} ->
            %% Get actual port
            ActualPort = quic_listener:get_port(ListenerPid),
            %% Register the listener for later adoption by quic_sup
            register_early_boot_listener(ServerName, ListenerPid, ActualPort),
            {ok, ServerName, ActualPort};
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% Register an early boot listener so it can be found and adopted
%% when the quic application starts.
register_early_boot_listener(Name, Pid, Port) ->
    %% Store in persistent_term for cross-process access
    Key = {quic_dist_early_listener, Name},
    persistent_term:put(Key, #{pid => Pid, port => Port, name => Name}),
    ok.

%% @private
dist_server_name(Name) ->
    list_to_atom("quic_dist_" ++ atom_to_list(Name)).

%% @private
%% Get creation number (1-3) for the node.
%% Different instances should have different creation numbers.
get_creation(Name) ->
    (erlang:phash2(Name) + erlang:system_time(second)) rem 3 + 1.

%% @private
%% Load TLS credentials from files or config.
load_credentials(#quic_dist_config{cert = Cert, key = Key, cacert = CACert}) when
    Cert =/= undefined, Key =/= undefined
->
    {ok, Cert, Key, CACert};
load_credentials(#quic_dist_config{
    cert_file = CertFile,
    key_file = KeyFile,
    cacert_file = CACertFile
}) when CertFile =/= undefined, KeyFile =/= undefined ->
    try
        {ok, CertPem} = file:read_file(CertFile),
        {ok, KeyPem} = file:read_file(KeyFile),

        %% Decode PEM to DER
        [{'Certificate', CertDer, _}] = public_key:pem_decode(CertPem),

        %% Decode private key - must be fully decoded record for crypto:sign
        KeyDer =
            case public_key:pem_decode(KeyPem) of
                [{'RSAPrivateKey', Der, not_encrypted}] ->
                    public_key:der_decode('RSAPrivateKey', Der);
                [{'ECPrivateKey', Der, not_encrypted}] ->
                    public_key:der_decode('ECPrivateKey', Der);
                [{'PrivateKeyInfo', Der, not_encrypted}] ->
                    %% PKCS#8 format - decode and extract the key
                    public_key:der_decode('PrivateKeyInfo', Der);
                [{Type, Der, not_encrypted}] ->
                    %% Fallback - try to decode as the specified type
                    public_key:der_decode(Type, Der);
                [Entry] ->
                    Entry
            end,

        %% Load CA certificate if provided
        CACertDer =
            case CACertFile of
                undefined ->
                    undefined;
                _ ->
                    %% A bundle is as valid as a single certificate here.
                    {ok, CADers} = quic_cert:cacerts_from_file(CACertFile),
                    CADers
            end,

        {ok, CertDer, KeyDer, CACertDer}
    catch
        _:Reason ->
            {error, {load_credentials, Reason}}
    end;
load_credentials(#quic_dist_config{} = Config) ->
    %% PSK-only configuration: either psks or psk_callback configured
    %% and no cert/key path supplied. Return undefined slots so the
    %% caller (start_quic_server / connect_to_node) builds Opts
    %% without cert/key keys.
    case psk_only_credentials_ok(Config) of
        true -> {ok, undefined, undefined, undefined};
        false -> {error, no_credentials}
    end.

%% @private
psk_only_credentials_ok(#quic_dist_config{
    psks = Psks, psk_callback = Cb
}) when Psks =/= undefined; Cb =/= undefined ->
    true;
psk_only_credentials_ok(_) ->
    false.

%% @private
%% Add psk_callback and/or psks to a listener Opts map when configured.
add_psk_listener_opts(Opts, #quic_dist_config{psks = Psks, psk_callback = Cb}) ->
    Opts1 =
        case Psks of
            undefined -> Opts;
            _ -> Opts#{psks => Psks}
        end,
    case Cb of
        undefined -> Opts1;
        _ -> Opts1#{psk_callback => resolve_psk_callback(Cb)}
    end.

%% @private
%% Add external_psk to a client Opts map when configured.
add_psk_client_opts(Opts, #quic_dist_config{external_psk = undefined}) ->
    Opts;
add_psk_client_opts(Opts, #quic_dist_config{external_psk = Ext}) ->
    Opts#{external_psk => Ext}.

%% @private
%% parse_auth_callback stores {Module, Function} or fun/3 — we need
%% to expose a fun/1 to the TLS layer. Wrap the {M, F} case.
resolve_psk_callback({Mod, Fun}) when is_atom(Mod), is_atom(Fun) ->
    fun(Identity) -> Mod:Fun(Identity) end;
resolve_psk_callback(Fn) when is_function(Fn, 1) ->
    Fn;
resolve_psk_callback(_) ->
    undefined.

%% @private
%% Handle a new incoming QUIC connection.
%%
%% The listener installs whatever pid we return as the connection owner
%% before it hands the connection its first packet, so returning the dist
%% controller gives it the connection from packet zero. With an auth
%% callback configured the controller holds the connection in `init_state'
%% until the callback admits the peer, and notifies the acceptor itself;
%% without one there is nothing to wait for and we notify here.
handle_new_connection(Conn) ->
    Config = load_config(),
    Auth =
        case Config#quic_dist_config.auth_callback of
            undefined -> undefined;
            Callback -> {Callback, Config#quic_dist_config.auth_handshake_timeout}
        end,
    case quic_dist_controller:start_link(Conn, server, Auth) of
        {ok, ControllerPid} ->
            case Auth of
                undefined -> notify_acceptor(ControllerPid);
                _ -> ok
            end,
            {ok, ControllerPid};
        Error ->
            logger:error("quic_dist: failed to start controller: ~p~n", [Error]),
            Error
    end.

%% @private
notify_acceptor(ControllerPid) ->
    NodeName = node(),
    ShortName =
        case NodeName of
            nonode@nohost ->
                nonode;
            _ ->
                NodeStr = atom_to_list(NodeName),
                case string:split(NodeStr, "@") of
                    [Name, _Host] -> list_to_atom(Name);
                    [Name] -> list_to_atom(Name)
                end
        end,
    ServerName = dist_server_name(ShortName),
    case persistent_term:get({quic_dist_acceptor, ServerName}, undefined) of
        undefined ->
            %% No acceptor registered yet (early boot). net_kernel will
            %% eventually call accept/1.
            ok;
        AcceptorPid when is_pid(AcceptorPid) ->
            AcceptorPid ! {accept, ControllerPid, undefined},
            ok
    end.

%%====================================================================
%% Internal Functions - Acceptor
%%====================================================================

%% @private
%% Acceptor loop - forwards new QUIC connections to net_kernel.
%%
%% The spawn created by accept_connection/5 handshakes directly with
%% dist_util; we do not serialize controller handoff through this loop.
%% net_kernel still sends `{self(), controller, Pid}' on every accept
%% (see net_kernel.erl handle_info({accept, ...})); those messages
%% are ignored by the catch-all clause below so they don't pile up.
acceptor_loop(Kernel, #quic_dist_listener{} = Listener) ->
    receive
        {accept, DistCtrl, _NodeName} ->
            Kernel ! {accept, self(), DistCtrl, inet, quic},
            acceptor_loop(Kernel, Listener);
        stop ->
            ok;
        _Other ->
            acceptor_loop(Kernel, Listener)
    end.

%%====================================================================
%% Internal Functions - Setup Outgoing Connection
%%====================================================================

%% @private
%% Set up outgoing connection to a node.
do_setup(Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    %% Trap exits so we can handle the setup timer timeout properly
    process_flag(trap_exit, true),

    %% Ensure quic application is started
    case ensure_quic_started() of
        ok -> ok;
        {error, AppReason} -> ?shutdown2(Node, {quic_app_start_failed, AppReason})
    end,

    %% Start setup timer
    Timer = dist_util:start_timer(SetupTime),

    %% Parse target node name
    case parse_node_name(Node, LongOrShortNames) of
        {ok, Host} ->
            %% Look up node address via discovery
            case discover_node(Node, Host) of
                {ok, IP, Port} ->
                    connect_to_node(Kernel, Node, IP, Port, MyNode, Type, Timer);
                {error, Reason} ->
                    ?shutdown2(Node, {discovery_failed, Reason})
            end;
        {error, Reason} ->
            ?shutdown2(Node, Reason)
    end.

%% @private
parse_node_name(Node, LongOrShortNames) ->
    case dist_util:split_node(Node) of
        {node, Name, Host} when Name =/= "", Host =/= "" ->
            case LongOrShortNames of
                shortnames ->
                    %% Short name - host should not have dots
                    case lists:member($., Host) of
                        true -> {error, shortnames_with_fqdn};
                        false -> {ok, Host}
                    end;
                longnames ->
                    {ok, Host}
            end;
        {host, _Host} ->
            {error, invalid_node_name};
        _ ->
            {error, invalid_node_name}
    end.

%% @private
%% Discover node address using configured discovery module.
discover_node(Node, Host) ->
    Config = load_config(),
    DiscoveryModule = Config#quic_dist_config.discovery_module,

    %% First check static configuration
    case lists:keyfind(Node, 1, Config#quic_dist_config.nodes) of
        {Node, {IP, Port}} when is_tuple(IP) ->
            {ok, IP, Port};
        {Node, {IPStr, Port}} when is_list(IPStr) ->
            case inet:parse_address(IPStr) of
                {ok, IP} -> {ok, IP, Port};
                _ -> resolve_and_lookup(DiscoveryModule, Node, Host)
            end;
        false ->
            resolve_and_lookup(DiscoveryModule, Node, Host)
    end.

%% @private
resolve_and_lookup(DiscoveryModule, Node, Host) ->
    %% Try discovery module
    case code:ensure_loaded(DiscoveryModule) of
        {module, DiscoveryModule} ->
            case DiscoveryModule:lookup(Node, Host) of
                {ok, {IP, Port}} ->
                    {ok, IP, Port};
                {error, not_found} ->
                    %% Fall back to DNS resolution with default port
                    resolve_host(Host);
                Error ->
                    Error
            end;
        _ ->
            %% Discovery module not available, use DNS
            resolve_host(Host)
    end.

%% @private
resolve_host(Host) ->
    case inet:getaddr(Host, inet) of
        {ok, IP} ->
            {ok, IP, ?QUIC_DIST_DEFAULT_PORT};
        {error, _} ->
            case inet:getaddr(Host, inet6) of
                {ok, IP} ->
                    {ok, IP, ?QUIC_DIST_DEFAULT_PORT};
                Error ->
                    Error
            end
    end.

%% @private
%% Convert IP address to host string for QUIC connect.
%% Handles IP tuples, binary strings, and list strings.
ip_to_host(IP) when is_tuple(IP) ->
    inet:ntoa(IP);
ip_to_host(IP) when is_binary(IP) ->
    binary_to_list(IP);
ip_to_host(IP) when is_list(IP) ->
    IP.

%% @doc Register per-node connect-time option overrides for the next
%% `setup/5' attempt against `Node'. The map is merged on top of the
%% defaults that `connect_to_node/7' builds, so callers can override
%% any key, including `socket_backend' and `socket_adapter' to route
%% the underlying UDP packets through a custom transport (for example
%% a MASQUE CONNECT-UDP tunnel), or `external_psk' to authenticate
%% this peer with a different identity/secret than the cluster-wide
%% default. See docs/PSK.md for the PSK option shapes.
%%
%% The entry is consumed once (the first matching `connect_to_node'
%% call clears it). Use `clear_connect_options/1' to drop it without
%% triggering a connect.
-spec set_connect_options(node(), map()) -> ok.
set_connect_options(Node, Opts) when is_atom(Node), is_map(Opts) ->
    ensure_connect_opts_table(),
    true = ets:insert(quic_dist_connect_opts, {Node, Opts}),
    ok.

%% @doc Look up the pending connect-option overrides for `Node' without
%% consuming them. Returns an empty map if none are registered.
-spec get_connect_options(node()) -> map().
get_connect_options(Node) when is_atom(Node) ->
    case ets:info(quic_dist_connect_opts) of
        undefined ->
            #{};
        _ ->
            case ets:lookup(quic_dist_connect_opts, Node) of
                [{Node, Opts}] -> Opts;
                [] -> #{}
            end
    end.

%% @doc Drop any pending connect-option overrides for `Node'.
-spec clear_connect_options(node()) -> ok.
clear_connect_options(Node) when is_atom(Node) ->
    case ets:info(quic_dist_connect_opts) of
        undefined ->
            ok;
        _ ->
            _ = ets:delete(quic_dist_connect_opts, Node),
            ok
    end.

%% @private
%% Atomically read and remove the override for `Node'. Used by the
%% setup path so a registered override applies once.
take_connect_options(Node) ->
    case ets:info(quic_dist_connect_opts) of
        undefined ->
            #{};
        _ ->
            case ets:take(quic_dist_connect_opts, Node) of
                [{Node, Opts}] -> Opts;
                [] -> #{}
            end
    end.

%% @private
%% Create the per-node connect-options table on first use.
ensure_connect_opts_table() ->
    ensure_named_set(quic_dist_connect_opts).

%% @private
%% Connect to the target node.
connect_to_node(Kernel, Node, IP, Port, MyNode, Type, Timer) ->
    Config = load_config(),

    %% Prepare QUIC connection options
    case load_credentials(Config) of
        {ok, Cert, Key, _CACert} ->
            CongestionThreshold = Config#quic_dist_config.congestion_threshold,
            BaseOpts0 = #{
                alpn => [?QUIC_DIST_ALPN],
                idle_timeout => ?QUIC_DIST_IDLE_TIMEOUT,
                %% QUIC-level keep-alive via PING frames (bypasses flow control).
                %% Paced off net_ticktime so net_kernel never sees a stale
                %% connection under load.
                keep_alive_interval => keep_alive_interval(),
                %% Use aggressive initial cwnd for distribution bulk transfers
                initial_window => ?INITIAL_WINDOW_AGGRESSIVE,
                %% Keep a higher congestion floor to avoid liveness stalls
                %% on bursty virtual networks (e.g., Docker bridge).
                minimum_window => ?MINIMUM_WINDOW_DISTRIBUTION,
                %% Higher flow control limits for distribution to avoid blocking
                %% during large message transfers (code loading, large terms)
                max_data => ?DIST_INITIAL_MAX_DATA,
                max_stream_data_bidi_local => ?DIST_INITIAL_MAX_STREAM_DATA,
                max_stream_data_bidi_remote => ?DIST_INITIAL_MAX_STREAM_DATA,
                max_stream_data_uni => ?DIST_INITIAL_MAX_STREAM_DATA,
                %% Backpressure threshold for congestion detection
                congestion_threshold => CongestionThreshold,
                %% Pacing spreads packet sends to avoid bursts
                pacing_enabled => Config#quic_dist_config.pacing_enabled,
                %% Longer recovery duration for virtual network packet reordering
                min_recovery_duration => ?MIN_RECOVERY_DURATION_DISTRIBUTION,
                %% Use known-safe MTU for LAN (1452 bytes, IPv4/IPv6 compatible)
                %% instead of PMTU probing which adds overhead
                max_udp_payload_size => ?DIST_MAX_UDP_PAYLOAD_SIZE,
                pmtu_enabled => false,
                % TODO: Enable proper verification
                verify => false
            },
            %% Add cert/key when present (PSK-only clients omit them).
            BaseOpts1 =
                case {Cert, Key} of
                    {undefined, undefined} -> BaseOpts0;
                    {_, _} -> BaseOpts0#{cert => Cert, key => Key}
                end,
            %% Add external_psk when configured.
            BaseOpts = add_psk_client_opts(BaseOpts1, Config),

            %% Per-node overrides registered via set_connect_options/2.
            %% Merged on top of the defaults so callers can swap the
            %% socket backend, adjust flow control, etc.
            Overrides = take_connect_options(Node),
            Opts = maps:merge(BaseOpts, Overrides),

            %% Convert IP to host format expected by QUIC
            Host = ip_to_host(IP),

            %% Attempt connection
            case quic:connect(Host, Port, Opts, self()) of
                {ok, Conn} ->
                    %% Wait for connection to be established
                    wait_for_connection(Kernel, Node, Conn, MyNode, Type, Timer, Config);
                {error, Reason} ->
                    ?shutdown2(Node, {connect_failed, Reason})
            end;
        {error, Reason} ->
            ?shutdown2(Node, {credentials, Reason})
    end.

%% @private
wait_for_connection(Kernel, Node, Conn, MyNode, Type, Timer, Config) ->
    receive
        {quic, Conn, {connected, _Info}} ->
            %% Optional auth handshake before the dist controller
            %% takes ownership.
            case maybe_run_client_auth(Conn, Config) of
                ok ->
                    start_client_controller(Kernel, Node, Conn, MyNode, Type, Timer);
                {error, AuthReason} ->
                    quic:safe_close(Conn, normal),
                    ?shutdown2(Node, {auth_failed, AuthReason})
            end;
        {quic, Conn, {closed, Reason}} ->
            ?shutdown2(Node, {closed, Reason});
        {quic, Conn, {transport_error, Code, Reason}} ->
            ?shutdown2(Node, {transport_error, Code, Reason});
        {'EXIT', Timer, setup_timer_timeout} ->
            quic:close(Conn, timeout),
            ?shutdown2(Node, connect_timeout);
        {'EXIT', _From, remarked} ->
            %% net_kernel resolved a simultaneous connect against this
            %% setup and is now blocked in an unconditional receive
            %% waiting for us to die (net_kernel.erl, accept_pending).
            %% Trapping turns that signal into a message, so leaving it
            %% unread wedges the node's entire dist machinery: no
            %% handshake, no arbitration, both dials time out.
            quic:close(Conn, normal),
            exit(remarked)
    end.

%% @private
%% net_kernel resolves a simultaneous connect by killing the losing setup
%% process and then blocking, with no timeout, until it dies
%% (net_kernel.erl, accept_pending). This process traps exits, so that
%% signal arrives as a message and killing it is our job. Trapping cannot
%% simply be turned off: unlike OTP's socket-based dist, the setup process
%% is linked to both the QUIC connection and the controller, so an
%% ordinary linked exit would become lethal mid-handshake.
exit_if_remarked() ->
    receive
        {'EXIT', _From, remarked} -> exit(remarked)
    after 0 -> ok
    end.

%% @private
maybe_run_client_auth(_Conn, #quic_dist_config{auth_callback = undefined}) ->
    ok;
maybe_run_client_auth(Conn, #quic_dist_config{
    auth_callback = Callback,
    auth_handshake_timeout = Timeout
}) ->
    case quic_dist_auth:run(Callback, Conn, client, Timeout) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.

%% @private
start_client_controller(Kernel, Node, Conn, MyNode, Type, Timer) ->
    case quic_dist_controller:start_link(Conn, client) of
        {ok, DistCtrl} ->
            %% The controller took ownership inside its init/1, so this
            %% mailbox holds exactly what the connection delivered before
            %% the swap and can receive nothing further. Hand that over
            %% before the controller has any work to do.
            _ = quic_dist_controller:adopt_owner_events(Conn, DistCtrl),
            quic_dist_controller:set_supervisor(DistCtrl, Kernel),
            quic_dist_controller:set_node(DistCtrl, Node),
            ok = quic_dist_controller:set_handshake_owner(DistCtrl, self()),
            HSData = create_hs_data_setup(Kernel, DistCtrl, Node, MyNode, Type, Timer),
            %% From here the handshake belongs to dist_util, and
            %% net_kernel resolves a simultaneous connect by killing this
            %% process and blocking until it dies. It cannot die while it
            %% traps exits, and it cannot stop trapping while it is linked
            %% to the connection and the controller, whose ordinary exits
            %% would then be lethal. The controller owns the connection by
            %% now, so drop both links and let net_kernel kill us the way
            %% it kills OTP's own setup processes.
            _ = unlink(Conn),
            _ = unlink(DistCtrl),
            ok = exit_if_remarked(),
            process_flag(trap_exit, false),
            dist_util:handshake_we_started(HSData);
        {error, Reason} ->
            quic:safe_close(Conn, normal),
            ?shutdown2(Node, {controller_failed, Reason})
    end.

%%====================================================================
%% Internal Functions - Handshake Data
%%====================================================================

%% @private
%% Create handshake data structure for accepted connections.
create_hs_data(DistCtrl, MyNode, Timer, Allowed, Kernel) ->
    %% Capture SetupPid (self) for dist_ctrlr message
    SetupPid = self(),
    logger:info(
        "create_hs_data: Kernel=~p, DistCtrl=~p, SetupPid=~p~n",
        [Kernel, DistCtrl, SetupPid]
    ),
    #hs_data{
        kernel_pid = Kernel,
        other_node = undefined,
        this_node = MyNode,
        socket = DistCtrl,
        timer = Timer,
        this_flags = 0,
        other_flags = 0,
        %% Reject the connection-wide atom cache so it cannot create
        %% cross-stream decoder-state dependencies. Fragments stay on
        %% (routed per SeqId by quic_dist_dispatch). strict_order_flags/0
        %% returns DFLAG_DIST_HDR_ATOM_CACHE (0x2000).
        reject_flags = dist_util:strict_order_flags(),
        f_send = fun(Ctrl, Data) -> quic_dist_controller:send(Ctrl, Data) end,
        f_recv = fun(Ctrl, Len, Timeout) ->
            %% Receive data and try to extract node name if this is the name message
            Result = quic_dist_controller:recv(Ctrl, Len, Timeout),
            case Result of
                {ok, Data} ->
                    %% Try to parse name message and store node in controller
                    maybe_extract_node(Data, Ctrl),
                    Result;
                _ ->
                    Result
            end
        end,
        f_setopts_pre_nodeup = fun(Ctrl) ->
            %% Just log and return ok - inet_tcp_dist doesn't do anything special here
            StoredNode = get_stored_node(Ctrl),
            logger:info(
                "f_setopts_pre_nodeup (accept): Ctrl=~p, Node=~p, SetupPid=~p, linked=~p~n",
                [
                    Ctrl,
                    StoredNode,
                    SetupPid,
                    lists:member(Ctrl, element(2, process_info(self(), links)))
                ]
            ),
            ok
        end,
        f_setopts_post_nodeup = fun(_Ctrl) -> ok end,
        f_getll = fun(Ctrl) -> {ok, Ctrl} end,
        f_address = fun(Ctrl, Node) ->
            quic_dist_controller:get_address(Ctrl, Node)
        end,
        mf_tick = fun(Ctrl) -> quic_dist_controller:tick(Ctrl) end,
        mf_getstat = fun(Ctrl) -> quic_dist_controller:getstat(Ctrl) end,
        request_type = normal,
        mf_setopts = fun(_Ctrl, _Opts) -> ok end,
        mf_getopts = fun(_Ctrl, Opts) -> {ok, [{O, 0} || O <- Opts]} end,
        allowed = Allowed,
        f_handshake_complete = fun(Ctrl, HsNode, DHandle) ->
            logger:info(
                "f_handshake_complete (accept): Ctrl=~p, Node=~p, DHandle=~p~n",
                [Ctrl, HsNode, DHandle]
            ),
            %% Notify controller that handshake is complete
            %% Pass DHandle so controller can use dist_ctrl_* functions
            Ctrl ! {handshake_complete, HsNode, DHandle},
            ok
        end
    }.

%% @private
%% Try to extract node name from name message and store in controller.
%% The name message format depends on protocol version:
%% Protocol 6: <<$N, Flags:64/big, Creation:32/big, NameLen:16/big, Name/binary>>
%% Older: <<$n, Version:16/big, Flags:32/big, Name/binary>>
maybe_extract_node([H | Rest], Ctrl) when H =:= $N; H =:= $n ->
    try
        case H of
            $N ->
                %% Protocol version 6 format
                RestBin = list_to_binary(Rest),
                <<_Flags:64/big, _Creation:32/big, NameLen:16/big, NameBin:NameLen/binary,
                    _/binary>> = RestBin,
                Node = binary_to_atom(NameBin, utf8),
                quic_dist_controller:set_node(Ctrl, Node);
            $n ->
                %% Older protocol format
                RestBin = list_to_binary(Rest),
                <<_Version:16/big, _Flags:32/big, NameBin/binary>> = RestBin,
                Node = binary_to_atom(NameBin, utf8),
                quic_dist_controller:set_node(Ctrl, Node)
        end
    catch
        _:_ ->
            %% Failed to parse, not a name message or malformed
            ok
    end;
maybe_extract_node(_, _) ->
    ok.

%% @private
%% Get the stored node from controller, with fallback.
get_stored_node(Ctrl) ->
    case quic_dist_controller:get_node(Ctrl) of
        {ok, Node} -> Node;
        undefined -> undefined
    end.

%% @private
%% Create handshake data structure for outgoing connections.
create_hs_data_setup(Kernel, DistCtrl, Node, MyNode, Type, Timer) ->
    %% Capture SetupPid (self) for dist_ctrlr message
    SetupPid = self(),
    logger:info(
        "create_hs_data_setup: Kernel=~p, DistCtrl=~p, Node=~p, SetupPid=~p~n",
        [Kernel, DistCtrl, Node, SetupPid]
    ),
    #hs_data{
        kernel_pid = Kernel,
        other_node = Node,
        this_node = MyNode,
        socket = DistCtrl,
        timer = Timer,
        this_flags = 0,
        other_flags = 0,
        %% Reject the connection-wide atom cache — see create_hs_data/5 comment.
        reject_flags = dist_util:strict_order_flags(),
        f_send = fun(Ctrl, Data) -> quic_dist_controller:send(Ctrl, Data) end,
        f_recv = fun(Ctrl, Len, Timeout) -> quic_dist_controller:recv(Ctrl, Len, Timeout) end,
        f_setopts_pre_nodeup = fun(Ctrl) ->
            %% Just log and return ok - inet_tcp_dist doesn't do anything special here
            logger:info(
                "f_setopts_pre_nodeup (setup): Ctrl=~p, Node=~p, SetupPid=~p, linked=~p~n",
                [Ctrl, Node, SetupPid, lists:member(Ctrl, element(2, process_info(self(), links)))]
            ),
            ok
        end,
        f_setopts_post_nodeup = fun(_Ctrl) -> ok end,
        f_getll = fun(Ctrl) -> {ok, Ctrl} end,
        f_address = fun(Ctrl, N) ->
            quic_dist_controller:get_address(Ctrl, N)
        end,
        mf_tick = fun(Ctrl) -> quic_dist_controller:tick(Ctrl) end,
        mf_getstat = fun(Ctrl) -> quic_dist_controller:getstat(Ctrl) end,
        request_type = Type,
        mf_setopts = fun(_Ctrl, _Opts) -> ok end,
        mf_getopts = fun(_Ctrl, Opts) -> {ok, [{O, 0} || O <- Opts]} end,
        f_handshake_complete = fun(Ctrl, HsNode, DHandle) ->
            logger:info(
                "f_handshake_complete (setup): Ctrl=~p, Node=~p, DHandle=~p~n",
                [Ctrl, HsNode, DHandle]
            ),
            %% Notify controller that handshake is complete
            %% Pass DHandle so controller can use dist_ctrl_* functions
            Ctrl ! {handshake_complete, HsNode, DHandle},
            ok
        end
    }.

%%====================================================================
%% User Stream API
%%====================================================================

%% @doc Open a bidirectional user stream to a connected node.
%% Returns {ok, StreamRef} on success where StreamRef can be used with send/2,3 and close_stream/1.
%% The caller becomes the stream owner.
-spec open_stream(Node :: node()) -> {ok, stream_ref()} | {error, term()}.
open_stream(Node) ->
    open_stream(Node, []).

%% @doc Open a bidirectional user stream with options.
%% Options:
%%   {priority, 16..255} - Stream priority (default: 128, lower = higher priority)
%%                         Note: priorities 0-15 are reserved for distribution
-spec open_stream(Node :: node(), Options :: [stream_opt()]) ->
    {ok, stream_ref()} | {error, term()}.
open_stream(Node, Options) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            case quic_dist_controller:open_user_stream(Ctrl, self(), Options) of
                {ok, StreamId} ->
                    {ok, {quic_dist_stream, Node, StreamId}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Send data on a user stream.
%% Equivalent to send(StreamRef, Data, false).
-spec send(StreamRef :: stream_ref(), Data :: iodata()) -> ok | {error, term()}.
send(StreamRef, Data) ->
    send(StreamRef, Data, false).

%% @doc Send data on a user stream.
%% When Fin is true, this marks the end of data on this stream (half-close).
-spec send(StreamRef :: stream_ref(), Data :: iodata(), Fin :: boolean()) -> ok | {error, term()}.
send({quic_dist_stream, Node, StreamId}, Data, Fin) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            quic_dist_controller:send_user_data(Ctrl, StreamId, Data, Fin);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Close a user stream gracefully.
%% This sends a FIN to the peer. When both sides have sent FIN, the owner
%% receives {quic_dist_stream, StreamRef, closed}.
-spec close_stream(StreamRef :: stream_ref()) -> ok | {error, term()}.
close_stream({quic_dist_stream, Node, StreamId}) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            quic_dist_controller:close_user_stream(Ctrl, StreamId);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Reset/cancel a user stream immediately (notifies peer).
%% Uses default error code 0.
-spec reset_stream(StreamRef :: stream_ref()) -> ok | {error, term()}.
reset_stream(StreamRef) ->
    reset_stream(StreamRef, 0).

%% @doc Reset/cancel a user stream with a specific error code.
%% The peer receives the reset notification immediately.
-spec reset_stream(StreamRef :: stream_ref(), ErrorCode :: non_neg_integer()) ->
    ok | {error, term()}.
reset_stream({quic_dist_stream, Node, StreamId}, ErrorCode) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            quic_dist_controller:reset_user_stream(Ctrl, StreamId, ErrorCode);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Register to accept incoming user streams from a node.
%% Joins the acceptor pool for the node. Multiple processes can register as acceptors.
%% Incoming streams are assigned to acceptors using round-robin selection.
%%
%% When a new stream arrives, one acceptor receives:
%%   {quic_dist_stream, StreamRef, {data, Data, Fin}}
%%
%% The acceptor automatically becomes the stream owner (implicit ownership).
%% Use controlling_process/2 to transfer ownership to a worker process.
%%
%% If no acceptors are registered, incoming streams are refused with RESET.
-spec accept_streams(Node :: node()) -> ok | {error, term()}.
accept_streams(Node) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            quic_dist_controller:accept_user_streams(Ctrl, self());
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Stop accepting incoming user streams from a node.
%% Removes the calling process from the acceptor pool.
-spec stop_accepting(Node :: node()) -> ok | {error, term()}.
stop_accepting(Node) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            quic_dist_controller:stop_accepting_streams(Ctrl);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Transfer stream ownership to another process.
%% The new owner will receive all subsequent messages for this stream.
-spec controlling_process(StreamRef :: stream_ref(), NewOwner :: pid()) -> ok | {error, term()}.
controlling_process({quic_dist_stream, Node, StreamId}, NewOwner) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            quic_dist_controller:controlling_process(Ctrl, StreamId, NewOwner);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc List all user streams across all connected nodes.
-spec list_streams() -> [stream_info()].
list_streams() ->
    try
        DistCtrls = erlang:system_info(dist_ctrl),
        lists:flatmap(
            fun
                ({_Node, Ctrl}) when is_pid(Ctrl) ->
                    quic_dist_controller:list_user_streams(Ctrl);
                ({_Node, _Port}) ->
                    []
            end,
            DistCtrls
        )
    catch
        _:_ ->
            []
    end.

%% @doc List user streams for a specific connected node.
-spec list_streams(Node :: node()) -> [stream_info()].
list_streams(Node) ->
    case get_controller(Node) of
        {ok, Ctrl} ->
            quic_dist_controller:list_user_streams(Ctrl);
        {error, _} ->
            []
    end.

%% @doc Get the distribution controller for a connected node.
%% Returns {ok, ControllerPid} if the node is connected, {error, not_connected} otherwise.
-spec get_controller(Node :: node()) -> {ok, pid()} | {error, not_connected | not_quic_connection}.
get_controller(Node) ->
    %% Use erlang:system_info(dist_ctrl) to get the list of distribution controllers
    %% This returns [{Node, CtrlPid}] for all connected nodes
    try
        DistCtrls = erlang:system_info(dist_ctrl),
        case lists:keyfind(Node, 1, DistCtrls) of
            {Node, Ctrl} when is_pid(Ctrl) ->
                {ok, Ctrl};
            {Node, Port} when is_port(Port) ->
                %% TCP distribution uses ports, not pids - not supported
                {error, not_quic_connection};
            _ ->
                {error, not_connected}
        end
    catch
        _:_ ->
            {error, not_connected}
    end.
