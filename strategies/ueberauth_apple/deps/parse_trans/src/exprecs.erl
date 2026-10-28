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
%% File    : exprecs.erl
%% @author  : Ulf Wiger <ulf@wiger.net>
%% @end
%% Description :
%%
%% Created : 13 Feb 2006 by Ulf Wiger <ulf@wiger.net>
%% Rewritten: Jan-Feb 2010 by Ulf Wiger <ulf@wiger.net>
%%-------------------------------------------------------------------

%% @doc Parse transform for generating record access functions.
%% <p>This parse transform can be used to reduce compile-time
%% dependencies in large systems.</p>
%% <p>In the old days, before records, Erlang programmers often wrote
%% access functions for tuple data. This was tedious and error-prone.
%% The record syntax made this easier, but since records were implemented
%% fully in the pre-processor, a nasty compile-time dependency was
%% introduced.</p>
%% <p>This module automates the generation of access functions for
%% records. While this method cannot fully replace the utility of
%% pattern matching, it does allow a fair bit of functionality on
%% records without the need for compile-time dependencies.</p>
%% <p>Whenever record definitions need to be exported from a module,
%% inserting a compiler attribute,
%% <code>export_records([RecName|...])</code> causes this transform
%% to lay out access functions for the exported records:</p>
%%
%% As an example, consider the following module:
%% <pre lang="erlang">
%% -module(test_exprecs).
%%
%% -record(r,{a = 0 :: integer(),b = 0 :: integer(),c = 0 :: integer()}).
%% -record(s,{a}).
%% -record(t,{}).
%%
%% -export_records([r,s,t]).
%%
%% -export_type(['#prop-r'/0,
%%               '#attr-r'/0,
%%               '#prop-s'/0,
%%               '#attr-s'/0,
%%               '#prop-t'/0,
%%               '#attr-t'/0]).
%%
%% -type '#prop-s'() :: {a, any()}.
%%
%% -type '#attr-s'() :: a.
%%
%% -type '#prop-r'() :: {a, any()} | {b, any()} | {c, any()}.
%%
%% -type '#attr-r'() :: a | b | c.
%%
%% -type '#prop-t'() :: any().
%%
%% -type '#attr-t'() :: any().
%%
%% -spec '#exported_records-'() -&gt; [r | s | t].
%%
%% -spec '#new-'(r) -&gt; #r{};
%%              (s) -&gt; #s{};
%%              (t) -&gt; #t{}.
%%
%% -spec '#info-'(r) -&gt; ['#attr-r'()];
%%               (s) -&gt; ['#attr-s'()];
%%               (t) -&gt; ['#attr-t'()].
%%
%% -spec '#info-'(r, size) -&gt; 4;
%%               (r, fields) -&gt; ['#attr-r'()];
%%               (s, size) -&gt; 2;
%%               (s, fields) -&gt; ['#attr-s'()];
%%               (t, size) -&gt; 1;
%%               (t, fields) -&gt; ['#attr-t'()].
%%
%% -spec '#pos-'(r, a) -&gt; 1;
%%              (r, b) -&gt; 2;
%%              (r, c) -&gt; 3;
%%              (s, a) -&gt; 1.
%%
%% -spec '#is_record-'(any()) -&gt; boolean().
%%
%% -spec '#is_record-'(any(), any()) -&gt; boolean().
%%
%% -spec '#get-'(a, #s{}) -&gt; any();
%%              (a, #r{}) -&gt; any();
%%              (b, #r{}) -&gt; any();
%%              (c, #r{}) -&gt; any();
%%              (['#attr-t'()], #t{}) -&gt; [];
%%              (['#attr-s'()], #s{}) -&gt; [any()];
%%              (['#attr-r'()], #r{}) -&gt; [any()].
%%
%% -spec '#set-'(['#prop-r'()], #r{}) -&gt; #r{};
%%              (['#prop-s'()], #s{}) -&gt; #s{};
%%              (['#prop-t'()], #t{}) -&gt; #t{}.
%%
%% -spec '#fromlist-'(['#prop-r'()], #r{}) -&gt; #r{};
%%                   (['#prop-s'()], #s{}) -&gt; #s{};
%%                   (['#prop-t'()], #t{}) -&gt; #t{}.
%%
%% -spec '#frommap-'(#{a =&gt; any(), b =&gt; any(), c =&gt; any()}, #r{}) -&gt; #r{};
%%                  (#{a =&gt; any()}, #s{}) -&gt; #s{};
%%                  (#{}, #t{}) -&gt; #t{}.
%%
%% -spec '#lens-'('#attr-r'(), r) -&gt;
%%                   {fun((#r{}) -&gt; any()), fun((any(), #r{}) -&gt; #r{})};
%%               ('#attr-s'(), s) -&gt;
%%                   {fun((#s{}) -&gt; any()), fun((any(), #s{}) -&gt; #s{})};
%%               ('#attr-t'(), t) -&gt;
%%                   {fun((#t{}) -&gt; any()), fun((any(), #t{}) -&gt; #t{})}.
%%
%% -spec '#new-r'() -&gt; #r{}.
%%
%% -spec '#new-r'(['#prop-r'()]) -&gt; #r{}.
%%
%% -spec '#get-r'(a, #r{}) -&gt; any();
%%               (b, #r{}) -&gt; any();
%%               (c, #r{}) -&gt; any();
%%               (['#attr-r'()], #r{}) -&gt; [any()].
%%
%% -spec '#set-r'(['#prop-r'()], #r{}) -&gt; #r{}.
%%
%% -spec '#fromlist-r'(['#prop-r'()]) -&gt; #r{}.
%%
%% -spec '#fromlist-r'(['#prop-r'()], #r{}) -&gt; #r{}.
%%
%% -spec '#frommap-r'(#{a =&gt; any(), b =&gt; any(), c =&gt; any()}) -&gt; #r{}.
%%
%% -spec '#frommap-r'(#{a =&gt; any(), b =&gt; any(), c =&gt; any()}, #r{}) -&gt; #r{}.
%%
%% -spec '#pos-r'('#attr-r'() | atom()) -&gt; integer().
%%
%% -spec '#info-r'(fields) -&gt; [a | b | c];
%%                (size) -&gt; 4.
%%
%% -spec '#lens-r'('#attr-r'()) -&gt;
%%                    {fun((#r{}) -&gt; any()), fun((any(), #r{}) -&gt; #r{})}.
%%
%% -spec '#new-s'() -&gt; #s{}.
%%
%% -spec '#new-s'(['#prop-s'()]) -&gt; #s{}.
%%
%% -spec '#get-s'(a, #s{}) -&gt; any();
%%               (['#attr-s'()], #s{}) -&gt; [any()].
%%
%% -spec '#set-s'(['#prop-s'()], #s{}) -&gt; #s{}.
%%
%% -spec '#fromlist-s'(['#prop-s'()]) -&gt; #s{}.
%%
%% -spec '#fromlist-s'(['#prop-s'()], #s{}) -&gt; #s{}.
%%
%% -spec '#frommap-s'(#{a =&gt; any()}) -&gt; #s{}.
%%
%% -spec '#frommap-s'(#{a =&gt; any()}, #s{}) -&gt; #s{}.
%%
%% -spec '#pos-s'('#attr-s'() | atom()) -&gt; integer().
%%
%% -spec '#info-s'(fields) -&gt; [a];
%%                (size) -&gt; 2.
%%
%% -spec '#lens-s'('#attr-s'()) -&gt;
%%                    {fun((#s{}) -&gt; any()), fun((any(), #s{}) -&gt; #s{})}.
%%
%% -spec '#new-t'() -&gt; #t{}.
%%
%% -spec '#new-t'(['#prop-t'()]) -&gt; #t{}.
%%
%% -spec '#get-t'(['#attr-t'()], #t{}) -&gt; [any()].
%%
%% -spec '#set-t'(['#prop-t'()], #t{}) -&gt; #t{}.
%%
%% -spec '#fromlist-t'(['#prop-t'()]) -&gt; #t{}.
%%
%% -spec '#fromlist-t'(['#prop-t'()], #t{}) -&gt; #t{}.
%%
%% -spec '#frommap-t'(#{}) -&gt; #t{}.
%%
%% -spec '#frommap-t'(#{}, #t{}) -&gt; #t{}.
%%
%% -spec '#pos-t'('#attr-t'() | atom()) -&gt; integer().
%%
%% -spec '#info-t'(fields) -&gt; [];
%%                (size) -&gt; 1.
%%
%% -spec '#lens-t'('#attr-t'()) -&gt;
%%                    {fun((#t{}) -&gt; any()), fun((any(), #t{}) -&gt; #t{})}.
%%
%% -file("c:/git/etp/_checkouts/parse_trans/examples/test_exprecs.erl", 1).
%%
%% '#exported_records-'() -&gt;
%%     [r,s,t].
%%
%% '#new-'(r) -&gt;
%%     '#new-r'();
%% '#new-'(s) -&gt;
%%     '#new-s'();
%% '#new-'(t) -&gt;
%%     '#new-t'().
%%
%% '#info-'(RecName) -&gt;
%%     '#info-'(RecName, fields).
%%
%% '#info-'(r, Info) -&gt;
%%     '#info-r'(Info);
%% '#info-'(s, Info) -&gt;
%%     '#info-s'(Info);
%% '#info-'(t, Info) -&gt;
%%     '#info-t'(Info).
%%
%% '#pos-'(r, Attr) -&gt;
%%     '#pos-r'(Attr);
%% '#pos-'(s, Attr) -&gt;
%%     '#pos-s'(Attr);
%% '#pos-'(t, Attr) -&gt;
%%     '#pos-t'(Attr).
%%
%% '#is_record-'(X) -&gt;
%%     if
%%         is_record(X, r, 4) -&gt;
%%             true;
%%         is_record(X, s, 2) -&gt;
%%             true;
%%         is_record(X, t, 1) -&gt;
%%             true;
%%         true -&gt;
%%             false
%%     end.
%%
%% '#is_record-'(t, Rec) when tuple_size(Rec) == 1, element(1, Rec) == t -&gt;
%%     true;
%% '#is_record-'(s, Rec) when tuple_size(Rec) == 2, element(1, Rec) == s -&gt;
%%     true;
%% '#is_record-'(r, Rec) when tuple_size(Rec) == 4, element(1, Rec) == r -&gt;
%%     true;
%% '#is_record-'(_, _) -&gt;
%%     false.
%%
%% '#get-'(Attrs, {r,_,_,_} = Rec) when true -&gt;
%%     '#get-r'(Attrs, Rec);
%% '#get-'(Attrs, {s,_} = Rec) when true -&gt;
%%     '#get-s'(Attrs, Rec);
%% '#get-'(Attrs, {t} = Rec) when true -&gt;
%%     '#get-t'(Attrs, Rec).
%%
%% '#set-'(Vals, {r,_,_,_} = Rec) when true -&gt;
%%     '#set-r'(Vals, Rec);
%% '#set-'(Vals, {s,_} = Rec) when true -&gt;
%%     '#set-s'(Vals, Rec);
%% '#set-'(Vals, {t} = Rec) when true -&gt;
%%     '#set-t'(Vals, Rec).
%%
%% '#fromlist-'(Vals, {r,_,_,_} = Rec) when true -&gt;
%%     '#fromlist-r'(Vals, Rec);
%% '#fromlist-'(Vals, {s,_} = Rec) when true -&gt;
%%     '#fromlist-s'(Vals, Rec);
%% '#fromlist-'(Vals, {t} = Rec) when true -&gt;
%%     '#fromlist-t'(Vals, Rec).
%%
%% '#frommap-'(Vals, {r,_,_,_} = Rec) when true -&gt;
%%     '#frommap-r'(Vals, Rec);
%% '#frommap-'(Vals, {s,_} = Rec) when true -&gt;
%%     '#frommap-s'(Vals, Rec);
%% '#frommap-'(Vals, {t} = Rec) when true -&gt;
%%     '#frommap-t'(Vals, Rec).
%%
%% '#lens-'(Attr, r) -&gt;
%%     '#lens-r'(Attr);
%% '#lens-'(Attr, s) -&gt;
%%     '#lens-s'(Attr);
%% '#lens-'(Attr, t) -&gt;
%%     '#lens-t'(Attr).
%%
%% '#new-r'() -&gt;
%%     {r,0,0,0}.
%%
%% '#new-r'(Vals) -&gt;
%%     '#set-r'(Vals, {r,0,0,0}).
%%
%% '#get-r'(Attrs, R) when is_list(Attrs) -&gt;
%%     [
%%      '#get-r'(A, R) ||
%%          A &lt;- Attrs
%%     ];
%% '#get-r'(a, R) -&gt;
%%     case R of
%%         {r,rec0,_,_} -&gt;
%%             rec0;
%%         _ -&gt;
%%             error({badrecord,r})
%%     end;
%% '#get-r'(b, R) -&gt;
%%     case R of
%%         {r,_,rec1,_} -&gt;
%%             rec1;
%%         _ -&gt;
%%             error({badrecord,r})
%%     end;
%% '#get-r'(c, R) -&gt;
%%     case R of
%%         {r,_,_,rec2} -&gt;
%%             rec2;
%%         _ -&gt;
%%             error({badrecord,r})
%%     end;
%% '#get-r'(Attr, R) -&gt;
%%     error(bad_record_op, ['#get-r',Attr,R]).
%%
%% '#set-r'(Vals, Rec) -&gt;
%%     F = % fun-info: {0,0,'-#set-r/2-fun-0-'}
%%         fun([], R, _F1) -&gt;
%%                R;
%%            ([{a,V}|T], R, F1) when is_list(T) -&gt;
%%                F1(T,
%%                   begin
%%                       rec3 = R,
%%                       case rec3 of
%%                           {r,_,_,_} -&gt;
%%                               setelement(2, rec3, V);
%%                           _ -&gt;
%%                               error({badrecord,r})
%%                       end
%%                   end,
%%                   F1);
%%            ([{b,V}|T], R, F1) when is_list(T) -&gt;
%%                F1(T,
%%                   begin
%%                       rec4 = R,
%%                       case rec4 of
%%                           {r,_,_,_} -&gt;
%%                               setelement(3, rec4, V);
%%                           _ -&gt;
%%                               error({badrecord,r})
%%                       end
%%                   end,
%%                   F1);
%%            ([{c,V}|T], R, F1) when is_list(T) -&gt;
%%                F1(T,
%%                   begin
%%                       rec5 = R,
%%                       case rec5 of
%%                           {r,_,_,_} -&gt;
%%                               setelement(4, rec5, V);
%%                           _ -&gt;
%%                               error({badrecord,r})
%%                       end
%%                   end,
%%                   F1);
%%            (Vs, R, _) -&gt;
%%                error(bad_record_op, ['#set-r',Vs,R])
%%         end,
%%     F(Vals, Rec, F).
%%
%% '#fromlist-r'(Vals) when is_list(Vals) -&gt;
%%     '#fromlist-r'(Vals, '#new-r'()).
%%
%% '#fromlist-r'(Vals, Rec) -&gt;
%%     AttrNames = [{a,2},{b,3},{c,4}],
%%     F = % fun-info: {0,0,'-#fromlist-r/2-fun-0-'}
%%         fun([], R, _F1) -&gt;
%%                R;
%%            ([{H,Pos}|T], R, F1) when is_list(T) -&gt;
%%                case lists:keyfind(H, 1, Vals) of
%%                    false -&gt;
%%                        F1(T, R, F1);
%%                    {_,Val} -&gt;
%%                        F1(T, setelement(Pos, R, Val), F1)
%%                end
%%         end,
%%     F(AttrNames, Rec, F).
%%
%% '#frommap-r'(Vals) when is_map(Vals) -&gt;
%%     '#frommap-r'(Vals, '#new-r'()).
%%
%% '#frommap-r'(Vals, Rec) -&gt;
%%     List = maps:to_list(Vals),
%%     '#fromlist-r'(List, Rec).
%%
%% '#pos-r'(a) -&gt;
%%     2;
%% '#pos-r'(b) -&gt;
%%     3;
%% '#pos-r'(c) -&gt;
%%     4;
%% '#pos-r'(A) when is_atom(A) -&gt;
%%     0.
%%
%% '#info-r'(fields) -&gt;
%%     [a,b,c];
%% '#info-r'(size) -&gt;
%%     4.
%%
%% '#lens-r'(a) -&gt;
%%     {% fun-info: {0,0,'-#lens-r/1-fun-0-'}
%%      fun(R) -&gt;
%%             '#get-r'(a, R)
%%      end,
%%      % fun-info: {0,0,'-#lens-r/1-fun-1-'}
%%      fun(X, R) -&gt;
%%             '#set-r'([{a,X}], R)
%%      end};
%% '#lens-r'(b) -&gt;
%%     {% fun-info: {0,0,'-#lens-r/1-fun-2-'}
%%      fun(R) -&gt;
%%             '#get-r'(b, R)
%%      end,
%%      % fun-info: {0,0,'-#lens-r/1-fun-3-'}
%%      fun(X, R) -&gt;
%%             '#set-r'([{b,X}], R)
%%      end};
%% '#lens-r'(c) -&gt;
%%     {% fun-info: {0,0,'-#lens-r/1-fun-4-'}
%%      fun(R) -&gt;
%%             '#get-r'(c, R)
%%      end,
%%      % fun-info: {0,0,'-#lens-r/1-fun-5-'}
%%      fun(X, R) -&gt;
%%             '#set-r'([{c,X}], R)
%%      end};
%% '#lens-r'(Attr) -&gt;
%%     error(bad_record_op, ['#lens-r',Attr]).
%%
%% '#new-s'() -&gt;
%%     {s,undefined}.
%%
%% '#new-s'(Vals) -&gt;
%%     '#set-s'(Vals, {s,undefined}).
%%
%% '#get-s'(Attrs, R) when is_list(Attrs) -&gt;
%%     [
%%      '#get-s'(A, R) ||
%%          A &lt;- Attrs
%%     ];
%% '#get-s'(a, R) -&gt;
%%     case R of
%%         {s,rec6} -&gt;
%%             rec6;
%%         _ -&gt;
%%             error({badrecord,s})
%%     end;
%% '#get-s'(Attr, R) -&gt;
%%     error(bad_record_op, ['#get-s',Attr,R]).
%%
%% '#set-s'(Vals, Rec) -&gt;
%%     F = % fun-info: {0,0,'-#set-s/2-fun-0-'}
%%         fun([], R, _F1) -&gt;
%%                R;
%%            ([{a,V}|T], R, F1) when is_list(T) -&gt;
%%                F1(T,
%%                   begin
%%                       rec7 = R,
%%                       case rec7 of
%%                           {s,rec8} -&gt;
%%                               {s,V};
%%                           _ -&gt;
%%                               error({badrecord,s})
%%                       end
%%                   end,
%%                   F1);
%%            (Vs, R, _) -&gt;
%%                error(bad_record_op, ['#set-s',Vs,R])
%%         end,
%%     F(Vals, Rec, F).
%%
%% '#fromlist-s'(Vals) when is_list(Vals) -&gt;
%%     '#fromlist-s'(Vals, '#new-s'()).
%%
%% '#fromlist-s'(Vals, Rec) -&gt;
%%     AttrNames = [{a,2}],
%%     F = % fun-info: {0,0,'-#fromlist-s/2-fun-0-'}
%%         fun([], R, _F1) -&gt;
%%                R;
%%            ([{H,Pos}|T], R, F1) when is_list(T) -&gt;
%%                case lists:keyfind(H, 1, Vals) of
%%                    false -&gt;
%%                        F1(T, R, F1);
%%                    {_,Val} -&gt;
%%                        F1(T, setelement(Pos, R, Val), F1)
%%                end
%%         end,
%%     F(AttrNames, Rec, F).
%%
%% '#frommap-s'(Vals) when is_map(Vals) -&gt;
%%     '#frommap-s'(Vals, '#new-s'()).
%%
%% '#frommap-s'(Vals, Rec) -&gt;
%%     List = maps:to_list(Vals),
%%     '#fromlist-s'(List, Rec).
%%
%% '#pos-s'(a) -&gt;
%%     2;
%% '#pos-s'(A) when is_atom(A) -&gt;
%%     0.
%%
%% '#info-s'(fields) -&gt;
%%     [a];
%% '#info-s'(size) -&gt;
%%     2.
%%
%% '#lens-s'(a) -&gt;
%%     {% fun-info: {0,0,'-#lens-s/1-fun-0-'}
%%      fun(R) -&gt;
%%             '#get-s'(a, R)
%%      end,
%%      % fun-info: {0,0,'-#lens-s/1-fun-1-'}
%%      fun(X, R) -&gt;
%%             '#set-s'([{a,X}], R)
%%      end};
%% '#lens-s'(Attr) -&gt;
%%     error(bad_record_op, ['#lens-s',Attr]).
%%
%% '#new-t'() -&gt;
%%     {t}.
%%
%% '#new-t'(Vals) -&gt;
%%     '#set-t'(Vals, {t}).
%%
%% '#get-t'(Attrs, R) when is_list(Attrs) -&gt;
%%     [
%%      '#get-t'(A, R) ||
%%          A &lt;- Attrs
%%     ];
%% '#get-t'(Attr, R) -&gt;
%%     error(bad_record_op, ['#get-t',Attr,R]).
%%
%% '#set-t'(Vals, Rec) -&gt;
%%     F = % fun-info: {0,0,'-#set-t/2-fun-0-'}
%%         fun([], R, _F1) -&gt;
%%                R;
%%            (Vs, R, _) -&gt;
%%                error(bad_record_op, ['#set-t',Vs,R])
%%         end,
%%     F(Vals, Rec, F).
%%
%% '#fromlist-t'(Vals) when is_list(Vals) -&gt;
%%     '#fromlist-t'(Vals, '#new-t'()).
%%
%% '#fromlist-t'(Vals, Rec) -&gt;
%%     AttrNames = [],
%%     F = % fun-info: {0,0,'-#fromlist-t/2-fun-0-'}
%%         fun([], R, _F1) -&gt;
%%                R;
%%            ([{H,Pos}|T], R, F1) when is_list(T) -&gt;
%%                case lists:keyfind(H, 1, Vals) of
%%                    false -&gt;
%%                        F1(T, R, F1);
%%                    {_,Val} -&gt;
%%                        F1(T, setelement(Pos, R, Val), F1)
%%                end
%%         end,
%%     F(AttrNames, Rec, F).
%%
%% '#frommap-t'(Vals) when is_map(Vals) -&gt;
%%     '#frommap-t'(Vals, '#new-t'()).
%%
%% '#frommap-t'(Vals, Rec) -&gt;
%%     List = maps:to_list(Vals),
%%     '#fromlist-t'(List, Rec).
%%
%% '#pos-t'(A) when is_atom(A) -&gt;
%%     0.
%%
%% '#info-t'(fields) -&gt;
%%     [];
%% '#info-t'(size) -&gt;
%%     1.
%%
%% '#lens-t'(Attr) -&gt;
%%     error(bad_record_op, ['#lens-t',Attr]).
%%
%% f() -&gt;
%%     foo.
%% </pre>
%%
%% It is possible to modify the naming rules of exprecs, through the use
%% of the following attributes (example reflecting the current rules):
%%
%% <pre>
%% -exprecs_prefix(["#", operation, "-"]).
%% -exprecs_fname([prefix, record]).
%% -exprecs_vfname([fname, "__", version]).
%% </pre>
%%
%% The lists must contain strings or any of the following control atoms:
%% <ul>
%% <li>in `exprecs_prefix': `operation'</li>
%% <li>in `exprecs_fname': `operation', `record', `prefix'</li>
%% <li>in `exprecs_vfname': `operation', `record', `prefix', `fname', `version'
%% </li>
%% </ul>
%%
%% Exprecs will substitute the control atoms with the string values of the
%% corresponding items. The result will then be flattened and converted to an
%% atom (a valid function or type name).
%%
%% `operation' is one of:
%% <dl>
%% <dt>`new'</dt> <dd>Creates a new record</dd>
%% <dt>`get'</dt> <dd>Retrieves given attribute values from a record</dd>
%% <dt>`set'</dt> <dd>Sets given attribute values in a record</dd>
%% <dt>`fromlist'</dt> <dd>Creates a record from a key-value list</dd>
%% <dt>`info'</dt> <dd>Equivalent to record_info/2</dd>
%% <dt>`pos'</dt> <dd>Returns the position of a given attribute</dd>
%% <dt>`is_record'</dt> <dd>Tests if a value is a specific record</dd>
%% <dt>`convert'</dt> <dd>Converts an old record to the current version</dd>
%% <dt>`prop'</dt> <dd>Used only in type specs</dd>
%% <dt>`attr'</dt> <dd>Used only in type specs</dd>
%% <dt>`lens'</dt> <dd>Returns a 'lens' (an accessor pair) as described in
%%              [http://github.com/jlouis/erl-lenses]</dd>
%% </dl>
%%
%% @end

-module(exprecs).

-export([parse_transform/2,
         format_error/1,
%        transform/3,
         context/2]).

-record(context, {module,
                  function,
                  arity}).

-record(pass1, {exports = [],
                generated = false,
                records = [],
                record_types = [],
                versions = orddict:new(),
                inserted = false,
                prefix = ["#", operation, "-"],
                fname = [prefix, record],
                vfname = [fname, "__", version]}).

-include("../include/codegen.hrl").

-define(HERE, {?MODULE, ?LINE}).

-define(ERROR(R, F, I),
        begin
            rpt_error(R, F, I),
            throw({error,get_pos(I),{unknown,R}})
        end).

-type form()    :: any().
-type forms()   :: [form()].
-type options() :: [{atom(), any()}].


get_pos(I) ->
    case proplists:get_value(form, I) of
        undefined ->
            0;
        Form ->
            Anno = erl_syntax:get_pos(Form),
            erl_anno:location(Anno)
    end.

-spec parse_transform(forms(), options()) ->
    forms().
parse_transform(Forms, Options) ->
    parse_trans:top(fun do_transform/2, Forms, Options).

do_transform(Forms, Context) ->
    Acc1 = versioned_records(
             add_untyped_recs(
               parse_trans:do_inspect(fun inspect_f/4, #pass1{},
                                      Forms, Context))),
    {Forms2, Acc2} =
        parse_trans:do_transform(fun generate_f/4, Acc1, Forms, Context),
    parse_trans:revert(verify_generated(Forms2, Acc2, Context)).

add_untyped_recs(#pass1{records = Rs,
                        record_types = RTypes,
                        exports = Es} = Acc) ->
    Untyped =
        [{R, Def} || {R, Def} <- Rs,
                     lists:member(R, Es),
                     not lists:keymember(R, 1, RTypes)],
    RTypes1 = [{R, lists:map(
                     fun({record_field,L,{atom,_,A}}) -> {A, t_any(L)};
                        ({record_field,L,{atom,_,A},_}) -> {A, t_any(L)};
                        ({typed_record_field,
                          {record_field,L,{atom,_,A}},_}) -> {A, t_any(L)};
                        ({typed_record_field,
                          {record_field,L,{atom,_,A},_},_}) -> {A, t_any(L)}
                     end, Def)} || {R, Def} <- Untyped],
    Acc#pass1{record_types = RTypes ++ RTypes1}.

inspect_f(attribute, {attribute,_L,exprecs_prefix,Pattern}, _Ctxt, Acc) ->
    {false, Acc#pass1{prefix = Pattern}};
inspect_f(attribute, {attribute,_L,exprecs_fname,Pattern}, _Ctxt, Acc) ->
    {false, Acc#pass1{fname = Pattern}};
inspect_f(attribute, {attribute,_L,exprecs_vfname,Pattern}, _Ctxt, Acc) ->
    {false, Acc#pass1{vfname = Pattern}};
inspect_f(attribute, {attribute,_L,record,RecDef}, _Ctxt, Acc) ->
    Recs0 = Acc#pass1.records,
    {false, Acc#pass1{records = [RecDef|Recs0]}};
inspect_f(attribute, {attribute,_L,export_records, E}, _Ctxt, Acc) ->
    Exports0 = Acc#pass1.exports,
    NewExports = Exports0 ++ E,
    {false, Acc#pass1{exports = NewExports}};
inspect_f(attribute, {attribute, _L, type,
                      {{record, R}, RType,_}}, _Ctxt, Acc) ->
    Type = lists:map(
             fun({typed_record_field, {record_field,_,{atom,_,A}}, T}) ->
                     {A, T};
                ({typed_record_field, {record_field,_,{atom,_,A},_}, T}) ->
                     {A, T};
                ({record_field, _, {atom,L,A}, _}) ->
                     {A, t_any(L)};
                ({record_field, _, {atom,L,A}}) ->
                     {A, t_any(L)}
             end, RType),
    {false, Acc#pass1{record_types = [{R, Type}|Acc#pass1.record_types]}};
inspect_f(_Type, _Form, _Context, Acc) ->
    {false, Acc}.

generate_f(attribute, {attribute,L,export_records,_} = Form, _Ctxt,
            #pass1{exports = [_|_] = Es, versions = Vsns,
                   inserted = false} = Acc) ->
    case check_record_names(Es, L, Acc) of
        ok -> continue;
        {error, Bad} ->
            ?ERROR(invalid_record_exports, ?HERE, Bad)
    end,
    Exports = [{fname(exported_records, Acc), 0},
               {fname(new, Acc), 1},
               {fname(info, Acc), 1},
               {fname(info, Acc), 2},
               {fname(pos, Acc), 2},
               {fname(is_record, Acc), 1},
               {fname(is_record, Acc), 2},
               {fname(get, Acc), 2},
               {fname(set, Acc), 2},
               {fname(fromlist, Acc), 2},
               {fname(frommap, Acc), 2},
               {fname(lens, Acc), 2} |
               lists:flatmap(
                 fun(Rec) ->
                         RecS = atom_to_list(Rec),
                         FNew = fname(new, RecS, Acc),
                         [{FNew, 0}, {FNew,1},
                          {fname(get, RecS, Acc), 2},
                          {fname(set, RecS, Acc), 2},
                          {fname(pos, RecS, Acc), 1},
                          {fname(fromlist, RecS, Acc), 1},
                          {fname(frommap, RecS, Acc), 1},
                          {fname(fromlist, RecS, Acc), 2},
                          {fname(frommap, RecS, Acc), 2},
                          {fname(info, RecS, Acc), 1},
                          {fname(lens, RecS, Acc), 1}]
                 end, Es)] ++ version_exports(Vsns, Acc),
    TypeExports =
        lists:flatmap(
          fun(Rec) ->
                  [{fname(prop, Rec, Acc), 0},
                   {fname(attr, Rec, Acc), 0}]
          end, Es),
    {[], Form,
     [{attribute,L,export,Exports},
      {attribute,L,ignore_xref,Exports},
      {attribute,L,export_type, TypeExports}],
     false, Acc#pass1{inserted = true}};
generate_f(function, Form, _Context, #pass1{generated = false} = Acc) ->
    % Layout record funs before first function
    Anno = erl_syntax:get_pos(Form),
    L = erl_anno:location(Anno),
    Forms = generate_specs_and_accessors(L, Acc),
    {Forms, Form, [], false, Acc#pass1{generated = true}};
generate_f(_Type, Form, _Ctxt, Acc) ->
    {Form, false, Acc}.

generate_specs_and_accessors(L, #pass1{exports = [_|_] = Es,
                                       record_types = Ts} = Acc) ->
    Specs = generate_specs(L, [{R,T} || {R,T} <- Ts, lists:member(R, Es)], Acc),
    Funs = generate_accessors(L, Acc),
    Specs ++ Funs;
generate_specs_and_accessors(_, _) ->
    [].

verify_generated(Forms, #pass1{} = Acc, _Context) ->
    case (Acc#pass1.generated == true) orelse (Acc#pass1.exports == []) of
        true ->
            Forms;
        false ->
            % should be re-written to use the parse_trans helper...?
            [{eof,Last}|RevForms] = lists:reverse(Forms),
            Anno = erl_anno:new(Last),
            [{function, NewLast, _, _, _}|_] = RevAs =
                lists:reverse(generate_specs_and_accessors(Anno, Acc)),
            Loc = erl_anno:location(NewLast),
            lists:reverse([{eof, increment_line(Loc)} | RevAs] ++ RevForms)
    end.

increment_line(L) when is_integer(L) ->
    L + 1;
increment_line({L, C}) when is_integer(L), is_integer(C) ->
    {L + 1, C}.

check_record_names(Es, L, #pass1{records = Rs}) ->
    case [E || E <- Es,
               not(lists:keymember(E, 1, Rs))] of
        [] ->
            ok;
        Bad ->
            {error, [{L,E} || E <- Bad]}
    end.

versioned_records(#pass1{exports = Es, records = Rs} = Pass1) ->
    case split_recnames(Rs) of
        [] ->
            Pass1#pass1{versions = []};
        [_|_] = Versions ->
            Exp_vsns =
                lists:foldl(
                  fun(Re, Acc) ->
                          case orddict:find(atom_to_list(Re), Versions) of
                              {ok, Vs} ->
                                  orddict:store(Re, Vs, Acc);
                              error ->
                                  Acc
                          end
                  end, orddict:new(), Es),
            Pass1#pass1{versions = Exp_vsns}
    end.

version_exports([], _Acc) ->
    [];
version_exports([_|_] = _Vsns, Acc) ->
    [{list_to_atom(fname_prefix(info, Acc)), 3},
     {list_to_atom(fname_prefix(convert, Acc)), 2}].


version_accessors(_L, #pass1{versions = []}) ->
    [];
version_accessors(L, #pass1{versions = Vsns} = Acc) ->
    Flat_vsns = flat_versions(Vsns),
    [f_convert(Vsns, L, Acc),
     f_info_3(Vsns, L, Acc)]
        ++ [f_info_1(Rname, Acc, L, V) || {Rname,V} <- Flat_vsns].

flat_versions(Vsns) ->
    lists:flatmap(fun({R,Vs}) ->
                          [{R,V} || V <- Vs]
                  end, Vsns).

split_recnames(Rs) ->
    lists:foldl(
      fun({R,_As}, Acc) ->
              case re:split(atom_to_list(R), "__", [{return, list}]) of
                  [Base, V] ->
                      orddict:append(Base,V,Acc);
                  [_] ->
                      Acc
              end
      end, orddict:new(), Rs).

generate_specs(L, Specs, Acc) ->
    [[
      {attribute, L, type,
      {fname(prop, R, Acc),
       {type, L, union,
        [{type, L, tuple, [{atom,L,A},T]} || {A,T} <- Attrs]}, []}},
      {attribute, L, type,
       {fname(attr, R, Acc),
        {type, L, union,
         [{atom, L, A} || {A,_} <- Attrs]}, []}}
     ] || {R, Attrs} <- Specs, Attrs =/= []] ++
        [[{attribute, L, type,
           {fname(prop, R, Acc),
            {type, L, any, []}, []}},
          {attribute, L, type,
           {fname(attr, R, Acc),
            {type, L, any, []}, []}}] || {R, []} <- Specs].


generate_accessors(L, Acc) ->
    lists:flatten(
      [f_exported_recs(Acc, L),
       f_new_(Acc, L),
       f_info(Acc, L),
       f_info_2(Acc, L),
       f_pos_2(Acc, L),
       f_isrec_1(Acc, L),
       f_isrec_2(Acc, L),
       f_get(Acc, L),
       f_set(Acc, L),
       f_fromlist(Acc, L),
       f_frommap(Acc, L),
       f_lens_(Acc, L)|
       lists:append(
         lists:map(
           fun(Rname) ->
                   Fields = get_flds(Rname, Acc),
                   [f_new_0(Rname, L, Acc),
                    f_new_1(Rname, L, Acc),
                    f_get_2(Rname, Fields, L, Acc),
                    f_set_2(Rname, Fields, L, Acc),
                    f_fromlist_1(Rname, L, Acc),
                    f_fromlist_2(Rname, Fields, L, Acc),
                    f_frommap_1(Rname, L, Acc),
                    f_frommap_2(Rname, L, Acc),
                    f_pos_1(Rname, Fields, L, Acc),
                    f_info_1(Rname, Acc, L),
                    f_lens_1(Rname, Fields, L, Acc)]
           end, Acc#pass1.exports))] ++ version_accessors(L, Acc)).

get_flds(Rname, #pass1{records = Rs}) ->
    {_, Flds} = lists:keyfind(Rname, 1, Rs),
    lists:map(
      fun({record_field,_, {atom,_,N}}) -> N;
         ({record_field,_, {atom,_,N}, _}) -> N;
         ({typed_record_field,{record_field,_,{atom,_,N}},_}) -> N;
         ({typed_record_field,{record_field,_,{atom,_,N},_},_}) -> N
      end, Flds).


fname_prefix(Op, #pass1{prefix = Pat}) ->
    lists:flatten(
      lists:map(fun(operation) -> str(Op);
                   (X) -> str(X)
                end, Pat)).
%% fname_prefix(Op, #pass1{} = Acc) ->
%%     case Op of
%%      new -> "#new-";
%%      get -> "#get-";
%%      set -> "#set-";
%%      fromlist -> "#fromlist-";
%%      info     -> "#info-";
%%         pos      -> "#pos-";
%%      is_record   -> "#is_record-";
%%         convert  -> "#convert-";
%%      prop     -> "#prop-";
%%      attr     -> "#attr-"
%%     end.

%% fname_prefix(Op, Rname, Acc) ->
%%     fname_prefix(Op, Acc) ++ str(Rname).

str(A) when is_atom(A) ->
    atom_to_list(A);
str(S) when is_list(S) ->
    S.

fname(Op, #pass1{} = Acc) ->
    list_to_atom(fname_prefix(Op, Acc)).
    %% list_to_atom(fname_prefix(Op, Acc)).

fname(Op, Rname, #pass1{fname = FPat} = Acc) ->
    Prefix = fname_prefix(Op, Acc),
    list_to_atom(
      lists:flatten(
        lists:map(fun(prefix) -> str(Prefix);
                     (record) -> str(Rname);
                     (operation) -> str(Op);
                     (X) -> str(X)
                  end, FPat))).
    %% list_to_atom(fname_prefix(Op, Rname, Acc)).

fname(Op, Rname, V, #pass1{vfname = VPat} = Acc) ->
    list_to_atom(
      lists:flatten(
        lists:map(fun(prefix) -> fname_prefix(Op, Acc);
                     (operation) -> str(Op);
                     (record) -> str(Rname);
                     (version) -> str(V);
                     (fname) -> str(fname(Op, Rname, Acc));
                     (X) -> str(X)
                  end, VPat))).
    %% list_to_atom(fname_prefix(Op, Rname, Acc) ++ "__" ++ V).


%%% Meta functions

f_exported_recs(#pass1{exports = Es} = Acc, L) ->
    Fname = fname(exported_records, Acc),
    [funspec(L, Fname, [],
             t_list(L, [t_union(L, [t_atom(L, E) || E <- Es])])),
     {function, L, Fname, 0,
      [{clause, L, [], [],
        [erl_parse:abstract(Es, L)]}]}
    ].

%%% Accessor functions
%%%
f_new_(#pass1{exports = Es} = Acc, L) ->
    Fname = fname(new, Acc),
    [funspec(L, Fname, [ {[t_atom(L, E)], t_record(L, E)} ||
                           E <- Es ]),
     {function, L, fname(new, Acc), 1,
      [{clause, L, [{atom, L, Re}], [],
        [{call, L, {atom, L, fname(new, Re, Acc)}, []}]}
       || Re <- Es]}
    ].

f_new_0(Rname, L, Acc) ->
    Fname = fname(new, Rname, Acc),
    [funspec(L, Fname, [], t_record(L, Rname)),
     {function, L, fname(new, Rname, Acc), 0,
      [{clause, L, [], [],
        [{record, L, Rname, []}]}]}
    ].


f_new_1(Rname, L, Acc) ->
    Fname = fname(new, Rname, Acc),
    [funspec(L, Fname, [t_list(L, [t_prop(L, Rname, Acc)])],
             t_record(L, Rname)),
    {function, L, Fname, 1,
     [{clause, L, [{var, L, 'Vals'}], [],
       [{call, L, {atom, L, fname(set, Rname, Acc)},
         [{var, L, 'Vals'},
          {record, L, Rname, []}
         ]}]
       }]}].

funspec(L, Fname, [{H,_} | _] = Alts) ->
    Arity = length(H),
    {attribute, L, spec,
     {{Fname, Arity},
      [{type, L, 'fun', [{type, L, product, Head}, Ret]} ||
          {Head, Ret} <- Alts,
          no_empty_union(Head)]}}.

no_empty_union({type,_,union,[]}) ->
    false;
no_empty_union(T) when is_tuple(T) ->
    no_empty_union(tuple_to_list(T));
no_empty_union([H|T]) ->
    no_empty_union(H) andalso no_empty_union(T);
no_empty_union(_) ->
    true.




funspec(L, Fname, Head, Returns) ->
    Arity = length(Head),
    {attribute, L, spec,
     {{Fname, Arity},
      [{type, L, 'fun',
        [{type, L, product, Head}, Returns]}]}}.


t_prop(L, Rname, Acc) -> {user_type, L, fname(prop, Rname, Acc), []}.
t_attr(L, Rname, Acc) -> {user_type, L, fname(attr, Rname, Acc), []}.
t_union(L, Alt)   -> {type, L, union, lists:usort(Alt)}.
t_any(L)          -> {type, L, any, []}.
t_atom(L)         -> {type, L, atom, []}.
t_atom(L, A)      -> {atom, L, A}.
t_integer(L)      -> {type, L, integer, []}.
t_integer(L, I)   -> {integer, L, I}.
t_list(L, Es)     -> {type, L, list, Es}.
t_fun(L, As, Res) -> {type, L, 'fun', [{type, L, product, As}, Res]}.
t_tuple(L, Es)    -> {type, L, tuple, Es}.
t_boolean(L)     -> {type, L, boolean, []}.
t_record(L, A)   -> {type, L, record, [{atom, L, A}]}.
t_map(L, Rname, Acc) -> {type, L, map,
                         [{type, L, map_field_assoc, [t_atom(L, F), t_any(L)]}
                          || F <- get_flds(Rname, Acc)
                         ]
                        }.

f_set_2(Rname, Flds, L, Acc) ->
    Fname = fname(set, Rname, Acc),
    TRec = t_record(L, Rname),
    [funspec(L, Fname, [t_list(L, [t_prop(L, Rname, Acc)]), TRec], TRec),
     {function, L, Fname, 2,
      [{clause, L, [{var, L, 'Vals'}, {var, L, 'Rec'}], [],
        [{match, L, {var, L, 'F'},
          {'fun', L,
           {clauses,
            [{clause, L, [{nil,L},
                          {var,L,'R'},
                          {var,L,'_F1'}],
              [],
              [{var, L, 'R'}]} |
             [{clause, L,
               [{cons, L, {tuple, L, [{atom, L, Attr},
                                      {var,  L, 'V'}]},
                 {var, L, 'T'}},
                {var, L, 'R'},
                {var, L, 'F1'}],
               [[{call, L, {atom, L, is_list}, [{var, L, 'T'}]}]],
               [{call, L, {var, L, 'F1'},
                 [{var,L,'T'},
                  {record, L, {var,L,'R'}, Rname,
                   [{record_field, L,
                     {atom, L, Attr},
                     {var, L, 'V'}}]},
                  {var, L, 'F1'}]}]} || Attr <- Flds]
             ++ [{clause, L, [{var, L, 'Vs'}, {var,L,'R'},{var,L,'_'}],
                  [],
                  [bad_record_op(L, Fname, 'Vs', 'R')]}]
            ]}}},
         {call, L, {var, L, 'F'}, [{var, L, 'Vals'},
                                   {var, L, 'Rec'},
                                   {var, L, 'F'}]}]}]}].

bad_record_op(L, Fname, Val) ->
    {call, L, {remote, L, {atom,L,erlang}, {atom,L,error}},
     [{atom,L,bad_record_op}, {cons, L, {atom, L, Fname},
                               {cons, L, {var, L, Val},
                                {nil, L}}}]}.

bad_record_op(L, Fname, Val, R) ->
    {call, L, {remote, L, {atom,L,erlang}, {atom,L,error}},
     [{atom,L,bad_record_op}, {cons, L, {atom, L, Fname},
                               {cons, L, {var, L, Val},
                                {cons, L, {var, L, R},
                                 {nil, L}}}}]}.


f_pos_1(Rname, Flds, L, Acc) ->
    Fname = fname(pos, Rname, Acc),
    FieldList = lists:zip(Flds, lists:seq(2, length(Flds)+1)),
    [
     funspec(L, Fname, [t_union(L, [t_attr(L, Rname, Acc),
                                    t_atom(L)])],
             t_integer(L)),
     {function, L, Fname, 1,
      [{clause, L,
        [{atom, L, FldName}],
        [],
        [{integer, L, Pos}]} || {FldName, Pos} <- FieldList] ++
          [{clause, L,
            [{var, L, 'A'}],
            [[{call, L, {atom, L, is_atom}, [{var, L, 'A'}]}]],
            [{integer, L, 0}]}]
     }].

f_frommap_1(Rname, L, Acc) ->
    Fname = fname(frommap, Rname, Acc),
    [
     funspec(L, Fname, [t_map(L, Rname, Acc)],
             t_record(L, Rname)),
     {function, L, Fname, 1,
      [{clause, L, [{var, L, 'Vals'}],
        [[ {call, L, {atom, L, is_map}, [{var, L, 'Vals'}]} ]],
        [{call, L, {atom, L, Fname},
          [{var, L, 'Vals'},
           {call, L, {atom, L, fname(new, Rname, Acc)}, []}]}
        ]}
      ]}].

f_fromlist_1(Rname, L, Acc) ->
    Fname = fname(fromlist, Rname, Acc),
    [
     funspec(L, Fname, [t_list(L, [t_prop(L, Rname, Acc)])],
             t_record(L, Rname)),
     {function, L, Fname, 1,
      [{clause, L, [{var, L, 'Vals'}],
        [[ {call, L, {atom, L, is_list}, [{var, L, 'Vals'}]} ]],
        [{call, L, {atom, L, Fname},
          [{var, L, 'Vals'},
           {call, L, {atom, L, fname(new, Rname, Acc)}, []}]}
        ]}
      ]}].

f_frommap_2(Rname, L, Acc) ->
    Fname = fname(frommap, Rname, Acc),
    TRec = t_record(L, Rname),
    [
     funspec(L, Fname, [t_map(L, Rname, Acc), TRec],
             TRec),
     {function, L, Fname, 2,
      [{clause, L, [{var, L, 'Vals'}, {var, L, 'Rec'}], [],
        [{match, L, {var, L, 'List'},
          {call, L, {remote, L, {atom, L, maps}, {atom, L, to_list}},
           [{var, L, 'Vals'}]
          }
         },
         {call, L, {atom, L, fname(fromlist, Rname, Acc)},
          [{var, L, 'List'}, {var, L, 'Rec'}]
         }
        ]}
      ]}].

f_fromlist_2(Rname, Flds, L, Acc) ->
    Fname = fname(fromlist, Rname, Acc),
    FldList = field_list(Flds),
    TRec = t_record(L, Rname),
    [
     funspec(L, Fname, [t_list(L, [t_prop(L, Rname, Acc)]), TRec],
             TRec),
     {function, L, Fname, 2,
      [{clause, L, [{var, L, 'Vals'}, {var, L, 'Rec'}], [],
        [{match, L, {var, L, 'AttrNames'}, FldList},
         {match, L, {var, L, 'F'},
          {'fun', L,
           {clauses,
            [{clause, L, [{nil, L},
                          {var, L,'R'},
                          {var, L,'_F1'}],
              [],
              [{var, L, 'R'}]},
             {clause, L, [{cons, L,
                           {tuple, L, [{var, L, 'H'},
                                       {var, L, 'Pos'}]},
                           {var, L, 'T'}},
                          {var, L, 'R'}, {var, L, 'F1'}],
              [[{call, L, {atom, L, is_list}, [{var, L, 'T'}]}]],
              [{'case', L, {call, L, {remote, L,
                                      {atom,L,lists},{atom,L,keyfind}},
                            [{var,L,'H'},{integer,L,1},{var,L,'Vals'}]},
                [{clause, L, [{atom,L,false}], [],
                  [{call, L, {var, L, 'F1'}, [{var, L, 'T'},
                                              {var, L, 'R'},
                                              {var, L, 'F1'}]}]},
                 {clause, L, [{tuple, L, [{var,L,'_'},{var,L,'Val'}]}],
                  [],
                  [{call, L, {var, L, 'F1'},
                    [{var, L, 'T'},
                     {call, L, {atom, L, 'setelement'},
                      [{var, L, 'Pos'}, {var, L, 'R'}, {var, L, 'Val'}]},
                     {var, L, 'F1'}]}]}
                ]}
              ]}
            ]}}},
         {call, L, {var, L, 'F'}, [{var, L, 'AttrNames'},
                                   {var, L, 'Rec'},
                                   {var, L, 'F'}]}
        ]}
      ]}].

field_list(Flds) ->
    erl_parse:abstract(
      lists:zip(Flds, lists:seq(2, length(Flds)+1))).



f_get_2(R, Flds, L, Acc) ->
    FName = fname(get, R, Acc),
    {_, Types} = lists:keyfind(R, 1, Acc#pass1.record_types),
    [funspec(L, FName,
             [{[t_atom(L, A), t_record(L, R)], T}
                 || {A, T} <- Types]
             ++ [{[t_list(L, [t_attr(L, R, Acc)]), t_record(L, R)],
                  t_list(L, [t_any(L)])}]
            ),
    {function, L, FName, 2,
     [{clause, L, [{var, L, 'Attrs'}, {var, L, 'R'}],
       [[{call, L, {atom, L, is_list}, [{var, L, 'Attrs'}]}]],
       [{lc, L, {call, L, {atom, L, FName}, [{var, L, 'A'}, {var, L, 'R'}]},
         [{generate, L, {var, L, 'A'}, {var, L, 'Attrs'}}]}]
       } |
      [{clause, L, [{atom, L, Attr}, {var, L, 'R'}], [],
        [{record_field, L, {var, L, 'R'}, R, {atom, L, Attr}}]} ||
          Attr <- Flds]] ++
     [{clause, L, [{var, L, 'Attr'}, {var, L, 'R'}], [],
       [bad_record_op(L, FName, 'Attr', 'R')]}]
    }].


f_info(Acc, L) ->
    Fname = list_to_atom(fname_prefix(info, Acc)),
    [funspec(L, Fname,
             [{[t_atom(L, R)],
               t_list(L, [t_attr(L, R, Acc)])}
              || R <- Acc#pass1.exports]),
     {function, L, Fname, 1,
      [{clause, L,
        [{var, L, 'RecName'}], [],
        [{call, L, {atom, L, Fname}, [{var, L, 'RecName'}, {atom, L, fields}]}]
       }]}
    ].

f_isrec_2(#pass1{records = Rs, exports = Es} = Acc, L) ->
    Fname = list_to_atom(fname_prefix(is_record, Acc)),
    Info = [{R,length(As) + 1} || {R,As} <- Rs, lists:member(R, Es)],
    [%% This contract is correct, but is ignored by Dialyzer because it
     %% has overlapping domains:
     %% funspec(L, Fname,
     %%              [{[t_atom(L, R), t_record(L, R)], t_atom(L, true)}
     %%               || R <- Es] ++
     %%                  [{[t_any(L), t_any(L)], t_atom(L, false)}]),
     %% This is less specific, but more useful to Dialyzer:
     funspec(L, Fname, [{[t_any(L), t_any(L)], t_boolean(L)}]),
     {function, L, Fname, 2,
      lists:map(
        fun({R, Ln}) ->
                {clause, L,
                 [{atom, L, R}, {var, L, 'Rec'}],
                 [[{op,L,'==',
                    {call, L, {atom,L,tuple_size},[{var,L,'Rec'}]},
                    {integer, L, Ln}},
                   {op,L,'==',
                    {call,L,{atom,L,element},[{integer,L,1},
                                              {var,L,'Rec'}]},
                    {atom, L, R}}]],
                 [{atom, L, true}]}
        end, Info) ++
          [{clause, L, [{var,L,'_'}, {var,L,'_'}], [],
            [{atom, L, false}]}]}
    ].


f_info_2(Acc, L) ->
    Fname = list_to_atom(fname_prefix(info, Acc)),
    [funspec(L, Fname,
             lists:flatmap(
               fun(Rname) ->
                       Flds = get_flds(Rname, Acc),
                       TRec = t_atom(L, Rname),
                       [{[TRec, t_atom(L, size)], t_integer(L, length(Flds)+1)},
                        {[TRec, t_atom(L, fields)],
                         t_list(L, [t_attr(L, Rname, Acc)])}]
               end, Acc#pass1.exports)),
     {function, L, Fname, 2,
      [{clause, L,
        [{atom, L, R},
         {var, L, 'Info'}],
        [],
        [{call, L, {atom, L, fname(info, R, Acc)}, [{var, L, 'Info'}]}]} ||
          R <- Acc#pass1.exports]}
    ].

f_info_3(Versions, L, Acc) ->
    Fname = list_to_atom(fname_prefix(info, Acc)),
    [
    {function, L, Fname, 3,
     [{clause, L,
       [{atom, L, R},
        {var, L, 'Info'},
        {string, L, V}],
       [],
       [{call, L, {atom, L, fname(info,R,V,Acc)}, [{var, L, 'Info'}]}]} ||
         {R,V} <- flat_versions(Versions)]}
    ].

f_pos_2(#pass1{exports = Es} = Acc, L) ->
    Fname = list_to_atom(fname_prefix(pos, Acc)),
    [
     funspec(L, Fname, lists:flatmap(
                         fun(R) ->
                                 Flds = get_flds(R, Acc),
                                 %% PFlds = lists:zip(
                                 %%           lists:seq(2, length(Flds)+1), Flds),
                                 Ps = lists:seq(2, length(Flds)+1),
                                 [{[t_atom(L, R), t_union(
                                                    L, ([t_atom(L, F)
                                                         || F <- Flds]
                                                        ++ [t_atom(L)]))],
                                   t_union(L, ([t_integer(L, P) || P <- Ps]
                                               ++ [t_integer(L, 0)]))}]
                                 %% [{[t_atom(L, R), t_atom(L, A)],
                                 %%   t_integer(L, P)} || {P,A} <- PFlds]
                                 %%     ++ [{[t_atom(L, R), t_any(L)],
                                 %%          t_integer(L, 0)}]
                         end, Es)),
     {function, L, Fname, 2,
      [{clause, L,
        [{atom, L, R},
         {var, L, 'Attr'}],
        [],
        [{call, L, {atom, L, fname(pos, R, Acc)}, [{var, L, 'Attr'}]}]} ||
          R <- Acc#pass1.exports]}
    ].

f_isrec_1(Acc, L) ->
    Fname = list_to_atom(fname_prefix(is_record, Acc)),
    [%% This contract is correct, but is ignored by Dialyzer because it
     %% has overlapping domains:
     %% funspec(L, Fname,
     %%              [{[t_record(L, R)], t_atom(L, true)}
     %%               || R <- Acc#pass1.exports]
     %%              ++ [{[t_any(L)], t_atom(L, false)}]),
     %% This is less specific, but more useful to Dialyzer:
     funspec(L, Fname, [{[t_any(L)], t_boolean(L)}]),
     {function, L, Fname, 1,
      [{clause, L,
        [{var, L, 'X'}],
        [],
        [{'if',L,
          [{clause, L, [], [[{call, L, {atom,L,is_record},
                              [{var,L,'X'},{atom,L,R}]}]],
            [{atom,L,true}]} || R <- Acc#pass1.exports] ++
              [{clause,L, [], [[{atom,L,true}]],
                [{atom, L, false}]}]}]}
      ]}
    ].



f_get(#pass1{record_types = RTypes, exports = Es} = Acc, L) ->
    Fname = list_to_atom(fname_prefix(get, Acc)),
    [funspec(L, Fname,
             lists:append(
               [[{[t_atom(L, A), t_record(L, R)], T}
                 || {A, T} <- Types]
                || {R, Types} <- RTypes, lists:member(R, Es)])
             ++ [{[t_list(L, [t_attr(L, R, Acc)]), t_record(L, R)],
                  t_list(L, [t_union(L, [Ts || {_, Ts} <- Types])])}
                 || {R, Types} <- RTypes, lists:member(R, Es)]
            ),
     {function, L, Fname, 2,
      [{clause, L,
        [{var, L, 'Attrs'},
         {var, L, 'Rec'}],
        [[{call, L,
           {atom, L, is_record},
           [{var, L, 'Rec'}, {atom, L, R}]}]],
        [{call, L, {atom, L, fname(get, R, Acc)}, [{var, L, 'Attrs'},
                                                   {var, L, 'Rec'}]}]} ||
          R <- Es]}
    ].


f_set(Acc, L) ->
    Fname = list_to_atom(fname_prefix(set, Acc)),
    [funspec(L, Fname,
             lists:map(
               fun(Rname) ->
                       TRec = t_record(L, Rname),
                       {[t_list(L, [t_prop(L, Rname, Acc)]), TRec], TRec}
               end, Acc#pass1.exports)),
     {function, L, Fname, 2,
      [{clause, L,
        [{var, L, 'Vals'},
         {var, L, 'Rec'}],
        [[{call, L,
           {atom, L, is_record},
           [{var, L, 'Rec'}, {atom, L, R}]}]],
        [{call, L, {atom, L, fname(set, R, Acc)}, [{var, L, 'Vals'},
                                                   {var, L, 'Rec'}]}]} ||
          R <- Acc#pass1.exports]}
    ].

f_fromlist(Acc, L) ->
    Fname = list_to_atom(fname_prefix(fromlist, Acc)),
    [funspec(L, Fname,
             lists:map(
               fun(Rname) ->
                       TRec = t_record(L, Rname),
                       {[t_list(L, [t_prop(L, Rname, Acc)]), TRec], TRec}
               end, Acc#pass1.exports)),
     {function, L, Fname, 2,
      [{clause, L,
        [{var, L, 'Vals'},
         {var, L, 'Rec'}],
        [[{call, L,
           {atom, L, is_record},
           [{var, L, 'Rec'}, {atom, L, R}]}]],
        [{call, L, {atom, L, fname(fromlist, R, Acc)}, [{var, L, 'Vals'},
                                                        {var, L, 'Rec'}]}]} ||
          R <- Acc#pass1.exports]}
    ].

f_frommap(Acc, L) ->
    Fname = list_to_atom(fname_prefix(frommap, Acc)),
    [funspec(L, Fname,
             lists:map(
               fun(Rname) ->
                       TRec = t_record(L, Rname),
                       {[t_map(L, Rname, Acc), TRec], TRec}
               end, Acc#pass1.exports)),
     {function, L, Fname, 2,
      [{clause, L,
        [{var, L, 'Vals'},
         {var, L, 'Rec'}],
        [[{call, L,
           {atom, L, is_record},
           [{var, L, 'Rec'}, {atom, L, R}]}]],
        [{call, L, {atom, L, fname(frommap, R, Acc)}, [{var, L, 'Vals'},
                                                        {var, L, 'Rec'}]}]} ||
          R <- Acc#pass1.exports]}
    ].

f_info_1(Rname, Acc, L) ->
    Fname = fname(info, Rname, Acc),
    Flds = get_flds(Rname, Acc),
    [funspec(L, Fname, [{[t_atom(L, fields)],
                         t_list(L, [t_union(L, [t_atom(L,F) || F <- Flds])])},
                        {[t_atom(L, size)], t_integer(L, length(Flds)+1)}]),
     {function, L, Fname, 1,
      [{clause, L, [{atom, L, fields}], [],
        [{call, L, {atom, L, record_info},
          [{atom, L, fields}, {atom, L, Rname}]}]
       },
       {clause, L, [{atom, L, size}], [],
        [{call, L, {atom, L, record_info},
          [{atom, L, size}, {atom, L, Rname}]}]
       }]}
    ].

f_info_1(Rname, Acc, L, V) ->
    f_info_1(recname(Rname, V), Acc, L).

recname(Rname, V) ->
    list_to_atom(lists:concat([Rname,"__",V])).

f_convert(_Vsns, L, Acc) ->
    {function, L, fname(convert, Acc), 2,
     [{clause, L,
       [{var, L, 'FromVsn'},
        {var, L, 'Rec'}],
       [[{call,L,{atom, L, is_tuple},
         [{var, L, 'Rec'}]}]],
       [{match, L, {var, L, 'Rname'},
         {call, L, {atom, L, element},
          [{integer, L, 1}, {var, L, 'Rec'}]}},
        {match,L,{var,L,'Size'},
         {call, L, {atom, L, fname(info, Acc)},
          [{var,L,'Rname'}, {atom, L, size}, {var,L,'FromVsn'}]}},
        {match, L, {var, L, 'Size'},
         {call, L, {atom, L, size},
          [{var, L, 'Rec'}]}},
        %%
        %% {match, L, {var, L, 'Old_fields'},
        %%  {call, L, {atom,L,fname(info, Acc)},
        %%     [{var,L,'Rname'},{atom,L,fields},{var,L,'FromVsn'}]}},
        {match, L, {var, L, 'New_fields'},
         {call, L, {atom,L,fname(info, Acc)},
            [{var,L,'Rname'},{atom,L,fields}]}},

        {match, L, {var, L, 'Values'},
         {call, L, {remote, L, {atom, L, lists}, {atom, L, zip}},
          [{call, L, {atom,L,fname(info, Acc)},
            [{var,L,'Rname'},{atom,L,fields},{var,L,'FromVsn'}]},
           {call, L, {atom, L, 'tl'},
            [{call, L, {atom, L, tuple_to_list},
              [{var, L, 'Rec'}]}]}]}},
        {match, L, {tuple, L, [{var, L, 'Matching'},
                               {var, L, 'Discarded'}]},
         {call, L, {remote, L, {atom, L, lists}, {atom, L, partition}},
          [{'fun',L,
            {clauses,
             [{clause,L,
               [{tuple,L,[{var,L,'F'},{var,L,'_'}]}],
               [],
               [{call,L,
                 {remote,L,{atom,L,lists},{atom,L,member}},
                 [{var, L, 'F'}, {var,L,'New_fields'}]}]}]}},
           {var, L, 'Values'}]}},
        {tuple, L, [{call, L, {atom, L, fname(set, Acc)},
                     [{var, L, 'Matching'},
                      {call, L, {atom, L, fname(new, Acc)},
                       [{var, L, 'Rname'}]}]},
                    {var, L, 'Discarded'}]}]
      }]}.

f_lens_(#pass1{exports = Es} = Acc, L) ->
    Fname = fname(lens, Acc),
    [
     funspec(L, Fname, [ {[t_attr(L, Rname, Acc), t_atom(L, Rname)],
                          t_tuple(L, [t_fun(L, [t_record(L, Rname)], t_any(L)),
                                      t_fun(L, [t_any(L),
                                                t_record(L, Rname)],
                                            t_record(L, Rname))])}
                         || Rname <- Es]),
     {function, L, Fname, 2,
      [{clause, L, [{var, L, 'Attr'}, {atom, L, Re}], [],
        [{call, L, {atom, L, fname(lens, Re, Acc)}, [{var, L, 'Attr'}]}]}
         || Re <- Es]}
    ].

f_lens_1(Rname, Flds, L, Acc) ->
    Fname = fname(lens, Rname, Acc),
    [funspec(L, Fname, [ {[t_attr(L, Rname, Acc)],
                          t_tuple(L, [t_fun(L, [t_record(L, Rname)], t_any(L)),
                                      t_fun(L, [t_any(L),
                                                t_record(L, Rname)],
                                            t_record(L, Rname))])} ]),
     {function, L, Fname, 1,
      [{clause, L, [{atom, L, Attr}], [],
        [{tuple, L, [{'fun', L,
                      {clauses,
                       [{clause, L, [{var, L, 'R'}], [],
                         [{call, L, {atom, L, fname(get, Rname, Acc)},
                           [{atom, L, Attr}, {var, L, 'R'}]}]}
                       ]}},
                     {'fun', L,
                      {clauses,
                       [{clause, L, [{var, L, 'X'}, {var, L, 'R'}], [],
                         [{call, L, {atom, L, fname(set, Rname, Acc)},
                           [{cons,L, {tuple, L, [{atom, L, Attr},
                                                 {var, L, 'X'}]}, {nil,L}},
                            {var, L, 'R'}]}]
                        }]}}
                    ]}]} || Attr <- Flds] ++
          [{clause, L, [{var, L, 'Attr'}], [],
           [bad_record_op(L, Fname, 'Attr')]}]
     }].

%%% ========== generic parse_transform stuff ==============

-spec context(atom(), #context{}) ->
    term().
%% @hidden
context(module,   #context{module = M}  ) -> M;
context(function, #context{function = F}) -> F;
context(arity,    #context{arity = A}   ) -> A.



rpt_error(Reason, Fun, Info) ->
    Fmt = lists:flatten(
            ["*** ERROR in parse_transform function:~n"
             "*** Reason     = ~p~n",
             "*** Location: ~p~n",
             ["*** ~10w = ~p~n" || _ <- Info]]),
    Args = [Reason, Fun |
            lists:foldr(
              fun({K,V}, Acc) ->
                      [K, V | Acc]
              end, [], Info)],
    io:format(Fmt, Args).

-spec format_error({atom(), term()}) ->
    iolist().
%% @hidden
format_error({_Cat, Error}) ->
    Error.
