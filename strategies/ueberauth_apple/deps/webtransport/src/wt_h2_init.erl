%% Copyright (c) 2026, Benoit Chesneau.
%% Licensed under the Apache License, Version 2.0.
%%
%% @doc WebTransport-Init structured-field header (draft-14 §4.3.2).
%%
%% The WebTransport-Init request header is an RFC 8941 Dictionary with
%% integer values. Defined keys:
%%   u  - initial max stream count for unidirectional streams opened by
%%        the recipient
%%   bl - initial max stream count for bidirectional streams opened by
%%        the sender
%%   br - initial max stream count for bidirectional streams opened by
%%        the recipient
%%
%% When both HTTP/2 SETTINGS and WebTransport-Init are present, the
%% endpoint MUST use the greater of the two values for each field.
-module(wt_h2_init).

-export([parse/1, encode/1]).
-export([apply_greater_of/2]).

-type init_params() :: #{
    u  => non_neg_integer(),
    bl => non_neg_integer(),
    br => non_neg_integer()
}.

-export_type([init_params/0]).

%% ============================================================================
%% Encode
%% ============================================================================

%% @doc Encode a WebTransport-Init header value.
%% Produces an RFC 8941 Dictionary in its simplest form: `key=value, ...'.
-spec encode(init_params()) -> binary().
encode(Params) when is_map(Params) ->
    Parts = lists:filtermap(fun({Key, Val}) ->
        case key_to_binary(Key) of
            undefined -> false;
            K -> {true, <<K/binary, "=", (integer_to_binary(Val))/binary>>}
        end
    end, maps:to_list(Params)),
    iolist_to_binary(lists:join(<<", ">>, Parts)).

%% ============================================================================
%% Parse
%% ============================================================================

%% @doc Parse a WebTransport-Init header value.
%% Accepts the RFC 8941 Dictionary subset we emit: `key=integer, ...'.
-spec parse(binary()) -> {ok, init_params()} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    try
        Items = binary:split(Bin, [<<",">>, <<", ">>], [global, trim_all]),
        {ok, parse_items(Items, #{})}
    catch
        throw:Reason -> {error, Reason}
    end.

parse_items([], Acc) ->
    Acc;
parse_items([Item | Rest], Acc) ->
    Trimmed = string:trim(Item),
    case binary:split(Trimmed, <<"=">>) of
        [KeyBin, ValBin] ->
            Key = binary_to_key(KeyBin),
            Val = try binary_to_integer(ValBin)
                  catch _:_ -> throw({bad_integer, ValBin})
                  end,
            case Key of
                undefined -> parse_items(Rest, Acc);
                K -> parse_items(Rest, Acc#{K => Val})
            end;
        _ ->
            throw({bad_item, Trimmed})
    end.

%% ============================================================================
%% Apply greater-of rule
%% ============================================================================

%% @doc Merge WebTransport-Init values with local defaults, taking
%% the greater of each field (draft-14 §4.3.2).
-spec apply_greater_of(init_params(), init_params()) -> init_params().
apply_greater_of(Init, Defaults) ->
    maps:fold(fun(Key, Val, Acc) ->
        case maps:find(Key, Acc) of
            {ok, Existing} -> Acc#{Key => max(Val, Existing)};
            error -> Acc#{Key => Val}
        end
    end, Defaults, Init).

%% ============================================================================
%% Key mapping
%% ============================================================================

key_to_binary(u)  -> <<"u">>;
key_to_binary(bl) -> <<"bl">>;
key_to_binary(br) -> <<"br">>;
key_to_binary(_)  -> undefined.

binary_to_key(<<"u">>)  -> u;
binary_to_key(<<"bl">>) -> bl;
binary_to_key(<<"br">>) -> br;
binary_to_key(_)        -> undefined.

%% ============================================================================
%% Tests
%% ============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Params = #{u => 100, bl => 50, br => 200},
    Encoded = encode(Params),
    {ok, Decoded} = parse(Encoded),
    ?assertEqual(Params, Decoded).

parse_simple_test() ->
    ?assertEqual({ok, #{u => 10}}, parse(<<"u=10">>)),
    ?assertEqual({ok, #{u => 10, bl => 20}}, parse(<<"u=10, bl=20">>)),
    ?assertEqual({ok, #{u => 10, bl => 20, br => 30}},
                 parse(<<"u=10, bl=20, br=30">>)).

parse_ignores_unknown_keys_test() ->
    {ok, Parsed} = parse(<<"u=5, foo=99, bl=3">>),
    ?assertEqual(#{u => 5, bl => 3}, Parsed).

parse_bad_integer_test() ->
    ?assertEqual({error, {bad_integer, <<"abc">>}}, parse(<<"u=abc">>)).

parse_bad_item_test() ->
    ?assertEqual({error, {bad_item, <<"noequals">>}}, parse(<<"noequals">>)).

encode_test() ->
    %% Order is implementation-defined; just check round-trip
    Params = #{u => 42, br => 99},
    {ok, D} = parse(encode(Params)),
    ?assertEqual(Params, D).

apply_greater_of_test() ->
    Init = #{u => 200, bl => 10},
    Defaults = #{u => 100, bl => 50, br => 30},
    Result = apply_greater_of(Init, Defaults),
    ?assertEqual(200, maps:get(u, Result)),   %% Init wins
    ?assertEqual(50, maps:get(bl, Result)),   %% Default wins
    ?assertEqual(30, maps:get(br, Result)).   %% Only in defaults

-endif.
