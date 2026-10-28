%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  16 Mar 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk_use_enc).

-callback block_encryptor(KTY, Fields) -> JWEMap
	when
		KTY    :: any(),
		Fields :: map(),
		JWEMap :: map().

-callback decrypt_private(CipherText, Options, KTY) -> PlainText
	when
		CipherText :: iodata(),
		Options    :: any(),
		KTY        :: any(),
		PlainText  :: iodata().
-callback derive_key(KTY) -> DerivedKey
	when
		KTY        :: any(),
		DerivedKey :: iodata().
-callback derive_key(OtherKTY, KTY) -> DerivedKey
	when
		OtherKTY   :: any(),
		KTY        :: any(),
		DerivedKey :: iodata().
-callback encrypt_public(PlainText, Options, KTY) -> CipherText
	when
		PlainText  :: iodata(),
		Options    :: any(),
		KTY        :: any(),
		CipherText :: iodata().

-optional_callbacks([decrypt_private/3]).
-optional_callbacks([derive_key/1]).
-optional_callbacks([derive_key/2]).
-optional_callbacks([encrypt_public/3]).

%%====================================================================
%% API functions
%%====================================================================

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
