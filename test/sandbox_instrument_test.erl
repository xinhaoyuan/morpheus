-module(sandbox_instrument_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , {timeout, 120, ?_test( t_instrument() )}
    ].

t_instrument() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, sandbox_entry, [],
                                         [ monitor ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

sandbox_entry() ->
    _ = zlib:module_info(),
    morpheus_guest:exit_with(success).
