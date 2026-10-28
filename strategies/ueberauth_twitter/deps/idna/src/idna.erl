%% -*- coding: utf-8 -*-
%%%
%%% This file is part of erlang-idna released under the MIT license.
%%% See the LICENSE for more information.
%%%
-module(idna).

%% API
-export([encode/1, encode/2,
         decode/1, decode/2]).

%% compatibility API
-export([to_ascii/1,
         to_unicode/1,
         utf8_to_ascii/1,
         from_ascii/1]).


-export([alabel/1, ulabel/1]).

-export([check_hyphen/1,
         check_nfc/1,
         check_context/1,
         check_initial_combiner/1,
         check_label_length/1]).

-export([check_label/1, check_label/4]).

-define(ACE_PREFIX, "xn--").

-ifdef('OTP_RELEASE').
-define(lower(C), string:lowercase(C)).
-else.
-define(lower(C), string:to_lower(C)).
-endif.

-include("idna_logger.hrl").


-type idna_flags() :: [{uts46, boolean()} |
                       {std3_rules, boolean()} |
                       {transitional, boolean()}].



%% @doc encode Internationalized Domain Names using IDNA protocol
-spec encode(string()) -> string().
encode(Domain) ->
  encode(Domain, []).


%% @doc encode Internationalized Domain Names using IDNA protocol.
%% Input can be mapped to unicode using [uts46](https://unicode.org/reports/tr46/#Introduction)
%% by setting  the `uts46' flag to `true' (default is `false'). If transition from IDNA 2003 to
%% IDNA 2008 is needed, the flag `transitional' can be set to `true', (default is `false'). If
%% conformance to STD3 is needed, the flag `std3_rules' can be set to `true'. (default is `false').
-spec encode(string(), idna_flags()) -> string().
encode(Domain0, Options) ->
  ok = validate_options(Options),
  Domain = case proplists:get_value(uts46, Options, false) of
             true ->
               STD3Rules = proplists:get_value(std3_rules, Options, false),
               Transitional = proplists:get_value(transitional, Options, false),
               uts46_remap(Domain0, STD3Rules, Transitional);
             false ->
               Domain0
           end,
  Labels = case proplists:get_value(strict, Options, false) of
             false ->
               re:split(Domain, "[.。．｡]", [{return, list}, unicode]);
             true ->
               string:tokens(Domain, ".")
           end,
  case Labels of
    [] -> exit(empty_domain);
    _ ->
      encode_1(Labels, [])
  end.

%% @doc decode an International Domain Name encoded with the IDNA protocol
-spec decode(string()) -> string().
decode(Domain) ->
  decode(Domain, []).

%% @doc decode an International Domain Name encoded with the IDNA protocol
-spec decode(string(), idna_flags()) -> string().
decode(Domain0, Options) ->
  ok = validate_options(Options),
  Domain = case proplists:get_value(uts46, Options, false) of
             true ->
               STD3Rules = proplists:get_value(std3_rules, Options, false),
               Transitional = proplists:get_value(transitional, Options, false),
               uts46_remap(Domain0, STD3Rules, Transitional);
             false ->
               Domain0
           end,

  Labels = case proplists:get_value(strict, Options, false) of
             false ->
               re:split(lowercase(Domain), "[.。．｡]", [{return, list}, unicode]);
             true ->
               string:tokens(lowercase(Domain), ".")
           end,
  case Labels of
    [] -> exit(empty_domain);
    _ ->
      decode_1(Labels, [])
  end.


%% Compatibility API
%%

%% @doc encode an International Domain Name to IDNA protocol (compatibility API)
-spec to_ascii(string()) -> string().
to_ascii(Domain) -> encode(Domain).

%% @doc decode an an encoded International Domain Name using the IDNA protocol (compatibility API)
-spec to_unicode(string()) -> string().
to_unicode(Domain) -> decode(Domain).


utf8_to_ascii(Domain) ->
  to_ascii(idna_ucs:from_utf8(Domain)).

%% @doc like `to_ascii/1'
-spec from_ascii(nonempty_string()) -> nonempty_string().
from_ascii(Domain) ->
  decode(Domain).


%% Helper functions
%%

validate_options([]) -> ok;
validate_options([uts46|Rs]) -> validate_options(Rs);
validate_options([{uts46, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([strict|Rs]) -> validate_options(Rs);
validate_options([{strict, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([std3_rules|Rs]) -> validate_options(Rs);
validate_options([{std3_rules, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([transitional|Rs]) -> validate_options(Rs);
validate_options([{transitional, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([_]) -> erlang:error(badarg).

encode_1([], Acc) ->
  lists:reverse(Acc);
encode_1([Label|Labels], []) ->
  encode_1(Labels, lists:reverse(alabel(Label)));
encode_1([Label|Labels], Acc) ->
  encode_1(Labels, lists:reverse(alabel(Label), [$.|Acc])).

check_nfc(Label) ->
  case characters_to_nfc_list(Label) of
    Label -> ok;
    _ ->
      erlang:exit({bad_label, {nfc, "Label must be in Normalization Form C"}})
  end.

check_hyphen(Label) -> check_hyphen(Label, true).

check_hyphen(Label, true) when length(Label) >= 3 ->
  case lists:nthtail(2, Label) of
    [$-, $-|_] ->
      ErrorMsg = error_msg("Label ~p has disallowed hyphens in 3rd and 4th position", [Label]),
      erlang:exit({bad_label, {hyphen, ErrorMsg}});
    _ ->
      case (lists:nth(1, Label) == $-) orelse (lists:last(Label) == $-) of
        true ->
          ErrorMsg = error_msg("Label ~p must not start or end with a hyphen", [Label]),
          erlang:exit({bad_label, {hyphen, ErrorMsg}});
        false ->
          ok
      end
  end;
check_hyphen(Label, true) ->
  case (lists:nth(1, Label) == $-) orelse (lists:last(Label) == $-) of
    true ->
      ErrorMsg = error_msg("Label ~p must not start or end with a hyphen", [Label]),
      erlang:exit({bad_label, {hyphen, ErrorMsg}});
    false ->
      ok
  end;
check_hyphen(_Label, false) ->
  ok.

check_initial_combiner([CP|_]) ->
  case idna_data:lookup(CP) of
    {[$M|_], _} ->
      erlang:exit({bad_label, {initial_combiner, "Label begins with an illegal combining character"}});
    _ ->
      ok
  end.

check_context(Label) ->
  check_context(Label, Label, true, 0).

check_context(Label, CheckJoiners) ->
  check_context(Label, Label, CheckJoiners, 0).

check_context([CP | Rest], Label, CheckJoiners, Pos) ->
  case idna_table:lookup(CP) of
    'PVALID' ->
      check_context(Rest, Label, CheckJoiners, Pos + 1);
    'CONTEXTJ' ->
        ok =  valid_contextj(CP, Label, Pos, CheckJoiners),
        check_context(Rest, Label, CheckJoiners, Pos + 1);
    'CONTEXTO' ->
      ok =  valid_contexto(CP, Label, Pos, CheckJoiners),
      check_context(Rest, Label, CheckJoiners, Pos + 1);
    _Status ->
      ErrorMsg = error_msg("Codepoint ~p not allowed (~p) at position ~p in ~p", [CP, _Status, Pos, Label]),
      erlang:exit({bad_label, {context, ErrorMsg}})
  end;
check_context([], _, _, _) ->
  ok.


valid_contextj(CP, Label, Pos, true) ->
  case idna_context:valid_contextj(CP, Label, Pos) of
    true ->
      ok;
    false ->
      ErrorMsg = error_msg("Joiner ~p not allowed at position ~p in ~p", [CP, Pos, Label]),
      erlang:exit({bad_label, {contextj, ErrorMsg}})
  end;
valid_contextj(_CP, _Label, _Pos, false) ->
  ok.

valid_contexto(CP, Label, Pos, true) ->
  case idna_context:valid_contexto(CP, Label, Pos) of
    true ->
      ok;
    false ->
      ErrorMsg = error_msg("Joiner ~p not allowed at position ~p in ~p", [CP, Pos, Label]),
      erlang:exit({bad_label, {contexto, ErrorMsg}})
  end;
valid_contexto(_CP, _Label, _Pos, false) ->
  ok.



-spec check_label(string()) -> ok.
check_label(Label) ->
  check_label(Label, true, true, true).

%% @doc validate a label of  a domain
-spec check_label(Label, CheckHyphens, CheckJoiners, CheckBidi) -> Result when
    Label :: string(),
    CheckHyphens :: boolean(),
    CheckJoiners :: boolean(),
    CheckBidi :: boolean(),
    Result :: ok.
check_label(Label, CheckHyphens, CheckJoiners, CheckBidi) ->
  ok = check_nfc(Label),
  ok = check_hyphen(Label, CheckHyphens),
  ok = check_initial_combiner(Label),
  ok = check_context(Label, CheckJoiners),
  ok = check_bidi(Label, CheckBidi),
  ok.


check_bidi(Label, true) ->
  idna_bidi:check_bidi(Label);
check_bidi(_, false) ->
  ok.

check_label_length(Label) when length(Label) > 63 ->
  ErrorMsg = error_msg("The label ~p  is too long", [Label]),
  erlang:exit({bad_label, {too_long, ErrorMsg}});
check_label_length(_) ->
  ok.

alabel(Label0) ->
  Label = case lists:all(fun(C) -> idna_ucs:is_ascii(C) end, Label0) of
            true ->
              _ = try ulabel(Label0)
                  catch
                    _:Error ->
                      ErrorMsg = error_msg("The label ~p  is not a valid A-label: ulabel error=~p", [Label0, Error]),
                      erlang:exit({bad_label, {alabel, ErrorMsg}})
                  end,
              ok = check_label_length(Label0),

              Label0;
            false ->
              ok = check_label(Label0),
              ?ACE_PREFIX ++ punycode:encode(Label0)
          end,
  ok = check_label_length(Label),
  Label.

decode_1([], Acc) ->
  lists:reverse(Acc);
decode_1([Label|Labels], []) ->
  decode_1(Labels, lists:reverse(ulabel(Label)));
decode_1([Label|Labels], Acc) ->
  decode_1(Labels, lists:reverse(ulabel(Label), [$.|Acc])).

ulabel([]) -> [];
ulabel(Label0) ->
  Label = case lists:all(fun(C) -> idna_ucs:is_ascii(C) end, Label0) of
            true ->
              case Label0 of
                [$x,$n,$-,$-|Label1] ->
                  punycode:decode(lowercase(Label1));
                _ ->
                  lowercase(Label0)
              end;
            false ->
              lowercase(Label0)
          end,
  ok = check_label(Label),
  Label.

%% Lowercase all chars in Str
-spec lowercase(String::unicode:chardata()) -> unicode:chardata().
lowercase(CD) when is_list(CD) ->
  try lowercase_list(CD, false)
  catch unchanged -> CD
  end;
lowercase(<<CP1/utf8, Rest/binary>>=Orig) ->
  try lowercase_bin(CP1, Rest, false) of
    List -> unicode:characters_to_binary(List)
  catch unchanged -> Orig
  end;
lowercase(<<>>) ->
  <<>>.


lowercase_list([CP1|[CP2|_]=Cont], _Changed) when $A =< CP1, CP1 =< $Z, CP2 < 256 ->
  [CP1+32|lowercase_list(Cont, true)];
lowercase_list([CP1|[CP2|_]=Cont], Changed) when CP1 < 128, CP2 < 256 ->
  [CP1|lowercase_list(Cont, Changed)];
lowercase_list([], true) ->
  [];
lowercase_list([], false) ->
  throw(unchanged);
lowercase_list(CPs0, Changed) ->
  case unicode_util_compat:lowercase(CPs0) of
    [Char|CPs] when Char =:= hd(CPs0) -> [Char|lowercase_list(CPs, Changed)];
    [Char|CPs] -> append(Char,lowercase_list(CPs, true));
    [] -> lowercase_list([], Changed)
  end.

lowercase_bin(CP1, <<CP2/utf8, Bin/binary>>, _Changed)
  when $A =< CP1, CP1 =< $Z, CP2 < 256 ->
  [CP1+32|lowercase_bin(CP2, Bin, true)];
lowercase_bin(CP1, <<CP2/utf8, Bin/binary>>, Changed)
  when CP1 < 128, CP2 < 256 ->
  [CP1|lowercase_bin(CP2, Bin, Changed)];
lowercase_bin(CP1, Bin, Changed) ->
  case unicode_util_compat:lowercase([CP1|Bin]) of
    [CP1|CPs] ->
      case unicode_util_compat:cp(CPs) of
        [Next|Rest] ->
          [CP1|lowercase_bin(Next, Rest, Changed)];
        [] when Changed ->
          [CP1];
        [] ->
          throw(unchanged)
      end;
    [Char|CPs] ->
      case unicode_util_compat:cp(CPs) of
        [Next|Rest] ->
          [Char|lowercase_bin(Next, Rest, true)];
        [] ->
          [Char]
      end
  end.


append(Char, <<>>) when is_integer(Char) -> [Char];
append(Char, <<>>) when is_list(Char) -> Char;
append(Char, Bin) when is_binary(Bin) -> [Char,Bin];
append(Char, Str) when is_integer(Char) -> [Char|Str];
append(GC, Str) when is_list(GC) -> GC ++ Str.


characters_to_nfc_list(CD) ->
  case unicode_util_compat:nfc(CD) of
    [CPs|Str] when is_list(CPs) -> CPs ++ characters_to_nfc_list(Str);
    [CP|Str] -> [CP|characters_to_nfc_list(Str)];
    [] -> []
  end.


uts46_remap(Str, Std3Rules, Transitional) ->
  characters_to_nfc_list(uts46_remap_1(Str, Std3Rules, Transitional)).

uts46_remap_1([Cp|Rs], Std3Rules, Transitional) ->
  Row = try idna_mapping:uts46_map(Cp)
        catch
          error:badarg  ->
            ?LOG_ERROR("codepoint ~p not found in mapping list~n", [Cp]),
            erlang:exit({invalid_codepoint, Cp})
        end,
  {Status, Replacement} = case Row of
                            {_, _} -> Row;
                            S -> {S, undefined}
                          end,
  if
    (Status =:= 'V');
    ((Status =:= 'D') andalso (Transitional =:= false));
    ((Status =:= '3') andalso (Std3Rules =:= true) andalso (Replacement =:= undefined)) ->
      [Cp] ++ uts46_remap_1(Rs, Std3Rules, Transitional);
    (Replacement =/= undefined) andalso (
        (Status =:= 'M') orelse
          (Status =:= '3' andalso Std3Rules =:= false) orelse
          (Status =:= 'D' andalso Transitional =:= true)) ->
      Replacement ++ uts46_remap_1(Rs, Std3Rules, Transitional);
    (Status =:= 'I') ->
      uts46_remap_1(Rs, Std3Rules, Transitional);
    true ->
      erlang:exit({invalid_codepoint, Cp})
  end;
uts46_remap_1([], _, _) ->
  [].

error_msg(Msg, Fmt) ->
  lists:flatten(io_lib:format(Msg, Fmt)).
