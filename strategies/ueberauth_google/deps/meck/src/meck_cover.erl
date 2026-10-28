%%=============================================================================
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

%% @private
%% @doc Module containing functions needed by meck to integrate with cover.

-module(meck_cover).

%% Interface exports
-export([compile_beam/2]).
-export([rename_module/2]).
-export([dump_coverdata/1]).

-ignore_xref({cover, compile_beams, 1}).
-ignore_xref({cover, compile_beam, 2}).
-ignore_xref({cover, get_term, 1}).
-ignore_xref({cover, write, 2}).

%%=============================================================================
%% Interface exports
%%=============================================================================

%% @doc Enabled cover on `<name>_meck_original'.
compile_beam(OriginalMod, Bin) ->
    CompileBeams = alter_cover(),
    [{ok, _}] = CompileBeams([{OriginalMod, Bin}]).

%% @doc Given a cover file `File' exported by `cover:export' overwrite
%% the module name with `Name'.
rename_module(File, Name) ->
    NewTerms = change_cover_mod_name(read_cover_file(File), Name),
    write_terms(File, NewTerms),
    ok.

%% @doc Dump cover data for `Mod' into a .coverdata file in the current
%% directory. Return the absolute path to the backup file.
dump_coverdata(Mod) ->
    {ok, CWD} = file:get_cwd(),
    File = lists:concat([Mod, ".", os:getpid(), ".coverdata"]),
    Path = filename:join(CWD, File),
    ok = cover:export(Path, Mod),
    Path.

%%=============================================================================
%% Internal functions
%%=============================================================================

%% @private
%%
%% @doc Alter the cover BEAM module to export some of it's private
%% functions.  This is done for two reasons:
%%
%% 1. Meck needs to alter the export analysis data on disk and
%% therefore needs to understand this format.  This is why `get_term'
%% and `write' are exposed.
%%
%% 2. In order to avoid creating temporary files meck needs direct
%% access to `compile_beam/2' which allows passing a binary.
%% In OTP 18.0 the internal API of cover changed a bit and
%% compile_beam/2 was replaced by compile_beams/1.
-dialyzer({no_missing_calls, alter_cover/0}). % for cover:compile_beams/1
alter_cover() ->
    CoverExports = cover:module_info(exports),
    case {lists:member({compile_beams,1}, CoverExports),
          lists:member({compile_beam,2}, CoverExports)} of
        {true, _} ->
            fun cover:compile_beams/1;
        {_, true} ->
            fun compile_beam_wrapper/1;
        {false, false} ->
            Beam = meck_code:beam_file(cover),
            AbsCode = meck_code:abstract_code(Beam),
            {Exports, CompileBeams} =
                case lists:member({analyse,0}, CoverExports) of
                    true ->
                        %% new API from OTP 18.0 on
                        {[{compile_beams, 1}, {get_term, 1}, {write, 2}],
                         fun cover:compile_beams/1};
                    false ->
                        {[{compile_beam, 2}, {get_term, 1}, {write, 2}],
                         fun compile_beam_wrapper/1}
                end,
            AbsCode2 = meck_code:add_exports(Exports, AbsCode),
            _Bin = meck_code:compile_and_load_forms(AbsCode2),
            CompileBeams
    end.

%% wrap cover's pre-18.0 internal API to simulate the new API
-dialyzer({no_missing_calls, compile_beam_wrapper/1}). % for cover:compile_beam/2
compile_beam_wrapper(ModFiles) ->
    [cover:compile_beam(Mod, Bin)||{Mod, Bin} <- ModFiles].

change_cover_mod_name(CoverTerms, Name) ->
    {_, Terms} = lists:foldl(fun change_name_in_term/2, {Name,[]}, CoverTerms),
    Terms.

change_name_in_term({file, Mod, File}, {Name, Terms}) ->
    Term2 = {file, Name, replace_string(File, Mod, Name)},
    {Name, [Term2|Terms]};
change_name_in_term({Bump={bump,_,_,_,_,_},_}=Term, {Name, Terms}) ->
    Bump2 = setelement(2, Bump, Name),
    Term2 = setelement(1, Term, Bump2),
    {Name, [Term2|Terms]};
change_name_in_term({_Mod,Clauses}, {Name, Terms}) ->
    Clauses2 = lists:foldl(fun change_name_in_clause/2, {Name, []}, Clauses),
    Term2 = {Name, Clauses2},
    {Name, [Term2|Terms]}.

change_name_in_clause(Clause, {Name, NewClauses}) ->
    {Name, [setelement(1, Clause, Name)|NewClauses]}.

replace_string(File, Old, New) ->
    Old2 = atom_to_list(Old),
    New2 = atom_to_list(New),
    re:replace(File, Old2, New2, [{return, list}]).

read_cover_file(File) ->
    {ok, Fd} = file:open(File, [read, binary, raw]),
    Terms = get_terms(Fd, []),
    ok = file:close(Fd),
    Terms.

-dialyzer({no_missing_calls, get_terms/2}). % for cover:get_term/1
get_terms(Fd, Terms) ->
    case cover:get_term(Fd) of
        eof -> Terms;
        Term -> get_terms(Fd, [Term|Terms])
    end.

write_terms(File, Terms) ->
    {ok, Fd} = file:open(File, [write, binary, raw]),
    lists:foreach(write_term(Fd), Terms),
    ok.

-dialyzer({no_missing_calls, write_term/1}). % for cover:write/2
write_term(Fd) ->
    fun(Term) -> cover:write(Term, Fd) end.
