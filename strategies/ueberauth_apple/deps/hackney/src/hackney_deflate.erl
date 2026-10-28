%%% -*- erlang -*-
%%%
%%% Based on cow_deflate from cowlib (https://github.com/ninenines/cowlib)
%%% Modified for hackney.
%%%
%% Copyright (c) jdamanalo <joshuadavid.agustin@manalo.ph>
%% Copyright (c) Loïc Hoguin <essen@ninenines.eu>
%% Copyright (c) 2026, Benoit Chesneau <benoitc@benoitcnetwork.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(hackney_deflate).

-export([inflate/3]).

-spec inflate(zlib:zstream(), iodata(), non_neg_integer() | infinity)
	-> {ok, binary()} | {error, data_error | size_error}.

inflate(Z, Data, Limit) ->
	try
		{Status, Output} = zlib:safeInflate(Z, Data),
		do_inflate(Z, iolist_size(Output), Limit, Status, [Output])
	catch
		error:data_error ->
			{error, data_error}
	end.

do_inflate(_, Size, Limit, _, _) when Size > Limit ->
	{error, size_error};
do_inflate(Z, Size0, Limit, continue, Acc) ->
	{Status, Output} = zlib:safeInflate(Z, []),
	Size = Size0 + iolist_size(Output),
	do_inflate(Z, Size, Limit, Status, [Output | Acc]);
do_inflate(_, _, _, finished, Acc) ->
	{ok, iolist_to_binary(lists:reverse(Acc))}.
