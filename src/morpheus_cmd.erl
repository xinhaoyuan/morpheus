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
          fun ({{iteration_info, It}, Info}, Acc) ->
                  [{It, Info} | Acc];
              %% Compatibility ...
              ({{iteration_seed, It}, Info}, Acc) ->
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
    Data = aggregate_states_acc_files(AccFilenames),
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
main(["aggregate-po-filter" | Args]) ->
    {Filenames, _Filter} = split_filenames_and_filter(Args),
    Data = aggregate_po_acc_files(Filenames),
    %% Result = filter_aggregated_po(Data, Filter),
    %% maps:fold(
    %%   fun (PO, Info, _) ->
    %%           io:format("Info: ~w~n  ~p~n", [Info, PO]),
    %%           undefined
    %%   end, undefined, Result),
    case ets:lookup(Data, po_coverage_counter) of
        [{_, Counter}] ->
            io:format("po coverage: ~p~n", [Counter])
    end,
    ok;
main(["visualize-path-info" | AccFilenames]) ->
    {Data, AccTabList} = aggregate_path_info(AccFilenames),
    io:format("digraph G {~n", []),
    Stat =
        dict:fold(
          fun ({covered_by, Node}, CoveredList, #{node_counter := NC} = Acc) ->
                  RacingFlags =
                      lists:foldr(
                        fun ({Index, TabNode}, IAcc) ->
                                case [] =/= ets:lookup(lists:nth(Index, AccTabList), {racing_path_flag, TabNode}) of
                                    true ->
                                        [Index | IAcc];
                                    false ->
                                        IAcc
                                end
                        end, [], CoveredList),
                  ExtraStyles =
                      case length(RacingFlags) of
                          1 ->
                              "style = filled, color = red";
                          _ ->
                              case length(CoveredList) =:= 1 of
                                  true ->
                                      "style = filled, color = yellow";
                                  false when RacingFlags =:= [] ->
                                      "";
                                  false ->
                                      "style = filled, color = green"
                              end
                      end,
                  io:format("  ~w [ shape = box, label = <Racing: ~w<br/>Covered: ~w>, ~s]~n",
                            [ Node
                            , RacingFlags
                            , [ {II, case ets:lookup(lists:nth(II, AccTabList), {path_hit_counter, IN}) of [{_, HC}] -> HC end} || {II, IN} <- CoveredList]
                            , ExtraStyles
                            ]),
                  Acc#{node_counter := NC + 1};
              ({branch, From, Info}, To, #{edge_counter := EC} = Acc) ->
                  Label = lists:foldr(
                            fun ($", S) ->
                                    [$\\, $" | S];
                                ($\n, S) ->
                                    [$\\, $l | S];
                                (C, S) ->
                                    [C | S]
                            end, [], lists:flatten(io_lib:fwrite("~p", [Info]))),
                  io:format(" ~w -> ~w [label=\"~s\"];~n", [From, To, Label]),
                  Acc#{edge_counter := EC + 1};
              (_, _, Acc) ->
                  Acc
          end, #{node_counter => 1, edge_counter => 1}, Data),
    io:format("}~n"
              "/* nodes: ~w */~n"
              "/* edges: ~w */~n",
              [maps:get(node_counter, Stat), maps:get(edge_counter, Stat)]),
    ok;
main(Args) ->
    io:format(standard_error, "Badarg: ~p~n", [Args]).

aggregate_path_info(AccFilenames) ->
    aggregate_path_info(AccFilenames, 1, {dict:from_list([{root, 0}, {node_counter, 1}, {{path_rev, 0}, []}]), []}).

aggregate_path_info([], _, {Data, AccTabs}) ->
    {Data, lists:reverse(AccTabs)};
aggregate_path_info([AccFilename | Other], Index, {Data, AccTabs}) ->
    {ok, AccTab} = ets:file2tab(AccFilename, [{verify, true}]),
    [{path_root, Root}] = ets:lookup(AccTab, path_root),
    {ok, DataRoot} = dict:find(root, Data),
    NewData = aggregate_path_info([{Root, DataRoot}], Index, AccTab, Data),
    aggregate_path_info(Other, Index + 1, {NewData, [AccTab | AccTabs]}).

aggregate_path_info([], _Index, _AccTab, Data) -> Data;
aggregate_path_info([{Head, DataHead} | Tail], Index, AccTab, Data) ->
    Data1 = dict:store({covered_by, DataHead},
                       case dict:find({covered_by, DataHead}, Data) of
                           error -> [{Index, Head}];
                           {ok, OldCoveredBy} -> [{Index, Head} | OldCoveredBy]
                       end,
                       Data),
    PathRev = dict:fetch({path_rev, DataHead}, Data),
    {NewData, NewStack} =
        lists:foldl(
          fun ([Info, To], {CurData, CurStack}) ->
                  case dict:find({branch, DataHead, Info}, CurData) of
                      {ok, ToData} ->
                          {CurData, [{To, ToData} | CurStack]};
                      error ->
                          {ok, ToData} = dict:find(node_counter, CurData),
                          CurData1 = dict:store(node_counter, ToData + 1, CurData),
                          CurData2 = dict:store({branch, DataHead, Info}, ToData, CurData1),
                          CurData3 = dict:store({path_rev, ToData}, [Info | PathRev], CurData2),
                          {CurData3, [{To, ToData} | CurStack]}
                  end
          end, {Data1, Tail}, ets:match(AccTab, {{path_branch, Head, '$1'}, '$2'})),
    aggregate_path_info(NewStack, Index, AccTab, NewData).

%% traverse_path_info(Root, AccTab) ->
%%     traverse_path_info([Root], {[], []}, AccTab).

%% traverse_path_info([], Acc, _) -> Acc;
%% traverse_path_info([Head | Tail], {Nodes, Edges}, AccTab) ->
%%     ThisNode =
%%         #{ id => Head
%%          , racing_flag => [] =/= ets:lookup(AccTab, {racing_path_flag, Head})
%%          },
%%     {NewStack, NewEdges} =
%%         lists:foldl(
%%           fun ([Info, To], {CurStack, CurEdges}) ->
%%                   {[To | CurStack], [{Head, To, Info} | CurEdges]}
%%           end, {Tail, Edges}, ets:match(AccTab, {{Head, '$1'}, '$2'})),
%%     traverse_path_info(NewStack, {[ThisNode | Nodes], NewEdges}, AccTab).

aggregate_states_acc_files(Filenames) ->
    aggregate_states_acc_files(Filenames, {1, #{}}).

aggregate_states_acc_files([], {_, Result}) ->
    Result;
aggregate_states_acc_files([Filename | Others], {Index, Result}) ->
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
    aggregate_states_acc_files(Others, {Index + 1, NewResult}).

%% aggregate_po_acc_files(Filenames) ->
%%     aggregate_po_acc_files(Filenames, {1, #{}}).

%% aggregate_po_acc_files([], {_Index, Result}) ->
%%     Result;
%% aggregate_po_acc_files([Filename | Others], {Index, Acc}) ->
%%     {ok, AccTab} = ets:file2tab(Filename, [{verify, true}]),
%%     Acc1 =
%%         ets:foldl(
%%           fun ({{po_trace, PO}, _ItList}, Cur) ->
%%                   Old = maps:get(PO, Cur, []),
%%                   Cur#{PO => [Index | Old]};
%%               (_, Cur) ->
%%                   Cur
%%           end, Acc, AccTab),
%%     aggregate_po_acc_files(Others, {Index + 1, Acc1}).

aggregate_po_acc_files(Filenames) ->
    R = ets:new(aggregate_tab, []),
    ets:insert(R, {po_node_counter, 1}),
    ets:insert(R, {{po_node_info, 1}, 0, []}),
    ets:insert(R, {po_coverage_counter, 0}),
    aggregate_po_acc_files(Filenames, 1, R),
    R.

aggregate_po_acc_files([], _, _) ->
    ok;
aggregate_po_acc_files([F | R], _Index, none) ->
    {ok, Tab} = ets:file2tab(F, [{verify, true}]),
    aggregate_po_acc_files(R, _Index + 1, Tab);
aggregate_po_acc_files([F | R], _Index, Agg) ->
    {ok, Tab} = ets:file2tab(F, [{verify, true}]),
    merge_from_po_node(Tab, [], [[root]], [], Agg, false),
    aggregate_po_acc_files(R, _Index + 1, Agg).

merge_from_po_node(_, [], [[]], [], _, _) ->
    ok;
merge_from_po_node(Tab, [_ | PathT] = _Path, [[] | R] = _BranchStack, [_ | AggPathT] = _AggPath, Agg, _IsNew) ->
    %% io:format(user, "??? ~p ~p ~p~n", [_Path, _BranchStack, _AggPath]),
    merge_from_po_node(Tab, PathT, R, AggPathT, Agg, false);
merge_from_po_node(Tab, Path, [[H | T] | R] = _BranchStack, AggPath, Agg, _IsNew) ->
    %% io:format(user, "??? ~p ~p ~p~n", [Path, _BranchStack, AggPath]),
    NewPath =
        case H of
            root -> [1];
            _ ->
                [PathH | _] = Path,
                case ets:lookup(Tab, {po_node_branch, PathH, H}) of
                    [{_, _Next}] ->
                        [_Next | Path]
                end
        end,
    {NewAggPath, IsNew1} =
        case H of
            root -> {[1], false};
            _ ->
                [AggPathH | _] = AggPath,
                case ets:lookup(Agg, {po_node_branch, AggPathH, H}) of
                    [] ->
                        NewNode = ets:update_counter(Agg, po_node_counter, 1),
                        case ets:lookup(Agg, {po_node_info, AggPathH}) of
                            [{_, _, AggBranches}] ->
                                ets:update_element(Agg, {po_node_info, AggPathH}, {3, [H | AggBranches]})
                        end,
                        ets:insert(Agg, {{po_node_branch, AggPathH, H}, NewNode}),
                        ets:insert(Agg, {{po_node_info, NewNode}, 0, [H]}),
                        {[NewNode | AggPath], true};
                    [{_, _NextAgg}] ->
                        {[_NextAgg | AggPath], false}
                end
        end,
    [NewAggPathH | _] = NewAggPath,
    [NewPathH | _] = NewPath,
    %% io:format(user, "??? ~p ~p~n", [NewAggPath, NewPath]),
    case ets:lookup(Tab, {po_node_info, NewPathH}) of
        [{_, HitCount, Branches}] ->
            case HitCount > 0 of
                true ->
                    case ets:update_counter(Agg, {po_node_info, NewAggPathH}, {2, HitCount}) of
                        HitCount ->
                            ets:update_counter(Agg, po_coverage_counter, 1);
                        _ ->
                            ok
                    end;
                false ->
                    ok
            end,
            merge_from_po_node(Tab, NewPath, [Branches, T | R], NewAggPath, Agg, IsNew1)
    end.

split_filenames_and_filter(Args) ->
    split_filenames_and_filter(Args, {[], sets:new()}).

split_filenames_and_filter([], {FilenamesRev, Filter}) ->
    {lists:reverse(FilenamesRev), sets:to_list(Filter)};
split_filenames_and_filter([[$+ | IndexStr] = FilterItem | Tail], {FilenamesRev, Filter}) ->
    Index = list_to_integer(IndexStr),
    case sets:is_element({exc, Index}, Filter) of
        false ->
            split_filenames_and_filter(Tail, {FilenamesRev, sets:add_element({inc, Index}, Filter)});
        true ->
            %% Conflict
            io:format("Ignore filter ~s due to conflict~n", [FilterItem]),
            split_filenames_and_filter(Tail, {FilenamesRev, Filter})
    end;
split_filenames_and_filter([[$- | IndexStr] = FilterItem | Tail], {FilenamesRev, Filter}) ->
    Index = list_to_integer(IndexStr),
    case sets:is_element({inc, Index}, Filter) of
        false ->
            split_filenames_and_filter(Tail, {FilenamesRev, sets:add_element({exc, Index}, Filter)});
        true ->
            %% Conflict
            io:format("Ignore filter ~s due to conflict~n", [FilterItem]),
            split_filenames_and_filter(Tail, {FilenamesRev, Filter})
    end;
split_filenames_and_filter([Filename | Tail], {FilenamesRev, Filter}) ->
    split_filenames_and_filter(Tail, {[Filename | FilenamesRev], Filter}).

%% filter_aggregated_po(Data, Filter) ->
%%     maps:fold(
%%       fun (PO, Info, Acc) ->
%%               Match = lists:foldl(
%%                         fun (_, false) ->
%%                                 false;
%%                             ({inc, Index}, true) ->
%%                                 lists:member(Index, Info);
%%                             ({exc, Index}, true) ->
%%                                 not lists:member(Index, Info)
%%                         end, true, Filter),
%%               case Match of
%%                   true ->
%%                       Acc#{PO => Info};
%%                   false ->
%%                       Acc
%%               end
%%       end, #{}, Data).
