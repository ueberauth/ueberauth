-module(telemetry_pt).

-include("telemetry.hrl").

-export([persist/1,
         list_for_event/2,
         list_by_prefix/2,
         insert/5,
         delete/2]).

persist(_Map) -> error.

list_for_event(Map, EventName) ->
    case Map of
        #{EventName := Handlers} -> Handlers;
        _ -> []
    end.

list_by_prefix(Map, EventPrefix) ->
    [Handler ||
     {EventName, Handlers} <- maps:to_list(Map),
     starts_with(EventName, EventPrefix),
     Handler <- Handlers].

starts_with(_Haystack, []) -> true;
starts_with([A | Haystack], [A | Needle]) -> starts_with(Haystack, Needle);
starts_with(_Haystack, _Needle) -> false.

insert(Map, _HandlerId, [], _Function, _Config) ->
    {ok, Map};
insert(Map, HandlerId, [EventName | Rest], Function, Config) ->
    OldHandlers = maps:get(EventName, Map, []),
    case OldHandlers of
        #{HandlerId := _} ->
            {error, already_exists};
        _ ->
            Handler = #handler{id=HandlerId,
                               event_name=EventName,
                               function=Function,
                               config=Config},
            case put_new(Handler, OldHandlers) of
                {ok, NewHandlers} ->
                    NewMap = Map#{EventName => NewHandlers},
                    insert(NewMap, HandlerId, Rest, Function, Config);
                {error, _} = Error ->
                    Error
            end
    end.

put_new(Handler, List) ->
    case lists:keymember(Handler#handler.id, #handler.id, List) of
        true -> {error, already_exists};
        false -> {ok, [Handler | List]}
    end.

delete(Map, HandlerId) ->
    Filtered = [{Event, lists:keydelete(HandlerId, #handler.id, Handlers)}
                || {Event, Handlers} <- maps:to_list(Map)],
    NewMap = maps:from_list(Filtered),
    case NewMap =:= Map of
        true -> {error, not_found};
        false -> {ok, NewMap}
    end.
