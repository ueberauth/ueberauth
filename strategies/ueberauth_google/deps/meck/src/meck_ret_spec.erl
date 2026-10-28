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
%%% @doc Provides expectation processing functions.
-module(meck_ret_spec).

-export_type([result_spec/0]).
-export_type([ret_spec/0]).

%% API
-export([passthrough/0]).
-export([val/1]).
-export([exec/1]).
-export([seq/1]).
-export([loop/1]).
-export([raise/2]).
-export([is_meck_exception/1]).
-export([is_passthrough/1]).
-export([retrieve_result/1]).
-export([eval_result/4]).

%%%============================================================================
%%% Types
%%%============================================================================

-opaque result_spec() :: {meck_value, any()} |
                         {meck_exec, fun()} |
                         {meck_raise, Class::throw | error | exit, Reason::any()} |
                         meck_passthrough.

-type ret_spec() :: {meck_seq, [ret_spec()]} |
                    {meck_loop, [ret_spec()], [ret_spec()]} |
                    result_spec() |
                    any().

%%%============================================================================
%%% API
%%%============================================================================

-spec passthrough() -> ret_spec().
passthrough() -> meck_passthrough.

-spec val(any()) -> ret_spec().
val(Value) -> {meck_value, Value}.

-spec exec(fun()) -> ret_spec().
exec(Fun) when is_function(Fun)-> {meck_exec, Fun}.

-spec seq([ret_spec()]) -> ret_spec().
seq(Sequence) when is_list(Sequence) -> {meck_seq, Sequence}.

-spec loop([ret_spec()]) -> ret_spec().
loop(Loop) when is_list(Loop) -> {meck_loop, Loop, Loop}.

-spec raise(Class:: throw | error | exit, Reason::any()) -> ret_spec().
raise(throw, Reason) -> {meck_raise, throw, Reason};
raise(error, Reason) -> {meck_raise, error, Reason};
raise(exit, Reason) -> {meck_raise, exit, Reason}.

-spec is_meck_exception(Reason::any()) -> {true, any(), any()} | false.
is_meck_exception({meck_raise, MockedClass, MockedReason}) ->
    {true, MockedClass, MockedReason};
is_meck_exception(_Reason) ->
    false.

-spec is_passthrough(ret_spec()) -> boolean().
is_passthrough(RetSpec) -> RetSpec == meck_passthrough.

-spec retrieve_result(RetSpec::ret_spec()) ->
        {result_spec(), NewRetSpec::ret_spec() | unchanged}.
retrieve_result(RetSpec) ->
    retrieve_result(RetSpec, []).

-spec eval_result(Mod::atom(), Func::atom(), Args::[any()], result_spec()) ->
        Result::any().
eval_result(_Mod, _Func, _Args, {meck_value, Value}) ->
    Value;
eval_result(_Mod, _Func, Args, {meck_exec, Fun}) when is_function(Fun) ->
    erlang:apply(Fun, Args);
eval_result(_Mod, _Func, _Args, MockedEx = {meck_raise, _Class, _Reason}) ->
    erlang:throw(MockedEx);
eval_result(Mod, Func, Args, meck_passthrough) ->
    erlang:apply(meck_util:original_name(Mod), Func, Args).

%%%============================================================================
%%% Internal functions
%%%============================================================================

-spec retrieve_result(RetSpec::ret_spec(), ExplodedRs::[ret_spec()]) ->
        {result_spec(), NewRetSpec::ret_spec() | unchanged}.
retrieve_result(RetSpec = {meck_seq, [InnerRs | _Rest]}, ExplodedRs) ->
    retrieve_result(InnerRs, [RetSpec | ExplodedRs]);
retrieve_result(RetSpec = {meck_loop, [InnerRs | _Rest], _Loop}, ExplodedRs) ->
    retrieve_result(InnerRs, [RetSpec | ExplodedRs]);
retrieve_result(RetSpec, ExplodedRs) ->
    ResultSpec = case is_result_spec(RetSpec) of
                     true ->
                         RetSpec;
                     _ when erlang:is_function(RetSpec) ->
                         exec(RetSpec);
                     _ ->
                         val(RetSpec)
                 end,
    {ResultSpec, update_rs(RetSpec, ExplodedRs, false)}.

-spec is_result_spec(any()) -> boolean().
is_result_spec({meck_value, _Value}) -> true;
is_result_spec({meck_exec, _Fun}) -> true;
is_result_spec({meck_raise, _Class, _Reason}) -> true;
is_result_spec(meck_passthrough) -> true;
is_result_spec(_Other) -> false.

-spec update_rs(InnerRs::ret_spec(), ExplodedRs::[ret_spec()], Done::boolean()) ->
        NewRetSpec::ret_spec() | unchanged.
update_rs(InnerRs, [], true) ->
    InnerRs;
update_rs(_InnerRs, [], false) ->
    unchanged;
update_rs(InnerRs, [CurrRs = {meck_seq, [InnerRs]} | ExplodedRs], Updated) ->
    update_rs(CurrRs, ExplodedRs, Updated);
update_rs(InnerRs, [{meck_seq, [InnerRs | Rest]} | ExplodedRs], _Updated) ->
    update_rs({meck_seq, Rest}, ExplodedRs, true);
update_rs(NewInnerRs, [{meck_seq, [_InnerRs | Rest]} | ExplodedRs], _Updated) ->
    update_rs({meck_seq, [NewInnerRs | Rest]}, ExplodedRs, true);
update_rs(InnerRs, [{meck_loop, [InnerRs], Loop} | ExplodedRs], _Updated) ->
    update_rs({meck_loop, Loop, Loop}, ExplodedRs, true);
update_rs(InnerRs, [{meck_loop, [InnerRs | Rest], Loop} | ExplodedRs],
             _Updated) ->
    update_rs({meck_loop, Rest, Loop}, ExplodedRs, true);
update_rs(NewInnerRs, [{meck_loop, [_InnerRs | Rest], Loop} | ExplodedRs],
             _Updated) ->
    update_rs({meck_loop, [NewInnerRs | Rest], Loop}, ExplodedRs, true).
