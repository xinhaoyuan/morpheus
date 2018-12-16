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
    [{iteration_counter, ItCount}] = ets:lookup(AccTab, iteration_counter),
    TabCount = length(States),
    SortedStates = lists:sort(States),
    HitSum =
        lists:foldr(
          fun ({Count, State}, Sum) ->
                  io:format("~w: ~p~n", [Count, State]),
                  Sum + Count
          end, 0, SortedStates),
    Mean = HitSum / ItCount / TabCount,
    Variance =
        lists:foldr(
          fun ({Count, _State}, VAcc) ->
                  Diff = Count / ItCount - Mean,
                  VAcc + Diff * Diff
          end, 0, SortedStates),
    io:format("~w state listed.~n"
              "  hit/it mean: ~w~n"
              "  hit/it variance: ~w~n",
              [TabCount, Mean, Variance]);
main(Args) ->
    io:format(standard_error, "Badarg: ~p~n", [Args]).
