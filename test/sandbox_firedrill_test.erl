-module(sandbox_firedrill_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("firedrill/include/firedrill.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    , ?_test( t_scoped_weight() )
    , {timeout, 20, ?_test( t_bootstrap_with_rapos() )}
    ].

t_basic() ->
    firedrill:start([{use_fd_sup, false}, {try_fire_timeout, infinity}, verbose_final]),
    {Ctl, MRef} = morpheus_sandbox:start(
                    sandbox_test, basic_test_entry, [],
                    [ monitor
                    , {fd_scheduler, whereis(fd_sched)}
                    ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    firedrill:stop(),
    ok.

is_scoped(sandbox_test) ->
    true;
is_scoped(_) ->
    false.

t_scoped_weight() ->
    firedrill:start([{use_fd_sup, false}, {try_fire_timeout, infinity}, verbose_final]),
    {Ctl, MRef} = morpheus_sandbox:start(
                    sandbox_test, basic_test_entry, [],
                    [ monitor
                    , {fd_scheduler, whereis(fd_sched)}
                    , {aux_module, ?MODULE}
                    , {scoped_weight, true}
                    ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    firedrill:stop(),
    ok.

t_bootstrap_with_rapos() ->
    firedrill:start([{scheduler, {rapos, []}}, {use_fd_sup, false}, {try_fire_timeout, infinity}, verbose_final]),
    {Ctl, MRef} = morpheus_sandbox:start(
                    sandbox_application_test, sandbox_bootstrap_entry, [],
                    [ monitor
                    , {fd_scheduler, whereis(fd_sched)}
                    ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    firedrill:stop(),
    ok.
