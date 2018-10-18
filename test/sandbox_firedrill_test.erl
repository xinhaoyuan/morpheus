-module(sandbox_firedrill_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("firedrill/include/firedrill.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    ].

t_basic() ->
    firedrill:start([{use_fd_sup, false}, {try_fire_timeout, infinity}, verbose_final]),
    {Ctl, MRef} = morpheus_sandbox:start(
                    sandbox_test, basic_test_entry, [],
                    [ monitor
                    , {firedrill_scheduler, whereis(fd_sched)}
                    ]),
    normal = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    firedrill:stop(),
    ok.
