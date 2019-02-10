-module(morpheus_tracer).

-behaviour(gen_server).

%% API.
-export([ start_link/1
        , set_sht/2
        , predict_racing/4
        , trace_schedule/4
        , trace_call/4
        , trace_new_process/5
        , trace_send/7
        , trace_receive/5
        , trace_read/2
        , trace_write/2
        , trace_barrier/1
        , trace_report_state/3
        , finalize/3
        , create_ets_tab/0
        , create_acc_ets_tab/0
        , open_or_create_acc_ets_tab/1
        , calc_acc_fanout/1
        ]).

-export([ simplify/2, simplify_sht/2 ]).

%% gen_server.
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3]).

-record(state,
        { sht                     :: ets:tid()
        , tab                     :: ets:tid()
        , acc_filename            :: string()
        , acc_tab                 :: ets:tid()
        , to_predict              :: boolean()
        , predict_by              :: atom()
        , pred_state              :: term()
        , acc_fork_period         :: integer()
        , dump_traces             :: boolean()
        , dump_traces_verbose     :: boolean()
        , dump_po_traces          :: new | all | false
        , find_races              :: boolean()
        , po_coverage             :: boolean()
        , path_coverage           :: boolean()
        , line_coverage           :: boolean()
        , state_coverage          :: boolean()
        , extra_handlers          :: [module()]
        , extra_opts              :: #{}
        }).

%% internal state for building partial order dependency
-record(po_state,
        { sch_vc                :: dict:dict(integer(), #{})
        , sch_dep_vc            :: dict:dict(integer(), #{})
        , sch_pi                :: dict:dict(integer(), {pid(), integer()}) %% index starts from 1
        , sch_info              :: dict:dict(integer(), {pid(), term()})
        , last_sch              :: integer()
        , last_sch_access       :: dict:dict(term(), read | write)
        , last_sch_dep          :: [integer()]
        , last_sch_may_dep      :: [integer()]
        , last_sch_may_conflict :: [integer()]
        , last_sch_aux_send     :: sets:set(pid())
        , last_barrier          :: undefined | integer()
        , local_last_sch        :: dict:dict(pid(), integer())
        , local_sch_history     :: dict:dict(pid(), [integer()])
        , local_msg_queue       :: dict:dict(pid(), dict:dict(term(), queue:queue(integer())))
        , local_msg_sch         :: dict:dict(pid(), [integer()])
        , var_write_sch         :: dict:dict(term(), [integer()])
        , var_read_sch          :: dict:dict(term(), [integer()])
        , conflicts             :: [{integer(), [integer()]}]
        }).

-include("morpheus_trace.hrl").

-define(H, morpheus_helper).

%% API.

-spec start_link(term()) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

set_sht(T, SHT) ->
    gen_server:call(T, {set_sht, SHT}, infinity).

predict_racing(T, Where, Proc, Info) ->
    gen_server:call(T, {predict_racing, Where, Proc, Info}, infinity).

trace_schedule(T, Where, Proc, Info) ->
    gen_server:call(T, {add_trace, {schedule, Where, Proc, Info}}, infinity).

trace_call(T, From, Where, Req) ->
    gen_server:call(T, {add_trace, {call, From, Where, Req}}, infinity).

trace_new_process(T, Proc, AbsId, Creator, EntryInfo) ->
    gen_server:call(T, {add_trace, {new_process, Proc, AbsId, Creator, EntryInfo}}, infinity).

trace_send(T, Where, From, To, Type, Content, Effect) ->
    gen_server:call(T, {add_trace, {send, Where, From, To, Type, Content, Effect}}, infinity).

trace_receive(T, Where, To, Type, Content) ->
    gen_server:call(T, {add_trace, {recv, Where, To, Type, Content}}, infinity).

trace_read(T, Var) ->
    gen_server:call(T, {add_trace, {read, Var}}, infinity).

trace_write(T, Var) ->
    gen_server:call(T, {add_trace, {write, Var}}, infinity).

trace_barrier(T) ->
    gen_server:call(T, {add_trace, {barrier}}, infinity).

trace_report_state(T, TraceInfo, State) ->
    gen_server:call(T, {add_trace, {report_state, TraceInfo, State}}, infinity).

finalize(T, TraceInfo, SHT) ->
    gen_server:call(T, {finalize, TraceInfo, SHT}, infinity).

create_ets_tab() ->
    Tab = ets:new(trace_tab, [ordered_set, public, {write_concurrency, true}]),
    ets:insert(Tab, {trace_counter, 0}),
    Tab.

create_acc_ets_tab() ->
    Tab = ets:new(acc_tab, []),
    ets:insert(Tab, {iteration_counter, 0}),
    ets:insert(Tab, {path_root, 1}),
    ets:insert(Tab, {{path_branch_counter, 1}, 0}),
    ets:insert(Tab, {{path_hit_counter, 1}, 0}),
    ets:insert(Tab, {path_node_counter, 1}),
    ets:insert(Tab, {po_coverage_counter, 0}),
    ets:insert(Tab, {path_coverage_counter, 0}),
    ets:insert(Tab, {line_coverage_counter, 0}),
    ets:insert(Tab, {state_coverage_counter, 0}),
    Tab.

open_or_create_acc_ets_tab(Filename) ->
    ?H:open_or_create_ets(
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

dict_get(K, D) ->
    dict:fetch(K, D).

dict_get(K, D, U) ->
    case dict:find(K, D) of
        {ok, Value} ->
            Value;
        error ->
            U
    end.

%% 1. Compute the VC and DepVC of the last sch
%% 2. Find out conflicting schs
handle_last_sch(#po_state{ sch_vc = SchVC
                         , sch_dep_vc = SchDepVC
                         , sch_pi = SchPI
                         , last_sch = LastSch
                         , last_sch_dep = LSDep
                         , last_sch_may_dep = LSMayDep
                         , last_sch_may_conflict = LSMayConflict
                         , conflicts = Conflicts
                         } = POState) ->
    LSUDep = lists:usort(LSDep),
    LSUMayDep = lists:usort(LSMayDep),
    LSUMayConflict = lists:usort(LSMayConflict),
    DepVC =
        lists:foldl(
          fun (0, Acc) -> Acc;
              (DepSch, Acc) when DepSch =:= LastSch -> Acc;
              (DepSch, Acc) ->
                  {P, I} = dict_get(DepSch, SchPI),
                  case I =< maps:get(P, Acc, 0) of
                      true ->
                          Acc;
                      false ->
                          DepSchVC = dict_get(DepSch, SchVC),
                          merge_vc(DepSchVC, Acc)
                  end
          end, #{}, LSUDep ++ (LSUMayDep -- LSUMayConflict)),

    {P, I} = dict_get(LastSch, SchPI),
    {VC, SchConflicts} =
        lists:foldl(
          fun (0, Acc) -> Acc;
              (ConfSch, Acc) when ConfSch =:= LastSch -> Acc;
              (ConfSch, {CurVC, CurConflicts}) ->
                  {CP, CI} = dict_get(ConfSch, SchPI),
                  ConfSchVC = dict_get(ConfSch, SchVC),
                  NewConflicts =
                      case CI =< maps:get(CP, DepVC, 0) of
                          true ->
                              CurConflicts;
                          false ->
                              CanHappensBefore =
                                  maps:fold(
                                    fun (_, _, true) -> true;
                                        (IP, II, false) ->
                                            II > maps:get(IP, DepVC, 0)
                                    end, false, ConfSchVC),
                              case CanHappensBefore of
                                  true ->
                                      [ConfSch | CurConflicts];
                                  false ->
                                      CurConflicts
                              end
                      end,
                  NewVC =
                      case CI =< maps:get(CP, CurVC, 0) of
                          true ->
                              CurVC;
                          false ->
                              merge_vc(ConfSchVC, CurVC)
                      end,
                  {NewVC, NewConflicts}
          end, {DepVC#{P => I}, []}, LSUMayConflict),

    POState#po_state
        { sch_vc = dict:store(LastSch, VC, SchVC)
        , sch_dep_vc = dict:store(LastSch, DepVC, SchDepVC)
        , conflicts = [{LastSch, SchConflicts} | Conflicts]
        }.

analyze_partial_order(#state{find_races = FindRaces} = _State, Tab, SimpMap) ->
    #po_state
        { sch_vc = SchVC
        , local_sch_history = LSH
        , conflicts = Conflicts
        } = handle_last_sch(
              ets:foldl(
                fun (?TraceNewProcess(_, Proc, _, _, _),
                     #po_state{ last_sch = LastSch
                              , local_last_sch = LLS
                              , local_sch_history = LSH
                              , local_msg_queue = LMQ
                              , local_msg_sch = LMS
                              } = POState) ->
                        POState#po_state{ local_last_sch = dict:store(Proc, LastSch, LLS)
                                        , local_sch_history = dict:store(Proc, [], LSH)
                                        , local_msg_queue = dict:store(Proc, dict:new(), LMQ)
                                        , local_msg_sch = dict:store(Proc, [], LMS)
                                        };

                    (?TraceSchedule(TID, _Where, Proc, Content),
                     POState) ->
                        #po_state{ sch_pi = SchPI
                                 , sch_info = SchInfo
                                 , last_barrier = LastBarrier
                                 , local_sch_history = LSH
                                 , local_last_sch = LLS
                                 } = POState1 = handle_last_sch(POState),
                        SH = dict_get(Proc, LSH),
                        Pre = dict_get(Proc, LLS),
                        POState1#po_state{ sch_pi = dict:store(TID, {Proc, length(SH) + 1}, SchPI)
                                         , sch_info = dict:store(TID, {Proc, Content}, SchInfo)
                                         , last_sch = TID
                                         , last_sch_access = dict:new()
                                         , last_sch_dep =
                                               case LastBarrier of
                                                   undefined ->
                                                       [Pre];
                                                   _ ->
                                                       [Pre, LastBarrier]
                                               end
                                         , last_sch_may_dep = []
                                         , last_sch_may_conflict = []
                                         , last_sch_aux_send = sets:new()
                                         , local_last_sch = dict:store(Proc, TID, LLS)
                                         , local_sch_history = dict:store(Proc, [TID | SH], LSH)
                                         };

                    (?TraceBarrier(TID), POState) ->
                        #po_state{ sch_pi = SchPI
                                 , last_barrier = LastBarrier
                                 , local_last_sch = LLS
                                 } = POState1 = handle_last_sch(POState),
                        POState1#po_state{ sch_pi = dict:store(TID, {undefined, 0}, SchPI)
                                         , last_sch = TID
                                         , last_sch_access = dict:new()
                                         , last_sch_dep =
                                               dict:fold(
                                                 fun (_, V, Acc) ->
                                                   [V | Acc]
                                                 end,
                                                 case LastBarrier of undefined -> []; _ -> [LastBarrier] end,
                                                 LLS)
                                         , last_sch_may_dep = []
                                         , last_sch_may_conflict = []
                                         , last_sch_aux_send = sets:new()
                                         };

                    (?TraceWrite(_, Var),
                     #po_state{ last_sch = LastSch
                              , last_sch_access = LSAccess
                              , last_sch_may_conflict = LSMayConflict
                              , var_write_sch = VWSch
                              , var_read_sch = VRSch
                              } = POState) ->
                        ToSkip =
                            case dict:find(Var, LSAccess) of
                                {ok, write} -> true;
                                {ok, read} -> false;
                                error -> false
                            end,
                        case ToSkip of
                            true -> POState;
                            false ->
                                WSch = dict_get(Var, VWSch, []),
                                RSch = dict_get(Var, VRSch, []),
                                POState#po_state
                                    { last_sch_access = dict:store(Var, write, LSAccess)
                                    , last_sch_may_conflict = RSch ++ WSch ++ LSMayConflict
                                    , var_write_sch = dict:store(Var, [LastSch | WSch], VWSch)
                                    }
                        end;

                    (?TraceRead(_, Var),
                     #po_state{ last_sch = LastSch
                              , last_sch_access = LSAccess
                              , last_sch_may_conflict = LSMayConflict
                              , var_write_sch = VWSch
                              , var_read_sch = VRSch
                              } = POState) ->
                        ToSkip =
                            case dict:find(Var, LSAccess) of
                                {ok, write} -> true;
                                {ok, read} -> true;
                                error -> false
                            end,
                        case ToSkip of
                            true -> POState;
                            false ->
                                WSch = dict_get(Var, VWSch, []),
                                RSch = dict_get(Var, VRSch, []),
                                POState#po_state
                                    { last_sch_access = dict:store(Var, read, LSAccess)
                                    , last_sch_may_conflict = WSch ++ LSMayConflict
                                    , var_read_sch = dict:store(Var, [LastSch | RSch], VRSch)
                                    }
                        end;

                    (?TraceRecv(_Id, _Where, To, message, Content),
                     #po_state{ last_sch = LastSch
                              , last_sch_may_dep = LSMayDep
                              , last_sch_may_conflict = LSMayConflict
                              , local_last_sch = LLS
                              , local_msg_queue = LMQ
                              } = POState) ->
                        %% Receive of the message depends on the sending operation
                        %% Note that for now only message receive is in scope, others (e.g. signals, timeouts) are ignored for now.
                        MQ = dict_get(To, LMQ),
                        case dict:is_key(Content, MQ) of
                            false ->
                                io:format(user, "??? analyze_partial_order: ~p cannot find in ~p", [Content, dict:to_list(MQ)]);
                            true ->
                                ok
                        end,
                        Q = dict_get(Content, MQ),
                        {{value, SendTID}, H1} = queue:out(Q),
                        %% LastSch may conflict with the last sch in the proc.
                        LS = dict_get(To, LLS),
                        POState#po_state{ local_last_sch = dict:store(To, LastSch, LLS)
                                        , local_msg_queue = dict:store(To, dict:store(Content, H1, MQ), LMQ)
                                        , last_sch_may_dep =
                                              case SendTID =:= LastSch of
                                                  true -> LSMayDep;
                                                  false -> [SendTID |  LSMayDep]
                                              end
                                        , last_sch_may_conflict =
                                              case LS =:= LastSch of
                                                  true -> LSMayConflict;
                                                  false -> [LS | LSMayConflict]
                                              end
                                        };

                    (?TraceSend(_, _Where, From, To, _Type, Content, _Effect),
                     #po_state{ last_sch = LastSch
                              , last_sch_may_conflict = LSMayConflict
                              , last_sch_aux_send = LSAuxSend
                              , local_msg_queue = LMQ
                              , local_msg_sch = LMS
                              } = POState) ->
                        %% Sending message to a process will make it happen after all sending of existing messages
                        case is_pid(From) of
                            true ->
                                MQ = dict_get(To, LMQ),
                                MS = dict_get(To, LMS),
                                Q = queue:in(LastSch, dict_get(Content, MQ, queue:new())),
                                {IsNewSend, LSAuxSend1} =
                                    case sets:is_element(To, LSAuxSend) of
                                        true ->
                                            {false, LSAuxSend};
                                        false ->
                                            {true, sets:add_element(LastSch, LSAuxSend)}
                                    end,
                                POState#po_state
                                    { last_sch_aux_send = LSAuxSend1
                                    , last_sch_may_conflict =
                                          case IsNewSend of
                                              true ->
                                                  MS ++ LSMayConflict;
                                              false ->
                                                  LSMayConflict
                                          end
                                    , local_msg_queue = dict:store(To, dict:store(Content, Q, MQ), LMQ)
                                    , local_msg_sch =
                                          case IsNewSend of
                                              true ->
                                                  dict:store(To, [LastSch | MS], LMS);
                                              false ->
                                                  LMS
                                          end
                                    };
                            false ->
                                %% XXX I do not know how to handle undet message yet ...
                                %% This is probably wrong, but I will assume a dummy sending tid (which has no dependency) for now
                                MQ = dict_get(To, LMQ),
                                Q = queue:in(0, dict_get(Content, MQ, queue:new())),
                                POState#po_state
                                    { local_msg_queue = dict:store(To, dict:store(Content, Q, MQ), LMQ)
                                    }
                        end;

                    (_, POState) ->
                        POState
                end,
                #po_state
                { sch_vc = dict:new()
                , sch_dep_vc = dict:new()
                , sch_pi = dict:from_list([{0, {undefined, 0}}])
                , sch_info = dict:from_list([{0, {undefined, undefined}}])
                , last_sch = 0
                , last_sch_access = dict:new()
                , last_sch_dep = []
                , last_sch_may_dep = []
                , last_sch_may_conflict = []
                , last_sch_aux_send = sets:new()
                , last_barrier = undefined
                , local_last_sch = dict:new()
                , local_sch_history = dict:new()
                , local_msg_queue = dict:new()
                , local_msg_sch = dict:new()
                , var_write_sch = dict:new()
                , var_read_sch = dict:new()
                , conflicts = []
                },
                Tab)),
    SimplifiedSchVC =
        dict:fold(
          fun (Sch, VC, Acc) ->
                  SimplifiedVC =
                      maps:fold(
                        fun (IPX, II, IAcc) ->
                                IP = simplify(IPX, SimpMap),
                                IAcc#{IP => II}
                        end, #{}, VC),
                  dict:store(Sch, SimplifiedVC, Acc)
          end, dict:new(), SchVC),
    POH = dict:fold(
            fun (PX, HX, Acc) ->
                    P = simplify(PX, SimpMap),
                    %% will reverse back he order in the process
                    H = lists:foldl(
                          fun (Sch, HAcc) ->
                                  VC = dict_get(Sch, SimplifiedSchVC),
                                  [VC | HAcc]
                          end, [], HX),
                    Acc#{P => H}
            end, #{}, LSH),

    Ret0 = #{partial_order_history => POH, conflicts => Conflicts},
    Ret1 =
        case FindRaces of
            false ->
                Ret0;
            true ->
                {RaceCount, RacingTIDs, RacingLocations} = refine_race_information(_State, Tab, Conflicts),
                Ret0#{racing_locations => RacingLocations, racing_tids => RacingTIDs, race_count => RaceCount}
        end,
    {ok, Ret1}.

%% simplify_po_trace(POTrace, AuxSerialization) ->
%%     {_, InitialInfo} =
%%         lists:foldl(
%%           fun (Actor, {Index, Acc}) ->
%%                   {Index + 1, Acc#{Actor => {Index, 1}}}
%%           end, {0, #{}}, lists:usort(AuxSerialization)),
%%     simplify_po_trace(InitialInfo, POTrace, AuxSerialization, []).

%% simplify_po_trace(_, _, [], Rev) ->
%%     lists:reverse(Rev);
%% simplify_po_trace(Info, POTrace, [From | RestSerialization] = _AuxSerialization, Rev) ->
%%     #{From := {FromI, Counter}} = Info,
%%     #{From := [{VC, {To, Content}} | Rest]} = POTrace,
%%     #{To := {ToI, _}} = Info,
%%     Height = maps:fold(
%%                fun (Actor, Index, AccHeight) ->
%%                        #{Actor := {ActorI, _}} = Info,
%%                        CurHeight = maps:get({ActorI, Index}, Info),
%%                        max(CurHeight, AccHeight)
%%                end, 0, VC) + 1,
%%     simplify_po_trace(Info#{{FromI, Counter} => Height, From := {FromI, Counter + 1}},
%%                        POTrace#{From := Rest},
%%                        RestSerialization,
%%                        [{FromI, Height, ToI, Content} | Rev]).

merge_po_coverage(#state{dump_po_traces = Dump} = State, Tab, IC, AccTab, #{partial_order_history := POH, simp_map := SimpMap} = FinalData) ->
    %% Thus we can count how many partial orders has been covered.
    case ets:insert_new(AccTab, {{po_trace, POH}, [IC]}) of
        true ->
            case Dump of
                _ when Dump =:= new; Dump =:= all ->
                    io:format(user, "New po trace ~p~n", [maps:get(simplified_po_trace, FinalData, POH)]),
                    dump_trace(State, Tab, SimpMap);
                _ ->
                    ok
            end,
            ets:update_counter(AccTab, po_coverage_counter, 1);
        false ->
            case Dump of
                all ->
                    io:format(user, "po trace ~p~n", [POH]),
                    dump_trace(State, Tab, SimpMap);
                _ ->
                    ok
            end,
            case ets:lookup(AccTab, {po_trace, POH}) of
                [{_, ItList}] ->
                    ets:update_element(AccTab, {po_trace, POH}, [{2, [IC | ItList]}])
            end
    end,
    ok.

refine_race_information(#state{extra_opts = ExtraOpts}, Tab, Races) ->
    {NRaces, TIDs} =
        lists:foldl(
          fun ({X, YList}, {N, S}) ->
                  {N + length(YList),
                   case YList of
                       [] -> S;
                       _ ->
                           lists:foldl(
                             fun (Y, Acc) ->
                                     sets:add_element(Y, Acc)
                             end,
                             sets:add_element(X, S), YList)
                   end}
          end, {0, sets:new()}, Races),
    Locations =
        ets:foldl(
          fun (?TraceSchedule(TID, Where, _, _), Acc) ->
                  case sets:is_element(TID, TIDs) of
                      true ->
                          sets:add_element(Where, Acc);
                      false ->
                          Acc
                  end;

              (_, Acc) ->
                  Acc
          end, sets:new(), Tab),
    case maps:get(verbose_race_info, ExtraOpts, false) of
        true ->
            io:format(user,
                      "# of races: ~w~n"
                      "racing locations: ~p~n",
                      [NRaces, sets:to_list(Locations)]);
        false ->
            ok
    end,
    {NRaces, TIDs, sets:to_list(Locations)}.

%% ==== Path Coverage ====

path_traverse(TraceEntry, #{simp_map := SimpMap} = AnalysesData, AccTab, PathState, #{allow_create_new_nodes := AllowCreate, debug := Debug}) ->
    case TraceEntry of
        ?TraceNewProcess(_, Proc, _AbsId, _Creator, EntryInfo) ->
            [{path_root, Root}] = ets:lookup(AccTab, path_root),
            Branch = {new, simplify(Proc, SimpMap), simplify(EntryInfo, SimpMap)},
            case ets:lookup(AccTab, {path_branch, Root, Branch}) of
                [] when AllowCreate ->
                    case Debug of
                        true ->
                            AvailableBranch = ets:match(AccTab, {{path_branch, Root, '$1'}, '_'}),
                            io:format(user,
                                      "New branch ~p at ~p~n"
                                      "  available: ~p~n",
                                      [Branch, Root, AvailableBranch]);
                        false ->
                            ok
                    end,
                    NewNode = ets:update_counter(AccTab, path_node_counter, 1),
                    ets:insert(AccTab, {{path_branch, Root, Branch}, NewNode}),
                    ets:update_counter(AccTab, {path_branch_counter, Root}, 1),
                    ets:insert(AccTab, {{path_branch_counter, NewNode}, 0}),
                    ets:insert(AccTab, {{path_hit_counter, NewNode}, 1}),
                    PathState#{Proc => {NewNode, true}};
                [{_, Next}] ->
                    ets:update_counter(AccTab, {path_hit_counter, Next}, 1),
                    PathState#{Proc => {Next, false}}
            end;
        ?TraceSchedule(TID, Where, Proc, Info) ->
            case maps:is_key(Proc, PathState) of
                true ->
                    #{Proc := {StateNode, InNewBranch}} = PathState,
                    SimpInfo = simplify(Info, SimpMap),
                    Branch = {schedule, Where, simplify(Proc, SimpMap), SimpInfo},
                    {NextState0, IsNew, NextNode} =
                        case ets:lookup(AccTab, {path_branch, StateNode, Branch}) of
                            [] when AllowCreate ->
                                case Debug of
                                    true ->
                                        AvailableBranch = ets:match(AccTab, {{StateNode, '$1'}, '_'}),
                                        io:format(user,
                                                  "New branch ~p at ~p~n"
                                                  "  available: ~p~n",
                                                  [Branch, StateNode, AvailableBranch]);
                                    false ->
                                        io:format(user,
                                                  "New branch ~p at ~p~n",
                                                  [Branch, StateNode])
                                end,
                                NewNode = ets:update_counter(AccTab, path_node_counter, 1),
                                ets:insert(AccTab, {{path_branch, StateNode, Branch}, NewNode}),
                                BC = ets:update_counter(AccTab, {path_branch_counter, StateNode}, 1),
                                ets:insert(AccTab, {{path_branch_counter, NewNode}, 0}),
                                ets:insert(AccTab, {{path_hit_counter, NewNode}, 1}),
                                {PathState#{Proc := {NewNode, InNewBranch orelse BC > 1}}, true, NewNode};
                            [{_, Next}] ->
                                ets:update_counter(AccTab, {path_hit_counter, Next}, 1),
                                {PathState#{Proc := {Next, InNewBranch}}, false, Next}
                        end,
                    NextState = NextState0#{total_op => 1 + maps:get(total_op, NextState0, 0)},
                    case maps:is_key(racing_tids, AnalysesData) of
                        true ->
                            IsRacing = sets:is_element(TID, maps:get(racing_tids, AnalysesData)),
                            HasFlag = ets:lookup(AccTab, {racing_path_flag, NextNode}) =/= [],
                            case IsRacing of
                                true ->
                                    case HasFlag of
                                        true ->
                                            ets:update_counter(AccTab, {racing_path_flag, NextNode}, 1);
                                        false ->
                                            ets:insert_new(AccTab, {{racing_path_flag, NextNode}, 1})
                                    end,
                                    case IsNew orelse HasFlag of
                                        true ->
                                            NextState#{racing_op => 1 + maps:get(racing_op, PathState, 0)};
                                        false ->
                                            NextState#{ racing_op => 1 + maps:get(racing_op, PathState, 0)
                                                      , racing_fn => 1 + maps:get(racing_fn, PathState, 0)}
                                    end;
                                false ->
                                    case IsNew or HasFlag of
                                        true ->
                                            NextState#{racing_fp => 1 + maps:get(racing_fp, PathState, 0)};
                                        false ->
                                            NextState
                                    end
                            end;
                        false ->
                            NextState
                    end;
                false ->
                    PathState
            end;
        ?TraceSend(_, Where, From, To, Type, Content, _Effect) ->
            case maps:is_key(From, PathState) of
                true ->
                    #{From := {StateNode, InNewBranch}} = PathState,
                    SimpContent = simplify(Content, SimpMap),
                    Branch = {send, Where, simplify(To, SimpMap), Type, SimpContent},
                    case ets:lookup(AccTab, {path_branch, StateNode, Branch}) of
                        [] when AllowCreate ->
                            case Debug of
                                true ->
                                    AvailableBranch = ets:match(AccTab, {{StateNode, '$1'}, '_'}),
                                    io:format(user,
                                              "New branch ~p at ~p~n"
                                              "  available: ~p~n",
                                              [Branch, StateNode, AvailableBranch]);
                                false ->
                                    ok
                            end,
                            NewNode = ets:update_counter(AccTab, path_node_counter, 1),
                            ets:insert(AccTab, {{path_branch, StateNode, Branch}, NewNode}),
                            BC = ets:update_counter(AccTab, {path_branch_counter, StateNode}, 1),
                            ets:insert(AccTab, {{path_branch_counter, NewNode}, 0}),
                            ets:insert(AccTab, {{path_hit_counter, NewNode}, 1}),
                            PathState#{From := {NewNode, InNewBranch orelse BC > 1}};
                        [{_, Next}] ->
                            ets:update_counter(AccTab, {path_hit_counter, Next}, 1),
                            PathState#{From := {Next, InNewBranch}}
                    end;
                false ->
                    PathState
            end;
        ?TraceRecv(_, Where, To, Type, Content) ->
            case maps:is_key(To, PathState) of
                true ->
                    #{To := {StateNode, InNewBranch}} = PathState,
                    SimpContent = simplify(Content, SimpMap),
                    Branch = {recv, Where, Type, SimpContent},
                    case ets:lookup(AccTab, {path_branch, StateNode, Branch}) of
                        [] when AllowCreate ->
                            case Debug of
                                true ->
                                    AvailableBranch = ets:match(AccTab, {{StateNode, '$1'}, '_'}),
                                    io:format(user,
                                              "New branch ~p at ~p~n"
                                              "  available: ~p~n",
                                              [Branch, StateNode, AvailableBranch]);
                                false ->
                                    ok
                            end,
                            NewNode = ets:update_counter(AccTab, path_node_counter, 1),
                            ets:insert(AccTab, {{path_branch, StateNode, Branch}, NewNode}),
                            BC = ets:update_counter(AccTab, {path_branch_counter, StateNode}, 1),
                            ets:insert(AccTab, {{path_branch_counter, NewNode}, 0}),
                            ets:insert(AccTab, {{path_hit_counter, NewNode}, 1}),
                            PathState#{To := {NewNode, InNewBranch orelse BC > 1}};
                        [{_, Next}] ->
                            ets:update_counter(AccTab, {path_hit_counter, Next}, 1),
                            PathState#{To := {Next, InNewBranch}}
                    end;
                false ->
                    PathState
            end;
        _ ->
            PathState
    end.

%% Almost path_traverse but for online prediction
path_prediction_traverse(TraceEntry, SHT, AccTab, PathState) ->
    case TraceEntry of
        ?TraceNewProcess(_, Proc, _AbsId, _Creator, EntryInfo) ->
            [{path_root, Root}] = ets:lookup(AccTab, path_root),
            Branch = {new, simplify_sht(Proc, SHT), simplify_sht(EntryInfo, SHT)},
            case ets:lookup(AccTab, {path_branch, Root, Branch}) of
                [] ->
                    maps:remove(Proc, PathState);
                [{_, Next}] ->
                    PathState#{Proc => Next}
            end;
        ?TraceSchedule(_, Where, Proc, Info) ->
            case maps:is_key(Proc, PathState) of
                true ->
                    #{Proc := StateNode} = PathState,
                    SimpInfo = simplify_sht(Info, SHT),
                    Branch = {schedule, Where, simplify_sht(Proc, SHT), SimpInfo},
                    case ets:lookup(AccTab, {path_branch, StateNode, Branch}) of
                        [] ->
                            maps:remove(Proc, PathState);
                        [{_, Next}] ->
                            PathState#{Proc := Next}
                    end;
                false ->
                    PathState
            end;
        ?TraceSend(_, Where, From, To, Type, Content, _Effect) ->
            case maps:is_key(From, PathState) of
                true ->
                    #{From := StateNode} = PathState,
                    SimpContent = simplify_sht(Content, SHT),
                    Branch = {send, Where, simplify_sht(To, SHT), Type, SimpContent},
                    case ets:lookup(AccTab, {path_branch, StateNode, Branch}) of
                        [] ->
                            maps:remove(From, PathState);
                        [{_, Next}] ->
                            PathState#{From := Next}
                    end;
                false ->
                    PathState
            end;
        ?TraceRecv(_, Where, To, Type, Content) ->
            case maps:is_key(To, PathState) of
                true ->
                    #{To := StateNode} = PathState,
                    SimpContent = simplify_sht(Content, SHT),
                    Branch = {recv, Where, Type, SimpContent},
                    case ets:lookup(AccTab, {path_branch, StateNode, Branch}) of
                        [] ->
                            maps:remove(To, PathState);
                        [{_, Next}] ->
                            PathState#{To := Next}
                    end;
                false ->
                    PathState
            end;
        _ ->
            PathState
    end.

%% Merge per-actor path.
merge_path_coverage(#state{extra_opts = ExtraOpts}, Tab, AccTab, AnalysesData) ->
    PathState =
        ets:foldl(
          fun (TraceEntry, PathState) ->
                  path_traverse(TraceEntry, AnalysesData, AccTab, PathState, #{allow_create_new_nodes => true, debug => false})
          end, #{}, Tab),
    NewPathCount = maps:fold(
                 fun (P, {_, true}, Acc) when is_pid(P) ->
                         Acc + 1;
                     (P, {_, false}, Acc) when is_pid(P) ->
                         Acc;
                     (_, _, Acc) ->
                         Acc
                  end, 0, PathState),
    case maps:get(verbose_racing_prediction_stat, ExtraOpts, false) of
        true ->
            io:format(user, "Prefix prediction: total ~w, racing ~w, FP ~w, FN ~w~n",
                      [maps:get(total_op, PathState, 0),
                       maps:get(racing_op, PathState, 0),
                       maps:get(racing_fp, PathState, 0),
                       maps:get(racing_fn, PathState, 0)]);
        false ->
            ok
    end,
    ets:update_counter(AccTab, path_coverage_counter, NewPathCount),
    ok.

%% Merge line coverage (approximately).
merge_line_coverage(#state{extra_opts = ExtraOpts}, Tab, AccTab, #{simp_map := SimpMap} = AnalysesData) ->
    Result =
        ets:foldl(
          fun (?TraceCall(_, _From, Where, _Req), Acc) ->
                  case ets:insert_new(AccTab, {{line_coverage, Where}, 1}) of
                      true ->
                          ets:update_counter(AccTab, line_coverage_counter, 1);
                      false ->
                          ets:update_counter(AccTab, {line_coverage, Where}, 1)
                  end,
                  Acc;
              (?TraceSchedule(TID, Where, Proc, _Info), Acc) ->
                  case ets:insert_new(AccTab, {{line_coverage, Where}, 1}) of
                      true ->
                          ets:update_counter(AccTab, line_coverage_counter, 1);
                      false ->
                          ets:update_counter(AccTab, {line_coverage, Where}, 1)
                  end,
                  case is_pid(Proc) of
                      true ->
                          P = simplify(Proc, SimpMap),
                          case ets:insert_new(AccTab, {{proc_line_coverage, P, Where}, 1}) of
                              true ->
                                  ok;
                              false ->
                                  ets:update_counter(AccTab, {proc_line_coverage, P, Where}, 1)
                          end,
                          case maps:is_key(racing_tids, AnalysesData) andalso
                              sets:is_element(TID, maps:get(racing_tids, AnalysesData)) of
                              true ->
                                  Acc1 =
                                      case ets:insert_new(AccTab, {{racing_loc, Where}, 1}) of
                                          true ->
                                              Acc#{racing_fn => 1 + maps:get(racing_fn, Acc, 0)};
                                          false ->
                                              ets:update_counter(AccTab, {racing_loc, Where}, 1),
                                              Acc
                                      end,
                                  case ets:insert_new(AccTab, {{racing_proc_loc, P, Where}, 1}) of
                                      true ->
                                          Acc1#{pl_racing_fn => 1 + maps:get(pl_racing_fn, Acc, 0)};
                                      false ->
                                          ets:update_counter(AccTab, {racing_proc_loc, P, Where}, 1),
                                          Acc1
                                  end;
                              false ->
                                  Acc1 =
                                      case ets:lookup(AccTab, {racing_loc, Where}) of
                                          [] ->
                                              Acc;
                                          _ ->
                                              Acc#{racing_fp => 1 + maps:get(racing_fp, Acc, 0)}
                                      end,
                                  case ets:lookup(AccTab, {racing_proc_loc, P, Where}) of
                                      [] ->
                                          Acc1;
                                      _ ->
                                          Acc1#{pl_racing_fp => 1 + maps:get(pl_racing_fp, Acc, 0)}
                                  end
                          end;
                      false ->
                          Acc
                  end;
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
          end, #{}, Tab),
    case maps:get(verbose_racing_prediction_stat, ExtraOpts, false) of
        true ->
            io:format(user, "Location prediction: FP ~w, FN ~w~n",
                      [maps:get(racing_fp, Result, 0),
                       maps:get(racing_fn, Result, 0)]),
            io:format(user, "Proc-location prediction: FP ~w, FN ~w~n",
                      [maps:get(pl_racing_fp, Result, 0),
                       maps:get(pl_racing_fn, Result, 0)]);
        false ->
            ok
    end,
    ok.

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
                  fun (?TraceSchedule(_, _Where, ProcX, InfoX), Acc) ->
                          Proc = simplify(ProcX, SimpMap),
                          Info = simplify(InfoX, SimpMap),
                          [ {schedule, Proc, Info} | Acc ];
                      (?TraceSend(_, _Where, FromX, ToX, _Type, ContentX, _Effect), Acc) ->
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
simplify(Data, _SimpMap) when is_atom(Data) ->
    case atom_to_list(Data) of
        [ $$, $M, $$ | Rest ] ->
            list_to_atom(lists:dropwhile(fun ($$) -> false; (_) -> true end, Rest));
        [ $$, $E, $$ | Rest ] ->
            list_to_atom(lists:dropwhile(fun ($$) -> false; (_) -> true end, Rest));
        _ -> Data
    end;
simplify(Data, _SimpMap) ->
    Data.

simplify_sht(D, undefined) ->
    D;
simplify_sht([H | T], SimpSHT) ->
    [simplify_sht(H, SimpSHT) | simplify_sht(T, SimpSHT)];
simplify_sht(Data, SimpSHT) when is_tuple(Data) ->
    %% The magic size is from experiments on OTP-20
    case size(Data) > 0 andalso element(1, Data) of
        dict when size(Data) =:= 9 ->
            {dict, simplify_sht(dict:to_list(Data), SimpSHT)};
        set when size(Data) =:= 9 ->
            {set, simplify_sht(sets:to_list(Data), SimpSHT)};
        _ ->
            list_to_tuple(simplify_sht(tuple_to_list(Data), SimpSHT))
    end;
simplify_sht(Data, SimpSHT) when is_map(Data) ->
    maps:fold(
      fun (K, V, Acc) ->
              Acc#{simplify_sht(K, SimpSHT) => simplify_sht(V, SimpSHT)}
      end, #{}, Data);
simplify_sht(Data, SimpSHT) when is_pid(Data) ->
    case ets:lookup(SimpSHT, {proc_abs_id, Data}) of
        [] -> Data;
        [{{proc_abs_id, Data}, Id}] -> Id
    end;
simplify_sht(Data, SimpSHT) when is_reference(Data) ->
    case ets:lookup(SimpSHT, {ref_abs_id, Data}) of
        [] -> Data;
        [{{ref_abs_id, Data}, {Pid, CreationCount}}] ->
            {simplify_sht(Pid, SimpSHT), CreationCount}
    end;
simplify_sht(Data, _SimpSHT) when is_function(Data) ->
    %% Function? Ignore for now...
    {function};
simplify_sht(Data, _SimpSHT) when is_atom(Data) ->
    case atom_to_list(Data) of
        [ $$, $M, $$ | Rest ] ->
            list_to_atom(lists:dropwhile(fun ($$) -> false; (_) -> true end, Rest));
        [ $$, $E, $$ | Rest ] ->
            list_to_atom(lists:dropwhile(fun ($$) -> false; (_) -> true end, Rest));
        _ -> Data
    end;
simplify_sht(Data, _SimpSHT) ->
    Data.

%% For a accumulated table, calculate the path tree fanout function
%%   f(d) := how many path node are at the depth d
%% Returns {MaxDepth, f}, where f has key from [0, MaxDepth]
calc_acc_fanout(AccTab) ->
    [{path_root, Root}] = ets:lookup(AccTab, path_root),
    ChildrenMap =
        ets:foldl(
          fun ({{path_branch, From, _}, To}, Acc) when is_integer(From), is_integer(To) ->
                  Acc#{From => [To | maps:get(From, Acc, [])]};
              %% Dirty hack for Acc in the last version ...
              ({{{path_root, From}, _}, To}, Acc) when is_integer(From), is_integer(To) ->
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
    ToPredict = proplists:get_value(to_predict, Args, false),
    PredictBy = proplists:get_value(predict_by, Args, undefined),
    DumpTraces = proplists:get_value(dump_traces, Args, false),
    DumpTracesVerbose = proplists:get_value(dump_traces_verbose, Args, false),
    DumpPOTraces = proplists:get_value(dump_po_traces, Args, false),
    FindRaces = proplists:get_value(find_races, Args, false),
    POCoverage = proplists:get_value(po_coverage, Args, false),
    PathCoverage = proplists:get_value(path_coverage, Args, false),
    LineCoverage = proplists:get_value(line_coverage, Args, false),
    StateCoverage = proplists:get_value(state_coverage, Args, false),
    ExtraHandlers = proplists:get_value(extra_handlers, Args, []),
    ExtraOpts = proplists:get_value(extra_opts, Args, #{}),
    AccTab =
        case AccFilename of
            undefined -> undefined;
            _ ->
                open_or_create_acc_ets_tab(AccFilename)
        end,
    State = #state{ sht = undefined
                  , tab = Tab
                  , acc_filename = AccFilename
                  , acc_tab = AccTab
                  , acc_fork_period = AccForkPeriod
                  , to_predict = ToPredict
                  , predict_by = PredictBy
                  , pred_state =
                        case ToPredict of
                            true ->
                                #{};
                            false ->
                                undefined
                        end
                  , dump_traces = DumpTraces
                  , dump_traces_verbose = DumpTracesVerbose
                  , dump_po_traces = DumpPOTraces
                  , find_races = FindRaces
                  , po_coverage = POCoverage
                  , path_coverage = PathCoverage
                  , line_coverage = LineCoverage
                  , state_coverage = StateCoverage
                  , extra_handlers = ExtraHandlers
                  , extra_opts = ExtraOpts
                  },
    {ok, State}.

handle_call({set_sht, SHT}, _From, State) ->
    {reply, ok, State#state{sht = SHT}};
handle_call({finalize, TraceInfo, SHT},
            _From,
            #state{ tab = Tab
                  , acc_filename = AF
                  , acc_tab = AccTab
                  , acc_fork_period = AFP
                  , po_coverage = POC
                  , path_coverage = PC
                  , line_coverage = LC
                  , state_coverage = SC
                  , extra_handlers = ExtraHandlers
                  , extra_opts = ExtraOpts
                  }
            = State)
  when Tab =/= undefined, AccTab =/= undefined ->
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
            merge_path_coverage(State, Tab, AccTab, R1),
            [{path_coverage_counter, PathCoverageCount}] = ets:lookup(AccTab, path_coverage_counter),
            [{path_node_counter, PathNodeCount}] = ets:lookup(AccTab, path_node_counter),
            io:format(user, "path coverage count = ~w, ~w~n", [PathCoverageCount, PathNodeCount]);
        false ->
            ok
    end,
    case LC of
        true ->
            merge_line_coverage(State, Tab, AccTab, R1),
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
    case maps:get(verbose_finalize_data, ExtraOpts, false) of
        true -> io:format(user, "Tracer finalize data: ~p~n", [RFinal]);
        false -> ok
    end,
    {reply, RFinal, State};
handle_call({add_trace, {schedule, Where, Proc, Info}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceSchedule(TC, Where, Proc, Info),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {call, From, Where, Req}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceCall(TC, From, Where, Req),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {new_process, Proc, AbsId, Creator, EntryInfo}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceNewProcess(TC, Proc, AbsId, Creator, EntryInfo),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {send, Where, From, To, Type, Content, Effect}}, _From, #state{tab = Tab} = State) when Tab =/= undefined->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceSend(TC, Where, From, To, Type, Content, Effect),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {recv, Where, To, Type, Content}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceRecv(TC, Where, To, Type, Content),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {read, Var}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceRead(TC, Var),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {write, Var}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceWrite(TC, Var),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {barrier}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceBarrier(TC),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({add_trace, {report_state, TraceInfo, RState}}, _From, #state{tab = Tab} = State) when Tab =/= undefined ->
    TC = ets:update_counter(Tab, trace_counter, 1),
    Event = ?TraceReportState(TC, TraceInfo, RState),
    ets:insert(Tab, Event),
    {reply, ok, maybe_update_prediction_state(State, Event)};
handle_call({predict_racing, Where, Proc, Info} = Req, _From, #state{sht = SHT, pred_state = PredState, acc_tab = AccTab} = State) ->
    {Reply, Hit} =
        case State#state.to_predict andalso State#state.predict_by of
            false ->
                {true, false};
            undefined ->
                {true, false};
            path ->
                case maps:is_key(Proc, PredState) of
                    true ->
                        Branch = {schedule, Where, simplify_sht(Proc, SHT), simplify_sht(Info, SHT)},
                        case ets:lookup(AccTab, {path_branch, maps:get(Proc, PredState), Branch}) of
                            [] ->
                                {true, false};
                            [{_, EventId}] ->
                                case ets:lookup(AccTab, {racing_path_flag, EventId}) of
                                    [] ->
                                        {false, true};
                                    _ ->
                                        {true, true}
                                end
                        end;
                    false ->
                        {true, false}
                end;
            ploc ->
                P = simplify_sht(Proc, SHT),
                case ets:lookup(AccTab, {racing_proc_loc, P, Where}) of
                    [] -> case ets:lookup(AccTab, {proc_line_coverage, P, Where}) of
                             [] -> {true, false};
                             _ -> {false, true}
                          end;
                    _ -> {true, true}
                end;
            loc ->
                case ets:lookup(AccTab, {racing_loc, Where}) of
                    [] -> case ets:lookup(AccTab, {line_coverage, Where}) of
                              [] -> {true, false};
                              _ -> {false, true}
                          end;
                    _ -> {true, true}
                end
        end,
    io:format(user, "Tracer ~p => ~w (hit: ~w)~n", [Req, Reply, Hit]),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

maybe_dump_trace(#state{dump_traces = true} = State, Tab, #{simp_map := SimpMap}) ->
    dump_trace(State, Tab, SimpMap);
maybe_dump_trace(_, _, _) ->
    ok.

maybe_extract_partial_order_info(#state{find_races = FindRaces, po_coverage = POC} = State, Tab, #{simp_map := SimpMap} = FinalData) ->
    case FindRaces or POC of
        true ->
            case (catch analyze_partial_order(State, Tab, SimpMap)) of
                {ok, R} ->
                    maps:merge(R, FinalData);
                Other ->
                    io:format(user,
                              "Unexpected result from analyze_partail_order:~n"
                              "  ~p~n"
                              "The trace:~n"
                              "~p~n",
                              [Other, ets:match(Tab, '$1')]),
                    FinalData
            end;
        false ->
            FinalData
    end.


handle_cast(_Msg, State) ->
    {noreply, State}.

maybe_update_prediction_state(#state{to_predict = true, predict_by = path, sht = SHT, pred_state = PredState, acc_tab = AccTab, po_coverage = true, path_coverage = true, find_races = true} = State, Trace) ->
    PredState1 = path_prediction_traverse(Trace, SHT, AccTab, PredState),
    State#state{pred_state = PredState1};
maybe_update_prediction_state(State, _) ->
    State.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
