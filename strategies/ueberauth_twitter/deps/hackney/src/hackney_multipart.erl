%%% -*- erlang -*-
%%%
%%% This file is part of hackney_lib released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2012-2015 Benoît Chesneau <benoitc@e-engura.org>
%%% Copyright (c) 2012 Ilya Khlopotov <ilya.khlopotov@gmail.com>
%%% Copyright (c) 2011, Anthony Ramine <nox@dev-extend.eu>
%%%

%% @doc module to encode/decode multipart

-module(hackney_multipart).

-include("hackney_lib.hrl").

-export([encode_form/1, encode_form/2,
         decode_form/2,
         boundary/0,
         parser/1]).

-export([mp_header/2,
         mp_eof/1,
         part/3,
         len_mp_stream/2,
         mp_file_header/2,
         mp_mixed_header/2,
         mp_data_header/2]).

-type part_parser() :: parser(more(part_result())).
-type parser(T) :: fun((binary()) -> T).
-type more(T) :: T | {more, parser(T)}.
-type part_result() :: headers() | eof.
-type headers() :: {headers, http_headers(), body_cont()}.
-type http_headers() :: [{binary(), binary()}].
-type body_cont() :: cont(more(body_result())).
-type cont(T) :: fun(() -> T).
-type body_result() :: {body, binary(), body_cont()} | end_of_part().
-type end_of_part() :: {end_of_part, cont(more(part_result()))}.

%% @doc encode a list of parts a multipart form.
%% Parts can be under the form:
%% <ul>
%%  <li>`{file, Path}' : to send a file</li>
%%  <li>`{file, Path, ExtraHeaders}' : to send a file with extra headers</li>
%%  <li>`{file, Path, Name, ExtraHeaders}': to send a file with DOM element name and extra headers</li>
%%  <li>`{mp_mixed, Name, Boundary}' to send a mixed multipart.</li>
%%  <li>`{mp_mixed_eof, Boundary}': to signal the end of the mixed
%%  multipart boundary.</li>
%%  <li>`{Name, Data}': to send a custom content as a part</li>
%%  <li>`{Name, Data, ExtraHeaders}': the same as above but with extra
%%  headers.</li>
%% </ul>
encode_form(Parts) ->
    encode_form(Parts, boundary()).

-spec encode_form(list(), binary()) -> {binary(), integer()}.
encode_form(Parts, Boundary) ->
    {Size, Acc} = lists:foldl(fun
                ({file, Path}, {AccSize, AccBin}) ->
                    {MpHeader, Len} = mp_file_header({file, Path}, Boundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + Len + 2,
                    {ok, Bin} = file:read_file(Path),
                    PartBin = << MpHeader/binary, Bin/binary , "\r\n" >>,
                    {AccSize1, << AccBin/binary, PartBin/binary >>};
                ({file, Path, ExtraHeaders}, {AccSize, AccBin}) ->
                    {MpHeader, Len} = mp_file_header({file, Path,
                                                      ExtraHeaders}, Boundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + Len + 2,
                    {ok, Bin} = file:read_file(Path),
                    PartBin = << MpHeader/binary, Bin/binary, "\r\n"  >>,
                    {AccSize1, << AccBin/binary, PartBin/binary >>};
                ({file, Path, {Disposition, Params}, ExtraHeaders}, {
                                AccSize, AccBin}) ->
                    {MpHeader, Len} = mp_file_header({file, Path, {Disposition, Params},
                                                      ExtraHeaders}, Boundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + Len + 2,
                    {ok, Bin} = file:read_file(Path),
                    PartBin = << MpHeader/binary, Bin/binary, "\r\n"  >>,
                    {AccSize1, << AccBin/binary, PartBin/binary >>};
                ({file, Path, Name, ExtraHeaders}, {AccSize, AccBin}) ->
                    {MpHeader, Len} = mp_file_header({file, Path, Name,
                                                      ExtraHeaders}, Boundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + Len + 2,
                    {ok, Bin} = file:read_file(Path),
                    PartBin = << MpHeader/binary, Bin/binary, "\r\n"  >>,
                    {AccSize1, << AccBin/binary, PartBin/binary >>};
                ({mp_mixed, Name, MixedBoundary}, {AccSize, AccBin}) ->
                    {MpHeader, _} = mp_mixed_header(Name, MixedBoundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + 2,
                    {AccSize1, << AccBin/binary, MpHeader/binary, "\r\n" >>};
                ({mp_mixed_eof, MixedBoundary}, {AccSize, AccBin}) ->
                    Eof = mp_eof(MixedBoundary),
                    {AccSize + byte_size(Eof) + 2, <<AccBin/binary,
                                                     Eof/binary, "\r\n" >>};
                ({Name, Bin}, {AccSize, AccBin}) when is_binary(Bin) ->
                    Len = byte_size(Bin),
                    {MpHeader, Len} = mp_data_header({Name, Len}, Boundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + Len + 2,
                    PartBin = << MpHeader/binary, Bin/binary, "\r\n" >>,
                    {AccSize1, << AccBin/binary, PartBin/binary >>};
                ({Name, Bin, ExtraHeaders}, {AccSize, AccBin})
                        when is_binary(Bin) ->
                    Len = byte_size(Bin),
                    {MpHeader, Len} = mp_data_header({Name, Len, ExtraHeaders},
                                                     Boundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + Len + 2,
                    PartBin = << MpHeader/binary, Bin/binary, "\r\n" >>,
                    {AccSize1, << AccBin/binary, PartBin/binary >>};
                ({Name, Bin, Disposition, ExtraHeaders}, {AccSize, AccBin})
                        when is_binary(Bin) ->
                    Len = byte_size(Bin),
                    {MpHeader, Len} = mp_data_header({Name, Len, Disposition,
                                                      ExtraHeaders}, Boundary),
                    AccSize1 = AccSize + byte_size(MpHeader) + Len + 2,
                    PartBin = << MpHeader/binary, Bin/binary, "\r\n" >>,
                    {AccSize1, << AccBin/binary, PartBin/binary >>}
        end, {0, <<>>}, Parts),
    MpEof = mp_eof(Boundary),
    FinalSize = Size + byte_size(MpEof),
    {<< Acc/binary, MpEof/binary >>, FinalSize}.



%% @doc decode a multipart form.
-spec decode_form(binary(), binary()) -> {ok, list()} | {error, term()}.
decode_form(Boundary, Body) ->
    Parser = parser(Boundary),
    decode_form1(Parser(Body), [[]]).

%% @doc Return a multipart parser for the given boundary.
-spec parser(binary()) -> part_parser().
parser(Boundary) when is_binary(Boundary) ->
        fun (Bin) when is_binary(Bin) -> parse(Bin, Boundary) end.

-spec boundary() -> binary().
boundary() ->
    Unique = unique(16),
    <<"---------------------------", Unique/binary>>.

%% @doc create a generic multipart header
mp_header(Headers, Boundary) ->
    BinHeaders = hackney_headers:to_binary(Headers),
    <<"--", Boundary/binary, "\r\n", BinHeaders/binary >>.

%% @doc return the boundary ending a multipart
mp_eof(Boundary) ->
    <<"--",  Boundary/binary, "--\r\n">>.

%% @doc create a part
part(Content, Headers, Boundary) ->
    BinHeaders = hackney_headers:to_binary(Headers),
    <<"--", Boundary/binary, "\r\n", BinHeaders/binary, Content/binary,
      "\r\n" >>.

%% @doc get the size of a mp stream. Useful to calculate the
%% content-length of a full multipart stream and send it as an identity
%% transfer-encoding instead of chunked so any server can handle it.
%%
%% Calculated Parts can be under the form:
%% <ul>
%%  <li>`{file, Path}' : to send a file</li>
%%  <li>`{file, Path, ExtraHeaders}' : to send a file with extra headers</li>
%%  <li>`{file, Path, Name, ExtraHeaders}' : to send a file with DOM element name and extra headers</li>
%%  <li>`{mp_mixed, Name, Boundary}' to send a mixed multipart.
%%  multipart boundary.</li>
%%  <li>`{Name, DataLen}': to send a custom content as a part</li>
%%  <li>`{Name, DataLen, ExtraHeaders}': the same as above but with extra
%%  headers.</li>
%% </ul>
len_mp_stream(Parts, Boundary) ->
    Size = lists:foldl(fun
                ({file, Path}, AccSize) ->
                    {MpHeader, Len} = mp_file_header({file, Path}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({file, Path, ExtraHeaders}, AccSize) ->
                    {MpHeader, Len} = mp_file_header({file, Path,
                                                      ExtraHeaders}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({file, Path, <<Name/binary>>, ExtraHeaders}, AccSize) ->
                    {MpHeader, Len} = mp_file_header({file, Path, Name,
                                                      ExtraHeaders}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({file, Path, {Disposition, Params}, ExtraHeaders}, AccSize) ->
                    {MpHeader, Len} = mp_file_header({file, Path, {Disposition, Params},
                                                      ExtraHeaders}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({mp_mixed, Name, MixedBoundary}, AccSize) ->
                    {MpHeader, _} = mp_mixed_header(Name, MixedBoundary),
                    AccSize + byte_size(MpHeader) + 2 +
                    byte_size(mp_eof(MixedBoundary));
                ({Name, Bin}, AccSize) when is_binary(Bin) ->
                    Len = byte_size(Bin),
                    {MpHeader, Len} = mp_data_header({Name, Len}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({Name, Len}, AccSize) when is_integer(Len) ->
                    {MpHeader, Len} = mp_data_header({Name, Len}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({Name, Bin, ExtraHeaders}, AccSize) when is_binary(Bin) ->
                    Len = byte_size(Bin),
                    {MpHeader, Len} = mp_data_header({Name, Len, ExtraHeaders},
                                                     Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({Name, Len, ExtraHeaders}, AccSize) when is_integer(Len) ->
                    {MpHeader, Len} = mp_data_header({Name, Len, ExtraHeaders},
                                                     Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({Name, Bin, Disposition, ExtraHeaders}, AccSize)
                        when is_binary(Bin) ->
                    Len = byte_size(Bin),
                    {MpHeader, Len} = mp_data_header({Name, Len, Disposition,
                                                      ExtraHeaders}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2;
                ({Name, Len, Disposition, ExtraHeaders}, AccSize) ->
                    {MpHeader, Len} = mp_data_header({Name, Len, Disposition,
                                                      ExtraHeaders}, Boundary),
                    AccSize + byte_size(MpHeader) + Len + 2
            end, 0, Parts),
    Size + byte_size(mp_eof(Boundary)).

%% @doc return the mixed multipart header
-spec mp_mixed_header({Name :: binary(), MixedBoundary :: binary()}, Boundary :: binary())  ->
    {binary(), 0}.
mp_mixed_header({Name, MixedBoundary}, Boundary) ->
    Headers = [{<<"Content-Disposition">>, <<"form-data">>,
                [{<<"name">>, <<"\"", Name/binary, "\"">>}]},
               {<<"Content-Type">>, <<"multipart/mixed">>,
                [{<<"boundary">>, MixedBoundary}]}],
    {mp_header(Headers, Boundary), 0}.


%% @doc return the multipart header for a file that will be sent later
-spec mp_file_header({file, Path :: binary()} |
                     {file, Path :: binary(),
                            ExtraHeaders :: [{binary(), binary()}]} |
                     {file, Path :: binary(),
                            Name :: binary(),
                            ExtraHeaders :: [{binary(), binary()}]} |
                     {file, Path :: binary(),
                            {Disposition :: binary(), Params :: [{binary(), binary()}]},
                            ExtraHeaders :: [{binary(), binary()}]},
                     Boundary :: binary()) ->
    {binary(), FileSize :: integer()}.
mp_file_header({file, Path}, Boundary) ->
    mp_file_header({file, Path, []}, Boundary);
mp_file_header({file, Path, ExtraHeaders}, Boundary) ->
    mp_file_header({file, Path, <<"file">>, ExtraHeaders}, Boundary);
mp_file_header({file, Path, Name, ExtraHeaders}, Boundary) when is_binary(Name) ->
    FName = hackney_bstr:to_binary(filename:basename(Path)),
    Disposition = <<"form-data">>,
    Params = [
        {<<"name">>,     <<"\"", Name/binary,  "\"">>},
        {<<"filename">>, <<"\"", FName/binary, "\"">>}
    ],
    mp_file_header({file, Path, {Disposition, Params}, ExtraHeaders}, Boundary);
mp_file_header({file, Path, {Disposition, Params}, ExtraHeaders}, Boundary) ->
    CType = mimerl:filename(Path),
    Len = filelib:file_size(Path),
    ExtraHeaders0 = lists:map(fun ({K, V}) -> {hackney_bstr:to_lower(K), V} end, ExtraHeaders),
    Headers = mp_filter_header([{<<"content-type">>, CType},
                                {<<"content-length">>, Len}],
                               [{<<"content-disposition">>, Disposition, Params} | ExtraHeaders0]),
    BinHeader = mp_header(Headers, Boundary),
    {BinHeader, Len}.

%% @doc return the multipart header for a data
-spec mp_data_header({Name:: binary(), DataLen :: integer()} |
                     {Name:: binary(), DataLen :: integer(),
                      ExtraHeaders ::[{binary(), binary()}]} |
                     {Name:: binary(), DataLen :: integer(),
                            {Disposition :: binary(), Params :: [{binary(), binary()}]},
                            ExtraHeaders :: [{binary(), binary()}]},
                     Boundary :: binary()) ->
    {binary(), DataLen :: integer()}.
mp_data_header({Name, Len}, Boundary) ->
    mp_data_header({Name, Len, []}, Boundary);
mp_data_header({Name, Len, ExtraHeaders}, Boundary) ->
    Disposition = {<<"form-data">>, [{<<"name">>,
                                      <<"\"", Name/binary, "\"">>}]},
    mp_data_header({Name, Len, Disposition, ExtraHeaders}, Boundary);
mp_data_header({Name, Len, {Disposition, Params}, ExtraHeaders}, Boundary) ->
    CType = mimerl:filename(Name),
    ExtraHeaders0 = lists:map(fun ({K, V}) -> {hackney_bstr:to_lower(K), V} end, ExtraHeaders),
    Headers = mp_filter_header([{<<"content-type">>, CType},
                                {<<"content-length">>, Len}],
                               [{<<"content-disposition">>, Disposition, Params} | ExtraHeaders0]),
    BinHeader = mp_header(Headers, Boundary),
    {BinHeader, Len}.

%% internal functions
%%
unique(Size) -> unique(Size, <<>>).
unique(0, Acc) -> Acc;
unique(Size, Acc) ->
  Random = $a + rand:uniform($z - $a),
  unique(Size - 1, <<Acc/binary, Random>>).

decode_form1(eof, [[]|Acc]) ->
    {ok, lists:reverse(Acc)};
decode_form1(eof, Acc) ->
    {ok, lists:reverse(Acc)};
decode_form1({headers, Headers, Fun}, [Last | Rest]) ->
    Last1 = [{headers, Headers} | Last],
    decode_form1(Fun(), [Last1| Rest]);
decode_form1({body, Bin, Fun}, [Last | Rest]) ->
    Last1 = case proplists:get_value(body, Last) of
        undefined ->
            [{body, Bin} | Last];
        Body ->
            lists:keyreplace(body, 1, Last,
                             {body, << Body/binary, Bin/binary >>})
    end,
    decode_form1(Fun(), [Last1| Rest]);
decode_form1({end_of_part, Fun}, [Last | Rest]) ->
    Headers = proplists:get_value(headers, Last, []),
    Body = proplists:get_value(body, Last, []),
    decode_form1(Fun(), [[], {Headers, Body} | Rest]);
decode_form1({more, Fun}, Acc) ->
    {error, {more, Fun, Acc}}.

%% @doc Entry point of the multipart parser, skips over the preamble if any.
-spec parse(binary(), binary()) -> more(part_result()).
parse(Bin, Boundary) when byte_size(Bin) >= byte_size(Boundary) + 2 ->
    BoundarySize = byte_size(Boundary),
    Pattern = pattern(Boundary),
    case Bin of
        <<"--", Boundary:BoundarySize/binary, Rest/binary>> ->
            % Data starts with initial boundary, skip preamble parsing.
            parse_boundary_tail(Rest, Pattern);
        _ ->
            % Parse preamble.
            skip(Bin, Pattern)
    end;
parse(Bin, Boundary) ->
    % Not enough data to know if the data begins with a boundary.
    more(Bin, fun (NewBin) -> parse(NewBin, Boundary) end).

-type pattern() :: {binary:cp(), non_neg_integer()}.
-type patterns() :: {pattern(), pattern()}.

%% @doc Return two compiled binary patterns with their sizes in bytes.
%% The boundary pattern is the boundary prepended with "\r\n--".
%% The boundary suffix pattern matches all prefixes of the boundary.
-spec pattern(binary()) -> patterns().
pattern(Boundary) ->
    MatchPattern = <<"\r\n--", Boundary/binary>>,
    MatchPrefixes = prefixes(MatchPattern),
    {{binary:compile_pattern(MatchPattern), byte_size(MatchPattern)},
     {binary:compile_pattern(MatchPrefixes), byte_size(MatchPattern)}}.

%% @doc Return all prefixes of a binary string.
%% The list of prefixes includes the full string.
-spec prefixes(binary()) -> [binary()].
prefixes(<<C, Rest/binary>>) ->
    prefixes(Rest, <<C>>).

-spec prefixes(binary(), binary()) -> [binary()].
prefixes(<<C, Rest/binary>>, Acc) ->
    [Acc|prefixes(Rest, <<Acc/binary, C>>)];
prefixes(<<>>, Acc) ->
    [Acc].

%% @doc Test if a boundary is a possible suffix.
%% The patterns are expected to have been returned from `pattern/1'.
-spec suffix_match(binary(), patterns()) -> nomatch | {integer(), integer()}.
suffix_match(Bin, {_Boundary, {Pat, Len}}) ->
    Size = byte_size(Bin),
    suffix_match(Bin, Pat, Size, max(-Size, -Len)).

-spec suffix_match(binary(), binary:cp(), non_neg_integer(), 0|neg_integer()) ->
    nomatch | {integer(), integer()}.
suffix_match(_Bin, _Pat, _Size, _Match=0) ->
    nomatch;
suffix_match(Bin, Pat, Size, Match) when Match < 0 ->
    case binary:match(Bin, Pat, [{scope, {Size, Match}}]) of
        {Pos, Len}=Part when Pos + Len =:= Size -> Part;
        {_, Len} -> suffix_match(Bin, Pat, Size, Match + Len);
        nomatch -> nomatch
    end.

%% @doc Parse remaining characters of a line beginning with the boundary.
%% If followed by "--", <em>eof</em> is returned and parsing is finished.
-spec parse_boundary_tail(binary(), patterns()) -> more(part_result()).
parse_boundary_tail(Bin, Pattern) when byte_size(Bin) >= 2 ->
    case Bin of
        <<"--\r\n">> ->
            % Boundary is followed by "--", end parsing.
            eof;
        <<"--">> ->
            eof;
        <<"--", Rest/binary>> ->
            % Boundary is followed by "--", end parsing.
            {eof, Rest};
        _ ->
            % No dash after boundary, proceed with unknown chars and lwsp
            % removal.
            parse_boundary_eol(Bin, Pattern)
    end;
parse_boundary_tail(Bin, Pattern) ->
    % Boundary may be followed by "--", need more data.
    more(Bin, fun (NewBin) -> parse_boundary_tail(NewBin, Pattern) end).

%% @doc Skip whitespace and unknown chars until CRLF.
-spec parse_boundary_eol(binary(), patterns()) -> more(part_result()).
parse_boundary_eol(Bin, Pattern) ->
    case binary:match(Bin, <<"\r\n">>) of
        {CrlfStart, _Length} ->
            % End of line found, remove optional whitespace.
            <<_:CrlfStart/binary, Rest/binary>> = Bin,
            Fun = fun (Rest2) -> parse_boundary_crlf(Rest2, Pattern) end,
            hackney_bstr:whitespace(Rest, Fun);
        nomatch ->
            % CRLF not found in the given binary.
            RestStart = max(byte_size(Bin) - 1, 0),
            <<_:RestStart/binary, Rest/binary>> = Bin,
            more(Rest, fun (NewBin) -> parse_boundary_eol(NewBin, Pattern) end)
    end.

-spec parse_boundary_crlf(binary(), patterns()) -> more(part_result()).
parse_boundary_crlf(<<"\r\n", Rest/binary>>, Pattern) ->
    % The binary is at least 2 bytes long as this function is only called by
    % parse_boundary_eol/3 when CRLF has been found so a more tuple will never
    % be returned from here.
    parse_headers(Rest, Pattern);
parse_boundary_crlf(Bin, Pattern) ->
    % Unspecified behaviour here: RFC 2046 doesn't say what to do when LWSP is
    % not followed directly by a new line. In this implementation it is
    % considered part of the boundary so EOL needs to be searched again.
    parse_boundary_eol(Bin, Pattern).

-spec parse_headers(binary(), patterns()) -> more(part_result()).
parse_headers(Bin, Pattern) ->
    parse_headers(Bin, Pattern, []).

-spec parse_headers(binary(), patterns(), http_headers()) -> more(part_result()).
parse_headers(Bin, Pattern, Acc) ->
    case erlang:decode_packet(httph_bin, Bin, []) of
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            Name2 = case is_atom(Name) of
                true -> atom_to_binary(Name, latin1);
                false -> Name
            end,
            parse_headers(Rest, Pattern, [{Name2, Value} | Acc]);
        {ok, http_eoh, Rest} ->
            Headers = lists:reverse(Acc),
            case hackney_headers:parse(<<"content-type">>, Headers) of
                {<<"multipart">>, _, Params} ->
                    {_, Boundary} = lists:keyfind(<<"boundary">>, 1, Params),
                    Parser = hackney_multipart:parser(Boundary),
                    Wrapper = fun() -> Parser(Rest) end,
                    {mp_mixed, fun() -> mp_parse_mixed(Pattern, Wrapper) end};
                _ ->
                    Fun =  fun () -> parse_body(Rest, Pattern) end,
                    {headers, Headers, Fun}
            end;
        {ok, {http_error, _}, _} ->
            % Skip malformed parts.
            skip(Bin, Pattern);
        {more, _} ->
            more(Bin, fun (NewBin) -> parse_headers(NewBin, Pattern, Acc) end)
    end.

-spec parse_body(binary(), patterns()) -> more(body_result()).
parse_body(Bin, Pattern = {{P, PSize}, _}) when byte_size(Bin) >= PSize ->
    case binary:match(Bin, P) of
        {0, _Length} ->
            <<_:PSize/binary, Rest/binary>> = Bin,
            end_of_part(Rest, Pattern);
        {BoundaryStart, _Length} ->
            % Boundary found, this is the latest partial body that will be
            % returned for this part.
            <<PBody:BoundaryStart/binary, _:PSize/binary, Rest/binary>> = Bin,
            FResult = end_of_part(Rest, Pattern),
            {body, PBody, fun () -> FResult end};
        nomatch ->
            case suffix_match(Bin, Pattern) of
                nomatch ->
                    %% Prefix of boundary not found at end of input. it's
                    %% safe to return the whole binary. Saves copying of
                    %% next input onto tail of current input binary.
                    {body, Bin, fun () -> parse_body(<<>>, Pattern) end};
                {BoundaryStart, Len} ->
                    PBody = binary:part(Bin, 0, BoundaryStart),
                    Rest = binary:part(Bin, BoundaryStart, Len),
                    {body, PBody, fun () -> parse_body(Rest, Pattern) end}
            end
    end;
parse_body(Bin, Pattern) ->
    more(Bin, fun (NewBin) -> parse_body(NewBin, Pattern) end).

-spec end_of_part(binary(), patterns()) -> end_of_part().
end_of_part(Bin, Pattern) ->
    {end_of_part, fun () -> parse_boundary_tail(Bin, Pattern) end}.

-spec skip(binary(), patterns()) -> more(part_result()).
skip(Bin, Pattern = {{P, PSize}, _}) ->
    case binary:match(Bin, P) of
        {BoundaryStart, _Length} ->
            % Boundary found, proceed with parsing of the next part.
            RestStart = BoundaryStart + PSize,
            <<_:RestStart/binary, Rest/binary>> = Bin,
            parse_boundary_tail(Rest, Pattern);
        nomatch ->
            % Boundary not found, need more data.
            RestStart = max(byte_size(Bin) - PSize + 1, 0),
            <<_:RestStart/binary, Rest/binary>> = Bin,
            more(Rest, fun (NewBin) -> skip(NewBin, Pattern) end)
    end.

-spec more(binary(), parser(T)) -> {more, parser(T)}.
more(<<>>, F) ->
    {more, F};
more(Bin, InnerF) ->
    F = fun (NewData) when is_binary(NewData) ->
            InnerF(<<Bin/binary, NewData/binary>>)
    end,
    {more, F}.

mp_parse_mixed(Pattern, {Fun, Body}) ->
    mp_parse_mixed1(Fun(Body), Pattern);
mp_parse_mixed(Pattern, Fun) ->
    mp_parse_mixed1(Fun(), Pattern).

mp_parse_mixed1({headers, Headers, F}, Pattern) ->
    {headers, Headers, fun() -> mp_parse_mixed(Pattern, F) end};
mp_parse_mixed1({body, Data, F}, Pattern) ->
    {body, Data, fun() -> mp_parse_mixed(Pattern, F) end};
mp_parse_mixed1({end_of_part, F}, Pattern) ->
    {end_of_part, fun() -> mp_parse_mixed(Pattern, F) end};
mp_parse_mixed1({more, F}, Pattern) ->
    {more, fun(Body) -> mp_parse_mixed(Pattern, {F, Body}) end};
mp_parse_mixed1({eof, Rest}, Pattern) ->
    {mp_mixed_eof, fun () -> parse_body(Rest, Pattern) end};
mp_parse_mixed1(eof, Pattern) ->
    {mp_mixed_eof, fun () -> parse_body(<<>>, Pattern) end};
mp_parse_mixed1(Error, _Pattern) ->
    Error.

mp_filter_header([], Acc) -> Acc;
mp_filter_header([{Key, Value} | Headers], Acc) ->
    case proplists:get_value(Key, Acc) of
        undefined ->
            mp_filter_header(Headers, [{Key, Value} | Acc]);
        _Else ->
            mp_filter_header(Headers, Acc)
    end.

