%%% -*- erlang -*-
%%%
%%% This file is part of hackney_lib released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>
%%% Copyright (c) 2013-2015 Benoit Chesneau
%%%
%%% @doc HTTP parser in pure Erlang
%%% This parser is able to parse HTTP responses and requests in a
%%% streaming fashion. If not set it will be autodetect the type of
%%% binary parsed, if it's a request or a response.
%%%
%%% Internally it is keeping a buffer for intermediary steps but don't
%%% keep any state in memory.
%%%
%%%
%%% The first time you initialise a parser using `hackney_http:parser/0'
%%% or `hackney_http:parser/1' you will receive an opaque record You can
%%% then process it using the function `hackney_http:execute/2'.
%%%
%%% Each steps will return the status, some data and the new parser that
%%% you can process later with `hackney_http:execute/2' when
%%% `{more, ...}'  is returnned or `hackney_http:execute/1' in other
%%% cases:
%%% <ul>
%%%  <li>`{response, http_version(), status(), http_reason(), parser()}':
%%% when the first line of a response is parsed</li>
%%%  <li>`{request, http_version(), http_method(), uri(), parser()}':
%%% when the first line of a request (on servers) is parsed</li>
%%%  <li>`{more, parser()}': when the parser need more
%%% data. The new data should be passed to `hackney_http:execute/2' with
%%% the new parser() state received.</li>
%%%  <li>`{header, {Name :: binary(), Value :: binary()}, parser()}':
%%% when an header has been parsed. To continue the parsing you must
%%% call the given `parser()' with `hackney_http:execute/1'.</li>
%%%  <li>`{headers_complete, parser()}' : when all headers have been parsed.
%%% To continue the parsing you must call the given `parser()' state
%%% with `hackney_http:execute/1'.</li>
%%%  <li>`{more, parser(), binary()}': on body, when
%%% the parser need more data. The new data should be passed to
%%% `hackney_http:execute/2' (with `parser()' ) when received. The binary at the end of the
%%% tuple correspond to the actual buffer of the parser. It may be used
%%% for other purpose, like start to parse a new request on pipeline
%%% connections, for a proxy...</li>
%%%  <li>`{ok, binary(), parser()}': on body, when a chunk has been
%%% parsed. To continue the parsing you must call
%%% `hackney_http:execute/1' with the given `parser()'.</li>
%%%  <li>`{done, binary()}': when the parsing is done. The binary
%%% given correpond to the non parsed part of the internal buffer.</li>
%%%  <li>`{error, term{}}': when an error happen</li>
%%% </ul>

-module(hackney_http).

-export([parser/0, parser/1]).
-export([execute/1, execute/2]).
-export([get/2]).
-export([parse_response_version/2]).

-include("hackney_lib.hrl").


-type parser() :: #hparser{}.
-export_type([parser/0]).

-type http_version() :: {integer(), integer()}.
-type status() :: integer().
-type http_reason() :: binary().
-type http_method() :: binary().
-type uri() :: binary().
-type body_result() :: {more, parser(), binary()}
| {ok, binary(), parser()}
| {done, binary()}
| done.

-type header_result() :: {headers_complete, parser()}
| {header, {binary(), binary()}, parser()}.

-type parser_result() ::
{response, http_version(), status(), http_reason(), parser()}
| {request, http_method(), uri(), http_version(), parser()}
| {more, parser()}
| header_result()
| body_result()
| {error, term()}.

-type parser_option() :: request | response | auto
| {max_empty_lines, integer()}
| {max_line_length, integer()}.

-type parser_options() :: [parser_option()].


%% @doc Create a new HTTP parser. The parser will autodetect if the parded
%% binary is a response or a request.
-spec parser() -> parser().
parser() ->
  parser([]).

%% @doc create a new HTTP parser with options. By default the type of
%% parsed binary will be detected.
%%
%% Available options:
%% <ul>
%%  <li>`auto' : autodetect if the binary parsed is a response or a
%%  request (default).</li>
%%  <li>`response': set the parser to parse a response</li>
%%  <li>`request': set the parser to parse a request (server)</li>
%%  <li>`{max_line_lenght, Max}': set the maximum size of a line parsed
%%  before we give up.</li>
%%  <li>`{max_lines_empty, Max}': the maximum number of empty line we
%%  accept before the first line happen</li>
%% </ul>
-spec parser(parser_options()) -> parser().
parser(Options) ->
  parse_options(Options, #hparser{}).

%% @doc retrieve a parser property.
%% Properties are:
%% <ul>
%%  <li>`buffer': internal buffer of the parser (non parsed)</li>
%%  <li>`state': the current state (on_status, on_header, on_body, done)</li>
%%  <li>`version': HTTP version</li>
%%  <li>`content_length': content length header if any</li>
%%  <li>`transfer_encoding': transfer encoding header if any</li>
%%  <li>`content_type': content type header if any</li>
%%  <li>`location': location header if any</li>
%%  <li>`connection': connection header if any.</li>
%% </ul>
-spec get(parser(), atom() | [atom()]) -> any().
get(Parser, Props) when is_list(Props) ->
  [get_property(P, Parser) || P <- Props];
get(Parser, Prop) ->
  get_property(Prop, Parser).

%% @doc Execute the parser with the current buffer.
-spec execute(#hparser{}) -> parser_result().
execute(St) ->
  execute(St, <<>>).

%% @doc Execute the parser with the new buffer
-spec execute(#hparser{}, binary()) -> parser_result().
execute(#hparser{state=Status, buffer=Buffer}=St, Bin) ->
  %% update the state with the new buffer
  NBuffer = << Buffer/binary, Bin/binary >>,
  St1 = St#hparser{buffer=NBuffer},

  %% process the right state.
  case Status of
    done -> done;
    on_first_line -> parse_first_line(NBuffer, St1, 0);
    on_header -> parse_headers(St1);
    on_body -> parse_body(St1);
    on_trailers -> parse_trailers(St1);
    on_junk -> skip_junks(St1)
  end.

%% Empty lines must be using \r\n.
parse_first_line(<< $\n, Buffer/binary >>, #hparser{empty_lines = Empty0} = St, Empty) ->
  parse_first_line(Buffer, St#hparser{buffer = Buffer, empty_lines = Empty0 + 1}, Empty + 1);
%% We limit the length of the first-line to MaxLength to avoid endlessly
%% reading from the socket and eventually crashing.
parse_first_line(_Buffer, #hparser{max_empty_lines=MaxEmpty}, Empty) when Empty >= MaxEmpty ->
  {error, bad_request};
parse_first_line(Buffer, St=#hparser{type=Type,
  max_line_length=MaxLength,
  max_empty_lines=MaxEmpty}, Empty) ->
  case match_eol(Buffer, 0) of
    nomatch when byte_size(Buffer) > MaxLength ->
      {error, line_too_long};
    nomatch ->
      {more, St#hparser{empty_lines=Empty}};
    1 when Empty =:= MaxEmpty ->
      {error, bad_request};
    1 ->
      << _:16, Rest/binary >> = Buffer,
      parse_first_line(Rest, St#hparser{buffer=Rest}, Empty + 1);
    _ when Type =:= auto ->
      case parse_request_line(St) of
        {request, _Method, _URI, _Version, _NState} = Req -> Req;
        {error, bad_request} -> parse_response_line(St)
      end;
    _ when Type =:= response ->
      case parse_response_line(St) of
	  {error, bad_request} -> {error, bad_request};
	  {response, Version, StatusInt, Reason, NState} when StatusInt >= 200 ->
	      {response, Version, StatusInt, Reason, NState};
	  {response, _Version, _StatusInt, _Reason, _NState} ->
	      {more, St#hparser{empty_lines=Empty, state=on_junk}}
      end;
    _ when Type =:= request ->
      parse_request_line(St)
  end.

match_eol(<< $\n, _/bits >>, N) ->
  N;
match_eol(<< _, Rest/bits >>, N) ->
  match_eol(Rest, N + 1);
match_eol(_, _) ->
  nomatch.

%% @doc parse status
parse_response_line(#hparser{}=St) ->
  parse_response_line([<<"\r\n">>, <<"\n">>], St).

parse_response_line([], _St) ->
  {error, bad_request};
parse_response_line([Sep | SepRest], #hparser{buffer=Buf}=St) ->
  case binary:split(Buf, Sep) of
    [Line, Rest] ->
      parse_response_version(Line, St#hparser{buffer=Rest});
    _Other ->
      parse_response_line(SepRest, #hparser{buffer=Buf}=St)
  end.


parse_response_version(<< "HTTP/", High, ".", Low, $\s, Rest/binary >>, St)
  when High >= $0, High =< $9, Low >= $0, Low =< $9 ->
  Version = { High -$0, Low - $0},
  parse_status(Rest, St, Version, <<>>);
parse_response_version(_, _) ->
  {error, bad_request}.

parse_status(<<>>, St, Version, Acc) ->
  parse_reason(<<>>, St, Version, Acc);
parse_status(<< C, Rest/bits >>, St, Version, Acc) ->
  case C of
    $\r ->  {error, bad_request};
    $\s -> parse_reason(Rest, St, Version, Acc);
    _ -> parse_status(Rest, St, Version, << Acc/binary, C >>)
  end.

parse_reason(Reason, St, Version, StatusCode) ->
  StatusInt = list_to_integer(binary_to_list(StatusCode)),

  NState = St#hparser{type=response,
    version=Version,
    state=on_header,
    partial_headers=[]},
  {response, Version, StatusInt, Reason, NState}.


parse_request_line(#hparser{buffer=Buf}=St) ->
  parse_method(Buf, St, <<>>).

parse_method(<< C, Rest/bits >>, St, Acc) ->
  case C of
    $\r ->  {error, bad_request};
    $\s -> parse_uri(Rest, St, Acc);
    _ -> parse_method(Rest, St, << Acc/binary, C >>)
  end.

parse_uri(<< $\r, _/bits >>, _St, _) ->
  {error, bad_request};
parse_uri(<< "* ", Rest/bits >>, St, Method) ->
  parse_version(Rest, St, Method, <<"*">>);
parse_uri(Buffer, St, Method) ->
  parse_uri_path(Buffer, St, Method, <<>>).

parse_uri_path(<< C, Rest/bits >>, St, Method, Acc) ->
  case C of
    $\r -> {error, bad_request};
    $\s -> parse_version(Rest, St, Method, Acc);
    _ -> parse_uri_path(Rest, St, Method, << Acc/binary, C >>)
  end.

parse_version(<< "HTTP/", High, ".", Low, Rest0/binary >>, St, Method, URI)
  when High >= $0, High =< $9, Low >= $0, Low =< $9 ->
  Version = { High -$0, Low - $0},
  Rest = case Rest0 of
           <<"\r\n", Rest1/binary>> ->
             Rest1;
           <<"\n", Rest1/binary>> ->
             Rest1
         end,
  NState = St#hparser{type=request,
    version=Version,
    method=Method,
    state=on_header,
    buffer=Rest,
    partial_headers=[]},
  {request, Method, URI, Version, NState};
parse_version(_, _, _, _) ->
  {error, bad_request}.

%% @doc fetch all headers
parse_headers(#hparser{}=St) ->
  parse_header(St).


parse_header(#hparser{}=St) ->
  parse_header_sep([<<"\r\n">>, <<"\n">>], St).

parse_header_sep([], St) ->
  {more, St};
parse_header_sep([Sep | SepRest], #hparser{buffer=Buf}=St) ->
  case binary:split(Buf, Sep) of
    [_, _] ->
      parse_header_(Sep, St);
    [Buf] ->
      parse_header_sep(SepRest, St)
  end.

parse_header_(Sep, #hparser{buffer=Buf}=St) ->
  case binary:split(Buf, Sep) of
    [<<>>, Rest] ->
      {headers_complete, St#hparser{buffer=Rest,
        state=on_body}};
    [Line, << " ", Rest/binary >> ] ->
      NewBuf = iolist_to_binary([Line, " ", Rest]),
      parse_header_(Sep, St#hparser{buffer=NewBuf});
    [Line, << "\t", Rest/binary >> ] ->
      NewBuf = iolist_to_binary([Line, " ", Rest]),
      parse_header_(Sep, St#hparser{buffer=NewBuf});
    [Line, Rest]->
      parse_header(Line, St#hparser{buffer=Rest});
    [Buf] ->
      {more, St}
  end.

parse_header(Line, St) ->
  [Key, Value] = case binary:split(Line, <<":">>, [trim]) of
                   [K] -> [K, <<>>];
                   [K, V] -> [K, parse_header_value(V)]
                 end,
  St1 = case hackney_bstr:to_lower(hackney_bstr:trim(Key)) of
          <<"content-length">> ->
            case hackney_util:to_int(Value) of
              {ok, CLen} -> St#hparser{clen=CLen};
              false -> St#hparser{clen=bad_int}
            end;
          <<"transfer-encoding">> ->
            TE = hackney_bstr:to_lower(hackney_bstr:trim(Value)),
            St#hparser{te=TE};
          <<"connection">> ->
            Connection = hackney_bstr:to_lower(hackney_bstr:trim(Value)),
            St#hparser{connection=Connection};
          <<"content-type">> ->
            CType=hackney_bstr:to_lower(hackney_bstr:trim(Value)),
            St#hparser{ctype=CType};
          <<"location">> ->
            Location = hackney_bstr:trim(Value),
            St#hparser{location=Location};
          _ ->
            St
        end,
  {header, {Key, Value}, St1}.

parse_header_value(H) ->
  hackney_bstr:trim(H).

skip_junks(#hparser{buffer=Buf}=St) ->
  case binary:split(Buf, <<"\r\n">>) of
    [<<>>, Rest] ->
      {more, St#hparser{buffer=Rest, state=on_first_line}};
    [_Line, Rest]->
      skip_junks(St#hparser{buffer=Rest});
    [Buf] ->
      {more, St}
  end.

parse_trailers(St) ->
  case parse_trailers(St, []) of
    {ok, _Trailers, #hparser{buffer=Rest1}} ->
      {done, Rest1};
    {more, St2} ->
      {more, St2}
  end.

parse_trailers(St, Acc) ->
  case parse_headers(St) of
    {header, Header, St2} -> parse_trailers(St2, [Header | Acc]);
    {headers_complete, St2} -> {ok, lists:reverse(Acc), St2};
    {more, St2} -> {more, St2}
  end.

parse_body(#hparser{body_state=waiting, method= <<"HEAD">>, buffer=Buffer}) ->
 {done, Buffer};
parse_body(St=#hparser{body_state=waiting, te=TE, clen=Length, buffer=Buffer}) ->
  case {TE, Length} of
    {<<"chunked">>, _} ->
      parse_body(St#hparser{body_state=
      {stream, fun te_chunked/2, {0, 0}, fun ce_identity/1}});
    {_, 0} ->
      {done, Buffer};
    {_, bad_int} ->
      {done, Buffer};
    {_, _} ->
      parse_body(
        St#hparser{body_state={stream, fun te_identity/2, {0, Length}, fun ce_identity/1}}
       )
  end;
parse_body(#hparser{body_state=done, buffer=Buffer}) ->
  {done, Buffer};
parse_body(St=#hparser{buffer=Buffer, body_state={stream, _, _, _}}) when byte_size(Buffer) > 0 ->
  transfer_decode(Buffer, St#hparser{buffer= <<>>});
parse_body(St) ->
  {more, St, <<>>}.


-spec transfer_decode(binary(), #hparser{})
    -> {ok, binary(), #hparser{}} | {done, binary()} | {error, atom()}.
transfer_decode(Data, St=#hparser{
  body_state={stream, TransferDecode,
    TransferState, ContentDecode},
  buffer=Buf}) ->
  case TransferDecode(Data, TransferState) of
    {ok, Data2, TransferState2} ->
      content_decode(ContentDecode, Data2,
        St#hparser{body_state= {stream,
          TransferDecode,
          TransferState2,
          ContentDecode}});
    {ok, Data2, Rest, TransferState2} ->
      content_decode(ContentDecode, Data2,
        St#hparser{buffer=Rest,
          body_state={stream,
            TransferDecode,
            TransferState2,
            ContentDecode}});
    {chunk_done, Rest} ->
      parse_trailers(St#hparser{buffer=Rest, state=on_trailers, body_state=done});
    {chunk_ok, Chunk, Rest} ->
      {ok, Chunk, St#hparser{buffer=Rest}};
    more ->
      {more, St#hparser{buffer=Data}, Buf};
    {more, TransferState2} ->
      {more, St#hparser{buffer=Data, body_state={stream, TransferDecode, TransferState2, ContentDecode}}, Buf};
    {done, Rest} ->
      {done, Rest};
    {done, Data2, _Rest} ->
      content_decode(ContentDecode, Data2,
        St#hparser{body_state=done});
    {done, Data2, _Length, Rest} ->
      content_decode(ContentDecode, Data2, St#hparser{buffer=Rest,
        body_state=done});
    done ->
      {done, <<>>};
    {error, Reason} ->
      {error, Reason}
  end.


-spec content_decode(fun(), binary(), #hparser{})
    -> {ok, binary(), #hparser{}} | {error, atom()}.
content_decode(ContentDecode, Data, St) ->
  case ContentDecode(Data) of
    {ok, Data2} -> {ok, Data2, St};
    {error, Reason} -> {error, Reason}
  end.


%% @doc Decode a stream of chunks.
-spec te_chunked(binary(), any())
    -> more | {ok, binary(), {non_neg_integer(), non_neg_integer()}}
  | {ok, binary(), binary(),  {non_neg_integer(), non_neg_integer()}}
  | {done, non_neg_integer(), binary()} | {error, badarg}.
te_chunked(<<>>, _) ->
  done;
te_chunked(Data, _) ->
  case read_size(Data) of
    {ok, 0, Rest} ->
      {chunk_done, Rest};
    {ok, Size, Rest} ->
      case read_chunk(Rest, Size) of
        {ok, Chunk, Rest1} ->
          {chunk_ok, Chunk, Rest1};
        eof ->
          {more, {byte_size(Rest), Size}}
      end;
    eof ->
      more
  end.

%% @doc Decode an identity stream.
-spec te_identity(binary(), {non_neg_integer(), non_neg_integer()})
    -> {ok, binary(), {non_neg_integer(), non_neg_integer()}}
  | {done, binary(), non_neg_integer(), binary()}.
te_identity(Data, {Streamed, Total})
  when (Streamed + byte_size(Data)) < Total ->
  {ok, Data, {Streamed + byte_size(Data), Total}};
te_identity(Data, {Streamed, Total}) ->
  Size = Total - Streamed,
  << Data2:Size/binary, Rest/binary >> = Data,
  {done, Data2, Total, Rest}.

%% @doc Decode an identity content.
-spec ce_identity(binary()) -> {ok, binary()}.
ce_identity(Data) ->
  {ok, Data}.

read_size(Data) ->
  case read_size(Data, [], true) of
    {ok, Line, Rest} ->
      case io_lib:fread("~16u", Line) of
        {ok, [Size], _} ->
          {ok, Size, Rest};
        _ ->
          {error, {poorly_formatted_size, Line}}
      end;
    Err ->
      Err
  end.

read_size(<<>>, _, _) ->
  eof;

read_size(<<"\r\n", Rest/binary>>, Acc, _) ->
  {ok, lists:reverse(Acc), Rest};

read_size(<<"\n", Rest/binary>>, Acc, _) ->
  {ok, lists:reverse(Acc), Rest};

read_size(<<$;, Rest/binary>>, Acc, _) ->
  read_size(Rest, Acc, false);

read_size(<<$\s, Rest/binary>>, Acc, _) ->
  read_size(Rest, Acc, false);

read_size(<<C, Rest/binary>>, Acc, AddToAcc) ->
  case AddToAcc of
    true ->
      read_size(Rest, [C|Acc], AddToAcc);
    false ->
      read_size(Rest, Acc, AddToAcc)
  end.

read_chunk(Data, Size) ->
  case Data of
    <<Chunk:Size/binary, "\r\n", Rest/binary>> ->
      {ok, Chunk, Rest};
    <<_Chunk:Size/binary, Rest/binary>> when byte_size(Rest) >= 2 ->
      {error, poorly_formatted_chunked_size};
    _ ->
      eof
  end.

%% @private

parse_options([], St) ->
  St;
parse_options([auto | Rest], St) ->
  parse_options(Rest, St#hparser{type=auto});
parse_options([request | Rest], St) ->
  parse_options(Rest, St#hparser{type=request});
parse_options([response | Rest], St) ->
  parse_options(Rest, St#hparser{type=response});
parse_options([{max_line_length, MaxLength} | Rest], St) ->
  parse_options(Rest, St#hparser{max_line_length=MaxLength});
parse_options([{max_empty_lines, MaxEmptyLines} | Rest], St) ->
  parse_options(Rest, St#hparser{max_empty_lines=MaxEmptyLines});
parse_options([_ | Rest], St) ->
  parse_options(Rest, St).

get_property(buffer, #hparser{buffer=Buffer}) ->
  Buffer;
get_property(state, #hparser{state=State}) ->
  State;
get_property(version, #hparser{version=Version}) ->
  Version;
get_property(method, #hparser{method=Method}) ->
  Method;
get_property(transfer_encoding, #hparser{te=TE}) ->
  TE;
get_property(content_length, #hparser{clen=CLen}) ->
  CLen;
get_property(connection, #hparser{connection=Connection}) ->
  Connection;
get_property(content_type, #hparser{ctype=CType}) ->
  CType;
get_property(location, #hparser{location=Location}) ->
  Location.

%%% Private Tests
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

parse_response_header_with_trailing_whitespace_test() ->
  Response = <<"Content-Length: 27515  ">>,
  Parser1 = parser([response]),
  {header, {<<"Content-Length">>, Length}, _} = parse_header(Response, Parser1),
  ?assertEqual(<<"27515">>, Length).

-endif.
