-module(telemetry_ets).

-include("telemetry.hrl").

-export([persist/1,
         list_for_event/2,
         list_by_prefix/2,
         insert/5,
         delete/2]).

persist(TID) ->
    Handlers = ets:tab2list(TID),
    Map = lists:foldl(fun(Handler, Acc) ->
                              maps:update_with(Handler#handler.event_name,
                                               fun(L) -> [Handler | L] end,
                                               [Handler],
                                               Acc)
                      end,
                      #{},
                      Handlers),
    {ok, Map}.

list_for_event(TID, EventName) ->
    try
        ets:lookup(TID, EventName)
    catch
        error:badarg ->
            []
    end.

list_by_prefix(TID, EventPrefix) ->
    Pattern = match_pattern_for_prefix(EventPrefix),
    try
        ets:match_object(TID, Pattern)
    catch
        error:badarg ->
            []
    end.

match_pattern_for_prefix(EventPrefix) ->
    #handler{event_name=match_for_prefix(EventPrefix),
             _='_'}.

-dialyzer({nowarn_function, match_for_prefix/1}).
match_for_prefix([]) ->
    '_';
match_for_prefix([Segment | Rest]) ->
    [Segment | match_for_prefix(Rest)].

insert(TID, HandlerId, EventNames, Function, Config) ->
    case ets:match(TID, #handler{id=HandlerId,
                                 _='_'}) of
        [] ->
            Objects = [#handler{id=HandlerId,
                                event_name=EventName,
                                function=Function,
                                config=Config} || EventName <- EventNames],
            ets:insert(TID, Objects),
            {ok, TID};
        _ ->
            {error, already_exists}
    end.

delete(TID, HandlerId) ->
    case ets:select_delete(TID, [{#handler{id=HandlerId,
                                           _='_'}, [], [true]}]) of
        0 -> {error, not_found};
        _ -> {ok, TID}
    end.
