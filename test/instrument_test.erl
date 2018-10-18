-module(instrument_test).

-include_lib("eunit/include/eunit.hrl").

-export([to_handle/4, handle/5]).

simple_test() ->
    lists:foreach(fun (ModName) ->
                          NewModName = list_to_atom(atom_to_list(ModName) ++ "_i"),
                          {module, ModName} = code:ensure_loaded(ModName),
                          {ModName, ObjectCode, Filename} = code:get_object_code(ModName),
                          {ok, _, _, _} = morpheus_instrument:instrument_and_load(?MODULE, none, ModName, NewModName, Filename, ObjectCode)
                  end,
                  [ %%
                    test_mod
                  , instr_test_mod_1
                  ]).

to_handle(none, _, _, _) ->
    {true, none}.

handle(Old, New, Tag, Args, _Ann) ->
    io:format(user, "handle ~w ~p~n", [Tag, Args]),
    case {Tag, Args} of
        {apply, [Fun, ApplyArgs]} ->
            erlang:apply(Fun, ApplyArgs);
        {call, [erlang, '!', [T, M]]} ->
            T ! M;
        {call, [Old, Name, CallArgs]} ->
            erlang:apply(New, Name, CallArgs);
        {call, [Module, Name, CallArgs]} ->
            erlang:apply(Module, Name, CallArgs)
    end.
