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
