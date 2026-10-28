%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  24 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk_pem).

-include("jose_public_key.hrl").

%% API
-export([from_binary/1]).
-export([from_binary/2]).
-export([from_certificate/1]).
-export([from_public_key_info/1]).
-export([to_binary/3]).

%%====================================================================
%% API functions
%%====================================================================

from_binary(PEMBinary) when is_binary(PEMBinary) ->
	case jose_public_key:pem_decode(PEMBinary) of
		[CertificatePEMEntry={'Certificate', _, not_encrypted}] ->
			from_certificate(CertificatePEMEntry);
		[PEMEntry] ->
			jose_jwk_kty:from_key(jose_public_key:pem_entry_decode(PEMEntry));
		PEMDecodeError ->
			PEMDecodeError
	end.

from_binary(Password, EncryptedPEMBinary) when is_binary(EncryptedPEMBinary) ->
	case jose_public_key:pem_decode(EncryptedPEMBinary) of
		[EncryptedPEMEntry] ->
			PasswordString = unicode:characters_to_list(Password),
			jose_jwk_kty:from_key(jose_public_key:pem_entry_decode(EncryptedPEMEntry, PasswordString));
		PEMDecodeError ->
			PEMDecodeError
	end.

from_certificate(CertificateBinary) when is_binary(CertificateBinary) ->
	case jose_public_key:pem_decode(CertificateBinary) of
		[CertificatePEMEntry={'Certificate', _, not_encrypted}] ->
			from_certificate(CertificatePEMEntry);
		PEMDecodeError ->
			{error, {pem_decode, PEMDecodeError}}
	end;
from_certificate(CertificatePEMEntry={'Certificate', _, not_encrypted}) ->
	case jose_public_key:pem_entry_decode(CertificatePEMEntry) of
		Certificate=#'Certificate'{} ->
			from_certificate(Certificate);
		PEMEntryDecodeError ->
			{error, {pem_entry_decode, PEMEntryDecodeError}}
	end;
from_certificate(#'Certificate'{tbsCertificate=#'TBSCertificate'{subjectPublicKeyInfo=#'SubjectPublicKeyInfo'{}=SubjectPublicKeyInfo}}) ->
	from_public_key_info(SubjectPublicKeyInfo).

from_public_key_info(#'SubjectPublicKeyInfo'{algorithm=#'AlgorithmIdentifier'{}}=SubjectPublicKeyInfo) ->
	from_public_key_info(jose_public_key:pem_entry_encode('SubjectPublicKeyInfo', SubjectPublicKeyInfo));
from_public_key_info(PEMEntry={'SubjectPublicKeyInfo', DER, not_encrypted}) when is_binary(DER) ->
	jose_jwk_kty:from_key(jose_public_key:pem_entry_decode(PEMEntry)).

to_binary(Password, 'PrivateKeyInfo', Key) ->
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
	PEMEntry = jose_public_key:pem_entry_encode('PrivateKeyInfo', Key, {CipherInfo, PasswordString}),
	jose_public_key:pem_encode([PEMEntry]);
to_binary(Password, KeyType, Key) ->
	CipherInfo = {"AES-256-CBC", crypto:strong_rand_bytes(16)},
	PasswordString = binary_to_list(iolist_to_binary(Password)),
	PEMEntry = jose_public_key:pem_entry_encode(KeyType, Key, {CipherInfo, PasswordString}),
	jose_public_key:pem_encode([PEMEntry]).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
