%% -*- coding: utf-8 -*-
%%%
%%% This file is part of erlang-idna released under the MIT license.
%%% See the LICENSE for more information.
%%%
%% @doc Punycode ([RFC 3492](http://tools.ietf.org/html/rfc3492)) implementation.

-module(punycode).


-export([encode/1,
         decode/1]).

-define(BASE, 36).
-define(TMIN, 1).
-define(TMAX, 26).
-define(SKEW, 38).
-define(DAMP, 700).
-define(INITIAL_BIAS, 72).
-define(INITIAL_N, 128).
-define(DELIMITER, $-).


-define(MAX, 1 bsl 32 - 1).

%% @doc Convert Unicode to Punycode.
%%
%% exit with an overflow error on overflow, which can only happen on inputs
%% that would take more than 63 encoded bytes, the DNS limit on domain name labels.
-spec encode(string()) -> string().
encode(Input) ->
  Output0 = lists:filtermap(fun
                             (C) when C < 16#80 -> {true, C};
                             (_) -> false
                           end, Input),
  B = length(Output0),
  Output = case B > 0 of
             true -> Output0 ++ [?DELIMITER];
             false -> Output0
           end,
  H = B,
  encode(Input, Output, H, B, ?INITIAL_N, 0, ?INITIAL_BIAS).


encode(Input, Output, H, B, N, Delta, Bias) when H < length(Input) ->
  M = lists:min(lists:filter(fun(C) -> C >= N end, Input)),
  Delta1 = case (M - N) > ((?MAX - Delta) / (H +1)) of
             false -> Delta +  (M - N) * (H + 1);
             true -> exit(oveflow)
           end,
  {Output2, H2, Delta2, N2, Bias2} = encode1(Input, Output, H, B, M, Delta1, Bias),
  encode(Input, Output2, H2, B, N2, Delta2, Bias2);
encode(_, Output, _, _, _, _, _) ->
  Output.

encode1([C|Rest], Output, H, B, N, Delta, Bias) when C < N ->
  Delta2 = Delta + 1,
  case Delta2 of
    0 -> exit(oveflow);
    _ ->
      encode1(Rest, Output, H, B, N, Delta2, Bias)
  end;
encode1([C|Rest], Output, H, B, N, Delta, Bias) when C == N ->
  encode2(Rest, Output, H, B, N, Delta, Bias, Delta, ?BASE);
encode1([_|Rest], Output, H, B, N, Delta, Bias) ->
  encode1(Rest, Output, H, B, N, Delta, Bias);
encode1([], Output, H, _B, N, Delta, Bias) ->
  {Output, H, Delta + 1, N +1, Bias}.

encode2(Rest, Output, H, B, N, Delta, Bias, Q, K) ->
  T = if
        K =< Bias -> ?TMIN;
        K >= (Bias + ?TMAX) -> ?TMAX;
        true -> K - Bias
      end,
  case  Q < T of
    true ->
      CodePoint = to_digit(Q),
      Output2 = Output ++ [CodePoint],
      Bias2 = adapt(Delta, H +1, H == B),
      Delta2 = 0,
      H2 = H + 1,
      encode1(Rest, Output2, H2, B, N, Delta2, Bias2);
    false ->
      CodePoint = to_digit(T + ((Q - T) rem (?BASE - T))),
      Output2 = Output ++ [CodePoint],
      Q2 = (Q - T) div (?BASE - T),
      encode2(Rest, Output2, H, B, N, Delta, Bias, Q2, K + ?BASE)
  end.

to_digit(V) when V >= 0, V =< 25 -> V + $a;
to_digit(V) when V >= 26, V =< 35 -> V - 26 + $0;
to_digit(_) -> exit(badarg).


%% @doc Convert Punycode to Unicode.
%% exit with an overflow or badarg errors if malformed or overflow.
%% Overflow can only happen on inputs that take more than 63 encoded bytes,
%% the DNS limit on domain name labels.
-spec decode(string()) -> string().
decode(Input) ->
  {Output, Input2} = case string:rstr(Input, [?DELIMITER]) of
             0 -> {"", Input};
             Pos ->
               {lists:sublist(Input, Pos - 1), lists:sublist(Input, Pos + 1, length(Input) )}
           end,
  decode(Input2, Output, ?INITIAL_N, ?INITIAL_BIAS, 0).

decode([], Output, _, _, _) -> Output;
decode(Input, Output, N, Bias, I) ->
  decode(Input, Output, N, Bias, I, I, 1, ?BASE).

decode([C|Rest], Output, N, Bias, I0, OldI, Weight, K) ->
  Digit = digit(C),
  I1 = case Digit > ((?MAX - I0 ) div Weight) of
         false -> I0 + (Digit * Weight);
         true -> exit(overflow)
       end,
  T = if
        K =< Bias -> ?TMIN;
        K >= (Bias + ?TMAX) -> ?TMAX;
        true -> K - Bias
      end,
  case Digit < T of
    true ->
      Len = length(Output),
      Bias2 = adapt(I1 - OldI, Len + 1, (OldI =:= 0)),
      {N2, I2}= case (I1 div (Len +1)) > (?MAX - N) of
                  false ->
                    {N + (I1 div (Len + 1)), I1 rem (Len + 1)};
                  true ->
                    exit(overflow)
                end,
      Output2 = insert(Output, N2, [], I2),
      decode(Rest, Output2, N2, Bias2, I2+1);
    false ->
      case Weight > (?MAX  div (?BASE - T)) of
        false ->
          decode(Rest, Output, N, Bias, I1, OldI, Weight * (?BASE - T), K + ?BASE);
        true ->
          exit(overflow)
      end
  end.

insert(Tail, CP, Head, 0) ->
  Head ++ [CP | Tail];
insert([], _CP, _Head, I) when I > 0->
  exit(overflow);
insert([C | Tail], CP, Head, I) ->
  insert(Tail, CP, Head ++ [C], I - 1).


digit(C) when C >= $0, C =< $9 -> C - $0 + 26;
digit(C) when C >= $A, C =< $Z -> C - $A;
digit(C) when C >= $a, C =< $z -> C - $a;
digit(_) -> exit(badarg).

adapt(Delta, NumPoints, FirstTime) ->
  Delta2 = case FirstTime of
             true ->
               Delta div ?DAMP;
             false ->
               Delta div 2
           end,
  adapt(Delta2 + (Delta2 div NumPoints), 0).

adapt(Delta, K) ->
  case Delta > (((?BASE - ?TMIN) * ?TMAX) div 2) of
    true ->
      adapt(Delta div (?BASE - ?TMIN), K + ?BASE);
    false ->
      K + (((?BASE - ?TMIN + 1) * Delta) div (Delta + ?SKEW))
  end.