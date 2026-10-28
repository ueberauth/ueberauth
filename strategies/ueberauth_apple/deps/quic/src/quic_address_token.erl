%%% -*- erlang -*-
%%%
%%% Opaque, HMAC-signed address validation tokens for RFC 9000 §8.1.
%%%
%%% Two shapes share the same wire format so the server can
%%% distinguish them from a single Token field in the client's
%%% Initial packet:
%%%
%%%   retry:     <<1, IPTag, IP, Port:16, Ts:64, ODCIDLen, ODCID, HMAC:16>>
%%%   new_token: <<2, IPTag, IP, Port:16, Ts:64,                  HMAC:16>>
%%%
%%% The HMAC is SHA-256 over all preceding bytes, keyed by the
%%% server-wide token secret, truncated to 16 bytes.

-module(quic_address_token).

-export([
    encode_retry/4,
    encode_new_token/3,
    decode/2,
    validate/2
]).

-type addr() :: {inet:ip_address(), inet:port_number()}.
-type kind() :: retry | new_token.

-define(KIND_RETRY, 1).
-define(KIND_NEW_TOKEN, 2).
-define(HMAC_LEN, 16).
-define(DEFAULT_MAX_AGE_MS, 600000).

-export_type([kind/0, addr/0]).

%% @doc Encode a retry token binding a client address, timestamp, and
%% the original DCID from the Initial that triggered the retry.
-spec encode_retry(binary(), addr(), binary(), non_neg_integer()) -> binary().
encode_retry(Secret, Addr, ODCID, Ts) ->
    Body = <<
        ?KIND_RETRY,
        (encode_addr(Addr))/binary,
        Ts:64,
        (byte_size(ODCID)):8,
        ODCID/binary
    >>,
    <<Body/binary, (sign(Secret, Body))/binary>>.

%% @doc Encode a NEW_TOKEN for a client address.
-spec encode_new_token(binary(), addr(), non_neg_integer()) -> binary().
encode_new_token(Secret, Addr, Ts) ->
    Body = <<?KIND_NEW_TOKEN, (encode_addr(Addr))/binary, Ts:64>>,
    <<Body/binary, (sign(Secret, Body))/binary>>.

%% @doc Decode a token envelope. Returns the kind, bound address,
%% timestamp, and (for retries) the original DCID. Signature is NOT
%% verified here; callers pass the result through validate/3.
-spec decode(binary(), binary()) ->
    {ok, #{
        kind := kind(),
        addr := addr(),
        ts := non_neg_integer(),
        odcid := binary() | undefined
    }}
    | {error, term()}.
decode(Secret, Token) ->
    try
        do_decode(Secret, Token)
    catch
        _:_ -> {error, malformed_token}
    end.

do_decode(_Secret, Token) when byte_size(Token) < ?HMAC_LEN + 12 ->
    {error, too_short};
do_decode(Secret, Token) ->
    BodyLen = byte_size(Token) - ?HMAC_LEN,
    <<Body:BodyLen/binary, Sig:?HMAC_LEN/binary>> = Token,
    %% Constant-time compare: the HMAC is the only thing preventing token
    %% forgery, so don't leak a byte-position oracle.
    case crypto:hash_equals(sign(Secret, Body), Sig) of
        true -> parse_body(Body);
        false -> {error, signature_mismatch}
    end.

parse_body(<<?KIND_RETRY, Rest/binary>>) ->
    {Addr, Rest1} = decode_addr(Rest),
    <<Ts:64, ODCIDLen:8, ODCID:ODCIDLen/binary>> = Rest1,
    {ok, #{kind => retry, addr => Addr, ts => Ts, odcid => ODCID}};
parse_body(<<?KIND_NEW_TOKEN, Rest/binary>>) ->
    {Addr, Rest1} = decode_addr(Rest),
    <<Ts:64>> = Rest1,
    {ok, #{kind => new_token, addr => Addr, ts => Ts, odcid => undefined}}.

%% @doc Validate a decoded token: the signature must match (checked in
%% decode/2) and the timestamp must be within `max_age_ms' of now. The
%% address is checked by the listener against the current source. The
%% retry token's ODCID is NOT compared here — it carries the client's
%% original DCID so the server can recover it for the
%% original_destination_connection_id transport param (RFC 9000 §7.3),
%% not to be matched against the retried Initial's DCID.
-spec validate(map(), #{max_age_ms => non_neg_integer()}) -> ok | {error, term()}.
validate(#{ts := Ts}, Opts) ->
    MaxAgeMs = maps:get(max_age_ms, Opts, ?DEFAULT_MAX_AGE_MS),
    NowMs = erlang:system_time(millisecond),
    Age = NowMs - Ts,
    check_age(Age, MaxAgeMs).

check_age(Age, _) when Age < 0 -> {error, token_from_future};
check_age(Age, MaxAgeMs) when Age > MaxAgeMs -> {error, token_expired};
check_age(_, _) -> ok.

%%====================================================================
%% Internal
%%====================================================================

sign(Secret, Body) ->
    <<Sig:?HMAC_LEN/binary, _/binary>> = crypto:mac(hmac, sha256, token_key(Secret), Body),
    Sig.

%% Domain-separate the address-token key from the stateless-reset-token
%% key, which share the same server secret. Derived internally so all
%% encode/decode paths stay consistent without changing callers.
token_key(Secret) ->
    crypto:mac(hmac, sha256, Secret, <<"quic address validation token v1">>).

encode_addr({{A, B, C, D}, Port}) ->
    <<4:8, A:8, B:8, C:8, D:8, Port:16>>;
encode_addr({{A, B, C, D, E, F, G, H}, Port}) ->
    <<16:8, A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16, Port:16>>.

decode_addr(<<4:8, A:8, B:8, C:8, D:8, Port:16, Rest/binary>>) ->
    {{{A, B, C, D}, Port}, Rest};
decode_addr(<<16:8, A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16, Port:16, Rest/binary>>) ->
    {{{A, B, C, D, E, F, G, H}, Port}, Rest}.
