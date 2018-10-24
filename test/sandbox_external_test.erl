-module(sandbox_external_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , {timeout, 120, ?_test( t_basic() )}
    , {timeout, 120, ?_test( t_crypto() )}
    ].

t_basic() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, basic_test_entry, [],
                                         [ monitor ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

basic_test_entry() ->
    morpheus_guest_helper:bootstrap(),
    Output = os:cmd("ls"),
    io:format(user, "ls output ~p~n", [Output]),
    morpheus_guest:exit_with(success),
    ok.

t_crypto() ->
    {Ctl, MRef} = morpheus_sandbox:start(?MODULE, crypto_test_entry, [],
                                         [ monitor
                                         , {undet_nifs, [ {crypto, hash, 2} ]}]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

crypto_test_entry() ->
    morpheus_guest_helper:bootstrap(),
    application:load(crypto),
    application:ensure_started(crypto),

    crypto:hash(sha, <<"abc">>),
    morpheus_guest:exit_with(success),
    ok.
