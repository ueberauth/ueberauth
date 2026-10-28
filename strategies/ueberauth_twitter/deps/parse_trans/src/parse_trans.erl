%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% --------------------------------------------------
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%% --------------------------------------------------
%% File    : parse_trans.erl
%% @author  : Ulf Wiger <ulf@wiger.net>
%% @end
%% Description :
%%
%% Created : 13 Feb 2006 by Ulf Wiger <ulf@wiger.net> (then Ericsson)
%%%-------------------------------------------------------------------

%% @doc Generic parse transform library for Erlang.
%%
%% <p>...</p>
%%
%% @end

-module(parse_trans).

-compile({no_auto_import,[error/3]}).

-export([plain_transform/2]).

-export([
         inspect/4,
         transform/4,
         depth_first/4,
         revert/1,
         revert_form/1,
         format_exception/2, format_exception/3,
         return/2
        ]).

-export([
         error/3,
         format_error/1
        ]).

-export([
         initial_context/2,
         do_inspect/4,
         do_transform/4,
         do_depth_first/4,
         top/3
        ]).

-export([do_insert_forms/4,
         replace_function/4,
         replace_function/5,
         export_function/3]).

-export([
         context/2,
         get_pos/1,
         get_file/1,
         get_module/1,
         get_attribute/2,
         get_attribute/3,
         get_orig_syntax_tree/1,
         function_exists/3,
         optionally_pretty_print/3,
         pp_src/2,
         pp_beam/1, pp_beam/2
        ]).

-import(erl_syntax, [atom_value/1,
                     attribute_name/1,
                     attribute_arguments/1,
                     string_value/1,
                     type/1
                    ]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(context, {module,
                  function,
                  arity,
                  file,
                  options}).

%% Useful macros for debugging and error reporting
-define(HERE, {?MODULE, ?LINE}).

-define(DUMMY_LINE, 9999).

-define(ERROR(R, F, I, Trace),
        begin
            rpt_error(R, F, I, Trace),
            throw({error,get_pos(I),{R, Trace}})
        end).

-export_type([forms/0]).

%% Typedefs
-type form()    :: any().
-type forms()   :: [form()].
-type options() :: [{atom(), any()}].
-type type()    :: atom().
-type xform_f_rec() :: fun((type(), form(), #context{}, Acc) ->
                                  {form(), boolean(), Acc}
                                      | {forms(), form(), forms(), boolean(), Acc}).
-type xform_f_df() :: fun((type(), form(), #context{}, Acc) ->
                                 {form(), Acc}
                                     | {forms(), form(), forms(), Acc}).
-type insp_f()  :: fun((type(), form(), #context{}, A) -> {boolean(), A}).


%%% @spec (Reason, Form, Info) -> throw()
%%% Info = [{Key,Value}]
%%%
%%% @doc
%%% <p>Used to report errors detected during the parse transform.</p>
%%% @end
%%%
-spec error(string(), any(), [{any(),any()}]) ->
    none().
error(R, _F, I) ->
    ST = erlang:process_info(self(), current_stacktrace),
    % rpt_error(R, F, I, ST),
    throw({error,get_pos(I),{R, ST}}).

%% @spec plain_transform(Fun, Forms) -> forms()
%% Fun = function()
%% Forms = forms()
%%
%% @doc
%% Performs a transform of `Forms' using the fun `Fun(Form)'. `Form' is always
%% an Erlang abstract form, i.e. it is not converted to syntax_tools
%% representation. The intention of this transform is for the fun to have a
%% catch-all clause returning `continue'. This will ensure that it stays robust
%% against additions to the language.
%%
%% `Fun(Form)' must return either of the following:
%%
%% * `NewForm' - any valid form
%% * `continue' - dig into the sub-expressions of the form
%% * `{done, NewForm}' - Replace `Form' with `NewForm'; return all following
%%   forms unchanged
%% * `{error, Reason}' - Abort transformation with an error message.
%%
%% Example - This transform fun would convert all instances of `P ! Msg' to
%% `gproc:send(P, Msg)':
%% <pre>
%% parse_transform(Forms, _Options) -&gt;
%%     parse_trans:plain_transform(fun do_transform/1, Forms).
%%
%% do_transform({'op', L, '!', Lhs, Rhs}) -&gt;
%%      [NewLhs] = parse_trans:plain_transform(fun do_transform/1, [Lhs]),
%%      [NewRhs] = parse_trans:plain_transform(fun do_transform/1, [Rhs]),
%%     {call, L, {remote, L, {atom, L, gproc}, {atom, L, send}},
%%      [NewLhs, NewRhs]};
%% do_transform(_) -&gt;
%%     continue.
%% </pre>
%% @end
%%
plain_transform(Fun, Forms) when is_function(Fun, 1), is_list(Forms) ->
    plain_transform1(Fun, Forms).

plain_transform1(_, []) ->
    [];
plain_transform1(Fun, [F|Fs]) when is_atom(element(1,F)) ->
    case Fun(F) of
        skip ->
            plain_transform1(Fun, Fs);
        continue ->
            [list_to_tuple(plain_transform1(Fun, tuple_to_list(F))) |
             plain_transform1(Fun, Fs)];
        {done, NewF} ->
            [NewF | Fs];
        {error, Reason} ->
            error(Reason, F, [{form, F}]);
        NewF when is_tuple(NewF) ->
            [NewF | plain_transform1(Fun, Fs)]
    end;
plain_transform1(Fun, [L|Fs]) when is_list(L) ->
    [plain_transform1(Fun, L) | plain_transform1(Fun, Fs)];
plain_transform1(Fun, [F|Fs]) ->
    [F | plain_transform1(Fun, Fs)];
plain_transform1(_, F) ->
    F.


%% @spec (list()) -> integer()
%%
%% @doc
%% Tries to retrieve the line number from an erl_syntax form. Returns a
%% (very high) dummy number if not successful.
%% @end
%%
-spec get_pos(list()) ->
    erl_anno:location().
get_pos(I) when is_list(I) ->
    case proplists:get_value(form, I) of
        undefined ->
            ?DUMMY_LINE;
        Form ->
            Anno = erl_syntax:get_pos(Form),
            erl_anno:location(Anno)
    end.


%%% @spec (Forms) -> string()
%%% @doc
%%% Returns the name of the file being compiled.
%%% @end
%%%
-spec get_file(forms()) ->
    string().
get_file(Forms) ->
    string_value(hd(get_attribute(file, Forms, [erl_syntax:string("undefined")]))).



%%% @spec (Forms) -> atom()
%%% @doc
%%% Returns the name of the module being compiled.
%%% @end
%%%
-spec get_module([any()]) ->
    atom().
get_module(Forms) ->
    atom_value(hd(get_attribute(module, Forms, [erl_syntax:atom(undefined)]))).



%%% @spec (A, Forms) -> any()
%%% A = atom()
%%%
%%% @doc
%%% Returns the value of the first occurrence of attribute A.
%%% @end
%%%
-spec get_attribute(atom(), [any()]) ->
                           'none' | [erl_syntax:syntaxTree()].
%%
get_attribute(A, Forms) -> get_attribute(A,Forms,[erl_syntax:atom(undefined)]).
get_attribute(A, Forms, Undef) ->
    case find_attribute(A, Forms) of
        false ->
            Undef;
        Other ->
            Other
    end.

find_attribute(A, [F|Forms]) ->
    case type(F) == attribute
        andalso atom_value(attribute_name(F)) == A of
        true ->
            attribute_arguments(F);
        false ->
            find_attribute(A, Forms)
    end;
find_attribute(_, []) ->
    false.

%% @spec (Fname::atom(), Arity::integer(), Forms) -> boolean()
%%
%% @doc
%% Checks whether the given function is defined in Forms.
%% @end
%%
-spec function_exists(atom(), integer(), forms()) ->
    boolean().
function_exists(Fname, Arity, Forms) ->
    Fns = proplists:get_value(
            functions, erl_syntax_lib:analyze_forms(Forms), []),
    lists:member({Fname,Arity}, Fns).


%%% @spec (Forms, Options) -> #context{}
%%%
%%% @doc
%%% Initializes a context record. When traversing through the form
%%% list, the context is updated to reflect the current function and
%%% arity. Static elements in the context are the file name, the module
%%% name and the options passed to the transform function.
%%% @end
%%%
-spec initial_context(forms(), options()) ->
    #context{}.
initial_context(Forms, Options) ->
    File = get_file(Forms),
    Module = get_module(Forms),
    #context{file = File,
             module = Module,
             options = Options}.

%%% @spec (Fun, Acc, Forms, Options) -> {TransformedForms, NewAcc}
%%% Fun = function()
%%% Options = [{Key,Value}]
%%%
%%% @doc
%%% Makes one pass
%%% @end
-spec transform(xform_f_rec(), Acc, forms(), options()) ->
    {forms(), Acc} | {error, list()}.
transform(Fun, Acc, Forms, Options) when is_function(Fun, 4) ->
    do(fun do_transform/4, Fun, Acc, Forms, Options).

-spec depth_first(xform_f_df(), Acc, forms(), options()) ->
    {forms(), Acc} | {error, list()}.
depth_first(Fun, Acc, Forms, Options) when is_function(Fun, 4) ->
    do(fun do_depth_first/4, Fun, Acc, Forms, Options).

do(Transform, Fun, Acc, Forms, Options) ->
    Context = initial_context(Forms, Options),
    File = Context#context.file,
    try Transform(Fun, Acc, Forms, Context) of
        {NewForms, Acc1} when is_list(NewForms) ->
            NewForms1 = optionally_renumber(NewForms, Options),
            optionally_pretty_print(NewForms1, Options, Context),
            {NewForms1, Acc1}
    catch
        error:Reason:ST ->
            {error,
             [{File, [{?DUMMY_LINE, ?MODULE,
                       {Reason, ST}}]}]};
        throw:{error, Ln, What} ->
            {error, [{error, {Ln, ?MODULE, What}}]}
    end.

-spec top(function(), forms(), list()) ->
    forms() | {error, term()}.
top(F, Forms, Options) ->
    Context = initial_context(Forms, Options),
    File = Context#context.file,
    try F(Forms, Context) of
        {error, Reason} -> {error, Reason};
        NewForms when is_list(NewForms) ->
            NewForms1 = optionally_renumber(NewForms, Options),
            optionally_pretty_print(NewForms1, Options, Context),
            NewForms1
    catch
        error:Reason:ST ->
            {error,
             [{File, [{?DUMMY_LINE, ?MODULE,
                       {Reason, ST}}]}]};
        throw:{error, Ln, What} ->
            {error, [{File, [{Ln, ?MODULE, What}]}], []}
    end.

replace_function(F, Arity, NewForm, Forms) ->
    replace_function(F, Arity, NewForm, Forms, []).

replace_function(F, Arity, NewForm, Forms, Opts) ->
    {NewForms, _} =
        do_transform(
          fun(function, Form, _Ctxt, Acc) ->
                  case erl_syntax:revert(Form) of
                      {function, _, F, Arity, _} = RevForm ->
                          {[], NewForm, with_original_f(RevForm, Opts),
                           false, Acc};
                      _ ->
                          {Form, false, Acc}
                  end;
             (_, Form, _Ctxt, Acc) ->
                  {Form, false, Acc}
          end, false, Forms, initial_context(Forms, [])),
    revert(maybe_export_renamed(NewForms, Arity, Opts)).

with_original_f({function,_,_,_,_} = Form, Opts) ->
    case lists:keyfind(rename_original, 1, Opts) of
        {_, NewName} when is_atom(NewName) ->
            [setelement(3, Form, NewName)];
        _ ->
            []
    end.

maybe_export_renamed(Forms, Arity, Opts) ->
    case lists:keyfind(rename_original, 1, Opts) of
        {_, NewName} when is_atom(NewName) ->
            export_function(NewName, Arity, Forms);
        _ ->
            Forms
    end.

export_function(F, Arity, Forms) ->
    do_insert_forms(above, [{attribute, 1, export, [{F, Arity}]}], Forms,
                    initial_context(Forms, [])).

-spec do_insert_forms(above | below, forms(), forms(), #context{}) ->
    forms().
do_insert_forms(above, Insert, Forms, Context) when is_list(Insert) ->
    {NewForms, _} =
        do_transform(
          fun(function, F, _Ctxt, false) ->
                  {Insert, F, [], _Recurse = false, true};
             (_, F, _Ctxt, Acc) ->
                  {F, _Recurse = false, Acc}
          end, false, Forms, Context),
    NewForms;
do_insert_forms(below, Insert, Forms, _Context) when is_list(Insert) ->
    insert_below(Forms, Insert).


insert_below([F|Rest], Insert) ->
    case type(F) of
        eof_marker ->
            %% In the unlikely case someone misused eof_marker
            Insert ++ [F | Rest];
        _ ->
            [F|insert_below(Rest, Insert)]
    end.

-spec optionally_pretty_print(forms(), options(), #context{}) ->
    ok.
optionally_pretty_print(Result, Options, Context) ->
    DoPP = option_value(pt_pp_src, Options, Result),
    DoLFs = option_value(pt_log_forms, Options, Result),
    File = Context#context.file,
    if DoLFs ->
            Out1 = outfile(File, forms),
            {ok,Fd} = file:open(Out1, [write]),
            try lists:foreach(fun(F) -> io:fwrite(Fd, "~p.~n", [F]) end, Result)
            after
                ok = file:close(Fd)
            end;
       true -> ok
    end,
    if DoPP ->
            Out2 = outfile(File, pp),
            pp_src(Result, Out2),
            io:fwrite("Pretty-printed in ~p~n", [Out2]);
       true -> ok
    end.

optionally_renumber(Result, Options) ->
    case option_value(pt_renumber, Options, Result) of
        true ->
            io:fwrite("renumbering...~n", []),
            Rev = revert(Result),
            renumber_(Rev);
        false ->
            Result
    end.

renumber_(L) when is_list(L) ->
    {Result, _} = renumber_(L, 1),
    Result.

renumber_(L, Acc) when is_list(L) ->
    lists:mapfoldl(fun renumber_/2, Acc, L);
renumber_(T, Prev) when is_tuple(T) ->
    case is_form(T) of
        true ->
            New = Prev+1,
            NewE2 = update_line(element(2, T), New),
            T1 = setelement(2, T, NewE2),
            {Res, NewAcc} = renumber_(tuple_to_list(T1), New),
            {list_to_tuple(Res), NewAcc};
        false ->
            L = tuple_to_list(T),
            {Res, NewAcc} = renumber_(L, Prev),
            {list_to_tuple(Res), NewAcc}
    end;
renumber_(X, Prev) ->
    {X, Prev}.

is_form(T) when element(1,T)==type -> true;
is_form(T) ->
    try erl_syntax:type(T),
         true
    catch
        error:_ ->
            false
    end.

update_line(Element2, Line) ->
    case erl_anno:is_anno(Element2) of
        true ->
            erl_anno:set_line(Line, Element2);
        false -> % location
            A = erl_anno:new(Element2),
            NewA = erl_anno:set_line(Line, A),
            erl_anno:location(NewA)
    end.

option_value(Key, Options, Result) ->
    case proplists:get_value(Key, Options) of
        undefined ->
            case find_attribute(Key,Result) of
                [Expr] ->
                    type(Expr) == atom andalso
                        atom_value(Expr) == true;
                _ ->
                    false
            end;
        V when is_boolean(V) ->
            V
    end.


%%% @spec (Fun, Forms, Acc, Options) -> NewAcc
%%% Fun = function()
%%% @doc
%%% Equvalent to do_inspect(Fun,Acc,Forms,initial_context(Forms,Options)).
%%% @end
%%%
-spec inspect(insp_f(), A, forms(), options()) ->
    A.
inspect(F, Acc, Forms, Options) ->
    Context = initial_context(Forms, Options),
    do_inspect(F, Acc, Forms, Context).



outfile(File, Type) ->
    "lre." ++ RevF = lists:reverse(File),
    lists:reverse(RevF) ++ ext(Type).

ext(pp)    -> ".xfm";
ext(forms) -> ".xforms".

%% @spec (Forms, Out::filename()) -> ok
%%
%% @doc Pretty-prints the erlang source code corresponding to Forms into Out
%%
-spec pp_src(forms(), string()) ->
    ok.
pp_src(Res, F) ->
    parse_trans_pp:pp_src(Res, F).
%%     Str = [io_lib:fwrite("~s~n",
%%                          [lists:flatten([erl_pp:form(Fm) ||
%%                                             Fm <- revert(Res)])])],
%%     file:write_file(F, list_to_binary(Str)).

%% @spec (Beam::file:filename()) -> string() | {error, Reason}
%%
%% @doc
%% Reads debug_info from the beam file Beam and returns a string containing
%% the pretty-printed corresponding erlang source code.
%% @end
-spec pp_beam(file:filename()) -> ok.
pp_beam(Beam) ->
    parse_trans_pp:pp_beam(Beam).

%% @spec (Beam::filename(), Out::filename()) -> ok | {error, Reason}
%%
%% @doc
%% Reads debug_info from the beam file Beam and pretty-prints it as
%% Erlang source code, storing it in the file Out.
%% @end
%%
-spec pp_beam(file:filename(), file:filename()) -> ok.
pp_beam(F, Out) ->
    parse_trans_pp:pp_beam(F, Out).


%%% @spec (File) -> Forms
%%%
%%% @doc
%%% <p>Fetches a Syntax Tree representing the code before pre-processing,
%%% that is, including record and macro definitions. Note that macro
%%% definitions must be syntactically complete forms (this function
%%% uses epp_dodger).</p>
%%% @end
%%%
-spec get_orig_syntax_tree(string()) ->
    forms().
get_orig_syntax_tree(File) ->
    case epp_dodger:parse_file(File) of
        {ok, Forms} ->
            Forms;
        Err ->
            error(error_reading_file, ?HERE, [{File,Err}])
    end.

%%% @spec (Tree) -> Forms
%%%
%%% @doc Reverts back from Syntax Tools format to Erlang forms.
%%% <p>Note that the Erlang forms are a subset of the Syntax Tools
%%% syntax tree, so this function is safe to call even on a list of
%%% regular Erlang forms.</p>
%%% <p>Note2: R16B03 introduced a bug, where forms produced by
%%% `erl_syntax:revert/1' (specifically, implicit funs) could crash the linter.
%%% This function works around that limitation, after first verifying that it's
%%% necessary to do so. Use of the workaround can be forced with the help of
%%% the `parse_trans' environment variable {revert_workaround, true}. This
%%% variable will be removed when R16B03 is no longer 'supported'.</p>
%%% @end
%%%
-spec revert(forms()) ->
    forms().
revert(Tree) when is_list(Tree) ->
    WorkAround = needs_revert_workaround(),
    [revert_form(T, WorkAround) || T <- lists:flatten(Tree)].

%%% @spec (Tree) -> Form
%%%
%%% @doc Reverts a single form back from Syntax Tools format to Erlang forms.
%%% <p>`erl_syntax:revert/1' has had a long-standing bug where it doesn't
%%% completely revert attribute forms. This function deals properly with those
%%% cases.</p>
%%% <p>Note that the Erlang forms are a subset of the Syntax Tools
%%% syntax tree, so this function is safe to call even on a regular Erlang
%%% form.</p>
%%% <p>Note2: R16B03 introduced a bug, where forms produced by
%%% `erl_syntax:revert/1' (specifically, implicit funs) could crash the linter.
%%% This function works around that limitation, after first verifying that it's
%%% necessary to do so. Use of the workaround can be forced with the help of
%%% the `parse_trans' environment variable {revert_workaround, true}. This
%%% variable will be removed when R16B03 is no longer 'supported'.</p>
%%% @end
revert_form(F) ->
    revert_form(F, needs_revert_workaround()).

revert_form(F, W) ->
    case erl_syntax:revert(F) of
        {attribute,L,A,Tree} when element(1,Tree) == tree ->
            {attribute,L,A,erl_syntax:revert(Tree)};
        Result ->
            if W -> fix_impl_fun(Result);
               true -> Result
            end
    end.

fix_impl_fun({'fun',L,{function,{atom,_,Fn},{integer,_,Ay}}}) ->
    {'fun',L,{function,Fn,Ay}};
fix_impl_fun({'fun',L,{function,{atom,_,M},{atom,_,Fn},{integer,_,Ay}}}) ->
    {'fun',L,{function,M,Fn,Ay}};
fix_impl_fun(T) when is_tuple(T) ->
    list_to_tuple([fix_impl_fun(F) || F <- tuple_to_list(T)]);
fix_impl_fun([H|T]) ->
    [fix_impl_fun(H) | fix_impl_fun(T)];
fix_impl_fun(X) ->
    X.

needs_revert_workaround() ->
    case application:get_env(parse_trans,revert_workaround) of
        {ok, Bool} when is_boolean(Bool) -> Bool;
        _ ->
            Res = try lint_reverted()
                  catch
                      error:_ ->
                          true
                  end,
            application:set_env(parse_trans,revert_workaround,Res),
            Res
    end.

lint_reverted() ->
    Ts = [{attribute,1,module,m},
          {attribute,2,export,[{f,0}]},
          erl_syntax:function(erl_syntax:atom(f),
                              [erl_syntax:clause(
                                 [],
                                 [erl_syntax:implicit_fun(
                                    erl_syntax:atom(f),
                                    erl_syntax:integer(0))])])],
    Rev = erl_syntax:revert_forms(Ts),
    erl_lint:module(Rev),
    false.


%%% @spec (Forms, Context) -> Forms | {error,Es,Ws} | {warnings,Forms,Ws}
%%%
%%% @doc Checks the transformed result for errors and warnings
%%% <p>Errors and warnings can be produced from inside a parse transform, with
%%% a bit of care. The easiest way is to simply produce an `{error, Err}' or
%%% `{warning, Warn}' form in place. This function finds such forms, and
%%% removes them from the form list (otherwise, the linter will crash), and
%%% produces a return value that the compiler can work with.</p>
%%%
%%% The format of the `error' and `warning' "forms" must be
%%% `{Tag, {Pos, Module, Info}}', where:
%%% <ul>
%%% <li>`Tag :: error | warning'</li>
%%% <li>`Pos :: LineNumber | {LineNumber, ColumnNumber}'</li>
%%% <li>`Module' is a module that exports a corresponding
%%%    `Module:format_error(Info)'</li>
%%% <li>`Info :: term()'</li>
%%% </ul>
%%% <p>If the error is in the form of a caught exception, `Info' may be produced
%%% using the function {@link format_exception/2}.</p>
%%% @end
return(Forms, Context) ->
    JustForms = plain_transform(
                  fun({error,_}) -> skip;
                     ({warning,_}) -> skip;
                     (_) -> continue
                  end, Forms),
    File = case Context of
               #context{file = F} -> F;
               _ -> "parse_transform"
           end,
    case {find_forms(Forms, error), find_forms(Forms, warning)} of
        {[], []} ->
            JustForms;
        {[], Ws} ->
            {warnings, JustForms, [{File, [W || {warning,W} <- Ws]}]};
        {Es, Ws} ->
            {error,
             [{File, [E || {error,E} <- Es]}],
             [{File, [W || {warning,W} <- Ws]}]}
    end.

find_forms([H|T], Tag) when element(1, H) == Tag ->
    [H|find_forms(T, Tag)];
find_forms([H|T], Tag) when is_tuple(H) ->
    find_forms(tuple_to_list(H), Tag) ++ find_forms(T, Tag);
find_forms([H|T], Tag) when is_list(H) ->
    find_forms(H, Tag) ++ find_forms(T, Tag);
find_forms([_|T], Tag) ->
    find_forms(T, Tag);
find_forms([], _) ->
    [].


-define(LINEMAX, 5).
-define(CHAR_MAX, 60).

%%% @spec (Class, Reason) -> String
%%% @equiv format_exception(Class, Reason, 4)
format_exception(Class, Reason) ->
    format_exception(Class, Reason, 4).

%%% @spec (Class, Reason, Lines) -> String
%%% Class = error | throw | exit
%%% Reason = term()
%%% Lines = integer() | infinity
%%%
%%% @doc Produces a few lines of user-friendly formatting of exception info
%%%
%%% This function is very similar to the exception pretty-printing in the shell,
%%% but returns a string that can be used as error info e.g. by error forms
%%% handled by {@link return/2}. By default, the first 4 lines of the
%%% pretty-printed exception info are returned, but this can be controlled
%%% with the `Lines' parameter.
%%%
%%% Note that a stacktrace is generated inside this function.
%%% @end
format_exception(Class, Reason, Lines) ->
    {current_stacktrace, ST} = erlang:process_info(self(), current_stacktrace),
    PrintF = fun(Term, I) ->
                     io_lib_pretty:print(
                       Term, I, columns(), ?LINEMAX, ?CHAR_MAX,
                       record_print_fun())
             end,
    StackF = fun(_, _, _) -> false end,
    lines(Lines, erl_error:format_exception(
                   1, Class, Reason, ST, StackF, PrintF)).

columns() ->
    case io:columns() of
        {ok, N} -> N;
        _-> 80
    end.

lines(infinity, S) -> S;
lines(N, S) ->
    [L1|Ls] = re:split(iolist_to_binary([S]), <<"\n">>, [{return,list}]),
    [L1|["\n" ++ L || L <- lists:sublist(Ls, 1, N-1)]].

record_print_fun() ->
    fun(_,_) -> no end.

%%% @spec (Attr, Context) -> any()
%%% Attr = module | function | arity | options
%%%
%%% @doc
%%% Accessor function for the Context record.
%%% @end
-spec context(atom(), #context{}) ->
    term().
context(module,   #context{module = M}  ) -> M;
context(function, #context{function = F}) -> F;
context(arity,    #context{arity = A}   ) -> A;
context(file,     #context{file = F}    ) -> F;
context(options,  #context{options = O} ) -> O.


-spec do_inspect(insp_f(), term(), forms(), #context{}) ->
    term().
do_inspect(F, Acc, Forms, Context) ->
    F1 =
        fun(Form, Acc0) ->
                Type = type(Form),
                {Recurse, Acc1} = apply_F(F, Type, Form, Context, Acc0),
                if_recurse(
                  Recurse, Form, _Else = Acc1,
                  fun(ListOfLists) ->
                          lists:foldl(
                            fun(L, AccX) ->
                                    do_inspect(
                                      F, AccX, L,
                                      update_context(Form, Context))
                            end, Acc1, ListOfLists)
                  end)
        end,
    lists:foldl(F1, Acc, Forms).

if_recurse(true, Form, Else, F) -> recurse(Form, Else, F);
if_recurse(false, _, Else, _)   -> Else.

recurse(Form, Else, F) ->
    case erl_syntax:subtrees(Form) of
        [] ->
            Else;
        [_|_] = ListOfLists ->
            F(ListOfLists)
    end.

-spec do_transform(xform_f_rec(), term(), forms(), #context{}) ->
    {forms(), term()}.
do_transform(F, Acc, Forms, Context) ->
    Rec = fun do_transform/4, % this function
    F1 =
        fun(Form, Acc0) ->
                {Before1, Form1, After1, Recurse, Acc1} =
                    this_form_rec(F, Form, Context, Acc0),
                if Recurse ->
                        {NewForm, NewAcc} =
                            enter_subtrees(Form1, F,
                                update_context(Form1, Context), Acc1, Rec),
                        {Before1, NewForm, After1, NewAcc};
                   true ->
                        {Before1, Form1, After1, Acc1}
                end
        end,
    mapfoldl(F1, Acc, Forms).

-spec do_depth_first(xform_f_df(), term(), forms(), #context{}) ->
    {forms(), term()}.
do_depth_first(F, Acc, Forms, Context) ->
    Rec = fun do_depth_first/4,  % this function
    F1 =
        fun(Form, Acc0) ->
                {NewForm, NewAcc} =
                    enter_subtrees(Form, F, Context, Acc0, Rec),
                this_form_df(F, NewForm, Context, NewAcc)
        end,
    mapfoldl(F1, Acc, Forms).

enter_subtrees(Form, F, Context, Acc, Recurse) ->
    case erl_syntax:subtrees(Form) of
        [] ->
            {Form, Acc};
        [_|_] = ListOfLists ->
            {NewListOfLists, NewAcc} =
                mapfoldl(
                  fun(L, AccX) ->
                          Recurse(F, AccX, L, Context)
                  end, Acc, ListOfLists),
            NewForm =
                erl_syntax:update_tree(
                  Form, NewListOfLists),
            {NewForm, NewAcc}
    end.


this_form_rec(F, Form, Context, Acc) ->
    Type = type(Form),
    case apply_F(F, Type, Form, Context, Acc) of
        {Form1x, Rec1x, A1x} ->
            {[], Form1x, [], Rec1x, A1x};
        {_Be1, _F1, _Af1, _Rec1, _Ac1} = Res1 ->
            Res1
    end.
this_form_df(F, Form, Context, Acc) ->
    Type = type(Form),
    case apply_F(F, Type, Form, Context, Acc) of
        {Form1x, A1x} ->
            {[], Form1x, [], A1x};
        {_Be1, _F1, _Af1, _Ac1} = Res1 ->
            Res1
    end.

apply_F(F, Type, Form, Context, Acc) ->
    try F(Type, Form, Context, Acc)
    catch
        error:Reason:ST ->
            ?ERROR(Reason,
                   ?HERE,
                   [{type, Type},
                    {context, Context},
                    {acc, Acc},
                    {apply_f, F},
                    {form, Form},
                    {stack, ST}],
                   ST)
    end.


update_context(Form, Context0) ->
    case type(Form) of
        function ->
            {Fun, Arity} =
                erl_syntax_lib:analyze_function(Form),
            Context0#context{function = Fun,
                             arity = Arity};
        _ ->
            Context0
    end.




%%% Slightly modified version of lists:mapfoldl/3
%%% Here, F/2 is able to insert forms before and after the form
%%% in question. The inserted forms are not transformed afterwards.
mapfoldl(F, Accu0, [Hd|Tail]) ->
    {Before, Res, After, Accu1} =
        case F(Hd, Accu0) of
            {Be, _, Af, _} = Result when is_list(Be), is_list(Af) ->
                Result;
            {R1, A1} ->
                {[], R1, [], A1}
        end,
    {Rs, Accu2} = mapfoldl(F, Accu1, Tail),
    {Before ++ [Res| After ++ Rs], Accu2};
mapfoldl(F, Accu, []) when is_function(F, 2) -> {[], Accu}.


rpt_error(_Reason, _Fun, _Info, _Trace) ->
    %% Fmt = lists:flatten(
    %%      ["*** ERROR in parse_transform function:~n"
    %%       "*** Reason     = ~p~n",
    %%          "*** Location: ~p~n",
    %%       "*** Trace: ~p~n",
    %%       ["*** ~10w = ~p~n" || _ <- Info]]),
    %% Args = [Reason, Fun, Trace |
    %%      lists:foldr(
    %%        fun({K,V}, Acc) ->
    %%                [K, V | Acc]
    %%        end, [], Info)],
    %%io:format(Fmt, Args),
    ok.

-spec format_error({atom(), term()}) ->
    iolist().
format_error({E, [{M,F,A}|_]} = Error) ->
    try lists:flatten(io_lib:fwrite("~p in ~s:~s/~s", [E, atom_to_list(M),
                                                       atom_to_list(F), integer_to_list(A)]))
    catch
        error:_ ->
            format_error_(Error)
    end;
format_error(Error) ->
    format_error_(Error).

format_error_(Error) ->
    lists:flatten(io_lib:fwrite("~p", [Error])).


%% EUnit
-ifdef(TEST).

format_exeption_test() ->
    [_,_,_] = format_exception(error, {error, foo}, 3),
    ok.

-endif.
