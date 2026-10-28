%%%% -*- erlang -*-
%%%% This file is part of hackney released under the Apache 2 license.
%%%% See the NOTICE for more information.
-module(hackney_trace).

-export([enable/2, disable/0,
  set_level/1,
  report_event/4]).

-type trace_level() :: max | min | integer().
-type filename() :: string().
-type trace_type() :: io | filename() | port() | {fun(), any()}.


-export_type([trace_level/0,
  filename/0,
  trace_type/0]).


%% @doc start tracing
%% start tracing at level Level and send the result either to the file File,
%% the port Port or to a  trace handler.
%%
%% Note: that it starts a tracer server.
%% When Destination is the atom io (or the tuple {io, Verbosity}),
%% %% all (printable) inets trace events (trace_ts events which has
%% %% Severity within Limit) will be written to stdout using io:format.
-spec enable(trace_level(), trace_type()) -> ok.
enable(Level, File) when is_list(File) ->
  case file:open(File, [write]) of
    {ok, Fd} ->
      HandleSpec = {fun handle_trace/2, {hackney, Fd}},
      do_enable(Level, process, HandleSpec);
    Err ->
      Err
  end;
enable(Level, Port) when is_integer(Port) ->
  do_enable(Level, port, dbg:trace_port(ip, Port));
enable(Level, io) ->
  HandleSpec = {fun handle_trace/2, {hackney, standard_io}},
  do_enable(Level, process, HandleSpec);
enable(Level, {Fun, _Data}=HandleSpec) when is_function(Fun) ->
  do_enable(Level, process, HandleSpec).

do_enable(Level, Type, HandleSpec) ->
  case dbg:tracer(Type, HandleSpec) of
    {ok, _} ->
      _ = set_level(Level),
      ok;
    Error ->
      Error
  end.

%% @doc stop tracing
-spec disable() -> ok.
disable() ->
  hackney_trace:report_event(100, "stop trace", stop_trace, [stop_trace]),
  dbg:stop().


%% @doc change the trace level when tracing has already started.
-spec set_level(trace_level()) -> ok | {error, term()}.
set_level(Level) ->
  Pat = make_pattern(?MODULE, Level),
  change_pattern(Pat).

make_pattern(Mod, Level) when is_atom(Mod) ->
  case Level of
    min ->
      {Mod, hackney, []};
    max ->
      Head = ['$1', '_', '_', '_'],
      Body = [],
      Cond = [],
      {Mod, hackney, [{Head, Cond, Body}]};
    DetailLevel when is_integer(DetailLevel) ->
      Head = ['$1', '_', '_', '_'],
      Body = [],
      Cond = [{ '=<', '$1', DetailLevel}],
      {Mod, hackney, [{Head, Cond, Body}]};
    _ ->
      exit({bad_level, Level})
  end.

change_pattern({Mod, Service, Pattern})
  when is_atom(Mod) andalso is_atom(Service) ->
  MFA = {Mod, report_event, 4},
  case Pattern of
    [] ->
      try
        _ = error_to_exit(ctp, dbg:ctp(MFA)),
        _ = error_to_exit(p,   dbg:p(all, clear)),
        ok
      catch
        exit:{Where, Reason} ->
          {error, {Where, Reason}}
      end;
    List when is_list(List) ->
      try
        _ = error_to_exit(ctp, dbg:ctp(MFA)),
        _ = error_to_exit(tp,  dbg:tp(MFA, Pattern)),
        _ = error_to_exit(p,   dbg:p(all, [call, timestamp])),
        ok
      catch
        exit:{Where, Reason} ->
          {error, {Where, Reason}}
      end
  end.

error_to_exit(_Where, {ok, _} = OK) ->
  OK;
error_to_exit(Where, {error, Reason}) ->
  exit({Where, Reason}).


report_event(Severity, Label, Service, Content)
  when (is_integer(Severity) andalso
  (Severity >= 0) andalso (100 >= Severity)) andalso
         is_list(Label) andalso
         is_atom(Service) andalso
         is_list(Content) ->
  hopefully_traced.


handle_trace(_, closed_file = Fd) ->
  Fd;
handle_trace({trace_ts, _Who, call,
  {?MODULE, report_event,
    [_Sev, "stop trace", stop_trace, [stop_trace]]},
  Timestamp},
  {_, standard_io} = Fd) ->
  (catch io:format(standard_io, "stop trace at ~s~n", [format_timestamp(Timestamp)])),
  Fd;
handle_trace({trace_ts, _Who, call,
  {?MODULE, report_event,
    [_Sev, "stop trace", stop_trace, [stop_trace]]},
  Timestamp},
  standard_io = Fd) ->
  (catch io:format(Fd, "stop trace at ~s~n", [format_timestamp(Timestamp)])),
  Fd;
handle_trace({trace_ts, _Who, call,
  {?MODULE, report_event,
    [_Sev, "stop trace", stop_trace, [stop_trace]]},
  Timestamp},
  {_Service, Fd}) ->
  (catch io:format(Fd, "stop trace at ~s~n", [format_timestamp(Timestamp)])),
  (catch file:close(Fd)),
  closed_file;
handle_trace({trace_ts, _Who, call,
  {?MODULE, report_event,
    [_Sev, "stop trace", stop_trace, [stop_trace]]},
  Timestamp},
  Fd) ->
  (catch io:format(Fd, "stop trace at ~s~n", [format_timestamp(Timestamp)])),
  (catch file:close(Fd)),
  closed_file;
handle_trace({trace_ts, Who, call,
  {?MODULE, report_event,
    [Sev, Label, Service, Content]}, Timestamp},
  Fd) ->
  (catch print_hackney_trace(Fd, Sev, Timestamp, Who,
    Label, Service, Content)),
  Fd;
handle_trace(Event, Fd) ->
  (catch print_trace(Fd, Event)),
  Fd.


print_hackney_trace({Service, Fd},
  Sev, Timestamp, Who, Label, Service, Content) ->
  do_print_hackney_trace(Fd, Sev, Timestamp, Who, Label, Service, Content);
print_hackney_trace({ServiceA, Fd},
  Sev, Timestamp, Who, Label, ServiceB, Content)
  when (ServiceA =:= all) ->
  do_print_hackney_trace(Fd, Sev, Timestamp, Who, Label, ServiceB, Content);
print_hackney_trace({ServiceA, _Fd},
  _Sev, _Timestamp, _Who, _Label, ServiceB, _Content)
  when ServiceA =/= ServiceB ->
  ok;
print_hackney_trace(Fd, Sev, Timestamp, Who, Label, Service, Content) ->
  do_print_hackney_trace(Fd, Sev, Timestamp, Who, Label, Service, Content).

do_print_hackney_trace(Fd, Sev, Timestamp, Who, Label, Service, Content) ->
  Ts = format_timestamp(Timestamp),
  io:format(Fd, "[~w trace ~w ~w ~s] ~s "
  "~n   Content: ~p"
  "~n",
    [Service, Sev, Who, Ts, Label, Content]).

print_trace({_, Fd}, Event) ->
  do_print_trace(Fd, Event);
print_trace(Fd, Event) ->
  do_print_trace(Fd, Event).

do_print_trace(Fd, {trace, Who, What, Where}) ->
  io:format(Fd, "[trace]"
  "~n   Who:   ~p"
  "~n   What:  ~p"
  "~n   Where: ~p"
  "~n", [Who, What, Where]);

do_print_trace(Fd, {trace, Who, What, Where, Extra}) ->
  io:format(Fd, "[trace]"
  "~n   Who:   ~p"
  "~n   What:  ~p"
  "~n   Where: ~p"
  "~n   Extra: ~p"
  "~n", [Who, What, Where, Extra]);

do_print_trace(Fd, {trace_ts, Who, What, Where, When}) ->
  Ts = format_timestamp(When),
  io:format(Fd, "[trace ~s]"
  "~n   Who:   ~p"
  "~n   What:  ~p"
  "~n   Where: ~p"
  "~n", [Ts, Who, What, Where]);

do_print_trace(Fd, {trace_ts, Who, What, Where, Extra, When}) ->
  Ts = format_timestamp(When),
  io:format(Fd, "[trace ~s]"
  "~n   Who:   ~p"
  "~n   What:  ~p"
  "~n   Where: ~p"
  "~n   Extra: ~p"
  "~n", [Ts, Who, What, Where, Extra]);

do_print_trace(Fd, {seq_trace, What, Where}) ->
  io:format(Fd, "[seq trace]"
  "~n   What:       ~p"
  "~n   Where:      ~p"
  "~n", [What, Where]);

do_print_trace(Fd, {seq_trace, What, Where, When}) ->
  Ts = format_timestamp(When),
  io:format(Fd, "[seq trace ~s]"
  "~n   What:       ~p"
  "~n   Where:      ~p"
  "~n", [Ts, What, Where]);

do_print_trace(Fd, {drop, Num}) ->
  io:format(Fd, "[drop trace] ~p~n", [Num]);

do_print_trace(Fd, Trace) ->
  io:format(Fd, "[trace] "
  "~n   ~p"
  "~n", [Trace]).


format_timestamp({_N1, _N2, N3} = Now) ->
  {Date, Time}   = calendar:now_to_datetime(Now),
  {YYYY,MM,DD}   = Date,
  {Hour,Min,Sec} = Time,
  FormatDate =
    io_lib:format("~.4w:~.2.0w:~.2.0w ~.2.0w:~.2.0w:~.2.0w 4~w",
      [YYYY,MM,DD,Hour,Min,Sec,round(N3/1000)]),
  lists:flatten(FormatDate).

