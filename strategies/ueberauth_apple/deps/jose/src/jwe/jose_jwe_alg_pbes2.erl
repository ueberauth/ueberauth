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
-module(jose_jwe_alg_pbes2).
-behaviour(jose_jwe).
-behaviour(jose_jwe_alg).

-include("jose_jwk.hrl").

%% jose_jwe callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jwe_alg callbacks
-export([generate_key/3]).
-export([key_decrypt/3]).
-export([key_encrypt/3]).
-export([next_cek/3]).
%% API
-export([format_error/2]).
-export([hmac_supported/0]).
-export([wrap_supported/0]).

%% Types
-record(jose_jwe_alg_pbes2, {
	hmac = undefined :: undefined | sha256 | sha384 | sha512,
	salt = undefined :: undefined | binary(),
	iter = undefined :: undefined | pos_integer(),
	wrap = undefined :: undefined | aes_gcm_kw | aes_kw | c20p_kw | xc20p_kw,
	bits = undefined :: undefined | 128 | 192 | 256,
	iv   = undefined :: undefined | binary(),
	tag  = undefined :: undefined | binary()
}).

-type alg() :: #jose_jwe_alg_pbes2{}.

-export_type([alg/0]).

-define(PBES2_HS256_A128GCMKW, #jose_jwe_alg_pbes2{hmac=sha256, wrap=aes_gcm_kw, bits=128}).
-define(PBES2_HS384_A192GCMKW, #jose_jwe_alg_pbes2{hmac=sha384, wrap=aes_gcm_kw, bits=192}).
-define(PBES2_HS512_A256GCMKW, #jose_jwe_alg_pbes2{hmac=sha512, wrap=aes_gcm_kw, bits=256}).
-define(PBES2_HS256_A128KW,    #jose_jwe_alg_pbes2{hmac=sha256, wrap=aes_kw, bits=128}).
-define(PBES2_HS384_A192KW,    #jose_jwe_alg_pbes2{hmac=sha384, wrap=aes_kw, bits=192}).
-define(PBES2_HS512_A256KW,    #jose_jwe_alg_pbes2{hmac=sha512, wrap=aes_kw, bits=256}).
-define(PBES2_HS512_C20PKW,    #jose_jwe_alg_pbes2{hmac=sha512, wrap=c20p_kw, bits=256}).
-define(PBES2_HS512_XC20PKW,   #jose_jwe_alg_pbes2{hmac=sha512, wrap=xc20p_kw, bits=256}).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(F = #{ <<"alg">> := <<"PBES2-HS256+A128GCMKW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS256_A128GCMKW);
from_map(F = #{ <<"alg">> := <<"PBES2-HS384+A192GCMKW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS384_A192GCMKW);
from_map(F = #{ <<"alg">> := <<"PBES2-HS512+A256GCMKW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS512_A256GCMKW);
from_map(F = #{ <<"alg">> := <<"PBES2-HS256+A128KW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS256_A128KW);
from_map(F = #{ <<"alg">> := <<"PBES2-HS384+A192KW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS384_A192KW);
from_map(F = #{ <<"alg">> := <<"PBES2-HS512+A256KW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS512_A256KW);
from_map(F = #{ <<"alg">> := <<"PBES2-HS512+C20PKW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS512_C20PKW);
from_map(F = #{ <<"alg">> := <<"PBES2-HS512+XC20PKW">> }) ->
	from_map_pbes2(maps:remove(<<"alg">>, F), ?PBES2_HS512_XC20PKW).

to_map(A = ?PBES2_HS256_A128GCMKW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS256+A128GCMKW">> }, A);
to_map(A = ?PBES2_HS384_A192GCMKW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS384+A192GCMKW">> }, A);
to_map(A = ?PBES2_HS512_A256GCMKW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS512+A256GCMKW">> }, A);
to_map(A = ?PBES2_HS256_A128KW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS256+A128KW">> }, A);
to_map(A = ?PBES2_HS384_A192KW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS384+A192KW">> }, A);
to_map(A = ?PBES2_HS512_A256KW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS512+A256KW">> }, A);
to_map(A = ?PBES2_HS512_C20PKW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS512+C20PKW">> }, A);
to_map(A = ?PBES2_HS512_XC20PKW, F) ->
	to_map_pbes2(F#{ <<"alg">> => <<"PBES2-HS512+XC20PKW">> }, A).

%%====================================================================
%% jose_jwe_alg callbacks
%%====================================================================

generate_key(_Fields, {ENCModule, ENC}, ALG=#jose_jwe_alg_pbes2{}) ->
	jose_jwe_alg:generate_key({oct, 16}, maps:get(<<"alg">>, to_map(ALG, #{})), ENCModule:algorithm(ENC)).

key_decrypt(Password, {_ENCModule, _ENC, EncryptedKey}, #jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=aes_gcm_kw, bits=Bits, iv=IV, tag=TAG})
		when is_binary(Password)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	jose_jwa:block_decrypt({aes_gcm, Bits}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Password, {_ENCModule, _ENC, EncryptedKey}, #jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=aes_kw, bits=Bits}) when is_binary(Password) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	jose_jwa_aes_kw:unwrap(EncryptedKey, DerivedKey);
key_decrypt(Password, {_ENCModule, _ENC, EncryptedKey}, #jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=c20p_kw, bits=Bits, iv=IV, tag=TAG})
		when is_binary(Password)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	jose_jwa:block_decrypt({chacha20_poly1305, Bits}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(Password, {_ENCModule, _ENC, EncryptedKey}, #jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=xc20p_kw, bits=Bits, iv=IV, tag=TAG})
		when is_binary(Password)
		andalso is_binary(IV)
		andalso is_binary(TAG) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	jose_jwa:block_decrypt({xchacha20_poly1305, Bits}, DerivedKey, IV, {<<>>, EncryptedKey, TAG});
key_decrypt(#jose_jwk{kty={KTYModule, KTY}}, EncryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{}) ->
	key_decrypt(KTYModule:derive_key(KTY), EncryptedKey, JWEPBES2).

key_encrypt(Password, DecryptedKey, ALG0=#jose_jwe_alg_pbes2{bits=Bits, salt=undefined}) ->
	ALG1 = ALG0#jose_jwe_alg_pbes2{salt=wrap_salt(crypto:strong_rand_bytes(Bits div 8), ALG0)},
	key_encrypt(Password, DecryptedKey, ALG1);
key_encrypt(Password, DecryptedKey, ALG0=#jose_jwe_alg_pbes2{bits=Bits, iter=undefined}) ->
	ALG1 = ALG0#jose_jwe_alg_pbes2{iter=(Bits * 32)},
	key_encrypt(Password, DecryptedKey, ALG1);
key_encrypt(Password, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=aes_gcm_kw, bits=Bits, iv=IV})
		when is_binary(Password)
		andalso is_binary(DecryptedKey)
		andalso is_binary(Salt)
		andalso is_integer(Iterations)
		andalso is_binary(IV) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({aes_gcm, Bits}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEPBES2#jose_jwe_alg_pbes2{ tag = CipherTag }};
key_encrypt(Password, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=aes_kw, bits=Bits})
		when is_binary(Password)
		andalso is_binary(DecryptedKey)
		andalso is_binary(Salt)
		andalso is_integer(Iterations) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	{jose_jwa_aes_kw:wrap(DecryptedKey, DerivedKey), JWEPBES2};
key_encrypt(Password, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=c20p_kw, bits=Bits, iv=IV})
		when is_binary(Password)
		andalso is_binary(DecryptedKey)
		andalso is_binary(Salt)
		andalso is_integer(Iterations)
		andalso is_binary(IV) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({chacha20_poly1305, Bits}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEPBES2#jose_jwe_alg_pbes2{ tag = CipherTag }};
key_encrypt(Password, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{hmac=HMAC, salt=Salt, iter=Iterations, wrap=xc20p_kw, bits=Bits, iv=IV})
		when is_binary(Password)
		andalso is_binary(DecryptedKey)
		andalso is_binary(Salt)
		andalso is_integer(Iterations)
		andalso is_binary(IV) ->
	{ok, DerivedKey} = pbkdf2({hmac, HMAC}, Password, Salt, Iterations, (Bits div 8) + (Bits rem 8)),
	{CipherText, CipherTag} = jose_jwa:block_encrypt({xchacha20_poly1305, Bits}, DerivedKey, IV, {<<>>, DecryptedKey}),
	{CipherText, JWEPBES2#jose_jwe_alg_pbes2{ tag = CipherTag }};
key_encrypt(Password, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{wrap=aes_gcm_kw, iv=undefined}) when is_binary(Password) ->
	key_encrypt(Password, DecryptedKey, JWEPBES2#jose_jwe_alg_pbes2{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Password, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{wrap=c20p_kw, iv=undefined}) when is_binary(Password) ->
	key_encrypt(Password, DecryptedKey, JWEPBES2#jose_jwe_alg_pbes2{ iv = crypto:strong_rand_bytes(12) });
key_encrypt(Password, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{wrap=xc20p_kw, iv=undefined}) when is_binary(Password) ->
	key_encrypt(Password, DecryptedKey, JWEPBES2#jose_jwe_alg_pbes2{ iv = crypto:strong_rand_bytes(24) });
key_encrypt(#jose_jwk{kty={KTYModule, KTY}}, DecryptedKey, JWEPBES2=#jose_jwe_alg_pbes2{}) ->
	key_encrypt(KTYModule:derive_key(KTY), DecryptedKey, JWEPBES2).

next_cek(_Key, {ENCModule, ENC}, ALG=#jose_jwe_alg_pbes2{}) ->
	{ENCModule:next_cek(ENC), ALG}.

%%====================================================================
%% API functions
%%====================================================================

-spec format_error(term(), term()) -> term().
format_error(_Reason, [{_M, _F, _As, Info} | _]) ->
    ErrorInfo = proplists:get_value(error_info, Info, #{}),
    ErrorDescription1 = maps:get(cause, ErrorInfo),
    ErrorDescription1.

hmac_supported() ->
	[sha256, sha384, sha512].

wrap_supported() ->
	[128, 192, 256].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
from_map_pbes2(F = #{ <<"p2c">> := P2C }, H) ->
	from_map_pbes2(maps:remove(<<"p2c">>, F), H#jose_jwe_alg_pbes2{ iter = P2C });
from_map_pbes2(F = #{ <<"p2s">> := P2S }, H) ->
	from_map_pbes2(maps:remove(<<"p2s">>, F), H#jose_jwe_alg_pbes2{ salt = wrap_salt(jose_jwa_base64url:decode(P2S), H) });
from_map_pbes2(F=#{ <<"iv">> := IV }, H) ->
	from_map_pbes2(maps:remove(<<"iv">>, F), H#jose_jwe_alg_pbes2{ iv = jose_jwa_base64url:decode(IV) });
from_map_pbes2(F=#{ <<"tag">> := TAG }, H) ->
	from_map_pbes2(maps:remove(<<"tag">>, F), H#jose_jwe_alg_pbes2{ tag = jose_jwa_base64url:decode(TAG) });
from_map_pbes2(F, H) ->
	{H, F}.

%% @private
pbkdf2(Mac, Password, Salt, Iterations, DerivedKeyLen) ->
	PBES2CountMaximum = jose:pbes2_count_maximum(),
	case PBES2CountMaximum < Iterations of
		false ->
			jose_jwa_pkcs5:pbkdf2(Mac, Password, Salt, Iterations, DerivedKeyLen);
		true ->
			erlang:error(badarg, [Mac, <<"REDACTED">>, Salt, Iterations, DerivedKeyLen], [
				{error_info, #{
					module => ?MODULE,
					cause => #{4 => lists:flatten(io_lib:format("maximum PBES2 iterations is set to ~w, but ~w was attempted (see jose:pbes2_count_maximum/0)", [PBES2CountMaximum, Iterations]))}
				}}
			])
	end.

%% @private
to_map_pbes2(F, H=#jose_jwe_alg_pbes2{ iter = P2C }) when is_integer(P2C) ->
	to_map_pbes2(F#{ <<"p2c">> => P2C }, H#jose_jwe_alg_pbes2{ iter = undefined });
to_map_pbes2(F, H=#jose_jwe_alg_pbes2{ salt = P2S }) when is_binary(P2S) ->
	to_map_pbes2(F#{ <<"p2s">> => jose_jwa_base64url:encode(unwrap_salt(P2S, H)) }, H#jose_jwe_alg_pbes2{ salt = undefined });
to_map_pbes2(F, H=#jose_jwe_alg_pbes2{ iv = IV }) when is_binary(IV) ->
	to_map_pbes2(F#{ <<"iv">> => jose_jwa_base64url:encode(IV) }, H#jose_jwe_alg_pbes2{ iv = undefined });
to_map_pbes2(F, H=#jose_jwe_alg_pbes2{ tag = TAG }) when is_binary(TAG) ->
	to_map_pbes2(F#{ <<"tag">> => jose_jwa_base64url:encode(TAG) }, H#jose_jwe_alg_pbes2{ tag = undefined });
to_map_pbes2(F, _) ->
	F.

%% @private
wrap_salt(SaltInput, ?PBES2_HS256_A128GCMKW) ->
	<< "PBES2-HS256+A128GCMKW", 0, SaltInput/binary >>;
wrap_salt(SaltInput, ?PBES2_HS384_A192GCMKW) ->
	<< "PBES2-HS384+A192GCMKW", 0, SaltInput/binary >>;
wrap_salt(SaltInput, ?PBES2_HS512_A256GCMKW) ->
	<< "PBES2-HS512+A256GCMKW", 0, SaltInput/binary >>;
wrap_salt(SaltInput, ?PBES2_HS256_A128KW) ->
	<< "PBES2-HS256+A128KW", 0, SaltInput/binary >>;
wrap_salt(SaltInput, ?PBES2_HS384_A192KW) ->
	<< "PBES2-HS384+A192KW", 0, SaltInput/binary >>;
wrap_salt(SaltInput, ?PBES2_HS512_A256KW) ->
	<< "PBES2-HS512+A256KW", 0, SaltInput/binary >>;
wrap_salt(SaltInput, ?PBES2_HS512_C20PKW) ->
	<< "PBES2-HS512+C20PKW", 0, SaltInput/binary >>;
wrap_salt(SaltInput, ?PBES2_HS512_XC20PKW) ->
	<< "PBES2-HS512+XC20PKW", 0, SaltInput/binary >>.

%% @private
unwrap_salt(<< "PBES2-HS256+A128GCMKW", 0, SaltInput/binary >>, ?PBES2_HS256_A128GCMKW) ->
	SaltInput;
unwrap_salt(<< "PBES2-HS384+A192GCMKW", 0, SaltInput/binary >>, ?PBES2_HS384_A192GCMKW) ->
	SaltInput;
unwrap_salt(<< "PBES2-HS512+A256GCMKW", 0, SaltInput/binary >>, ?PBES2_HS512_A256GCMKW) ->
	SaltInput;
unwrap_salt(<< "PBES2-HS256+A128KW", 0, SaltInput/binary >>, ?PBES2_HS256_A128KW) ->
	SaltInput;
unwrap_salt(<< "PBES2-HS384+A192KW", 0, SaltInput/binary >>, ?PBES2_HS384_A192KW) ->
	SaltInput;
unwrap_salt(<< "PBES2-HS512+A256KW", 0, SaltInput/binary >>, ?PBES2_HS512_A256KW) ->
	SaltInput;
unwrap_salt(<< "PBES2-HS512+C20PKW", 0, SaltInput/binary >>, ?PBES2_HS512_C20PKW) ->
	SaltInput;
unwrap_salt(<< "PBES2-HS512+XC20PKW", 0, SaltInput/binary >>, ?PBES2_HS512_XC20PKW) ->
	SaltInput.
