%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  29 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwe_enc).

-callback algorithm(ENC) -> Algorithm
	when
		ENC       :: any(),
		Algorithm :: iodata().
-callback bits(ENC) -> Bits
	when
		ENC  :: any(),
		Bits :: non_neg_integer().

-optional_callbacks([algorithm/1]).
-optional_callbacks([bits/1]).

-callback block_decrypt({AAD, CipherText, CipherTag}, CEK, IV, ENC) -> PlainText | error
	when
		AAD        :: iodata(),
		CipherText :: iodata(),
		CipherTag  :: iodata(),
		CEK        :: iodata(),
		IV         :: iodata(),
		ENC        :: any(),
		PlainText  :: iodata().
-callback block_encrypt({AAD, PlainText}, CEK, IV, ENC) -> {CipherText, CipherTag}
	when
		AAD        :: iodata(),
		PlainText  :: iodata(),
		CEK        :: iodata(),
		IV         :: iodata(),
		ENC        :: any(),
		CipherText :: iodata(),
		CipherTag  :: iodata().
-callback next_cek(ENC) -> CEK
	when
		ENC :: any(),
		CEK :: iodata().
-callback next_iv(ENC) -> IV
	when
		ENC :: any(),
		IV  :: iodata().
