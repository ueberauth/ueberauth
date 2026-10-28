%%=============================================================================
%% Copyright 2010-2017 Adam Lindberg, 2010-2011 Erlang Solutions Ltd
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%=============================================================================

%% @hidden
%% @author Adam Lindberg <eproxus@gmail.com>
%% @copyright 2010-2017 Adam Lindberg, 2010-2011 Erlang Solutions Ltd
%% @doc Module wrangling helper functions.

-module(meck_code).

%% Interface exports
-export([abstract_code/1]).
-export([add_exports/2]).
-export([beam_file/1]).
-export([compile_and_load_forms/1]).
-export([compile_and_load_forms/2]).
-export([compile_options/1]).
-export([enable_on_load/2]).
-export([rename_module/3]).

%% Types
-type erlang_form() :: term().
-type compile_options() :: [term()].
-type export() :: {atom(), byte()}.

%%=============================================================================
%% Interface exports
%%=============================================================================

-spec abstract_code(binary()) -> erlang_form().
abstract_code(BeamFile) ->
    case beam_lib:chunks(BeamFile, [abstract_code]) of
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            Forms;
        {ok, {_, [{abstract_code, no_abstract_code}]}} ->
            throw(no_abstract_code)
    end.

-spec add_exports([export()], erlang_form()) -> erlang_form().
add_exports(Exports, AbsCode) ->
    {attribute, Line, export, OrigExports} = lists:keyfind(export, 3, AbsCode),
    Attr = {attribute, Line, export, OrigExports ++ Exports},
    lists:keyreplace(export, 3, AbsCode, Attr).

-spec beam_file(module()) -> binary().
beam_file(Module) ->
    % code:which/1 cannot be used for cover_compiled modules
    case code:get_object_code(Module) of
        {_, Binary, _Filename} -> Binary;
        error                  -> throw({object_code_not_found, Module})
    end.

-spec compile_and_load_forms(erlang_form()) -> binary().
compile_and_load_forms(AbsCode) -> compile_and_load_forms(AbsCode, []).

-spec compile_and_load_forms(erlang_form(), compile_options()) -> binary().
compile_and_load_forms(AbsCode, Opts) ->
    case compile:forms(AbsCode, [return_errors|Opts]) of
        {ok, ModName, Binary} ->
            load_binary(ModName, Binary),
            Binary;
        {ok, ModName, Binary, _Warnings} ->
            load_binary(ModName, Binary),
            Binary;
        Error ->
            exit({compile_forms, Error})
    end.

-spec compile_options(binary() | module()) -> compile_options().
compile_options(BeamFile) when is_binary(BeamFile) ->
    case beam_lib:chunks(BeamFile, [compile_info]) of
        {ok, {_, [{compile_info, Info}]}} ->
          filter_options(proplists:get_value(options, Info));
        _ ->
            []
    end;
compile_options(Module) ->
  filter_options(proplists:get_value(options, Module:module_info(compile))).

enable_on_load(Forms, false) ->
    Map = fun({attribute,L,on_load,{F,A}}) -> {attribute,L,export,[{F,A}]};
             (Other) -> Other
          end,
    lists:map(Map, Forms);
enable_on_load(Forms, _) ->
    Forms.

-spec rename_module(erlang_form(), module(), module()) -> erlang_form().
rename_module(Forms, Old, New) ->
    lists:map(fun(F) -> rename_module_in_form(F, Old, New) end, Forms).

%%=============================================================================
%% Internal functions
%%=============================================================================

load_binary(Name, Binary) ->
    case code:load_binary(Name, "", Binary) of
        {module, Name}  -> ok;
        {error, Reason} -> exit({error_loading_module, Name, Reason})
    end.

% parse transforms have already been applied to the abstract code in the
% module, and often are not always available when compiling the forms, so
% filter them out of the options.
%
% Furthermore, since Erlang/OTP 20, a code may be compiled from core but
% still have abstract code, so we make sure to remove the from_core option
% as we always compile it as a form.
%
% The -MMD option (makedep_side_effect) needs to be removed, otherwise
% the compiler will attempt to generate a dependency file.
filter_options (Options) ->
    case Options of
        undefined -> [];
        _ -> lists:filter(
               fun({parse_transform,_})  -> false;
                  (makedep_side_effect)  -> false;
                  (from_core)            -> false;
                  (_)                    -> true
               end, Options)
    end.

rename_module_in_form({attribute, Line, AttrName, AttrData}, Old, New) ->
    {attribute, Line, AttrName,
        rename_module_in_attribute(AttrName, AttrData, Old, New)
    };
rename_module_in_form(Form, _Old, _New) ->
    Form.

rename_module_in_attribute(module, Old, Old, New) ->
    New;
rename_module_in_attribute(spec, {{Old, Fun, Arity}, Spec}, Old, New) ->
    {{New, Fun, Arity}, Spec};
rename_module_in_attribute(_AttrName, AttrData, _Old, _New) ->
    AttrData.
