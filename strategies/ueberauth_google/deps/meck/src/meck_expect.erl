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
-module(meck_expect).

%% API
-export_type([func_ari/0]).
-export_type([expect/0]).

-export([new/2]).
-export([new/3]).
-export([new_passthrough/1]).
-export([new_dummy/2]).
-export([func_ari/1]).
-export([is_passthrough/1]).
-export([fetch_result/2]).

%%%============================================================================
%%% Types
%%%============================================================================

-type func_clause_spec() :: {meck_args_matcher:args_spec(),
                             meck_ret_spec:ret_spec()}.

-type func_clause() :: {meck_args_matcher:args_matcher(),
                        meck_ret_spec:ret_spec()}.

-type func_ari() :: {Func::atom(), Ari::byte()}.
-type expect() :: {func_ari(), [func_clause()]}.

%%%============================================================================
%%% API
%%%============================================================================

-spec new(Func::atom(), fun() | func_clause_spec()) -> expect().
new(Func, StubFun) when is_function(StubFun) ->
    {arity, Arity} = erlang:fun_info(StubFun, arity),
    Clause = {meck_args_matcher:new(Arity), meck_ret_spec:exec(StubFun)},
    {{Func, Arity}, [Clause]};
new(Func, ClauseSpecs) when is_list(ClauseSpecs) ->
    {Arity, Clauses} = parse_clause_specs(ClauseSpecs),
    {{Func, Arity}, Clauses}.

-spec new(Func::atom(),
          meck_args_matcher:args_spec(),
          meck_ret_spec:ret_spec()) ->
        expect().
new(Func, ArgsSpec, RetSpec) ->
    {Ari, Clause} = parse_clause_spec({ArgsSpec, RetSpec}),
    {{Func, Ari}, [Clause]}.

-spec new_passthrough(func_ari()) -> expect().
new_passthrough({Func, Ari}) ->
    {{Func, Ari}, [{meck_args_matcher:new(Ari), meck_ret_spec:passthrough()}]}.

-spec new_dummy(func_ari(), meck_ret_spec:ret_spec()) -> expect().
new_dummy({Func, Ari}, RetSpec) ->
    {{Func, Ari}, [{meck_args_matcher:new(Ari), RetSpec}]}.

-spec func_ari(expect()) -> func_ari().
func_ari({FuncAri, _Clauses}) ->
    FuncAri.

-spec is_passthrough(expect()) -> boolean().
is_passthrough({_FuncAri, [{_Matcher, RetSpec}]}) ->
    meck_ret_spec:is_passthrough(RetSpec);
is_passthrough(_) ->
    false.

-spec fetch_result(Args::[any()], expect()) ->
        {undefined, unchanged} |
        {meck_ret_spec:result_spec(), unchanged} |
        {meck_ret_spec:result_spec(), NewExpect::expect()}.
fetch_result(Args, {FuncAri, Clauses}) ->
    case find_matching_clause(Args, Clauses) of
        not_found ->
            {undefined, unchanged};
        {ArgsMatcher, RetSpec} ->
            case meck_ret_spec:retrieve_result(RetSpec) of
                {ResultSpec, unchanged} ->
                    {ResultSpec, unchanged};
                {ResultSpec, NewRetSpec} ->
                    NewClauses = lists:keyreplace(ArgsMatcher, 1, Clauses,
                                                  {ArgsMatcher, NewRetSpec}),
                    {ResultSpec, {FuncAri, NewClauses}}
            end
    end.

%%%============================================================================
%%% Internal functions
%%%============================================================================

-spec parse_clause_specs([func_clause_spec()]) -> {Ari::byte(), [func_clause()]}.
parse_clause_specs([ClauseSpec | Rest]) ->
    {Ari, Clause} = parse_clause_spec(ClauseSpec),
    parse_clause_specs(Rest, Ari, [Clause]).

-spec parse_clause_specs([func_clause_spec()],
                         FirstClauseAri::byte(),
                         Clauses::[func_clause()]) ->
        {Ari::byte(), [func_clause()]}.
parse_clause_specs([ClauseSpec | Rest], FirstClauseAri, Clauses) ->
    {Ari, Clause} = parse_clause_spec(ClauseSpec),
    case Ari of
        FirstClauseAri ->
            parse_clause_specs(Rest, FirstClauseAri, [Clause | Clauses]);
        _ ->
            erlang:error({invalid_arity, {{expected, FirstClauseAri},
                                          {actual, Ari},
                                          {clause, ClauseSpec}}})
    end;
parse_clause_specs([], FirstClauseAri, Clauses) ->
    {FirstClauseAri, lists:reverse(Clauses)}.

-spec parse_clause_spec(func_clause_spec()) ->
        {Ari::byte(), func_clause()}.
parse_clause_spec({ArgsSpec, RetSpec}) ->
    ArgsMatcher = meck_args_matcher:new(ArgsSpec),
    Ari = meck_args_matcher:arity(ArgsMatcher),
    Clause = {ArgsMatcher, RetSpec},
    {Ari, Clause}.

-spec find_matching_clause(Args::[any()], Defined::[func_clause()]) ->
        Matching::func_clause() | not_found.
find_matching_clause(Args, [{ArgsMatcher, RetSpec} | Rest]) ->
    case meck_args_matcher:match(Args, ArgsMatcher) of
        true ->
            {ArgsMatcher, RetSpec};
        _Else ->
            find_matching_clause(Args, Rest)
    end;
find_matching_clause(_Args, []) ->
    not_found.
