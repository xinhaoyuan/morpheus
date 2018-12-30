-module(morpheus_guest_real).

-export([ call_ctl/1
        , report_state/1
        , log/1
        , cast_ctl/1
        , get_node/0
        , exit_with/1
        , in_sandbox/0
        , start_node/4
        , set_flags/1
        , get_code_path/0
        , get_kernel_app/0
        , raw_apply/3
        , global_get/1
        , global_set/2
        , global_remove/1
        ]).

-include("morpheus.hrl").
-include("morpheus_priv.hrl").

-define(S, morpheus_sandbox).

call_ctl(Args) ->
    ?S:call_ctl(?S:get_ctl(), undefined, {nodelay, Args}).

report_state(State) ->
    call_ctl(?cci_guest_report_state(State)).

log(L) ->
    call_ctl(?cci_log(L)).

cast_ctl(Args) ->
    ?S:cast_ctl(?S:get_ctl(), Args).

get_node() ->
    ?S:get_node().

exit_with(Reason) ->
    ?S:cast_ctl(?S:get_ctl(), {stop, Reason}).

in_sandbox() ->
    true.

start_node(Node, M, F, A) ->
    ?S:start_node(Node, M, F, A).

set_flags(Flags) ->
    lists:foreach(
      fun ({Name, Value}) ->
              ?S:set_flag(Name, Value)
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

global_get(K) ->
    Tab = ?S:get_shtab(),
    RealK = {'$test_global', K},
    GetResult = ?SHTABLE_GET(Tab, RealK),
    case GetResult of
        {_, V} ->
            {value, V};
        undefined ->
            error
    end.

global_set(K, V) ->
    RealK = {'$test_global', K},
    Tab = ?S:get_shtab(),
    ?SHTABLE_REMOVE(Tab, RealK),
    ?SHTABLE_SET(Tab, RealK, V).

global_remove(K) ->
    RealK = {'$test_global', K},
    Tab = ?S:get_shtab(),
    ?SHTABLE_REMOVE(Tab, RealK).
