%%% -*- erlang -*-
%%%
%%% This file is part of hackney released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2012-2018 Benoît Chesneau <benoitc@e-engura.org>
%%%

-module(hackney_metrics).
-author("benoitc").

%% API
-export([
  init/0,
  get_engine/0
]).


-include("hackney.hrl").


init() ->
  Metrics = metrics:init(hackney_util:mod_metrics()),
  ets:insert(?CONFIG, {mod_metrics, Metrics}).

get_engine() ->
  ets:lookup_element(?CONFIG, mod_metrics, 2).