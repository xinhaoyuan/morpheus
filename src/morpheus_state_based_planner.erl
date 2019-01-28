-module(morpheus_state_based_planner).

-behavior(gen_server).
-export([init/1, handle_call/3, handle_cast/2]).

-export([start/1, get_guidance/1, get_handler/1, finalize/1, handle_trace/3]).

-include("morpheus_trace.hrl").

-record(state, { state_info_filename :: string()
               , state_info          :: ets:tid()
               , trace_info_budget   :: integer()
               , fresh_threshold     :: float()
               , target_guidance     :: term()
               , target_state        :: term()
               , rng                 :: rand:state()
               }).

start(Opts) ->
    gen_server:start(?MODULE, Opts, []).

get_handler(Server) ->
    {?MODULE, Server}.

get_guidance(Server) ->
    gen_server:call(Server, {get_guidance}, infinity).

finalize(Server) ->
    gen_server:call(Server, {finalize}, infinity).

init(Opts) ->
    TabFilename = maps:get(state_info_filename, Opts, undefined),
    Tab =
        case TabFilename of
            undefined ->
                ets:new(?MODULE, []);
            Filename ->
                LoadedTab = morpheus_helper:open_or_create_ets(Filename, fun (_) -> ets:new(?MODULE, []) end),
                io:format(user, "Loaded ~w from tab file ~p~n", [ets:info(LoadedTab, size), TabFilename]), 
                LoadedTab
        end,
    {ok, #state{ state_info_filename = TabFilename
               , state_info = Tab
               , trace_info_budget = maps:get(trace_info_budget, Opts, 10)
               , fresh_threshold = maps:get(fresh_threshold, Opts, 0.2)
               , target_guidance = undefined
               , target_state = undefined
               , rng = rand:seed_s(exrop)
               }
    }.

list_replace(List, PI) ->
    list_replace(List, PI, []).

list_replace([], _, R) ->
    lists:reverse(R);
list_replace([{HP, _HI} = Head | Tail], {P, _I} = PI, R) ->
    case HP > P of
        true ->
            list_replace(Tail, PI, [Head | R]);
        false ->
            list_replace(Tail, Head, [PI | R])
    end.

handle_call({hit_state, State, TraceInfo}, _From,
            #state{state_info = StateInfo, trace_info_budget = Budget, target_guidance = Guidance, target_state = TargetState } = ServerState) ->
    case TraceInfo of
        #{seed := Seed, dequeue_count := DequeueCount} when Seed =/= undefined ->
            NewGuidance =
                case lists:reverse(Guidance) of
                    [H | Rest] when is_integer(H) ->
                        lists:reverse([DequeueCount, {H, Seed} | Rest])
                end,
            P = lists:foldl(
                  fun
                      ({C, _}, Acc) -> Acc + C;
                      (C, Acc) -> Acc + C
                  end,
                  DequeueCount, Guidance),
            case ets:lookup(StateInfo, State) of
                [] ->
                    ets:insert(StateInfo, {State, 1, [{P, NewGuidance}]});
                [{State, HitCount, GuidanceList}] ->
                    NewGuidanceList =
                        case length(GuidanceList) < Budget of
                            true ->
                                [{P, NewGuidance} | GuidanceList];
                            false ->
                                list_replace(GuidanceList, {P, NewGuidance})
                        end,
                    ets:update_element(StateInfo, State, [{2, HitCount + 1}, {3, NewGuidanceList}])
            end,
            {reply, ok, ServerState};
        _ ->
            case ets:lookup(StateInfo, State) of
                [] ->
                    io:format(user, "Warning: unexpected new state ~p~n", [State]);
                [{_State, HitCount, _GuidanceList}] ->
                    ets:update_element(StateInfo, State, [{2, HitCount + 1}])
            end, 
            case TargetState =:= State of
                true ->
                    io:format(user, "Target state hit~n", []),
                    {reply, ok, ServerState#state{target_state = undefined}};
                false ->
                    {reply, ok, ServerState}
            end
    end;

handle_call({get_guidance}, _From, #state{ state_info = StateInfo, rng = Rng, fresh_threshold = FreshT, target_state = TargetState } = ServerState) ->
    case TargetState =:= undefined of
        true ->
            ok;
        false ->
            io:format(user, "Warning: target state not hit:~n  ~p~n", [TargetState])
    end,
    {FreshP, Rng0} = rand:uniform_s(Rng),
    case FreshP < FreshT of
        true ->
            {reply, [0], ServerState#state{rng = Rng0, target_guidance = [0], target_state = undefined}};
        false ->
            {Choice, _, _, Rng1} =
                ets:foldl(
                  fun ({State, HitCount, GuidanceList}, {Choice, MinHit, TieBreaker, CurRng}) ->
                          {ToUpdate, TieBreaker1, CurRng1} =
                              case MinHit =:= HitCount of
                                  true ->
                                      {Cur, _CurRng1} = rand:uniform_s(CurRng),
                                      {Cur > TieBreaker, max(Cur, TieBreaker), _CurRng1};
                                  false ->
                                      {MinHit =:= undefined orelse HitCount < MinHit, TieBreaker, CurRng}
                              end, 
                          case ToUpdate of
                              true ->
                                  {{State, GuidanceList}, HitCount, TieBreaker1, CurRng1};
                              false ->
                                  {Choice, MinHit, TieBreaker1, CurRng1}
                          end
                  end, {undefined, undefined, 0, Rng0}, StateInfo),
            {Reply, NewTargetState, Rng2} =
                case Choice of
                    undefined ->
                        {[0], undefined, Rng1};
                    {_State, GuidanceList} ->
                        {Pick, InnerRng} = rand:uniform_s(length(GuidanceList), Rng1),
                        {_P, Guidance} = lists:nth(Pick, GuidanceList),
                        {Guidance, _State, InnerRng}
                end,
            {reply, Reply, ServerState#state{ rng = Rng2, target_guidance = Reply, target_state = NewTargetState }}
    end;

handle_call({finalize}, _From, #state{ state_info_filename = Filename, state_info = Tab } = State)
  when Filename =/= undefined ->
    ets:tab2file(Tab, Filename ++ ".tmp", [{extended_info, [md5sum]}]),
    os:cmd(lists:flatten(io_lib:format("mv ~s ~s", [Filename ++ ".tmp", Filename]))),
    {stop, normal, ok, State};

handle_call(_Req, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Req, State) ->
    {noreply, State}.

handle_trace(Server, Tab, #{simp_map := SimpMap} = Data) ->
    ets:foldl(
      fun (?TraceReportState(_TS, TraceInfo, State), Acc) ->
              gen_server:call(Server, {hit_state, morpheus_tracer:simplify(State, SimpMap), TraceInfo}, infinity),
              Acc;
          (_, Acc) ->
              Acc
      end, undefined, Tab),
    Data.
