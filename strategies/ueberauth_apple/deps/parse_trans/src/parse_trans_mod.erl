%%============================================================================
%% Copyright 2014 Ulf Wiger
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
%%============================================================================
%%
%% Based on meck_mod.erl from http://github.com/eproxus/meck.git
%% Original author: Adam Lindberg
%%
-module(parse_trans_mod).
%% Interface exports
-export([transform_module/3]).

-export([abstract_code/1]).
-export([beam_file/1]).
-export([compile_and_load_forms/1]).
-export([compile_and_load_forms/2]).
-export([compile_options/1]).
-export([rename_module/2]).

%% Types
-type erlang_form() :: term().
-type compile_options() :: [term()].

%%============================================================================
%% Interface exports
%%============================================================================

transform_module(Mod, PT, Options) ->
    File = beam_file(Mod),
    Forms = abstract_code(File),
    Context = parse_trans:initial_context(Forms, Options),
    PTMods = if is_atom(PT) -> [PT];
                is_function(PT, 2) -> [PT];
                is_list(PT) -> PT
             end,
    Transformed = lists:foldl(fun(PTx, Fs) when is_function(PTx, 2) ->
                                      PTx(Fs, Options);
                                 (PTMod, Fs) ->
                                      PTMod:parse_transform(Fs, Options)
                              end, Forms, PTMods),
    parse_trans:optionally_pretty_print(Transformed, Options, Context),
    compile_and_load_forms(Transformed, get_compile_options(Options)).


-spec abstract_code(binary()) -> erlang_form().
abstract_code(BeamFile) ->
    case beam_lib:chunks(BeamFile, [abstract_code]) of
        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            Forms;
        {ok, {_, [{abstract_code, no_abstract_code}]}} ->
            erlang:error(no_abstract_code)
    end.

-spec beam_file(module()) -> binary().
beam_file(Module) ->
    % code:which/1 cannot be used for cover_compiled modules
    case code:get_object_code(Module) of
        {_, Binary, _Filename} -> Binary;
        error                  -> throw({object_code_not_found, Module})
    end.

-spec compile_and_load_forms(erlang_form()) -> ok.
compile_and_load_forms(AbsCode) -> compile_and_load_forms(AbsCode, []).

-spec compile_and_load_forms(erlang_form(), compile_options()) -> ok.
compile_and_load_forms(AbsCode, Opts) ->
    case compile:forms(AbsCode, Opts) of
        {ok, ModName, Binary} ->
            load_binary(ModName, Binary, Opts);
        {ok, ModName, Binary, _Warnings} ->
            load_binary(ModName, Binary, Opts)
    end.

-spec compile_options(binary() | module()) -> compile_options().
compile_options(BeamFile) when is_binary(BeamFile) ->
    case beam_lib:chunks(BeamFile, [compile_info]) of
        {ok, {_, [{compile_info, Info}]}} ->
            proplists:get_value(options, Info);
        _ ->
            []
    end;
compile_options(Module) ->
    proplists:get_value(options, Module:module_info(compile)).

-spec rename_module(erlang_form(), module()) -> erlang_form().
rename_module([{attribute, Line, module, _OldName}|T], NewName) ->
    [{attribute, Line, module, NewName}|T];
rename_module([H|T], NewName) ->
    [H|rename_module(T, NewName)].

%%==============================================================================
%% Internal functions
%%==============================================================================

load_binary(Name, Binary, Opts) ->
    code:purge(Name),
    File = beam_filename(Name, Opts),
    case code:load_binary(Name, File, Binary) of
        {module, Name}  -> ok;
        {error, Reason} ->  exit({error_loading_module, Name, Reason})
    end.

get_compile_options(Options) ->
    case lists:keyfind(compile_options, 1, Options) of
        {_, COpts} ->
            COpts;
        false ->
            []
    end.

beam_filename(Mod, Opts) ->
    case lists:keyfind(outdir, 1, Opts) of
        {_, D} ->
            filename:join(D, atom_to_list(Mod) ++ code:objfile_extension());
        false ->
            ""
    end.
