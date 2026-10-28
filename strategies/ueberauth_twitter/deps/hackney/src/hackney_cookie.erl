%%% -*- erlang -*-
%%%
%%% This file is part of hackney_lib released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright 2007 Mochi Media, Inc.
%%% Copyright 2011 Thomas Burdick <thomas.burdick@gmail.com>
%%% Copyright 2013, Loïc Hoguin <essen@ninenines.eu>
%%% Copyright 2013-2015, Benoit Chesneau
%%%
-module(hackney_cookie).

-export([setcookie/3]).
-export([parse_cookie/1]).


-type cookie_option() :: {max_age, non_neg_integer()}
| {domain, binary()} | {path, binary()}
| {secure, boolean()} | {http_only, boolean()}.
-type cookie_opts() :: [cookie_option()].
-export_type([cookie_opts/0]).


%% @doc Convert a cookie name, value and options to its iodata form.
-spec setcookie(iodata(), iodata(), cookie_opts()) -> binary().
setcookie(Name, Value, Opts) ->
  nomatch = binary:match(iolist_to_binary(Name), [<<$=>>, <<$,>>, <<$;>>,
    <<$\s>>, <<$\t>>, <<$\r>>,
    <<$\n>>, <<$\013>>,
    <<$\014>>]),
  nomatch = binary:match(iolist_to_binary(Value), [<<$,>>, <<$;>>,
    <<$\s>>, <<$\t>>,
    <<$\r>>, <<$\n>>,
    <<$\013>>, <<$\014>>]),
  MaxAgeBin = case lists:keyfind(max_age, 1, Opts) of
                false -> <<>>;
                {_, 0} ->
                  %% MSIE requires an Expires date in the past to delete a cookie.
                  <<"; Expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0">>;
                {_, MaxAge} when is_integer(MaxAge), MaxAge > 0 ->
                  UTC = calendar:universal_time(),
                  Secs = calendar:datetime_to_gregorian_seconds(UTC),
                  Expires = calendar:gregorian_seconds_to_datetime(Secs + MaxAge),
                  [<<"; Expires=">>, hackney_date:date_to_rfc2109(Expires),
                    <<"; Max-Age=">>, integer_to_list(MaxAge)]
              end,
  DomainBin = case lists:keyfind(domain, 1, Opts) of
                false -> <<>>;
                {_, Domain} -> [<<"; Domain=">>, Domain]
              end,
  PathBin = case lists:keyfind(path, 1, Opts) of
              false -> <<>>;
              {_, Path} -> [<<"; Path=">>, Path]
            end,
  SecureBin = case lists:keyfind(secure, 1, Opts) of
                false -> <<>>;
                {_, true} -> <<"; Secure">>
              end,
  HttpOnlyBin = case lists:keyfind(http_only, 1, Opts) of
                  false -> <<>>;
                  {_, true} -> <<"; HttpOnly">>
                end,
  iolist_to_binary([Name, <<"=">>, Value, <<"; Version=1">>,
    MaxAgeBin, DomainBin, PathBin, SecureBin,
    HttpOnlyBin]).

%% @doc Parse a cookie header string and return a list of key/values.

-spec parse_cookie(binary()) -> [{binary(), binary()}] | {error, badarg}.
parse_cookie(Cookie) ->
  parse_cookie(Cookie, []).

parse_cookie(<<>>, Acc) ->
  lists:reverse(Acc);
parse_cookie(<< $\s, Rest/binary >>, Acc) ->
  parse_cookie(Rest, Acc);
parse_cookie(<< $\t, Rest/binary >>, Acc) ->
  parse_cookie(Rest, Acc);
parse_cookie(<< $,, Rest/binary >>, Acc) ->
  parse_cookie(Rest, Acc);
parse_cookie(<< $;, Rest/binary >>, Acc) ->
  parse_cookie(Rest, Acc);
parse_cookie(<< $$, Rest/binary >>, Acc) ->
  skip_cookie(Rest, Acc);
parse_cookie(Cookie, Acc) ->
  parse_cookie_name(Cookie, Acc, <<>>).

skip_cookie(<<>>, Acc) ->
  lists:reverse(Acc);
skip_cookie(<< $,, Rest/binary >>, Acc) ->
  parse_cookie(Rest, Acc);
skip_cookie(<< $;, Rest/binary >>, Acc) ->
  parse_cookie(Rest, Acc);
skip_cookie(<< _, Rest/binary >>, Acc) ->
  skip_cookie(Rest, Acc).

parse_cookie_name(<<>>, Acc, Name) when Name /= <<>> ->
  lists:reverse([{Name, true} | Acc]);
parse_cookie_name(<<>>, _, _) ->
  {error, badarg};
parse_cookie_name(<< $=, _/binary >>, _, <<>>) ->
  {error, badarg};
parse_cookie_name(<< $=, Rest/binary >>, Acc, Name) ->
  parse_cookie_value(Rest, Acc, Name, <<>>);
parse_cookie_name(<< $,, _/binary >>, _, _) ->
  {error, badarg};
parse_cookie_name(<< $;, Rest/binary >>, Acc, Name) ->
  parse_cookie(Rest, [{Name, true} | Acc]);
parse_cookie_name(<< $\s, _/binary >>, _, _) ->
  {error, badarg};
parse_cookie_name(<< $\t, _/binary >>, _, _) ->
  {error, badarg};
parse_cookie_name(<< $\r, _/binary >>, _, _) ->
  {error, badarg};
parse_cookie_name(<< $\n, _/binary >>, _, _) ->
  {error, badarg};
parse_cookie_name(<< $\013, _/binary >>, _, _) ->
  {error, badarg};
parse_cookie_name(<< $\014, _/binary >>, _, _) ->
  {error, badarg};
parse_cookie_name(<< C, Rest/binary >>, Acc, Name) ->
  parse_cookie_name(Rest, Acc, << Name/binary, C >>).

parse_cookie_value(<<>>, Acc, Name, Value) ->
  lists:reverse([{Name, parse_cookie_trim(Value)}|Acc]);
parse_cookie_value(<< $;, Rest/binary >>, Acc, Name, Value) ->
  parse_cookie(Rest, [{Name, parse_cookie_trim(Value)}|Acc]);
parse_cookie_value(<< $\t, _/binary >>, _, _, _) ->
  {error, badarg};
parse_cookie_value(<< $\r, _/binary >>, _, _, _) ->
  {error, badarg};
parse_cookie_value(<< $\n, _/binary >>, _, _, _) ->
  {error, badarg};
parse_cookie_value(<< $\013, _/binary >>, _, _, _) ->
  {error, badarg};
parse_cookie_value(<< $\014, _/binary >>, _, _, _) ->
  {error, badarg};
parse_cookie_value(<< C, Rest/binary >>, Acc, Name, Value) ->
  parse_cookie_value(Rest, Acc, Name, << Value/binary, C >>).

parse_cookie_trim(Value = <<>>) ->
  Value;
parse_cookie_trim(Value) ->
  case binary:last(Value) of
    $\s ->
      Size = byte_size(Value) - 1,
      << Value2:Size/binary, _ >> = Value,
      parse_cookie_trim(Value2);
    _ ->
      Value
  end.
