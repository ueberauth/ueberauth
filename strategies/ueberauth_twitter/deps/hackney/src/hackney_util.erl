%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
-module(hackney_util).

-export([filter_options/3]).
-export([set_option_default/3]).
-export([require/1]).
-export([maybe_apply_defaults/2]).
-export([is_ipv6/1]).
-export([privdir/0]).
-export([mod_metrics/0]).
-export([to_atom/1]).

-export([merge_opts/2]).
-export([to_int/1]).

-include("hackney.hrl").

%% @doc filter a proplists and only keep allowed keys
-spec filter_options([{atom(), any()} | {raw, any(), any(), any()}],
  [atom()], Acc) -> Acc when Acc :: [any()].
filter_options([], _, Acc) ->
  Acc;
filter_options([Opt = {Key, _}|Tail], AllowedKeys, Acc) ->
  case lists:member(Key, AllowedKeys) of
    true -> filter_options(Tail, AllowedKeys, [Opt|Acc]);
    false -> filter_options(Tail, AllowedKeys, Acc)
  end;
filter_options([Opt = {raw, _, _, _}|Tail], AllowedKeys, Acc) ->
  case lists:member(raw, AllowedKeys) of
    true -> filter_options(Tail, AllowedKeys, [Opt|Acc]);
    false -> filter_options(Tail, AllowedKeys, Acc)
  end;
filter_options([Opt|Tail], AllowedKeys, Acc) when is_atom(Opt) ->
  case lists:member(Opt, AllowedKeys) of
    true -> filter_options(Tail, AllowedKeys, [Opt|Acc]);
    false -> filter_options(Tail, AllowedKeys, Acc)
  end.

%% @doc set the default options in a proplists if not defined
-spec set_option_default(Opts, atom(), any())
    -> Opts when Opts :: [{atom(), any()}].
set_option_default(Opts, Key, Value) ->
  case lists:keymember(Key, 1, Opts) of
    true -> Opts;
    false -> [{Key, Value}|Opts]
  end.

%% @doc Start the given applications if they were not already started.
-spec require(list(module())) -> ok.
require([]) ->
  ok;
require([App|Rest]) ->
  case application:start(App) of
    ok -> ok;
    {error, {already_started, App}} -> ok
  end,
  require(Rest).

maybe_apply_defaults([], Options) ->
  Options;
maybe_apply_defaults([OptName | Rest], Options) ->
  case proplists:is_defined(OptName, Options) of
    true ->
      maybe_apply_defaults(Rest, Options);
    false ->
      {ok, Default} = application:get_env(hackney, OptName),
      maybe_apply_defaults(Rest, [{OptName, Default} | Options])
  end.

is_ipv6(Host) ->
  case inet_parse:address(Host) of
    {ok, {_, _, _, _, _, _, _, _}} ->
      true;
    {ok, {_, _, _, _}} ->
      false;
    _ ->
      case inet:getaddr(Host, inet) of
        {ok, _} ->
          false;
        _ ->
          case inet:getaddr(Host, inet6) of
            {ok, _} ->
              true;
            _ ->
              false
          end
      end
  end.

privdir() ->
  case code:priv_dir(hackney) of
    {error, _} ->
      %% try to get relative priv dir. useful for tests.
      EbinDir = filename:dirname(code:which(?MODULE)),
      AppPath = filename:dirname(EbinDir),
      filename:join(AppPath, "priv");
    Dir -> Dir
  end.

mod_metrics() ->
  case application:get_env(hackney, mod_metrics) of
    {ok, folsom} -> metrics_folsom;
    {ok, exometer} -> metrics_exometer;
    {ok, dummy} -> metrics_dummy;
    {ok, Mod} -> Mod;
    _ -> metrics_dummy
  end.


to_atom(V) when is_list(V) ->
  try
    list_to_existing_atom(V)
  catch
    _:_ -> list_to_atom(V)
  end;
to_atom(V) when is_binary(V) ->
  to_atom(binary_to_list(V));
to_atom(V) when is_atom(V) ->
  V.

merge_opts([], Options) -> Options;
merge_opts([Opt = {K, _}| Rest], Options) ->
  case lists:keymember(K, 1, Options) of
    true -> merge_opts(Rest, Options);
    false -> merge_opts(Rest, [Opt | Options])
  end;
merge_opts([Opt={raw, _, _, _} | Rest], Options) ->
  merge_opts(Rest, [Opt | Options]);
merge_opts([K | Rest], Options) when is_atom(K) ->
  case lists:member(K, Options) of
    true -> merge_opts(Rest, Options);
    false -> merge_opts(Rest, [K | Options])
  end;
merge_opts([_ | Rest], Options) ->
  merge_opts(Rest, Options).

to_int(S) when is_binary(S) ->
  to_int(binary_to_list(S));
to_int(S) ->
  try
    I = list_to_integer(S),
    {ok, I}
  catch
    error:badarg -> false
  end.