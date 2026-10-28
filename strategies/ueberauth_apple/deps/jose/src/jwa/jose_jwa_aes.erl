%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Advanced Encryption Standard (AES)
%%% Cipher Block Chaining (CBC), as defined in NIST.800-38A
%%% Electronic Codebook (ECB), as defined in NIST.800-38A
%%% Galois/Counter Mode (GCM) and GMAC, as defined in NIST.800-38D
%%% See NIST.800-38A: http://csrc.nist.gov/publications/nistpubs/800-38a/sp800-38a.pdf
%%% See NIST.800-38D: http://csrc.nist.gov/publications/nistpubs/800-38D/SP-800-38D.pdf
%%% @end
%%% Created :  28 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_aes).
-behaviour(jose_block_encryptor).

%% jose_block_encryptor callbacks
-export([block_decrypt/3]).
-export([block_decrypt/4]).
-export([block_encrypt/3]).
-export([block_encrypt/4]).

%%====================================================================
%% jose_block_encryptor callbacks
%%====================================================================

block_decrypt({aes_ecb, Bits}, Key, CipherText)
		when (Bits =:= 128
			orelse Bits =:= 192
			orelse Bits =:= 256)
		andalso bit_size(Key) =:= Bits
		andalso is_binary(CipherText) ->
	{St, RoundKey} = aes_key_expansion(Bits, Key),
	ecb_block_decrypt(St, RoundKey, CipherText, <<>>).

block_decrypt({aes_cbc, Bits}, Key, IV, CipherText)
		when (Bits =:= 128
			orelse Bits =:= 192
			orelse Bits =:= 256)
		andalso bit_size(Key) =:= Bits
		andalso bit_size(IV) =:= 128
		andalso is_binary(CipherText) ->
	{St, RoundKey} = aes_key_expansion(Bits, Key),
	cbc_block_decrypt(St, RoundKey, IV, CipherText, <<>>);
block_decrypt({aes_gcm, Bits}, Key, IV, {AAD, CipherText, CipherTag})
		when (Bits =:= 128
			orelse Bits =:= 192
			orelse Bits =:= 256)
		andalso bit_size(Key) =:= Bits
		andalso bit_size(IV) > 0
		andalso is_binary(AAD)
		andalso is_binary(CipherText)
		andalso is_binary(CipherTag)
		%% GCM tags are always 128 bits here.  Verifying a shorter tag
		%% would compare only bit_size(CipherTag) bits of the real tag
		%% (tag truncation forgery), and a longer one would crash the
		%% bitstring match in gcm_block_decrypt/6.
		andalso bit_size(CipherTag) =:= 128 ->
	MasterKey = block_encrypt({aes_ecb, Bits}, Key, << 0:128 >>),
	gcm_block_decrypt(MasterKey, Key, IV, AAD, CipherText, CipherTag);
block_decrypt({aes_gcm, Bits}, Key, IV, {AAD, CipherText, CipherTag})
		when (Bits =:= 128
			orelse Bits =:= 192
			orelse Bits =:= 256)
		andalso bit_size(Key) =:= Bits
		andalso bit_size(IV) > 0
		andalso is_binary(AAD)
		andalso is_binary(CipherText)
		andalso is_binary(CipherTag) ->
	error.

block_encrypt({aes_ecb, Bits}, Key, PlainText)
		when (Bits =:= 128
			orelse Bits =:= 192
			orelse Bits =:= 256)
		andalso bit_size(Key) =:= Bits
		andalso is_binary(PlainText) ->
	{St, RoundKey} = aes_key_expansion(Bits, Key),
	ecb_block_encrypt(St, RoundKey, PlainText, <<>>).

block_encrypt({aes_cbc, Bits}, Key, IV, PlainText)
		when (Bits =:= 128
			orelse Bits =:= 192
			orelse Bits =:= 256)
		andalso bit_size(Key) =:= Bits
		andalso bit_size(IV) =:= 128
		andalso is_binary(PlainText) ->
	{St, RoundKey} = aes_key_expansion(Bits, Key),
	cbc_block_encrypt(St, RoundKey, IV, PlainText, <<>>);
block_encrypt({aes_gcm, Bits}, Key, IV, {AAD, PlainText})
		when (Bits =:= 128
			orelse Bits =:= 192
			orelse Bits =:= 256)
		andalso bit_size(Key) =:= Bits
		andalso bit_size(IV) > 0
		andalso is_binary(AAD)
		andalso is_binary(PlainText) ->
	MasterKey = block_encrypt({aes_ecb, Bits}, Key, << 0:128 >>),
	gcm_block_encrypt(MasterKey, Key, IV, AAD, PlainText).

%%%-------------------------------------------------------------------
%%% Internal AES functions
%%%-------------------------------------------------------------------

%% @private
aes_add_round_key(B0, RoundKey, {Nb, _, _}, Round) ->
	B1 = aes_add_round_key(0, 0, B0, RoundKey, Nb, Round),
	B2 = aes_add_round_key(1, 0, B1, RoundKey, Nb, Round),
	B3 = aes_add_round_key(2, 0, B2, RoundKey, Nb, Round),
	B4 = aes_add_round_key(3, 0, B3, RoundKey, Nb, Round),
	B4.

%% @private
aes_add_round_key(_I, 4, Block, _RoundKey, _Nb, _Round) ->
	Block;
aes_add_round_key(I, J, B0, RoundKey, Nb, Round) ->
	RK = bget(RoundKey, Round * Nb * 4 + I * Nb + J),
	BK = bget(B0, I * 4 + J),
	B1 = bset(B0, I * 4 + J, BK bxor RK),
	aes_add_round_key(I, J + 1, B1, RoundKey, Nb, Round).

%% @private
aes_key_expansion(Bits, Key) ->
	% The number of columns comprising a state in AES.
	Nb = 4,
	% The number of 32 bit words in a key.
	Nk = Bits div 32,
	% The number of rounds in AES Cipher.
	Nr = case Bits of
		128 -> 10;
		192 -> 12;
		256 -> 14
	end,
	KeyLen = bit_size(Key),
	KeysLen = Nb * (Nr + 1) * Nk * 8,
	Keys = << Key/binary, 0:(KeysLen - KeyLen) >>,
	St = {Nb, Nk, Nr},
	{St, aes_key_expansion((KeyLen div 32), (Nb * (Nr + 1)), St, Keys)}.

aes_key_expansion(Rs, Rs, _, RoundKey) ->
	RoundKey;
aes_key_expansion(I, Rs, St={Nb, Nk, _}, RoundKey) ->
	T0 = bget(RoundKey, (I - 1) * Nb + 0),
	T1 = bget(RoundKey, (I - 1) * Nb + 1),
	T2 = bget(RoundKey, (I - 1) * Nb + 2),
	T3 = bget(RoundKey, (I - 1) * Nb + 3),
	{V0, V1, V2, V3} = case I rem Nk of
		0 ->
			% RotWord
			RW0 = T1,
			RW1 = T2,
			RW2 = T3,
			RW3 = T0,
			% SubWord
			SW0 = sBox(RW0) bxor rcon(I div Nk),
			SW1 = sBox(RW1),
			SW2 = sBox(RW2),
			SW3 = sBox(RW3),
			{
				SW0,
				SW1,
				SW2,
				SW3
			};
		4 when Nk > 6 ->
			% SubWord
			SW0 = sBox(T0),
			SW1 = sBox(T1),
			SW2 = sBox(T2),
			SW3 = sBox(T3),
			{
				SW0,
				SW1,
				SW2,
				SW3
			};
		_ ->
			{
				T0,
				T1,
				T2,
				T3
			}
	end,
	A0 = bget(RoundKey, (I - Nk) * Nb + 0) bxor V0,
	A1 = bget(RoundKey, (I - Nk) * Nb + 1) bxor V1,
	A2 = bget(RoundKey, (I - Nk) * Nb + 2) bxor V2,
	A3 = bget(RoundKey, (I - Nk) * Nb + 3) bxor V3,
	RK0 = bset(RoundKey, I * Nb + 0, A0),
	RK1 = bset(RK0, I * Nb + 1, A1),
	RK2 = bset(RK1, I * Nb + 2, A2),
	RK3 = bset(RK2, I * Nb + 3, A3),
	aes_key_expansion(I + 1, Rs, St, RK3).

%%%-------------------------------------------------------------------
%%% Internal AES decrypt functions
%%%-------------------------------------------------------------------

%% @private
aes_inverse_cipher(St={_, _, Nr}, RoundKey, B0) ->
	B1 = aes_add_round_key(B0, RoundKey, St, Nr),
	B2 = aes_inverse_cipher_rounds(Nr - 1, St, RoundKey, B1),
	B3 = aes_inverse_shift_rows(B2),
	B4 = aes_inverse_sub_bytes(B3),
	B5 = aes_add_round_key(B4, RoundKey, St, 0),
	B5.

%% @private
aes_inverse_cipher_rounds(0, _St, _RoundKey, B) ->
	B;
aes_inverse_cipher_rounds(Round, St, RoundKey, B0) ->
	B1 = aes_inverse_shift_rows(B0),
	B2 = aes_inverse_sub_bytes(B1),
	B3 = aes_add_round_key(B2, RoundKey, St, Round),
	B4 = aes_inverse_mix_columns(B3),
	aes_inverse_cipher_rounds(Round - 1, St, RoundKey, B4).

%% @private
aes_inverse_mix_columns(B) ->
	aes_inverse_mix_columns(0, B).

%% @private
aes_inverse_mix_columns(4, B) ->
	B;
aes_inverse_mix_columns(I, B0) ->
	A = bget(B0, I * 4 + 0),
	B = bget(B0, I * 4 + 1),
	C = bget(B0, I * 4 + 2),
	D = bget(B0, I * 4 + 3),
	B1 = bset(B0, I * 4 + 0, gex(A) bxor gbx(B) bxor gdx(C) bxor g9x(D)),
	B2 = bset(B1, I * 4 + 1, g9x(A) bxor gex(B) bxor gbx(C) bxor gdx(D)),
	B3 = bset(B2, I * 4 + 2, gdx(A) bxor g9x(B) bxor gex(C) bxor gbx(D)),
	B4 = bset(B3, I * 4 + 3, gbx(A) bxor gdx(B) bxor g9x(C) bxor gex(D)),
	aes_inverse_mix_columns(I + 1, B4).

%% @private
aes_inverse_shift_rows(B0) ->
	% Rotate first row 1 columns to right
	T0 = bget(B0, 3 * 4 + 1),
	B1 = bset(B0, 3 * 4 + 1, bget(B0, 2 * 4 + 1)),
	B2 = bset(B1, 2 * 4 + 1, bget(B1, 1 * 4 + 1)),
	B3 = bset(B2, 1 * 4 + 1, bget(B2, 0 * 4 + 1)),
	B4 = bset(B3, 0 * 4 + 1, T0),
	% Rotate second row 2 columns to right
	T1 = bget(B4, 0 * 4 + 2),
	B5 = bset(B4, 0 * 4 + 2, bget(B4, 2 * 4 + 2)),
	B6 = bset(B5, 2 * 4 + 2, T1),
	T2 = bget(B6, 1 * 4 + 2),
	B7 = bset(B6, 1 * 4 + 2, bget(B6, 3 * 4 + 2)),
	B8 = bset(B7, 3 * 4 + 2, T2),
	% Rotate third row 3 columns to right
	T3 = bget(B8, 0 * 4 + 3),
	B9 = bset(B8, 0 * 4 + 3, bget(B8, 1 * 4 + 3)),
	BA = bset(B9, 1 * 4 + 3, bget(B9, 2 * 4 + 3)),
	BB = bset(BA, 2 * 4 + 3, bget(BA, 3 * 4 + 3)),
	BC = bset(BB, 3 * 4 + 3, T3),
	BC.

%% @private
aes_inverse_sub_bytes(B0) ->
	B1 = aes_inverse_sub_bytes(0, 0, B0),
	B2 = aes_inverse_sub_bytes(1, 0, B1),
	B3 = aes_inverse_sub_bytes(2, 0, B2),
	B4 = aes_inverse_sub_bytes(3, 0, B3),
	B4.

%% @private
aes_inverse_sub_bytes(_I, 4, B) ->
	B;
aes_inverse_sub_bytes(I, J, B0) ->
	T0 = bget(B0, J * 4 + I),
	B1 = bset(B0, J * 4 + I, isBox(T0)),
	aes_inverse_sub_bytes(I, J + 1, B1).

%%%-------------------------------------------------------------------
%%% Internal AES encrypt functions
%%%-------------------------------------------------------------------

%% @private
aes_cipher(St={_, _, Nr}, RoundKey, B0) ->
	B1 = aes_add_round_key(B0, RoundKey, St, 0),
	B2 = aes_cipher_rounds(1, St, RoundKey, B1),
	B3 = aes_sub_bytes(B2),
	B4 = aes_shift_rows(B3),
	B5 = aes_add_round_key(B4, RoundKey, St, Nr),
	B5.

%% @private
aes_cipher_rounds(Nr, _St={_, _, Nr}, _RoundKey, B) ->
	B;
aes_cipher_rounds(Round, St, RoundKey, B0) ->
	B1 = aes_sub_bytes(B0),
	B2 = aes_shift_rows(B1),
	B3 = aes_mix_columns(B2),
	B4 = aes_add_round_key(B3, RoundKey, St, Round),
	aes_cipher_rounds(Round + 1, St, RoundKey, B4).

%% @private
aes_mix_columns(B) ->
	aes_mix_columns(0, B).

%% @private
aes_mix_columns(4, B) ->
	B;
aes_mix_columns(I, B0) ->
	A = bget(B0, I * 4 + 0),
	B = bget(B0, I * 4 + 1),
	C = bget(B0, I * 4 + 2),
	D = bget(B0, I * 4 + 3),
	B1 = bset(B0, I * 4 + 0, g2x(A) bxor g3x(B) bxor C bxor D),
	B2 = bset(B1, I * 4 + 1, A bxor g2x(B) bxor g3x(C) bxor D),
	B3 = bset(B2, I * 4 + 2, A bxor B bxor g2x(C) bxor g3x(D)),
	B4 = bset(B3, I * 4 + 3, g3x(A) bxor B bxor C bxor g2x(D)),
	aes_mix_columns(I + 1, B4).

%% @private
aes_shift_rows(B0) ->
	% Rotate first row 1 columns to left
	T0 = bget(B0, 0 * 4 + 1),
	B1 = bset(B0, 0 * 4 + 1, bget(B0, 1 * 4 + 1)),
	B2 = bset(B1, 1 * 4 + 1, bget(B1, 2 * 4 + 1)),
	B3 = bset(B2, 2 * 4 + 1, bget(B2, 3 * 4 + 1)),
	B4 = bset(B3, 3 * 4 + 1, T0),
	% Rotate second row 2 columns to left
	T1 = bget(B4, 0 * 4 + 2),
	B5 = bset(B4, 0 * 4 + 2, bget(B4, 2 * 4 + 2)),
	B6 = bset(B5, 2 * 4 + 2, T1),
	T2 = bget(B6, 1 * 4 + 2),
	B7 = bset(B6, 1 * 4 + 2, bget(B6, 3 * 4 + 2)),
	B8 = bset(B7, 3 * 4 + 2, T2),
	% Rotate third row 3 columns to left
	T3 = bget(B8, 0 * 4 + 3),
	B9 = bset(B8, 0 * 4 + 3, bget(B8, 3 * 4 + 3)),
	BA = bset(B9, 3 * 4 + 3, bget(B9, 2 * 4 + 3)),
	BB = bset(BA, 2 * 4 + 3, bget(BA, 1 * 4 + 3)),
	BC = bset(BB, 1 * 4 + 3, T3),
	BC.

%% @private
aes_sub_bytes(B0) ->
	B1 = aes_sub_bytes(0, 0, B0),
	B2 = aes_sub_bytes(1, 0, B1),
	B3 = aes_sub_bytes(2, 0, B2),
	B4 = aes_sub_bytes(3, 0, B3),
	B4.

%% @private
aes_sub_bytes(_I, 4, B) ->
	B;
aes_sub_bytes(I, J, B0) ->
	T0 = bget(B0, J * 4 + I),
	B1 = bset(B0, J * 4 + I, sBox(T0)),
	aes_sub_bytes(I, J + 1, B1).

%%%-------------------------------------------------------------------
%%% Internal CBC decrypt functions
%%%-------------------------------------------------------------------

%% @private
cbc_block_decrypt(_St, _RoundKey, _IV, <<>>, PlainText) ->
	PlainText;
cbc_block_decrypt(St, RoundKey, IV, << Block:128/bitstring, CipherText/bitstring >>, PlainText) ->
	Decrypted = crypto:exor(aes_inverse_cipher(St, RoundKey, Block), IV),
	cbc_block_decrypt(St, RoundKey, Block, CipherText, << PlainText/binary, Decrypted/binary >>).

%%%-------------------------------------------------------------------
%%% Internal CBC encrypt functions
%%%-------------------------------------------------------------------

%% @private
cbc_block_encrypt(_St, _RoundKey, _IV, <<>>, CipherText) ->
	CipherText;
cbc_block_encrypt(St, RoundKey, IV, << Block:128/bitstring, PlainText/bitstring >>, CipherText) ->
	Encrypted = aes_cipher(St, RoundKey, crypto:exor(Block, IV)),
	cbc_block_encrypt(St, RoundKey, Encrypted, PlainText, << CipherText/binary, Encrypted/binary >>).

%%%-------------------------------------------------------------------
%%% Internal GCM functions
%%%-------------------------------------------------------------------

%% @private
gcm_block_decrypt(H, K, IV, A, C, T) ->
	Y0 = case bit_size(IV) of
		96 ->
			<< IV/binary, 1:32/unsigned-big-integer-unit:1 >>;
		_ ->
			gcm_ghash(H, <<>>, IV)
	end,
	KeyLen = bit_size(K),
	Cipher = list_to_atom("aes_" ++ integer_to_list(KeyLen) ++ "_ctr"),
	S0 = jose_crypto_compat:crypto_init(Cipher, K, Y0, true),
	{S1, EKY0xor} = jose_crypto_compat:crypto_update_encrypt(S0, Y0),
	EKY0 = crypto:exor(EKY0xor, Y0),
	<< Y0int:128/unsigned-big-integer-unit:1 >> = Y0,
	Y1 = << (Y0int + 1):128/unsigned-big-integer-unit:1 >>,
	GHASH = gcm_ghash(H, A, C),
	TBits = bit_size(T),
	<< TPrime:TBits/bitstring, _/bitstring >> = crypto:exor(GHASH, EKY0),
	case jose_jwa:constant_time_compare(T, TPrime) of
		false ->
			error;
		true ->
			P = gcm_exor(S1, Y1, C, <<>>),
			P
	end.

%% @private
gcm_block_encrypt(H, K, IV, A, P) ->
	Y0 = case bit_size(IV) of
		96 ->
			<< IV/binary, 1:32/unsigned-big-integer-unit:1 >>;
		_ ->
			gcm_ghash(H, <<>>, IV)
	end,
	KeyLen = bit_size(K),
	Cipher = list_to_atom("aes_" ++ integer_to_list(KeyLen) ++ "_ctr"),
	S0 = jose_crypto_compat:crypto_init(Cipher, K, Y0, true),
	{S1, EKY0xor} = jose_crypto_compat:crypto_update_encrypt(S0, Y0),
	EKY0 = crypto:exor(EKY0xor, Y0),
	<< Y0int:128/unsigned-big-integer-unit:1 >> = Y0,
	Y1 = << (Y0int + 1):128/unsigned-big-integer-unit:1 >>,
	C = gcm_exor(S1, Y1, P, <<>>),
	GHASH = gcm_ghash(H, A, C),
	T = crypto:exor(GHASH, EKY0),
	{C, T}.

%% @private
gcm_exor(_S, _Y, <<>>, C) ->
	C;
gcm_exor(S0, Y0, << B:128/bitstring, P/bitstring >>, C0) ->
	{S1, EKY0xor} = jose_crypto_compat:crypto_update_encrypt(S0, Y0),
	EKY0 = crypto:exor(EKY0xor, Y0),
	<< Y0int:128/unsigned-big-integer-unit:1 >> = Y0,
	Y1 = << (Y0int + 1):128/unsigned-big-integer-unit:1 >>,
	C1 = << C0/binary, (crypto:exor(B, EKY0))/binary >>,
	gcm_exor(S1, Y1, P, C1);
gcm_exor(S0, Y0, P, C0) ->
	PBits = bit_size(P),
	{_S1, EKY0xor} = jose_crypto_compat:crypto_update_encrypt(S0, Y0),
	<< EKY0:PBits/bitstring, _/bitstring >> = crypto:exor(EKY0xor, Y0),
	C1 = << C0/binary, (crypto:exor(P, EKY0))/binary >>,
	C1.

%% @private
gcm_ghash(Key, AAD, CipherText) ->
	Data = << (gcm_pad(AAD))/binary, (gcm_pad(CipherText))/binary >>,
	K = crypto:bytes_to_integer(Key),
	gcm_ghash_block(K, AAD, CipherText, Data, << 0:128/unsigned-big-integer-unit:1 >>).

%% @private
gcm_ghash_block(K, AAD, CipherText, <<>>, GHash) ->
	AADBits = bit_size(AAD),
	CipherTextBits = bit_size(CipherText),
	GHashMask = << ((AADBits bsl 64) bor CipherTextBits):128/unsigned-big-integer-unit:1 >>,
	gcm_ghash_multiply(crypto:exor(GHash, GHashMask), K);
gcm_ghash_block(K, AAD, CipherText, << Block:128/bitstring, Data/bitstring >>, GHash) ->
	gcm_ghash_block(K, AAD, CipherText, Data, gcm_ghash_multiply(crypto:exor(GHash, Block), K)).

%% @private
gcm_ghash_multiply(GHash, K) ->
	gcm_ghash_multiply(0, K, crypto:bytes_to_integer(GHash), 0).

%% @private
gcm_ghash_multiply(16, _K, _GHash, Result) ->
	<< Result:128/unsigned-big-integer-unit:1 >>;
gcm_ghash_multiply(I, K, GHash, Result) ->
	J = (GHash band 16#FF),
	Val = gf_2_128_mul(K, (J bsl (I * 8))),
	gcm_ghash_multiply(I + 1, K, GHash bsr 8, Result bxor Val).

%% @private
gcm_pad(Binary) when (byte_size(Binary) rem 16) =/= 0 ->
	PadBits = (16 - (byte_size(Binary) rem 16)) * 8,
	<< Binary/binary, 0:PadBits >>;
gcm_pad(Binary) ->
	Binary.

%% @private
gf_2_128_mul(X, Y) ->
	gf_2_128_mul(127, X, Y, 0).

%% @private
gf_2_128_mul(-1, _X, _Y, R) ->
	R;
gf_2_128_mul(I, X0, Y, R0) ->
	R1 = (R0 bxor (X0 * ((Y bsr I) band 1))),
	X1 = (X0 bsr 1) bxor ((X0 band 1) * 16#E1000000000000000000000000000000),
	gf_2_128_mul(I - 1, X1, Y, R1).

%%%-------------------------------------------------------------------
%%% Internal ECB decrypt functions
%%%-------------------------------------------------------------------

%% @private
ecb_block_decrypt(_St, _RoundKey, <<>>, PlainText) ->
	PlainText;
ecb_block_decrypt(St, RoundKey, << Block:128/bitstring, CipherText/bitstring >>, PlainText) ->
	Decrypted = aes_inverse_cipher(St, RoundKey, Block),
	ecb_block_decrypt(St, RoundKey, CipherText, << PlainText/binary, Decrypted/binary >>).

%%%-------------------------------------------------------------------
%%% Internal ECB encrypt functions
%%%-------------------------------------------------------------------

%% @private
ecb_block_encrypt(_St, _RoundKey, <<>>, CipherText) ->
	CipherText;
ecb_block_encrypt(St, RoundKey, << Block:128/bitstring, PlainText/bitstring >>, CipherText) ->
	Encrypted = aes_cipher(St, RoundKey, Block),
	ecb_block_encrypt(St, RoundKey, PlainText, << CipherText/binary, Encrypted/binary >>).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
bget(B, Pos) when Pos >= 0 ->
	binary:at(B, Pos);
bget(B, Pos) ->
	bget(B, byte_size(B) + Pos).

%% @private
bset(B, Pos, Val) when Pos =:= byte_size(B) ->
	<< B/binary, Val >>;
bset(<< _, B/binary >>, 0, Val) ->
	<< Val, B/binary >>;
bset(B, Pos, Val) when Pos >= 0 ->
	<< Head:Pos/binary, _, Tail/binary >> = B,
	<< Head/binary, Val, Tail/binary >>;
bset(B, Pos, Val) ->
	bset(B, byte_size(B) + Pos, Val).

%%%-------------------------------------------------------------------
%%% AES constant functions
%%%-------------------------------------------------------------------

%% @private
g2x(16#00) -> 16#00;
g2x(16#01) -> 16#02;
g2x(16#02) -> 16#04;
g2x(16#03) -> 16#06;
g2x(16#04) -> 16#08;
g2x(16#05) -> 16#0A;
g2x(16#06) -> 16#0C;
g2x(16#07) -> 16#0E;
g2x(16#08) -> 16#10;
g2x(16#09) -> 16#12;
g2x(16#0A) -> 16#14;
g2x(16#0B) -> 16#16;
g2x(16#0C) -> 16#18;
g2x(16#0D) -> 16#1A;
g2x(16#0E) -> 16#1C;
g2x(16#0F) -> 16#1E;
g2x(16#10) -> 16#20;
g2x(16#11) -> 16#22;
g2x(16#12) -> 16#24;
g2x(16#13) -> 16#26;
g2x(16#14) -> 16#28;
g2x(16#15) -> 16#2A;
g2x(16#16) -> 16#2C;
g2x(16#17) -> 16#2E;
g2x(16#18) -> 16#30;
g2x(16#19) -> 16#32;
g2x(16#1A) -> 16#34;
g2x(16#1B) -> 16#36;
g2x(16#1C) -> 16#38;
g2x(16#1D) -> 16#3A;
g2x(16#1E) -> 16#3C;
g2x(16#1F) -> 16#3E;
g2x(16#20) -> 16#40;
g2x(16#21) -> 16#42;
g2x(16#22) -> 16#44;
g2x(16#23) -> 16#46;
g2x(16#24) -> 16#48;
g2x(16#25) -> 16#4A;
g2x(16#26) -> 16#4C;
g2x(16#27) -> 16#4E;
g2x(16#28) -> 16#50;
g2x(16#29) -> 16#52;
g2x(16#2A) -> 16#54;
g2x(16#2B) -> 16#56;
g2x(16#2C) -> 16#58;
g2x(16#2D) -> 16#5A;
g2x(16#2E) -> 16#5C;
g2x(16#2F) -> 16#5E;
g2x(16#30) -> 16#60;
g2x(16#31) -> 16#62;
g2x(16#32) -> 16#64;
g2x(16#33) -> 16#66;
g2x(16#34) -> 16#68;
g2x(16#35) -> 16#6A;
g2x(16#36) -> 16#6C;
g2x(16#37) -> 16#6E;
g2x(16#38) -> 16#70;
g2x(16#39) -> 16#72;
g2x(16#3A) -> 16#74;
g2x(16#3B) -> 16#76;
g2x(16#3C) -> 16#78;
g2x(16#3D) -> 16#7A;
g2x(16#3E) -> 16#7C;
g2x(16#3F) -> 16#7E;
g2x(16#40) -> 16#80;
g2x(16#41) -> 16#82;
g2x(16#42) -> 16#84;
g2x(16#43) -> 16#86;
g2x(16#44) -> 16#88;
g2x(16#45) -> 16#8A;
g2x(16#46) -> 16#8C;
g2x(16#47) -> 16#8E;
g2x(16#48) -> 16#90;
g2x(16#49) -> 16#92;
g2x(16#4A) -> 16#94;
g2x(16#4B) -> 16#96;
g2x(16#4C) -> 16#98;
g2x(16#4D) -> 16#9A;
g2x(16#4E) -> 16#9C;
g2x(16#4F) -> 16#9E;
g2x(16#50) -> 16#A0;
g2x(16#51) -> 16#A2;
g2x(16#52) -> 16#A4;
g2x(16#53) -> 16#A6;
g2x(16#54) -> 16#A8;
g2x(16#55) -> 16#AA;
g2x(16#56) -> 16#AC;
g2x(16#57) -> 16#AE;
g2x(16#58) -> 16#B0;
g2x(16#59) -> 16#B2;
g2x(16#5A) -> 16#B4;
g2x(16#5B) -> 16#B6;
g2x(16#5C) -> 16#B8;
g2x(16#5D) -> 16#BA;
g2x(16#5E) -> 16#BC;
g2x(16#5F) -> 16#BE;
g2x(16#60) -> 16#C0;
g2x(16#61) -> 16#C2;
g2x(16#62) -> 16#C4;
g2x(16#63) -> 16#C6;
g2x(16#64) -> 16#C8;
g2x(16#65) -> 16#CA;
g2x(16#66) -> 16#CC;
g2x(16#67) -> 16#CE;
g2x(16#68) -> 16#D0;
g2x(16#69) -> 16#D2;
g2x(16#6A) -> 16#D4;
g2x(16#6B) -> 16#D6;
g2x(16#6C) -> 16#D8;
g2x(16#6D) -> 16#DA;
g2x(16#6E) -> 16#DC;
g2x(16#6F) -> 16#DE;
g2x(16#70) -> 16#E0;
g2x(16#71) -> 16#E2;
g2x(16#72) -> 16#E4;
g2x(16#73) -> 16#E6;
g2x(16#74) -> 16#E8;
g2x(16#75) -> 16#EA;
g2x(16#76) -> 16#EC;
g2x(16#77) -> 16#EE;
g2x(16#78) -> 16#F0;
g2x(16#79) -> 16#F2;
g2x(16#7A) -> 16#F4;
g2x(16#7B) -> 16#F6;
g2x(16#7C) -> 16#F8;
g2x(16#7D) -> 16#FA;
g2x(16#7E) -> 16#FC;
g2x(16#7F) -> 16#FE;
g2x(16#80) -> 16#1B;
g2x(16#81) -> 16#19;
g2x(16#82) -> 16#1F;
g2x(16#83) -> 16#1D;
g2x(16#84) -> 16#13;
g2x(16#85) -> 16#11;
g2x(16#86) -> 16#17;
g2x(16#87) -> 16#15;
g2x(16#88) -> 16#0B;
g2x(16#89) -> 16#09;
g2x(16#8A) -> 16#0F;
g2x(16#8B) -> 16#0D;
g2x(16#8C) -> 16#03;
g2x(16#8D) -> 16#01;
g2x(16#8E) -> 16#07;
g2x(16#8F) -> 16#05;
g2x(16#90) -> 16#3B;
g2x(16#91) -> 16#39;
g2x(16#92) -> 16#3F;
g2x(16#93) -> 16#3D;
g2x(16#94) -> 16#33;
g2x(16#95) -> 16#31;
g2x(16#96) -> 16#37;
g2x(16#97) -> 16#35;
g2x(16#98) -> 16#2B;
g2x(16#99) -> 16#29;
g2x(16#9A) -> 16#2F;
g2x(16#9B) -> 16#2D;
g2x(16#9C) -> 16#23;
g2x(16#9D) -> 16#21;
g2x(16#9E) -> 16#27;
g2x(16#9F) -> 16#25;
g2x(16#A0) -> 16#5B;
g2x(16#A1) -> 16#59;
g2x(16#A2) -> 16#5F;
g2x(16#A3) -> 16#5D;
g2x(16#A4) -> 16#53;
g2x(16#A5) -> 16#51;
g2x(16#A6) -> 16#57;
g2x(16#A7) -> 16#55;
g2x(16#A8) -> 16#4B;
g2x(16#A9) -> 16#49;
g2x(16#AA) -> 16#4F;
g2x(16#AB) -> 16#4D;
g2x(16#AC) -> 16#43;
g2x(16#AD) -> 16#41;
g2x(16#AE) -> 16#47;
g2x(16#AF) -> 16#45;
g2x(16#B0) -> 16#7B;
g2x(16#B1) -> 16#79;
g2x(16#B2) -> 16#7F;
g2x(16#B3) -> 16#7D;
g2x(16#B4) -> 16#73;
g2x(16#B5) -> 16#71;
g2x(16#B6) -> 16#77;
g2x(16#B7) -> 16#75;
g2x(16#B8) -> 16#6B;
g2x(16#B9) -> 16#69;
g2x(16#BA) -> 16#6F;
g2x(16#BB) -> 16#6D;
g2x(16#BC) -> 16#63;
g2x(16#BD) -> 16#61;
g2x(16#BE) -> 16#67;
g2x(16#BF) -> 16#65;
g2x(16#C0) -> 16#9B;
g2x(16#C1) -> 16#99;
g2x(16#C2) -> 16#9F;
g2x(16#C3) -> 16#9D;
g2x(16#C4) -> 16#93;
g2x(16#C5) -> 16#91;
g2x(16#C6) -> 16#97;
g2x(16#C7) -> 16#95;
g2x(16#C8) -> 16#8B;
g2x(16#C9) -> 16#89;
g2x(16#CA) -> 16#8F;
g2x(16#CB) -> 16#8D;
g2x(16#CC) -> 16#83;
g2x(16#CD) -> 16#81;
g2x(16#CE) -> 16#87;
g2x(16#CF) -> 16#85;
g2x(16#D0) -> 16#BB;
g2x(16#D1) -> 16#B9;
g2x(16#D2) -> 16#BF;
g2x(16#D3) -> 16#BD;
g2x(16#D4) -> 16#B3;
g2x(16#D5) -> 16#B1;
g2x(16#D6) -> 16#B7;
g2x(16#D7) -> 16#B5;
g2x(16#D8) -> 16#AB;
g2x(16#D9) -> 16#A9;
g2x(16#DA) -> 16#AF;
g2x(16#DB) -> 16#AD;
g2x(16#DC) -> 16#A3;
g2x(16#DD) -> 16#A1;
g2x(16#DE) -> 16#A7;
g2x(16#DF) -> 16#A5;
g2x(16#E0) -> 16#DB;
g2x(16#E1) -> 16#D9;
g2x(16#E2) -> 16#DF;
g2x(16#E3) -> 16#DD;
g2x(16#E4) -> 16#D3;
g2x(16#E5) -> 16#D1;
g2x(16#E6) -> 16#D7;
g2x(16#E7) -> 16#D5;
g2x(16#E8) -> 16#CB;
g2x(16#E9) -> 16#C9;
g2x(16#EA) -> 16#CF;
g2x(16#EB) -> 16#CD;
g2x(16#EC) -> 16#C3;
g2x(16#ED) -> 16#C1;
g2x(16#EE) -> 16#C7;
g2x(16#EF) -> 16#C5;
g2x(16#F0) -> 16#FB;
g2x(16#F1) -> 16#F9;
g2x(16#F2) -> 16#FF;
g2x(16#F3) -> 16#FD;
g2x(16#F4) -> 16#F3;
g2x(16#F5) -> 16#F1;
g2x(16#F6) -> 16#F7;
g2x(16#F7) -> 16#F5;
g2x(16#F8) -> 16#EB;
g2x(16#F9) -> 16#E9;
g2x(16#FA) -> 16#EF;
g2x(16#FB) -> 16#ED;
g2x(16#FC) -> 16#E3;
g2x(16#FD) -> 16#E1;
g2x(16#FE) -> 16#E7;
g2x(16#FF) -> 16#E5.

%% @private
g3x(16#00) -> 16#00;
g3x(16#01) -> 16#03;
g3x(16#02) -> 16#06;
g3x(16#03) -> 16#05;
g3x(16#04) -> 16#0C;
g3x(16#05) -> 16#0F;
g3x(16#06) -> 16#0A;
g3x(16#07) -> 16#09;
g3x(16#08) -> 16#18;
g3x(16#09) -> 16#1B;
g3x(16#0A) -> 16#1E;
g3x(16#0B) -> 16#1D;
g3x(16#0C) -> 16#14;
g3x(16#0D) -> 16#17;
g3x(16#0E) -> 16#12;
g3x(16#0F) -> 16#11;
g3x(16#10) -> 16#30;
g3x(16#11) -> 16#33;
g3x(16#12) -> 16#36;
g3x(16#13) -> 16#35;
g3x(16#14) -> 16#3C;
g3x(16#15) -> 16#3F;
g3x(16#16) -> 16#3A;
g3x(16#17) -> 16#39;
g3x(16#18) -> 16#28;
g3x(16#19) -> 16#2B;
g3x(16#1A) -> 16#2E;
g3x(16#1B) -> 16#2D;
g3x(16#1C) -> 16#24;
g3x(16#1D) -> 16#27;
g3x(16#1E) -> 16#22;
g3x(16#1F) -> 16#21;
g3x(16#20) -> 16#60;
g3x(16#21) -> 16#63;
g3x(16#22) -> 16#66;
g3x(16#23) -> 16#65;
g3x(16#24) -> 16#6C;
g3x(16#25) -> 16#6F;
g3x(16#26) -> 16#6A;
g3x(16#27) -> 16#69;
g3x(16#28) -> 16#78;
g3x(16#29) -> 16#7B;
g3x(16#2A) -> 16#7E;
g3x(16#2B) -> 16#7D;
g3x(16#2C) -> 16#74;
g3x(16#2D) -> 16#77;
g3x(16#2E) -> 16#72;
g3x(16#2F) -> 16#71;
g3x(16#30) -> 16#50;
g3x(16#31) -> 16#53;
g3x(16#32) -> 16#56;
g3x(16#33) -> 16#55;
g3x(16#34) -> 16#5C;
g3x(16#35) -> 16#5F;
g3x(16#36) -> 16#5A;
g3x(16#37) -> 16#59;
g3x(16#38) -> 16#48;
g3x(16#39) -> 16#4B;
g3x(16#3A) -> 16#4E;
g3x(16#3B) -> 16#4D;
g3x(16#3C) -> 16#44;
g3x(16#3D) -> 16#47;
g3x(16#3E) -> 16#42;
g3x(16#3F) -> 16#41;
g3x(16#40) -> 16#C0;
g3x(16#41) -> 16#C3;
g3x(16#42) -> 16#C6;
g3x(16#43) -> 16#C5;
g3x(16#44) -> 16#CC;
g3x(16#45) -> 16#CF;
g3x(16#46) -> 16#CA;
g3x(16#47) -> 16#C9;
g3x(16#48) -> 16#D8;
g3x(16#49) -> 16#DB;
g3x(16#4A) -> 16#DE;
g3x(16#4B) -> 16#DD;
g3x(16#4C) -> 16#D4;
g3x(16#4D) -> 16#D7;
g3x(16#4E) -> 16#D2;
g3x(16#4F) -> 16#D1;
g3x(16#50) -> 16#F0;
g3x(16#51) -> 16#F3;
g3x(16#52) -> 16#F6;
g3x(16#53) -> 16#F5;
g3x(16#54) -> 16#FC;
g3x(16#55) -> 16#FF;
g3x(16#56) -> 16#FA;
g3x(16#57) -> 16#F9;
g3x(16#58) -> 16#E8;
g3x(16#59) -> 16#EB;
g3x(16#5A) -> 16#EE;
g3x(16#5B) -> 16#ED;
g3x(16#5C) -> 16#E4;
g3x(16#5D) -> 16#E7;
g3x(16#5E) -> 16#E2;
g3x(16#5F) -> 16#E1;
g3x(16#60) -> 16#A0;
g3x(16#61) -> 16#A3;
g3x(16#62) -> 16#A6;
g3x(16#63) -> 16#A5;
g3x(16#64) -> 16#AC;
g3x(16#65) -> 16#AF;
g3x(16#66) -> 16#AA;
g3x(16#67) -> 16#A9;
g3x(16#68) -> 16#B8;
g3x(16#69) -> 16#BB;
g3x(16#6A) -> 16#BE;
g3x(16#6B) -> 16#BD;
g3x(16#6C) -> 16#B4;
g3x(16#6D) -> 16#B7;
g3x(16#6E) -> 16#B2;
g3x(16#6F) -> 16#B1;
g3x(16#70) -> 16#90;
g3x(16#71) -> 16#93;
g3x(16#72) -> 16#96;
g3x(16#73) -> 16#95;
g3x(16#74) -> 16#9C;
g3x(16#75) -> 16#9F;
g3x(16#76) -> 16#9A;
g3x(16#77) -> 16#99;
g3x(16#78) -> 16#88;
g3x(16#79) -> 16#8B;
g3x(16#7A) -> 16#8E;
g3x(16#7B) -> 16#8D;
g3x(16#7C) -> 16#84;
g3x(16#7D) -> 16#87;
g3x(16#7E) -> 16#82;
g3x(16#7F) -> 16#81;
g3x(16#80) -> 16#9B;
g3x(16#81) -> 16#98;
g3x(16#82) -> 16#9D;
g3x(16#83) -> 16#9E;
g3x(16#84) -> 16#97;
g3x(16#85) -> 16#94;
g3x(16#86) -> 16#91;
g3x(16#87) -> 16#92;
g3x(16#88) -> 16#83;
g3x(16#89) -> 16#80;
g3x(16#8A) -> 16#85;
g3x(16#8B) -> 16#86;
g3x(16#8C) -> 16#8F;
g3x(16#8D) -> 16#8C;
g3x(16#8E) -> 16#89;
g3x(16#8F) -> 16#8A;
g3x(16#90) -> 16#AB;
g3x(16#91) -> 16#A8;
g3x(16#92) -> 16#AD;
g3x(16#93) -> 16#AE;
g3x(16#94) -> 16#A7;
g3x(16#95) -> 16#A4;
g3x(16#96) -> 16#A1;
g3x(16#97) -> 16#A2;
g3x(16#98) -> 16#B3;
g3x(16#99) -> 16#B0;
g3x(16#9A) -> 16#B5;
g3x(16#9B) -> 16#B6;
g3x(16#9C) -> 16#BF;
g3x(16#9D) -> 16#BC;
g3x(16#9E) -> 16#B9;
g3x(16#9F) -> 16#BA;
g3x(16#A0) -> 16#FB;
g3x(16#A1) -> 16#F8;
g3x(16#A2) -> 16#FD;
g3x(16#A3) -> 16#FE;
g3x(16#A4) -> 16#F7;
g3x(16#A5) -> 16#F4;
g3x(16#A6) -> 16#F1;
g3x(16#A7) -> 16#F2;
g3x(16#A8) -> 16#E3;
g3x(16#A9) -> 16#E0;
g3x(16#AA) -> 16#E5;
g3x(16#AB) -> 16#E6;
g3x(16#AC) -> 16#EF;
g3x(16#AD) -> 16#EC;
g3x(16#AE) -> 16#E9;
g3x(16#AF) -> 16#EA;
g3x(16#B0) -> 16#CB;
g3x(16#B1) -> 16#C8;
g3x(16#B2) -> 16#CD;
g3x(16#B3) -> 16#CE;
g3x(16#B4) -> 16#C7;
g3x(16#B5) -> 16#C4;
g3x(16#B6) -> 16#C1;
g3x(16#B7) -> 16#C2;
g3x(16#B8) -> 16#D3;
g3x(16#B9) -> 16#D0;
g3x(16#BA) -> 16#D5;
g3x(16#BB) -> 16#D6;
g3x(16#BC) -> 16#DF;
g3x(16#BD) -> 16#DC;
g3x(16#BE) -> 16#D9;
g3x(16#BF) -> 16#DA;
g3x(16#C0) -> 16#5B;
g3x(16#C1) -> 16#58;
g3x(16#C2) -> 16#5D;
g3x(16#C3) -> 16#5E;
g3x(16#C4) -> 16#57;
g3x(16#C5) -> 16#54;
g3x(16#C6) -> 16#51;
g3x(16#C7) -> 16#52;
g3x(16#C8) -> 16#43;
g3x(16#C9) -> 16#40;
g3x(16#CA) -> 16#45;
g3x(16#CB) -> 16#46;
g3x(16#CC) -> 16#4F;
g3x(16#CD) -> 16#4C;
g3x(16#CE) -> 16#49;
g3x(16#CF) -> 16#4A;
g3x(16#D0) -> 16#6B;
g3x(16#D1) -> 16#68;
g3x(16#D2) -> 16#6D;
g3x(16#D3) -> 16#6E;
g3x(16#D4) -> 16#67;
g3x(16#D5) -> 16#64;
g3x(16#D6) -> 16#61;
g3x(16#D7) -> 16#62;
g3x(16#D8) -> 16#73;
g3x(16#D9) -> 16#70;
g3x(16#DA) -> 16#75;
g3x(16#DB) -> 16#76;
g3x(16#DC) -> 16#7F;
g3x(16#DD) -> 16#7C;
g3x(16#DE) -> 16#79;
g3x(16#DF) -> 16#7A;
g3x(16#E0) -> 16#3B;
g3x(16#E1) -> 16#38;
g3x(16#E2) -> 16#3D;
g3x(16#E3) -> 16#3E;
g3x(16#E4) -> 16#37;
g3x(16#E5) -> 16#34;
g3x(16#E6) -> 16#31;
g3x(16#E7) -> 16#32;
g3x(16#E8) -> 16#23;
g3x(16#E9) -> 16#20;
g3x(16#EA) -> 16#25;
g3x(16#EB) -> 16#26;
g3x(16#EC) -> 16#2F;
g3x(16#ED) -> 16#2C;
g3x(16#EE) -> 16#29;
g3x(16#EF) -> 16#2A;
g3x(16#F0) -> 16#0B;
g3x(16#F1) -> 16#08;
g3x(16#F2) -> 16#0D;
g3x(16#F3) -> 16#0E;
g3x(16#F4) -> 16#07;
g3x(16#F5) -> 16#04;
g3x(16#F6) -> 16#01;
g3x(16#F7) -> 16#02;
g3x(16#F8) -> 16#13;
g3x(16#F9) -> 16#10;
g3x(16#FA) -> 16#15;
g3x(16#FB) -> 16#16;
g3x(16#FC) -> 16#1F;
g3x(16#FD) -> 16#1C;
g3x(16#FE) -> 16#19;
g3x(16#FF) -> 16#1A.

%% @private
g9x(16#00) -> 16#00;
g9x(16#01) -> 16#09;
g9x(16#02) -> 16#12;
g9x(16#03) -> 16#1B;
g9x(16#04) -> 16#24;
g9x(16#05) -> 16#2D;
g9x(16#06) -> 16#36;
g9x(16#07) -> 16#3F;
g9x(16#08) -> 16#48;
g9x(16#09) -> 16#41;
g9x(16#0A) -> 16#5A;
g9x(16#0B) -> 16#53;
g9x(16#0C) -> 16#6C;
g9x(16#0D) -> 16#65;
g9x(16#0E) -> 16#7E;
g9x(16#0F) -> 16#77;
g9x(16#10) -> 16#90;
g9x(16#11) -> 16#99;
g9x(16#12) -> 16#82;
g9x(16#13) -> 16#8B;
g9x(16#14) -> 16#B4;
g9x(16#15) -> 16#BD;
g9x(16#16) -> 16#A6;
g9x(16#17) -> 16#AF;
g9x(16#18) -> 16#D8;
g9x(16#19) -> 16#D1;
g9x(16#1A) -> 16#CA;
g9x(16#1B) -> 16#C3;
g9x(16#1C) -> 16#FC;
g9x(16#1D) -> 16#F5;
g9x(16#1E) -> 16#EE;
g9x(16#1F) -> 16#E7;
g9x(16#20) -> 16#3B;
g9x(16#21) -> 16#32;
g9x(16#22) -> 16#29;
g9x(16#23) -> 16#20;
g9x(16#24) -> 16#1F;
g9x(16#25) -> 16#16;
g9x(16#26) -> 16#0D;
g9x(16#27) -> 16#04;
g9x(16#28) -> 16#73;
g9x(16#29) -> 16#7A;
g9x(16#2A) -> 16#61;
g9x(16#2B) -> 16#68;
g9x(16#2C) -> 16#57;
g9x(16#2D) -> 16#5E;
g9x(16#2E) -> 16#45;
g9x(16#2F) -> 16#4C;
g9x(16#30) -> 16#AB;
g9x(16#31) -> 16#A2;
g9x(16#32) -> 16#B9;
g9x(16#33) -> 16#B0;
g9x(16#34) -> 16#8F;
g9x(16#35) -> 16#86;
g9x(16#36) -> 16#9D;
g9x(16#37) -> 16#94;
g9x(16#38) -> 16#E3;
g9x(16#39) -> 16#EA;
g9x(16#3A) -> 16#F1;
g9x(16#3B) -> 16#F8;
g9x(16#3C) -> 16#C7;
g9x(16#3D) -> 16#CE;
g9x(16#3E) -> 16#D5;
g9x(16#3F) -> 16#DC;
g9x(16#40) -> 16#76;
g9x(16#41) -> 16#7F;
g9x(16#42) -> 16#64;
g9x(16#43) -> 16#6D;
g9x(16#44) -> 16#52;
g9x(16#45) -> 16#5B;
g9x(16#46) -> 16#40;
g9x(16#47) -> 16#49;
g9x(16#48) -> 16#3E;
g9x(16#49) -> 16#37;
g9x(16#4A) -> 16#2C;
g9x(16#4B) -> 16#25;
g9x(16#4C) -> 16#1A;
g9x(16#4D) -> 16#13;
g9x(16#4E) -> 16#08;
g9x(16#4F) -> 16#01;
g9x(16#50) -> 16#E6;
g9x(16#51) -> 16#EF;
g9x(16#52) -> 16#F4;
g9x(16#53) -> 16#FD;
g9x(16#54) -> 16#C2;
g9x(16#55) -> 16#CB;
g9x(16#56) -> 16#D0;
g9x(16#57) -> 16#D9;
g9x(16#58) -> 16#AE;
g9x(16#59) -> 16#A7;
g9x(16#5A) -> 16#BC;
g9x(16#5B) -> 16#B5;
g9x(16#5C) -> 16#8A;
g9x(16#5D) -> 16#83;
g9x(16#5E) -> 16#98;
g9x(16#5F) -> 16#91;
g9x(16#60) -> 16#4D;
g9x(16#61) -> 16#44;
g9x(16#62) -> 16#5F;
g9x(16#63) -> 16#56;
g9x(16#64) -> 16#69;
g9x(16#65) -> 16#60;
g9x(16#66) -> 16#7B;
g9x(16#67) -> 16#72;
g9x(16#68) -> 16#05;
g9x(16#69) -> 16#0C;
g9x(16#6A) -> 16#17;
g9x(16#6B) -> 16#1E;
g9x(16#6C) -> 16#21;
g9x(16#6D) -> 16#28;
g9x(16#6E) -> 16#33;
g9x(16#6F) -> 16#3A;
g9x(16#70) -> 16#DD;
g9x(16#71) -> 16#D4;
g9x(16#72) -> 16#CF;
g9x(16#73) -> 16#C6;
g9x(16#74) -> 16#F9;
g9x(16#75) -> 16#F0;
g9x(16#76) -> 16#EB;
g9x(16#77) -> 16#E2;
g9x(16#78) -> 16#95;
g9x(16#79) -> 16#9C;
g9x(16#7A) -> 16#87;
g9x(16#7B) -> 16#8E;
g9x(16#7C) -> 16#B1;
g9x(16#7D) -> 16#B8;
g9x(16#7E) -> 16#A3;
g9x(16#7F) -> 16#AA;
g9x(16#80) -> 16#EC;
g9x(16#81) -> 16#E5;
g9x(16#82) -> 16#FE;
g9x(16#83) -> 16#F7;
g9x(16#84) -> 16#C8;
g9x(16#85) -> 16#C1;
g9x(16#86) -> 16#DA;
g9x(16#87) -> 16#D3;
g9x(16#88) -> 16#A4;
g9x(16#89) -> 16#AD;
g9x(16#8A) -> 16#B6;
g9x(16#8B) -> 16#BF;
g9x(16#8C) -> 16#80;
g9x(16#8D) -> 16#89;
g9x(16#8E) -> 16#92;
g9x(16#8F) -> 16#9B;
g9x(16#90) -> 16#7C;
g9x(16#91) -> 16#75;
g9x(16#92) -> 16#6E;
g9x(16#93) -> 16#67;
g9x(16#94) -> 16#58;
g9x(16#95) -> 16#51;
g9x(16#96) -> 16#4A;
g9x(16#97) -> 16#43;
g9x(16#98) -> 16#34;
g9x(16#99) -> 16#3D;
g9x(16#9A) -> 16#26;
g9x(16#9B) -> 16#2F;
g9x(16#9C) -> 16#10;
g9x(16#9D) -> 16#19;
g9x(16#9E) -> 16#02;
g9x(16#9F) -> 16#0B;
g9x(16#A0) -> 16#D7;
g9x(16#A1) -> 16#DE;
g9x(16#A2) -> 16#C5;
g9x(16#A3) -> 16#CC;
g9x(16#A4) -> 16#F3;
g9x(16#A5) -> 16#FA;
g9x(16#A6) -> 16#E1;
g9x(16#A7) -> 16#E8;
g9x(16#A8) -> 16#9F;
g9x(16#A9) -> 16#96;
g9x(16#AA) -> 16#8D;
g9x(16#AB) -> 16#84;
g9x(16#AC) -> 16#BB;
g9x(16#AD) -> 16#B2;
g9x(16#AE) -> 16#A9;
g9x(16#AF) -> 16#A0;
g9x(16#B0) -> 16#47;
g9x(16#B1) -> 16#4E;
g9x(16#B2) -> 16#55;
g9x(16#B3) -> 16#5C;
g9x(16#B4) -> 16#63;
g9x(16#B5) -> 16#6A;
g9x(16#B6) -> 16#71;
g9x(16#B7) -> 16#78;
g9x(16#B8) -> 16#0F;
g9x(16#B9) -> 16#06;
g9x(16#BA) -> 16#1D;
g9x(16#BB) -> 16#14;
g9x(16#BC) -> 16#2B;
g9x(16#BD) -> 16#22;
g9x(16#BE) -> 16#39;
g9x(16#BF) -> 16#30;
g9x(16#C0) -> 16#9A;
g9x(16#C1) -> 16#93;
g9x(16#C2) -> 16#88;
g9x(16#C3) -> 16#81;
g9x(16#C4) -> 16#BE;
g9x(16#C5) -> 16#B7;
g9x(16#C6) -> 16#AC;
g9x(16#C7) -> 16#A5;
g9x(16#C8) -> 16#D2;
g9x(16#C9) -> 16#DB;
g9x(16#CA) -> 16#C0;
g9x(16#CB) -> 16#C9;
g9x(16#CC) -> 16#F6;
g9x(16#CD) -> 16#FF;
g9x(16#CE) -> 16#E4;
g9x(16#CF) -> 16#ED;
g9x(16#D0) -> 16#0A;
g9x(16#D1) -> 16#03;
g9x(16#D2) -> 16#18;
g9x(16#D3) -> 16#11;
g9x(16#D4) -> 16#2E;
g9x(16#D5) -> 16#27;
g9x(16#D6) -> 16#3C;
g9x(16#D7) -> 16#35;
g9x(16#D8) -> 16#42;
g9x(16#D9) -> 16#4B;
g9x(16#DA) -> 16#50;
g9x(16#DB) -> 16#59;
g9x(16#DC) -> 16#66;
g9x(16#DD) -> 16#6F;
g9x(16#DE) -> 16#74;
g9x(16#DF) -> 16#7D;
g9x(16#E0) -> 16#A1;
g9x(16#E1) -> 16#A8;
g9x(16#E2) -> 16#B3;
g9x(16#E3) -> 16#BA;
g9x(16#E4) -> 16#85;
g9x(16#E5) -> 16#8C;
g9x(16#E6) -> 16#97;
g9x(16#E7) -> 16#9E;
g9x(16#E8) -> 16#E9;
g9x(16#E9) -> 16#E0;
g9x(16#EA) -> 16#FB;
g9x(16#EB) -> 16#F2;
g9x(16#EC) -> 16#CD;
g9x(16#ED) -> 16#C4;
g9x(16#EE) -> 16#DF;
g9x(16#EF) -> 16#D6;
g9x(16#F0) -> 16#31;
g9x(16#F1) -> 16#38;
g9x(16#F2) -> 16#23;
g9x(16#F3) -> 16#2A;
g9x(16#F4) -> 16#15;
g9x(16#F5) -> 16#1C;
g9x(16#F6) -> 16#07;
g9x(16#F7) -> 16#0E;
g9x(16#F8) -> 16#79;
g9x(16#F9) -> 16#70;
g9x(16#FA) -> 16#6B;
g9x(16#FB) -> 16#62;
g9x(16#FC) -> 16#5D;
g9x(16#FD) -> 16#54;
g9x(16#FE) -> 16#4F;
g9x(16#FF) -> 16#46.

%% @private
gbx(16#00) -> 16#00;
gbx(16#01) -> 16#0B;
gbx(16#02) -> 16#16;
gbx(16#03) -> 16#1D;
gbx(16#04) -> 16#2C;
gbx(16#05) -> 16#27;
gbx(16#06) -> 16#3A;
gbx(16#07) -> 16#31;
gbx(16#08) -> 16#58;
gbx(16#09) -> 16#53;
gbx(16#0A) -> 16#4E;
gbx(16#0B) -> 16#45;
gbx(16#0C) -> 16#74;
gbx(16#0D) -> 16#7F;
gbx(16#0E) -> 16#62;
gbx(16#0F) -> 16#69;
gbx(16#10) -> 16#B0;
gbx(16#11) -> 16#BB;
gbx(16#12) -> 16#A6;
gbx(16#13) -> 16#AD;
gbx(16#14) -> 16#9C;
gbx(16#15) -> 16#97;
gbx(16#16) -> 16#8A;
gbx(16#17) -> 16#81;
gbx(16#18) -> 16#E8;
gbx(16#19) -> 16#E3;
gbx(16#1A) -> 16#FE;
gbx(16#1B) -> 16#F5;
gbx(16#1C) -> 16#C4;
gbx(16#1D) -> 16#CF;
gbx(16#1E) -> 16#D2;
gbx(16#1F) -> 16#D9;
gbx(16#20) -> 16#7B;
gbx(16#21) -> 16#70;
gbx(16#22) -> 16#6D;
gbx(16#23) -> 16#66;
gbx(16#24) -> 16#57;
gbx(16#25) -> 16#5C;
gbx(16#26) -> 16#41;
gbx(16#27) -> 16#4A;
gbx(16#28) -> 16#23;
gbx(16#29) -> 16#28;
gbx(16#2A) -> 16#35;
gbx(16#2B) -> 16#3E;
gbx(16#2C) -> 16#0F;
gbx(16#2D) -> 16#04;
gbx(16#2E) -> 16#19;
gbx(16#2F) -> 16#12;
gbx(16#30) -> 16#CB;
gbx(16#31) -> 16#C0;
gbx(16#32) -> 16#DD;
gbx(16#33) -> 16#D6;
gbx(16#34) -> 16#E7;
gbx(16#35) -> 16#EC;
gbx(16#36) -> 16#F1;
gbx(16#37) -> 16#FA;
gbx(16#38) -> 16#93;
gbx(16#39) -> 16#98;
gbx(16#3A) -> 16#85;
gbx(16#3B) -> 16#8E;
gbx(16#3C) -> 16#BF;
gbx(16#3D) -> 16#B4;
gbx(16#3E) -> 16#A9;
gbx(16#3F) -> 16#A2;
gbx(16#40) -> 16#F6;
gbx(16#41) -> 16#FD;
gbx(16#42) -> 16#E0;
gbx(16#43) -> 16#EB;
gbx(16#44) -> 16#DA;
gbx(16#45) -> 16#D1;
gbx(16#46) -> 16#CC;
gbx(16#47) -> 16#C7;
gbx(16#48) -> 16#AE;
gbx(16#49) -> 16#A5;
gbx(16#4A) -> 16#B8;
gbx(16#4B) -> 16#B3;
gbx(16#4C) -> 16#82;
gbx(16#4D) -> 16#89;
gbx(16#4E) -> 16#94;
gbx(16#4F) -> 16#9F;
gbx(16#50) -> 16#46;
gbx(16#51) -> 16#4D;
gbx(16#52) -> 16#50;
gbx(16#53) -> 16#5B;
gbx(16#54) -> 16#6A;
gbx(16#55) -> 16#61;
gbx(16#56) -> 16#7C;
gbx(16#57) -> 16#77;
gbx(16#58) -> 16#1E;
gbx(16#59) -> 16#15;
gbx(16#5A) -> 16#08;
gbx(16#5B) -> 16#03;
gbx(16#5C) -> 16#32;
gbx(16#5D) -> 16#39;
gbx(16#5E) -> 16#24;
gbx(16#5F) -> 16#2F;
gbx(16#60) -> 16#8D;
gbx(16#61) -> 16#86;
gbx(16#62) -> 16#9B;
gbx(16#63) -> 16#90;
gbx(16#64) -> 16#A1;
gbx(16#65) -> 16#AA;
gbx(16#66) -> 16#B7;
gbx(16#67) -> 16#BC;
gbx(16#68) -> 16#D5;
gbx(16#69) -> 16#DE;
gbx(16#6A) -> 16#C3;
gbx(16#6B) -> 16#C8;
gbx(16#6C) -> 16#F9;
gbx(16#6D) -> 16#F2;
gbx(16#6E) -> 16#EF;
gbx(16#6F) -> 16#E4;
gbx(16#70) -> 16#3D;
gbx(16#71) -> 16#36;
gbx(16#72) -> 16#2B;
gbx(16#73) -> 16#20;
gbx(16#74) -> 16#11;
gbx(16#75) -> 16#1A;
gbx(16#76) -> 16#07;
gbx(16#77) -> 16#0C;
gbx(16#78) -> 16#65;
gbx(16#79) -> 16#6E;
gbx(16#7A) -> 16#73;
gbx(16#7B) -> 16#78;
gbx(16#7C) -> 16#49;
gbx(16#7D) -> 16#42;
gbx(16#7E) -> 16#5F;
gbx(16#7F) -> 16#54;
gbx(16#80) -> 16#F7;
gbx(16#81) -> 16#FC;
gbx(16#82) -> 16#E1;
gbx(16#83) -> 16#EA;
gbx(16#84) -> 16#DB;
gbx(16#85) -> 16#D0;
gbx(16#86) -> 16#CD;
gbx(16#87) -> 16#C6;
gbx(16#88) -> 16#AF;
gbx(16#89) -> 16#A4;
gbx(16#8A) -> 16#B9;
gbx(16#8B) -> 16#B2;
gbx(16#8C) -> 16#83;
gbx(16#8D) -> 16#88;
gbx(16#8E) -> 16#95;
gbx(16#8F) -> 16#9E;
gbx(16#90) -> 16#47;
gbx(16#91) -> 16#4C;
gbx(16#92) -> 16#51;
gbx(16#93) -> 16#5A;
gbx(16#94) -> 16#6B;
gbx(16#95) -> 16#60;
gbx(16#96) -> 16#7D;
gbx(16#97) -> 16#76;
gbx(16#98) -> 16#1F;
gbx(16#99) -> 16#14;
gbx(16#9A) -> 16#09;
gbx(16#9B) -> 16#02;
gbx(16#9C) -> 16#33;
gbx(16#9D) -> 16#38;
gbx(16#9E) -> 16#25;
gbx(16#9F) -> 16#2E;
gbx(16#A0) -> 16#8C;
gbx(16#A1) -> 16#87;
gbx(16#A2) -> 16#9A;
gbx(16#A3) -> 16#91;
gbx(16#A4) -> 16#A0;
gbx(16#A5) -> 16#AB;
gbx(16#A6) -> 16#B6;
gbx(16#A7) -> 16#BD;
gbx(16#A8) -> 16#D4;
gbx(16#A9) -> 16#DF;
gbx(16#AA) -> 16#C2;
gbx(16#AB) -> 16#C9;
gbx(16#AC) -> 16#F8;
gbx(16#AD) -> 16#F3;
gbx(16#AE) -> 16#EE;
gbx(16#AF) -> 16#E5;
gbx(16#B0) -> 16#3C;
gbx(16#B1) -> 16#37;
gbx(16#B2) -> 16#2A;
gbx(16#B3) -> 16#21;
gbx(16#B4) -> 16#10;
gbx(16#B5) -> 16#1B;
gbx(16#B6) -> 16#06;
gbx(16#B7) -> 16#0D;
gbx(16#B8) -> 16#64;
gbx(16#B9) -> 16#6F;
gbx(16#BA) -> 16#72;
gbx(16#BB) -> 16#79;
gbx(16#BC) -> 16#48;
gbx(16#BD) -> 16#43;
gbx(16#BE) -> 16#5E;
gbx(16#BF) -> 16#55;
gbx(16#C0) -> 16#01;
gbx(16#C1) -> 16#0A;
gbx(16#C2) -> 16#17;
gbx(16#C3) -> 16#1C;
gbx(16#C4) -> 16#2D;
gbx(16#C5) -> 16#26;
gbx(16#C6) -> 16#3B;
gbx(16#C7) -> 16#30;
gbx(16#C8) -> 16#59;
gbx(16#C9) -> 16#52;
gbx(16#CA) -> 16#4F;
gbx(16#CB) -> 16#44;
gbx(16#CC) -> 16#75;
gbx(16#CD) -> 16#7E;
gbx(16#CE) -> 16#63;
gbx(16#CF) -> 16#68;
gbx(16#D0) -> 16#B1;
gbx(16#D1) -> 16#BA;
gbx(16#D2) -> 16#A7;
gbx(16#D3) -> 16#AC;
gbx(16#D4) -> 16#9D;
gbx(16#D5) -> 16#96;
gbx(16#D6) -> 16#8B;
gbx(16#D7) -> 16#80;
gbx(16#D8) -> 16#E9;
gbx(16#D9) -> 16#E2;
gbx(16#DA) -> 16#FF;
gbx(16#DB) -> 16#F4;
gbx(16#DC) -> 16#C5;
gbx(16#DD) -> 16#CE;
gbx(16#DE) -> 16#D3;
gbx(16#DF) -> 16#D8;
gbx(16#E0) -> 16#7A;
gbx(16#E1) -> 16#71;
gbx(16#E2) -> 16#6C;
gbx(16#E3) -> 16#67;
gbx(16#E4) -> 16#56;
gbx(16#E5) -> 16#5D;
gbx(16#E6) -> 16#40;
gbx(16#E7) -> 16#4B;
gbx(16#E8) -> 16#22;
gbx(16#E9) -> 16#29;
gbx(16#EA) -> 16#34;
gbx(16#EB) -> 16#3F;
gbx(16#EC) -> 16#0E;
gbx(16#ED) -> 16#05;
gbx(16#EE) -> 16#18;
gbx(16#EF) -> 16#13;
gbx(16#F0) -> 16#CA;
gbx(16#F1) -> 16#C1;
gbx(16#F2) -> 16#DC;
gbx(16#F3) -> 16#D7;
gbx(16#F4) -> 16#E6;
gbx(16#F5) -> 16#ED;
gbx(16#F6) -> 16#F0;
gbx(16#F7) -> 16#FB;
gbx(16#F8) -> 16#92;
gbx(16#F9) -> 16#99;
gbx(16#FA) -> 16#84;
gbx(16#FB) -> 16#8F;
gbx(16#FC) -> 16#BE;
gbx(16#FD) -> 16#B5;
gbx(16#FE) -> 16#A8;
gbx(16#FF) -> 16#A3.

%% @private
gdx(16#00) -> 16#00;
gdx(16#01) -> 16#0D;
gdx(16#02) -> 16#1A;
gdx(16#03) -> 16#17;
gdx(16#04) -> 16#34;
gdx(16#05) -> 16#39;
gdx(16#06) -> 16#2E;
gdx(16#07) -> 16#23;
gdx(16#08) -> 16#68;
gdx(16#09) -> 16#65;
gdx(16#0A) -> 16#72;
gdx(16#0B) -> 16#7F;
gdx(16#0C) -> 16#5C;
gdx(16#0D) -> 16#51;
gdx(16#0E) -> 16#46;
gdx(16#0F) -> 16#4B;
gdx(16#10) -> 16#D0;
gdx(16#11) -> 16#DD;
gdx(16#12) -> 16#CA;
gdx(16#13) -> 16#C7;
gdx(16#14) -> 16#E4;
gdx(16#15) -> 16#E9;
gdx(16#16) -> 16#FE;
gdx(16#17) -> 16#F3;
gdx(16#18) -> 16#B8;
gdx(16#19) -> 16#B5;
gdx(16#1A) -> 16#A2;
gdx(16#1B) -> 16#AF;
gdx(16#1C) -> 16#8C;
gdx(16#1D) -> 16#81;
gdx(16#1E) -> 16#96;
gdx(16#1F) -> 16#9B;
gdx(16#20) -> 16#BB;
gdx(16#21) -> 16#B6;
gdx(16#22) -> 16#A1;
gdx(16#23) -> 16#AC;
gdx(16#24) -> 16#8F;
gdx(16#25) -> 16#82;
gdx(16#26) -> 16#95;
gdx(16#27) -> 16#98;
gdx(16#28) -> 16#D3;
gdx(16#29) -> 16#DE;
gdx(16#2A) -> 16#C9;
gdx(16#2B) -> 16#C4;
gdx(16#2C) -> 16#E7;
gdx(16#2D) -> 16#EA;
gdx(16#2E) -> 16#FD;
gdx(16#2F) -> 16#F0;
gdx(16#30) -> 16#6B;
gdx(16#31) -> 16#66;
gdx(16#32) -> 16#71;
gdx(16#33) -> 16#7C;
gdx(16#34) -> 16#5F;
gdx(16#35) -> 16#52;
gdx(16#36) -> 16#45;
gdx(16#37) -> 16#48;
gdx(16#38) -> 16#03;
gdx(16#39) -> 16#0E;
gdx(16#3A) -> 16#19;
gdx(16#3B) -> 16#14;
gdx(16#3C) -> 16#37;
gdx(16#3D) -> 16#3A;
gdx(16#3E) -> 16#2D;
gdx(16#3F) -> 16#20;
gdx(16#40) -> 16#6D;
gdx(16#41) -> 16#60;
gdx(16#42) -> 16#77;
gdx(16#43) -> 16#7A;
gdx(16#44) -> 16#59;
gdx(16#45) -> 16#54;
gdx(16#46) -> 16#43;
gdx(16#47) -> 16#4E;
gdx(16#48) -> 16#05;
gdx(16#49) -> 16#08;
gdx(16#4A) -> 16#1F;
gdx(16#4B) -> 16#12;
gdx(16#4C) -> 16#31;
gdx(16#4D) -> 16#3C;
gdx(16#4E) -> 16#2B;
gdx(16#4F) -> 16#26;
gdx(16#50) -> 16#BD;
gdx(16#51) -> 16#B0;
gdx(16#52) -> 16#A7;
gdx(16#53) -> 16#AA;
gdx(16#54) -> 16#89;
gdx(16#55) -> 16#84;
gdx(16#56) -> 16#93;
gdx(16#57) -> 16#9E;
gdx(16#58) -> 16#D5;
gdx(16#59) -> 16#D8;
gdx(16#5A) -> 16#CF;
gdx(16#5B) -> 16#C2;
gdx(16#5C) -> 16#E1;
gdx(16#5D) -> 16#EC;
gdx(16#5E) -> 16#FB;
gdx(16#5F) -> 16#F6;
gdx(16#60) -> 16#D6;
gdx(16#61) -> 16#DB;
gdx(16#62) -> 16#CC;
gdx(16#63) -> 16#C1;
gdx(16#64) -> 16#E2;
gdx(16#65) -> 16#EF;
gdx(16#66) -> 16#F8;
gdx(16#67) -> 16#F5;
gdx(16#68) -> 16#BE;
gdx(16#69) -> 16#B3;
gdx(16#6A) -> 16#A4;
gdx(16#6B) -> 16#A9;
gdx(16#6C) -> 16#8A;
gdx(16#6D) -> 16#87;
gdx(16#6E) -> 16#90;
gdx(16#6F) -> 16#9D;
gdx(16#70) -> 16#06;
gdx(16#71) -> 16#0B;
gdx(16#72) -> 16#1C;
gdx(16#73) -> 16#11;
gdx(16#74) -> 16#32;
gdx(16#75) -> 16#3F;
gdx(16#76) -> 16#28;
gdx(16#77) -> 16#25;
gdx(16#78) -> 16#6E;
gdx(16#79) -> 16#63;
gdx(16#7A) -> 16#74;
gdx(16#7B) -> 16#79;
gdx(16#7C) -> 16#5A;
gdx(16#7D) -> 16#57;
gdx(16#7E) -> 16#40;
gdx(16#7F) -> 16#4D;
gdx(16#80) -> 16#DA;
gdx(16#81) -> 16#D7;
gdx(16#82) -> 16#C0;
gdx(16#83) -> 16#CD;
gdx(16#84) -> 16#EE;
gdx(16#85) -> 16#E3;
gdx(16#86) -> 16#F4;
gdx(16#87) -> 16#F9;
gdx(16#88) -> 16#B2;
gdx(16#89) -> 16#BF;
gdx(16#8A) -> 16#A8;
gdx(16#8B) -> 16#A5;
gdx(16#8C) -> 16#86;
gdx(16#8D) -> 16#8B;
gdx(16#8E) -> 16#9C;
gdx(16#8F) -> 16#91;
gdx(16#90) -> 16#0A;
gdx(16#91) -> 16#07;
gdx(16#92) -> 16#10;
gdx(16#93) -> 16#1D;
gdx(16#94) -> 16#3E;
gdx(16#95) -> 16#33;
gdx(16#96) -> 16#24;
gdx(16#97) -> 16#29;
gdx(16#98) -> 16#62;
gdx(16#99) -> 16#6F;
gdx(16#9A) -> 16#78;
gdx(16#9B) -> 16#75;
gdx(16#9C) -> 16#56;
gdx(16#9D) -> 16#5B;
gdx(16#9E) -> 16#4C;
gdx(16#9F) -> 16#41;
gdx(16#A0) -> 16#61;
gdx(16#A1) -> 16#6C;
gdx(16#A2) -> 16#7B;
gdx(16#A3) -> 16#76;
gdx(16#A4) -> 16#55;
gdx(16#A5) -> 16#58;
gdx(16#A6) -> 16#4F;
gdx(16#A7) -> 16#42;
gdx(16#A8) -> 16#09;
gdx(16#A9) -> 16#04;
gdx(16#AA) -> 16#13;
gdx(16#AB) -> 16#1E;
gdx(16#AC) -> 16#3D;
gdx(16#AD) -> 16#30;
gdx(16#AE) -> 16#27;
gdx(16#AF) -> 16#2A;
gdx(16#B0) -> 16#B1;
gdx(16#B1) -> 16#BC;
gdx(16#B2) -> 16#AB;
gdx(16#B3) -> 16#A6;
gdx(16#B4) -> 16#85;
gdx(16#B5) -> 16#88;
gdx(16#B6) -> 16#9F;
gdx(16#B7) -> 16#92;
gdx(16#B8) -> 16#D9;
gdx(16#B9) -> 16#D4;
gdx(16#BA) -> 16#C3;
gdx(16#BB) -> 16#CE;
gdx(16#BC) -> 16#ED;
gdx(16#BD) -> 16#E0;
gdx(16#BE) -> 16#F7;
gdx(16#BF) -> 16#FA;
gdx(16#C0) -> 16#B7;
gdx(16#C1) -> 16#BA;
gdx(16#C2) -> 16#AD;
gdx(16#C3) -> 16#A0;
gdx(16#C4) -> 16#83;
gdx(16#C5) -> 16#8E;
gdx(16#C6) -> 16#99;
gdx(16#C7) -> 16#94;
gdx(16#C8) -> 16#DF;
gdx(16#C9) -> 16#D2;
gdx(16#CA) -> 16#C5;
gdx(16#CB) -> 16#C8;
gdx(16#CC) -> 16#EB;
gdx(16#CD) -> 16#E6;
gdx(16#CE) -> 16#F1;
gdx(16#CF) -> 16#FC;
gdx(16#D0) -> 16#67;
gdx(16#D1) -> 16#6A;
gdx(16#D2) -> 16#7D;
gdx(16#D3) -> 16#70;
gdx(16#D4) -> 16#53;
gdx(16#D5) -> 16#5E;
gdx(16#D6) -> 16#49;
gdx(16#D7) -> 16#44;
gdx(16#D8) -> 16#0F;
gdx(16#D9) -> 16#02;
gdx(16#DA) -> 16#15;
gdx(16#DB) -> 16#18;
gdx(16#DC) -> 16#3B;
gdx(16#DD) -> 16#36;
gdx(16#DE) -> 16#21;
gdx(16#DF) -> 16#2C;
gdx(16#E0) -> 16#0C;
gdx(16#E1) -> 16#01;
gdx(16#E2) -> 16#16;
gdx(16#E3) -> 16#1B;
gdx(16#E4) -> 16#38;
gdx(16#E5) -> 16#35;
gdx(16#E6) -> 16#22;
gdx(16#E7) -> 16#2F;
gdx(16#E8) -> 16#64;
gdx(16#E9) -> 16#69;
gdx(16#EA) -> 16#7E;
gdx(16#EB) -> 16#73;
gdx(16#EC) -> 16#50;
gdx(16#ED) -> 16#5D;
gdx(16#EE) -> 16#4A;
gdx(16#EF) -> 16#47;
gdx(16#F0) -> 16#DC;
gdx(16#F1) -> 16#D1;
gdx(16#F2) -> 16#C6;
gdx(16#F3) -> 16#CB;
gdx(16#F4) -> 16#E8;
gdx(16#F5) -> 16#E5;
gdx(16#F6) -> 16#F2;
gdx(16#F7) -> 16#FF;
gdx(16#F8) -> 16#B4;
gdx(16#F9) -> 16#B9;
gdx(16#FA) -> 16#AE;
gdx(16#FB) -> 16#A3;
gdx(16#FC) -> 16#80;
gdx(16#FD) -> 16#8D;
gdx(16#FE) -> 16#9A;
gdx(16#FF) -> 16#97.

%% @private
gex(16#00) -> 16#00;
gex(16#01) -> 16#0E;
gex(16#02) -> 16#1C;
gex(16#03) -> 16#12;
gex(16#04) -> 16#38;
gex(16#05) -> 16#36;
gex(16#06) -> 16#24;
gex(16#07) -> 16#2A;
gex(16#08) -> 16#70;
gex(16#09) -> 16#7E;
gex(16#0A) -> 16#6C;
gex(16#0B) -> 16#62;
gex(16#0C) -> 16#48;
gex(16#0D) -> 16#46;
gex(16#0E) -> 16#54;
gex(16#0F) -> 16#5A;
gex(16#10) -> 16#E0;
gex(16#11) -> 16#EE;
gex(16#12) -> 16#FC;
gex(16#13) -> 16#F2;
gex(16#14) -> 16#D8;
gex(16#15) -> 16#D6;
gex(16#16) -> 16#C4;
gex(16#17) -> 16#CA;
gex(16#18) -> 16#90;
gex(16#19) -> 16#9E;
gex(16#1A) -> 16#8C;
gex(16#1B) -> 16#82;
gex(16#1C) -> 16#A8;
gex(16#1D) -> 16#A6;
gex(16#1E) -> 16#B4;
gex(16#1F) -> 16#BA;
gex(16#20) -> 16#DB;
gex(16#21) -> 16#D5;
gex(16#22) -> 16#C7;
gex(16#23) -> 16#C9;
gex(16#24) -> 16#E3;
gex(16#25) -> 16#ED;
gex(16#26) -> 16#FF;
gex(16#27) -> 16#F1;
gex(16#28) -> 16#AB;
gex(16#29) -> 16#A5;
gex(16#2A) -> 16#B7;
gex(16#2B) -> 16#B9;
gex(16#2C) -> 16#93;
gex(16#2D) -> 16#9D;
gex(16#2E) -> 16#8F;
gex(16#2F) -> 16#81;
gex(16#30) -> 16#3B;
gex(16#31) -> 16#35;
gex(16#32) -> 16#27;
gex(16#33) -> 16#29;
gex(16#34) -> 16#03;
gex(16#35) -> 16#0D;
gex(16#36) -> 16#1F;
gex(16#37) -> 16#11;
gex(16#38) -> 16#4B;
gex(16#39) -> 16#45;
gex(16#3A) -> 16#57;
gex(16#3B) -> 16#59;
gex(16#3C) -> 16#73;
gex(16#3D) -> 16#7D;
gex(16#3E) -> 16#6F;
gex(16#3F) -> 16#61;
gex(16#40) -> 16#AD;
gex(16#41) -> 16#A3;
gex(16#42) -> 16#B1;
gex(16#43) -> 16#BF;
gex(16#44) -> 16#95;
gex(16#45) -> 16#9B;
gex(16#46) -> 16#89;
gex(16#47) -> 16#87;
gex(16#48) -> 16#DD;
gex(16#49) -> 16#D3;
gex(16#4A) -> 16#C1;
gex(16#4B) -> 16#CF;
gex(16#4C) -> 16#E5;
gex(16#4D) -> 16#EB;
gex(16#4E) -> 16#F9;
gex(16#4F) -> 16#F7;
gex(16#50) -> 16#4D;
gex(16#51) -> 16#43;
gex(16#52) -> 16#51;
gex(16#53) -> 16#5F;
gex(16#54) -> 16#75;
gex(16#55) -> 16#7B;
gex(16#56) -> 16#69;
gex(16#57) -> 16#67;
gex(16#58) -> 16#3D;
gex(16#59) -> 16#33;
gex(16#5A) -> 16#21;
gex(16#5B) -> 16#2F;
gex(16#5C) -> 16#05;
gex(16#5D) -> 16#0B;
gex(16#5E) -> 16#19;
gex(16#5F) -> 16#17;
gex(16#60) -> 16#76;
gex(16#61) -> 16#78;
gex(16#62) -> 16#6A;
gex(16#63) -> 16#64;
gex(16#64) -> 16#4E;
gex(16#65) -> 16#40;
gex(16#66) -> 16#52;
gex(16#67) -> 16#5C;
gex(16#68) -> 16#06;
gex(16#69) -> 16#08;
gex(16#6A) -> 16#1A;
gex(16#6B) -> 16#14;
gex(16#6C) -> 16#3E;
gex(16#6D) -> 16#30;
gex(16#6E) -> 16#22;
gex(16#6F) -> 16#2C;
gex(16#70) -> 16#96;
gex(16#71) -> 16#98;
gex(16#72) -> 16#8A;
gex(16#73) -> 16#84;
gex(16#74) -> 16#AE;
gex(16#75) -> 16#A0;
gex(16#76) -> 16#B2;
gex(16#77) -> 16#BC;
gex(16#78) -> 16#E6;
gex(16#79) -> 16#E8;
gex(16#7A) -> 16#FA;
gex(16#7B) -> 16#F4;
gex(16#7C) -> 16#DE;
gex(16#7D) -> 16#D0;
gex(16#7E) -> 16#C2;
gex(16#7F) -> 16#CC;
gex(16#80) -> 16#41;
gex(16#81) -> 16#4F;
gex(16#82) -> 16#5D;
gex(16#83) -> 16#53;
gex(16#84) -> 16#79;
gex(16#85) -> 16#77;
gex(16#86) -> 16#65;
gex(16#87) -> 16#6B;
gex(16#88) -> 16#31;
gex(16#89) -> 16#3F;
gex(16#8A) -> 16#2D;
gex(16#8B) -> 16#23;
gex(16#8C) -> 16#09;
gex(16#8D) -> 16#07;
gex(16#8E) -> 16#15;
gex(16#8F) -> 16#1B;
gex(16#90) -> 16#A1;
gex(16#91) -> 16#AF;
gex(16#92) -> 16#BD;
gex(16#93) -> 16#B3;
gex(16#94) -> 16#99;
gex(16#95) -> 16#97;
gex(16#96) -> 16#85;
gex(16#97) -> 16#8B;
gex(16#98) -> 16#D1;
gex(16#99) -> 16#DF;
gex(16#9A) -> 16#CD;
gex(16#9B) -> 16#C3;
gex(16#9C) -> 16#E9;
gex(16#9D) -> 16#E7;
gex(16#9E) -> 16#F5;
gex(16#9F) -> 16#FB;
gex(16#A0) -> 16#9A;
gex(16#A1) -> 16#94;
gex(16#A2) -> 16#86;
gex(16#A3) -> 16#88;
gex(16#A4) -> 16#A2;
gex(16#A5) -> 16#AC;
gex(16#A6) -> 16#BE;
gex(16#A7) -> 16#B0;
gex(16#A8) -> 16#EA;
gex(16#A9) -> 16#E4;
gex(16#AA) -> 16#F6;
gex(16#AB) -> 16#F8;
gex(16#AC) -> 16#D2;
gex(16#AD) -> 16#DC;
gex(16#AE) -> 16#CE;
gex(16#AF) -> 16#C0;
gex(16#B0) -> 16#7A;
gex(16#B1) -> 16#74;
gex(16#B2) -> 16#66;
gex(16#B3) -> 16#68;
gex(16#B4) -> 16#42;
gex(16#B5) -> 16#4C;
gex(16#B6) -> 16#5E;
gex(16#B7) -> 16#50;
gex(16#B8) -> 16#0A;
gex(16#B9) -> 16#04;
gex(16#BA) -> 16#16;
gex(16#BB) -> 16#18;
gex(16#BC) -> 16#32;
gex(16#BD) -> 16#3C;
gex(16#BE) -> 16#2E;
gex(16#BF) -> 16#20;
gex(16#C0) -> 16#EC;
gex(16#C1) -> 16#E2;
gex(16#C2) -> 16#F0;
gex(16#C3) -> 16#FE;
gex(16#C4) -> 16#D4;
gex(16#C5) -> 16#DA;
gex(16#C6) -> 16#C8;
gex(16#C7) -> 16#C6;
gex(16#C8) -> 16#9C;
gex(16#C9) -> 16#92;
gex(16#CA) -> 16#80;
gex(16#CB) -> 16#8E;
gex(16#CC) -> 16#A4;
gex(16#CD) -> 16#AA;
gex(16#CE) -> 16#B8;
gex(16#CF) -> 16#B6;
gex(16#D0) -> 16#0C;
gex(16#D1) -> 16#02;
gex(16#D2) -> 16#10;
gex(16#D3) -> 16#1E;
gex(16#D4) -> 16#34;
gex(16#D5) -> 16#3A;
gex(16#D6) -> 16#28;
gex(16#D7) -> 16#26;
gex(16#D8) -> 16#7C;
gex(16#D9) -> 16#72;
gex(16#DA) -> 16#60;
gex(16#DB) -> 16#6E;
gex(16#DC) -> 16#44;
gex(16#DD) -> 16#4A;
gex(16#DE) -> 16#58;
gex(16#DF) -> 16#56;
gex(16#E0) -> 16#37;
gex(16#E1) -> 16#39;
gex(16#E2) -> 16#2B;
gex(16#E3) -> 16#25;
gex(16#E4) -> 16#0F;
gex(16#E5) -> 16#01;
gex(16#E6) -> 16#13;
gex(16#E7) -> 16#1D;
gex(16#E8) -> 16#47;
gex(16#E9) -> 16#49;
gex(16#EA) -> 16#5B;
gex(16#EB) -> 16#55;
gex(16#EC) -> 16#7F;
gex(16#ED) -> 16#71;
gex(16#EE) -> 16#63;
gex(16#EF) -> 16#6D;
gex(16#F0) -> 16#D7;
gex(16#F1) -> 16#D9;
gex(16#F2) -> 16#CB;
gex(16#F3) -> 16#C5;
gex(16#F4) -> 16#EF;
gex(16#F5) -> 16#E1;
gex(16#F6) -> 16#F3;
gex(16#F7) -> 16#FD;
gex(16#F8) -> 16#A7;
gex(16#F9) -> 16#A9;
gex(16#FA) -> 16#BB;
gex(16#FB) -> 16#B5;
gex(16#FC) -> 16#9F;
gex(16#FD) -> 16#91;
gex(16#FE) -> 16#83;
gex(16#FF) -> 16#8D.

%% @private
isBox(16#00) -> 16#52;
isBox(16#01) -> 16#09;
isBox(16#02) -> 16#6A;
isBox(16#03) -> 16#D5;
isBox(16#04) -> 16#30;
isBox(16#05) -> 16#36;
isBox(16#06) -> 16#A5;
isBox(16#07) -> 16#38;
isBox(16#08) -> 16#BF;
isBox(16#09) -> 16#40;
isBox(16#0A) -> 16#A3;
isBox(16#0B) -> 16#9E;
isBox(16#0C) -> 16#81;
isBox(16#0D) -> 16#F3;
isBox(16#0E) -> 16#D7;
isBox(16#0F) -> 16#FB;
isBox(16#10) -> 16#7C;
isBox(16#11) -> 16#E3;
isBox(16#12) -> 16#39;
isBox(16#13) -> 16#82;
isBox(16#14) -> 16#9B;
isBox(16#15) -> 16#2F;
isBox(16#16) -> 16#FF;
isBox(16#17) -> 16#87;
isBox(16#18) -> 16#34;
isBox(16#19) -> 16#8E;
isBox(16#1A) -> 16#43;
isBox(16#1B) -> 16#44;
isBox(16#1C) -> 16#C4;
isBox(16#1D) -> 16#DE;
isBox(16#1E) -> 16#E9;
isBox(16#1F) -> 16#CB;
isBox(16#20) -> 16#54;
isBox(16#21) -> 16#7B;
isBox(16#22) -> 16#94;
isBox(16#23) -> 16#32;
isBox(16#24) -> 16#A6;
isBox(16#25) -> 16#C2;
isBox(16#26) -> 16#23;
isBox(16#27) -> 16#3D;
isBox(16#28) -> 16#EE;
isBox(16#29) -> 16#4C;
isBox(16#2A) -> 16#95;
isBox(16#2B) -> 16#0B;
isBox(16#2C) -> 16#42;
isBox(16#2D) -> 16#FA;
isBox(16#2E) -> 16#C3;
isBox(16#2F) -> 16#4E;
isBox(16#30) -> 16#08;
isBox(16#31) -> 16#2E;
isBox(16#32) -> 16#A1;
isBox(16#33) -> 16#66;
isBox(16#34) -> 16#28;
isBox(16#35) -> 16#D9;
isBox(16#36) -> 16#24;
isBox(16#37) -> 16#B2;
isBox(16#38) -> 16#76;
isBox(16#39) -> 16#5B;
isBox(16#3A) -> 16#A2;
isBox(16#3B) -> 16#49;
isBox(16#3C) -> 16#6D;
isBox(16#3D) -> 16#8B;
isBox(16#3E) -> 16#D1;
isBox(16#3F) -> 16#25;
isBox(16#40) -> 16#72;
isBox(16#41) -> 16#F8;
isBox(16#42) -> 16#F6;
isBox(16#43) -> 16#64;
isBox(16#44) -> 16#86;
isBox(16#45) -> 16#68;
isBox(16#46) -> 16#98;
isBox(16#47) -> 16#16;
isBox(16#48) -> 16#D4;
isBox(16#49) -> 16#A4;
isBox(16#4A) -> 16#5C;
isBox(16#4B) -> 16#CC;
isBox(16#4C) -> 16#5D;
isBox(16#4D) -> 16#65;
isBox(16#4E) -> 16#B6;
isBox(16#4F) -> 16#92;
isBox(16#50) -> 16#6C;
isBox(16#51) -> 16#70;
isBox(16#52) -> 16#48;
isBox(16#53) -> 16#50;
isBox(16#54) -> 16#FD;
isBox(16#55) -> 16#ED;
isBox(16#56) -> 16#B9;
isBox(16#57) -> 16#DA;
isBox(16#58) -> 16#5E;
isBox(16#59) -> 16#15;
isBox(16#5A) -> 16#46;
isBox(16#5B) -> 16#57;
isBox(16#5C) -> 16#A7;
isBox(16#5D) -> 16#8D;
isBox(16#5E) -> 16#9D;
isBox(16#5F) -> 16#84;
isBox(16#60) -> 16#90;
isBox(16#61) -> 16#D8;
isBox(16#62) -> 16#AB;
isBox(16#63) -> 16#00;
isBox(16#64) -> 16#8C;
isBox(16#65) -> 16#BC;
isBox(16#66) -> 16#D3;
isBox(16#67) -> 16#0A;
isBox(16#68) -> 16#F7;
isBox(16#69) -> 16#E4;
isBox(16#6A) -> 16#58;
isBox(16#6B) -> 16#05;
isBox(16#6C) -> 16#B8;
isBox(16#6D) -> 16#B3;
isBox(16#6E) -> 16#45;
isBox(16#6F) -> 16#06;
isBox(16#70) -> 16#D0;
isBox(16#71) -> 16#2C;
isBox(16#72) -> 16#1E;
isBox(16#73) -> 16#8F;
isBox(16#74) -> 16#CA;
isBox(16#75) -> 16#3F;
isBox(16#76) -> 16#0F;
isBox(16#77) -> 16#02;
isBox(16#78) -> 16#C1;
isBox(16#79) -> 16#AF;
isBox(16#7A) -> 16#BD;
isBox(16#7B) -> 16#03;
isBox(16#7C) -> 16#01;
isBox(16#7D) -> 16#13;
isBox(16#7E) -> 16#8A;
isBox(16#7F) -> 16#6B;
isBox(16#80) -> 16#3A;
isBox(16#81) -> 16#91;
isBox(16#82) -> 16#11;
isBox(16#83) -> 16#41;
isBox(16#84) -> 16#4F;
isBox(16#85) -> 16#67;
isBox(16#86) -> 16#DC;
isBox(16#87) -> 16#EA;
isBox(16#88) -> 16#97;
isBox(16#89) -> 16#F2;
isBox(16#8A) -> 16#CF;
isBox(16#8B) -> 16#CE;
isBox(16#8C) -> 16#F0;
isBox(16#8D) -> 16#B4;
isBox(16#8E) -> 16#E6;
isBox(16#8F) -> 16#73;
isBox(16#90) -> 16#96;
isBox(16#91) -> 16#AC;
isBox(16#92) -> 16#74;
isBox(16#93) -> 16#22;
isBox(16#94) -> 16#E7;
isBox(16#95) -> 16#AD;
isBox(16#96) -> 16#35;
isBox(16#97) -> 16#85;
isBox(16#98) -> 16#E2;
isBox(16#99) -> 16#F9;
isBox(16#9A) -> 16#37;
isBox(16#9B) -> 16#E8;
isBox(16#9C) -> 16#1C;
isBox(16#9D) -> 16#75;
isBox(16#9E) -> 16#DF;
isBox(16#9F) -> 16#6E;
isBox(16#A0) -> 16#47;
isBox(16#A1) -> 16#F1;
isBox(16#A2) -> 16#1A;
isBox(16#A3) -> 16#71;
isBox(16#A4) -> 16#1D;
isBox(16#A5) -> 16#29;
isBox(16#A6) -> 16#C5;
isBox(16#A7) -> 16#89;
isBox(16#A8) -> 16#6F;
isBox(16#A9) -> 16#B7;
isBox(16#AA) -> 16#62;
isBox(16#AB) -> 16#0E;
isBox(16#AC) -> 16#AA;
isBox(16#AD) -> 16#18;
isBox(16#AE) -> 16#BE;
isBox(16#AF) -> 16#1B;
isBox(16#B0) -> 16#FC;
isBox(16#B1) -> 16#56;
isBox(16#B2) -> 16#3E;
isBox(16#B3) -> 16#4B;
isBox(16#B4) -> 16#C6;
isBox(16#B5) -> 16#D2;
isBox(16#B6) -> 16#79;
isBox(16#B7) -> 16#20;
isBox(16#B8) -> 16#9A;
isBox(16#B9) -> 16#DB;
isBox(16#BA) -> 16#C0;
isBox(16#BB) -> 16#FE;
isBox(16#BC) -> 16#78;
isBox(16#BD) -> 16#CD;
isBox(16#BE) -> 16#5A;
isBox(16#BF) -> 16#F4;
isBox(16#C0) -> 16#1F;
isBox(16#C1) -> 16#DD;
isBox(16#C2) -> 16#A8;
isBox(16#C3) -> 16#33;
isBox(16#C4) -> 16#88;
isBox(16#C5) -> 16#07;
isBox(16#C6) -> 16#C7;
isBox(16#C7) -> 16#31;
isBox(16#C8) -> 16#B1;
isBox(16#C9) -> 16#12;
isBox(16#CA) -> 16#10;
isBox(16#CB) -> 16#59;
isBox(16#CC) -> 16#27;
isBox(16#CD) -> 16#80;
isBox(16#CE) -> 16#EC;
isBox(16#CF) -> 16#5F;
isBox(16#D0) -> 16#60;
isBox(16#D1) -> 16#51;
isBox(16#D2) -> 16#7F;
isBox(16#D3) -> 16#A9;
isBox(16#D4) -> 16#19;
isBox(16#D5) -> 16#B5;
isBox(16#D6) -> 16#4A;
isBox(16#D7) -> 16#0D;
isBox(16#D8) -> 16#2D;
isBox(16#D9) -> 16#E5;
isBox(16#DA) -> 16#7A;
isBox(16#DB) -> 16#9F;
isBox(16#DC) -> 16#93;
isBox(16#DD) -> 16#C9;
isBox(16#DE) -> 16#9C;
isBox(16#DF) -> 16#EF;
isBox(16#E0) -> 16#A0;
isBox(16#E1) -> 16#E0;
isBox(16#E2) -> 16#3B;
isBox(16#E3) -> 16#4D;
isBox(16#E4) -> 16#AE;
isBox(16#E5) -> 16#2A;
isBox(16#E6) -> 16#F5;
isBox(16#E7) -> 16#B0;
isBox(16#E8) -> 16#C8;
isBox(16#E9) -> 16#EB;
isBox(16#EA) -> 16#BB;
isBox(16#EB) -> 16#3C;
isBox(16#EC) -> 16#83;
isBox(16#ED) -> 16#53;
isBox(16#EE) -> 16#99;
isBox(16#EF) -> 16#61;
isBox(16#F0) -> 16#17;
isBox(16#F1) -> 16#2B;
isBox(16#F2) -> 16#04;
isBox(16#F3) -> 16#7E;
isBox(16#F4) -> 16#BA;
isBox(16#F5) -> 16#77;
isBox(16#F6) -> 16#D6;
isBox(16#F7) -> 16#26;
isBox(16#F8) -> 16#E1;
isBox(16#F9) -> 16#69;
isBox(16#FA) -> 16#14;
isBox(16#FB) -> 16#63;
isBox(16#FC) -> 16#55;
isBox(16#FD) -> 16#21;
isBox(16#FE) -> 16#0C;
isBox(16#FF) -> 16#7D.

%% @private
rcon(16#00) -> 16#8D;
rcon(16#01) -> 16#01;
rcon(16#02) -> 16#02;
rcon(16#03) -> 16#04;
rcon(16#04) -> 16#08;
rcon(16#05) -> 16#10;
rcon(16#06) -> 16#20;
rcon(16#07) -> 16#40;
rcon(16#08) -> 16#80;
rcon(16#09) -> 16#1B;
rcon(16#0A) -> 16#36;
rcon(16#0B) -> 16#6C;
rcon(16#0C) -> 16#D8;
rcon(16#0D) -> 16#AB;
rcon(16#0E) -> 16#4D;
rcon(16#0F) -> 16#9A;
rcon(16#10) -> 16#2F;
rcon(16#11) -> 16#5E;
rcon(16#12) -> 16#BC;
rcon(16#13) -> 16#63;
rcon(16#14) -> 16#C6;
rcon(16#15) -> 16#97;
rcon(16#16) -> 16#35;
rcon(16#17) -> 16#6A;
rcon(16#18) -> 16#D4;
rcon(16#19) -> 16#B3;
rcon(16#1A) -> 16#7D;
rcon(16#1B) -> 16#FA;
rcon(16#1C) -> 16#EF;
rcon(16#1D) -> 16#C5;
rcon(16#1E) -> 16#91;
rcon(16#1F) -> 16#39;
rcon(16#20) -> 16#72;
rcon(16#21) -> 16#E4;
rcon(16#22) -> 16#D3;
rcon(16#23) -> 16#BD;
rcon(16#24) -> 16#61;
rcon(16#25) -> 16#C2;
rcon(16#26) -> 16#9F;
rcon(16#27) -> 16#25;
rcon(16#28) -> 16#4A;
rcon(16#29) -> 16#94;
rcon(16#2A) -> 16#33;
rcon(16#2B) -> 16#66;
rcon(16#2C) -> 16#CC;
rcon(16#2D) -> 16#83;
rcon(16#2E) -> 16#1D;
rcon(16#2F) -> 16#3A;
rcon(16#30) -> 16#74;
rcon(16#31) -> 16#E8;
rcon(16#32) -> 16#CB;
rcon(16#33) -> 16#8D;
rcon(16#34) -> 16#01;
rcon(16#35) -> 16#02;
rcon(16#36) -> 16#04;
rcon(16#37) -> 16#08;
rcon(16#38) -> 16#10;
rcon(16#39) -> 16#20;
rcon(16#3A) -> 16#40;
rcon(16#3B) -> 16#80;
rcon(16#3C) -> 16#1B;
rcon(16#3D) -> 16#36;
rcon(16#3E) -> 16#6C;
rcon(16#3F) -> 16#D8;
rcon(16#40) -> 16#AB;
rcon(16#41) -> 16#4D;
rcon(16#42) -> 16#9A;
rcon(16#43) -> 16#2F;
rcon(16#44) -> 16#5E;
rcon(16#45) -> 16#BC;
rcon(16#46) -> 16#63;
rcon(16#47) -> 16#C6;
rcon(16#48) -> 16#97;
rcon(16#49) -> 16#35;
rcon(16#4A) -> 16#6A;
rcon(16#4B) -> 16#D4;
rcon(16#4C) -> 16#B3;
rcon(16#4D) -> 16#7D;
rcon(16#4E) -> 16#FA;
rcon(16#4F) -> 16#EF;
rcon(16#50) -> 16#C5;
rcon(16#51) -> 16#91;
rcon(16#52) -> 16#39;
rcon(16#53) -> 16#72;
rcon(16#54) -> 16#E4;
rcon(16#55) -> 16#D3;
rcon(16#56) -> 16#BD;
rcon(16#57) -> 16#61;
rcon(16#58) -> 16#C2;
rcon(16#59) -> 16#9F;
rcon(16#5A) -> 16#25;
rcon(16#5B) -> 16#4A;
rcon(16#5C) -> 16#94;
rcon(16#5D) -> 16#33;
rcon(16#5E) -> 16#66;
rcon(16#5F) -> 16#CC;
rcon(16#60) -> 16#83;
rcon(16#61) -> 16#1D;
rcon(16#62) -> 16#3A;
rcon(16#63) -> 16#74;
rcon(16#64) -> 16#E8;
rcon(16#65) -> 16#CB;
rcon(16#66) -> 16#8D;
rcon(16#67) -> 16#01;
rcon(16#68) -> 16#02;
rcon(16#69) -> 16#04;
rcon(16#6A) -> 16#08;
rcon(16#6B) -> 16#10;
rcon(16#6C) -> 16#20;
rcon(16#6D) -> 16#40;
rcon(16#6E) -> 16#80;
rcon(16#6F) -> 16#1B;
rcon(16#70) -> 16#36;
rcon(16#71) -> 16#6C;
rcon(16#72) -> 16#D8;
rcon(16#73) -> 16#AB;
rcon(16#74) -> 16#4D;
rcon(16#75) -> 16#9A;
rcon(16#76) -> 16#2F;
rcon(16#77) -> 16#5E;
rcon(16#78) -> 16#BC;
rcon(16#79) -> 16#63;
rcon(16#7A) -> 16#C6;
rcon(16#7B) -> 16#97;
rcon(16#7C) -> 16#35;
rcon(16#7D) -> 16#6A;
rcon(16#7E) -> 16#D4;
rcon(16#7F) -> 16#B3;
rcon(16#80) -> 16#7D;
rcon(16#81) -> 16#FA;
rcon(16#82) -> 16#EF;
rcon(16#83) -> 16#C5;
rcon(16#84) -> 16#91;
rcon(16#85) -> 16#39;
rcon(16#86) -> 16#72;
rcon(16#87) -> 16#E4;
rcon(16#88) -> 16#D3;
rcon(16#89) -> 16#BD;
rcon(16#8A) -> 16#61;
rcon(16#8B) -> 16#C2;
rcon(16#8C) -> 16#9F;
rcon(16#8D) -> 16#25;
rcon(16#8E) -> 16#4A;
rcon(16#8F) -> 16#94;
rcon(16#90) -> 16#33;
rcon(16#91) -> 16#66;
rcon(16#92) -> 16#CC;
rcon(16#93) -> 16#83;
rcon(16#94) -> 16#1D;
rcon(16#95) -> 16#3A;
rcon(16#96) -> 16#74;
rcon(16#97) -> 16#E8;
rcon(16#98) -> 16#CB;
rcon(16#99) -> 16#8D;
rcon(16#9A) -> 16#01;
rcon(16#9B) -> 16#02;
rcon(16#9C) -> 16#04;
rcon(16#9D) -> 16#08;
rcon(16#9E) -> 16#10;
rcon(16#9F) -> 16#20;
rcon(16#A0) -> 16#40;
rcon(16#A1) -> 16#80;
rcon(16#A2) -> 16#1B;
rcon(16#A3) -> 16#36;
rcon(16#A4) -> 16#6C;
rcon(16#A5) -> 16#D8;
rcon(16#A6) -> 16#AB;
rcon(16#A7) -> 16#4D;
rcon(16#A8) -> 16#9A;
rcon(16#A9) -> 16#2F;
rcon(16#AA) -> 16#5E;
rcon(16#AB) -> 16#BC;
rcon(16#AC) -> 16#63;
rcon(16#AD) -> 16#C6;
rcon(16#AE) -> 16#97;
rcon(16#AF) -> 16#35;
rcon(16#B0) -> 16#6A;
rcon(16#B1) -> 16#D4;
rcon(16#B2) -> 16#B3;
rcon(16#B3) -> 16#7D;
rcon(16#B4) -> 16#FA;
rcon(16#B5) -> 16#EF;
rcon(16#B6) -> 16#C5;
rcon(16#B7) -> 16#91;
rcon(16#B8) -> 16#39;
rcon(16#B9) -> 16#72;
rcon(16#BA) -> 16#E4;
rcon(16#BB) -> 16#D3;
rcon(16#BC) -> 16#BD;
rcon(16#BD) -> 16#61;
rcon(16#BE) -> 16#C2;
rcon(16#BF) -> 16#9F;
rcon(16#C0) -> 16#25;
rcon(16#C1) -> 16#4A;
rcon(16#C2) -> 16#94;
rcon(16#C3) -> 16#33;
rcon(16#C4) -> 16#66;
rcon(16#C5) -> 16#CC;
rcon(16#C6) -> 16#83;
rcon(16#C7) -> 16#1D;
rcon(16#C8) -> 16#3A;
rcon(16#C9) -> 16#74;
rcon(16#CA) -> 16#E8;
rcon(16#CB) -> 16#CB;
rcon(16#CC) -> 16#8D;
rcon(16#CD) -> 16#01;
rcon(16#CE) -> 16#02;
rcon(16#CF) -> 16#04;
rcon(16#D0) -> 16#08;
rcon(16#D1) -> 16#10;
rcon(16#D2) -> 16#20;
rcon(16#D3) -> 16#40;
rcon(16#D4) -> 16#80;
rcon(16#D5) -> 16#1B;
rcon(16#D6) -> 16#36;
rcon(16#D7) -> 16#6C;
rcon(16#D8) -> 16#D8;
rcon(16#D9) -> 16#AB;
rcon(16#DA) -> 16#4D;
rcon(16#DB) -> 16#9A;
rcon(16#DC) -> 16#2F;
rcon(16#DD) -> 16#5E;
rcon(16#DE) -> 16#BC;
rcon(16#DF) -> 16#63;
rcon(16#E0) -> 16#C6;
rcon(16#E1) -> 16#97;
rcon(16#E2) -> 16#35;
rcon(16#E3) -> 16#6A;
rcon(16#E4) -> 16#D4;
rcon(16#E5) -> 16#B3;
rcon(16#E6) -> 16#7D;
rcon(16#E7) -> 16#FA;
rcon(16#E8) -> 16#EF;
rcon(16#E9) -> 16#C5;
rcon(16#EA) -> 16#91;
rcon(16#EB) -> 16#39;
rcon(16#EC) -> 16#72;
rcon(16#ED) -> 16#E4;
rcon(16#EE) -> 16#D3;
rcon(16#EF) -> 16#BD;
rcon(16#F0) -> 16#61;
rcon(16#F1) -> 16#C2;
rcon(16#F2) -> 16#9F;
rcon(16#F3) -> 16#25;
rcon(16#F4) -> 16#4A;
rcon(16#F5) -> 16#94;
rcon(16#F6) -> 16#33;
rcon(16#F7) -> 16#66;
rcon(16#F8) -> 16#CC;
rcon(16#F9) -> 16#83;
rcon(16#FA) -> 16#1D;
rcon(16#FB) -> 16#3A;
rcon(16#FC) -> 16#74;
rcon(16#FD) -> 16#E8;
rcon(16#FE) -> 16#CB.

%% @private
sBox(16#00) -> 16#63;
sBox(16#01) -> 16#7C;
sBox(16#02) -> 16#77;
sBox(16#03) -> 16#7B;
sBox(16#04) -> 16#F2;
sBox(16#05) -> 16#6B;
sBox(16#06) -> 16#6F;
sBox(16#07) -> 16#C5;
sBox(16#08) -> 16#30;
sBox(16#09) -> 16#01;
sBox(16#0A) -> 16#67;
sBox(16#0B) -> 16#2B;
sBox(16#0C) -> 16#FE;
sBox(16#0D) -> 16#D7;
sBox(16#0E) -> 16#AB;
sBox(16#0F) -> 16#76;
sBox(16#10) -> 16#CA;
sBox(16#11) -> 16#82;
sBox(16#12) -> 16#C9;
sBox(16#13) -> 16#7D;
sBox(16#14) -> 16#FA;
sBox(16#15) -> 16#59;
sBox(16#16) -> 16#47;
sBox(16#17) -> 16#F0;
sBox(16#18) -> 16#AD;
sBox(16#19) -> 16#D4;
sBox(16#1A) -> 16#A2;
sBox(16#1B) -> 16#AF;
sBox(16#1C) -> 16#9C;
sBox(16#1D) -> 16#A4;
sBox(16#1E) -> 16#72;
sBox(16#1F) -> 16#C0;
sBox(16#20) -> 16#B7;
sBox(16#21) -> 16#FD;
sBox(16#22) -> 16#93;
sBox(16#23) -> 16#26;
sBox(16#24) -> 16#36;
sBox(16#25) -> 16#3F;
sBox(16#26) -> 16#F7;
sBox(16#27) -> 16#CC;
sBox(16#28) -> 16#34;
sBox(16#29) -> 16#A5;
sBox(16#2A) -> 16#E5;
sBox(16#2B) -> 16#F1;
sBox(16#2C) -> 16#71;
sBox(16#2D) -> 16#D8;
sBox(16#2E) -> 16#31;
sBox(16#2F) -> 16#15;
sBox(16#30) -> 16#04;
sBox(16#31) -> 16#C7;
sBox(16#32) -> 16#23;
sBox(16#33) -> 16#C3;
sBox(16#34) -> 16#18;
sBox(16#35) -> 16#96;
sBox(16#36) -> 16#05;
sBox(16#37) -> 16#9A;
sBox(16#38) -> 16#07;
sBox(16#39) -> 16#12;
sBox(16#3A) -> 16#80;
sBox(16#3B) -> 16#E2;
sBox(16#3C) -> 16#EB;
sBox(16#3D) -> 16#27;
sBox(16#3E) -> 16#B2;
sBox(16#3F) -> 16#75;
sBox(16#40) -> 16#09;
sBox(16#41) -> 16#83;
sBox(16#42) -> 16#2C;
sBox(16#43) -> 16#1A;
sBox(16#44) -> 16#1B;
sBox(16#45) -> 16#6E;
sBox(16#46) -> 16#5A;
sBox(16#47) -> 16#A0;
sBox(16#48) -> 16#52;
sBox(16#49) -> 16#3B;
sBox(16#4A) -> 16#D6;
sBox(16#4B) -> 16#B3;
sBox(16#4C) -> 16#29;
sBox(16#4D) -> 16#E3;
sBox(16#4E) -> 16#2F;
sBox(16#4F) -> 16#84;
sBox(16#50) -> 16#53;
sBox(16#51) -> 16#D1;
sBox(16#52) -> 16#00;
sBox(16#53) -> 16#ED;
sBox(16#54) -> 16#20;
sBox(16#55) -> 16#FC;
sBox(16#56) -> 16#B1;
sBox(16#57) -> 16#5B;
sBox(16#58) -> 16#6A;
sBox(16#59) -> 16#CB;
sBox(16#5A) -> 16#BE;
sBox(16#5B) -> 16#39;
sBox(16#5C) -> 16#4A;
sBox(16#5D) -> 16#4C;
sBox(16#5E) -> 16#58;
sBox(16#5F) -> 16#CF;
sBox(16#60) -> 16#D0;
sBox(16#61) -> 16#EF;
sBox(16#62) -> 16#AA;
sBox(16#63) -> 16#FB;
sBox(16#64) -> 16#43;
sBox(16#65) -> 16#4D;
sBox(16#66) -> 16#33;
sBox(16#67) -> 16#85;
sBox(16#68) -> 16#45;
sBox(16#69) -> 16#F9;
sBox(16#6A) -> 16#02;
sBox(16#6B) -> 16#7F;
sBox(16#6C) -> 16#50;
sBox(16#6D) -> 16#3C;
sBox(16#6E) -> 16#9F;
sBox(16#6F) -> 16#A8;
sBox(16#70) -> 16#51;
sBox(16#71) -> 16#A3;
sBox(16#72) -> 16#40;
sBox(16#73) -> 16#8F;
sBox(16#74) -> 16#92;
sBox(16#75) -> 16#9D;
sBox(16#76) -> 16#38;
sBox(16#77) -> 16#F5;
sBox(16#78) -> 16#BC;
sBox(16#79) -> 16#B6;
sBox(16#7A) -> 16#DA;
sBox(16#7B) -> 16#21;
sBox(16#7C) -> 16#10;
sBox(16#7D) -> 16#FF;
sBox(16#7E) -> 16#F3;
sBox(16#7F) -> 16#D2;
sBox(16#80) -> 16#CD;
sBox(16#81) -> 16#0C;
sBox(16#82) -> 16#13;
sBox(16#83) -> 16#EC;
sBox(16#84) -> 16#5F;
sBox(16#85) -> 16#97;
sBox(16#86) -> 16#44;
sBox(16#87) -> 16#17;
sBox(16#88) -> 16#C4;
sBox(16#89) -> 16#A7;
sBox(16#8A) -> 16#7E;
sBox(16#8B) -> 16#3D;
sBox(16#8C) -> 16#64;
sBox(16#8D) -> 16#5D;
sBox(16#8E) -> 16#19;
sBox(16#8F) -> 16#73;
sBox(16#90) -> 16#60;
sBox(16#91) -> 16#81;
sBox(16#92) -> 16#4F;
sBox(16#93) -> 16#DC;
sBox(16#94) -> 16#22;
sBox(16#95) -> 16#2A;
sBox(16#96) -> 16#90;
sBox(16#97) -> 16#88;
sBox(16#98) -> 16#46;
sBox(16#99) -> 16#EE;
sBox(16#9A) -> 16#B8;
sBox(16#9B) -> 16#14;
sBox(16#9C) -> 16#DE;
sBox(16#9D) -> 16#5E;
sBox(16#9E) -> 16#0B;
sBox(16#9F) -> 16#DB;
sBox(16#A0) -> 16#E0;
sBox(16#A1) -> 16#32;
sBox(16#A2) -> 16#3A;
sBox(16#A3) -> 16#0A;
sBox(16#A4) -> 16#49;
sBox(16#A5) -> 16#06;
sBox(16#A6) -> 16#24;
sBox(16#A7) -> 16#5C;
sBox(16#A8) -> 16#C2;
sBox(16#A9) -> 16#D3;
sBox(16#AA) -> 16#AC;
sBox(16#AB) -> 16#62;
sBox(16#AC) -> 16#91;
sBox(16#AD) -> 16#95;
sBox(16#AE) -> 16#E4;
sBox(16#AF) -> 16#79;
sBox(16#B0) -> 16#E7;
sBox(16#B1) -> 16#C8;
sBox(16#B2) -> 16#37;
sBox(16#B3) -> 16#6D;
sBox(16#B4) -> 16#8D;
sBox(16#B5) -> 16#D5;
sBox(16#B6) -> 16#4E;
sBox(16#B7) -> 16#A9;
sBox(16#B8) -> 16#6C;
sBox(16#B9) -> 16#56;
sBox(16#BA) -> 16#F4;
sBox(16#BB) -> 16#EA;
sBox(16#BC) -> 16#65;
sBox(16#BD) -> 16#7A;
sBox(16#BE) -> 16#AE;
sBox(16#BF) -> 16#08;
sBox(16#C0) -> 16#BA;
sBox(16#C1) -> 16#78;
sBox(16#C2) -> 16#25;
sBox(16#C3) -> 16#2E;
sBox(16#C4) -> 16#1C;
sBox(16#C5) -> 16#A6;
sBox(16#C6) -> 16#B4;
sBox(16#C7) -> 16#C6;
sBox(16#C8) -> 16#E8;
sBox(16#C9) -> 16#DD;
sBox(16#CA) -> 16#74;
sBox(16#CB) -> 16#1F;
sBox(16#CC) -> 16#4B;
sBox(16#CD) -> 16#BD;
sBox(16#CE) -> 16#8B;
sBox(16#CF) -> 16#8A;
sBox(16#D0) -> 16#70;
sBox(16#D1) -> 16#3E;
sBox(16#D2) -> 16#B5;
sBox(16#D3) -> 16#66;
sBox(16#D4) -> 16#48;
sBox(16#D5) -> 16#03;
sBox(16#D6) -> 16#F6;
sBox(16#D7) -> 16#0E;
sBox(16#D8) -> 16#61;
sBox(16#D9) -> 16#35;
sBox(16#DA) -> 16#57;
sBox(16#DB) -> 16#B9;
sBox(16#DC) -> 16#86;
sBox(16#DD) -> 16#C1;
sBox(16#DE) -> 16#1D;
sBox(16#DF) -> 16#9E;
sBox(16#E0) -> 16#E1;
sBox(16#E1) -> 16#F8;
sBox(16#E2) -> 16#98;
sBox(16#E3) -> 16#11;
sBox(16#E4) -> 16#69;
sBox(16#E5) -> 16#D9;
sBox(16#E6) -> 16#8E;
sBox(16#E7) -> 16#94;
sBox(16#E8) -> 16#9B;
sBox(16#E9) -> 16#1E;
sBox(16#EA) -> 16#87;
sBox(16#EB) -> 16#E9;
sBox(16#EC) -> 16#CE;
sBox(16#ED) -> 16#55;
sBox(16#EE) -> 16#28;
sBox(16#EF) -> 16#DF;
sBox(16#F0) -> 16#8C;
sBox(16#F1) -> 16#A1;
sBox(16#F2) -> 16#89;
sBox(16#F3) -> 16#0D;
sBox(16#F4) -> 16#BF;
sBox(16#F5) -> 16#E6;
sBox(16#F6) -> 16#42;
sBox(16#F7) -> 16#68;
sBox(16#F8) -> 16#41;
sBox(16#F9) -> 16#99;
sBox(16#FA) -> 16#2D;
sBox(16#FB) -> 16#0F;
sBox(16#FC) -> 16#B0;
sBox(16#FD) -> 16#54;
sBox(16#FE) -> 16#BB;
sBox(16#FF) -> 16#16.
