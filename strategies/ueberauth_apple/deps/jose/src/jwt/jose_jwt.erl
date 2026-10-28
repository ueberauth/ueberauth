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
-module(jose_jwt).

-include("jose_jwe.hrl").
-include("jose_jwk.hrl").
-include("jose_jws.hrl").
-include("jose_jwt.hrl").

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
-export([decrypt/2]).
-export([encrypt/2]).
-export([encrypt/3]).
-export([merge/2]).
-export([peek/1]).
-export([peek_payload/1]).
-export([peek_protected/1]).
-export([sign/2]).
-export([sign/3]).
-export([verify/2]).
-export([verify_strict/3]).

%%====================================================================
%% Decode API functions
%%====================================================================

from(List) when is_list(List) ->
	[from(Element) || Element <- List];
from({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({Modules, Map});
from({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	from_binary({Modules, Binary});
from(JWT=#jose_jwt{}) ->
	JWT;
from(Other) when is_map(Other) orelse is_binary(Other) ->
	from({#{}, Other}).

from_binary(List) when is_list(List) ->
	[from_binary(Element) || Element <- List];
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

from_map(List) when is_list(List) ->
	[from_map(Element) || Element <- List];
from_map(Map) when is_map(Map) ->
	from_map({#{}, Map});
from_map({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({#jose_jwt{}, Modules, Map});
from_map({JWT, _Modules, Fields}) ->
	JWT#jose_jwt{ fields = Fields }.

%%====================================================================
%% Encode API functions
%%====================================================================

to_binary(List) when is_list(List) ->
	[to_binary(Element) || Element <- List];
to_binary(JWT=#jose_jwt{}) ->
	{Modules, Map} = to_map(JWT),
	{Modules, jose:encode(Map)};
to_binary(Other) ->
	to_binary(from(Other)).

to_file(File, JWT=#jose_jwt{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_binary(JWT),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_file(File, from(Other)).

to_map(List) when is_list(List) ->
	[to_map(Element) || Element <- List];
to_map(JWT=#jose_jwt{fields=Fields}) ->
	record_to_map(JWT, #{}, Fields);
to_map(Other) ->
	to_map(from(Other)).

%%====================================================================
%% API functions
%%====================================================================

decrypt(Key, {Modules, Encrypted}) when is_map(Modules) andalso is_map(Encrypted) ->
	{JWTBinary, JWE=#jose_jwe{}} = jose_jwe:block_decrypt(Key, {Modules, Encrypted}),
	{JWE, from_binary({Modules, JWTBinary})};
decrypt(Key, {Modules, Encrypted = << ${, _/binary >>}) when is_map(Modules) ->
	EncryptedMap = jose:decode(Encrypted),
	decrypt(Key, {Modules, EncryptedMap});
decrypt(Key, {Modules, Encrypted}) when is_map(Modules) andalso is_binary(Encrypted) ->
	{JWTBinary, JWE=#jose_jwe{}} = jose_jwe:block_decrypt(Key, {Modules, Encrypted}),
	{JWE, from_binary({Modules, JWTBinary})};
decrypt(Key, Encrypted) when is_map(Encrypted) orelse is_binary(Encrypted) ->
	decrypt(Key, {#{}, Encrypted}).

encrypt(JWK=#jose_jwk{}, JWT=#jose_jwt{}) ->
	encrypt(JWK, jose_jwk:block_encryptor(JWK), JWT);
encrypt(JWKOther, JWTOther) ->
	encrypt(jose_jwk:from(JWKOther), from(JWTOther)).

encrypt(JWK=#jose_jwk{}, JWE=#jose_jwe{}, JWT=#jose_jwt{}) ->
	{Modules0, JWTBinary} = to_binary(JWT),
	{Modules1, SignedMap} = jose_jwk:block_encrypt(JWTBinary, JWE, JWK),
	{maps:merge(Modules0, Modules1), SignedMap};
encrypt(JWKOther, {JWEModules, JWEMap=#{ <<"typ">> := _ }}, JWTOther) ->
	encrypt(JWKOther, jose_jwe:from({JWEModules, JWEMap}), JWTOther);
encrypt(JWKOther, {JWEModules, JWEMap0}, JWTOther) when is_map(JWEMap0) ->
	Keys = [<<"typ">>] -- maps:keys(JWEMap0),
	JWEMap1 = normalize_block_encryptor(Keys, JWEMap0),
	encrypt(JWKOther, {JWEModules, JWEMap1}, JWTOther);
encrypt(JWKOther, JWEMap, JWTOther) when is_map(JWEMap) ->
	encrypt(JWKOther, {#{}, JWEMap}, JWTOther);
encrypt(JWKOther, JWEOther, JWTOther) ->
	encrypt(jose_jwk:from(JWKOther), jose_jwe:from(JWEOther), from(JWTOther)).

merge(LeftJWT=#jose_jwt{}, RightMap) when is_map(RightMap) ->
	{Modules, LeftMap} = to_map(LeftJWT),
	from_map({Modules, maps:merge(LeftMap, RightMap)});
merge(LeftOther, RightJWT=#jose_jwt{}) ->
	merge(LeftOther, element(2, to_map(RightJWT)));
merge(LeftOther, RightMap) when is_map(RightMap) ->
	merge(from(LeftOther), RightMap).

peek(Signed) ->
	peek_payload(Signed).

peek_payload(Signed) ->
	from(jose_jws:peek_payload(Signed)).

peek_protected(Signed) ->
	jose_jws:from(jose_jws:peek_protected(Signed)).

sign(JWK=#jose_jwk{}, JWT=#jose_jwt{}) ->
	sign(JWK, jose_jwk:signer(JWK), JWT);
sign([], JWTOther) ->
	erlang:error({badarg, [[], JWTOther]});
sign(JWKOther, JWTOther) ->
	sign(jose_jwk:from(JWKOther), from(JWTOther)).

sign(JWK=#jose_jwk{}, JWS=#jose_jws{}, JWT=#jose_jwt{}) ->
	{Modules0, JWTBinary} = to_binary(JWT),
	{Modules1, SignedMap} = jose_jwk:sign(JWTBinary, JWS, JWK),
	{maps:merge(Modules0, Modules1), SignedMap};
sign(JWKOther, {JWSModules, JWSMap=#{ <<"typ">> := _ }}, JWTOther) ->
	sign(JWKOther, jose_jws:from({JWSModules, JWSMap}), JWTOther);
sign(JWKOther, {JWSModules, JWSMap0}, JWTOther) when is_map(JWSMap0) ->
	Keys = [<<"typ">>] -- maps:keys(JWSMap0),
	JWSMap1 = normalize_signer(Keys, JWSMap0),
	sign(JWKOther, {JWSModules, JWSMap1}, JWTOther);
sign(JWKOther, JWSMap, JWTOther) when is_map(JWSMap) ->
	sign(JWKOther, {#{}, JWSMap}, JWTOther);
sign([], JWSOther, JWTOther) ->
	erlang:error({badarg, [[], JWSOther, JWTOther]});
sign(JWKOther, JWSOther, JWTOther) ->
	sign(jose_jwk:from(JWKOther), jose_jws:from(JWSOther), from(JWTOther)).

verify(JWK=#jose_jwk{}, {Modules, Signed}) ->
	{Verified, JWTBinary, JWS} = jose_jwk:verify({Modules, Signed}, JWK),
	{Verified, from_binary({Modules, JWTBinary}), JWS};
verify(Other, SignedBinary) when is_binary(SignedBinary) ->
	verify(Other, {#{}, SignedBinary});
verify(Other, SignedMap) when is_map(SignedMap) ->
	verify(Other, {#{}, SignedMap});
verify(JWK=#jose_jwk{}, Signed) ->
	erlang:error({badarg, [JWK, Signed]});
verify([], Signed) ->
	erlang:error({badarg, [[], Signed]});
verify(Other, Signed) ->
	verify(jose_jwk:from(Other), Signed).

verify_strict(JWK=#jose_jwk{}, Allow, {Modules, Signed}) ->
	{Verified, JWTBinary, JWS} = jose_jwk:verify_strict({Modules, Signed}, Allow, JWK),
	{Verified, from_binary({Modules, JWTBinary}), JWS};
verify_strict(Other, Allow, SignedBinary) when is_binary(SignedBinary) ->
	verify_strict(Other, Allow, {#{}, SignedBinary});
verify_strict(Other, Allow, SignedMap) when is_map(SignedMap) ->
	verify_strict(Other, Allow, {#{}, SignedMap});
verify_strict(JWK=#jose_jwk{}, Allow, Signed) ->
	erlang:error({badarg, [JWK, Allow, Signed]});
verify_strict([], Allow, Signed) ->
	erlang:error({badarg, [[], Allow, Signed]});
verify_strict(Other, Allow, Signed) ->
	verify_strict(jose_jwk:from(Other), Allow, Signed).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
normalize_block_encryptor([<<"typ">> | Keys], Map) ->
	normalize_block_encryptor(Keys, Map#{ <<"typ">> => <<"JWT">> });
normalize_block_encryptor([], Map) ->
	Map.

%% @private
normalize_signer([<<"typ">> | Keys], Map) ->
	normalize_signer(Keys, Map#{ <<"typ">> => <<"JWT">> });
normalize_signer([], Map) ->
	Map.

%% @private
record_to_map(_JWT, Modules, Fields) ->
	{Modules, Fields}.
