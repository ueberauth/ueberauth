%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014-2022, Andrew Bennett
%%% @doc PKCS-7
%%% See RFC 2315: https://tools.ietf.org/html/rfc2315
%%% @end
%%% Created :  22 Jul 2015 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(jose_jwa_pkcs7).

%% API
-export([pad/1]).
-export([unpad/1]).

%%====================================================================
%% API functions
%%====================================================================

-spec pad(binary()) -> binary().
pad(Bin) ->
	Size = 16 - (byte_size(Bin) rem 16),
	pad(Size, Bin).

-spec unpad(binary()) -> binary().
unpad(Data) ->
	P = binary:last(Data),
	Size = byte_size(Data) - P,
	case Data of
		<< Bin:Size/binary, P >> -> Bin;
		<< Bin:Size/binary, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P, P, P, P, P, P, P >> -> Bin;
		<< Bin:Size/binary, P, P, P, P, P, P, P, P, P, P, P, P, P, P, P, P >> -> Bin;
		_ -> erlang:error({badarg, Data})
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
pad(P= 1, Bin) -> << Bin/binary, P >>;
pad(P= 2, Bin) -> << Bin/binary, P, P >>;
pad(P= 3, Bin) -> << Bin/binary, P, P, P >>;
pad(P= 4, Bin) -> << Bin/binary, P, P, P, P >>;
pad(P= 5, Bin) -> << Bin/binary, P, P, P, P, P >>;
pad(P= 6, Bin) -> << Bin/binary, P, P, P, P, P, P >>;
pad(P= 7, Bin) -> << Bin/binary, P, P, P, P, P, P, P >>;
pad(P= 8, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P >>;
pad(P= 9, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P >>;
pad(P=10, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P, P >>;
pad(P=11, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P, P, P >>;
pad(P=12, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P, P, P, P >>;
pad(P=13, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P, P, P, P, P >>;
pad(P=14, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P, P, P, P, P, P >>;
pad(P=15, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P, P, P, P, P, P, P >>;
pad(P=16, Bin) -> << Bin/binary, P, P, P, P, P, P, P, P, P, P, P, P, P, P, P, P >>.
