%% Aux module callback names. Made as macros to (sort of) separate CBs from regular functions.
-define(MORPHEUS_CB_TRACE_SEND_FILTER, '$morpheus$trace_send_filter').
-define(MORPHEUS_CB_TRACE_RECEIVE_FILTER, '$morpheus$trace_receive_filter').
-define(MORPHEUS_CB_DELAY_LEVEL, '$morpheus$delay_level').
-define(MORPHEUS_CB_TO_DELAY_CALL, '$morpheus$to_delay_call').
-define(MORPHEUS_CB_TO_OVERRIDE, '$morpheus$to_override').
-define(MORPHEUS_CB_IS_SCOPED, '$morpheus$is_scoped').
-define(MORPHEUS_CB_HANDLE_OVERRIDE, '$morpheus$handle_override').

%% ctl call tuples definition for avoiding mistakes.
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
-define(cci_log(Log), {log, Log}).


