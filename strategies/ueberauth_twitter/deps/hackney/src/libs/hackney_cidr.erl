%%% -*- erlang -*-
%%% This file is part of inet_cidr eleased under the MIT license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2016-2024 Benoît Chesneau

-module(hackney_cidr).

-export([parse/1, parse/2]).
-export([address_count/2]).
-export([contains/2]).
-export([usort_cidrs/1]).
-export([merge_cidrs/1]).
-export([to_string/1]).
-export([to_binary/1]).
-export([is_ipv4/1]).
-export([is_ipv6/1]).
-export([ip_gte/2, ip_lte/2]).

-type cidr() :: {Start :: inet:ip4_address(), End :: inet:ip4_address(), MaskLen :: 0..32}
              | {Start :: inet:ip6_address(), End :: inet:ip6_address(), MaskLen :: 0..128}.

-export_type([cidr/0]).

-spec parse(string() | binary()) -> cidr().
%% @doc parses S as a CIDR notation IP address and mask
parse(S) ->
    parse(S, false).

-spec parse(string() | binary(), Adjust :: boolean()) -> cidr().
%% @doc parses S as a CIDR notation IP address and mask.
%% If Adjust = `true', allow the IP to contain values beyond the mask and
%% silently ignore them. Otherwise, enforce that the IP address is fully inside
%% the specified mask (the default behavior of `parse/1').
parse(B, Adjust) when is_binary(B) ->
    parse(binary_to_list(B), Adjust);
parse(S, Adjust) ->
    {StartAddr, PrefixLen} = parse_cidr(S, Adjust),
    EndAddr = calc_end_address(StartAddr, PrefixLen),
    {StartAddr, EndAddr, PrefixLen}.

-spec address_count(inet:ip4_address(), MaskLen :: 0..32)  -> pos_integer();
                   (inet:ip6_address(), MaskLen :: 0..128) -> pos_integer().
%% @doc return the number of IP addresses included in the CIDR block
address_count(IP, Len) ->
    1 bsl (bit_count(IP) - Len).

-spec contains(cidr(), inet:ip_address() | cidr()) -> boolean().
%% @doc return true if the CIDR block contains the IP address or CIDR block, false otherwise.
contains({StartAddr, EndAddr, _L}, Addr) when tuple_size(StartAddr) == tuple_size(EndAddr),
                                              tuple_size(StartAddr) == tuple_size(Addr) ->
    ip_gte(Addr, StartAddr) andalso ip_lte(Addr, EndAddr);

contains({StartAddr1, EndAddr1, _L1},
         {StartAddr2, EndAddr2, _L2}) when tuple_size(StartAddr1) == tuple_size(EndAddr1),
                                           tuple_size(EndAddr1) == tuple_size(StartAddr2),
                                           tuple_size(StartAddr2) == tuple_size(EndAddr2) ->
    ip_gte(StartAddr2, StartAddr1) andalso ip_lte(StartAddr2, EndAddr1) andalso
    ip_gte(EndAddr2, StartAddr1) andalso ip_lte(EndAddr2, EndAddr1);

contains(_, _) ->
    false.

-spec usort_cidrs([cidr()]) -> [cidr()].
%% @doc Unique sort a list of CIDR blocks, ordering IPv4 ranges before IPv6 ranges
usort_cidrs(CIDRs) ->
    lists:usort(fun cidr_lte/2, CIDRs).

-spec merge_cidrs([cidr()]) -> [cidr()].
%% @doc Unique sort and merge a list of CIDR blocks, ordering IPv4 ranges before IPv6 ranges.
%% For merging, CIDR blocks that are contained by other CIDR blocks are removed and
%% adjacent CIDR blocks are merged into larger ones.
merge_cidrs(CIDRs) ->
    merge_sorted_cidrs(usort_cidrs(CIDRs)).

-spec to_string(cidr()) -> string().
%% @doc return a CIDR block as a string.
to_string({StartAddr, _EndAddr, Len}) ->
    inet:ntoa(StartAddr) ++ "/" ++ integer_to_list(Len).

-spec to_binary(cidr()) -> binary().
%% @doc return a CIDR block as a binary string.
to_binary({StartAddr, _EndAddr, Len}) ->
    <<(list_to_binary(inet:ntoa(StartAddr)))/binary, "/", (integer_to_binary(Len))/binary>>.

-spec is_ipv4(inet:ip_address()) -> boolean().
%% @doc return true if the value is an ipv4 address
is_ipv4({A, B, C, D}) ->
    (((A >= 0) andalso (A =< 255)) andalso
     ((B >= 0) andalso (B =< 255)) andalso
     ((C >= 0) andalso (C =< 255)) andalso
     ((D >= 0) andalso (D =< 255)));
is_ipv4(_) ->
    false.

-spec is_ipv6(inet:ip_address()) -> boolean().
%% @doc return true if the value is an ipv6 address
is_ipv6({A, B, C, D, E, F, G, H}) ->
    (((A >= 0) andalso (A =< 65535)) andalso
     ((B >= 0) andalso (B =< 65535)) andalso
     ((C >= 0) andalso (C =< 65535)) andalso
     ((D >= 0) andalso (D =< 65535)) andalso
     ((E >= 0) andalso (E =< 65535)) andalso
     ((F >= 0) andalso (F =< 65535)) andalso
     ((G >= 0) andalso (G =< 65535)) andalso
     ((H >= 0) andalso (H =< 65535)));
is_ipv6(_) ->
    false.

%% internals

bit_count({_, _, _, _}) -> 32;
bit_count({_, _, _, _, _, _, _, _}) -> 128.

parse_cidr(S, Adjust) ->
  {StartAddr, Masked, PrefixLen} =
        case re:split(S, "/", [{return, list}, {parts, 2}]) of
            [Prefix, LenStr] ->
                {ok, Addr} = inet:parse_address(Prefix),
                {PLen, _} = string:to_integer(LenStr),
                {Addr, band_with_mask(Addr, start_mask(Addr, PLen)), PLen};
            [Prefix] ->
                {ok, Addr} = inet:parse_address(Prefix),
                PLen = case is_ipv6(Addr) of
                                true -> 128;
                                false -> 32
                            end,
                {Addr, band_with_mask(Addr, start_mask(Addr, PLen)), PLen}
        end,
    if
        Adjust /= true, Masked /= StartAddr -> error(invalid_cidr);
        true -> ok
    end,
    {Masked, PrefixLen}.

start_mask({_, _, _, _}=Addr, Len) when Len >= 0, Len =< 32 ->
    {A, B, C, D} = end_mask(Addr, Len),
    {bnot A, bnot B, bnot C, bnot D};

start_mask({_, _, _, _, _, _, _, _}=Addr, Len) when Len >= 0, Len =< 128 ->
    {A, B, C, D, E, F, G, H} = end_mask(Addr, Len),
    {bnot A, bnot B, bnot C, bnot D, bnot E, bnot F, bnot G, bnot H}.

end_mask({_, _, _, _}, Len) when Len >= 0, Len =< 32 ->
    if
        Len == 32 -> {0, 0, 0, 0};
        Len >= 24 -> {0, 0, 0, bmask(Len, 8)};
        Len >= 16 -> {0, 0, bmask(Len, 8), 16#FF};
        Len >= 8 -> {0, bmask(Len, 8), 16#FF, 16#FF};
        Len >= 0 -> {bmask(Len, 8), 16#FF, 16#FF, 16#FF}
    end;

end_mask({_, _, _, _, _, _, _, _}, Len) when Len >= 0, Len =< 128 ->
    if
        Len == 128 -> {0, 0, 0, 0, 0, 0, 0, 0};
        Len >= 112 -> {0, 0, 0, 0, 0, 0, 0, bmask(Len, 16)};
        Len >= 96 -> {0, 0, 0, 0, 0, 0, bmask(Len, 16), 16#FFFF};
        Len >= 80 ->  {0, 0, 0, 0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF};
        Len >= 64 -> {0, 0, 0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF};
        Len >= 48 -> {0, 0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF,
                      16#FFFF};
        Len >= 32 -> {0, 0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF,
                      16#FFFF};
        Len >= 16 -> {0, bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF,
                      16#FFFF, 16#FFFF};
        Len >= 0 -> {bmask(Len, 16), 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF,
                     16#FFFF, 16#FFFF, 16#FFFF}
    end.

bmask(I, 8) when I >= 0, I =< 32 ->
    16#FF bsr (I rem 8);
bmask(I, 16) when I >= 0, I =< 128 ->
    16#FFFF bsr (I rem 16).

calc_end_address(Addr, Len) ->
    bor_with_mask(Addr, end_mask(Addr, Len)).

bor_with_mask({A, B, C, D}, {E, F, G, H}) ->
    {A bor E, B bor F, C bor G, D bor H};
bor_with_mask({A, B, C, D, E, F, G, H}, {I, J, K, L, M, N, O, P}) ->
    {A bor I, B bor J, C bor K, D bor L, E bor M, F bor N, G bor O, H bor P}.

band_with_mask({A, B, C, D}, {E, F, G, H}) ->
    {A band E, B band F, C band G, D band H};
band_with_mask({A, B, C, D, E, F, G, H}, {I, J, K, L, M, N, O, P}) ->
    {A band I, B band J, C band K, D band L, E band M, F band N, G band O,
     H band P}.

ip_lte({A, B, C, D1}, {A, B, C, D2}) -> D1 =< D2;
ip_lte({A, B, C1, _}, {A, B, C2, _}) -> C1 =< C2;
ip_lte({A, B1, _, _}, {A, B2, _, _}) -> B1 =< B2;
ip_lte({A1, _, _, _}, {A2, _, _, _}) -> A1 =< A2;
ip_lte({A, B, C, D, E, F, G, H1}, {A, B, C, D, E, F, G, H2}) -> H1 =< H2;
ip_lte({A, B, C, D, E, F, G1, _}, {A, B, C, D, E, F, G2, _}) -> G1 =< G2;
ip_lte({A, B, C, D, E, F1, _, _}, {A, B, C, D, E, F2, _, _}) -> F1 =< F2;
ip_lte({A, B, C, D, E1, _, _, _}, {A, B, C, D, E2, _, _, _}) -> E1 =< E2;
ip_lte({A, B, C, D1, _, _, _, _}, {A, B, C, D2, _, _, _, _}) -> D1 =< D2;
ip_lte({A, B, C1, _, _, _, _, _}, {A, B, C2, _, _, _, _, _}) -> C1 =< C2;
ip_lte({A, B1, _, _, _, _, _, _}, {A, B2, _, _, _, _, _, _}) -> B1 =< B2;
ip_lte({A1, _, _, _, _, _, _, _}, {A2, _, _, _, _, _, _, _}) -> A1 =< A2.

ip_gte({A, B, C, D1}, {A, B, C, D2}) -> D1 >= D2;
ip_gte({A, B, C1, _}, {A, B, C2, _}) -> C1 >= C2;
ip_gte({A, B1, _, _}, {A, B2, _, _}) -> B1 >= B2;
ip_gte({A1, _, _, _}, {A2, _, _, _}) -> A1 >= A2;
ip_gte({A, B, C, D, E, F, G, H1}, {A, B, C, D, E, F, G, H2}) -> H1 >= H2;
ip_gte({A, B, C, D, E, F, G1, _}, {A, B, C, D, E, F, G2, _}) -> G1 >= G2;
ip_gte({A, B, C, D, E, F1, _, _}, {A, B, C, D, E, F2, _, _}) -> F1 >= F2;
ip_gte({A, B, C, D, E1, _, _, _}, {A, B, C, D, E2, _, _, _}) -> E1 >= E2;
ip_gte({A, B, C, D1, _, _, _, _}, {A, B, C, D2, _, _, _, _}) -> D1 >= D2;
ip_gte({A, B, C1, _, _, _, _, _}, {A, B, C2, _, _, _, _, _}) -> C1 >= C2;
ip_gte({A, B1, _, _, _, _, _, _}, {A, B2, _, _, _, _, _, _}) -> B1 >= B2;
ip_gte({A1, _, _, _, _, _, _, _}, {A2, _, _, _, _, _, _, _}) -> A1 >= A2.

% @private Compare 2 CIDR specifications based on the following criteria:
% * IPv4 < IPv6
% * If start range matches, sort on mask length
% * Otherwise, sort on start IP
cidr_lte({StartAddr, _, L1},
         {StartAddr, _, L2}) ->
    L1 =< L2;
cidr_lte({StartAddr1, _, _L1},
         {StartAddr2, _, _L2}) when tuple_size(StartAddr1) =/= tuple_size(StartAddr2) ->
    tuple_size(StartAddr1) =< tuple_size(StartAddr2);
cidr_lte({StartAddr1, _, _L1},
         {StartAddr2, _, _L2}) when tuple_size(StartAddr1) == tuple_size(StartAddr2) ->
    ip_lte(StartAddr1, StartAddr2).

%% @private merge a list of uniquely sorted CIDR blocks to their minimal
%% representation.
merge_sorted_cidrs(SortedCIDRs) ->
    merge_sorted_cidrs(SortedCIDRs, []).

merge_sorted_cidrs([], Acc) ->
    lists:reverse(Acc);
merge_sorted_cidrs([CIDR], Acc) ->
    lists:reverse([CIDR | Acc]);
merge_sorted_cidrs([CIDR1, CIDR2 | SortedCIDRs], Acc) ->
    case contains(CIDR1, CIDR2) of
        true ->
            merge_sorted_cidrs([CIDR1 | SortedCIDRs], Acc);
        false ->
            merge_sorted_cidrs([CIDR2 | SortedCIDRs], [CIDR1 | Acc])
    end.
