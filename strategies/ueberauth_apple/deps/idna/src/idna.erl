%% -*- coding: utf-8 -*-
%%%-------------------------------------------------------------------
%%% @doc A pure Erlang IDNA implementation.
%%%
%%% This module provides functions to encode and decode Internationalized
%%% Domain Names (IDN) using the IDNA protocol as defined in
%%% <a href="https://tools.ietf.org/html/rfc5891">RFC 5891</a>.
%%%
%%% == Features ==
%%% <ul>
%%%   <li>Support for IDNA 2008 and IDNA 2003</li>
%%%   <li>UTS #46 compatibility processing</li>
%%%   <li>Label validation (NFC, hyphens, combining marks, context rules, BIDI)</li>
%%% </ul>
%%%
%%% == Basic Usage ==
%%% ```
%%% %% Encode a domain name to ASCII (Punycode)
%%% "xn--nxasmq5b.com" = idna:encode("βόλος.com").
%%%
%%% %% Decode an ASCII domain name to Unicode
%%% "βόλος.com" = idna:decode("xn--nxasmq5b.com").
%%%
%%% %% Use UTS #46 processing
%%% "xn--fa-hia.de" = idna:encode("faß.de", [uts46]).
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
%%% This file is part of erlang-idna released under the MIT license.
%%% See the LICENSE for more information.
%%%-------------------------------------------------------------------
-module(idna).

%% API
-export([encode/1, encode/2,
         decode/1, decode/2]).

%% Compatibility API
-export([to_ascii/1,
         to_unicode/1,
         utf8_to_ascii/1,
         from_ascii/1]).

%% Label functions
-export([alabel/1, ulabel/1]).

%% Validation functions
-export([check_hyphen/1,
         check_nfc/1,
         check_context/1,
         check_initial_combiner/1,
         check_label_length/1]).

-export([check_label/1, check_label/4]).

-define(ACE_PREFIX, "xn--").

-ifdef('OTP_RELEASE').
-define(lower(C), string:lowercase(C)).
-else.
-define(lower(C), string:to_lower(C)).
-endif.

-include("idna_logger.hrl").

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type idna_flag() :: uts46
                   | {uts46, boolean()}
                   | std3_rules
                   | {std3_rules, boolean()}
                   | transitional
                   | {transitional, boolean()}
                   | strict
                   | {strict, boolean()}.
%% IDNA processing options.
%%
%% <ul>
%%   <li>`uts46' - Enable UTS #46 compatibility processing (default: false)</li>
%%   <li>`std3_rules' - Enforce STD3 ASCII rules (default: false)</li>
%%   <li>`transitional' - Use transitional processing for IDNA 2003 compatibility (default: false)</li>
%%   <li>`strict' - Use strict dot separator (only ASCII period) (default: false)</li>
%% </ul>

-type idna_flags() :: [idna_flag()].
%% List of IDNA processing options.

-type label() :: string().
%% A single label (part between dots) of a domain name.

-type domain() :: string().
%% A full domain name (may contain multiple labels separated by dots).

-export_type([idna_flags/0, idna_flag/0, label/0, domain/0]).



%%--------------------------------------------------------------------
%% @doc Encode a domain name to ASCII using the IDNA protocol.
%%
%% Equivalent to `encode(Domain, [])'.
%% @end
%%--------------------------------------------------------------------
-spec encode(Domain) -> AsciiDomain when
      Domain :: domain(),
      AsciiDomain :: domain().
encode(Domain) ->
  encode(Domain, []).

%%--------------------------------------------------------------------
%% @doc Encode a domain name to ASCII using the IDNA protocol with options.
%%
%% Converts an Internationalized Domain Name to its ASCII-compatible
%% encoding (ACE) form using Punycode.
%%
%% == Options ==
%% <ul>
%%   <li>`uts46' - Enable <a href="https://unicode.org/reports/tr46/">UTS #46</a>
%%       compatibility processing. This maps characters according to the
%%       IDNA Mapping Table before encoding.</li>
%%   <li>`std3_rules' - Enforce STD3 ASCII rules (disallow certain characters).</li>
%%   <li>`transitional' - Use transitional processing for backward compatibility
%%       with IDNA 2003. For example, maps ß to ss.</li>
%%   <li>`strict' - Only use ASCII period (.) as label separator instead of
%%       also accepting fullwidth and ideographic periods.</li>
%% </ul>
%%
%% == Examples ==
%% ```
%% %% Basic encoding
%% "xn--nxasmq5b.com" = idna:encode("βόλος.com").
%%
%% %% With UTS #46 processing
%% "xn--fa-hia.de" = idna:encode("faß.de", [uts46]).
%%
%% %% With transitional processing (ß -> ss)
%% "fass.de" = idna:encode("faß.de", [uts46, transitional]).
%% '''
%% @end
%%--------------------------------------------------------------------
-spec encode(Domain, Options) -> AsciiDomain when
      Domain :: domain(),
      Options :: idna_flags(),
      AsciiDomain :: domain().
encode(Domain0, Options) ->
  ok = validate_options(Options),
  Domain = case proplists:get_value(uts46, Options, false) of
             true ->
               STD3Rules = proplists:get_value(std3_rules, Options, false),
               Transitional = proplists:get_value(transitional, Options, false),
               uts46_remap(Domain0, STD3Rules, Transitional);
             false ->
               Domain0
           end,
  Labels = case proplists:get_value(strict, Options, false) of
             false ->
               re:split(Domain, "[.。．｡]", [{return, list}, unicode]);
             true ->
               string:tokens(Domain, ".")
           end,
  case Labels of
    [] -> exit(empty_domain);
    _ ->
      encode_1(Labels, [])
  end.

%%--------------------------------------------------------------------
%% @doc Decode an ASCII domain name to Unicode using the IDNA protocol.
%%
%% Equivalent to `decode(Domain, [])'.
%% @end
%%--------------------------------------------------------------------
-spec decode(AsciiDomain) -> Domain when
      AsciiDomain :: domain(),
      Domain :: domain().
decode(Domain) ->
  decode(Domain, []).

%%--------------------------------------------------------------------
%% @doc Decode an ASCII domain name to Unicode using the IDNA protocol with options.
%%
%% Converts an ASCII-compatible encoding (ACE) domain name back to its
%% Unicode representation.
%%
%% == Options ==
%% Same options as {@link encode/2}.
%%
%% == Examples ==
%% ```
%% %% Basic decoding
%% "βόλος.com" = idna:decode("xn--nxasmq5b.com").
%%
%% %% Decode with UTS #46 processing
%% "faß.de" = idna:decode("xn--fa-hia.de", [uts46]).
%% '''
%% @end
%%--------------------------------------------------------------------
-spec decode(AsciiDomain, Options) -> Domain when
      AsciiDomain :: domain(),
      Options :: idna_flags(),
      Domain :: domain().
decode(Domain0, Options) ->
  ok = validate_options(Options),
  Domain = case proplists:get_value(uts46, Options, false) of
             true ->
               STD3Rules = proplists:get_value(std3_rules, Options, false),
               Transitional = proplists:get_value(transitional, Options, false),
               uts46_remap(Domain0, STD3Rules, Transitional);
             false ->
               Domain0
           end,

  Labels = case proplists:get_value(strict, Options, false) of
             false ->
               re:split(lowercase(Domain), "[.。．｡]", [{return, list}, unicode]);
             true ->
               string:tokens(lowercase(Domain), ".")
           end,
  case Labels of
    [] -> exit(empty_domain);
    _ ->
      decode_1(Labels, [])
  end.


%%--------------------------------------------------------------------
%% Compatibility API
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc Encode a domain name to ASCII (compatibility API).
%%
%% This function is provided for backward compatibility with older
%% IDNA libraries. It is equivalent to {@link encode/1}.
%%
%% @deprecated Use {@link encode/1} instead.
%% @end
%%--------------------------------------------------------------------
-spec to_ascii(Domain) -> AsciiDomain when
      Domain :: domain(),
      AsciiDomain :: domain().
to_ascii(Domain) -> encode(Domain).

%%--------------------------------------------------------------------
%% @doc Decode an ASCII domain name to Unicode (compatibility API).
%%
%% This function is provided for backward compatibility with older
%% IDNA libraries. It is equivalent to {@link decode/1}.
%%
%% @deprecated Use {@link decode/1} instead.
%% @end
%%--------------------------------------------------------------------
-spec to_unicode(AsciiDomain) -> Domain when
      AsciiDomain :: domain(),
      Domain :: domain().
to_unicode(Domain) -> decode(Domain).

%%--------------------------------------------------------------------
%% @doc Convert a UTF-8 binary domain to ASCII.
%%
%% Converts the UTF-8 encoded domain to a Unicode string first,
%% then encodes it to ASCII.
%%
%% @deprecated Use {@link encode/1} with proper Unicode string instead.
%% @end
%%--------------------------------------------------------------------
-spec utf8_to_ascii(Utf8Domain) -> AsciiDomain when
      Utf8Domain :: binary() | string(),
      AsciiDomain :: domain().
utf8_to_ascii(Domain) ->
  to_ascii(idna_ucs:from_utf8(Domain)).

%%--------------------------------------------------------------------
%% @doc Decode an ASCII domain name to Unicode (compatibility API).
%%
%% This function is provided for backward compatibility. It is
%% equivalent to {@link decode/1}.
%%
%% @deprecated Use {@link decode/1} instead.
%% @end
%%--------------------------------------------------------------------
-spec from_ascii(AsciiDomain) -> Domain when
      AsciiDomain :: domain(),
      Domain :: domain().
from_ascii(Domain) ->
  decode(Domain).


%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% @private
validate_options([]) -> ok;
validate_options([uts46|Rs]) -> validate_options(Rs);
validate_options([{uts46, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([strict|Rs]) -> validate_options(Rs);
validate_options([{strict, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([std3_rules|Rs]) -> validate_options(Rs);
validate_options([{std3_rules, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([transitional|Rs]) -> validate_options(Rs);
validate_options([{transitional, B}|Rs]) when is_boolean(B) -> validate_options(Rs);
validate_options([_]) -> erlang:error(badarg).

%% @private
encode_1([], Acc) ->
  lists:reverse(Acc);
encode_1([Label|Labels], []) ->
  encode_1(Labels, lists:reverse(alabel(Label)));
encode_1([Label|Labels], Acc) ->
  encode_1(Labels, lists:reverse(alabel(Label), [$.|Acc])).

%%--------------------------------------------------------------------
%% @doc Check that a label is in Unicode Normalization Form C (NFC).
%%
%% Validates that the label is properly normalized according to
%% <a href="https://tools.ietf.org/html/rfc5891#section-4.2.1">RFC 5891 Section 4.2.1</a>.
%%
%% Exits with `{bad_label, {nfc, Reason}}' if validation fails.
%% @end
%%--------------------------------------------------------------------
-spec check_nfc(Label) -> ok when
      Label :: label().
check_nfc(Label) ->
  case characters_to_nfc_list(Label) of
    Label -> ok;
    _ ->
      erlang:exit({bad_label, {nfc, "Label must be in Normalization Form C"}})
  end.

%%--------------------------------------------------------------------
%% @doc Check that a label conforms to hyphen placement rules.
%%
%% Validates that the label does not have hyphens in the 3rd and 4th
%% positions (which would indicate an ACE prefix) and does not start
%% or end with a hyphen.
%%
%% See <a href="https://tools.ietf.org/html/rfc5891#section-4.2.3.1">RFC 5891 Section 4.2.3.1</a>.
%%
%% Exits with `{bad_label, {hyphen, Reason}}' if validation fails.
%% @end
%%--------------------------------------------------------------------
-spec check_hyphen(Label) -> ok when
      Label :: label().
check_hyphen(Label) -> check_hyphen(Label, true).

%% @private
check_hyphen(Label, true) when length(Label) >= 3 ->
  case lists:nthtail(2, Label) of
    [$-, $-|_] ->
      ErrorMsg = error_msg("Label ~p has disallowed hyphens in 3rd and 4th position", [Label]),
      erlang:exit({bad_label, {hyphen, ErrorMsg}});
    _ ->
      case (lists:nth(1, Label) == $-) orelse (lists:last(Label) == $-) of
        true ->
          ErrorMsg = error_msg("Label ~p must not start or end with a hyphen", [Label]),
          erlang:exit({bad_label, {hyphen, ErrorMsg}});
        false ->
          ok
      end
  end;
check_hyphen(Label, true) ->
  case (lists:nth(1, Label) == $-) orelse (lists:last(Label) == $-) of
    true ->
      ErrorMsg = error_msg("Label ~p must not start or end with a hyphen", [Label]),
      erlang:exit({bad_label, {hyphen, ErrorMsg}});
    false ->
      ok
  end;
check_hyphen(_Label, false) ->
  ok.

%%--------------------------------------------------------------------
%% @doc Check that a label does not begin with a combining mark.
%%
%% Validates that the label does not start with a combining character
%% as required by <a href="https://tools.ietf.org/html/rfc5891#section-4.2.3.2">RFC 5891 Section 4.2.3.2</a>.
%%
%% Exits with `{bad_label, {initial_combiner, Reason}}' if validation fails.
%% @end
%%--------------------------------------------------------------------
-spec check_initial_combiner(Label) -> ok when
      Label :: label().
check_initial_combiner([CP|_]) ->
  case idna_data:lookup(CP) of
    {[$M|_], _} ->
      erlang:exit({bad_label, {initial_combiner, "Label begins with an illegal combining character"}});
    _ ->
      ok
  end.

%%--------------------------------------------------------------------
%% @doc Check contextual rules for characters in a label.
%%
%% Validates that all characters in the label are either PVALID
%% (protocol valid) or pass their contextual rules (CONTEXTJ/CONTEXTO)
%% as defined in <a href="https://tools.ietf.org/html/rfc5892">RFC 5892</a>.
%%
%% Exits with `{bad_label, {context, Reason}}' if validation fails.
%% @end
%%--------------------------------------------------------------------
-spec check_context(Label) -> ok when
      Label :: label().
check_context(Label) ->
  check_context(Label, Label, true, 0).

%% @private
check_context(Label, CheckJoiners) ->
  check_context(Label, Label, CheckJoiners, 0).

%% @private
check_context([CP | Rest], Label, CheckJoiners, Pos) ->
  case idna_table:lookup(CP) of
    'PVALID' ->
      check_context(Rest, Label, CheckJoiners, Pos + 1);
    'CONTEXTJ' ->
        ok =  valid_contextj(CP, Label, Pos, CheckJoiners),
        check_context(Rest, Label, CheckJoiners, Pos + 1);
    'CONTEXTO' ->
      ok =  valid_contexto(CP, Label, Pos, CheckJoiners),
      check_context(Rest, Label, CheckJoiners, Pos + 1);
    _Status ->
      ErrorMsg = error_msg("Codepoint ~p not allowed (~p) at position ~p in ~p", [CP, _Status, Pos, Label]),
      erlang:exit({bad_label, {context, ErrorMsg}})
  end;
check_context([], _, _, _) ->
  ok.

%% @private
valid_contextj(CP, Label, Pos, true) ->
  case idna_context:valid_contextj(CP, Label, Pos) of
    true ->
      ok;
    false ->
      ErrorMsg = error_msg("Joiner ~p not allowed at position ~p in ~p", [CP, Pos, Label]),
      erlang:exit({bad_label, {contextj, ErrorMsg}})
  end;
valid_contextj(_CP, _Label, _Pos, false) ->
  ok.

%% @private
valid_contexto(CP, Label, Pos, true) ->
  case idna_context:valid_contexto(CP, Label, Pos) of
    true ->
      ok;
    false ->
      ErrorMsg = error_msg("Joiner ~p not allowed at position ~p in ~p", [CP, Pos, Label]),
      erlang:exit({bad_label, {contexto, ErrorMsg}})
  end;
valid_contexto(_CP, _Label, _Pos, false) ->
  ok.

%%--------------------------------------------------------------------
%% @doc Validate a domain label with default settings.
%%
%% Equivalent to `check_label(Label, true, true, true)'.
%%
%% Performs all IDNA validation checks: NFC normalization, hyphen rules,
%% initial combiner, context rules, and BIDI rules.
%% @end
%%--------------------------------------------------------------------
-spec check_label(Label) -> ok when
      Label :: label().
check_label(Label) ->
  check_label(Label, true, true, true).

%%--------------------------------------------------------------------
%% @doc Validate a domain label with configurable checks.
%%
%% Validates that a label conforms to IDNA requirements. The following
%% checks can be enabled or disabled:
%%
%% <ul>
%%   <li>`CheckHyphens' - Check hyphen placement rules</li>
%%   <li>`CheckJoiners' - Check CONTEXTJ/CONTEXTO rules</li>
%%   <li>`CheckBidi' - Check bidirectional text rules (RFC 5893)</li>
%% </ul>
%%
%% NFC normalization and initial combiner checks are always performed.
%%
%% Exits with `{bad_label, {Reason, Message}}' if validation fails.
%% @end
%%--------------------------------------------------------------------
-spec check_label(Label, CheckHyphens, CheckJoiners, CheckBidi) -> ok when
      Label :: label(),
      CheckHyphens :: boolean(),
      CheckJoiners :: boolean(),
      CheckBidi :: boolean().
check_label(Label, CheckHyphens, CheckJoiners, CheckBidi) ->
  ok = check_nfc(Label),
  ok = check_hyphen(Label, CheckHyphens),
  ok = check_initial_combiner(Label),
  ok = check_context(Label, CheckJoiners),
  ok = check_bidi(Label, CheckBidi),
  ok.


%% @private
check_bidi(Label, true) ->
  idna_bidi:check_bidi(Label);
check_bidi(_, false) ->
  ok.

%%--------------------------------------------------------------------
%% @doc Check that a label does not exceed the maximum length.
%%
%% Labels in DNS are limited to 63 octets. This function validates
%% that the label length does not exceed this limit.
%%
%% Exits with `{bad_label, {too_long, Reason}}' if validation fails.
%% @end
%%--------------------------------------------------------------------
-spec check_label_length(Label) -> ok when
      Label :: label().
check_label_length(Label) when length(Label) > 63 ->
  ErrorMsg = error_msg("The label ~p  is too long", [Label]),
  erlang:exit({bad_label, {too_long, ErrorMsg}});
check_label_length(_) ->
  ok.

%%--------------------------------------------------------------------
%% @doc Convert a label to its ASCII-compatible encoding (A-label).
%%
%% Takes a Unicode label and returns its Punycode-encoded form with
%% the "xn--" ACE prefix. If the label is already ASCII, it is
%% validated and returned as-is.
%%
%% == Examples ==
%% ```
%% "xn--nxasmq5b" = idna:alabel("βόλος").
%% "example" = idna:alabel("example").
%% '''
%%
%% Exits with `{bad_label, Reason}' if the label is invalid.
%% @end
%%--------------------------------------------------------------------
-spec alabel(Label) -> ALabel when
      Label :: label(),
      ALabel :: label().
alabel(Label0) ->
  Label = case lists:all(fun(C) -> idna_ucs:is_ascii(C) end, Label0) of
            true ->
              _ = try ulabel(Label0)
                  catch
                    _:Error ->
                      ErrorMsg = error_msg("The label ~p  is not a valid A-label: ulabel error=~p", [Label0, Error]),
                      erlang:exit({bad_label, {alabel, ErrorMsg}})
                  end,
              ok = check_label_length(Label0),

              Label0;
            false ->
              ok = check_label(Label0),
              ?ACE_PREFIX ++ punycode:encode(Label0)
          end,
  ok = check_label_length(Label),
  Label.

%% @private
decode_1([], Acc) ->
  lists:reverse(Acc);
decode_1([Label|Labels], []) ->
  decode_1(Labels, lists:reverse(ulabel(Label)));
decode_1([Label|Labels], Acc) ->
  decode_1(Labels, lists:reverse(ulabel(Label), [$.|Acc])).

%%--------------------------------------------------------------------
%% @doc Convert a label to its Unicode form (U-label).
%%
%% Takes an ASCII label (potentially Punycode-encoded with "xn--" prefix)
%% and returns its Unicode representation. The result is validated
%% against IDNA rules.
%%
%% == Examples ==
%% ```
%% "βόλος" = idna:ulabel("xn--nxasmq5b").
%% "example" = idna:ulabel("example").
%% '''
%%
%% Exits with `{bad_label, Reason}' if the label is invalid.
%% @end
%%--------------------------------------------------------------------
-spec ulabel(ALabel) -> Label when
      ALabel :: label(),
      Label :: label().
ulabel([]) -> [];
ulabel(Label0) ->
  Label = case lists:all(fun(C) -> idna_ucs:is_ascii(C) end, Label0) of
            true ->
              case Label0 of
                [$x,$n,$-,$-|Label1] ->
                  punycode:decode(lowercase(Label1));
                _ ->
                  lowercase(Label0)
              end;
            false ->
              lowercase(Label0)
          end,
  ok = check_label(Label),
  Label.

%% Lowercase all chars in Str
-spec lowercase(String::unicode:chardata()) -> unicode:chardata().
lowercase(CD) when is_list(CD) ->
  try lowercase_list(CD, false)
  catch unchanged -> CD
  end;
lowercase(<<CP1/utf8, Rest/binary>>=Orig) ->
  try lowercase_bin(CP1, Rest, false) of
    List -> unicode:characters_to_binary(List)
  catch unchanged -> Orig
  end;
lowercase(<<>>) ->
  <<>>.


lowercase_list([CP1|[CP2|_]=Cont], _Changed) when $A =< CP1, CP1 =< $Z, CP2 < 256 ->
  [CP1+32|lowercase_list(Cont, true)];
lowercase_list([CP1|[CP2|_]=Cont], Changed) when CP1 < 128, CP2 < 256 ->
  [CP1|lowercase_list(Cont, Changed)];
lowercase_list([], true) ->
  [];
lowercase_list([], false) ->
  throw(unchanged);
lowercase_list(CPs0, Changed) ->
  case unicode_util:lowercase(CPs0) of
    [Char|CPs] when Char =:= hd(CPs0) -> [Char|lowercase_list(CPs, Changed)];
    [Char|CPs] -> append(Char,lowercase_list(CPs, true));
    [] -> lowercase_list([], Changed)
  end.

lowercase_bin(CP1, <<CP2/utf8, Bin/binary>>, _Changed)
  when $A =< CP1, CP1 =< $Z, CP2 < 256 ->
  [CP1+32|lowercase_bin(CP2, Bin, true)];
lowercase_bin(CP1, <<CP2/utf8, Bin/binary>>, Changed)
  when CP1 < 128, CP2 < 256 ->
  [CP1|lowercase_bin(CP2, Bin, Changed)];
lowercase_bin(CP1, Bin, Changed) ->
  case unicode_util:lowercase([CP1|Bin]) of
    [CP1|CPs] ->
      case unicode_util:cp(CPs) of
        [Next|Rest] ->
          [CP1|lowercase_bin(Next, Rest, Changed)];
        [] when Changed ->
          [CP1];
        [] ->
          throw(unchanged)
      end;
    [Char|CPs] ->
      case unicode_util:cp(CPs) of
        [Next|Rest] ->
          [Char|lowercase_bin(Next, Rest, true)];
        [] ->
          [Char]
      end
  end.


append(Char, <<>>) when is_integer(Char) -> [Char];
append(Char, <<>>) when is_list(Char) -> Char;
append(Char, Bin) when is_binary(Bin) -> [Char,Bin];
append(Char, Str) when is_integer(Char) -> [Char|Str];
append(GC, Str) when is_list(GC) -> GC ++ Str.


characters_to_nfc_list(CD) ->
  case unicode_util:nfc(CD) of
    [CPs|Str] when is_list(CPs) -> CPs ++ characters_to_nfc_list(Str);
    [CP|Str] -> [CP|characters_to_nfc_list(Str)];
    [] -> []
  end.


uts46_remap(Str, Std3Rules, Transitional) ->
  characters_to_nfc_list(uts46_remap_1(Str, Std3Rules, Transitional)).

uts46_remap_1([Cp|Rs], Std3Rules, Transitional) ->
  Row = try idna_mapping:uts46_map(Cp)
        catch
          error:badarg  ->
            ?LOG_ERROR("codepoint ~p not found in mapping list~n", [Cp]),
            erlang:exit({invalid_codepoint, Cp})
        end,
  {Status, Replacement} = case Row of
                            {_, _} -> Row;
                            S -> {S, undefined}
                          end,
  if
    (Status =:= 'V');
    ((Status =:= 'D') andalso (Transitional =:= false));
    ((Status =:= '3') andalso (Std3Rules =:= true) andalso (Replacement =:= undefined)) ->
      [Cp] ++ uts46_remap_1(Rs, Std3Rules, Transitional);
    (Replacement =/= undefined) andalso (
        (Status =:= 'M') orelse
          (Status =:= '3' andalso Std3Rules =:= false) orelse
          (Status =:= 'D' andalso Transitional =:= true)) ->
      %% Recursively process replacement characters (they may have their own mappings)
      uts46_remap_1(Replacement ++ Rs, Std3Rules, Transitional);
    (Status =:= 'I') ->
      uts46_remap_1(Rs, Std3Rules, Transitional);
    true ->
      erlang:exit({invalid_codepoint, Cp})
  end;
uts46_remap_1([], _, _) ->
  [].

error_msg(Msg, Fmt) ->
  lists:flatten(io_lib:format(Msg, Fmt)).
