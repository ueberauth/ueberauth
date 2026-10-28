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
-module(jose_jwe_zip).
-behaviour(jose_jwe).

-callback compress(Uncompressed, ZIP) -> Compressed
	when
		Uncompressed :: iodata(),
		ZIP          :: any(),
		Compressed   :: iodata().
-callback uncompress(Compressed, ZIP) -> Uncompressed
	when
		Compressed   :: iodata(),
		ZIP          :: any(),
		Uncompressed :: iodata().

%% jose_jwe callbacks
-export([from_map/1]).
-export([to_map/2]).
%% jose_jwe_zip callbacks
-export([compress/2]).
-export([uncompress/2]).
%% API
-export([format_error/2]).
-export([zip_supported/0]).

%% Types
-type zip() :: zlib.

-export_type([zip/0]).

-define(DEF, zlib).

%%====================================================================
%% jose_jwe callbacks
%%====================================================================

from_map(Fields = #{ <<"zip">> := <<"DEF">> }) ->
	{?DEF, maps:remove(<<"zip">>, Fields)}.

to_map(?DEF, Fields) ->
	Fields#{ <<"zip">> => <<"DEF">> }.

%%====================================================================
%% jose_jwe_zip callbacks
%%====================================================================

compress(Uncompressed, zlib) ->
	Z = zlib:open(),
	ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
	Compressed = zlib:deflate(Z, Uncompressed, finish),
	ok = zlib:deflateEnd(Z),
	ok = zlib:close(Z),
	iolist_to_binary(Compressed).

uncompress(Compressed, zlib) ->
	ZipSizeMaximum = jose:zip_size_maximum(),
	Z = zlib:open(),
	try
		ok = zlib:inflateInit(Z, -15),
		Uncompressed = safe_inflate(Z, Compressed, ZipSizeMaximum),
		ok = zlib:inflateEnd(Z),
		Uncompressed
	after
		ok = zlib:close(Z)
	end.

%%====================================================================
%% API functions
%%====================================================================

-spec format_error(term(), term()) -> term().
format_error(_Reason, [{_M, _F, _As, Info} | _]) ->
	ErrorInfo = proplists:get_value(error_info, Info, #{}),
	ErrorDescription1 = maps:get(cause, ErrorInfo),
	ErrorDescription1.

zip_supported() ->
	[zlib].

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
%% Incrementally inflate so that a decompression bomb is rejected before the
%% whole payload has been materialized, rather than after.
safe_inflate(Z, Compressed, ZipSizeMaximum) ->
	safe_inflate(zlib:safeInflate(Z, Compressed), Z, ZipSizeMaximum, 0, []).

%% @private
safe_inflate({continue, Output}, Z, ZipSizeMaximum, Size0, Acc) ->
	Size1 = Size0 + erlang:iolist_size(Output),
	ok = safe_inflate_check(Size1, ZipSizeMaximum),
	safe_inflate(zlib:safeInflate(Z, []), Z, ZipSizeMaximum, Size1, [Output | Acc]);
safe_inflate({finished, Output}, _Z, ZipSizeMaximum, Size0, Acc) ->
	Size1 = Size0 + erlang:iolist_size(Output),
	ok = safe_inflate_check(Size1, ZipSizeMaximum),
	erlang:iolist_to_binary(lists:reverse([Output | Acc])).

%% @private
safe_inflate_check(Size, ZipSizeMaximum) when Size =< ZipSizeMaximum ->
	ok;
safe_inflate_check(Size, ZipSizeMaximum) ->
	erlang:error(badarg, [<<"REDACTED">>, zlib], [
		{error_info, #{
			module => ?MODULE,
			cause => #{1 => lists:flatten(io_lib:format("maximum uncompressed size is set to ~w bytes, but at least ~w bytes was attempted (see jose:zip_size_maximum/0)", [ZipSizeMaximum, Size]))}
		}}
	]).
