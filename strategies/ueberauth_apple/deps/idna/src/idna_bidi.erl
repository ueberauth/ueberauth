%% -*- coding: utf-8 -*-
%%%
%%% This file is part of erlang-idna released under the MIT license.
%%% See the LICENSE for more information.
%%%

-module(idna_bidi).
-author("benoitc").

%% API
-export([check_bidi/1, check_bidi/2]).

check_bidi(Label) -> check_bidi(Label, false).

check_bidi(Label, CheckLtr) ->
  %% Bidi rules should only be applied if string contains RTL characters
  case {check_rtl(Label, Label), CheckLtr} of
    {false, false}  -> ok;
    _ ->
      [C | _Rest] = Label,
      % bidi rule 1
      RTL = rtl(C, Label),
      check_bidi1(Label, RTL, false, undefined)
  end.

check_rtl([C | Rest], Label) ->
  case idna_data:bidirectional(C) of
    false ->
      erlang:exit(bidi_error("unknown directionality in label=~p c=~w~n", [Label, C]));
    Dir ->
      case lists:member(Dir, ["R", "AL", "AN"]) of
        true -> true;
        false -> check_rtl(Rest, Label)
      end
  end;
check_rtl([], _Label) ->
  false.

rtl(C, Label) ->
  case idna_data:bidirectional(C) of
    "R" -> true;
    "AL" -> true;
    "L" -> false;
    _ ->
      erlang:exit(bidi_error("first codepoint in label ~p must be directionality L, R or AL ", [Label]))
  end.


check_bidi1([C | Rest], true, ValidEnding, NumberType) ->
  Dir =  idna_data:bidirectional(C),
  %% bidi rule 2
  ValidEnding2 = case lists:member(Dir, ["R", "AL", "AN", "EN", "ES", "CS", "ET", "ON", "BN", "NSM"]) of
                  true ->
                    % bidi rule 3
                    case lists:member(Dir, ["R", "AL", "AN", "EN"]) of
                      true  -> true;
                      false when Dir =/= "NSM" -> false;
                      false -> ValidEnding
                    end;
                  false ->
                    erlang:exit({bad_label, {bidi, "Invalid direction for codepoint  in a right-to-left label"}})
                end,
  % bidi rule 4
  NumberType2 = case lists:member(Dir, ["AN", "EN"]) of
                  true when NumberType =:= undefined ->
                    Dir;
                  true when NumberType /= Dir ->
                    erlang:exit({bad_label, {bidi, "Can not mix numeral types in a right-to-left label"}});
                  _ ->
                    NumberType
                end,
  check_bidi1(Rest, true, ValidEnding2, NumberType2);
check_bidi1([C | Rest], false, ValidEnding, NumberType) ->
  Dir =  idna_data:bidirectional(C),
  % bidi rule 5
  ValidEnding2 = case lists:member(Dir, ["L", "EN", "ES", "CS", "ET", "ON", "BN", "NSM"]) of
                   true ->
                     % bidi rule 6
                     case Dir of
                       "L" -> true;
                       "EN" -> true;
                       _ when Dir /= "NSM" -> false;
                       _ -> ValidEnding
                     end;
                   false ->
                     erlang:exit({bad_label, {bidi, "Invalid direction for codepoint in a left-to-right label"}})
                 end,
  check_bidi1(Rest, false, ValidEnding2, NumberType);
check_bidi1([], _, false, _) ->
  erlang:exit({bad_label, {bidi, "Label ends with illegal codepoint directionality"}});
check_bidi1([], _, true, _) ->
  ok.

bidi_error(Msg, Fmt) ->
  ErrorMsg = lists:flatten(io_lib:format(Msg, Fmt)),
  {bad_label, {bidi, ErrorMsg}}.
