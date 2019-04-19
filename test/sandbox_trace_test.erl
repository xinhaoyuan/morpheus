-module(sandbox_trace_test).

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
    Tab = ?T:create_ets_tab(),
    {ok, Tracer} = ?T:start_link([{tab, Tab}, {acc_filename, "acc.dat"}]),
    {Ctl, MRef} = ?S:start(?MODULE, receive_entry, [],
                           [ monitor
                           , {tracer_pid, Tracer}
                           , {fd_opts, [{scheduler, {rw, []}}]}
                           ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ets:foldl(fun (E, Acc) ->
                      io:format(user, "~p~n", [E]),
                      Acc
              end, undefined, Tab),
    ?T:stop(Tracer),
    os:cmd("rm acc.dat"),
    ok.

basic_test_entry() ->
    %% test simple send/receive
    (fun Loop(0) -> ok;
         Loop(X) ->
             self() ! yo,
             receive yo -> ok end,
             Loop(X - 1)
     end)(5),
    ?G:exit_with(success).

receive_entry() ->
    self() ! msg,
    receive
        msg ->
            ok
    after 0 ->
            ok
    end,
    receive
        msg ->
            ok
    after 0 ->
            ok
    end,
    ?G:exit_with(success).
