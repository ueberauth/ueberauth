%% Copied from basho/riak_core.
%%
%% Fix to make Erlang programs compile on both OTP20 and OTP21.
%%
%% Get the stack trace in a way that is backwards compatible. Luckily
%% OTP_RELEASE was introduced in the same version as the new preferred way of
%% getting the stack trace. A _catch_/2 macro is provided for consistency in
%% cases where the stack trace is not needed.
%%
%% Example use:
%%    try f(...)
%%    catch
%%         ?_exception_(_, Reason, StackToken) ->
%%             case Reason of
%%                 {fail, Error} -> ok;
%%                 _             -> {'EXIT', Reason, ?_get_stacktrace_(StackToken)}
%%             end
%%     end,

-ifdef(OTP_RELEASE). %% This implies 21 or higher
-define(_exception_(Class, Reason, StackToken), Class:Reason:StackToken).
-define(_get_stacktrace_(StackToken), StackToken).
-define(_current_stacktrace_(),
        try
            exit('$get_stacktrace')
        catch
            exit:'$get_stacktrace':__GetCurrentStackTrace ->
                __GetCurrentStackTrace
        end).
-else.
-define(_exception_(Class, Reason, _), Class:Reason).
-define(_get_stacktrace_(_), erlang:get_stacktrace()).
-define(_current_stacktrace_(), erlang:get_stacktrace()).
-endif.
