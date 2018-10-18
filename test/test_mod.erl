-module(test_mod).

-compile(export_all).

main() ->
    A = fun () -> hello(0) end,
    call(A),
    X = ?MODULE,
    call_m(X),
    hello(1),
    ?MODULE:hello(2),
    erlang:send(spawn(fun () -> receive Name -> io:format(user, "hello from ~p~n", [Name]) end end), "test send"),
    spawn(fun () -> receive Name -> io:format(user, "hello from ~p~n", [Name]) end end) ! "test bang",
    ok.

call(F) ->
    F().

call_m(M) ->
    M:hello(-1).

hello(I) ->
    io:format(user, "hello ~w!~n", [I + 1]).

