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

%%% @hidden
%%% @doc Implements a gen_server that maintains the state of a mocked module.
%%% The state includes function stubs, call history, etc. Meck starts one such
%%% process per mocked module.
-module(meck_proc).
-behaviour(gen_server).

%% API
-export([start/2]).
-export([set_expect/2]).
-export([delete_expect/4]).
-export([list_expects/2]).
-export([get_history/1]).
-export([wait/6]).
-export([reset/1]).
-export([validate/1]).
-export([stop/1]).

%% To be accessible from generated modules
-export([get_result_spec/3]).
-export([add_history_exception/5]).
-export([add_history/5]).
-export([invalidate/1]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%%%============================================================================
%%% Definitions
%%%============================================================================

-type meck_dict() :: dict:dict().

-record(state, {mod :: atom(),
                can_expect :: any | [{Mod::atom(), Ari::byte()}],
                expects :: meck_dict(),
                valid = true :: boolean(),
                history = [] :: meck_history:history() | undefined,
                original :: term(),
                was_sticky = false :: boolean(),
                merge_expects = false :: boolean(),
                passthrough = false :: boolean(),
                reload :: {Compiler::pid(), {From::pid(), Tag::any()}} |
                          undefined,
                trackers = [] :: [tracker()]}).

-record(tracker, {opt_func :: '_' | atom(),
                  args_matcher :: meck_args_matcher:args_matcher(),
                  opt_caller_pid :: '_' | pid(),
                  countdown :: non_neg_integer(),
                  reply_to :: {Caller::pid(), Tag::any()},
                  expire_at :: erlang:timestamp()}).

%%%============================================================================
%%% Types
%%%============================================================================

-type tracker() :: #tracker{}.

%%%============================================================================
%%% API
%%%============================================================================

-spec start(Mod::atom(), Options::[proplists:property()]) -> ok | no_return().
start(Mod, Options) ->
    StartFunc = case proplists:is_defined(no_link, Options) of
                    true  -> start;
                    false -> start_link
                end,
    SpawnOpt = proplists:get_value(spawn_opt, Options, []),
    case gen_server:StartFunc({local, meck_util:proc_name(Mod)}, ?MODULE,
                              [Mod, Options], [{spawn_opt, SpawnOpt}]) of
        {ok, _Pid}      -> ok;
        {error, Reason} -> erlang:error(Reason, [Mod, Options])
    end.

-spec get_result_spec(Mod::atom(), Func::atom(), Args::[any()]) ->
        meck_ret_spec:result_spec() | undefined.
get_result_spec(Mod, Func, Args) ->
    gen_server(call, Mod, {get_result_spec, Func, Args}).

-spec set_expect(Mod::atom(), meck_expect:expect()) ->
        ok | {error, Reason::any()}.
set_expect(Mod, Expect) ->
    Proc = meck_util:proc_name(Mod),
    try
        gen_server:call(Proc, {set_expect, Expect})
    catch
        exit:{noproc, _Details} ->
            Options = [Mod, [passthrough]],
            case gen_server:start({local, Proc}, ?MODULE, Options, []) of
                {ok, Pid} ->
                    Result = gen_server:call(Proc, {set_expect, Expect}),
                    true = erlang:link(Pid),
                    Result;
                {error, {{undefined_module, Mod}, _StackTrace}} ->
                    erlang:error({not_mocked, Mod})
            end
    end.

-spec delete_expect(Mod::atom(), Func::atom(), Ari::byte(), Force::boolean()) -> ok.
delete_expect(Mod, Func, Ari, Force) ->
    gen_server(call, Mod, {delete_expect, Func, Ari, Force}).

-spec list_expects(Mod::atom(), ExcludePassthrough::boolean()) ->
    [{Mod::atom(), Func::atom(), Ari::byte()}].
list_expects(Mod, ExcludePassthrough) ->
    gen_server(call, Mod, {list_expects, ExcludePassthrough}).

-spec add_history_exception(
        Mod::atom(), CallerPid::pid(), Func::atom(), Args::[any()],
        {Class::error|exit|throw, Reason::any(), StackTrace::any()}) ->
        ok.
add_history_exception(Mod, CallerPid, Func, Args, {Class, Reason, StackTrace}) ->
    gen_server(cast, Mod, {add_history, {CallerPid, {Mod, Func, Args}, Class, Reason, StackTrace}}).

-spec add_history(Mod::atom(), CallerPid::pid(), Func::atom(), Args::[any()],
                  Result::any()) ->
        ok.
add_history(Mod, CallerPid, Func, Args, Result) ->
    gen_server(cast, Mod, {add_history, {CallerPid, {Mod, Func, Args}, Result}}).

-spec get_history(Mod::atom()) -> meck_history:history().
get_history(Mod) ->
    gen_server(call, Mod, get_history).

-spec wait(Mod::atom(),
           Times::non_neg_integer(),
           OptFunc::'_' | atom(),
           meck_args_matcher:args_matcher(),
           OptCallerPid::'_' | pid(),
           Timeout::non_neg_integer()) ->
        ok.
wait(Mod, Times, OptFunc, ArgsMatcher, OptCallerPid, Timeout) ->
    EffectiveTimeout = case Timeout of
                           0 ->
                               infinity;
                           _Else ->
                               Timeout
                       end,
    Name = meck_util:proc_name(Mod),
    try gen_server:call(Name, {wait, Times, OptFunc, ArgsMatcher, OptCallerPid,
                               Timeout},
                        EffectiveTimeout)
    of
        ok ->
            ok;
        {error, timeout} ->
            erlang:error(timeout)
    catch
        exit:{timeout, _Details} ->
            erlang:error(timeout);
        exit:_Reason ->
            erlang:error({not_mocked, Mod})
    end.

-spec reset(Mod::atom()) -> ok.
reset(Mod) ->
    gen_server(call, Mod, reset).

-spec validate(Mod::atom()) -> boolean().
validate(Mod) ->
    gen_server(call, Mod, validate).

-spec invalidate(Mod::atom()) -> ok.
invalidate(Mod) ->
    gen_server(cast, Mod, invalidate).

-spec stop(Mod::atom()) -> ok.
stop(Mod) ->
    gen_server(call, Mod, stop).

%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

%% @hidden
validate_options([]) -> ok;
validate_options([no_link|Options]) -> validate_options(Options);
validate_options([spawn_opt|Options]) -> validate_options(Options);
validate_options([unstick|Options]) -> validate_options(Options);
validate_options([no_passthrough_cover|Options]) -> validate_options(Options);
validate_options([merge_expects|Options]) -> validate_options(Options);
validate_options([enable_on_load|Options]) -> validate_options(Options);
validate_options([passthrough|Options]) -> validate_options(Options);
validate_options([no_history|Options]) -> validate_options(Options);
validate_options([non_strict|Options]) -> validate_options(Options);
validate_options([stub_all|Options]) -> validate_options(Options);
validate_options([{stub_all, _}|Options]) -> validate_options(Options);
validate_options([UnknownOption|_]) -> erlang:error({bad_arg, UnknownOption}).

%% @hidden
init([Mod, Options]) ->
    validate_options(Options),
    Exports = normal_exports(Mod),
    WasSticky = case proplists:get_bool(unstick, Options) of
        true -> {module, Mod} = code:ensure_loaded(Mod),
            unstick_original(Mod);
        _    -> false
    end,
    NoPassCover = proplists:get_bool(no_passthrough_cover, Options),
    MergeExpects = proplists:get_bool(merge_expects, Options),
    EnableOnLoad = proplists:get_bool(enable_on_load, Options),
    Passthrough = proplists:get_bool(passthrough, Options),
    Original = backup_original(Mod, Passthrough, NoPassCover, EnableOnLoad),
    NoHistory = proplists:get_bool(no_history, Options),
    History = if NoHistory -> undefined; true -> [] end,
    CanExpect = resolve_can_expect(Mod, Exports, Options),
    Expects = init_expects(Exports, Options),
    process_flag(trap_exit, true),
    try
        Forms = meck_code_gen:to_forms(Mod, Expects),
        _Bin = meck_code:compile_and_load_forms(Forms),
        {ok, #state{mod = Mod,
                    can_expect = CanExpect,
                    expects = Expects,
                    original = Original,
                    was_sticky = WasSticky,
                    merge_expects = MergeExpects,
                    passthrough = Passthrough,
                    history = History}}
    catch
        exit:{error_loading_module, Mod, sticky_directory} ->
            {stop, {module_is_sticky, Mod}}
    end.

%% @hidden
handle_call({get_result_spec, Func, Args}, _From, S) ->
    {ResultSpec, NewExpects} = do_get_result_spec(S#state.expects, Func, Args),
    {reply, ResultSpec, S#state{expects = NewExpects}};
handle_call({set_expect, Expect}, From,
            S = #state{mod = Mod, expects = Expects, passthrough = Passthrough,
                       merge_expects = MergeExpects, can_expect = CanExpect}) ->
    check_if_being_reloaded(S),
    FuncAri = {Func, Ari} = meck_expect:func_ari(Expect),
    case validate_expect(Mod, Func, Ari, S#state.can_expect) of
        ok ->
            case store_expect(Mod, FuncAri, Expect, Expects,
                              MergeExpects, Passthrough, CanExpect) of
                {no_compile, NewExpects} ->
                    {reply, ok, S#state{expects = NewExpects}};
                {CompilerPid, NewExpects} ->
                    {noreply, S#state{expects = NewExpects,
                                      reload = {CompilerPid, From}}}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end;
handle_call({delete_expect, Func, Ari, Force}, From,
            S = #state{mod = Mod, expects = Expects,
                       passthrough = PassThrough, can_expect = CanExpect}) ->
    check_if_being_reloaded(S),
    ErasePassThrough = Force orelse (not PassThrough),
    case do_delete_expect(Mod, {Func, Ari}, Expects, ErasePassThrough,
                          PassThrough, CanExpect) of
        {no_compile, NewExpects} ->
            {reply, ok, S#state{expects = NewExpects}};
        {CompilerPid, NewExpects} ->
            {noreply, S#state{expects = NewExpects, reload = {CompilerPid, From}}}
    end;
handle_call({list_expects, ExcludePassthrough}, _From, S = #state{mod = Mod, expects = Expects}) ->
    Result =
        case ExcludePassthrough of
            false ->
                [{Mod, Func, Ari} || {Func, Ari} <- dict:fetch_keys(Expects)];
            true ->
                [{Mod, Func, Ari} ||
                    {{Func, Ari}, Expect} <- dict:to_list(Expects),
                    not meck_expect:is_passthrough(Expect)]
        end,
    {reply, Result, S};
handle_call(get_history, _From, S = #state{history = undefined}) ->
    {reply, [], S};
handle_call(get_history, _From, S) ->
    {reply, lists:reverse(S#state.history), S};
handle_call({wait, Times, OptFunc, ArgsMatcher, OptCallerPid, Timeout}, From,
            S = #state{history = History, trackers = Trackers}) ->
    case times_called(OptFunc, ArgsMatcher, OptCallerPid, History) of
        CalledSoFar when CalledSoFar >= Times ->
            {reply, ok, S};
        _CalledSoFar when Timeout =:= 0 ->
            {reply, {error, timeout}, S};
        CalledSoFar ->
            Tracker = #tracker{opt_func = OptFunc,
                               args_matcher = ArgsMatcher,
                               opt_caller_pid = OptCallerPid,
                               countdown = Times - CalledSoFar,
                               reply_to = From,
                               expire_at = timeout_to_timestamp(Timeout)},
            {noreply, S#state{trackers = [Tracker | Trackers]}}
    end;
handle_call(reset, _From, S) ->
    {reply, ok, S#state{history = []}};
handle_call(validate, _From, S) ->
    {reply, S#state.valid, S};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S}.

%% @hidden
handle_cast(invalidate, S) ->
    {noreply, S#state{valid = false}};
handle_cast({add_history, HistoryRecord}, S = #state{history = undefined,
                                                     trackers = Trackers}) ->
    UpdTrackers = update_trackers(HistoryRecord, Trackers),
    {noreply, S#state{trackers = UpdTrackers}};
handle_cast({add_history, HistoryRecord}, S = #state{history = History,
                                                     trackers = Trackers}) ->
    UpdTrackers = update_trackers(HistoryRecord, Trackers),
    {noreply, S#state{history = [HistoryRecord | History],
                      trackers = UpdTrackers}};
handle_cast(_Msg, S)  ->
    {noreply, S}.

%% @hidden
handle_info({'EXIT', Pid, _Reason}, S = #state{reload = Reload}) ->
    case Reload of
        {Pid, From} ->
            gen_server:reply(From, ok),
            {noreply, S#state{reload = undefined}};
        _ ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%% @hidden
terminate(_Reason, #state{mod = Mod, original = OriginalState,
                          was_sticky = WasSticky}) ->
    BackupCover = export_original_cover(Mod, OriginalState),
    cleanup(Mod),
    restore_original(Mod, OriginalState, WasSticky, BackupCover),
    ok.

%% @hidden
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%%%============================================================================
%%% Internal functions
%%%============================================================================

-spec normal_exports(Mod::atom()) -> [meck_expect:func_ari()] | undefined.
normal_exports(Mod) ->
    try
        [FuncAri || FuncAri = {Func, Ari} <- Mod:module_info(exports),
            normal == expect_type(Mod, Func, Ari)]
    catch
        error:undef -> undefined
    end.

-spec expect_type(Mod::atom(), Func::atom(), Ari::byte()) ->
        autogenerated | builtin | normal.
expect_type(_, module_info, 0) -> autogenerated;
expect_type(_, module_info, 1) -> autogenerated;
expect_type(Mod, Func, Ari) ->
    case erlang:is_builtin(Mod, Func, Ari) of
        true -> builtin;
        false -> normal
    end.

-spec backup_original(Mod::atom(), Passthrough::boolean(), NoPassCover::boolean(), EnableOnLoad::boolean()) ->
    {Cover:: false |
             {File::string(), Data::string(), CompiledOptions::[any()]},
     Binary:: no_binary |
              no_passthrough_cover |
              binary()}.
backup_original(Mod, Passthrough, NoPassCover, EnableOnLoad) ->
    Cover = get_cover_state(Mod),
    try
        Forms0 = meck_code:abstract_code(meck_code:beam_file(Mod)),
        Forms = meck_code:enable_on_load(Forms0, EnableOnLoad),
        NewName = meck_util:original_name(Mod),
        CompileOpts = [debug_info | meck_code:compile_options(meck_code:beam_file(Mod))],
        Renamed = meck_code:rename_module(Forms, Mod, NewName),
        Binary = meck_code:compile_and_load_forms(Renamed, CompileOpts),

        %% At this point we care about `Binary' if and only if we want
        %% to recompile it to enable cover on the original module code
        %% so that we can still collect cover stats on functions that
        %% have not been mocked.  Below are the different values
        %% passed back along with `Cover'.
        %%
        %% `no_passthrough_cover' - there is no coverage on the
        %% original module OR passthrough coverage has been disabled
        %% via the `no_passthrough_cover' option
        %%
        %% `no_binary' - something went wrong while trying to compile
        %% the original module in `backup_original'
        %%
        %% Binary - a `binary()' of the compiled code for the original
        %% module that is being mocked, this needs to be passed around
        %% so that it can be passed to Cover later.  There is no way
        %% to use the code server to access this binary without first
        %% saving it to disk.  Instead, it's passed around as state.
        Binary2 = if
            (Cover == false) orelse NoPassCover ->
                no_passthrough_cover;
            true ->
                _ = meck_cover:compile_beam(NewName, Binary),
                Binary
        end,
        {Cover, Binary2}
    catch
        throw:{object_code_not_found, _Module} ->
            {Cover, no_binary}; % TODO: What to do here?
        throw:no_abstract_code ->
            case Passthrough of
                true  -> exit({abstract_code_not_found, Mod});
                false -> {Cover, no_binary}
            end
    end.

-spec get_cover_state(Mod::atom()) ->
        {File::string(), Data::string(), CompileOptions::[any()]} | false.
get_cover_state(Mod) ->
    case cover:is_compiled(Mod) of
        {file, File} ->
            OriginalCover = meck_cover:dump_coverdata(Mod),
            CompileOptions =
            try
                meck_code:compile_options(meck_code:beam_file(Mod))
            catch
                throw:{object_code_not_found, _Module} -> []
            end,
            {File, OriginalCover, CompileOptions};
        _ ->
            false
    end.

-spec resolve_can_expect(Mod::atom(),
                         Exports::[meck_expect:func_ari()] | undefined,
                         Options::[proplists:property()]) ->
        any | [meck_expect:func_ari()].
resolve_can_expect(Mod, Exports, Options) ->
    NonStrict = proplists:get_bool(non_strict, Options),
    case {Exports, NonStrict} of
        {_, true}      -> any;
        {undefined, _} -> erlang:error({undefined_module, Mod});
        _              -> Exports
    end.

-spec init_expects(Exports::[meck_expect:func_ari()] | undefined,
                   Options::[proplists:property()]) ->
        meck_dict().
init_expects(Exports, Options) ->
    Passthrough = proplists:get_bool(passthrough, Options),
    StubAll = proplists:is_defined(stub_all, Options),
    Expects = case Exports of
                  undefined ->
                      [];
                  Exports when Passthrough ->
                      [meck_expect:new_passthrough(FuncArity) ||
                          FuncArity <- Exports];
                  Exports when StubAll ->
                      StubRet = case lists:keyfind(stub_all, 1, Options) of
                                    {stub_all, RetSpec} -> RetSpec;
                                    _ -> meck:val(ok)
                                end,
                      [meck_expect:new_dummy(FuncArity, StubRet) ||
                          FuncArity <- Exports];
                  Exports ->
                      []
              end,
    lists:foldl(fun(Expect, D) ->
                        dict:store(meck_expect:func_ari(Expect), Expect, D)
                end,
                dict:new(), Expects).

-spec gen_server(Method:: call | cast, Mod::atom(), Msg::tuple() | atom()) -> any().
gen_server(Func, Mod, Msg) ->
    Name = meck_util:proc_name(Mod),
    try gen_server:Func(Name, Msg)
    catch exit:_Reason -> erlang:error({not_mocked, Mod}) end.

-spec check_if_being_reloaded(#state{}) -> ok.
check_if_being_reloaded(#state{reload = undefined}) ->
    ok;
check_if_being_reloaded(#state{passthrough = true}) ->
    ok;
check_if_being_reloaded(_S) ->
    erlang:error(concurrent_reload).

-spec do_get_result_spec(Expects::meck_dict(), Func::atom(), Args::[any()]) ->
        {meck_ret_spec:result_spec() | undefined, NewExpects::meck_dict()}.
do_get_result_spec(Expects, Func, Args) ->
    FuncAri = {Func, erlang:length(Args)},
    Expect = dict:fetch(FuncAri, Expects),
    {ResultSpec, NewExpect} = meck_expect:fetch_result(Args, Expect),
    NewExpects = case NewExpect of
                     unchanged ->
                         Expects;
                     _ ->
                         dict:store(FuncAri, NewExpect, Expects)
                 end,
    {ResultSpec, NewExpects}.

-spec validate_expect(Mod::atom(), Func::atom(), Ari::byte(),
                      CanExpect::any | [meck_expect:func_ari()]) ->
        ok | {error, Reason::any()}.
validate_expect(Mod, Func, Ari, CanExpect) ->
    case expect_type(Mod, Func, Ari) of
        autogenerated ->
            {error, {cannot_mock_autogenerated, {Mod, Func, Ari}}};
        builtin ->
            {error, {cannot_mock_builtin, {Mod, Func, Ari}}};
        normal ->
            case CanExpect =:= any orelse lists:member({Func, Ari}, CanExpect) of
                true -> ok;
                _    -> {error, {undefined_function, {Mod, Func, Ari}}}
            end
    end.

-spec store_expect(Mod::atom(), meck_expect:func_ari(),
                   meck_expect:expect(), Expects::meck_dict(),
                   MergeExpects::boolean(), Passthrough::boolean(),
                   CanExpect::term()) ->
        {CompilerPidOrNoCompile::no_compile | pid(), NewExpects::meck_dict()}.
store_expect(Mod, FuncAri, Expect, Expects, true, PassThrough, CanExpect) ->
    NewExpects = case dict:is_key(FuncAri, Expects) of
        true ->
            {FuncAri, ExistingClauses} = dict:fetch(FuncAri, Expects),
            {FuncAri, NewClauses} = Expect,
            ToStore = case PassThrough of
                          false ->
                              ExistingClauses ++ NewClauses;
                          true ->
                              RevExistingClauses = lists:reverse(ExistingClauses),
                              [PassthroughClause | OldClauses] = RevExistingClauses,
                              lists:reverse(OldClauses,
                                            NewClauses ++ [PassthroughClause])
                      end,
            dict:store(FuncAri, {FuncAri, ToStore}, Expects);
        false -> dict:store(FuncAri, Expect, Expects)
    end,
    {compile_expects_if_needed(Mod, NewExpects, PassThrough, CanExpect),
     NewExpects};
store_expect(Mod, FuncAri, Expect, Expects, false, PassThrough, CanExpect) ->
    NewExpects =  dict:store(FuncAri, Expect, Expects),
    {compile_expects_if_needed(Mod, NewExpects, PassThrough, CanExpect),
     NewExpects}.

-spec do_delete_expect(Mod::atom(), meck_expect:func_ari(),
                       Expects::meck_dict(), ErasePassThrough::boolean(),
                       Passthrough::boolean(), CanExpect::term()) ->
        {CompilerPid::no_compile | pid(), NewExpects::meck_dict()}.
do_delete_expect(Mod, FuncAri, Expects, ErasePassThrough, Passthrough, CanExpect) ->
    NewExpects = case ErasePassThrough of
                     true  ->
                         dict:erase(FuncAri, Expects);
                     false ->
                         dict:store(FuncAri,
                                    meck_expect:new_passthrough(FuncAri),
                                    Expects)
                 end,
    {compile_expects_if_needed(Mod, NewExpects, Passthrough, CanExpect),
     NewExpects}.

-spec compile_expects_if_needed(Mod::atom(), Expects::meck_dict(),
                                Passthrough::boolean(), CanExpect::term()) ->
        CompilerPidOrNoCompile::no_compile | pid().
compile_expects_if_needed(_Mod, _Expects, true, CanExpect) when CanExpect =/= any ->
    no_compile;
compile_expects_if_needed(Mod, Expects, _, _) ->
    compile_expects(Mod, Expects).

-spec compile_expects(Mod::atom(), Expects::meck_dict()) ->
        CompilerPid::pid().
compile_expects(Mod, Expects) ->
    %% If the recompilation is made by the server that executes a module
    %% no module that is called from meck_code:compile_and_load_forms/2
    %% can be mocked by meck.
    erlang:spawn_link(fun() ->
                              Forms = meck_code_gen:to_forms(Mod, Expects),
                              meck_code:compile_and_load_forms(Forms)
                      end).

restore_original(Mod, {false, _Bin}, WasSticky, _BackupCover) ->
    restick_original(Mod, WasSticky),
    ok;
restore_original(Mod, {{File, OriginalCover, Options}, _Bin}, WasSticky, BackupCover) ->
    {ok, Mod} = case filename:extension(File) of
                    ".erl" ->
                        cover:compile_module(File, Options);
                    ".beam" ->
                        cover:compile_beam(File)
                end,
    restick_original(Mod, WasSticky),
    if BackupCover =/= undefined ->
        %% Import the cover data for `<name>_meck_original' but since it was
        %% modified by `export_original_cover' it will count towards `<name>'.
        ok = cover:import(BackupCover),
        ok = file:delete(BackupCover);
    true -> ok
    end,
    ok = cover:import(OriginalCover),
    ok = file:delete(OriginalCover),
    ok.

%% @doc Export the cover data for `<name>_meck_original' and modify
%% the data so it can be imported under `<name>'.
export_original_cover(Mod, {_, Bin}) when is_binary(Bin) ->
    OriginalMod = meck_util:original_name(Mod),
    BackupCover = meck_cover:dump_coverdata(OriginalMod),
    ok = meck_cover:rename_module(BackupCover, Mod),
    BackupCover;
export_original_cover(_, _) ->
    undefined.

unstick_original(Module) -> unstick_original(Module, code:is_sticky(Module)).

unstick_original(Module, true) -> code:unstick_mod(Module);
unstick_original(_,_) -> false.

restick_original(Module, true) ->
    code:stick_mod(Module),
    {module, Module} = code:ensure_loaded(Module),
    ok;
restick_original(_,_) -> ok.

-spec cleanup(Mod::atom()) -> boolean().
cleanup(Mod) ->
    code:purge(Mod),
    code:delete(Mod),
    code:purge(meck_util:original_name(Mod)),
    code:delete(meck_util:original_name(Mod)).

-spec times_called(OptFunc::'_' | atom(),
                   meck_args_matcher:args_matcher(),
                   OptCallerPid::'_' | pid(),
                   meck_history:history()) ->
        non_neg_integer().
times_called(OptFunc, ArgsMatcher, OptCallerPid, History) ->
    Filter = meck_history:new_filter(OptCallerPid, OptFunc, ArgsMatcher),
    lists:foldl(fun(HistoryRec, Acc) ->
                        case Filter(HistoryRec) of
                            true ->
                                Acc + 1;
                            _Else ->
                                Acc
                        end
                end, 0, History).

-spec update_trackers(meck_history:history_record(), [tracker()]) ->
        UpdTracker::[tracker()].
update_trackers(HistoryRecord, Trackers) ->
    update_trackers(HistoryRecord, Trackers, []).

-spec update_trackers(meck_history:history_record(),
                      Trackers::[tracker()],
                      CheckedSoFar::[tracker()]) ->
        UpdTrackers::[tracker()].
update_trackers(_HistoryRecord, [], UpdatedSoFar) ->
    UpdatedSoFar;
update_trackers(HistoryRecord, [Tracker | Rest], UpdatedSoFar) ->
    CallerPid = erlang:element(1, HistoryRecord),
    {_Mod, Func, Args} = erlang:element(2, HistoryRecord),
    case update_tracker(Func, Args, CallerPid, Tracker) of
        expired ->
            update_trackers(HistoryRecord, Rest, UpdatedSoFar);
        UpdTracker ->
            update_trackers(HistoryRecord, Rest, [UpdTracker | UpdatedSoFar])
    end.


-spec update_tracker(Func::atom(), Args::[any()], Caller::pid(), tracker()) ->
        expired |
        (UpdTracker::tracker()).
update_tracker(Func, Args, CallerPid,
               #tracker{opt_func = OptFunc,
                        args_matcher = ArgsMatcher,
                        opt_caller_pid = OptCallerPid,
                        countdown = Countdown,
                        reply_to = ReplyTo,
                        expire_at = ExpireAt} = Tracker)
  when (OptFunc =:= '_' orelse Func =:= OptFunc) andalso
       (OptCallerPid =:= '_' orelse CallerPid =:= OptCallerPid) ->
    case meck_args_matcher:match(Args, ArgsMatcher) of
        false ->
            Tracker;
        true ->
            case is_expired(ExpireAt) of
                true ->
                    expired;
                false when Countdown == 1 ->
                    gen_server:reply(ReplyTo, ok),
                    expired;
                false ->
                    Tracker#tracker{countdown = Countdown - 1}
            end
    end;
update_tracker(_Func, _Args, _CallerPid, Tracker) ->
    Tracker.

-spec timeout_to_timestamp(Timeout::non_neg_integer()) -> erlang:timestamp().
timeout_to_timestamp(Timeout) ->
    {MacroSecs, Secs, MicroSecs} = os:timestamp(),
    MicroSecs2 = MicroSecs + Timeout * 1000,
    UpdMicroSecs = MicroSecs2 rem 1000000,
    Secs2 = Secs + MicroSecs2 div 1000000,
    UpdSecs = Secs2 rem 1000000,
    UpdMacroSecs = MacroSecs + Secs2 div 1000000,
    {UpdMacroSecs, UpdSecs, UpdMicroSecs}.

-spec is_expired(erlang:timestamp()) -> boolean().
is_expired({MacroSecs, Secs, MicroSecs}) ->
    {NowMacroSecs, NowSecs, NowMicroSecs} = os:timestamp(),
    ((NowMacroSecs > MacroSecs) orelse
     (NowMacroSecs == MacroSecs andalso NowSecs > Secs) orelse
     (NowMacroSecs == MacroSecs andalso NowSecs == Secs andalso
      NowMicroSecs > MicroSecs)).
