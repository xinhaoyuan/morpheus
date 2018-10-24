-module(sandbox_race_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , {timeout, 120, ?_test( t_basic() )}
    ].

t_basic() ->
    firedrill:start([{scheduler,
                      {basicpos, [
                                 ]}},
                     {use_fd_sup, false}, {try_fire_timeout, infinity}, verbose_final]),
    {Ctl, MRef} = morpheus_sandbox:start(
                    ?MODULE, basic_test_entry, [],
                    [ monitor
                    , {firedrill_scheduler, whereis(fd_sched)}
                    %% , verbose_handle, verbose_ctl
                    ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    firedrill:stop(),
    ok.

-define(GH, morpheus_guest_helper).
-define(G, morpheus_guest).

basic_test_entry() ->
    ?GH:bootstrap(),
    {ok, Fd} = file:open("test.txt", [write, binary]),
    %% ?GH:sync_task(
    %%    [ par
    %%    , fun () ->
    %%              ok = file:pwrite(Fd, 10, <<"hello">>)
    %%      end
    %%    , fun () ->
    %%              ok = file:pwrite(Fd, 6, <<"world">>)
    %%      end
    %%    ]),
    ok = file:pwrite(Fd, 10, <<"hello">>),
    ok = file:pwrite(Fd, 6, <<"world">>),
    file:close(Fd),
    ?G:exit_with(success),
    ok.
