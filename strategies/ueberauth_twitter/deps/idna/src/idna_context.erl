%% -*- coding: utf-8 -*-
%%%
%%% This file is part of erlang-idna released under the MIT license.
%%% See the LICENSE for more information.
%%%
-module(idna_context).
-author("benoitc").

%% API
-export([
  valid_contextj/2, valid_contextj/3,
  valid_contexto/2, valid_contexto/3,
  contexto_with_rule/1
]).

-define(virama_combining_class, 9).


valid_contextj([], _Pos)  -> true;

valid_contextj(Label, Pos) ->
  CP = lists:nth(Pos + 1, Label),
  valid_contextj(CP, Label, Pos).

valid_contextj(16#200c, Label, Pos) ->
  if
     Pos > 0 ->
       case unicode_util_compat:lookup(lists:nth(Pos, Label)) of
         #{ ccc := ?virama_combining_class } -> true;
         _ ->
           valid_contextj_1(Label, Pos)
       end;
    true ->
      valid_contextj_1(Label, Pos)
  end;

valid_contextj(16#200d, Label, Pos) when Pos > 0 ->
  case unicode_util_compat:lookup(lists:nth(Pos, Label)) of
    #{ ccc := ?virama_combining_class } -> true;
    _ -> false
  end;
valid_contextj(_, _, _) ->
  false.

valid_contextj_1(Label, Pos) ->
  case range(lists:reverse(lists:nthtail(Pos, Label))) of
    true ->
      range(lists:nthtail(Pos+2, Label));
    false ->
      false
  end.

range([CP|Rest]) ->
  case idna_data:joining_types(CP) of
    "T" -> range(Rest);
    "L" -> true;
    "D" -> true;
    _ ->
      range(Rest)
  end;
range([]) ->
  false.

valid_contexto([], _Pos) ->
  io:format("ici", []),
  true;
valid_contexto(Label, Pos) ->
  CP = lists:nth(Pos + 1, Label),
  valid_contexto(CP, Label, Pos).

valid_contexto(CP, Label, Pos) ->
  Len = length(Label),
  case CP of
    16#00B7 ->

      % MIDDLE DOT
      if
        (Pos > 0) andalso (Pos < (Len -1)) ->
          case lists:sublist(Label, Pos, 3) of
            [16#006C, _, 16#006C] -> true;
            _ -> false
          end;
        true ->
          false
      end;
    16#0375 ->
      % GREEK LOWER NUMERAL SIGN (KERAIA)
      if
        (Pos < (Len -1)) andalso (Len > 1) ->
          case idna_data:scripts(lists:nth(Pos + 2, Label)) of
            "greek" -> true;
            _Else -> false
          end;
        true ->
          false
      end;
    16#30FB ->
      % KATAKANA MIDDLE DOT
      script_ok(Label);
    CP when CP == 16#05F3; CP == 16#05F4 ->
      % HEBREW PUNCTUATION GERESH or HEBREW PUNCTUATION GERSHAYIM
      if
        Pos > 0 ->
          case idna_data:scripts(lists:nth(Pos, Label)) of
            "hebrew" -> true;
            _ -> false
          end;
        true ->
          false
      end;
    CP when CP >= 16#660, CP =< 16#669 ->
      % ARABIC-INDIC DIGITS
      contexto_in_range(Label, 16#6F0, 16#6F9);
    CP when 16#6F0 =< CP, CP =< 16#6F9 ->
      % EXTENDED ARABIC-INDIC DIGIT
      contexto_in_range(Label, 16#660, 16#669);
    _ ->

      false
  end.


contexto_in_range([CP | _], Start, End) when CP >= Start, CP =< End -> false;
contexto_in_range([_CP|Rest], Start, End) -> contexto_in_range(Rest, Start, End);
contexto_in_range([], _, _) -> true.

script_ok([16#30fb| Rest]) ->
  script_ok(Rest);
script_ok([C | Rest]) ->
  case idna_data:scripts(C) of
    "hiragana" -> true;
    "katakana" -> true;
    "han" -> true;
    _ ->
      script_ok(Rest)
  end;
script_ok([]) ->
  false.

contexto_with_rule(16#00B7) -> true;
% MIDDLE DOT
contexto_with_rule(16#0375) -> true;
% GREEK LOWER NUMERAL SIGN (KERAIA)
contexto_with_rule(16#05F3) -> true;
% HEBREW PUNCTUATION GERESH
contexto_with_rule(16#05F4) -> true;
% HEBREW PUNCTUATION GERSHAYIM
contexto_with_rule(16#30FB) -> true;
% KATAKANA MIDDLE DOT
contexto_with_rule(CP) when 16#0660 =< CP, CP =< 16#0669 -> true;
% ARABIC-INDIC DIGITS
contexto_with_rule(CP) when 16#06F0 =< CP, CP =< 16#06F9 -> true;
% KATAKANA MIDDLE DOT
contexto_with_rule(_) -> false.
