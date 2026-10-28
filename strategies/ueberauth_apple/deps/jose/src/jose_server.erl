%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  13 Aug 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_server).
-behaviour(gen_server).

-include_lib("public_key/include/public_key.hrl").

-define(SERVER, ?MODULE).

%% API
-export([start_link/0]).
-export([config_change/0]).
-export([chacha20_poly1305_module/1]).
-export([curve25519_module/1]).
-export([curve448_module/1]).
-export([json_module/1]).
-export([pbes2_count_maximum/1]).
-export([sha3_module/1]).
-export([unsecured_signing/1]).
-export([xchacha20_poly1305_module/1]).
-export([zip_size_maximum/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(CRYPTO_FALLBACK, application:get_env(jose, crypto_fallback, false)).

-define(TAB, jose_jwa).

-define(POISON_MAP, #{
	<<"a">> => 1,
	<<"b">> => 2,
	<<"c">> => #{
		<<"d">> => 3,
		<<"e">> => 4
	}
}).
-define(POISON_BIN, <<"{\"a\":1,\"b\":2,\"c\":{\"d\":3,\"e\":4}}">>).

%% Types
-record(state, {}).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

config_change() ->
	gen_server:call(?SERVER, config_change).

chacha20_poly1305_module(ChaCha20Poly1305Module) when is_atom(ChaCha20Poly1305Module) ->
	gen_server:call(?SERVER, {chacha20_poly1305_module, ChaCha20Poly1305Module}).

curve25519_module(Curve25519Module) when is_atom(Curve25519Module) ->
	gen_server:call(?SERVER, {curve25519_module, Curve25519Module}).

curve448_module(Curve448Module) when is_atom(Curve448Module) ->
	gen_server:call(?SERVER, {curve448_module, Curve448Module}).

json_module(JSONModule) when is_atom(JSONModule) ->
	gen_server:call(?SERVER, {json_module, JSONModule}).

-spec pbes2_count_maximum(PBES2CountMaximum) -> ok when PBES2CountMaximum :: non_neg_integer().
pbes2_count_maximum(PBES2CountMaximum) when is_integer(PBES2CountMaximum) andalso PBES2CountMaximum >= 0 ->
	gen_server:call(?SERVER, {pbes2_count_maximum, PBES2CountMaximum}).

sha3_module(SHA3Module) when is_atom(SHA3Module) ->
	gen_server:call(?SERVER, {sha3_module, SHA3Module}).

-spec unsecured_signing(UnsecuredSigning) -> ok when UnsecuredSigning :: boolean().
unsecured_signing(UnsecuredSigning) when is_boolean(UnsecuredSigning) ->
	gen_server:call(?SERVER, {unsecured_signing, UnsecuredSigning}).

xchacha20_poly1305_module(XChaCha20Poly1305Module) when is_atom(XChaCha20Poly1305Module) ->
	gen_server:call(?SERVER, {xchacha20_poly1305_module, XChaCha20Poly1305Module}).

-spec zip_size_maximum(ZipSizeMaximum) -> ok when ZipSizeMaximum :: non_neg_integer().
zip_size_maximum(ZipSizeMaximum) when is_integer(ZipSizeMaximum) andalso ZipSizeMaximum >= 0 ->
	gen_server:call(?SERVER, {zip_size_maximum, ZipSizeMaximum}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	?TAB = ets:new(?TAB, [
		named_table,
		public,
		ordered_set,
		{read_concurrency, true}
	]),
	ok = support_check(),
	{ok, #state{}}.

%% @private
handle_call(config_change, _From, State) ->
	{reply, support_check(), State};
handle_call({chacha20_poly1305_module, M}, _From, State) ->
	ChaCha20Poly1305Module = check_chacha20_poly1305_module(M),
	Entries = lists:flatten(check_crypto(?CRYPTO_FALLBACK, [{chacha20_poly1305_module, ChaCha20Poly1305Module}])),
	_ = ets:select_delete(?TAB, [{{{cipher, '_'}, '_'}, [], [true]}]),
	true = ets:insert(?TAB, Entries),
	{reply, ok, State};
handle_call({curve25519_module, M}, _From, State) ->
	Curve25519Module = check_curve25519_module(M),
	true = ets:insert(?TAB, {curve25519_module, Curve25519Module}),
	{reply, ok, State};
handle_call({curve448_module, M}, _From, State) ->
	Curve448Module = check_curve448_module(M),
	true = ets:insert(?TAB, {curve448_module, Curve448Module}),
	{reply, ok, State};
handle_call({json_module, M}, _From, State) ->
	JSONModule = check_json_module(M),
	true = ets:insert(?TAB, {json_module, JSONModule}),
	{reply, ok, State};
handle_call({pbes2_count_maximum, PBES2CountMaximum}, _From, State) when is_integer(PBES2CountMaximum) andalso PBES2CountMaximum >= 0 ->
	true = ets:insert(?TAB, {pbes2_count_maximum, PBES2CountMaximum}),
	{reply, ok, State};
handle_call({sha3_module, M}, _From, State) ->
	SHA3Module = check_sha3_module(M),
	true = ets:insert(?TAB, {sha3_module, SHA3Module}),
	{reply, ok, State};
handle_call({unsecured_signing, UnsecuredSigning}, _From, State) when is_boolean(UnsecuredSigning) ->
	true = ets:insert(?TAB, {unsecured_signing, UnsecuredSigning}),
	_ = spawn(fun() ->
		_ = try jose_jwa:unsecured_signing(UnsecuredSigning) catch _:_ -> ok end,
		exit(normal)
	end),
	{reply, ok, State};
handle_call({xchacha20_poly1305_module, M}, _From, State) ->
	XChaCha20Poly1305Module = check_xchacha20_poly1305_module(M),
	Entries = lists:flatten(check_crypto(?CRYPTO_FALLBACK, [{xchacha20_poly1305_module, XChaCha20Poly1305Module}])),
	_ = ets:select_delete(?TAB, [{{{cipher, '_'}, '_'}, [], [true]}]),
	true = ets:insert(?TAB, Entries),
	{reply, ok, State};
handle_call({zip_size_maximum, ZipSizeMaximum}, _From, State) when is_integer(ZipSizeMaximum) andalso ZipSizeMaximum >= 0 ->
	true = ets:insert(?TAB, {zip_size_maximum, ZipSizeMaximum}),
	{reply, ok, State};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info(_Info, State) ->
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
support_check() ->
	PBES2CountMaximum =
		case application:get_env(jose, pbes2_count_maximum, 10000) of
			V1 when is_integer(V1) andalso V1 >= 0 ->
				V1
		end,
	UnsecuredSigning =
		case application:get_env(jose, unsecured_signing, false) of
			V2 when is_boolean(V2) ->
				V2
		end,
	ZipSizeMaximum =
		case application:get_env(jose, zip_size_maximum, 1048576) of
			V3 when is_integer(V3) andalso V3 >= 0 ->
				V3
		end,
	Fallback = ?CRYPTO_FALLBACK,
	Entries1 = lists:flatten(lists:foldl(fun(Check, Acc) ->
		Check(Fallback, Acc)
	end, [], [
		fun check_sha3/2,
		fun check_ec_key_mode/2,
		fun check_chacha20_poly1305/2,
		fun check_xchacha20_poly1305/2,
		fun check_curve25519/2,
		fun check_curve448/2,
		fun check_json/2,
		fun check_crypto/2,
		fun check_public_key/2
	])),
	Entries2 = [
		{pbes2_count_maximum, PBES2CountMaximum},
		{unsecured_signing, UnsecuredSigning},
		{zip_size_maximum, ZipSizeMaximum}
		| Entries1
	],
	true = ets:delete_all_objects(?TAB),
	true = ets:insert(?TAB, Entries2),
	ok.

%%%-------------------------------------------------------------------
%%% Internal check functions
%%%-------------------------------------------------------------------

%% @private
check_ec_key_mode(_Fallback, Entries) ->
	PEMBin = <<
			48,119,2,1,1,4,32,104,152,88,12,19,82,251,156,171,31,222,207,
			0,76,115,88,210,229,36,106,137,192,81,153,154,254,226,38,247,
			70,226,157,160,10,6,8,42,134,72,206,61,3,1,7,161,68,3,66,0,4,
			46,75,29,46,150,77,222,40,220,159,244,193,125,18,190,254,216,
			38,191,11,52,115,159,213,230,77,27,131,94,17,46,21,186,71,62,
			36,225,0,90,21,186,235,132,152,229,13,189,196,121,64,84,64,
			229,173,12,24,23,127,175,67,247,29,139,91
		>>,
	PEMEntry = {'ECPrivateKey', PEMBin, not_encrypted},
	%% Erlang 24 changes 'ECPrivateKey' record in a way that makes record matching fail
	%% when this module is compiled on Erlang 23 (or earlier) but runs on 24.
	%% So we destructure tuples, as ugly as it may be.
	%%
	%% See erlang-jose#113 for details.
	PrivateKey = case list_to_integer(erlang:system_info(otp_release)) >= 24 of
		true ->
			{'ECPrivateKey', _Version, PrivKey0, _Params, _PubKey0, _Attributes} = public_key:pem_entry_decode(PEMEntry),
			PrivKey0;
		false ->
			{'ECPrivateKey', _Version, PrivKey0, _Params, _PubKey0} = public_key:pem_entry_decode(PEMEntry),
			PrivKey0
	end,
	case is_binary(PrivateKey) of
		true -> [{ec_key_mode, binary} | Entries];
		_    -> [{ec_key_mode, list} | Entries]
	end.

%% @private
check_chacha20_poly1305(false, Entries) ->
	check_chacha20_poly1305(jose_chacha20_poly1305_unsupported, Entries);
check_chacha20_poly1305(true, Entries) ->
	check_chacha20_poly1305(jose_jwa_chacha20_poly1305, Entries);
check_chacha20_poly1305(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {chacha20_poly1305_module, jose_jwa_chacha20_poly1305}),
	true = ets:delete_object(?TAB, {chacha20_poly1305_module, jose_chacha20_poly1305_unsupported}),
	ChaCha20Poly1305Module = case ets:lookup(?TAB, chacha20_poly1305_module) of
		[{chacha20_poly1305_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, chacha20_poly1305_module, undefined) of
				undefined ->
					check_chacha20_poly1305_modules(Fallback, [crypto, libsodium]);
				M when is_atom(M) ->
					check_chacha20_poly1305_module(M)
			end
	end,
	%% Potentially used by XChaCha20-Poly1305 related functions below, needs to be inserted early.
	true = ets:insert(?TAB, {chacha20_poly1305_module, ChaCha20Poly1305Module}),
	[{chacha20_poly1305_module, ChaCha20Poly1305Module} | Entries].

%% @private
check_chacha20_poly1305_module(crypto) ->
	jose_chacha20_poly1305_crypto;
check_chacha20_poly1305_module(libsodium) ->
	jose_chacha20_poly1305_libsodium;
check_chacha20_poly1305_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_chacha20_poly1305_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			M = check_chacha20_poly1305_module(Module),
			PT = crypto:strong_rand_bytes(8),
			CEK = crypto:strong_rand_bytes(32),
			IV = crypto:strong_rand_bytes(12),
			AAD = <<>>,
			try M:encrypt(PT, AAD, IV, CEK) of
				{CT, TAG} when is_binary(CT) andalso is_binary(TAG) ->
					try M:decrypt(CT, TAG, AAD, IV, CEK) of
						PT ->
							M;
						_ ->
							check_chacha20_poly1305_modules(Fallback, Modules)
					catch
						_:_ ->
							check_chacha20_poly1305_modules(Fallback, Modules)
					end;
				_ ->
					check_chacha20_poly1305_modules(Fallback, Modules)
			catch
				_:_ ->
					check_chacha20_poly1305_modules(Fallback, Modules)
			end;
		_ ->
			check_chacha20_poly1305_modules(Fallback, Modules)
	end;
check_chacha20_poly1305_modules(Fallback, []) ->
	Fallback.

%% @private
check_curve25519(false, Entries) ->
	check_curve25519(jose_curve25519_unsupported, Entries);
check_curve25519(true, Entries) ->
	check_curve25519(jose_jwa_curve25519, Entries);
check_curve25519(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {curve25519_module, jose_jwa_curve25519}),
	true = ets:delete_object(?TAB, {curve25519_module, jose_curve25519_unsupported}),
	Curve25519Module = case ets:lookup(?TAB, curve25519_module) of
		[{curve25519_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, curve25519_module, undefined) of
				undefined ->
					check_curve25519_modules(Fallback, [libdecaf, libsodium, crypto]);
				M when is_atom(M) ->
					check_curve25519_module(M)
			end
	end,
	[{curve25519_module, Curve25519Module} | Entries].

%% @private
check_curve25519_module(crypto) ->
	jose_curve25519_crypto;
check_curve25519_module(libdecaf) ->
	jose_curve25519_libdecaf;
check_curve25519_module(libsodium) ->
	jose_curve25519_libsodium;
check_curve25519_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_curve25519_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			RealFallback = jose_jwa_curve25519,
			RealModule = check_curve25519_module(Module),
			try check_curve25519_module_does_it_work(RealFallback, RealModule) of
				true ->
					RealModule;
				false ->
					check_curve25519_modules(Fallback, Modules)
			catch _Class:_Reason:_Stacktrace ->
				% io:format("Class = ~p~nReason = ~p~nStacktrace = ~p~n", [Class, Reason, Stacktrace]),
				check_curve25519_modules(Fallback, Modules)
			end;
		_ ->
			check_curve25519_modules(Fallback, Modules)
	end;
check_curve25519_modules(Fallback, []) ->
	Fallback.

%% @private
check_curve25519_module_does_it_work(Fallback, Module) ->
	{PK, SK = <<Secret:32/binary, _:32/binary>>} = Module:eddsa_keypair(),
	{PK, SK} = Module:eddsa_keypair(Secret),
	PK = Module:eddsa_secret_to_public(Secret),
	Message = crypto:strong_rand_bytes(16),
	Signature = Module:ed25519_sign(Message, SK),
	true = Module:ed25519_verify(Signature, Message, PK),
	true = Fallback:ed25519_verify(Signature, Message, PK),
	{XPK, XSK} = Module:x25519_keypair(),
	XPK = Module:x25519_secret_to_public(XSK),
	{PeerPK, PeerSK} = Module:x25519_keypair(),
	Shared = Module:x25519_shared_secret(XSK, PeerPK),
	Shared = Module:x25519_shared_secret(PeerSK, XPK),
	%% NOTE: Ed25519ctx and Ed25519ph are lower priority, no need to check for now.
	% Ctx = <<"ctx">>,
	% CtxSignature = Module:ed25519ctx_sign(Message, SK, Ctx),
	% true = Module:ed25519ctx_verify(CtxSignature, Message, PK, Ctx),
	% true = Fallback:ed25519ctx_verify(CtxSignature, Message, PK, Ctx),
	% PHSignature = Module:ed25519ph_sign(Message, SK),
	% true = Module:ed25519ph_verify(PHSignature, Message, PK),
	% true = Fallback:ed25519ph_verify(PHSignature, Message, PK),
	% CtxPHSignature = Module:ed25519ph_sign(Message, SK, Ctx),
	% true = Module:ed25519ph_verify(CtxPHSignature, Message, PK, Ctx),
	% true = Fallback:ed25519ph_verify(CtxPHSignature, Message, PK, Ctx),
	true.

%% @private
check_curve448(false, Entries) ->
	check_curve448(jose_curve448_unsupported, Entries);
check_curve448(true, Entries) ->
	check_curve448(jose_jwa_curve448, Entries);
check_curve448(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {curve448_module, jose_jwa_curve448}),
	true = ets:delete_object(?TAB, {curve448_module, jose_curve448_unsupported}),
	Curve448Module = case ets:lookup(?TAB, curve448_module) of
		[{curve448_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, curve448_module, undefined) of
				undefined ->
					check_curve448_modules(Fallback, [libdecaf, crypto]);
				M when is_atom(M) ->
					check_curve448_module(M)
			end
	end,
	[{curve448_module, Curve448Module} | Entries].

%% @private
check_curve448_module(crypto) ->
	jose_curve448_crypto;
check_curve448_module(libdecaf) ->
	jose_curve448_libdecaf;
check_curve448_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_curve448_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			RealFallback = jose_jwa_curve448,
			RealModule = check_curve448_module(Module),
			try check_curve448_module_does_it_work(RealFallback, RealModule) of
				true ->
					RealModule;
				false ->
					check_curve448_modules(Fallback, Modules)
			catch _Class:_Reason:_Stacktrace ->
				% io:format("Class = ~p~nReason = ~p~nStacktrace = ~p~n", [_Class, _Reason, _Stacktrace]),
				check_curve448_modules(Fallback, Modules)
			end;
		_ ->
			check_curve448_modules(Fallback, Modules)
	end;
check_curve448_modules(Fallback, []) ->
	Fallback.

%% @private
check_curve448_module_does_it_work(Fallback, Module) ->
	{PK, SK = <<Secret:57/binary, _:57/binary>>} = Module:eddsa_keypair(),
	{PK, SK} = Module:eddsa_keypair(Secret),
	PK = Module:eddsa_secret_to_public(Secret),
	Message = crypto:strong_rand_bytes(16),
	Signature = Module:ed448_sign(Message, SK),
	true = Module:ed448_verify(Signature, Message, PK),
	%% The pure verifier needs SHAKE256, which may be unavailable when
	%% fallback is disabled. Do not reject a working native provider for that.
	case ?CRYPTO_FALLBACK of
		true -> true = Fallback:ed448_verify(Signature, Message, PK);
		false -> ok
	end,
	{XPK, XSK} = Module:x448_keypair(),
	XPK = Module:x448_secret_to_public(XSK),
	{PeerPK, PeerSK} = Module:x448_keypair(),
	Shared = Module:x448_shared_secret(XSK, PeerPK),
	Shared = Module:x448_shared_secret(PeerSK, XPK),
	%% NOTE: Ed448ph is lower priority, no need to check for now.
	% Ctx = <<"ctx">>,
	% CtxSignature = Module:ed448_sign(Message, SK, Ctx),
	% true = Module:ed448_verify(CtxSignature, Message, PK, Ctx),
	% true = Fallback:ed448_verify(CtxSignature, Message, PK, Ctx),
	% PHSignature = Module:ed448ph_sign(Message, SK),
	% true = Module:ed448ph_verify(PHSignature, Message, PK),
	% true = Fallback:ed448ph_verify(PHSignature, Message, PK),
	% CtxPHSignature = Module:ed448ph_sign(Message, SK, Ctx),
	% true = Module:ed448ph_verify(CtxPHSignature, Message, PK, Ctx),
	% true = Fallback:ed448ph_verify(CtxPHSignature, Message, PK, Ctx),
	true.

%% @private
check_json(_Fallback, Entries) ->
	JSONModule = case ets:lookup(?TAB, json_module) of
		[{json_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, json_module, undefined) of
				undefined ->
					case code:ensure_loaded(elixir) of
						{module, elixir} ->
							check_json_modules([json, ojson, 'Elixir.Jason', 'Elixir.Poison', jiffy, jsone, jsx, thoas]);
						_ ->
							check_json_modules([json, ojson, jiffy, jsone, jsx, thoas])
					end;
				M when is_atom(M) ->
					check_json_module(M)
			end
	end,
	[{json_module, JSONModule} | Entries].

%% @private
check_json_module(json) ->
	jose_json_otp;
check_json_module(jiffy) ->
	jose_json_jiffy;
check_json_module(jsx) ->
	jose_json_jsx;
check_json_module(jsone) ->
	jose_json_jsone;
check_json_module(ojson) ->
	jose_json_ojson;
check_json_module(thoas) ->
	jose_json_thoas;
check_json_module('Elixir.Jason') ->
	jose_json_jason;
check_json_module('Elixir.Poison') ->
	Map = ?POISON_MAP,
	Bin = ?POISON_BIN,
	case jose_json_poison:encode(Map) of
		Bin ->
			jose_json_poison;
		_ ->
			check_json_module('Elixir.JOSE.Poison')
	end;
check_json_module('Elixir.JOSE.Poison') ->
	Map = ?POISON_MAP,
	Bin = ?POISON_BIN,
	case code:ensure_loaded('Elixir.JOSE.Poison') of
		{module, 'Elixir.JOSE.Poison'} ->
			try jose_json_poison_lexical_encoder:encode(Map) of
				Bin ->
					jose_json_poison_lexical_encoder;
				_ ->
					check_json_module(jose_json_poison_compat_encoder)
			catch
				_:_ ->
					check_json_module(jose_json_poison_compat_encoder)
			end;
		_ ->
			check_json_module(jose_json_poison_compat_encoder)
	end;
check_json_module(jose_json_poison_compat_encoder) ->
	Map = ?POISON_MAP,
	Bin = ?POISON_BIN,
	try jose_json_poison_compat_encoder:encode(Map) of
		Bin ->
			jose_json_poison_compat_encoder;
		_ ->
			jose_json_poison
	catch
		_:_ ->
			jose_json_poison
	end;
check_json_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_json_modules([Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			check_json_module(Module);
		_ ->
			check_json_modules(Modules)
	end;
check_json_modules([]) ->
	jose_json_unsupported.

%% @private
check_sha3(false, Entries) ->
	check_sha3(jose_sha3_unsupported, Entries);
check_sha3(true, Entries) ->
	check_sha3(jose_jwa_sha3, Entries);
check_sha3(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {sha3_module, jose_jwa_sha3}),
	true = ets:delete_object(?TAB, {sha3_module, jose_sha3_unsupported}),
	SHA3Module = case ets:lookup(?TAB, sha3_module) of
		[{sha3_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, sha3_module, undefined) of
				undefined ->
					check_sha3_modules(Fallback, [libdecaf, keccakf1600]);
				M when is_atom(M) ->
					check_sha3_module(M)
			end
	end,
	%% Potentially used by Ed448 related functions below, needs to be inserted early.
	true = ets:insert(?TAB, {sha3_module, SHA3Module}),
	[{sha3_module, SHA3Module} | Entries].

%% @private
check_sha3_module(keccakf1600) ->
	check_sha3_module(jose_sha3_keccakf1600);
check_sha3_module(libdecaf) ->
	check_sha3_module(jose_sha3_libdecaf);
check_sha3_module(jose_sha3_keccakf1600) ->
	_ = code:ensure_loaded(keccakf1600),
	case erlang:function_exported(keccakf1600, hash, 3) of
		false ->
			% version < 2
			check_sha3_module(jose_sha3_keccakf1600_driver);
		true ->
			% version >= 2
			check_sha3_module(jose_sha3_keccakf1600_nif)
	end;
check_sha3_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_sha3_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			check_sha3_module(Module);
		_ ->
			check_sha3_modules(Fallback, Modules)
	end;
check_sha3_modules(Fallback, []) ->
	Fallback.

%% @private
check_crypto(false, Entries) ->
	check_crypto(jose_jwa_unsupported, Entries);
check_crypto(true, Entries) ->
	check_crypto(jose_jwa_aes, Entries);
check_crypto(Fallback, Entries) ->
	Ciphers = [
		aes_cbc,
		aes_ecb,
		aes_gcm
	],
	KeySizes = [
		128,
		192,
		256
	],
	CipherEntries0 = [begin
		case has_cipher(Cipher, KeySize) of
			false ->
				{{cipher, {Cipher, KeySize}}, {Fallback, {Cipher, KeySize}}};
			{true, CryptoCipher} ->
				{{cipher, {Cipher, KeySize}}, {crypto, CryptoCipher}}
		end
	end || Cipher <- Ciphers, KeySize <- KeySizes],
	CipherEntries1 =
		case lists:keyfind(chacha20_poly1305_module, 1, Entries) of
			{chacha20_poly1305_module, jose_chacha20_poly1305_unsupported} ->
				CipherEntries0 ++ [{{cipher, {chacha20_poly1305, 256}}, {Fallback, {chacha20_poly1305, 256}}}];
			_ ->
				CipherEntries0 ++ [{{cipher, {chacha20_poly1305, 256}}, {jose_chacha20_poly1305, {chacha20_poly1305, 256}}}]
		end,
	CipherEntries2 =
		case lists:keyfind(xchacha20_poly1305_module, 1, Entries) of
			{xchacha20_poly1305_module, jose_xchacha20_poly1305_unsupported} ->
				CipherEntries1 ++ [{{cipher, {xchacha20_poly1305, 256}}, {Fallback, {xchacha20_poly1305, 256}}}];
			_ ->
				CipherEntries1 ++ [{{cipher, {xchacha20_poly1305, 256}}, {jose_xchacha20_poly1305, {xchacha20_poly1305, 256}}}]
		end,
	[CipherEntries2 | Entries].

%% @private
check_public_key(Fallback, Entries) ->
	RSACrypt = check_rsa_crypt(Fallback),
	RSASign = check_rsa_sign(Fallback),
	[RSACrypt, RSASign | Entries].

%% @private
check_rsa_crypt(false) ->
	check_rsa_crypt(jose_jwa_unsupported);
check_rsa_crypt(true) ->
	check_rsa_crypt(jose_jwa_pkcs1);
check_rsa_crypt(Fallback) ->
	Algorithms = [
		%% Algorithm,    LegacyOptions,                       FutureOptions
		{rsa1_5,       [{rsa_pad, rsa_pkcs1_padding}],      [{rsa_padding, rsa_pkcs1_padding}]},
		{rsa_oaep,     [{rsa_pad, rsa_pkcs1_oaep_padding}], [{rsa_padding, rsa_pkcs1_oaep_padding}]},
		{rsa_oaep_256, notsup,                              [{rsa_padding, rsa_pkcs1_oaep_padding}, {rsa_oaep_md, sha256}]}
	],
	_ = code:ensure_loaded(public_key),
	_ = application:ensure_all_started(public_key),
	Legacy = case erlang:function_exported(public_key, sign, 4) of
		false ->
			legacy;
		true ->
			future
	end,
	CryptEntries = [begin
		case has_rsa_crypt(Algorithm, Legacy, LegacyOptions, FutureOptions) of
			false ->
				{{rsa_crypt, Algorithm}, {Fallback, FutureOptions}};
			{true, Module, Options} ->
				{{rsa_crypt, Algorithm}, {Module, Options}}
		end
	end || {Algorithm, LegacyOptions, FutureOptions} <- Algorithms],
	CryptEntries.

%% @private
check_rsa_sign(false) ->
	check_rsa_sign(jose_jwa_unsupported);
check_rsa_sign(true) ->
	check_rsa_sign(jose_jwa_pkcs1);
check_rsa_sign(Fallback) ->
	Paddings = [
		rsa_pkcs1_padding,
		rsa_pkcs1_pss_padding
	],
	_ = code:ensure_loaded(public_key),
	_ = application:ensure_all_started(public_key),
	Legacy = case erlang:function_exported(public_key, sign, 4) of
		false ->
			legacy;
		true ->
			future
	end,
	SignEntries = [begin
		case has_rsa_sign(Padding, Legacy, sha256) of
			false ->
				{{rsa_sign, Padding}, {Fallback, [{rsa_padding, Padding}]}};
			{true, Module} ->
				{{rsa_sign, Padding}, {Module, undefined}};
			{true, Module, Options} ->
				{{rsa_sign, Padding}, {Module, Options}}
		end
	end || Padding <- Paddings],
	SignEntries.

%% @private
check_xchacha20_poly1305(false, Entries) ->
	check_xchacha20_poly1305(jose_xchacha20_poly1305_unsupported, Entries);
check_xchacha20_poly1305(true, Entries) ->
	check_xchacha20_poly1305(jose_jwa_xchacha20_poly1305, Entries);
check_xchacha20_poly1305(Fallback, Entries) ->
	true = ets:delete_object(?TAB, {xchacha20_poly1305_module, jose_jwa_xchacha20_poly1305}),
	true = ets:delete_object(?TAB, {xchacha20_poly1305_module, jose_xchacha20_poly1305_unsupported}),
	ChaCha20Poly1305Module = case ets:lookup(?TAB, xchacha20_poly1305_module) of
		[{xchacha20_poly1305_module, M}] when is_atom(M) ->
			M;
		[] ->
			case application:get_env(jose, xchacha20_poly1305_module, undefined) of
				undefined ->
					check_xchacha20_poly1305_modules(Fallback, [libsodium, crypto]);
				M when is_atom(M) ->
					check_xchacha20_poly1305_module(M)
			end
	end,
	[{xchacha20_poly1305_module, ChaCha20Poly1305Module} | Entries].

%% @private
check_xchacha20_poly1305_module(crypto) ->
	jose_xchacha20_poly1305_crypto;
check_xchacha20_poly1305_module(libsodium) ->
	jose_xchacha20_poly1305_libsodium;
check_xchacha20_poly1305_module(Module) when is_atom(Module) ->
	Module.

%% @private
check_xchacha20_poly1305_modules(Fallback, [Module | Modules]) ->
	case code:ensure_loaded(Module) of
		{module, Module} ->
			_ = application:ensure_all_started(Module),
			M = check_xchacha20_poly1305_module(Module),
			PT = crypto:strong_rand_bytes(8),
			CEK = crypto:strong_rand_bytes(32),
			IV = crypto:strong_rand_bytes(24),
			AAD = <<>>,
			try M:encrypt(PT, AAD, IV, CEK) of
				{CT, TAG} when is_binary(CT) andalso is_binary(TAG) ->
					try M:decrypt(CT, TAG, AAD, IV, CEK) of
						PT ->
							M;
						_ ->
							check_xchacha20_poly1305_modules(Fallback, Modules)
					catch
						_:_ ->
							check_xchacha20_poly1305_modules(Fallback, Modules)
					end;
				_ ->
					check_xchacha20_poly1305_modules(Fallback, Modules)
			catch
				_:_ ->
					check_xchacha20_poly1305_modules(Fallback, Modules)
			end;
		_ ->
			check_xchacha20_poly1305_modules(Fallback, Modules)
	end;
check_xchacha20_poly1305_modules(Fallback, []) ->
	Fallback.

%% @private
has_cipher(aes_cbc, KeySize) ->
	Key = << 0:KeySize >>,
	IV = << 0:128 >>,
	PlainText = jose_jwa_pkcs7:pad(<<>>),
	case has_block_cipher(aes_cbc, {Key, IV, PlainText}) of
		false ->
			Cipher = list_to_atom("aes_" ++ integer_to_list(KeySize) ++ "_cbc"),
			has_block_cipher(Cipher, {Key, IV, PlainText});
		Other ->
			Other
	end;
has_cipher(aes_ecb, KeySize) ->
	Key = << 0:KeySize >>,
	PlainText = jose_jwa_pkcs7:pad(<<>>),
	case has_block_cipher(aes_ecb, {Key, PlainText}) of
		false ->
			Cipher = list_to_atom("aes_" ++ integer_to_list(KeySize) ++ "_ecb"),
			has_block_cipher(Cipher, {Key, PlainText});
		Other ->
			Other
	end;
has_cipher(aes_gcm, KeySize) ->
	Key = << 0:KeySize >>,
	IV = << 0:96 >>,
	AAD = <<>>,
	PlainText = jose_jwa_pkcs7:pad(<<>>),
	case has_block_cipher(aes_gcm, {Key, IV, AAD, PlainText}) of
		false ->
			Cipher = list_to_atom("aes_" ++ integer_to_list(KeySize) ++ "_gcm"),
			has_block_cipher(Cipher, {Key, IV, AAD, PlainText});
		Other ->
			Other
	end.

%% @private
has_block_cipher(Cipher, {Key, PlainText}) ->
	try jose_crypto_compat:crypto_one_time(Cipher, Key, PlainText, true) of
		CipherText when is_binary(CipherText) ->
			try jose_crypto_compat:crypto_one_time(Cipher, Key, CipherText, false) of
				PlainText ->
					{true, Cipher};
				_ ->
					false
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	catch
		_:_ ->
			false
	end;
has_block_cipher(Cipher, {Key, IV, PlainText}) ->
	try jose_crypto_compat:crypto_one_time(Cipher, Key, IV, PlainText, true) of
		CipherText when is_binary(CipherText) ->
			try jose_crypto_compat:crypto_one_time(Cipher, Key, IV, CipherText, false) of
				PlainText ->
					{true, Cipher};
				_ ->
					false
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	catch
		_:_ ->
			false
	end;
has_block_cipher(Cipher, {Key, IV, AAD, PlainText}) ->
	try jose_crypto_compat:crypto_one_time(Cipher, Key, IV, {AAD, PlainText}, true) of
		{CipherText, CipherTag} when is_binary(CipherText) andalso is_binary(CipherTag) ->
			try jose_crypto_compat:crypto_one_time(Cipher, Key, IV, {AAD, CipherText, CipherTag}, false) of
				PlainText ->
					{true, Cipher};
				_ ->
					false
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	catch
		_:_ ->
			false
	end.

%% @private
has_rsa_crypt(Algorithm, future, _LegacyOptions, FutureOptions) ->
	PlainText = << 0:8 >>,
	PublicKey = rsa_public_key(),
	try public_key:encrypt_public(PlainText, PublicKey, FutureOptions) of
		CipherText when is_binary(CipherText) ->
			PrivateKey = rsa_private_key(),
			try public_key:decrypt_private(CipherText, PrivateKey, FutureOptions) of
				PlainText ->
					try public_key:decrypt_private(rsa_ciphertext(Algorithm), PrivateKey, FutureOptions) of
						<<"ciphertext">> ->
							{true, public_key, FutureOptions};
						_ ->
							false
					catch
						_:_ ->
							false
					end;
				_ ->
					false
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	catch
		_:_ ->
			false
	end;
has_rsa_crypt(_Algorithm, legacy, notsup, _FutureOptions) ->
	false;
has_rsa_crypt(Algorithm, legacy, LegacyOptions, _FutureOptions) ->
	PlainText = << 0:8 >>,
	PublicKey = rsa_public_key(),
	try public_key:encrypt_public(PlainText, PublicKey, LegacyOptions) of
		CipherText when is_binary(CipherText) ->
			PrivateKey = rsa_private_key(),
			try public_key:decrypt_private(CipherText, PrivateKey, LegacyOptions) of
				PlainText ->
					try public_key:decrypt_private(rsa_ciphertext(Algorithm), PrivateKey, LegacyOptions) of
						<<"ciphertext">> ->
							{true, public_key, LegacyOptions};
						_ ->
							false
					catch
						_:_ ->
							false
					end;
				_ ->
					false
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	catch
		_:_ ->
			false
	end.

%% @private
has_rsa_sign(Padding, future, DigestType) ->
	Message = << 0:8 >>,
	PrivateKey = rsa_private_key(),
	Options = [{rsa_padding, Padding}],
	try public_key:sign(Message, DigestType, PrivateKey, Options) of
		Signature when is_binary(Signature) ->
			PublicKey = rsa_public_key(),
			try public_key:verify(Message, DigestType, Signature, PublicKey, Options) of
				true ->
					{true, public_key, Options};
				_ ->
					false
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	catch
		_:_ ->
			false
	end;
has_rsa_sign(rsa_pkcs1_padding, legacy, DigestType) ->
	Message = << 0:8 >>,
	PrivateKey = rsa_private_key(),
	try public_key:sign(Message, DigestType, PrivateKey) of
		Signature when is_binary(Signature) ->
			PublicKey = rsa_public_key(),
			try public_key:verify(Message, DigestType, Signature, PublicKey) of
				true ->
					{true, public_key};
				_ ->
					false
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	catch
		_:_ ->
			false
	end;
has_rsa_sign(_Padding, legacy, _DigestType) ->
	false.

%% @private
read_pem_key(PEM) ->
	public_key:pem_entry_decode(hd(public_key:pem_decode(PEM))).

%% @private
rsa_ciphertext(rsa1_5) ->
	<<
		16#67, 16#3F, 16#BF, 16#D4, 16#93, 16#1E, 16#6C, 16#54,
		16#67, 16#DE, 16#29, 16#3C, 16#71, 16#5F, 16#95, 16#BE,
		16#69, 16#99, 16#D3, 16#6C, 16#E4, 16#81, 16#1E, 16#49,
		16#BE, 16#5D, 16#91, 16#85, 16#E7, 16#1D, 16#04, 16#C5,
		16#38, 16#0A, 16#6F, 16#3F, 16#32, 16#2C, 16#3D, 16#67,
		16#53, 16#B1, 16#EA, 16#D7, 16#2E, 16#ED, 16#6A, 16#7A,
		16#EB, 16#49, 16#79, 16#71, 16#CA, 16#F5, 16#71, 16#67,
		16#FA, 16#8B, 16#B8, 16#A8, 16#30, 16#59, 16#2E, 16#88,
		16#98, 16#19, 16#AE, 16#B2, 16#94, 16#BA, 16#6E, 16#D2,
		16#EF, 16#28, 16#BE, 16#04, 16#4F, 16#90, 16#77, 16#CA,
		16#3D, 16#11, 16#2B, 16#E7, 16#17, 16#D8, 16#89, 16#7F,
		16#EC, 16#7A, 16#2C, 16#70, 16#A5, 16#08, 16#FB, 16#5B
	>>;
rsa_ciphertext(rsa_oaep) ->
	<<
		16#B8, 16#F7, 16#0C, 16#A8, 16#F8, 16#30, 16#2A, 16#E9,
		16#68, 16#8A, 16#DB, 16#3E, 16#5D, 16#AE, 16#84, 16#A7,
		16#16, 16#FA, 16#9D, 16#E2, 16#FC, 16#81, 16#F7, 16#DF,
		16#A8, 16#DB, 16#8F, 16#4F, 16#92, 16#A1, 16#51, 16#9E,
		16#6B, 16#C5, 16#36, 16#CE, 16#93, 16#10, 16#11, 16#D9,
		16#D5, 16#C2, 16#C9, 16#85, 16#14, 16#EF, 16#D5, 16#C3,
		16#AC, 16#63, 16#BE, 16#49, 16#FA, 16#02, 16#1A, 16#FC,
		16#3D, 16#D0, 16#2C, 16#83, 16#C5, 16#76, 16#1D, 16#F5,
		16#FA, 16#A0, 16#D7, 16#42, 16#ED, 16#3F, 16#A4, 16#12,
		16#32, 16#14, 16#93, 16#51, 16#79, 16#2E, 16#40, 16#FB,
		16#14, 16#18, 16#DF, 16#30, 16#62, 16#9F, 16#F3, 16#59,
		16#5D, 16#83, 16#0F, 16#4A, 16#8F, 16#9B, 16#3F, 16#39
	>>;
rsa_ciphertext(rsa_oaep_256) ->
	<<
		16#09, 16#24, 16#EA, 16#EB, 16#D4, 16#EF, 16#00, 16#BE,
		16#8E, 16#02, 16#BE, 16#25, 16#24, 16#24, 16#18, 16#81,
		16#8D, 16#7A, 16#A2, 16#EB, 16#F1, 16#BE, 16#5C, 16#DC,
		16#D0, 16#71, 16#43, 16#09, 16#53, 16#12, 16#44, 16#AD,
		16#8A, 16#CD, 16#F8, 16#45, 16#7F, 16#1F, 16#30, 16#B6,
		16#54, 16#8E, 16#AB, 16#D2, 16#10, 16#14, 16#BC, 16#CE,
		16#7A, 16#99, 16#DC, 16#A6, 16#8D, 16#16, 16#5A, 16#A0,
		16#50, 16#3A, 16#93, 16#0E, 16#53, 16#4A, 16#B5, 16#6B,
		16#51, 16#E8, 16#43, 16#8F, 16#BD, 16#2D, 16#E0, 16#63,
		16#36, 16#24, 16#5B, 16#8D, 16#DD, 16#98, 16#AC, 16#37,
		16#7C, 16#16, 16#DB, 16#03, 16#C8, 16#BD, 16#22, 16#D2,
		16#15, 16#98, 16#91, 16#B7, 16#3C, 16#01, 16#CF, 16#0E
	>>.

%% @private
rsa_public_key() ->
	read_pem_key(<<
		"-----BEGIN PUBLIC KEY-----\n"
		"MHwwDQYJKoZIhvcNAQEBBQADawAwaAJhAL/f1xISwDSm4m6sYHm6WD4WK2egfyfZ\n"
		"hd0w4iVeZvHjUurZVRVQojs7hZC7DKBfjShl6M7BT9j7gkaYOXlJHLhK6/J+Zr0C\n"
		"g6PMkkbejQltgr4fUzbG8zUBo7BMs4Xm0wIDAQAB\n"
		"-----END PUBLIC KEY-----\n"
	>>).

%% @private
rsa_private_key() ->
	read_pem_key(<<
		"-----BEGIN RSA PRIVATE KEY-----\n"
		"MIIBzAIBAAJhAL/f1xISwDSm4m6sYHm6WD4WK2egfyfZhd0w4iVeZvHjUurZVRVQ\n"
		"ojs7hZC7DKBfjShl6M7BT9j7gkaYOXlJHLhK6/J+Zr0Cg6PMkkbejQltgr4fUzbG\n"
		"8zUBo7BMs4Xm0wIDAQABAmEAiisNO7WG9SNLoPi+TEn061iZjvjTOAX60Io3/0LY\n"
		"jMzu07EHBN9Yw6CcENmxQPcsdIRlSKLlt+UeUdBES6Zoccek5fJl+gnqExeX2Av1\n"
		"v0Y8vIP2yejV7Pw+SrNxpY5ZAjEA+WMEZEgFrK8cPJmZLR9Kj3jvN5P+AmIKzg00\n"
		"VMW93rS+sdHmYQUStqBuu2XRw5SlAjEAxPZlLCZ83GrqdStcmChCFpflzCRyU/wC\n"
		"qVVP8QYfct49Cca3TyC8lCywwXI5s5wXAjA1JQK0lByRdiegSmM4GGj9NhpUT7db\n"
		"rqT60BmMzy7tHLtejYp4tmoMfRfb25DeCvkCMQCO+usQ9NOZUsfmzNaH4lmvew8n\n"
		"daHFE+F+uV6x8ibsRSZ8LVQuze33hsW9eEUo/HsCMQDKkImE3DSqHgwfKPjtecFH\n"
		"oftdsGQ4u+MUGkST94Hh8479oNYaNveCRDOTJ4GJjUE=\n"
		"-----END RSA PRIVATE KEY-----\n"
	>>).
