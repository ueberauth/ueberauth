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
%% File    : parse_trans_codegen.erl
%% @author  : Ulf Wiger <ulf@wiger.net>
%% @end
%%-------------------------------------------------------------------

%% @doc Parse transform for code generation pseduo functions
%%
%% <p>...</p>
%%
%% @end

-module(parse_trans_codegen).

-export([parse_transform/2]).
-export([format_error/1]).

%% @spec (Forms, Options) -> NewForms
%%
%% @doc
%% Searches for calls to pseudo functions in the module `codegen',
%% and converts the corresponding erlang code to a data structure
%% representing the abstract form of that code.
%%
%% The purpose of these functions is to let the programmer write
%% the actual code that is to be generated, rather than manually
%% writing abstract forms, which is more error prone and cannot be
%% checked by the compiler until the generated module is compiled.
%%
%% Supported functions:
%%
%% <h2>gen_function/2</h2>
%%
%% Usage: `codegen:gen_function(Name, Fun)'
%%
%% Substitutes the abstract code for a function with name `Name'
%% and the same behaviour as `Fun'.
%%
%% `Fun' can either be a anonymous `fun', which is then converted to
%% a named function, or it can be an `implicit fun', e.g.
%% `fun is_member/2'. In the latter case, the referenced function is fetched
%% and converted to an abstract form representation. It is also renamed
%% so that the generated function has the name `Name'.
%% <p/>
%% Another alternative is to wrap a fun inside a list comprehension, e.g.
%% <pre>
%% f(Name, L) -&gt;
%%     codegen:gen_function(
%%         Name,
%%         [ fun({'$var',X}) -&gt;
%%              {'$var', Y}
%%           end || {X, Y} &amp;lt;- L ]).
%% </pre>
%% <p/>
%% Calling the above with `f(foo, [{1,a},{2,b},{3,c}])' will result in
%% generated code corresponding to:
%% <pre>
%% foo(1) -&gt; a;
%% foo(2) -&gt; b;
%% foo(3) -&gt; c.
%% </pre>
%%
%% <h2>gen_functions/1</h2>
%%
%% Takes a list of `{Name, Fun}' tuples and produces a list of abstract
%% data objects, just as if one had written
%% `[codegen:gen_function(N1,F1),codegen:gen_function(N2,F2),...]'.
%%
%% <h2>exprs/1</h2>
%%
%% Usage: `codegen:exprs(Fun)'
%%
%% `Fun' is either an anonymous function, or an implicit fun with only one
%% function clause. This "function" takes the body of the fun and produces
%% a data type representing the abstract form of the list of expressions in
%% the body. The arguments of the function clause are ignored, but can be
%% used to ensure that all necessary variables are known to the compiler.
%%
%% <h2>gen_module/3</h2>
%%
%% Generates abstract forms for a complete module definition.
%%
%% Usage: `codegen:gen_module(ModuleName, Exports, Functions)'
%%
%% `ModuleName' is either an atom or a <code>{'$var', V}</code> reference.
%%
%% `Exports' is a list of `{Function, Arity}' tuples.
%%
%% `Functions' is a list of `{Name, Fun}' tuples analogous to that for
%% `gen_functions/1'.
%%
%% <h2>Variable substitution</h2>
%%
%% It is possible to do some limited expansion (importing a value
%% bound at compile-time), using the construct <code>{'$var', V}</code>, where
%% `V' is a bound variable in the scope of the call to `gen_function/2'.
%%
%% Example:
%% <pre>
%% gen(Name, X) ->
%%    codegen:gen_function(Name, fun(L) -> lists:member({'$var',X}, L) end).
%% </pre>
%%
%% After transformation, calling `gen(contains_17, 17)' will yield the
%% abstract form corresponding to:
%% <pre>
%% contains_17(L) ->
%%    lists:member(17, L).
%% </pre>
%%
%% <h2>Form substitution</h2>
%%
%% It is possible to inject abstract forms, using the construct
%% <code>{'$form', F}</code>, where `F' is bound to a parsed form in
%% the scope of the call to `gen_function/2'.
%%
%% Example:
%% <pre>
%% gen(Name, F) ->
%%    codegen:gen_function(Name, fun(X) -> X =:= {'$form',F} end).
%% </pre>
%%
%% After transformation, calling `gen(is_foo, {atom,0,foo})' will yield the
%% abstract form corresponding to:
%% <pre>
%% is_foo(X) ->
%%    X =:= foo.
%% </pre>
%% @end
%%
parse_transform(Forms, Options) ->
    Context = parse_trans:initial_context(Forms, Options),
    {NewForms, _} =
        parse_trans:do_depth_first(
          fun xform_fun/4, _Acc = Forms, Forms, Context),
    parse_trans:return(parse_trans:revert(NewForms), Context).

xform_fun(application, Form, _Ctxt, Acc) ->
    MFA = erl_syntax_lib:analyze_application(Form),
    Anno = erl_syntax:get_pos(Form),
    L = erl_anno:line(Anno),
    case MFA of
        {codegen, {gen_module, 3}} ->
            [NameF, ExportsF, FunsF] =
                erl_syntax:application_arguments(Form),
            NewForms = gen_module(NameF, ExportsF, FunsF, L, Acc),
            {NewForms, Acc};
        {codegen, {gen_function, 2}} ->
            [NameF, FunF] =
                erl_syntax:application_arguments(Form),
            NewForm = gen_function(NameF, FunF, L, L, Acc),
            {NewForm, Acc};
        {codegen, {gen_function, 3}} ->
            [NameF, FunF, LineF] =
                erl_syntax:application_arguments(Form),
            NewForm = gen_function(
                        NameF, FunF, L, erl_syntax:integer_value(LineF), Acc),
            {NewForm, Acc};
        {codegen, {gen_function_alt, 3}} ->
            [NameF, FunF, AltF] =
                erl_syntax:application_arguments(Form),
            NewForm = gen_function_alt(NameF, FunF, AltF, L, L, Acc),
            {NewForm, Acc};
        {codegen, {gen_functions, 1}} ->
            [List] = erl_syntax:application_arguments(Form),
            Elems = erl_syntax:list_elements(List),
            NewForms = lists:map(
                         fun(E) ->
                                 [NameF, FunF] = erl_syntax:tuple_elements(E),
                                 gen_function(NameF, FunF, L, L, Acc)
                         end, Elems),
            {erl_syntax:list(NewForms), Acc};
        {codegen, {exprs, 1}} ->
            [FunF] = erl_syntax:application_arguments(Form),
            [Clause] = erl_syntax:fun_expr_clauses(FunF),
            [{clause,_,_,_,Body}] = parse_trans:revert([Clause]),
            NewForm = substitute(erl_parse:abstract(Body)),
            {NewForm, Acc};
        _ ->
            {Form, Acc}
    end;
xform_fun(_, Form, _Ctxt, Acc) ->
    {Form, Acc}.

gen_module(NameF, ExportsF, FunsF, L, Acc) ->
    case erl_syntax:type(FunsF) of
        list ->
            try gen_module_(NameF, ExportsF, FunsF, L, Acc)
            catch
                error:E ->
                    ErrStr = parse_trans:format_exception(error, E),
                    {error, {L, ?MODULE, ErrStr}}
            end;
        _ ->
            ErrStr = parse_trans:format_exception(
                       error, "Argument must be a list"),
            {error, {L, ?MODULE, ErrStr}}
    end.

gen_module_(NameF, ExportsF, FunsF, L0, Acc) ->
    P = erl_syntax:get_pos(NameF),
    ModF = case parse_trans:revert_form(NameF) of
               {atom,_,_} = Am -> Am;
               {tuple,_,[{atom,_,'$var'},
                         {var,_,V}]} ->
                   {var,P,V}
           end,
    cons(
      {cons,P,
       {tuple,P,
        [{atom,P,attribute},
         {integer,P,1},
         {atom,P,module},
         ModF]},
       substitute(
         abstract(
           [{attribute,P,export,
             lists:map(
               fun(TupleF) ->
                       [F,A] = erl_syntax:tuple_elements(TupleF),
                       {erl_syntax:atom_value(F), erl_syntax:integer_value(A)}
               end, erl_syntax:list_elements(ExportsF))}]))},
      lists:map(
        fun(FTupleF) ->
                Pos = erl_syntax:get_pos(FTupleF),
                [FName, FFunF] = erl_syntax:tuple_elements(FTupleF),
                gen_function(FName, FFunF, L0, Pos, Acc)
        end, erl_syntax:list_elements(FunsF))).

cons({cons,L,H,T}, L2) ->
    {cons,L,H,cons(T, L2)};
cons({nil,L}, [H|T]) ->
    Pos = erl_syntax:get_pos(H),
    {cons,L,H,cons({nil,Pos}, T)};
cons({nil,L}, []) ->
    {nil,L}.



gen_function(NameF, FunF, L0, L, Acc) ->
    try gen_function_(NameF, FunF, [], L, Acc)
    catch
        error:E ->
            ErrStr = parse_trans:format_exception(error, E),
            {error, {L0, ?MODULE, ErrStr}}
    end.

gen_function_alt(NameF, FunF, AltF, L0, L, Acc) ->
    try gen_function_(NameF, FunF, AltF, L, Acc)
    catch
        error:E ->
            ErrStr = parse_trans:format_exception(error, E),
            {error, {L0, ?MODULE, ErrStr}}
    end.

gen_function_(NameF, FunF, AltF, L, Acc) ->
    case erl_syntax:type(FunF) of
        T when T==implicit_fun; T==fun_expr ->
            {Arity, Clauses} = gen_function_clauses(T, NameF, FunF, L, Acc),
            A1 = erl_anno:new(1),
            {tuple, A1, [{atom, A1, function},
                         {integer, A1, L},
                         NameF,
                         {integer, A1, Arity},
                         substitute(abstract(Clauses))]};
        list_comp ->
            %% Extract the fun from the LC
            [Template] = parse_trans:revert(
                           [erl_syntax:list_comp_template(FunF)]),
            %% Process fun in the normal fashion (as above)
            {Arity, Clauses} = gen_function_clauses(erl_syntax:type(Template),
                                                    NameF, Template, L, Acc),
            Body = erl_syntax:list_comp_body(FunF),
            %% Collect all variables from the LC generator(s)
            %% We want to produce an abstract representation of something like:
            %% {function,1,Name,Arity,
            %%  lists:flatten(
            %%     [(fun(V1,V2,...) ->
            %%           ...
            %%       end)(__V1,__V2,...) || {__V1,__V2,...} <- L])}
            %% where the __Vn vars are our renamed versions of the LC generator
            %% vars. This allows us to instantiate the clauses at run-time.
            Vars = lists:flatten(
                     [sets:to_list(erl_syntax_lib:variables(
                                     erl_syntax:generator_pattern(G)))
                      || G <- Body]),
            Vars1 = [list_to_atom("__" ++ atom_to_list(V)) || V <- Vars],
            VarMap = lists:zip(Vars, Vars1),
            Body1 =
                [erl_syntax:generator(
                   rename_vars(VarMap, gen_pattern(G)),
                   gen_body(G)) || G <- Body],
            A1 = erl_anno:new(1),
            [RevLC] = parse_trans:revert(
                        [erl_syntax:list_comp(
                           {call, A1,
                            {'fun',A1,
                             {clauses,
                              [{clause,A1,[{var,A1,V} || V <- Vars],[],
                                [substitute(
                                   abstract(Clauses))]
                               }]}
                            }, [{var,A1,V} || V <- Vars1]}, Body1)]),
            AltC = case AltF of
                       [] -> {nil,A1};
                       _ ->
                           {Arity, AltC1} = gen_function_clauses(
                                              erl_syntax:type(AltF),
                                              NameF, AltF, L, Acc),
                           substitute(abstract(AltC1))
                   end,
            {tuple,A1,[{atom,A1,function},
                       {integer, A1, L},
                       NameF,
                       {integer, A1, Arity},
                       {call, A1, {remote, A1, {atom, A1, lists},
                                  {atom,A1,flatten}},
                        [{op, A1, '++', RevLC, AltC}]}]}
    end.

gen_pattern(G) ->
    erl_syntax:generator_pattern(G).

gen_body(G) ->
    erl_syntax:generator_body(G).

rename_vars(Vars, Tree) ->
    erl_syntax_lib:map(
      fun(T) ->
              case erl_syntax:type(T) of
                  variable ->
                      V = erl_syntax:variable_name(T),
                      {_,V1} = lists:keyfind(V,1,Vars),
                      erl_syntax:variable(V1);
                  _ ->
                      T
              end
      end, Tree).

gen_function_clauses(implicit_fun, _NameF, FunF, _L, Acc) ->
    AQ = erl_syntax:implicit_fun_name(FunF),
    Name = erl_syntax:atom_value(erl_syntax:arity_qualifier_body(AQ)),
    Arity = erl_syntax:integer_value(
              erl_syntax:arity_qualifier_argument(AQ)),
    NewForm = find_function(Name, Arity, Acc),
    ClauseForms = erl_syntax:function_clauses(NewForm),
    {Arity, ClauseForms};
gen_function_clauses(fun_expr, _NameF, FunF, _L, _Acc) ->
    ClauseForms = erl_syntax:fun_expr_clauses(FunF),
    Arity = get_arity(ClauseForms),
    {Arity, ClauseForms}.

find_function(Name, Arity, Forms) ->
    [Form] = [F || {function,_,N,A,_} = F <- Forms,
                   N == Name,
                   A == Arity],
    Form.

abstract(ClauseForms) ->
    erl_parse:abstract(parse_trans:revert(ClauseForms)).

substitute({tuple,L0,
            [{atom,_,tuple},
             Loc,
             {cons,_,
              {tuple,_,[{atom,_,atom},_LocA,{atom,_,'$var'}]},
              {cons,_,
               {tuple,_,[{atom,_,var},_LocB,{atom,_,V}]},
               {nil,_}}}]}) when element(1, Loc) == tuple; % Erlang 24+
                                 element(1, Loc) == integer ->
    AbstConcreteLoc =
        case Loc of
            {integer, _, L} ->
                {integer, L0, L};
            {tuple, _, [{integer, _, L}, {integer, _, C}]} ->
                {tuple, L0, [{integer, L0, L}, {integer, L0, C}]}
        end,
    {call, L0, {remote,L0,{atom,L0,erl_parse},
                {atom,L0,abstract}},
     [{var, L0, V}, AbstConcreteLoc]};
substitute({tuple,L0, % Erlang 24: {Line,Col}
            [{atom,_,tuple},
             Loc,
             {cons,_,
              {tuple,_,[{atom,_,atom},_LocA,{atom,_,'$form'}]},
              {cons,_,
               {tuple,_,[{atom,_,var},_LocB,{atom,_,F}]},
               {nil,_}}}]}) when element(1, Loc) == tuple; % Erlang 24+
                                 element(1, Loc) == integer ->
    {var, L0, F};
substitute([]) ->
    [];
substitute([H|T]) ->
    [substitute(H) | substitute(T)];
substitute(T) when is_tuple(T) ->
    list_to_tuple(substitute(tuple_to_list(T)));
substitute(X) ->
    X.

get_arity(Clauses) ->
    Ays = [length(erl_syntax:clause_patterns(C)) || C <- Clauses],
    case lists:usort(Ays) of
        [Ay] ->
            Ay;
        Other ->
            erlang:error(ambiguous, Other)
    end.


format_error(E) ->
    case io_lib:deep_char_list(E) of
        true ->
            E;
        _ ->
            io_lib:write(E)
    end.
