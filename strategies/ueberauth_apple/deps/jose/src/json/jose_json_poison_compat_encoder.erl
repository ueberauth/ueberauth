%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  14 Aug 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_json_poison_compat_encoder).
-behaviour(jose_json).

%% jose_json callbacks
-export([decode/1]).
-export([encode/1]).

%%====================================================================
%% jose_json callbacks
%%====================================================================

decode(Binary) ->
	'Elixir.Poison':'decode!'(Binary).

encode(Term) ->
	'Elixir.IO':'iodata_to_binary'(lexical_encode(Term)).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
lexical_encode(Atom) when is_atom(Atom) ->
	apply('Elixir.Poison.Encoder.Atom', 'encode', [Atom, #{}]);
lexical_encode(BitString) when is_bitstring(BitString) ->
	apply('Elixir.Poison.Encoder.BitString', 'encode', [BitString, #{}]);
lexical_encode(Integer) when is_integer(Integer) ->
	apply('Elixir.Poison.Encoder.Integer', 'encode', [Integer, #{}]);
lexical_encode(Float) when is_float(Float) ->
	apply('Elixir.Poison.Encoder.Float', 'encode', [Float, #{}]);
lexical_encode(Struct = #{ '__struct__' := Type }) ->
	lexical_encode_struct(Type, Struct);
lexical_encode(Map) when is_map(Map) ->
	lexical_encode_map(Map);
lexical_encode(List) when is_list(List) ->
	lexical_encode_list(List);
lexical_encode(Any) ->
	erlang:error('Elixir.Poison.EncodeError':'exception'([{value, Any}])).

%% @private
lexical_encode_name(Binary) when is_binary(Binary) ->
	Binary;
lexical_encode_name(Atom) when is_atom(Atom) ->
	'Elixir.Atom':'to_string'(Atom);
lexical_encode_name(Any) ->
	erlang:error('Elixir.Poison.EncodeError':'exception'([
		{value, Any},
		{message, <<
			"expected string or atom key, got: ",
			('Elixir.Kernel':'inspect'(Any))/binary
		>>}
	])).

%% @private
lexical_encode_map(Map) when map_size(Map) < 1 ->
	<<"{}">>;
lexical_encode_map(Map) when is_map(Map) ->
	Folder = fun (Key, Acc) ->
		[
			$,,
			apply('Elixir.Poison.Encoder.BitString', 'encode', [lexical_encode_name(Key), #{}]),
			$:,
			lexical_encode(maps:get(Key, Map))
			| Acc
		]
	end,
	[
		${,
		tl(lists:foldr(Folder, [], lists:sort(maps:keys(Map)))),
		$}
	].

%% @private
lexical_encode_list([]) ->
	<<"[]">>;
lexical_encode_list(List) when is_list(List) ->
	Folder = fun (Element, Acc) ->
		[
			$,,
			lexical_encode(Element)
			| Acc
		]
	end,
	[
		$[,
		tl(lists:foldr(Folder, [], List)),
		$]
	].

%% @private
lexical_encode_struct(Type, Struct)
		when Type == 'Elixir.Range'
		orelse Type == 'Elixir.Stream'
		orelse Type == 'Elixir.MapSet'
		orelse Type == 'Elixir.HashSet' ->
	FlatMapper = fun (Element) ->
		[
			$,,
			lexical_encode(Element)
		]
	end,
	case 'Elixir.Enum':'flat_map'(Struct, FlatMapper) of
		[] ->
			<<"[]">>;
		[_ | Tail] ->
			[
				$[,
				Tail,
				$]
			]
	end;
lexical_encode_struct('Elixir.HashDict', HashDict) ->
	case 'Elixir.HashDict':'size'(HashDict) < 1 of
		true ->
			<<"{}">>;
		false ->
			FlatMapper = fun ({Key, Value}) ->
				[
					$,,
					apply('Elixir.Poison.Encoder.BitString', 'encode', [lexical_encode_name(Key), #{}]),
					$:,
					lexical_encode(Value)
				]
			end,
			[
				${,
				tl('Elixir.Enum':'flat_map'(HashDict, FlatMapper)),
				$}
			]
	end;
lexical_encode_struct(Type, Struct)
		when Type == 'Elixir.Date'
		orelse Type == 'Elixir.Time'
		orelse Type == 'Elixir.NaiveDateTime'
		orelse Type == 'Elixir.DateTime' ->
	apply('Elixir.Poison.Encoder.BitString', 'encode', [Type:'to_iso8601'(Struct), #{}]);
lexical_encode_struct(Type, Struct) ->
	case find_encoder(Type) of
		{true, Encoder} ->
			apply(Encoder, 'encode', [Struct, #{}]);
		false ->
			lexical_encode_map('Elixir.Map':'from_struct'(Struct))
	end.

%% @private
find_encoder(ElixirType) ->
	case atom_to_binary(ElixirType, unicode) of
		<< "Elixir.", Type/binary >> ->
			try binary_to_existing_atom(<< "Elixir.Poison.Encoder.", Type/binary >>, unicode) of
				EncoderType ->
					case code:ensure_loaded(EncoderType) of
						{module, EncoderType} ->
							{true, EncoderType};
						_ ->
							false
					end
			catch
				_:_ ->
					false
			end;
		_ ->
			false
	end.
