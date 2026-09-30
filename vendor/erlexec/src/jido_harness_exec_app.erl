%%%------------------------------------------------------------------------
%%% File: $Id$
%%%------------------------------------------------------------------------
%%% @doc     This module implements application and supervisor behaviors
%%%          of the `exec' application.
%%% @author  Serge Aleynikov <saleyn@gmail.com>
%%% @version $Revision: 1.1 $
%%% @end
%%%----------------------------------------------------------------------
%%% Created: 2003-06-25 by Serge Aleynikov <saleyn@gmail.com>
%%% $URL$
%%%------------------------------------------------------------------------
-module(jido_harness_exec_app).
-moduledoc false.
-author('saleyn@gmail.com').
-id    ("$Id$").

-behaviour(application).
-behaviour(supervisor).

%% application and supervisor callbacks
-export([start/2, stop/1, init/1]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% This is the entry module for your application. It contains the
%% start function and some other stuff. You identify this module
%% using the 'mod' attribute in the .app file.
%%
%% The start function is called by the application controller.
%% It normally returns {ok,Pid}, i.e. the same as gen_server and
%% supervisor. Here, we simply call the start function in our supervisor.
%% One can also return {ok, Pid, State}, where State is reused in stop(State).
%%
%% Type can be 'normal' or {takeover,FromNode}. If the 'start_phases'
%% attribute is present in the .app file, Type can also be {failover,FromNode}.
%% This is an odd compatibility thing.
%% @private
%%----------------------------------------------------------------------
start(_Type, _Args) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%----------------------------------------------------------------------
%% stop(State) is called when the application has been terminated, and
%% all processes are gone. The return value is ignored.
%% @private
%%----------------------------------------------------------------------
stop(_S) ->
    ok.

%%%---------------------------------------------------------------------
%%% Supervisor behaviour callbacks
%%%---------------------------------------------------------------------

%% @private
init([]) ->
    Options =
        lists:foldl(
            fun(I, Acc) -> add_option(I, Acc) end,
            [], [I || {I, _} <- jido_harness_exec:default()]),
    {ok, {
        {one_for_one, 3, 30},               % Allow MaxR restarts within MaxT seconds
        [{  jido_harness_exec,                           % Id       = internal id
            {jido_harness_exec, start_link, [Options]},  % StartFun = {M, F, A}
            permanent,                      % Restart  = permanent | transient | temporary
            10000,                          % Shutdown - wait 10 seconds, to give child processes time to be killed off.
            worker,                         % Type     = worker | supervisor
            [jido_harness_exec]                          % Modules  = [Module] | dynamic
        }]
    }}.

add_option(Option, Acc) ->
    case lists:keyfind(Option, 1, application:get_env(jido_harness, native_process, [])) of
    {Option, Value} -> [{Option, Value} | Acc];
    false       -> Acc
    end.
