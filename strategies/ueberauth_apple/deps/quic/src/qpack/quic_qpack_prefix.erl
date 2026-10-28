%%% -*- erlang -*-
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Encoded Field Section Prefix reconstruction for QPACK (RFC 9204
%%% Section 4.5.1): rebuild the Required Insert Count and Base from the wire.
%%% @end
-module(quic_qpack_prefix).

-export([
    decode_ric/3,
    decode_base/3
]).

%% @doc Reconstruct the Required Insert Count from its encoded value using the
%% modulo scheme of RFC 9204 Section 4.5.1.1. `MaxEntries` is the table's
%% maximum entry count and `TotalInsertCount` the decoder's current insert
%% count.
-spec decode_ric(non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
    non_neg_integer().
decode_ric(0, _MaxEntries, _TotalInsertCount) ->
    0;
decode_ric(ERIC, MaxEntries, TotalInsertCount) ->
    FullRange = 2 * MaxEntries,
    MaxValue = TotalInsertCount + MaxEntries,
    MaxWrapped = (MaxValue div FullRange) * FullRange,
    RIC = MaxWrapped + ERIC - 1,
    case RIC > MaxValue of
        true -> RIC - FullRange;
        false -> RIC
    end.

%% @doc Reconstruct the Base from the field section prefix Sign bit and Delta
%% Base (RFC 9204 Section 4.5.1.2). With Sign bit 0 the Base is at or above the
%% Required Insert Count and equals `ReqInsertCount + DeltaBase'. With Sign bit
%% 1 the Base is below it and equals `ReqInsertCount - DeltaBase - 1'.
-spec decode_base(0 | 1, non_neg_integer(), non_neg_integer()) -> integer().
decode_base(0, RIC, DeltaBase) ->
    RIC + DeltaBase;
decode_base(1, RIC, DeltaBase) ->
    RIC - DeltaBase - 1.
