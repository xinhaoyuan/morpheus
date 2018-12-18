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
main(["show-iterations", AccFilename]) ->
    {ok, AccTab} = ets:file2tab(AccFilename, [{verify,true}]),
    IterationList =
        ets:foldl(
          fun ({{iteration_seed, It}, Info}, Acc) ->
                  [{It, Info} | Acc];
              (_, Acc) ->
                  Acc
          end, [], AccTab),
    lists:foreach(
      fun ({It, Info}) ->
              io:format("~w: ~p~n", [It, Info])
      end, lists:sort(IterationList));
main(["show-states", AccFilename]) ->
    {ok, AccTab} = ets:file2tab(AccFilename, [{verify,true}]),
    States =
        ets:foldl(
          fun ({{state_coverage, State}, HitCount, IterationCount, Iterations}, Acc) ->
                  [{HitCount, IterationCount, State, Iterations} | Acc];
              (_, Acc) ->
                  Acc
          end, [], AccTab),
    [{state_coverage_counter, TabCount}] = ets:lookup(AccTab, state_coverage_counter),
    [{iteration_counter, ItCount}] = ets:lookup(AccTab, iteration_counter),
    TabCount = length(States),
    SortedStates = lists:sort(States),
    {HitSum, IterationSum} =
        lists:foldr(
          fun ({HitCount, IterationCount, State, Iterations}, {HitSum, IterationSum}) ->
                  io:format("~w, ~w. Iterations = ~w~n"
                            "  ~p~n",
                            [HitCount, IterationCount, Iterations, State]),
                  {HitSum + HitCount, IterationSum + IterationCount}
          end, {0, 0}, SortedStates),
    HitMean = HitSum / ItCount / TabCount,
    IterationMean = IterationSum / ItCount / TabCount,
    {HitVariance, IterationVariance} =
        lists:foldr(
          fun ({HitCount, IterationCount, _State, _Iterations}, {HitV, IterationV}) ->
                  HitDiff = HitCount / ItCount - HitMean,
                  IterationDiff = IterationCount / ItCount - IterationMean,
                  {HitV + HitDiff * HitDiff, IterationV + IterationDiff * IterationDiff}
          end, {0, 0}, SortedStates),
    io:format("~w state listed.~n"
              "  hit/it mean: ~w~n"
              "  hit/it variance: ~w~n"
              "  cover/it mean: ~w~n"
              "  cover/it variance: ~w~n",
              [TabCount, HitMean, HitVariance, IterationMean, IterationVariance]);
main(["aggregate-states" | AccFilenames]) ->
    Data = aggregate_acc_files(AccFilenames),
    CSV = case os:getenv("CSV") of
              false -> false;
              "" -> false;
              _ -> true
          end,
    case CSV of
        true ->
            Count = length(AccFilenames),
            maps:fold(
              fun (_State, SData, _Acc) ->
                      Row =
                          tuple_to_list(
                            erlang:make_tuple(
                              Count, undefined,
                              maps:fold(
                                fun (K, {_, _, ItInfo}, Acc) ->
                                        [{K,
                                          lists:foldl(
                                            fun ({_, Depth}, MinDepth) ->
                                                    case MinDepth =:= undefined orelse MinDepth > Depth of
                                                        true ->
                                                            Depth;
                                                        false ->
                                                            MinDepth
                                                    end
                                            end, undefined, ItInfo)}
                                         | Acc]
                                end, [], SData))),
                      RowString =
                          lists:flatten(
                            lists:join(
                              ",",
                              lists:map(
                                fun (I) when is_integer(I) ->
                                        integer_to_list(I);
                                    (_) -> ""
                                end, Row))),
                      io:format("~s~n", [RowString]),
                      _Acc
              end, undefined, Data);
        false ->
            maps:fold(
              fun (_State, SData, Acc) ->
                      io:format("~w~n", [SData]),
                      Acc
              end, undefined, Data)
    end;
main(Args) ->
    io:format(standard_error, "Badarg: ~p~n", [Args]).

aggregate_acc_files(Filenames) ->
    aggregate_acc_files(Filenames, {1, #{}}).

aggregate_acc_files([], {_, Result}) ->
    Result;
aggregate_acc_files([Filename | Others], {Index, Result}) ->
    {ok, AccTab} = ets:file2tab(Filename, [{verify,true}]),
    {StateCount, NewResult} =
        ets:foldl(
          fun ({{state_coverage, State}, HitCount, IterationCount, Iterations}, {StateCount, CurResult}) ->
                  OldStatus = maps:get(State, CurResult, #{}),
                  {StateCount + 1, CurResult#{State => OldStatus#{Index => {HitCount, IterationCount, Iterations}}}};
              (_, Acc) ->
                  Acc
          end, {0, Result}, AccTab),
    [{state_coverage_counter, TabCount}] = ets:lookup(AccTab, state_coverage_counter),
    TabCount = StateCount,
    aggregate_acc_files(Others, {Index + 1, NewResult}).
