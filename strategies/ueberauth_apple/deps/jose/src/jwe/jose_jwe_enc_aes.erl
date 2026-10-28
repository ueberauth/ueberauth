%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  22 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_enc_aes).
-behaviour(jose_jwe).
-behaviour(jose_jwe_enc).

%% jose_jwe callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jwe_enc callbacks
-export([algorithm/1]).
-export([bits/1]).
-export([block_decrypt/4]).
-export([block_encrypt/4]).
-export([next_cek/1]).
-export([next_iv/1]).
%% API
-export([cipher_supported/0]).
-export([hmac_supported/0]).

%% Types
-type cipher()   :: aes_cbc | aes_gcm.
-type key_size() :: 128 | 192 | 256.

-record(jose_jwe_enc_aes, {
	cipher  = undefined :: undefined | {cipher(), key_size()},
	bits    = undefined :: undefined | pos_integer(),
	cek_len = undefined :: undefined | pos_integer(),
	iv_len  = undefined :: undefined | pos_integer(),
	enc_len = undefined :: undefined | pos_integer(),
	mac_len = undefined :: undefined | pos_integer(),
	tag_len = undefined :: undefined | pos_integer(),
	hmac    = undefined :: undefined | sha256 | sha384 | sha512
}).

-type enc() :: #jose_jwe_enc_aes{}.

-export_type([enc/0]).

-define(AES_128_CBC_HMAC_SHA_256, #jose_jwe_enc_aes{
	cipher  = {aes_cbc, 128},
	bits    = 256,
	cek_len = 32,
	iv_len  = 16,
	enc_len = 16,
	mac_len = 16,
	tag_len = 16,
	hmac    = sha256
}).

-define(AES_192_CBC_HMAC_SHA_384, #jose_jwe_enc_aes{
	cipher  = {aes_cbc, 192},
	bits    = 384,
	cek_len = 48,
	iv_len  = 16,
	enc_len = 24,
	mac_len = 24,
	tag_len = 24,
	hmac    = sha384
}).

-define(AES_256_CBC_HMAC_SHA_512, #jose_jwe_enc_aes{
	cipher  = {aes_cbc, 256},
	bits    = 512,
	cek_len = 64,
	iv_len  = 16,
	enc_len = 32,
	mac_len = 32,
	tag_len = 32,
	hmac    = sha512
}).

-define(AES_128_GCM, #jose_jwe_enc_aes{
	cipher  = {aes_gcm, 128},
	bits    = 128,
	cek_len = 16,
	iv_len  = 12
}).

-define(AES_192_GCM, #jose_jwe_enc_aes{
	cipher  = {aes_gcm, 192},
	bits    = 192,
	cek_len = 24,
	iv_len  = 12
}).

-define(AES_256_GCM, #jose_jwe_enc_aes{
	cipher  = {aes_gcm, 256},
	bits    = 256,
	cek_len = 32,
	iv_len  = 12
}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"enc">> := <<"A128CBC-HS256">> }) ->
	{?AES_128_CBC_HMAC_SHA_256, maps:remove(<<"enc">>, F)};
from_map(F = #{ <<"enc">> := <<"A192CBC-HS384">> }) ->
	{?AES_192_CBC_HMAC_SHA_384, maps:remove(<<"enc">>, F)};
from_map(F = #{ <<"enc">> := <<"A256CBC-HS512">> }) ->
	{?AES_256_CBC_HMAC_SHA_512, maps:remove(<<"enc">>, F)};
from_map(F = #{ <<"enc">> := <<"A128GCM">> }) ->
	{?AES_128_GCM, maps:remove(<<"enc">>, F)};
from_map(F = #{ <<"enc">> := <<"A192GCM">> }) ->
	{?AES_192_GCM, maps:remove(<<"enc">>, F)};
from_map(F = #{ <<"enc">> := <<"A256GCM">> }) ->
	{?AES_256_GCM, maps:remove(<<"enc">>, F)}.

to_map(?AES_128_CBC_HMAC_SHA_256, F) ->
	F#{ <<"enc">> => <<"A128CBC-HS256">> };
to_map(?AES_192_CBC_HMAC_SHA_384, F) ->
	F#{ <<"enc">> => <<"A192CBC-HS384">> };
to_map(?AES_256_CBC_HMAC_SHA_512, F) ->
	F#{ <<"enc">> => <<"A256CBC-HS512">> };
to_map(?AES_128_GCM, F) ->
	F#{ <<"enc">> => <<"A128GCM">> };
to_map(?AES_192_GCM, F) ->
	F#{ <<"enc">> => <<"A192GCM">> };
to_map(?AES_256_GCM, F) ->
	F#{ <<"enc">> => <<"A256GCM">> }.

%%====================================================================
%% jose_jwe_enc callbacks
%%====================================================================

algorithm(?AES_128_CBC_HMAC_SHA_256) -> <<"A128CBC-HS256">>;
algorithm(?AES_192_CBC_HMAC_SHA_384) -> <<"A192CBC-HS384">>;
algorithm(?AES_256_CBC_HMAC_SHA_512) -> <<"A256CBC-HS512">>;
algorithm(?AES_128_GCM)              -> <<"A128GCM">>;
algorithm(?AES_192_GCM)              -> <<"A192GCM">>;
algorithm(?AES_256_GCM)              -> <<"A256GCM">>.

bits(#jose_jwe_enc_aes{bits=Bits}) -> Bits.

block_decrypt({AAD, CipherText, CipherTag}, CEK, IV, #jose_jwe_enc_aes{
		cipher=Cipher,
		cek_len=CEKLen,
		hmac=undefined})
			when byte_size(CEK) =:= CEKLen
			andalso bit_size(IV) > 0 ->
	jose_jwa:block_decrypt(Cipher, CEK, IV, {AAD, CipherText, CipherTag});
block_decrypt({AAD, CipherText, CipherTag}, CEK, IV, #jose_jwe_enc_aes{
		cipher=Cipher,
		cek_len=CEKLen,
		iv_len=IVLen,
		enc_len=EncLen,
		mac_len=MacLen,
		tag_len=TagLen,
		hmac=HMAC})
			when byte_size(CEK) =:= CEKLen
			andalso byte_size(IV) =:= IVLen ->
	<< MacKey:MacLen/binary, EncKey:EncLen/binary >> = CEK,
	AADLength = << (bit_size(AAD)):1/unsigned-big-integer-unit:64 >>,
	MacData = << AAD/binary, IV/binary, CipherText/binary, AADLength/binary >>,
	case jose_crypto_compat:mac(hmac, HMAC, MacKey, MacData) of
		<< CipherTag:TagLen/binary, _/binary >> ->
			PlainText = jose_jwa_pkcs7:unpad(jose_jwa:block_decrypt(Cipher, EncKey, IV, CipherText)),
			PlainText;
		_ ->
			error
	end.

block_encrypt({AAD, PlainText}, CEK, IV, #jose_jwe_enc_aes{
		cipher=Cipher,
		cek_len=CEKLen,
		hmac=undefined})
			when byte_size(CEK) =:= CEKLen
			andalso bit_size(IV) > 0 ->
	jose_jwa:block_encrypt(Cipher, CEK, IV, {AAD, PlainText});
block_encrypt({AAD, PlainText}, CEK, IV, #jose_jwe_enc_aes{
		cipher=Cipher,
		cek_len=CEKLen,
		iv_len=IVLen,
		enc_len=EncLen,
		mac_len=MacLen,
		tag_len=TagLen,
		hmac=HMAC})
			when byte_size(CEK) =:= CEKLen
			andalso byte_size(IV) =:= IVLen ->
	<< MacKey:MacLen/binary, EncKey:EncLen/binary, _/binary >> = CEK,
	CipherText = jose_jwa:block_encrypt(Cipher, EncKey, IV, jose_jwa_pkcs7:pad(PlainText)),
	AADLength = << (bit_size(AAD)):1/unsigned-big-integer-unit:64 >>,
	MacData = << AAD/binary, IV/binary, CipherText/binary, AADLength/binary >>,
	<< CipherTag:TagLen/binary, _/binary >> = jose_crypto_compat:mac(hmac, HMAC, MacKey, MacData),
	{CipherText, CipherTag}.

next_cek(#jose_jwe_enc_aes{cek_len=CEKLen}) ->
	crypto:strong_rand_bytes(CEKLen).

next_iv(#jose_jwe_enc_aes{iv_len=IVLen}) ->
	crypto:strong_rand_bytes(IVLen).

%%====================================================================
%% API functions
%%====================================================================

cipher_supported() ->
	[aes_cbc, aes_gcm].

hmac_supported() ->
	[sha256, sha384, sha512].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
