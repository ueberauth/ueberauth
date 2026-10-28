%%% -*- erlang -*-
%%%
%%% This file is part of hackney_lib released under the Apache 2 license.
%%% See the NOTICE for more information.

-module(hackney_headers_new).
-author("benoitc").

%% API
-export([
  new/0, new/1,
  from_list/1,
  append/3,
  store/2, store/3,
  store_new/3,
  delete/2,
  is_key/2,
  lookup/2,
  get_value/2, get_value/3,
  size/1,
  fold/3,
  merge/2,
  to_list/1,
  to_iolist/1,
  to_binary/1,
  parse_content_type/1,
  parse_media_type/2
]).

-define(kl(Key), hackney_bstr:to_lower(Key)).


-type headers() ::term().
-type key() :: binary() | string().
-type value() :: binary() | {binary() | list({binary(), binary()} | binary())}.
-type headers_list() :: [{key(), value()}].

-export_types([headers/0, key/0, value/0]).

%% @doc initialize an empty headers objecy
-spec new() -> headers().
new() -> {0, dict:new()}.

-spec new(headers_list() | headers()) -> headers().
new(H) when is_list(H) -> from_list(H);
new({_, _}=H) -> H;
new(_) -> erlang:error(badarg).

%% @doc create headers from a list
-spec from_list(headers_list()) -> headers().
from_list(HeadersList) when is_list(HeadersList) ->
  lists:foldl(
    fun({Key, Value}, Headers) -> append(Key, Value, Headers) end,
    {0, dict:new()},
    HeadersList
  );
from_list(_) -> erlang:error(badarg).

%% @doc append a new value to the list of value for the the header field
%% if the key has not been recorded the list will be created with the value as the first item.
-spec append(key(), value(), headers()) -> headers().
append(Key, Value, {N, Headers}) ->
  KL = ?kl(Key),
  {N + 1, dict:append(KL, {N, Key, Value}, Headers)}.

%% @doc replace the content of the header field with the value or the list of values.
-spec store(key(), value() | [value()], headers()) -> headers().
store(Key, Values, {N, Headers}) when is_list(Values) ->
  KL = ?kl(Key),
  lists:foldl(
    fun(V, {I, H}) ->
      {I + 1, dict:append(KL, {I, Key, V}, H)}
    end,
    {N, dict:store(KL, [], Headers)},
    Values
  );
store(Key, Value, {N, Headers}) ->
  KL = ?kl(Key),
  {N +1, dict:store(KL, [{N, Key, Value}], Headers)}.

%% @doc store a list of headers. Replacing oldest
-spec store(headers_list(), headers()) -> headers().
store(KVs, Headers) when is_list(KVs) ->
  lists:foldl(
    fun({K, V}, H) -> store(K, V, H) end,
    Headers,
    KVs
   ).

%% @doc only store a value if the key exist.
-spec store_new(key(), value(), headers()) -> {boolean(), headers()}.
store_new(Key, Value, {_N, DictHeaders}=Headers) ->
  KL = ?kl(Key),
  case dict:is_key(KL, DictHeaders) of
    true ->
      {false, Headers};
    false ->
      {true, store(Key, Value, Headers)}
  end.

%% @doc delete a field from headers.
-spec delete(key(), headers()) -> headers().
delete(Key, {N, Headers}=H) ->
  KL = ?kl(Key),
  case dict:find(KL, Headers) of
    {ok, Values} ->
      Headers2 = dict:erase(KL, Headers),
      {N - length(Values), Headers2};
    error ->
      H
  end.

%% @doc is the header field exists or no
-spec is_key(key(), headers()) -> true | false.
is_key(Key, {_, Headers}) -> dict:is_key(?kl(Key), Headers).

lookup(Key, {_, Headers}) ->
  case dict:find(?kl(Key), Headers) of
    {ok, KVs} -> [{K, V} || {_, K, V} <- KVs];
    error -> []
  end.

%% @doc get the first value of an headers or return undefined
-spec get_value(key(), headers()) -> value() | undefined.
get_value(Key, Headers) -> get_value(Key, Headers, undefined).

%% @doc get the first value of an headers or return the default
-spec get_value(key(), headers(), any()) -> value() | any().
get_value(Key, Headers, Default) ->
  case lookup(Key, Headers) of
    [] -> Default;
    [{_Key, Value}|_] -> Value
  end.

%% @doc return the number of headers fields
-spec size(headers()) -> non_neg_integer().
size({N, _}) -> N.

fold(Fun, Acc, {_, Headers}) ->
  Lines = dict:fold(
    fun(_, Value, Acc1) -> Value ++ Acc1 end,
    [],
    Headers
  ),
  do_fold(lists:sort(Lines), Fun, Acc).

do_fold([{_, Key, Value} | Rest], Fun, Acc) ->
  do_fold(Rest, Fun, Fun(Key, Value, Acc));
do_fold([], _Fun, Acc) -> Acc.

%% @doc merge 2 headers objects. If a key is already existing in HEader1, it will be kept.
-spec merge(headers(), headers()) -> headers().
merge(Headers1, {_, DictHeaders2}) ->
  dict:fold(
    fun(Key, Value, H) ->
      case is_key(Key, H) of
        true -> H;
        false ->
          [{_, K, V} | Rest] = Value,
          do_merge(Rest, store(K, V, H))
      end
    end,
    Headers1,
    DictHeaders2
  ).

do_merge([{_, K, V} | R], H) -> do_merge(R, append(K, V, H));
do_merge([], H) -> H.


%% @doc convert headers to a list
-spec to_list(headers()) -> headers_list().
to_list(Headers) ->
  Result = fold(
    fun(Key, Value, Acc) -> [{Key, Value} | Acc] end,
    [],
    Headers
  ),
  lists:reverse(Result).

%% @doc convert headers to an iolist. Useful to send them over the wire.
-spec to_iolist(headers()) -> iolist().
to_iolist(Headers) ->
  L = fold(
    fun(Key, Value0, L1) ->
      case Value0 of
        {Value, Params} ->
          [[
            hackney_bstr:to_binary(Key),": ",  hackney_bstr:to_binary(Value),
            params_to_iolist(Params, []), "\r\n"
          ] | L1];
        _ ->
          [[hackney_bstr:to_binary(Key),": ", hackney_bstr:to_binary(Value0), "\r\n"] | L1]
      end
    end,
    [],
    Headers
  ),
  lists:reverse(["\r\n" | L ]).

params_to_iolist([{K, V} | Rest], List) ->
  List2 = [[";", hackney_bstr:to_binary(K), "=", hackney_bstr:to_binary(V)] | List],
  params_to_iolist(Rest, List2);
params_to_iolist([K | Rest], List) ->
  List2 = [[";", hackney_bstr:to_binary(K)] | List],
  params_to_iolist(Rest, List2);
params_to_iolist([], List) ->
  lists:reverse(List).

%% @doc transform headers to a binary that can be used to construct a request
-spec to_binary(headers()) -> binary().
to_binary(Headers) ->
  iolist_to_binary(to_iolist(Headers)).


%% We lowercase the charset header as we know it's case insensitive.
%% TODO: change api to parse content
-spec parse_content_type(binary()) -> any().
parse_content_type(Data) ->
  parse_media_type(Data,
    fun (Rest, Type, SubType) ->
      hackney_bstr:params(Rest,
        fun (<<>>, Params) ->
          case lists:keyfind(<<"charset">>, 1, Params) of
            false ->
              {Type, SubType, Params};
            {_, Charset} ->
              Charset2 = hackney_bstr:to_lower(Charset),
              Params2 = lists:keyreplace(<<"charset">>,
                1, Params,
                {<<"charset">>, Charset2}),
              {Type, SubType, Params2}
          end;
            (_Rest2, _) ->
              {error, badarg}
        end)
    end).

%% @doc Parse a media type.
-spec parse_media_type(binary(), fun()) -> any().
parse_media_type(Data, Fun) ->
  hackney_bstr:token_ci(Data,
    fun (_Rest, <<>>) -> {error, badarg};
        (<< $/, Rest/binary >>, Type) ->
          hackney_bstr:token_ci(Rest,
            fun (_Rest2, <<>>) -> {error, badarg};
                (Rest2, SubType) -> Fun(Rest2, Type, SubType)
            end);
      %% This is a non-strict parsing clause required by some user agents
      %% that use * instead of */* in the list of media types.
        (Rest, <<"*">> = Type) ->
          hackney_bstr:token_ci(<<"*", Rest/binary>>,
            fun (_Rest2, <<>>) -> {error, badarg};
                (Rest2, SubType) -> Fun(Rest2, Type, SubType)
            end);
        (_Rest, _Type) -> {error, badarg}
    end).
