%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  14 Sep 2019 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_xchacha20_poly1305_crypto).

-behaviour(jose_xchacha20_poly1305).

%% jose_xchacha20_poly1305 callbacks
-export([decrypt/5]).
-export([encrypt/4]).
-export([authenticate/3]).
-export([verify/4]).
%% Internal API
-export([hchacha20/2]).
-export([poly1305_key_gen/2]).
-export([xchacha20_subkey_and_nonce/2]).

%% Types
-type chacha20_key() :: <<_:256>>.
-type chacha20_nonce() :: <<_:96>>.
-type hchacha20_nonce() :: <<_:128>>.
-type hchacha20_block() :: <<_:256>>.
-type poly1305_otk() :: <<_:256>>.
-type xchacha20_nonce() :: <<_:192>>.

% -type poly1305_mac() :: <<_:128>>.

%%====================================================================
%% jose_xchacha20_poly1305 callbacks
%%====================================================================

decrypt(CipherText, CipherTag, AAD, IV, CEK) ->
	{Subkey, Nonce} = xchacha20_subkey_and_nonce(CEK, IV),
	crypto:crypto_one_time_aead(chacha20_poly1305, Subkey, Nonce, CipherText, AAD, CipherTag, false).

encrypt(PlainText, AAD, IV, CEK) ->
	{Subkey, Nonce} = xchacha20_subkey_and_nonce(CEK, IV),
    crypto:crypto_one_time_aead(chacha20_poly1305, Subkey, Nonce, PlainText, AAD, true).

authenticate(Message, Key, Nonce0) ->
	{Subkey, Nonce} = xchacha20_subkey_and_nonce(Key, Nonce0),
	OTK = poly1305_key_gen(Subkey, Nonce),
	crypto:mac(poly1305, OTK, Message).

verify(MAC, Message, Key, Nonce) ->
	Challenge = authenticate(Message, Key, Nonce),
	jose_jwa:constant_time_compare(MAC, Challenge).

%%====================================================================
%% Internal API Functions
%%====================================================================

%% @doc Short example of why this works: `HChaCha20 = ChaCha20 - State0'
%%
%% Longer example of why this works:
%%
%% ```
%% K  = 256-bit key
%% C  = 32-bit counter
%% N  = 96-bit nonce
%% X  = 128-bit nonce
%% || = concatenation
%% ++ = 32-bit word little endian addition
%% -- = 32-bit word little endian subtraction
%%
%% ChaCha20(K, C, N) =
%%     State0 = "expand 32-byte k" || K || C || N
%%     State1 = Rounds(State0, 10)
%%     State2 = State1 ++ State2
%%     return State2
%%
%% HChaCha20(K, X) =
%%     State0 = "expand 32-byte k" || K || X
%%     State1 = Rounds(State0, 10)
%%     return FirstBits(State1, 128) || LastBits(State1, 128)
%%
%% # Let's rewrite HChaCha20 to use ChaCha20 with State0 subtraction:
%%
%% HChaCha20(K, X) =
%%     C = FirstBits(X, 32)
%%     N = LastBits(X, 96)
%%     State0 = "expand 32-byte k" || K || X
%%     State2 = ChaCha20(K, C, N)
%%     State1 = State2 -- State0
%%     return FirstBits(State1, 128) || LastBits(State1, 128)
%%
%% # Let's further reduce to not use K and use a Mask for blinding:
%%
%% HChaCha20(K, X) =
%%     Mask = CSPRNG(512)
%%     C = FirstBits(X, 32)
%%     N = LastBits(X, 96)
%%     KeyStream = ChaCha20(K, C, N) ^ Mask
%%     State2 = (FirstBits(KeyStream, 128) || LastBits(KeyStream, 128)) ^
%%         (FirstBits(Mask, 128) || LastBits(Mask, 128))
%%     State0 = "expand 32-byte k" || X
%%     State1 = State2 -- State0
%%     return State1
%% '''
%%
%% See: [https://tools.ietf.org/html/rfc7539#section-2.3]
%% See: [https://tools.ietf.org/html/draft-irtf-cfrg-xchacha-03#section-2.2]
-spec hchacha20(
    Key :: chacha20_key(),
    Nonce :: hchacha20_nonce()
) -> hchacha20_block().
hchacha20(
    <<Key:256/bitstring>>,
    <<Nonce:128/bitstring>>
) ->
    %% ChaCha20 has an internal blocksize of 512-bits (64-bytes).
    %% Let's use a Mask of random 64-bytes to blind the intermediate keystream.
    Mask = <<MaskH:128/bits, _:256/bits, MaskT:128/bits>> = crypto:strong_rand_bytes(64),
    <<State2H:128/bits, _:256/bits, State2T:128/bits>> = crypto:crypto_one_time(chacha20, Key, Nonce, Mask, true),
    <<
        X00:32/unsigned-little-integer-unit:1,
        X01:32/unsigned-little-integer-unit:1,
        X02:32/unsigned-little-integer-unit:1,
        X03:32/unsigned-little-integer-unit:1,
        X12:32/unsigned-little-integer-unit:1,
        X13:32/unsigned-little-integer-unit:1,
        X14:32/unsigned-little-integer-unit:1,
        X15:32/unsigned-little-integer-unit:1
    >> = crypto:exor(<<MaskH:128/bits, MaskT:128/bits>>, <<State2H:128/bits, State2T:128/bits>>),
    %% The final step of ChaCha20 is `State2 = State0 + State1', so let's
    %% recover `State1' with subtraction: `State1 = State2 - State0'
    <<
        Y00:32/unsigned-little-integer-unit:1,
        Y01:32/unsigned-little-integer-unit:1,
        Y02:32/unsigned-little-integer-unit:1,
        Y03:32/unsigned-little-integer-unit:1,
        Y12:32/unsigned-little-integer-unit:1,
        Y13:32/unsigned-little-integer-unit:1,
        Y14:32/unsigned-little-integer-unit:1,
        Y15:32/unsigned-little-integer-unit:1
    >> = <<"expand 32-byte k", Nonce:128/bits>>,
    <<
        (X00 - Y00):32/unsigned-little-integer-unit:1,
        (X01 - Y01):32/unsigned-little-integer-unit:1,
        (X02 - Y02):32/unsigned-little-integer-unit:1,
        (X03 - Y03):32/unsigned-little-integer-unit:1,
        (X12 - Y12):32/unsigned-little-integer-unit:1,
        (X13 - Y13):32/unsigned-little-integer-unit:1,
        (X14 - Y14):32/unsigned-little-integer-unit:1,
        (X15 - Y15):32/unsigned-little-integer-unit:1
    >>.

-spec poly1305_key_gen(
	Key :: chacha20_key(),
	Nonce :: chacha20_nonce()
) -> poly1305_otk().
poly1305_key_gen(
	<<Key:256/bitstring>>,
	<<Nonce:96/bitstring>>
) ->
	crypto:crypto_one_time(chacha20, Key, <<0:32, Nonce:96/bits>>, <<0:256>>, true).

-spec xchacha20_subkey_and_nonce(
    Key :: chacha20_key(),
    Nonce :: xchacha20_nonce()
) -> {chacha20_key(), chacha20_nonce()}.
xchacha20_subkey_and_nonce(
    <<Key:256/bitstring>>,
    <<Nonce0:128/bitstring, Nonce1:64/bitstring>>
) ->
    Subkey = hchacha20(Key, Nonce0),
    Nonce = <<0:32, Nonce1:64/bitstring>>,
    {Subkey, Nonce}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
