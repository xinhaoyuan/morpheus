-module(morpheus_tracer).

-behaviour(gen_server).

%% API.
-export([ start_link/1
        , trace_call/4
        , trace_new_process/6
        , trace_send/7
        , trace_receive/5
        , trace_report_state/2
        , stop/2
        , create_ets_tab/0
        , create_acc_ets_tab/0
        , open_or_create_acc_ets_tab/1
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

-record(state, { tab            :: ets:tid()
               , acc_filename   :: string()
               , path_coverage  :: boolean()
               , line_coverage  :: boolean()
               , state_coverage :: boolean()
               }).

-include("morpheus_trace.hrl").

-define(H, morpheus_helper).

%% API.

-spec start_link(term()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

trace_call(T, From, Where, Req) ->
    gen_server:cast(T, {call, From, Where, Req}).

trace_new_process(T, Proc, AbsId, Creator, EntryInfo, EntryHash) ->
    gen_server:cast(T, {new_process, Proc, AbsId, Creator, EntryInfo, EntryHash}).

trace_send(T, Where, From, To, Type, Content, Effect) ->
    gen_server:cast(T, {send, Where, From, To, Type, Content, Effect}).

trace_receive(T, Where, To, Type, Content) ->
    gen_server:cast(T, {recv, Where, To, Type, Content}).

trace_report_state(T, State) ->
    gen_server:cast(T, {report_state, State}).

stop(T, SHT) ->
    gen_server:call(T, {stop, SHT}).

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
    ets:insert(Tab, {root, 1}),
    ets:insert(Tab, {node_counter, 1}),
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

%% Merge per-actor path.
merge_path_coverage(Tab, AccTab) ->
    ProcState =
        ets:foldl(
          fun (?TraceNewProcess(_, Proc, _AbsId, _Creator, _EntryInfo, EntryHash), ProcState) ->
                  [{root, Root}] = ets:lookup(AccTab, root),
                  Branch = {new, Proc, EntryHash},
                  case ets:lookup(AccTab, {Root, Branch}) of
                      [] ->
                          %% AvailableBranch = ets:match(AccTab, {{Root, '$1'}, '_'}),
                          %% io:format(user,
                          %%           "New branch ~p at ~p~n"
                          %%           "  available: ~p~n",
                          %%           [Branch, Root, AvailableBranch]),
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
                          Branch = {send, Where, To, Type, Content},
                          case ets:lookup(AccTab, {StateNode, Branch}) of
                              [] ->
                                  %% AvailableBranch = ets:match(AccTab, {{StateNode, '$1'}, '_'}),
                                  %% io:format(user,
                                  %%           "New branch ~p at ~p~n"
                                  %%           "  available: ~p~n",
                                  %%           [Branch, StateNode, AvailableBranch]),
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
                          Branch = {recv, Where, Type, Content},
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

merge_state_coverage(Tab, AccTab) ->
    merge_state_coverage(Tab, AccTab, undefined).

merge_state_coverage(Tab, AccTab, SimpMap) ->
    ets:foldl(
      fun (?TraceReportState(_, RState), Acc) ->
              SimpState =
                  case SimpMap of
                      undefined ->
                          RState;
                      _ ->
                          SimpResult = simplify(RState, SimpMap),
                          %% io:format(user,
                          %%           "simplify: ~p~n"
                          %%           "      to: ~p~n",
                          %%           [RState, SimpResult]),
                          SimpResult
                  end,
              case ets:insert_new(AccTab, {{state_coverage, SimpState}, 1}) of
                  true ->
                      ets:update_counter(AccTab, state_coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {state_coverage, SimpState}, 1)
              end,
              Acc;
          (_, Acc) ->
              Acc
      end, undefined, Tab).

extract_simplify_map(SHT) ->
    ets:foldl(
      fun ({{proc_abs_id, Proc}, Id}, Acc) ->
              Acc#{Proc => Id};
          ({{ref_abs_id, Ref}, Id}, Acc) ->
              Acc#{Ref => Id};
          (_, Acc) ->
              Acc
      end, #{}, SHT).

simplify([H | T], SimpMap) ->
    [simplify(H, SimpMap) | simplify(T, SimpMap)];
simplify(Data, SimpMap) when is_tuple(Data) ->
    list_to_tuple(simplify(tuple_to_list(Data), SimpMap));
simplify(Data, SimpMap) when is_map(Data) ->
    maps:fold(
      fun (K, V, Acc) ->
              Acc#{simplify(K, SimpMap) => simplify(V, SimpMap)}
      end, #{}, Data);
simplify(Data, SimpMap) when is_pid(Data) ->
    maps:get(Data, SimpMap, Data);
simplify(Data, SimpMap) when is_reference(Data) ->
    maps:get(Data, SimpMap, Data);
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
    PathCoverage = proplists:get_value(path_coverage, Args, false),
    LineCoverage = proplists:get_value(line_coverage, Args, false),
    StateCoverage = proplists:get_value(state_coverage, Args, false),
    State = #state{ tab = Tab
                  , acc_filename = AccFilename
                  , path_coverage = PathCoverage
                  , line_coverage = LineCoverage
                  , state_coverage = StateCoverage
                  },
    {ok, State}.

handle_call({stop, SHT},
            _From,
            #state{ tab = Tab
                  , acc_filename = AF
                  , path_coverage = PC
                  , line_coverage = LC
                  , state_coverage = SC
                  }
            = State)
  when Tab =/= undefined, AF =/= undefined ->
    %% XXX use SHT to simplify states
    SimpMap = extract_simplify_map(SHT),
    AccTab = open_or_create_acc_ets_tab(AF),
    case PC of
        true ->
            merge_path_coverage(Tab, AccTab),
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
            merge_state_coverage(Tab, AccTab, SimpMap),
            [{state_coverage_counter, StateCoverageCount}] = ets:lookup(AccTab, state_coverage_counter),
            io:format(user, "state coverage count = ~p~n", [StateCoverageCount]);
        false ->
            ok
    end,
    ets:tab2file(AccTab, AF, [{extended_info, [md5sum]}]),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast({call, From, Where, Req}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceCall(TC, From, Where, Req)),
    {noreply, State};
handle_cast({new_process, Proc, AbsId, Creator, EntryInfo, EntryHash}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceNewProcess(TC, Proc, AbsId, Creator, EntryInfo, EntryHash)),
    {noreply, State};
handle_cast({send, Where, From, To, Type, Content, Effect}, #state{tab = Tab} = State) when Tab =/= undefined->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceSend(TC, Where, From, To, Type, Content, Effect)),
    {noreply, State};
handle_cast({recv, Where, To, Type, Content}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceRecv(TC, Where, To, Type, Content)),
    {noreply, State};
handle_cast({report_state, RState}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, ?TraceReportState(TC, RState)),
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
