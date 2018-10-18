-module(morpheus_guest_real).

-export([ call_ctl/1
        , cast_ctl/1
        , get_node/0
        , exit_with/1
        , in_sandbox/0
        , start_node/4
        , set_flags/1
        , get_code_path/0
        , get_kernel_app/0
        , raw_apply/3
        ]).

call_ctl(Args) ->
    morpheus_sandbox:call_ctl(morpheus_sandbox:get_ctl(), Args).

cast_ctl(Args) ->
    morpheus_sandbox:cast_ctl(morpheus_sandbox:get_ctl(), Args).

get_node() ->
    morpheus_sandbox:get_node().

exit_with(Reason) ->
    morpheus_sandbox:cast_ctl(morpheus_sandbox:get_ctl(), {stop, Reason}).

in_sandbox() ->
    true.

start_node(Node, M, F, A) ->
    morpheus_sandbox:start_node(Node, M, F, A).

set_flags(Flags) ->
    lists:foreach(
      fun ({Name, Value}) ->
              morpheus_sandbox:set_flag(Name, Value)
      end, Flags).

get_code_path() ->
    code:get_path().

get_kernel_app() ->
    case code:where_is_file("kernel.app") of
        non_existing ->
            error(?MODULE);
        FullName ->
            case file:consult(FullName) of
                {ok, [AppInfo]} ->
                    AppInfo;
                _ ->
                    error(?MODULE)
            end
    end.

raw_apply(M, F, A) ->
    erlang:apply(M, F, A).
