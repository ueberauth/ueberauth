%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  18 May 2017 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_public_key).

-include("jose_compat.hrl").
-include("jose_public_key.hrl").

%% API
-export([cipher/3]).
-export([decipher/2]).
-export([encrypt_parameters/1]).
-export([decrypt_parameters/1]).
-export([der_decode/1]).
-export([der_decode/2]).
-export([der_encode/2]).
-export([pem_decode/1]).
-export([pem_encode/1]).
-export([pem_entry_decode/1]).
-export([pem_entry_decode/2]).
-export([pem_entry_encode/2]).
-export([pem_entry_encode/3]).

%%====================================================================
%% API functions
%%====================================================================

cipher(DecryptedDER, CipherInfo={Cipher, #'PBES2-params'{}}, Password)
		when Cipher == "AES-128-CBC" orelse Cipher == "AES-192-CBC" orelse Cipher == "AES-256-CBC" ->
	{true, EncryptedDER} = pem_cipher(DecryptedDER, CipherInfo, Password),
	EncryptedDER;
cipher(DecryptedDER, CipherInfo, Password) ->
	try
		pubkey_pem:cipher(DecryptedDER, CipherInfo, Password)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case pem_cipher(DecryptedDER, CipherInfo, Password) of
				{true, EncryptedDER} ->
					EncryptedDER;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

decipher({_, EncryptedDER, CipherInfo={Cipher, #'PBES2-params'{}}}, Password)
		when Cipher == "AES-128-CBC" orelse Cipher == "AES-192-CBC" orelse Cipher == "AES-256-CBC" ->
	{true, DecryptedDER} = pem_decipher(EncryptedDER, CipherInfo, Password),
	DecryptedDER;
decipher(Encrypted = {_, EncryptedDER, CipherInfo}, Password) ->
	try
		pubkey_pem:decipher(Encrypted, Password)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case pem_decipher(EncryptedDER, CipherInfo, Password) of
				{true, DecryptedDER} ->
					DecryptedDER;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

encrypt_parameters(Arg = {Cipher, Params}) ->
	try
		pubkey_pbe:encrypt_parameters(Arg)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case encrypt_parameters(Cipher, Params) of
				{true, Result} ->
					Result;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

%% @private
encrypt_parameters(_Cipher, #'PBES2-params'{} = Params) ->
	{ok, Der} ='PKCS-FRAME':encode('PBES2-params', Params),
	{true, #'EncryptedPrivateKeyInfo_encryptionAlgorithm'{algorithm = ?'id-PBES2', parameters = encode_handle_open_type_wrapper(Der)}};
encrypt_parameters(_, _) ->
	false.

decrypt_parameters(Arg = #'EncryptedPrivateKeyInfo_encryptionAlgorithm'{algorithm = Oid, parameters = Param}) ->
	try
		pubkey_pbe:decrypt_parameters(Arg)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case decrypt_parameters(Oid, decode_handle_open_type_wrapper(Param)) of
				{true, Result} ->
					Result;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

%% @private
decrypt_parameters(?'id-PBES2', DekParams) ->
	{ok, Params} = 'PKCS-FRAME':decode('PBES2-params', DekParams),
	case cipher(Params#'PBES2-params'.encryptionScheme) of
		{true, Cipher} ->
			{true, {Cipher, Params}};
		false ->
			false
	end;
decrypt_parameters(_, _) ->
	false.

%% @private
cipher(#'PBES2-params_encryptionScheme'{algorithm = ?'id-aes128-CBC'}) ->
	{true, "AES-128-CBC"};
cipher(#'PBES2-params_encryptionScheme'{algorithm = ?'id-aes192-CBC'}) ->
	{true, "AES-192-CBC"};
cipher(#'PBES2-params_encryptionScheme'{algorithm = ?'id-aes256-CBC'}) ->
	{true, "AES-256-CBC"};
cipher(_) ->
	false.

der_decode(DER) when is_binary(DER) ->
	Result =
		try_der_decode([
			'Certificate',
			'RSAPrivateKey',
			'RSAPublicKey',
			'SubjectPublicKeyInfo',
			'DSAPrivateKey',
			'DHParameter',
			'PrivateKeyInfo',
			'EncryptedPrivateKeyInfo',
			'CertificationRequest',
			'ContentInfo',
			'CertificateList',
			'EcpkParameters',
			'ECPrivateKey',
			{no_asn1, new_openssh} %% Temporarily in the prototype of this format
		], DER),
	case Result of
		PrivateKeyInfo=#'PrivateKeyInfo'{} ->
			i2k(PrivateKeyInfo);
		ECPrivateKey={'ECPrivateKey', _, _, _, _, _} -> %% OTP 24
			i2k(ECPrivateKey);
		ECPrivateKey={'ECPrivateKey', _, _, _, _} -> %% OTP 23
			i2k(ECPrivateKey);
		SubjectPublicKeyInfo=#'SubjectPublicKeyInfo'{} ->
			i2k(SubjectPublicKeyInfo);
		Other ->
			Other
	end.

der_decode('EcpkParameters', EcpkParameters = {namedCurve, _}) ->
	EcpkParameters;
der_decode(ASN1Type, DER) when is_atom(ASN1Type) andalso is_binary(DER) ->
	public_key:der_decode(ASN1Type, DER).

der_encode(ASN1Type, Entity) when is_atom(ASN1Type) ->
	try
		public_key:der_encode(ASN1Type, Entity)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case der_enc(ASN1Type, Entity) of
				{true, DERBinary} ->
					DERBinary;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

pem_decode(PEMBinary) when is_binary(PEMBinary) ->
	try
		public_key:pem_decode(PEMBinary)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case pem_dec(PEMBinary) of
				{true, PEMEntries} ->
					PEMEntries;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

pem_encode(PEMEntries) when is_list(PEMEntries) ->
	try
		public_key:pem_encode(PEMEntries)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case pem_enc(PEMEntries) of
				{true, PEMBinary} ->
					PEMBinary;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

pem_entry_decode(PEMEntry) ->
	Result =
		try
			public_key:pem_entry_decode(PEMEntry)
		catch
			?COMPAT_CATCH(Class, Reason, ST) ->
				case pem_entry_dec(PEMEntry) of
					{true, DecodedPEMEntry} ->
						DecodedPEMEntry;
					false ->
						erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
				end
		end,
	case Result of
		PrivateKeyInfo=#'PrivateKeyInfo'{} ->
			i2k(PrivateKeyInfo);
		ECPrivateKey={'ECPrivateKey', _, _, _, _, _} -> %% OTP 24
			i2k(ECPrivateKey);
		ECPrivateKey={'ECPrivateKey', _, _, _, _} -> %% OTP 23
			i2k(ECPrivateKey);
		SubjectPublicKeyInfo=#'SubjectPublicKeyInfo'{} ->
			i2k(SubjectPublicKeyInfo);
		Other ->
			Other
	end.

pem_entry_decode(PEMEntry, Password) ->
	Result =
		try
			case PEMEntry of
				{Type, _, {Cipher, #'PBES2-params'{}}}
						when Cipher == "AES-128-CBC" orelse Cipher == "AES-192-CBC" orelse Cipher == "AES-256-CBC" ->
					public_key:pem_entry_decode({Type, decipher(PEMEntry, Password), not_encrypted});
				_ ->
					public_key:pem_entry_decode(PEMEntry, Password)
			end
		catch
			?COMPAT_CATCH(Class, Reason, ST) ->
				case pem_entry_dec(PEMEntry, Password) of
					{true, DecodedPEMEntry} ->
						DecodedPEMEntry;
					false ->
						erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
				end
		end,
	case Result of
		PrivateKeyInfo=#'PrivateKeyInfo'{} ->
			i2k(PrivateKeyInfo);
		ECPrivateKey={'ECPrivateKey', _, _, _, _, _} -> %% OTP 24
			i2k(ECPrivateKey);
		ECPrivateKey={'ECPrivateKey', _, _, _, _} -> %% OTP 23
			i2k(ECPrivateKey);
		SubjectPublicKeyInfo=#'SubjectPublicKeyInfo'{} ->
			i2k(SubjectPublicKeyInfo);
		Other ->
			Other
	end.

pem_entry_encode(ASN1Type, Entity) ->
	try
		public_key:pem_entry_encode(ASN1Type, Entity)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case pem_entry_enc(ASN1Type, Entity) of
				{true, PEMEntry} ->
					PEMEntry;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

pem_entry_encode('PrivateKeyInfo', Entity, Password={{Cipher, #'PBES2-params'{}}, _})
		when Cipher == "AES-128-CBC" orelse Cipher == "AES-192-CBC" orelse Cipher == "AES-256-CBC" ->
	{true, Encoded} = pem_entry_enc1('PrivateKeyInfo', Entity, Password),
	Encoded;
pem_entry_encode(ASN1Type, Entity, Password) ->
	try
		public_key:pem_entry_encode(ASN1Type, Entity, Password)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case pem_entry_enc(ASN1Type, Entity, Password) of
				{true, PEMEntry} ->
					PEMEntry;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
try_der_decode([ASN1Type | Rest], DER) ->
	try der_decode(ASN1Type, DER) of
		Result ->
			Result
	catch
		?COMPAT_CATCH(error, Reason={badmatch, _}, ST) ->
			try_der_decode(Rest, DER, {error, Reason, ?COMPAT_GET_STACKTRACE(ST)})
	end.

%% @private
try_der_decode([], _DER, {Class, Reason, Stacktrace}) ->
	erlang:raise(Class, Reason, Stacktrace);
try_der_decode([ASN1Type | Rest], DER, _) ->
	try der_decode(ASN1Type, DER) of
		Result ->
			Result
	catch
		?COMPAT_CATCH(error, Reason={badmatch, _}, ST) ->
			try_der_decode(Rest, DER, {error, Reason, ?COMPAT_GET_STACKTRACE(ST)})
	end.

%% @private
der_enc('EdDSA25519PrivateKey', K=#'jose_EdDSA25519PrivateKey'{}) ->
	EncodedDER = public_key:der_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('EdDSA25519PublicKey', K=#'jose_EdDSA25519PublicKey'{}) ->
	EncodedDER = public_key:der_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('EdDSA448PrivateKey', K=#'jose_EdDSA448PrivateKey'{}) ->
	EncodedDER = public_key:der_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('EdDSA448PublicKey', K=#'jose_EdDSA448PublicKey'{}) ->
	EncodedDER = public_key:der_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedDER};
%% OTP 29+ expects the ECParameters as a term instead of a DER binary, so
%% let public_key build the AlgorithmIdentifier for the running version.
der_enc('SubjectPublicKeyInfo', K={#'ECPoint'{}, _ECParameters}) ->
	{'SubjectPublicKeyInfo', EncodedDER, not_encrypted} = public_key:pem_entry_encode('SubjectPublicKeyInfo', K),
	{true, EncodedDER};
der_enc('SubjectPublicKeyInfo', K)  ->
	EncodedDER = public_key:der_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('X25519PrivateKey', K=#'jose_X25519PrivateKey'{}) ->
	EncodedDER = public_key:der_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('X25519PublicKey', K=#'jose_X25519PublicKey'{}) ->
	EncodedDER = public_key:der_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('X448PrivateKey', K=#'jose_X448PrivateKey'{}) ->
	EncodedDER = public_key:der_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('X448PublicKey', K=#'jose_X448PublicKey'{}) ->
	EncodedDER = public_key:der_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('PrivateKeyInfo', K) ->
	case K of
		#'jose_EdDSA25519PrivateKey'{} -> der_enc('EdDSA25519PrivateKey', K);
		#'jose_EdDSA448PrivateKey'{} -> der_enc('EdDSA448PrivateKey', K);
		#'jose_X25519PrivateKey'{} -> der_enc('X25519PrivateKey', K);
		#'jose_X448PrivateKey'{} -> der_enc('X448PrivateKey', K);
		#'ECPrivateKey'{} -> der_enc('ECPrivateKey', K);
		#'RSAPrivateKey'{} -> der_enc('RSAPrivateKey', K);
		_ -> false
	end;
%% Compatibility between PKCS1 and PKCS8 versions of public_key
der_enc('ECPrivateKey', K=#'ECPrivateKey'{}) ->
	EncodedDER = public_key:der_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc('RSAPrivateKey', K=#'RSAPrivateKey'{}) ->
	EncodedDER = public_key:der_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedDER};
der_enc(_, _) ->
	false.

%% @private
pem_dec(PEMBinary) ->
	pem_dec(pem_dec_split_bin(PEMBinary), []).

%% @private
pem_dec([], Entries) ->
	{true, lists:reverse(Entries)};
pem_dec([<<>>], Entries) ->
	{true, lists:reverse(Entries)};
pem_dec([<<>> | Lines], Entries) ->
	pem_dec(Lines, Entries);
pem_dec([Start| Lines], Entries) ->
	case pem_end(Start) of
		undefined ->
			pem_dec(Lines, Entries);
		_End ->
			{Entry, RestLines} = pem_dec_join_entry(Lines, []),
			case pem_dec_entry(Start, Entry) of
				{true, Head} ->
					pem_dec(RestLines, [Head | Entries]);
				false ->
					false
			end
	end.

%% @private
pem_dec_entry(Start, Lines) ->
	Type = asn1_type(Start),
	Cs = erlang:iolist_to_binary(Lines),
	Decoded = base64:mime_decode(Cs),
	case Type of
		'EncryptedPrivateKeyInfo'->
			decode_encrypted_private_keyinfo(Decoded);
		_ ->
			{true, {Type, Decoded, not_encrypted}}
	end.

%% @private
decode_encrypted_private_keyinfo(Der) ->
	#'EncryptedPrivateKeyInfo'{encryptionAlgorithm = AlgorithmInfo, encryptedData = Data} = der_decode('EncryptedPrivateKeyInfo', Der),
	DecryptParams = decrypt_parameters(AlgorithmInfo),
	{true, {'PrivateKeyInfo', Data, DecryptParams}}.

%% @private
%% Ignore white space at end of line
pem_dec_join_entry([<<"-----END ", _/binary>>| Lines], Entry) ->
	{lists:reverse(Entry), Lines};
pem_dec_join_entry([<<"-----END X509 CRL-----", _/binary>>| Lines], Entry) ->
	{lists:reverse(Entry), Lines};
pem_dec_join_entry([Line | Lines], Entry) ->
	pem_dec_join_entry(Lines, [Line | Entry]).

%% @private
pem_dec_split_bin(Bin) ->
	pem_dec_split_bin(0, Bin).

%% @private
pem_dec_split_bin(N, Bin) ->
	case Bin of
		<<Line:N/binary, "\r\n", Rest/binary>> ->
			[Line | pem_dec_split_bin(0, Rest)];
		<<Line:N/binary, "\n", Rest/binary>> ->
			[Line | pem_dec_split_bin(0, Rest)];
		<<Line:N/binary>> ->
			[Line];
		_ ->
		pem_dec_split_bin(N+1, Bin)
	end.

%% @private
asn1_type(<<"-----BEGIN CERTIFICATE-----">>) ->
	'Certificate';
asn1_type(<<"-----BEGIN RSA PRIVATE KEY-----">>) ->
	'RSAPrivateKey';
asn1_type(<<"-----BEGIN RSA PUBLIC KEY-----">>) ->
	'RSAPublicKey';
asn1_type(<<"-----BEGIN PUBLIC KEY-----">>) ->
	'SubjectPublicKeyInfo';
asn1_type(<<"-----BEGIN DSA PRIVATE KEY-----">>) ->
	'DSAPrivateKey';
asn1_type(<<"-----BEGIN DH PARAMETERS-----">>) ->
	'DHParameter';
asn1_type(<<"-----BEGIN PRIVATE KEY-----">>) ->
	'PrivateKeyInfo';
asn1_type(<<"-----BEGIN ENCRYPTED PRIVATE KEY-----">>) ->
	'EncryptedPrivateKeyInfo';
asn1_type(<<"-----BEGIN CERTIFICATE REQUEST-----">>) ->
	'CertificationRequest';
asn1_type(<<"-----BEGIN PKCS7-----">>) ->
	'ContentInfo';
asn1_type(<<"-----BEGIN X509 CRL-----">>) ->
	'CertificateList';
asn1_type(<<"-----BEGIN EC PARAMETERS-----">>) ->
	'EcpkParameters';
asn1_type(<<"-----BEGIN EC PRIVATE KEY-----">>) ->
	'ECPrivateKey';
asn1_type(<<"-----BEGIN OPENSSH PRIVATE KEY-----">>) ->
	{no_asn1, new_openssh}. %% Temporarily in the prototype of this format

%% @private
pem_end(<<"-----BEGIN CERTIFICATE-----">>) ->
	<<"-----END CERTIFICATE-----">>;
pem_end(<<"-----BEGIN RSA PRIVATE KEY-----">>) ->
	<<"-----END RSA PRIVATE KEY-----">>;
pem_end(<<"-----BEGIN RSA PUBLIC KEY-----">>) ->
	<<"-----END RSA PUBLIC KEY-----">>;
pem_end(<<"-----BEGIN PUBLIC KEY-----">>) ->
	<<"-----END PUBLIC KEY-----">>;
pem_end(<<"-----BEGIN DSA PRIVATE KEY-----">>) ->
	<<"-----END DSA PRIVATE KEY-----">>;
pem_end(<<"-----BEGIN DH PARAMETERS-----">>) ->
	<<"-----END DH PARAMETERS-----">>;
pem_end(<<"-----BEGIN PRIVATE KEY-----">>) ->
	<<"-----END PRIVATE KEY-----">>;
pem_end(<<"-----BEGIN ENCRYPTED PRIVATE KEY-----">>) ->
	<<"-----END ENCRYPTED PRIVATE KEY-----">>;
pem_end(<<"-----BEGIN CERTIFICATE REQUEST-----">>) ->
	<<"-----END CERTIFICATE REQUEST-----">>;
pem_end(<<"-----BEGIN PKCS7-----">>) ->
	<<"-----END PKCS7-----">>;
pem_end(<<"-----BEGIN X509 CRL-----">>) ->
	<<"-----END X509 CRL-----">>;
pem_end(<<"-----BEGIN EC PARAMETERS-----">>) ->
	<<"-----END EC PARAMETERS-----">>;
pem_end(<<"-----BEGIN EC PRIVATE KEY-----">>) ->
	<<"-----END EC PRIVATE KEY-----">>;
pem_end(<<"-----BEGIN OPENSSH PRIVATE KEY-----">>) ->
	<<"-----END OPENSSH PRIVATE KEY-----">>;
pem_end(_) ->
	undefined.

%% @private
pem_enc(Entries) ->
	pem_enc(Entries, []).

%% @private
pem_enc([Entry={'PrivateKeyInfo', _, _} | Entries], Acc) ->
	Encoded =
		try
			public_key:pem_encode([Entry])
		catch
			_:_ ->
				pem_entry_enc(Entry)
		end,
	pem_enc(Entries, [Encoded | Acc]);
pem_enc([Entry | Entries], Acc) ->
	Encoded = public_key:pem_encode([Entry]),
	pem_enc(Entries, [Encoded | Acc]);
pem_enc([], Acc) ->
	{true, erlang:iolist_to_binary(lists:reverse(Acc))}.

%% @private
pem_entry_dec({ASN1Type='PrivateKeyInfo', Der, not_encrypted}) ->
	Entity = der_decode(ASN1Type, Der),
	{true, i2k(Entity)};
pem_entry_dec({ASN1Type='SubjectPublicKeyInfo', Der, not_encrypted}) ->
	Entity = der_decode(ASN1Type, Der),
	{true, i2k(Entity)};
pem_entry_dec(_) ->
	false.

%% @private
pem_entry_dec({Asn1Type, EncryptedDer, CipherInfo = {_, #'PBES2-params'{}}}, Password) when is_atom(Asn1Type) ->
	case decipher({Asn1Type, EncryptedDer, CipherInfo}, Password) of
		DecryptedDer when is_binary(DecryptedDer) ->
			{true, der_decode(Asn1Type, DecryptedDer)};
		_ ->
			false
	end;
pem_entry_dec(PEMEntry, _Password) ->
	pem_entry_dec(PEMEntry).

%% @private
pem_entry_enc({'PrivateKeyInfo', Der, EncParams}) ->
	EncodedPEM = public_key:pem_encode([{'ECPrivateKey', Der, EncParams}]),
	erlang:iolist_to_binary(binary:split(EncodedPEM, <<" EC">>, [global, trim_all]));
pem_entry_enc(Entry) ->
	Entry.

%% @private
pem_entry_enc('EdDSA25519PrivateKey', K=#'jose_EdDSA25519PrivateKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('EdDSA25519PublicKey', K=#'jose_EdDSA25519PublicKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('EdDSA448PrivateKey', K=#'jose_EdDSA448PrivateKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('EdDSA448PublicKey', K=#'jose_EdDSA448PublicKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('X25519PrivateKey', K=#'jose_X25519PrivateKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('X25519PublicKey', K=#'jose_X25519PublicKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('X448PrivateKey', K=#'jose_X448PrivateKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('X448PublicKey', K=#'jose_X448PublicKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('SubjectPublicKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('PrivateKeyInfo', K) ->
	case K of
		#'jose_EdDSA25519PrivateKey'{} -> pem_entry_enc('EdDSA25519PrivateKey', K);
		#'jose_EdDSA448PrivateKey'{} -> pem_entry_enc('EdDSA448PrivateKey', K);
		#'jose_X25519PrivateKey'{} -> pem_entry_enc('X25519PrivateKey', K);
		#'jose_X448PrivateKey'{} -> pem_entry_enc('X448PrivateKey', K);
		#'ECPrivateKey'{} -> pem_entry_enc('ECPrivateKey', K);
		#'RSAPrivateKey'{} -> pem_entry_enc('RSAPrivateKey', K);
		_ -> false
	end;
%% Compatibility between PKCS1 and PKCS8 versions of public_key
pem_entry_enc('ECPrivateKey', K=#'ECPrivateKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc('RSAPrivateKey', K=#'RSAPrivateKey'{}) ->
	EncodedPEMEntry = public_key:pem_entry_encode('PrivateKeyInfo', k2i(K)),
	{true, EncodedPEMEntry};
pem_entry_enc(_, _) ->
	false.

%% @private
pem_entry_enc('EdDSA25519PrivateKey', K=#'jose_EdDSA25519PrivateKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('PrivateKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('EdDSA25519PublicKey', K=#'jose_EdDSA25519PublicKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('SubjectPublicKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('EdDSA448PrivateKey', K=#'jose_EdDSA448PrivateKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('PrivateKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('EdDSA448PublicKey', K=#'jose_EdDSA448PublicKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('SubjectPublicKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('X25519PrivateKey', K=#'jose_X25519PrivateKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('PrivateKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('X25519PublicKey', K=#'jose_X25519PublicKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('SubjectPublicKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('X448PrivateKey', K=#'jose_X448PrivateKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('PrivateKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('X448PublicKey', K=#'jose_X448PublicKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('SubjectPublicKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('PrivateKeyInfo', K, Password) ->
	case K of
		#'jose_EdDSA25519PrivateKey'{} -> pem_entry_enc('EdDSA25519PrivateKey', K, Password);
		#'jose_EdDSA448PrivateKey'{} -> pem_entry_enc('EdDSA448PrivateKey', K, Password);
		#'jose_X25519PrivateKey'{} -> pem_entry_enc('X25519PrivateKey', K, Password);
		#'jose_X448PrivateKey'{} -> pem_entry_enc('X448PrivateKey', K, Password);
		#'ECPrivateKey'{} -> pem_entry_enc('ECPrivateKey', K, Password);
		#'RSAPrivateKey'{} -> pem_entry_enc('RSAPrivateKey', K, Password);
		_ -> false
	end;
%% Compatibility between PKCS1 and PKCS8 versions of public_key
pem_entry_enc('ECPrivateKey', K=#'ECPrivateKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('PrivateKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc('RSAPrivateKey', K=#'RSAPrivateKey'{}, Password) ->
	EncodedPEMEntry = pem_entry_enc0('PrivateKeyInfo', k2i(K), Password),
	{true, EncodedPEMEntry};
pem_entry_enc(_, _, _) ->
	false.

%% @private
pem_entry_enc0(ASN1Type, Entry, Cipher) ->
	try
		public_key:pem_entry_encode(ASN1Type, Entry, Cipher)
	catch
		?COMPAT_CATCH(Class, Reason, ST) ->
			case pem_entry_enc1(ASN1Type, Entry, Cipher) of
				{true, Encoded} ->
					Encoded;
				false ->
					erlang:raise(Class, Reason, ?COMPAT_GET_STACKTRACE(ST))
			end
	end.

%% @private
pem_entry_enc1(ASN1Type, Entry, {CipherInfo={C, _}, Password}) when C == "AES-128-CBC" orelse C == "AES-192-CBC" orelse C == "AES-256-CBC" ->
	DecryptedDer = der_encode(ASN1Type, Entry),
	case cipher(DecryptedDer, CipherInfo, Password) of
		EncryptedDer when is_binary(EncryptedDer) ->
			{true, {ASN1Type, EncryptedDer, CipherInfo}};
		_ ->
			false
	end;
pem_entry_enc1(_, _, _) ->
	false.

%% @private
pem_cipher(Data, {Cipher = "AES-128-CBC", KeyDevParams}, Password) ->
	{Key, IV} = password_to_key_and_iv(Password, Cipher, KeyDevParams),
	{true, jose_crypto_compat:crypto_one_time(aes_128_cbc, Key, IV, jose_jwa_pkcs7:pad(Data), true)};
pem_cipher(Data, {Cipher = "AES-192-CBC", KeyDevParams}, Password) ->
	{Key, IV} = password_to_key_and_iv(Password, Cipher, KeyDevParams),
	{true, jose_crypto_compat:crypto_one_time(aes_192_cbc, Key, IV, jose_jwa_pkcs7:pad(Data), true)};
pem_cipher(Data, {Cipher = "AES-256-CBC", KeyDevParams}, Password) ->
	{Key, IV} = password_to_key_and_iv(Password, Cipher, KeyDevParams),
	{true, jose_crypto_compat:crypto_one_time(aes_256_cbc, Key, IV, jose_jwa_pkcs7:pad(Data), true)};
pem_cipher(_, _, _) ->
	false.

%% @private
pem_decipher(Data, {Cipher = "AES-128-CBC", KeyDevParams}, Password) ->
	{Key, IV} = password_to_key_and_iv(Password, Cipher, KeyDevParams),
	{true, jose_crypto_compat:crypto_one_time(aes_128_cbc, Key, IV, Data, false)};
pem_decipher(Data, {Cipher = "AES-192-CBC", KeyDevParams}, Password) ->
	{Key, IV} = password_to_key_and_iv(Password, Cipher, KeyDevParams),
	{true, jose_crypto_compat:crypto_one_time(aes_192_cbc, Key, IV, Data, false)};
pem_decipher(Data, {Cipher = "AES-256-CBC", KeyDevParams}, Password) ->
	{Key, IV} = password_to_key_and_iv(Password, Cipher, KeyDevParams),
	{true, jose_crypto_compat:crypto_one_time(aes_256_cbc, Key, IV, Data, false)};
pem_decipher(_, _, _) ->
	false.

%% @private
ceiling(Float) ->
	erlang:round(Float + 0.5).

%% @private
derived_key_length(_, Len) when is_integer(Len) ->
	Len;
derived_key_length(Cipher, _) when (Cipher == "AES-128-CBC"); (Cipher == ?'id-aes128-CBC') ->
	16;
derived_key_length(Cipher,_) when (Cipher == "AES-192-CBC"); (Cipher == ?'id-aes192-CBC') ->
	24;
derived_key_length(Cipher,_) when (Cipher == "AES-256-CBC"); (Cipher == ?'id-aes256-CBC') ->
	32.

%% @private
password_to_key_and_iv(Password, _Cipher, Params = #'PBES2-params'{}) ->
	{Salt, ItrCount, KeyLen, PseudoRandomFunction, PseudoHash, PseudoOtputLen, IV} = key_derivation_params(Params),
	%% Use the native implementation for the strengthened export defaults when
	%% available (OTP 24+). Older runtimes keep the existing derivation path.
	KeyMaterial = case erlang:function_exported(crypto, pbkdf2_hmac, 5) of
		true ->
			crypto:pbkdf2_hmac(PseudoHash, iolist_to_binary(Password), iolist_to_binary(Salt), ItrCount, KeyLen);
		false ->
			pubkey_pbe:pbdkdf2(Password, Salt, ItrCount, KeyLen, PseudoRandomFunction, PseudoHash, PseudoOtputLen)
	end,
	<<Key:KeyLen/binary, _/binary>> = KeyMaterial,
	{Key, IV};
password_to_key_and_iv(Password, _Cipher, {#'PBEParameter'{salt = Salt, iterationCount = Count}, Hash}) ->
	<<Key:8/binary, IV:8/binary, _/binary>> = pubkey_pbe:pbdkdf1(Password, Salt, Count, Hash),
	{Key, IV};
password_to_key_and_iv(Password, Cipher, KeyDevParams) ->
	%% PKCS5_SALT_LEN is 8 bytes
	<<Salt:8/binary,_/binary>> = KeyDevParams,
	KeyLen = derived_key_length(Cipher, undefined),
	<<Key:KeyLen/binary, _/binary>> = pem_encrypt(<<>>, Password, Salt, ceiling(KeyLen div 16), <<>>, md5),
	%% Old PEM encryption does not use standard encryption method
	%% pbdkdf1 and uses then salt as IV
	{Key, KeyDevParams}.

%% @private
pem_encrypt(_, _, _, 0, Acc, _) ->
	Acc;
pem_encrypt(Prev, Password, Salt, Count, Acc, Hash) ->
	Result = crypto:hash(Hash, [Prev, Password, Salt]),
	pem_encrypt(Result, Password, Salt, Count-1 , <<Acc/binary, Result/binary>>, Hash).

%% @private
key_derivation_params(#'PBES2-params'{keyDerivationFunc = KeyDerivationFunc, encryptionScheme = EncScheme}) ->
	#'PBES2-params_keyDerivationFunc'{
		algorithm = ?'id-PBKDF2',
		parameters = #'PBKDF2-params'{
			salt = {specified, OctetSalt},
			iterationCount = Count,
			keyLength = Length,
			prf = Prf
		}
	} = KeyDerivationFunc,
	#'PBES2-params_encryptionScheme'{algorithm = Algo} = EncScheme,
	{PseudoRandomFunction, PseudoHash, PseudoOtputLen} = pseudo_random_function(Prf),
	KeyLen = derived_key_length(Algo, Length),
	{OctetSalt, Count, KeyLen,
	PseudoRandomFunction, PseudoHash, PseudoOtputLen, iv(EncScheme)}.

%% @private
%% This function currently matches a tuple that ougth to be the value
%% ?'id-hmacWithSHA1, but we need some kind of ASN1-fix for this.
pseudo_random_function(#'PBKDF2-params_prf'{algorithm = {_,_, _,'id-hmacWithSHA1'}}) ->
	{fun hmac/4, sha, pseudo_output_length(?'id-hmacWithSHA1')};
pseudo_random_function(#'PBKDF2-params_prf'{algorithm = ?'id-hmacWithSHA1' = Algo}) ->
	{fun hmac/4, sha, pseudo_output_length(Algo)};
pseudo_random_function(#'PBKDF2-params_prf'{algorithm = ?'id-hmacWithSHA224'= Algo}) ->
	{fun hmac/4, sha224, pseudo_output_length(Algo)};
pseudo_random_function(#'PBKDF2-params_prf'{algorithm = ?'id-hmacWithSHA256' = Algo}) ->
	{fun hmac/4, sha256, pseudo_output_length(Algo)};
pseudo_random_function(#'PBKDF2-params_prf'{algorithm = ?'id-hmacWithSHA384' = Algo}) ->
	{fun hmac/4, sha384, pseudo_output_length(Algo)};
pseudo_random_function(#'PBKDF2-params_prf'{algorithm = ?'id-hmacWithSHA512' = Algo}) ->
	{fun hmac/4, sha512, pseudo_output_length(Algo)}.

%% @private
hmac(SubType, Key, Data, MacLength) ->
    jose_crypto_compat:mac(hmac, SubType, Key, Data, MacLength).

%% @private
pseudo_output_length(?'id-hmacWithSHA1') ->
	20; %%160/8
pseudo_output_length(?'id-hmacWithSHA224') ->
	28; %%%224/8
pseudo_output_length(?'id-hmacWithSHA256') ->
	32; %%256/8
pseudo_output_length(?'id-hmacWithSHA384') ->
	48; %%384/8
pseudo_output_length(?'id-hmacWithSHA512') ->
	64. %%512/8

%% @private
iv(#'PBES2-params_encryptionScheme'{algorithm = ?'rc2CBC', parameters =  ASN1IV}) ->
	{ok, #'RC2-CBC-Parameter'{iv = IV}} = 'PKCS-FRAME':decode('RC2-CBC-Parameter', decode_handle_open_type_wrapper(ASN1IV)),
	erlang:iolist_to_binary(IV);
iv(#'PBES2-params_encryptionScheme'{algorithm = _Algo, parameters = ASN1IV}) ->
	<<4, Len:8/unsigned-big-integer, IV:Len/binary>> = decode_handle_open_type_wrapper(ASN1IV),
	IV.

%% @private
decode_handle_open_type_wrapper({asn1_OPENTYPE, Type}) ->
	Type.

%% @private
encode_handle_open_type_wrapper(Type) ->
	{asn1_OPENTYPE, Type}.

%% @private
%% OTP 29+ decodes the algorithm as 'PrivateKeyAlgorithmIdentifier'.
i2k(PrivateKeyInfo=#'PrivateKeyInfo'{
	privateKeyAlgorithm = {'PrivateKeyAlgorithmIdentifier', Algorithm, Parameters}
}) ->
	i2k(PrivateKeyInfo#'PrivateKeyInfo'{
		privateKeyAlgorithm =
			#'PrivateKeyInfo_privateKeyAlgorithm'{
				algorithm = Algorithm,
				parameters = Parameters
			}
	});
i2k(#'PrivateKeyInfo'{
	privateKeyAlgorithm =
		#'PrivateKeyInfo_privateKeyAlgorithm'{
			algorithm = ?'jose_id-EdDSA25519'
		},
	privateKey =
		<< 4, 32:8/integer, PrivateKey:32/binary >>
}) ->
	PublicKey = jose_curve25519:eddsa_secret_to_public(PrivateKey),
	#'jose_EdDSA25519PrivateKey'{
		publicKey = #'jose_EdDSA25519PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	};
i2k(ECPrivateKey = {'ECPrivateKey', _, PrivateKey, {namedCurve, ?'jose_id-EdDSA25519'}, _, _}) ->
	i2k_eddsa25519(ECPrivateKey, PrivateKey);
i2k(ECPrivateKey = {'ECPrivateKey', _, PrivateKey, {namedCurve, ?'jose_id-EdDSA25519'}, _, _, _}) ->
	i2k_eddsa25519(ECPrivateKey, PrivateKey);
i2k(#'SubjectPublicKeyInfo'{
	algorithm =
		#'AlgorithmIdentifier'{
			algorithm = ?'jose_id-EdDSA25519'
		},
	subjectPublicKey = << PublicKey:32/binary >>
}) ->
	#'jose_EdDSA25519PublicKey'{ publicKey = PublicKey };
i2k(#'PrivateKeyInfo'{
	privateKeyAlgorithm =
		#'PrivateKeyInfo_privateKeyAlgorithm'{
			algorithm = ?'jose_id-EdDSA448'
		},
	privateKey =
		<< 4, 57:8/integer, PrivateKey:57/binary >>
}) ->
	PublicKey = jose_curve448:eddsa_secret_to_public(PrivateKey),
	#'jose_EdDSA448PrivateKey'{
		publicKey = #'jose_EdDSA448PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	};
i2k(ECPrivateKey = {'ECPrivateKey', _, PrivateKey, {namedCurve, ?'jose_id-EdDSA448'}, _, _}) ->
	i2k_eddsa448(ECPrivateKey, PrivateKey);
i2k(ECPrivateKey = {'ECPrivateKey', _, PrivateKey, {namedCurve, ?'jose_id-EdDSA448'}, _, _, _}) ->
	i2k_eddsa448(ECPrivateKey, PrivateKey);
i2k(#'SubjectPublicKeyInfo'{
	algorithm =
		#'AlgorithmIdentifier'{
			algorithm = ?'jose_id-EdDSA448'
		},
	subjectPublicKey = << PublicKey:57/binary >>
}) ->
	#'jose_EdDSA448PublicKey'{ publicKey = PublicKey };
i2k(#'PrivateKeyInfo'{
	privateKeyAlgorithm =
		#'PrivateKeyInfo_privateKeyAlgorithm'{
			algorithm = ?'jose_id-X25519'
		},
	privateKey =
		<< 4, 32:8/integer, PrivateKey:32/binary >>
}) ->
	PublicKey = jose_curve25519:x25519_secret_to_public(PrivateKey),
	#'jose_X25519PrivateKey'{
		publicKey = #'jose_X25519PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	};
i2k(#'SubjectPublicKeyInfo'{
	algorithm =
		#'AlgorithmIdentifier'{
			algorithm = ?'jose_id-X25519'
		},
	subjectPublicKey = << PublicKey:32/binary >>
}) ->
	#'jose_X25519PublicKey'{ publicKey = PublicKey };
i2k(#'PrivateKeyInfo'{
	privateKeyAlgorithm =
		#'PrivateKeyInfo_privateKeyAlgorithm'{
			algorithm = ?'jose_id-X448'
		},
	privateKey =
		<< 4, 56:8/integer, PrivateKey:56/binary >>
}) ->
	PublicKey = jose_curve448:x448_secret_to_public(PrivateKey),
	#'jose_X448PrivateKey'{
		publicKey = #'jose_X448PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	};
i2k(#'SubjectPublicKeyInfo'{
	algorithm =
		#'AlgorithmIdentifier'{
			algorithm = ?'jose_id-X448'
		},
	subjectPublicKey = << PublicKey:56/binary >>
}) ->
	#'jose_X448PublicKey'{ publicKey = PublicKey };
% public_key compat
i2k(#'SubjectPublicKeyInfo'{
	algorithm =
		#'AlgorithmIdentifier'{
			algorithm = ?'id-ecPublicKey',
			parameters = ECParameters
		},
	subjectPublicKey = ECPublicKey
}) ->
	{#'ECPoint'{point = ECPublicKey}, der_decode('EcpkParameters', ECParameters)};
i2k(PrivateKeyInfo=#'PrivateKeyInfo'{
	privateKeyAlgorithm =
		#'PrivateKeyInfo_privateKeyAlgorithm'{
			algorithm = ?'id-ecPublicKey',
			parameters = {asn1_OPENTYPE, EcpkParameters}
		},
	privateKey = PrivateKey
}) ->
	case der_decode('ECPrivateKey', PrivateKey) of
		ECPrivateKey = #'ECPrivateKey'{parameters = asn1_NOVALUE} ->
			ECPrivateKey#'ECPrivateKey'{parameters = der_decode('EcpkParameters', EcpkParameters)};
		_ ->
			PrivateKeyInfo
	end;
i2k(Info) ->
	Info.

%% @private
i2k_eddsa25519(_ECPrivateKey, << 4, 32:8/integer, PrivateKey:32/binary >>) ->
	PublicKey = jose_curve25519:eddsa_secret_to_public(PrivateKey),
	#'jose_EdDSA25519PrivateKey'{
		publicKey = #'jose_EdDSA25519PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	};
i2k_eddsa25519(_ECPrivateKey, << PrivateKey:32/binary >>) ->
	PublicKey = jose_curve25519:eddsa_secret_to_public(PrivateKey),
	#'jose_EdDSA25519PrivateKey'{
		publicKey = #'jose_EdDSA25519PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	}.

%% @private
i2k_eddsa448(_ECPrivateKey, << 4, 57:8/integer, PrivateKey:57/binary >>) ->
	PublicKey = jose_curve448:eddsa_secret_to_public(PrivateKey),
	#'jose_EdDSA448PrivateKey'{
		publicKey = #'jose_EdDSA448PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	};
i2k_eddsa448(_ECPrivateKey, << PrivateKey:57/binary >>) ->
	PublicKey = jose_curve448:eddsa_secret_to_public(PrivateKey),
	#'jose_EdDSA448PrivateKey'{
		publicKey = #'jose_EdDSA448PublicKey'{ publicKey = PublicKey },
		privateKey = PrivateKey
	}.

%% @private
k2i(#'jose_EdDSA25519PrivateKey'{privateKey=PrivateKey}) ->
	#'PrivateKeyInfo'{
		version = v1,
		privateKeyAlgorithm =
			#'PrivateKeyInfo_privateKeyAlgorithm'{
				algorithm = ?'jose_id-EdDSA25519',
				parameters = asn1_NOVALUE
			},
		privateKey =
			<< 4, 32:8/integer, PrivateKey:32/binary >>,
		attributes = asn1_NOVALUE
	};
k2i(#'jose_EdDSA25519PublicKey'{publicKey=PublicKey}) ->
	#'SubjectPublicKeyInfo'{
		algorithm =
			#'AlgorithmIdentifier'{
				algorithm = ?'jose_id-EdDSA25519',
				parameters = asn1_NOVALUE
			},
		subjectPublicKey = << PublicKey:32/binary >>
	};
k2i(#'jose_EdDSA448PrivateKey'{privateKey=PrivateKey}) ->
	#'PrivateKeyInfo'{
		version = v1,
		privateKeyAlgorithm =
			#'PrivateKeyInfo_privateKeyAlgorithm'{
				algorithm = ?'jose_id-EdDSA448',
				parameters = asn1_NOVALUE
			},
		privateKey =
			<< 4, 57:8/integer, PrivateKey:57/binary >>,
		attributes = asn1_NOVALUE
	};
k2i(#'jose_EdDSA448PublicKey'{publicKey=PublicKey}) ->
	#'SubjectPublicKeyInfo'{
		algorithm =
			#'AlgorithmIdentifier'{
				algorithm = ?'jose_id-EdDSA448',
				parameters = asn1_NOVALUE
			},
		subjectPublicKey = << PublicKey:57/binary >>
	};
k2i(#'jose_X25519PrivateKey'{privateKey=PrivateKey}) ->
	#'PrivateKeyInfo'{
		version = v1,
		privateKeyAlgorithm =
			#'PrivateKeyInfo_privateKeyAlgorithm'{
				algorithm = ?'jose_id-X25519',
				parameters = asn1_NOVALUE
			},
		privateKey =
			<< 4, 32:8/integer, PrivateKey:32/binary >>,
		attributes = asn1_NOVALUE
	};
k2i(#'jose_X25519PublicKey'{publicKey=PublicKey}) ->
	#'SubjectPublicKeyInfo'{
		algorithm =
			#'AlgorithmIdentifier'{
				algorithm = ?'jose_id-X25519',
				parameters = asn1_NOVALUE
			},
		subjectPublicKey = << PublicKey:32/binary >>
	};
k2i(#'jose_X448PrivateKey'{privateKey=PrivateKey}) ->
	#'PrivateKeyInfo'{
		version = v1,
		privateKeyAlgorithm =
			#'PrivateKeyInfo_privateKeyAlgorithm'{
				algorithm = ?'jose_id-X448',
				parameters = asn1_NOVALUE
			},
		privateKey =
			<< 4, 56:8/integer, PrivateKey:56/binary >>,
		attributes = asn1_NOVALUE
	};
k2i(#'jose_X448PublicKey'{publicKey=PublicKey}) ->
	#'SubjectPublicKeyInfo'{
		algorithm =
			#'AlgorithmIdentifier'{
				algorithm = ?'jose_id-X448',
				parameters = asn1_NOVALUE
			},
		subjectPublicKey = << PublicKey:56/binary >>
	};
% public_key compat
k2i(PrivateKey=#'ECPrivateKey'{parameters=ECParameters}) ->
	#'PrivateKeyInfo'{
		version = v1,
		privateKeyAlgorithm =
			#'PrivateKeyInfo_privateKeyAlgorithm'{
				algorithm = ?'id-ecPublicKey',
				parameters = encode_handle_open_type_wrapper(der_encode('EcpkParameters', ECParameters))
			},
		privateKey = der_encode('ECPrivateKey', PrivateKey#'ECPrivateKey'{parameters=asn1_NOVALUE}),
		attributes = asn1_NOVALUE
	};
k2i(PrivateKey=#'RSAPrivateKey'{}) ->
	#'PrivateKeyInfo'{
		version = v1,
		privateKeyAlgorithm =
			#'PrivateKeyInfo_privateKeyAlgorithm'{
				algorithm = ?'rsaEncryption',
				parameters = asn1_NOVALUE
			},
		privateKey = der_encode('RSAPrivateKey', PrivateKey),
		attributes = asn1_NOVALUE
	}.
