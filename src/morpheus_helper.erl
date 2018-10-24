-module(morpheus_helper).

-export([take_nth/2, while/2, replace_pid/2]).

take_nth(N, List) ->
    take_nth(N, [], List).
take_nth(1, RPrefix, [E | Rest]) ->
    {E, lists:reverse(RPrefix) ++ Rest};
take_nth(N, RPrefix, [E | Rest]) ->
    take_nth(N - 1, [E | RPrefix], Rest).

while(State, Body) ->
    case Body(State) of
        {true, State0} ->
            while(State0, Body);
        Other ->
            Other
    end.

replace_pid(Lst, F) when is_list(Lst) ->
    replace_pid_list([], Lst, F);
replace_pid(Tp, F) when is_tuple(Tp) ->
    replace_pid_tuple(tuple_size(Tp), Tp, F);
replace_pid(Map, F) when is_map(Map) ->
    maps:map(fun (_K, V) ->
                     replace_pid(V, F)
             end, Map);
replace_pid(Else, F) ->
    F(Else).

replace_pid_list(Rev, [H | T], F) ->
    replace_pid_list([replace_pid(H, F) | Rev], T, F);
replace_pid_list(Rev, [], _) ->
    lists:reverse(Rev);
replace_pid_list(Rev, E, F) ->
    lists:foldl(fun (I, Acc) ->
                        [I | Acc]
                end, replace_pid(E, F), Rev).

replace_pid_tuple(0, Tp, _) ->
    Tp;
replace_pid_tuple(Pos, Tp, F) ->
    replace_pid_tuple(Pos - 1, setelement(Pos, Tp, replace_pid(element(Pos, Tp), F)), F).

