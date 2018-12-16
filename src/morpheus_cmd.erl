-module(morpheus_cmd).

-export([main/1]).

-define(T, morpheus_tracer).

main(["show-acc-fanout", AccFilename]) ->
    {ok, AccTab} = ets:file2tab(AccFilename, [{verify, true}]),
    {MaxDepth, Fanout} = ?T:calc_acc_fanout(AccTab),
    lists:foreach(
      fun (D) ->
              #{D := N} = Fanout,
              io:format("~w: ~w~n", [D, N])
      end, lists:seq(0, MaxDepth));
main(["show-states", AccFilename]) ->
    {ok, AccTab} = ets:file2tab(AccFilename, [{verify,true}]),
    StateCount =
        ets:foldl(
          fun ({{state_coverage, State}, Count}, Acc) ->
                  io:format("~w: ~p~n", [Count, State]),
                  Acc + 1;
              (_, Acc) ->
                  Acc
          end, 0, AccTab),
    [{state_coverage_counter, TabCount}] = ets:lookup(AccTab, state_coverage_counter),
    TabCount = StateCount,
    io:format("~w state listed.~n", [StateCount]);
main(Args) ->
    io:format(standard_error, "Badarg: ~p~n", [Args]).
