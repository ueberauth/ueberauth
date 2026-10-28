%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  02 Jan 2020 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk_der).

-include("jose_public_key.hrl").

%% API
-export([from_binary/1]).
-export([from_binary/2]).
-export([to_binary/3]).

%%====================================================================
%% API functions
%%====================================================================

from_binary(DERBinary) when is_binary(DERBinary) ->
	case jose_public_key:der_decode(DERBinary) of
		Key ->
			jose_jwk_kty:from_key(Key)
	end.

from_binary(Password, DERBinary) when is_binary(DERBinary) ->
	case jose_public_key:der_decode(DERBinary) of
		#'EncryptedPrivateKeyInfo'{
			encryptionAlgorithm = AlgorithmInfo,
			encryptedData = EncryptedDER
		} ->
			CipherInfo = jose_public_key:decrypt_parameters(AlgorithmInfo),
			DecryptedDER = jose_public_key:decipher({'PrivateKeyInfo', EncryptedDER, CipherInfo}, Password),
			from_binary(DecryptedDER);
		Key ->
			jose_jwk_kty:from_key(Key)
	end.

to_binary(Password, _KeyType, Key) ->
	CipherInfo = {"AES-256-CBC", #'PBES2-params'{
		keyDerivationFunc = #'PBES2-params_keyDerivationFunc'{
			algorithm = ?'id-PBKDF2',
			parameters = #'PBKDF2-params'{
				salt = {specified, crypto:strong_rand_bytes(?JOSE_PBES2_SALT_BYTES)},
				iterationCount = ?JOSE_PBES2_ITERATION_COUNT,
				keyLength = asn1_NOVALUE,
				prf = #'PBKDF2-params_prf'{
					algorithm = ?'id-hmacWithSHA256',
					parameters = {asn1_OPENTYPE, <<5, 0>>}
				}
			}
		},
		encryptionScheme = #'PBES2-params_encryptionScheme'{
			algorithm = ?'id-aes256-CBC',
			parameters = {asn1_OPENTYPE, <<4, 16, (crypto:strong_rand_bytes(16))/binary>>}
		}
	}},
	PasswordString = binary_to_list(iolist_to_binary(Password)),
	DecryptedDER = jose_public_key:der_encode('PrivateKeyInfo', Key),
	EncryptedDER = jose_public_key:cipher(DecryptedDER, CipherInfo, PasswordString),
	AlgorithmInfo = jose_public_key:encrypt_parameters(CipherInfo),
	jose_public_key:der_encode('EncryptedPrivateKeyInfo', #'EncryptedPrivateKeyInfo'{
		encryptionAlgorithm = AlgorithmInfo,
		encryptedData = EncryptedDER
	}).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
