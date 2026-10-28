%%% -*- erlang -*-
%%%
%%% QUIC Session Ticket Management
%%% RFC 9001 Section 4.6 - 0-RTT Support
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc Session ticket storage and PSK derivation for 0-RTT.
%%%
%%% This module handles:
%%% - Storing and retrieving NewSessionTicket messages
%%% - Deriving PSK from resumption_master_secret
%%% - Managing ticket lifetimes and early data limits
%%%
%%% == Two stores ==
%%%
%%% `new_store/0' and friends are a plain map held in one connection's
%%% state: pure, per-connection, gone when the connection ends.
%%%
%%% `store_issued/2' and friends are the ETS table of one listener (or
%%% listener pool), shared by its connections, which is what lets a
%%% server resume a session it issued on a different connection. A
%%% ticket is only ever looked up in the table of the listener that
%%% issued it. Those functions touch ETS, the clock and the random
%%% source, so they are not pure.

-module(quic_ticket).

-export([
    %% Ticket storage (per connection, a map)
    new_store/0,
    store_ticket/3,
    lookup_ticket/2,
    clear_ticket/2,
    clear_expired/1,

    %% Tickets a server issued (per listener, ETS)
    store_issued/2,
    lookup_issued/2,
    take_issued/2,

    %% PSK derivation
    derive_resumption_secret/4,
    derive_psk/2,

    %% Ticket parsing
    parse_new_session_ticket/1,

    %% Ticket creation (server-side)
    create_ticket/5,
    build_new_session_ticket/1
]).

-include("quic.hrl").

%%====================================================================
%% Types
%%====================================================================

-type ticket_store() :: #{binary() => #session_ticket{}}.
-type session_ticket() :: #session_ticket{}.

-export_type([ticket_store/0, session_ticket/0]).

%% RFC 9001 Section 4.6.1:
%% For QUIC, max_early_data_size in NewSessionTicket must be 0xffffffff.
-define(QUIC_MAX_EARLY_DATA_SIZE, 16#FFFFFFFF).

%%====================================================================
%% Ticket Storage API
%%====================================================================

%% @doc Create a new empty ticket store.
-spec new_store() -> ticket_store().
new_store() ->
    #{}.

%% @doc Store a session ticket for a server.
%% The ticket is indexed by server name.
-spec store_ticket(binary(), session_ticket(), ticket_store()) -> ticket_store().
store_ticket(ServerName, Ticket, Store) ->
    maps:put(ServerName, Ticket, Store).

%% @doc Look up a ticket for a server.
%% Returns {ok, Ticket} if found and not expired, error otherwise.
-spec lookup_ticket(binary(), ticket_store()) -> {ok, session_ticket()} | error.
lookup_ticket(ServerName, Store) ->
    case maps:find(ServerName, Store) of
        {ok, #session_ticket{received_at = ReceivedAt, lifetime = Lifetime} = Ticket} ->
            Now = erlang:system_time(second),
            Age = Now - ReceivedAt,
            case Age =< Lifetime of
                true -> {ok, Ticket};
                % Expired
                false -> error
            end;
        error ->
            error
    end.

%% @doc Remove a ticket for a server.
-spec clear_ticket(binary(), ticket_store()) -> ticket_store().
clear_ticket(ServerName, Store) ->
    maps:remove(ServerName, Store).

%% @doc Remove all expired tickets from the store.
-spec clear_expired(ticket_store()) -> ticket_store().
clear_expired(Store) ->
    Now = erlang:system_time(second),
    maps:filter(
        fun(_ServerName, #session_ticket{received_at = ReceivedAt, lifetime = Lifetime}) ->
            (Now - ReceivedAt) =< Lifetime
        end,
        Store
    ).

%%====================================================================
%% PSK Derivation
%%====================================================================

%% @doc Derive the resumption_master_secret from the master secret.
%% RFC 8446 Section 7.1:
%%   resumption_master_secret = Derive-Secret(Master Secret, "res master", ClientHello..client Finished)
-spec derive_resumption_secret(atom(), binary(), binary(), binary()) -> binary().
derive_resumption_secret(Cipher, MasterSecret, TranscriptHash, _ClientFinished) ->
    Hash = quic_crypto:cipher_to_hash(Cipher),
    quic_crypto:derive_secret(Hash, MasterSecret, <<"res master">>, TranscriptHash).

%% @doc Derive PSK from resumption_master_secret and ticket nonce.
%% RFC 8446 Section 4.6.1:
%%   PSK = HKDF-Expand-Label(resumption_master_secret, "resumption", ticket_nonce, Hash.length)
-spec derive_psk(binary(), #session_ticket{}) -> binary().
derive_psk(ResumptionSecret, #session_ticket{nonce = Nonce, cipher = Cipher}) ->
    Hash = quic_crypto:cipher_to_hash(Cipher),
    HashLen = quic_crypto:hash_len(Hash),
    quic_hkdf:expand_label(Hash, ResumptionSecret, <<"resumption">>, Nonce, HashLen).

%%====================================================================
%% Ticket Parsing
%%====================================================================

%% @doc Parse a NewSessionTicket message from the server.
%% RFC 8446 Section 4.6.1:
%%   struct {
%%       uint32 ticket_lifetime;
%%       uint32 ticket_age_add;
%%       opaque ticket_nonce&lt;0..255&gt;;
%%       opaque ticket&lt;1..2^16-1&gt;;
%%       Extension extensions&lt;0..2^16-2&gt;;
%%   } NewSessionTicket;
-spec parse_new_session_ticket(binary()) ->
    {ok, #{
        lifetime := non_neg_integer(),
        age_add := non_neg_integer(),
        nonce := binary(),
        ticket := binary(),
        max_early_data := non_neg_integer()
    }}
    | {error, term()}.
parse_new_session_ticket(<<Lifetime:32, AgeAdd:32, NonceLen, Rest/binary>>) ->
    case Rest of
        <<Nonce:NonceLen/binary, TicketLen:16, Rest1/binary>> when byte_size(Rest1) >= TicketLen ->
            <<Ticket:TicketLen/binary, ExtLen:16, Extensions/binary>> = Rest1,
            case byte_size(Extensions) >= ExtLen of
                true ->
                    <<ExtData:ExtLen/binary, _/binary>> = Extensions,
                    MaxEarlyData = parse_early_data_extension(ExtData),
                    {ok, #{
                        lifetime => Lifetime,
                        age_add => AgeAdd,
                        nonce => Nonce,
                        ticket => Ticket,
                        max_early_data => MaxEarlyData
                    }};
                false ->
                    {error, invalid_extensions}
            end;
        _ ->
            {error, invalid_ticket}
    end;
parse_new_session_ticket(_) ->
    {error, invalid_format}.

%% Parse early_data extension from NewSessionTicket
%% Extension type 42 (0x002a) = early_data
parse_early_data_extension(<<>>) ->
    0;
parse_early_data_extension(<<16#00, 16#2a, 4:16, MaxEarlyData:32, _Rest/binary>>) ->
    MaxEarlyData;
parse_early_data_extension(<<_Type:16, Len:16, _Data:Len/binary, Rest/binary>>) ->
    parse_early_data_extension(Rest);
parse_early_data_extension(_) ->
    0.

%%====================================================================
%% Ticket Creation (for server use)
%%====================================================================

%% @doc Create a session ticket from connection state.
%% This is used by the server to issue tickets to clients.
-spec create_ticket(binary(), binary(), non_neg_integer(), atom(), binary() | undefined) ->
    #session_ticket{}.
create_ticket(ServerName, ResumptionSecret, MaxEarlyData, Cipher, ALPN) ->
    %% Use crypto:strong_rand_bytes for age_add to prevent replay attacks
    <<AgeAdd:32>> = crypto:strong_rand_bytes(4),
    #session_ticket{
        server_name = ServerName,
        ticket = crypto:strong_rand_bytes(32),
        % 24 hours
        lifetime = 86400,
        age_add = AgeAdd,
        nonce = crypto:strong_rand_bytes(8),
        resumption_secret = ResumptionSecret,
        max_early_data = MaxEarlyData,
        received_at = erlang:system_time(second),
        cipher = Cipher,
        alpn = ALPN
    }.

%% @doc Build a NewSessionTicket message.
-spec build_new_session_ticket(#session_ticket{}) -> binary().
build_new_session_ticket(#session_ticket{
    lifetime = Lifetime,
    age_add = AgeAdd,
    nonce = Nonce,
    ticket = Ticket,
    max_early_data = MaxEarlyData
}) ->
    NonceLen = byte_size(Nonce),
    TicketLen = byte_size(Ticket),

    %% Build early_data extension if max_early_data > 0
    %% QUIC requires the wire value to be 0xffffffff (RFC 9001 Section 4.6.1).
    Extensions =
        case MaxEarlyData of
            0 -> <<>>;
            _ -> <<16#00, 16#2a, 4:16, ?QUIC_MAX_EARLY_DATA_SIZE:32>>
        end,
    ExtLen = byte_size(Extensions),

    <<Lifetime:32, AgeAdd:32, NonceLen, Nonce/binary, TicketLen:16, Ticket/binary, ExtLen:16,
        Extensions/binary>>.

%%====================================================================
%% Issued-ticket store (ETS, one per listener)
%%
%% Shared by the connections of one listener, so a server can resume a
%% session it issued on a different connection. Side-effecting: these
%% read the clock, use the random source and mutate a public table.
%%====================================================================

%% Ticket TTL: 7 days in milliseconds (RFC 8446 recommends max 7 days)
-define(TICKET_TTL_MS, 7 * 24 * 60 * 60 * 1000).
%% Max tickets to store (prevents unbounded memory growth)
-define(MAX_TICKETS, 10000).

%% @doc Store a ticket this server issued in its listener's table.
-spec store_issued(ets:table(), session_ticket()) -> true.
store_issued(Tab, #session_ticket{ticket = Identity} = Ticket) ->
    Now = erlang:monotonic_time(millisecond),
    %% Cleanup expired tickets periodically (1 in 100 chance on insert)
    case rand:uniform(100) of
        1 -> cleanup_expired(Tab, Now);
        _ -> ok
    end,
    case ets:info(Tab, size) >= ?MAX_TICKETS of
        true -> evict_one(Tab);
        false -> ok
    end,
    ets:insert(Tab, {Identity, Ticket, Now}).

%% @doc Look an issued ticket up, dropping it if expired.
-spec lookup_issued(ets:table(), binary()) -> {ok, session_ticket()} | error.
lookup_issued(Tab, Identity) ->
    unexpired(Identity, ets:lookup(Tab, Identity), Tab).

%% @doc Remove an issued ticket and return it. Tickets are single-use
%% (RFC 9001 Section 9.2); of two handshakes presenting the same ticket
%% only one gets it.
-spec take_issued(ets:table(), binary()) -> {ok, session_ticket()} | error.
take_issued(Tab, Identity) ->
    unexpired(Identity, ets:take(Tab, Identity), Tab).

unexpired(Identity, [{_, Ticket, StoredAt}], Tab) ->
    case erlang:monotonic_time(millisecond) - StoredAt > ?TICKET_TTL_MS of
        true ->
            ets:delete(Tab, Identity),
            error;
        false ->
            {ok, Ticket}
    end;
unexpired(_Identity, [], _Tab) ->
    error.

cleanup_expired(Tab, Now) ->
    ets:select_delete(Tab, [
        {{'_', '_', '$1'}, [{'<', '$1', {const, Now - ?TICKET_TTL_MS}}], [true]}
    ]).

evict_one(Tab) ->
    case ets:first(Tab) of
        '$end_of_table' -> ok;
        Key -> ets:delete(Tab, Key)
    end.
