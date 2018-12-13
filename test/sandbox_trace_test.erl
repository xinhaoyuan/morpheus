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
    {Ctl, MRef} = ?S:start(?MODULE, basic_test_entry, [],
                           [ monitor
                           , {tracer_args, [{tab, Tab}, {acc_filename, "acc.dat"}]}
                           ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ets:foldl(fun (E, Acc) ->
                      io:format(user, "~p~n", [E]),
                      Acc
              end, undefined, Tab),
    AccTab = ?T:create_acc_ets_tab(),
    ?T:merge_path(Tab, AccTab),
    [NodeCount1] = ets:lookup(AccTab, node_counter),
    %% make sure that adding the same path does not create new path nodes.
    ?T:merge_path(Tab, AccTab),
    [NodeCount1] = ets:lookup(AccTab, node_counter),
    %% [PathCount] = ets:lookup(AccTab, path_counter),
    %% io:format(user, "~p~n", [PathCount]),
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
