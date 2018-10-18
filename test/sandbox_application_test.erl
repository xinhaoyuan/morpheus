-module(sandbox_application_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    %% , ?_test( t_sandbox_bootstrap() )
    , {timeout, 120, ?_test( t_real_kernel() )}
    ].

t_sandbox_bootstrap() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, sandbox_bootstrap_entry, [],
                                         [ monitor ]),
    normal = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

sandbox_bootstrap_entry() ->
    morpheus_guest_helper:bootstrap(),
    morpheus_guest_helper:cleanup(),
    ok.

t_real_kernel() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, real_kernel_entry, [],
                                         [ monitor ]),
    normal = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

real_kernel_entry() ->
    morpheus_guest_helper:bootstrap_real(),
    morpheus_guest_helper:cleanup(),
    ok.
