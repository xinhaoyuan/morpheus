-module(morpheus_tracer).

-behaviour(gen_server).

%% API.
-export([ start_link/1
        , trace_call/4
        , trace_new_process/5
        , trace_send/7
        , trace_receive/5
        , trace_report_state/3
        , stop/3
        , create_ets_tab/0
        , create_acc_ets_tab/0
        , open_or_create_acc_ets_tab/1
        , merge_po_coverage/2
        , merge_path_coverage/2
        , merge_line_coverage/2
        , merge_state_coverage/2
        , calc_acc_fanout/1
        ]).

%% gen_server.
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3]).

-record(state, { tab             :: ets:tid()
               , acc_filename    :: string()
               , acc_fork_period :: integer()
               , po_coverage     :: boolean()
               , path_coverage   :: boolean()
               , line_coverage   :: boolean()
               , state_coverage  :: boolean()
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

trace_report_state(T, Depth, State) ->
    gen_server:cast(T, {report_state, Depth, State}).

stop(T, SeedInfo, SHT) ->
    gen_server:call(T, {stop, SeedInfo, SHT}, infinity).

create_ets_tab() ->
    Tab = ets:new(trace_tab, [ordered_set, public, {write_concurrency, true}]),
    ets:insert(Tab, {trace_counter, 0}),
    Tab.

open_or_create_ets(Filename, CreateFun) ->
    case ets:file2tab(Filename, [{verify, true}]) of
        {ok, ETS} ->
            ETS;
        {error, Reason} ->
            CreateFun(Reason)
    end.

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
    open_or_create_ets(
      Filename,
      fun (_Reason) ->
              create_acc_ets_tab()
      end).

%% ==== Partial Order Coverage ====

merge_vc(VC1, VC2) ->
    maps:fold(
      fun (K, V, Acc) ->
              Acc#{K => max(V, maps:get(K, VC2, 0))}
      end, VC2, VC1).

merge_po_coverage(Tab, AccTab) ->
    merge_po_coverage(Tab, AccTab, undefined).

merge_po_coverage(Tab, AccTab, SimpMap) ->
    %% Reconstruct the trace according to vector clocks. Traces with the same reconstructed trace are po-equivalent.
    %% We ignore process creation and receiving for partial order trace.
    %% And for now, we only consider send operations.
    %% To rebuild recv-send dependency, we need to rebuild the message history for each process.
    %%
    %% XXX I am not sure how to deal with ETS yet. Probably I would treat each ETS table as a process.
    R = (
      catch
          begin
              #{proc_operation_map := POMReversed} =
                  ets:foldl(
                    fun (?TraceNewProcess(_, ProcX, _AbsId, CreatorX, _EntryInfo), #{local_vc_map := LVC, message_history_map := MHM, proc_operation_map := POM} = ProcState) ->
                            Proc = simplify(ProcX, SimpMap), Creator = simplify(CreatorX, SimpMap),
                            %% The creator could be initial, which has no record in state
                            VC = (maps:get(Creator, LVC, #{}))#{Proc => 0},
                            ProcState#{local_vc_map := LVC#{Proc => VC}, message_history_map := MHM#{Proc => #{}}, proc_operation_map := POM#{Proc => []}};
                        (?TraceRecv(_Id, _Where, ToX, _Type, Content), #{local_vc_map := LVC, message_history_map := MHM} = ProcState) ->
                            To = simplify(ToX, SimpMap),
                            #{To := VC} = LVC,
                            #{To := MH} = MHM,
                            #{Content := H} = MH,
                            {{value, MsgVC}, H1} = queue:out(H),
                            %% GVC is not changing for the same reason as creation
                            ProcState#{local_vc_map := LVC#{To := merge_vc(VC, MsgVC)}, message_history_map := MHM#{To := MH#{Content := H1}}};
                        (?TraceSend(_, _Where, FromX, ToX, _Type, Content, _Effect), #{local_vc_map := LVC, message_history_map := MHM, proc_operation_map := POM} = ProcState) ->
                            From = simplify(FromX, SimpMap), To = simplify(ToX, SimpMap),
                            #{From := #{From := Step} = VC} = LVC,
                            #{From := PO} = POM,
                            #{To := MH} = MHM,
                            VC1 = VC#{From := Step + 1},
                            H = queue:in(VC1, maps:get(Content, MH, queue:new())),
                            ProcState#{ local_vc_map := LVC#{From := VC1}
                                      , message_history_map := MHM#{To := MH#{Content => H}}
                                      , proc_operation_map := POM#{From => [{VC, To} | PO]}
                                      };
                        (_, ProcState) ->
                            ProcState
                    end,
                    #{local_vc_map => #{}, message_history_map => #{}, proc_operation_map => #{}},
                    Tab),
              POM =
                  maps:fold(
                    fun (Proc, OPList, Acc) ->
                            Acc#{Proc => lists:reverse(OPList)}
                    end, #{}, POMReversed),
              case ets:insert_new(AccTab, {{po_trace, POM}, 1}) of
                  true ->
                      io:format("New po trace ~p~n"
                                "  original ~p~n",
                                [POM, ets:match(Tab, '$1')]),
                      ets:update_counter(AccTab, po_coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {po_trace, POM}, 1)
              end,
              ok
          end),
    case R of
        ok -> ok;
        _ ->
            io:format("Got error ~p~n"
                      "  while processing trace~n"
                      "  ~p~n",
                      [R, ets:match(Tab, '$1')])
    end,
    ok.

%% ==== Path Coverage ====

merge_path_coverage(Tab, AccTab) ->
    merge_path_coverage(Tab, AccTab, undefined).

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

merge_state_coverage(Tab, AccTab) ->
    merge_state_coverage(Tab, undefined, AccTab, undefined).

merge_state_coverage(Tab, IterationId, AccTab, SimpMap) ->
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
    POCoverage = proplists:get_value(po_coverage, Args, false),
    PathCoverage = proplists:get_value(path_coverage, Args, false),
    LineCoverage = proplists:get_value(line_coverage, Args, false),
    StateCoverage = proplists:get_value(state_coverage, Args, false),
    State = #state{ tab = Tab
                  , acc_filename = AccFilename
                  , acc_fork_period = AccForkPeriod
                  , po_coverage = POCoverage
                  , path_coverage = PathCoverage
                  , line_coverage = LineCoverage
                  , state_coverage = StateCoverage
                  },
    {ok, State}.

handle_call({stop, SeedInfo, SHT},
            _From,
            #state{ tab = Tab
                  , acc_filename = AF
                  , acc_fork_period = AFP
                  , po_coverage = POC
                  , path_coverage = PC
                  , line_coverage = LC
                  , state_coverage = SC
                  }
            = State)
  when Tab =/= undefined, AF =/= undefined ->
    SimpMap = extract_simplify_map(SHT),
    AccTab = open_or_create_acc_ets_tab(AF),
    IC = ets:update_counter(AccTab, iteration_counter, 1),
    ets:insert(AccTab, {{iteration_seed, IC}, SeedInfo}),
    case POC of
        true ->
            merge_po_coverage(Tab, AccTab, SimpMap),
            [{po_coverage_counter, POCoverageCount}] = ets:lookup(AccTab, po_coverage_counter),
            io:format(user, "po coverage count = ~p~n", [POCoverageCount]);
        false ->
            ok
    end,
    case PC of
        true ->
            merge_path_coverage(Tab, AccTab, SimpMap),
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
            merge_state_coverage(Tab, IC, AccTab, SimpMap),
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
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

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
handle_cast({report_state, Depth, RState}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceReportState(TC, Depth, RState)),
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
