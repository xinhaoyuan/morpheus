-module(helper_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    ].

-define(h, morpheus_helper).

erase_pid(Pid) when is_pid(Pid) ->
    pid.

t_basic() ->
    {pid, pid, pid} = ?h:replace_pid({self(), self(), self()}, fun erase_pid/1),
    [{pid, pid}] = dict:to_list(?h:replace_pid(dict:store(self(), self(), dict:new()), fun erase_pid/1)),
    ok.
