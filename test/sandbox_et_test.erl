-module(sandbox_et_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    ].

t_basic() ->
    {ok, Collector} = et_collector:start_link([]),
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, basic_test_entry, [],
                                         [ monitor
                                         , {et_handle, Collector}
                                         ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    et_collector:iterate( Collector, first, infinity
                        , fun (E, Acc) ->
                                  io:format(user, "~p~n", [E])
                          end
                        , undefined),
    %% ok = et_collector:stop(Collector),
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
