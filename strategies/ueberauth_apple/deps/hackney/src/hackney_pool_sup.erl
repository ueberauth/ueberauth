-module(hackney_pool_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link(Name) ->
    supervisor:start_link({local, Name}, ?MODULE, [Name]).

init([Name]) ->
    PoolName = hackney_pool:to_pool_name(Name),
    {ok, {{one_for_one, 10, 10},
          [{PoolName, {hackney_pool, start_link, [Name]},
            permanent, 5000, worker, [hackney_pool]}]}}.
