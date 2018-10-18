-module(instr_test_mod_1).

%% instrumentation used to fail in otp-22 but not in otp-20
%% because of the missing failure branch in receive -> case transformation

-compile(export_all).

entry() ->
    ok.

foo() ->
    receive
        X when X =/= 10 ->
            ok
    end.
