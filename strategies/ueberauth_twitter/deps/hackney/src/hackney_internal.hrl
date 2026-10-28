
-ifndef(hackney_internal_hrl).
-define(hackney_internal_hrl, true).

-define(STACK(), erlang:get_stacktrace()).

%% Various trace macros
-define(report(Severity, Label, Content),
  hackney_trace:report_event(Severity, Label, hackney,
    [{module, ?MODULE}, {line, ?LINE} | Content])).
-define(report_important(Label,  Content),
  ?report(20, Label, Content)).
-define(report_verbose(Label, Content),
  ?report(40, Label, Content)).
-define(report_debug(Label, Content),
  ?report(60, Label, Content)).
-define(report_trace(Label, Content),
  ?report(80, Label,  Content)).


-endif.
