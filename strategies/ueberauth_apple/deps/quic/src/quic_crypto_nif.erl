%%% -*- erlang -*-
%%%
%%% Loader/stubs for the optional AEAD context NIF (c_src/quic_crypto_nif.c).
%%%
%%% The NIF is a pure accelerator: when the shared object is missing
%%% or fails to load, `is_loaded/0' stays `false' and quic_crypto
%%% falls back to the OTP crypto one-shot API, so the library keeps
%%% working without a C toolchain.

-module(quic_crypto_nif).

-export([
    is_loaded/0,
    new_aead_ctx/3,
    new_hp_ctx/2,
    seal/4,
    open/5,
    hp_block/2,
    protect_run/7,
    open_packet/7,
    open_run/7
]).

-nifs([
    is_loaded/0,
    new_aead_ctx/3,
    new_hp_ctx/2,
    seal/4,
    open/5,
    hp_block/2,
    protect_run/7,
    open_packet/7,
    open_run/7
]).
-on_load(load/0).

%% Never fails: an on_load that returns anything but ok makes the
%% module unloadable, and every caller then dies with undef instead of
%% taking the pure-Erlang path. code:priv_dir/1 answers {error, _} when
%% the app is not resolvable (an escript bundle, a bare code path), so
%% it has to be matched rather than passed to filename:join/2.
load() ->
    case nif_disabled() of
        true ->
            %% Opt-out: stubs below stay in place; is_loaded/0 returns
            %% false and quic_crypto uses OTP crypto.
            ok;
        false ->
            case code:priv_dir(quic) of
                {error, _} ->
                    ok;
                Dir ->
                    _ = erlang:load_nif(filename:join(Dir, "quic_crypto_nif"), 0),
                    ok
            end
    end.

%% Runtime opt-out for benchmarking and fault isolation, read once at
%% module load: QUIC_DISABLE_CRYPTO_NIF=1 disables this NIF alone,
%% QUIC_DISABLE_NIFS=1 disables every optional NIF.
nif_disabled() ->
    env_true("QUIC_DISABLE_CRYPTO_NIF") orelse env_true("QUIC_DISABLE_NIFS").

env_true(Var) ->
    case os:getenv(Var) of
        "1" -> true;
        "true" -> true;
        _ -> false
    end.

-spec is_loaded() -> boolean().
is_loaded() -> false.

%% The stubs raise (none() success typing) so dialyzer takes the specs
%% below as the NIF return types. They are unreachable in practice:
%% every caller gates on is_loaded/0 first.
-spec new_aead_ctx(atom(), binary(), boolean()) -> {ok, reference()} | {error, atom()}.
new_aead_ctx(_Cipher, _Key, _Enc) -> erlang:nif_error(not_loaded).
-spec new_hp_ctx(atom(), binary()) -> {ok, reference()} | {error, atom()}.
new_hp_ctx(_Cipher, _Key) -> erlang:nif_error(not_loaded).
-spec seal(reference(), binary(), iodata(), iodata()) -> binary() | {error, atom()}.
seal(_Ctx, _Nonce, _AAD, _Plain) -> erlang:nif_error(not_loaded).
-spec open(reference(), binary(), iodata(), iodata(), binary()) ->
    binary() | error | {error, atom()}.
open(_Ctx, _Nonce, _AAD, _CipherText, _Tag) -> erlang:nif_error(not_loaded).
-spec hp_block(reference(), binary()) -> binary() | {error, atom()}.
hp_block(_Ctx, _Sample) -> erlang:nif_error(not_loaded).
-spec protect_run(
    reference(), reference(), binary(), non_neg_integer(), byte(), iodata(), [iodata()]
) -> [binary()] | {error, atom()}.
protect_run(_AeadCtx, _HpCtx, _IV, _PN0, _FirstByteBase, _DCID, _Payloads) ->
    erlang:nif_error(not_loaded).
-spec open_packet(
    reference(), reference(), binary(), integer(), 0 | 1, binary(), binary()
) -> {non_neg_integer(), byte(), binary()} | error | key_phase | {error, atom()}.
open_packet(_AeadCtx, _HpCtx, _IV, _LargestRecv, _ExpectedPhase, _Header, _EncPayload) ->
    erlang:nif_error(not_loaded).
-spec open_run(
    reference(), reference(), binary(), integer(), 0 | 1, non_neg_integer(), [binary()]
) -> {ok, [{non_neg_integer(), byte(), [term()] | {raw, binary()}}]} | {error, atom()}.
open_run(_AeadCtx, _HpCtx, _IV, _LargestRecv, _ExpectedPhase, _DcidLen, _Datagrams) ->
    erlang:nif_error(not_loaded).
