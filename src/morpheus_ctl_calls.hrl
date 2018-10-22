-define(cci_node_created(Node), {node_created, Node}).
-define(cci_get_opt(), {get_opt}).
-define(cci_get_shtab(), {get_shtab}).
-define(cci_initial_kick(), {initial_kick}).
-define(cci_instrument_module(M), {instrument, M}).
-define(cci_undet(), {undet}).
-define(cci_send_msg(From, Where, To, Msg), {process_send, From, Where, To, Msg}).
-define(cci_send_signal(From, Where, To, Reason), {process_send_signal, From, Where, To, Reason}).
-define(cci_process_link(From, To), {process_link, From, To}).
-define(cci_process_unlink(From, To), {process_unlink, From, To}).
-define(cci_ets_all(), {ets_all}).
-define(cci_get_clock(), {get_clock}).
-define(cci_process_receive(Proc, PatFun, Timeout), {process_receive, Proc, PatFun, Timeout}).
-define(cci_process_on_exit(Proc, Reason), {process_on_exit, Proc, Reason}).
-define(cci_instrumented_process_created(Node, Proc), {instrumented_process_created, Node, Proc}).
-define(cci_instrumented_process_list(Node), {instrumented_process_list, Node}).
-define(cci_instrumented_registered_list(Node), {instrumented_registered_list, Node}).
-define(cci_process_monitor(Watcher, WatcherNode, Target), {process_monitor, Watcher, WatcherNode, Target}).
-define(cci_process_demonitor(Watcher, Ref, Opts), {process_demonitor, Watcher, Ref, Opts}).
-define(cci_register_external_process(Node, Name, Proc), {register_external_process, Node, Name, Proc}).
-define(cci_register_process(Node, Name, Proc), {register_process, Node, Name, Proc}).
-define(cci_unregister(Node, Name), {unregister, Node, Name}).
-define(cci_whereis(FromNode, Node, Name), {whereis, FromNode, Node, Name}).

-define(cc_node_created(Ctl, Node),
        call_ctl(Ctl, ?cci_node_created(Node))).

-define(cc_get_opt(Ctl),
        call_ctl(Ctl, ?cci_get_opt())).

-define(cc_get_shtab(Ctl),
        call_ctl(Ctl, ?cci_get_shtab())).

-define(cc_initial_kick(Ctl),
        call_ctl(Ctl, ?cci_initial_kick())).

-define(cc_instrument_module(Ctl, M),
        call_ctl(Ctl, ?cci_instrument_module(M))).

-define(cc_undet(Ctl),
        call_ctl(Ctl, ?cci_undet())).

-define(cc_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, ?cci_send_msg(From, Where, To, Msg))).
-define(cc_undet_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, {undet, ?cci_send_msg(From, Where, To, Msg)})).
-define(cc_nodelay_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, {nodelay, ?cci_send_msg(From, Where, To, Msg)})).

-define(cc_send_signal(Ctl, From, Where, To, Reason),
        call_ctl(Ctl, ?cci_send_signal(From, Where, To, Reason))).

-define(cc_process_link(Ctl, From, To),
        call_ctl(Ctl, ?cci_process_link(From, To))).

-define(cc_process_unlink(Ctl, From, To),
        call_ctl(Ctl, ?cci_process_unlink(From, To))).

-define(cc_ets_all(Ctl),
        call_ctl(Ctl, ?cci_ets_all())).

-define(cc_get_clock(Ctl),
        call_ctl(Ctl, ?cci_get_clock())).

-define(cc_process_receive(Ctl, Proc, PatFun, Timeout),
        call_ctl(Ctl, ?cci_process_receive(Proc, PatFun, Timeout))).

-define(cc_process_on_exit(Ctl, Proc, Reason),
        call_ctl(Ctl, ?cci_process_on_exit(Proc, Reason))).

-define(cc_instrumented_process_created(Ctl, Node, Proc),
        call_ctl(Ctl, ?cci_instrumented_process_created(Node, Proc))).

-define(cc_instrumented_process_list(Ctl, Node),
        call_ctl(Ctl, ?cci_instrumented_process_list(Node))).

-define(cc_instrumented_registered_list(Ctl, Node),
        call_ctl(Ctl, ?cci_instrumented_registered_list(Node))).

-define(cc_register_external_process(Ctl, Node, Name, Proc),
        call_ctl(Ctl, ?cci_register_external_process(Node, Name, Proc))).

-define(cc_register_process(Ctl, Node, Name, Proc),
        call_ctl(Ctl, ?cci_register_process(Node, Name, Proc))).

-define(cc_unregister(Ctl, Node, Name),
        call_ctl(Ctl, ?cci_unregister(Node, Name))).

-define(cc_whereis(Ctl, FromNode, Node, Name),
        call_ctl(Ctl, ?cci_whereis(FromNode, Node, Name))).
