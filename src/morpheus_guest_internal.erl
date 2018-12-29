%% This module is supposed to run in instrumented mode, but only called by sandbox-rewriting.
%% It used for emulation of system functionalities (currently only timer)
-module(morpheus_guest_internal).

-export([ init/0 ]).

-export([ init_timer/0
        , start_timer/3, start_timer/4
        , send_after/3, send_after/4
        , read_timer/1, read_timer/2
        , cancel_timer/1, cancel_timer/2
        ]).


%% called once in the startup thread of the sandbox
init() ->
    init_timer(),
    ok.

%%%% timer

-record(timer_entry,
        { deadline    :: integer()
        , dest        :: pid() | atom()
        , ref         :: reference()
        , msg         :: any()
        , with_header :: boolean()
        }).
-record(timer_state,
        { timers   :: [#timer_entry{}]
        , monitors :: dict:dict(pid(), {non_neg_integer(), reference()})
        }).

%% -define(DEBUG, true).

-compile({inline, [event/1]}).
-ifdef(DEBUG).
event(E) ->
    io:format(user, "!!! ~p~n", [E]).
-else.
event(_E) ->
    ok.
-endif.

init_timer() ->
    Me = self(),
    Pid = spawn(fun() ->
                        morpheus_guest:call_ctl({become_persistent, self()}),
                        Me ! timer_started,
                        timer_loop(#timer_state{timers = [], monitors = dict:new()},
                                   erlang:monotonic_time(millisecond))
                end),
    receive timer_started -> ok end,
    register(?MODULE, Pid).

-spec process_timeouts(#timer_state{}, non_neg_integer()) ->
                              {[#timer_entry{}], dict:dict(pid(), {non_neg_integer(), reference()}), #timer_state{}}.
%% Find all timer entries that timed out, fire them and remove the corresponding monitors
process_timeouts(#timer_state{timers = Timers0, monitors = Monitors0}, Now) ->
    {Expired, Timers, NextDeadline} =
        lists:foldr(
          fun (#timer_entry{deadline = DL} = Timer, {E, T, N}) ->
                  if
                      DL =< Now ->
                          {[Timer | E], T, N};
                      N =:= infinite ->
                          {E, [Timer | T], DL};
                      DL < N ->
                          {E, [Timer | T], DL};
                      true ->
                          {E, [Timer | T], N}
                  end
          end, {[], [], infinity}, Timers0),
    %% XXX shuffle the expired list to fire them randomly?
    Monitors = lists:foldr(
      fun ( #timer_entry{dest = Dest, ref = Ref, msg = Msg, with_header = WithHeader}
          , CurMonitors) ->
              event({timer_expired, Ref}),
              %% Dest may be a non-exist process name. By API documentation it's silently ignored
              _ = (catch
                       case WithHeader of
                           true ->
                               Dest ! {timeout, Ref, Msg};
                           false ->
                               Dest ! Msg
                       end),
              case is_pid(Dest) andalso dict:take(Dest, CurMonitors) of
                  false ->
                      CurMonitors;
                  {{C, MRef}, NxMonitors} when C =:= 1 ->
                      demonitor(MRef, [flush]),
                      NxMonitors;
                  {{C, MRef}, NxMonitors} when C > 1 ->
                      dict:store(Dest, {C - 1, MRef}, NxMonitors)
              end
      end, Monitors0, Expired),
    {Timers, Monitors, NextDeadline}.

-spec timer_loop(#timer_state{}, non_neg_integer()) -> none().
timer_loop(S, Now) ->
    {Timers, Monitors, NextDeadline} = process_timeouts(S, Now),
    ReceiveTimeout =
        case NextDeadline of
            infinity ->
                infinity;
            _ ->
                NextDeadline - Now
        end,
    receive
        {Ref, Pid, {new, Abs, Time, Dest, Msg, WithHeader}} ->
            Now0 = erlang:monotonic_time(millisecond),
            TRef = make_ref(),
            event({new_timer, Time, TRef}),
            Timer = #timer_entry{ deadline = case Abs of
                                                 true ->
                                                     Time;
                                                 false ->
                                                     Now0 + Time
                                             end
                                , dest = Dest
                                , ref = TRef
                                , msg = Msg
                                , with_header = WithHeader
                                },
            Monitors1 =
                case is_pid(Dest) andalso dict:take(Dest, Monitors) of
                    false ->
                        Monitors;
                    {{C, MRef}, _M} ->
                        dict:store(Dest, {C + 1, MRef}, _M);
                    error ->
                        MRef = monitor(process, Dest),
                        dict:store(Dest, {1, MRef}, Monitors)
                end,
            Pid ! {Ref, TRef},
            timer_loop(S#timer_state{timers = [Timer | Timers], monitors = Monitors1}, Now0);
        {Ref, Pid, {cancel, TRef, Async}} ->
            event({cancel_timer, TRef}),
            Now0 = erlang:monotonic_time(millisecond),
            {R, Dest, NewTimers} =
                lists:foldr(fun (#timer_entry{deadline = DL, dest = Dest, ref = TRef0}, {_F, _D, L})
                                  when TRef0 =:= TRef ->
                                    {DL - Now0, Dest, L};
                                (Timeout, {F, D, L}) ->
                                    {F, D, [Timeout | L]}
                            end, {false, undefined, []}, Timers),
            case Async of
                true ->
                    Pid ! {cancel_timer, TRef, R};
                false ->
                    Pid ! {Ref, R}
            end,
            Monitors1 =
                case Dest of
                    undefined ->
                        Monitors;
                    _ ->
                        case is_pid(Dest) andalso dict:take(Dest, Monitors) of
                            false ->
                                Monitors;
                            {{C, MRef}, NxM} when C =:= 1 ->
                                demonitor(MRef, [flush]),
                                NxM;
                            {{C, MRef}, NxM} when C > 1 ->
                                dict:store(Dest, {C - 1, MRef}, NxM)
                        end
                end,
            timer_loop(S#timer_state{timers = NewTimers, monitors = Monitors1}, Now0);
        {Ref, Pid, {read, TRef, Async}} ->
            Now0 = erlang:monotonic_time(millisecond),
            {Info, R} =
                case lists:keysearch(TRef, #timer_entry.ref, Timers) of
                    {value, #timer_entry{deadline = DL}} ->
                        case DL > Now0 of
                            true ->
                                {found, DL - Now0};
                            false ->
                                %% this should not happen ... but anyway
                                {expired, false}
                        end;
                    _ ->
                        {not_found, false}
                end,
            event({read_timer, TRef, Timers, Now0, {Info, R}}),
            case Async of
                true ->
                    Pid ! {read_timer, TRef, R};
                false ->
                    Pid ! {Ref, R}
            end,
            timer_loop(S, Now0);
        {'DOWN', _, process, Pid, _} ->
            Now0 = erlang:monotonic_time(millisecond),
            Timers1 = lists:foldr(
                        fun (#timer_entry{dest = Dest} = TE, Acc) ->
                                case Dest =:= Pid of
                                    true ->
                                        Acc;
                                    false ->
                                        [TE | Acc]
                                end
                        end, [], Timers),
            Monitors1 = dict:erase(Pid, Monitors),
            timer_loop(S#timer_state{timers = Timers1, monitors = Monitors1}, Now0)
    after
        ReceiveTimeout ->
            Now0 = erlang:monotonic_time(millisecond),
            timer_loop(S, Now0)
    end.

start_timer(Time, Dest, Msg) ->
    start_timer(Time, Dest, Msg, []).

start_timer(Time, Dest, Msg, Opts) ->
    start_timer(Time, Dest, Msg, Opts, true).

send_after(Time, Dest, Msg) ->
    send_after(Time, Dest, Msg, []).

send_after(Time, Dest, Msg, Opts) ->
    start_timer(Time, Dest, Msg, Opts, false).

start_timer(Time, Dest, Msg, Opts, WithHeader) ->
    Abs = case proplists:get_value(abs, Opts, false) of
              true -> true;
              _ -> false
          end,
    case whereis(?MODULE) of
        undefined ->
            morpheus_guest:exit_with(timer_controller_not_found);
        Pid ->
            MRef = monitor(process, Pid),
            Pid ! {MRef, self(), {new, Abs, Time, Dest, Msg, WithHeader}},
            receive
                {MRef, TRef} ->
                    demonitor(MRef, [flush]),
                    TRef;
                {'DOWN', MRef, _, _, _} ->
                    morpheus_guest:exit_with(timer_controller_down)
            end
    end.

read_timer(TRef) ->
    read_timer(TRef, []).

read_timer(TRef, Options) ->
    Async = proplists:get_value(async, Options, false),
    case {whereis(?MODULE), Async} of
        {undefined, false} -> false;
        {undefined, true} -> ok;
        {Pid, false} ->
            MRef = monitor(process, Pid),
            Pid ! {MRef, self(), {read, TRef, false}},
            receive
                {MRef, R} ->
                    demonitor(MRef, [flush]),
                    R;
                {'DOWN', MRef, _, _, _} ->
                    false
            end;
        {Pid, true} ->
            Pid ! {undefined, self(), {read, TRef, true}},
            ok
    end.

cancel_timer(TRef) ->
    cancel_timer(TRef, []).

cancel_timer(TRef, Opts) when is_reference(TRef) ->
    Async = proplists:get_value(async, Opts, false),
    Info = proplists:get_value(async, Opts, true),
    case {whereis(?MODULE), Async} of
        {undefined, false} ->
            case Info of
                true -> false;
                false -> ok
            end;
        {undefined, true} ->
            ok;
        {Pid, false} ->
            MRef = monitor(process, Pid),
            Pid ! {MRef, self(), {cancel, TRef, false}},
            receive
                {MRef, R} ->
                    demonitor(MRef, [flush]),
                    case Info of
                        true ->
                            R;
                        false ->
                            ok
                    end;
                {'DOWN', MRef, _, _, _} ->
                    case Info of
                        true ->
                            false;
                        false ->
                            ok
                    end
            end;
        {Pid, true} ->
            Pid ! {undefined, self(), {cancel, TRef, true}},
            ok
    end;
cancel_timer(_Other, _Opts) ->
    error(badarg).

%%%% Naive timer emulation for future reference

%% start_timer(Time, Dest, Msg) ->
%%     start_timer(Time, Dest, Msg, []).

%% start_timer(Time, Dest, Msg, Opts) ->
%%     case proplists:get_value(abs, Opts) of
%%         true ->
%%             io:format(user, "!!!! abs_timer !!!!~n", []),
%%             error(unhandled_abs_timer);
%%         _ ->
%%             ok
%%     end,
%%     spawn(fun () ->
%%                   receive
%%                   after Time ->
%%                           Dest ! {timeout, self(), Msg}
%%                   end
%%           end).

%% send_after(Time, Dest, Msg) ->
%%     send_after(Time, Dest, Msg, []).

%% send_after(Time, Dest, Msg, Opts) ->
%%     case proplists:get_value(abs, Opts, false) of
%%         true ->
%%             io:format(user, "!!!! abs_timer !!!!~n", []),
%%             error(unhandled_abs_timer);
%%         false ->
%%             ok
%%     end,
%%     spawn(fun () ->
%%                   receive
%%                   after Time ->
%%                           Dest ! Msg
%%                   end
%%           end).

%% read_timer(Timer) ->
%%     read_timer(Timer, []).
%% read_timer(_Timer, _Options) ->
%%     error(unhandled_read_timer).

%% cancel_timer(Timer) ->
%%     cancel_timer(Timer, []).

%% cancel_timer(Timer, Opts) ->
%%     Async = proplists:get_value(async, Opts, false),
%%     Info = proplists:get_value(async, Opts, true),
%%     exit(Timer, cancel_timer),
%%     case Info of
%%         false -> ok;
%%         true ->
%%             case Async of
%%                 false ->
%%                     0;
%%                 true ->
%%                     self() ! {cancel_timer, Timer, 0},
%%                     ok
%%             end
%%     end.
