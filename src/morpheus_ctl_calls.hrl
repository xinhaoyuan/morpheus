-define(cci_node_created(Node), {node_created, Node}).
-define(ctl_call_node_created(Ctl, Node),
        call_ctl(Ctl, ?cci_node_created(Node))).

-define(cci_get_opt(), {get_opt}).
-define(ctl_call_get_opt(Ctl),
        call_ctl(Ctl, ?cci_get_opt())).

-define(cci_get_shtab(), {get_shtab}).
-define(ctl_call_get_shtab(Ctl),
        call_ctl(Ctl, ?cci_get_shtab())).

-define(cci_initial_kick(), {initial_kick}).
-define(ctl_call_initial_kick(Ctl),
        call_ctl(Ctl, ?cci_initial_kick())).

-define(cci_instrument_module(M), {instrument, M}).
-define(ctl_call_instrument_module(Ctl, M),
        call_ctl(Ctl, ?cci_instrument_module(M))).

-define(cci_undet(), {undet}).
-define(ctl_call_undet(Ctl),
        call_ctl(Ctl, ?cci_undet())).

-define(cci_send_msg(From, Where, To, Msg), {process_send, From, Where, To, Msg}).
-define(ctl_call_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, ?cci_send_msg(From, Where, To, Msg))).
-define(ctl_call_undet_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, {undet, ?cci_send_msg(From, Where, To, Msg)})).
-define(ctl_call_nodelay_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, {nodelay, ?cci_send_msg(From, Where, To, Msg)})).

-define(cci_send_signal(From, Where, To, Reason), {process_send_signal, From, Where, To, Reason}).
-define(ctl_call_send_signal(Ctl, From, Where, To, Reason),
        call_ctl(Ctl, ?cci_send_signal(From, Where, To, Reason))).

-define(cci_process_link(From, To), {process_link, From, To}).
-define(ctl_call_process_link(Ctl, From, To),
        call_ctl(Ctl, ?cci_process_link(From, To))).

-define(cci_process_unlink(From, To), {process_unlink, From, To}).
-define(ctl_call_process_unlink(Ctl, From, To),
        call_ctl(Ctl, ?cci_process_unlink(From, To))).

-define(cci_ets_all(), {ets_all}).
-define(ctl_call_ets_all(Ctl),
        call_ctl(Ctl, ?cci_ets_all())).

-define(cci_get_clock(), {get_clock}).
-define(ctl_call_get_clock(Ctl),
        call_ctl(Ctl, ?cci_get_clock())).

-define(cci_process_receive(Proc, PatFun, Timeout), {process_receive, Proc, PatFun, Timeout}).
-define(ctl_call_process_receive(Ctl, Proc, PatFun, Timeout),
        call_ctl(Ctl, ?cci_process_receive(Proc, PatFun, Timeout))).

-define(cci_process_on_exit(Proc, Reason), {process_on_exit, Proc, Reason}).
-define(ctl_call_process_on_exit(Ctl, Proc, Reason),
        call_ctl(Ctl, ?cci_process_on_exit(Proc, Reason))).
