%%%============================================================================
%%% Copyright 2010-2017 Adam Lindberg, 2010-2011 Erlang Solutions Ltd
%%%
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

%%% @author Adam Lindberg <eproxus@gmail.com>
%%% @copyright 2010-2017 Adam Lindberg, 2010-2011 Erlang Solutions Ltd
%%% @doc Module mocking library for Erlang.

-module(meck).

%% API
-export_type([matcher/0]).
-export_type([args_spec/0]).
-export_type([ret_spec/0]).
-export_type([func_clause_spec/0]).

%% Interface exports
-export([new/1]).
-export([new/2]).
-export([expect/3]).
-export([expect/4]).
-export([sequence/4]).
-export([loop/4]).
-export([delete/3]).
-export([delete/4]).
-export([expects/1]).
-export([expects/2]).
-export([exception/2]).
-export([passthrough/1]).
-export([history/1]).
-export([history/2]).
-export([validate/1]).
-export([unload/0]).
-export([unload/1]).
-export([called/3]).
-export([called/4]).
-export([num_calls/3]).
-export([num_calls/4]).
-export([reset/1]).
-export([capture/5]).
-export([capture/6]).
-export([wait/4]).
-export([wait/5]).
-export([wait/6]).
-export([mocked/0]).

%% Syntactic sugar
-export([loop/1]).
-export([seq/1]).
-export([val/1]).
-export([raise/2]).
-export([passthrough/0]).
-export([exec/1]).
-export([is/1]).

%%%============================================================================
%%% Types
%%%============================================================================

-type meck_mfa() :: {Mod::atom(), Func::atom(), Args::[any()]}.
%% Module, function and arguments that the mock module got called with.

-type stack_trace() :: [{Mod::atom(), Func::atom(), AriOrArgs::byte()|[any()]} |
                        {Mod::atom(), Func::atom(), AriOrArgs::byte()|[any()],
                         Location::[{atom(), any()}]}].
%% Erlang stack trace.

-type history() :: [{CallerPid::pid(), meck_mfa(), Result::any()} |
                    {CallerPid::pid(), meck_mfa(), Class::throw|error|exit,
                     Reason::any(), stack_trace()}].
%% Represents a list of either successful function calls with a returned
%% result or function calls that resulted in an exception with a type,
%% reason and a stack trace. Each tuple begins with the pid of the process
%% that made the call to the function.

-opaque matcher() :: meck_matcher:matcher().
%% Matcher is an entity that is used to check that a particular value meets
%% some criteria. They are used in defining expectation where Erlang patterns
%% are not enough. E.g. to check that a numeric value is within bounds.
%% Instances of `matcher' can be created by {@link is/1} function from either a
%% predicate function or a hamcrest matcher. (see {@link is/1} for details).
%% An instance of this type may be specified in any or even all positions of an
%% {@link arg_spec()}.

-type args_spec() :: [any() | '_' | matcher()] | non_neg_integer().
%% Argument specification is used to specify argument patterns throughout Meck.
%% In particular it is used in definition of expectation clauses by
%% {@link expect/3}, {@link expect/4}, and by history digging functions
%% {@link num_called/3}, {@link called/3} to specify what arguments of a
%% function call of interest should look like.
%%
%% An argument specification can be given as a argument pattern list or
%% as a non-negative integer that represents function clause/call arity.
%%
%% If an argument specification is given as an argument pattern, then every
%% pattern element corresponds to a function argument at the respective
%% position. '_' is a wildcard that matches any value. In fact you can specify
%% atom wildcard '_' at any level in the value structure.
%% (E.g.: {1, [blah, {'_', "bar", 2} | '_'], 3}). It is also possible to use a
%% {@link matcher()} created by {@link is/1} in-place of a value pattern.
%%
%% If an argument specification is given by an arity, then it is equivalent to
%% a pattern based argument specification that consists solely of wildcards,
%% and has the length of arity (e.g.: 3 is equivalent to ['_', '_', '_']).

-type ret_spec() :: meck_ret_spec:ret_spec().
%% Opaque data structure that specifies a value or a set of values to be returned
%% by a mock stub function defined by either {@link expect/3} and {@link expect/4}.
%% Values of `ret_spec()' are constructed by {@link seq/1}, {@link loop/1},
%% {@link val/1}, {@link exec/1}, and {@link raise/2} functions. They are used
%% to specify return values in {@link expect/3} and {@link expect/4} functions,
%% and also as a parameter of the `stub_all' option of {@link new/2} function.
%%
%% Note that any Erlang term `X' is a valid `ret_spec()' equivalent to
%% `meck:val(X)'.

-type func_clause_spec() :: {args_spec(), ret_spec()}.
%% It is used in {@link expect/3} and {@link expect/4} to define a function
%% clause of complex multi-clause expectations.

%%%============================================================================
%%% Interface exports
%%%============================================================================

%% @equiv new(Mod, [])
-spec new(Mods) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom().
new(Mod) when is_atom(Mod) -> new(Mod, []);
new(Mod) when is_list(Mod) -> lists:foreach(fun new/1, Mod), ok.

%% @doc Creates new mocked module(s).
%%
%% This replaces the current version (if any) of the modules in `Mod'
%% with an empty module.
%%
%% Since this library is intended to use from test code, this
%% function links a process for each mock to the calling process.
%%
%% The valid options are:
%% <dl>
%%   <dt>`passthrough'</dt>
%%   <dd>Retains the original functions, if not mocked by meck. If used along
%%       with `stub_all' then `stub_all' is ignored.</dd>
%%
%%   <dt>`no_link'</dt>
%%   <dd>Does not link the meck process to the caller process (needed for using
%%       meck in rpc calls).</dd>
%%
%%   <dt>`unstick'</dt>
%%   <dd>Unstick the module to be mocked (e.g. needed for using meck with
%%       kernel and stdlib modules).</dd>
%%
%%   <dt>`no_passthrough_cover'</dt>
%%   <dd>If cover is enabled on the module to be mocked then meck will continue
%%       to capture coverage on passthrough calls. This option allows you to
%%       disable that feature if it causes problems.</dd>
%%
%%   <dt>`{spawn_opt, list()}'</dt>
%%   <dd>Specify Erlang process spawn options. Typically used to specify
%%       non-default, garbage collection options.</dd>
%%
%%   <dt>`no_history'</dt>
%%   <dd>Do not store history of meck calls.</dd>
%%
%%   <dt>`non_strict'</dt>
%%   <dd>A mock created with this option will allow setting expectations on
%%       functions that does not exist in the mocked module. With this
%%       option on it is even possible to mock non existing modules.</dd>
%%
%%   <dt>`{stub_all, '{@link ret_spec()}`}'</dt>
%%   <dd>Stubs all functions exported from the mocked module. The stubs will
%%       return whatever defined by {@link ret_spec()} regardless of arguments
%%       passed in. It is possible to specify this option as just `stub_all'
%%       then stubs will return atom `ok'. If used along with `passthrough'
%%       then `stub_all' is ignored. </dd>
%%
%%   <dt>`merge_expects'</dt>
%%   <dd>The expectations for the function/arity signature are merged with
%%       existing ones instead of replacing all of them each time an
%%       expectation is added. Expectations are added to the end of the
%%       function clause list, meaning that pattern matching will be performed
%%       in the order the expectations were added.</dd>
%% </dl>
%%
%% Possible exceptions:
%% <dl>
%%   <dt>`error:{undefined_module, Mod}'</dt>
%%   <dd>The module to be mocked does not exist. This error exists to prevent
%%       mocking of misspelled module names. To bypass this and create a new
%%       mocked module anyway, use the option `non_strict'.</dd>
%%   <dt>`error:{module_is_sticky, Mod}'</dt>
%%   <dd>The module to be mocked resides in a sticky directory. To unstick the
%%       module and mock it anyway, use the option `unstick'.</dd>
%%   <dt>`error:{abstract_code_not_found, Mod}'</dt>
%%   <dd>The option `passthrough' was used but the original module has no
%%       abstract code which can be called. Make sure the module is compiled
%%       with the compiler option `debug_info'.</dd>
%% </dl>

-spec new(Mods, Options) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Options :: [proplists:property()].
new(Mod, Options) when is_atom(Mod), is_list(Options) ->
    meck_proc:start(Mod, Options);
new(Mod, Options) when is_list(Mod) ->
    lists:foreach(fun(M) -> new(M, Options) end, Mod),
    ok.

%% @doc Add expectation for a function `Func' to the mocked modules `Mod'.
%%
%% An expectation is either of the following:
%% <dl>
%% <dt>`function()'</dt><dd>a stub function that is executed whenever the
%% function `Func' is called. The arity of `function()' identifies for which
%% particular `Func' variant an expectation is created for (that is, a function
%% with arity 2 will generate an expectation for `Func/2').</dd>
%% <dt>`['{@link func_clause_spec()}`]'</dt><dd>a list of {@link
%% arg_spec()}/{@link ret_spec()} pairs. Whenever the function `Func' is called
%% the arguments are matched against the {@link arg_spec()} in the list. As
%% soon as the first match is found then a value defined by the corresponding
%% {@link ret_spec()} is returned.</dd>
%% </dl>
%%
%% It affects the validation status of the mocked module(s). If an
%% expectation is called with the wrong number of arguments or invalid
%% arguments the mock module(s) is invalidated. It is also invalidated if
%% an unexpected exception occurs.
-spec expect(Mods, Func, Expectation) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      Expectation :: function() | [func_clause_spec()].
expect(Mod, Func, Expectation) when is_list(Mod) ->
    lists:foreach(fun(M) -> expect(M, Func, Expectation) end, Mod),
    ok;
expect(_Mod, _Func, []) ->
    erlang:error(empty_clause_list);
expect(Mod, Func, Expectation) when is_atom(Mod), is_atom(Func) ->
    Expect = meck_expect:new(Func, Expectation),
    check_expect_result(meck_proc:set_expect(Mod, Expect)).

%% @doc Adds an expectation with the supplied arity and return value.
%%
%% This creates an expectation that has the only clause {`ArgsSpec', `RetSpec'}.
%%
%% @equiv expect(Mod, Func, [{ArgsSpec, RetSpec}])
-spec expect(Mods, Func, ArgsSpec, RetSpec) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      ArgsSpec :: args_spec(),
      RetSpec :: ret_spec().
expect(Mod, Func, ArgsSpec, RetSpec) when is_list(Mod) ->
    lists:foreach(fun(M) -> expect(M, Func, ArgsSpec, RetSpec) end, Mod),
    ok;
expect(Mod, Func, ArgsSpec, RetSpec) when is_atom(Mod), is_atom(Func) ->
    Expect = meck_expect:new(Func, ArgsSpec, RetSpec),
    check_expect_result(meck_proc:set_expect(Mod, Expect)).

%% @equiv expect(Mod, Func, Ari, seq(Sequence))
%% @deprecated Please use {@link expect/3} or {@link expect/4} along with
%% {@link ret_spec()} generated by {@link seq/1}.
-spec sequence(Mods, Func, Ari, Sequence) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      Ari :: byte(),
      Sequence :: [any()].
sequence(Mod, Func, Ari, Sequence)
  when is_atom(Mod), is_atom(Func), is_integer(Ari), Ari >= 0 ->
    Expect = meck_expect:new(Func, Ari, meck_ret_spec:seq(Sequence)),
    check_expect_result(meck_proc:set_expect(Mod, Expect));
sequence(Mod, Func, Ari, Sequence) when is_list(Mod) ->
    lists:foreach(fun(M) -> sequence(M, Func, Ari, Sequence) end, Mod),
    ok.

%% @equiv expect(Mod, Func, Ari, loop(Loop))
%% @deprecated Please use {@link expect/3} or {@link expect/4} along with
%% {@link ret_spec()} generated by {@link loop/1}.
-spec loop(Mods, Func, Ari, Loop) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      Ari :: byte(),
      Loop :: [any()].
loop(Mod, Func, Ari, Loop)
  when is_atom(Mod), is_atom(Func), is_integer(Ari), Ari >= 0 ->
    Expect = meck_expect:new(Func, Ari, meck_ret_spec:loop(Loop)),
    check_expect_result(meck_proc:set_expect(Mod, Expect));
loop(Mod, Func, Ari, Loop) when is_list(Mod) ->
    lists:foreach(fun(M) -> loop(M, Func, Ari, Loop) end, Mod),
    ok.

%% @doc Deletes an expectation.
%%
%% Deletes the expectation for the function `Func' with the matching
%% arity `Arity'.
%% `Force' is a flag to delete the function even if it is passthrough.
-spec delete(Mods, Func, Ari, Force) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      Ari :: byte(),
      Force :: boolean().
delete(Mod, Func, Ari, Force)
  when is_atom(Mod), is_atom(Func), Ari >= 0 ->
    meck_proc:delete_expect(Mod, Func, Ari, Force);
delete(Mod, Func, Ari, Force) when is_list(Mod) ->
    lists:foreach(fun(M) -> delete(M, Func, Ari, Force) end, Mod),
    ok.

%% @doc Deletes an expectation.
%%
%% Deletes the expectation for the function `Func' with the matching
%% arity `Arity'.
%% If the mock has passthrough enabled, this function restores the
%% expectation to the original function. See {@link delete/4}.
-spec delete(Mods, Func, Ari) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      Ari :: byte().
delete(Mod, Func, Ari) ->
    delete(Mod, Func, Ari, false).

%% @doc Returns the list of expectations.
%%
%% Returns the list of MFAs that were replaced by expectations
%% If `ExcludePassthrough' is on, only expectations that are not
%% direct passthroughs are returned
-spec expects(Mods, ExcludePassthrough) -> [{Mod, Func, Ari}] when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      Ari :: byte(),
      ExcludePassthrough :: boolean().
expects(Mod, ExcludePassthrough) when is_atom(Mod) ->
    meck_proc:list_expects(Mod, ExcludePassthrough);
expects(Mods, ExcludePassthrough) when is_list(Mods) ->
    [Expect || Mod <- Mods, Expect <- expects(Mod, ExcludePassthrough)].

%% @doc Returns the list of expectations.
%%
%% Returns the list of MFAs that were replaced by expectations
-spec expects(Mods) -> [{Mod, Func, Ari}] when
      Mods :: Mod | [Mod],
      Mod :: atom(),
      Func :: atom(),
      Ari :: byte().
expects(Mod) ->
    expects(Mod, false).

%% @doc Throws an expected exception inside an expect fun.
%%
%% This exception will get thrown without invalidating the mocked
%% module. That is, the code using the mocked module is expected to
%% handle this exception.
%%
%% <em>Note: this code should only be used inside an expect fun.</em>
-spec exception(Class, Reason) -> no_return() when
      Class :: throw | error | exit,
      Reason :: any().
exception(Class, Reason) when Class == throw; Class == error; Class == exit ->
    erlang:throw(meck_ret_spec:raise(Class, Reason)).

%% @doc Calls the original function (if existing) inside an expectation fun.
%%
%% <em>Note: this code should only be used inside an expect fun.</em>
-spec passthrough(Args) -> Result when
      Args :: [any()],
      Result :: any().
passthrough(Args) when is_list(Args) ->
    {Mod, Func} = meck_code_gen:get_current_call(),
    erlang:apply(meck_util:original_name(Mod), Func, Args).

%% @doc Validate the state of the mock module(s).
%%
%% The function returns `true' if the mocked module(s) has been used
%% according to its expectations. It returns `false' if a call has
%% failed in some way. Reasons for failure are wrong number of
%% arguments or non-existing function (undef), wrong arguments
%% (function clause) or unexpected exceptions.
%%
%% Validation can detect:
%%
%% <ul>
%%   <li>When a function was called with the wrong argument types
%%       (`function_clause')</li>
%%   <li>When an exception was thrown</li>
%%   <li>When an exception was thrown and expected (via meck:exception/2),
%%       which still results in `true' being returned</li>
%% </ul>
%%
%% Validation cannot detect:
%%
%% <ul>
%%   <li>When you didn't call a function</li>
%%   <li>When you called a function with the wrong number of arguments
%%       (`undef')</li>
%%   <li>When you called an undefined function (`undef')</li>
%% </ul>
%%
%% The reason Meck cannot detect these cases is because of how it is implemented.
%% Meck replaces the module with a mock and a process that maintains the mock.
%% Everything Meck get goes through that mock module. Meck does not insert
%% itself at the caller level (i.e. in your module or in your test case), so it
%% cannot know that you failed to call a module.
%%
%% Use the {@link history/1} or {@link history/2} function to analyze errors.
-spec validate(Mods) -> boolean() when
      Mods :: Mod | [Mod],
      Mod :: atom().
validate(Mod) when is_atom(Mod) ->
    meck_proc:validate(Mod);
validate(Mod) when is_list(Mod) ->
    not lists:member(false, [validate(M) || M <- Mod]).

%% @doc Return the call history of the mocked module for all processes.
%%
%% @equiv history(Mod, '_')
-spec history(Mod) -> history() when
      Mod :: atom().
history(Mod) when is_atom(Mod) -> meck_history:get_history('_', Mod).

%% @doc Return the call history of the mocked module for the specified process.
%%
%% Returns a list of calls to the mocked module and their results for
%% the specified `Pid'.  Results can be either normal Erlang terms or
%% exceptions that occurred.
%%
%% @see history/1
%% @see called/3
%% @see called/4
%% @see num_calls/3
%% @see num_calls/4
-spec history(Mod, OptCallerPid) -> history() when
      Mod :: atom(),
      OptCallerPid :: '_' | pid().
history(Mod, OptCallerPid)
  when is_atom(Mod), is_pid(OptCallerPid) orelse OptCallerPid == '_' ->
    meck_history:get_history(OptCallerPid, Mod).

%% @doc Unloads all mocked modules from memory.
%%
%% The function returns the list of mocked modules that were unloaded
%% in the process.
-spec unload() -> Unloaded when
      Unloaded :: [Mod],
      Mod :: atom().
unload() ->
    fold_mocks(fun(Mod, Acc) ->
        try
            unload(Mod),
            [Mod | Acc]
        catch error:{not_mocked, Mod} ->
            Acc
        end
    end, []).

%% @doc Unload a mocked module or a list of mocked modules.
%%
%% This will purge and delete the module(s) from the Erlang virtual
%% machine. If the mocked module(s) replaced an existing module, this
%% module will still be in the Erlang load path and can be loaded
%% manually or when called.
-spec unload(Mods) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom().
unload(Mod) when is_atom(Mod) ->
    meck_proc:stop(Mod),
    wait_for_exit(Mod);
unload(Mods) when is_list(Mods) ->
    lists:foreach(fun unload/1, Mods), ok.

%% @doc Returns whether `Mod:Func' has been called with `Args'.
%%
%% @equiv called(Mod, Fun, Args, '_')
-spec called(Mod, OptFun, OptArgsSpec) -> boolean() when
      Mod :: atom(),
      OptFun :: '_' | atom(),
      OptArgsSpec :: '_' | args_spec().
called(Mod, OptFun, OptArgsSpec) ->
    meck_history:num_calls('_', Mod, OptFun, OptArgsSpec) > 0.

%% @doc Returns whether `Pid' has called `Mod:Func' with `Args'.
%%
%% This will check the history for the module, `Mod', to determine
%% whether process `Pid' call the function, `Fun', with arguments, `Args'. If
%% so, this function returns true, otherwise false.
%%
%% Wildcards can be used, at any level in any term, by using the underscore
%% atom: ``'_' ''
%%
%% @see called/3
-spec called(Mod, OptFun, OptArgsSpec, OptCallerPid) -> boolean() when
      Mod :: atom(),
      OptFun :: '_' | atom(),
      OptArgsSpec :: '_' | args_spec(),
      OptCallerPid :: '_' | pid().
called(Mod, OptFun, OptArgsSpec, OptPid) ->
    meck_history:num_calls(OptPid, Mod, OptFun, OptArgsSpec) > 0.

%% @doc Returns the number of times `Mod:Func' has been called with `Args'.
%%
%% @equiv num_calls(Mod, Fun, Args, '_')
-spec num_calls(Mod, OptFun, OptArgsSpec) -> non_neg_integer() when
      Mod :: atom(),
      OptFun :: '_' | atom(),
      OptArgsSpec :: '_' | args_spec().
num_calls(Mod, OptFun, OptArgsSpec) ->
    meck_history:num_calls('_', Mod, OptFun, OptArgsSpec).

%% @doc Returns the number of times process `Pid' has called `Mod:Func'
%%      with `Args'.
%%
%% This will check the history for the module, `Mod', to determine how
%% many times process `Pid' has called the function, `Fun', with
%% arguments, `Args' and returns the result.
%%
%% @see num_calls/3
-spec num_calls(Mod, OptFun, OptArgsSpec, OptCallerPid) ->
        non_neg_integer() when
      Mod :: atom(),
      OptFun :: '_' | atom(),
      OptArgsSpec :: '_' | args_spec(),
      OptCallerPid :: '_' | pid().
num_calls(Mod, OptFun, OptArgsSpec, OptPid) ->
    meck_history:num_calls(OptPid, Mod, OptFun, OptArgsSpec).

%% @doc Blocks until either function `Mod:Func' is called at least once with
%% arguments matching `OptArgsSpec', or `Timeout' has elapsed. In the latter
%% case the call fails with `error:timeout'.
%%
%% The number of calls is counted starting from the most resent call to
%% {@link reset/1} on the mock or from the mock creation, whichever occurred
%% latter. If a matching call has already occurred, then the function returns
%% `ok' immediately.
%%
%% @equiv wait(1, Mod, OptFunc, OptArgsSpec, '_', Timeout)
-spec wait(Mod, OptFunc, OptArgsSpec, Timeout) -> ok when
      Mod :: atom(),
      OptFunc :: '_' | atom(),
      OptArgsSpec :: '_' | args_spec(),
      Timeout :: non_neg_integer().
wait(Mod, OptFunc, OptArgsSpec, Timeout) ->
    wait(1, Mod, OptFunc, OptArgsSpec, '_', Timeout).

%% @doc Blocks until either function `Mod:Func' is called at least `Times' with
%% arguments matching `OptArgsSpec', or `Timeout' has elapsed. In the latter
%% case the call fails with `error:timeout'.
%%
%% The number of calls is counted starting from the most resent call to
%% {@link reset/1} on the mock or from the mock creation, whichever occurred
%% latter. If `Times' number of matching calls has already occurred, then the
%% function returns `ok' immediately.
%%
%% @equiv wait(Times, Mod, OptFunc, OptArgsSpec, '_', Timeout)
-spec wait(Times, Mod, OptFunc, OptArgsSpec, Timeout) -> ok when
      Times :: pos_integer(),
      Mod :: atom(),
      OptFunc :: '_' | atom(),
      OptArgsSpec :: '_' | args_spec(),
      Timeout :: non_neg_integer().
wait(Times, Mod, OptFunc, OptArgsSpec, Timeout) ->
    wait(Times, Mod, OptFunc, OptArgsSpec, '_', Timeout).

%% @doc Blocks until either function `Mod:Func' is called at least `Times' with
%% arguments matching `OptArgsSpec' by process `OptCallerPid', or `Timeout' has
%% elapsed. In the latter case the call fails with `error:timeout'.
%%
%% The number of calls is counted starting from the most resent call to
%% {@link reset/1} on the mock or from the mock creation, whichever occurred
%% latter. If `Times' number of matching call has already occurred, then the
%% function returns `ok' immediately.
-spec wait(Times, Mod, OptFunc, OptArgsSpec, OptCallerPid, Timeout) -> ok when
      Times :: pos_integer(),
      Mod :: atom(),
      OptFunc :: '_' | atom(),
      OptArgsSpec :: '_' | args_spec(),
      OptCallerPid :: '_' | pid(),
      Timeout :: non_neg_integer().
wait(0, _Mod, _OptFunc, _OptArgsSpec, _OptCallerPid, _Timeout) ->
    ok;
wait(Times, Mod, OptFunc, OptArgsSpec, OptCallerPid, Timeout)
  when is_integer(Times) andalso Times > 0 andalso
       is_integer(Timeout) andalso Timeout >= 0 ->
    ArgsMatcher = meck_args_matcher:new(OptArgsSpec),
    meck_proc:wait(Mod, Times, OptFunc, ArgsMatcher, OptCallerPid, Timeout).

%% @doc Erases the call history for a mocked module or a list of mocked modules.
%%
%% This function will erase all calls made heretofore from the history of the
%% specified modules. It is intended to prevent cluttering of test results with
%% calls to mocked modules made during the test setup phase.
-spec reset(Mods) -> ok when
      Mods :: Mod | [Mod],
      Mod :: atom().
reset(Mod) when is_atom(Mod) ->
    meck_proc:reset(Mod);
reset(Mods) when is_list(Mods) ->
    lists:foreach(fun(Mod) -> reset(Mod) end, Mods).

%% @doc Converts a list of terms into {@link ret_spec()} defining a loop of
%% values. It is intended to be in construction of clause specs for the
%% {@link expect/3} function.
%%
%% Calls to an expect, created with {@link ret_spec()} returned by this function,
%% will return one element at a time from the `Loop' list and will restart at
%% the first element when the end is reached.
-spec loop(Loop) -> ret_spec() when
      Loop :: [ret_spec()].
loop(Loop) -> meck_ret_spec:loop(Loop).

%% @doc Converts a list of terms into {@link ret_spec()} defining a sequence of
%% values. It is intended to be in construction of clause specs for the
%% {@link expect/3} function.
%%
%% Calls to an expect, created with {@link ret_spec} returned by this function,
%% will exhaust the `Sequence' list of return values in order until the last
%% value is reached. That value is then returned for all subsequent calls.
-spec seq(Sequence) -> ret_spec() when
      Sequence :: [ret_spec()].
seq(Sequence) -> meck_ret_spec:seq(Sequence).

%% @doc Converts a term into {@link ret_spec()} defining an individual value.
%% It is intended to be in construction of clause specs for the
%% {@link expect/3} function.
-spec val(Value) -> ret_spec() when
      Value :: any().
val(Value) -> meck_ret_spec:val(Value).

%% @doc Creates a {@link ret_spec()} that defines an exception.
%%
%% Calls to an expect, created with {@link ret_spec()} returned by this function,
%% will raise the specified exception.
-spec raise(Class, Reason) -> ret_spec() when
      Class :: throw | error | exit,
      Reason :: term.
raise(Class, Reason) -> meck_ret_spec:raise(Class, Reason).

%% @doc Creates a {@link ret_spec()} that makes the original module function be
%% called.
%%
%% Calls to an expect, created with {@link ret_spec()} returned by this function,
%% will be forwarded to the original function.
-spec passthrough() -> ret_spec().
passthrough() -> meck_ret_spec:passthrough().

%% @doc Creates a {@link ret_spec()} from a function. Calls to an expect,
%% created with {@link ret_spec()} returned by this function, will be forwarded
%% to the specified function.
-spec exec(fun()) -> ret_spec().
exec(Fun) -> meck_ret_spec:exec(Fun).

%% @doc creates a {@link matcher/0} instance from either `Predicate' or
%% `HamcrestMatcher'.
%% <ul>
%% <li>`Predicate' - is a single parameter function. If it returns `true' then
%% the argument passed to it is considered as meeting the matcher criteria,
%% otherwise as not.</li>
%% <li>`HamcrestMatcher' - is a matcher created by
%% <a href="https://github.com/hyperthunk/hamcrest-erlang">Hamcrest-Erlang</a>
%% library</li>
%% </ul>
-spec is(MatcherImpl) -> matcher() when
      MatcherImpl :: Predicate | HamcrestMatcher,
      Predicate :: fun((any()) -> any()),
      HamcrestMatcher :: meck_matcher:hamcrest_matchspec().
is(MatcherImpl) ->
    meck_matcher:new(MatcherImpl).

%% @doc Returns the value of an argument as it was passed to a particular
%% function call made by a particular process. It fails with `not_found' error
%% if a function call of interest has never been made.
%%
%% It retrieves the value of argument at `ArgNum' position as it was passed
%% to function call `Mod:Func' with arguments that match `OptArgsSpec' made by
%% process `CallerPid' that occurred `Occur''th according to the call history.
%%
%% Atoms `first' and `last' can be used in place of the occurrence number to
%% retrieve the argument value passed when the function was called the first
%% or the last time respectively.
%%
%% If an occurrence of a function call irrespective of the calling process needs
%% to be captured then `_' might be passed as `OptCallerPid', but it is better
%% to use {@link capture/5} instead.
-spec capture(Occur, Mod, Func, OptArgsSpec, ArgNum, OptCallerPid) -> ArgValue when
      Occur :: first | last | pos_integer(),
      Mod :: atom(),
      Func :: atom(),
      OptArgsSpec :: '_' | args_spec(),
      ArgNum :: pos_integer(),
      OptCallerPid :: '_' | pid(),
      ArgValue :: any().
capture(Occur, Mod, Func, OptArgsSpec, ArgNum, OptCallerPid) ->
    meck_history:capture(Occur, OptCallerPid, Mod, Func, OptArgsSpec, ArgNum).

%% @doc Returns the value of an argument as it was passed to a particular
%% function call, It fails with `not_found' error if a function call of
%% interest has never been made.
%%
%% It retrieves the value of argument at `ArgNum' position as it was passed
%% to function call `Mod:Func' with arguments that match `OptArgsSpec' that
%% occurred `Occur''th according to the call history.
%%
%% Atoms `first' and `last' can be used in place of the occurrence number to
%% retrieve the argument value passed when the function was called the first
%% or the last time respectively.
%%
%% @equiv capture(Occur, Mod, Func, OptArgsSpec, ArgNum, '_')
-spec capture(Occur, Mod, Func, OptArgsSpec, ArgNum) -> ArgValue when
      Occur :: first | last | pos_integer(),
      Mod::atom(),
      Func::atom(),
      OptArgsSpec :: args_spec(),
      ArgNum :: pos_integer(),
      ArgValue :: any().
capture(Occur, Mod, Func, OptArgsSpec, ArgNum) ->
    meck_history:capture(Occur, '_', Mod, Func, OptArgsSpec, ArgNum).

%% @doc Returns the currently mocked modules.
-spec mocked() -> list(atom()).
mocked() ->
    fold_mocks(fun(M, Acc) -> [M | Acc] end, []).

%%%============================================================================
%%% Internal functions
%%%============================================================================

-spec wait_for_exit(Mod::atom()) -> ok.
wait_for_exit(Mod) ->
    MonitorRef = erlang:monitor(process, meck_util:proc_name(Mod)),
    receive {'DOWN', MonitorRef, _Type, _Object, _Info} -> ok end.

-spec fold_mocks(Fun, AccIn) -> AccOut when
    Fun :: fun((Elem :: module(), AccIn) -> AccOut),
    AccIn :: term(),
    AccOut :: term().
fold_mocks(Fun, Acc0) when is_function(Fun, 2) ->
    lists:foldl(fun(Mod, Acc)  ->
        ModName = atom_to_list(Mod),
        case lists:split(max(length(ModName) - 5, 0), ModName) of
            {Name, "_meck"} -> Fun(erlang:list_to_existing_atom(Name), Acc);
            _Else -> Acc
        end
    end, Acc0, erlang:registered()).

-spec check_expect_result(ok | {error, Reason::any()}) -> ok.
check_expect_result(ok) -> ok;
check_expect_result({error, Reason}) -> erlang:error(Reason).
