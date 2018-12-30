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

names(_Hostname) ->
    io:format(user, "EPMD: names(~w)~n", [_Hostname]),
    {error, address}.

port_please(Name, IP) ->
    port_please(Name, IP, infinity).

-define(DUMMY_EPMD, true).

-ifdef(DUMMY_EPMD).
register_node(Name, Port, _Family) ->
    V = rand:uniform(3),
    io:format(user, "EPMD: register_node(~s, ~w, ~w) => {ok, ~w}~n", [Name, Port, _Family, V]),
    {ok, V}.

port_please(Name, _IP, _Timeout) ->
    io:format(user, "EPMD: port_please(~s, ~w, ~w)~n", [Name, _IP, _Timeout]),
    noport.
-else.
register_node(Name, Port, _Family) ->
    Key = if
              is_list(Name) ->
                  {?MODULE, list_to_atom(Name)};
              is_atom(Name) ->
                  {?MODULE, Name}
          end,
    V = rand:uniform(3),
    morpheus_guest:global_set(Key, {Port, V}),
    io:format(user, "EPMD: register_node(~s, ~w, ~w) => {ok, ~w}~n", [Name, Port, _Family, V]),
    {ok, V}.

port_please(Name, _IP, _Timeout) ->
    Key = if
              is_list(Name) ->
                  {?MODULE, list_to_atom(Name)};
              is_atom(Name) ->
                  {?MODULE, Name}
          end,
    R = case morpheus_guest:global_get(Key) of
        error -> noport;
        {value, {Port, V}} -> {port, Port, V}
    end,
    io:format(user, "EPMD: port_please(~s, ~w, ~w) => ~w~n", [Name, _IP, _Timeout, R]),
    R.
-endif.
