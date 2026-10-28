%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%

%% @doc module handling the request

-module(hackney_request).

-include("hackney.hrl").
-include("hackney_lib.hrl").
-include_lib("hackney_internal.hrl").

-export([perform/2,
         location/1,
         send/2, send_chunk/2,
         sendfile/3,
         stream_body/2, end_stream_body/1,
         stream_multipart/2,
         encode_form/1,
         default_ua/0]).

-export([is_default_port/1]).

-export([make_multipart_stream/2]).

-define(CHUNK_SIZE, 65536000). %% 64 MB is the default

perform(Client0, {Method0, Path0, Headers0, Body0}) ->
  Method = hackney_bstr:to_upper(hackney_bstr:to_binary(Method0)),
  Path = case Path0 of
           <<"">> -> <<"/">>;
           _ -> Path0
         end,

  #client{options=Options} = Client0,

  %% basic & Cookies authorization handling
  Cookies = proplists:get_value(cookie, Options, []),
  DefaultHeaders = case proplists:get_value(basic_auth, Options) of
                     undefined ->
                      maybe_add_cookies(Cookies, [{<<"User-Agent">>, default_ua()}]);
                     {User, Pwd} ->
                       %% Security: Check if basic auth over HTTP is allowed
                       AllowInsecureAuth = proplists:get_value(insecure_basic_auth, Options, hackney_app:get_app_env(insecure_basic_auth, true)),
                       case {Client0#client.transport, AllowInsecureAuth} of
                         {hackney_ssl, _} ->
                           %% HTTPS connection - always safe
                           User1 = hackney_bstr:to_binary(User),
                           Pwd1 = hackney_bstr:to_binary(Pwd),
                           Credentials = base64:encode(<< User1/binary, ":", Pwd1/binary >>),
                           maybe_add_cookies(
                             Cookies,
                             [{<<"User-Agent">>, default_ua()},
                              {<<"Authorization">>, <<"Basic ", Credentials/binary>>}]
                            );
                         {_, true} ->
                           %% HTTP connection with explicit bypass - allow but warn
                           User1 = hackney_bstr:to_binary(User),
                           Pwd1 = hackney_bstr:to_binary(Pwd),
                           Credentials = base64:encode(<< User1/binary, ":", Pwd1/binary >>),
                           maybe_add_cookies(
                             Cookies,
                             [{<<"User-Agent">>, default_ua()},
                              {<<"Authorization">>, <<"Basic ", Credentials/binary>>}]
                            );
                         {_, false} ->
                           %% HTTP connection without bypass - reject
                           erlang:error({insecure_basic_auth, 
                                        "Basic authentication over HTTP is insecure. "
                                        "Use HTTPS, add {insecure_basic_auth, true} option, or set "
                                        "application:set_env(hackney, insecure_basic_auth, true) to bypass this check."})
                       end
                   end,

  %% detect the request type: normal or chunked
  {Headers1, ReqType0} = req_type(
                           hackney_headers_new:merge(Headers0, hackney_headers_new:new(DefaultHeaders)),
                           Body0
                          ),

  %% add host eventually
  Headers2 = maybe_add_host(Headers1, Client0#client.netloc),

  %% get expect headers
  Expect = expectation(Headers2),

  %% build headers with the body.
  {FinalHeaders, ReqType, Body, Client1} = case Body0 of
                                            stream ->
                                               {Headers2, ReqType0, stream, Client0};
                                            stream_multipart ->
                                              handle_multipart_body(Headers2, ReqType0, Client0);
                                            {stream_multipart, Size} ->
                                              handle_multipart_body(Headers2, ReqType0, Size, Client0);
                                            {stream_multipart, Size, Boundary} ->
                                              handle_multipart_body(Headers2, ReqType0,
                                                                    Size, Boundary, Client0);
                                            <<>> when Method =:= <<"POST">> orelse Method =:= <<"PUT">> ->
                                              handle_body(Headers2, ReqType0, Body0, Client0);
                                            [] when Method =:= <<"POST">> orelse Method =:= <<"PUT">> ->
                                              handle_body(Headers2, ReqType0, Body0, Client0);
                                            <<>> ->
                                              {Headers2, ReqType0, Body0, Client0};
                                            [] ->
                                              {Headers2, ReqType0, Body0, Client0};
                                            _ ->
                                              handle_body(Headers2, ReqType0, Body0, Client0)
                                          end,

  %% build final client record
  Client = case ReqType of
             normal ->
               Client1#client{send_fun=fun hackney_request:send/2, req_type=normal};
             chunked ->
               Client1#client{send_fun=fun hackney_request:send_chunk/2, req_type=chunked}
           end,

  %% request to send
  HeadersData = [
                 << Method/binary, " ", Path/binary, " HTTP/1.1", "\r\n" >>,
                 hackney_headers_new:to_iolist(FinalHeaders)
                ],

  PerformAll = proplists:get_value(perform_all, Options, true),

  ?report_verbose("perform request", [{header_data, HeadersData},
                                      {perform_all, PerformAll},
                                      {expect, Expect}]),


  case can_perform_all(Body, Expect, PerformAll) of
    true ->
      perform_all(Client, HeadersData, Body, Method, Path, Expect);
    _ ->
      case hackney_request:send(Client, HeadersData) of
        ok when Body =:= stream ->
          {ok, Client#client{response_state=stream,
                             method=Method,
                             path=Path,
                             expect=Expect}};
        ok ->
          case stream_body(Body, Client#client{expect=Expect}) of
            {error, _Reason}=E ->
              E;
            {stop, Client2} ->
              FinalClient = Client2#client{method=Method,
                                           path=Path},
              hackney_response:start_response(FinalClient);
            {ok, Client2} ->
              case end_stream_body(Client2) of
                {ok, Client3} ->
                  FinalClient = Client3#client{method=Method,
                                               path=Path},
                  hackney_response:start_response(FinalClient);
                Error ->
                  Error
              end
          end;
        Error ->
          Error
      end
  end.

location(Client) ->
  #client{headers=Headers, transport=Transport, netloc=Netloc, path=Path} = Client,
  case hackney_headers_new:get_value(<<"location">>, Headers) of
    undefined ->
      Scheme = hackney_url:transport_scheme(Transport),
      Url = #hackney_url{scheme=Scheme, netloc=Netloc, path=Path},
      hackney_url:unparse_url(Url);
    Location ->
      Location
  end.

stream_body(Msg, #client{expect=true}=Client) ->
  case hackney_response:expect_response(Client) of
    {continue, Client2} ->
      stream_body(Msg, Client2);
    {stop, Client2} ->
      {stop, Client2};
    Error ->
      Error
  end;
stream_body(eof, Client) ->
  {ok, Client};
stream_body(<<>>, Client) ->
  {ok, Client};
stream_body(Func, Client) when is_function(Func) ->
  case Func() of
    {ok, Data} ->
      case stream_body(Data, Client) of
        {ok, Client1} ->
          stream_body(Func, Client1);
        Error ->
          Error
      end;
    eof ->
      stream_body(eof, Client);
    Err ->
      Err
  end;
stream_body({Func, State}, Client) when is_function(Func) ->
  case Func(State) of
    {ok, Data, NewState} ->
      case stream_body(Data, Client) of
        {ok, Client1} ->
          stream_body({Func, NewState}, Client1);
        Error ->
          Error
      end;
    eof ->
      stream_body(eof, Client);
    Err ->
      Err
  end;
stream_body({file, FileName}, Client) ->
  stream_body({file, FileName, []}, Client);
stream_body({file, FileName, Opts}, Client) ->
  case sendfile(FileName, Opts, Client) of
    {ok, _BytesSent} ->
      {ok, Client};
    Error ->
      Error
  end;
stream_body(Body, #client{send_fun=Send}=Client) ->
  case Send(Client, Body) of
    ok ->
      {ok, Client};
    Error ->
      Error
  end.

%% @doc stream multipart
stream_multipart(eof, #client{response_state=waiting}=Client) ->
  {ok, Client};
stream_multipart(eof, #client{mp_boundary=Boundary}=Client) ->
  case stream_body(hackney_multipart:mp_eof(Boundary), Client) of
    {ok, Client1} ->
      end_stream_body(Client1);
    Error ->
      Error
  end;
stream_multipart({mp_mixed, Name, MixedBoundary}, #client{mp_boundary=Boundary}=Client) ->
  {MpHeader, _} = hackney_multipart:mp_mixed_header({Name, MixedBoundary}, Boundary),
  stream_body(<< MpHeader/binary, "\r\n" >>, Client);
stream_multipart({mp_mixed_eof, MixedBoundary}, Client) ->
  Eof = hackney_multipart:mp_eof(MixedBoundary),
  stream_body(<< Eof/binary, "\r\n" >>, Client);
stream_multipart({file, Path}, Client) ->
  stream_multipart({file, Path, []}, Client);
stream_multipart({file, Path, <<Name/binary>>}, Client) ->
  stream_multipart({file, Path, Name, []}, Client);
stream_multipart({file, Path, ExtraHeaders}, Client) ->
  stream_multipart({file, Path, <<"file">>, ExtraHeaders}, Client);
stream_multipart({file, Path, _Name, _ExtraHeaders}=File,
  #client{mp_boundary=Boundary}=Client) ->
  {MpHeader, _} = hackney_multipart:mp_file_header(File, Boundary),
  case stream_body(MpHeader, Client) of
    {ok, Client1} ->
      case stream_body({file, Path}, Client1) of
        {ok, Client2} ->
          stream_body(<<"\r\n">>, Client2);
        Error ->
          Error
      end;
    Error ->
      Error
  end;
stream_multipart({data, Name, Bin}, Client) ->
  stream_multipart({data, Name, Bin, []}, Client);
stream_multipart({data, Name, Bin, ExtraHeaders},
  #client{mp_boundary=Boundary}=Client) ->
  Len = byte_size(Name),
  {MpHeader, _} = hackney_multipart:mp_data_header({Name, Len, ExtraHeaders},
    Boundary),
  Bin1 = << MpHeader/binary, Bin/binary, "\r\n" >>,
  stream_body(Bin1, Client);
stream_multipart({part, eof}, Client) ->
  stream_body(<<"\r\n">>, Client);
stream_multipart({part, Headers}, #client{mp_boundary=Boundary}=Client)
  when is_list(Headers) ->
  MpHeader = hackney_multipart:mp_header(Headers, Boundary),
  stream_body(MpHeader, Client);
stream_multipart({part, Name}, Client) when is_binary(Name) ->
  stream_multipart({part, Name, []}, Client);
stream_multipart({part, Name, ExtraHeaders},
  #client{mp_boundary=Boundary}=Client)
  when is_list(ExtraHeaders) ->
  %% part without content-length
  CType = mimerl:filename(Name),
  Headers = [{<<"Content-Disposition">>,
    <<"form-data">>, [{<<"name">>, <<"\"", Name/binary, "\"">>}]},
    {<<"Content-Type">>, CType}],
  MpHeader = hackney_multipart:mp_header(Headers, Boundary),
  stream_body(MpHeader, Client);
stream_multipart({part, Name, Len}, Client) when is_integer(Len)->
  stream_multipart({part, Name, Len, []}, Client);
stream_multipart({part, Name, Len, ExtraHeaders},
  #client{mp_boundary=Boundary}=Client) ->
  {MpHeader, _} = hackney_multipart:mp_data_header({Name, Len, ExtraHeaders},
    Boundary),
  stream_body(MpHeader, Client);
stream_multipart({part_bin, Bin}, Client) ->
  stream_body(Bin, Client).

send(#client{transport=Transport, socket=Skt}, Data) ->
  Transport:send(Skt, Data).

send_chunk(Client, Data) ->
  Length = iolist_size(Data),
  send(Client, [io_lib:format("~.16b\r\n", [Length]), Data,
    <<"\r\n">>]).

sendfile(FileName, Opts, #client{transport=hackney_tcp_tansport, socket=Skt,
  req_type=normal}) ->
  Offset = proplists:get_value(offset, Opts, 0),
  Bytes = proplists:get_value(bytes, Opts, 0),

  SendFileOpts = case proplists:get_value(chunk_size, Opts, ?CHUNK_SIZE) of
                   undefined -> Opts;
                   ChunkSize -> [{chunk_size, ChunkSize}]
                 end,
  file:sendfile(FileName, Skt, Offset, Bytes, SendFileOpts);
sendfile(FileName, Opts, Client) ->
  case file:open(FileName, [read, raw, binary]) of
    {error, Reason} ->
      {error, Reason};
    {ok, Fd} ->
      Res = sendfile_fallback(Fd, Opts, Client),
      ok = file:close(Fd),
      Res
  end.

%% @doc encode a list of properties in a form.
encode_form(KVs) ->
  Lines = hackney_url:qs(KVs),
  CType = <<"application/x-www-form-urlencoded; charset=utf-8">>,
  {erlang:byte_size(Lines), CType, Lines}.

%% internal
handle_body(Headers, ReqType0, Body0, Client) ->
  {CLen, CType, Body} = case Body0 of
                          {form, KVs} ->
                            encode_form(KVs);
                          {multipart, Parts} ->
                            Boundary = hackney_multipart:boundary(),
                            MpLen = hackney_multipart:len_mp_stream(Parts, Boundary),
                            MpStream = make_multipart_stream(Parts, Boundary),
                            CT = << "multipart/form-data; boundary=", Boundary/binary >>,
                            {MpLen, CT, MpStream};
                          {file, FileName} ->
                            S= filelib:file_size(FileName),
                            FileName1 = hackney_bstr:to_binary(FileName),
                            CT = hackney_headers_new:get_value(
                                   <<"content-type">>, Headers, mimerl:filename(FileName1)
                                  ),
                            {S, CT, Body0};
                          Func when is_function(Func) ->
                            CT = hackney_headers_new:get_value(
                                   <<"content-type">>, Headers, <<"application/octet-stream">>
                                  ),
                            S = hackney_headers_new:get_value(<<"content-length">>, Headers),
                            {S, CT, Body0};
                          {Func, _} when is_function(Func) ->
                            CT = hackney_headers_new:get_value(
                                   <<"content-type">>, Headers, <<"application/octet-stream">>
                                  ),
                            S = hackney_headers_new:get_value(<<"content-length">>, Headers),
                            {S, CT, Body0};

                          _ when is_list(Body0) -> % iolist case
                            Body1 = iolist_to_binary(Body0),
                            S = erlang:byte_size(Body1),
                            CT = hackney_headers_new:get_value(
                                   <<"content-type">>, Headers, <<"application/octet-stream">>
                                  ),
                            {S, CT, Body1};
                          _ when is_binary(Body0) ->
                            S = erlang:byte_size(Body0),
                            CT = hackney_headers_new:get_value(
                                   <<"content-type">>, Headers, <<"application/octet-stream">>
                                  ),
                            {S, CT, Body0}
                        end,

  {NewHeaders, ReqType} = case {ReqType0, Body} of
                            {chunked, {file, _}} ->
                              Headers1 = hackney_headers_new:delete(
                                           <<"transfer-encoding">>,
                                           hackney_headers_new:store(
                                             <<"Content-Type">>, CType,
                                             hackney_headers_new:store(
                                               <<"Content-Length">>, CLen, Headers))),
                              {Headers1, normal};
                            {chunked, _} ->
                              Headers1 = hackney_headers_new:delete(
                                           <<"content-length">>,
                                           hackney_headers_new:store(
                                             <<"Content-Type">>, CType, Headers)),
                              {Headers1, chunked};
                            {_, _} when CLen =:= undefined ->
                              Headers1 = hackney_headers_new:delete(
                                           <<"content-length">>,
                                           hackney_headers_new:store(
                                             [{<<"Content-Type">>, CType},
                                              {<<"Transfer-Encoding">>, <<"chunked">>}],
                                             Headers)),
                              {Headers1, chunked};
                            {_, _} ->
                              Headers1 = hackney_headers_new:delete(
                                           <<"transfer-encoding">>,
                                           hackney_headers_new:store(
                                             [{<<"Content-Type">>, CType},
                                              {<<"Content-Length">>, CLen}],
                                             Headers)),
                              {Headers1, normal}
                          end,
  {NewHeaders, ReqType, Body, Client}.

handle_multipart_body(Headers, ReqType, Client) ->
  handle_multipart_body(Headers, ReqType, chunked, hackney_multipart:boundary(), Client).

handle_multipart_body(Headers, ReqType, CLen, Client) ->
  handle_multipart_body(Headers, ReqType, CLen, hackney_multipart:boundary(), Client).

handle_multipart_body(Headers, ReqType, CLen, Boundary, Client) ->
  CType = case hackney_headers_new:get_value(<<"content-type">>, Headers) of
            undefined ->
              << "multipart/form-data; boundary=", Boundary/binary >>;
            Value ->
              case hackney_headers_new:parse_content_type(Value) of
                {<<"multipart">>, _, _} -> Value;
                _ ->
                  << "multipart/form-data; boundary=", Boundary/binary >>
              end
          end,

  {NewHeaders, ReqType1}  = case {CLen, ReqType} of
                              {chunked, _} ->
                                Headers1 = hackney_headers_new:delete(
                                             <<"content-length">>,
                                             hackney_headers_new:store(
                                               [{<<"Content-Type">>, CType},
                                                {<<"Transfer-Encoding">>, <<"chunked">>}],
                                               Headers)),
                                {Headers1, chunked};
                              {_, _} ->
                                Headers1 = hackney_headers_new:delete(
                                             <<"transfer-encoding">>,
                                             hackney_headers_new:store(
                                               [{<<"Content-Type">>, CType},
                                                {<<"Content-Length">>, CLen}],
                                               Headers)),
                                {Headers1, normal}
                            end,
  {NewHeaders, ReqType1, stream, Client#client{response_state=stream,
                                               mp_boundary=Boundary}}.

req_type(Headers, stream) ->
  Te = hackney_bstr:to_lower(
         hackney_headers_new:get_value(<<"transfer-encoding">>, Headers, <<>>)
        ),
  case Te of
    <<"chunked">> -> {Headers, chunked};
    _ ->
      case hackney_headers_new:get_value(<<"content-length">>, Headers) of
        undefined ->
          Headers2 = hackney_headers_new:store(
                       <<"Transfer-Encoding">>, <<"chunked">>, Headers
                      ),
          {Headers2, chunked};
        _ ->
          {Headers, normal}
      end
  end;
req_type(Headers, _Body) ->
  Te = hackney_bstr:to_lower(
         hackney_headers_new:get_value(<<"transfer-encoding">>, Headers, <<>>)
        ),
  case Te of
    <<"chunked">> -> {Headers, chunked};
    _ -> {Headers, normal}
  end.


expectation(Headers) ->
  Expect = hackney_headers_new:get_value(<<"expect">>, Headers, <<>>),
  (hackney_bstr:to_lower(Expect) =:= <<"100-continue">>).

end_stream_body(#client{req_type=chunked}=Client) ->
  case send_chunk(Client, <<>>) of
    ok ->
      {ok, Client#client{response_state=waiting}};
    Error ->
      Error
  end;
end_stream_body(Client) ->
  {ok, Client#client{response_state=waiting}}.

can_perform_all(Body, Expect, PerformAll) when Expect =:= false,
                                               (is_list(Body) orelse is_binary(Body)) ->
  PerformAll;
can_perform_all(_Body, _Expect, _PerformAll) ->
  false.

perform_all(Client, HeadersData, Body, Method, Path, Expect) ->
  case stream_body(iolist_to_binary([HeadersData, Body]),
    Client#client{expect=Expect}) of
    {error, _Reason}=E ->
      E;
    {stop, Client2} ->
      FinalClient = Client2#client{method=Method, path=Path},
      hackney_response:start_response(FinalClient);
    {ok, Client2} ->
      case end_stream_body(Client2) of
        {ok, Client3} ->
          FinalClient = Client3#client{method=Method,
            path=Path},
          hackney_response:start_response(FinalClient);
        Error ->
          Error
      end
  end.

sendfile_fallback(Fd, Opts, Client) ->
  Offset = proplists:get_value(offset, Opts, 0),
  Bytes = proplists:get_value(bytes, Opts, 0),
  ChunkSize = proplists:get_value(chunk_size, Opts, ?CHUNK_SIZE),

  {ok, CurrPos} = file:position(Fd, {cur, 0}),
  {ok, _NewPos} = file:position(Fd, {bof, Offset}),
  Res = sendfile_fallback(Fd, Bytes, ChunkSize, Client, 0),
  {ok, _} = file:position(Fd, {bof, CurrPos}),
  Res.

sendfile_fallback(Fd, Bytes, ChunkSize, #client{send_fun=Send}=Client, Sent)
  when Bytes > Sent orelse Bytes =:= 0 ->

  Length = if Bytes > 0 -> erlang:min(ChunkSize, Bytes - Sent);
             true -> ChunkSize
           end,

  case file:read(Fd, Length) of
    {ok, Data} ->
      Len = iolist_size(Data),
      case Send(Client, Data) of
        ok ->
          sendfile_fallback(Fd, Bytes, ChunkSize, Client,
            Sent + Len);
        Error ->
          Error
      end;
    eof ->
      {ok, Sent};
    Error ->
      Error
  end;
sendfile_fallback(_, _, _, _, Sent) ->
  {ok, Sent}.

-spec make_multipart_stream(list(), binary()) -> {fun(), list()}.
make_multipart_stream(Parts, Boundary) ->
  Stream = lists:foldl(fun
                         ({file, Path}, Acc) ->
                           {MpHeader, _} = hackney_multipart:mp_file_header(
                             {file, Path}, Boundary),
                           [<<"\r\n">>, {file, Path}, MpHeader | Acc];
                         ({file, Path, ExtraHeaders}, Acc) ->
                           {MpHeader, _} = hackney_multipart:mp_file_header(
                             {file, Path, ExtraHeaders}, Boundary),
                           [<<"\r\n">>, {file, Path}, MpHeader | Acc];
                         ({file, Path, Disposition, ExtraHeaders}, Acc) ->
                           {MpHeader, _} = hackney_multipart:mp_file_header(
                             {file, Path, Disposition, ExtraHeaders}, Boundary),
                           [<<"\r\n">>, {file, Path}, MpHeader | Acc];
                         ({mp_mixed, Name, MixedBoundary}, Acc) ->
                           {MpHeader, _} = hackney_multipart:mp_mixed_header(
                             Name, MixedBoundary),
                           [<< MpHeader/binary, "\r\n" >> | Acc];
                         ({mp_mixed_eof, MixedBoundary}, Acc) ->
                           Eof = hackney_multipart:mp_eof(MixedBoundary),
                           [<< Eof/binary, "\r\n" >> | Acc];
                         ({Name, Bin}, Acc) ->
                           Len = byte_size(Bin),
                           {MpHeader, _} = hackney_multipart:mp_data_header(
                             {Name, Len}, Boundary),
                           PartBin = << MpHeader/binary, Bin/binary, "\r\n" >>,
                           [PartBin | Acc];
                         ({Name, Bin, ExtraHeaders}, Acc) ->
                           Len = byte_size(Bin),
                           {MpHeader, _} = hackney_multipart:mp_data_header(
                             {Name, Len, ExtraHeaders}, Boundary),
                           PartBin = << MpHeader/binary, Bin/binary, "\r\n" >>,
                           [PartBin | Acc];
                         ({Name, Bin, Disposition, ExtraHeaders}, Acc) ->
                           Len = byte_size(Bin),
                           {MpHeader, _} = hackney_multipart:mp_data_header(
                             {Name, Len, Disposition,  ExtraHeaders},
                             Boundary),
                           PartBin = << MpHeader/binary, Bin/binary, "\r\n" >>,
                           [PartBin | Acc]
                       end, [], Parts),

  FinalStream = lists:reverse([hackney_multipart:mp_eof(Boundary) |
    Stream]),

  %% function used to stream
  StreamFun = fun
                ([]) ->
                  eof;
                ([Part | Rest]) ->
                  {ok, Part, Rest}
              end,

  {StreamFun, FinalStream}.


maybe_add_cookies([], Headers) ->
  Headers;
maybe_add_cookies(Cookie, Headers) when is_binary(Cookie) ->
  Headers ++ [{<<"Cookie">>, Cookie}];
maybe_add_cookies({Name, Value}, Headers) ->
  Cookie = hackney_cookie:setcookie(Name, Value, []),
  Headers ++ [{<<"Cookie">>, Cookie}];
maybe_add_cookies({Name, Value, Opts}, Headers) ->
  Cookie = hackney_cookie:setcookie(Name, Value, Opts),
  Headers ++ [{<<"Cookie">>, Cookie}];
maybe_add_cookies([{Name, Value} | Rest], Headers) ->
  Cookie = hackney_cookie:setcookie(Name, Value, []),
  Headers1 = Headers ++ [{<<"Cookie">>, Cookie}],
  maybe_add_cookies(Rest, Headers1);
maybe_add_cookies([{Name, Value, Opts} | Rest], Headers) ->
  Cookie = hackney_cookie:setcookie(Name, Value, Opts),
  Headers1 = Headers ++ [{<<"Cookie">>, Cookie}],
  maybe_add_cookies(Rest, Headers1);
maybe_add_cookies([Cookie | Rest], Headers) ->
  Headers1 = Headers ++ [{<<"Cookie">>, Cookie}],
  maybe_add_cookies(Rest, Headers1).

default_ua() ->
  Version = case application:get_key(hackney, vsn) of
              {ok, FullVersion} ->
                list_to_binary(hd(string:tokens(FullVersion, "-")));
              _ ->
                << "0.0.0" >>
            end,
  << "hackney/", Version/binary >>.

maybe_add_host(Headers0, Netloc) ->
  {_, Headers1} = hackney_headers_new:store_new(<<"Host">>, Netloc, Headers0),
  Headers1.

is_default_port(#client{transport=hackney_tcp, port=80}) ->
  true;
is_default_port(#client{transport=hackney_ssl, port=443}) ->
  true;
is_default_port(_) ->
  false.
