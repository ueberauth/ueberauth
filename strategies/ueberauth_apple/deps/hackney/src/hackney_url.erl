%% -*- erlang -*-
%%%
%%% This file is part of hackney_lib released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2012-2015 Benoît Chesneau <benoitc@e-engura.org>
%%% Copyright (c) 2011, Magnus Klaar <magnus.klaar@gmail.com>
%%%

%% @doc module to manage URLs.

-module(hackney_url).

-export([parse_url/1,
         transport_scheme/1,
         unparse_url/1,
         urldecode/1, urldecode/2,
         urlencode/1, urlencode/2,
         parse_qs/1,
         qs/1, qs/2,
         make_url/3,
         fix_path/1,
         pathencode/1,
         normalize/1, normalize/2,
         property/2]).

-export([idnconvert_hostname/1]).
-export([is_ip_literal/1]).
-export([same_origin/2]).

-include("hackney_lib.hrl").

-type qs_vals() :: [{binary() | atom() | list() | integer(), binary() | true}].
-type qs_opt() :: noplus | upper.

%% @doc Parse an URL and return a #hackney_url record.
-spec parse_url(URL::binary()|list()) -> hackney_url().
parse_url(URL) when is_list(URL) ->
  case unicode:characters_to_binary(URL) of
    URL1 when is_binary(URL1) ->
      parse_url(URL1);
    _ ->
      parse_url(unicode:characters_to_binary(list_to_binary(URL)))
  end;
parse_url(<<"http://", Rest/binary>>) ->
  parse_url(Rest, #hackney_url{transport=hackney_tcp,
    scheme=http});
parse_url(<<"https://", Rest/binary>>) ->
  parse_url(Rest, #hackney_url{transport=hackney_ssl,
    scheme=https});
parse_url(<<"ws://", Rest/binary>>) ->
  parse_url(Rest, #hackney_url{transport=hackney_tcp,
    scheme=ws});
parse_url(<<"wss://", Rest/binary>>) ->
  parse_url(Rest, #hackney_url{transport=hackney_ssl,
    scheme=wss});
parse_url(<<"http+unix://", Rest/binary>>) ->
  parse_url(Rest, #hackney_url{transport=hackney_local_tcp, scheme=http_unix});
parse_url(<<"socks5://", Rest/binary>>) ->
  parse_url(Rest, #hackney_url{transport=hackney_socks5, scheme=socks5});
parse_url(URL) ->
  %% Check if this looks like a URL with an unrecognized scheme
  case binary:split(URL, <<"://">>) of
    [Scheme, Rest] when byte_size(Scheme) > 0, byte_size(Scheme) < 20 ->
      %% Looks like scheme://... - parse it but mark as unsupported
      case is_valid_scheme(Scheme) of
        true ->
          SchemeLower = hackney_bstr:to_lower(Scheme),
          %% GHSA-9653: never mint a fresh atom for an attacker-supplied
          %% scheme. `binary_to_existing_atom` only matches schemes that
          %% have already been registered (i.e. ones the runtime, this
          %% module, or the caller has explicitly seen). Anything else
          %% stays as a binary; the dispatcher rejects it as
          %% unsupported_scheme either way.
          SchemeRef = try binary_to_existing_atom(SchemeLower, utf8)
                      catch error:badarg -> SchemeLower
                      end,
          parse_url(Rest, #hackney_url{transport=undefined, scheme=SchemeRef});
        false ->
          %% Not a valid scheme, treat as path-like URL
          parse_url(URL, #hackney_url{transport=hackney_tcp, scheme=http})
      end;
    _ ->
      %% No :// found or empty scheme, treat as relative/partial URL
      parse_url(URL, #hackney_url{transport=hackney_tcp, scheme=http})
  end.

%% @private Check if a binary is a valid URL scheme (RFC 3986)
%% scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
is_valid_scheme(<<C, Rest/binary>>) when (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) ->
  is_valid_scheme_rest(Rest);
is_valid_scheme(_) ->
  false.

is_valid_scheme_rest(<<>>) ->
  true;
is_valid_scheme_rest(<<C, Rest/binary>>) when (C >= $a andalso C =< $z) orelse
                                               (C >= $A andalso C =< $Z) orelse
                                               (C >= $0 andalso C =< $9) orelse
                                               C =:= $+ orelse C =:= $- orelse C =:= $. ->
  is_valid_scheme_rest(Rest);
is_valid_scheme_rest(_) ->
  false.

parse_url(URL, S) ->
  {URL1, Fragment} = cut_fragment(URL),
  {URL2, Query} = cut_query(URL1),
  RawPath = << (raw_query(Query))/binary, (raw_fragment(Fragment))/binary >>,
  case binary:split(URL2, <<"/">>) of
    [URL2] ->
      parse_addr1(URL2, S#hackney_url{raw_path = RawPath,
                                      path = <<>>,
                                      qs = Query,
                                      fragment = Fragment});
    [Addr, <<>>] ->
      Path = <<"/">>,
      parse_addr1(Addr, S#hackney_url{raw_path = << Path/binary, RawPath/binary >>,
                                      path = Path,
                                      qs = Query,
                                      fragment = Fragment});
    [Addr, Path] ->
      parse_addr(Addr, S#hackney_url{raw_path = <<"/", Path/binary, RawPath/binary >>,
                                     path = <<"/", Path/binary >>,
                                     qs = Query,
                                     fragment = Fragment})
  end.


raw_fragment(<<"">>) -> <<"">>;
raw_fragment(Fragment) -> <<"#", Fragment/binary>>.

raw_query(<<>>) -> <<>>;
raw_query(Query) -> <<"?", Query/binary>>.

property(transport, URL) -> URL#hackney_url.transport;
property(scheme, URL) -> URL#hackney_url.scheme;
property(netloc, URL) -> URL#hackney_url.netloc;
property(raw_path, URL) -> URL#hackney_url.raw_path;
property(path, URL) -> URL#hackney_url.path;
property(qs, URL) -> URL#hackney_url.qs;
property(fragment, URL) -> URL#hackney_url.fragment;
property(host, URL) -> URL#hackney_url.host;
property(port, URL) -> URL#hackney_url.port;
property(user, URL) -> URL#hackney_url.user;
property(password, URL) -> URL#hackney_url.password;
property(_, _) -> erlang:error(badarg).


%% @doc Normalizes the encoding of an URL.
%% Use the {@link hackney_url:pathencode/1} to encode an URL.
-spec normalize(URL) -> NormalizedUrl when
  URL :: binary() | list() | hackney_url(),
  NormalizedUrl :: hackney_url().
normalize(Url) ->
  normalize(Url, fun hackney_url:pathencode/1).

%% @doc Normalizes the encoding of an URL.
-spec normalize(URL, Fun) -> NormalizedUrl when
  URL :: binary() | list() | hackney_url(),
  Fun :: fun(),
  NormalizedUrl :: hackney_url().
normalize(Url, Fun) when is_list(Url) orelse is_binary(Url) ->
  normalize(parse_url(Url), Fun);
normalize(#hackney_url{}=Url, Fun) when is_function(Fun, 1) ->
  #hackney_url{scheme=Scheme,
    host = Host0,
    port = Port,
    netloc = Netloc0,
    path = Path} = Url,

  {Host, Netloc} = case inet_parse:address(Host0) of
                     {ok, {_, _, _, _}} ->
                       {Host0, Netloc0};
                     {ok, {_, _, _, _, _, _, _, _}} ->
                       {Host0, Netloc0};
                     _ ->
                       DecodedBin = urldecode(unicode:characters_to_binary(Host0)),
                       Host1 = binary_to_list(DecodedBin),

                       %% A non-IP host that decodes to an IP literal (e.g.
                       %% `%31%32%37%2E%30%2E%30%2E%31` -> `127.0.0.1`) bypasses
                       %% any caller-side SSRF allowlist that ran
                       %% inet:parse_address on the pre-normalised host. IDNA
                       %% also folds the Unicode full-stop variants
                       %% (U+3002/U+FF0E/U+FF61) onto ASCII dots, so a host
                       %% written with them normalises to the same literal.
                       %% Reject the differential on the dot-canonicalised host.
                       %% IDN / pct-encoded UTF-8 hosts still flow through.
                       case inet_parse:address(ip_candidate(dot_canonical(DecodedBin))) of
                         {ok, _} -> error({invalid_url_host, Host0});
                         _ -> ok
                       end,

                       %% encode domain if needed
                       Host2 = case Scheme of
                                 http_unix -> Host1;
                                 _ -> idnconvert_hostname(Host1)
                               end,
                       Netloc1 = case {Scheme, Port} of
                                   {http, 80} -> list_to_binary(Host2);
                                   {https, 443} -> list_to_binary(Host2);
                                   {ws, 80} -> list_to_binary(Host2);
                                   {wss, 443} -> list_to_binary(Host2);
                                   {http_unix, _} -> list_to_binary(Host2);
                                   _ ->
                                     iolist_to_binary([Host2, ":", integer_to_list(Port)])
                                 end,
                       {Host2, Netloc1}
                   end,
  Path1 = Fun(Path),
  Url#hackney_url{host=Host, netloc=Netloc, path=Path1}.

transport_scheme(hackney_tcp) ->
  http;
transport_scheme(hackney_ssl) ->
  https;
transport_scheme(hackney_local_tcp) ->
  http_unix.

is_ascii(Host) ->
  lists:all(fun(C) -> idna_ucs:is_ascii(C) end, Host).

idnconvert_hostname(Host) ->
  case is_ascii(Host) of
    true ->
      Host;
    false ->
      idna:utf8_to_ascii(Host)
  end.

%% @private Fold the Unicode full-stop variants that IDNA treats as label
%% separators onto ASCII '.', so an IP literal written with them is caught by
%% the inet_parse gate. Falls back to the raw bytes if the host is not valid
%% UTF-8 (which cannot be an IP literal anyway).
dot_canonical(Bin) when is_binary(Bin) ->
  case unicode:characters_to_list(Bin) of
    Cps when is_list(Cps) -> [fold_dot(C) || C <- Cps];
    _ -> binary_to_list(Bin)
  end.

%% @private Strip what the connect path ignores before it reads a host as an
%% address: one `[...]' pair (hackney_happy:parse_address/1 drops it) and one
%% trailing dot (the resolver reads it as the root label). Without this,
%% `%5B%3A%3A1%5D' and `127.0.0.1.' pass the IP gate yet still reach the
%% literal address (GHSA-5643).
ip_candidate("[" ++ Rest) ->
  case lists:reverse(Rest) of
    "]" ++ Inner -> ip_candidate(lists:reverse(Inner));
    _ -> "[" ++ Rest
  end;
ip_candidate(Host) ->
  case lists:reverse(Host) of
    "." ++ Inner when Inner =/= [] -> lists:reverse(Inner);
    _ -> Host
  end.

fold_dot(16#3002) -> $.;
fold_dot(16#FF0E) -> $.;
fold_dot(16#FF61) -> $.;
fold_dot(C) -> C.

%% @doc True when both URLs share an origin: the same scheme, host (compared
%% case-insensitively) and port. Redirects to another origin drop credentials
%% (CVE-2018-1000007, GHSA-h73q). Takes parsed URLs or URLs to parse; the
%% default port is filled in by parse_url/1, so an explicit default port is
%% the same origin as none.
-spec same_origin(hackney_url() | binary() | string(),
                  hackney_url() | binary() | string()) -> boolean().
same_origin(#hackney_url{scheme = SchemeA, host = HostA, port = PortA},
            #hackney_url{scheme = SchemeB, host = HostB, port = PortB}) ->
  {SchemeA, string:lowercase(HostA), PortA} =:=
    {SchemeB, string:lowercase(HostB), PortB};
same_origin(#hackney_url{} = UrlA, UrlB) ->
  same_origin(UrlA, parse_url(UrlB));
same_origin(UrlA, UrlB) ->
  same_origin(parse_url(UrlA), UrlB).

%% @doc True when Host is an IPv4/IPv6 literal. RFC 6066 forbids sending SNI
%% for IP literals. Hosts reach the TLS layer bracket-stripped, but strip a
%% stray bracket pair defensively.
-spec is_ip_literal(binary() | string()) -> boolean().
is_ip_literal(Host) when is_binary(Host) ->
  is_ip_literal(binary_to_list(Host));
is_ip_literal("[" ++ Rest) ->
  is_ip_literal(string:trim(Rest, trailing, "]"));
is_ip_literal(Host) when is_list(Host) ->
  case inet:parse_address(Host) of
    {ok, _} -> true;
    {error, _} -> false
  end;
is_ip_literal(_) ->
  false.

unparse_url(#hackney_url{}=Url) ->
  #hackney_url{scheme = Scheme,
    netloc = Netloc,
    path = Path,
    qs = Qs,
    fragment = Fragment,
    user = User,
    password = Password} = Url,

  Scheme1 = case Scheme of
              http -> <<"http://">>;
              https -> <<"https://">>;
              ws -> <<"ws://">>;
              wss -> <<"wss://">>;
              http_unix -> <<"http+unix://">>
            end,

  Netloc1 = case User of
              <<>> ->
                Netloc;
              _ when Password /= <<>>, Password /= <<"">> ->
              EncodedUser = urlencode(User),
              EncodedPassword = urlencode(Password),
                << EncodedUser/binary, ":", EncodedPassword/binary, "@", Netloc/binary >>;
              _ ->
                EncodedUser = urlencode(User),
                << EncodedUser/binary, "@", Netloc/binary >>
            end,

  Qs1 = case Qs of
          <<>> -> <<>>;
          _ -> << "?", Qs/binary >>
        end,

  Fragment1 = case Fragment of
                <<>> -> <<>>;
                _ -> << "#", Fragment/binary >>
              end,

  Path1 = case Path of
            nil -> <<>>;
            undefined -> <<>>;
            _ -> Path
          end,

  << Scheme1/binary, Netloc1/binary, Path1/binary, Qs1/binary, Fragment1/binary >>.

%% @private
parse_addr1(Addr, S) ->
  case binary:split(Addr, <<"?">>) of
    [_Addr] ->
     parse_addr(Addr, S);
    [Addr1, Query] ->
      RawPath = << "?", Query/binary, (S#hackney_url.raw_path)/binary >>,
      parse_addr(Addr1, S#hackney_url{raw_path=RawPath, qs=Query})
  end.

parse_addr(Addr, S) ->
  %% RFC 3986: userinfo ends at the LAST @ before the host
  %% Example: user@domain.com:p@ssword@host.com -> userinfo=user@domain.com:p@ssword, host=host.com
  case binary:split(Addr, <<"@">>, [global]) of
    [Addr] ->
      %% No @ found - no credentials
      parse_netloc(Addr, S#hackney_url{netloc=Addr});
    Parts ->
      %% Split into credentials (all but last) and netloc (last)
      {CredParts, [Netloc]} = lists:split(length(Parts) - 1, Parts),
      Credentials = lists:join(<<"@">>, CredParts),
      CredentialsBin = iolist_to_binary(Credentials),
      case binary:split(CredentialsBin, <<":">>) of
        [User, Password] ->
          parse_netloc(Netloc, S#hackney_url{netloc=Netloc,
            user = urldecode(User),
            password = urldecode(Password)});
        [User] ->
          parse_netloc(Netloc, S#hackney_url{netloc = Netloc,
            user = urldecode(User),
            password = <<>> })
      end
  end.

parse_netloc(<<"[", Rest/binary>>, #hackney_url{transport=Transport}=S) ->
  case binary:split(Rest, <<"]">>, [trim]) of
    [Host] when Transport =:= hackney_tcp ->
      S#hackney_url{host=binary_to_list(Host), port=80};
    [Host] when Transport =:= hackney_ssl ->
      S#hackney_url{host=binary_to_list(Host), port=443};
    [Host] when Transport =:= hackney_socks5 ->
      S#hackney_url{host=binary_to_list(Host), port=1080};
    [Host, <<":", Port/binary>>] when Port /= <<>> ->
      S#hackney_url{host=binary_to_list(Host),
                    port=list_to_integer(binary_to_list(Port))};
    _ ->
      parse_netloc(Rest, S)
  end;

parse_netloc(<<>>, S) ->
  %% Empty netloc (e.g., file:///path)
  S#hackney_url{host=[], port=0};
parse_netloc(Netloc, #hackney_url{transport=Transport}=S) ->
  case binary:split(Netloc, <<":">>, [trim]) of
    [Host] when Transport =:= hackney_tcp ->
      S#hackney_url{host=unicode:characters_to_list((Host)),
                    port=80};
    [Host] when Transport =:= hackney_ssl ->
      S#hackney_url{host=unicode:characters_to_list(Host),
                    port=443};
    [Host] when Transport =:= hackney_local_tcp ->
      S#hackney_url{host=unicode:characters_to_list(urldecode(Host)),
                    port=0};
    [Host] when Transport =:= hackney_socks5 ->
      S#hackney_url{host=unicode:characters_to_list(Host),
                    port=1080};
    [Host] when Transport =:= undefined ->
      %% Unknown/unsupported scheme - no default port
      S#hackney_url{host=unicode:characters_to_list(Host),
                    port=0};
    [Host, Port] ->
      S#hackney_url{host=unicode:characters_to_list(Host),
                    port=list_to_integer(binary_to_list(Port))}
  end.


cut_query(Path) ->
  case binary:split(Path, <<"?">>) of
    [_Path] ->
      {Path, <<>>};
    [Path1, Query] ->
      {Path1, Query}
  end.

cut_fragment(S) ->
  case binary:split(S, <<"#">>) of
    [_S] ->
      {S, <<>>};
    [S1, F] ->
      {S1, F}
  end.


%% @doc Decode an URL encoded binary.
%% @equiv urldecode(Bin, crash)
-spec urldecode(binary()) -> binary().
urldecode(Bin) when is_binary(Bin) ->
  urldecode(Bin, <<>>, crash).

%% @doc Decode an URL encoded binary.
%% The second argument specifies how to handle percent characters that are not
%% followed by two valid hex characters. Use `skip' to ignore such errors,
%% if `crash' is used the function will fail with the reason `badarg'.
-spec urldecode(binary(), crash | skip) -> binary().
urldecode(Bin, OnError) when is_binary(Bin) ->
  urldecode(Bin, <<>>, OnError).

-spec urldecode(binary(), binary(), crash | skip) -> binary().
urldecode(<<$%, H, L, Rest/binary>>, Acc, OnError) ->
  G = unhex(H),
  M = unhex(L),
  if	G =:= error; M =:= error ->
    case OnError of skip -> ok; crash -> erlang:error(badarg) end,
    urldecode(<<H, L, Rest/binary>>, <<Acc/binary, $%>>, OnError);
    true ->
      urldecode(Rest, <<Acc/binary, (G bsl 4 bor M)>>, OnError)
  end;
urldecode(<<$%, Rest/binary>>, Acc, OnError) ->
  case OnError of skip -> ok; crash -> erlang:error(badarg) end,
  urldecode(Rest, <<Acc/binary, $%>>, OnError);
urldecode(<<$+, Rest/binary>>, Acc, OnError) ->
  urldecode(Rest, <<Acc/binary, $ >>, OnError);
urldecode(<<C, Rest/binary>>, Acc, OnError) ->
  urldecode(Rest, <<Acc/binary, C>>, OnError);
urldecode(<<>>, Acc, _OnError) ->
  Acc.

-spec unhex(byte()) -> byte() | error.
unhex(C) when C >= $0, C =< $9 -> C - $0;
unhex(C) when C >= $A, C =< $F -> C - $A + 10;
unhex(C) when C >= $a, C =< $f -> C - $a + 10;
unhex(_) -> error.

%% @doc URL encode a string binary.
-spec urlencode(binary() | string()) -> binary().
urlencode(Bin) ->
  urlencode(Bin, []).

%% @doc URL encode a string binary.
%% The `noplus' option disables the default behaviour of quoting space
%% characters, `\s', as `+'. The `lower' option overrides the default behaviour
%% of writing hex numbers using uppercase letters to using lowercase letters
%% instead.
-spec urlencode(binary() | string(), [qs_opt()]) -> binary().
urlencode(Bin, Opts) ->
  Plus = not proplists:get_value(noplus, Opts, false),
  Lower = proplists:get_value(lower, Opts, false),
  urlencode(hackney_bstr:to_binary(Bin), <<>>, Plus, Lower).

-spec urlencode(binary(), binary(), boolean(), boolean()) -> binary().
urlencode(<<C, Rest/binary>>, Acc, P=Plus, Lower) ->
  if	C >= $0, C =< $9 -> urlencode(Rest, <<Acc/binary, C>>, P, Lower);
    C >= $A, C =< $Z -> urlencode(Rest, <<Acc/binary, C>>, P, Lower);
    C >= $a, C =< $z -> urlencode(Rest, <<Acc/binary, C>>, P, Lower);
    C =:= $.; C =:= $-; C =:= $~; C =:= $_; C =:= $*; C =:= $@ ->
      urlencode(Rest, <<Acc/binary, C>>, P, Lower);
    C =:= $(; C =:= $); C =:= $!; C =:= $$ ->
      urlencode(Rest, <<Acc/binary, C>>, P, Lower);
    C =:= $ , Plus ->
      urlencode(Rest, <<Acc/binary, $+>>, P, Lower);
    true ->
      H = C band 16#F0 bsr 4, L = C band 16#0F,
      H1 = if Lower -> tohexl(H); true -> tohexu(H) end,
      L1 = if Lower -> tohexl(L); true -> tohexu(L) end,
      urlencode(Rest, <<Acc/binary, $%, H1, L1>>, P, Lower)
  end;
urlencode(<<>>, Acc, _Plus, _Lower) ->
  Acc.

-spec tohexu(byte()) -> byte().
tohexu(C) when C < 10 -> $0 + C;
tohexu(C) when C < 16 -> $A + C - 10.

-spec tohexl(byte()) -> byte().
tohexl(C) when C < 10 -> $0 + C;
tohexl(C) when C < 16 -> $a + C - 10.


%% Parse a query or a form from a binary and return a list of properties.
-spec parse_qs(binary()) -> qs_vals().
parse_qs(<<>>) ->
  [];
parse_qs(Bin) ->
  Tokens = hackney_bstr:split(Bin, <<"&">>, [trim_all, global]),
  [case hackney_bstr:split(Token, <<"=">>, [trim_all]) of
     [T] ->
       {urldecode(T), true};
     [Name, Value] ->
       {urldecode(Name), urldecode(Value)}
   end || Token <- Tokens].


%% @doc Encode query properties to binary.
-spec qs(qs_vals()) -> binary().
qs(KVs) ->
  qs(KVs, []).

%% @doc Encode query properties to binary.
%% Opts are passed to {@link urlencode/2.}
-spec qs(qs_vals(), [qs_opt()]) -> binary().
qs(KVs, Opts) ->
  qs(KVs, Opts, []).

qs([], _Opts, Acc) ->
  hackney_bstr:join(lists:reverse(Acc), <<"&">>);
qs([{K, V}|R], Opts, Acc) ->
  K1 = urlencode(K, Opts),
  V1 = urlencode(V, Opts),
  Line = << K1/binary, "=", V1/binary >>,
  qs(R, Opts, [Line | Acc]).

%% @doc Construct an URL from a base URL, a path and a list of
%% properties to give to the URL.
-spec make_url(binary(), binary() | [binary()], binary() | qs_vals())
    -> binary().
make_url(Url, Path, Query) when is_list(Query) ->
  %% a list of properties has been passed
  make_url(Url, Path, qs(Query));
make_url(Url, Path, Query) when is_binary(Path) ->
  make_url(Url, [Path], Query);
make_url(Url, PathParts, Query) when is_binary(Query) ->
  %% create path
  PathParts1 = [fix_path(P) || P <- PathParts, P /= "", P /= "/" orelse P /= <<"/">>],
  Path = hackney_bstr:join([<<>> | PathParts1], <<"/">>),

  %% initialise the query
  Query1 = case Query of
             <<>> -> <<>>;
             _ -> << "?", Query/binary >>
           end,

  %% make the final uri
  iolist_to_binary([fix_path(Url), Path, Query1]).

fix_path(Path) when is_list(Path) ->
  fix_path(list_to_binary(Path));
fix_path(<<>>) ->
  <<>>;
fix_path(<<"/", Path/binary>>) ->
  fix_path(Path);
fix_path(Path) ->
  case binary:part(Path, {size(Path), -1}) of
    <<"/">> -> binary:part(Path, {0, size(Path) - 1});
    _ -> Path
  end.

%% @doc Encode an URL path.
-spec pathencode(binary() | list()) -> binary().
pathencode(Path) when is_list(Path) ->
  pathencode(list_to_binary(Path));
pathencode(Path) when is_binary(Path) ->
  case  binary:split(Path, <<"/">>, [global]) of
    [Path] -> partial_pathencode(Path, <<>>);
    Parts ->
      do_partial_pathencode(Parts, [])
  end;
pathencode(undefined) ->
  <<>>;
pathencode(nil) ->
  <<>>;
pathencode(_) ->
  erlang:error(badarg).


do_partial_pathencode([], Acc) ->
  hackney_bstr:join(lists:reverse(Acc), <<"/">>);
do_partial_pathencode([Part | Rest], Acc) ->
  do_partial_pathencode(Rest, [partial_pathencode(Part, <<>>) | Acc]).



partial_pathencode(<<C, Rest/binary>> = Bin, Acc) ->
  if	C >= $0, C =< $9 -> partial_pathencode(Rest, <<Acc/binary, C>>);
    C >= $A, C =< $Z -> partial_pathencode(Rest, <<Acc/binary, C>>);
    C >= $a, C =< $z -> partial_pathencode(Rest, <<Acc/binary, C>>);
    C =:= $;; C =:= $=; C =:= $,; C =:= $:; C =:= $*; C =:= $@; C =:= $(; C =:= $) ->
      partial_pathencode(Rest, <<Acc/binary, C>>);
    C =:= $.; C =:= $-; C =:= $+; C =:= $~; C =:= $_ ->
      partial_pathencode(Rest, <<Acc/binary, C>>);
    C =:= $  ->
      partial_pathencode(Rest, <<Acc/binary, $+>>);
    C =:= $% ->
      %% special case, when a % is passed to the path, check if
      %% it's a valid escape sequence. If the sequence is valid we
      %% don't try to encode it and continue, else, we encode it.
      %% the behaviour is similar to the one you find in chrome:
      %% http://src.chromium.org/viewvc/chrome/trunk/src/url/url_canon_path.cc
      case Bin of
        << $%, H, L, Rest1/binary >> ->
          G = unhex(H),
          M = unhex(L),
          if	G =:= error; M =:= error ->
            H1 = C band 16#F0 bsr 4, L1 = C band 16#0F,
            H2 = tohexu(H1),
            L2 = tohexu(L1),
            partial_pathencode(Rest, <<Acc/binary, $%, H2, L2>>);
            true ->
              partial_pathencode(Rest1, <<Acc/binary, $%, H, L>>)
          end;
        _ ->
          H1 = C band 16#F0 bsr 4, L1 = C band 16#0F,
          H2 = tohexu(H1),
          L2 = tohexu(L1),
          partial_pathencode(Rest, <<Acc/binary, $%, H2, L2>>)
      end;
    true ->
      H = C band 16#F0 bsr 4, L = C band 16#0F,
      H1 = tohexu(H),
      L1 = tohexu(L),
      partial_pathencode(Rest, <<Acc/binary, $%, H1, L1>>)
  end;
partial_pathencode(<<>>, Acc) ->
  Acc.
