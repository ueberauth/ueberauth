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
%%% @doc This module introduces Matcher abstraction. It is an entity that can
%%% be created from a predicate function or a matcher provided by a supported
%%% framework (at the moment only Hamcrest is supported). Then it can be used
%%% to check that an arbitrary value meets the matcher's criteria, matches in
%%% other words.
-module(meck_matcher).

-export_type([matcher/0]).

%% API
-export([new/1]).
-export([is_matcher/1]).
-export([match_ignore/2]).

-ignore_xref({hamcrest, is_matcher, 1}).
-ignore_xref({hamcrest, assert_that, 2}).

%%%============================================================================
%%% Definitions
%%%============================================================================

-record('$meck.matcher', {type :: predicate | hamcrest,
                          impl :: predicate() | hamcrest_matchspec()}).

%%%============================================================================
%%% Types
%%%============================================================================

-type predicate() :: fun((X::any()) -> any()).
-type matcher() :: #'$meck.matcher'{}.
-type hamcrest_matchspec() :: tuple(). %% #'hamcrest.matchspec'{}
-export_type([hamcrest_matchspec/0]).

%%%============================================================================
%%% API
%%%============================================================================

-spec new(predicate() | hamcrest_matchspec()) -> matcher().
new(Predicate) when is_function(Predicate) ->
    {arity, 1} = erlang:fun_info(Predicate, arity),
    #'$meck.matcher'{type = predicate, impl = Predicate};
new(Something) ->
    case is_hamcrest_matcher(Something) of
        true ->
            #'$meck.matcher'{type = hamcrest, impl = Something};
        _Else ->
            erlang:error({invalid_matcher, Something})
    end.

-spec is_matcher(any()) -> boolean().
is_matcher(#'$meck.matcher'{}) -> true;
is_matcher(_Other) -> false.

%% @doc If `Something' is a {@link meck_matcher()} instance then `Value' is
%% matched with it, otherwise `true' is returned effectively ignoring
%% `Something''s value.
-spec match_ignore(Value::any(), Something::any()) -> boolean().
match_ignore(Value, #'$meck.matcher'{type = predicate, impl = Predicate}) ->
    Predicate(Value) == true;
match_ignore(Value, #'$meck.matcher'{type = hamcrest, impl = HamcrestMatcher}) ->
    (catch erlang:apply(hamcrest, assert_that, [Value, HamcrestMatcher])) == true;
match_ignore(_Value, _NotMatcher) ->
    true.

%%%============================================================================
%%% Internal functions
%%%============================================================================

-spec is_hamcrest_matcher(any()) -> boolean().
is_hamcrest_matcher(Something) ->
    try erlang:apply(hamcrest, is_matcher, [Something])
    catch _Class:_Reason -> false
    end.
