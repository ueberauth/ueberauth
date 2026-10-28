%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%%
%%% @doc HTTP/3 support for hackney.
%%%
%%% This module provides HTTP/3 functionality using pure Erlang QUIC.
%%% It handles stream management, header encoding, and request/response
%%% handling for HTTP/3 connections over QUIC.
%%%
%%% == Usage ==
%%%
%%% ```
%%% %% Make a simple GET request
%%% {ok, Status, Headers, Body} = hackney_h3:request(get, "https://cloudflare.com/")
%%%
%%% %% Make a request with options
%%% {ok, Status, Headers, Body} = hackney_h3:request(get, "https://example.com/",
%%%     [{<<"user-agent">>, <<"hackney/2.0">>}], <<>>, #{timeout => 30000})
%%% '''
%%%

-module(hackney_h3).

-behaviour(gen_server).

-include("hackney.hrl").
-include("hackney_lib.hrl").

-export([
    %% Connection table, created by hackney_sup
    init_table/0,
    %% High-level API
    is_available/0,
    request/2, request/3, request/4, request/5,
    connect/2, connect/3,
    await_response/2,
    %% Request operations (used by hackney_conn)
    send_request/6,
    send_request_headers/5,
    send_body_chunk/4,
    finish_send_body/3,
    %% Stream management
    get_stream_state/2,
    update_stream_state/3,
    %% Response parsing
    parse_response_headers/1,
    cacertfile_ders/1,
    %% 0-RTT / session resumption
    early_data_accepted/1,
    get_session_ticket/1,
    wait_session_ticket/2,
    %% Connection close
    close/1,
    close/2,
    %% Low-level adapter API
    connect/4,
    send_request/3,
    send_data/4,
    reset_stream/3,
    handle_timeout/2,
    process/1,
    get_fd/1,
    peername/1,
    sockname/1,
    peercert/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([maybe_strip_redirect_headers/4]).
-export([body_within_limit/2, remaining/1]).
-export([build_h3_opts/2]).
-endif.

-record(state, {
    h3_conn :: pid() | undefined,
    conn_ref :: reference(),
    owner :: pid(),
    owner_mon :: reference(),
    %% Last 0-RTT/resumption session ticket delivered by quic_h3 (opaque term).
    session_ticket :: term() | undefined
}).

-define(CONN_TABLE, hackney_h3_conns).

%% GHSA-jq4m: the non-streaming await path holds the whole body in memory,
%% so it is capped at ?DEFAULT_MAX_BODY_SIZE (hackney.hrl) unless the
%% `max_body_size' option says otherwise.

-type h3_conn() :: reference().
-type stream_id() :: non_neg_integer().
-type method() :: get | post | put | delete | head | options | patch | atom() | binary().
-type url() :: binary() | string().
-type headers() :: [{binary(), binary()}].
-type body() :: binary() | iodata().
-type response() :: {ok, integer(), headers(), binary()} | {error, term()}.
-type stream_state() :: waiting_headers | {receiving_body, integer(), headers(), binary()} | done.
-type streams_map() :: #{stream_id() => {term(), stream_state()}}.

-export_type([h3_conn/0, stream_id/0, stream_state/0, streams_map/0]).

%%====================================================================
%% High-level API
%%====================================================================

%% @doc Check if HTTP/3/QUIC support is available.
%% Always returns true as pure Erlang implementation is always available.
-spec is_available() -> true.
is_available() -> true.

%% @doc Make an HTTP/3 request with default options.
-spec request(method(), url()) -> response().
request(Method, Url) ->
    request(Method, Url, [], <<>>, #{}).

%% @doc Make an HTTP/3 request with headers.
-spec request(method(), url(), headers()) -> response().
request(Method, Url, Headers) ->
    request(Method, Url, Headers, <<>>, #{}).

%% @doc Make an HTTP/3 request with headers and body.
-spec request(method(), url(), headers(), body()) -> response().
request(Method, Url, Headers, Body) ->
    request(Method, Url, Headers, Body, #{}).

%% @doc Make an HTTP/3 request with all options.
%%
%% Options:
%%   - timeout: Request timeout in milliseconds (default: 30000)
%%   - recv_timeout: Response receive timeout (default: 30000)
%%   - follow_redirect: boolean to follow redirects (default: false)
%%   - max_redirect: maximum number of redirects to follow (default: 5)
%%
-spec request(method(), url(), headers(), body(), map()) -> response().
request(Method, Url, Headers, Body, Opts) ->
    FollowRedirect = maps:get(follow_redirect, Opts, false),
    MaxRedirect = maps:get(max_redirect, Opts, 5),
    do_request_with_redirect(Method, Url, Headers, Body, Opts, FollowRedirect, MaxRedirect, 0).

%% @private Handle request with redirect following
do_request_with_redirect(Method, Url, Headers, Body, Opts, FollowRedirect, MaxRedirect, RedirectCount) ->
    #hackney_url{host = Host, port = Port, path = Path, qs = Qs} = hackney_url:parse_url(Url),
    HostBin = list_to_binary(Host),
    PathBin = case Path of
        <<>> -> <<"/">>;
        _ -> Path
    end,
    %% Include query string if present
    FullPath = case Qs of
        <<>> -> PathBin;
        _ -> <<PathBin/binary, "?", Qs/binary>>
    end,
    Timeout = maps:get(timeout, Opts, 30000),
    MaxBodySize = maps:get(max_body_size, Opts, ?DEFAULT_MAX_BODY_SIZE),
    case h3_connect_for_request(HostBin, Port, Body, Opts) of
        {ok, Conn} ->
            try
                case do_request(Conn, Method, HostBin, FullPath, Headers, Body, Timeout, MaxBodySize) of
                    {ok, Status, RespHeaders, RespBody} when Status >= 301, Status =< 308 ->
                        %% Redirect response
                        handle_redirect(Status, RespHeaders, RespBody, Method, Url, Headers, Body, Opts,
                                        FollowRedirect, MaxRedirect, RedirectCount);
                    Other ->
                        Other
                end
            after
                close(Conn)
            end;
        {error, _} = Error ->
            Error
    end.

%% @private Handle redirect response
handle_redirect(Status, RespHeaders, RespBody, _Method, _Url, _Headers, _Body, _Opts, false, _MaxRedirect, _RedirectCount) ->
    %% follow_redirect is false, return redirect response as-is
    {ok, Status, RespHeaders, RespBody};
handle_redirect(_Status, _RespHeaders, _RespBody, _Method, _Url, _Headers, _Body, _Opts, true, MaxRedirect, RedirectCount)
  when RedirectCount >= MaxRedirect ->
    {error, {max_redirect, RedirectCount}};
handle_redirect(Status, RespHeaders, _RespBody, Method, Url, Headers, Body, Opts, true, MaxRedirect, RedirectCount) ->
    case get_redirect_location(RespHeaders) of
        {ok, Location} ->
            %% Resolve Location to absolute URL
            NewUrl = resolve_redirect_url(Location, Url),
            %% Determine new method based on status code
            NewMethod = redirect_method(Status, Method),
            %% Clear body for POST->GET redirects
            NewBody = case NewMethod of
                get when Method =/= get -> <<>>;
                _ -> Body
            end,
            %% GHSA-h73q: do not forward credential headers to a different
            %% origin unless the caller opted into location_trusted.
            NewHeaders = maybe_strip_redirect_headers(Url, NewUrl, Headers, Opts),
            %% Follow the redirect
            do_request_with_redirect(NewMethod, NewUrl, NewHeaders, NewBody, Opts,
                                     true, MaxRedirect, RedirectCount + 1);
        {error, no_location} ->
            %% No Location header, return as-is
            {ok, Status, RespHeaders, <<>>}
    end.

%% @private Get Location header from response
get_redirect_location(Headers) ->
    case lists:keyfind(<<"location">>, 1, Headers) of
        {_, Location} -> {ok, Location};
        false ->
            %% Try case-insensitive search
            case lists:keyfind(<<"Location">>, 1, Headers) of
                {_, Location} -> {ok, Location};
                false -> {error, no_location}
            end
    end.

%% @private GHSA-h73q: strip Authorization / Cookie / Proxy-Authorization
%% before following a redirect to a different origin (scheme, host or port).
%% location_trusted lets a caller opt back into forwarding them.
maybe_strip_redirect_headers(OldUrl, NewUrl, Headers, Opts) ->
    case maps:get(location_trusted, Opts, false) of
        true -> Headers;
        false ->
            case hackney_url:same_origin(OldUrl, NewUrl) of
                true -> Headers;
                false -> drop_credential_headers(Headers)
            end
    end.

drop_credential_headers(Headers) ->
    Sensitive = [<<"authorization">>, <<"cookie">>, <<"proxy-authorization">>],
    lists:filter(
      fun({Name, _Value}) ->
              not lists:member(hackney_bstr:to_lower(to_bin(Name)), Sensitive)
      end, Headers).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

%% @private Resolve redirect URL relative to original URL
resolve_redirect_url(Location, OriginalUrl) when is_binary(Location) ->
    case Location of
        <<"http://", _/binary>> -> Location;
        <<"https://", _/binary>> -> Location;
        <<"/", _/binary>> ->
            %% Absolute path - use original scheme, host, port
            #hackney_url{scheme = Scheme, host = Host, port = Port} = hackney_url:parse_url(OriginalUrl),
            SchemeBin = atom_to_binary(Scheme),
            HostBin = list_to_binary(Host),
            case {Scheme, Port} of
                {https, 443} -> <<SchemeBin/binary, "://", HostBin/binary, Location/binary>>;
                {http, 80} -> <<SchemeBin/binary, "://", HostBin/binary, Location/binary>>;
                _ ->
                    PortBin = integer_to_binary(Port),
                    <<SchemeBin/binary, "://", HostBin/binary, ":", PortBin/binary, Location/binary>>
            end;
        _ ->
            %% Relative path
            #hackney_url{scheme = Scheme, host = Host, port = Port, path = BasePath} = hackney_url:parse_url(OriginalUrl),
            SchemeBin = atom_to_binary(Scheme),
            HostBin = list_to_binary(Host),
            %% Get directory of base path
            BaseDir = case binary:split(BasePath, <<"/">>, [global, trim]) of
                [] -> <<"/">>;
                Parts ->
                    DirParts = lists:droplast(Parts),
                    case DirParts of
                        [] -> <<"/">>;
                        _ -> iolist_to_binary(["/", lists:join("/", DirParts), "/"])
                    end
            end,
            FullPath = <<BaseDir/binary, Location/binary>>,
            case {Scheme, Port} of
                {https, 443} -> <<SchemeBin/binary, "://", HostBin/binary, FullPath/binary>>;
                {http, 80} -> <<SchemeBin/binary, "://", HostBin/binary, FullPath/binary>>;
                _ ->
                    PortBin = integer_to_binary(Port),
                    <<SchemeBin/binary, "://", HostBin/binary, ":", PortBin/binary, FullPath/binary>>
            end
    end.

%% @private Determine HTTP method after redirect
%% 301, 302, 303: POST/PUT/DELETE -> GET (de facto standard)
%% 307, 308: Preserve original method
redirect_method(Status, Method) when Status =:= 301; Status =:= 302; Status =:= 303 ->
    case Method of
        get -> get;
        head -> head;
        _ -> get  %% POST, PUT, DELETE, etc. become GET
    end;
redirect_method(_Status, Method) ->
    %% 307, 308 preserve method
    Method.

%% @doc Connect to an HTTP/3 server.
-spec connect(binary() | string(), inet:port_number()) -> {ok, reference()} | {error, term()}.
connect(Host, Port) ->
    connect(Host, Port, #{}).

%% @doc Connect to an HTTP/3 server with options.
%% lsquic handles its own UDP socket creation and DNS resolution.
-spec connect(binary() | string(), inet:port_number(), map()) -> {ok, reference()} | {error, term()}.
connect(Host, Port, Opts) when is_list(Host) ->
    connect(list_to_binary(Host), Port, Opts);
connect(Host, Port, Opts) when is_binary(Host) ->
    Timeout = maps:get(timeout, Opts, 30000),
    case connect(Host, Port, Opts, self()) of
        {ok, ConnRef} ->
            wait_connected(ConnRef, Timeout, erlang:monotonic_time(millisecond));
        {error, _} = Error ->
            Error
    end.

%% @doc Wait for an HTTP/3 response.
-spec await_response(reference(), non_neg_integer()) ->
    {ok, integer(), headers(), binary()} | {error, term()}.
await_response(ConnRef, StreamId) ->
    await_response_loop(ConnRef, StreamId, 30000, ?DEFAULT_MAX_BODY_SIZE).

%%====================================================================
%% Request operations (used by hackney_conn)
%%====================================================================

%% @doc Send a complete HTTP/3 request (headers + body).
%% Returns {ok, StreamId, UpdatedStreams} or {error, Reason}.
-spec send_request(h3_conn(), method(), binary(), binary(), headers(), binary()) ->
    {ok, stream_id(), streams_map()} | {error, term()}.
send_request(ConnRef, Method, Host, Path, Headers, Body) ->
    AllHeaders = build_request_headers(Method, Host, Path, Headers),
    HasBody = Body =/= <<>> andalso Body =/= [],
    Fin = not HasBody,
    case send_request(ConnRef, AllHeaders, Fin) of
        {ok, StreamId} when HasBody ->
            case send_data(ConnRef, StreamId, Body, true) of
                ok ->
                    {ok, StreamId, #{StreamId => {undefined, waiting_headers}}};
                {error, _} = Error ->
                    Error
            end;
        {ok, StreamId} ->
            {ok, StreamId, #{StreamId => {undefined, waiting_headers}}};
        {error, _} = Error ->
            Error
    end.

%% @doc Send HTTP/3 request headers only (for streaming body).
%% Returns {ok, StreamId, UpdatedStreams} or {error, Reason}.
-spec send_request_headers(h3_conn(), method(), binary(), binary(), headers()) ->
    {ok, stream_id(), streams_map()} | {error, term()}.
send_request_headers(ConnRef, Method, Host, Path, Headers) ->
    AllHeaders = build_request_headers(Method, Host, Path, Headers),
    case send_request(ConnRef, AllHeaders, false) of
        {ok, StreamId} ->
            {ok, StreamId, #{StreamId => {undefined, waiting_headers}}};
        {error, _} = Error ->
            Error
    end.

%% @doc Send a chunk of body data on a stream.
-spec send_body_chunk(h3_conn(), stream_id(), binary(), boolean()) ->
    ok | {error, term()}.
send_body_chunk(ConnRef, StreamId, Data, Fin) ->
    send_data(ConnRef, StreamId, Data, Fin).

%% @doc Finish sending body (close stream for writing).
-spec finish_send_body(h3_conn(), stream_id(), streams_map()) ->
    {ok, streams_map()} | {error, term()}.
finish_send_body(ConnRef, StreamId, Streams) ->
    case send_data(ConnRef, StreamId, <<>>, true) of
        ok ->
            {ok, Streams};
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% Stream management
%%====================================================================

%% @doc Get the state of a specific stream.
-spec get_stream_state(stream_id(), streams_map()) ->
    {ok, {term(), stream_state()}} | {error, not_found}.
get_stream_state(StreamId, Streams) ->
    case maps:find(StreamId, Streams) of
        {ok, State} -> {ok, State};
        error -> {error, not_found}
    end.

%% @doc Update the state of a stream.
-spec update_stream_state(stream_id(), {term(), stream_state()}, streams_map()) ->
    streams_map().
update_stream_state(StreamId, State, Streams) ->
    maps:put(StreamId, State, Streams).

%%====================================================================
%% Response parsing
%%====================================================================

%% @doc Parse response headers from a QUIC stream_headers event.
%% Returns {ok, Status, ResponseHeaders} or {error, Reason}.
-spec parse_response_headers(headers()) -> {ok, integer(), headers()} | {error, term()}.
parse_response_headers(Headers) ->
    case get_status_from_headers(Headers) of
        {ok, Status} ->
            RespHeaders = filter_pseudo_headers(Headers),
            {ok, Status, RespHeaders};
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% Connection close
%%====================================================================

%% @doc Close the HTTP/3 connection.
-spec close(h3_conn()) -> ok.
close(ConnRef) ->
    close(ConnRef, normal).

%% @doc Close the HTTP/3 connection with a reason.
-spec close(h3_conn(), term()) -> ok.
close(ConnRef, Reason) ->
    with_pid(ConnRef, fun(Pid) -> gen_server:cast(Pid, {close, Reason}) end, ok).

%%====================================================================
%% Internal functions
%%====================================================================

%% Drive QUIC event loop until connected
wait_connected(ConnRef, Timeout, StartTime) ->
    Elapsed = erlang:monotonic_time(millisecond) - StartTime,
    Remaining = max(0, Timeout - Elapsed),
    receive
        {select, _Resource, _Ref, ready_input} ->
            _ = process(ConnRef),
            wait_connected(ConnRef, Timeout, StartTime);
        {h3, ConnRef, {connected, _Info}} ->
            {ok, ConnRef};
        {h3, ConnRef, {closed, Reason}} ->
            {error, {connection_closed, Reason}};
        {h3, ConnRef, {transport_error, Code, Msg}} ->
            {error, {transport_error, Code, Msg}};
        {h3, ConnRef, {settings, _Settings}} ->
            %% HTTP/3 SETTINGS frame - ignore and continue waiting
            wait_connected(ConnRef, Timeout, StartTime);
        {h3, ConnRef, {session_ticket, _Ticket}} ->
            %% Resumption ticket - kept in the adapter state; ignore here
            wait_connected(ConnRef, Timeout, StartTime);
        {h3, ConnRef, {early_data_rejected, _Ids}} ->
            %% Not expected before connected on this path; ignore
            wait_connected(ConnRef, Timeout, StartTime)
    after Remaining ->
        close(ConnRef, timeout),
        {error, timeout}
    end.

%% @private Connect for a one-shot request, choosing the 0-RTT no-wait path.
%% True request-in-0-RTT only carries HEADERS (quic_h3 serves `request' but not
%% `send_data' in the early_data state), so it is used only for bodyless
%% requests with `zero_rtt' enabled and a `session_ticket' present. Otherwise we
%% wait for `connected' (1-RTT; still a resumed/abbreviated handshake when a
%% ticket is supplied).
h3_connect_for_request(HostBin, Port, Body, Opts) ->
    HasBody = Body =/= <<>> andalso Body =/= [],
    ZeroRtt = maps:get(zero_rtt, Opts, true)
              andalso maps:is_key(session_ticket, Opts)
              andalso (not HasBody),
    case ZeroRtt of
        true ->
            %% No-wait: the adapter is started and the request is sent while the
            %% connection is in early_data, riding 0-RTT.
            connect(HostBin, Port, Opts, self());
        false ->
            connect(HostBin, Port, Opts)
    end.

do_request(ConnRef, Method, Host, Path, Headers, Body, Timeout, MaxBodySize) ->
    do_request(ConnRef, Method, Host, Path, Headers, Body, Timeout, MaxBodySize, false).

do_request(ConnRef, Method, Host, Path, Headers, Body, Timeout, MaxBodySize, Retried) ->
    AllHeaders = build_request_headers(Method, Host, Path, Headers),
    HasBody = Body =/= <<>> andalso Body =/= [],
    Fin = not HasBody,
    Result = case send_request(ConnRef, AllHeaders, Fin) of
        {ok, StreamId} when HasBody ->
            case send_data(ConnRef, StreamId, Body, true) of
                ok ->
                    await_response_loop(ConnRef, StreamId, Timeout, MaxBodySize);
                {error, _} = Error ->
                    Error
            end;
        {ok, StreamId} ->
            await_response_loop(ConnRef, StreamId, Timeout, MaxBodySize);
        {error, _} = Error ->
            Error
    end,
    case Result of
        {error, early_data_rejected} when not Retried ->
            %% Server rejected 0-RTT; the connection is now past the handshake,
            %% so retry once on the same connection at 1-RTT.
            do_request(ConnRef, Method, Host, Path, Headers, Body, Timeout, MaxBodySize, true);
        _ ->
            Result
    end.

%% @private Wait for HTTP/3 response.
%% GHSA-jq4m: `Timeout' is an absolute wall-clock deadline for the whole
%% response, not a per-chunk timer; a peer that dribbles a byte just before
%% each chunk deadline used to reset it forever. The accumulated body is also
%% capped at MaxBodySize so a slow- or fast-drip cannot exhaust memory.
await_response_loop(ConnRef, StreamId, Timeout, MaxBodySize) ->
    Deadline = case Timeout of
                   infinity -> infinity;
                   _ -> erlang:monotonic_time(millisecond) + Timeout
               end,
    await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, undefined, [], <<>>).

await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, Status, Headers, AccBody) ->
    receive
        {select, _Resource, _Ref, ready_input} ->
            _ = process(ConnRef),
            await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, Status, Headers, AccBody);
        {h3, ConnRef, {stream_headers, StreamId, RespHeaders, Fin}} ->
            NewStatus = get_status(RespHeaders),
            FilteredHeaders = filter_pseudo_headers(RespHeaders),
            case Fin of
                true ->
                    %% Headers with Fin=true means no body (e.g., HEAD response, 204, 304)
                    {ok, NewStatus, FilteredHeaders, AccBody};
                false ->
                    await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, NewStatus, FilteredHeaders, AccBody)
            end;
        {h3, ConnRef, {stream_data, StreamId, Data, Fin}} ->
            NewBody = <<AccBody/binary, Data/binary>>,
            case body_within_limit(byte_size(NewBody), MaxBodySize) of
                false ->
                    {error, body_too_large};
                true ->
                    case Fin of
                        true ->
                            {ok, Status, Headers, NewBody};
                        false ->
                            await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, Status, Headers, NewBody)
                    end
            end;
        {h3, ConnRef, {stream_reset, StreamId, _ErrorCode}} ->
            {error, stream_reset};
        {h3, ConnRef, {closed, Reason}} ->
            {error, {connection_closed, Reason}};
        {h3, ConnRef, {settings, _Settings}} ->
            %% HTTP/3 SETTINGS frame - ignore and continue waiting
            await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, Status, Headers, AccBody);
        {h3, ConnRef, {connected, _Info}} ->
            %% 0-RTT no-wait path: the request was sent before `connected'.
            %% Ignore the late connected event and keep awaiting the response.
            await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, Status, Headers, AccBody);
        {h3, ConnRef, {session_ticket, _Ticket}} ->
            %% Resumption ticket - kept in the adapter state; ignore here
            await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, Status, Headers, AccBody);
        {h3, ConnRef, {early_data_rejected, _Ids}} ->
            %% Server rejected 0-RTT; the request stream was reset. Surface a
            %% distinct error so the caller can retry once at 1-RTT.
            {error, early_data_rejected};
        {h3, ConnRef, {goaway, GoawayId}} when StreamId >= GoawayId ->
            %% RFC 9114 5.2: the GOAWAY refused this request.
            {error, goaway};
        {h3, ConnRef, {goaway, _GoawayId}} ->
            %% Accepted before the GOAWAY: the response still comes.
            await_response_loop(ConnRef, StreamId, Deadline, MaxBodySize, Status, Headers, AccBody)
    after remaining(Deadline) ->
        {error, timeout}
    end.

%% @private Milliseconds left until the absolute deadline.
remaining(infinity) -> infinity;
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% @private GHSA-jq4m: bound the buffered body size.
body_within_limit(_Size, infinity) -> true;
body_within_limit(Size, Max) -> Size =< Max.

%% @private Build HTTP/3 request headers including pseudo-headers.
-spec build_request_headers(method(), binary(), binary(), headers()) -> headers().
build_request_headers(Method, Host, Path, Headers) ->
    MethodBin = method_to_binary(Method),
    PseudoHeaders = [
        {<<":method">>, MethodBin},
        {<<":path">>, Path},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, Host}
    ],
    PseudoHeaders ++ normalize_headers(Headers).

%% @private Convert HTTP method to binary.
-spec method_to_binary(method()) -> binary().
method_to_binary(get) -> <<"GET">>;
method_to_binary(post) -> <<"POST">>;
method_to_binary(put) -> <<"PUT">>;
method_to_binary(delete) -> <<"DELETE">>;
method_to_binary(head) -> <<"HEAD">>;
method_to_binary(options) -> <<"OPTIONS">>;
method_to_binary(patch) -> <<"PATCH">>;
method_to_binary(query) -> <<"QUERY">>;
method_to_binary(Method) when is_atom(Method) ->
    string:uppercase(atom_to_binary(Method));
method_to_binary(Method) when is_binary(Method) ->
    Method.

%% @private Normalize headers to binary key-value pairs.
-spec normalize_headers(headers()) -> headers().
normalize_headers(Headers) ->
    [{ensure_binary(K), ensure_binary(V)} || {K, V} <- Headers].

%% @private Ensure value is binary.
-spec ensure_binary(term()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> list_to_binary(L);
ensure_binary(A) when is_atom(A) -> atom_to_binary(A).

%% @private Extract status from HTTP/3 response headers (returns integer or 0).
-spec get_status(headers()) -> integer().
get_status(Headers) ->
    case lists:keyfind(<<":status">>, 1, Headers) of
        {_, StatusBin} ->
            binary_to_integer(StatusBin);
        false ->
            0
    end.

%% @private Extract status from HTTP/3 response headers (returns ok/error tuple).
-spec get_status_from_headers(headers()) -> {ok, integer()} | {error, no_status | {invalid_status, binary()}}.
get_status_from_headers(Headers) ->
    case lists:keyfind(<<":status">>, 1, Headers) of
        {_, StatusBin} ->
            try
                {ok, binary_to_integer(StatusBin)}
            catch
                error:badarg -> {error, {invalid_status, StatusBin}}
            end;
        false ->
            {error, no_status}
    end.

%% @private Filter out pseudo-headers from response.
-spec filter_pseudo_headers(headers()) -> headers().
filter_pseudo_headers(Headers) ->
    [{K, V} || {K, V} <- Headers, not is_pseudo_header(K)].

%% @private Check if header is a pseudo-header (starts with ':').
-spec is_pseudo_header(binary()) -> boolean().
is_pseudo_header(<<$:, _/binary>>) -> true;
is_pseudo_header(_) -> false.

%%====================================================================
%% Low-level adapter API (gen_server-backed)
%%
%% Messages delivered to the owner:
%%   {h3, ConnRef, {connected, Info}}
%%   {h3, ConnRef, {stream_headers, StreamId, Headers, Fin}}
%%   {h3, ConnRef, {stream_data, StreamId, Bin, Fin}}
%%   {h3, ConnRef, {stream_reset, StreamId, ErrorCode}}
%%   {h3, ConnRef, {goaway, LastStreamId}}
%%   {h3, ConnRef, {closed, Reason}}
%%   {h3, ConnRef, {transport_error, Code, Reason}}
%%====================================================================

-spec get_fd(gen_udp:socket()) -> {ok, integer()} | {error, term()}.
get_fd(Socket) ->
    inet:getfd(Socket).

-spec connect(Host, Port, Opts, Owner) -> {ok, reference()} | {error, term()}
    when Host :: binary() | string(),
         Port :: inet:port_number(),
         Opts :: map(),
         Owner :: pid().
connect(Host, Port, Opts, Owner) when is_list(Host) ->
    connect(list_to_binary(Host), Port, Opts, Owner);
connect(Host, Port, Opts, Owner) when is_binary(Host), is_integer(Port),
                                       Port > 0, Port =< 65535,
                                       is_map(Opts), is_pid(Owner) ->
    case gen_server:start(?MODULE, {Host, Port, Opts, Owner}, []) of
        {ok, Pid} ->
            gen_server:call(Pid, get_conn_ref);
        {error, _} = Error ->
            Error
    end;
connect(_Host, _Port, _Opts, _Owner) ->
    {error, badarg}.

-spec send_request(reference(), [{binary(), binary()}], boolean()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(ConnRef, Headers, Fin) when is_list(Headers), is_boolean(Fin) ->
    with_pid(ConnRef,
             fun(Pid) -> gen_server:call(Pid, {send_request, Headers, Fin}) end,
             {error, not_connected}).

-spec send_data(reference(), non_neg_integer(), iodata(), boolean()) ->
    ok | {error, term()}.
send_data(ConnRef, StreamId, Data, Fin) when is_boolean(Fin) ->
    with_pid(ConnRef,
             fun(Pid) -> gen_server:call(Pid, {send_data, StreamId, Data, Fin}) end,
             {error, not_connected});
send_data(_ConnRef, _StreamId, _Data, _Fin) ->
    {error, badarg}.

-spec reset_stream(reference(), non_neg_integer(), non_neg_integer()) ->
    ok | {error, term()}.
reset_stream(ConnRef, StreamId, ErrorCode)
  when is_integer(ErrorCode), ErrorCode >= 0 ->
    with_pid(ConnRef,
             fun(Pid) -> gen_server:call(Pid, {reset_stream, StreamId, ErrorCode}) end,
             {error, not_connected});
reset_stream(_ConnRef, _StreamId, _ErrorCode) ->
    {error, badarg}.

-spec handle_timeout(reference(), non_neg_integer()) -> non_neg_integer() | infinity.
handle_timeout(_ConnRef, _NowMs) ->
    infinity.

-spec process(reference()) -> non_neg_integer() | infinity.
process(_ConnRef) ->
    infinity.

-spec peername(reference()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(ConnRef) ->
    quic_call(ConnRef, peername).

-spec sockname(reference()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
sockname(ConnRef) ->
    quic_call(ConnRef, sockname).

-spec peercert(reference()) -> {ok, binary()} | {error, term()}.
peercert(ConnRef) ->
    quic_call(ConnRef, peercert).

%% @doc Whether the server accepted 0-RTT early data, or `unknown' before the
%% handshake completes.
-spec early_data_accepted(reference()) -> boolean() | unknown | {error, term()}.
early_data_accepted(ConnRef) ->
    with_pid(ConnRef,
             fun(Pid) -> gen_server:call(Pid, early_data_accepted) end,
             {error, not_connected}).

%% @doc Return the last session ticket delivered for this connection, or
%% `undefined' if none has arrived yet. See {@link wait_session_ticket/2} to
%% block until one is available.
-spec get_session_ticket(reference()) -> term() | undefined | {error, term()}.
get_session_ticket(ConnRef) ->
    with_pid(ConnRef,
             fun(Pid) -> gen_server:call(Pid, get_session_ticket) end,
             {error, not_connected}).

%% @doc Block until a session ticket is delivered to the owner, up to `Timeout'
%% ms. The caller must be the connection owner (the process that called
%% {@link connect/4}). Returns `{ok, Ticket}' or `{error, timeout}'.
-spec wait_session_ticket(reference(), timeout()) ->
    {ok, term()} | {error, timeout}.
wait_session_ticket(ConnRef, Timeout) ->
    receive
        {h3, ConnRef, {session_ticket, Ticket}} -> {ok, Ticket}
    after Timeout -> {error, timeout}
    end.

quic_call(ConnRef, Op) ->
    with_pid(ConnRef,
             fun(Pid) -> gen_server:call(Pid, {quic_op, Op}) end,
             {error, not_connected}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Host, Port, Opts, Owner}) ->
    MonRef = erlang:monitor(process, Owner),
    H3Opts = build_h3_opts(Host, Opts),
    case quic_h3:connect(Host, Port, H3Opts) of
        {ok, H3Conn} ->
            ConnRef = make_ref(),
            ok = init_table(),
            ets:insert(?CONN_TABLE, {ConnRef, self()}),
            {ok, #state{h3_conn = H3Conn,
                        conn_ref = ConnRef,
                        owner = Owner,
                        owner_mon = MonRef}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(get_conn_ref, _From, #state{conn_ref = Ref} = State) ->
    {reply, {ok, Ref}, State};

handle_call({send_request, Headers, Fin}, _From, #state{h3_conn = Conn} = State) ->
    case quic_h3:request(Conn, Headers, #{end_stream => Fin}) of
        {ok, StreamId} ->
            {reply, {ok, StreamId}, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;

handle_call({send_data, StreamId, Data, Fin}, _From, #state{h3_conn = Conn} = State) ->
    Bin = iolist_to_binary(Data),
    {reply, quic_h3:send_data(Conn, StreamId, Bin, Fin), State};

handle_call({reset_stream, StreamId, ErrorCode}, _From, #state{h3_conn = Conn} = State) ->
    {reply, quic_h3:cancel(Conn, StreamId, ErrorCode), State};

handle_call({quic_op, Op}, _From, #state{h3_conn = Conn} = State)
  when Op =:= peername; Op =:= sockname; Op =:= peercert ->
    Reply = try
        quic:Op(quic_h3:get_quic_conn(Conn))
    catch
        _:Reason -> {error, Reason}
    end,
    {reply, Reply, State};

handle_call(early_data_accepted, _From, #state{h3_conn = Conn} = State) ->
    Reply = try quic_h3:early_data_accepted(Conn)
            catch _:Reason -> {error, Reason}
            end,
    {reply, Reply, State};

handle_call(get_session_ticket, _From, #state{session_ticket = Ticket} = State) ->
    {reply, Ticket, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({close, _Reason}, #state{h3_conn = Conn} = State) ->
    close_h3(Conn),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({quic_h3, Conn, connected},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    Owner ! {h3, Ref, {connected, #{}}},
    {noreply, State};

handle_info({quic_h3, Conn, {response, StreamId, Status, Headers}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    %% quic_h3 passes the status separately and keeps it in the header list,
    %% so drop it there before prepending the authoritative one: two
    %% `:status' make a malformed response (RFC 9114 4.3.1).
    Rest = [H || {Name, _} = H <- Headers, Name =/= <<":status">>],
    Full = [{<<":status">>, integer_to_binary(Status)} | Rest],
    Owner ! {h3, Ref, {stream_headers, StreamId, Full, false}},
    {noreply, State};

handle_info({quic_h3, Conn, {data, StreamId, Data, Fin}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    Owner ! {h3, Ref, {stream_data, StreamId, Data, Fin}},
    {noreply, State};

handle_info({quic_h3, Conn, {trailers, StreamId, Trailers}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    Owner ! {h3, Ref, {stream_headers, StreamId, Trailers, true}},
    {noreply, State};

handle_info({quic_h3, Conn, {stream_reset, StreamId, ErrorCode}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    Owner ! {h3, Ref, {stream_reset, StreamId, ErrorCode}},
    {noreply, State};

handle_info({quic_h3, Conn, {goaway, LastStreamId}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    Owner ! {h3, Ref, {goaway, LastStreamId}},
    {noreply, State};

handle_info({quic_h3, Conn, {goaway_sent, _}}, #state{h3_conn = Conn} = State) ->
    {noreply, State};

handle_info({quic_h3, Conn, {session_ticket, Ticket}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    %% 0-RTT/resumption: keep the latest ticket and forward to the owner so the
    %% pooled path (hackney_conn) can cache it.
    Owner ! {h3, Ref, {session_ticket, Ticket}},
    {noreply, State#state{session_ticket = Ticket}};

handle_info({quic_h3, Conn, {early_data_rejected, StreamIds}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    Owner ! {h3, Ref, {early_data_rejected, StreamIds}},
    {noreply, State};

handle_info({quic_h3, Conn, {closed, Reason}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    %% quic_h3 reports why the connection went away: `normal' for a local
    %% close or a drained GOAWAY, `owner_down', an {h3_error, Code, Phrase},
    %% or whatever QUIC reported. A failure before HTTP/3 comes up (a bad
    %% certificate, a TLS alert) arrives here too, so pass the reason on
    %% rather than letting the caller wait out its timeout.
    Owner ! {h3, Ref, {closed, Reason}},
    {stop, normal, State};

handle_info({quic_h3, Conn, closed},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    %% quic =< 1.10.0 closes without a reason on the local-close and
    %% QUIC-down paths.
    Owner ! {h3, Ref, {closed, normal}},
    {stop, normal, State};

handle_info({quic_h3, Conn, {error, Code, Reason}},
            #state{h3_conn = Conn, conn_ref = Ref, owner = Owner} = State) ->
    Owner ! {h3, Ref, {transport_error, Code, Reason}},
    {stop, {transport_error, Code}, State};

handle_info({'DOWN', MonRef, process, _Pid, _Reason},
            #state{owner_mon = MonRef, h3_conn = Conn} = State) ->
    close_h3(Conn),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn_ref = Ref, h3_conn = Conn}) ->
    case ets:whereis(?CONN_TABLE) of
        undefined -> ok;
        _ -> ets:delete(?CONN_TABLE, Ref)
    end,
    case Conn of
        undefined -> ok;
        _ -> close_h3(Conn)
    end,
    ok.

%%====================================================================
%% Internal adapter helpers
%%====================================================================

%% @private Close a QUIC/HTTP3 connection, tolerating an already-closed one.
close_h3(Conn) ->
    try quic_h3:close(Conn) catch _:_ -> ok end.

build_h3_opts(Host, Opts) ->
    HostStr = binary_to_list(Host),
    Verify = case maps:get(insecure_skip_verify, Opts, false) of
        true -> verify_none;
        false ->
            case maps:get(verify, Opts, verify_peer) of
                verify_peer -> verify_peer;
                verify_none -> verify_none;
                true -> verify_peer;
                false -> verify_none
            end
    end,
    %% SNI: a user override wins (`disable' suppresses it); otherwise default
    %% to the host, unless it is an IP literal (RFC 6066 forbids SNI for IPs).
    QuicOpts0 = case maps:get(server_name_indication, Opts, undefined) of
        undefined ->
            case hackney_url:is_ip_literal(HostStr) of
                true -> #{};
                false -> #{server_name_indication => HostStr}
            end;
        disable -> #{};
        Sni -> #{server_name_indication => Sni}
    end,
    %% quic takes trust anchors as DER `cacerts' only, so a cacertfile is
    %% decoded here; passed through as is, quic ignored it.
    QuicOpts1 = case maps:get(cacerts, Opts, undefined) of
        undefined ->
            case maps:get(cacertfile, Opts, undefined) of
                undefined -> QuicOpts0;
                File -> QuicOpts0#{cacerts => cacertfile_ders(File)}
            end;
        CACerts -> QuicOpts0#{cacerts => CACerts}
    end,
    %% IPv6: forward the address family (inet|inet6) and happy_eyeballs toggle
    %% to quic, which does DNS + RFC 8305 Happy Eyeballs internally.
    QuicOpts2 = case maps:get(family, Opts, undefined) of
        undefined -> QuicOpts1;
        Family -> QuicOpts1#{family => Family}
    end,
    QuicOpts3 = case maps:get(happy_eyeballs, Opts, undefined) of
        undefined -> QuicOpts2;
        Happy -> QuicOpts2#{happy_eyeballs => Happy}
    end,
    %% 0-RTT / resumption: forward an opaque session ticket when supplied.
    QuicOpts = case maps:get(session_ticket, Opts, undefined) of
        undefined -> QuicOpts3;
        Ticket -> QuicOpts3#{session_ticket => Ticket}
    end,
    Base = #{verify => Verify, quic_opts => QuicOpts},
    case maps:get(settings, Opts, undefined) of
        undefined -> Base;
        Settings -> Base#{settings => Settings}
    end.

%% @doc Read a PEM CA file into the DER certificates quic takes as `cacerts'.
%% An unreadable file gives no anchors, so verification fails closed.
-spec cacertfile_ders(file:filename_all()) -> [public_key:der_encoded()].
cacertfile_ders(File) ->
    case file:read_file(File) of
        {ok, Pem} -> [Der || {'Certificate', Der, _} <- public_key:pem_decode(Pem)];
        {error, _} -> []
    end.

%% @doc Create the table mapping connection refs to their processes. hackney_sup
%% calls this at start so the table outlives every connection: owned by the
%% first connection, it vanished when that one closed and took every other
%% live connection's entry with it. The call in init/1 only covers hackney_h3
%% used without the hackney application.
-spec init_table() -> ok.
init_table() ->
    case ets:whereis(?CONN_TABLE) of
        undefined ->
            try
                _ = ets:new(?CONN_TABLE,
                            [named_table, public, set, {read_concurrency, true}]),
                ok
            catch
                error:badarg -> ok
            end;
        _ -> ok
    end.

with_pid(ConnRef, Fun, Default) ->
    case ets:whereis(?CONN_TABLE) of
        undefined -> Default;
        _ ->
            case ets:lookup(?CONN_TABLE, ConnRef) of
                [{ConnRef, Pid}] -> Fun(Pid);
                [] -> Default
            end
    end.
