%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%

-module(hackney_stream).

-export([start_link/3]).

%% internal
-export([async_recv/5, maybe_continue/4]).
-export([init/4,
  system_continue/3,
  system_terminate/4,
  system_code_change/4]).

-include("hackney.hrl").
-include_lib("hackney_internal.hrl").

start_link(Owner, Ref, Client) ->
  proc_lib:start_link(?MODULE, init, [self(), Owner, Ref, Client]).

init(Parent, Owner, Ref, Client) ->
  %% register the stream
  ok = proc_lib:init_ack(Parent, {ok, self()}),
  ok = wait_for_controlling_process(),
  _MRef = erlang:monitor(process, Owner),
  Parser = hackney_http:parser([response]),
  try
    stream_loop(Parent, Owner, Ref, Client#client{parser=Parser,
      response_state=on_status})
  catch _:Reason ->
    Owner ! {hackney_response, Ref, {error, {unknown_error, Reason}}}
  end.

wait_for_controlling_process() ->
  receive
    controlling_process_done ->
      ok
  after 10000 ->
    timeout
  end.

stream_loop(Parent, Owner, Ref, #client{transport=Transport,
                                        socket=Socket,
                                        response_state=on_body,
                                        method= <<"HEAD">>,
                                        parser=Parser}=Client) ->
  Buffer = hackney_http:get(Parser, buffer),
  hackney_manager:store_state(finish_response(Buffer, Client)),
  %% remove ant message in the socket
  _ = flush(Transport, Socket),
  %% pass the control of the socket to the manager so we make
  %% sure a new request will be able to use it
  Transport:controlling_process(Socket, Parent),
  %% tell the client we are done
  Owner ! {hackney_response, Ref, done};
stream_loop(Parent, Owner, Ref, #client{transport=Transport,
                                        socket=Socket,
                                        response_state=on_body,
                                        clen=0, te=TE,
                                        parser=Parser}=Client)
  when TE /= <<"chunked">> ->
  Buffer = hackney_http:get(Parser, buffer),
  hackney_manager:store_state(finish_response(Buffer, Client)),
  %% remove ant message in the socket
  _ = flush(Transport, Socket),
  %% pass the control of the socket to the manager so we make
  %% sure a new request will be able to use it
  Transport:controlling_process(Socket, Parent),
  %% tell the client we are done
  Owner ! {hackney_response, Ref, done};
stream_loop(Parent, Owner, Ref, #client{transport=Transport,
                                        socket=Socket}=Client) ->
  case parse(Client) of
    {loop, Client2} ->
      stream_loop(Parent, Owner, Ref, Client2);
    {more, Client2, Rest} ->
      async_recv(Parent, Owner, Ref, Client2, Rest);
    {ok, StatusInt, Reason, Client2} ->
      maybe_redirect(Parent, Owner, Ref, StatusInt, Reason,
        Client2);
    {ok, {headers, Headers}, Client2} ->
      Owner ! {hackney_response, Ref, {headers, Headers}},
      maybe_continue(Parent, Owner, Ref, Client2);
    {ok, Data, Client2} ->
      Owner ! {hackney_response, Ref, Data},
      maybe_continue(Parent, Owner, Ref, Client2);
    done ->
      %% remove ant message in the socket
      _ = flush(Transport, Socket),
      %% pass the control of the socket to the manager so we make
      %% sure a new request will be able to use it
      Transport:controlling_process(Socket, Parent),
      Owner ! {hackney_response, Ref, done};
    {error, _Reason} = Error ->
      Owner ! {hackney_response, Ref, Error},
      hackney_manager:handle_error(Client)
  end.

maybe_continue(Parent, Owner, Ref, #client{transport=Transport,
                                           socket=Socket,
                                           async=true}=Client) ->
  receive
    {Ref, resume} ->
      stream_loop(Parent, Owner, Ref, Client);
    {Ref, pause} ->
      _ = Transport:setopts(Socket, [{active, false}]),
      proc_lib:hibernate(?MODULE, maybe_continue, [Parent, Owner, Ref,
        Client]);
    {Ref, stop_async, From} ->
      hackney_manager:store_state(Client#client{async=false}),
      _ = Transport:setopts(Socket, [{active, false}]),
      Transport:controlling_process(Socket, From),
      From ! {Ref, ok};
    {Ref, close} ->
      hackney_response:close(Client);
    {'DOWN', _MRef, process, Owner, Reason} ->
      exit({owner_down, Owner, Reason});
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
        {stream_loop, Parent, Owner, Ref, Client});
    Else ->
      ?report_trace("stream: unexpected message", [{message, Else}]),
      error_logger:error_msg("Unexpected message: ~w~n", [Else])

  after 0 ->
    stream_loop(Parent, Owner, Ref, Client)
  end;
maybe_continue(Parent, Owner, Ref, #client{transport=Transport,
                                           socket=Socket,
                                           async=once}=Client) ->
  receive
    {Ref, stream_next} ->
      stream_loop(Parent, Owner, Ref, Client);
    {Ref, stop_async, From} ->
      hackney_manager:store_state(Client),
      _ = Transport:setopts(Socket, [{active, false}]),
      Transport:controlling_process(Socket, From),
      From ! {Ref, ok};
    {Ref, close} ->
      hackney_response:close(Client);
        {'DOWN', _MRef, process, Owner, Reason} ->
      exit({owner_down, Owner, Reason});
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
        {maybe_continue, Parent, Owner, Ref,
          Client});
    Else ->
      ?report_trace("stream: unexpected message", [{message, Else}]),
      error_logger:error_msg("Unexpected message: ~w~n", [Else])
  after 5000 ->
    _ = Transport:setopts(Socket, [{active, false}]),
    proc_lib:hibernate(?MODULE, maybe_continue, [Parent, Owner, Ref,
      Client])

  end.


%% if follow_redirect is true, we are parsing the headers to fetch the
%% location. If we can still redirect, send a message with the location
%% to the receiver so he can eventually start a new request.
%%
%% redirect messages:
%% - {redirect, To, Headers}
%% - {see_other, To, Headers} for status 303 and POST requests.
maybe_redirect(Parent, Owner, Ref, StatusInt, Reason,
               #client{method=Method, follow_redirect=true}=Client) ->
  case lists:member(StatusInt, [301, 302, 307, 308]) of
    true ->
      maybe_redirect_1(Parent, Owner, Ref, Reason, Client);
   false when StatusInt =:= 303, Method =:= <<"POST">> ->
      maybe_redirect_2(Parent, Owner, Ref, Reason, Client);
    _ ->
      Owner ! {hackney_response, Ref, {status, StatusInt, Reason}},
      maybe_continue(Parent, Owner, Ref, Client)
  end;
maybe_redirect(Parent, Owner, Ref, StatusInt, Reason, Client) ->
  Owner ! {hackney_response, Ref, {status, StatusInt, Reason}},
  maybe_continue(Parent, Owner, Ref, Client).

%% The first case for redirections are status codes 301, 302, 307 and 308.
%% In this case {redirect, Location, Headers} is sent to the owner if
%% the request is valid.
maybe_redirect_1(Parent, Owner, Ref, Reason,
               #client{transport=Transport, socket=Socket}=Client) ->
  _ = Transport:setopts(Socket, [{active, false}]),
  case parse(Client) of
    {loop, Client2} ->
      maybe_redirect_1(Parent, Owner, Ref, Reason, Client2);
    {more, Client2, Rest} ->
      Continuation = fun(Client3) ->
                         maybe_redirect_1(Parent, Owner, Ref, Reason, Client3)
                     end,
          async_recv(Parent, Owner, Ref, Client2, Rest, Continuation);
    {ok, {headers, Headers}, Client2} ->
      Location = hackney:redirect_location(Headers),
      case Location of
        undefined ->
          Owner ! {hackney_response, Ref, {error,invalid_redirection}},
          hackney_manager:handle_error(Client2);
        _ ->
          case hackney_response:skip_body(Client2) of
            {skip, Client3} ->
              hackney_manager:store_state(Client3),
              Owner ! {hackney_response, Ref,
                       {redirect, Location, Headers}};
            Error ->
              Owner ! {hackney_response, Ref, Error},
              hackney_manager:handle_error(Client2)
              end
          end;
    {error, Error} ->
      Owner ! {hackney_response, Ref, {error, Error}},
      hackney_manager:handle_error(Client)
  end.

%% The second case is for status code 303 and POST requests.
%% This results in sending {see_other, Location, Headers} to the owner.
maybe_redirect_2(Parent, Owner, Ref, Reason,
               #client{transport=Transport,
                       socket=Socket}=Client) ->
      _ = Transport:setopts(Socket, [{active, false}]),
      case parse(Client) of
        {loop, Client2} ->
          maybe_redirect_2(Parent, Owner, Ref, Reason, Client2);
        {more, Client2, Rest} ->
          Continuation = fun(Client3) ->
                           maybe_redirect_2(Parent, Owner, Ref, Reason, Client3)
                       end,
          async_recv(Parent, Owner, Ref, Client2, Rest, Continuation);
        {ok, {headers, Headers}, Client2} ->
          case hackney:redirect_location(Headers) of
            undefined ->
              Owner ! {hackney_response, Ref,
                {error, invalid_redirection}},
              hackney_manager:handle_error(Client2);
            Location ->
              case hackney_response:skip_body(Client2) of
                {skip, Client3} ->
                  hackney_manager:store_state(Client3),
                  Owner ! {hackney_response, Ref,
                    {see_other, Location, Headers}};
                Error ->
                  Owner ! {hackney_response, Ref, Error},
                  hackney_manager:handle_error(Client2)
              end
          end;
        {error, Error} ->
          Owner ! {hackney_response, Ref, {error, Error}},
          hackney_manager:handle_error(Client)
      end.


async_recv(Parent, Owner, Ref, Client, Buffer) ->
  Continuation = fun(Client2) ->
    stream_loop(Parent, Owner, Ref, Client2)
  end,
  async_recv(Parent, Owner, Ref, Client, Buffer, Continuation).

async_recv(Parent, Owner, Ref,
           #client{transport=Transport,
                   socket=TSock,
                   recv_timeout=Timeout}=Client, Buffer, Continuation) ->
  {OK, Closed, Error} = Transport:messages(TSock),
  Sock = raw_sock(TSock),
  Transport:setopts(TSock, [{active, once}]),
  %% some useful info
  #client{version=Version, clen=CLen, te=TE} = Client,
  receive
    {Ref, resume} ->
      async_recv(Parent, Owner, Ref, Client, Buffer);
    {Ref, stream_next} ->
      async_recv(Parent, Owner, Ref, Client, Buffer);
    {Ref, pause} ->
      %% make sure that the process won't be awoken by a tcp msg
      _ = Transport:setopts(TSock, [{active, false}]),
      proc_lib:hibernate(?MODULE, async_recv, [Parent, Owner, Ref,
        Client, Buffer]);
    {Ref, close} ->
      Transport:close(TSock);
    {Ref, stop_async, From} ->
      hackney_manager:store_state(Client#client{async=false}),
      _ = Transport:setopts(TSock, [{active, false}]),
      Transport:controlling_process(TSock, From),
      From ! {Ref, ok};
    {OK, Sock, Data} ->
      Continuation(Client#client{buffer=Data});
    {Closed, Sock} ->
      case Client#client.response_state of
        on_body when (Version =:= {1, 0} orelse Version =:= {1, 1})
                       andalso (CLen =:= undefined orelse CLen =:= nil) ->
          Owner ! {hackney_response, Ref, Buffer},
          Owner ! {hackney_response, Ref, done},
          ok;
        on_body when TE =:= <<"identity">> ->
          Owner ! {hackney_response, Ref, Buffer},
          Owner ! {hackney_response, Ref, done},
          ok;
        on_body ->
          Owner ! {hackney_response, Ref, {error, {closed, Buffer}}},
          ok;
        _ ->
          Owner ! {hackney_response, Ref, {error, closed}},
          ok
      end,
      Transport:close(Sock);
    {Error, Sock, Reason} ->
      Owner ! {hackney_response, Ref, {error, Reason}},
      Transport:close(TSock);
    {ssl_closed, Sock} ->
      %% Handle SSL close messages same as regular close
      case Client#client.response_state of
        on_body when (Version =:= {1, 0} orelse Version =:= {1, 1})
                       andalso (CLen =:= undefined orelse CLen =:= nil) ->
          Owner ! {hackney_response, Ref, Buffer},
          Owner ! {hackney_response, Ref, done},
          ok;
        on_body when TE =:= <<"identity">> ->
          Owner ! {hackney_response, Ref, Buffer},
          Owner ! {hackney_response, Ref, done},
          ok;
        on_body ->
          Owner ! {hackney_response, Ref, {error, {closed, Buffer}}},
          ok;
        _ ->
          Owner ! {hackney_response, Ref, {error, closed}},
          ok
      end,
      Transport:close(TSock);
    {ssl_error, Sock, Reason} ->
      %% Handle SSL errors same as regular errors
      Owner ! {hackney_response, Ref, {error, Reason}},
      Transport:close(TSock);
    {'DOWN', _MRef, process, Owner, Reason} ->
      exit({owner_down, Owner, Reason});
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
        {async_recv, Parent, Owner, Ref, Client});
    Else ->
      ?report_trace("stream: unexpected message", [{message, Else},
        {sock, TSock}]),
      error_logger:error_msg("Unexpected message: ~w~n", [Else])
  after Timeout ->
    Owner ! {hackney_response, Ref, {error, {closed, timeout}}},
    Transport:close(TSock)
  end.

system_continue(_, _, {maybe_continue, Parent, Owner, Ref, Client}) ->
  maybe_continue(Parent, Owner, Ref, Client);
system_continue(_, _, {stream_loop, Parent, Owner, Ref, Client}) ->
  stream_loop(Parent, Owner, Ref, Client);
system_continue(_, _, {async_recv, Parent, Owner, Ref, Client, Buffer}) ->
  async_recv(Parent, Owner, Ref, Client, Buffer).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, {_, _, _, _Ref, _}) ->
  exit(Reason).

system_code_change(Misc, _, _, _) ->
  {ok, Misc}.


parse(#client{parser=Parser, buffer=Buffer}=Client) ->
  Res = hackney_http:execute(Parser, Buffer),
  process(Res, Client#client{buffer= <<>>}).

process({more, NParser}, Client) ->
  NClient = update_client(NParser, Client),
  {more, NClient, <<>>};
process({more, NParser, Buffer}, Client) ->
  NClient = update_client(NParser, Client),
  {more, NClient, Buffer};
process({response, Version, Status, Reason, Parser}, Client0) ->
  Client1 = update_client(Parser, Client0#client{version=Version,
                                                 response_state=on_header}),
  Client2 = case Status of
              S when S =:= 204 orelse S =:= 304 ->
                Client1#client{clen = 0};
              _Otherwise ->
                Client1
            end,
  {ok, Status, Reason, Client2};
process({header, {Key, Value}=KV, NParser},
  #client{partial_headers=Headers}=Client) ->
  %% store useful headers
  Client1 = case hackney_bstr:to_lower(Key) of
              <<"content-length">> ->
                case hackney_util:to_int(Value) of
                  {ok, CLen} -> Client#client{clen=CLen};
                  false -> Client#client{clen=bad_int}
                end;
              <<"transfer-encoding">> ->
                Client#client{te=hackney_bstr:to_lower(Value)};
              <<"connection">> ->
                Client#client{connection=hackney_bstr:to_lower(Value)};
              <<"content-type">> ->
                Client#client{ctype=hackney_bstr:to_lower(Value)};
              <<"location">> ->
                Client#client{location=Value};
              _ ->
                Client
            end,
  NHeaders = [KV | Headers],
  NClient = update_client(NParser, Client1#client{partial_headers=NHeaders}),
  {loop, NClient};
process({headers_complete, NParser},
        #client{partial_headers=Headers}=Client) ->
  NClient = update_client(NParser, Client#client{partial_headers=[],
                                                 response_state=on_body}),
  {ok, {headers, lists:reverse(Headers)}, NClient};
process({ok, Data, NParser}, Client) ->
  NClient = update_client(NParser, Client),
  {ok, Data, NClient};
process({done, Rest}, Client) ->
  Client2 = finish_response(Rest, Client),
  hackney_manager:store_state(Client2),
  done;
process(done, Client) ->
  Client2 = finish_response(<<>>, Client),
  hackney_manager:store_state(Client2),
  done;
process({error, Reason}, _Client) ->
  {error, Reason};
process(Error, _Client) ->
  {error, Error}.

update_client(Parser, Client) ->
  Client#client{parser=Parser}.

finish_response(Rest, Client0) ->
  Client = Client0#client{response_state=done,
                          body_state=done,
                          parser=nil,
                          buffer=Rest,
                          async=false,
                          stream_to=false},

  Pool = hackney_connect:is_pool(Client),
  case hackney_response:maybe_close(Client) of
    true ->
      hackney_response:close(Client);
    false when Pool /= false ->
      #client{socket=Socket,
        socket_ref=Ref,
        pool_handler=Handler}=Client,
      Handler:checkin(Ref, Socket),
      Client#client{state=closed, socket=nil, socket_ref=nil};
    false ->
      Client
  end.


raw_sock({hackney_ssl, RawSock}) ->
  RawSock;
raw_sock({hackney_tcp, RawSock}) ->
  RawSock;
raw_sock(RawSock) ->
  RawSock.

%% check that no events from the sockets is received
%% after giving the control back.
flush(Transport, Socket) ->
  {Msg, MsgClosed, MsgError} = Transport:messages(Socket),
  receive
    {Msg, Socket, _} -> flush(Transport, Socket) ;
    {MsgClosed, Socket} -> flush(Transport, Socket) ;
    {MsgError, Socket, _} -> flush(Transport, Socket)
  after 0 ->
    ok
  end.
