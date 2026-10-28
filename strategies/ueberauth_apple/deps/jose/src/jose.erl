%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  20 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose).

%% API
-export([chacha20_poly1305_module/0]).
-export([chacha20_poly1305_module/1]).
-export([crypto_fallback/0]).
-export([crypto_fallback/1]).
-export([curve25519_module/0]).
-export([curve25519_module/1]).
-export([curve448_module/0]).
-export([curve448_module/1]).
-export([decode/1]).
-export([encode/1]).
-export([json_module/0]).
-export([json_module/1]).
-export([pbes2_count_maximum/0]).
-export([pbes2_count_maximum/1]).
-export([sha3_module/0]).
-export([sha3_module/1]).
-export([unsecured_signing/0]).
-export([unsecured_signing/1]).
-export([xchacha20_poly1305_module/0]).
-export([xchacha20_poly1305_module/1]).
-export([zip_size_maximum/0]).
-export([zip_size_maximum/1]).
%% Private API
-export([start/0]).

-define(TAB, jose_jwa).

-define(MAYBE_START_JOSE(F), try
	F
catch
	_:_ ->
		_ = jose:start(),
		F
end).

%%====================================================================
%% API functions
%%====================================================================

chacha20_poly1305_module() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, chacha20_poly1305_module, 2)).

chacha20_poly1305_module(ChaCha20Poly1305Module) when is_atom(ChaCha20Poly1305Module) ->
	?MAYBE_START_JOSE(jose_server:chacha20_poly1305_module(ChaCha20Poly1305Module)).

crypto_fallback() ->
	jose_jwa:crypto_fallback().

crypto_fallback(Boolean) when is_boolean(Boolean) ->
	jose_jwa:crypto_fallback(Boolean).

curve25519_module() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, curve25519_module, 2)).

curve25519_module(Curve25519Module) when is_atom(Curve25519Module) ->
	?MAYBE_START_JOSE(jose_server:curve25519_module(Curve25519Module)).

curve448_module() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, curve448_module, 2)).

curve448_module(Curve448Module) when is_atom(Curve448Module) ->
	?MAYBE_START_JOSE(jose_server:curve448_module(Curve448Module)).

decode(Binary) ->
	JSONModule = json_module(),
	JSONModule:decode(Binary).

encode(Term) ->
	JSONModule = json_module(),
	JSONModule:encode(Term).

json_module() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, json_module, 2)).

json_module(JSONModule) when is_atom(JSONModule) ->
	?MAYBE_START_JOSE(jose_server:json_module(JSONModule)).

-spec pbes2_count_maximum() -> non_neg_integer().
pbes2_count_maximum() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, pbes2_count_maximum, 2)).

-spec pbes2_count_maximum(PBES2CountMaximum) -> ok when PBES2CountMaximum :: non_neg_integer().
pbes2_count_maximum(PBES2CountMaximum) when is_integer(PBES2CountMaximum) andalso PBES2CountMaximum >= 0 ->
	?MAYBE_START_JOSE(jose_server:pbes2_count_maximum(PBES2CountMaximum)).

sha3_module() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, sha3_module, 2)).

sha3_module(SHA3Module) when is_atom(SHA3Module) ->
	?MAYBE_START_JOSE(jose_server:sha3_module(SHA3Module)).

-spec unsecured_signing() -> boolean().
unsecured_signing() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, unsecured_signing, 2)).

-spec unsecured_signing(UnsecuredSigning) -> ok when UnsecuredSigning :: boolean().
unsecured_signing(UnsecuredSigning) when is_boolean(UnsecuredSigning) ->
	?MAYBE_START_JOSE(jose_server:unsecured_signing(UnsecuredSigning)).

xchacha20_poly1305_module() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, xchacha20_poly1305_module, 2)).

xchacha20_poly1305_module(XChaCha20Poly1305Module) when is_atom(XChaCha20Poly1305Module) ->
	?MAYBE_START_JOSE(jose_server:xchacha20_poly1305_module(XChaCha20Poly1305Module)).

-spec zip_size_maximum() -> non_neg_integer().
zip_size_maximum() ->
	?MAYBE_START_JOSE(ets:lookup_element(?TAB, zip_size_maximum, 2)).

-spec zip_size_maximum(ZipSizeMaximum) -> ok when ZipSizeMaximum :: non_neg_integer().
zip_size_maximum(ZipSizeMaximum) when is_integer(ZipSizeMaximum) andalso ZipSizeMaximum >= 0 ->
	?MAYBE_START_JOSE(jose_server:zip_size_maximum(ZipSizeMaximum)).

%%====================================================================
%% Private API functions
%%====================================================================

start() ->
	case application:ensure_all_started(?MODULE) of
		{ok, _} ->
			ok;
		StartError ->
			StartError
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
