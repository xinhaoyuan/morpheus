-module(sandbox_guest_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , ?_test( t_basic() )
    ].

t_basic() ->
    try
        morpheus_guest:get_node(),
        error(unexpected)
    catch
        error:not_in_sandbox -> ok
    end,
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, basic_test_entry, [], [monitor]),
    normal = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

basic_test_entry() ->
    io:format("hello from ~p~n", [morpheus_guest:get_node()]),
    morpheus_guest:log(log_test),
    ok.
