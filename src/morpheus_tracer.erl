-module(morpheus_tracer).

-behaviour(gen_server).

%% API.
-export([ start_link/1
        , trace_call/4
        , trace_new_process/5
        , trace_send/7
        , trace_receive/5
        , stop/1
        , create_ets_tab/0
        , create_acc_ets_tab/0
        , open_or_create_acc_ets_tab/1
        , merge_path/2
        ]).

%% gen_server.
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3]).

-record(state, { tab :: ets:tid()
               , merge_path_filename :: string()
               }).

%% API.

-spec start_link(term()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

trace_call(T, From, Where, Req) ->
    gen_server:cast(T, {call, From, Where, Req}).

trace_new_process(T, Proc, AbsId, EntryInfo, EntryHash) ->
    gen_server:cast(T, {new_process, Proc, AbsId, EntryInfo, EntryHash}).

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
    case ets:file2tab(Filename) of
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
    Tab.

open_or_create_acc_ets_tab(Filename) ->
    open_or_create_ets(
      Filename,
      fun (_Reason) ->
              create_acc_ets_tab()
      end).

merge_path(Tab, AccTab) ->
    ProcState =
        ets:foldl(
          fun ({_, call, _}, Acc) ->
                  Acc;
              ({_, new_process, {Proc, _AbsId, _EntryInfo, EntryHash}}, ProcState) ->
                  [Root] = ets:lookup(AccTab, root),
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
              ({_, send, {Where, From, To, Type, Content, _Effect}}, ProcState) ->
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
              ({_, recv, {Where, To, Type, Content}}, ProcState) ->
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

%% gen_server.

init(Args) ->
    Tab =
        case proplists:get_value(tab, Args) of
            undefined ->
                create_ets_tab();
            _T ->
                _T
        end,
    MergePathFilename = proplists:get_value(merge_path_filename, Args, undefined),
    State = #state{tab = Tab, merge_path_filename = MergePathFilename},
    {ok, State}.

handle_call({stop}, _From, #state{tab = Tab, merge_path_filename = MPF} = State) when Tab =/= undefined, MPF =/= undefined ->
    AccTab = open_or_create_acc_ets_tab(MPF),
    merge_path(Tab, AccTab),
    [PathCount] = ets:lookup(AccTab, path_counter),
    io:format(user, "path count = ~p~n", [PathCount]),
    ets:tab2file(AccTab, MPF),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast({call, From, Where, Req}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, {TC, call, {From, Where, Req}}),
    {noreply, State};
handle_cast({new_process, Proc, AbsId, EntryInfo, EntryHash}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, {TC, new_process, {Proc, AbsId, EntryInfo, EntryHash}}),
    {noreply, State};
handle_cast({send, Where, From, To, Type, Content, Effect}, #state{tab = Tab} = State) when Tab =/= undefined->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, {TC, send, {Where, From, To, Type, Content, Effect}}),
    {noreply, State};
handle_cast({recv, Where, To, Type, Content}, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    ets:insert(Tab, {TC, recv, {Where, To, Type, Content}}),
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
