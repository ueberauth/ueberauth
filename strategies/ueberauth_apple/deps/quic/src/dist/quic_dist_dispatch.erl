%%% -*- erlang -*-
%%%
%%% QUIC Distribution Stream Dispatch
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Per-message stream routing for QUIC-distribution traffic.
%%%
%%% Each call to `erlang:dist_ctrl_get_data/1' returns either a complete
%%% distribution message (plain pass-through), the first fragment of a
%%% fragmented message, or a continuation fragment. This module
%%% classifies the byte buffer and picks a QUIC stream for it:
%%%
%%% - Plain / first fragment with a `{From, To}' pair → hash the pair
%%%   into the data-stream pool.
%%% - Continuation fragment → look up the SeqId recorded for the first
%%%   fragment; route to the same stream.
%%% - Known control message with no principals (e.g. NODE_LINK) →
%%%   first data stream (not stream 0; the receiver drops non-tick
%%%   bytes there).
%%% - Anything we cannot parse → `{fatal, Reason}'; the caller exits
%%%   the controller so net_kernel rebuilds.
%%%
%%% Atom cache must be disabled on the connection (`reject_flags =
%%% dist_util:strict_order_flags()'); the parser assumes
%%% `NumberOfAtomCacheRefs = 0' in fragment headers and a
%%% PASS_THROUGH (`112') byte before plain control messages.
%%% @end

-module(quic_dist_dispatch).

-export([
    pick_stream/4,
    %% Exported for unit tests.
    classify/1
]).

-export_type([fragments_state/0, stream_id/0, classify_result/0]).

-type stream_id() :: non_neg_integer().
-type fragments_state() :: #{SeqId :: non_neg_integer() => stream_id()}.

-type extract_result() ::
    {ok, From :: binary() | undefined, To :: binary() | undefined}
    | no_principals
    | unknown_dop
    | parse_error.

-type classify_result() ::
    {plain, extract_result()}
    | {first, SeqId :: non_neg_integer(), FragId :: non_neg_integer(), extract_result()}
    | {cont, SeqId :: non_neg_integer(), FragId :: non_neg_integer()}
    | {atom_cache_active, NumRefs :: pos_integer()}
    | not_control.

%%====================================================================
%% Public API
%%====================================================================

%% @doc Pick a stream for `Data' from the data-stream pool `DataStreams'.
%% `CtrlStream' is the control stream id; currently unused but kept in
%% the signature for future control-stream routing of system messages.
%% `Frags' is the in-flight-fragments map, updated as fragments arrive.
%%
%% Returns `{{ok, StreamId}, NewFrags}' on success, or
%% `{{fatal, Reason}, Frags}' when the buffer cannot be safely routed.
-spec pick_stream(
    Data :: binary(),
    DataStreams :: [stream_id()],
    CtrlStream :: stream_id(),
    Frags :: fragments_state()
) ->
    {{ok, stream_id()}, fragments_state()}
    | {{fatal, term()}, fragments_state()}.
pick_stream(_Data, [] = _DataStreams, _CtrlStream, Frags) ->
    %% Setup guarantees N data streams are reserved; an empty pool here
    %% is a post-setup invariant violation. Fail closed — routing dist
    %% bytes to the control stream would be silent data loss.
    {{fatal, no_data_streams}, Frags};
pick_stream(Data, DataStreams, _CtrlStream, Frags) ->
    case classify(Data) of
        {plain, Extract} ->
            route_extract(Extract, Data, DataStreams, Frags);
        {first, SeqId, FragId, Extract} ->
            case route_extract(Extract, Data, DataStreams, Frags) of
                {{ok, Sid}, Frags1} when FragId > 1 ->
                    %% Multi-fragment message — remember it for the
                    %% continuations.
                    {{ok, Sid}, maps:put(SeqId, Sid, Frags1)};
                {{ok, Sid}, Frags1} ->
                    %% FragId =:= 1 on the first fragment means total
                    %% fragment count was 1.
                    {{ok, Sid}, Frags1};
                Other ->
                    Other
            end;
        {cont, SeqId, FragId} ->
            case maps:find(SeqId, Frags) of
                {ok, Sid} when FragId =:= 1 ->
                    %% Last fragment — emit, drop the entry.
                    {{ok, Sid}, maps:remove(SeqId, Frags)};
                {ok, Sid} ->
                    {{ok, Sid}, Frags};
                error ->
                    %% Continuation without a recorded first fragment.
                    %% Reassembly on the peer would corrupt; fail closed.
                    {{fatal, {orphan_fragment, SeqId, FragId}}, Frags}
            end;
        {atom_cache_active, N} ->
            %% Sender VM is emitting cache references despite our
            %% reject_flags. Routing across streams would corrupt the
            %% receiver's cache state. Fail closed.
            {{fatal, {atom_cache_active, N}}, Frags};
        not_control ->
            {{fatal, not_control_message}, Frags}
    end.

%%====================================================================
%% Classification — exported for unit tests
%%====================================================================

%% @doc Classify the byte buffer returned by `erlang:dist_ctrl_get_data/1'.
-spec classify(binary()) -> classify_result().
classify(<<112, 131, Rest/binary>>) ->
    %% Plain pass-through: 'p' + version magic + control tuple [+ msg].
    {plain, read_tuple(Rest)};
classify(<<131, 68, 0:8, Rest/binary>>) ->
    %% Distribution header (tag 'D' = 68) with NumberOfAtomCacheRefs = 0.
    %% OTP can emit this even when DFLAG_DIST_HDR_ATOM_CACHE is rejected
    %% (the empty atom-cache section is harmless). The control tuple
    %% follows directly; the inner version byte (131) is omitted by spec.
    {plain, read_tuple(Rest)};
classify(<<131, 68, N:8, _/binary>>) when N > 0 ->
    %% Non-empty atom-cache section. With our reject_flags this should
    %% never occur — its existence implies cache state crosses streams,
    %% which our routing cannot safely multiplex. Fail closed.
    {atom_cache_active, N};
classify(<<131, 69, SeqId:64, FragId:64, 0:8, Rest/binary>>) ->
    %% First fragment, atom-cache section empty. Control tuple follows
    %% directly; no leading 131 because the version byte is omitted on
    %% terms inside a dist header.
    {first, SeqId, FragId, read_tuple(Rest)};
classify(<<131, 69, _SeqId:64, _FragId:64, N:8, _/binary>>) when N > 0 ->
    %% First fragment with atom-cache refs — same safety concern as the
    %% non-fragmented case above.
    {atom_cache_active, N};
classify(<<131, 70, SeqId:64, FragId:64, _Payload/binary>>) ->
    %% Continuation fragment: SeqId + FragId + raw bytes.
    {cont, SeqId, FragId};
classify(_) ->
    not_control.

%%====================================================================
%% Internal
%%====================================================================

route_extract({ok, F, T}, _Data, DS, Frags) when
    F =/= undefined, T =/= undefined
->
    {{ok, hash_to({F, T}, DS)}, Frags};
route_extract({ok, F, undefined}, _Data, DS, Frags) when F =/= undefined ->
    {{ok, hash_to(F, DS)}, Frags};
route_extract({ok, undefined, T}, _Data, DS, Frags) when T =/= undefined ->
    {{ok, hash_to(T, DS)}, Frags};
route_extract(no_principals, _Data, [First | _], Frags) ->
    %% NODE_LINK etc. Route to the first data stream — NOT control,
    %% because handle_control_data/3 drops non-tick bytes on stream 0.
    {{ok, First}, Frags};
route_extract(unknown_dop, Data, _DS, Frags) ->
    {{fatal, {unknown_dop, peek_tag(Data)}}, Frags};
route_extract(parse_error, Data, _DS, Frags) ->
    {{fatal, {parse_error, peek_tag(Data)}}, Frags}.

hash_to(Key, DS) ->
    Idx = erlang:phash2(Key, length(DS)),
    lists:nth(Idx + 1, DS).

peek_tag(<<112, 131, 104, _Arity, 97, Tag, _/binary>>) -> Tag;
peek_tag(<<112, 131, 104, _Arity, 98, Tag:32, _/binary>>) -> Tag;
peek_tag(<<131, 69, _SeqId:64, _FragId:64, 0, 104, _Arity, 97, Tag, _/binary>>) -> Tag;
peek_tag(<<131, 69, _SeqId:64, _FragId:64, 0, 104, _Arity, 98, Tag:32, _/binary>>) -> Tag;
peek_tag(_) -> unknown.

%%--------------------------------------------------------------------
%% Tuple / DOP walk
%%--------------------------------------------------------------------

read_tuple(<<104, Arity, R/binary>>) when Arity >= 1 ->
    read_dop(Arity, R);
read_tuple(<<105, Arity:32, R/binary>>) when Arity >= 1 ->
    read_dop(Arity, R);
read_tuple(_) ->
    not_control.

read_dop(Arity, <<97, Tag, R/binary>>) -> walk(Tag, Arity, R);
read_dop(Arity, <<98, Tag:32, R/binary>>) -> walk(Tag, Arity, R);
read_dop(_, _) -> not_control.

%% positions(DOPTag) -> {FromIdx | none, ToIdx | none} | no_principals | unknown_dop
%% Positions are 1-based within the full tuple (tag at elem 1).
positions(1) -> {2, 3};
positions(2) -> {none, 3};
positions(3) -> {2, 3};
positions(4) -> {2, 3};
positions(5) -> no_principals;
positions(6) -> {2, 4};
positions(7) -> {2, 3};
positions(8) -> {2, 3};
positions(12) -> {none, 3};
positions(13) -> {2, 3};
positions(16) -> {2, 4};
positions(18) -> {2, 3};
positions(19) -> {2, 3};
positions(20) -> {2, 3};
positions(21) -> {2, 3};
positions(22) -> {2, 3};
positions(23) -> {2, 3};
positions(24) -> {2, 3};
positions(25) -> {2, 3};
positions(26) -> {2, 3};
positions(27) -> {2, 3};
positions(28) -> {2, 3};
positions(29) -> {3, none};
positions(30) -> {3, none};
positions(31) -> {none, 3};
positions(32) -> {none, 3};
positions(33) -> {2, 3};
positions(34) -> {2, 3};
positions(35) -> {3, 4};
positions(36) -> {3, 4};
positions(37) -> {3, 4};
positions(_) -> unknown_dop.

%% walk/3 dispatches on positions/1, then walks at most max(FromIdx, ToIdx)
%% elements of the tuple, capturing the byte slices at FromIdx and ToIdx.
walk(Tag, Arity, Rest) ->
    case positions(Tag) of
        unknown_dop ->
            unknown_dop;
        no_principals ->
            no_principals;
        {FromIdx, ToIdx} ->
            %% Elements after the tag = Arity - 1; we read indices 2..Last
            %% where Last = max(FromIdx, ToIdx).
            Last = erlang:max(idx_value(FromIdx), idx_value(ToIdx)),
            case Arity >= Last of
                false ->
                    parse_error;
                true ->
                    walk_loop(
                        Rest,
                        2,
                        Last,
                        FromIdx,
                        ToIdx,
                        undefined,
                        undefined
                    )
            end
    end.

idx_value(none) -> 0;
idx_value(N) when is_integer(N) -> N.

walk_loop(_Rest, Pos, Last, _FromIdx, _ToIdx, From, To) when Pos > Last ->
    {ok, From, To};
walk_loop(Rest, Pos, Last, FromIdx, ToIdx, From0, To0) ->
    case slice_term_at(Rest) of
        {ok, Slice, Rest1} ->
            From =
                case Pos =:= FromIdx of
                    true -> Slice;
                    false -> From0
                end,
            To =
                case Pos =:= ToIdx of
                    true -> Slice;
                    false -> To0
                end,
            walk_loop(Rest1, Pos + 1, Last, FromIdx, ToIdx, From, To);
        parse_error ->
            parse_error
    end.

%%--------------------------------------------------------------------
%% Term slicer — only the tags that can legally appear at or before
%% any principal position in the DOP table above.
%%--------------------------------------------------------------------

%% NEW_PID_EXT  = <<88, NodeAtom, Id:32, Serial:32, Creation:32>>
slice_term_at(<<88, Rest/binary>>) ->
    case slice_atom_only(Rest) of
        {ok, AtomBytes, <<Tail:12/binary, R/binary>>} ->
            {ok, <<88, AtomBytes/binary, Tail/binary>>, R};
        _ ->
            parse_error
    end;
%% PID_EXT      = <<103, NodeAtom, Id:32, Serial:32, Creation:8>>
slice_term_at(<<103, Rest/binary>>) ->
    case slice_atom_only(Rest) of
        {ok, AtomBytes, <<Tail:9/binary, R/binary>>} ->
            {ok, <<103, AtomBytes/binary, Tail/binary>>, R};
        _ ->
            parse_error
    end;
%% V4_PID_EXT   = <<88 is NEW_PID_EXT; V4 form uses 88 too in OTP 26+;
%% if a different tag is introduced we'll see parse_error here.>>
%% ATOM_UTF8_EXT     = <<118, Len:16, Name:Len/binary>>
slice_term_at(<<118, Len:16, Name:Len/binary, R/binary>>) ->
    {ok, <<118, Len:16, Name/binary>>, R};
%% SMALL_ATOM_UTF8_EXT = <<119, Len:8, Name:Len/binary>>
slice_term_at(<<119, Len, Name:Len/binary, R/binary>>) ->
    {ok, <<119, Len, Name/binary>>, R};
%% ATOM_EXT (legacy)   = <<100, Len:16, Name:Len/binary>>
slice_term_at(<<100, Len:16, Name:Len/binary, R/binary>>) ->
    {ok, <<100, Len:16, Name/binary>>, R};
%% NEWER_REFERENCE_EXT = <<90, Len:16, NodeAtom, Creation:32, Ids:(4*Len)/binary>>
slice_term_at(<<90, Len:16, Rest/binary>>) ->
    case slice_atom_only(Rest) of
        {ok, AtomBytes, <<Creation:32, Ids:(4 * Len)/binary, R/binary>>} ->
            {ok, <<90, Len:16, AtomBytes/binary, Creation:32, Ids/binary>>, R};
        _ ->
            parse_error
    end;
%% NEW_REFERENCE_EXT   = <<82, Len:16, NodeAtom, Creation:8, Ids:(4*Len)/binary>>
slice_term_at(<<82, Len:16, Rest/binary>>) ->
    case slice_atom_only(Rest) of
        {ok, AtomBytes, <<Creation:8, Ids:(4 * Len)/binary, R/binary>>} ->
            {ok, <<82, Len:16, AtomBytes/binary, Creation:8, Ids/binary>>, R};
        _ ->
            parse_error
    end;
%% SMALL_INTEGER_EXT   = <<97, Int:8>>
slice_term_at(<<97, I, R/binary>>) ->
    {ok, <<97, I>>, R};
%% INTEGER_EXT         = <<98, Int:32>>
slice_term_at(<<98, I:32, R/binary>>) ->
    {ok, <<98, I:32>>, R};
%% SMALL_BIG_EXT       = <<110, N:8, Sign:8, Bytes:N/binary>>
slice_term_at(<<110, N, Sign, Body:N/binary, R/binary>>) ->
    {ok, <<110, N, Sign, Body/binary>>, R};
%% LARGE_BIG_EXT       = <<111, N:32, Sign:8, Bytes:N/binary>>
slice_term_at(<<111, N:32, Sign, Body:N/binary, R/binary>>) ->
    {ok, <<111, N:32, Sign, Body/binary>>, R};
slice_term_at(_) ->
    parse_error.

%% slice_atom_only/1 reads one atom term (the embedded Node atom inside
%% pid / ref encodings) and returns its byte slice + the rest.
slice_atom_only(<<118, Len:16, Name:Len/binary, R/binary>>) ->
    {ok, <<118, Len:16, Name/binary>>, R};
slice_atom_only(<<119, Len, Name:Len/binary, R/binary>>) ->
    {ok, <<119, Len, Name/binary>>, R};
slice_atom_only(<<100, Len:16, Name:Len/binary, R/binary>>) ->
    {ok, <<100, Len:16, Name/binary>>, R};
slice_atom_only(_) ->
    parse_error.
