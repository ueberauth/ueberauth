%%% -*- erlang -*-
%%%
%%% Happy Eyeballs v2 (RFC 8305) client connection establishment.
%%%
%%% Resolution happens in the caller process (so a resolution failure
%%% returns `{error, Reason}' without ever linking a connection to the
%%% caller). A literal IP, a single resolved address, or a pre-opened
%%% socket take the direct, caller-linked, async path. A hostname that
%%% resolves to two or more addresses is raced IPv6-first under a
%%% supervised coordinator that returns the winning connection.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0

-module(quic_happy).

%% Public entry (called from quic:connect/4).
-export([connect/5]).
%% Supervisor + proc_lib entry points.
-export([start_coordinator/1, coordinator_entry/1]).
%% Pure helpers (exported for unit tests).
-export([interleave/2, parse_host/1]).

-define(DEFAULT_ATTEMPT_DELAY, 250).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Establish a client connection. Runs resolution in the caller.
-spec connect(
    inet:ip_address() | binary() | string(),
    inet:port_number(),
    map(),
    pid(),
    gen_udp:socket() | undefined
) -> {ok, pid()} | {error, term()}.
connect(Host, Port, Opts, Owner, Socket) ->
    case parse_host(Host) of
        {literal, IP} ->
            direct(IP, Port, Opts, Owner, Socket);
        {name, Name} ->
            Family = maps:get(family, Opts, any),
            Opts1 = with_sni(Opts, Name),
            case {Socket, maps:get(happy_eyeballs, Opts, true)} of
                {undefined, true} ->
                    happy(Name, Port, Opts1, Owner, Family);
                _ ->
                    %% Pre-opened socket or Happy Eyeballs disabled: resolve a
                    %% single address (family-ordered) and take the direct path.
                    case resolve_single(Name, Family) of
                        {ok, IP} -> direct(IP, Port, Opts1, Owner, Socket);
                        {error, _} = Error -> Error
                    end
            end
    end.

%%====================================================================
%% Direct (caller-linked) path
%%====================================================================

direct(IP, Port, Opts, Owner, Socket) ->
    quic_connection:start_link(IP, Port, Opts, Owner, Socket).

%%====================================================================
%% Happy Eyeballs path
%%====================================================================

happy(Name, Port, Opts, Owner, Family) ->
    case resolve_all(Name, Family) of
        {error, _} = Error ->
            Error;
        {ok, [{IP, _Fam}]} ->
            %% Single address: caller-linked async path, no race.
            direct(IP, Port, Opts, Owner, undefined);
        {ok, Addrs} ->
            race(Addrs, Port, Opts, Owner)
    end.

%% Start a supervised coordinator and block until it reports a winner,
%% all attempts fail, or the overall timeout elapses.
race(Addrs, Port, Opts, Owner) ->
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    Args = #{
        addrs => Addrs,
        port => Port,
        opts => Opts,
        owner => Owner,
        caller => self(),
        delay => maps:get(connection_attempt_delay, Opts, ?DEFAULT_ATTEMPT_DELAY),
        timeout => Timeout
    },
    case quic_happy_sup:start_child([Args]) of
        {ok, Coord} ->
            MRef = erlang:monitor(process, Coord),
            receive
                {quic_happy_result, Coord, Result} ->
                    erlang:demonitor(MRef, [flush]),
                    Result;
                {'DOWN', MRef, process, Coord, Reason} ->
                    {error, {coordinator_crash, Reason}}
            after Timeout + 1000 ->
                erlang:demonitor(MRef, [flush]),
                exit(Coord, kill),
                {error, connect_timeout}
            end;
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% Coordinator process
%%====================================================================

%% Supervisor entry: spawn the coordinator via proc_lib so the
%% supervisor receives {ok, Pid}.
-spec start_coordinator(map()) -> {ok, pid()}.
start_coordinator(Args) when is_map(Args) ->
    proc_lib:start_link(?MODULE, coordinator_entry, [Args]).

-spec coordinator_entry(map()) -> no_return().
coordinator_entry(Args) ->
    %% Trap exits so the link from quic_connection:start_link (attempts) does
    %% not kill us; failures are observed through monitors instead.
    process_flag(trap_exit, true),
    proc_lib:init_ack({ok, self()}),
    St = #{
        remaining => maps:get(addrs, Args),
        port => maps:get(port, Args),
        opts => maps:get(opts, Args),
        owner => maps:get(owner, Args),
        caller => maps:get(caller, Args),
        delay => maps:get(delay, Args),
        attempts => #{},
        backlog => #{},
        last_error => undefined
    },
    %% Overall deadline. Messages to this process after it exits are dropped,
    %% so no explicit timer cancellation is needed.
    _ = erlang:start_timer(maps:get(timeout, Args), self(), overall_timeout),
    loop(start_head(St)).

loop(St) ->
    #{remaining := Remaining, attempts := Attempts} = St,
    case (map_size(Attempts) =:= 0) andalso (Remaining =:= []) of
        true ->
            finish(St, {error, exhausted_reason(St)});
        false ->
            receive
                {timeout, _Ref, next_attempt} ->
                    loop(start_head(St));
                {timeout, _Ref, overall_timeout} ->
                    finish(St, {error, connect_timeout});
                {quic, Pid, {connected, Info}} ->
                    case maps:is_key(Pid, Attempts) of
                        true -> on_connected(St, Pid, Info);
                        false -> loop(St)
                    end;
                %% Before the generic buffer clause: a failure belongs to the
                %% attempt that reported it, not to the winner's owner.
                {quic, Pid, {error, Reason}} ->
                    loop(note_error(St, Pid, Reason));
                {quic, Pid, {closed, Reason}} ->
                    loop(note_error(St, Pid, Reason));
                {quic, Pid, _} = Msg ->
                    loop(buffer_owner_msg(St, Pid, Msg));
                {'DOWN', _MRef, process, Pid, _Reason} ->
                    loop(drop_attempt(St, Pid));
                _Other ->
                    loop(St)
            after infinity ->
                %% The overall deadline is delivered as an `overall_timeout'
                %% timer message above; this clause only satisfies the linter.
                finish(St, {error, connect_timeout})
            end
    end.

%% Start the next pending address and, if more remain, arm the staggered
%% Connection Attempt Delay timer so the following one starts concurrently.
start_head(#{remaining := []} = St) ->
    St;
start_head(#{remaining := [Addr | Rest], delay := Delay} = St) ->
    St1 = start_attempt(Addr, St#{remaining := Rest}),
    case Rest of
        [] ->
            St1;
        _ ->
            _ = erlang:start_timer(Delay, self(), next_attempt),
            St1
    end.

start_attempt({IP, _Fam}, #{port := Port, opts := Opts, attempts := Attempts} = St) ->
    case quic_conn_sup:start_child(IP, Port, Opts, self()) of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            St#{attempts := maps:put(Pid, MRef, Attempts)};
        {error, _} ->
            %% Immediate start failure (no process): just don't track it; the
            %% termination check / next timer handles progress.
            St
    end.

%% Why an attempt gave up, kept so the caller sees the real reason (a bad
%% certificate, a peer close) rather than only `all_attempts_failed'. The
%% last one wins: the attempts race, and any of them explains the failure.
note_error(#{attempts := Attempts} = St, Pid, Reason) ->
    case maps:is_key(Pid, Attempts) of
        true -> St#{last_error := Reason};
        false -> St
    end.

exhausted_reason(#{last_error := undefined}) -> all_attempts_failed;
exhausted_reason(#{last_error := Reason}) -> Reason.

drop_attempt(#{attempts := Attempts, backlog := Backlog} = St, Pid) ->
    case maps:take(Pid, Attempts) of
        {MRef, Rest} ->
            _ = erlang:demonitor(MRef, [flush]),
            St#{attempts := Rest, backlog := maps:remove(Pid, Backlog)};
        error ->
            St
    end.

%% Owner events an attempt delivers before it reports `connected' (a server
%% that opens its HTTP/3 control stream in the same flight as the handshake
%% sends SETTINGS here). They belong to the winner's owner, so hold them per
%% attempt instead of discarding, and drop them with the attempt that loses.
%% The peer's initial flow-control window bounds what can pile up.
buffer_owner_msg(#{attempts := Attempts, backlog := Backlog} = St, Pid, Msg) ->
    case maps:is_key(Pid, Attempts) of
        true ->
            Buffered = maps:get(Pid, Backlog, []),
            St#{backlog := maps:put(Pid, [Msg | Buffered], Backlog)};
        false ->
            St
    end.

%% First attempt to finish its handshake wins. Hand it to the real owner
%% (re-delivers {connected}); the remaining attempts are still owned by this
%% coordinator and self-close on owner-DOWN when we exit below.
on_connected(#{owner := Owner, caller := Caller, backlog := Backlog} = St, Pid, _Info) ->
    %% set_owner_sync is a gen_statem:call; a winner that died between
    %% {connected} and here raises, and we continue the race.
    try quic_connection:set_owner_sync(Pid, Owner) of
        ok ->
            %% The connection handshaked while we owned it, so any peer data
            %% it already delivered (e.g. the server's HTTP/3 control stream
            %% and SETTINGS) was buffered here or is still sitting in our
            %% mailbox, and would be lost when we exit. set_owner_sync
            %% re-delivers {connected} but not that backlog, so hand it to the
            %% new owner in order.
            [Owner ! M || M <- lists:reverse(maps:get(Pid, Backlog, []))],
            forward_quic_backlog(Pid, Owner),
            Caller ! {quic_happy_result, self(), {ok, Pid}},
            ok
    catch
        _:_ ->
            loop(drop_attempt(St, Pid))
    end.

%% Drain this process's mailbox of `{quic, Conn, _}' messages and forward them
%% to NewOwner in arrival order. {connected} is skipped: set_owner re-delivers
%% it to the new owner already, so forwarding it too would duplicate it.
forward_quic_backlog(Conn, NewOwner) ->
    receive
        {quic, Conn, {connected, _}} ->
            forward_quic_backlog(Conn, NewOwner);
        {quic, Conn, _} = Msg ->
            NewOwner ! Msg,
            forward_quic_backlog(Conn, NewOwner)
    after 0 ->
        ok
    end.

finish(#{caller := Caller}, Result) ->
    Caller ! {quic_happy_result, self(), Result},
    ok.

%%====================================================================
%% Resolution helpers
%%====================================================================

%% @doc Classify a host: a (possibly bracketed) IP literal or a name.
-spec parse_host(inet:ip_address() | binary() | string()) ->
    {literal, inet:ip_address()} | {name, string()}.
parse_host(IP) when is_tuple(IP) ->
    {literal, IP};
parse_host(Host) when is_binary(Host) ->
    parse_host(binary_to_list(Host));
parse_host(Host) when is_list(Host) ->
    Stripped = strip_brackets(Host),
    case inet:parse_address(Stripped) of
        {ok, IP} -> {literal, IP};
        {error, _} -> {name, Stripped}
    end.

resolve_single(Name, inet) ->
    inet:getaddr(Name, inet);
resolve_single(Name, inet6) ->
    inet:getaddr(Name, inet6);
resolve_single(Name, any) ->
    case inet:getaddr(Name, inet) of
        {ok, _} = Ok -> Ok;
        {error, _} -> inet:getaddr(Name, inet6)
    end.

resolve_all(Name, Family) ->
    V6 = lookup(Name, inet6, Family =/= inet),
    V4 = lookup(Name, inet, Family =/= inet6),
    case {V6, V4} of
        {[], []} ->
            {error, nxdomain};
        _ ->
            Tagged6 = [{IP, inet6} || IP <- V6],
            Tagged4 = [{IP, inet} || IP <- V4],
            {ok, interleave(Tagged6, Tagged4)}
    end.

lookup(_Name, _Family, false) ->
    [];
lookup(Name, Family, true) ->
    case inet:getaddrs(Name, Family) of
        {ok, Addrs} -> Addrs;
        {error, _} -> []
    end.

%% @doc RFC 8305 §4 address ordering: interleave families, IPv6 first.
-spec interleave(list(), list()) -> list().
interleave([], L4) ->
    L4;
interleave(L6, []) ->
    L6;
interleave([H6 | T6], [H4 | T4]) ->
    [H6, H4 | interleave(T6, T4)].

with_sni(Opts, Name) ->
    case maps:is_key(server_name, Opts) of
        true -> Opts;
        false -> Opts#{server_name => list_to_binary(Name)}
    end.

strip_brackets([$[ | Rest]) ->
    case lists:reverse(Rest) of
        [$] | RevInner] -> lists:reverse(RevInner);
        _ -> [$[ | Rest]
    end;
strip_brackets(Host) ->
    Host.
