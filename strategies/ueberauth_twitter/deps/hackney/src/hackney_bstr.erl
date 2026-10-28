%%% -*- erlang -*-
%%%
%%% This file is part of hackney_lib released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
-module(hackney_bstr).

-export([to_binary/1,
  to_lower/1, to_upper/1,
  char_to_lower/1, char_to_upper/1,
  join/2,
  to_hex/1,
  token_ci/2, token/2,
  list/2,
  nonempty_list/2,
  params/2,
  parameterized_tokens/1,
  whitespace/2,
  digits/1, digits/2, digits/3,
  alpha/2,
  word/2,
  trim/1]).

%% BEGIN: Remove when OTP 17 not officially supported
-export([split/3]).

-export_type([cp/0]).

-opaque cp() :: {'am' | 'bm', binary()}.
-type part() :: {Start :: non_neg_integer(), Length :: integer()}.
%% END: Remove when OTP 17 not officially supported

-export([quoted_string/2]).

to_binary(V) when is_list(V) ->
  list_to_binary(V);
to_binary(V) when is_atom(V) ->
  atom_to_binary(V, latin1);
to_binary(V) when is_integer(V) ->
  list_to_binary(integer_to_list(V));
to_binary(V) when is_binary(V) ->
  V.

%% @doc Convert a binary string to lowercase.
-spec to_lower(binary()|atom()|list()) -> binary().
to_lower(L) when is_binary(L) ->
  << << (char_to_lower(C)) >> || << C >> <= L >>;
to_lower(L) ->
  to_lower(to_binary(L)).

-spec to_upper(binary()|atom()|list()) -> binary().
to_upper(U) when is_binary(U)->
  << << (char_to_upper(C)) >> || << C >> <= U >>;
to_upper(L) ->
  to_upper(to_binary(L)).


%% @doc Convert [A-Z] characters to lowercase.
%% @end
%% We gain noticeable speed by matching each value directly.
-spec char_to_lower(char()) -> char().
char_to_lower($A) -> $a;
char_to_lower($B) -> $b;
char_to_lower($C) -> $c;
char_to_lower($D) -> $d;
char_to_lower($E) -> $e;
char_to_lower($F) -> $f;
char_to_lower($G) -> $g;
char_to_lower($H) -> $h;
char_to_lower($I) -> $i;
char_to_lower($J) -> $j;
char_to_lower($K) -> $k;
char_to_lower($L) -> $l;
char_to_lower($M) -> $m;
char_to_lower($N) -> $n;
char_to_lower($O) -> $o;
char_to_lower($P) -> $p;
char_to_lower($Q) -> $q;
char_to_lower($R) -> $r;
char_to_lower($S) -> $s;
char_to_lower($T) -> $t;
char_to_lower($U) -> $u;
char_to_lower($V) -> $v;
char_to_lower($W) -> $w;
char_to_lower($X) -> $x;
char_to_lower($Y) -> $y;
char_to_lower($Z) -> $z;
char_to_lower(Ch) -> Ch.

%% @doc Convert [a-z] characters to uppercase.
-spec char_to_upper(char()) -> char().
char_to_upper($a) -> $A;
char_to_upper($b) -> $B;
char_to_upper($c) -> $C;
char_to_upper($d) -> $D;
char_to_upper($e) -> $E;
char_to_upper($f) -> $F;
char_to_upper($g) -> $G;
char_to_upper($h) -> $H;
char_to_upper($i) -> $I;
char_to_upper($j) -> $J;
char_to_upper($k) -> $K;
char_to_upper($l) -> $L;
char_to_upper($m) -> $M;
char_to_upper($n) -> $N;
char_to_upper($o) -> $O;
char_to_upper($p) -> $P;
char_to_upper($q) -> $Q;
char_to_upper($r) -> $R;
char_to_upper($s) -> $S;
char_to_upper($t) -> $T;
char_to_upper($u) -> $U;
char_to_upper($v) -> $V;
char_to_upper($w) -> $W;
char_to_upper($x) -> $X;
char_to_upper($y) -> $Y;
char_to_upper($z) -> $Z;
char_to_upper(Ch) -> Ch.

join([], _Separator) ->
  <<>>;
join([S], _separator) ->
  S;
join(L, Separator) ->
  iolist_to_binary(join(lists:reverse(L), Separator, [])).

join([], _Separator, Acc) ->
  Acc;
join([S | Rest], Separator, []) ->
  join(Rest, Separator, [S]);
join([S | Rest], Separator, Acc) ->
  join(Rest, Separator, [S, Separator | Acc]).

to_hex([]) ->
  [];
to_hex(Bin) when is_binary(Bin) ->
  to_hex(binary_to_list(Bin));
to_hex([H|T]) ->
  [to_digit(H div 16), to_digit(H rem 16) | to_hex(T)].

to_digit(N) when N < 10 -> $0 + N;
to_digit(N)             -> $a + N-10.



%% @doc Parse a case-insensitive token.
%%
%% Changes all characters to lowercase.
-spec token_ci(binary(), fun()) -> any().
token_ci(Data, Fun) ->
  token(Data, Fun, ci, <<>>).

%% @doc Parse a token.
-spec token(binary(), fun()) -> any().
token(Data, Fun) ->
  token(Data, Fun, cs, <<>>).

-spec token(binary(), fun(), ci | cs, binary()) -> any().
token(<<>>, Fun, _Case, Acc) ->
  Fun(<<>>, Acc);
token(Data = << C, _Rest/binary >>, Fun, _Case, Acc)
  when C =:= $(; C =:= $); C =:= $<; C =:= $>; C =:= $@;
       C =:= $,; C =:= $;; C =:= $:; C =:= $\\; C =:= $";
       C =:= $/; C =:= $[; C =:= $]; C =:= $?; C =:= $=;
       C =:= ${; C =:= $}; C =:= $\s; C =:= $\t;
       C < 32; C =:= 127 ->
  Fun(Data, Acc);
token(<< C, Rest/binary >>, Fun, Case = ci, Acc) ->
  C2 = char_to_lower(C),
  token(Rest, Fun, Case, << Acc/binary, C2 >>);
token(<< C, Rest/binary >>, Fun, Case, Acc) ->
  token(Rest, Fun, Case, << Acc/binary, C >>).


%% @doc Parse a non-empty list of the given type.
-spec nonempty_list(binary(), fun()) -> [any(), ...] | {error, badarg}.
nonempty_list(Data, Fun) ->
  case list(Data, Fun, []) of
    {error, badarg} -> {error, badarg};
    [] -> {error, badarg};
    L -> lists:reverse(L)
  end.

%% @doc Parse a list of the given type.
-spec list(binary(), fun()) -> list() | {error, badarg}.
list(Data, Fun) ->
  case list(Data, Fun, []) of
    {error, badarg} -> {error, badarg};
    L -> lists:reverse(L)
  end.

-spec list(binary(), fun(), [binary()]) -> [any()] | {error, badarg}.
%% From the RFC:
%% <blockquote>Wherever this construct is used, null elements are allowed,
%% but do not contribute to the count of elements present.
%% That is, "(element), , (element) " is permitted, but counts
%% as only two elements. Therefore, where at least one element is required,
%% at least one non-null element MUST be present.</blockquote>
list(Data, Fun, Acc) ->
  whitespace(Data,
    fun (<<>>) -> Acc;
        (<< $,, Rest/binary >>) -> list(Rest, Fun, Acc);
        (Rest) -> Fun(Rest,
          fun (D, I) -> whitespace(D,
            fun (<<>>) -> [I|Acc];
                (<< $,, R/binary >>) -> list(R, Fun,
                  [I|Acc]);
                (_Any) -> {error, badarg}
            end)
          end)
    end).


%% @doc Parse a list of parameters (a=b;c=d).
-spec params(binary(), fun()) -> any().
params(Data, Fun) ->
  params(Data, Fun, []).

-spec params(binary(), fun(), [{binary(), binary()}]) -> any().
params(Data, Fun, Acc) ->
  whitespace(Data,
    fun (<< $;, Rest/binary >>) ->
      param(Rest,
        fun (Rest2, Attr, Value) ->
          params(Rest2, Fun, [{Attr, Value}|Acc])
        end);
        (Rest) ->
          Fun(Rest, lists:reverse(Acc))
    end).

-spec param(binary(), fun()) -> any().
param(Data, Fun) ->
  whitespace(Data,
    fun (Rest) ->
      token_ci(Rest,
        fun (_Rest2, <<>>) -> {error, badarg};
            (<< $=, Rest2/binary >>, Attr) ->
              word(Rest2,
                fun (Rest3, Value) ->
                  Fun(Rest3, Attr, Value)
                end);
            (_Rest2, _Attr) -> {error, badarg}
        end)
    end).

%% @doc Parse a non empty list of tokens followed with optional parameters.
-spec parameterized_tokens(binary()) -> any().
parameterized_tokens(Data) ->
  nonempty_list(Data,
    fun (D, Fun) ->
      token(D,
        fun (_Rest, <<>>) -> {error, badarg};
            (Rest, Token) ->
              parameterized_tokens_params(Rest,
                fun (Rest2, Params) ->
                  Fun(Rest2, {Token, Params})
                end, [])
        end)
    end).

-spec parameterized_tokens_params(binary(), fun(),
  [binary() | {binary(), binary()}]) -> any().
parameterized_tokens_params(Data, Fun, Acc) ->
  whitespace(Data,
    fun (<< $;, Rest/binary >>) ->
      parameterized_tokens_param(Rest,
        fun (Rest2, Param) ->
          parameterized_tokens_params(Rest2, Fun,
            [Param|Acc])
        end);
        (Rest) ->
          Fun(Rest, lists:reverse(Acc))
    end).

-spec parameterized_tokens_param(binary(), fun()) -> any().
parameterized_tokens_param(Data, Fun) ->
  whitespace(Data,
    fun (Rest) ->
      token(Rest,
        fun (_Rest2, <<>>) ->
          {error, badarg};
            (<< $=, Rest2/binary >>, Attr) ->
              word(Rest2,
                fun (Rest3, Value) ->
                  Fun(Rest3, {Attr, Value})
                end);
            (Rest2, Attr) ->
              Fun(Rest2, Attr)
        end)
    end).

%% @doc Skip whitespace.
-spec whitespace(binary(), fun()) -> any().
whitespace(<< C, Rest/binary >>, Fun)
  when C =:= $\s; C =:= $\t ->
  whitespace(Rest, Fun);
whitespace(Data, Fun) ->
  Fun(Data).

%% @doc Parse a list of digits as a non negative integer.
-spec digits(binary()) -> non_neg_integer() | {error, badarg}.
digits(Data) ->
  digits(Data,
    fun (Rest, I) ->
      whitespace(Rest,
        fun (<<>>) ->
          I;
            (_Rest2) ->
              {error, badarg}
        end)
    end).

-spec digits(binary(), fun()) -> any().
digits(<< C, Rest/binary >>, Fun)
  when C >= $0, C =< $9 ->
  digits(Rest, Fun, C - $0);
digits(_Data, _Fun) ->
  {error, badarg}.

-spec digits(binary(), fun(), non_neg_integer()) -> any().
digits(<< C, Rest/binary >>, Fun, Acc)
  when C >= $0, C =< $9 ->
  digits(Rest, Fun, Acc * 10 + (C - $0));
digits(Data, Fun, Acc) ->
  Fun(Data, Acc).


%% @doc Parse a list of case-insensitive alpha characters.
%%
%% Changes all characters to lowercase.
-spec alpha(binary(), fun()) -> any().
alpha(Data, Fun) ->
  alpha(Data, Fun, <<>>).

-spec alpha(binary(), fun(), binary()) -> any().
alpha(<<>>, Fun, Acc) ->
  Fun(<<>>, Acc);
alpha(<< C, Rest/binary >>, Fun, Acc)
  when C >= $a andalso C =< $z;
       C >= $A andalso C =< $Z ->
  C2 = char_to_lower(C),
  alpha(Rest, Fun, << Acc/binary, C2 >>);
alpha(Data, Fun, Acc) ->
  Fun(Data, Acc).

%% @doc Parse either a token or a quoted string.
-spec word(binary(), fun()) -> any().
word(Data = << $", _/binary >>, Fun) ->
  quoted_string(Data, Fun);
word(Data, Fun) ->
  token(Data,
    fun (_Rest, <<>>) -> {error, badarg};
        (Rest, Token) -> Fun(Rest, Token)
    end).

-spec trim(binary()) -> binary().
trim(Data) ->
  re:replace(Data, "^\\s+|\\s+$", "", [{return, binary}, global]).

-spec quoted_string(binary(), fun()) -> any().
quoted_string(<< $", Rest/binary >>, Fun) ->
  quoted_string(Rest, Fun, <<>>).

-spec quoted_string(binary(), fun(), binary()) -> any().
quoted_string(<<>>, _Fun, _Acc) ->
  {error, badarg};
quoted_string(<< $", Rest/binary >>, Fun, Acc) ->
  Fun(Rest, Acc);
quoted_string(<< $\\, C, Rest/binary >>, Fun, Acc) ->
  quoted_string(Rest, Fun, << Acc/binary, C >>);
quoted_string(<< C, Rest/binary >>, Fun, Acc) ->
  quoted_string(Rest, Fun, << Acc/binary, C >>).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% binary:split/3 from OTP 18
%% remove when support for < 18
%% formally dropped
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec split(Subject, Pattern, Options) -> Parts when
  Subject :: binary(),
  Pattern :: binary() | [binary()] | cp(),
  Options :: [Option],
  Option :: {scope, part()} | trim | global | trim_all,
  Parts :: [binary()].

split(Haystack,Needles,Options) ->
  try
    {Part,Global,Trim,TrimAll} =
      get_opts_split(Options,{no,false,false,false}),
    Moptlist = case Part of
                 no ->
                   [];
                 {A,B} ->
                   [{scope,{A,B}}]
               end,
    MList = if
              Global ->
                binary:matches(Haystack,Needles,Moptlist);
              true ->
                case binary:match(Haystack,Needles,Moptlist) of
                  nomatch -> [];
                  Match -> [Match]
                end
            end,
    do_split(Haystack,MList,0,Trim,TrimAll)
  catch
    _:_ ->
      erlang:error(badarg)
  end.

do_split(H,[],N,true,_) when N >= byte_size(H) ->
  [];
do_split(H,[],N,_,true) when N >= byte_size(H) ->
  [];
do_split(H,[],N,_,_) ->
  [binary:part(H,{N,byte_size(H)-N})];
do_split(H,[{A,B}|T],N,Trim,TrimAll) ->
  case binary:part(H,{N,A-N}) of
    <<>> when TrimAll == true ->
      do_split(H,T,A+B,Trim,TrimAll);
    <<>> ->
      Rest =  do_split(H,T,A+B,Trim,TrimAll),
      case {Trim, Rest} of
        {true,[]} ->
          [];
        _ ->
          [<<>> | Rest]
      end;
    Oth ->
      [Oth | do_split(H,T,A+B,Trim,TrimAll)]
  end.

get_opts_split([],{Part,Global,Trim,TrimAll}) ->
  {Part,Global,Trim,TrimAll};
get_opts_split([{scope,{A,B}} | T],{_Part,Global,Trim,TrimAll}) ->
  get_opts_split(T,{{A,B},Global,Trim,TrimAll});
get_opts_split([global | T],{Part,_Global,Trim,TrimAll}) ->
  get_opts_split(T,{Part,true,Trim,TrimAll});
get_opts_split([trim | T],{Part,Global,_Trim,TrimAll}) ->
  get_opts_split(T,{Part,Global,true,TrimAll});
get_opts_split([trim_all | T],{Part,Global,Trim,_TrimAll}) ->
  get_opts_split(T,{Part,Global,Trim,true});
get_opts_split(_,_) ->
  throw(badopt).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  END binary:split from OTP 18
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
