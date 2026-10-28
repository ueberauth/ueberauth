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
-module(jose_jwe).

-include("jose_jwe.hrl").
-include("jose_jwk.hrl").

-callback from_map(Fields) -> State
	when
		Fields :: map(),
		State  :: any().
-callback to_map(State, Fields) -> Map
	when
		State  :: any(),
		Fields :: map(),
		Map    :: map().

%% Decode API
-export([from/1]).
-export([from_binary/1]).
-export([from_file/1]).
-export([from_map/1]).
%% Encode API
-export([to_binary/1]).
-export([to_file/2]).
-export([to_map/1]).
%% API
-export([block_decrypt/2]).
-export([block_encrypt/3]).
-export([block_encrypt/4]).
-export([block_encrypt/5]).
-export([compact/1]).
-export([compress/2]).
-export([expand/1]).
-export([generate_key/1]).
-export([key_decrypt/3]).
-export([key_encrypt/3]).
-export([merge/2]).
-export([next_cek/2]).
-export([next_iv/1]).
-export([uncompress/2]).

-define(ALG_AES_KW_MODULE,   jose_jwe_alg_aes_kw).
-define(ALG_C20P_KW_MODULE,  jose_jwe_alg_c20p_kw).
-define(ALG_XC20P_KW_MODULE, jose_jwe_alg_xc20p_kw).
-define(ALG_DIR_MODULE,      jose_jwe_alg_dir).
-define(ALG_ECDH_1PU_MODULE, jose_jwe_alg_ecdh_1pu).
-define(ALG_ECDH_ES_MODULE,  jose_jwe_alg_ecdh_es).
-define(ALG_ECDH_SS_MODULE,  jose_jwe_alg_ecdh_ss).
-define(ALG_PBES2_MODULE,    jose_jwe_alg_pbes2).
-define(ALG_RSA_MODULE,      jose_jwe_alg_rsa).
-define(ENC_AES_MODULE,      jose_jwe_enc_aes).
-define(ENC_C20P_MODULE,     jose_jwe_enc_c20p).
-define(ENC_XC20P_MODULE,    jose_jwe_enc_xc20p).
-define(ZIP_MODULE,          jose_jwe_zip).

%%====================================================================
%% Decode API functions
%%====================================================================

from({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({Modules, Map});
from({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	from_binary({Modules, Binary});
from(JWE=#jose_jwe{}) ->
	JWE;
from(Other) when is_map(Other) orelse is_binary(Other) ->
	from({#{}, Other}).

from_binary({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	from_map({Modules, jose:decode(Binary)});
from_binary(Binary) when is_binary(Binary) ->
	from_binary({#{}, Binary}).

from_file({Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_binary({Modules, Binary});
		ReadError ->
			ReadError
	end;
from_file(File) when is_binary(File) orelse is_list(File) ->
	from_file({#{}, File}).

from_map(Map) when is_map(Map) ->
	from_map({#{}, Map});
from_map({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({#jose_jwe{}, Modules, Map});
from_map({JWE, Modules = #{ alg := Module }, Map=#{ <<"alg">> := _ }}) ->
	{ALG, Fields} = Module:from_map(Map),
	from_map({JWE#jose_jwe{ alg = {Module, ALG} }, maps:remove(alg, Modules), Fields});
from_map({JWE, Modules = #{ enc := Module }, Map=#{ <<"enc">> := _ }}) ->
	{ENC, Fields} = Module:from_map(Map),
	from_map({JWE#jose_jwe{ enc = {Module, ENC} }, maps:remove(enc, Modules), Fields});
from_map({JWE, Modules = #{ zip := Module }, Map=#{ <<"zip">> := _ }}) ->
	{ZIP, Fields} = Module:from_map(Map),
	from_map({JWE#jose_jwe{ zip = {Module, ZIP} }, maps:remove(zip, Modules), Fields});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "A", _, _, _, "GCMKW", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_AES_KW_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "A", _, _, _, "KW", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_AES_KW_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "C20PKW" >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_C20P_KW_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "dir", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_DIR_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "ECDH-1PU", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_ECDH_1PU_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "ECDH-ES", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_ECDH_ES_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "ECDH-SS", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_ECDH_SS_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "PBES2", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_PBES2_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "RSA", _/binary >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_RSA_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"alg">> := << "XC20PKW" >> }}) ->
	from_map({JWE, Modules#{ alg => ?ALG_XC20P_KW_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"enc">> := << "A", _/binary >> }}) ->
	from_map({JWE, Modules#{ enc => ?ENC_AES_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"enc">> := << "C20P" >> }}) ->
	from_map({JWE, Modules#{ enc => ?ENC_C20P_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"enc">> := << "XC20P" >> }}) ->
	from_map({JWE, Modules#{ enc => ?ENC_XC20P_MODULE }, Map});
from_map({JWE, Modules, Map=#{ <<"zip">> := << "DEF" >> }}) ->
	from_map({JWE, Modules#{ zip => ?ZIP_MODULE }, Map});
from_map({#jose_jwe{ alg = undefined, enc = undefined }, _Modules, _Map}) ->
	{error, {missing_required_keys, [<<"alg">>, <<"enc">>]}};
from_map({JWE, _Modules, Fields}) ->
	case {maps:is_key(<<"alg">>, Fields), maps:is_key(<<"enc">>, Fields)} of
		{true, true} ->
			{error, {invalid_fields, [{<<"alg">>, maps:get(<<"alg">>, Fields)}, {<<"enc">>, maps:get(<<"enc">>, Fields)}]}};
		{true, false} ->
			{error, {invalid_fields, [{<<"alg">>, maps:get(<<"alg">>, Fields)}]}};
		{false, true} ->
			{error, {invalid_fields, [{<<"enc">>, maps:get(<<"enc">>, Fields)}]}};
		{false, false} ->
			JWE#jose_jwe{ fields = Fields }
	end.

%%====================================================================
%% Encode API functions
%%====================================================================

to_binary(JWE=#jose_jwe{}) ->
	{Modules, Map} = to_map(JWE),
	{Modules, jose:encode(Map)};
to_binary(Other) ->
	to_binary(from(Other)).

to_file(File, JWE=#jose_jwe{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_binary(JWE),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_file(File, from(Other)).

to_map(JWE=#jose_jwe{fields=Fields}) ->
	record_to_map(JWE, #{}, Fields);
to_map(Other) ->
	to_map(from(Other)).

%%====================================================================
%% API functions
%%====================================================================

block_decrypt(Key, EncryptedMap) when is_map(EncryptedMap) ->
	block_decrypt(Key, {#{}, EncryptedMap});
block_decrypt(Key, EncryptedBinary) when is_binary(EncryptedBinary) ->
	block_decrypt(Key, expand(EncryptedBinary));
block_decrypt(Key, {Modules, EncryptedBinary}) when is_binary(EncryptedBinary) ->
	block_decrypt(Key, expand({Modules, EncryptedBinary}));
block_decrypt(Key, {Modules, EncryptedMap=#{
		<<"protected">> := Protected,
		<<"encrypted_key">> := EncodedEncryptedKey,
		<<"iv">> := EncodedIV,
		<<"ciphertext">> := EncodedCipherText,
		<<"tag">> := EncodedCipherTag}}) ->
	case maps:is_key(<<"aad">>, EncryptedMap) of
		false ->
			JWE = #jose_jwe{enc={ENCModule, ENC}} = from_binary({Modules, jose_jwa_base64url:decode(Protected)}),
			EncryptedKey = jose_jwa_base64url:decode(EncodedEncryptedKey),
			IV = jose_jwa_base64url:decode(EncodedIV),
			CipherText = jose_jwa_base64url:decode(EncodedCipherText),
			CipherTag = jose_jwa_base64url:decode(EncodedCipherTag),
			case key_decrypt(Key, EncryptedKey, JWE) of
				error ->
					{error, JWE};
				CEK when is_binary(CEK) ->
					PlainText = uncompress(ENCModule:block_decrypt({Protected, CipherText, CipherTag}, CEK, IV, ENC), JWE),
					{PlainText, JWE}
			end;
		true ->
			EncodedAAD = maps:get(<<"aad">>, EncryptedMap),
			ConcatAAD = << Protected/binary, $., EncodedAAD/binary >>,
			JWE = #jose_jwe{enc={ENCModule, ENC}} = from_binary({Modules, jose_jwa_base64url:decode(Protected)}),
			EncryptedKey = jose_jwa_base64url:decode(EncodedEncryptedKey),
			IV = jose_jwa_base64url:decode(EncodedIV),
			CipherText = jose_jwa_base64url:decode(EncodedCipherText),
			CipherTag = jose_jwa_base64url:decode(EncodedCipherTag),
			case key_decrypt(Key, EncryptedKey, JWE) of
				error ->
					{error, JWE};
				CEK when is_binary(CEK) ->
					PlainText = uncompress(ENCModule:block_decrypt({ConcatAAD, CipherText, CipherTag}, CEK, IV, ENC), JWE),
					{PlainText, JWE}
			end
	end.

block_encrypt(Key, Block, JWE0=#jose_jwe{}) ->
	{CEK, JWE1} = next_cek(Key, JWE0),
	block_encrypt(Key, Block, CEK, JWE1);
block_encrypt(Key, PlainText, Other) ->
	block_encrypt(Key, PlainText, from(Other)).

block_encrypt(Key, Block, CEK, JWE=#jose_jwe{}) ->
	IV = next_iv(JWE),
	block_encrypt(Key, Block, CEK, IV, JWE);
block_encrypt(Key, Block, CEK, Other) ->
	block_encrypt(Key, Block, CEK, from(Other)).

block_encrypt(Key, PlainText, CEK, IV, JWE0=#jose_jwe{enc={ENCModule, ENC}})
		when is_binary(PlainText) ->
	{EncryptedKey, JWE1} = key_encrypt(Key, CEK, JWE0),
	{Modules, ProtectedBinary} = to_binary(JWE1),
	Protected = jose_jwa_base64url:encode(ProtectedBinary),
	{CipherText, CipherTag} = ENCModule:block_encrypt({Protected, compress(PlainText, JWE1)}, CEK, IV, ENC),
	{Modules, #{
		<<"protected">> => Protected,
		<<"encrypted_key">> => jose_jwa_base64url:encode(EncryptedKey),
		<<"iv">> => jose_jwa_base64url:encode(IV),
		<<"ciphertext">> => jose_jwa_base64url:encode(CipherText),
		<<"tag">> => jose_jwa_base64url:encode(CipherTag)
	}};
block_encrypt(Key, {AAD0, PlainText}, CEK, IV, JWE0=#jose_jwe{enc={ENCModule, ENC}})
		when is_binary(AAD0)
		andalso is_binary(PlainText) ->
	{EncryptedKey, JWE1} = key_encrypt(Key, CEK, JWE0),
	{Modules, ProtectedBinary} = to_binary(JWE1),
	Protected = jose_jwa_base64url:encode(ProtectedBinary),
	AAD1 = jose_jwa_base64url:encode(AAD0),
	ConcatAAD = << Protected/binary, $., AAD1/binary >>,
	{CipherText, CipherTag} = ENCModule:block_encrypt({ConcatAAD, compress(PlainText, JWE1)}, CEK, IV, ENC),
	{Modules, #{
		<<"protected">> => Protected,
		<<"encrypted_key">> => jose_jwa_base64url:encode(EncryptedKey),
		<<"iv">> => jose_jwa_base64url:encode(IV),
		<<"ciphertext">> => jose_jwa_base64url:encode(CipherText),
		<<"tag">> => jose_jwa_base64url:encode(CipherTag),
		<<"aad">> => AAD1
	}};
block_encrypt(Key, Block, CEK, IV, Other)
		when is_binary(Block)
		orelse (is_tuple(Block) andalso tuple_size(Block) =:= 2) ->
	block_encrypt(Key, Block, CEK, IV, from(Other)).

compact({Modules, EncryptedMap=#{
		<<"protected">> := Protected,
		<<"encrypted_key">> := EncryptedKey,
		<<"iv">> := InitializationVector,
		<<"ciphertext">> := CipherText,
		<<"tag">> := AuthenticationTag}}) ->
	case maps:is_key(<<"aad">>, EncryptedMap) of
		false ->
			{Modules, <<
				Protected/binary, $.,
				EncryptedKey/binary, $.,
				InitializationVector/binary, $.,
				CipherText/binary, $.,
				AuthenticationTag/binary
			>>};
		true ->
			erlang:error({badarg, [{Modules, EncryptedMap}]})
	end;
compact(Map) when is_map(Map) ->
	compact({#{}, Map}).

compress(PlainText, #jose_jwe{zip={Module, ZIP}}) ->
	Module:compress(PlainText, ZIP);
compress(PlainText, #jose_jwe{}) ->
	PlainText;
compress(PlainText, Other) ->
	compress(PlainText, from(Other)).

expand({Modules, Binary}) when is_binary(Binary) ->
	case binary:split(Binary, <<".">>, [global]) of
		[Protected, EncryptedKey, InitializationVector, CipherText, AuthenticationTag] ->
			{Modules, #{
				<<"protected">> => Protected,
				<<"encrypted_key">> => EncryptedKey,
				<<"iv">> => InitializationVector,
				<<"ciphertext">> => CipherText,
				<<"tag">> => AuthenticationTag
			}};
		_ ->
			erlang:error({badarg, [{Modules, Binary}]})
	end;
expand(Binary) when is_binary(Binary) ->
	expand({#{}, Binary}).

generate_key(List) when is_list(List) ->
	[generate_key(Element) || Element <- List];
generate_key(#jose_jwe{alg={ALGModule, ALG}, enc={ENCModule, ENC}, fields=Fields}) ->
	ALGModule:generate_key(Fields, {ENCModule, ENC}, ALG);
generate_key(Other) ->
	generate_key(from(Other)).

key_decrypt(Key, EncryptedKey, #jose_jwe{alg={ALGModule, ALG}, enc={ENCModule, ENC}}) ->
	ALGModule:key_decrypt(Key, {ENCModule, ENC, EncryptedKey}, ALG);
key_decrypt(Key, EncryptedKey, JWE=#jose_jwe{}) ->
	erlang:error({badarg, [Key, EncryptedKey, JWE]});
key_decrypt(Key, EncryptedKey, Other) ->
	key_decrypt(Key, EncryptedKey, from(Other)).

key_encrypt(Key, DecryptedKey, JWE0=#jose_jwe{alg={ALGModule, ALG0}}) ->
	{EncryptedKey, ALG1} = ALGModule:key_encrypt(Key, DecryptedKey, ALG0),
	JWE1 = JWE0#jose_jwe{alg={ALGModule, ALG1}},
	{EncryptedKey, JWE1};
key_encrypt(Key, EncryptedKey, Other) ->
	key_encrypt(Key, EncryptedKey, from(Other)).

merge(LeftJWE=#jose_jwe{}, RightMap) when is_map(RightMap) ->
	{Modules, LeftMap} = to_map(LeftJWE),
	from_map({Modules, maps:merge(LeftMap, RightMap)});
merge(LeftOther, RightJWE=#jose_jwe{}) ->
	merge(LeftOther, element(2, to_map(RightJWE)));
merge(LeftOther, RightMap) when is_map(RightMap) ->
	merge(from(LeftOther), RightMap).

next_cek(Key, JWE0=#jose_jwe{alg={ALGModule, ALG0}, enc={ENCModule, ENC}}) ->
	{DecryptedKey, ALG1} = ALGModule:next_cek(Key, {ENCModule, ENC}, ALG0),
	JWE1 = JWE0#jose_jwe{alg={ALGModule, ALG1}},
	{DecryptedKey, JWE1};
next_cek(Key, Other) ->
	next_cek(Key, from(Other)).

next_iv(#jose_jwe{enc={ENCModule, ENC}}) ->
	ENCModule:next_iv(ENC);
next_iv(Other) ->
	next_iv(from(Other)).

%% Authentication failure must never be passed to a decompressor.
uncompress(error, #jose_jwe{}) ->
	error;
uncompress(CipherText, #jose_jwe{zip={Module, ZIP}}) ->
	Module:uncompress(CipherText, ZIP);
uncompress(CipherText, #jose_jwe{}) ->
	CipherText;
uncompress(CipherText, Other) ->
	uncompress(CipherText, from(Other)).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
record_to_map(JWE=#jose_jwe{alg={Module, ALG}}, Modules, Fields0) ->
	Fields1 = Module:to_map(ALG, Fields0),
	record_to_map(JWE#jose_jwe{alg=undefined}, Modules#{ alg => Module }, Fields1);
record_to_map(JWE=#jose_jwe{enc={Module, ENC}}, Modules, Fields0) ->
	Fields1 = Module:to_map(ENC, Fields0),
	record_to_map(JWE#jose_jwe{enc=undefined}, Modules#{ enc => Module }, Fields1);
record_to_map(JWE=#jose_jwe{zip={Module, ZIP}}, Modules, Fields0) ->
	Fields1 = Module:to_map(ZIP, Fields0),
	record_to_map(JWE#jose_jwe{zip=undefined}, Modules#{ zip => Module }, Fields1);
record_to_map(_JWE, Modules, Fields) ->
	{Modules, Fields}.
