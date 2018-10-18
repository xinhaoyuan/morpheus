-module(sandbox_dist_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
      %% , {timeout, 120, ?_test( t_basic() )}
      %% , {timeout, 120, ?_test( t_two_nodes() )}
    , {timeout, 120, ?_test( t_remote_node() )}
    ].

t_basic() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, basic_test_entry, [],
                                         [ monitor
                                         , {heartbeat, 5000}
                                         , {node, test@localhost}
                                         ]),
    normal = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

basic_test_entry() ->
    morpheus_guest_helper:bootstrap_real(),
    net_kernel:start([test@localhost]),
    io:format(user, "node ~p~n", [node()]),
    morpheus_guest_helper:cleanup(),
    ok.

t_two_nodes() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, two_nodes_test_entry, [],
                                         [ monitor
                                         , {heartbeat, 5000}
                                         , {node, test@localhost}
                                         ]),
    normal = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

two_nodes_test_entry() ->
    morpheus_guest_helper:bootstrap_real(),
    io:format(user, "before node ~p~n", [node()]),
    net_kernel:start([test@localhost]),
    io:format(user, "node ~p~n", [node()]),
    morpheus_guest_helper:cleanup(),
    ok.

node2_entry() ->
    morpheus_guest_helper:bootstrap_real(),
    io:format(user, "before node ~p~n", [node()]),
    net_kernel:start([test2@localhost]),
    io:format(user, "after node ~p~n", [node()]),
    morpheus_guest_helper:cleanup(),
    ok.

t_remote_node() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, remote_node_entry, [],
                                         [ monitor
                                         , {node, test@localhost}
                                         ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

remote_node_entry() ->
    morpheus_guest_helper:bootstrap_real_remote(test2@localhost),
    morpheus_guest_helper:bootstrap_real(test@localhost),
    ok = rpc:call(test2@localhost, ?MODULE, print_node, []),
    [] = nodes() -- [test2@localhost],
    morpheus_guest:exit_with(success),
    ok.

print_node() ->
    test2@localhost = node(),
    ok.
