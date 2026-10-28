%%% -*- erlang -*-
%%%
%%% Connection ID pools (RFC 9000 Section 5.1).
%%%
%%% Two pools in one record: the CIDs we issued to the peer, and the ones
%%% it issued to us. Each is bounded by the other side's
%%% active_connection_id_limit, so both limits live here too: ours bounds
%%% how many of the peer's CIDs we retain, and the peer's bounds how many
%%% of ours we issue.
%%%
%%% Sequence 0 is the handshake CID on both sides and counts against the
%%% limit (RFC 9000 Section 18.2), so both pools carry it from the start.
%%%
%%% Everything here is a decision about pool contents. Sending frames,
%%% registering a CID with the listener and closing the connection stay
%%% with `quic_connection': they need the socket, the listener and the
%%% handshake's ordering rules.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
-module(quic_cid).

-include("quic.hrl").

-export([
    %% Construction
    new/2,
    set_initial_peer_cid/3,
    set_peer_active_limit/2,

    %% CIDs we issue to the peer
    issue/3,
    retire_local/2,
    replenish_needed/1,
    local_active_limit/1,
    local_entries/1,
    local_active_count/1,

    %% CIDs the peer issues to us
    add_peer_cid/5,
    add_preferred_address_cid/3,
    record_initial_reset_token/2,
    prune_retired_peer/1,
    retire_peer/2,
    peer_entries/1,
    peer_active_count/1,

    %% Choosing a destination CID
    fresh_dcid/2,
    bind_peer_cid/3,
    replacement_for_retired_dcid/2,

    %% Stateless reset
    generate_reset_token/2,
    find_reset_token_match/2
]).

-export_type([pool/0]).

-opaque pool() :: #cid_pool_state{}.

%%====================================================================
%% Construction
%%====================================================================

%% @doc A pool holding our handshake CID as sequence 0, and the limit we
%% advertise, which bounds how many of the peer's CIDs we will retain.
-spec new(binary(), non_neg_integer()) -> pool().
new(SCID, LocalActiveLimit) ->
    #cid_pool_state{
        local = [#cid_entry{seq_num = 0, cid = SCID, status = active}],
        peer = [],
        local_active_limit = LocalActiveLimit
    }.

%% @doc Record the peer's handshake CID as its sequence 0, when its Initial
%% is adopted. It counts against the limit we advertised, so it has to be in
%% the pool before any NEW_CONNECTION_ID is counted against that limit.
-spec set_initial_peer_cid(pool(), binary(), binary() | undefined) -> pool().
set_initial_peer_cid(#cid_pool_state{peer = Peer} = Pool, CID, Token) ->
    Entry = #cid_entry{seq_num = 0, cid = CID, stateless_reset_token = Token, status = active},
    Pool#cid_pool_state{peer = lists:keystore(0, #cid_entry.seq_num, Peer, Entry)}.

%% @doc Adopt the peer's advertised active_connection_id_limit, which bounds
%% how many CIDs we may issue.
-spec set_peer_active_limit(pool(), non_neg_integer()) -> pool().
set_peer_active_limit(#cid_pool_state{} = Pool, Limit) ->
    Pool#cid_pool_state{peer_active_limit = Limit}.

%%====================================================================
%% CIDs we issue to the peer
%%====================================================================

%% @doc How many more CIDs the peer's limit leaves room for.
-spec replenish_needed(pool()) -> non_neg_integer().
replenish_needed(#cid_pool_state{peer_active_limit = Limit} = Pool) ->
    max(0, Limit - local_active_count(Pool)).

%% @doc Issue N new CIDs, returning them in issue order for the caller to
%% register and advertise.
%%
%% Effectful: the CID is random, and so is the reset token when no secret is
%% configured.
-spec issue(pool(), non_neg_integer(), binary() | undefined) ->
    {pool(), [{non_neg_integer(), binary(), binary()}]}.
issue(Pool, N, ResetSecret) ->
    issue(Pool, N, ResetSecret, []).

issue(Pool, 0, _ResetSecret, Acc) ->
    {Pool, lists:reverse(Acc)};
issue(#cid_pool_state{local = Local} = Pool, N, ResetSecret, Acc) when N > 0 ->
    SeqNum = next_seq(Local),
    CID = crypto:strong_rand_bytes(8),
    Token = generate_reset_token(CID, ResetSecret),
    Entry = #cid_entry{
        seq_num = SeqNum, cid = CID, stateless_reset_token = Token, status = active
    },
    issue(
        Pool#cid_pool_state{local = [Entry | Local]},
        N - 1,
        ResetSecret,
        [{SeqNum, CID, Token} | Acc]
    ).

%% @doc Retire a CID we issued, returning it so the caller can drop it from
%% the listener's routing table. A sequence we never issued is a protocol
%% violation the caller reports (RFC 9000 Section 19.16).
-spec retire_local(pool(), non_neg_integer()) ->
    {ok, pool(), binary()} | {ok, pool(), undefined} | {error, unissued}.
retire_local(#cid_pool_state{local = Local} = Pool, SeqNum) ->
    case SeqNum >= next_seq(Local) of
        true ->
            {error, unissued};
        false ->
            Retired = [retire_matching(SeqNum, E) || E <- Local],
            CID =
                case lists:keyfind(SeqNum, #cid_entry.seq_num, Local) of
                    #cid_entry{cid = C} -> C;
                    false -> undefined
                end,
            {ok, Pool#cid_pool_state{local = Retired}, CID}
    end.

%% @doc The limit we advertise, which bounds how many of the peer's CIDs
%% we retain.
-spec local_active_limit(pool()) -> non_neg_integer().
local_active_limit(#cid_pool_state{local_active_limit = Limit}) -> Limit.

-spec local_entries(pool()) -> [#cid_entry{}].
local_entries(#cid_pool_state{local = Local}) -> Local.

-spec local_active_count(pool()) -> non_neg_integer().
local_active_count(#cid_pool_state{local = Local}) -> active_count(Local).

%%====================================================================
%% CIDs the peer issues to us
%%====================================================================

%% @doc Take a NEW_CONNECTION_ID from the peer.
%%
%% Returns the sequence numbers this frame retires, for the caller to
%% announce. They are captured before the entries are marked, so the
%% announcement does not depend on a status the marking clears. The entries
%% stay in the pool as retired until prune_retired_peer/1, so a retired
%% current DCID can still be replaced first.
-spec add_peer_cid(pool(), non_neg_integer(), non_neg_integer(), binary(), binary() | undefined) ->
    {ok, pool(), [non_neg_integer()]}
    | {duplicate, pool()}
    | {error, limit_exceeded}
    | {error, {reuse, non_neg_integer()}}.
add_peer_cid(
    #cid_pool_state{peer = Peer, local_active_limit = Limit} = Pool, SeqNum, RetirePrior, CID, Token
) ->
    case lists:keyfind(SeqNum, #cid_entry.seq_num, Peer) of
        #cid_entry{cid = CID, stateless_reset_token = Token} ->
            {duplicate, Pool};
        #cid_entry{} ->
            {error, {reuse, SeqNum}};
        false ->
            ToRetire = [S || #cid_entry{seq_num = S, status = active} <- Peer, S < RetirePrior],
            Marked = [retire_if_below(RetirePrior, E) || E <- Peer],
            Entry = #cid_entry{
                seq_num = SeqNum, cid = CID, stateless_reset_token = Token, status = active
            },
            NewPeer = [Entry | Marked],
            case active_count(NewPeer) > Limit of
                true -> {error, limit_exceeded};
                false -> {ok, Pool#cid_pool_state{peer = NewPeer}, ToRetire}
            end
    end.

%% @doc Take the CID carried in the server's preferred_address transport
%% parameter, which has an implicit sequence number of 1 and arrives outside
%% any NEW_CONNECTION_ID (RFC 9000 Section 9.6).
-spec add_preferred_address_cid(pool(), binary(), binary() | undefined) ->
    {ok, pool()} | {error, {collision, non_neg_integer()}} | {error, limit_exceeded}.
add_preferred_address_cid(
    #cid_pool_state{peer = Peer, local_active_limit = Limit} = Pool, CID, Token
) ->
    case lists:keyfind(1, #cid_entry.seq_num, Peer) of
        #cid_entry{} ->
            {error, {collision, 1}};
        false ->
            Entry = #cid_entry{
                seq_num = 1, cid = CID, stateless_reset_token = Token, status = active
            },
            NewPeer = [Entry | Peer],
            case active_count(NewPeer) > Limit of
                true -> {error, limit_exceeded};
                false -> {ok, Pool#cid_pool_state{peer = NewPeer}}
            end
    end.

%% @doc Fill in the reset token the peer sent in its transport parameters.
%% Sequence 0 exists already, installed when its Initial was adopted; a
%% token alone never creates the entry.
-spec record_initial_reset_token(pool(), binary() | undefined) -> pool().
record_initial_reset_token(#cid_pool_state{peer = Peer} = Pool, Token) when
    is_binary(Token), byte_size(Token) =:= 16
->
    case lists:keyfind(0, #cid_entry.seq_num, Peer) of
        #cid_entry{stateless_reset_token = undefined} = Entry ->
            Updated = Entry#cid_entry{stateless_reset_token = Token},
            Pool#cid_pool_state{
                peer = lists:keystore(0, #cid_entry.seq_num, Peer, Updated)
            };
        _ ->
            Pool
    end;
record_initial_reset_token(Pool, _Token) ->
    Pool.

%% @doc Drop retired peer CIDs. RETIRE_CONNECTION_ID has been sent for them
%% and we will not use them again (RFC 9000 Section 5.1.2).
-spec prune_retired_peer(pool()) -> pool().
prune_retired_peer(#cid_pool_state{peer = Peer} = Pool) ->
    Pool#cid_pool_state{peer = [E || #cid_entry{status = St} = E <- Peer, St =/= retired]}.

%% @doc Retire one peer CID by value, reporting its sequence number so the
%% caller can announce it. Used when a path stops using a CID, which
%% RFC 9000 Section 5.1.2 says to retire rather than leave outstanding.
%%
%% Total by design: an unknown CID and an already-retired one both answer
%% not_found, so a caller abandoning a CID never has to guard first.
-spec retire_peer(pool(), binary()) -> {ok, pool(), non_neg_integer()} | not_found.
retire_peer(#cid_pool_state{peer = Peer} = Pool, CID) ->
    case lists:keyfind(CID, #cid_entry.cid, Peer) of
        #cid_entry{seq_num = SeqNum, status = active} ->
            {ok, Pool#cid_pool_state{peer = [retire_matching(SeqNum, E) || E <- Peer]}, SeqNum};
        _ ->
            not_found
    end.

-spec peer_entries(pool()) -> [#cid_entry{}].
peer_entries(#cid_pool_state{peer = Peer}) -> Peer.

-spec peer_active_count(pool()) -> non_neg_integer().
peer_active_count(#cid_pool_state{peer = Peer}) -> active_count(Peer).

%%====================================================================
%% Choosing a destination CID
%%====================================================================

%% @doc An active, unbound peer CID other than the one in use.
-spec fresh_dcid(pool(), binary()) -> {ok, binary()} | not_found.
fresh_dcid(#cid_pool_state{peer = Peer}, CurrentDCID) ->
    case first_available(Peer, CurrentDCID) of
        {ok, #cid_entry{cid = CID}} -> {ok, CID};
        not_found -> not_found
    end.

%% @doc Take a CID for a new path and bind it there in one step.
%%
%% RFC 9000 Section 9.5 forbids the same CID appearing on two paths, so
%% selection and reservation cannot be separate calls: two paths probing at
%% once would otherwise pick the same entry. A bound CID is never offered
%% again, and `none' is what stops a path being probed at all.
-spec bind_peer_cid(pool(), term(), binary()) ->
    {ok, pool(), binary(), non_neg_integer()} | none.
bind_peer_cid(#cid_pool_state{peer = Peer} = Pool, PathRef, CurrentDCID) ->
    case first_available(Peer, CurrentDCID) of
        {ok, #cid_entry{seq_num = SeqNum, cid = CID}} ->
            Bound = [bind_matching(SeqNum, PathRef, E) || E <- Peer],
            {ok, Pool#cid_pool_state{peer = Bound}, CID, SeqNum};
        not_found ->
            none
    end.

%% @doc A replacement when the CID we send with has just been retired.
%%
%% RFC 9000 Section 5.1.2: keeping a retired DCID makes the peer treat our
%% packets as unroutable, so the switch happens before the retirements are
%% announced. `keep' means the current DCID is still usable, or the peer
%% retired everything without providing a replacement.
-spec replacement_for_retired_dcid(pool(), binary()) -> {ok, binary()} | keep.
replacement_for_retired_dcid(#cid_pool_state{peer = Peer}, CurrentDCID) ->
    case lists:keyfind(CurrentDCID, #cid_entry.cid, Peer) of
        #cid_entry{status = retired} ->
            case first_available(Peer, CurrentDCID) of
                {ok, #cid_entry{cid = CID}} -> {ok, CID};
                not_found -> keep
            end;
        _ ->
            keep
    end.

%%====================================================================
%% Stateless reset
%%====================================================================

%% @doc The token advertised for a CID. With a listener-wide secret it is
%% derived, so a restarted listener holding the same secret can recompute it
%% for a connection whose state it has lost. Without one it is random, which
%% no listener can reproduce.
%%
%% Effectful in the no-secret case.
-spec generate_reset_token(binary(), binary() | undefined) -> binary().
generate_reset_token(_CID, undefined) ->
    crypto:strong_rand_bytes(16);
generate_reset_token(CID, Secret) when is_binary(Secret), byte_size(Secret) >= 32 ->
    <<Token:16/binary, _/binary>> = crypto:mac(hmac, sha256, Secret, CID),
    Token.

%% @doc Match a packet's trailing bytes against the reset tokens the peer
%% gave us. Compared in constant time: the tokens are secret
%% (RFC 9000 Section 10.3.1), so avoid a byte-position timing oracle.
-spec find_reset_token_match(pool(), binary()) -> {ok, binary()} | not_found.
find_reset_token_match(#cid_pool_state{peer = Peer}, Token) ->
    match_token(Peer, Token).

match_token([], _Token) ->
    not_found;
match_token([#cid_entry{stateless_reset_token = Known, cid = CID} | Rest], Token) ->
    case
        is_binary(Known) andalso byte_size(Known) =:= byte_size(Token) andalso
            crypto:hash_equals(Token, Known)
    of
        true -> {ok, CID};
        false -> match_token(Rest, Token)
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% The pool is the only place a sequence number lives, so issuance and the
%% unissued check cannot drift apart. The pool always holds sequence 0 from
%% init, so the empty clause is defensive.
next_seq([]) -> 0;
next_seq(Entries) -> lists:max([E#cid_entry.seq_num || E <- Entries]) + 1.

active_count(Entries) ->
    length([E || #cid_entry{status = active} = E <- Entries]).

retire_if_below(RetirePrior, #cid_entry{seq_num = S} = Entry) when S < RetirePrior ->
    Entry#cid_entry{status = retired};
retire_if_below(_RetirePrior, Entry) ->
    Entry.

retire_matching(SeqNum, #cid_entry{seq_num = SeqNum} = Entry) ->
    Entry#cid_entry{status = retired};
retire_matching(_SeqNum, Entry) ->
    Entry.

%% The first entry usable on a new path: active, not already bound to a
%% path, and not the one we are sending with.
first_available([], _CurrentCID) ->
    not_found;
first_available(
    [#cid_entry{cid = CID, status = active, bound_to = undefined} = Entry | _Rest], CurrentCID
) when
    CID =/= CurrentCID
->
    {ok, Entry};
first_available([_ | Rest], CurrentCID) ->
    first_available(Rest, CurrentCID).

bind_matching(SeqNum, PathRef, #cid_entry{seq_num = SeqNum} = Entry) ->
    Entry#cid_entry{bound_to = PathRef};
bind_matching(_SeqNum, _PathRef, Entry) ->
    Entry.
