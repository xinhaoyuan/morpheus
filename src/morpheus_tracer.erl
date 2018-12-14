-module(morpheus_tracer).

-behaviour(gen_server).

%% API.
-export([ start_link/1
        , trace_call/4
        , trace_new_process/6
        , trace_send/7
        , trace_receive/5
        , stop/1
        , create_ets_tab/0
        , create_acc_ets_tab/0
        , open_or_create_acc_ets_tab/1
        , merge_path/2
        , calc_acc_fanout/1
        ]).

%% gen_server.
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3]).

-record(state, { tab :: ets:tid()
               , acc_filename :: string()
               }).

-include("morpheus_trace.hrl").

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

stop(T) ->
    gen_server:call(T, {stop}).

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
    ets:insert(Tab, {path_counter, 0}),
    ets:insert(Tab, {coverage_counter, 0}),
    Tab.

open_or_create_acc_ets_tab(Filename) ->
    open_or_create_ets(
      Filename,
      fun (_Reason) ->
              create_acc_ets_tab()
      end).

%% Merge per-actor path.
merge_path(Tab, AccTab) ->
    ProcState =
        ets:foldl(
          fun (?TraceCall(_, _, _, _), Acc) ->
                  Acc;
              (?TraceNewProcess(_, Proc, _AbsId, _Creator, _EntryInfo, EntryHash), ProcState) ->
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
              ({trace_counter, _}, Acc) ->
                  Acc
          end, #{}, Tab),
    NewPathCount = maps:fold(
                 fun (_, {_, true}, Acc) ->
                         Acc + 1;
                     (_, {_, false}, Acc) ->
                         Acc
                 end, 0, ProcState),
    ets:update_counter(AccTab, path_counter, NewPathCount),
    ok.

%% Merge line coverage (approximately).
merge_coverage(Tab, AccTab) ->
    ets:foldl(
      fun (?TraceCall(_, _From, Where, _Req), Acc) ->
              case ets:insert_new(AccTab, {{coverage, Where}, 1}) of
                  true ->
                      ets:update_counter(AccTab, coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {coverage, Where}, 1)
              end,
              Acc;
          (?TraceSend(_, Where, _From, _To, _Type, _Content, _Effect), Acc) ->
              case ets:insert_new(AccTab, {{coverage, Where}, 1}) of
                  true ->
                      ets:update_counter(AccTab, coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {coverage, Where}, 1)
              end,
              Acc;
          (?TraceRecv(_, Where, _To, _Type, _Content), Acc) ->
              case ets:insert_new(AccTab, {{coverage, Where}, 1}) of
                  true ->
                      ets:update_counter(AccTab, coverage_counter, 1);
                  false ->
                      ets:update_counter(AccTab, {coverage, Where}, 1)
              end,
              Acc;
          (_, Acc) ->
              Acc
      end, undefined, Tab).

%% For a accumulated table, calculate the path tree fanout function
%%   f(d) := how many path node are at the depth d
%% Returns {MaxDepth, f}, where f has key from [0, MaxDepth] 
calc_acc_fanout(AccTab) ->
    [{root, Root}] = ets:lookup(AccTab, root),
    ChildrenMap =
        ets:foldl(
          fun ({{From, _}, To}, Acc) when is_integer(From), is_integer(To) ->
                  Acc#{From => [To | maps:get(From, Acc, [])]};
              %% Dirty hack for Acc in last version ...
              ({{{root, From}, _}, To}, Acc) when is_integer(From), is_integer(To) ->
                  Acc#{From => [To | maps:get(From, Acc, [])]};
              (_, Acc) ->
                  Acc
          end, #{}, AccTab),
    calc_acc_fanout(ChildrenMap, [], Root, {0, 0, #{}}).

calc_acc_fanout(_, [], backtrack, {MaxDepth, 0, Result}) ->
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
    State = #state{tab = Tab, acc_filename = AccFilename},
    {ok, State}.

handle_call({stop}, _From, #state{tab = Tab, acc_filename = AF} = State) when Tab =/= undefined, AF =/= undefined ->
    AccTab = open_or_create_acc_ets_tab(AF),
    merge_path(Tab, AccTab),
    merge_coverage(Tab, AccTab),
    [PathCount] = ets:lookup(AccTab, path_counter),
    [CoverageCount] = ets:lookup(AccTab, coverage_counter),
    io:format(user, "path count = ~p~n", [PathCount]),
    io:format(user, "coverage count = ~p~n", [CoverageCount]),
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
handle_cast(Msg, State) ->
    io:format(user, "Unknown trace cast ~p~n", [Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
