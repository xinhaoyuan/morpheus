-module(sandbox_trace_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    ].

t_basic() ->
    Tab = ets:new(trace_tab, [ordered_set, public, {write_concurrency, true}]),
    ets:insert(Tab, {trace_counter, 0}),
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, basic_test_entry, [],
                                         [ monitor
                                         , {trace_tab, Tab}
                                         ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ets:foldl(fun (E, Acc) ->
                      io:format(user, "~p~n", [E]),
                      Acc
              end, undefined, Tab),
    ok.

basic_test_entry() ->
    %% test simple send/receive
    (fun Loop(0) -> ok;
         Loop(X) ->
             self() ! yo,
             receive yo -> ok end,
             Loop(X - 1)
     end)(5),
    morpheus_guest:exit_with(success).
