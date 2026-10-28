%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%

%% @doc module handling the response

-module(hackney_response).

-include("hackney.hrl").
-include("hackney_lib.hrl").

-type response_state() :: start | waiting | on_status | on_headers | on_body.
-export_type([response_state/0]).

-export([start_response/1,
  stream_body/1,
  stream_multipart/1,
  skip_multipart/1,
  body/1, body/2, skip_body/1,
  maybe_close/1,
  close/1,
  expect_response/1]).

%% internal
%% @doc Start the response It parse the request lines and headers.
start_response(#client{response_state=stream, mp_boundary=nil} = Client) ->
  case hackney_request:end_stream_body(Client) of
    {ok, Client1} ->
      start_response(Client1);
    Error ->
      Error
  end;
start_response(#client{response_state=stream} = Client) ->
  case hackney_request:stream_multipart(eof, Client) of
    {ok, Client1} ->
      start_response(Client1);
    Error ->
      Error
  end;
start_response(#client{request_ref=Ref, response_state=waiting,
  async=Async}=Client)
  when Async =:= true orelse Async =:= once ->

  hackney_manager:update_state(Client),
  case hackney_manager:start_async_response(Ref) of
    ok ->
      {ok, Ref};
    Error ->
      Error
  end;
start_response(#client{response_state=waiting} = Client) ->
  Parser = hackney_http:parser([response]),
  wait_status(Client#client{parser=Parser});
start_response(_) ->
  {error, invalide_state}.

%% @doc handle Expect header
expect_response(Client) ->
  case recv(Client#client{recv_timeout=1000}) of
    {ok, <<"HTTP/1.1 100 Continue\r\n\r\n" , Rest/binary >>} ->
      {continue, Client#client{expect=false, buffer=Rest}};
    {ok, Data} ->
      {stop, Client#client{buffer=Data, expect=false,
        response_state=waiting}};
    {error, timeout} ->
      {continue, Client#client{expect=false}};
    Error ->
      Error
  end.


wait_status(#client{buffer=Buf, parser=Parser}=Client) ->
  case hackney_http:execute(Parser, Buf) of
    {more, NParser} ->
      case recv(Client) of
        {ok, Data} ->
          wait_status(Client#client{buffer=Data,
            parser=NParser});
        Error  ->
          Error
      end;
    {response, Version, Status, _Reason, NParser} ->
      wait_headers(Client#client{parser=NParser,
        buffer = <<>>,
        version=Version}, Status);
    Error ->
      Error
  end.

wait_headers(#client{parser=Parser}=Client, Status) ->
  wait_headers(hackney_http:execute(Parser), Client, Status, hackney_headers_new:new()).


wait_headers({more, Parser}, Client, Status, Headers) ->
  case recv(Client) of
    {ok, Data} ->
      wait_headers(hackney_http:execute(Parser, Data), Client, Status,
        Headers);
    Error  ->
      Error
  end;
wait_headers({header, {Key, Value}, Parser}, Client, Status, Headers) ->
  Headers2 = hackney_headers_new:append(Key, Value, Headers),
  wait_headers(hackney_http:execute(Parser), Client, Status, Headers2);

wait_headers({headers_complete, Parser}, Client, Status, Headers) ->
  ResponseTime = timer:now_diff(os:timestamp(),
    Client#client.start_time)/1000,
  _ = metrics:update_histogram(Client#client.mod_metrics,
                               [hackney, Client#client.host, response_time],
                               ResponseTime),
  HeadersList = hackney_headers_new:to_list(Headers),
  TE = hackney_headers_new:get_value(<<"transfer-encoding">>, Headers, nil),
  CLen = case hackney_headers_new:lookup("content-length", Headers) of
           [] -> undefined;
           [{_, Len} |_] ->
             case hackney_util:to_int(Len) of
              {ok, I} -> I;
               false -> bad_int
             end
         end,
  Client2 = Client#client{parser=Parser,
                          headers=Headers,
                          te=TE,
                          clen=CLen},
  {ok, Status, HeadersList, Client2}.

stream_body(Client=#client{response_state=done}) ->
  {done, Client};
stream_body(Client=#client{method= <<"HEAD">>, parser=Parser}) ->
  Buffer = hackney_http:get(Parser, buffer),
  Client2 = end_stream_body(Buffer, Client),
  {done, Client2};
stream_body(Client=#client{parser=Parser, clen=CLen, te=TE}) ->
  case {TE, CLen} of
    {<<"chunked">>, _} ->
      stream_body1(hackney_http:execute(Parser), Client);
    {_, CLen} when CLen =:= 0 orelse CLen =:= bad_int ->
      Buffer = hackney_http:get(Parser, buffer),
      Client2 = end_stream_body(Buffer, Client),
      {done, Client2};
    {_, _} ->
      stream_body1(hackney_http:execute(Parser), Client)
  end.

stream_body(Data, #client{parser=Parser}=Client) ->
  stream_body1(hackney_http:execute(Parser, Data), Client).

stream_body1({more, Parser}, Client) ->
  stream_body_recv(<<>>, Client#client{parser=Parser});
stream_body1({more, Parser, Buffer}, Client) ->
  stream_body_recv(Buffer, Client#client{parser=Parser});
stream_body1({ok, Data, Parser}, Client) ->
  {ok, Data, Client#client{parser=Parser}};
stream_body1({done, Rest}, Client) ->
  Client2 = end_stream_body(Rest, Client),
  {done, Client2};
stream_body1(done, Client) ->
  Client2 = end_stream_body(<<>>, Client),
  {done, Client2};
stream_body1(Error, _Client) ->
  Error.


-spec stream_body_recv(binary(), #client{})
    -> {ok, binary(), #client{}} | {error, term()}.
stream_body_recv(Buffer, Client=#client{parser=#hparser{body_state={stream, _, TransferState, _}}}) ->
  case recv(Client, TransferState) of
    {ok, Data} ->
      stream_body(Data, Client);
    {error, Reason} ->
      stream_body_recv_error(Reason, Buffer, Client)
  end;
stream_body_recv(Buffer, Client=#client{parser=#hparser{body_state=done}}) ->
  case recv(Client) of
    {ok, Data} ->
      stream_body(Data, Client);
    {error, Reason} ->
      stream_body_recv_error(Reason, Buffer, Client)
  end.

stream_body_recv_error(Reason, Buffer, Client=#client{version=Version, clen=CLen}) ->
  Client2 = close(Client),
  case Reason of
    closed when (Version =:= {1, 0} orelse Version =:= {1, 1}) andalso (CLen =:= nil orelse CLen =:= undefined) ->
      {ok, Buffer, Client2#client{response_state=done,
                                  body_state=done,
                                  buffer = <<>>,
                                  parser=nil}};
    closed when Client#client.te =:= <<"identity">> ->
      {ok, Buffer, Client2#client{response_state=done,
                                  body_state=done,
                                  buffer = <<>>}};
    closed ->
      {error, {closed, Buffer}};
    _Else ->
      {error, Reason}
  end.


%% @doc stream a multipart response
%%
%% Use this function for multipart streaming. For each part in the
%% response, this function returns <em>{headers, Headers, Req}</em> followed by a sequence of
%% <em>{body, Data, Req}</em> tuples and finally <em>{end_of_part, Req}</em>. When there
%% is no part to parse anymore, <em>{eof, Req}</em> is returned.
-spec stream_multipart(#client{})
    -> {headers, list(), #client{}} | {body, binary(), #client{}}
  | {eof|end_of_part|mp_mixed|mp_mixed_eof, #client{}}.
stream_multipart(Client=#client{headers=Headers, body_state=waiting, clen=Length}) ->
  CType = hackney_headers_new:get_value(<<"content-type">>, Headers),
  {<<"multipart">>, _, Params} = hackney_headers_new:parse_content_type(CType),
  {_, Boundary} = lists:keyfind(<<"boundary">>, 1, Params),
  Parser = hackney_multipart:parser(Boundary),
  multipart_data(Client#client{body_state=processing}, Length,
    {more, Parser});
stream_multipart(Client=#client{multipart={Length, Cont}}) ->
  multipart_data(Client, Length, Cont());
stream_multipart(Client=#client{body_state=done}) ->
  {eof, Client}.

multipart_data(Client, Length, {headers, Headers, Cont}) ->
  {headers, Headers, Client#client{multipart={Length, Cont}}};
multipart_data(Client, Length, {body, Data, Cont}) ->
  {body, Data, Client#client{multipart={Length, Cont}}};
multipart_data(Client, Length, {end_of_part, Cont}) ->
  {end_of_part, Client#client{multipart={Length, Cont}}};
multipart_data(Client, Length, {mp_mixed, Cont}) ->
  {mp_mixed, Client#client{multipart={Length, Cont}}};
multipart_data(Client, Length, {mp_mixed_eof, Cont}) ->
  {mp_mixed_eof, Client#client{multipart={Length, Cont}}};
multipart_data(Client, Length, eof)
  when Length =:= 0 orelse Length =:= nil orelse Length =:= undefined ->
  Client2 = end_stream_body(<<>>, Client),
  {eof, Client2#client{body_state=done, multipart=nil}};
multipart_data(Client, _, eof) ->
  %% We just want to skip so no need to stream data here.
  {skip, Client2} = skip_body(Client),
  {eof, Client2#client{multipart=nil}};
multipart_data(Client, Length, {more, Parser})
  when Length > 0 orelse Length =:= nil orelse Length =:= undefined ->
  case stream_body(Client) of
    {ok, Data, Client2} when Length =:= nil  ->
      multipart_data(Client2, Length, Parser(Data));
    {ok, Data, Client2} when Length =:= undefined  ->
      multipart_data(Client2, Length, Parser(Data));
    {ok, << Data:Length/binary, Buffer/binary >>, Client2} ->
      multipart_data(Client2#client{buffer=Buffer}, 0,
        Parser(Data));
    {ok, Data, Client2} ->
      multipart_data(Client2, Length - byte_size(Data),
        Parser(Data))
  end.

%% @doc Skip a part returned by the multipart parser.
%%
%% This function repeatedly calls <em>multipart_data/1</em> until
%% <em>{end_of_part, Req}</em> or <em>{eof, Req}</em> is parsed.
-spec skip_multipart(Client) -> {ok, Client} when Client::#client{}.
skip_multipart(Client) ->
  case stream_multipart(Client) of
    {end_of_part, Client2} -> {ok, Client2};
    {eof, Client2} -> {ok, Client2};
    {_, _, Client2} -> skip_multipart(Client2)
  end.

%% @doc Return the full body sent with the request.
-spec body(#client{}) -> {ok, binary(), #client{}} | {error, atom()}.
body(Client) ->
  read_body(infinity, Client, <<>>).

%% @doc Return the full body sent with the request as long as the body
%% length doesn't go over MaxLength.
%%
%% This is most useful to quickly be able to get the full body while
%% avoiding filling your memory with huge request bodies when you're
%% not expecting it.
%%
%% When the response is larger than MaxLength, this function will return
%% the body it received up to the last chunk, which might be a bit more than MaxLength.
-spec body(non_neg_integer() | infinity, #client{})
    -> {ok, binary(), #client{}} | {error, atom()}.
body(MaxLength, Client) ->
  read_body(MaxLength, Client, <<>>).

-spec skip_body(#client{}) -> {ok, #client{}} | {skip, #client{}} | {error, atom()}.
skip_body(Client) ->
  case stream_body(Client) of
    {ok, _, Client2} -> skip_body(Client2);
    {done, Client2} -> {skip, Client2};
    {error, Reason} -> {error, Reason}
  end.

end_stream_body(Rest, Client0) ->
  %% Prepare new client state atomically
  BaseClient = Client0#client{response_state=done,
    body_state=done,
    parser=nil,
    buffer=Rest,
    stream_to=false,
    async=false},

  Pool = hackney_connect:is_pool(BaseClient),

  case maybe_close(BaseClient) of
    true ->
      close(BaseClient);
    false when Pool /= false ->
      #client{socket=Socket,
        socket_ref=Ref,
        pool_handler=Handler}=BaseClient,

      Handler:checkin(Ref, Socket),
      %% Complete state update atomically
      BaseClient#client{state=closed, socket=nil, socket_ref=nil,
        buffer = <<>>};
    false ->
      BaseClient
  end.


-spec read_body(non_neg_integer() | infinity, #client{}, binary())
    -> {ok, binary(), #client{}} | {error, term()}.
read_body(MaxLength, Client, Acc) when MaxLength > byte_size(Acc) ->
  case stream_body(Client) of
    {ok, Data, Client2} ->
      read_body(MaxLength, Client2, << Acc/binary, Data/binary >>);
    {done, Client2} ->
      {ok, Acc, Client2};
    {error, Reason}=Error ->
      case Reason of
        {closed, Bin} when is_binary(Bin) ->
          {error, {closed, << Acc/binary, Bin/binary >>}};
        _ ->
          Error
      end;
    Else ->
      {error, Else}
  end;
read_body(_MaxLength, Client, Acc) ->
  Client2 = end_stream_body(<<>>, Client),
  {ok, Acc, Client2}.


maybe_close(#client{socket=nil}) ->
  true;
maybe_close(#client{connection= <<"close">>}) ->
  true;
maybe_close(#client{version={Min,Maj}, headers=Headers, clen=CLen}) ->
  Connection = hackney_bstr:to_lower(
                 hackney_headers_new:get_value(<<"connection">>, Headers, <<"">>)
                ),
  case Connection of
    <<"close">> -> true;
    <<"keep-alive">> -> false;
    _ when Min =< 0 orelse Maj < 1 -> true;
    _ when CLen =:= bad_int -> true;
    _ -> false
  end.

recv(#client{transport=Transport, socket=Skt, recv_timeout=Timeout}) ->
  Transport:recv(Skt, 0, Timeout).

recv(#client{transport=Transport, socket=Skt, recv_timeout=Timeout}, {_BufSize, undefined}) ->
  Transport:recv(Skt, 0, Timeout);
recv(#client{transport=Transport, socket=Skt, recv_timeout=Timeout}, {BufSize, ExpectedSize}) when ExpectedSize >= BufSize ->
  Transport:recv(Skt, ExpectedSize - BufSize, Timeout);
recv(#client{transport=Transport, socket=Skt, recv_timeout=Timeout}, {_BufSize, _ExpectedSize}) ->
  Transport:recv(Skt, 0, Timeout).

close(#client{socket=nil}=Client) ->
  Client#client{state = closed};
close(#client{transport=Transport, socket=Skt}=Client) ->
  Transport:close(Skt),
  Client#client{state = closed, socket=nil}.
