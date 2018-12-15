-define(cci_node_created(Node), {node_created, Node}).
-define(cci_get_opt(), {get_opt}).
-define(cci_get_shtab(), {get_shtab}).
-define(cci_initial_kick(), {initial_kick}).
-define(cci_instrument_module(M), {instrument, M}).
-define(cci_undet(), {undet}).
-define(cci_send_msg(From, To, Msg), {process_send, From, To, Msg}).
-define(cci_send_signal(From, To, Reason), {process_send_signal, From, To, Reason}).
-define(cci_process_link(From, To), {process_link, From, To}).
-define(cci_process_unlink(From, To), {process_unlink, From, To}).
-define(cci_ets_all(), {ets_all}).
-define(cci_get_clock(), {get_clock}).
-define(cci_process_receive(Proc, PatFun, Timeout), {process_receive, Proc, PatFun, Timeout}).
-define(cci_process_on_exit(Proc, Reason), {process_on_exit, Proc, Reason}).
-define(cci_instrumented_process_created(Node, Proc, Creator, Entry), {instrumented_process_created, Node, Proc, Creator, Entry}).
-define(cci_instrumented_process_list(Node), {instrumented_process_list, Node}).
-define(cci_instrumented_registered_list(Node), {instrumented_registered_list, Node}).
-define(cci_process_monitor(Watcher, WatcherNode, Target), {process_monitor, Watcher, WatcherNode, Target}).
-define(cci_process_demonitor(Watcher, Ref, Opts), {process_demonitor, Watcher, Ref, Opts}).
-define(cci_register_external_process(Node, Name, Proc), {register_external_process, Node, Name, Proc}).
-define(cci_register_process(Node, Name, Proc), {register_process, Node, Name, Proc}).
-define(cci_unregister(Node, Name), {unregister, Node, Name}).
-define(cci_whereis(FromNode, Node, Name), {whereis, FromNode, Node, Name}).
-define(cci_list_nodes(FromNode, Label), {list_nodes, FromNode, Label}).
-define(cci_process_set_trap_exit(Proc, On), {process_set_trap_exit, Proc, On}).
-define(cci_process_info(Proc, Props), {process_info, Proc, Props}).
-define(cci_resource_acquire(OpList), {resource_acquire, OpList}).
-define(cci_resource_release(OpList), {resource_release, OpList}).
-define(cci_is_process_alive(Proc), {is_process_alive, Proc}).
-define(cci_unique_integer(), {unique_integer}).
-define(cci_get_advice(), {get_advice}).
-define(cci_guest_report_state(State), {guest_report_state, State}).

-define(cc_node_created(Ctl, Where, Node),
        call_ctl(Ctl, Where, ?cci_node_created(Node))).

-define(cc_get_opt(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_get_opt())).

-define(cc_get_shtab(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_get_shtab())).

-define(cc_initial_kick(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_initial_kick())).

-define(cc_instrument_module(Ctl, Where, M),
        call_ctl(Ctl, Where, ?cci_instrument_module(M))).

-define(cc_undet(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_undet())).

-define(cc_send_msg(Ctl, Where, From, To, Msg),
        call_ctl(Ctl, Where, ?cci_send_msg(From, To, Msg))).
-define(cc_undet_send_msg(Ctl, Where, From, To, Msg),
        call_ctl(Ctl, Where, {undet, ?cci_send_msg(From, To, Msg)})).
-define(cc_nodelay_send_msg(Ctl, Where, From, To, Msg),
        call_ctl(Ctl, Where, {nodelay, ?cci_send_msg(From, To, Msg)})).

-define(cc_send_signal(Ctl, Where, From, To, Reason),
        call_ctl(Ctl, Where, ?cci_send_signal(From, To, Reason))).

-define(cc_process_link(Ctl, Where, From, To),
        call_ctl(Ctl, Where, ?cci_process_link(From, To))).

-define(cc_process_unlink(Ctl, Where, From, To),
        call_ctl(Ctl, Where, ?cci_process_unlink(From, To))).

-define(cc_ets_all(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_ets_all())).

-define(cc_get_clock(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_get_clock())).

-define(cc_process_receive(Ctl, Where, Proc, PatFun, Timeout),
        call_ctl(Ctl, Where, ?cci_process_receive(Proc, PatFun, Timeout))).

-define(cc_process_on_exit(Ctl, Where, Proc, Reason),
        call_ctl(Ctl, Where, ?cci_process_on_exit(Proc, Reason))).

-define(cc_instrumented_process_created(Ctl, Where, Node, Proc, Creator, Entry),
        call_ctl(Ctl, Where, ?cci_instrumented_process_created(Node, Proc, Creator, Entry))).

-define(cc_instrumented_process_list(Ctl, Where, Node),
        call_ctl(Ctl, Where, ?cci_instrumented_process_list(Node))).

-define(cc_instrumented_registered_list(Ctl, Where, Node),
        call_ctl(Ctl, Where, ?cci_instrumented_registered_list(Node))).

-define(cc_process_monitor(Ctl, Where, Watcher, WatcherNode, Target),
        call_ctl(Ctl, Where, ?cci_process_monitor(Watcher, WatcherNode, Target))).

-define(cc_process_demonitor(Ctl, Where, Watcher, Ref, Opts),
        call_ctl(Ctl, Where, ?cci_process_demonitor(Watcher, Ref, Opts))).

-define(cc_register_external_process(Ctl, Where, Node, Name, Proc),
        call_ctl(Ctl, Where, ?cci_register_external_process(Node, Name, Proc))).

-define(cc_register_process(Ctl, Where, Node, Name, Proc),
        call_ctl(Ctl, Where, ?cci_register_process(Node, Name, Proc))).

-define(cc_unregister(Ctl, Where, Node, Name),
        call_ctl(Ctl, Where, ?cci_unregister(Node, Name))).

-define(cc_whereis(Ctl, Where, FromNode, Node, Name),
        call_ctl(Ctl, Where, ?cci_whereis(FromNode, Node, Name))).

-define(cc_list_nodes(Ctl, Where, FromNode, Label),
        call_ctl(Ctl, Where, ?cci_list_nodes(FromNode, Label))).

-define(cc_process_set_trap_exit(Ctl, Where, Proc, On),
        call_ctl(Ctl, Where, ?cci_process_set_trap_exit(Proc, On))).

-define(cc_process_info(Ctl, Where, Proc, Props),
        call_ctl(Ctl, Where, ?cci_process_info(Proc, Props))).

-define(cc_resource_acquire(Ctl, Where, OpList),
        call_ctl(Ctl, Where, ?cci_resource_acquire(OpList))).

-define(cc_resource_release(Ctl, Where, OpList),
        call_ctl(Ctl, Where, ?cci_resource_release(OpList))).

-define(cc_is_process_alive(Ctl, Where, Proc),
        call_ctl(Ctl, Where, ?cci_is_process_alive(Proc))).

-define(cc_unique_integer(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_unique_integer())).

-define(cc_get_advice(Ctl, Where),
        call_ctl(Ctl, Where, ?cci_get_advice())).
