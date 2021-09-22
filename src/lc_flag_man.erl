%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(lc_flag_man).
-export([ start_link/0
        , init/0
        , flag_man_loop/1
        ]).

-include("lc.hrl").

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

start_link() ->
  proc_lib:start_link(?MODULE, init, []).

init() ->
  process_flag(priority, max),
  process_flag(trap_exit, false),
  process_flag(message_queue_data, off_heap),
  proc_lib:init_ack({ok, self()}),
  Credit = config_get(?RUNQ_MON_C1, configs(), ?RUNQ_MON_C1_DEFAULT),
  State =
    #{ current_credit => Credit
     , sample => scheduler:sample()
     },
  flag_man_loop(State).

flag_man_loop(#{ current_credit := CurrentCredit, sample := LastSample} = State) ->
  RunQLen = erlang:statistics(total_run_queue_lengths),
  ScheduleCount = erlang:system_info(schedulers_online),
  Conf = configs(),
  F1 = config_get(?RUNQ_MON_F1, Conf, ?RUNQ_MON_F1_DEFAULT),
  F2 = config_get(?RUNQ_MON_F2, Conf, ?RUNQ_MON_F2_DEFAULT),
  F3 = config_get(?RUNQ_MON_F3, Conf, ?RUNQ_MON_F3_DEFAULT),
  F4 = config_get(?RUNQ_MON_F4, Conf, ?RUNQ_MON_F4_DEFAULT),
  T1 = config_get(?RUNQ_MON_T1, Conf, ?RUNQ_MON_T1_DEFAULT),
  T2 = config_get(?RUNQ_MON_T2, Conf, ?RUNQ_MON_T2_DEFAULT),
  C1 = config_get(?RUNQ_MON_C1, Conf, ?RUNQ_MON_C1_DEFAULT),

  {NewCredit, SleepMs}
    = case RunQLen > ScheduleCount * F1 of
        true when CurrentCredit == 1 ->
          %% overloaded, raise flag
          catch register(?RUNQ_MON_FLAG_NAME, self()),
          kill_priority_groups(F3),
          ?tp(debug, lc_flagman, #{event => flag_on}),
          {0, T1 + T2};
        true when CurrentCredit > 1 ->
          %% overloaded, but still have credits
          ?tp(debug, lc_flagman, #{event => on_fire}),
          CurrentCredit / C1 * 100 < F4 andalso kill_priority_groups(F3),
          {CurrentCredit - 1, T2};
        false when CurrentCredit == (C1 - 1) ->
          %% cool down, remove flag
          catch unregister(?RUNQ_MON_FLAG_NAME),
          ?tp(debug, lc_flagman, #{event => flag_off}),
          {C1, T1};
        false when CurrentCredit < C1 ->
          %% cool down, recovering
          case lists:keyfind(total, 1, scheduler:utilization(LastSample)) of
            {total, Util, _} when Util < F2 ->
              %% gain credit only when utilization is recovering as well
              ?tp(debug, lc_flagman, #{event => cooldown_success}),
              {CurrentCredit + 1, T1};
            _ ->
              ?tp(debug, lc_flagman, #{event => cooldown_pending}),
              {CurrentCredit, T1}
          end;
        _ ->
          ?tp(debug, lc_flagman, #{event => noop}),
          {CurrentCredit, T1}
      end,
  timer:sleep(SleepMs),
  NewState = State#{current_credit => NewCredit, sample => scheduler:sample()},
  ?MODULE:flag_man_loop(NewState).

config_get(_Name, undefined, Default) ->
  Default;
config_get(Name, ConfigTerm, Default) when is_map(ConfigTerm) ->
  maps:get(Name, ConfigTerm, Default).

configs() ->
  persistent_term:get(?FLAG_MAN_CONFIGS_TERM, undefined).

kill_priority_groups(Threshold) when is_integer(Threshold) ->
  ?tp(debug, lc_flagman, #{event => kill_priority_groups}),
  lists:foreach(
    fun(P) ->
        lists:foreach(
          fun(Pid) -> exit(Pid, kill) end,
          pg:get_local_members(?LC_SCOPE, {?LC_GROUP, P})
         )
    end,  lists:seq(0, Threshold)).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End: