-define(ctl_call_node_created(Ctl, Node),
        call_ctl(Ctl, {node_created, Node})).
-define(ctl_call_get_opt(Ctl),
        call_ctl(Ctl, {get_opt})).
-define(ctl_call_get_shtab(Ctl),
        call_ctl(Ctl, {get_shtab})).
-define(ctl_call_initial_kick(Ctl),
        call_ctl(Ctl, {initial_kick})).
