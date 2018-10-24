-module(sandbox_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    , ?_test( t_spawn() )
    %% %% May fail
    %% , ?_test( t_spawn2() )
    %% %% this should fail, skipped
    %% , ?_test( t_spawn3() )
    , ?_test( t_spawn_monitor() )
    , ?_test( t_monitor_demonitor() )
    , ?_test( t_process_info() )
    , ?_test( t_link_trap() )
    , ?_test( t_registry() )
    , ?_test( t_ets() )
    , ?_test( t_random() )
    , ?_test( t_timer() )
    , ?_test( t_helper() )
    , ?_test( t_timestamp() )
    , ?_test( t_error() )
    ].

config() ->
    [ {heartbeat, false} ].

t_basic() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, basic_test_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

basic_test_entry() ->
    %% test simple send/receive
    self() ! yo,
    receive yo -> ok end,
    %% proper filter handling
    self() ! a,
    self() ! b,
    receive b ->
            ok end,
    receive a ->
            ok end,
    %% instant timeout
    receive after 0 -> ok end,
    self() ! x,
    ok = receive x -> ok after 0 -> fail end,
    fail = receive x -> ok after 0 -> fail end,
    receive after 500 -> ok end,
    y = receive x -> x after 500 -> y end,
    try
        should_not_exist ! msg,
        error(what)
    catch
        error:badarg ->
            ok
    end,
    morpheus_guest:exit_with(success).

hello() ->
    io:format(user, "Hello!~n", []).

t_spawn() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, spawn_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end.

spawn_entry() ->
    true = morpheus_guest:in_sandbox(),
    {_, M1} = spawn_monitor(?MODULE, spawn_inner_entry, []),
    {_, M2} = spawn_monitor(fun spawn_inner_entry/0),
    {_, M3} = spawn_monitor(fun spawn_inner_entry/0),
    normal = receive {'DOWN', M1, _, _, Reason1} -> Reason1 end,
    normal = receive {'DOWN', M2, _, _, Reason2} -> Reason2 end,
    normal = receive {'DOWN', M3, _, _, Reason3} -> Reason3 end,
    morpheus_guest:exit_with(success).

t_spawn2() ->
    {Ctl, MRef} = morpheus_sandbox:start(erlang, apply, [?MODULE, spawn_inner_entry, []],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end.

t_spawn3() ->
    {Ctl, MRef} = morpheus_sandbox:start(erlang, apply, [fun spawn_inner_entry/0, []],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end.

spawn_inner_entry() ->
    true = morpheus_guest:in_sandbox(),
    morpheus_guest:exit_with(success).

t_spawn_monitor() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, spawn_monitor_test_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

spawn_monitor_test_entry() ->
    Pid = spawn(fun () ->
                        hello()
                end),
    MRef = monitor(process, Pid),
    receive {'DOWN', MRef, _, _, _} ->
            ok end,
    Pid2 = spawn(?MODULE, hello, []),
    MRef2 = monitor(process, Pid2),
    receive {'DOWN', MRef2, _, _, _} ->
            ok end,
    Pid3 = apply(erlang, spawn, [?MODULE, hello, []]),
    MRef3 = monitor(process, Pid3),
    receive {'DOWN', MRef3, _, _, _} ->
            ok end,
    MRef4 = monitor(process, should_not_exist),
    receive {'DOWN', MRef4, process, {should_not_exist, nonode@nohost}, _} -> ok end,
    Pid5 = spawn(fun () ->
                         receive exit -> ok end
                 end),
    register(random_name, Pid5),
    MRef5 = monitor(process, random_name),
    random_name ! exit,
    receive {'DOWN', MRef5, process, {random_name, nonode@nohost}, _} -> ok end,
    MRef6 = monitor(process, {should_not_exist, nonode@nohost}),
    receive {'DOWN', MRef6, process, {should_not_exist, nonode@nohost}, _} -> ok end,
    morpheus_guest:exit_with(success).

t_monitor_demonitor() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, monitor_demonitor_test_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

monitor_demonitor_test_entry() ->
    Me = self(),
    Pid = spawn(fun () -> Me ! a end),
    MRef = monitor(process, Pid),
    ok =
        receive
            a ->
                demonitor(MRef, [flush]),
                ok;
            _ ->
                failed
        end,
    ok = receive _ -> failed after 0 -> ok end,
    Pid2 = spawn(fun () -> ok end),
    MRef2 = monitor(process, Pid2),
    ok =
        receive
            {'DOWN', MRef2, _, _, _} ->
                false = demonitor(MRef2, [info]),
                ok;
            _ ->
                failed
        end,
    ok = receive _ -> failed after 0 -> ok end,
    morpheus_guest:exit_with(success).

t_process_info() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, process_info_test_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

process_info_test_entry() ->
    [] = process_info(self(), registered_name),
    {monitored_by, []} = process_info(self(), monitored_by),
    {monitors, []} = process_info(self(), monitors),
    {links, []} = process_info(self(), links),
    self() ! a, self() ! b,
    {messages, [a, b]} = process_info(self(), messages),
    receive a -> ok; _ -> error(unexpected) end,
    receive b -> ok; _ -> error(unexpected) end,
    receive _ -> error(unexpected) after 0 -> ok end,
    morpheus_guest:exit_with(success).

t_link_trap() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, link_trap_test_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

link_trap_test_entry() ->
    process_flag(trap_exit, true),
    Pid = spawn_link(fun () ->
                             hello()
                     end),
    receive {'EXIT', Pid, _} ->
            ok end,
    Pid2 = spawn_link(fun () ->
                              spawn_link(fun() -> exit(intented) end),
                              receive after infinity -> ok end
                      end),
    receive {'EXIT', Pid2, _} ->
            ok end,
    morpheus_guest:exit_with(success).

t_registry() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, registry_sandbox_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

registry_sandbox_entry() ->
    Init = erlang:registered(),
    register(test, self()),
    Q = whereis(test),
    Q = self(),
    [test] = erlang:registered() -- Init,
    unregister(test),
    Q1 = whereis(test),
    Q1 = undefined,
    [] = erlang:registered() -- Init,
    morpheus_guest:exit_with(success).

t_ets() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, ets_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

ets_entry() ->
    [] = ets:all(),
    A = ets:new(tab_1, []),
    tab_2 = ets:new(tab_2, [named_table]),
    [] = (ets:all() -- [A, tab_2]),
    Me = self(),
    spawn(fun() -> ets:new(tab_3, [named_table, {heir, Me, yolo}]) end),
    receive {'ETS-TRANSFER', tab_3, _, yolo} -> ok end,
    spawn(fun() -> ets:new(tab_4, [{heir, Me, unnamed_yolo}]) end),
    receive {'ETS-TRANSFER', _, _, unnamed_yolo} -> ok end,
    spawn(fun() ->
                  Me2 = self(),
                  spawn(fun () ->
                                ets:new(tab_5, [named_table, {heir, Me, hello}]),
                                ets:give_away(tab_5, Me2, hello)
                        end),
                  receive {'ETS-TRANSFER', tab_5, _, hello} -> ok end
          end),
    receive {'ETS-TRANSFER', tab_5, _, hello} -> ok end,
    spawn(fun () -> ets:new(tab_6, [named_table, {heir, Me, aha}]), ets:rename(tab_6, tab_7) end),
    receive {'ETS-TRANSFER', tab_7, _, aha} -> ok end,
    morpheus_guest:exit_with(success).

t_random() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, random_entry, [],
                                         [ monitor
                                         , {clock_offset, 0}
                                         ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

random_entry() ->
    case node() of
        'nonode@nohost' ->
            5956636 = rand:uniform(10000000),
            4435847 = random:uniform(10000000);
        _ ->
            io:format(user, "t_random check skipped.~n", [])
    end,
    morpheus_guest:exit_with(success).

t_timer() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, timer_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

timer_entry() ->
    T1 = erlang:monotonic_time(millisecond),
    io:format(user, "~p~n", [T1]),
    TRef1 = erlang:start_timer(1000, self(), hello),
    receive
        {timeout, TRef1, hello} -> ok
    end,
    T2 = erlang:monotonic_time(millisecond),
    io:format(user, "~p~n", [T2]),
    1000 = T2 - T1,
    _TRef2 = erlang:send_after(1000, self(), hello),
    receive
        hello -> ok
    end,
    T3 = erlang:monotonic_time(millisecond),
    io:format(user, "~p~n", [T3]),
    1000 = T3 - T2,
    _TRef3 = erlang:send_after(T3 + 1000, self(), hello, [{abs, true}]),
    receive
        hello -> ok
    end,
    T4 = erlang:monotonic_time(millisecond),
    io:format(user, "~p~n", [T4]),
    TRef4 = erlang:send_after(1000, self(), hello),
    ok =
        receive
            hello -> not_expected
        after
            500 -> ok
        end,
    _T4_1 = erlang:monotonic_time(millisecond),
    500 = erlang:cancel_timer(TRef4),
    ok =
        receive
            hello -> not_expected
        after
            1000 -> ok
        end,

    Pid1 = spawn(fun () -> receive exit -> ok end end),
    SRef1 = erlang:send_after(1000, Pid1, hello, []),
    1000 = erlang:cancel_timer(SRef1),

    Pid2 = spawn(fun () -> receive exit -> ok end end),
    SRef2 = erlang:send_after(1000, Pid2, hello, []),
    timer:sleep(10),
    990 = erlang:cancel_timer(SRef2),

    Pid3 = spawn(fun () -> receive exit -> ok end end),
    SRef3 = erlang:send_after(1000, Pid3, hello, []),
    Pid3 ! exit,
    timer:sleep(10),
    false = erlang:cancel_timer(SRef3),

    morpheus_guest:exit_with(success),
    ok.

t_helper() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, helper_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

-define(GH, morpheus_guest_helper).

helper_entry() ->
    ?GH:sync_task([ par
                  , fun () -> ok end
                  , fun () -> ok end
                  ]),
    morpheus_guest:exit_with(success),
    ok.

t_timestamp() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, timestamp_entry, [],
                                         [ monitor
                                         , {clock_offset, 10000}
                                         ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

timestamp_entry() ->
    0 = erlang:monotonic_time(),
    10000 = erlang:system_time(),
    10000 = erlang:system_time(millisecond),
    10 = erlang:system_time(second),
    10 = erlang:convert_time_unit(10000, native, second),
    {0, 10, 0} = erlang:timestamp(),
    {0, 10, 0} = os:timestamp(),
    10000 = os:system_time(),
    10 = os:system_time(second),
    morpheus_guest:exit_with(success),
    ok.

t_error() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, error_test_entry, [],
                                         [ monitor ] ++ config()),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

error_test_entry() ->
    process_flag(trap_exit, true),
    Pid1 = spawn_link(fun () ->
                              exit(shutdown)
                      end),
    receive {'EXIT', Pid1, shutdown} -> ok end,
    {Pid2, M2} = spawn_monitor(
                   fun () ->
                           error(abc)
                   end),
    receive {'DOWN', M2, process, Pid2, {abc, _}} -> ok end,
    {Pid3, M3} = spawn_monitor(
                   fun () ->
                           error(abc, def)
                   end),
    receive {'DOWN', M3, process, Pid3, {abc, _}} -> ok end,
    {Pid4, M4} = spawn_monitor(
                   fun () ->
                           throw(abc)
                   end),
    receive {'DOWN', M4, process, Pid4, {{nocatch, abc}, _}} -> ok end,
    {Pid5, M5} = spawn_monitor(
                   fun () ->
                           spawn_link(fun () ->
                                              error(exit)
                                      end),
                           receive after infinity -> ok end
                   end),
    receive {'DOWN', M5, process, Pid5, {exit, _}} -> ok end,
    {Pid6, M6} = spawn_monitor(
                   fun () ->
                           process_flag(trap_exit, true),
                           Pid = spawn_link(fun () ->
                                              exit(self(), kill)
                                      end),
                           receive {'EXIT', Pid, killed} -> exit(saw_killed) after infinity -> ok end
                   end),
    receive {'DOWN', M6, process, Pid6, saw_killed} -> ok end,
    {Pid7, M7} = spawn_monitor(
                   fun () ->
                           Pid = spawn_link(fun () ->
                                              exit(self(), kill)
                                      end),
                           receive after infinity -> ok end
                   end),
    receive {'DOWN', M7, process, Pid7, killed} -> ok end,
    morpheus_guest:exit_with(success),
    ok.
