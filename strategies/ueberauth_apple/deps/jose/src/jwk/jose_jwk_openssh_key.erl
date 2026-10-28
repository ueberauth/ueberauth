%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc Private key format for OpenSSH
%%% See https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key
%%% @end
%%% Created :  16 Jan 2016 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwk_openssh_key).

%% API
-export([from_binary/1]).
-export([to_binary/1]).

%% Macros
-define(AUTH_MAGIC, "openssh-key-v1").
-define(OPENSSH_HEAD, "-----BEGIN OPENSSH PRIVATE KEY-----").
-define(OPENSSH_TAIL, "-----END OPENSSH PRIVATE KEY-----").

%%====================================================================
%% API
%%====================================================================

from_binary(Binary) when is_binary(Binary) ->
	parse_keys(Binary, []).

to_binary(List) when is_list(List) ->
	to_binary(List, []).

%%%-------------------------------------------------------------------
%%% Internal encode functions
%%%-------------------------------------------------------------------

to_binary([KeyList | List], Acc) when is_list(KeyList) ->
	to_binary(List, [write_keylist(lists:unzip(KeyList)) | Acc]);
to_binary([], Acc) ->
	iolist_to_binary([[?OPENSSH_HEAD, $\n, chunk(jose_base64:encode(Keys), 70, []), ?OPENSSH_TAIL, $\n] || Keys <- lists:reverse(Acc)]).

chunk(Bin, Size, Chunks) when byte_size(Bin) > Size ->
	<< Chunk:Size/binary, Rest/binary >> = Bin,
	chunk(Rest, Size, [[Chunk, $\n] | Chunks]);
chunk(Bin, _Size, Chunks) ->
	lists:reverse([[Bin, $\n] | Chunks]).

write_keylist({PKs, SKs}) when length(PKs) =:= length(SKs) ->
	N = length(PKs),
	PKBin = write_publickeys(PKs, []),
	SKBin = write_secretkeys(SKs, []),
	Check = crypto:strong_rand_bytes(4),
	Unpadded = << Check:4/binary, Check:4/binary, SKBin/binary >>,
	Padded = add_padding(Unpadded, 0),
	CipherName = <<"none">>,
	CipherNameLen = byte_size(CipherName),
	KDFName = <<"none">>,
	KDFNameLen = byte_size(KDFName),
	KDFOptions = <<>>,
	KDFOptionsLen = byte_size(KDFOptions),
	PaddedLen = byte_size(Padded),
	<<
		?AUTH_MAGIC, 16#00,
		CipherNameLen:32/unsigned-big-integer-unit:1, CipherName:CipherNameLen/binary,
		KDFNameLen:32/unsigned-big-integer-unit:1, KDFName:KDFNameLen/binary,
		KDFOptionsLen:32/unsigned-big-integer-unit:1, KDFOptions:KDFOptionsLen/binary,
		N:32/unsigned-big-integer-unit:1,
		PKBin/binary,
		PaddedLen:32/unsigned-big-integer-unit:1, Padded:PaddedLen/binary
	>>.

write_publickeys([PK | PKs], Acc) when is_binary(PK) ->
	PKSize = byte_size(PK),
	write_publickeys(PKs, [<< PKSize:32/unsigned-big-integer-unit:1, PK:PKSize/binary >> | Acc]);
write_publickeys([{Type, Key} | PKs], Acc) ->
	TypeLen = byte_size(Type),
	KeyLen = byte_size(Key),
	PK = <<
		TypeLen:32/unsigned-big-integer-unit:1, Type:TypeLen/binary,
		KeyLen:32/unsigned-big-integer-unit:1, Key:KeyLen/binary
	>>,
	write_publickeys([PK | PKs], Acc);
write_publickeys([], Acc) ->
	iolist_to_binary(lists:reverse(Acc)).

write_secretkeys([{Type, PK, SK, Comment} | SKs], Acc) ->
	TypeLen = byte_size(Type),
	PKLen = byte_size(PK),
	SKLen = byte_size(SK),
	CommentLen = byte_size(Comment),
	SecretKey = <<
		TypeLen:32/unsigned-big-integer-unit:1, Type:TypeLen/binary,
		PKLen:32/unsigned-big-integer-unit:1, PK:PKLen/binary,
		SKLen:32/unsigned-big-integer-unit:1, SK:SKLen/binary,
		CommentLen:32/unsigned-big-integer-unit:1, Comment:CommentLen/binary
	>>,
	write_secretkeys(SKs, [SecretKey | Acc]);
write_secretkeys([], Acc) ->
	iolist_to_binary(lists:reverse(Acc)).

add_padding(U, P) when (byte_size(U) + P) rem 8 =/= 0 ->
	add_padding(U, P + 1);
add_padding(U, P) ->
	<< U/binary, (binary:list_to_bin(lists:seq(1, P)))/binary >>.

%%%-------------------------------------------------------------------
%%% Internal decode functions
%%%-------------------------------------------------------------------

%% @private
parse_keys(<< ?OPENSSH_HEAD, SoFar/binary >>, Acc) ->
	case parse_key(SoFar, <<>>) of
		{Key, Rest} ->
			parse_keys(Rest, [Key | Acc]);
		Rest ->
			parse_keys(Rest, Acc)
	end;
parse_keys(<< _, Rest/binary >>, Acc) ->
	parse_keys(Rest, Acc);
parse_keys(<<>>, Acc) ->
	lists:reverse(Acc).

%% @private
parse_key(<< W, Rest/binary >>, Body)
		when W =:= $\r
		orelse W =:= $\n
		orelse W =:= $\s
		orelse W =:= $\t ->
	parse_key(Rest, Body);
parse_key(<< ?OPENSSH_TAIL, Rest/binary >>, Body) ->
	case parse_key(jose_base64:'decode!'(Body)) of
		{true, Key} ->
			{Key, Rest};
		false ->
			Rest
	end;
parse_key(<< C, Rest/binary >>, Body) ->
	parse_key(Rest, << Body/binary, C >>);
parse_key(<<>>, _Body) ->
	<<>>.

%% @private
parse_key(<<
			?AUTH_MAGIC, 16#00,
			CipherNameLen:32/unsigned-big-integer-unit:1, CipherName:CipherNameLen/binary,
			KDFNameLen:32/unsigned-big-integer-unit:1, KDFName:KDFNameLen/binary,
			KDFOptionsLen:32/unsigned-big-integer-unit:1, KDFOptions:KDFOptionsLen/binary,
			N:32/unsigned-big-integer-unit:1,
			SoFar/binary
		>>) ->
	case parse_publickeys(SoFar, N, []) of
		{true, PKs, << EncryptedLen:32/unsigned-big-integer-unit:1, Encrypted:EncryptedLen/binary >>} ->
			Header = {CipherName, KDFName, KDFOptions, N},
			case maybe_parse_secretkeys(Header, PKs, Encrypted) of
				{true, Key} ->
					{true, Key};
				false ->
					{true, {Header, PKs, Encrypted}}
			end;
		{true, _PKs, _BadEncrypted} ->
			false;
		false ->
			false
	end;
parse_key(<< _, Rest/binary >>) ->
	parse_key(Rest);
parse_key(<<>>) ->
	false.

%% @private
parse_publickeys(Rest, 0, PKs) ->
	{true, lists:reverse(PKs), Rest};
parse_publickeys(<<
			PKLen:32/unsigned-big-integer-unit:1, PK:PKLen/binary,
			Rest/binary
		>>, N, PKs) ->
	case parse_publickey(PK) of
		{true, Type, Key} ->
			parse_publickeys(Rest, N - 1, [{Type, Key} | PKs]);
		false ->
			parse_publickeys(Rest, N - 1, [PK | PKs])
	end;
parse_publickeys(_Binary, _N, _PKs) ->
	false.

%% @private
parse_publickey(<<
			TypeLen:32/unsigned-big-integer-unit:1, Type:TypeLen/binary,
			KeyLen:32/unsigned-big-integer-unit:1, Key:KeyLen/binary
		>>) ->
	{true, Type, Key};
parse_publickey(_Binary) ->
	false.

%% @private
maybe_parse_secretkeys({<<"none">>, <<"none">>, <<>>, N}, PKs, <<
			Check:4/binary,
			Check:4/binary,
			SoFar/binary
		>>) ->
	case parse_secretkeys(del_padding(SoFar), N, []) of
		{true, SKs} ->
			{true, lists:zip(PKs, SKs)};
		false ->
			false
	end;
maybe_parse_secretkeys(_Header, _PKs, _Binary) ->
	false.

%% @private
parse_secretkeys(<<>>, 0, SKs) ->
	{true, lists:reverse(SKs)};
parse_secretkeys(<<
			TypeLen:32/unsigned-big-integer-unit:1, Type:TypeLen/binary,
			PKLen:32/unsigned-big-integer-unit:1, PK:PKLen/binary,
			SKLen:32/unsigned-big-integer-unit:1, SK:SKLen/binary,
			CommentLen:32/unsigned-big-integer-unit:1, Comment:CommentLen/binary,
			Rest/binary
		>>, N, SKs) ->
	parse_secretkeys(Rest, N - 1, [{Type, PK, SK, Comment} | SKs]);
parse_secretkeys(_Binary, _N, _SKs) ->
	false.

%% @private
del_padding(<<>>) ->
	<<>>;
del_padding(Padded) when is_binary(Padded) ->
	Padding = binary:last(Padded),
	case Padding > byte_size(Padded) of
		true ->
			<<>>;
		false ->
			del_padding(Padded, Padding)
	end.

%% @private
del_padding(Padded, 0) ->
	Padded;
del_padding(Padded, Padding) ->
	case binary:last(Padded) of
		Padding ->
			del_padding(binary:part(Padded, 0, byte_size(Padded) - 1), Padding - 1);
		_ ->
			<<>>
	end.
