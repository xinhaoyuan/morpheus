-define(ctl_call_node_created(Ctl, Node),
        call_ctl(Ctl, {node_created, Node})).
-define(ctl_call_get_opt(Ctl),
        call_ctl(Ctl, {get_opt})).
-define(ctl_call_get_shtab(Ctl),
        call_ctl(Ctl, {get_shtab})).
-define(ctl_call_initial_kick(Ctl),
        call_ctl(Ctl, {initial_kick})).
-define(ctl_call_instrument_module(Ctl, M),
        call_ctl(Ctl, {instrument, M})).
-define(ctl_call_undet(Ctl),
        call_ctl(Ctl, {undet})).
-define(ctl_call_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, {process_send, From, Where, To, Msg})).
-define(ctl_call_undet_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, {undet, {process_send, From, Where, To, Msg}})).
-define(ctl_call_nodelay_send_msg(Ctl, From, Where, To, Msg),
        call_ctl(Ctl, {nodelay, {process_send, From, Where, To, Msg}})).
-define(ctl_call_send_signal(Ctl, From, Where, To, Reason),
        call_ctl(Ctl, {process_send_signal, From, Where, To, Reason})).
