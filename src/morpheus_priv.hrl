%% -define(DEBUG, 1).
%% -define(VERBOSE_DEBUG, 1).

-ifdef(DEBUG).
-define(DEBUG(Format, Args), (begin io:format(user, "DEBUG - " ++ (Format) ++ "~n", Args), ok end)).
-else.
-define(DEBUG(Format, Args), ok).
-endif.

-ifdef(VERBOSE_DEBUG).
-define(VERBOSE_DEBUG(Format, Args), (begin io:format(user, "VERBOSE_DEBUG - " ++ (Format) ++ "~n", Args), ok end)).
-else.
-define(VERBOSE_DEBUG(Format, Args), ok).
-endif.

-define(INFO(Format, Args), (begin io:format(user, "INFO - " ++ (Format) ++ "~n", Args), ok end)).
-define(WARNING(Format, Args), (begin io:format(user, "WARNING - " ++ (Format) ++ "~n", Args), ok end)).
-define(ERROR(Format, Args), (begin io:format(user, "ERROR - " ++ (Format) ++ "~n", Args), ok end)).

%% table (supposed to used by a single process)
-define(TABLE_TYPE(), ets:tid()).
-define(TABLE_NEW(), ets:new(?MODULE, [])).
-define(TABLE_SET(Table, Key, Value), '__table_set'(Table, Key, Value)).
-define(TABLE_REMOVE(Table, Key), '__table_remove'(Table, Key)).
-define(TABLE_GET(Table, Key), '__table_get'(Table, Key)).
-define(TABLE_FOLD(Table, Func, Initial), '__table_fold'(Table, Func, Initial)).

%% shared table
-define(SHTABLE_TYPE(), ets:tid()).
-define(SHTABLE_NEW(), ets:new(?MODULE, [public, {read_concurrency, true}, {write_concurrency, true}])).
-define(SHTABLE_SET(Table, Key, Value), '__table_set'(Table, Key, Value)).
-define(SHTABLE_REMOVE(Table, Key), '__table_remove'(Table, Key)).
-define(SHTABLE_GET(Table, Key), '__table_get'(Table, Key)).
-define(SHTABLE_FOLD(Table, Func, Initial), '__table_fold'(Table, Func, Initial)).

-compile({inline, ['__table_set'/3, '__table_remove'/2, '__table_get'/2, '__table_fold'/3]}).
-compile({nowarn_unused_function, ['__table_set'/3, '__table_remove'/2, '__table_get'/2, '__table_fold'/3]}).

'__table_set'(T, K, V) -> ets:insert(T, {K, V}), T.
'__table_remove'(T, K) -> ets:delete(T, K), T.
'__table_get'(T, K) -> case ets:lookup(T, K) of [] -> undefined; [_KV|_] -> _KV end.
'__table_fold'(T, F, I) -> ets:foldl(F, I, T).

%% ctl call shortcut

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
