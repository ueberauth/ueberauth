%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  21 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk).

-include("jose_jwe.hrl").
-include("jose_jwk.hrl").
-include("jose_jws.hrl").

-callback from_map(Fields) -> KTY
	when
		Fields :: map(),
		KTY    :: any().
-callback to_key(KTY) -> Key
	when
		KTY :: any(),
		Key :: any().
-callback to_map(KTY, Fields) -> Map
	when
		KTY    :: any(),
		Fields :: map(),
		Map    :: map().
-callback to_public_map(KTY, Fields) -> Map
	when
		KTY    :: any(),
		Fields :: map(),
		Map    :: map().
-callback to_thumbprint_map(KTY, Fields) -> Map
	when
		KTY    :: any(),
		Fields :: map(),
		Map    :: map().

%% Decode API
-export([from/1]).
-export([from/2]).
-export([from_binary/1]).
-export([from_binary/2]).
-export([from_der/1]).
-export([from_der/2]).
-export([from_der_file/1]).
-export([from_der_file/2]).
-export([from_file/1]).
-export([from_file/2]).
-export([from_firebase/1]).
-export([from_key/1]).
-export([from_map/1]).
-export([from_map/2]).
-export([from_oct/1]).
-export([from_oct/2]).
-export([from_oct_file/1]).
-export([from_oct_file/2]).
-export([from_okp/1]).
-export([from_openssh_key/1]).
-export([from_openssh_key_file/1]).
-export([from_pem/1]).
-export([from_pem/2]).
-export([from_pem_file/1]).
-export([from_pem_file/2]).
%% Encode API
-export([to_binary/1]).
-export([to_binary/2]).
-export([to_binary/3]).
-export([to_der/1]).
-export([to_der/2]).
-export([to_der_file/2]).
-export([to_der_file/3]).
-export([to_file/2]).
-export([to_file/3]).
-export([to_file/4]).
-export([to_key/1]).
-export([to_map/1]).
-export([to_map/2]).
-export([to_map/3]).
-export([to_oct/1]).
-export([to_oct/2]).
-export([to_oct/3]).
-export([to_oct_file/2]).
-export([to_oct_file/3]).
-export([to_oct_file/4]).
-export([to_okp/1]).
-export([to_openssh_key/1]).
-export([to_openssh_key_file/2]).
-export([to_pem/1]).
-export([to_pem/2]).
-export([to_pem_file/2]).
-export([to_pem_file/3]).
-export([to_public/1]).
-export([to_public_file/2]).
-export([to_public_key/1]).
-export([to_public_map/1]).
-export([to_thumbprint_map/1]).
%% API
-export([block_decrypt/2]).
-export([block_encrypt/2]).
-export([block_encrypt/3]).
-export([block_encryptor/1]).
-export([box_decrypt/2]).
-export([box_encrypt/2]).
-export([box_encrypt/3]).
-export([box_encrypt/4]).
-deprecated([{box_decrypt, 2, next_major_release}]).
-deprecated([{box_encrypt, 2, next_major_release}]).
-deprecated([{box_encrypt, 3, next_major_release}]).
-deprecated([{box_encrypt, 4, next_major_release}]).
-export([box_decrypt_ecdh_1pu/3]).
-export([box_encrypt_ecdh_1pu/3]).
-export([box_encrypt_ecdh_1pu/4]).
-export([box_encrypt_ecdh_1pu/5]).
-export([box_decrypt_ecdh_es/2]).
-export([box_encrypt_ecdh_es/2]).
-export([box_encrypt_ecdh_es/3]).
-export([box_encrypt_ecdh_es/4]).
-export([box_decrypt_ecdh_ss/2]).
-export([box_encrypt_ecdh_ss/2]).
-export([box_encrypt_ecdh_ss/3]).
-export([box_encrypt_ecdh_ss/4]).
-export([generate_key/1]).
-export([merge/2]).
-export([shared_secret/2]).
-export([sign/2]).
-export([sign/3]).
-export([signer/1]).
-export([thumbprint/1]).
-export([thumbprint/2]).
-export([thumbprint_concat/1]).
-export([thumbprint_concat/2]).
-export([verifier/1]).
-export([verify/2]).
-export([verify_strict/3]).

%% Types
-type key() :: #jose_jwk{}.

-export_type([key/0]).

-define(KEYS_MODULE,    jose_jwk_set).
-define(KTY_EC_MODULE,  jose_jwk_kty_ec).
-define(KTY_OCT_MODULE, jose_jwk_kty_oct).
-define(KTY_RSA_MODULE, jose_jwk_kty_rsa).

-define(KTY_OKP_Ed25519_MODULE,   jose_jwk_kty_okp_ed25519).
-define(KTY_OKP_Ed25519ph_MODULE, jose_jwk_kty_okp_ed25519ph).
-define(KTY_OKP_X25519_MODULE,    jose_jwk_kty_okp_x25519).
-define(KTY_OKP_Ed448_MODULE,     jose_jwk_kty_okp_ed448).
-define(KTY_OKP_Ed448ph_MODULE,   jose_jwk_kty_okp_ed448ph).
-define(KTY_OKP_X448_MODULE,      jose_jwk_kty_okp_x448).

%%====================================================================
%% Decode API functions
%%====================================================================

from(List) when is_list(List) ->
	[from(Element) || Element <- List];
from({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({Modules, Map});
from({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	from_binary({Modules, Binary});
from(JWK=#jose_jwk{}) ->
	JWK;
from(Other) when is_map(Other) orelse is_binary(Other) ->
	from({#{}, Other}).

from(Key, List) when is_list(List) ->
	[from(Key, Element) || Element <- List];
from(Key, {Modules, EncryptedMap}) when is_map(Modules) andalso is_map(EncryptedMap) ->
	from_map(Key, {Modules, EncryptedMap});
from(Key, {Modules, EncryptedBinary}) when is_map(Modules) andalso is_binary(EncryptedBinary) ->
	from_binary(Key, {Modules, EncryptedBinary});
from(_Key, JWK=#jose_jwk{}) ->
	JWK;
from(Key, Other) when is_map(Other) orelse is_binary(Other) ->
	from(Key, {#{}, Other}).

from_binary(List) when is_list(List) ->
	[from_binary(Element) || Element <- List];
from_binary({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	from_map({Modules, jose:decode(Binary)});
from_binary(Binary) when is_binary(Binary) ->
	from_binary({#{}, Binary}).

from_binary(Key, List) when is_list(List) ->
	[from_binary(Key, Element) || Element <- List];
from_binary(Key, {Modules, Encrypted = << ${, _/binary >>}) when is_map(Modules) andalso is_binary(Encrypted) ->
	EncrypedMap = jose:decode(Encrypted),
	from_map(Key, {Modules, EncrypedMap});
from_binary(Key, {Modules, Encrypted}) when is_map(Modules) andalso is_binary(Encrypted) ->
	{JWKBinary, JWE=#jose_jwe{}} = jose_jwe:block_decrypt(Key, {Modules, Encrypted}),
	{JWE, from_binary({Modules, JWKBinary})};
from_binary(Key, Encrypted) when is_binary(Encrypted) ->
	from_binary(Key, {#{}, Encrypted}).

from_der(List) when is_list(List) ->
	[from_der(Element) || Element <- List];
from_der({#{ kty := Module }, Binary}) when is_binary(Binary) ->
	{KTY, Fields} = Module:from_der(Binary),
	#jose_jwk{ kty = {Module, KTY}, fields = Fields };
from_der({#{}, Binary}) when is_binary(Binary) ->
	case jose_jwk_der:from_binary(Binary) of
		{Module, {KTY, Fields}} when Module =/= error ->
			#jose_jwk{ kty = {Module, KTY}, fields = Fields };
		PEMError ->
			PEMError
	end;
from_der(Binary) when is_binary(Binary) ->
	from_der({#{}, Binary}).

from_der(Key, List) when is_list(List) ->
	[from_der(Key, Element) || Element <- List];
from_der(Key, {#{ kty := Module }, Binary}) when is_binary(Binary) ->
	{KTY, Fields} = Module:from_der(Key, Binary),
	#jose_jwk{ kty = {Module, KTY}, fields = Fields };
from_der(Key, {#{}, Binary}) when is_binary(Binary) ->
	case jose_jwk_der:from_binary(Key, Binary) of
		{Module, {KTY, Fields}} when Module =/= error ->
			#jose_jwk{ kty = {Module, KTY}, fields = Fields };
		PEMError ->
			PEMError
	end;
from_der(Key, Binary) when is_binary(Binary) ->
	from_der(Key, {#{}, Binary}).

from_der_file({Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_der({Modules, Binary});
		ReadError ->
			ReadError
	end;
from_der_file(File) when is_binary(File) orelse is_list(File) ->
	from_der_file({#{}, File}).

from_der_file(Key, {Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_der(Key, {Modules, Binary});
		ReadError ->
			ReadError
	end;
from_der_file(Key, File) when is_binary(File) orelse is_list(File) ->
	from_der_file(Key, {#{}, File}).

from_file({Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_binary({Modules, Binary});
		ReadError ->
			ReadError
	end;
from_file(File) when is_binary(File) orelse is_list(File) ->
	from_file({#{}, File}).

from_file(Key, {Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_binary(Key, {Modules, Binary});
		ReadError ->
			ReadError
	end;
from_file(Key, File) when is_binary(File) orelse is_list(File) ->
	from_file(Key, {#{}, File}).

from_firebase(Binary) when is_binary(Binary) ->
	from_firebase({#{}, Binary});
from_firebase({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	Map = jose:decode(Binary),
	from_firebase({Modules, Map});
from_firebase(Map) when is_map(Map) ->
	from_firebase({#{}, Map});
from_firebase({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	Folder = fun (Key, Val, Acc) ->
		JWK = jose_jwk:merge(jose_jwk:from_pem({Modules, Val}), #{ <<"kid">> => Key }),
		maps:put(Key, JWK, Acc)
	end,
	maps:fold(Folder, #{}, Map).

from_key(List) when is_list(List) ->
	[from_key(Element) || Element <- List];
from_key(Key) ->
	case jose_jwk_kty:from_key(Key) of
		{KTYModule, {KTY, Fields}} when KTYModule =/= error ->
			#jose_jwk{ kty = {KTYModule, KTY}, fields = Fields };
		FromKeyError ->
			FromKeyError
	end.

from_map(List) when is_list(List) ->
	[from_map(Element) || Element <- List];
from_map(Map) when is_map(Map) ->
	from_map({#{}, Map});
from_map({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({#jose_jwk{}, Modules, Map});
from_map({JWK, Modules=#{ keys := Module }, Map=#{ <<"keys">> := _ }}) ->
	{KEYS, Fields} = Module:from_map(Map),
	from_map({JWK#jose_jwk{ keys = {Module, KEYS} }, maps:remove(keys, Modules), Fields});
from_map({JWK, Modules=#{ kty := Module }, Map=#{ <<"kty">> := _ }}) ->
	{KTY, Fields} = Module:from_map(Map),
	from_map({JWK#jose_jwk{ kty = {Module, KTY} }, maps:remove(kty, Modules), Fields});
from_map({JWK, Modules, Map=#{ <<"keys">> := _ }}) ->
	from_map({JWK, Modules#{ keys => ?KEYS_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"EC">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_EC_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"oct">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_OCT_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"OKP">>, <<"crv">> := <<"Ed25519">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_OKP_Ed25519_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"OKP">>, <<"crv">> := <<"Ed25519ph">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_OKP_Ed25519ph_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"OKP">>, <<"crv">> := <<"X25519">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_OKP_X25519_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"OKP">>, <<"crv">> := <<"Ed448">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_OKP_Ed448_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"OKP">>, <<"crv">> := <<"Ed448ph">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_OKP_Ed448ph_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"OKP">>, <<"crv">> := <<"X448">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_OKP_X448_MODULE }, Map});
from_map({JWK, Modules, Map=#{ <<"kty">> := <<"RSA">> }}) ->
	from_map({JWK, Modules#{ kty => ?KTY_RSA_MODULE }, Map});
from_map({#jose_jwk{ keys = undefined, kty = undefined }, _Modules, _Map}) ->
	{error, {missing_required_keys, [<<"keys">>, <<"kty">>]}};
from_map({JWK, _Modules, Fields}) ->
	JWK#jose_jwk{ fields = Fields }.

from_map(Key, List) when is_list(List) ->
	[from_map(Key, Element) || Element <- List];
from_map(Key, {Modules, Encrypted}) when is_map(Modules) andalso is_map(Encrypted) ->
	{JWKBinary, JWE=#jose_jwe{}} = jose_jwe:block_decrypt(Key, {Modules, Encrypted}),
	{JWE, from_binary({Modules, JWKBinary})};
from_map(Key, Encrypted) when is_map(Encrypted) ->
	from_map(Key, {#{}, Encrypted}).

from_oct(List) when is_list(List) ->
	[from_oct(Element) || Element <- List];
from_oct({#{ kty := Module }, Binary}) when is_binary(Binary) ->
	{KTY, Fields} = Module:from_oct(Binary),
	#jose_jwk{ kty = {Module, KTY}, fields = Fields };
from_oct({#{}, Binary}) when is_binary(Binary) ->
	case jose_jwk_oct:from_binary(Binary) of
		{Module, {KTY, Fields}} when Module =/= error ->
			#jose_jwk{ kty = {Module, KTY}, fields = Fields };
		OCTError ->
			OCTError
	end;
from_oct(Binary) when is_binary(Binary) ->
	from_oct({#{}, Binary}).

from_oct(Key, List) when is_list(List) ->
	[from_oct(Key, Element) || Element <- List];
from_oct(Key, {Modules, Encrypted}) when is_map(Modules) andalso is_binary(Encrypted) ->
	{OCTBinary, JWE=#jose_jwe{}} = jose_jwe:block_decrypt(Key, {Modules, Encrypted}),
	{JWE, from_oct({Modules, OCTBinary})};
from_oct(Key, Encrypted) when is_binary(Encrypted) ->
	from_oct(Key, {#{}, Encrypted}).

from_oct_file({Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_oct({Modules, Binary});
		ReadError ->
			ReadError
	end;
from_oct_file(File) when is_binary(File) orelse is_list(File) ->
	from_oct_file({#{}, File}).

from_oct_file(Key, {Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_oct(Key, {Modules, Binary});
		ReadError ->
			ReadError
	end;
from_oct_file(Key, File) when is_binary(File) orelse is_list(File) ->
	from_oct_file(Key, {#{}, File}).

from_okp(List) when is_list(List) ->
	[from_okp(Element) || Element <- List];
from_okp({#{ kty := Module }, OKP}) ->
	{KTY, Fields} = Module:from_okp(OKP),
	#jose_jwk{ kty = {Module, KTY}, fields = Fields };
from_okp(P={'Ed25519', Binary}) when is_binary(Binary) ->
	from_okp({#{ kty => ?KTY_OKP_Ed25519_MODULE }, P});
from_okp(P={'Ed25519ph', Binary}) when is_binary(Binary) ->
	from_okp({#{ kty => ?KTY_OKP_Ed25519ph_MODULE }, P});
from_okp(P={'X25519', Binary}) when is_binary(Binary) ->
	from_okp({#{ kty => ?KTY_OKP_X25519_MODULE }, P});
from_okp(P={'Ed448', Binary}) when is_binary(Binary) ->
	from_okp({#{ kty => ?KTY_OKP_Ed448_MODULE }, P});
from_okp(P={'Ed448ph', Binary}) when is_binary(Binary) ->
	from_okp({#{ kty => ?KTY_OKP_Ed448ph_MODULE }, P});
from_okp(P={'X448', Binary}) when is_binary(Binary) ->
	from_okp({#{ kty => ?KTY_OKP_X448_MODULE }, P}).

from_openssh_key(List) when is_list(List) ->
	[from_openssh_key(Element) || Element <- List];
from_openssh_key({#{ kty := Module }, Binary}) when is_binary(Binary) ->
	{KTY, Fields} = Module:from_openssh_key(Binary),
	#jose_jwk{ kty = {Module, KTY}, fields = Fields };
from_openssh_key({#{}, Binary}) when is_binary(Binary) ->
	case jose_jwk_openssh_key:from_binary(Binary) of
		CurrentKey = [[{{Type, PK}, Key = {Type, PK, _SK, _Comment}} | _] | _] ->
			Module = case Type of
				<<"ssh-ed25519">> ->
					?KTY_OKP_Ed25519_MODULE;
				<<"ssh-ed25519ph">> ->
					?KTY_OKP_Ed25519ph_MODULE;
				<<"ssh-x25519">> ->
					?KTY_OKP_X25519_MODULE;
				<<"ssh-ed448">> ->
					?KTY_OKP_Ed448_MODULE;
				<<"ssh-ed448ph">> ->
					?KTY_OKP_Ed448ph_MODULE;
				<<"ssh-x448">> ->
					?KTY_OKP_X448_MODULE;
				_ ->
					{error, {unknown_key, CurrentKey}}
			end,
			case is_atom(Module) of
				true ->
					{KTY, Fields} = Module:from_openssh_key(Key),
					#jose_jwk{ kty = {Module, KTY}, fields = Fields };
				false ->
					Module
			end;
		UnknownKey ->
			{error, {unknown_key, UnknownKey}}
	end;
from_openssh_key(Binary) when is_binary(Binary) ->
	from_openssh_key({#{}, Binary}).

from_openssh_key_file({Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_openssh_key({Modules, Binary});
		ReadError ->
			ReadError
	end;
from_openssh_key_file(File) when is_binary(File) orelse is_list(File) ->
	from_openssh_key_file({#{}, File}).

from_pem(List) when is_list(List) ->
	[from_pem(Element) || Element <- List];
from_pem({#{ kty := Module }, Binary}) when is_binary(Binary) ->
	{KTY, Fields} = Module:from_pem(Binary),
	#jose_jwk{ kty = {Module, KTY}, fields = Fields };
from_pem({#{}, Binary}) when is_binary(Binary) ->
	case jose_jwk_pem:from_binary(Binary) of
		{Module, {KTY, Fields}} when Module =/= error ->
			#jose_jwk{ kty = {Module, KTY}, fields = Fields };
		PEMError ->
			PEMError
	end;
from_pem(Binary) when is_binary(Binary) ->
	from_pem({#{}, Binary}).

from_pem(Key, List) when is_list(List) ->
	[from_pem(Key, Element) || Element <- List];
from_pem(Key, {#{ kty := Module }, Binary}) when is_binary(Binary) ->
	{KTY, Fields} = Module:from_pem(Key, Binary),
	#jose_jwk{ kty = {Module, KTY}, fields = Fields };
from_pem(Key, {#{}, Binary}) when is_binary(Binary) ->
	case jose_jwk_pem:from_binary(Key, Binary) of
		{Module, {KTY, Fields}} when Module =/= error ->
			#jose_jwk{ kty = {Module, KTY}, fields = Fields };
		PEMError ->
			PEMError
	end;
from_pem(Key, Binary) when is_binary(Binary) ->
	from_pem(Key, {#{}, Binary}).

from_pem_file({Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_pem({Modules, Binary});
		ReadError ->
			ReadError
	end;
from_pem_file(File) when is_binary(File) orelse is_list(File) ->
	from_pem_file({#{}, File}).

from_pem_file(Key, {Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_pem(Key, {Modules, Binary});
		ReadError ->
			ReadError
	end;
from_pem_file(Key, File) when is_binary(File) orelse is_list(File) ->
	from_pem_file(Key, {#{}, File}).

%%====================================================================
%% Encode API functions
%%====================================================================

to_binary(List) when is_list(List) ->
	[to_binary(Element) || Element <- List];
to_binary(JWK=#jose_jwk{}) ->
	{Modules, Map} = to_map(JWK),
	{Modules, jose:encode(Map)};
to_binary(Other) ->
	to_binary(from(Other)).

to_binary(Key, List) when is_list(List) ->
	[to_binary(Key, Element) || Element <- List];
to_binary(Key, JWK=#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	to_binary(Key, Module:key_encryptor(KTY, Fields, Key), JWK);
to_binary(Key, Other) ->
	to_binary(Key, from(Other)).

to_binary(Key, JWE=#jose_jwe{}, JWK=#jose_jwk{}) ->
	{Modules, EncryptedMap} = to_map(Key, JWE, JWK),
	{Modules, jose:encode(EncryptedMap)};
to_binary(Key, JWEOther, JWKOther) ->
	to_binary(Key, jose_jwe:from(JWEOther), from(JWKOther)).

to_der(List) when is_list(List) ->
	[to_der(Element) || Element <- List];
to_der(#jose_jwk{kty={Module, KTY}}) ->
	{#{ kty => Module }, Module:to_der(KTY)};
to_der(Other) ->
	to_der(from(Other)).

to_der(Key, #jose_jwk{kty={Module, KTY}}) ->
	{#{ kty => Module }, Module:to_der(Key, KTY)};
to_der(Key, Other) ->
	to_der(Key, from(Other)).

to_der_file(File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_der(JWK),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_der_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_der_file(File, from(Other)).

to_der_file(Key, File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_der(Key, JWK),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_der_file(Key, File, Other) when is_binary(File) orelse is_list(File) ->
	to_der_file(Key, File, from(Other)).

to_file(File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_binary(JWK),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_file(File, from(Other)).

to_file(Key, File, JWK=#jose_jwk{kty={Module, KTY}, fields=Fields}) when is_binary(File) orelse is_list(File) ->
	to_file(Key, File, Module:key_encryptor(KTY, Fields, Key), JWK);
to_file(Key, File, Other) when is_binary(File) orelse is_list(File) ->
	to_file(Key, File, from(Other)).

to_file(Key, File, JWE=#jose_jwe{}, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, EncryptedBinary} = to_binary(Key, JWE, JWK),
	case file:write_file(File, EncryptedBinary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_file(Key, File, JWEOther, JWKOther) when is_binary(File) orelse is_list(File) ->
	to_file(Key, File, jose_jwe:from(JWEOther), from(JWKOther)).

to_key(List) when is_list(List) ->
	[to_key(Element) || Element <- List];
to_key(#jose_jwk{kty={Module, KTY}}) ->
	{#{ kty => Module }, Module:to_key(KTY)};
to_key(Other) ->
	to_key(from(Other)).

to_map(List) when is_list(List) ->
	[to_map(Element) || Element <- List];
to_map(JWK=#jose_jwk{fields=Fields}) ->
	record_to_map(JWK, #{}, Fields);
to_map(Other) ->
	to_map(from(Other)).

to_map(Key, JWK=#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	to_map(Key, Module:key_encryptor(KTY, Fields, Key), JWK);
to_map(Key, Other) ->
	to_map(Key, from(Other)).

to_map(Key, JWE=#jose_jwe{}, JWK=#jose_jwk{}) ->
	{Modules0, JWKBinary} = to_binary(JWK),
	{Modules1, Encrypted} = jose_jwe:block_encrypt(Key, JWKBinary, JWE),
	{maps:merge(Modules0, Modules1), Encrypted};
to_map(Key, JWEOther, JWKOther) ->
	to_map(Key, jose_jwe:from(JWEOther), from(JWKOther)).

to_oct(List) when is_list(List) ->
	[to_oct(Element) || Element <- List];
to_oct(#jose_jwk{kty={Module, KTY}}) ->
	{#{ kty => Module }, Module:to_oct(KTY)};
to_oct(Other) ->
	to_oct(from(Other)).

to_oct(Key, JWK=#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	to_oct(Key, Module:key_encryptor(KTY, Fields, Key), JWK);
to_oct(Key, Other) ->
	to_oct(Key, from(Other)).

to_oct(Key, JWE=#jose_jwe{}, JWK=#jose_jwk{}) ->
	{Modules0, OCTBinary} = to_oct(JWK),
	{Modules1, EncryptedMap} = jose_jwe:block_encrypt(Key, OCTBinary, JWE),
	jose_jwe:compact({maps:merge(Modules0, Modules1), EncryptedMap});
to_oct(Key, JWEOther, JWKOther) ->
	to_oct(Key, jose_jwe:from(JWEOther), from(JWKOther)).

to_oct_file(File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_oct(JWK),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_oct_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_oct_file(File, from(Other)).

to_oct_file(Key, File, JWK=#jose_jwk{kty={Module, KTY}, fields=Fields}) when is_binary(File) orelse is_list(File) ->
	to_oct_file(Key, File, Module:key_encryptor(KTY, Fields, Key), JWK);
to_oct_file(Key, File, Other) when is_binary(File) orelse is_list(File) ->
	to_oct_file(Key, File, from(Other)).

to_oct_file(Key, File, JWE=#jose_jwe{}, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, EncryptedBinary} = to_oct(Key, JWE, JWK),
	case file:write_file(File, EncryptedBinary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_oct_file(Key, File, JWEOther, JWKOther) when is_binary(File) orelse is_list(File) ->
	to_oct_file(Key, File, jose_jwe:from(JWEOther), from(JWKOther)).

to_okp(List) when is_list(List) ->
	[to_okp(Element) || Element <- List];
to_okp(#jose_jwk{kty={Module, KTY}}) ->
	{#{ kty => Module }, Module:to_okp(KTY)};
to_okp(Other) ->
	to_okp(from(Other)).

to_openssh_key(List) when is_list(List) ->
	[to_openssh_key(Element) || Element <- List];
to_openssh_key(#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	{#{ kty => Module }, Module:to_openssh_key(KTY, Fields)};
to_openssh_key(Other) ->
	to_openssh_key(from(Other)).

to_openssh_key_file(File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_openssh_key(JWK),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_openssh_key_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_openssh_key_file(File, from(Other)).

to_pem(List) when is_list(List) ->
	[to_pem(Element) || Element <- List];
to_pem(#jose_jwk{kty={Module, KTY}}) ->
	{#{ kty => Module }, Module:to_pem(KTY)};
to_pem(Other) ->
	to_pem(from(Other)).

to_pem(Key, #jose_jwk{kty={Module, KTY}}) ->
	{#{ kty => Module }, Module:to_pem(Key, KTY)};
to_pem(Key, Other) ->
	to_pem(Key, from(Other)).

to_pem_file(File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_pem(JWK),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_pem_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_pem_file(File, from(Other)).

to_pem_file(Key, File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_pem(Key, JWK),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_pem_file(Key, File, Other) when is_binary(File) orelse is_list(File) ->
	to_pem_file(Key, File, from(Other)).

to_public(List) when is_list(List) ->
	[to_public(Element) || Element <- List];
to_public(JWK=#jose_jwk{}) ->
	from_map(to_public_map(JWK));
to_public(Other) ->
	to_public(from(Other)).

to_public_file(File, JWK=#jose_jwk{}) when is_binary(File) orelse is_list(File) ->
	to_file(File, to_public(JWK));
to_public_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_public_file(File, from(Other)).

to_public_key(List) when is_list(List) ->
	[to_public_key(Element) || Element <- List];
to_public_key(JWT=#jose_jwk{}) ->
	to_key(to_public(JWT));
to_public_key(Other) ->
	to_public_key(from(Other)).

to_public_map(List) when is_list(List) ->
	[to_public_map(Element) || Element <- List];
to_public_map(#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	{#{ kty => Module }, Module:to_public_map(KTY, Fields)};
to_public_map(Other) ->
	to_public_map(from(Other)).

to_thumbprint_map(List) when is_list(List) ->
	[to_thumbprint_map(Element) || Element <- List];
to_thumbprint_map(#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	{#{ kty => Module }, Module:to_thumbprint_map(KTY, Fields)};
to_thumbprint_map(Other) ->
	to_thumbprint_map(from(Other)).

%%====================================================================
%% API functions
%%====================================================================

block_decrypt(Encrypted, JWK=#jose_jwk{}) ->
	jose_jwe:block_decrypt(JWK, Encrypted);
block_decrypt(Encrypted, Other) ->
	block_decrypt(Encrypted, from(Other)).

block_encrypt(PlainText, JWK=#jose_jwk{}) ->
	block_encrypt(PlainText, block_encryptor(JWK), JWK);
block_encrypt(PlainText, Other) ->
	block_encrypt(PlainText, from(Other)).

block_encrypt(PlainText, JWE=#jose_jwe{}, JWK=#jose_jwk{}) ->
	jose_jwe:block_encrypt(JWK, PlainText, JWE);
block_encrypt(PlainText, JWEOther, JWKOther) ->
	block_encrypt(PlainText, jose_jwe:from(JWEOther), from(JWKOther)).

block_encryptor(List) when is_list(List) ->
	[block_encryptor(Element) || Element <- List];
block_encryptor(#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	Module:block_encryptor(KTY, Fields);
block_encryptor(Other) ->
	block_encryptor(from(Other)).

box_decrypt(Encrypted, VStaticSecretKey) ->
	box_decrypt_ecdh_es(Encrypted, VStaticSecretKey).

%% @doc Generates an ephemeral private key based on receiver public key curve.
box_encrypt(PlainText, VStaticPublicKey=#jose_jwk{}) ->
	box_encrypt_ecdh_es(PlainText, VStaticPublicKey).

box_encrypt(PlainText, VStaticPublicKey, UEphemeralSecretKey) ->
	box_encrypt_ecdh_es(PlainText, VStaticPublicKey, UEphemeralSecretKey).

box_encrypt(PlainText, JWE, VStaticPublicKey, UEphemeralSecretKey) ->
	box_encrypt_ecdh_es(PlainText, JWE, VStaticPublicKey, UEphemeralSecretKey).

box_decrypt_ecdh_1pu(Encrypted, UStaticPublicKey=#jose_jwk{}, VStaticSecretKey=#jose_jwk{}) ->
	jose_jwe:block_decrypt({UStaticPublicKey, VStaticSecretKey}, Encrypted);
box_decrypt_ecdh_1pu(Encrypted, UStaticPublicKey, VStaticSecretKey) ->
	box_decrypt_ecdh_1pu(Encrypted, from(UStaticPublicKey), from(VStaticSecretKey)).

%% @doc Generates an ephemeral private key based on receiver public key curve.
box_encrypt_ecdh_1pu(PlainText, VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}) ->
	UEphemeralSecretKey = generate_key(VStaticPublicKey),
	{box_encrypt_ecdh_1pu(PlainText, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey), UEphemeralSecretKey};
box_encrypt_ecdh_1pu(PlainText, VStaticPublicKey, UStaticSecretKey) ->
	box_encrypt_ecdh_1pu(PlainText, from(VStaticPublicKey), from(UStaticSecretKey)).

box_encrypt_ecdh_1pu(PlainText, VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	UEphemeralPublicKey0 = #jose_jwk{fields=Fields0} = to_public(UEphemeralSecretKey),
	Fields1 = maps:put(<<"epk">>, element(2, to_map(UEphemeralPublicKey0)), Fields0),
	Fields2 =
		case Fields1 of
			#{ <<"alg">> := _ } ->
				Fields1;
			_ ->
				maps:put(<<"alg">>, <<"ECDH-1PU">>, Fields1)
		end,
	UEphemeralPublicKey = UEphemeralPublicKey0#jose_jwk{fields=Fields2},
	JWEFields = block_encryptor(UEphemeralPublicKey),
	box_encrypt_ecdh_1pu(PlainText, JWEFields, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
box_encrypt_ecdh_1pu(PlainText, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey) ->
	box_encrypt_ecdh_1pu(PlainText, from(VStaticPublicKey), from(UStaticSecretKey), from(UEphemeralSecretKey)).

box_encrypt_ecdh_1pu(PlainText, JWE=#jose_jwe{}, VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	jose_jwe:block_encrypt({VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey}, PlainText, JWE);
box_encrypt_ecdh_1pu(PlainText, {JWEModules, JWEMap=#{ <<"apu">> := _, <<"apv">> := _, <<"epk">> := _, <<"skid">> := _ }}, VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	box_encrypt_ecdh_1pu(PlainText, jose_jwe:from({JWEModules, JWEMap}), VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
box_encrypt_ecdh_1pu(PlainText, {JWEModules, JWEMap0}, VStaticPublicKey=#jose_jwk{}, UStaticSecretKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	Keys = [<<"apu">>, <<"apv">>, <<"epk">>, <<"skid">>] -- maps:keys(JWEMap0),
	JWEMap1 = normalize_ecdh_1pu(Keys, JWEMap0, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey),
	box_encrypt_ecdh_1pu(PlainText, {JWEModules, JWEMap1}, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
box_encrypt_ecdh_1pu(PlainText, JWEMap, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey) when is_map(JWEMap) ->
	box_encrypt_ecdh_1pu(PlainText, {#{}, JWEMap}, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
box_encrypt_ecdh_1pu(PlainText, JWE, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey) ->
	box_encrypt_ecdh_1pu(PlainText, JWE, from(VStaticPublicKey), from(UStaticSecretKey), from(UEphemeralSecretKey)).

box_decrypt_ecdh_es(Encrypted, VStaticSecretKey=#jose_jwk{}) ->
	jose_jwe:block_decrypt(VStaticSecretKey, Encrypted);
box_decrypt_ecdh_es(Encrypted, VStaticSecretKey) ->
	box_decrypt_ecdh_es(Encrypted, from(VStaticSecretKey)).

%% @doc Generates an ephemeral private key based on receiver public key curve.
box_encrypt_ecdh_es(PlainText, VStaticPublicKey=#jose_jwk{}) ->
	UEphemeralSecretKey = generate_key(VStaticPublicKey),
	{box_encrypt_ecdh_es(PlainText, VStaticPublicKey, UEphemeralSecretKey), UEphemeralSecretKey};
box_encrypt_ecdh_es(PlainText, VStaticPublicKey) ->
	box_encrypt_ecdh_es(PlainText, from(VStaticPublicKey)).

box_encrypt_ecdh_es(PlainText, VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	UEphemeralPublicKey0 = #jose_jwk{fields=Fields0} = to_public(UEphemeralSecretKey),
	Fields1 = maps:put(<<"epk">>, element(2, to_map(UEphemeralPublicKey0)), Fields0),
	UEphemeralPublicKey = UEphemeralPublicKey0#jose_jwk{fields=Fields1},
	JWEFields = block_encryptor(UEphemeralPublicKey),
	box_encrypt_ecdh_es(PlainText, JWEFields, VStaticPublicKey, UEphemeralSecretKey);
box_encrypt_ecdh_es(PlainText, VStaticPublicKey, UEphemeralSecretKey) ->
	box_encrypt_ecdh_es(PlainText, from(VStaticPublicKey), from(UEphemeralSecretKey)).

box_encrypt_ecdh_es(PlainText, JWE=#jose_jwe{}, VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	jose_jwe:block_encrypt({VStaticPublicKey, UEphemeralSecretKey}, PlainText, JWE);
box_encrypt_ecdh_es(PlainText, {JWEModules, JWEMap=#{ <<"apu">> := _, <<"apv">> := _, <<"epk">> := _ }}, VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	box_encrypt_ecdh_es(PlainText, jose_jwe:from({JWEModules, JWEMap}), VStaticPublicKey, UEphemeralSecretKey);
box_encrypt_ecdh_es(PlainText, {JWEModules, JWEMap0}, VStaticPublicKey=#jose_jwk{}, UEphemeralSecretKey=#jose_jwk{}) ->
	Keys = [<<"apu">>, <<"apv">>, <<"epk">>] -- maps:keys(JWEMap0),
	JWEMap1 = normalize_ecdh_es(Keys, JWEMap0, VStaticPublicKey, UEphemeralSecretKey),
	box_encrypt_ecdh_es(PlainText, {JWEModules, JWEMap1}, VStaticPublicKey, UEphemeralSecretKey);
box_encrypt_ecdh_es(PlainText, JWEMap, VStaticPublicKey, UEphemeralSecretKey) when is_map(JWEMap) ->
	box_encrypt_ecdh_es(PlainText, {#{}, JWEMap}, VStaticPublicKey, UEphemeralSecretKey);
box_encrypt_ecdh_es(PlainText, JWE, VStaticPublicKey, UEphemeralSecretKey) ->
	box_encrypt_ecdh_es(PlainText, JWE, from(VStaticPublicKey), from(UEphemeralSecretKey)).

box_decrypt_ecdh_ss(Encrypted, VStaticSecretKey0) ->
	VStaticSecretKey =
		case VStaticSecretKey0 of
			#jose_jwk{} ->
				VStaticSecretKey0;
			_ ->
				from(VStaticSecretKey0)
		end,
	jose_jwe:block_decrypt(VStaticSecretKey, Encrypted).

%% @doc Generates a new static secret key based on receiver public key curve.
box_encrypt_ecdh_ss(PlainText, VStaticPublicKey0) ->
	VStaticPublicKey =
		case VStaticPublicKey0 of
			#jose_jwk{} ->
				VStaticPublicKey0;
			_ ->
				from(VStaticPublicKey0)
		end,
	UStaticSecretKey = generate_key(VStaticPublicKey),
	{box_encrypt_ecdh_ss(PlainText, VStaticPublicKey, UStaticSecretKey), UStaticSecretKey}.

box_encrypt_ecdh_ss(PlainText, VStaticPublicKey0, UStaticSecretKey0) ->
	VStaticPublicKey =
		case VStaticPublicKey0 of
			#jose_jwk{} ->
				VStaticPublicKey0;
			_ ->
				from(VStaticPublicKey0)
		end,
	UStaticSecretKey =
		case UStaticSecretKey0 of
			#jose_jwk{} ->
				UStaticSecretKey0;
			_ ->
				from(UStaticSecretKey0)
		end,
	UStaticPublicKey0 = #jose_jwk{fields=Fields0} = to_public(UStaticSecretKey),
	Fields1 = maps:put(<<"spk">>, element(2, to_map(UStaticPublicKey0)), Fields0),
	Fields2 =
		case Fields1 of
			#{ <<"alg">> := _ } ->
				Fields1;
			_ ->
				maps:put(<<"alg">>, <<"ECDH-SS">>, Fields1)
		end,
	UStaticPublicKey = UStaticPublicKey0#jose_jwk{fields=Fields2},
	JWEFields = block_encryptor(UStaticPublicKey),
	box_encrypt_ecdh_ss(PlainText, JWEFields, VStaticPublicKey, UStaticSecretKey).

box_encrypt_ecdh_ss(PlainText, JWE0, VStaticPublicKey0, UStaticSecretKey0) ->
	VStaticPublicKey =
		case VStaticPublicKey0 of
			#jose_jwk{} ->
				VStaticPublicKey0;
			_ ->
				from(VStaticPublicKey0)
		end,
	UStaticSecretKey =
		case UStaticSecretKey0 of
			#jose_jwk{} ->
				UStaticSecretKey0;
			_ ->
				from(UStaticSecretKey0)
		end,
	JWE =
		case JWE0 of
			#jose_jwe{} ->
				JWE0;
			{JWEModules, JWEMap=#{ <<"apu">> := _, <<"spk">> := _ }} ->
				jose_jwe:from({JWEModules, JWEMap});
			{JWEModules, JWEMap0} when is_map(JWEMap0) ->
				Keys = [<<"apu">>, <<"apv">>, <<"spk">>] -- maps:keys(JWEMap0),
				JWEMap1 = normalize_ecdh_ss(Keys, JWEMap0, VStaticPublicKey, UStaticSecretKey),
				jose_jwe:from({JWEModules, JWEMap1});
			JWEMap0 when is_map(JWEMap0) ->
				Keys = [<<"apu">>, <<"apv">>, <<"spk">>] -- maps:keys(JWEMap0),
				JWEMap1 = normalize_ecdh_ss(Keys, JWEMap0, VStaticPublicKey, UStaticSecretKey),
				jose_jwe:from_map(JWEMap1);
			_ ->
				jose_jwe:from(JWE0)
		end,
	jose_jwe:block_encrypt({VStaticPublicKey, UStaticSecretKey}, PlainText, JWE).

generate_key(#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	{NewKTY, NewFields} = Module:generate_key(KTY, Fields),
	#jose_jwk{kty={Module, NewKTY}, fields=NewFields};
generate_key({#{ kty := Module }, Parameters}) ->
	{KTY, Fields} = Module:generate_key(Parameters),
	#jose_jwk{kty={Module, KTY}, fields=Fields};
generate_key(Parameters) ->
	jose_jwk_kty:generate_key(Parameters).

merge(LeftJWK=#jose_jwk{}, RightMap) when is_map(RightMap) ->
	{Modules, LeftMap} = to_map(LeftJWK),
	from_map({Modules, maps:merge(LeftMap, RightMap)});
merge(LeftOther, RightJWK=#jose_jwk{}) ->
	merge(LeftOther, element(2, to_map(RightJWK)));
merge(LeftOther, RightMap) when is_map(RightMap) ->
	merge(from(LeftOther), RightMap).

shared_secret(#jose_jwk{kty={Module, YourKTY}}, #jose_jwk{kty={Module, MyKTY}}) ->
	Module:derive_key(YourKTY, MyKTY);
%% Both arguments are already decoded, but their "kty" modules differ (or one
%% is absent), so no shared secret can be derived.  Fail closed here: the
%% fallback clause below would call from/1 on two #jose_jwk{} records, which
%% returns them unchanged, and re-enter shared_secret/2 with identical
%% arguments -- an unbounded tail-recursive loop.  Only the module names are
%% reported, because a #jose_jwk{} may carry private key material.
shared_secret(#jose_jwk{kty=YourKTY}, #jose_jwk{kty=MyKTY}) ->
	erlang:error({badarg, [kty_module(YourKTY), kty_module(MyKTY)]});
shared_secret(YourJWK, MyJWK) ->
	shared_secret(from(YourJWK), from(MyJWK)).

sign(PlainText, JWK=#jose_jwk{}) ->
	sign(PlainText, signer(JWK), JWK);
sign(PlainText, KeyList)
		when is_list(KeyList) ->
	Folder = fun
		Folder(Key=#jose_jwk{}, {Signers, Keys}) ->
			Signer = signer(Key),
			{[Signer | Signers], [Key | Keys]};
		Folder(Other, Acc) ->
			Folder(from(Other), Acc)
	end,
	{Signers, Keys} = lists:foldr(Folder, {[], []}, KeyList),
	sign(PlainText, Signers, Keys);
sign(PlainText, Other) ->
	sign(PlainText, from(Other)).

sign(PlainText, JWS=#jose_jws{}, JWK=#jose_jwk{}) ->
	jose_jws:sign(JWK, PlainText, JWS);
sign(PlainText, SignerList, KeyList)
		when is_list(SignerList)
		andalso is_list(KeyList)
		andalso length(SignerList) =:= length(KeyList) ->
	Signers = jose_jws:from(SignerList),
	Keys = from(KeyList),
	jose_jws:sign(Keys, PlainText, Signers);
sign(PlainText, JWS=#jose_jws{}, KeyList)
		when is_list(KeyList) ->
	jose_jws:sign(from(KeyList), PlainText, JWS);
sign(PlainText, SignerList, KeyList)
		when is_list(SignerList)
		andalso is_list(KeyList)
		andalso length(SignerList) =/= length(KeyList) ->
	erlang:error({badarg, [PlainText, SignerList, KeyList]});
sign(PlainText, JWSOther, KeyList)
		when is_list(KeyList) ->
	sign(PlainText, jose_jws:from(JWSOther), KeyList);
sign(PlainText, JWSOther, JWKOther) ->
	sign(PlainText, jose_jws:from(JWSOther), from(JWKOther)).

signer(List) when is_list(List) ->
	[signer(Element) || Element <- List];
signer(#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	Module:signer(KTY, Fields);
signer(Other) ->
	signer(from(Other)).

%% See https://tools.ietf.org/html/rfc7638
thumbprint(List) when is_list(List) ->
	[thumbprint(Element) || Element <- List];
thumbprint(JWK=#jose_jwk{}) ->
	thumbprint(sha256, JWK);
thumbprint(Other) ->
	thumbprint(from(Other)).

thumbprint(DigestType, List) when is_list(List) ->
	[thumbprint(DigestType, Element) || Element <- List];
thumbprint(DigestType, JWK=#jose_jwk{}) ->
	{_, ThumbprintMap} = to_thumbprint_map(JWK),
	ThumbprintBinary = jose:encode(ThumbprintMap),
	jose_jwa_base64url:encode(crypto:hash(DigestType, ThumbprintBinary));
thumbprint(DigestType, Other) ->
	thumbprint(DigestType, from(Other)).

thumbprint_concat(List) when is_list(List) ->
	thumbprint_concat(sha256, List).

thumbprint_concat(DigestType, List) when is_list(List) ->
	jose_jwa_base64url:encode(crypto:hash(DigestType, do_thumbprint_concat(List))).

verifier(List) when is_list(List) ->
	[verifier(Element) || Element <- List];
verifier(#jose_jwk{kty={Module, KTY}, fields=Fields}) ->
	Module:verifier(KTY, Fields);
verifier(Other) ->
	verifier(from(Other)).

verify(Signed, JWK=#jose_jwk{}) ->
	jose_jws:verify(JWK, Signed);
verify(Signed, Other) ->
	verify(Signed, from(Other)).

verify_strict(Signed, Allow, JWK=#jose_jwk{}) ->
	jose_jws:verify_strict(JWK, Allow, Signed);
verify_strict(Signed, Allow, Other) ->
	verify_strict(Signed, Allow, from(Other)).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
do_thumbprint_concat([]) ->
	[];
do_thumbprint_concat([H | T]) ->
	{_, ThumbprintMap} = to_thumbprint_map(H),
	ThumbprintBinary = jose:encode(ThumbprintMap),
	[ThumbprintBinary | do_thumbprint_concat(T)].

%% @private
kty_module({Module, _KTY}) when is_atom(Module) ->
	Module;
kty_module(_) ->
	undefined.

%% @private
normalize_ecdh_1pu([<<"apu">> | Keys], Map, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey) ->
	APU = thumbprint_concat([UStaticSecretKey, UEphemeralSecretKey]),
	normalize_ecdh_1pu(Keys, Map#{ <<"apu">> => APU }, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
normalize_ecdh_1pu([<<"apv">> | Keys], Map, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey) ->
	APV = thumbprint(VStaticPublicKey),
	normalize_ecdh_1pu(Keys, Map#{ <<"apv">> => APV }, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
normalize_ecdh_1pu([<<"epk">> | Keys], Map, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey) ->
	{_, UEphemeralPublicKeyMap} = to_public_map(UEphemeralSecretKey),
	normalize_ecdh_1pu(Keys, Map#{ <<"epk">> => UEphemeralPublicKeyMap }, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
normalize_ecdh_1pu([<<"skid">> | Keys], Map, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey) ->
	SenderKeyId =
		case UStaticSecretKey of
			#jose_jwk{fields=#{ <<"kid">> := KID }} ->
				KID;
			_ ->
				thumbprint(UStaticSecretKey)
		end,
	normalize_ecdh_1pu(Keys, Map#{ <<"skid">> => SenderKeyId }, VStaticPublicKey, UStaticSecretKey, UEphemeralSecretKey);
normalize_ecdh_1pu([], Map, _, _, _) ->
	Map.

%% @private
normalize_ecdh_es([<<"apu">> | Keys], Map, VStaticPublicKey, UEphemeralSecretKey=#jose_jwk{fields=#{ <<"kid">> := KID }}) ->
	normalize_ecdh_es(Keys, Map#{ <<"apu">> => KID }, VStaticPublicKey, UEphemeralSecretKey);
normalize_ecdh_es([<<"apu">> | Keys], Map, VStaticPublicKey, UEphemeralSecretKey) ->
	normalize_ecdh_es(Keys, Map#{ <<"apu">> => thumbprint(UEphemeralSecretKey) }, VStaticPublicKey, UEphemeralSecretKey);
normalize_ecdh_es([<<"apv">> | Keys], Map, VStaticPublicKey=#jose_jwk{fields=#{ <<"kid">> := KID }}, UEphemeralSecretKey) ->
	normalize_ecdh_es(Keys, Map#{ <<"apv">> => KID }, VStaticPublicKey, UEphemeralSecretKey);
normalize_ecdh_es([<<"apv">> | Keys], Map, VStaticPublicKey, UEphemeralSecretKey) ->
	normalize_ecdh_es(Keys, Map#{ <<"apv">> => thumbprint(VStaticPublicKey) }, VStaticPublicKey, UEphemeralSecretKey);
normalize_ecdh_es([<<"epk">> | Keys], Map, VStaticPublicKey, UEphemeralSecretKey) ->
	{_, UEphemeralPublicKeyMap} = to_public_map(UEphemeralSecretKey),
	normalize_ecdh_es(Keys, Map#{ <<"epk">> => UEphemeralPublicKeyMap }, VStaticPublicKey, UEphemeralSecretKey);
normalize_ecdh_es([], Map, _, _) ->
	Map.

%% @private
normalize_ecdh_ss([<<"apu">> | Keys], Map, VStaticPublicKey, UStaticSecretKey) ->
	normalize_ecdh_ss(Keys, Map#{ <<"apu">> => jose_jwa_base64url:encode(crypto:strong_rand_bytes(64)) }, VStaticPublicKey, UStaticSecretKey);
normalize_ecdh_ss([<<"apv">> | Keys], Map, VStaticPublicKey=#jose_jwk{fields=#{ <<"kid">> := KID }}, UStaticSecretKey) ->
	normalize_ecdh_ss(Keys, Map#{ <<"apv">> => KID }, VStaticPublicKey, UStaticSecretKey);
normalize_ecdh_ss([<<"apv">> | Keys], Map, VStaticPublicKey, UStaticSecretKey) ->
	normalize_ecdh_ss(Keys, Map#{ <<"apv">> => thumbprint(VStaticPublicKey) }, VStaticPublicKey, UStaticSecretKey);
normalize_ecdh_ss([<<"spk">> | Keys], Map, VStaticPublicKey, UStaticSecretKey) ->
	{_, UStaticPublicKeyMap} = to_public_map(UStaticSecretKey),
	normalize_ecdh_ss(Keys, Map#{ <<"spk">> => UStaticPublicKeyMap }, VStaticPublicKey, UStaticSecretKey);
normalize_ecdh_ss([], Map, _, _) ->
	Map.

%% @private
record_to_map(JWK=#jose_jwk{keys={Module, KEYS}}, Modules, Fields0) ->
	Fields1 = Module:to_map(KEYS, Fields0),
	record_to_map(JWK#jose_jwk{keys=undefined}, Modules#{ keys => Module }, Fields1);
record_to_map(JWK=#jose_jwk{kty={Module, KTY}}, Modules, Fields0) ->
	Fields1 = Module:to_map(KTY, Fields0),
	record_to_map(JWK#jose_jwk{kty=undefined}, Modules#{ kty => Module }, Fields1);
record_to_map(_JWK, Modules, Fields) ->
	{Modules, Fields}.
