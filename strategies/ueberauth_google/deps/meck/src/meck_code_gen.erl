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
%%% @doc Implements code generation for mocked module and also contains code
%%% pieces that are called in the generated module context.
-module(meck_code_gen).

%% API
-export([to_forms/2]).
-export([get_current_call/0]).

%% Exported to be accessible from generated modules.
-export([exec/4]).

-include("meck.hrl").

%%%============================================================================
%%% Definitions
%%%============================================================================

-define(CURRENT_CALL, '$meck_call').
-define(call(Module, Function, Arguments),
        {call, ?LINE,
         {remote, ?LINE, ?atom(Module), ?atom(Function)},
         Arguments}).

-define(atom(Atom), {atom, ?LINE, Atom}).
-define(integer(Integer), {integer, ?LINE, Integer}).
-define(var(Name), {var, ?LINE, Name}).
-define(attribute(Attribute, Args), {attribute, ?LINE, Attribute, Args}).
-define(function(Name, Arity, Clauses),
        {function, ?LINE, Name, Arity, Clauses}).
-define(clause(Arguments, Body), {clause, ?LINE, Arguments, [], Body}).
-define(tuple(Elements), {tuple, ?LINE, Elements}).

%%%============================================================================
%%% API
%%%============================================================================

to_forms(Mod, Expects) ->
    {Exports, Functions} = functions(Mod, Expects),
    [?attribute(module, Mod)] ++ attributes(Mod) ++ Exports ++ Functions.

-spec get_current_call() -> {Mod::atom(), Func::atom()}.
get_current_call() ->
    get(?CURRENT_CALL).

%%%============================================================================
%%% Internal functions
%%%============================================================================

attribute({Key, _Value}, Attrs)
    when Key =:= vsn;
         Key =:= deprecated;
         Key =:= optional_callbacks;
     Key =:= dialyzer ->
    Attrs;
attribute({Key, Value}, Attrs)
  when (Key =:= behaviour orelse Key =:= behavior)
       andalso is_list(Value) ->
    lists:foldl(fun(Behavior, Acc) -> [?attribute(Key, Behavior) | Acc] end,
                Attrs, Value);
attribute({Key, Value}, Attrs) ->
    [?attribute(Key, Value) | Attrs].

attributes(Mod) ->
    try
        lists:foldl(fun attribute/2, [],
                    proplists:get_value(attributes, Mod:module_info(), []))
    catch
        error:undef -> []
    end.

functions(Mod, Expects) ->
    dict:fold(fun(Export, Expect, {Exports, Functions}) ->
        {[?attribute(export, [Export]) | Exports],
         [func(Mod, Export, Expect) | Functions]}
              end,
              {[], []},
              Expects).

func(Mod, {Func, Arity}, {anon, Arity, Result}) ->
    case contains_opaque(Result) of
        true ->
            func_exec(Mod, Func, Arity);
        false ->
            func_native(Mod, Func, Arity, Result)
    end;
func(Mod, {Func, Arity}, _Expect) ->
    func_exec(Mod, Func, Arity).

func_exec(Mod, Func, Arity) ->
    Args = args(Arity),
    ?function(Func, Arity,
              [?clause(Args,
                       [?call(?MODULE, exec,
                              [?call(erlang, self, []),
                               ?atom(Mod),
                               ?atom(Func),
                               list(Args)])])]).

func_native(Mod, Func, Arity, Result) ->
    Args = args(Arity),
    AbsResult = erl_parse:abstract(Result),
    ?function(
            Func, Arity,
            [?clause(
                    Args,
                    [?call(gen_server, cast,
                           [?atom(meck_util:proc_name(Mod)),
                            ?tuple([?atom(add_history),
                                    ?tuple([?call(erlang, self, []),
                                            ?tuple([?atom(Mod), ?atom(Func),
                                                    list(Args)]),
                                            AbsResult])])]),
                     AbsResult])]).

contains_opaque(Term) when is_pid(Term); is_port(Term); is_function(Term);
    is_reference(Term) ->
    true;
contains_opaque(Term) when is_list(Term) ->
    lists_any(fun contains_opaque/1, Term);
contains_opaque(Term) when is_tuple(Term) ->
    lists_any(fun contains_opaque/1, tuple_to_list(Term));
contains_opaque(_Term) ->
    false.

%% based on lists.erl but accepts improper lists.
lists_any(Pred, []) when is_function(Pred, 1) -> false;
lists_any(Pred, [Hd|Tail]) ->
    case Pred(Hd) of
        true -> true;
        false -> lists_any(Pred, Tail)
    end;
lists_any(Pred, Improper) ->
    Pred(Improper).

args(0)     -> [];
args(Arity) -> [?var(var_name(N)) || N <- lists:seq(1, Arity)].

list([])    -> {nil, ?LINE};
list([H|T]) -> {cons, ?LINE, H, list(T)}.

var_name(A) -> list_to_atom("A"++integer_to_list(A)).

%% @hidden
-spec exec(CallerPid::pid(), Mod::atom(), Func::atom(), Args::[any()]) ->
        Result::any().
exec(Pid, Mod, Func, Args) ->
    try meck_proc:get_result_spec(Mod, Func, Args) of
        undefined ->
            meck_proc:invalidate(Mod),
            raise(Pid, Mod, Func, Args, error, function_clause, []);
        ResultSpec ->
            eval(Pid, Mod, Func, Args, ResultSpec)
    catch
        error:{not_mocked, Mod} ->
            apply(Mod, Func, Args)
    end.

-spec eval(Pid::pid(), Mod::atom(), Func::atom(), Args::[any()],
           ResultSpec::any()) -> Result::any() | no_return().
eval(Pid, Mod, Func, Args, ResultSpec) ->
    put(?CURRENT_CALL, {Mod, Func}),
    try
        Result = meck_ret_spec:eval_result(Mod, Func, Args, ResultSpec),
        meck_proc:add_history(Mod, Pid, Func, Args, Result),
        Result
    catch
        ?_exception_(Class, Reason, StackToken) ->
            handle_exception(Pid, Mod, Func, Args,
                             Class, Reason, ?_get_stacktrace_(StackToken))
    after
        erase(?CURRENT_CALL)
    end.

-spec handle_exception(CallerPid::pid(), Mod::atom(), Func::atom(),
                       Args::[any()], Class:: exit | error | throw,
                       Reason::any(),
                       Stack::meck_history:stack_trace()) ->
        no_return().
handle_exception(Pid, Mod, Func, Args, Class, Reason, Stack) ->
    case meck_ret_spec:is_meck_exception(Reason) of
        {true, MockedClass, MockedReason} ->
            raise(Pid, Mod, Func, Args, MockedClass, MockedReason, Stack);
        _ ->
            meck_proc:invalidate(Mod),
            raise(Pid, Mod, Func, Args, Class, Reason, Stack)
    end.

-spec raise(CallerPid::pid(), Mod::atom(), Func::atom(), Args::[any()],
            Class:: exit | error | throw, Reason::any(), Stack::meck_history:stack_trace()) ->
        no_return().
raise(Pid, Mod, Func, Args, Class, Reason, Stack) ->
    StackTrace = inject(Mod, Func, Args, Stack),
    meck_proc:add_history_exception(Mod, Pid, Func, Args,
                                    {Class, Reason, StackTrace}),
    erlang:raise(Class, Reason, StackTrace).

-dialyzer({no_match, inject/4}). % for meck_history:stack_trace in older Erlang/OTP versions
-spec inject(Mod::atom(), Func::atom(), Args::[any()],
             meck_history:stack_trace()) ->
        NewStackTrace::meck_history:stack_trace().
inject(Mod, Func, Args, []) ->
    [{Mod, Func, Args}];
inject(Mod, Func, Args, [{?MODULE, exec, _AriOrArgs, _Loc}|Stack]) ->
    [{Mod, Func, Args} | Stack];
inject(Mod, Func, Args, [{?MODULE, exec, _AriOrArgs}|Stack]) ->
    [{Mod, Func, Args} | Stack];
inject(Mod, Func, Args, [Call|Stack]) when element(1, Call) == ?MODULE ->
    inject(Mod, Func, Args, Stack);
inject(Mod, Func, Args, [H | Stack]) ->
    [H | inject(Mod, Func, Args, Stack)].
