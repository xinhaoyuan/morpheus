-module(helper_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    ].

-define(H, morpheus_helper).

%% very preliminary

erase_pid(Pid) when is_pid(Pid) ->
    pid;
erase_pid(Other) ->
    Other.

t_basic() ->
    {pid, pid, pid} = ?H:replace_pid({self(), self(), self()}, fun erase_pid/1),
    [{pid, pid}] = dict:to_list(?H:replace_pid(dict:store(self(), self(), dict:new()), fun erase_pid/1)),
    ok.
