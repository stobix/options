%%% @hidden
-module(options_sup).

-behaviour(supervisor).
-export([init/1,start_link/0]).

start_link() ->
    supervisor:start_link(?MODULE,[]).

init(_) ->
    {ok,{{one_for_all,3,10},[
                {options,{options,start_link,[]},permanent,10,worker,[options]}
                ]}}.
