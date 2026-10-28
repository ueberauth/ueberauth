%%% -*- erlang -*-
%%%
%%% QUIC Application
%%% RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%
%%% @doc QUIC application behaviour.
%%%
%%% This module implements the OTP application behaviour for the QUIC
%%% library, providing supervision and lifecycle management for multi-pool
%%% server support.

-module(quic_app).
-behaviour(application).

-export([
    start/2,
    stop/1
]).

%%====================================================================
%% Application callbacks
%%====================================================================

%% @doc Start the QUIC application.
%% Creates the top-level supervision tree for multi-pool server support.
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    quic_sup:start_link().

%% @doc Stop the QUIC application.
-spec stop(term()) -> ok.
stop(_State) ->
    ok.
