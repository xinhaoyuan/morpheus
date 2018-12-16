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
    States =
        ets:foldl(
          fun ({{state_coverage, State}, Count}, Acc) ->
                  [{Count, State} | Acc];
              (_, Acc) ->
                  Acc
          end, [], AccTab),
    [{state_coverage_counter, TabCount}] = ets:lookup(AccTab, state_coverage_counter),
    TabCount = length(States),
    lists:foldr(
      fun ({Count, State}, Acc) ->
              io:format("~w: ~p~n", [Count, State]),
              Acc
      end, undefined, lists:sort(States)),
    io:format("~w state listed.~n", [TabCount]);
main(Args) ->
    io:format(standard_error, "Badarg: ~p~n", [Args]).
