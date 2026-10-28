%%% -*- erlang -*-
%%%
%%% HKDF Implementation for QUIC
%%% RFC 5869 - HMAC-based Extract-and-Expand Key Derivation Function
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc HKDF implementation for QUIC key derivation.
%%%
%%% HKDF is used in QUIC/TLS 1.3 for deriving keys from shared secrets.
%%% This module implements the Extract-Expand paradigm with SHA-256.
%%%

-module(quic_hkdf).

-export([
    extract/2,
    extract/3,
    expand/3,
    expand/4,
    expand_label/4,
    expand_label/5
]).

% SHA-256 output length
-define(HASH_LEN, 32).

%%====================================================================
%% API
%%====================================================================

%% @doc HKDF-Extract using SHA-256.
%% Extracts a pseudorandom key from input keying material.
%% Salt defaults to a string of HashLen zeros if not provided.
-spec extract(binary(), binary()) -> binary().
extract(Salt, IKM) ->
    extract(sha256, Salt, IKM).

%% @doc HKDF-Extract with specified hash algorithm.
-spec extract(atom(), binary(), binary()) -> binary().
extract(Hash, <<>>, IKM) ->
    %% RFC 5869: if salt is not provided, use HashLen zeros
    ZeroSalt = binary:copy(<<0>>, quic_crypto:hash_len(Hash)),
    crypto:mac(hmac, Hash, ZeroSalt, IKM);
extract(Hash, Salt, IKM) ->
    crypto:mac(hmac, Hash, Salt, IKM).

%% @doc HKDF-Expand using SHA-256.
%% Expands a pseudorandom key to the desired length.
-spec expand(binary(), binary(), non_neg_integer()) -> binary().
expand(PRK, Info, Length) ->
    expand(sha256, PRK, Info, Length).

%% @doc HKDF-Expand with specified hash algorithm.
-spec expand(atom(), binary(), binary(), non_neg_integer()) -> binary().
expand(_Hash, _PRK, _Info, 0) ->
    <<>>;
expand(Hash, PRK, Info, Length) ->
    HashLen = quic_crypto:hash_len(Hash),
    MaxLen = 255 * HashLen,
    % Assert valid length
    true = Length =< MaxLen,
    N = ceiling(Length, HashLen),
    FullOutput = expand_loop(Hash, PRK, Info, N, 1, <<>>, <<>>),
    %% Truncate to requested length
    binary:part(FullOutput, 0, Length).

%% @doc HKDF-Expand-Label for TLS 1.3/QUIC.
%% Label format: "tls13 " ++ Label
%% Context is the additional info (often empty for QUIC).
-spec expand_label(binary(), binary(), binary(), non_neg_integer()) -> binary().
expand_label(Secret, Label, Context, Length) ->
    expand_label(sha256, Secret, Label, Context, Length).

%% @doc HKDF-Expand-Label with specified hash algorithm.
%% Implements TLS 1.3 HKDF-Expand-Label (RFC 8446 Section 7.1)
-spec expand_label(atom(), binary(), binary(), binary(), non_neg_integer()) -> binary().
expand_label(Hash, Secret, Label, Context, Length) ->
    %% HkdfLabel structure:
    %% uint16 length = Length;
    %% opaque label<7..255> = "tls13 " + Label;
    %% opaque context<0..255> = Context;
    FullLabel = <<"tls13 ", Label/binary>>,
    LabelLen = byte_size(FullLabel),
    ContextLen = byte_size(Context),
    HkdfLabel = <<Length:16, LabelLen, FullLabel/binary, ContextLen, Context/binary>>,
    expand(Hash, Secret, HkdfLabel, Length).

%%====================================================================
%% Internal Functions
%%====================================================================

expand_loop(_Hash, _PRK, _Info, N, I, _Prev, Acc) when I > N ->
    Acc;
expand_loop(Hash, PRK, Info, N, I, Prev, Acc) ->
    %% T(i) = HMAC-Hash(PRK, T(i-1) | info | i)
    T = crypto:mac(hmac, Hash, PRK, <<Prev/binary, Info/binary, I>>),
    expand_loop(Hash, PRK, Info, N, I + 1, T, <<Acc/binary, T/binary>>).

ceiling(X, Y) ->
    (X + Y - 1) div Y.
