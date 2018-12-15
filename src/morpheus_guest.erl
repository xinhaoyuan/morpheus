-module(morpheus_guest).

-export([ call_ctl/1
        , report_state/1
        , cast_ctl/1
        , get_node/0
        , exit_with/1
        , in_sandbox/0
        , start_node/4
        , set_flags/1
        , get_code_path/0
        , get_kernel_app/0
        , raw_apply/3
        , log/1
        ]).

call_ctl(_Args) ->
    error(not_in_sandbox).

report_state(_State) ->
    error(not_in_sandbox).

cast_ctl(_Args) ->
    error(not_in_sandbox).

get_node() ->
    error(not_in_sandbox).

exit_with(_Reason) ->
    error(not_in_sandbox).

in_sandbox() ->
    error(not_in_sanbox).

start_node(_Node, _M, _F, _A) ->
    error(not_in_sandbox).

set_flags(_Flags) ->
    error(not_in_sandbox).

get_code_path() ->
    error(not_in_sandbox).

get_kernel_app() ->
    error(not_in_sandbox).

raw_apply(_M, _F, _A) ->
    error(not_in_sandbox).

log(_L) ->
    error(not_in_sandbox).
