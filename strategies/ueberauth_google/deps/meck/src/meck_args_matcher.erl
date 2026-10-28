%%%============================================================================
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%% http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%============================================================================

%%% @private
-module(meck_args_matcher).

-export_type([args_spec/0]).
-export_type([opt_args_spec/0]).
-export_type([args_matcher/0]).

%% API
-export([new/1]).
-export([arity/1]).
-export([match/2]).

%%%============================================================================
%%% Definitions
%%%============================================================================

-record(args_matcher, {opt_args_pattern :: opt_args_pattern(),
                       comp_match_spec :: ets:comp_match_spec(),
                       has_matchers :: boolean()}).

%%%============================================================================
%%% Types
%%%============================================================================

-type opt_args_spec() :: args_spec() | '_'.
-type args_spec() :: args_pattern() | non_neg_integer().
-type opt_args_pattern() :: args_pattern() | '_'.
-type args_pattern() :: [any() | '_' | meck_matcher:matcher()].

-opaque args_matcher() :: #args_matcher{}.

%%%============================================================================
%%% API
%%%============================================================================

-spec new(opt_args_spec()) -> args_matcher().
new('_') ->
    MatchSpecItem = meck_util:match_spec_item({'_'}),
    CompMatchSpec = ets:match_spec_compile([MatchSpecItem]),
    #args_matcher{opt_args_pattern = '_',
                  comp_match_spec = CompMatchSpec,
                  has_matchers = false};
new(Arity) when is_number(Arity) ->
    ArgsPattern = lists:duplicate(Arity, '_'),
    MatchSpecItem = meck_util:match_spec_item({ArgsPattern}),
    CompMatchSpec = ets:match_spec_compile([MatchSpecItem]),
    #args_matcher{opt_args_pattern = ArgsPattern,
                  comp_match_spec = CompMatchSpec,
                  has_matchers = false};
new(ArgsPattern) when is_list(ArgsPattern) ->
    {HasMatchers, Pattern} = case strip_off_matchers(ArgsPattern) of
                                 unchanged ->
                                     {false, ArgsPattern};
                                 StrippedArgsSpec ->
                                     {true, StrippedArgsSpec}
                             end,
    MatchSpecItem = meck_util:match_spec_item({Pattern}),
    CompMatchSpec = ets:match_spec_compile([MatchSpecItem]),
    #args_matcher{opt_args_pattern = ArgsPattern,
                  comp_match_spec = CompMatchSpec,
                  has_matchers = HasMatchers}.

-spec arity(args_matcher()) -> Arity::non_neg_integer().
arity(#args_matcher{opt_args_pattern = ArgsPattern}) ->
    erlang:length(ArgsPattern).

-spec match(Args::any(), args_matcher()) -> boolean().
match(Args, #args_matcher{opt_args_pattern = OptArgsPattern,
                          comp_match_spec = CompMatchSpec,
                          has_matchers = HasMatchers}) ->
    case ets:match_spec_run([{Args}], CompMatchSpec) of
        [] ->
            false;
        _Matches when HasMatchers andalso erlang:is_list(OptArgsPattern) ->
            check_by_matchers(Args, OptArgsPattern);
        _Matches ->
            true
    end.

%%%============================================================================
%%% Internal functions
%%%============================================================================

-spec strip_off_matchers(args_pattern()) ->
        NewArgsPattern::args_pattern() | unchanged.
strip_off_matchers(ArgsPattern) ->
    strip_off_matchers(ArgsPattern, [], false).

-spec strip_off_matchers(args_pattern(), Stripped::[any() | '_'], boolean()) ->
        NewArgsPattern::args_pattern() | unchanged.
strip_off_matchers([ArgPattern | Rest], Stripped, HasMatchers) ->
    case meck_matcher:is_matcher(ArgPattern) of
        true ->
            strip_off_matchers(Rest, ['_' | Stripped], true);
        _ ->
            strip_off_matchers(Rest, [ArgPattern | Stripped], HasMatchers)
    end;
strip_off_matchers([], Stripped, true) ->
    lists:reverse(Stripped);
strip_off_matchers([], _Stripped, false) ->
    unchanged.

-spec check_by_matchers(Args ::[any()], MaybeMatchers::[any()]) -> boolean().
check_by_matchers([Arg | RestArgs], [MaybeMatcher | RestMaybeMatchers]) ->
    case meck_matcher:match_ignore(Arg, MaybeMatcher) of
        true ->
            check_by_matchers(RestArgs, RestMaybeMatchers);
        _Else ->
            false
    end;
check_by_matchers([], []) ->
    true.