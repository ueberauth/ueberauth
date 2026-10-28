-module(hackney_pools_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([start_pool/1, stop_pool/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_pool(Name) ->
    supervisor:start_child(?SERVER, {Name, {hackney_pool_sup, start_link, [Name]},
                                    permanent, 5000, supervisor, [hackney_pool_sup]}).

stop_pool(Name) ->
    _ = supervisor:terminate_child(?SERVER, Name),
    _ = supervisor:delete_child(?SERVER, Name),
    ok.

init([]) ->
    {ok, {{one_for_one, 10, 10}, []}}.
