-module(sandbox_application_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , {timeout, 120, ?_test( t_sandbox_bootstrap() )}
    ].

t_sandbox_bootstrap() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, sandbox_bootstrap_entry, [],
                                         [ monitor ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

sandbox_bootstrap_entry() ->
    morpheus_guest_helper:bootstrap(),
    morpheus_guest:exit_with(success).
