%%% -*- erlang -*-
%%%
%%% RFC 9297 §3.2 Capsule Protocol codec.
%%%
%%% A capsule is a reliable framed unit carried on the body of an
%%% extended-CONNECT request stream, distinct from the unreliable HTTP
%%% Datagrams delivered via `quic_h3:send_datagram/3'. The wire format
%%% is simply `Type (varint) | Length (varint) | Value`.
%%%
%%% We expose encode/2 and decode/1 as low-level primitives. Higher
%%% layers (for instance a CONNECT-UDP implementation built on top of
%%% RFC 9297) drive the codec themselves by buffering stream body bytes
%%% and feeding them to `decode/1' until it returns `{more, N}'.
%%%
%%% Nothing inside this library calls it: the codec exists for
%%% extension libraries. `erlang_masque' wraps it as `masque_capsule',
%%% and the wire format is identical to `h1_capsule' and `h2_capsule',
%%% so the same capsule stream can be framed over HTTP/1, HTTP/2 or
%%% HTTP/3 without reframing.

-module(quic_h3_capsule).

-export([encode/2, decode/1]).

-type capsule_type() :: non_neg_integer().
-type capsule_value() :: binary().
-export_type([capsule_type/0, capsule_value/0]).

%% @doc Encode a capsule as an iolist.
-spec encode(capsule_type(), iodata()) -> iodata().
encode(Type, Value) when is_integer(Type), Type >= 0 ->
    ValueBin = iolist_to_binary(Value),
    TypeEnc = quic_varint:encode(Type),
    LenEnc = quic_varint:encode(byte_size(ValueBin)),
    [TypeEnc, LenEnc, ValueBin].

%% @doc Decode a single capsule from the head of a binary.
%%
%% Returns `{ok, {Type, Value, Rest}}' when a complete capsule is
%% available, or `{more, Needed}' when more bytes are needed. `Needed'
%% is exact only when the value itself is short: it is 1 whenever the
%% type or length varint is still incomplete, so treat it as a hint and
%% keep feeding bytes rather than waiting for exactly that many.
%%
%% A peer can announce a length of up to 2^62-1, which yields
%% `{more, Huge}' rather than an error, so bound the buffer yourself.
%%
%% `{error, malformed_varint}' is defensive. Both empty-binary cases are
%% intercepted first, so for any binary input decode/1 returns only
%% `{ok, _}' or `{more, _}'.
-spec decode(binary()) ->
    {ok, {capsule_type(), capsule_value(), binary()}}
    | {more, non_neg_integer()}
    | {error, term()}.
decode(<<>>) ->
    {more, 1};
decode(Bin) ->
    try
        {Type, Rest1} = quic_varint:decode(Bin),
        case Rest1 of
            <<>> ->
                {more, 1};
            _ ->
                {Len, Rest2} = quic_varint:decode(Rest1),
                case Rest2 of
                    <<Value:Len/binary, Rest3/binary>> ->
                        {ok, {Type, Value, Rest3}};
                    _ ->
                        {more, max(0, Len - byte_size(Rest2))}
                end
        end
    catch
        error:{incomplete, _} -> {more, 1};
        error:badarg -> {error, malformed_varint}
    end.
