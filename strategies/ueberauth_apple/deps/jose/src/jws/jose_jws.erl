%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc JSON Web Signature (JWS)
%%% See RFC 7515: https://tools.ietf.org/html/rfc7515
%%% See RFC 7797: https://tools.ietf.org/html/rfc7797
%%% @end
%%% Created :  21 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jws).

-include("jose_jwk.hrl").
-include("jose_jws.hrl").

-callback from_map(Fields) -> State
	when
		Fields :: map(),
		State  :: any().
-callback to_map(State, Fields) -> Map
	when
		State  :: any(),
		Fields :: map(),
		Map    :: map().

%% Decode API
-export([from/1]).
-export([from_binary/1]).
-export([from_file/1]).
-export([from_map/1]).
%% Encode API
-export([to_binary/1]).
-export([to_file/2]).
-export([to_map/1]).
%% API
-export([compact/1]).
-export([expand/1]).
-export([generate_key/1]).
-export([merge/2]).
-export([peek/1]).
-export([peek_payload/1]).
-export([peek_protected/1]).
-export([peek_signature/1]).
-export([sign/3]).
-export([sign/4]).
-export([signing_input/2]).
-export([signing_input/3]).
-export([verify/2]).
-export([verify_strict/3]).

-define(ALG_ECDSA_MODULE,          jose_jws_alg_ecdsa).
-define(ALG_EDDSA_MODULE,          jose_jws_alg_eddsa).
-define(ALG_HMAC_MODULE,           jose_jws_alg_hmac).
-define(ALG_NONE_MODULE,           jose_jws_alg_none).
-define(ALG_POLY1305_MODULE,       jose_jws_alg_poly1305).
-define(ALG_RSA_PKCS1_V1_5_MODULE, jose_jws_alg_rsa_pkcs1_v1_5).
-define(ALG_RSA_PSS_MODULE,        jose_jws_alg_rsa_pss).

%%====================================================================
%% Decode API functions
%%====================================================================

from(List) when is_list(List) ->
	[from(Element) || Element <- List];
from({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({Modules, Map});
from({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	from_binary({Modules, Binary});
from(JWS=#jose_jws{}) ->
	JWS;
from(Other) when is_map(Other) orelse is_binary(Other) ->
	from({#{}, Other}).

from_binary(List) when is_list(List) ->
	[from_binary(Element) || Element <- List];
from_binary({Modules, Binary}) when is_map(Modules) andalso is_binary(Binary) ->
	from_map({Modules, jose:decode(Binary)});
from_binary(Binary) when is_binary(Binary) ->
	from_binary({#{}, Binary}).

from_file({Modules, File}) when is_map(Modules) andalso (is_binary(File) orelse is_list(File)) ->
	case file:read_file(File) of
		{ok, Binary} ->
			from_binary({Modules, Binary});
		ReadError ->
			ReadError
	end;
from_file(File) when is_binary(File) orelse is_list(File) ->
	from_file({#{}, File}).

from_map(List) when is_list(List) ->
	[from_map(Element) || Element <- List];
from_map(Map) when is_map(Map) ->
	from_map({#{}, Map});
from_map({Modules, Map}) when is_map(Modules) andalso is_map(Map) ->
	from_map({#jose_jws{}, Modules, Map});
from_map({JWS, Modules = #{ alg := Module }, Map=#{ <<"alg">> := _ }}) ->
	{ALG, Fields} = Module:from_map(Map),
	from_map({JWS#jose_jws{ alg = {Module, ALG} }, maps:remove(alg, Modules), Fields});
from_map({JWS, Modules, Map=#{ <<"b64">> := B64 }}) ->
	from_map({JWS#jose_jws{ b64 = B64 }, Modules, maps:remove(<<"b64">>, Map)});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "Ed25519", _/binary >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_EDDSA_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "Ed448", _/binary >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_EDDSA_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "EdDSA", _/binary >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_EDDSA_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "ES", _/binary >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_ECDSA_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "HS", _/binary >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_HMAC_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "Poly1305" >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_POLY1305_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "PS", _/binary >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_RSA_PSS_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "RS", _/binary >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_RSA_PKCS1_V1_5_MODULE }, Map});
from_map({JWS, Modules, Map=#{ <<"alg">> := << "none" >> }}) ->
	from_map({JWS, Modules#{ alg => ?ALG_NONE_MODULE }, Map});
from_map({#jose_jws{ alg = undefined }, _Modules, _Map}) ->
	{error, {missing_required_keys, [<<"alg">>]}};
from_map({JWS, _Modules, Fields}) ->
	JWS#jose_jws{ fields = Fields }.

%%====================================================================
%% Encode API functions
%%====================================================================

to_binary(List) when is_list(List) ->
	[to_binary(Element) || Element <- List];
to_binary(JWS=#jose_jws{}) ->
	{Modules, Map} = to_map(JWS),
	{Modules, jose:encode(Map)};
to_binary(Other) ->
	to_binary(from(Other)).

to_file(File, JWS=#jose_jws{}) when is_binary(File) orelse is_list(File) ->
	{Modules, Binary} = to_binary(JWS),
	case file:write_file(File, Binary) of
		ok ->
			{Modules, File};
		WriteError ->
			WriteError
	end;
to_file(File, Other) when is_binary(File) orelse is_list(File) ->
	to_file(File, from(Other)).

to_map(List) when is_list(List) ->
	[to_map(Element) || Element <- List];
to_map(JWS=#jose_jws{fields=Fields}) ->
	record_to_map(JWS, #{}, Fields);
to_map(Other) ->
	to_map(from(Other)).

%%====================================================================
%% API functions
%%====================================================================

compact({Modules, #{
			<<"payload">> := Payload,
			<<"signatures">> := Signatures }}) when is_list(Signatures) ->
	{Modules, [do_compact(Map#{ <<"payload">> => Payload }) || Map <- Signatures]};
compact({Modules, Map}) when is_map(Map) ->
	{Modules, do_compact(Map)};
compact({Modules, List}) when is_list(List) ->
	{Modules, [do_compact(Map) || Map <- List]};
compact(Map) when is_map(Map) ->
	compact({#{}, Map});
compact(List) when is_list(List) ->
	compact({#{}, List});
compact(BadArg) ->
	erlang:error({badarg, [BadArg]}).

expand({Modules, Binary}) when is_binary(Binary) ->
	{Modules, do_expand(Binary)};
expand({Modules, List}) when is_list(List) ->
	Expanded = [do_expand(Binary) || Binary <- List],
	Eligible = lists:foldl(fun
		(_, false) ->
			false;
		(#{ <<"payload">> := Payload }, undefined) when is_binary(Payload) ->
			Payload;
		(#{ <<"payload">> := Payload }, Payload) when is_binary(Payload) ->
			Payload;
		(_, _) ->
			false
	end, undefined, Expanded),
	case Eligible of
		_ when Eligible =:= false orelse Eligible =:= undefined ->
			{Modules, Expanded};
		Payload ->
			Signatures = [maps:remove(<<"payload">>, Map) || Map <- Expanded],
			{Modules, #{
				<<"payload">> => Payload,
				<<"signatures">> => Signatures
			}}
	end;
expand(Binary) when is_binary(Binary) ->
	expand({#{}, Binary});
expand(List) when is_list(List) ->
	expand({#{}, List}).

generate_key(List) when is_list(List) ->
	[generate_key(Element) || Element <- List];
generate_key(#jose_jws{alg={Module, ALG}, fields=Fields}) ->
	Module:generate_key(ALG, Fields);
generate_key(Other) ->
	generate_key(from(Other)).

merge(LeftJWS=#jose_jws{}, RightMap) when is_map(RightMap) ->
	{Modules, LeftMap} = to_map(LeftJWS),
	from_map({Modules, maps:merge(LeftMap, RightMap)});
merge(LeftOther, RightJWS=#jose_jws{}) ->
	merge(LeftOther, element(2, to_map(RightJWS)));
merge(LeftOther, RightMap) when is_map(RightMap) ->
	merge(from(LeftOther), RightMap).

peek(Signed) ->
	peek_payload(Signed).

peek_payload({_Modules, Signed}) when is_binary(Signed) or is_map(Signed) ->
	peek_payload(Signed);
peek_payload(SignedBinary) when is_binary(SignedBinary) ->
	peek_payload(expand(SignedBinary));
peek_payload(#{ <<"payload">> := Payload }) ->
	jose_jwa_base64url:decode(Payload).

peek_protected({_Modules, Signed}) when is_binary(Signed) or is_map(Signed) ->
	peek_protected(Signed);
peek_protected(SignedBinary) when is_binary(SignedBinary) ->
	peek_protected(expand(SignedBinary));
peek_protected(#{ <<"protected">> := Protected }) ->
	jose_jwa_base64url:decode(Protected).

peek_signature({_Modules, Signed}) when is_binary(Signed) or is_map(Signed) ->
	peek_signature(Signed);
peek_signature(SignedBinary) when is_binary(SignedBinary) ->
	peek_signature(expand(SignedBinary));
peek_signature(#{ <<"signature">> := Signature }) ->
	jose_jwa_base64url:decode(Signature).

sign(KeyList, PlainText, SignerList)
		when is_list(KeyList)
		andalso is_list(SignerList)
		andalso length(KeyList) =:= length(SignerList) ->
	HeaderList = [#{} || _ <- SignerList],
	sign(KeyList, PlainText, HeaderList, SignerList);
sign(KeyList, PlainText, SignerList)
		when is_list(KeyList)
		andalso is_list(SignerList)
		andalso length(KeyList) =/= length(SignerList) ->
	erlang:error({badarg, [KeyList, PlainText, SignerList]});
sign(KeyOrKeyList, PlainText, JWS=#jose_jws{}) ->
	sign(KeyOrKeyList, PlainText, #{}, JWS);
sign(KeyOrKeyList, PlainText, Other) ->
	sign(KeyOrKeyList, PlainText, from(Other)).

sign(KeyList, PlainText, Header, Signer=#jose_jws{})
		when is_list(KeyList)
		andalso is_binary(PlainText)
		andalso is_map(Header) ->
	HeaderList = [Header || _ <- KeyList],
	SignerList = [Signer || _ <- KeyList],
	sign(KeyList, PlainText, HeaderList, SignerList);
sign(KeyList, PlainText, Header, SignerList)
		when is_list(KeyList)
		andalso is_binary(PlainText)
		andalso is_map(Header)
		andalso is_list(SignerList)
		andalso length(KeyList) =:= length(SignerList) ->
	HeaderList = [Header || _ <- KeyList],
	sign(KeyList, PlainText, HeaderList, SignerList);
sign(KeyList, PlainText, HeaderList, Signer=#jose_jws{})
		when is_list(KeyList)
		andalso is_binary(PlainText)
		andalso is_list(HeaderList)
		andalso length(KeyList) =:= length(HeaderList) ->
	SignerList = [Signer || _ <- KeyList],
	sign(KeyList, PlainText, HeaderList, SignerList);
sign(KeyList, PlainText, HeaderList, SignerList)
		when is_list(KeyList)
		andalso is_binary(PlainText)
		andalso is_list(HeaderList)
		andalso is_list(SignerList)
		andalso length(KeyList) =:= length(SignerList)
		andalso length(KeyList) =:= length(HeaderList) ->
	Keys = jose_jwk:from(KeyList),
	Signers = from(SignerList),
	Payload = jose_jwa_base64url:encode(PlainText),
	Signatures = map_signatures(Keys, PlainText, HeaderList, Signers, []),
	{#{}, #{
		<<"payload">> => Payload,
		<<"signatures">> => Signatures
	}};
sign(Key=#jose_jwk{}, PlainText, Header, JWS=#jose_jws{alg={ALGModule, ALG}})
		when is_binary(PlainText)
		andalso is_map(Header) ->
	_ = code:ensure_loaded(ALGModule),
	NewALG = case erlang:function_exported(ALGModule, presign, 2) of
		false ->
			ALG;
		true ->
			ALGModule:presign(Key, ALG)
	end,
	NewJWS = JWS#jose_jws{alg={ALGModule, NewALG}},
	{Modules, ProtectedBinary} = to_binary(NewJWS),
	Protected = jose_jwa_base64url:encode(ProtectedBinary),
	Payload = jose_jwa_base64url:encode(PlainText),
	SigningInput = signing_input(PlainText, Protected, NewJWS),
	Signature = jose_jwa_base64url:encode(ALGModule:sign(Key, SigningInput, NewALG)),
	{Modules, maps:put(<<"payload">>, Payload, signature_to_map(Protected, Header, Key, Signature))};
sign(Key=none, PlainText, Header, JWS=#jose_jws{alg={ALGModule, ALG}})
		when is_binary(PlainText)
		andalso is_map(Header) ->
	_ = code:ensure_loaded(ALGModule),
	NewALG = case erlang:function_exported(ALGModule, presign, 2) of
		false ->
			ALG;
		true ->
			ALGModule:presign(Key, ALG)
	end,
	NewJWS = JWS#jose_jws{alg={ALGModule, NewALG}},
	{Modules, ProtectedBinary} = to_binary(NewJWS),
	Protected = jose_jwa_base64url:encode(ProtectedBinary),
	Payload = jose_jwa_base64url:encode(PlainText),
	SigningInput = signing_input(PlainText, Protected, NewJWS),
	Signature = jose_jwa_base64url:encode(ALGModule:sign(Key, SigningInput, NewALG)),
	{Modules, maps:put(<<"payload">>, Payload, signature_to_map(Protected, Header, Key, Signature))};
sign(KeyList, PlainText, HeaderList, SignerList)
		when (is_list(KeyList)
			andalso is_list(HeaderList)
			andalso length(KeyList) =/= length(HeaderList))
		orelse (is_list(KeyList)
			andalso is_list(SignerList)
			andalso length(KeyList) =/= length(SignerList))
		orelse (is_list(HeaderList)
			andalso is_list(SignerList)
			andalso length(HeaderList) =/= length(SignerList))
		orelse (is_list(HeaderList)
			andalso not is_list(KeyList)
			andalso not is_list(SignerList)) ->
	erlang:error({badarg, [KeyList, PlainText, HeaderList, SignerList]});
sign(KeyOrKeyList, PlainText, Header, Other)
		when is_binary(PlainText)
		andalso is_map(Header) ->
	sign(jose_jwk:from(KeyOrKeyList), PlainText, Header, from(Other)).

%% See https://tools.ietf.org/html/rfc7797
signing_input(Payload, JWS=#jose_jws{}) ->
	{_, ProtectedBinary} = to_binary(JWS),
	Protected = jose_jwa_base64url:encode(ProtectedBinary),
	signing_input(Payload, Protected, JWS);
signing_input(Payload, Other) ->
	signing_input(Payload, from(Other)).

signing_input(PlainText, Protected, #jose_jws{b64=B64})
		when (B64 =:= true
			orelse B64 =:= undefined) ->
	Payload = jose_jwa_base64url:encode(PlainText),
	<< Protected/binary, $., Payload/binary >>;
signing_input(Payload, Protected, #jose_jws{b64=false}) ->
	<< Protected/binary, $., Payload/binary >>.

verify(Key, SignedMap) when is_map(SignedMap) ->
	verify(Key, {#{}, SignedMap});
verify(Key, SignedBinary) when is_binary(SignedBinary) ->
	verify(Key, expand(SignedBinary));
verify(Key, {Modules, SignedBinary}) when is_binary(SignedBinary) ->
	verify(Key, expand({Modules, SignedBinary}));
verify(Key, {Modules, #{
		<<"payload">> := Payload,
		<<"protected">> := Protected,
		<<"signature">> := EncodedSignature}}) ->
	JWS = #jose_jws{alg={ALGModule, ALG}} = from_binary({Modules, jose_jwa_base64url:decode(Protected)}),
	Signature = jose_jwa_base64url:decode(EncodedSignature),
	PlainText = jose_jwa_base64url:decode(Payload),
	SigningInput = signing_input(PlainText, Protected, JWS),
	{ALGModule:verify(Key, SigningInput, Signature, ALG), PlainText, JWS};
verify(Keys = [_ | _], {Modules, Signed=#{
		<<"payload">> := _Payload,
		<<"signatures">> := EncodedSignatures}})
		when is_list(EncodedSignatures) ->
	[begin
		{Key, verify(Key, {Modules, Signed})}
	end || Key <- Keys];
verify(Key, {Modules, #{
		<<"payload">> := Payload,
		<<"signatures">> := EncodedSignatures}})
		when is_list(EncodedSignatures) ->
	[begin
		verify(Key, {Modules, maps:put(<<"payload">>, Payload, EncodedSignature)})
	end || EncodedSignature <- EncodedSignatures].

verify_strict(Key, Allow, SignedMap) when is_map(SignedMap) ->
	verify_strict(Key, Allow, {#{}, SignedMap});
verify_strict(Key, Allow, SignedBinary) when is_binary(SignedBinary) ->
	verify_strict(Key, Allow, expand(SignedBinary));
verify_strict(Key, Allow, {Modules, SignedBinary}) when is_binary(SignedBinary) ->
	verify_strict(Key, Allow, expand({Modules, SignedBinary}));
verify_strict(Key, Allow, {Modules, #{
		<<"payload">> := Payload,
		<<"protected">> := Protected,
		<<"signature">> := EncodedSignature}}) ->
	ProtectedMap = jose:decode(jose_jwa_base64url:decode(Protected)),
	Signature = jose_jwa_base64url:decode(EncodedSignature),
	PlainText = jose_jwa_base64url:decode(Payload),
	case ProtectedMap of
		#{ <<"alg">> := Algorithm } ->
			case lists:member(Algorithm, Allow) of
				false ->
					{false, PlainText, ProtectedMap};
				true ->
					JWS = #jose_jws{alg={ALGModule, ALG}} = from_map({Modules, ProtectedMap}),
					SigningInput = signing_input(PlainText, Protected, JWS),
					{ALGModule:verify(Key, SigningInput, Signature, ALG), PlainText, JWS}
			end;
		_ ->
			{false, PlainText, ProtectedMap}
	end;
verify_strict(Keys = [_ | _], Allow, {Modules, Signed=#{
		<<"payload">> := _Payload,
		<<"signatures">> := EncodedSignatures}})
		when is_list(EncodedSignatures) ->
	[begin
		{Key, verify_strict(Key, Allow, {Modules, Signed})}
	end || Key <- Keys];
verify_strict(Key, Allow, {Modules, #{
		<<"payload">> := Payload,
		<<"signatures">> := EncodedSignatures}})
		when is_list(EncodedSignatures) ->
	[begin
		verify_strict(Key, Allow, {Modules, maps:put(<<"payload">>, Payload, EncodedSignature)})
	end || EncodedSignature <- EncodedSignatures].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
do_compact(#{
		<<"payload">> := Payload,
		<<"protected">> := Protected,
		<<"signature">> := Signature}) ->
	<<
		Protected/binary, $.,
		Payload/binary, $.,
		Signature/binary
	>>;
do_compact(BadArg) ->
	erlang:error({badarg, [BadArg]}).

%% @private
do_expand(Binary) when is_binary(Binary) ->
	case binary:split(Binary, <<".">>, [global]) of
		[Protected, Payload, Signature] ->
			#{
				<<"payload">> => Payload,
				<<"protected">> => Protected,
				<<"signature">> => Signature
			};
		_ ->
			erlang:error({badarg, [Binary]})
	end;
do_expand(BadArg) ->
	erlang:error({badarg, [BadArg]}).

%% @private
map_signatures([Key | Keys], PlainText, [Header | Headers], [Signer=#jose_jws{alg={ALGModule, ALG}} | Signers], Acc) ->
	_ = code:ensure_loaded(ALGModule),
	NewALG = case erlang:function_exported(ALGModule, presign, 2) of
		false ->
			ALG;
		true ->
			ALGModule:presign(Key, ALG)
	end,
	NewSigner = Signer#jose_jws{alg={ALGModule, NewALG}},
	{_Modules, ProtectedBinary} = to_binary(NewSigner),
	Protected = jose_jwa_base64url:encode(ProtectedBinary),
	SigningInput = signing_input(PlainText, Protected, NewSigner),
	Signature = jose_jwa_base64url:encode(ALGModule:sign(Key, SigningInput, NewALG)),
	map_signatures(Keys, PlainText, Headers, Signers, [signature_to_map(Protected, Header, Key, Signature) | Acc]);
map_signatures([], _PlainText, [], [], Acc) ->
	lists:reverse(Acc).

%% @private
record_to_map(JWS=#jose_jws{alg={Module, ALG}}, Modules, Fields0) ->
	Fields1 = Module:to_map(ALG, Fields0),
	record_to_map(JWS#jose_jws{alg=undefined}, Modules#{ alg => Module }, Fields1);
record_to_map(JWS=#jose_jws{b64=B64}, Modules, Fields0) when is_boolean(B64) ->
	Fields1 = Fields0#{ <<"b64">> => B64 },
	record_to_map(JWS#jose_jws{b64=undefined}, Modules, Fields1);
record_to_map(_JWS, Modules, Fields) ->
	{Modules, Fields}.

%% @private
signature_to_map(Protected, Header, #jose_jwk{fields=Fields}, Signature) ->
	signature_to_map(Protected, Header, Fields, Signature);
signature_to_map(Protected, Header, #{ <<"kid">> := KID }, Signature) ->
	#{
		<<"protected">> => Protected,
		<<"header">> => maps:put(<<"kid">>, KID, Header),
		<<"signature">> => Signature
	};
signature_to_map(Protected, Header, _Fields, Signature) ->
	case maps:size(Header) of
		0 ->
			#{
				<<"protected">> => Protected,
				<<"signature">> => Signature
			};
		_ ->
			#{
				<<"protected">> => Protected,
				<<"header">> => Header,
				<<"signature">> => Signature
			}
	end.
