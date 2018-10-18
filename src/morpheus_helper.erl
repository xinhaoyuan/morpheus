-module(morpheus_helper).

-export([take_nth/2, while/2]).

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
