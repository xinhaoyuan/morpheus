-module(morpheus_tracer).

-behaviour(gen_server).

%% API.
-export([ start_link/1
        , trace_call/4
        , trace_new_process/5
        , trace_send/7
        , trace_receive/5
        , trace_report_state/3
        , finalize/3
        , create_ets_tab/0
        , create_acc_ets_tab/0
        , open_or_create_acc_ets_tab/1
        , calc_acc_fanout/1
        ]).

-export([ simplify/2 ]).

%% gen_server.
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3]).

-record(state, { tab                     :: ets:tid()
               , acc_filename            :: string()
               , acc_fork_period         :: integer()
               , dump_traces             :: boolean()
               , dump_traces_verbose     :: boolean()
               , dump_po_traces          :: new | all | false
               , find_races              :: boolean()
               , simplify_po_trace       :: boolean()
               , po_coverage             :: boolean()
               , path_coverage           :: boolean()
               , line_coverage           :: boolean()
               , state_coverage          :: boolean()
               , extra_handlers          :: [module()]
               }).

-include("morpheus_trace.hrl").

-define(H, morpheus_helper).

%% API.

-spec start_link(term()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

trace_call(T, From, Where, Req) ->
    gen_server:cast(T, {call, From, Where, Req}).

trace_new_process(T, Proc, AbsId, Creator, EntryInfo) ->
    gen_server:cast(T, {new_process, Proc, AbsId, Creator, EntryInfo}).

trace_send(T, Where, From, To, Type, Content, Effect) ->
    gen_server:cast(T, {send, Where, From, To, Type, Content, Effect}).

trace_receive(T, Where, To, Type, Content) ->
    gen_server:cast(T, {recv, Where, To, Type, Content}).

trace_report_state(T, TraceInfo, State) ->
    gen_server:cast(T, {report_state, TraceInfo, State}).

finalize(T, TraceInfo, SHT) ->
    gen_server:call(T, {finalize, TraceInfo, SHT}, infinity).

create_ets_tab() ->
    Tab = ets:new(trace_tab, [ordered_set, public, {write_concurrency, true}]),
    ets:insert(Tab, {trace_counter, 0}),
    Tab.

create_acc_ets_tab() ->
    Tab = ets:new(acc_tab, []),
    ets:insert(Tab, {iteration_counter, 0}),
    ets:insert(Tab, {root, 1}),
    ets:insert(Tab, {node_counter, 1}),
    ets:insert(Tab, {po_coverage_counter, 0}),
    ets:insert(Tab, {path_coverage_counter, 0}),
    ets:insert(Tab, {line_coverage_counter, 0}),
    ets:insert(Tab, {state_coverage_counter, 0}),
    Tab.

open_or_create_acc_ets_tab(Filename) ->
    morpheus_helper:open_or_create_ets(
      Filename,
      fun (_Reason) ->
              create_acc_ets_tab()
      end).

%% ==== Partial Order Analysis ====

%% RET[k] := undefined (k not in VC1 /\ k not in VC2)
%%        |  VC1[k]    (k in VC1     /\ k not in VC2)
%%        |  VC2[k]    (k not in VC1 /\ k in VC2)
%%        |  max(VC1[k], VC2[k])
merge_vc(VC1, VC2) ->
    maps:fold(
      fun (K, V, Acc) ->
              Acc#{K => max(V, maps:get(K, VC2, 0))}
      end, VC2, VC1).

analyze_partial_order(#state{find_races = FindRaces, simplify_po_trace = SimplifyPOTrace} = _State, Tab, SimpMap) ->
    %% Reconstruct the trace according to vector clocks.
    %% And detect racing operations.
    %% Traces with the same reconstructed vector clocks are po-equivalent.
    %% Thus we can count how many partial orders has been covered.
    %%
    %% For now, we only consider creation, recv, and send operations.
    %% To rebuild recv-send dependency, we need to rebuild the message history for each process.
    %%
    %% XXX I am not sure how to deal with ETS yet. Probably I would treat each ETS table as a process.
    #{proc_operation_map := POMReversed, races := Races, aux_serialization := AuxSerialization} =
        ets:foldl(
          fun (?TraceNewProcess(_, ProcX, _AbsId, CreatorX, _EntryInfo),
               #{local_vc_map := LVC, inbox_vc_map := IBM, message_queue_map := MQM, message_history_map := MHM, proc_operation_map := POM} = ProcState) ->
                  %% When a new process is created the created process inherit the creator's VC.
                  Proc = simplify(ProcX, SimpMap), Creator = simplify(CreatorX, SimpMap),
                  %% The creator could be initial, which has no record in state
                  VC = (maps:get(Creator, LVC, #{})),
                  ProcState#{ local_vc_map := LVC#{Proc => VC}
                            , inbox_vc_map := IBM#{Proc => VC}
                            , message_queue_map := MQM#{Proc => #{}}
                            , message_history_map := MHM#{Proc => []}
                            , proc_operation_map := POM#{Proc => []}
                            };

              (?TraceRecv(_Id, _Where, ToX, message, Content),
               #{local_vc_map := LVC, message_queue_map := MQM} = ProcState) ->
                  %% Receive of the message needs to happens after the sending operation
                  %% Note that for now only message receive is in scope, others (e.g. signals, timeouts) are ignored for now.
                  To = simplify(ToX, SimpMap),
                  #{To := VC} = LVC,
                  #{To := MQ} = MQM,
                  #{Content := Q} = MQ,
                  {{value, MsgVC}, H1} = queue:out(Q),
                  VC1 = merge_vc(VC, MsgVC),
                  %% GVC is not changing for the same reason as creation
                  ProcState#{ local_vc_map := LVC#{To := VC1}
                            , message_queue_map := MQM#{To := MQ#{Content := H1}}
                            };

              (?TraceSend(TID, _Where, FromX, ToX, _Type, Content, _Effect),
               #{ local_vc_map := LVC
                , inbox_vc_map := IBM
                , message_queue_map := MQM
                , message_history_map := MHM
                , aux_serialization := AuxSerialization
                , proc_operation_map := POM
                , races := Races} = ProcState) ->
                  %% Sending message to a process will make it happen after all sending of existing messages, which is in inbox_vc_map
                  case is_pid(FromX) of
                      true ->
                          From = simplify(FromX, SimpMap), To = simplify(ToX, SimpMap),
                          #{From := VC} = LVC,
                          Step = maps:get(From, VC, 0),
                          #{From := PO} = POM,
                          #{To := IVC} = IBM,
                          #{To := MQ} = MQM,
                          #{To := MH} = MHM,
                          VC1 = merge_vc(IVC, VC),
                          VC2 = VC1#{From => Step + 1},
                          RacingOps =
                              case FindRaces of
                                  true ->
                                      lists:foldl(
                                        fun ({SenderProc, SenderIdx, SenderTID}, Acc) ->
                                                %% Check if the current send can happens before each message in the queue
                                                HappensAfter = maps:get(SenderProc, VC, 0),
                                                case SenderIdx >= HappensAfter of
                                                    true ->
                                                        [SenderTID | Acc];
                                                    false ->
                                                        Acc
                                                end
                                        end, [], MH);
                                  false ->
                                      []
                              end,
                          Q = queue:in(VC2, maps:get(Content, MQ, queue:new())),
                          ProcState#{ local_vc_map := LVC#{From := VC2}
                                    , inbox_vc_map := IBM#{To := VC2}
                                    , message_queue_map := MQM#{To := MQ#{Content => Q}}
                                    , message_history_map := MHM#{To := [{From, Step, TID} | MH]}
                                    , aux_serialization := [From | AuxSerialization]
                                    , proc_operation_map := POM#{From => [{VC1, {To, Content}} | PO]}
                                    , races :=
                                          case RacingOps of
                                              [] ->
                                                  Races;
                                              _ ->
                                                  [{TID, RacingOps} | Races]
                                          end
                                    };
                      false ->
                          %% XXX I do not know how to handle undet message yet ...
                          %% This is probably wrong, but I will assign a empty clock for now.
                          To = simplify(ToX, SimpMap),
                          #{To := IVC} = IBM,
                          #{To := MQ} = MQM,
                          VC1 = IVC,
                          Q = queue:in(VC1, maps:get(Content, MQ, queue:new())),
                          ProcState#{ inbox_vc_map := IBM#{To := VC1}
                                    , message_queue_map := MQM#{To := MQ#{Content => Q}}
                                    }
                  end;

              (_, ProcState) ->
                  ProcState
          end,
          #{ local_vc_map => #{}
           , inbox_vc_map => #{}
           , message_queue_map => #{}
           , message_history_map => #{}
           , aux_serialization => []
           , proc_operation_map => #{}
           , races => []
           },
          Tab),
    POM =
        maps:fold(
          fun (Proc, OPList, Acc) ->
                  Acc#{Proc => lists:foldl(
                                 fun ({VC, _Info}, InnerAcc) ->
                                         [VC | InnerAcc]
                                 end, [], OPList)}
          end, #{}, POMReversed),
    Ret0 = #{partial_order_map => POM},
    Ret1 =
        case FindRaces of
            false ->
                Ret0;
            true ->
                {RaceCount, RacingLocations} = refine_race_information(_State, Tab, Races),
                Ret0#{racing_locations => RacingLocations, race_count => RaceCount}
        end,
    Ret2 =
        case SimplifyPOTrace of
            true ->
                POTrace =
                    maps:fold(
                      fun (Proc, OPList, Acc) ->
                              Acc#{Proc => lists:foldl(
                                             fun ({VC, {To, Content}}, InnerAcc) ->
                                                     [{VC, {To, simplify(Content, SimpMap)}} | InnerAcc]
                                             end, [], OPList)}
                      end, #{}, POMReversed),
                Ret1#{simplified_po_trace => simplify_po_trace(POTrace, lists:reverse(AuxSerialization))};
            false ->
                Ret1
        end,
    {ok, Ret2}.

simplify_po_trace(POTrace, AuxSerialization) ->
    {_, InitialInfo} =
        lists:foldl(
          fun (Actor, {Index, Acc}) ->
                  {Index + 1, Acc#{Actor => {Index, 1}}}
          end, {0, #{}}, lists:usort(AuxSerialization)),

    simplify_po_trace(InitialInfo, POTrace, AuxSerialization, []).

simplify_po_trace(_, _, [], Rev) ->
    lists:reverse(Rev);
simplify_po_trace(Info, POTrace, [From | RestSerialization] = _AuxSerialization, Rev) ->
    #{From := {FromI, Counter}} = Info,
    #{From := [{VC, {To, Content}} | Rest]} = POTrace,
    #{To := {ToI, _}} = Info,
    Height = maps:fold(
               fun (Actor, Index, AccHeight) ->
                       #{Actor := {ActorI, _}} = Info,
                       CurHeight = maps:get({ActorI, Index}, Info),
                       max(CurHeight, AccHeight)
               end, 0, VC) + 1,
    simplify_po_trace(Info#{{FromI, Counter} => Height, From := {FromI, Counter + 1}},
                       POTrace#{From := Rest},
                       RestSerialization,
                       [{FromI, Height, ToI, Content} | Rev]).


merge_po_coverage(#state{dump_po_traces = Dump} = State, Tab, IC, AccTab, #{partial_order_map := POM, simp_map := SimpMap} = FinalData) ->
    %% Thus we can count how many partial orders has been covered.
    case ets:insert_new(AccTab, {{po_trace, POM}, [IC]}) of
        true ->
            case Dump of
                _ when Dump =:= new; Dump =:= all ->
                    io:format(user, "New po trace ~p~n", [maps:get(simplified_po_trace, FinalData, POM)]),
                    dump_trace(State, Tab, SimpMap);
                _ ->
                    ok
            end,
            ets:update_counter(AccTab, po_coverage_counter, 1);
        false ->
            case Dump of
                all ->
                    io:format(user, "po trace ~p~n", [POM]),
                    dump_trace(State, Tab, SimpMap);
                _ ->
                    ok
            end,
            case ets:lookup(AccTab, {po_trace, POM}) of
                [{_, ItList}] ->
                    ets:update_element(AccTab, {po_trace, POM}, [{2, [IC | ItList]}])
            end
    end,
    ok.

refine_race_information(_, Tab, Races) ->
    {NRaces, TIDs} =
        lists:foldl(
          fun ({X, YList}, {N, S}) ->
                  {N + length(YList),
                   lists:foldl(
                     fun (Y, Acc) ->
                             sets:add_element(Y, Acc)
                     end,
                     sets:add_element(X, S),
                     YList)}
          end, {0, sets:new()}, Races),
    Locations =
        ets:foldl(
          fun (?TraceSend(TID, Where, _, _, _, _, _), Acc) ->
                  case sets:is_element(TID, TIDs) of
                      true ->
                          sets:add_element(Where, Acc);
                      false ->
                          Acc
                  end;

              (_, Acc) ->
                  Acc
          end, sets:new(), Tab),
    {NRaces, sets:to_list(Locations)}.

%% ==== Path Coverage ====

%% Merge per-actor path.
merge_path_coverage(Tab, AccTab, SimpMap) ->
    ProcState =
        ets:foldl(
          fun (?TraceNewProcess(_, Proc, _AbsId, _Creator, EntryInfo), ProcState) ->
                  [{root, Root}] = ets:lookup(AccTab, root),
                  Branch = {new, simplify(Proc, SimpMap), simplify(EntryInfo, SimpMap)},
                  case ets:lookup(AccTab, {Root, Branch}) of
                      [] ->
                          AvailableBranch = ets:match(AccTab, {{Root, '$1'}, '_'}),
                          io:format(user,
                                    "New branch ~p at ~p~n"
                                    "  available: ~p~n",
                                    [Branch, Root, AvailableBranch]),
                          NewNode = ets:update_counter(AccTab, node_counter, 1),
                          ets:insert(AccTab, {{Root, Branch}, NewNode}),
                          ProcState#{Proc => {NewNode, true}};
                      [{_, Next}] ->
                          ProcState#{Proc => {Next, false}}
                  end;
              (?TraceSend(_, Where, From, To, Type, Content, _Effect), ProcState) ->
                  case maps:is_key(From, ProcState) of
                      true ->
                          #{From := {StateNode, _}} = ProcState,
                          SimpContent = simplify(Content, SimpMap),
                          Branch = {send, Where, simplify(To, SimpMap), Type, SimpContent},
                          case ets:lookup(AccTab, {StateNode, Branch}) of
                              [] ->
                                  AvailableBranch = ets:match(AccTab, {{StateNode, '$1'}, '_'}),
                                  io:format(user,
                                            "New branch ~p at ~p~n"
                                            "  available: ~p~n",
                                            [Branch, StateNode, AvailableBranch]),
                                  NewNode = ets:update_counter(AccTab, node_counter, 1),
                                  ets:insert(AccTab, {{StateNode, Branch}, NewNode}),
                                  ProcState#{From := {NewNode, true}};
                              [{_, Next}] ->
                                  ProcState#{From := {Next, false}}
                          end;
                      false ->
                          ProcState
                  end;
              (?TraceRecv(_, Where, To, Type, Content), ProcState) ->
                  case maps:is_key(To, ProcState) of
                      true ->
                          #{To := {StateNode, _}} = ProcState,
                          SimpContent = simplify(Content, SimpMap),
                          Branch = {recv, Where, Type, SimpContent},
                          case ets:lookup(AccTab, {StateNode, Branch}) of
                              [] ->
                                  %% AvailableBranch = ets:match(AccTab, {{StateNode, '$1'}, '_'}),
                                  %% io:format(user,
                                  %%           "New branch ~p at ~p~n"
                                  %%           "  available: ~p~n",
                                  %%           [Branch, StateNode, AvailableBranch]),
                                  NewNode = ets:update_counter(AccTab, node_counter, 1),
                                  ets:insert(AccTab, {{StateNode, Branch}, NewNode}),
                                  ProcState#{To := {NewNode, true}};
                              [{_, Next}] ->
                                  ProcState#{To := {Next, false}}
                          end;
                      false ->
                          ProcState
                  end;
              (_, Acc) ->
                  Acc
          end, #{}, Tab),
    NewPathCount = maps:fold(
                 fun (_, {_, true}, Acc) ->
                         Acc + 1;
                     (_, {_, false}, Acc) ->
                         Acc
                 end, 0, ProcState),
    ets:update_counter(AccTab, path_coverage_counter, NewPathCount),
    ok.

%% Merge line coverage (approximately).
merge_line_coverage(Tab, AccTab) ->
    ets:foldl(
      fun (?TraceCall(_, _From, Where, _Req), Acc) ->
              case ets:insert_new(AccTab, {{line_coverage, Where}, 1}) of
                  true ->
                      ets:update_counter(AccTab, line_coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {line_coverage, Where}, 1)
              end,
              Acc;
          (?TraceSend(_, Where, _From, _To, _Type, _Content, _Effect), Acc) ->
              case ets:insert_new(AccTab, {{line_coverage, Where}, 1}) of
                  true ->
                      ets:update_counter(AccTab, line_coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {line_coverage, Where}, 1)
              end,
              Acc;
          (?TraceRecv(_, Where, _To, _Type, _Content), Acc) ->
              case ets:insert_new(AccTab, {{line_coverage, Where}, 1}) of
                  true ->
                      ets:update_counter(AccTab, line_coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {line_coverage, Where}, 1)
              end,
              Acc;
          (_, Acc) ->
              Acc
      end, undefined, Tab).

%% ==== State Coverage ====

merge_state_coverage(Tab, IterationId, AccTab, #{simp_map := SimpMap}) ->
    ets:foldl(
      fun (?TraceReportState(_, Depth, RState), Acc) ->
              SimpState = simplify(RState, SimpMap),
              case ets:insert_new(AccTab, {{state_coverage, SimpState}, 1, 1, [{IterationId, Depth}]}) of
                  true ->
                      ets:update_counter(AccTab, state_coverage_counter, 1),
                      Acc#{SimpState => true};
                  false ->
                      ets:update_counter(AccTab, {state_coverage, SimpState}, {2, 1}),
                      case maps:is_key(SimpState, Acc) of
                          false ->
                              case ets:lookup(AccTab, {state_coverage, SimpState}) of
                                  [{_, _, ItCount, ItList}] ->
                                      ets:update_element(AccTab, {state_coverage, SimpState},
                                                         [{3, ItCount + 1}, {4, [{IterationId, Depth} | ItList]}])
                              end,
                              Acc#{SimpState => true};
                          true ->
                              Acc
                      end
              end;
          (_, Acc) ->
              Acc
      end, #{}, Tab).

%% ==== Trace Dump ====

dump_trace(#state{dump_traces_verbose = Verbose} = _State, Tab, SimpMap) ->
    case Verbose of
        false ->
            TraceRev =
                ets:foldl(
                  fun (?TraceSend(_, _Where, FromX, ToX, _Type, ContentX, _Effect), Acc) ->
                          From = simplify(FromX, SimpMap),
                          To = simplify(ToX, SimpMap),
                          Content = simplify(ContentX, SimpMap),
                          [ {send, From, To, Content} | Acc ];
                      (?TraceRecv(_, _Where, ToX, _Type, ContentX), Acc) ->
                          To = simplify(ToX, SimpMap),
                          Content = simplify(ContentX, SimpMap),
                          [ {recv, To, Content} | Acc];
                      (_, Acc) ->
                          Acc
                  end, [], Tab),
            io:format(user,
                      "Trace: ~p~n",
                      [lists:reverse(TraceRev)]);

        true ->
            io:format(user,
                      "Verbose trace: ~p~n",
                      [ets:match(Tab, '$1')])
    end,
    ok.

%% ========

extract_simplify_map(SHT) ->
    ets:foldl(
      fun ({{proc_abs_id, Proc}, Id}, Acc) ->
              Acc#{Proc => Id};
          ({{ref_abs_id, Ref}, Id}, Acc) ->
              Acc#{Ref => Id};
          (_, Acc) ->
              Acc
      end, #{}, SHT).

simplify(D, undefined) ->
    D;
simplify([H | T], SimpMap) ->
    [simplify(H, SimpMap) | simplify(T, SimpMap)];
simplify(Data, SimpMap) when is_tuple(Data) ->
    %% The magic size is from experiments on OTP-20
    case size(Data) > 0 andalso element(1, Data) of
        dict when size(Data) =:= 9 ->
            {dict, simplify(dict:to_list(Data), SimpMap)};
        set when size(Data) =:= 9 ->
            {set, simplify(sets:to_list(Data), SimpMap)};
        _ ->
            list_to_tuple(simplify(tuple_to_list(Data), SimpMap))
    end;
simplify(Data, SimpMap) when is_map(Data) ->
    maps:fold(
      fun (K, V, Acc) ->
              Acc#{simplify(K, SimpMap) => simplify(V, SimpMap)}
      end, #{}, Data);
simplify(Data, SimpMap) when is_pid(Data) ->
    maps:get(Data, SimpMap, Data);
simplify(Data, SimpMap) when is_reference(Data) ->
    case maps:get(Data, SimpMap, undefined) of
        {Pid, CreationCount} ->
            {simplify(Pid, SimpMap), CreationCount};
        undefined ->
            Data
    end;
simplify(Data, _SimpMap) when is_function(Data) ->
    %% Function? Ignore for now...
    {function};
simplify(Data, _SimpMap) ->
    Data.

%% For a accumulated table, calculate the path tree fanout function
%%   f(d) := how many path node are at the depth d
%% Returns {MaxDepth, f}, where f has key from [0, MaxDepth]
calc_acc_fanout(AccTab) ->
    [{root, Root}] = ets:lookup(AccTab, root),
    ChildrenMap =
        ets:foldl(
          fun ({{From, _}, To}, Acc) when is_integer(From), is_integer(To) ->
                  Acc#{From => [To | maps:get(From, Acc, [])]};
              %% Dirty hack for Acc in the last version ...
              ({{{root, From}, _}, To}, Acc) when is_integer(From), is_integer(To) ->
                  Acc#{From => [To | maps:get(From, Acc, [])]};
              (_, Acc) ->
                  Acc
          end, #{}, AccTab),
    calc_acc_fanout(ChildrenMap, [], Root, {0, 0, #{}}).

calc_acc_fanout(_, [], backtrack, {MaxDepth, _, Result}) ->
    {MaxDepth, Result};
calc_acc_fanout(ChildrenMap, [[] | RestFrames], backtrack, {MaxDepth, Depth, Result}) ->
    calc_acc_fanout(ChildrenMap, RestFrames, backtrack, {MaxDepth, Depth - 1, Result});
calc_acc_fanout(ChildrenMap, [[Next | Others] | RestFrames], backtrack, {MaxDepth, Depth, Result}) ->
    calc_acc_fanout(ChildrenMap, [Others | RestFrames], Next, {MaxDepth, Depth + 1, Result});
calc_acc_fanout(ChildrenMap, Stack, Node, {MaxDepth, Depth, Result}) ->
    NewResult = Result#{Depth => maps:get(Depth, Result, 0) + 1},
    Children = maps:get(Node, ChildrenMap, []),
    calc_acc_fanout(ChildrenMap, [Children | Stack], backtrack, {max(MaxDepth, Depth), Depth, NewResult}).

%% gen_server.

init(Args) ->
    Tab =
        case proplists:get_value(tab, Args) of
            undefined ->
                create_ets_tab();
            _T ->
                _T
        end,
    AccFilename = proplists:get_value(acc_filename, Args, undefined),
    AccForkPeriod = proplists:get_value(acc_fork_period, Args, 0),
    DumpTraces = proplists:get_value(dump_traces, Args, false),
    DumpTracesVerbose = proplists:get_value(dump_traces_verbose, Args, false),
    DumpPOTraces = proplists:get_value(dump_po_traces, Args, false),
    FindRaces = proplists:get_value(find_races, Args, false),
    SimplifyPOTrace = proplists:get_value(simplify_po_trace, Args, false),
    POCoverage = proplists:get_value(po_coverage, Args, false),
    PathCoverage = proplists:get_value(path_coverage, Args, false),
    LineCoverage = proplists:get_value(line_coverage, Args, false),
    StateCoverage = proplists:get_value(state_coverage, Args, false),
    ExtraHandlers = proplists:get_value(extra_handlers, Args, []),
    State = #state{ tab = Tab
                  , acc_filename = AccFilename
                  , acc_fork_period = AccForkPeriod
                  , dump_traces = DumpTraces
                  , dump_traces_verbose = DumpTracesVerbose
                  , dump_po_traces = DumpPOTraces
                  , find_races = FindRaces
                  , simplify_po_trace = SimplifyPOTrace
                  , po_coverage = POCoverage
                  , path_coverage = PathCoverage
                  , line_coverage = LineCoverage
                  , state_coverage = StateCoverage
                  , extra_handlers = ExtraHandlers
                  },
    {ok, State}.

handle_call({finalize, TraceInfo, SHT},
            _From,
            #state{ tab = Tab
                  , acc_filename = AF
                  , acc_fork_period = AFP
                  , po_coverage = POC
                  , path_coverage = PC
                  , line_coverage = LC
                  , state_coverage = SC
                  , extra_handlers = ExtraHandlers
                  }
            = State)
  when Tab =/= undefined, AF =/= undefined ->
    AccTab = open_or_create_acc_ets_tab(AF),
    IC = ets:update_counter(AccTab, iteration_counter, 1),
    ets:insert(AccTab, {{iteration_info, IC}, TraceInfo}),
    R0 = #{simp_map => extract_simplify_map(SHT)},
    R1 = maybe_extract_partial_order_info(State, Tab, R0),
    maybe_dump_trace(State, Tab, R1),
    case POC of
        true ->
            merge_po_coverage(State, Tab, IC, AccTab, R1),
            [{po_coverage_counter, POCoverageCount}] = ets:lookup(AccTab, po_coverage_counter),
            io:format(user, "po coverage count = ~p~n", [POCoverageCount]);
        false ->
            ok
    end,
    case PC of
        true ->
            merge_path_coverage(Tab, AccTab, R1),
            [{path_coverage_counter, PathCoverageCount}] = ets:lookup(AccTab, path_coverage_counter),
            io:format(user, "path coverage count = ~p~n", [PathCoverageCount]);
        false ->
            ok
    end,
    case LC of
        true ->
            merge_line_coverage(Tab, AccTab),
            [{line_coverage_counter, LineCoverageCount}] = ets:lookup(AccTab, line_coverage_counter),
            io:format(user, "line coverage count = ~p~n", [LineCoverageCount]);
        false ->
            ok
    end,
    case SC of
        true ->
            merge_state_coverage(Tab, IC, AccTab, R1),
            [{state_coverage_counter, StateCoverageCount}] = ets:lookup(AccTab, state_coverage_counter),
            io:format(user, "state coverage count = ~p~n", [StateCoverageCount]);
        false ->
            ok
    end,
    %% Use (tmp; rename) to keep atomicity
    ets:tab2file(AccTab, AF ++ ".tmp", [{extended_info, [md5sum]}]),
    case AFP > 0 andalso IC rem AFP =:= 0 of
        true ->
            os:cmd(lists:flatten(io_lib:format("cp ~s ~s", [AF ++ ".tmp", AF ++ "." ++ integer_to_list(IC)])));
        false ->
            ok
    end,
    os:cmd(lists:flatten(io_lib:format("mv ~s ~s", [AF ++ ".tmp", AF]))),
    RFinal = lists:foldl(
               fun ({HandlerMod, HandlerState}, AccR) ->
                       HandlerMod:handle_trace(HandlerState, Tab, AccR)
               end, R1, ExtraHandlers),
    {reply, RFinal, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

maybe_dump_trace(#state{dump_traces = true} = State, Tab, #{simp_map := SimpMap}) ->
    dump_trace(State, Tab, SimpMap);
maybe_dump_trace(_, _, _) ->
    ok.

maybe_extract_partial_order_info(#state{find_races = FindRaces, po_coverage = POC, simplify_po_trace = SimplifyPOTrace} = State, Tab, #{simp_map := SimpMap} = FinalData) ->
    case FindRaces or POC or SimplifyPOTrace of
        true ->
            case (catch analyze_partial_order(State, Tab, SimpMap)) of
                {ok, R} ->
                    maps:merge(R, FinalData);
                Other ->
                    io:format(user,
                              "Unexpected result from analyze_partail_order:~n"
                              "  ~p~n",
                              [Other]),
                    FinalData
            end;
        false ->
            FinalData
    end.


handle_cast({call, From, Where, Req}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceCall(TC, From, Where, Req)),
    {noreply, State};
handle_cast({new_process, Proc, AbsId, Creator, EntryInfo}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceNewProcess(TC, Proc, AbsId, Creator, EntryInfo)),
    {noreply, State};
handle_cast({send, Where, From, To, Type, Content, Effect}, #state{tab = Tab} = State) when Tab =/= undefined->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceSend(TC, Where, From, To, Type, Content, Effect)),
    {noreply, State};
handle_cast({recv, Where, To, Type, Content}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceRecv(TC, Where, To, Type, Content)),
    {noreply, State};
handle_cast({report_state, TraceInfo, RState}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceReportState(TC, TraceInfo, RState)),
    {noreply, State};
handle_cast(Msg, State) ->
    io:format(user, "Unknown trace cast ~p~n", [Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
