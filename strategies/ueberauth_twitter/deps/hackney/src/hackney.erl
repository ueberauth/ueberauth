%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%

-module(hackney).

-export([connect/1, connect/2, connect/3, connect/4,
         close/1,
         peername/1,
         sockname/1,
         request_info/1,
         location/1,
         request/1, request/2, request/3, request/4, request/5,
         send_request/2, send_request/3,
         start_response/1,
         cookies/1,
         send_body/2, finish_send_body/1,
         send_multipart_body/2,
         body/1, body/2, skip_body/1,
         stream_body/1,
         stream_multipart/1,
         skip_multipart/1,
         controlling_process/2,
         cancel_request/1,
         setopts/2]).

-export([redirect_location/1]).

-export([stream_next/1,
         stop_async/1,
         pause_stream/1,
         resume_stream/1]).

-define(METHOD_TPL(Method),
  -export([Method/1, Method/2, Method/3, Method/4])).
-include("hackney_methods.hrl").

-include("hackney.hrl").
-include("hackney_lib.hrl").
-include("hackney_internal.hrl").


-type url() :: #hackney_url{} | binary().
-export_type([url/0]).

-type client() :: #client{}.
-export_type([client/0]).

-type client_ref() :: term().
-export_type([client_ref/0]).

connect(URL) ->
  connect(URL, []).

connect(#hackney_url{}=URL, Options) ->
  #hackney_url{transport=Transport,
    host=Host,
    port=Port} = URL,
  connect(Transport, Host, Port, Options);
connect(URL, Options) when is_binary(URL) orelse is_list(URL) ->
  connect(hackney_url:parse_url(URL), Options).

%% @doc connect a socket and create a client state.
connect(Transport, Host, Port) ->
  hackney_connect:connect(Transport, Host, Port, []).

connect(Transport, Host, Port, Options) ->
  hackney_connect:connect(Transport, Host, Port, Options).

%% @doc Assign a new controlling process <em>Pid</em> to <em>Client</em>.
-spec controlling_process(client_ref(), pid())
    -> ok | {error, closed | not_owner | atom()}.
controlling_process(Ref, Pid) ->
  hackney_manager:controlling_process(Ref, Pid).

%% @doc Extract raw information from the client context
%% This feature can be useful when you want to create a simple proxy, rerouting
%% on the headers and the status line and continue to forward the connection for example.
%%
%% return: `{ResponseState, Transport, Socket, Buffer} | {error, Reason}'
%% <ul>
%% <li>`Response': waiting_response, on_status, on_headers, on_body</li>
%% <li>`Transport': The current transport module</li>
%% <li>`Socket': the current socket</li>
%% <li>`Buffer': Data fetched but not yet processed</li>
%% </ul>
-spec cancel_request(client_ref()) ->
  {ok, {atom(), inet:socket(), binary(), hackney_response:response_state()}}
  | {error, term()}.
cancel_request(Ref) ->
  hackney_manager:cancel_request(Ref).

%% @doc set client options.
%% Options are:
%% <ul>
%%  <li>`async': to fetch the response asynchronously</li>
%%  <li>`{async, once}': to receive the response asynchronously one time.
%%  To receive the next message use the function `hackney:stream_next/1'.</li>
%%  <li>`{stream_to, pid()}': to set the pid where the messages of an
%%  asynchronous response will be sent.</li>
%%  <li>`{follow_redirect, bool()}' : if true a redirection will be
%%  followed when the response is received synchronously</li>
%%  <li>`{force_redirect, bool()}' : if true a 301/302 redirection will be
%%  followed even on POST.</li>
%%  <li>`{max_redirect, integer()}' the maximum number of redirections that
%%  will be followed</li>
%% </ul>
-spec setopts(client_ref(), list()) -> ok.
setopts(Ref, Options) ->
  hackney_manager:get_state(Ref, fun(State) ->
    State2 = parse_options(Options, State),
    hackney_manager:update_state(Ref, State2)
                                 end),
  ok.

%% @doc close the client
close(Ref) ->
  hackney_connect:close(Ref).


%% @doc peername of the client
peername(Ref) ->
  hackney_connect:peername(Ref).

%% @doc sockname of the client
sockname(Ref) ->
  hackney_connect:sockname(Ref).

%% @doc get request info
-spec request_info(client_ref()) -> list().
request_info(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    #client{transport=Transport,
      socket=Socket,
      method=Method} = State,

    Location = hackney_request:location(State),

    [{method, Method},
      {location, Location},
      {transport, Transport},
      {socket, Socket}]
                                 end).

%% @doc return the requested location
-spec location(client_ref()) -> binary().
location(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    hackney_request:location(State)
                                 end).


%% @doc make a request
-spec request(url()|binary()|list())
    -> {ok, integer(), list(), client_ref()}
  | {ok, integer(), list()}
  | {error, term()}.
request(URL) ->
  request(get, URL).

%% @doc make a request
-spec request(term(), url()|binary()|list())
    -> {ok, integer(), list(), client_ref()}
  | {ok, integer(), list()}
  | {error, term()}.
request(Method, URL) ->
  request(Method, URL, [], <<>>, []).

%% @doc make a request
-spec request(term(), url()|binary()|list(), list())
    -> {ok, integer(), list(), client_ref()}
  | {ok, integer(), list()}
  | {error, term()}.
request(Method, URL, Headers) ->
  request(Method, URL, Headers, <<>>, []).

%% @doc make a request
-spec request(term(), url()|binary()|list(), list(), term())
    -> {ok, integer(), list(), client_ref()}
  | {ok, integer(), list()}
  | {error, term()}.
request(Method, URL, Headers, Body) ->
  request(Method, URL, Headers, Body, []).

%% @doc make a request
%%
%% Args:
%% <ul>
%% <li><strong>Method</strong>>: method used for the request (get, post,
%% ...)</li>
%% <li><strong>Url</strong>: full url of the request</li>
%% <li><strong>Headers</strong> Proplists </li>
%% <li><strong>Body</strong>:
%%      <ul>
%%      <li>{form, [{K, V}, ...]}: send a form url encoded</li>
%%      <li>{multipart, [{K, V}, ...]}: send a form using multipart</li>
%%      <li>{file, "/path/to/file"}: to send a file</li>
%%      <li>Bin: binary or iolist</li>
%%      </ul>
%%  </li>
%%  <li><strong>Options:</strong> `[{connect_options, connect_options(),
%%  {ssl_options, ssl_options()}, Others]'</li>
%%      <li>`connect_options()': The default connect_options are
%%      `[binary, {active, false}, {packet, raw}])'. For valid options
%%      see the gen_tcp options.</li>
%%
%%      <li>`ssl_options()': See the ssl options from the ssl
%%      module.</li>
%%
%%      <li>`with_body': when this option is passed the body is returned
%%      directly. The response is `{ok, Status, Headers, Body}'</li>
%%      <li>`max_body': sets maximum allowed size of the body if
%%      with_body is true</li>
%%      <li>`async': receive the response asynchronously
%%      The function return {ok, StreamRef}.
%%      When {async, once} is used the response will be received only once. To
%%      receive the other messages use the function
%%      `hackney:stream_next/1'
%%      </li>
%%      <li>`{path_encode_fun, fun()}': function used to encode the path. if
%%      not set it will use `hackney_url:pathencode/1' the function takes the
%%      binary path as entry and return a new encoded path.</li>
%%
%%      <li>`{stream_to, pid()}': If async is true or once, the response
%%      messages will be sent to this PID.</li>
%%
%%      <li>`{cookie, list() | binary()}' : to set a cookie or a
%%      list of cookies.</li>
%%
%%      <li><em>Others options are</em>:
%%      <ul>
%%          <li>`{follow_redirect, boolean}': false by default, follow a
%%          redirection</li>
%%          <li>`{max_redirect, integer}': 5 by default, the maximum of
%%          redirection for a request</li>
%%          <li>`{force_redirect, boolean}': false by default, to force the
%%          redirection even on POST</li>
%%          <li>`{basic_auth, {binary, binary}}`: HTTP basic auth username and password. 
%%          Only allowed over HTTPS unless {insecure_basic_auth, true} is also set.</li>
%%          <li>`{insecure_basic_auth, boolean}': true by default. When true, allows 
%%          basic auth over unencrypted HTTP connections (security risk). 
%%          Can also be set globally via application:set_env(hackney, insecure_basic_auth, false).</li>
%%          <li>`{proxy, proxy_options()}': to connect via a proxy.</li>
%%          <li>`insecure': to perform "insecure" SSL connections and
%%          transfers without checking the certificate</li>
%%          <li>`{checkout_timeout, infinity | integer()}': timeout used when
%%          checking out a socket from the pool, in milliseconds.
%%          By default is equal to connect_timeout</li>
%%          <li>`{connect_timeout, infinity | integer()}': timeout used when
%%          establishing a connection, in milliseconds. Default is 8000</li>
%%          <li>`{recv_timeout, infinity | integer()}': timeout used when
%%          receiving data over a connection. Default is 5000</li>
%%      </ul>
%%
%%      <blockquote>Note: if the response is async, only
%%      `follow_redirect' is take in consideration for the redirection.
%%      If a valid redirection happen you receive the messages:
%%      <ul>
%%        <li>`{redirect, To, Headers'}</li>
%%        <li>`{see_other, To, Headers}' for status 303 POST requests.</li>
%%      </ul></blockquote>
%%
%%      </li>
%%
%%      <li>`proxy_options()':  options to connect by a proxy:
%%      <p><ul>
%%          <li>binary(): url to use for the proxy. Used for basic HTTP
%%          proxy</li>
%%          <li>{Host::binary(), Port::binary}: Host and port to connect,
%%          for HTTP proxy</li>
%%          <li>{socks5, Host::binary(), Port::binary()}: Host and Port
%%          to connect to a socks5 proxy.</li>
%%          <li>{connect, Host::binary(), Port::binary()}: Host and Port
%%          to connect to an HTTP tunnel.</li>
%%      </ul></p>
%%      </li>
%%  </ul>
%%
%%  <blockquote>Note: instead of doing `hackney:request(Method, ...)' you can
%%  also do `hackney:Method(...)' if you prefer to use the REST
%%  syntax.</blockquote>
%%
%%  Return:
%%  <ul>
%%  <li><code>{ok, ResponseStatus, ResponseHeaders}</code>: On HEAD
%%  request if the response succeeded.</li>
%%  <li><code>{ok, ResponseStatus, ResponseHeaders, Ref}</code>: When
%%  the response succeeded. The request reference is used later to
%%  retrieve the body.</li>
%%  <li><code>{ok, ResponseStatus, ResponseHeaders, Body}</code>: When the
%%  option `with_body' is set to true and the response succeeded.</li>
%%  <li><code>{ok, Ref}</code> Return the request reference when you
%%  decide to stream the request. You can use the returned reference to
%%  stream the request body and continue to handle the response.</li>
%%  <li><code>{error, {closed, PartialBody}}</code> A body was expected but
%%  instead the remote closed the response after sending the headers.
%%  Equivalent to the curl  message <code>no chunk, no close, no size.
%%  Assume close to signal end</code>. </li>
%%  <li><code>{error, term()}</code> other errors.</li>
%%  </ul>
-spec request(term(), url() | binary() | list(), list(), term(), list())
    -> {ok, integer(), list(), client_ref()}
  | {ok, integer(), list(), binary()}
  | {ok, integer(), list()}
  | {ok, client_ref()}
  | {error, term()}.
request(Method, #hackney_url{}=URL0, Headers0, Body, Options0) ->
  PathEncodeFun = proplists:get_value(path_encode_fun, Options0,
    fun hackney_url:pathencode/1),


  %% normalize the url encoding
  URL = hackney_url:normalize(URL0, PathEncodeFun),

  ?report_trace("request", [{method, Method},
                            {url, URL},
                            {headers, Headers0},
                            {body, Body},
                            {options, Options0}]),

  #hackney_url{transport=Transport,
               host = Host,
               port = Port,
               user = User,
               password = Password,
               scheme = Scheme} = URL,


  Options = case User of
              <<>> ->
                Options0;
              _ ->
                lists:keystore(basic_auth, 1, Options0,
                  {basic_auth, {User, Password}})
            end,

  Headers1 = hackney_headers_new:new(Headers0),

  case maybe_proxy(Transport, Scheme, Host, Port, Options) of
    {ok, Ref, AbsolutePath} ->
      Request = make_request(
                  Method, URL, Headers1, Body, Options, AbsolutePath
                 ),
      send_request(Ref, Request);
    {ok, Ref} ->
      Request = make_request(
                  Method, URL, Headers1, Body, Options, false
                 ),
      send_request(Ref, Request);
    Error ->
      Error
  end;
request(Method, URL, Headers, Body, Options)
  when is_binary(URL) orelse is_list(URL) ->
  request(Method, hackney_url:parse_url(URL), Headers, Body, Options).


%% @doc send a request using the current client state and pass new
%% options to it.
send_request(Ref, Req, Options) ->
  ok = setopts(Ref, Options),
  send_request(Ref, Req).

%% @doc send a request using the current client state
send_request(Ref, Req) when is_reference(Ref) ->
  case hackney_manager:get_state(Ref) of
    req_not_found ->
      {error, closed};
    #client{} = State ->
      send_request(State, Req)
  end;
send_request(#client{response_state=done}=Client0 ,
  {Method, Path, Headers, Body}) ->
  Client = Client0#client{response_state=start, body_state=waiting},
  send_request(Client, {Method, Path, Headers, Body});

send_request(Client0, {Method, Path, Headers, Body}=Req) ->
  case hackney_connect:maybe_connect(Client0) of
    {ok, Client} ->
      case {Client#client.response_state, Client#client.body_state} of
        {start, waiting} ->
          Resp = hackney_request:perform(
                   Client, {Method, Path, hackney_headers_new:new(Headers), Body}
                  ),
          ?report_trace("got response", [{response, Resp}, {client, Client}]),
          Reply = maybe_redirect(Resp, Req),
          reply_response(Reply, Client);
        _ ->
          ?report_trace("invalid state", [{client, Client}]),
          reply_response({error, invalide_state}, Client)
      end;
    Error ->
      ?report_trace("response error", [{error, Error}, {client, Client0}]),
      reply_response(Error, Client0)
  end.

%% @doc send the request body until eob. It's issued after sending a request using
%% the `request' and `send_request' functions.
-spec send_body(client_ref(), term()) -> ok | {error, term()}.
send_body(Ref, Body) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_request:stream_body(Body, State),
    reply(Reply, State)
                                 end).

finish_send_body(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_request:end_stream_body(State),
    reply(Reply, State)
                                 end).


%% @doc send a multipart body until eof
%% Possible value are :
%% <ul>
%% <li>`eof': end the multipart request</li>
%% <li>`{file, Path}': to stream a file</li>
%% <li>`{file, Path, ExtraHeaders}': to stream a file</li>
%% <li>`{data, Name, Content}': to send a full part</li>
%% <li>`{data, Name, Content, ExtraHeaders}': to send a full part</li>
%% <li>`{part, Name, Len}': to start sending a part with a known length in a streaming
%% fashion</li>
%% <li>`{part, Name, Len, ExtraHeader}': to start sending a part in a streaming
%% fashion</li>
%% <li>`{part, Name}': to start sending a part without length in a streaming
%% fashion</li>
%% <li>`{part, Name, ExtraHeader}': to start sending a part without
%% length in a streaming  fashion</li>
%% <li>`{part_bin, Bin}': To send part of part</li>
%% <li>`{part, eof}': To notify the end of the part </li>
%% <li>`{mp_mixed, Name, MixedBoundary}': To notify we start a part with a a mixed
%% multipart content</li>
%% <li>`{mp_mixed_eof, MixedBoundary}': To notify we end a part with a a mixed
%% multipart content</li>
%% </ul>
%%
%% Note: You can calculate the full length of a multipart stream using
%% the function `hackney_multipart:len_mp_stream/2' .
-spec send_multipart_body(client_ref(), term()) -> ok | {error, term()}.
send_multipart_body(Ref, Body) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_request:stream_multipart(Body, State),
    reply(Reply, State)
                                 end).

%% @doc start a response.
%% Useful if you stream the body by yourself. It will fetch the status
%% and headers of the response. and return
-spec start_response(client_ref())
    -> {ok, integer(), list(), client_ref()} | {ok, client_ref()} | {error, term()}.
start_response(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_response:start_response(State),
    reply_response(Reply, State)
                                 end).

%% return all parsed cookies from the response headers.
-spec cookies(list()) -> list().
cookies(Headers) ->
  lists:foldl(fun({K, V}, Acc) ->
                  case hackney_bstr:to_lower(K) of
                    <<"set-cookie">> ->
                      case hackney_cookie:parse_cookie(V) of
                        {error, _} -> Acc;
                        [{Name, _} | _]=Cookie ->
                          [{Name, Cookie} | Acc]
                      end;
                    _ ->
                      Acc
                  end
              end, [], Headers).

%% @doc Stream the response body.
-spec stream_body(client_ref())
    -> {ok, binary()} | done | {error, term()}.
stream_body(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_response:stream_body(State),
    reply(Reply, State)
                                 end).

%% @doc Stream the response body.
%%
%% Return:
%% <ul>
%% <li>`{headers, Headers}': the part headers</li>
%% <li>`{body, Bin}': part of the content</li>
%% <li>`end_of_part' : end of part</li>
%% <li>`mp_mixed': notify the beginning of a mixed multipart part</li>
%% <li>`mp_mixed_eof': notify the end  of a mixed multipart part</li>
%% <li>`eof': notify the end of the multipart request</li>
%% </ul>
-spec stream_multipart(client_ref())
    -> {headers, list()} | {body, binary()} | eof | end_of_part
  | {error, term()}.
stream_multipart(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_response:stream_multipart(State),
    mp_reply(Reply, State)
                                 end).

%% @doc Stream the response body.
-spec skip_multipart(client_ref()) -> ok | {error, term()}.
skip_multipart(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_response:skip_multipart(State),
    mp_reply(Reply, State)
                                 end).

%% @doc Return the full body sent with the response.
-spec body(client_ref()) -> {ok, binary()} | {error, atom()} | {error, {closed, binary()}}.
body(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_response:body(State),
    reply(Reply, State)
                                 end).

%% @doc Return the full body sent with the response as long as the body
%% length doesn't go over MaxLength.
-spec body(client_ref(), non_neg_integer() | infinity)
    -> {ok, binary()} | {error, atom()} | {error, {closed, binary()}}.
body(Ref, MaxLength) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_response:body(MaxLength, State),
    reply(Reply, State)
                                 end).


%% @doc skip the full body. (read all the body if needed).
-spec skip_body(client_ref()) -> ok | {error, atom()}.
skip_body(Ref) ->
  hackney_manager:get_state(Ref, fun(State) ->
    Reply = hackney_response:skip_body(State),
    reply(Reply, State)
                                 end).


%% @doc continue to the next stream message. Only use it when
%% `{async, once}' is set in the client options.
-spec stream_next(client_ref()) -> ok | {error, req_not_found}.
stream_next(Ref) ->
  hackney_manager:with_async_response_pid(Ref, fun(Pid) ->
    Pid ! {Ref, stream_next},
    ok
                                               end).

%% @doc pause a response stream, the stream process will hibernate and
%% be woken later by the resume function
-spec pause_stream(client_ref()) -> ok | {error, req_not_found}.
pause_stream(Ref) ->
  hackney_manager:with_async_response_pid(Ref, fun(Pid) ->
    Pid ! {Ref, pause},
    ok
                                               end).

%% @doc resume a paused response stream, the stream process will be
%% awoken
-spec resume_stream(client_ref()) -> ok | {error, req_not_found}.
resume_stream(Ref) ->
  hackney_manager:with_async_response_pid(Ref, fun(Pid) ->
    Pid ! {Ref, resume},
    ok
                                               end).

%% @doc stop to receive asynchronously.
-spec stop_async(client_ref()) -> {ok, client_ref()} | {error, req_not_found} | {error, term()}.
stop_async(Ref) ->
  hackney_manager:stop_async_response(Ref).

%% internal functions
%%
%%
%%
host_header(#hackney_url{transport=Transport,netloc=Netloc}, Headers) ->
  {_, Headers1} = hackney_headers_new:store_new(
                    <<"Host">>, host_header_encode(Transport, Netloc), Headers
                   ),
  Headers1.

host_header_encode(hackney_local_tcp, Netloc) -> hackney_url:urlencode(Netloc);
host_header_encode(_Transport, Netloc) -> Netloc.


make_request(connect, #hackney_url{}=URL, Headers, Body, _, _) ->
  #hackney_url{host = Host, port = Port}= URL,

  %% place the correct host
  Headers1 = host_header(URL, Headers),

  Path = iolist_to_binary([Host, ":", integer_to_list(Port)]),
  {connect, Path, Headers1, Body};
make_request(Method, #hackney_url{}=URL, Headers0, Body, Options, true) ->
  %% place the correct host
  Headers1 = host_header(URL, Headers0),

  FinalPath = hackney_url:unparse_url(URL),
  Headers = case proplists:get_value(proxy_auth, Options) of
              undefined -> Headers1;
              {User, Pwd} ->
                Credentials = base64:encode(<< User/binary, ":", Pwd/binary >>),
                hackney_headers_new:store(
                  <<"Proxy-Authorization">>, <<"Basic ", Credentials/binary>>,
                  Headers1
                )
            end,
  {Method, FinalPath, Headers, Body};
make_request(Method, #hackney_url{}=URL, Headers, Body, _, _) ->
  #hackney_url{path = Path, qs = Query} = URL,

  %% place the correct host
  Headers1 = host_header(URL, Headers),

  FinalPath = case Query of
                <<>> ->
                  Path;
                _ ->
                  <<Path/binary, "?", Query/binary>>
              end,
  {Method, FinalPath, Headers1, Body}.


maybe_proxy(Transport, Scheme, Host, Port, Options)
  when is_list(Host), is_integer(Port), is_list(Options) ->
  case proplists:get_value(proxy, Options) of
    Url when is_binary(Url) orelse is_list(Url) ->
      ?report_debug("HTTP proxy request", [{url, Url}]),
      proxy_from_url(Url, Transport, Host, Port, Options);
    {ProxyHost, ProxyPort} ->
      ?report_debug("HTTP proxy request", [{proxy_host, ProxyHost}, {proxy_port, ProxyPort}]),
      case Transport of
        hackney_ssl ->
          ProxyAuth = proplists:get_value(proxy_auth, Options),
          do_connect(ProxyHost, ProxyPort, ProxyAuth, Transport, Host, Port, Options);
        _ ->
          case hackney_connect:connect(Transport, ProxyHost,
                                       ProxyPort, Options, true) of
            {ok, Ref} -> {ok, Ref, true};
            Error -> Error
          end
      end;
    {connect, ProxyHost, ProxyPort} ->
      ?report_debug("HTTP tunnel request", [{proxy_host, ProxyHost}, {proxy_port, ProxyPort}]),
      ProxyAuth = proplists:get_value(proxy_auth, Options),
      do_connect(ProxyHost, ProxyPort, ProxyAuth, Transport, Host, Port, Options);
    {socks5, ProxyHost, ProxyPort} ->
      ?report_debug("SOCKS proxy request", [{proxy_host, ProxyHost}, {proxy_port, ProxyPort}]),

      %% create connection options
      ProxyUser = proplists:get_value(socks5_user, Options),
      ProxyPass = proplists:get_value(socks5_pass, Options),
      ProxyResolve = proplists:get_value(socks5_resolve, Options),
      ConnectOpts0 = proplists:get_value(connect_options, Options, []),
      ConnectOpts1 = [{socks5_host, ProxyHost},
                      {socks5_port, ProxyPort},
                      {socks5_user, ProxyUser},
                      {socks5_pass, ProxyPass},
                      {socks5_resolve, ProxyResolve},
                      {socks5_transport, Transport} | ConnectOpts0],

      %% ssl options?
      Insecure = proplists:get_value(insecure, Options, false),
      ConnectOpts2 =  case proplists:get_value(ssl_options, Options) of
                        undefined ->
                          [{insecure, Insecure}] ++ ConnectOpts1;
                        SslOpts ->
                          [{ssl_options, SslOpts},
                           {insecure, Insecure}] ++ ConnectOpts1
                      end,

      Options1 = lists:keystore(connect_options, 1, Options, {connect_options, ConnectOpts2}),

      %% connect using a socks5 proxy
      hackney_connect:connect(hackney_socks5, Host, Port, Options1, true);
    _ ->
      NoProxyEnv = proplists:get_value(
                     no_proxy_env, Options, application:get_env(hackney, no_proxy_env, false)
                    ),
      maybe_proxy_from_env(Transport, Scheme, Host, Port, Options, NoProxyEnv)
  end.

maybe_proxy_from_env(Transport, _Scheme, Host, Port, Options, true) ->
  ?report_debug("no proxy env is forced, request without proxy", []),
  hackney_connect:connect(Transport, Host, Port, Options, true);
maybe_proxy_from_env(Transport, Scheme, Host, Port, Options, _) ->
  case get_proxy_env(Scheme) of
    {ok, Url} ->
      NoProxyEnv = get_no_proxy_env(),
      case match_no_proxy_env(NoProxyEnv, Host) of
        false ->
          ?report_debug("request with proxy", [{proxy, Url}, {host, Host}]),
          proxy_from_url(Url, Transport, Host, Port, Options);
        true ->
         ?report_debug("request without proxy", []),
         hackney_connect:connect(Transport, Host, Port, Options, true)
      end;
    false ->
      ?report_debug("no proxy env setup, request without proxy", []),
      hackney_connect:connect(Transport, Host, Port, Options, true)
  end.

proxy_from_url(Url, Transport, Host, Port, Options) ->
  ?report_debug("HTTP proxy request", [{url, Url}]),
  Url1 = hackney_url:parse_url(Url),
  #hackney_url{transport = PTransport,
               host = ProxyHost,
               port = ProxyPort} = hackney_url:normalize(Url1),
  ProxyAuth = proplists:get_value(proxy_auth, Options),
  case {Transport, PTransport} of
    {hackney_ssl, hackney_ssl} -> {error, invalid_proxy_transport};
    {hackney_ssl, _} ->
      do_connect(ProxyHost, ProxyPort, ProxyAuth,Transport, Host, Port, Options);
    _ ->
      case hackney_connect:connect(Transport, ProxyHost,ProxyPort, Options, true) of
        {ok, Ref} -> {ok, Ref, true};
        Error -> Error
      end
  end.

get_no_proxy_env() ->
  case application:get_env(hackney, no_proxy) of
    undefined ->
      case get_no_proxy_env(?HTTP_NO_PROXY_ENV_VARS) of
        false ->
          application:set_env(hackney, no_proxy, false),
          false;
        NoProxyEnv ->
          parse_no_proxy_env(NoProxyEnv, [])
      end;
    {ok, NoProxyEnv} ->
      NoProxyEnv
  end.

get_no_proxy_env([Key | Rest]) ->
  case os:getenv(Key) of
    false -> get_no_proxy_env(Rest);
    NoProxyStr ->
      lists:usort(string:tokens(NoProxyStr, ","))
  end;
get_no_proxy_env([]) ->
  false.

parse_no_proxy_env(["*" | _], _Acc) ->
  application:set_env(hackney, no_proxy, '*'),
  '*';
parse_no_proxy_env([S | Rest], Acc) ->
  try
    CIDR = hackney_cidr:parse(S),
    parse_no_proxy_env(Rest, [{cidr, CIDR} | Acc])
  catch
    _:_ ->
      Labels = string:tokens(S, "."),
      parse_no_proxy_env(Rest, [{host, lists:reverse(Labels)}])
  end;
parse_no_proxy_env([], Acc) ->
  NoProxy = lists:reverse(Acc),
  application:set_env(hackney, no_proxy, NoProxy),
  NoProxy.

match_no_proxy_env(false, _Host) -> false;
match_no_proxy_env('*', _Host) -> true;
match_no_proxy_env(Patterns, Host) ->
  do_match_no_proxy_env(Patterns, undefined, undefined, Host).

do_match_no_proxy_env([{cidr, _CIDR} | _]=Patterns, undefined, Labels, Host) ->
  Addrs = case inet:parse_address(Host) of
            {ok, Addr} -> [Addr];
            _ -> getaddrs(Host)
          end,
  do_match_no_proxy_env(Patterns, Addrs, Labels, Host);
do_match_no_proxy_env([{cidr, CIDR} | Rest], Addrs, Labels, Host) ->
  case test_host_cidr(Addrs, CIDR) of
    true -> true;
    false -> do_match_no_proxy_env(Rest, Addrs, Labels, Host)
  end;
do_match_no_proxy_env([{host, _Labels} | _] = Patterns, Addrs, undefined, Host) ->
  HostLabels = string:tokens(Host, "."),
  do_match_no_proxy_env(Patterns, Addrs, lists:reverse(HostLabels), Host);
do_match_no_proxy_env([{host, Labels} | Rest], Addrs, HostLabels, Host) ->
  case test_host_labels(Labels, HostLabels) of
    true -> true;
    false -> do_match_no_proxy_env(Rest, Addrs, Labels, Host)
  end;
do_match_no_proxy_env([], _, _, _) ->
  false.

test_host_labels(["*" | R1], [_ | R2]) -> test_host_labels(R1, R2);
test_host_labels([ A | R1], [A | R2]) -> test_host_labels(R1, R2);
test_host_labels([], _) -> true;
test_host_labels(_, _) -> false.

test_host_cidr([Addr, Rest], CIDR) ->
  case hackney_cidr:contains(CIDR, Addr) of
    true -> true;
    false -> test_host_cidr(Rest, CIDR)
  end;
test_host_cidr([], _) ->
  false.

getaddrs(Host) ->
  IP4Addrs = case inet:getaddrs(Host, inet) of
               {ok, Addrs} -> Addrs;
               {error, nxdomain} -> []
             end,
  case inet:getaddrs(Host, inet6) of
    {ok, IP6Addrs} -> [IP6Addrs | IP4Addrs];
    {error, nxdomain} -> IP4Addrs
  end.

get_proxy_env(https) ->
  case application:get_env(hackney, https_proxy) of
    undefined ->
      ProxyEnv = do_get_proxy_env(?HTTPS_PROXY_ENV_VARS),
      application:set_env(hackney, https_proxy, ProxyEnv),
      ProxyEnv;
    {ok, Cached} ->
      Cached
  end;
get_proxy_env(S) when S =:= http; S =:= http_unix ->
  case application:get_env(hackney, http_proxy) of
    undefined ->
      ProxyEnv = do_get_proxy_env(?HTTP_PROXY_ENV_VARS),
      application:set_env(hackney, http_proxy, ProxyEnv),
      ProxyEnv;
    {ok, Cached} ->
      Cached
  end.

do_get_proxy_env([Var | Rest]) ->
  case os:getenv(Var) of
    false -> do_get_proxy_env(Rest);
    Url -> {ok, Url}
  end;
do_get_proxy_env([]) ->
  false.

do_connect(ProxyHost, ProxyPort, undefined, Transport, Host, Port, Options) ->
  do_connect(ProxyHost, ProxyPort, {undefined, <<>>}, Transport, Host, Port, Options);
do_connect(ProxyHost, ProxyPort, {ProxyUser, ProxyPass}, Transport, Host, Port, Options) ->
  %% create connection options
  ConnectOpts = proplists:get_value(connect_options, Options, []),
  ConnectOpts1 = [{connect_host, Host},
                  {connect_port, Port},
                  {connect_transport, Transport},
                  {connect_user, ProxyUser},
                  {connect_pass, ProxyPass}| ConnectOpts],

  %% ssl options?
  Insecure = proplists:get_value(insecure, Options, false),
  ConnectOpts2 =  case proplists:get_value(ssl_options, Options) of
                    undefined ->
                      [{insecure, Insecure}] ++ ConnectOpts1;
                    SslOpts ->
                      [{ssl_options, SslOpts},
                       {insecure, Insecure}] ++ ConnectOpts1
                  end,

  Options1 = lists:keystore(connect_options, 1, Options, {connect_options, ConnectOpts2}),

  %% connect using a socks5 proxy
  hackney_connect:connect(hackney_http_connect, ProxyHost, ProxyPort, Options1, true).



maybe_redirect({ok, _}=Resp, _Req) -> Resp;
maybe_redirect(
  {ok, S, _H, #client{headers=Headers, follow_redirect=true, retries=Tries}=Client}=Resp,
  Req
 ) when Tries > 0 ->
  %% check if the given location is an absolute url,
  %% else return an error.
  case redirect_location(Headers) of
    undefined -> Resp;
    Location ->
      IsRedirect = lists:member(S, [301, 302, 303, 307, 308]),
      case IsRedirect of
        false -> Resp;
        _ ->
          URL = absolute_url(Location, Client),
          maybe_redirect1(URL, Resp, Req)
      end
  end;
maybe_redirect({ok, S, _H, #client{follow_redirect=true}}=Resp, _Req) ->
  case lists:member(S, [301, 302, 303, 307, 308]) of
    true ->
      {error, {max_redirect_overflow, Resp}};
    false ->
      Resp
  end;
maybe_redirect(Resp, _Req) ->
  Resp.


maybe_redirect1(Location, {ok, S, H, #client{retries=Tries}=Client}=Resp, Req) ->
  {Method, _Path, Headers, Body} = Req,
  case lists:member(S, [301, 302, 307, 308]) of
    true  ->
      ?report_debug("redirect request", [{location, Location},
                                         {req, Req},
                                         {resp, Resp},
                                         {tries, Tries}]),
      %% redirect the location if possible. If the method is
      %% different from  get or head it will return
      %% `{ok, {maybe_redirect, Status, Headers, Client}}' to let
      %% the  user make his choice.
      case lists:member(Method, [get, head]) of
        true ->
          NewReq = {Method, Location, Headers, Body},
          maybe_redirect(redirect(Client#client{retries=Tries-1}, NewReq), Req);
        false when Client#client.force_redirect =:= true ->
          NewReq = {Method, Location, Headers, Body},
          maybe_redirect(redirect(Client#client{retries=Tries-1}, NewReq), Req);
        false ->
          {ok, {maybe_redirect, S, H, Client}}
      end;
    false when S =:= 303 andalso (Method =:= post orelse
      Client#client.force_redirect =:= true) ->
      %% see other. If method is not POST it is
      %% considered an invalid redirection.
      ?report_debug("redirect request", [{location, Location},
                                         {req, Req},
                                         {resp, Resp},
                                         {tries, Tries}]),

      NewReq = {get, Location, hackney_headers_new:new(), <<>>},
      maybe_redirect(redirect(Client#client{retries=Tries-1}, NewReq), Req);
    false when S =:= 303 ->
      ?report_debug("invalid redirection", [{location, Location},
                                            {req, Req},
                                            {resp, Resp},
                                            {tries, Tries}]),
      {error, {invalid_redirection, Resp}};
    _ ->
      Resp
  end.

redirect(Client0, {Method, NewLocation, Headers, Body}) ->
  %% skip the body
  {skip, Client} = hackney_response:skip_body(Client0),

  %% close the connection if we don't use a pool
  RedirectUrl = hackney_url:parse_url(NewLocation),
  #hackney_url{transport=RedirectTransport,
               host=RedirectHost,
               port=RedirectPort,
               netloc=RedirectNetloc}=RedirectUrl,

  #client{transport=Transport,
          host=Host,
          port=Port,
          options=Opts0,
          follow_redirect=FollowRedirect,
          max_redirect=MaxRedirect,
          retries=Tries,
          redirect=Redirect} = Client,


  NewHeaders = case RedirectHost of
                 Host -> Headers;
                 _    ->
                   hackney_headers_new:store(<<"Host">>,
                                             hackney_bstr:to_binary(RedirectHost),
                                             Headers)
               end,
  RedirectRequest = make_request(Method, RedirectUrl, NewHeaders, Body,
                                 Client#client.options, false),
  %% make a request without any redirection
  Opts = lists:keystore(follow_redirect, 1, Opts0, {follow_redirect, false}),
  Client1 = hackney_connect:check_or_close(Client),

  %% update the state with the redirect info
  Client2 = Client1#client{transport=RedirectTransport,
                           host=RedirectHost,
                           port=RedirectPort,
                           netloc=RedirectNetloc,
                           options=Opts},

  %% send a request to the new location
  case send_request(Client2, RedirectRequest) of
    {ok,  S, H, RedirectRef} when is_reference(RedirectRef) ->
      RedirectState = hackney_manager:get_state(RedirectRef),
      RedirectState1 = case Redirect of
                         nil ->
                           RedirectState#client{redirect=Redirect,
                                                follow_redirect=FollowRedirect,
                                                max_redirect=MaxRedirect,
                                                retries=Tries,
                                                options=Opts0};
                         _ ->
                           NewRedirect = {Transport, Host, Port, Opts0},
                           RedirectState#client{redirect=NewRedirect,
                                                follow_redirect=FollowRedirect,
                                                max_redirect=MaxRedirect,
                                                retries=Tries,
                                                options=Opts0}
                       end,
      {ok, S, H, RedirectState1};
    {ok,  S, H, #client{}=RedirectClient} when Redirect /= nil ->
      NewClient = RedirectClient#client{redirect=Redirect,
                                        follow_redirect=FollowRedirect,
                                        max_redirect=MaxRedirect,
                                        retries=Tries,
                                        options=Opts0},
      {ok, S, H, NewClient};
    {ok, S, H, #client{}=RedirectClient} ->
      NewRedirect = {Transport, Host, Port, Opts0},
      NewClient = RedirectClient#client{redirect=NewRedirect,
                                        follow_redirect=FollowRedirect,
                                        max_redirect=MaxRedirect,
                                        retries=Tries,
                                        options=Opts0},
      {ok, S, H, NewClient};
    Response ->
      Response
  end.

redirect_location(Headers) when is_list(Headers) ->
  redirect_location(hackney_headers_new:from_list(Headers));
redirect_location(Headers) ->
  hackney_headers_new:get_value(<<"location">>, Headers).

absolute_url(<<"http://", _Rest/binary >>= URL, _Client) ->
  URL;
absolute_url(<<"https://", _Rest/binary >>= URL, _Client) ->
  URL;
absolute_url(RelativeUrl, #client{transport=T, host=Host, port=Port,
  netloc=Netloc, path=Path}) ->
  Scheme = hackney_url:transport_scheme(T),
  NewPath = case RelativeUrl of
              <<"/", _Rest/binary>> ->
                RelativeUrl;
              _ ->
                case binary:part(Path, {size(Path), -1}) of
                  <<"/">> -> <<Path/binary, RelativeUrl/binary>>;
                  _       -> <<Path/binary, "/", RelativeUrl/binary>>
                end
            end,

  hackney_url:unparse_url(#hackney_url{scheme=Scheme,
                                       host=Host,
                                       port=Port,
                                       netloc=Netloc,
                                       path=NewPath}).

%% handle send response
reply({ok, Data, NState}, _State) ->
  maybe_update_req(NState),
  {ok, Data};
reply({done, NState}, _State) ->
  maybe_update_req(NState),
  done;
reply({skip, NState}, _State) ->
  maybe_update_req(NState),
  ok;
reply({ok, NState}, _State) ->
  hackney_manager:update_state(NState),
  ok;
reply(Error, State) ->
  hackney_manager:handle_error(State),
  Error.

mp_reply({headers, Headers, NState}, _State) ->
  maybe_update_req(NState),
  {headers, Headers};
mp_reply({body, Body, NState}, _State) ->
  maybe_update_req(NState),
  {body, Body};
mp_reply({mp_mixed, NState}, _State) ->
  maybe_update_req(NState),
  mp_mixed;
mp_reply({mp_mixed_eof, NState}, _State) ->
  maybe_update_req(NState),
  mp_mixed_eof;
mp_reply({eof, NState}, _State) ->
  maybe_update_req(NState),
  eof;
mp_reply({end_of_part, NState}, _State) ->
  maybe_update_req(NState),
  end_of_part;
mp_reply({ok, NState}, _State) ->
  hackney_manager:update_state(NState),
  ok.

%% response reply
reply_response({ok, Status, Headers, #client{method= <<"HEAD">>}=NState},
  _State) ->
  {skip, NState2} = hackney_response:skip_body(NState),
  maybe_update_req(NState2),
  {ok, Status, Headers};
reply_response(
  {ok, Status, Headers, #client{request_ref=Ref}=NState}, _State
 )  when Status =:= 204 orelse Status =:= 304 ->
  case NState#client.with_body of
    false ->
      hackney_manager:update_state(NState#client{clen = 0}),
      {ok, Status, Headers, Ref};
    true ->
      reply_with_body(Status, Headers, NState#client{clen = 0})
  end;
reply_response({ok, Status, Headers, #client{request_ref=Ref}=NState}, _State) ->
  case NState#client.with_body of
    false ->
      %% For redirect responses with pools, ensure body is consumed to properly clean up connections
      IsRedirect = lists:member(Status, [301, 302, 303, 307, 308]),
      IsPool = hackney_connect:is_pool(NState) /= false,
      case IsRedirect andalso IsPool of
        true ->
          %% Skip the body to ensure proper connection cleanup for pool redirects
          case hackney_response:skip_body(NState) of
            {skip, CleanNState} ->
              %% For pools, the connection cleanup should have happened in skip_body
              %% Check if this breaks existing API by checking pool name
              PoolName = proplists:get_value(pool, NState#client.options, default),
              case PoolName of
                default ->
                  %% For default pool, preserve existing API compatibility
                  hackney_manager:update_state(CleanNState),
                  {ok, Status, Headers, Ref};
                _ ->
                  %% For custom pools, use full cleanup to ensure connection release
                  maybe_update_req(CleanNState),
                  {ok, Status, Headers, Ref}
              end;
            Error ->
              hackney_manager:handle_error(NState),
              Error
          end;
        false ->
          hackney_manager:update_state(NState),
          {ok, Status, Headers, Ref}
      end;
    true ->
      reply_with_body(Status, Headers, NState)
  end;
reply_response({ok, #client{request_ref=Ref}=NState}, _State) ->
  hackney_manager:update_state(NState),
  {ok, Ref};
reply_response({ok, Ref}, _State) when is_reference(Ref) ->
  {ok, Ref};
reply_response(Error, State) ->
  hackney_manager:handle_error(State),
  Error.


reply_with_body(Status, Headers, State) ->
  Reply = case State#client.max_body of
            undefined -> hackney_response:body(State);
            MaxBody   -> hackney_response:body(MaxBody, State)
          end,
  case reply(Reply, State) of
    {ok, Body} ->
      {ok, Status, Headers, Body};
    {closed, Body} ->
      {ok, Status, Headers, Body};
    Error ->
      Error
  end.


maybe_update_req(#client{dynamic=true, response_state=done}=State) ->
  hackney_manager:close_request(State);
maybe_update_req(State) ->
  hackney_manager:update_state(State).


parse_options([], State) ->
  State;
parse_options([async | Rest], State) ->
  parse_options(Rest, State#client{async=true});
parse_options([{async, Async} | Rest], State) ->
  parse_options(Rest, State#client{async=Async});
parse_options([{stream_to, Pid} | Rest], State) ->
  parse_options(Rest, State#client{stream_to=Pid});
parse_options([{follow_redirect, Follow} | Rest], State) ->
  parse_options(Rest, State#client{follow_redirect=Follow});
parse_options([{force_redirect, Force} | Rest], State) ->
  parse_options(Rest, State#client{force_redirect=Force});
parse_options([{max_redirect, Max} | Rest], State) ->
  parse_options(Rest, State#client{max_redirect=Max});
parse_options([dynamic | Rest], State) ->
  parse_options(Rest, State#client{dynamic=true});
parse_options([{dynamic, Dynamic} | Rest], State) ->
  parse_options(Rest, State#client{dynamic=Dynamic});
parse_options([{with_body, WithBody} | Rest], State) ->
  parse_options(Rest, State#client{with_body=WithBody});
parse_options([with_body | Rest], State) ->
  parse_options(Rest, State#client{with_body=true});
parse_options([{max_body, MaxBody} | Rest], State) ->
  parse_options(Rest, State#client{max_body=MaxBody});
parse_options([_ | Rest], State) ->
  parse_options(Rest, State).

-define(METHOD_TPL(Method),
  Method(URL) ->
  hackney:request(Method, URL)).
-include("hackney_methods.hrl").

-define(METHOD_TPL(Method),
  Method(URL, Headers) ->
  hackney:request(Method, URL, Headers)).
-include("hackney_methods.hrl").


-define(METHOD_TPL(Method),
  Method(URL, Headers, Body) ->
  hackney:request(Method, URL, Headers, Body)).
-include("hackney_methods.hrl").

-define(METHOD_TPL(Method),
  Method(URL, Headers, Body, Options) ->
  hackney:request(Method, URL, Headers, Body, Options)).
-include("hackney_methods.hrl").
