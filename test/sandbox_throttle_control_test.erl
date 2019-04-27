-module(sandbox_throttle_control_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    ].

-define(T, morpheus_tracer).
-define(S, morpheus_sandbox).
-define(G, morpheus_guest).

t_basic() ->
    {Ctl, MRef} = ?S:start(?MODULE, test_entry, [],
                           [ monitor
                           , {fd_opts, [{scheduler, {rw, []}}]}
                           , {throttle_control, {100, 100}}
                           , {clock_limit, 1000}
                           ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

test_entry() ->
    %% test simple send/receive
    (fun Loop(0) -> ok;
         Loop(X) ->
             self() ! yo,
             receive yo -> ok end,
             Loop(X - 1)
     end)(10000),
    ?G:exit_with(success).
