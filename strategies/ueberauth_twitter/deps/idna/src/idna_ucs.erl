%%% -*- erlang -*-
%%
%% Copyright Ericsson AB 2005-2016. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.


-module(idna_ucs).

-compile([verbose,report_warnings,warn_unused_vars]).


%%% Micellaneous predicates
-export([is_iso10646/1, is_unicode/1, is_ascii/1]).

%%% UTF-8 encoding and decoding
-export([to_utf8/1, from_utf8/1]).

%%% Test if Ch is a legitimate ISO-10646 character code
is_iso10646(Ch) when is_integer(Ch), Ch >= 0 ->
  if Ch  < 16#D800 -> true;
    Ch  < 16#E000 -> false;	% Surrogates
    Ch  < 16#FFFE -> true;
    Ch =< 16#FFFF -> false;	% FFFE and FFFF (not characters)
    Ch =< 16#7FFFFFFF -> true;
    true -> false
  end;
is_iso10646(_) -> false.

%%% Test if Ch is a legitimate ISO-10646 character code capable of
%%% being encoded in a UTF-16 string.
is_unicode(Ch) when Ch < 16#110000 -> is_iso10646(Ch);
is_unicode(_) -> false.

%%% Test for legitimate ASCII code
is_ascii(Ch) when is_integer(Ch), Ch >= 0, Ch =< 127 -> true;
is_ascii(_) -> false.


%%% UTF-8 encoding and decoding
to_utf8(List) when is_list(List) -> lists:flatmap(fun to_utf8/1, List);
to_utf8(Ch) -> char_to_utf8(Ch).

from_utf8(Bin) when is_binary(Bin) -> from_utf8(binary_to_list(Bin));
from_utf8(List) ->
  case expand_utf8(List) of
    {Result,0} -> Result;
    {_Res,_NumBadChar} ->
      exit({ucs,{bad_utf8_character_code}})
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% UTF-8 support
%%% Possible errors encoding UTF-8:
%%%	- Non-character values (something other than 0 .. 2^31-1).
%%%	- Surrogate pair code in string.
%%%	- 16#FFFE or 16#FFFF character in string.
%%% Possible errors decoding UTF-8:
%%%	- 10xxxxxx or 1111111x as initial byte.
%%%	- Insufficient number of 10xxxxxx octets following an initial octet of
%%%	multi-octet sequence.
%%% 	- Non-canonical encoding used.
%%%	- Surrogate-pair code encoded as UTF-8.
%%%	- 16#FFFE or 16#FFFF character in string.
char_to_utf8(Ch) when is_integer(Ch), Ch >= 0 ->
  if Ch < 128 ->
    %% 0yyyyyyy
    [Ch];
    Ch < 16#800 ->
      %% 110xxxxy 10yyyyyy
      [16#C0 + (Ch bsr 6),
        128+(Ch band 16#3F)];
    Ch < 16#10000 ->
      %% 1110xxxx 10xyyyyy 10yyyyyy
      if Ch < 16#D800; Ch > 16#DFFF, Ch < 16#FFFE ->
        [16#E0 + (Ch bsr 12),
          128+((Ch bsr 6) band 16#3F),
          128+(Ch band 16#3F)]
      end;
    Ch < 16#200000 ->
      %% 11110xxx 10xxyyyy 10yyyyyy 10yyyyyy
      [16#F0+(Ch bsr 18),
        128+((Ch bsr 12) band 16#3F),
        128+((Ch bsr 6) band 16#3F),
        128+(Ch band 16#3F)];
    Ch < 16#4000000 ->
      %% 111110xx 10xxxyyy 10yyyyyy 10yyyyyy 10yyyyyy
      [16#F8+(Ch bsr 24),
        128+((Ch bsr 18) band 16#3F),
        128+((Ch bsr 12) band 16#3F),
        128+((Ch bsr 6) band 16#3F),
        128+(Ch band 16#3F)];
    Ch < 16#80000000 ->
      %% 1111110x 10xxxxyy 10yyyyyy 10yyyyyy 10yyyyyy 10yyyyyy
      [16#FC+(Ch bsr 30),
        128+((Ch bsr 24) band 16#3F),
        128+((Ch bsr 18) band 16#3F),
        128+((Ch bsr 12) band 16#3F),
        128+((Ch bsr 6) band 16#3F),
        128+(Ch band 16#3F)]
  end.




%% expand_utf8([Byte]) -> {[UnicodeChar],NumberOfBadBytes}
%%  Expand UTF8 byte sequences to ISO 10646/Unicode
%%  charactes. Any illegal bytes are removed and the number of
%%  bad bytes are returned.
%%
%%  Reference:
%%     RFC 3629: "UTF-8, a transformation format of ISO 10646".

expand_utf8(Str) ->
  expand_utf8_1(Str, [], 0).

expand_utf8_1([C|Cs], Acc, Bad) when C < 16#80 ->
  %% Plain Ascii character.
  expand_utf8_1(Cs, [C|Acc], Bad);
expand_utf8_1([C1,C2|Cs], Acc, Bad) when C1 band 16#E0 =:= 16#C0,
  C2 band 16#C0 =:= 16#80 ->
  case ((C1 band 16#1F) bsl 6) bor (C2 band 16#3F) of
    C when 16#80 =< C ->
      expand_utf8_1(Cs, [C|Acc], Bad);
    _ ->
      %% Bad range.
      expand_utf8_1(Cs, Acc, Bad+1)
  end;
expand_utf8_1([C1,C2,C3|Cs], Acc, Bad) when C1 band 16#F0 =:= 16#E0,
  C2 band 16#C0 =:= 16#80,
  C3 band 16#C0 =:= 16#80 ->
  case ((((C1 band 16#0F) bsl 6) bor (C2 band 16#3F)) bsl 6) bor
    (C3 band 16#3F) of
    C when 16#800 =< C ->
      expand_utf8_1(Cs, [C|Acc], Bad);
    _ ->
      %% Bad range.
      expand_utf8_1(Cs, Acc, Bad+1)
  end;
expand_utf8_1([C1,C2,C3,C4|Cs], Acc, Bad) when C1 band 16#F8 =:= 16#F0,
  C2 band 16#C0 =:= 16#80,
  C3 band 16#C0 =:= 16#80,
  C4 band 16#C0 =:= 16#80 ->
  case ((((((C1 band 16#0F) bsl 6) bor (C2 band 16#3F)) bsl 6) bor
    (C3 band 16#3F)) bsl 6) bor (C4 band 16#3F) of
    C when 16#10000 =< C ->
      expand_utf8_1(Cs, [C|Acc], Bad);
    _ ->
      %% Bad range.
      expand_utf8_1(Cs, Acc, Bad+1)
  end;
expand_utf8_1([_|Cs], Acc, Bad) ->
  %% Ignore bad character.
  expand_utf8_1(Cs, Acc, Bad+1);
expand_utf8_1([], Acc, Bad) -> {lists:reverse(Acc),Bad}.
