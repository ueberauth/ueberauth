%%% -*- erlang -*-
%%%
%%% @private
%%%
%%% QUIC structured logging – report_cb for OTP Logger.
%%%
%%% Callback for formatting QUIC log reports (maps with mandatory `what' key)
%%% into human-readable strings. Mirrors supervisor:format_log/2: merge defaults,
%%% build {Format, Args} via format_* helpers, then io_lib:format(Format, Args, IoOpts).

-module(quic_log).

-export([format_report/2]).

%% @private
%% Report is a map with mandatory key `what' and optional key-value pairs.
%% Config is report_cb_config(): depth, chars_limit, single_line (see OTP Logger).
-spec format_report(logger:report(), logger:report_cb_config()) -> unicode:chardata().
format_report(Report, Config) when is_map(Report) ->
    Default = #{
        chars_limit => unlimited,
        depth => unlimited,
        single_line => false,
        encoding => utf8
    },
    FormatOpts = maps:merge(Default, Config),
    IoOpts =
        case FormatOpts of
            #{chars_limit := unlimited} -> [];
            #{chars_limit := Limit} -> [{chars_limit, Limit}]
        end,
    {Format, Args} = format_log(Report, FormatOpts),
    io_lib:format("[QUIC] " ++ Format, Args, IoOpts).

%% Single-line: one "~p = ~P " (or ~p) per pair; multi-line: "  ~p = ~P~n" etc.
format_log(Report, #{single_line := Single} = FormatOpts) ->
    Sep =
        case Single of
            true -> " ";
            false -> "~n  "
        end,
    P = p(FormatOpts),
    Pairs = sort_what_first(Report),
    {FormatParts, Args} = lists:mapfoldl(
        fun(Pair, Acc) -> part_and_args(FormatOpts, Pair, P, Sep, Acc) end,
        [],
        Pairs
    ),
    {lists:flatten(FormatParts), Args}.

%% 'what' is always an atom with underscores; print value as string without underscores.
part_and_args(_FormatOpts, {what, V}, _P, Sep, Acc) when is_atom(V) ->
    Part = "[~s]" ++ Sep,
    ArgsHere = [what_to_string(V)],
    {Part, Acc ++ ArgsHere};
part_and_args(FormatOpts, {K, V}, P, Sep, Acc) ->
    Part = "~p=" ++ P ++ Sep,
    ArgsHere = args_for(FormatOpts, K, V),
    {Part, Acc ++ ArgsHere}.

%% Atom to readable string: underscores become spaces (e.g. udp_received -> "udp received").
what_to_string(Atom) when is_atom(Atom) ->
    lists:flatten([
        case C of
            $_ -> " ";
            _ -> C
        end
     || C <- atom_to_list(Atom)
    ]).

args_for(#{depth := unlimited}, K, V) ->
    [K, V];
args_for(#{depth := Depth}, K, V) ->
    [K, V, Depth].

%% Format control for value: ~p / ~P with optional width and encoding (cf. supervisor).
p(#{single_line := Single, depth := Depth, encoding := Enc}) ->
    "~" ++ single(Single) ++ mod(Enc) ++ p_depth(Depth).

p_depth(unlimited) -> "p";
p_depth(_) -> "P".

single(true) -> "0";
single(false) -> "".

mod(latin1) -> "";
mod(_) -> "t".

sort_what_first(Report) ->
    Pairs = maps:to_list(Report),
    case lists:keytake(what, 1, Pairs) of
        {value, WhatPair, Rest} ->
            [WhatPair | Rest];
        false ->
            Pairs
    end.
