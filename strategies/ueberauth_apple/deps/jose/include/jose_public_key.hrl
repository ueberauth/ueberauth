%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  12 May 2017 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------

-ifndef(JOSE_PUBLIC_KEY_HRL).

-include_lib("public_key/include/public_key.hrl").

-ifndef('id-aes128-CBC').
-define('id-aes128-CBC', {2,16,840,1,101,3,4,1,2}).
-endif.

-ifndef('id-aes192-CBC').
-define('id-aes192-CBC', {2,16,840,1,101,3,4,1,22}).
-endif.

-ifndef('id-aes256-CBC').
-define('id-aes256-CBC', {2,16,840,1,101,3,4,1,42}).
-endif.

%% PBES2 key-derivation defaults used when exporting a password-protected
%% PKCS#8 private key. Shared by jose_jwk_der:to_binary/3 and
%% jose_jwk_pem:to_binary/3 so that both export paths stay in sync.
%%
%% The OWASP "Password Storage Cheat Sheet" recommends 600,000 iterations for
%% PBKDF2-HMAC-SHA256, and NIST SP 800-132 requires a salt of at least 128
%% bits. Decoding is unaffected by these values: the salt and iteration count
%% are always read back out of the PBES2 parameters carried in the blob, so
%% keys exported by earlier releases keep importing unchanged.
-ifndef(JOSE_PBES2_SALT_BYTES).
-define(JOSE_PBES2_SALT_BYTES, 16).
-endif.

-ifndef(JOSE_PBES2_ITERATION_COUNT).
-define(JOSE_PBES2_ITERATION_COUNT, 600000).
-endif.

-define('jose_id-X25519', {1,3,101,110}).
-define('jose_id-X448', {1,3,101,111}).
-define('jose_id-EdDSA25519', {1,3,101,112}).
-define('jose_id-EdDSA448', {1,3,101,113}).

-record(jose_EdDSA25519PublicKey, {
	publicKey = undefined :: undefined | << _:256 >>
}).

-record(jose_EdDSA25519PrivateKey, {
	publicKey = undefined :: undefined | #jose_EdDSA25519PublicKey{},
	privateKey = undefined :: undefined | << _:256 >>
}).

-record(jose_EdDSA448PublicKey, {
	publicKey = undefined :: undefined | << _:456 >>
}).

-record(jose_EdDSA448PrivateKey, {
	publicKey = undefined :: undefined | #jose_EdDSA448PublicKey{},
	privateKey = undefined :: undefined | << _:456 >>
}).

-record(jose_X25519PublicKey, {
	publicKey = undefined :: undefined | << _:256 >>
}).

-record(jose_X25519PrivateKey, {
	publicKey = undefined :: undefined | #jose_X25519PublicKey{},
	privateKey = undefined :: undefined | << _:256 >>
}).

-record(jose_X448PublicKey, {
	publicKey = undefined :: undefined | << _:448 >>
}).

-record(jose_X448PrivateKey, {
	publicKey = undefined :: undefined | #jose_X448PublicKey{},
	privateKey = undefined :: undefined | << _:448 >>
}).

-define(JOSE_PUBLIC_KEY_HRL, 1).

-endif.
