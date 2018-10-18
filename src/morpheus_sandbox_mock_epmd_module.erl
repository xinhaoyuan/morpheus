-module(morpheus_sandbox_mock_epmd_module).

-export([ start/0, start_link/0, stop/0
        , port_please/2, port_please/3, names/1
        , register_node/2, register_node/3
        ]).

start() ->
    ignore.

start_link() ->
    ignore.

stop() ->
    ok.

register_node(Name, Port) ->
    register_node(Name, Port, inet).

register_node(_Name, _Port, _Family) ->
    io:format(user, "EPMD: register_node(~w, ~w, ~w)~n", [_Name, _Port, _Family]),
    {ok, rand:uniform(3)}.

names(_Hostname) ->
    io:format(user, "EPMD: names(~w)~n", [_Hostname]),
    {error, address}.

port_please(Name, IP) ->
    port_please(Name, IP, infinity).

port_please(_Name, _IP, _Timeout) ->
    io:format(user, "EPMD: port_please(~w, ~w, ~w)~n", [_Name, _IP, _Timeout]),
    noport.
